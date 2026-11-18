/**
 * Tentacle 后端网络封装（单例）
 *
 * - REST：@kit.NetworkKit http
 * - WebSocket：实时事件订阅 + 自动重连
 * - 配置持久化：@kit.ArkData preferences
 */

import { http } from '@kit.NetworkKit';
import { webSocket } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { GraphSnapshot } from '../model/GraphSnapshot';
import { LocalCache, cacheHash } from './LocalCache';
import { ChatRecovery } from './ChatRecovery';

  import {
  Settings,
  LoginResult,
  EnrollResult,
  AuthState,
  SendResult,
  StatusData,
  HistoryResult,
  TableData,
  WsEvent,
  ApiErrorDetail,
  ApiFailure,
  SetPasswordResult,
  UnauthorizedError,
  TerminalHistoryResult,
  Neo4jSummaryResult,
  Neo4jGraphResult,
  UsageResult,
  BalanceResult,
  UploadResult,
  FileRecord,
  GraphData,
  GraphSummary,
  chatStore,
  ChatSnapshot,
  ChatStopTarget,
  ChatStopResult,
} from '../model/Types';
import { CommandCatalog } from '../model/ChatCommands';
import { PhoneRegistration, PhoneRegistrationResult, PhoneLiveMeta, PhoneState } from '../model/PhoneProtocol';
import { ConfigSnapshot, ConfigPreview, ConfigValue, ConfigEnvResult, StructureOperation, ModelCatalog, RestartState,
  DeviceInfo, SelfBackupsResult, SubagentList, SubagentDetail, DedupStatus, DedupAuditResult,
  MaintenanceStatus, MaintenanceOperation } from '../model/Management';
import { McpServerConfig, PluginDecisionPayload, PluginEnvWriteResult, PluginsSnapshot } from '../model/Plugins';

const PREFS_NAME = 'tentacle_app';
const KEY_SERVER_URL = 'server_url';
const KEY_TOKEN = 'token';
const KEY_DEVICE_COOKIE = 'device_cookie';
const DEVICE_COOKIE_NAME = 'tentacle_device';

export interface FilesResult { files: FileRecord[]; }
interface SavedGraph { summary: GraphSummary; graph: GraphData; updatedAt: number; }
interface SavedUpload { key: string; file: FileRecord; }

export class TentacleApi {
  private static instance: TentacleApi = new TentacleApi();

  static getInstance(): TentacleApi {
    return TentacleApi.instance;
  }

  private serverUrl: string = '';
  private token: string = '';
  private deviceCookie: string = '';
  private phoneDeviceId: string = '';
  private phoneDeviceSecret: string = '';
  private phoneResetListener: (() => void) | null = null;
  private prefs: preferences.Preferences | null = null;
  private ws: webSocket.WebSocket | null = null;
  private wsConnected: boolean = false;
  private manualClose: boolean = false;
  private reconnectTimer: number = -1;
  private listeners: Array<(evt: WsEvent) => void> = [];
  private connListeners: Array<(online: boolean) => void> = [];
  private readonly appPlatform: string = 'harmony';
  private imageCache: Map<string, string> = new Map<string, string>();
  private imagePending: Map<string, Promise<string>> = new Map();
  private uploaded: Map<string, FileRecord> = new Map();
  private uploadPending: Map<string, Promise<FileRecord>> = new Map();
  private cacheEpoch: number = 0;
  private graphSnapshot: GraphSnapshot | null = null;
  private graphPending: Promise<GraphSnapshot> | null = null;
  private graphFreshAt: number = 0;
  private graphRevision: number = 0;
  private localCache: LocalCache | null = null;
  private cacheRoot: string = '';
  private graphDiskLoaded: boolean = false;
  private graphDiskPending: Promise<GraphSnapshot | null> | null = null;
  private uploadDiskLoaded: boolean = false;
  private chatRecovery: ChatRecovery = new ChatRecovery(chatStore,
    (limit: number) => this.getChatSync(limit), (event: WsEvent) => this.dispatchWs(event));

  getCacheEpoch(): number { return this.cacheEpoch; }

  private clearCaches(): void {
    if (this.localCache !== null) { this.localCache.closeAndClear(); this.localCache = null; }
    this.cacheEpoch++;
    this.imageCache.clear(); this.imagePending.clear();
    this.uploaded.clear(); this.uploadPending.clear();
    this.graphSnapshot = null; this.graphPending = null;
    this.graphDiskLoaded = false; this.graphDiskPending = null; this.uploadDiskLoaded = false;
    this.invalidateGraph();
  }

  private invalidateGraph(): void { this.graphFreshAt = 0; this.graphRevision++; }

  peekGraph(): GraphSnapshot | null { return this.graphSnapshot; }

  private activateLocalCache(): void {
    if (this.cacheRoot && this.localCache === null) {
      this.localCache = new LocalCache(this.cacheRoot, JSON.stringify([this.serverUrl, this.token, this.deviceCookie]));
    }
  }

  async clearLocalCache(): Promise<void> {
    const previous = this.localCache;
    this.clearCaches();
    if (previous !== null) { await previous.flush(); }
    this.activateLocalCache();
  }

  async localCacheBytes(): Promise<number> { return this.localCache === null ? 0 : this.localCache.size(); }

  async restoreGraphCache(): Promise<GraphSnapshot | null> {
    if (this.graphSnapshot !== null || this.graphDiskLoaded || this.localCache === null) { return this.graphSnapshot; }
    if (this.graphDiskPending !== null) { return this.graphDiskPending; }
    const task = this.readGraphCache(this.localCache, this.cacheEpoch);
    this.graphDiskPending = task;
    try { return await task; }
    finally { if (this.graphDiskPending === task) { this.graphDiskPending = null; } }
  }

  private async readGraphCache(disk: LocalCache, epoch: number): Promise<GraphSnapshot | null> {
    const text = await disk.read('graph', 7 * 86400000);
    if (epoch !== this.cacheEpoch) { return null; }
    this.graphDiskLoaded = true;
    if (this.graphSnapshot !== null || text === null) { return this.graphSnapshot; }
    try {
      const saved = JSON.parse(text) as SavedGraph;
      if (!saved.graph || !Array.isArray(saved.graph.nodes) || !Array.isArray(saved.graph.relationships) ||
        !saved.summary || !saved.summary.nodes || !Number.isFinite(saved.updatedAt) ||
        !saved.graph.nodes.every((node) => typeof node.id === 'string' && typeof node.label === 'string') ||
        !saved.graph.relationships.every((edge) => typeof edge.source === 'string' && typeof edge.target === 'string' && typeof edge.type === 'string')) {
        throw new Error('Invalid cached graph');
      }
      const snapshot = new GraphSnapshot(saved.summary, saved.graph);
      snapshot.updatedAt = saved.updatedAt;
      this.graphSnapshot = snapshot;
      // A snapshot restored after process restart is always revalidated.
      this.graphFreshAt = 0;
    } catch (e) { await disk.remove('graph'); }
    return this.graphSnapshot;
  }

  private async restoreUploads(disk: LocalCache, epoch: number): Promise<void> {
    if (this.uploadDiskLoaded) { return; }
    const text = await disk.read('uploads', 30 * 86400000);
    if (epoch !== this.cacheEpoch || this.uploadDiskLoaded) { return; }
    this.uploadDiskLoaded = true;
    if (text === null) { return; }
    try {
      const records = JSON.parse(text) as SavedUpload[];
      if (!Array.isArray(records) || records.length > 64 || !records.every((item: SavedUpload) =>
        typeof item.key === 'string' && item.key.length <= 2048 && item.file && typeof item.file.local_id === 'string' &&
        typeof item.file.filename === 'string' && typeof item.file.mime === 'string' && typeof item.file.path === 'string')) {
        throw new Error('Invalid upload cache');
      }
      for (const record of records) {
        if (!this.uploaded.has(record.key)) { this.uploaded.set(record.key, record.file); }
      }
    } catch (e) { await disk.remove('uploads'); }
  }

  private persistUploads(): void {
    const records: SavedUpload[] = [];
    this.uploaded.forEach((file: FileRecord, key: string) => { records.push({ key: key, file: file }); });
    if (this.localCache !== null) { this.localCache.write('uploads', JSON.stringify(records)); }
  }

  async getGraphSnapshot(force: boolean = false): Promise<GraphSnapshot> {
    const startedEpoch = this.cacheEpoch;
    await this.restoreGraphCache();
    if (startedEpoch !== this.cacheEpoch) { throw new Error('连接已变化'); }
    if (!force && this.graphSnapshot !== null && Date.now() - this.graphFreshAt < 30000) {
      return this.graphSnapshot;
    }
    if (this.graphPending !== null) { return this.graphPending; }
    const epoch = this.cacheEpoch;
    const revision = this.graphRevision;
    const task = this.fetchGraphSnapshot(epoch, revision);
    this.graphPending = task;
    try { return await task; }
    finally { if (this.graphPending === task) { this.graphPending = null; } }
  }

  private async fetchGraphSnapshot(epoch: number, revision: number): Promise<GraphSnapshot> {
    const results = await Promise.all([this.getNeo4jSummary(), this.getNeo4jGraph()]);
    if (epoch !== this.cacheEpoch) { throw new Error('连接已变化'); }
    const summary = results[0]; const graph = results[1];
    if (!summary.ok || !graph.ok || !summary.data || !graph.data) {
      throw new Error(graph.error || summary.error || '图谱加载失败');
    }
    const snapshot = new GraphSnapshot(summary.data, graph.data);
    this.graphSnapshot = snapshot;
    this.graphFreshAt = revision === this.graphRevision ? Date.now() : 0;
    if (this.localCache !== null) {
      const saved: SavedGraph = { summary: summary.data, graph: graph.data, updatedAt: snapshot.updatedAt };
      this.localCache.write('graph', JSON.stringify(saved));
    }
    return snapshot;
  }

  // ---------- 初始化与配置 ----------

  init(context: common.Context): void {
    try {
      this.prefs = preferences.getPreferencesSync(context, { name: PREFS_NAME });
      this.serverUrl = this.prefs.getSync(KEY_SERVER_URL, '') as string;
      this.token = this.prefs.getSync(KEY_TOKEN, '') as string;
      this.deviceCookie = this.prefs.getSync(KEY_DEVICE_COOKIE, '') as string;
      if (typeof context.filesDir === 'string' && context.filesDir.length > 0) {
        this.cacheRoot = context.filesDir + '/tentacle-cache-v1';
        this.activateLocalCache();
      }
    } catch (e) {
      this.prefs = null;
    }
  }

  hasSavedServer(): boolean {
    return this.serverUrl.length > 0;
  }

  getServerUrl(): string {
    return this.serverUrl;
  }

  getToken(): string {
    return this.token;
  }

  isWsConnected(): boolean {
    return this.wsConnected;
  }

  private saveConfig(): void {
    if (this.prefs === null) {
      return;
    }
    try {
      this.prefs.putSync(KEY_SERVER_URL, this.serverUrl);
      this.prefs.putSync(KEY_TOKEN, this.token);
      this.prefs.putSync(KEY_DEVICE_COOKIE, this.deviceCookie);
      this.prefs.flush().catch(() => {
        // 忽略持久化失败
      });
    } catch (e) {
      // 忽略
    }
  }

  private normalizeUrl(input: string): string {
    let u = input.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'http://' + u;
    }
    return u;
  }

  private wsUrl(): string {
    let base = this.serverUrl;
    if (base.startsWith('https://')) {
      base = 'wss://' + base.substring(8);
    } else if (base.startsWith('http://')) {
      base = 'ws://' + base.substring(7);
    }
    return base + '/ws/chat?token=' + encodeURIComponent(this.token);
  }

  // ---------- REST 基础 ----------

  private buildHeader(): object {
    let s = '{"Content-Type":"application/json"';
    if (this.phoneDeviceId && this.phoneDeviceSecret) {
      s += ',"X-Tentacle-Device":' + JSON.stringify(this.phoneDeviceId) +
        ',"X-Tentacle-Device-Secret":' + JSON.stringify(this.phoneDeviceSecret);
    }
    if (this.token.length > 0) {
      s = s + ',"Authorization":"Bearer ' + this.token + '"';
    }
    if (this.deviceCookie.length > 0) {
      s = s + ',"Cookie":"' + DEVICE_COOKIE_NAME + '=' + this.deviceCookie + '"';
    }
    s = s + '}';
    return JSON.parse(s) as object;
  }

  private buildHeaderRaw(pairs: string[][]): object {
    let s = '{';
    for (let i = 0; i < pairs.length; i++) {
      if (i > 0) {
        s = s + ',';
      }
      s = s + '"' + pairs[i][0] + '":' + JSON.stringify(pairs[i][1]);
    }
    s = s + '}';
    return JSON.parse(s) as object;
  }

  private request<T>(path: string, method: http.RequestMethod, body: string,
    readTimeoutMs: number = 60000): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const req = http.createHttp();
      req.request(this.serverUrl + path, {
        method: method,
        header: this.buildHeader(),
        extraData: body,
        // REST 均为动态状态；切页和重连必须向服务端取最新快照。
        usingCache: false,
        connectTimeout: 10000,
        readTimeout: readTimeoutMs,
      }, (err: BusinessError, data: http.HttpResponse) => {
        req.destroy();
        if (err) {
          reject(new Error(err.message));
          return;
        }
        const code: number = data.responseCode;
        const text: string = String(data.result);
        if (code === 401) {
          // 凭证失效：仿 WebUI 即时弹回连接面板（Index 监听 unauthorized 事件）
          this.notifyWs({ type: 'unauthorized', data: {} });
          reject(new UnauthorizedError());
          return;
        }
        if (code >= 200 && code < 300) {
          if (text.length === 0) {
            reject(new Error('empty response'));
            return;
          }
          try {
            const parsed: T = JSON.parse(text) as T;
            if (method !== http.RequestMethod.GET && (path.startsWith('/api/neo4j/') || path.startsWith('/api/memory/') || path === '/api/admin/query')) {
              this.invalidateGraph();
            }
            resolve(parsed);
          } catch (e) {
            reject(new Error('invalid json'));
          }
          return;
        }
        try {
          const detail = JSON.parse(text) as ApiErrorDetail;
          const msg = typeof detail.detail === 'string' && detail.detail.length > 0 ? detail.detail :
            (detail.detail !== undefined ? JSON.stringify(detail.detail) : 'HTTP ' + code.toString());
          reject(new ApiFailure(msg, detail.round, code));
        } catch (e) {
          reject(new ApiFailure('HTTP ' + code.toString(), undefined, code));
        }
      });
    });
  }

  private jsonObj(pairs: Array<Array<string>>): string {
    let s = '{';
    for (let i = 0; i < pairs.length; i++) {
      if (i > 0) {
        s = s + ',';
      }
      s = s + '"' + pairs[i][0] + '":' + pairs[i][1];
    }
    s = s + '}';
    return s;
  }

  // ---------- 认证与连接 ----------

  /**
   * 连接流程（状态驱动，与 WebUI 一致：先设备绑定后密码登录）：
   * 1. GET /api/auth/state 探测鉴权要求（公开端点）
   * 2. 设备门开启且本机未绑定 -> POST /api/auth/enroll（主机脚本 gen-code 生成的一次性绑定码），
   *    成功后解析 Set-Cookie 持久化 tentacle_device
   * 3. 服务端设了密码 -> POST /api/auth/login 取 Bearer token
   * 4. GET /api/settings 打通全部权限
   */
  async connectAndAuth(serverUrl: string, password: string, enrollCode: string): Promise<Settings> {
    this.resetPhoneSession();
    this.clearCaches();
    this.serverUrl = this.normalizeUrl(serverUrl);
    this.token = '';
    this.saveConfig();
    let st = await this.getAuthState();
    hilog.info(0x0001, 'TentacleAuth',
      'state: dev_auth=%{public}s dev_ok=%{public}s has_pw=%{public}s freeze=%{public}s',
      st.device_auth.toString(), st.device_ok.toString(), st.has_password.toString(), st.freeze.toString());
    if (st.device_auth && !st.device_ok) {
      if (enrollCode.trim().length === 0) {
        throw new Error('设备验证已开启：请在主机运行 scripts/device_token.py gen-code 生成绑定码');
      }
      await this.enroll(enrollCode.trim(), '');
      hilog.info(0x0001, 'TentacleAuth', 'enroll done, saved cookie len=%{public}d',
        this.deviceCookie.length);
      st = await this.getAuthState();
      hilog.info(0x0001, 'TentacleAuth', 'state after enroll: dev_ok=%{public}s',
        st.device_ok.toString());
      if (st.device_auth && !st.device_ok) {
        throw new Error('设备绑定未生效，请重试');
      }
    }
    if (st.has_password) {
      if (password.length === 0) {
        throw new Error('请输入访问密码');
      }
      try {
        const login = await this.login(password);
        this.token = login.token;
        this.saveConfig();
      } catch (e) {
        if (e instanceof UnauthorizedError) {
          throw new Error('密码错误');
        }
        throw new Error(e instanceof Error ? e.message : String(e));
      }
    }
    const settings = await this.getSettings();
    this.activateLocalCache();
    return settings;
  }

  async autoConnect(): Promise<Settings> {
    if (this.serverUrl.length === 0) {
      throw new Error('未配置服务器');
    }
    const s = await this.getSettings();
    return s;
  }

  async login(password: string): Promise<LoginResult> {
    const body = '{"password":' + JSON.stringify(password) + '}';
    return this.request<LoginResult>('/api/auth/login', http.RequestMethod.POST, body);
  }

  getAuthState(): Promise<AuthState> {
    return this.request<AuthState>('/api/auth/state', http.RequestMethod.GET, '');
  }

  /**
   * 设备绑定：凭一次性绑定码换设备 cookie（tentacle_device，10 年有效期）。
   * 使用自定义请求以读取 HttpResponse.cookies（Set-Cookie 数组）。
   */
  /** 绑定码指纹（检测 IME 大小写转换/非法字符/长度问题；hex 码为 16 位小写 [0-9a-f]） */
  private codeFingerprint(code: string): string {
    let upper = 0;
    let bad = 0;
    for (let i = 0; i < code.length; i++) {
      const cc = code.charCodeAt(i);
      if (cc >= 65 && cc <= 70) {
        upper = upper + 1;
      } else if (!((cc >= 48 && cc <= 57) || (cc >= 97 && cc <= 102))) {
        bad = bad + 1;
      }
    }
    return 'len=' + code.length.toString() + ' upper=' + upper.toString() + ' bad=' + bad.toString();
  }

  async enroll(code: string, name: string): Promise<EnrollResult> {
    hilog.info(0x0001, 'TentacleAuth', 'enroll code %{public}s', this.codeFingerprint(code));
    return new Promise<EnrollResult>((resolve, reject) => {
      const req = http.createHttp();
      const body = '{"code":' + JSON.stringify(code) + ',"name":' + JSON.stringify(name) + '}';
      req.request(this.serverUrl + '/api/auth/enroll', {
        method: http.RequestMethod.POST,
        header: this.buildHeader(),
        extraData: body,
        connectTimeout: 10000,
        readTimeout: 30000,
      }, (err: BusinessError, data: http.HttpResponse) => {
        req.destroy();
        if (err) {
          hilog.error(0x0001, 'TentacleAuth', 'enroll req err: %{public}s', err.message);
          reject(new Error(err.message));
          return;
        }
        const codeNum: number = data.responseCode;
        const text: string = String(data.result);
        hilog.info(0x0001, 'TentacleAuth', 'enroll resp: code=%{public}d response_bytes=%{public}d',
          codeNum, text.length);
        if (codeNum >= 200 && codeNum < 300) {
          const cookieValue = this.extractDeviceCookie(data.cookies);
          hilog.info(0x0001, 'TentacleAuth', 'enroll parsed cookie len=%{public}d', cookieValue.length);
          if (cookieValue.length > 0) {
            if (cookieValue !== this.deviceCookie) { this.clearCaches(); }
            this.deviceCookie = cookieValue;
            this.saveConfig();
          }
          try {
            const parsed: EnrollResult = JSON.parse(text) as EnrollResult;
            resolve(parsed);
          } catch (e) {
            reject(new Error('invalid json'));
          }
          return;
        }
        try {
          const detail = JSON.parse(text) as ApiErrorDetail;
          const detailMsg = detail.detail || ('HTTP ' + codeNum.toString());
          hilog.warn(0x0001, 'TentacleAuth', 'enroll 403: %{public}s', detailMsg);
          reject(new Error(detailMsg + '：请在主机重新运行 gen-code（码仅 15 分钟有效，小写十六进制，注意 0/O、1/l、大小写）'));
        } catch (e) {
          reject(new Error('HTTP ' + codeNum.toString()));
        }
      });
    });
  }

  /**
   * 从 HttpResponse.cookies 中解析 tentacle_device 的值。实测该字段返回两种形态：
   * 1) Netscape cookie 文件行（tab 分隔，httponly 带 #HttpOnly_ 前缀）：
   *    "#HttpOnly_<domain>\tFALSE\t/\tTRUE\t<expiry>\ttentacle_device\t<value>"
   * 2) 原始 Set-Cookie： "tentacle_device=<value>; Path=/; HttpOnly; ..."
   * 兼容两种，属性（HttpOnly/Secure/SameSite）对原生客户端无意义，直接取 token。
   */
  private extractDeviceCookie(cookieHeader: string): string {
    if (cookieHeader.length === 0) {
      return '';
    }
    const tabParts = cookieHeader.split('\t');
    if (tabParts.length >= 2) {
      const nameIdx = tabParts.length - 2;
      if (tabParts[nameIdx] === DEVICE_COOKIE_NAME) {
        return tabParts[tabParts.length - 1].trim();
      }
    }
    const prefix = DEVICE_COOKIE_NAME + '=';
    const start = cookieHeader.indexOf(prefix);
    if (start < 0) {
      return '';
    }
    let value = cookieHeader.substring(start + prefix.length);
    const semi = value.indexOf(';');
    if (semi >= 0) {
      value = value.substring(0, semi);
    }
    return value.trim();
  }

  // ---------- 业务 REST ----------

  getSettings(): Promise<Settings> {
    return this.request<Settings>('/api/settings', http.RequestMethod.GET, '');
  }

  updateSettings(showReasoning: boolean, splitMessages: boolean): Promise<Settings> {
    const body = '{"show_reasoning":' + showReasoning.toString() + ',"split_messages":' +
      splitMessages.toString() + '}';
    return this.request<Settings>('/api/settings', http.RequestMethod.PUT, body);
  }

  getStatus(): Promise<StatusData> {
    return this.request<StatusData>('/api/status', http.RequestMethod.GET, '');
  }

  getUsage(granularity: string, windowN: number, providerId: string = '', modelId: string = '',
    role: string = ''): Promise<UsageResult> {
    const url = '/api/usage?granularity=' + encodeURIComponent(granularity) +
      '&window=' + windowN.toString() + (providerId ? '&provider_id=' + encodeURIComponent(providerId) : '') +
      (modelId ? '&model_id=' + encodeURIComponent(modelId) : '') + (role ? '&role=' + encodeURIComponent(role) : '');
    return this.request<UsageResult>(url, http.RequestMethod.GET, '');
  }

  getBalance(force: boolean, providerId: string = ''): Promise<BalanceResult> {
    return this.request<BalanceResult>('/api/balance?force=' + force.toString() +
      (providerId ? '&provider_id=' + encodeURIComponent(providerId) : ''),
      http.RequestMethod.GET, '');
  }

  getHistory(limit: number): Promise<HistoryResult> {
    return this.request<HistoryResult>('/api/chat/history?limit=' + limit.toString(), http.RequestMethod.GET, '');
  }

  /**
   * 图片内容字节抓取（设备门开启时 Image 组件直连 URL 不带 cookie，必然 401，
   * 故统一走本方法带 Cookie 头抓取，转 base64 data URI 供 Image 渲染）。
   * 结果按 local_id 缓存，避免重复编码。
   */
  async getImageDataUri(localId: string, mime: string): Promise<string> {
    const cached = this.imageCache.get(localId);
    if (cached !== undefined) {
      return cached;
    }
    const pending = this.imagePending.get(localId);
    if (pending !== undefined) { return pending; }
    const task = this.loadImageUri(localId, mime, this.cacheEpoch);
    this.imagePending.set(localId, task);
    try { return await task; }
    finally { if (this.imagePending.get(localId) === task) { this.imagePending.delete(localId); } }
  }

  private async loadImageUri(localId: string, mime: string, epoch: number): Promise<string> {
    const disk = this.localCache;
    const key = disk === null ? '' : 'image-' + await cacheHash(localId);
    if (epoch !== this.cacheEpoch) { throw new Error('连接已变化'); }
    if (disk !== null) {
      const saved = await disk.read(key, 7 * 86400000);
      if (epoch !== this.cacheEpoch) { throw new Error('连接已变化'); }
      if (saved !== null && saved.startsWith('data:image/')) {
        this.rememberImageUri(localId, saved); return saved;
      }
    }
    const bytes = await this.fetchImageBytes(localId);
    if (epoch !== this.cacheEpoch) { throw new Error('连接已变化'); }
    const b64Helper = new util.Base64Helper();
    const b64 = b64Helper.encodeToStringSync(new Uint8Array(bytes));
    const uri = 'data:' + (mime.length > 0 ? mime : 'image/jpeg') + ';base64,' + b64;
    this.rememberImageUri(localId, uri);
    if (disk !== null && uri.length <= 4 * 1024 * 1024) { disk.write(key, uri); }
    return uri;
  }

  private rememberImageUri(localId: string, uri: string): void {
    // Bound retained base64 strings to 16 Mi characters and 24 previews.
    if (uri.length <= 16 * 1024 * 1024) {
      this.imageCache.set(localId, uri);
      let size = 0;
      this.imageCache.forEach((value: string) => { size += value.length; });
      for (const key of this.imageCache.keys()) {
        if (size <= 16 * 1024 * 1024 && this.imageCache.size <= 24) { break; }
        size -= this.imageCache.get(key)!.length; this.imageCache.delete(key);
      }
    }
  }

  private fetchImageBytes(localId: string): Promise<ArrayBuffer> {
    return new Promise<ArrayBuffer>((resolve, reject) => {
      const req = http.createHttp();
      req.request(this.serverUrl + '/api/files/' + encodeURIComponent(localId) + '/content', {
        method: http.RequestMethod.GET,
        header: this.downloadHeaders(),
        usingCache: false,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 10000,
        readTimeout: 30000,
      }, (err: BusinessError, data: http.HttpResponse) => {
        req.destroy();
        if (err) {
          reject(new Error(err.message));
          return;
        }
        const code: number = data.responseCode;
        if (code === 401) {
          this.signalUnauthorized();
          reject(new UnauthorizedError());
          return;
        }
        if (code >= 200 && code < 300) {
          if (data.result instanceof ArrayBuffer) {
            resolve(data.result);
            return;
          }
          reject(new Error('invalid image response'));
          return;
        }
        reject(new Error('HTTP ' + code.toString()));
      });
    });
  }

  async uploadImage(data: ArrayBuffer, filename: string, mime: string): Promise<FileRecord> {
    const epoch = this.cacheEpoch;
    if (this.localCache !== null) { await this.restoreUploads(this.localCache, epoch); }
    if (epoch !== this.cacheEpoch) { throw new Error('连接已变化'); }
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: new Uint8Array(data) });
    const digest = await md.digest();
    const key = JSON.stringify([new util.Base64Helper().encodeToStringSync(digest.data), filename, mime]);
    if (epoch !== this.cacheEpoch) { throw new Error('连接已变化'); }
    const pending = this.uploadPending.get(key);
    if (pending !== undefined) { return pending; }
    const task = this.reuseOrUpload(key, data, filename, mime, epoch);
    this.uploadPending.set(key, task);
    try { return await task; }
    finally { if (this.uploadPending.get(key) === task) { this.uploadPending.delete(key); } }
  }

  private async reuseOrUpload(key: string, data: ArrayBuffer, filename: string, mime: string,
    epoch: number): Promise<FileRecord> {
    const cached = this.uploaded.get(key);
    if (cached !== undefined) {
      // Check that another client has not deleted it; transfer metadata only.
      const current = await this.getFiles();
      if (epoch !== this.cacheEpoch) { throw new Error('连接已变化'); }
      const existing = current.files.find((file: FileRecord) => file.local_id === cached.local_id);
      if (existing !== undefined) { return existing; }
    }
    const file = await this.uploadBytes(data, filename, mime);
    if (epoch !== this.cacheEpoch) { throw new Error('连接已变化'); }
    this.uploaded.delete(key);
    this.uploaded.set(key, file);
    for (const oldest of this.uploaded.keys()) {
      if (this.uploaded.size <= 64) { break; }
      this.uploaded.delete(oldest);
    }
    this.persistUploads();
    return file;
  }

  private uploadBytes(data: ArrayBuffer, filename: string, mime: string): Promise<FileRecord> {
    return new Promise<FileRecord>((resolve, reject) => {
      const req = http.createHttp();
      const pairs: string[][] = [['Content-Type', 'multipart/form-data']];
      if (this.token.length > 0) {
        pairs.push(['Authorization', 'Bearer ' + this.token]);
      }
      if (this.deviceCookie.length > 0) {
        pairs.push(['Cookie', DEVICE_COOKIE_NAME + '=' + this.deviceCookie]);
      }
      const formItem: http.MultiFormData = {
        name: 'file',
        contentType: mime,
        data: data,
        remoteFileName: filename,
      };
      const opts: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: this.buildHeaderRaw(pairs),
        multiFormDataList: [formItem],
        connectTimeout: 10000,
        readTimeout: 60000,
      };
      req.request(this.serverUrl + '/api/files/upload', opts,
        (err: BusinessError, resp: http.HttpResponse) => {
          req.destroy();
          if (err) {
            reject(new Error(err.message));
            return;
          }
          const code: number = resp.responseCode;
          const text: string = String(resp.result);
          if (code === 401) {
            this.notifyWs({ type: 'unauthorized', data: {} });
            reject(new UnauthorizedError());
            return;
          }
          if (code >= 200 && code < 300) {
            try {
              const parsed: UploadResult = JSON.parse(text) as UploadResult;
              resolve(parsed.file);
            } catch (e) {
              reject(new Error('invalid json'));
            }
            return;
          }
          try {
            const detail = JSON.parse(text) as ApiErrorDetail;
            reject(new Error(detail.detail || ('HTTP ' + code.toString())));
          } catch (e) {
            reject(new Error('HTTP ' + code.toString()));
          }
        });
    });
  }

  setPhoneIdentity(id: string, secret: string): void { this.phoneDeviceId = id; this.phoneDeviceSecret = secret; }

  onPhoneReset(callback: () => void): void { this.phoneResetListener = callback; }

  private resetPhoneSession(): void {
    this.chatRecovery.reset(true);
    if (this.phoneDeviceId) { this.unregisterPhone().catch(() => {}); }
    this.setPhoneIdentity('', '');
    if (this.phoneResetListener !== null) { this.phoneResetListener(); }
  }

  registerPhone(body: PhoneRegistration): Promise<PhoneRegistrationResult> {
    return this.request<PhoneRegistrationResult>('/api/plugins/ext/harmony/register', http.RequestMethod.POST,
      JSON.stringify(body));
  }

  getChatSync(limit: number = 50): Promise<ChatSnapshot> {
    return this.request<ChatSnapshot>('/api/chat/sync?limit=' + limit.toString(), http.RequestMethod.GET, '');
  }

  synchronizeChat(): Promise<void> { return this.chatRecovery.synchronize(); }
  chatSyncEnabled(): boolean { return this.chatRecovery.enabled(); }
  setChatSyncLimit(limit: number): void { this.chatRecovery.setLimit(limit); }

  resumeChat(): void {
    if (!this.serverUrl || this.manualClose) { return; }
    this.chatRecovery.disconnected(); this.synchronizeChat();
    if (!this.wsConnected) { this.connectWs(); }
  }

  stopChat(target: ChatStopTarget): Promise<ChatStopResult> {
    return this.request<ChatStopResult>('/api/chat/stop', http.RequestMethod.POST, JSON.stringify(target));
  }

  unregisterPhone(): Promise<object> {
    return this.request<object>('/api/plugins/ext/harmony/register', http.RequestMethod.DELETE, '');
  }

  phoneState(): Promise<PhoneState> {
    return this.request<PhoneState>('/api/plugins/ext/harmony/state', http.RequestMethod.GET, '');
  }

  phoneReceipt(id: string, status: string, result: string): Promise<object> {
    return this.request<object>('/api/plugins/ext/harmony/actions/' + encodeURIComponent(id) + '/receipt',
      http.RequestMethod.POST, JSON.stringify({ status: status, result: result }));
  }

  sendChat(text: string, images: string[], requestId: string, live?: PhoneLiveMeta): Promise<SendResult> {
    let body = '{"text":' + JSON.stringify(text) + ',"platform":' + JSON.stringify(this.appPlatform) +
      ',"request_id":' + JSON.stringify(requestId);
    if (live !== undefined) { body += ',"client_meta":{"live_view":' + JSON.stringify(live) + '}'; }
    if (images.length > 0) {
      body = body + ',"files":[';
      for (let i = 0; i < images.length; i++) {
        if (i > 0) {
          body = body + ',';
        }
        body = body + JSON.stringify(images[i]);
      }
      body = body + ']';
    }
    body = body + '}';
    // 后端同步等待整轮 agent 回合完成（含工具链/锁排队），读超时须长于最长回合
    return this.request<SendResult>('/api/chat/send', http.RequestMethod.POST, body, 300000);
  }

  getChatCommands(): Promise<CommandCatalog> {
    return this.request<CommandCatalog>('/api/chat/commands', http.RequestMethod.GET, '');
  }

  getTerminalHistory(since: number): Promise<TerminalHistoryResult> {
    const url = '/api/terminal/history?since=' + since.toString();
    return this.request<TerminalHistoryResult>(url, http.RequestMethod.GET, '');
  }

  getNeo4jSummary(): Promise<Neo4jSummaryResult> {
    return this.request<Neo4jSummaryResult>('/api/neo4j/summary', http.RequestMethod.GET, '');
  }

  getNeo4jGraph(labels: string = ''): Promise<Neo4jGraphResult> {
    let url = '/api/neo4j/graph';
    if (labels.length > 0) {
      url = url + '?labels=' + encodeURIComponent(labels);
    }
    return this.request<Neo4jGraphResult>(url, http.RequestMethod.GET, '');
  }

  setPassword(password: string): Promise<SetPasswordResult> {
    const body = '{"password":' + JSON.stringify(password) + '}';
    return this.request<SetPasswordResult>('/api/auth/set_password', http.RequestMethod.POST, body);
  }

  getConfiguration(): Promise<ConfigSnapshot> {
    return this.request<ConfigSnapshot>('/api/configuration', http.RequestMethod.GET, '');
  }

  previewConfiguration(revision: string, changes: Record<string, ConfigValue>): Promise<ConfigPreview> {
    return this.request<ConfigPreview>('/api/configuration/preview', http.RequestMethod.POST,
      JSON.stringify({ revision: revision, changes: changes }));
  }

  saveConfiguration(revision: string, changes: Record<string, ConfigValue>): Promise<ConfigPreview> {
    return this.request<ConfigPreview>('/api/configuration', http.RequestMethod.PUT,
      JSON.stringify({ revision: revision, changes: changes }));
  }

  structureConfiguration(revision: string, operations: StructureOperation[], apply: boolean): Promise<ConfigPreview> {
    return this.request<ConfigPreview>('/api/configuration/structure', http.RequestMethod.POST,
      JSON.stringify({ revision: revision, operations: operations, apply: apply }));
  }

  restoreConfiguration(revision: string, backup: string, apply: boolean): Promise<ConfigPreview> {
    return this.request<ConfigPreview>('/api/configuration/restore', http.RequestMethod.POST,
      JSON.stringify({ revision: revision, backup: backup, apply: apply }));
  }

  discoverModels(revision: string, provider: string): Promise<ModelCatalog> {
    return this.request<ModelCatalog>('/api/configuration/discover-models', http.RequestMethod.POST,
      JSON.stringify({ revision: revision, provider: provider }));
  }

  applyConfiguration(): Promise<ConfigSnapshot> {
    return this.request<ConfigSnapshot>('/api/configuration/apply', http.RequestMethod.POST, '');
  }

  restartApplication(revision: string, reembed: boolean = false): Promise<RestartState> {
    return this.request<RestartState>('/api/configuration/restart', http.RequestMethod.POST,
      JSON.stringify({ revision: revision, reembed: reembed }));
  }

  getMaintenance(operationId: string = ''): Promise<MaintenanceStatus> {
    const query = operationId ? '?operation_id=' + encodeURIComponent(operationId) : '';
    return this.request<MaintenanceStatus>('/api/maintenance' + query, http.RequestMethod.GET, '');
  }

  postMaintenance(action: string, version: string = '', revision: string = ''): Promise<MaintenanceOperation> {
    const pairs: Array<Array<string>> = [['action', JSON.stringify(action)]];
    if (version.length > 0) {
      pairs.push(['version', JSON.stringify(version)]);
    }
    if (revision.length > 0) {
      pairs.push(['revision', JSON.stringify(revision)]);
    }
    return this.request<MaintenanceOperation>('/api/maintenance', http.RequestMethod.POST, this.jsonObj(pairs));
  }

  saveConfigurationEnvironment(path: string, value: string, revision: string): Promise<ConfigEnvResult> {
    return this.request<ConfigEnvResult>('/api/configuration/environment', http.RequestMethod.POST,
      JSON.stringify({ path: path, value: value, revision: revision }));
  }

  getPlugins(): Promise<PluginsSnapshot> {
    return this.request<PluginsSnapshot>('/api/plugins', http.RequestMethod.GET, '');
  }

  decideLocalPlugin(id: string, body: PluginDecisionPayload): Promise<PluginsSnapshot> {
    return this.request<PluginsSnapshot>('/api/plugins/local/' + encodeURIComponent(id) + '/decision',
      http.RequestMethod.POST, JSON.stringify(body));
  }

  deleteLocalPlugin(id: string, revision: string, deleteFiles: boolean = true): Promise<PluginsSnapshot> {
    return this.request<PluginsSnapshot>('/api/plugins/local/' + encodeURIComponent(id) +
      '?revision=' + encodeURIComponent(revision) + '&delete_files=' + (deleteFiles ? 'true' : 'false'),
      http.RequestMethod.DELETE, '');
  }

  upsertMcpServer(id: string, revision: string, config: McpServerConfig): Promise<PluginsSnapshot> {
    return this.request<PluginsSnapshot>('/api/plugins/mcp/' + encodeURIComponent(id), http.RequestMethod.POST,
      JSON.stringify({ revision: revision, config: config }));
  }

  deleteMcpServer(id: string, revision: string): Promise<PluginsSnapshot> {
    return this.request<PluginsSnapshot>('/api/plugins/mcp/' + encodeURIComponent(id) +
      '?revision=' + encodeURIComponent(revision), http.RequestMethod.DELETE, '');
  }

  reconnectMcpServer(id: string): Promise<PluginsSnapshot> {
    return this.request<PluginsSnapshot>('/api/plugins/mcp/' + encodeURIComponent(id) + '/reconnect',
      http.RequestMethod.POST, '');
  }

  writePluginEnv(name: string, value: string): Promise<PluginEnvWriteResult> {
    return this.request<PluginEnvWriteResult>('/api/plugins/env', http.RequestMethod.POST,
      JSON.stringify({ name: name, value: value }));
  }

  restartAfterPluginChange(revision: string): Promise<RestartState> {
    return this.request<RestartState>('/api/plugins/restart', http.RequestMethod.POST,
      JSON.stringify({ revision: revision }));
  }

  getDevices(): Promise<DeviceInfo> {
    return this.request<DeviceInfo>('/api/auth/devices', http.RequestMethod.GET, '');
  }

  async setDeviceAuth(enabled: boolean, code: string): Promise<object> {
    // 开启设备门前先绑定，复用可正确持久化 Set-Cookie 的 enroll 流程。
    const info = await this.getDevices();
    if (enabled && !info.device_bound) { await this.enroll(code.trim(), 'HarmonyOS'); }
    return this.request<object>('/api/auth/device_auth', http.RequestMethod.PUT,
      JSON.stringify({ enabled: enabled }));
  }

  revokeDevice(id: string): Promise<object> {
    return this.request<object>('/api/auth/devices/' + encodeURIComponent(id), http.RequestMethod.DELETE, '');
  }

  setNewDevices(enabled: boolean): Promise<object> {
    return this.request<object>('/api/auth/new_devices', http.RequestMethod.PUT,
      JSON.stringify({ enabled: enabled }));
  }

  getBackups(path: string): Promise<SelfBackupsResult> {
    return this.request<SelfBackupsResult>('/api/admin/backups' + (path ? '?path=' + encodeURIComponent(path) : ''),
      http.RequestMethod.GET, '');
  }

  restoreBackup(path: string, timestamp: string): Promise<object> {
    return this.request<object>('/api/admin/backups/restore', http.RequestMethod.POST,
      JSON.stringify({ path: path, timestamp: timestamp }));
  }

  getFiles(): Promise<FilesResult> {
    return this.request<FilesResult>('/api/files', http.RequestMethod.GET, '');
  }

  async deleteFile(id: string): Promise<object> {
    const result = await this.request<object>('/api/files/' + encodeURIComponent(id), http.RequestMethod.DELETE, '');
    this.imageCache.delete(id);
    this.uploaded.clear();
    this.uploadDiskLoaded = true;
    if (this.localCache !== null) {
      await this.localCache.remove('image-' + await cacheHash(id));
      this.persistUploads();
    }
    return result;
  }

  getSubagents(): Promise<SubagentList> {
    return this.request<SubagentList>('/api/subagents', http.RequestMethod.GET, '', 10000);
  }

  getSubagent(id: string, before: number | null = null): Promise<SubagentDetail> {
    return this.request<SubagentDetail>('/api/subagents/' + encodeURIComponent(id) +
      (before === null ? '' : '?before=' + before.toString()), http.RequestMethod.GET, '', 10000);
  }

  getDedup(state: string, offset: number): Promise<DedupStatus> {
    return this.request<DedupStatus>('/api/memory/dedup?state=' + encodeURIComponent(state) + '&offset=' + offset,
      http.RequestMethod.GET, '');
  }

  getDedupAudit(actor: string = 'all', offset: number = 0): Promise<DedupAuditResult> {
    return this.request<DedupAuditResult>('/api/memory/dedup/audit?actor=' + encodeURIComponent(actor) + '&offset=' + offset,
      http.RequestMethod.GET, '');
  }

  startDedup(topK: number, maxPairs: number): Promise<object> {
    return this.request<object>('/api/memory/dedup/start', http.RequestMethod.POST,
      JSON.stringify({ top_k: topK, max_pairs: maxPairs }));
  }

  cancelDedup(): Promise<object> {
    return this.request<object>('/api/memory/dedup/cancel', http.RequestMethod.POST, '');
  }

  decideDedup(id: string, action: string, keepId: string, policy: string): Promise<object> {
    return this.request<object>('/api/memory/dedup/' + encodeURIComponent(id) +
      (action === 'refresh' ? '/refresh' : action === 'reevaluate' ? '/reevaluate' : '/decide'),
      http.RequestMethod.POST,
      action === 'refresh' || action === 'reevaluate' ? '' :
        JSON.stringify({ action: action, keep_id: keepId, policy: policy }));
  }

  downloadHeaders(): Record<string, string> {
    const headers: Record<string, string> = {};
    if (this.token) { headers['Authorization'] = 'Bearer ' + this.token; }
    if (this.deviceCookie) { headers['Cookie'] = DEVICE_COOKIE_NAME + '=' + this.deviceCookie; }
    return headers;
  }

  signalUnauthorized(): void { this.notifyWs({ type: 'unauthorized', data: {} }); }

  // ---------- 记忆库管理 ----------

  private normalizeTable(raw: TableData): TableData {
    const t = new TableData();
    t.columns = raw.columns;
    t.total = raw.total;
    t.truncated = raw.truncated;
    t.row_count = raw.row_count;
    const rows: Array<Array<string>> = [];
    for (let r = 0; r < raw.rows.length; r++) {
      const rowIn: Array<string> = raw.rows[r];
      const rowOut: string[] = [];
      for (let c = 0; c < rowIn.length; c++) {
        rowOut.push(String(rowIn[c]));
      }
      rows.push(rowOut);
    }
    t.rows = rows;
    return t;
  }

  async getAdminMessages(offset: number, limit: number, role: string, platform: string,
    sessionId: string, q: string): Promise<TableData> {
    let url = '/api/admin/messages?offset=' + offset.toString() + '&limit=' + limit.toString();
    if (role.length > 0) {
      url = url + '&role=' + encodeURIComponent(role);
    }
    if (platform.length > 0) {
      url = url + '&platform=' + encodeURIComponent(platform);
    }
    if (sessionId.length > 0) {
      url = url + '&session_id=' + encodeURIComponent(sessionId);
    }
    if (q.length > 0) {
      url = url + '&q=' + encodeURIComponent(q);
    }
    const raw = await this.request<TableData>(url, http.RequestMethod.GET, '');
    return this.normalizeTable(raw);
  }

  async deleteMessage(id: number): Promise<object> {
    return this.request<object>('/api/admin/messages/' + id.toString(), http.RequestMethod.DELETE, '');
  }

  async getAdminSessions(offset: number, limit: number): Promise<TableData> {
    const url = '/api/admin/sessions?offset=' + offset.toString() + '&limit=' + limit.toString();
    const raw = await this.request<TableData>(url, http.RequestMethod.GET, '');
    return this.normalizeTable(raw);
  }

  async getAdminSummaries(offset: number, limit: number): Promise<TableData> {
    const url = '/api/admin/summaries?offset=' + offset.toString() + '&limit=' + limit.toString();
    const raw = await this.request<TableData>(url, http.RequestMethod.GET, '');
    return this.normalizeTable(raw);
  }

  async deleteSummary(id: number): Promise<object> {
    return this.request<object>('/api/admin/summaries/' + id.toString(), http.RequestMethod.DELETE, '');
  }

  async getAdminGoals(): Promise<TableData> {
    const raw = await this.request<TableData>('/api/admin/goals', http.RequestMethod.GET, '');
    return this.normalizeTable(raw);
  }

  async createGoal(description: string, priority: string): Promise<object> {
    const body = this.jsonObj([
      ['description', JSON.stringify(description)],
      ['priority', JSON.stringify(priority)],
    ]);
    return this.request<object>('/api/admin/goals', http.RequestMethod.POST, body);
  }

  async updateGoal(id: number, description: string | null, priority: string | null,
    result: string | null, status: string | null): Promise<object> {
    const pairs: Array<Array<string>> = [];
    if (description !== null) {
      pairs.push(['description', JSON.stringify(description)]);
    }
    if (priority !== null) {
      pairs.push(['priority', JSON.stringify(priority)]);
    }
    if (result !== null) {
      pairs.push(['result', JSON.stringify(result)]);
    }
    if (status !== null) {
      pairs.push(['status', JSON.stringify(status)]);
    }
    return this.request<object>('/api/admin/goals/' + id.toString(), http.RequestMethod.PUT, this.jsonObj(pairs));
  }

  async archiveGoal(id: number): Promise<object> {
    return this.request<object>('/api/admin/goals/' + id.toString(), http.RequestMethod.DELETE, '');
  }

  async getAdminTasks(): Promise<TableData> {
    const raw = await this.request<TableData>('/api/admin/tasks', http.RequestMethod.GET, '');
    return this.normalizeTable(raw);
  }

  async createTask(goalId: number, content: string, urgency: string): Promise<object> {
    const body = '{"goal_id":' + goalId.toString() + ',"content":' + JSON.stringify(content) +
      ',"urgency":' + JSON.stringify(urgency) + '}';
    return this.request<object>('/api/admin/tasks', http.RequestMethod.POST, body);
  }

  async updateTask(id: number, content: string | null, urgency: string | null,
    status: string | null, goalId: number | null): Promise<object> {
    const pairs: Array<Array<string>> = [];
    if (content !== null) {
      pairs.push(['content', JSON.stringify(content)]);
    }
    if (urgency !== null) {
      pairs.push(['urgency', JSON.stringify(urgency)]);
    }
    if (status !== null) {
      pairs.push(['status', JSON.stringify(status)]);
    }
    if (goalId !== null) {
      pairs.push(['goal_id', goalId.toString()]);
    }
    return this.request<object>('/api/admin/tasks/' + id.toString(), http.RequestMethod.PUT, this.jsonObj(pairs));
  }

  async deleteTask(id: number): Promise<object> {
    return this.request<object>('/api/admin/tasks/' + id.toString(), http.RequestMethod.DELETE, '');
  }

  async runSql(sql: string): Promise<TableData> {
    const body = '{"sql":' + JSON.stringify(sql) + '}';
    const raw = await this.request<TableData>('/api/admin/query', http.RequestMethod.POST, body);
    return this.normalizeTable(raw);
  }

  // ---------- WebSocket ----------

  onWsEvent(cb: (evt: WsEvent) => void): void {
    this.listeners.push(cb);
  }

  offWsEvent(cb: (evt: WsEvent) => void): void {
    const out: Array<(evt: WsEvent) => void> = [];
    for (let i = 0; i < this.listeners.length; i++) {
      if (this.listeners[i] !== cb) {
        out.push(this.listeners[i]);
      }
    }
    this.listeners = out;
  }

  onConn(cb: (online: boolean) => void): void {
    this.connListeners.push(cb);
  }

  offConn(cb: (online: boolean) => void): void {
    this.connListeners = this.connListeners.filter((c: (online: boolean) => void) => c !== cb);
  }

  private notifyWs(evt: WsEvent): void {
    this.chatRecovery.receive(evt);
  }

  private dispatchWs(evt: WsEvent): void {
    if (evt.type === 'unauthorized') { this.chatRecovery.reset(true); this.clearCaches(); }
    if (evt.type === 'round_finished') { this.invalidateGraph(); }
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i](evt);
    }
  }

  private notifyConn(online: boolean): void {
    for (let i = 0; i < this.connListeners.length; i++) {
      this.connListeners[i](online);
    }
  }

  connectWs(): void {
    if (this.wsConnected) {
      return;
    }
    this.manualClose = false;
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
    if (this.ws !== null) {
      this.ws.close();
      this.ws = null;
    }
    const ws = webSocket.createWebSocket();
    this.ws = ws;
    const url = this.wsUrl();
    ws.on('open', (err: BusinessError) => {
      if (this.ws !== ws || err) {
        return;
      }
      this.wsConnected = true;
      this.chatRecovery.setOnline(true);
      this.synchronizeChat();
      this.notifyConn(true);
    });

    ws.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
      if (this.ws !== ws || err) {
        return;
      }
      if (typeof value !== 'string') {
        return;
      }
      try {
        const evt = JSON.parse(value) as WsEvent;
        this.notifyWs(evt);
      } catch (e) {
        // 忽略解析失败
      }
    });

    ws.on('close', (err: BusinessError, value: webSocket.CloseResult) => {
      if (this.ws !== ws) { return; }
      this.wsConnected = false;
      this.chatRecovery.setOnline(false);
      this.chatRecovery.disconnected();
      this.notifyConn(false);
      if (!this.manualClose && value && value.code === 4401) {
        // token 失效：提示重新登录（由上层处理），不自动重连
        this.notifyWs({ type: 'unauthorized', data: {} });
        return;
      }
      if (!this.manualClose) {
        this.scheduleReconnect();
        this.synchronizeChat();
      }
    });

    ws.on('error', (err: BusinessError) => {
      // 错误事件后通常伴随 close，交给 close 处理重连
    });

    // 设备门开启时 WS 握手也要求 cookie（服务端 close 4401 才放行）
    if (this.deviceCookie.length > 0) {
      const wsOpt: webSocket.WebSocketRequestOptions = {
        header: this.buildHeaderRaw([['Cookie', DEVICE_COOKIE_NAME + '=' + this.deviceCookie]])
      };
      ws.connect(url, wsOpt).catch((e: BusinessError) => {
        if (this.ws !== ws) { return; }
        this.wsConnected = false;
        this.notifyConn(false);
        if (!this.manualClose) {
          this.scheduleReconnect();
          this.chatRecovery.setOnline(false);
          this.synchronizeChat();
        }
      });
      return;
    }
    ws.connect(url).catch((e: BusinessError) => {
      if (this.ws !== ws) { return; }
      this.wsConnected = false;
      this.notifyConn(false);
      if (!this.manualClose) {
        this.scheduleReconnect();
        this.chatRecovery.setOnline(false);
        this.synchronizeChat();
      }
    });
  }

  private scheduleReconnect(): void {
    if (this.manualClose) {
      return;
    }
    if (this.reconnectTimer >= 0) {
      return;
    }
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      this.connectWs();
    }, 3000);
  }

  disconnectWs(): void {
    this.manualClose = true;
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
    if (this.ws !== null) {
      this.ws.close();
      this.ws = null;
    }
    this.wsConnected = false;
  }

  logout(): void {
    this.resetPhoneSession();
    this.clearCaches();
    this.disconnectWs();
    this.token = '';
    this.saveConfig();
  }
}
