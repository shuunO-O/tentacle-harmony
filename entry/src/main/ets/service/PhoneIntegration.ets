import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PhoneAction, PhoneLiveMeta, PhoneReceipt, PhoneRegistrationResult, SavedPhoneRound, validatePhoneAlarm } from '../model/PhoneProtocol';
import { ApiFailure, UnauthorizedError, WsEvent } from '../model/Types';
import { PhoneNative } from './PhoneNative';
import { TentacleApi } from './TentacleApi';

export class PhoneIntegration {
  private static instance: PhoneIntegration = new PhoneIntegration();
  static getInstance(): PhoneIntegration { return PhoneIntegration.instance; }
  private prefs: preferences.Preferences | null = null;
  private native: PhoneNative | null = null;
  private deviceId: string = '';
  private secret: string = '';
  private pushToken: string = '';
  private foreground: boolean = false;
  private timer: number = -1;
  private syncing: boolean = false;
  private generation: number = 0;
  private registeredServer: string = '';
  private registering: Promise<void> | null = null;
  private credentialsReady: Promise<void> | null = null;
  private alarms: boolean = false;
  private live: boolean = false;
  private receipts: PhoneReceipt[] = [];
  private rounds: SavedPhoneRound[] = [];
  private finishing: Set<string> = new Set<string>();

  init(context: common.UIAbilityContext): void {
    if (this.native !== null) { return; }
    this.native = new PhoneNative(context);
    this.prefs = preferences.getPreferencesSync(context, { name: 'tentacle_phone' });
    this.deviceId = this.prefs.getSync('device_id', '') as string;
    this.secret = this.prefs.getSync('secret', '') as string;
    if (!this.deviceId || !this.secret) {
      this.deviceId = util.generateRandomUUID();
      this.secret = util.generateRandomUUID() + util.generateRandomUUID();
      this.prefs.putSync('device_id', this.deviceId); this.prefs.putSync('secret', this.secret);
      this.credentialsReady = this.prefs.flush();
      this.credentialsReady.catch(() => this.status('设备凭证保存失败，请重新打开应用'));
    }
    this.alarms = this.prefs.getSync('alarms', false) as boolean;
    this.live = this.prefs.getSync('live', false) as boolean;
    AppStorage.setOrCreate('phoneAlarms', this.alarms);
    AppStorage.setOrCreate('phoneLiveView', this.live);
    this.status('等待连接');
    TentacleApi.getInstance().onWsEvent((evt: WsEvent) => this.onEvent(evt));
    TentacleApi.getInstance().onPhoneReset(() => this.disconnect());
  }

  private status(message: string): void { AppStorage.setOrCreate('phoneStatus', message); }

  private setupFailure(stage: string, error: Error): Error {
    const systemCode = (error as BusinessError).code;
    const code = Number.isInteger(systemCode) ? systemCode : 0;
    const httpStatus = error instanceof ApiFailure ? error.httpStatus :
      (error instanceof UnauthorizedError ? 401 : 0);
    let message = '手机能力未能初始化，请重新打开应用';
    if (stage === 'notification') {
      message = '通知授权未完成，请在系统设置中允许 Tentacle 通知' +
        (code ? '（错误码 ' + code.toString() + '）' : '');
    } else if (stage === 'storage') {
      message = '手机能力设置保存失败，请检查本机存储后重试';
    } else if (stage === 'ledger') {
      message = '本机操作回执损坏，已停止接收新指令以免重复设置';
    } else if (stage === 'push') {
      message = '推送标识获取失败，请检查推送服务和签名配置' +
        (code ? '（错误码 ' + code.toString() + '）' : '');
    } else if (stage === 'registration') {
      if (httpStatus === 404 || httpStatus === 405) {
        message = '服务器未启用或未提供 harmony 插件接口（HTTP ' + httpStatus.toString() + '），请在「插件扩展」启用或更新后端';
      } else if (httpStatus === 401) {
        message = '手机注册未完成：登录已失效，请重新连接服务器';
      } else if (httpStatus === 403) {
        message = '服务器拒绝手机注册（HTTP 403），请检查设备授权';
      } else if (httpStatus) {
        message = '手机注册失败（HTTP ' + httpStatus.toString() + '），请检查后端';
      } else {
        message = '手机注册未完成，请检查服务器连接后重试';
      }
    }
    this.status(message);
    // Only fixed stages and numeric codes; never log credentials or response bodies.
    hilog.warn(0x0001, 'TentaclePhoneSetup', 'stage=%{public}s http_status=%{public}d system_code=%{public}d',
      stage, httpStatus, code);
    return new Error(message);
  }

  async configure(alarms: boolean, live: boolean): Promise<void> {
    if (this.native === null || this.prefs === null) { throw this.setupFailure('initialization', new Error()); }
    if (alarms || live) {
      try { await this.native.enableNotifications(); }
      catch (error) { throw this.setupFailure('notification', error as Error); }
    }
    if (this.live && !live) {
      for (const round of this.rounds) {
        if (!round.finished) {
          try { await this.native.finishLive(round.activityId, '已关闭实况窗'); round.finished = true; }
          catch (_) { this.status('部分实况窗尚未关闭，请检查系统通知'); }
        }
      }
      if (this.registeredServer) { await this.saveRounds(); }
    }
    this.alarms = alarms; this.live = live;
    try {
      this.prefs.putSync('alarms', alarms); this.prefs.putSync('live', live); await this.prefs.flush();
    } catch (error) { throw this.setupFailure('storage', error as Error); }
    AppStorage.setOrCreate('phoneAlarms', alarms); AppStorage.setOrCreate('phoneLiveView', live);
    this.registeredServer = ''; this.registering = null; this.generation++;
    if (this.foreground) {
      if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
      if (alarms || live) { this.timer = setInterval(() => this.sync(), 10000); }
    }
    if (!alarms && !live) {
      try { await TentacleApi.getInstance().unregisterPhone(); } finally {
        TentacleApi.getInstance().setPhoneIdentity('', ''); this.status('已关闭手机能力');
      }
      return;
    }
    await this.connected();
  }

  getPushToken(): string { return this.pushToken; }

  async refreshPushToken(): Promise<string> {
    if (this.native === null) { throw this.setupFailure('initialization', new Error()); }
    const generation = this.generation;
    const api = TentacleApi.getInstance();
    const scope = api.getServerUrl();
    try { await this.native.enableNotifications(); }
    catch (error) { throw this.setupFailure('notification', error as Error); }
    let token: string;
    try {
      token = await this.native.pushToken();
      if (!token) { throw new Error(); }
    } catch (error) { throw this.setupFailure('push', error as Error); }
    if (generation !== this.generation || scope !== api.getServerUrl()) {
      throw new Error('连接已变化，请重新获取推送标识');
    }
    this.pushToken = token;
    if (this.alarms || this.live) {
      this.generation++; this.registeredServer = ''; this.registering = null;
      await this.connected();
    } else { this.status('已获取推送标识；开启手机能力并连接后可绑定到服务器'); }
    return token;
  }

  async connected(): Promise<void> {
    if (this.native === null || (!this.alarms && !this.live)) { return; }
    const api = TentacleApi.getInstance();
    const scope = api.getServerUrl();
    if (!scope) { this.status('请先连接服务器，再启用手机能力'); throw new Error('请先连接服务器'); }
    if (this.registeredServer === scope) { return; }
    if (this.registering !== null) { return this.registering; }
    const generation = this.generation;
    this.registering = this.register(scope, generation);
    try { await this.registering; } finally { if (generation === this.generation) { this.registering = null; } }
  }

  private async register(scope: string, generation: number): Promise<void> {
    if (this.native === null || this.prefs === null) { return; }
    if (this.credentialsReady !== null) {
      try { await this.credentialsReady; }
      catch (error) { throw this.setupFailure('storage', error as Error); }
    }
    if (this.live) {
      try { this.pushToken = await this.native.pushToken(); }
      catch (_) { this.pushToken = ''; }
    }
    if (generation !== this.generation) { return; }
    const api = TentacleApi.getInstance();
    let result: PhoneRegistrationResult;
    try {
      result = await api.registerPhone({ device_id: this.deviceId, secret: this.secret,
        push_token: this.pushToken, timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
        alarms: this.alarms, live_view: this.live });
    } catch (error) {
      if (generation !== this.generation || scope !== api.getServerUrl()) { return; }
      throw this.setupFailure('registration', error as Error);
    }
    if (generation !== this.generation || scope !== api.getServerUrl()) { return; }
    let savedReceipts: PhoneReceipt[];
    let savedRounds: SavedPhoneRound[];
    try {
      savedReceipts = JSON.parse(this.prefs.getSync('receipts:' + scope, '[]') as string) as PhoneReceipt[];
      savedRounds = JSON.parse(this.prefs.getSync('rounds:' + scope, '[]') as string) as SavedPhoneRound[];
    } catch (error) { throw this.setupFailure('ledger', error as Error); }
    if (!Array.isArray(savedReceipts) || !Array.isArray(savedRounds) || savedReceipts.some((r: PhoneReceipt) =>
      r === null || typeof r.id !== 'string' || typeof r.status !== 'string' || typeof r.result !== 'string') ||
      savedRounds.some((r: SavedPhoneRound) => r === null || typeof r.requestId !== 'string' ||
        !Number.isInteger(r.activityId) || typeof r.finished !== 'boolean')) {
      throw this.setupFailure('ledger', new Error());
    }
    this.receipts = savedReceipts; this.rounds = savedRounds;
    api.setPhoneIdentity(this.deviceId, this.secret);
    this.registeredServer = scope;
    this.status(this.live && (!this.pushToken || !result.push_configured)
      ? '已连接；云端实况窗尚未就绪，请检查推送配置' : '手机能力已连接');
    hilog.info(0x0001, 'TentaclePhoneSetup', 'stage=registration result=connected');
    this.sync();
  }

  foregroundChanged(value: boolean): void {
    this.foreground = value;
    if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
    if (value) {
      this.registeredServer = '';
      if (AppStorage.get<boolean>('connected') === true) {
        this.connected().then(() => this.sync()).catch(() => {});
      }
      if (this.alarms || this.live) { this.timer = setInterval(() => this.sync(), 10000); }
    }
  }

  disconnect(): void {
    this.generation++; this.registeredServer = ''; this.registering = null;
    TentacleApi.getInstance().setPhoneIdentity('', '');
    this.status('等待重新连接');
  }

  private async saveReceipts(scope: string, receipts: PhoneReceipt[]): Promise<void> {
    if (this.prefs === null || !scope) { throw new Error('设备连接已变化'); }
    this.prefs.putSync('receipts:' + scope, JSON.stringify(receipts));
    await this.prefs.flush();
  }

  private async saveRounds(): Promise<void> {
    if (this.prefs === null || !this.registeredServer) { throw new Error('设备连接已变化'); }
    this.prefs.putSync('rounds:' + this.registeredServer, JSON.stringify(this.rounds)); await this.prefs.flush();
  }

  async sync(): Promise<void> {
    if (!this.foreground || !this.registeredServer || this.syncing) { return; }
    const generation = this.generation;
    this.syncing = true;
    try {
      const state = await TentacleApi.getInstance().phoneState();
      for (const action of state.actions) {
        if (generation !== this.generation || !this.foreground) { return; }
        await this.execute(action);
      }
      for (const round of state.rounds) {
        if (generation !== this.generation) { return; }
        if (round.status !== 'thinking') { await this.finishRound(round.request_id, round.status); }
      }
    } catch (_) { this.status('手机同步未完成，回前台或点击重试后继续'); }
    finally { this.syncing = false; }
  }

  private async execute(action: PhoneAction): Promise<void> {
    if (this.native === null || !this.alarms) { return; }
    const generation = this.generation;
    const scope = this.registeredServer;
    this.receipts = this.receipts.filter((r: PhoneReceipt) => r.expiresAt === undefined || r.expiresAt > Date.now());
    const receipts = this.receipts;
    let receipt = receipts.find((r: PhoneReceipt) => r.id === action.id);
    if (receipt === undefined) {
      if (receipts.length >= 512) { throw new Error('闹钟回执存储已满'); }
      receipt = { id: action.id, status: 'unknown', result: '执行结果未知，请检查闹钟；不会自动重复设置',
        expiresAt: Number.isFinite(action.expires_at) ? action.expires_at + 86400000 : Date.now() + 2 * 86400000 };
      receipts.push(receipt);
      // Persist before crossing the OS boundary. A crash here must never duplicate an alarm.
      await this.saveReceipts(scope, receipts);
      if (generation !== this.generation || !this.foreground || !this.alarms) { return; }
      try {
        validatePhoneAlarm(action, Date.now());
        const id = await this.native.createAlarm(action);
        receipt.status = 'executed'; receipt.result = id.toString();
      } catch (_) {
        receipt.status = 'failed'; receipt.result = '闹钟未设置成功，请检查代理提醒权益和通知权限';
      }
      await this.saveReceipts(scope, receipts);
    }
    if (generation !== this.generation) { return; }
    await TentacleApi.getInstance().phoneReceipt(receipt.id, receipt.status, receipt.result);
    this.status(receipt.status === 'executed' ? '闹钟已交给系统，到点无需保持应用连接' : receipt.result);
  }

  async prepareRound(requestId: string): Promise<PhoneLiveMeta | undefined> {
    if (this.native === null || (!this.alarms && !this.live)) { return undefined; }
    if (!this.registeredServer) {
      this.connected().catch(() => {});
      return undefined;
    }
    if (!this.live || !this.foreground || !this.registeredServer) { return undefined; }
    const id = Math.floor(Math.random() * 2000000000) + 1;
    const generation = this.generation;
    let started = false;
    try {
      await this.native.startLive(id);
      started = true;
      if (generation !== this.generation || !this.foreground) { throw new Error('应用状态已变化'); }
      this.rounds = this.rounds.filter((r: SavedPhoneRound) => !r.finished).concat([
        { requestId: requestId, activityId: id, finished: false }
      ]);
      await this.saveRounds();
      return { activity_id: id, event: 'PROGRESS' };
    } catch (_) {
      if (started) { try { await this.native.finishLive(id, '本次实况窗未启用'); } catch (_) {} }
      this.status('本地实况窗未创建，请检查系统开关及调测设备配置'); return undefined;
    }
  }

  async finishRound(requestId: string, status: string): Promise<void> {
    const round = this.rounds.find((r: SavedPhoneRound) => r.requestId === requestId);
    if (round === undefined || round.finished || this.native === null) { return; }
    if (status === 'unconfirmed') { this.status('连接中断，本轮结果将在恢复后同步'); return; }
    if (this.finishing.has(requestId)) { return; }
    this.finishing.add(requestId);
    try {
      await this.native.finishLive(round.activityId, status === 'completed' ? '回复完成' :
        (status === 'unconfirmed' || status === 'unknown' ? '连接中断，结果待确认' : '本轮已结束'));
      round.finished = true; await this.saveRounds();
    } catch (_) { this.status('实况窗状态待同步，请回前台后重试'); }
    finally { this.finishing.delete(requestId); }
  }

  isSendPluginRejection(error: Error): boolean {
    if (!(error instanceof ApiFailure) || error.round !== undefined) {
      return false;
    }
    if (error.httpStatus === 422) {
      return true;
    }
    if (error.httpStatus === 403 && (error.message.includes('实况窗') ||
      error.message.includes('手机未注册') || error.message.includes('手机授权已失效'))) {
      return true;
    }
    return error.httpStatus === 400 && error.message.includes('实况窗');
  }

  async handleSendRejection(requestId: string, error: Error): Promise<boolean> {
    if (!this.isSendPluginRejection(error)) {
      return false;
    }
    const apiErr = error as ApiFailure;
    const identityInvalid = apiErr.httpStatus === 403 &&
      (apiErr.message.includes('手机未注册') || apiErr.message.includes('手机授权已失效'));
    await this.finishRound(requestId, 'failed');
    if (identityInvalid) {
      this.registeredServer = '';
      TentacleApi.getInstance().setPhoneIdentity('', '');
      this.status('手机注册已失效，已改为普通发送；请在设置重连');
    } else if (apiErr.httpStatus === 403) {
      this.status('服务端已禁用实况窗同步，已改为普通发送');
    } else {
      if (apiErr.httpStatus === 400) {
        this.registeredServer = '';
      }
      this.status('实况窗参数未通过服务端校验，已改为普通发送');
    }
    return true;
  }

  private onEvent(evt: WsEvent): void {
    if (evt.type === 'unauthorized') { this.disconnect(); }
    if (evt.type === 'phone_action' && evt.data.device_id === this.deviceId) { this.sync(); }
    if (evt.type === 'round_finished' && evt.data.request_id) {
      this.finishRound(evt.data.request_id, evt.data.status ?? 'unknown');
    }
  }
}
