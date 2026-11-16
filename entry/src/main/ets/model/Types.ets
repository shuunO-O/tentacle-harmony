/**
 * TentacleApp 数据模型
 *
 * 所有 API 交互使用的数据类型 + 聊天状态模型。
 * 统一放在一个文件，避免 ArkTS 循环引用。
 */

// ========== REST API 模型 ==========

export interface Settings {
  agent_name: string;
  show_reasoning: boolean;
  split_messages: boolean;
  has_password: boolean;
}

export interface LoginResult {
  token: string;
  has_password: boolean;
}

export interface EnrollResult {
  ok: boolean;
}

// GET /api/auth/state（公开端点，前端据此决定显示绑定码还是密码登录）
export interface AuthState {
  has_password: boolean;
  device_auth: boolean;
  device_ok: boolean;
  freeze: boolean;
}

export interface SendResult {
  ok: boolean;
  total_tokens: number;
  round: RoundResult;
  command?: CommandResult;
}

export interface RoundMeta {
  round_id: string;
  request_id: string | null;
  source: string;
  platform: string;
}

export interface RoundResult extends RoundMeta {
  status: string;
  stop_reason: string;
  error: string | null;
  command?: CommandResult;
}

export interface CommandResult {
  text: string;
  refresh_history: boolean;
}

// /api/files/upload 返回的图片文件记录
export interface FileRecord {
  local_id: string;
  filename: string;
  path: string;
  mime: string;
  size: number;
  file_id?: string | null;
  expires_at?: number | null;
}

export interface UploadResult {
  ok: boolean;
  file: FileRecord;
}

// 气泡内引用的图片（历史 images 元素只需 local_id/filename；mime 用于 base64 data URI 渲染）
export interface MsgImage {
  local_id: string;
  filename: string;
  mime?: string;
  path?: string;
}

export interface SetPasswordResult {
  has_password: boolean;
}

export interface ApiErrorDetail {
  detail: string;
  round?: RoundResult;
}

export class ApiFailure extends Error {
  round: RoundResult | undefined;
  httpStatus: number;
  constructor(message: string, round?: RoundResult, httpStatus: number = 0) {
    super(message);
    this.round = round;
    this.httpStatus = httpStatus;
  }
}

export interface SubconsciousState {
  bond_level: number;
  emotion_score: number;
  miss_degree: number;
  drift_level: number;
  last_update_time: number;
}

export interface SessionInfo {
  session_id: string;
  start_time: number;
  end_time: number | null;
  status: string;
}

export interface TokenInfo {
  accumulated: number;
}

export interface HeartbeatInfo {
  interval_seconds: number;
  next_beat_at: number;
}

export interface DbCounts {
  raw_messages: number;
  sessions: number;
  summaries: number;
  goals: number;
  tasks: number;
  files: number;
  usage_logs: number;
}

// 最近一次请求的缓存命中快照（cache_hit_rate 服务端算好，无 prompt 时为 null）
export interface UsageLast {
  prompt_tokens: number;
  cached_tokens: number;
  cache_hit_rate: number | null;
}

// 启动以来累计 token（重启进程清零）
export interface UsageTotal {
  prompt_tokens: number;
  completion_tokens: number;
  total_tokens: number;
  cached_tokens: number;
}

export interface StatusUsage {
  last: UsageLast | null;
  total: UsageTotal;
}

export interface GraphNode {
  id: string;
  label: string;
  name?: string;
  type?: string;
  summary?: string;
  content?: string;
  create_time?: string;
}

export interface GraphRelationship {
  source: string;
  target: string;
  type: string;
  properties?: Record<string, string>;
}

export interface GraphData {
  nodes: GraphNode[];
  relationships: GraphRelationship[];
}

export interface GraphSummary {
  nodes: Record<string, number>;
  relationships: number;
}

export interface TerminalEntry {
  ts: number;
  content: string;
}

export interface TerminalHistoryResult {
  entries: TerminalEntry[];
}

// ---------- 用量统计 ----------

export interface UsagePoint {
  bucket: string;
  prompt_tokens: number;
  completion_tokens: number;
  total_tokens: number;
  cached_tokens: number;
  requests: number;
  cache_hit_rate: number | null;
}

export interface PeriodSummary {
  prompt_tokens: number;
  completion_tokens: number;
  total_tokens: number;
  cached_tokens: number;
  requests: number;
}

export interface UsageSummary {
  today: PeriodSummary;
  week: PeriodSummary;
  month: PeriodSummary;
  all: PeriodSummary;
}

export interface UsageOption {
  id: string;
  label: string;
  provider_ids?: string[];
}

export interface UsageOptions {
  providers: UsageOption[];
  models: UsageOption[];
  roles: UsageOption[];
}

export interface UsageResult {
  granularity: string;
  points: UsagePoint[];
  summary: UsageSummary;
  options: UsageOptions;
}

export interface BalanceInfo {
  currency?: string;
  total_balance?: string;
  topped_up_balance?: string;
  granted_balance?: string;
}

export interface BalanceResult {
  items: ProviderBalance[];
}

export interface ProviderBalance {
  provider_id: string;
  label: string;
  ok: boolean;
  is_available?: boolean;
  balances?: BalanceInfo[];
  fetched_at?: number;
  error?: string;
}

export interface Neo4jSummaryResult {
  ok: boolean;
  data: GraphSummary;
  error?: string;
}

export interface Neo4jGraphResult {
  ok: boolean;
  data: GraphData;
  error?: string;
}

export interface StatusData {
  agent_name: string;
  subconscious: SubconsciousState;
  session: SessionInfo | null;
  tokens: TokenInfo;
  heartbeat: HeartbeatInfo;
  db: DbCounts;
  connections: number;
  time: number;
  usage: StatusUsage | null;
}

@Observed
export class Bubble {
  text: string = '';
  platform: string = '';
  streaming: boolean = false;
}

export interface HistoryMessage {
  id: number;
  round_id: string | null;
  role: string;
  platform: string;
  created_time: number;
  content: string;
  segments?: string[];
  images?: MsgImage[] | null;
  interrupted?: boolean;
}

export interface HistoryResult {
  messages: HistoryMessage[];
  has_more: boolean;
}

// 表格数据（后端 rows 为值数组，客户端统一转字符串）
export class TableData {
  columns: string[] = [];
  rows: Array<Array<string>> = [];
  total: number = 0;
  truncated: boolean = false;
  row_count: number = 0;
}

// ========== WebSocket 事件模型 ==========

export interface WsData {
  device_id?: string;
  round_id?: string;
  request_id?: string | null;
  source?: string;
  status?: string;
  stop_reason?: string;
  command?: CommandResult;
  content?: string;
  name?: string;
  arguments?: string;
  result?: string;
  text?: string;
  platform?: string;
  error?: string;
  prompt_tokens?: number;
  completion_tokens?: number;
  total_tokens?: number;
  cached_tokens?: number;
  agent_name?: string;
  show_reasoning?: boolean;
  split_messages?: boolean;
  has_password?: boolean;
}

export interface WsEvent {
  type: string;
  data: WsData;
  round?: RoundMeta;
  chat_instance?: string;
  chat_seq?: number;
}

export interface ChatInput { content: string; platform: string; images?: MsgImage[] | null; }
export interface ActiveChatRound extends RoundMeta {
  phase: string; stopping: boolean; created_time: number; input: ChatInput | null;
}
export interface ChatSnapshot extends HistoryResult {
  instance_id: string; seq: number; rounds: ActiveChatRound[]; events: WsEvent[]; finished: RoundResult[];
}
export interface ChatStopTarget { round_id?: string; request_id?: string; }
export interface ChatStopResult extends ChatStopTarget { accepted: boolean; state: string; }

// 鉴权失败
export class UnauthorizedError extends Error {
  constructor() {
    super('unauthorized');
  }
}

// 编辑对话框字段定义
export class FieldDef {
  key: string = '';
  label: string = '';
  type: string = 'text';
  options: string[] = [];
  value: string = '';
  placeholder: string = '';
}

// ========== 聊天状态模型 ==========

@Observed
export class ToolCallItem {
  name: string = '';
  arguments: string = '';
  result: string = '';
  hasResult: boolean = false;
}

@Observed
export class MsgGroup {
  key: number = 0;
  time: number = 0;
  reasoning: string = '';
  tools: ToolCallItem[] = [];
  bubbles: Bubble[] = [];
  reasoningOpen: boolean = false;
  toolsOpen: boolean = false;
  isError: boolean = false;
  errorText: string = '';
  roundId: string = '';
  requestId: string = '';
  receiving: boolean = false;
  unconfirmed: boolean = false;
  interrupted: boolean = false;
}

export class UserMsg {
  text: string = '';
  time: number = 0;
  images: MsgImage[] = [];
  platform: string = 'harmony';
}

// 待发附件：picker 本地 URI 先行渲染，上传完成后回填 localId
export class PendingImage {
  uri: string = '';
  localId: string = '';
  filename: string = '';
  mime: string = '';
  uploading: boolean = false;
}

// 页面销毁重建时仍保留草稿，上传回调也继续写入同一个对象。
@Observed
export class ChatDraft {
  text: string = '';
  pending: PendingImage[] = [];
}

export const chatDraft: ChatDraft = new ChatDraft();

export class SystemMsg {
  text: string = '';
}

export class ChatRow {
  private static nextKey: number = 1;
  key: number = 0;
  kind: string = '';
  user: UserMsg | null = null;
  system: SystemMsg | null = null;
  group: MsgGroup | null = null;
  archiveId: number = 0;
  roundId: string = '';

  constructor() {
    this.key = ChatRow.nextKey;
    ChatRow.nextKey = ChatRow.nextKey + 1;
  }
}

@Observed
export class ChatStore {
  rows: ChatRow[] = [];
  sending: boolean = false;
  activeSendKey: number = 0;
  activeRequestId: string = '';
  pendingCommand: CommandResult | null = null;
  commandAttachments: PendingImage[] = [];
  commandDraft: ChatDraft = chatDraft;
  private completedRequests: string[] = [];
  private unconfirmedRequestId: string = '';
  typing: boolean = false;
  usageLine: string = '';
  revision: number = 0;
  receiving: boolean = false;
  activeRound: ActiveChatRound | null = null;
  stopping: boolean = false;
  finishing: boolean = false;
  syncing: boolean = false;
  syncError: string = '';
  syncHasMore: boolean = false;
  private _nextKey: number = 1;

  hasUnconfirmedRequest(): boolean { return !!this.activeRequestId && this.unconfirmedRequestId === this.activeRequestId; }

  stopTarget(): ChatStopTarget | null {
    if (this.sending && this.activeRequestId) {
      const group = this.rows.find((row: ChatRow) => row.group?.requestId === this.activeRequestId)?.group;
      const roundId = this.activeRound?.request_id === this.activeRequestId ? this.activeRound.round_id : group?.roundId;
      return roundId ? { round_id: roundId, request_id: this.activeRequestId } : { request_id: this.activeRequestId };
    }
    if (this.activeRound !== null) {
      return this.activeRound.request_id ? { round_id: this.activeRound.round_id, request_id: this.activeRound.request_id } :
        { round_id: this.activeRound.round_id };
    }
    return null;
  }

  private ensureGroup(round?: RoundMeta): MsgGroup {
    if (round !== undefined) {
      for (const row of this.rows) {
        if (row.group !== null && (row.group.roundId === round.round_id ||
          (round.request_id !== null && row.group.requestId === round.request_id))) {
          row.group.roundId = round.round_id;
          return row.group;
        }
      }
    }
    let last: ChatRow | null = null;
    if (this.rows.length > 0) {
      last = this.rows[this.rows.length - 1];
    }
    if (last !== null && last.kind === 'group' && last.group !== null &&
      (round === undefined || last.group.roundId === round.round_id)) {
      return last.group;
    }
    const g = new MsgGroup();
    g.key = this._nextKey;
    this._nextKey = this._nextKey + 1;
    g.time = Date.now() / 1000;
    if (round !== undefined) {
      g.roundId = round.round_id;
      g.requestId = round.request_id ?? '';
    }
    const row = new ChatRow();
    row.kind = 'group';
    row.group = g;
    this.rows = this.rows.concat([row]);
    this.revision = this.revision + 1;
    return g;
  }

  addUser(text: string, ts: number, images: MsgImage[] = [], platform: string = 'harmony'): void {
    const row = new ChatRow();
    row.kind = 'user';
    const u = new UserMsg();
    u.text = text;
    u.time = ts;
    u.images = images;
    u.platform = platform;
    row.user = u;
    this.rows = this.rows.concat([row]);
    this.revision = this.revision + 1;
  }

  addSystem(text: string): void {
    const row = new ChatRow();
    row.kind = 'system';
    const s = new SystemMsg();
    s.text = text;
    row.system = s;
    this.rows = this.rows.concat([row]);
    this.revision = this.revision + 1;
  }

  addError(text: string): void {
    this.revision = this.revision + 1;
    const g = this.ensureGroup();
    g.isError = true;
    g.errorText = text;
    this.sending = false;
    this.typing = false;
    this.receiving = false;
  }

  resetGroup(): void {
    // 追加一行空 group，后续 WS 事件写入该组
    const g = this.ensureGroup();
    g.requestId = this.activeRequestId;
  }

  clear(): void {
    this.revision = this.revision + 1;
    this.rows = [];
    this.sending = false;
    this.typing = false;
    this.usageLine = '';
    this.receiving = false;
    this.activeRequestId = '';
    this.activeRound = null; this.stopping = false; this.finishing = false;
    this.syncing = false; this.syncError = '';
  }

  replaceHistory(rows: ChatRow[], expectedRevision: number): boolean {
    // 请求期间收到实时消息或发起新一轮时，旧历史快照不能覆盖内存中的新内容。
    if (this.revision !== expectedRevision || this.sending || this.receiving) {
      return false;
    }
    this.rows = rows;
    this.revision = this.revision + 1;
    return true;
  }

  // 剥离尾部换行/空白。流式分段协议中边界切片含段尾空行（segments.py 边界定义含 \n\n），
  // WebUI 因 HTML 折叠尾部空白不可见，ArkUI Text 会真实渲染，故在段收口时裁剪对齐历史 strip 行为
  private rtrim(s: string): string {
    let end = s.length;
    while (end > 0) {
      const c = s.charAt(end - 1);
      if (c === '\n' || c === '\r' || c === ' ' || c === '\t') {
        end--;
      } else {
        break;
      }
    }
    return s.substring(0, end);
  }

  private closeGroup(g: MsgGroup): void {
    for (const b of g.bubbles) {
      b.text = this.rtrim(b.text);
      b.streaming = false;
    }
    g.receiving = false;
    this.receiving = this.rows.some((r: ChatRow) => r.group !== null && r.group.receiving);
  }

  finishRequest(round: RoundResult, command?: CommandResult): boolean {
    const id = round.request_id ?? '';
    if (id.length === 0 || id !== this.activeRequestId ||
      this.completedRequests.includes(id) && this.unconfirmedRequestId !== id) {
      return false;
    }
    this.completedRequests = this.completedRequests.filter((old: string) => old !== id).concat([id]).slice(-100);
    this.unconfirmedRequestId = round.status === 'unconfirmed' ? id : '';
    for (const row of this.rows) {
      if (row.group !== null && row.group.requestId === id) {
        this.closeGroup(row.group);
        if (round.status === 'cancelled') {
          row.group.interrupted = true; row.group.isError = false; row.group.errorText = ''; row.group.unconfirmed = false;
        } else if (round.status !== 'completed') {
          row.group.isError = true;
          row.group.unconfirmed = round.status === 'unconfirmed';
          row.group.errorText = round.error || '本轮' + round.status + '，请核对结果后再发送';
        } else if (row.group.unconfirmed) {
          row.group.isError = false;
          row.group.errorText = '';
          row.group.unconfirmed = false;
        }
      }
    }
    this.sending = false;
    this.typing = false;
    this.stopping = false; this.finishing = false;
    if (this.activeRound?.round_id === round.round_id) { this.activeRound = null; }
    const result = command ?? round.command;
    if (result !== undefined) {
      this.pendingCommand = result;
      const restored = this.commandAttachments.concat(this.commandDraft.pending);
      this.commandDraft.pending = restored.filter((p: PendingImage, i: number) => restored.indexOf(p) === i).slice(0, 10);
      this.rows = this.rows.filter((r: ChatRow) => r.group === null || r.group.requestId !== id ||
        r.group.bubbles.length > 0 || r.group.tools.length > 0 || r.group.reasoning.length > 0);
    }
    if (round.status !== 'unconfirmed') { this.commandAttachments = []; }
    this.revision++;
    return true;
  }

  failRequest(requestId: string, message: string): void {
    if (requestId !== this.activeRequestId || this.completedRequests.includes(requestId)) {
      return;
    }
    this.finishRequest({ round_id: '', request_id: requestId, source: 'user', platform: 'harmony',
      status: 'unconfirmed', stop_reason: 'network', error: message + '（结果未确认，请勿自动重发）' });
  }

  handleWs(evt: WsEvent): void {
    // HTTP 兜底已收尾的本机请求不能被迟到的增量重新打开，也不能重复追加到归档。
    if (evt.type !== 'round_finished' && evt.round?.request_id && this.completedRequests.includes(evt.round.request_id)) {
      return;
    }
    this.revision = this.revision + 1;
    if (evt.type === 'round_finished') {
      const d = evt.data;
      const terminal: RoundResult = { round_id: d.round_id ?? '', request_id: d.request_id ?? null,
        source: d.source ?? '', platform: d.platform ?? '', status: d.status ?? '',
        stop_reason: d.stop_reason ?? '', error: d.error ?? null, command: d.command };
      this.finishRequest(terminal);
      if (this.activeRound?.round_id === terminal.round_id) {
        this.activeRound = null; this.stopping = false; this.finishing = false;
      }
      for (const row of this.rows) {
        if (row.group !== null && (row.group.roundId === terminal.round_id ||
          terminal.request_id !== null && row.group.requestId === terminal.request_id)) {
          this.closeGroup(row.group);
          if (terminal.status === 'cancelled') {
            row.group.interrupted = true; row.group.isError = false; row.group.errorText = ''; row.group.unconfirmed = false;
          } else if (terminal.status === 'failed') {
            row.group.isError = true;
            row.group.errorText = terminal.error ?? terminal.status;
            row.group.unconfirmed = false;
          } else if (terminal.status === 'completed' && row.group.unconfirmed) {
            row.group.isError = false;
            row.group.errorText = '';
            row.group.unconfirmed = false;
          }
        }
      }
      return;
    }
    if (evt.round !== undefined && ['thinking', 'thinking_delta', 'text', 'text_delta', 'message_delta',
      'message', 'tool_call', 'tool_result'].includes(evt.type)) {
      if (this.activeRound?.round_id !== evt.round.round_id) {
        this.activeRound = { round_id: evt.round.round_id, request_id: evt.round.request_id,
          source: evt.round.source, platform: evt.round.platform, phase: 'running', stopping: false,
          created_time: Date.now() / 1000, input: null };
      }
    }
    if (evt.type === 'thinking' || evt.type === 'thinking_delta' || evt.type === 'text' ||
      evt.type === 'text_delta' || evt.type === 'message_delta' || evt.type === 'tool_call' ||
      evt.type === 'tool_result') {
      const group = this.ensureGroup(evt.round);
      group.receiving = true;
      this.receiving = true;
    }
    const d = evt.data;
    if (evt.type === 'thinking' || evt.type === 'thinking_delta') {
      const g = this.ensureGroup(evt.round);
      g.reasoning = g.reasoning + (d.content ?? '');
    } else if (evt.type === 'text' || evt.type === 'text_delta') {
      // 兼容兜底：后端针对 web/harmony 平台已不再推送 text/text_delta，
      // 若收到则直接作为正式消息气泡展示
      const g = this.ensureGroup(evt.round);
      const b = new Bubble();
      b.text = d.content ?? '';
      b.platform = d.platform ?? 'web';
      b.streaming = false;
      g.bubbles = g.bubbles.concat([b]);
      g.time = Date.now() / 1000;
    } else if (evt.type === 'message_delta') {
      const g = this.ensureGroup(evt.round);
      let last: Bubble | null = null;
      if (g.bubbles.length > 0) {
        last = g.bubbles[g.bubbles.length - 1];
      }
      if (last === null || !last.streaming) {
        const b = new Bubble();
        b.text = '';
        b.platform = d.platform ?? 'web';
        b.streaming = true;
        g.bubbles = g.bubbles.concat([b]);
        last = b;
      }
      last.text = last.text + (d.text ?? '');
      g.time = Date.now() / 1000;
    } else if (evt.type === 'tool_call') {
      const g = this.ensureGroup(evt.round);
      // 普通工具同样划定模型输出边界。
      for (const bubble of g.bubbles) {
        if (bubble.streaming) { bubble.text = this.rtrim(bubble.text); bubble.streaming = false; }
      }
      const t = new ToolCallItem();
      t.name = d.name ?? '';
      t.arguments = d.arguments ?? '';
      g.tools = g.tools.concat([t]);
    } else if (evt.type === 'tool_result') {
      const g = this.ensureGroup(evt.round);
      const name = d.name ?? '';
      let found: boolean = false;
      let idx: number = g.tools.length - 1;
      while (idx >= 0 && !found) {
        if (g.tools[idx].name === name && !g.tools[idx].hasResult) {
          g.tools[idx].result = d.result ?? '';
          g.tools[idx].hasResult = true;
          found = true;
        }
        idx = idx - 1;
      }
      if (!found) {
        const t = new ToolCallItem();
        t.name = name;
        t.result = d.result ?? '';
        t.hasResult = true;
        g.tools = g.tools.concat([t]);
      }
    } else if (evt.type === 'message_seg_end') {
      // 分段边界：裸事件无 data；关闭当前流式气泡，下一个 message_delta 自动开新泡（与 webui 一致）
      const g = this.ensureGroup(evt.round);
      let lastSeg: Bubble | null = null;
      if (g.bubbles.length > 0) {
        lastSeg = g.bubbles[g.bubbles.length - 1];
      }
      if (lastSeg !== null && lastSeg.streaming) {
        // 边界切片自带段尾空行，收口时裁剪，避免气泡底部多出空行
        lastSeg.text = this.rtrim(lastSeg.text);
        lastSeg.streaming = false;
      }
    } else if (evt.type === 'message') {
      const g = this.ensureGroup(evt.round);
      const b = new Bubble();
      b.text = d.text ?? '';
      b.platform = d.platform ?? '';
      g.bubbles = g.bubbles.concat([b]);
      g.time = Date.now() / 1000;
    } else if (evt.type === 'final') {
      const g = this.ensureGroup(evt.round);
      this.closeGroup(g);
      if (evt.round !== undefined && evt.round.request_id === this.activeRequestId) {
        this.typing = false;
        this.finishing = true;
      }
      if (this.activeRound !== null && this.activeRound.round_id === evt.round?.round_id) {
        this.activeRound.phase = 'finishing';
      }
    } else if (evt.type === 'usage') {
      const p: number = d.prompt_tokens ?? 0;
      const c: number = d.completion_tokens ?? 0;
      const t: number = d.total_tokens ?? 0;
      let line = 'Token 输入 ' + p.toString() + ' · 输出 ' + c.toString() + ' · 总计 ' + t.toString();
      const ca: number = d.cached_tokens ?? 0;
      if (ca > 0) {
        line = line + ' · 缓存 ' + ca.toString();
      }
      this.usageLine = line;
    } else if (evt.type === 'error') {
      const g = this.ensureGroup(evt.round);
      g.isError = true;
      g.errorText = d.error ?? '未知错误';
      this.closeGroup(g);
    }
  }
}

export const chatStore: ChatStore = new ChatStore();

@Observed
export class TerminalStore {
  entries: TerminalEntry[] = [];

  append(content: string): void {
    this.entries = this.entries.concat([{ ts: Date.now() / 1000, content: content }]);
  }

  setHistory(entries: TerminalEntry[]): void {
    this.entries = entries;
  }

  clear(): void {
    this.entries = [];
  }
}

export const terminalStore: TerminalStore = new TerminalStore();
