/**
 * DSH 编码台网关客户端（单例，走 Tentacle /api/subagents/dsh/access + /coding/api/* + /coding/api/remote.mux）
 *
 * 协议与 ArkTS 宿主实测适配：
 * - HTTP POST JSON：对纯 ASCII 载荷显式声明 Content-Length，避开 libwebsockets 空体 400
 * - 鉴权恢复：收到 401/403 时清理并重取 tentacle_coding Cookie，自动重试一次
 * - WebSocket Mux：显式带上 Cookie 与设备门头，不手动注入 origin 头（避免 ArkTS 逗号双 Origin 触发 _same_origin 拒绝）
 * - Socket 判死纪律：忽略无伴随 close 的伪错误码（如 code=200），仅以 close 事件与连续探活超时判死
 */

import { http, webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TentacleApi } from '../service/TentacleApi';
import {
  DshCommandCandidate,
  DshDirectoryListing,
  DshLiveAttempt,
  DshModelCatalogResult,
  DshModelOption,
  DshModelSelection,
  DshPendingAttachment,
  DshPendingPrompt,
  DshPinnedSessionEntry,
  DshProjectedSession,
  DshQueuedItem,
  DshRawRecord,
  DshReferenceCandidate,
  DshSession,
  DshSessionSearchResult,
  DshUploadedFile,
  DshWorkspace,
  DshWorkspaceGroup,
  JsonBag,
  applyAssistantStreamFrame,
  buildArchivedSessions,
  buildPinnedSessionEntries,
  buildRpcPacket,
  createEmptyLiveAttempt,
  groupSessionsByWorkspace,
  isAsciiText,
  isPlainObject,
  jsonArr,
  jsonBool,
  jsonField,
  jsonNum,
  jsonRec,
  jsonStr,
  jsonStrArr,
  parseCommandsList,
  parseDirectoryListing,
  parseFileUploadReceipt,
  parseJsonSafe,
  parseModelCatalog,
  parseModelSelection,
  parseQueuedItems,
  parseReferenceCandidates,
  parseRpcResponse,
  parseSessionList,
  parseSessionSearchResult,
  parseSessionSummary,
  parseWaterfallPrompt,
  parseWorkspaceBaseline,
  parseWorkspaceView,
  projectSessionRecords
} from './DshModels';

const LOG_DOMAIN = 0x0001;
const LOG_TAG = 'TentacleDSH';

function randomUuid(): string {
  const hex = '0123456789abcdef';
  let out = '';
  for (let i = 0; i < 32; i++) {
    out += hex.charAt(Math.floor(Math.random() * 16));
  }
  return out.substring(0, 8) + '-' + out.substring(8, 12) + '-4' + out.substring(13, 16)
    + '-a' + out.substring(17, 20) + '-' + out.substring(20);
}

interface MuxStreamSink {
  onItem: (value: Object) => void;
  onError: (code: string, message: string) => void;
  onEnd: () => void;
}

class DshMuxTransport {
  private socket: webSocket.WebSocket | null = null;
  private state: string = 'closed'; // 'closed' | 'connecting' | 'open'
  private streams: Map<string, MuxStreamSink> = new Map<string, MuxStreamSink>();
  private openWaiters: Array<(ok: boolean) => void> = [];
  private probeTimer: number = -1;
  private probeTimeoutTimer: number = -1;
  private probeFailCount: number = 0;
  private onDead: () => void = () => {};

  setOnDead(cb: () => void): void {
    this.onDead = cb;
  }

  isOpen(): boolean {
    return this.state === 'open';
  }

  private lastConnectError: string = '';

  getLastConnectError(): string {
    return this.lastConnectError;
  }

  async connect(wsUrl: string, headers: object): Promise<boolean> {
    this.lastConnectError = '';
    if (this.state === 'open') {
      return true;
    }
    if (this.state === 'connecting') {
      return await new Promise<boolean>((resolve) => {
        const timer = setTimeout(() => resolve(false), 12000);
        this.openWaiters.push((ok: boolean) => {
          clearTimeout(timer);
          resolve(ok);
        });
      });
    }

    const sock = webSocket.createWebSocket();
    this.socket = sock;
    this.state = 'connecting';

    sock.on('message', (err: BusinessError, data: string | ArrayBuffer) => {
      if (this.socket !== sock || (err && err.code !== 0)) {
        return;
      }
      this.settleProbe();
      if (typeof data === 'string') {
        this.handleFrame(data as string);
      }
    });

    sock.on('close', (_err: BusinessError, _res: webSocket.CloseResult) => {
      if (this.socket !== sock) {
        return;
      }
      this.teardown('closed');
    });

    sock.on('error', (err: BusinessError) => {
      // ArkTS 实测在健康连接上也会抛 code=200 message=undefined 且不伴随 close；仅记录不关流
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'mux error code=%{public}d msg=%{public}s',
        err ? err.code : -1, err ? (err.message ?? '') : '');
    });

    try {
      const hasHeaders = Object.keys(headers as Record<string, Object>).length > 0;
      const ok: boolean = hasHeaders
        ? await sock.connect(wsUrl, { header: headers })
        : await sock.connect(wsUrl);
      if (!ok || this.socket !== sock) {
        this.lastConnectError = '[DSH WS] connect 返回 false';
        this.teardown('connect_false');
        return false;
      }
      this.state = 'open';
      this.probeFailCount = 0;
      this.flushOpenWaiters(true);
      this.startProbe();
      return true;
    } catch (e) {
      const bErr = e as BusinessError;
      this.lastConnectError = '[DSH WS code=' + (bErr.code ?? 0).toString() + '] ' + (bErr.message ?? String(e));
      this.teardown('connect_throw');
      return false;
    }
  }

  openStream(endpoint: string, args: Object, sink: MuxStreamSink): string {
    if (this.state !== 'open' || this.socket === null) {
      return '';
    }
    const streamId = randomUuid();
    this.streams.set(streamId, sink);
    const payload: JsonBag = { 'args': args };
    const frame: JsonBag = {
      'type': 'open',
      'streamId': streamId,
      'endpoint': endpoint,
      'payload': payload
    };
    const raw = JSON.stringify(frame);
    this.socket.send(raw).catch((err: BusinessError) => {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'mux open send fail stream=%{public}s code=%{public}d',
        endpoint, err ? err.code : -1);
      const s = this.streams.get(streamId);
      if (s !== undefined) {
        this.streams.delete(streamId);
        s.onError('carrier/send', err ? err.message : 'send failed');
      }
    });
    return streamId;
  }

  cancelStream(streamId: string): void {
    if (streamId.length === 0) {
      return;
    }
    this.streams.delete(streamId);
    if (this.state === 'open' && this.socket !== null) {
      const frame: JsonBag = { 'type': 'cancel', 'streamId': streamId };
      this.socket.send(JSON.stringify(frame)).catch(() => {});
    }
  }

  close(): void {
    const sock = this.socket;
    this.socket = null;
    this.state = 'closed';
    this.stopProbe();
    this.streams.clear();
    this.flushOpenWaiters(false);
    if (sock !== null) {
      sock.close().catch(() => {});
    }
  }

  private flushOpenWaiters(ok: boolean): void {
    const list = this.openWaiters;
    this.openWaiters = [];
    for (let i = 0; i < list.length; i++) {
      list[i](ok);
    }
  }

  private teardown(_reason: string): void {
    if (this.state === 'closed' && this.socket === null) {
      return;
    }
    const sock = this.socket;
    this.socket = null;
    this.state = 'closed';
    this.stopProbe();
    this.flushOpenWaiters(false);
    const oldStreams: MuxStreamSink[] = [];
    this.streams.forEach((sink: MuxStreamSink) => oldStreams.push(sink));
    this.streams.clear();
    if (sock !== null) {
      sock.close().catch(() => {});
    }
    for (let i = 0; i < oldStreams.length; i++) {
      oldStreams[i].onError('carrier/closed', 'WebSocket 已断开');
    }
    this.onDead();
  }

  private handleFrame(text: string): void {
    const parsed = parseJsonSafe(text);
    if (parsed === undefined || !isPlainObject(parsed)) {
      return;
    }
    const streamId = jsonStr(parsed, 'streamId');
    if (streamId.length === 0) {
      return;
    }
    const sink = this.streams.get(streamId);
    if (sink === undefined) {
      return;
    }
    const ftype = jsonStr(parsed, 'type');
    if (ftype === 'item') {
      const val = jsonField(parsed, 'value');
      if (val !== undefined) {
        sink.onItem(val);
      }
      return;
    }
    if (ftype === 'error') {
      this.streams.delete(streamId);
      const errObj = jsonRec(parsed, 'error');
      const code = errObj !== undefined ? jsonStr(errObj, 'code', 'stream/error') : 'stream/error';
      const msg = errObj !== undefined ? jsonStr(errObj, 'message', '流错误') : '流错误';
      sink.onError(code, msg);
      return;
    }
    if (ftype === 'end') {
      this.streams.delete(streamId);
      sink.onEnd();
    }
  }

  private startProbe(): void {
    this.stopProbe();
    this.probeTimer = setInterval(() => {
      if (this.state !== 'open' || this.socket === null || this.probeTimeoutTimer >= 0) {
        return;
      }
      const sock = this.socket;
      const pid = 'probe-' + randomUuid();
      const payload: JsonBag = { 'args': {} as JsonBag };
      const frame: JsonBag = {
        'type': 'open',
        'streamId': pid,
        'endpoint': 'settings/describe',
        'payload': payload
      };
      this.probeTimeoutTimer = setTimeout(() => {
        this.probeTimeoutTimer = -1;
        this.probeFailCount += 1;
        if (this.probeFailCount >= 3) {
          this.teardown('probe_timeout');
        }
      }, 15000);
      sock.send(JSON.stringify(frame)).catch(() => {
        if (this.probeTimeoutTimer >= 0) {
          clearTimeout(this.probeTimeoutTimer);
          this.probeTimeoutTimer = -1;
        }
        this.probeFailCount += 1;
        if (this.probeFailCount >= 3) {
          this.teardown('probe_send_fail');
        }
      });
    }, 8000);
  }

  private settleProbe(): void {
    this.probeFailCount = 0;
    if (this.probeTimeoutTimer >= 0) {
      clearTimeout(this.probeTimeoutTimer);
      this.probeTimeoutTimer = -1;
    }
  }

  private stopProbe(): void {
    if (this.probeTimer >= 0) {
      clearInterval(this.probeTimer);
      this.probeTimer = -1;
    }
    if (this.probeTimeoutTimer >= 0) {
      clearTimeout(this.probeTimeoutTimer);
      this.probeTimeoutTimer = -1;
    }
  }
}

export interface DshQuestionAnswerPayload {
  id: string;
  selected: string[];
  custom?: string;
}

export interface DshCommandExecResult {
  commandId: string;
  matched: boolean;
  kind: string;
  text: string;
}

export class DshClient {
  private static instance: DshClient | null = null;

  static getInstance(): DshClient {
    if (DshClient.instance === null) {
      DshClient.instance = new DshClient();
    }
    return DshClient.instance;
  }

  // 共享连接与列表状态
  ready: boolean = false;
  connecting: boolean = false;
  muxConnected: boolean = false;
  lastError: string = '';
  sessions: DshSession[] = [];
  workspaces: DshWorkspace[] = [];
  archivedSessionIds: string[] = [];
  pinnedSessionIds: string[] = [];
  modelCatalog: DshModelCatalogResult = { groups: [], flatModels: [] };

  // 当前打开的会话状态
  activeSessionId: string = '';
  activeSessionLoading: boolean = false;
  activeSessionRunning: boolean = false;
  activeHasMore: boolean = false;
  activeCommands: DshCommandCandidate[] = [];
  commandsLoadState: string = 'idle'; // 'idle' | 'loading' | 'loaded' | 'error'
  commandsError: string = '';
  activeReferences: DshReferenceCandidate[] = [];
  activeQueued: DshQueuedItem[] = [];
  pendingPrompts: DshPendingPrompt[] = [];
  projected: DshProjectedSession = projectSessionRecords([]);

  private rawRecords: DshRawRecord[] = [];
  private activeProjections: Object | undefined = undefined;
  private liveAttempt: DshLiveAttempt = createEmptyLiveAttempt();
  private activeTokenEpoch: number = -1;

  private mux: DshMuxTransport = new DshMuxTransport();
  private eventsStreamId: string = '';
  private eventsClientId: string = '';
  private workspaceStreamId: string = '';
  private controlStreamId: string = '';
  private followStreamId: string = '';

  private authPending: Promise<void> | null = null;
  private reconnectTimer: number = -1;
  private reconnectAttempt: number = 0;
  private refreshListTimer: number = -1;
  private projectThrottleTimer: number = -1;
  private listeners: Array<() => void> = [];
  private wantConnected: boolean = false;

  private constructor() {
    this.mux.setOnDead(() => {
      this.muxConnected = false;
      this.eventsStreamId = '';
      this.eventsClientId = '';
      this.workspaceStreamId = '';
      this.controlStreamId = '';
      this.followStreamId = '';
      this.notify();
      if (this.wantConnected) {
        this.scheduleReconnect();
      }
    });
  }

  subscribe(listener: () => void): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unsubscribe(listener: () => void): void {
    this.listeners = this.listeners.filter((item: () => void) => item !== listener);
  }

  private notify(): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i]();
    }
  }

  getWorkspaceGroups(excludePinned: boolean = false): DshWorkspaceGroup[] {
    return groupSessionsByWorkspace(
      this.sessions,
      this.workspaces,
      this.archivedSessionIds,
      excludePinned ? this.pinnedSessionIds : []
    );
  }

  getPinnedSessions(): DshPinnedSessionEntry[] {
    return buildPinnedSessionEntries(
      this.sessions,
      this.workspaces,
      this.archivedSessionIds,
      this.pinnedSessionIds
    );
  }

  getArchivedSessions(): DshPinnedSessionEntry[] {
    return buildArchivedSessions(this.sessions, this.workspaces, this.archivedSessionIds);
  }

  isSessionPinned(sessionId: string): boolean {
    return this.pinnedSessionIds.indexOf(sessionId) >= 0;
  }

  isSessionArchived(sessionId: string): boolean {
    return this.archivedSessionIds.indexOf(sessionId) >= 0;
  }

  getSessionSummary(sessionId: string): DshSession | undefined {
    for (let i = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].sessionId === sessionId) {
        return this.sessions[i];
      }
    }
    return undefined;
  }

  getActiveModelSelection(sessionId: string): DshModelSelection | undefined {
    if (sessionId === this.activeSessionId && this.projected.modelSelection !== undefined) {
      return this.projected.modelSelection;
    }
    const summary = this.getSessionSummary(sessionId);
    if (summary !== undefined && summary.modelSelection !== undefined) {
      return summary.modelSelection;
    }
    return this.modelCatalog.defaultSelection;
  }

  getPromptsForSession(sessionId: string): DshPendingPrompt[] {
    const out: DshPendingPrompt[] = [];
    for (let i = 0; i < this.pendingPrompts.length; i++) {
      const p = this.pendingPrompts[i];
      if (p.agentId.length === 0 || p.agentId === sessionId) {
        out.push(p);
      }
    }
    return out;
  }

  // ───────────────────────── 生命周期与鉴权 ─────────────────────────

  private async ensureAuthorized(forceRefresh: boolean = false): Promise<void> {
    const api = TentacleApi.getInstance();
    const epoch = api.getCacheEpoch();
    if (this.activeTokenEpoch !== epoch) {
      this.resetAllState();
      this.activeTokenEpoch = epoch;
    }
    if (!forceRefresh && api.hasCodingCookie()) {
      return;
    }
    if (forceRefresh) {
      api.clearCodingCookie();
    }
    if (this.authPending !== null) {
      return await this.authPending;
    }
    this.authPending = api.authorizeDsh().then(() => {
      this.authPending = null;
    }).catch((err: Error) => {
      this.authPending = null;
      throw err;
    });
    await this.authPending;
  }

  resetAllState(): void {
    this.wantConnected = false;
    this.ready = false;
    this.connecting = false;
    this.muxConnected = false;
    this.lastError = '';
    this.sessions = [];
    this.workspaces = [];
    this.archivedSessionIds = [];
    this.pinnedSessionIds = [];
    this.modelCatalog = { groups: [], flatModels: [] };
    this.pendingPrompts = [];
    this.activeQueued = [];
    this.activeCommands = [];
    this.commandsLoadState = 'idle';
    this.commandsError = '';
    this.activeReferences = [];
    this.rawRecords = [];
    this.liveAttempt = createEmptyLiveAttempt();
    this.projected = projectSessionRecords([]);
    this.eventsStreamId = '';
    this.eventsClientId = '';
    this.workspaceStreamId = '';
    this.controlStreamId = '';
    this.followStreamId = '';
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
    this.mux.close();
  }

  async ensureConnected(): Promise<boolean> {
    this.wantConnected = true;
    const api = TentacleApi.getInstance();
    const epoch = api.getCacheEpoch();
    if (this.activeTokenEpoch !== epoch) {
      this.resetAllState();
      this.wantConnected = true;
      this.activeTokenEpoch = epoch;
    }
    this.connecting = true;
    this.lastError = '';
    this.notify();
    try {
      await this.ensureAuthorized(false);
      await Promise.all([
        this.refreshSessions(),
        this.refreshModelCatalog()
      ]);
      this.ready = true;
      await this.ensureMuxOpen();
      return true;
    } catch (e) {
      this.lastError = (e as Error).message;
      return false;
    } finally {
      this.connecting = false;
      this.notify();
    }
  }

  private async ensureMuxOpen(): Promise<boolean> {
    if (this.mux.isOpen()) {
      this.muxConnected = true;
      this.ensureCoreStreams();
      return true;
    }
    const api = TentacleApi.getInstance();
    let base = api.getServerUrl();
    if (base.startsWith('https://')) {
      base = 'wss://' + base.substring(8);
    } else if (base.startsWith('http://')) {
      base = 'ws://' + base.substring(7);
    } else {
      return false;
    }
    const wsUrl = base + '/coding/api/remote.mux';
    const headers = api.buildCodingHeaders(false);
    const ok = await this.mux.connect(wsUrl, headers);
    this.muxConnected = ok;
    if (!ok && this.mux.getLastConnectError().length > 0 && this.lastError.length === 0) {
      this.lastError = this.mux.getLastConnectError();
    }
    if (ok) {
      this.reconnectAttempt = 0;
      this.ensureCoreStreams();
      if (this.activeSessionId.length > 0 && this.followStreamId.length === 0) {
        this.openFollowStream(this.activeSessionId);
      }
    }
    this.notify();
    return ok;
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer >= 0 || !this.wantConnected) {
      return;
    }
    const delayMs = Math.min(12000, 1200 * Math.pow(1.6, this.reconnectAttempt));
    this.reconnectAttempt = Math.min(this.reconnectAttempt + 1, 6);
    this.reconnectTimer = setTimeout(async () => {
      this.reconnectTimer = -1;
      if (!this.wantConnected) {
        return;
      }
      try {
        await this.ensureAuthorized(false);
        await this.ensureMuxOpen();
        if (this.activeSessionId.length > 0) {
          this.refreshSessions();
        }
      } catch (_) {
        this.scheduleReconnect();
      }
    }, delayMs);
  }

  private ensureCoreStreams(): void {
    if (!this.mux.isOpen()) {
      return;
    }
    if (this.eventsStreamId.length === 0) {
      this.eventsStreamId = this.mux.openStream('$events', {} as JsonBag, {
        onItem: (val: Object) => this.handleEventsFrame(val),
        onError: (_c: string, _m: string) => {
          this.eventsStreamId = '';
          this.eventsClientId = '';
        },
        onEnd: () => {
          this.eventsStreamId = '';
          this.eventsClientId = '';
        }
      });
    }
    if (this.workspaceStreamId.length === 0) {
      this.workspaceStreamId = this.mux.openStream('workspace/follow', {} as JsonBag, {
        onItem: (val: Object) => this.handleWorkspaceFrame(val),
        onError: (_c: string, _m: string) => { this.workspaceStreamId = ''; },
        onEnd: () => { this.workspaceStreamId = ''; }
      });
    }
    if (this.controlStreamId.length === 0) {
      this.controlStreamId = this.mux.openStream('session/control', {} as JsonBag, {
        onItem: (val: Object) => this.handleControlFrame(val),
        onError: (_c: string, _m: string) => { this.controlStreamId = ''; },
        onEnd: () => { this.controlStreamId = ''; }
      });
    }
  }

  // ───────────────────────── 一元 HTTP RPC ─────────────────────────

  async callRpc(method: string, args: Object, timeoutMs: number = 25000): Promise<Object | undefined> {
    await this.ensureAuthorized(false);
    try {
      return await this.sendUnaryOnce(method, args, timeoutMs);
    } catch (e) {
      const msg = (e as Error).message;
      if (msg.indexOf('HTTP 401') >= 0 || msg.indexOf('HTTP 403') >= 0) {
        await this.ensureAuthorized(true);
        return await this.sendUnaryOnce(method, args, timeoutMs);
      }
      throw e instanceof Error ? e : new Error(String(e));
    }
  }

  private sendUnaryOnce(method: string, args: Object, timeoutMs: number): Promise<Object | undefined> {
    const api = TentacleApi.getInstance();
    const rpcId = randomUuid();
    const body = buildRpcPacket(rpcId, method, args);
    const asciiLen = isAsciiText(body) ? body.length : -1;
    const headers = api.buildCodingHeaders(true, 'application/json', asciiLen);

    return new Promise<Object | undefined>((resolve, reject) => {
      const req = http.createHttp();
      try {
        req.request(api.getServerUrl() + '/coding/api/' + method, {
          method: http.RequestMethod.POST,
          header: headers,
          extraData: body,
          usingCache: false,
          expectDataType: http.HttpDataType.STRING,
          connectTimeout: 10000,
          readTimeout: timeoutMs
        }, (err: BusinessError, resp: http.HttpResponse) => {
          req.destroy();
          if (err) {
            reject(new Error('[DSH RPC:' + method + ' code=' + (err.code ?? 0).toString() + '] ' + err.message));
            return;
          }
          const status: number = resp.responseCode;
          const text: string = String(resp.result ?? '');
          if (status === 401 || status === 403) {
            reject(new Error('HTTP ' + status.toString() + ': 鉴权已失效'));
            return;
          }
          if (status < 200 || status >= 300) {
            reject(new Error('HTTP ' + status.toString() + (text.length > 0 ? ': ' + text.substring(0, 140) : '')));
            return;
          }
          let contentType = '';
          if (resp.header) {
            const hRec = resp.header as Record<string, Object>;
            const hKeys = Object.keys(hRec);
            for (let i = 0; i < hKeys.length; i++) {
              if (hKeys[i].toLowerCase() === 'content-type') {
                const v = hRec[hKeys[i]];
                if (typeof v === 'string') {
                  contentType = v as string;
                }
                break;
              }
            }
          }
          const outcome = parseRpcResponse(text, rpcId, method, contentType);
          if (!outcome.ok) {
            const errInfo = outcome.error;
            reject(new Error(errInfo !== undefined ? errInfo.message : (method + ' 请求失败')));
            return;
          }
          resolve(outcome.value);
        });
      } catch (syncErr) {
        req.destroy();
        const bErr = syncErr as BusinessError;
        reject(new Error('[DSH RPC:' + method + ' 异常 code=' + (bErr.code ?? 0).toString() + '] ' + (bErr.message ?? String(syncErr))));
      }
    });
  }

  // ───────────────────────── 工作区与会话操作 ─────────────────────────

  async refreshSessions(): Promise<void> {
    const args: JsonBag = { '_request': {} as JsonBag };
    const value = await this.callRpc('session/list', args, 15000);
    this.sessions = parseSessionList(value);
    if (this.activeSessionId.length > 0) {
      const cur = this.getSessionSummary(this.activeSessionId);
      if (cur !== undefined && this.followStreamId.length === 0) {
        this.activeSessionRunning = cur.running;
      }
    }
    this.notify();
  }

  async refreshModelCatalog(): Promise<void> {
    try {
      const value = await this.callRpc('session/modelCatalog', {} as JsonBag, 15000);
      this.modelCatalog = parseModelCatalog(value);
      this.notify();
    } catch (_) {
      // 模型目录拉取失败不阻断列表展示
    }
  }

  async listDirectory(dirPath: string = ''): Promise<DshDirectoryListing> {
    const args: JsonBag = dirPath.length > 0 ? { 'path': dirPath } : {};
    const value = await this.callRpc('directoryPicker/list', args, 15000);
    return parseDirectoryListing(value);
  }

  async createDirectory(parentPath: string, name: string): Promise<string> {
    const args: JsonBag = { 'path': parentPath, 'name': name };
    const value = await this.callRpc('directoryPicker/createDirectory', args, 15000);
    return typeof value === 'string' ? value as string : '';
  }

  async createSessionInDirectory(dirPath: string, existingWorkspaceId: string = ''): Promise<string> {
    let wsId = existingWorkspaceId;
    if (wsId.length === 0 && dirPath.length > 0) {
      const wsReq: JsonBag = { 'path': dirPath };
      const wsRes = await this.callRpc('workspace/create', { 'request': wsReq } as JsonBag, 20000);
      const wsObj = wsRes !== undefined ? jsonField(wsRes, 'workspace') : undefined;
      if (wsObj !== undefined) {
        wsId = jsonStr(wsObj, 'workspaceId');
      }
    }
    const req: JsonBag = {};
    if (wsId.length > 0) {
      req['workspaceId'] = wsId;
    } else if (dirPath.length > 0) {
      req['cwd'] = dirPath;
    }
    const created = await this.callRpc('session/create', { 'request': req } as JsonBag, 20000);
    const sid = created !== undefined ? jsonStr(created, 'sessionId') : '';
    if (sid.length === 0) {
      throw new Error('创建会话未返回 sessionId');
    }
    await this.refreshSessions();
    return sid;
  }

  async renameSession(sessionId: string, title: string): Promise<string> {
    const req: JsonBag = { 'sessionId': sessionId, 'title': title };
    const value = await this.callRpc('session/rename', { 'request': req } as JsonBag, 15000);
    const normalized = value !== undefined ? jsonStr(value, 'title', title) : title;
    this.patchSessionTitle(sessionId, normalized);
    return normalized;
  }

  async forkSession(sessionId: string): Promise<string> {
    const req: JsonBag = { 'sessionId': sessionId };
    const value = await this.callRpc('session/fork', { 'request': req } as JsonBag, 20000);
    const forkedId = value !== undefined ? jsonStr(value, 'sessionId') : '';
    if (forkedId.length === 0) {
      throw new Error('Fork 会话未返回新 sessionId');
    }
    await this.refreshSessions();
    return forkedId;
  }

  async pinSession(sessionId: string): Promise<void> {
    const req: JsonBag = { 'sessionId': sessionId };
    const value = await this.callRpc('workspace/pinSession', { 'request': req } as JsonBag, 15000);
    const nextIds = value !== undefined ? jsonStrArr(value, 'pinnedSessionIds') : [];
    if (nextIds.length > 0 || (value !== undefined && isPlainObject(value) && jsonField(value, 'pinnedSessionIds') !== undefined)) {
      this.pinnedSessionIds = nextIds;
    } else if (this.pinnedSessionIds.indexOf(sessionId) < 0) {
      this.pinnedSessionIds = [sessionId].concat(this.pinnedSessionIds);
    }
    this.notify();
  }

  async unpinSession(sessionId: string): Promise<void> {
    const req: JsonBag = { 'sessionId': sessionId };
    const value = await this.callRpc('workspace/unpinSession', { 'request': req } as JsonBag, 15000);
    if (value !== undefined && isPlainObject(value) && jsonField(value, 'pinnedSessionIds') !== undefined) {
      this.pinnedSessionIds = jsonStrArr(value, 'pinnedSessionIds');
    } else {
      this.pinnedSessionIds = this.pinnedSessionIds.filter((id: string) => id !== sessionId);
    }
    this.notify();
  }

  async archiveSession(sessionId: string, stopActivity: boolean = true): Promise<void> {
    const req: JsonBag = { 'sessionId': sessionId };
    if (stopActivity) {
      req['stopActivity'] = true;
    }
    const value = await this.callRpc('workspace/archiveSession', { 'request': req } as JsonBag, 15000);
    if (value !== undefined && isPlainObject(value) && jsonField(value, 'archivedSessionIds') !== undefined) {
      this.archivedSessionIds = jsonStrArr(value, 'archivedSessionIds');
    } else if (this.archivedSessionIds.indexOf(sessionId) < 0) {
      this.archivedSessionIds = this.archivedSessionIds.concat([sessionId]);
    }
    if (this.pinnedSessionIds.indexOf(sessionId) >= 0) {
      this.pinnedSessionIds = this.pinnedSessionIds.filter((id: string) => id !== sessionId);
    }
    this.notify();
  }

  async unarchiveSession(sessionId: string): Promise<void> {
    const req: JsonBag = { 'sessionId': sessionId };
    const value = await this.callRpc('workspace/unarchiveSession', { 'request': req } as JsonBag, 15000);
    if (value !== undefined && isPlainObject(value) && jsonField(value, 'archivedSessionIds') !== undefined) {
      this.archivedSessionIds = jsonStrArr(value, 'archivedSessionIds');
    } else {
      this.archivedSessionIds = this.archivedSessionIds.filter((id: string) => id !== sessionId);
    }
    this.notify();
  }

  async renameWorkspace(workspaceId: string, title: string): Promise<void> {
    const req: JsonBag = { 'workspaceId': workspaceId, 'title': title };
    const value = await this.callRpc('workspace/rename', { 'request': req } as JsonBag, 15000);
    const updated = value !== undefined ? parseWorkspaceView(jsonField(value, 'workspace')) : undefined;
    const next: DshWorkspace[] = [];
    for (let i = 0; i < this.workspaces.length; i++) {
      const cur = this.workspaces[i];
      if (cur.workspaceId === workspaceId) {
        if (updated !== undefined) {
          next.push(updated);
        } else {
          next.push({
            workspaceId: cur.workspaceId,
            path: cur.path,
            title: title,
            sessionIds: cur.sessionIds,
            createdAt: cur.createdAt,
            updatedAt: cur.updatedAt
          });
        }
      } else {
        next.push(cur);
      }
    }
    this.workspaces = next;
    this.notify();
  }

  async deleteWorkspace(workspaceId: string): Promise<void> {
    const req: JsonBag = { 'workspaceId': workspaceId };
    await this.callRpc('workspace/delete', { 'request': req } as JsonBag, 15000);
    this.workspaces = this.workspaces.filter((w: DshWorkspace) => w.workspaceId !== workspaceId);
    this.notify();
  }

  async searchSessions(query: string): Promise<DshSessionSearchResult> {
    const clean = query.trim();
    if (clean.length === 0) {
      return { items: [], hasMore: false };
    }
    const req: JsonBag = { 'query': clean };
    const value = await this.callRpc('session/search', { 'request': req } as JsonBag, 15000);
    return parseSessionSearchResult(value);
  }

  // ───────────────────────── 单会话详情与流订阅 ─────────────────────────

  async openSession(sessionId: string): Promise<void> {
    this.wantConnected = true;
    if (this.activeSessionId !== sessionId) {
      this.closeFollowStream();
      this.activeSessionId = sessionId;
      this.rawRecords = [];
      this.activeProjections = undefined;
      this.liveAttempt = createEmptyLiveAttempt();
      this.activeCommands = [];
      this.commandsLoadState = 'idle';
      this.commandsError = '';
      this.activeReferences = [];
      this.activeQueued = [];
      const summary = this.getSessionSummary(sessionId);
      this.activeSessionRunning = summary !== undefined ? summary.running : false;
      this.projected = projectSessionRecords([]);
    }
    this.activeSessionLoading = true;
    this.notify();

    try {
      await this.ensureAuthorized(false);
      if (this.sessions.length === 0) {
        await this.refreshSessions();
      }
      if (this.modelCatalog.flatModels.length === 0) {
        this.refreshModelCatalog();
      }
      const muxOk = await this.ensureMuxOpen();
      if (muxOk) {
        this.openFollowStream(sessionId);
      } else {
        await this.loadInitialViaPage(sessionId);
      }
      this.refreshCommands(sessionId);
      this.queryReferences(sessionId, '').then((refs: DshReferenceCandidate[]) => {
        if (this.activeSessionId === sessionId) {
          this.activeReferences = refs;
          this.notify();
        }
      }).catch(() => {});
    } catch (e) {
      this.lastError = (e as Error).message;
      this.activeSessionLoading = false;
      this.notify();
    }
  }

  closeSession(): void {
    this.closeFollowStream();
    this.activeSessionId = '';
    this.activeSessionLoading = false;
    this.rawRecords = [];
    this.liveAttempt = createEmptyLiveAttempt();
    if (this.projectThrottleTimer >= 0) {
      clearTimeout(this.projectThrottleTimer);
      this.projectThrottleTimer = -1;
    }
  }

  private openFollowStream(sessionId: string): void {
    this.closeFollowStream();
    if (!this.mux.isOpen() || sessionId.length === 0) {
      return;
    }
    const addr: JsonBag = { 'kind': 'session', 'sessionId': sessionId };
    const req: JsonBag = {
      'address': addr,
      'maxMessages': 80,
      'assistantStream': true
    };
    this.followStreamId = this.mux.openStream('session/follow', { 'request': req } as JsonBag, {
      onItem: (val: Object) => {
        if (this.activeSessionId === sessionId) {
          this.handleFollowFrame(val);
        }
      },
      onError: (_code: string, msg: string) => {
        if (this.activeSessionId === sessionId) {
          this.followStreamId = '';
          this.activeSessionLoading = false;
          if (this.rawRecords.length === 0) {
            this.lastError = msg;
          }
          this.notify();
        }
      },
      onEnd: () => {
        if (this.activeSessionId === sessionId) {
          this.followStreamId = '';
          this.activeSessionLoading = false;
          this.notify();
        }
      }
    });
  }

  private closeFollowStream(): void {
    if (this.followStreamId.length > 0) {
      this.mux.cancelStream(this.followStreamId);
      this.followStreamId = '';
    }
  }

  private async loadInitialViaPage(sessionId: string): Promise<void> {
    const summary = this.getSessionSummary(sessionId);
    const cursor = summary !== undefined ? summary.asOfSeq : -1;
    if (cursor < 0) {
      this.activeSessionLoading = false;
      this.notify();
      return;
    }
    const addr: JsonBag = { 'kind': 'session', 'sessionId': sessionId };
    const req: JsonBag = { 'address': addr, 'throughSeq': cursor, 'maxMessages': 80 };
    const value = await this.callRpc('session/page', { 'request': req } as JsonBag, 15000);
    if (this.activeSessionId !== sessionId || value === undefined) {
      return;
    }
    const recs = jsonArr(value, 'records');
    this.rawRecords = this.toRawRecordList(recs);
    this.activeHasMore = jsonBool(value, 'hasMore');
    this.activeSessionLoading = false;
    this.reprojectNow();
  }

  async loadEarlierMessages(): Promise<void> {
    const sessionId = this.activeSessionId;
    if (sessionId.length === 0 || !this.activeHasMore || this.rawRecords.length === 0) {
      return;
    }
    let minSeq = this.rawRecords[0].seq;
    for (let i = 1; i < this.rawRecords.length; i++) {
      if (this.rawRecords[i].seq < minSeq) {
        minSeq = this.rawRecords[i].seq;
      }
    }
    if (minSeq <= 0) {
      this.activeHasMore = false;
      this.notify();
      return;
    }
    const addr: JsonBag = { 'kind': 'session', 'sessionId': sessionId };
    const req: JsonBag = { 'address': addr, 'throughSeq': minSeq - 1, 'maxMessages': 60 };
    const value = await this.callRpc('session/page', { 'request': req } as JsonBag, 15000);
    if (this.activeSessionId !== sessionId || value === undefined) {
      return;
    }
    const older = this.toRawRecordList(jsonArr(value, 'records'));
    const seen: Set<number> = new Set<number>();
    const merged: DshRawRecord[] = [];
    for (let i = 0; i < older.length; i++) {
      if (!seen.has(older[i].seq)) {
        seen.add(older[i].seq);
        merged.push(older[i]);
      }
    }
    for (let i = 0; i < this.rawRecords.length; i++) {
      if (!seen.has(this.rawRecords[i].seq)) {
        seen.add(this.rawRecords[i].seq);
        merged.push(this.rawRecords[i]);
      }
    }
    merged.sort((a: DshRawRecord, b: DshRawRecord) => a.seq - b.seq);
    this.rawRecords = merged;
    this.activeHasMore = jsonBool(value, 'hasMore');
    this.reprojectNow();
  }

  // ───────────────────────── 模型 / 指令 / 发送 / 队列 / 审批 ─────────────────────────

  async selectModel(sessionId: string, provider: string, model: string,
    reasoningEffort: string): Promise<DshModelSelection> {
    const req: JsonBag = {
      'sessionId': sessionId,
      'provider': provider,
      'model': model
    };
    if (reasoningEffort.length > 0) {
      req['reasoningEffort'] = reasoningEffort;
    }
    const value = await this.callRpc('session/selectModel', { 'request': req } as JsonBag, 15000);
    const selObj = value !== undefined ? jsonField(value, 'selected') : undefined;
    const normalized = parseModelSelection(selObj) ?? {
      provider: provider,
      model: model,
      reasoningEffort: reasoningEffort
    };
    if (this.activeSessionId === sessionId) {
      this.projected.modelSelection = normalized;
    }
    for (let i = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].sessionId === sessionId) {
        this.sessions[i].modelSelection = normalized;
      }
    }
    this.notify();
    return normalized;
  }

  async refreshCommands(sessionId: string): Promise<void> {
    if (sessionId.length === 0) {
      return;
    }
    if (this.activeSessionId === sessionId) {
      this.commandsLoadState = 'loading';
      this.commandsError = '';
      this.notify();
    }
    try {
      const value = await this.callRpc('commands/list', { 'agentId': sessionId } as JsonBag, 10000);
      if (this.activeSessionId === sessionId) {
        this.activeCommands = parseCommandsList(value);
        this.commandsLoadState = 'loaded';
        this.commandsError = '';
        this.notify();
      }
    } catch (e) {
      if (this.activeSessionId === sessionId) {
        this.commandsLoadState = 'error';
        this.commandsError = (e as Error).message;
        this.notify();
      }
    }
  }

  async executeCommand(sessionId: string, line: string,
    attachments: DshPendingAttachment[] = []): Promise<DshCommandExecResult> {
    const subAtts: Object[] = [];
    for (let i = 0; i < attachments.length; i++) {
      const a = attachments[i];
      if (a.receiptId.length > 0) {
        subAtts.push({ 'type': 'file', 'receiptId': a.receiptId } as JsonBag);
      } else if (a.isImage && a.dataBase64.length > 0) {
        const img: JsonBag = { 'type': 'image', 'mediaType': a.mediaType, 'data': a.dataBase64 };
        if (a.name.length > 0) {
          img['name'] = a.name;
        }
        subAtts.push(img);
      }
    }
    const args: JsonBag = {
      'agentId': sessionId,
      'line': line,
      'submittedAttachments': subAtts
    };
    const value = await this.callRpc('commands/execute', args, 20000);
    if (value === undefined || !isPlainObject(value)) {
      return {
        commandId: '',
        matched: false,
        kind: 'error',
        text: '未识别的斜杠指令或参数不匹配'
      };
    }
    const commandId = jsonStr(value, 'commandId');
    const resObj = jsonRec(value, 'result');
    const resKind = resObj !== undefined ? jsonStr(resObj, 'kind', 'success') : 'success';
    const resText = resObj !== undefined ? jsonStr(resObj, 'text') : '';
    if (!this.mux.isOpen()) {
      this.loadInitialViaPage(sessionId).catch(() => {});
    }
    return {
      commandId: commandId,
      matched: true,
      kind: resKind,
      text: resText
    };
  }

  async sendPrompt(sessionId: string, text: string, attachments: DshPendingAttachment[],
    mode: string = 'queue'): Promise<void> {
    const parts: Object[] = [];
    if (text.trim().length > 0) {
      parts.push({ 'type': 'text', 'text': text } as JsonBag);
    }
    for (let i = 0; i < attachments.length; i++) {
      const a = attachments[i];
      if (a.receiptId.length > 0) {
        parts.push({ 'type': 'file', 'receiptId': a.receiptId } as JsonBag);
      } else if (a.isImage && a.dataBase64.length > 0) {
        const img: JsonBag = { 'type': 'image', 'mediaType': a.mediaType, 'data': a.dataBase64 };
        if (a.name.length > 0) {
          img['name'] = a.name;
        }
        parts.push(img);
      }
    }
    if (parts.length === 0) {
      return;
    }
    const requestId = randomUuid();
    let tz = '';
    try {
      tz = Intl.DateTimeFormat().resolvedOptions().timeZone ?? '';
    } catch (_) {
      tz = 'Asia/Shanghai';
    }
    const req: JsonBag = {
      'requestId': requestId,
      'sessionId': sessionId,
      'mode': mode === 'steer' ? 'steer' : 'queue',
      'content': parts
    };
    if (tz.length > 0) {
      req['clientTimeZone'] = tz;
    }
    this.activeSessionRunning = true;
    this.notify();
    try {
      await this.callRpc('session/prompt', { 'request': req } as JsonBag, 25000);
    } catch (e) {
      this.notify();
      throw e instanceof Error ? e : new Error(String(e));
    }
  }

  async cancelTurn(sessionId: string): Promise<void> {
    const req: JsonBag = { 'sessionId': sessionId };
    await this.callRpc('session/cancel', { 'request': req } as JsonBag, 10000);
  }

  async updateQueueItem(sessionId: string, itemId: string, actionKind: string): Promise<void> {
    const action: JsonBag = { 'kind': actionKind === 'steer' ? 'steer' : 'remove' };
    const req: JsonBag = { 'sessionId': sessionId, 'itemId': itemId, 'action': action };
    await this.callRpc('session/updateQueue', { 'request': req } as JsonBag, 15000);
  }

  async queryReferences(sessionId: string, query: string): Promise<DshReferenceCandidate[]> {
    const args: JsonBag = { 'agentId': sessionId, 'query': query };
    const value = await this.callRpc('fileReferences/list', args, 10000);
    return parseReferenceCandidates(value);
  }

  async uploadFileBytes(sessionId: string, bytes: ArrayBuffer, name: string): Promise<DshUploadedFile> {
    const helper = new util.Base64Helper();
    const b64 = helper.encodeToStringSync(new Uint8Array(bytes));
    const inner: JsonBag = { 'data': b64 };
    if (name.length > 0) {
      inner['name'] = name;
    }
    const args: JsonBag = { 'agentId': sessionId, 'request': inner };
    const value = await this.callRpc('fileUploads/upload', args, 45000);
    const parsed = parseFileUploadReceipt(value);
    if (parsed === undefined) {
      throw new Error('附件上传未返回有效回执');
    }
    return parsed;
  }

  async answerApproval(prompt: DshPendingPrompt, allow: boolean): Promise<boolean> {
    if (this.eventsClientId.length === 0) {
      throw new Error('事件通道尚未就绪，请稍后重试');
    }
    const outcome: JsonBag = { 'kind': 'result', 'value': allow ? 'allowed-once' : 'rejected' };
    const args: JsonBag = { 'clientId': this.eventsClientId, 'eventId': prompt.eventId, 'outcome': outcome };
    await this.callRpc('$events/result', args, 15000);
    this.removePrompt(prompt.eventId);
    return true;
  }

  async answerQuestions(prompt: DshPendingPrompt, answers: DshQuestionAnswerPayload[]): Promise<boolean> {
    if (this.eventsClientId.length === 0) {
      throw new Error('事件通道尚未就绪，请稍后重试');
    }
    const ansObjs: Object[] = [];
    for (let i = 0; i < answers.length; i++) {
      const a = answers[i];
      const one: JsonBag = { 'id': a.id, 'selected': a.selected };
      if (a.custom !== undefined && a.custom.trim().length > 0) {
        one['custom'] = a.custom.trim();
      }
      ansObjs.push(one);
    }
    const valObj: JsonBag = { 'answers': ansObjs };
    const outcome: JsonBag = { 'kind': 'result', 'value': valObj };
    const args: JsonBag = { 'clientId': this.eventsClientId, 'eventId': prompt.eventId, 'outcome': outcome };
    await this.callRpc('$events/result', args, 15000);
    this.removePrompt(prompt.eventId);
    return true;
  }

  async rejectQuestion(prompt: DshPendingPrompt): Promise<boolean> {
    if (this.eventsClientId.length === 0) {
      this.removePrompt(prompt.eventId);
      return true;
    }
    const errObj: JsonBag = { 'code': 'ASK_CANCELLED', 'message': '用户取消作答' };
    const outcome: JsonBag = { 'kind': 'rejected', 'error': errObj };
    const args: JsonBag = { 'clientId': this.eventsClientId, 'eventId': prompt.eventId, 'outcome': outcome };
    await this.callRpc('$events/result', args, 15000);
    this.removePrompt(prompt.eventId);
    return true;
  }

  // ───────────────────────── 内部流帧分发 ─────────────────────────

  private handleEventsFrame(val: Object): void {
    const ftype = jsonStr(val, 'type');
    if (ftype === 'ready') {
      this.eventsClientId = jsonStr(val, 'clientId');
      this.notify();
      return;
    }
    if (ftype === 'waterfall') {
      const prompt = parseWaterfallPrompt(val);
      if (prompt !== undefined) {
        const next: DshPendingPrompt[] = [];
        let replaced = false;
        for (let i = 0; i < this.pendingPrompts.length; i++) {
          if (this.pendingPrompts[i].eventId === prompt.eventId) {
            next.push(prompt);
            replaced = true;
          } else {
            next.push(this.pendingPrompts[i]);
          }
        }
        if (!replaced) {
          next.push(prompt);
        }
        this.pendingPrompts = next;
        this.notify();
      } else {
        const eid = jsonStr(val, 'eventId');
        if (eid.length > 0 && this.eventsClientId.length > 0) {
          const nextOutcome: JsonBag = { 'kind': 'next' };
          this.callRpc('$events/result', {
            'clientId': this.eventsClientId,
            'eventId': eid,
            'outcome': nextOutcome
          } as JsonBag, 10000).catch(() => {});
        }
      }
      return;
    }
    if (ftype === 'cancel') {
      const eid = jsonStr(val, 'eventId');
      if (eid.length > 0) {
        this.removePrompt(eid);
      }
      return;
    }
    if (ftype === 'emit') {
      const evName = jsonStr(val, 'event');
      const args = jsonArr(val, 'args');
      if (evName === 'api-session/removed' && args.length > 0 && typeof args[0] === 'string') {
        const removedId = args[0] as string;
        this.sessions = this.sessions.filter((s: DshSession) => s.sessionId !== removedId);
        this.notify();
      } else if (evName === 'api-session/status' && args.length >= 2 && typeof args[0] === 'string') {
        const sid = args[0] as string;
        const running = args[1] === true;
        this.patchSessionRunning(sid, running);
      } else if (evName === 'api-session/activity' && args.length >= 2 && typeof args[0] === 'string') {
        const sid = args[0] as string;
        const ts = typeof args[1] === 'number' ? args[1] as number : 0;
        if (ts > 0) {
          this.patchSessionActivity(sid, ts);
        }
      } else if (evName === 'api-session/added' && args.length > 0) {
        const added = parseSessionSummary(args[0]);
        if (added !== undefined) {
          this.upsertSession(added);
        }
      } else if (evName === 'commands/change' && this.activeSessionId.length > 0) {
        this.refreshCommands(this.activeSessionId);
      } else if (evName === 'api-session/error' && args.length >= 2 && typeof args[1] === 'string') {
        this.lastError = args[1] as string;
        this.notify();
      }
    }
  }

  private handleWorkspaceFrame(val: Object): void {
    const ftype = jsonStr(val, 'type');
    if (ftype === 'baseline' || ftype === 'replace') {
      const base = parseWorkspaceBaseline(jsonField(val, 'value'));
      this.workspaces = base.workspaces;
      this.archivedSessionIds = base.archivedSessionIds;
      this.pinnedSessionIds = base.pinnedSessionIds;
      this.notify();
      return;
    }
    if (ftype === 'upsert') {
      const ws = parseWorkspaceView(jsonField(val, 'workspace'));
      if (ws === undefined) {
        return;
      }
      const next: DshWorkspace[] = [];
      let replaced = false;
      for (let i = 0; i < this.workspaces.length; i++) {
        if (this.workspaces[i].workspaceId === ws.workspaceId) {
          next.push(ws);
          replaced = true;
        } else {
          next.push(this.workspaces[i]);
        }
      }
      if (!replaced) {
        next.push(ws);
      }
      this.workspaces = next;
      this.notify();
      return;
    }
    if (ftype === 'remove') {
      const wsid = jsonStr(val, 'workspaceId');
      this.workspaces = this.workspaces.filter((w: DshWorkspace) => w.workspaceId !== wsid);
      this.notify();
      return;
    }
    if (ftype === 'order') {
      const ids = jsonStrArr(val, 'workspaceIds');
      const byId: Map<string, DshWorkspace> = new Map<string, DshWorkspace>();
      for (let i = 0; i < this.workspaces.length; i++) {
        byId.set(this.workspaces[i].workspaceId, this.workspaces[i]);
      }
      const ordered: DshWorkspace[] = [];
      for (let i = 0; i < ids.length; i++) {
        const w = byId.get(ids[i]);
        if (w !== undefined) {
          ordered.push(w);
          byId.delete(ids[i]);
        }
      }
      byId.forEach((w: DshWorkspace) => ordered.push(w));
      this.workspaces = ordered;
      this.notify();
      return;
    }
    if (ftype === 'archived') {
      this.archivedSessionIds = jsonStrArr(val, 'archivedSessionIds');
      this.notify();
      return;
    }
    if (ftype === 'pinned') {
      this.pinnedSessionIds = jsonStrArr(val, 'pinnedSessionIds');
      this.notify();
    }
  }

  private handleControlFrame(val: Object): void {
    const ftype = jsonStr(val, 'type');
    if (ftype === 'baseline') {
      const base = jsonRec(val, 'value');
      if (base !== undefined && this.activeSessionId.length > 0) {
        const queues = jsonRec(base, 'queues');
        if (queues !== undefined) {
          this.activeQueued = parseQueuedItems(jsonArr(queues, this.activeSessionId));
        }
        const projs = jsonRec(base, 'projections');
        if (projs !== undefined) {
          const curProj = jsonField(projs, this.activeSessionId);
          if (curProj !== undefined) {
            this.mergeProjectionValues(curProj);
          }
        }
        this.notify();
      }
      return;
    }
    if (ftype === 'queue') {
      const sid = jsonStr(val, 'sessionId');
      if (sid === this.activeSessionId) {
        this.activeQueued = parseQueuedItems(jsonArr(val, 'items'));
        this.notify();
      }
      return;
    }
    if (ftype === 'projection') {
      const sid = jsonStr(val, 'sessionId');
      const key = jsonStr(val, 'key');
      const pVal = jsonField(val, 'value');
      if (sid === this.activeSessionId && key.length > 0 && pVal !== undefined) {
        const bag = this.ensureProjectionValuesBag();
        bag[key] = pVal;
        this.scheduleProject();
      }
    }
  }

  private handleFollowFrame(val: Object): void {
    const ftype = jsonStr(val, 'type');
    if (ftype === 'snapshot') {
      this.activeSessionLoading = false;
      this.rawRecords = this.toRawRecordList(jsonArr(val, 'records'));
      this.activeHasMore = jsonBool(val, 'hasMore');
      this.activeProjections = jsonField(val, 'projections');
      this.liveAttempt = createEmptyLiveAttempt();

      const asStream = jsonRec(val, 'assistantStream');
      if (asStream !== undefined) {
        const activeAttempt = jsonRec(asStream, 'activeAttempt');
        if (activeAttempt !== undefined) {
          let nextLive: DshLiveAttempt = {
            active: true,
            attemptId: jsonStr(activeAttempt, 'attemptId'),
            turn: jsonNum(activeAttempt, 'turn', 0),
            step: jsonNum(activeAttempt, 'step', 0),
            startedAt: Date.now(),
            blocks: []
          };
          const streamItems = jsonArr(activeAttempt, 'stream');
          for (let i = 0; i < streamItems.length; i++) {
            const wrapper: JsonBag = { 'type': 'chunk', 'chunk': streamItems[i] };
            nextLive = applyAssistantStreamFrame(nextLive, wrapper);
          }
          this.liveAttempt = nextLive;
          this.activeSessionRunning = true;
        }
      }
      const header = jsonRec(val, 'header');
      const summary = this.getSessionSummary(this.activeSessionId);
      if (summary !== undefined && !this.liveAttempt.active) {
        this.activeSessionRunning = summary.running;
      }
      if (header !== undefined && jsonBool(header, 'running', false)) {
        this.activeSessionRunning = true;
      }
      this.reprojectNow();
      return;
    }

    if (ftype === 'event') {
      const ev = jsonRec(val, 'event');
      if (ev === undefined) {
        return;
      }
      const seq = jsonNum(ev, 'seq', 0);
      const time = jsonNum(ev, 'time', 0);
      const evType = jsonStr(ev, 'type');

      let updated = false;
      for (let i = this.rawRecords.length - 1; i >= 0; i--) {
        if (this.rawRecords[i].seq === seq) {
          this.rawRecords[i] = { seq: seq, time: time, type: evType, raw: val };
          updated = true;
          break;
        }
      }
      if (!updated) {
        this.rawRecords.push({ seq: seq, time: time, type: evType, raw: val });
      }

      if (evType === 'turn/start' || evType === 'step/start') {
        this.activeSessionRunning = true;
      } else if (evType === 'turn/end') {
        this.activeSessionRunning = false;
        this.liveAttempt = createEmptyLiveAttempt();
        const evData = jsonRec(ev, 'data');
        const reasonObj = evData !== undefined ? jsonRec(evData, 'reason') : undefined;
        if (reasonObj !== undefined && jsonStr(reasonObj, 'kind') === 'error') {
          const errObj = jsonRec(reasonObj, 'error');
          if (errObj !== undefined) {
            this.lastError = jsonStr(errObj, 'message', '本轮执行失败');
          }
        }
        this.scheduleListRefresh();
      } else if (evType === 'assistant/message') {
        this.liveAttempt = createEmptyLiveAttempt();
      } else if (evType === 'session/title') {
        const evData = jsonRec(ev, 'data');
        const newTitle = evData !== undefined ? jsonStr(evData, 'title') : '';
        if (newTitle.length > 0) {
          const bag = this.ensureProjectionValuesBag();
          bag['title'] = newTitle;
          this.patchSessionTitle(this.activeSessionId, newTitle);
        }
      }
      this.reprojectNow();
      return;
    }

    if (ftype === 'assistant-stream') {
      const frame = jsonField(val, 'frame');
      if (frame !== undefined) {
        this.liveAttempt = applyAssistantStreamFrame(this.liveAttempt, frame);
        if (this.liveAttempt.active) {
          this.activeSessionRunning = true;
        }
        this.scheduleProject();
      }
    }
  }

  private toRawRecordList(arr: Object[]): DshRawRecord[] {
    const out: DshRawRecord[] = [];
    for (let i = 0; i < arr.length; i++) {
      const ev = jsonRec(arr[i], 'event');
      if (ev !== undefined) {
        out.push({
          seq: jsonNum(ev, 'seq', i),
          time: jsonNum(ev, 'time', 0),
          type: jsonStr(ev, 'type'),
          raw: arr[i]
        });
      }
    }
    return out;
  }

  private ensureProjectionValuesBag(): JsonBag {
    let p = isPlainObject(this.activeProjections) ? (this.activeProjections as JsonBag) : undefined;
    if (p === undefined) {
      p = {};
      this.activeProjections = p;
    }
    let vals = jsonRec(p, 'values');
    if (vals === undefined) {
      vals = {};
      p['values'] = vals;
    }
    return vals;
  }

  private mergeProjectionValues(valuesObj: Object): void {
    const rec = isPlainObject(valuesObj) ? (valuesObj as JsonBag) : undefined;
    if (rec === undefined) {
      return;
    }
    const bag = this.ensureProjectionValuesBag();
    const keys = Object.keys(rec);
    for (let i = 0; i < keys.length; i++) {
      bag[keys[i]] = rec[keys[i]];
    }
    this.scheduleProject();
  }

  private scheduleProject(): void {
    if (this.projectThrottleTimer >= 0) {
      return;
    }
    this.projectThrottleTimer = setTimeout(() => {
      this.projectThrottleTimer = -1;
      this.reprojectNow();
    }, 60);
  }

  private reprojectNow(): void {
    if (this.projectThrottleTimer >= 0) {
      clearTimeout(this.projectThrottleTimer);
      this.projectThrottleTimer = -1;
    }
    const records: Object[] = [];
    for (let i = 0; i < this.rawRecords.length; i++) {
      records.push(this.rawRecords[i].raw);
    }
    const summary = this.getSessionSummary(this.activeSessionId);
    const cursor = summary !== undefined ? summary.asOfSeq : -1;
    this.projected = projectSessionRecords(records, this.activeProjections, this.liveAttempt, cursor);
    this.notify();
  }

  private scheduleListRefresh(): void {
    if (this.refreshListTimer >= 0) {
      clearTimeout(this.refreshListTimer);
    }
    this.refreshListTimer = setTimeout(() => {
      this.refreshListTimer = -1;
      this.refreshSessions().catch(() => {});
    }, 400);
  }

  private removePrompt(eventId: string): void {
    this.pendingPrompts = this.pendingPrompts.filter((p: DshPendingPrompt) => p.eventId !== eventId);
    this.notify();
  }

  private patchSessionTitle(sessionId: string, title: string): void {
    for (let i = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].sessionId === sessionId) {
        this.sessions[i].title = title;
        this.sessions[i].titleFromHost = true;
      }
    }
    if (this.activeSessionId === sessionId) {
      this.projected.title = title;
      this.projected.hasTitle = title.length > 0;
    }
    this.notify();
  }

  private patchSessionRunning(sessionId: string, running: boolean): void {
    for (let i = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].sessionId === sessionId) {
        this.sessions[i].running = running;
      }
    }
    if (this.activeSessionId === sessionId) {
      this.activeSessionRunning = running;
    }
    this.notify();
  }

  private patchSessionActivity(sessionId: string, updatedAt: number): void {
    for (let i = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].sessionId === sessionId) {
        this.sessions[i].updatedAt = updatedAt;
      }
    }
    this.notify();
  }

  private upsertSession(session: DshSession): void {
    const next: DshSession[] = [];
    let replaced = false;
    for (let i = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].sessionId === session.sessionId) {
        next.push(session);
        replaced = true;
      } else {
        next.push(this.sessions[i]);
      }
    }
    if (!replaced) {
      next.push(session);
    }
    this.sessions = next;
    this.notify();
  }
}
