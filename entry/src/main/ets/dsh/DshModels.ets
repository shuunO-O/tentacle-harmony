/**
 * DSH 原生编码台核心领域模型与纯函数投影层（零 UI / 零网络依赖，可直接在 Node 隔离单测）
 *
 * 职责边界：
 * - 线协议 RPC 信封编解码（含 multipart/form-data 兼容）与参数构造
 * - 对话视图严格降噪（结构化白名单 + 系统注入标签剥离）
 * - 轨迹视图全量事件聚合（轮次 / 步骤 / 耗时占比 / Token / TTFT / TPS）
 * - 工作区 / 会话分组、模型目录、指令目录、队列与审批/提问负载投影
 */

export type JsonBag = Record<string, Object>;

// ───────────────────────── 基础数据模型 ─────────────────────────

export interface DshWorkspace {
  workspaceId: string;
  path: string;
  title: string;
  sessionIds: string[];
  createdAt: string;
  updatedAt: string;
}

export interface DshModelSelection {
  provider: string;
  model: string;
  reasoningEffort: string;
}

export interface DshSession {
  sessionId: string;
  title: string;
  titleFromHost: boolean;
  cwd: string;
  updatedAt: number;
  running: boolean;
  blank: boolean;
  parentSessionId: string;
  origin: string;
  asOfSeq: number;
  modelSelection?: DshModelSelection;
  planActive: boolean;
  planPending: boolean;
}

export interface DshWorkspaceGroup {
  key: string;
  workspaceId: string;
  path: string;
  title: string;
  sessions: DshSession[];
}

export interface DshWorkspaceBaseline {
  workspaces: DshWorkspace[];
  archivedSessionIds: string[];
  pinnedSessionIds: string[];
}

export interface DshPinnedSessionEntry {
  session: DshSession;
  workspaceTitle: string;
  workspacePath: string;
}

export interface DshSessionSearchItem {
  sessionId: string;
  snippet: string;
}

export interface DshSessionSearchResult {
  items: DshSessionSearchItem[];
  hasMore: boolean;
}

export interface DshDirectoryEntry {
  name: string;
  path: string;
  hidden: boolean;
}

export interface DshDirectoryListing {
  path: string;
  home: string;
  crumbs: DshDirectoryEntry[];
  entries: DshDirectoryEntry[];
  truncated: boolean;
}

export interface DshModelOption {
  provider: string;
  providerName: string;
  modelId: string;
  modelName: string;
  description: string;
  efforts: string[];
  defaultEffort: string;
}

export interface DshModelGroup {
  id: string;
  name: string;
  models: DshModelOption[];
}

export interface DshModelCatalogResult {
  defaultSelection?: DshModelSelection;
  groups: DshModelGroup[];
  flatModels: DshModelOption[];
}

export interface DshCommandCandidate {
  name: string;
  hint: string;
  description: string;
}

export interface DshReferenceCandidate {
  path: string;
  isDir: boolean;
  insert: string;
}

export interface DshUploadedFile {
  receiptId: string;
  attachmentId: string;
  name: string;
  bytes: number;
}

export interface DshPendingAttachment {
  id: string;
  name: string;
  isImage: boolean;
  mediaType: string;
  dataBase64: string;
  receiptId: string;
  bytes: number;
  uploading: boolean;
  error: string;
}

export interface DshQueuedItem {
  id: string;
  placement: string;
  rpcId: string;
  text: string;
}

export interface DshChoiceOption {
  label: string;
  description: string;
}

export interface DshQuestionSpec {
  id: string;
  question: string;
  detail: string;
  header: string;
  multiSelect: boolean;
  options: DshChoiceOption[];
  approveLabel: string;
}

export interface DshPendingPrompt {
  id: string;
  eventId: string;
  kind: string; // 'approval' | 'question'
  agentId: string;
  title: string;
  detail: string;
  toolName: string;
  callId: string;
  reason: string;
  questions: DshQuestionSpec[];
  resolvedText: string;
}

export interface DshConvEntry {
  id: string;
  seq: number;
  at: number;
  kind: string; // 'user' | 'assistant' | 'reasoning' | 'tool' | 'status' | 'error'
  text: string;
  title: string;
  detail: string;
  toolName: string;
  callId: string;
  toolState: string; // 'running' | 'success' | 'failed'
  toolArgs: string;
  toolOutput: string;
  model: string;
  durationMs: number;
  streaming: boolean;
  attachmentLabels: string[];
}

export interface DshTrajectoryStep {
  id: string;
  seq: number;
  turnNumber: number;
  stepNumber: number;
  kind: string; // 'thinking' | 'tool' | 'text' | 'user' | 'compaction' | 'audit' | 'command' | 'error' | 'system'
  label: string;
  summary: string;
  previewText: string;
  rawJson: string;
  at: number;
  durationMs: number;
  tokensIn: number;
  tokensOut: number;
  tokensCacheRead: number;
  model: string;
  isError: boolean;
}

export interface DshTrajectoryTurn {
  id: string;
  turnNumber: number;
  title: string;
  at: number;
  durationMs: number;
  thinkingMs: number;
  toolMs: number;
  textMs: number;
  endReason: string;
  steps: DshTrajectoryStep[];
}

export interface DshTrajectoryStats {
  turns: number;
  steps: number;
  totalMs: number;
  thinkingMs: number;
  toolMs: number;
  llmMs: number;
  ttftMs: number;
  ttftSteps: number;
  decodeMs: number;
  decodeTokens: number;
  tps: number;
  uncachedInputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
}

export interface DshLiveBlock {
  index: number;
  blockType: string;
  text: string;
  callId: string;
  toolName: string;
  toolArgs: string;
}

export interface DshLiveAttempt {
  active: boolean;
  attemptId: string;
  turn: number;
  step: number;
  startedAt: number;
  blocks: DshLiveBlock[];
}

export interface DshProjectedSession {
  conversation: DshConvEntry[];
  turns: DshTrajectoryTurn[];
  stats: DshTrajectoryStats;
  title: string;
  hasTitle: boolean;
  planActive: boolean;
  planPending: boolean;
  modelSelection?: DshModelSelection;
  agentPreset: string;
  cursor: number;
  maxImagesPerMessage: number;
  maxImageBytes: number;
}

export interface DshRpcErrorInfo {
  code: string;
  message: string;
  details: string;
}

export interface DshRpcOutcome {
  ok: boolean;
  value?: Object;
  hasValue: boolean;
  error?: DshRpcErrorInfo;
}

export interface DshRawRecord {
  seq: number;
  time: number;
  type: string;
  raw: Object;
}

// ───────────────────────── JSON 安全取值助手 ─────────────────────────

export function emptyBag(): JsonBag {
  const bag: JsonBag = {};
  return bag;
}

export function isPlainObject(v: Object | undefined | null): boolean {
  return v !== undefined && v !== null && typeof v === 'object' && !Array.isArray(v);
}

export function asRecord(v: Object | undefined | null): JsonBag | undefined {
  if (!isPlainObject(v)) {
    return undefined;
  }
  return v as JsonBag;
}

export function jsonField(obj: Object | undefined | null, key: string): Object | undefined {
  const rec = asRecord(obj);
  if (rec === undefined) {
    return undefined;
  }
  return rec[key];
}

export function jsonStr(obj: Object | undefined | null, key: string, fallback: string = ''): string {
  const v = jsonField(obj, key);
  return typeof v === 'string' ? v as string : fallback;
}

export function jsonOptStr(obj: Object | undefined | null, key: string): string | undefined {
  const v = jsonField(obj, key);
  return typeof v === 'string' ? v as string : undefined;
}

export function jsonNum(obj: Object | undefined | null, key: string, fallback: number = 0): number {
  const v = jsonField(obj, key);
  if (typeof v === 'number' && Number.isFinite(v as number)) {
    return v as number;
  }
  return fallback;
}

export function jsonOptNum(obj: Object | undefined | null, key: string): number | undefined {
  const v = jsonField(obj, key);
  if (typeof v === 'number' && Number.isFinite(v as number)) {
    return v as number;
  }
  return undefined;
}

export function jsonBool(obj: Object | undefined | null, key: string, fallback: boolean = false): boolean {
  const v = jsonField(obj, key);
  return typeof v === 'boolean' ? v as boolean : fallback;
}

export function jsonOptBool(obj: Object | undefined | null, key: string): boolean | undefined {
  const v = jsonField(obj, key);
  return typeof v === 'boolean' ? v as boolean : undefined;
}

export function jsonArr(obj: Object | undefined | null, key: string): Object[] {
  const v = jsonField(obj, key);
  return Array.isArray(v) ? v as Object[] : [];
}

export function jsonOptArr(obj: Object | undefined | null, key: string): Object[] | undefined {
  const v = jsonField(obj, key);
  return Array.isArray(v) ? v as Object[] : undefined;
}

export function jsonRec(obj: Object | undefined | null, key: string): JsonBag | undefined {
  return asRecord(jsonField(obj, key));
}

export function jsonStrArr(obj: Object | undefined | null, key: string): string[] {
  const raw = jsonArr(obj, key);
  const out: string[] = [];
  for (let i = 0; i < raw.length; i++) {
    if (typeof raw[i] === 'string') {
      out.push(raw[i] as string);
    }
  }
  return out;
}

export function parseJsonSafe(text: string): Object | undefined {
  if (text.length === 0) {
    return undefined;
  }
  try {
    return JSON.parse(text) as Object;
  } catch (_) {
    return undefined;
  }
}

export function firstNonEmptyStr(obj: Object | undefined | null, keys: string[]): string {
  for (let i = 0; i < keys.length; i++) {
    const val = jsonOptStr(obj, keys[i]);
    if (val !== undefined && val.length > 0) {
      return val;
    }
  }
  return '';
}

export function stringifyPretty(obj: Object | undefined | null, maxLen: number = 12000): string {
  if (obj === undefined || obj === null) {
    return '';
  }
  try {
    const s = JSON.stringify(obj, null, 2);
    if (s.length <= maxLen) {
      return s;
    }
    return s.substring(0, maxLen) + '\n... (已截断)';
  } catch (_) {
    return '';
  }
}

// ───────────────────────── RPC 信封编解码 ─────────────────────────

export function isAsciiText(text: string): boolean {
  for (let i = 0; i < text.length; i++) {
    if (text.charCodeAt(i) > 0x7f) {
      return false;
    }
  }
  return true;
}

export function buildRpcPacket(rpcId: string, method: string, args: Object): string {
  const payload: JsonBag = { 'args': args };
  const packet: JsonBag = {
    'type': 'client-request',
    'rpcId': rpcId,
    'method': method,
    'payload': payload
  };
  return JSON.stringify(packet);
}

export function decodeMultipartMetadataText(contentType: string, bodyText: string): string {
  const lower = contentType.toLowerCase();
  if (lower.indexOf('multipart/form-data') < 0) {
    return bodyText;
  }
  const m = /boundary=(?:"([^"]+)"|([^;\s]+))/i.exec(contentType);
  if (m === null) {
    return bodyText;
  }
  const boundary = m[1] !== undefined && m[1].length > 0 ? m[1] : (m[2] ?? '');
  if (boundary.length === 0) {
    return bodyText;
  }
  const parts = bodyText.split('--' + boundary);
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i];
    if (part.indexOf('name="metadata"') < 0 && part.indexOf("name='metadata'") < 0) {
      continue;
    }
    let sep = part.indexOf('\r\n\r\n');
    let offset = 4;
    if (sep < 0) {
      sep = part.indexOf('\n\n');
      offset = 2;
    }
    if (sep >= 0) {
      let content = part.substring(sep + offset);
      if (content.endsWith('\r\n')) {
        content = content.substring(0, content.length - 2);
      } else if (content.endsWith('\n')) {
        content = content.substring(0, content.length - 1);
      }
      return content.trim();
    }
  }
  return bodyText;
}

export function parseRpcResponse(bodyText: string, expectedRpcId: string, endpoint: string,
  contentType: string = ''): DshRpcOutcome {
  const raw = decodeMultipartMetadataText(contentType, bodyText);
  const parsed = parseJsonSafe(raw);
  if (parsed === undefined || !isPlainObject(parsed)) {
    return {
      ok: false,
      hasValue: false,
      error: { code: 'carrier/parse', message: endpoint + ' 响应非有效 JSON', details: raw.substring(0, 120) }
    };
  }
  const type = jsonStr(parsed, 'type');
  if (type !== 'server-response') {
    return {
      ok: false,
      hasValue: false,
      error: { code: 'carrier/parse', message: endpoint + ' 响应信封类型异常', details: type }
    };
  }
  const rpcId = jsonStr(parsed, 'rpcId');
  if (expectedRpcId.length > 0 && rpcId !== expectedRpcId) {
    return {
      ok: false,
      hasValue: false,
      error: { code: 'carrier/parse', message: endpoint + ' rpcId 不匹配', details: rpcId }
    };
  }
  const result = jsonRec(parsed, 'result');
  if (result === undefined) {
    return {
      ok: false,
      hasValue: false,
      error: { code: 'carrier/parse', message: endpoint + ' 缺少 result 字段', details: '' }
    };
  }
  const okVal = jsonField(result, 'ok');
  if (okVal === true) {
    const keys = Object.keys(result);
    const hasValue = keys.indexOf('value') >= 0;
    return {
      ok: true,
      hasValue: hasValue,
      value: hasValue ? result['value'] : undefined
    };
  }
  const errObj = jsonRec(result, 'error');
  const code = errObj !== undefined ? jsonStr(errObj, 'code', 'rpc/error') : 'rpc/error';
  const msg = errObj !== undefined ? jsonStr(errObj, 'message', endpoint + ' 调用失败') : endpoint + ' 调用失败';
  const detObj = errObj !== undefined ? jsonRec(errObj, 'details') : undefined;
  return {
    ok: false,
    hasValue: false,
    error: {
      code: code,
      message: msg,
      details: detObj !== undefined ? JSON.stringify(detObj) : ''
    }
  };
}

// ───────────────────────── 工作区与会话投影 ─────────────────────────

export function cwdBasename(cwd: string): string {
  let end = cwd.length;
  while (end > 0 && (cwd.charAt(end - 1) === '/' || cwd.charAt(end - 1) === '\\')) {
    end -= 1;
  }
  let start = end;
  while (start > 0 && cwd.charAt(start - 1) !== '/' && cwd.charAt(start - 1) !== '\\') {
    start -= 1;
  }
  return cwd.substring(start, end);
}

export function normalizePathKey(p: string): string {
  let s = p.trim().replace(/\\/g, '/');
  while (s.length > 1 && s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

export function parseModelSelection(raw: Object | undefined): DshModelSelection | undefined {
  if (raw === undefined || !isPlainObject(raw)) {
    return undefined;
  }
  const provider = jsonStr(raw, 'provider');
  const model = firstNonEmptyStr(raw, ['model', 'modelId']);
  if (provider.length === 0 || model.length === 0) {
    return undefined;
  }
  const effort = firstNonEmptyStr(raw, ['reasoningEffort', 'effort']);
  return { provider: provider, model: model, reasoningEffort: effort };
}

export function parseWorkspaceView(raw: Object | undefined): DshWorkspace | undefined {
  if (raw === undefined || !isPlainObject(raw)) {
    return undefined;
  }
  const id = jsonStr(raw, 'workspaceId');
  const path = jsonStr(raw, 'path');
  if (id.length === 0 && path.length === 0) {
    return undefined;
  }
  const rawTitle = jsonStr(raw, 'title');
  const title = rawTitle.length > 0 ? rawTitle : (cwdBasename(path) || path);
  return {
    workspaceId: id,
    path: path,
    title: title,
    sessionIds: jsonStrArr(raw, 'sessionIds'),
    createdAt: jsonStr(raw, 'createdAt'),
    updatedAt: jsonStr(raw, 'updatedAt')
  };
}

export function parseWorkspaceBaseline(value: Object | undefined): DshWorkspaceBaseline {
  const items = jsonArr(value, 'items');
  const workspaces: DshWorkspace[] = [];
  for (let i = 0; i < items.length; i++) {
    const ws = parseWorkspaceView(items[i]);
    if (ws !== undefined) {
      workspaces.push(ws);
    }
  }
  return {
    workspaces: workspaces,
    archivedSessionIds: jsonStrArr(value, 'archivedSessionIds'),
    pinnedSessionIds: jsonStrArr(value, 'pinnedSessionIds')
  };
}

export function parseSessionSearchResult(value: Object | undefined): DshSessionSearchResult {
  const rawItems = jsonArr(value, 'items');
  const items: DshSessionSearchItem[] = [];
  for (let i = 0; i < rawItems.length; i++) {
    const it = rawItems[i];
    if (!isPlainObject(it)) {
      continue;
    }
    const sid = jsonStr(it, 'sessionId');
    if (sid.length === 0) {
      continue;
    }
    items.push({
      sessionId: sid,
      snippet: jsonStr(it, 'snippet')
    });
  }
  return {
    items: items,
    hasMore: jsonBool(value, 'hasMore')
  };
}

export function parseSessionSummary(item: Object | undefined): DshSession | undefined {
  if (item === undefined || !isPlainObject(item)) {
    return undefined;
  }
  const sessionId = jsonStr(item, 'sessionId');
  if (sessionId.length === 0) {
    return undefined;
  }
  const cwd = jsonStr(item, 'cwd');
  const projections = jsonRec(item, 'projections');
  const asOfSeq = projections !== undefined ? jsonNum(projections, 'asOfSeq', -1) : -1;
  const values = projections !== undefined ? jsonRec(projections, 'values') : undefined;
  const hostTitle = values !== undefined ? jsonOptStr(values, 'title') : undefined;
  const titleFromHost = hostTitle !== undefined && hostTitle.length > 0;
  const fallbackName = cwdBasename(cwd);
  const title = titleFromHost ? hostTitle : (fallbackName.length > 0 ? fallbackName : sessionId.substring(0, 8));

  let modelSelection: DshModelSelection | undefined = undefined;
  const msRec = values !== undefined ? jsonRec(values, 'modelSelection') : undefined;
  if (msRec !== undefined) {
    modelSelection = parseModelSelection(jsonField(msRec, 'next'))
      ?? parseModelSelection(jsonField(msRec, 'lastUsed'));
  }

  const planRec = values !== undefined ? jsonRec(values, 'plan') : undefined;
  const planActive = planRec !== undefined ? jsonBool(planRec, 'active') : false;
  const planPending = planRec !== undefined ? jsonBool(planRec, 'pending') : false;

  return {
    sessionId: sessionId,
    title: title,
    titleFromHost: titleFromHost,
    cwd: cwd,
    updatedAt: jsonNum(item, 'updatedAt', 0),
    running: jsonBool(item, 'running'),
    blank: jsonBool(item, 'blank'),
    parentSessionId: jsonStr(item, 'parentSessionId'),
    origin: jsonStr(item, 'origin'),
    asOfSeq: asOfSeq,
    modelSelection: modelSelection,
    planActive: planActive,
    planPending: planPending
  };
}

export function parseSessionList(value: Object | undefined): DshSession[] {
  const items = jsonArr(value, 'items');
  const out: DshSession[] = [];
  for (let i = 0; i < items.length; i++) {
    const s = parseSessionSummary(items[i]);
    if (s !== undefined) {
      out.push(s);
    }
  }
  return out;
}

export function groupSessionsByWorkspace(sessions: DshSession[], workspaces: DshWorkspace[],
  archivedIds: string[], excludeIds: string[] = []): DshWorkspaceGroup[] {
  const archivedSet: Set<string> = new Set<string>(archivedIds);
  const excludeSet: Set<string> = new Set<string>(excludeIds);
  const visibleSessions: DshSession[] = [];
  for (let i = 0; i < sessions.length; i++) {
    const s = sessions[i];
    if (s.origin === 'subagent') {
      continue;
    }
    if (archivedSet.has(s.sessionId) || excludeSet.has(s.sessionId)) {
      continue;
    }
    visibleSessions.push(s);
  }

  const byId: Map<string, DshSession> = new Map<string, DshSession>();
  for (let i = 0; i < visibleSessions.length; i++) {
    byId.set(visibleSessions[i].sessionId, visibleSessions[i]);
  }

  const assigned: Set<string> = new Set<string>();
  const groups: DshWorkspaceGroup[] = [];
  const pathToGroupIdx: Map<string, number> = new Map<string, number>();

  for (let i = 0; i < workspaces.length; i++) {
    const ws = workspaces[i];
    const groupSessions: DshSession[] = [];
    for (let j = 0; j < ws.sessionIds.length; j++) {
      const hit = byId.get(ws.sessionIds[j]);
      if (hit !== undefined && !assigned.has(hit.sessionId)) {
        assigned.add(hit.sessionId);
        groupSessions.push(hit);
      }
    }
    const norm = normalizePathKey(ws.path);
    for (let j = 0; j < visibleSessions.length; j++) {
      const s = visibleSessions[j];
      if (!assigned.has(s.sessionId) && norm.length > 0 && normalizePathKey(s.cwd) === norm) {
        assigned.add(s.sessionId);
        groupSessions.push(s);
      }
    }
    groupSessions.sort((a: DshSession, b: DshSession) => b.updatedAt - a.updatedAt);
    const idx = groups.length;
    if (norm.length > 0) {
      pathToGroupIdx.set(norm, idx);
    }
    groups.push({
      key: ws.workspaceId.length > 0 ? ws.workspaceId : ('ws:' + norm),
      workspaceId: ws.workspaceId,
      path: ws.path,
      title: ws.title,
      sessions: groupSessions
    });
  }

  for (let i = 0; i < visibleSessions.length; i++) {
    const s = visibleSessions[i];
    if (assigned.has(s.sessionId)) {
      continue;
    }
    const norm = normalizePathKey(s.cwd);
    const existingIdx = pathToGroupIdx.get(norm);
    if (existingIdx !== undefined) {
      groups[existingIdx].sessions.push(s);
      assigned.add(s.sessionId);
    } else {
      const newIdx = groups.length;
      if (norm.length > 0) {
        pathToGroupIdx.set(norm, newIdx);
      }
      assigned.add(s.sessionId);
      groups.push({
        key: norm.length > 0 ? ('cwd:' + norm) : 'default',
        workspaceId: '',
        path: s.cwd,
        title: cwdBasename(s.cwd) || '默认工作区',
        sessions: [s]
      });
    }
  }

  for (let i = 0; i < groups.length; i++) {
    groups[i].sessions.sort((a: DshSession, b: DshSession) => b.updatedAt - a.updatedAt);
  }
  return groups;
}

export function resolveSessionWorkspaceMeta(session: DshSession, workspaces: DshWorkspace[]): DshPinnedSessionEntry {
  for (let i = 0; i < workspaces.length; i++) {
    const ws = workspaces[i];
    if (ws.sessionIds.indexOf(session.sessionId) >= 0) {
      return {
        session: session,
        workspaceTitle: ws.title,
        workspacePath: ws.path
      };
    }
  }
  const norm = normalizePathKey(session.cwd);
  if (norm.length > 0) {
    for (let i = 0; i < workspaces.length; i++) {
      const ws = workspaces[i];
      if (normalizePathKey(ws.path) === norm) {
        return {
          session: session,
          workspaceTitle: ws.title,
          workspacePath: ws.path
        };
      }
    }
  }
  return {
    session: session,
    workspaceTitle: cwdBasename(session.cwd) || '默认工作区',
    workspacePath: session.cwd
  };
}

export function buildPinnedSessionEntries(sessions: DshSession[], workspaces: DshWorkspace[],
  archivedIds: string[], pinnedIds: string[]): DshPinnedSessionEntry[] {
  if (pinnedIds.length === 0) {
    return [];
  }
  const archivedSet: Set<string> = new Set<string>(archivedIds);
  const byId: Map<string, DshSession> = new Map<string, DshSession>();
  for (let i = 0; i < sessions.length; i++) {
    const s = sessions[i];
    if (s.origin === 'subagent' || archivedSet.has(s.sessionId)) {
      continue;
    }
    byId.set(s.sessionId, s);
  }
  const seen: Set<string> = new Set<string>();
  const out: DshPinnedSessionEntry[] = [];
  for (let i = 0; i < pinnedIds.length; i++) {
    const pid = pinnedIds[i];
    if (seen.has(pid)) {
      continue;
    }
    const hit = byId.get(pid);
    if (hit !== undefined) {
      seen.add(pid);
      out.push(resolveSessionWorkspaceMeta(hit, workspaces));
    }
  }
  return out;
}

export function buildArchivedSessions(sessions: DshSession[], workspaces: DshWorkspace[],
  archivedIds: string[]): DshPinnedSessionEntry[] {
  if (archivedIds.length === 0) {
    return [];
  }
  const archivedSet: Set<string> = new Set<string>(archivedIds);
  const matched: DshSession[] = [];
  for (let i = 0; i < sessions.length; i++) {
    const s = sessions[i];
    if (s.origin === 'subagent') {
      continue;
    }
    if (archivedSet.has(s.sessionId)) {
      matched.push(s);
    }
  }
  matched.sort((a: DshSession, b: DshSession) => b.updatedAt - a.updatedAt);
  const out: DshPinnedSessionEntry[] = [];
  for (let i = 0; i < matched.length; i++) {
    out.push(resolveSessionWorkspaceMeta(matched[i], workspaces));
  }
  return out;
}

export function parseDirectoryListing(value: Object | undefined): DshDirectoryListing {
  const crumbsRaw = jsonArr(value, 'crumbs');
  const entriesRaw = jsonArr(value, 'entries');
  const crumbs: DshDirectoryEntry[] = [];
  const entries: DshDirectoryEntry[] = [];
  for (let i = 0; i < crumbsRaw.length; i++) {
    const name = jsonStr(crumbsRaw[i], 'name');
    const path = jsonStr(crumbsRaw[i], 'path');
    if (path.length > 0) {
      crumbs.push({ name: name || cwdBasename(path) || '/', path: path, hidden: jsonBool(crumbsRaw[i], 'hidden') });
    }
  }
  for (let i = 0; i < entriesRaw.length; i++) {
    const name = jsonStr(entriesRaw[i], 'name');
    const path = jsonStr(entriesRaw[i], 'path');
    const hidden = jsonBool(entriesRaw[i], 'hidden');
    if (path.length > 0 && name.length > 0) {
      entries.push({ name: name, path: path, hidden: hidden });
    }
  }
  return {
    path: jsonStr(value, 'path'),
    home: jsonStr(value, 'home'),
    crumbs: crumbs,
    entries: entries,
    truncated: jsonBool(value, 'truncated')
  };
}

// ───────────────────────── 模型 / 指令 / 引用 / 附件 / 队列 / 审批 ─────────────────────────

export function parseModelCatalog(value: Object | undefined): DshModelCatalogResult {
  const groups: DshModelGroup[] = [];
  const flatModels: DshModelOption[] = [];
  const defaultSel = parseModelSelection(jsonField(value, 'default'));
  const rawGroups = jsonArr(value, 'groups');
  for (let g = 0; g < rawGroups.length; g++) {
    const grp = rawGroups[g];
    const pid = jsonStr(grp, 'id');
    const pname = jsonStr(grp, 'name', pid);
    const rawModels = jsonArr(grp, 'models');
    const groupModels: DshModelOption[] = [];
    for (let m = 0; m < rawModels.length; m++) {
      const mod = rawModels[m];
      const mid = jsonStr(mod, 'id');
      if (pid.length === 0 || mid.length === 0) {
        continue;
      }
      const reasoning = jsonRec(mod, 'reasoning');
      const efforts: string[] = [];
      let defaultEffort = '';
      if (reasoning !== undefined) {
        const effRaw = jsonArr(reasoning, 'efforts');
        for (let e = 0; e < effRaw.length; e++) {
          const eid = jsonStr(effRaw[e], 'id');
          if (eid.length > 0) {
            efforts.push(eid);
          }
        }
        defaultEffort = jsonStr(reasoning, 'defaultEffort');
      }
      const item: DshModelOption = {
        provider: pid,
        providerName: pname,
        modelId: mid,
        modelName: jsonStr(mod, 'name', mid),
        description: jsonStr(mod, 'description'),
        efforts: efforts,
        defaultEffort: defaultEffort
      };
      groupModels.push(item);
      flatModels.push(item);
    }
    if (groupModels.length > 0) {
      groups.push({ id: pid, name: pname, models: groupModels });
    }
  }
  return { defaultSelection: defaultSel, groups: groups, flatModels: flatModels };
}

export function formatModelCapsule(sel: DshModelSelection | undefined, flatModels: DshModelOption[]): string {
  if (sel === undefined || sel.model.length === 0) {
    return '选择模型';
  }
  let name = sel.model;
  for (let i = 0; i < flatModels.length; i++) {
    if (flatModels[i].provider === sel.provider && flatModels[i].modelId === sel.model) {
      name = flatModels[i].modelName || sel.model;
      break;
    }
  }
  if (sel.reasoningEffort.length > 0) {
    return name + ' · ' + sel.reasoningEffort;
  }
  return name;
}

export function parseCommandsList(value: Object | undefined): DshCommandCandidate[] {
  const list = Array.isArray(value) ? value as Object[] : jsonArr(value, 'items');
  const out: DshCommandCandidate[] = [];
  for (let i = 0; i < list.length; i++) {
    const raw = jsonStr(list[i], 'name');
    if (raw.length === 0) {
      continue;
    }
    const name = raw.startsWith('/') ? raw : '/' + raw;
    const input = jsonRec(list[i], 'input');
    out.push({
      name: name,
      hint: input !== undefined ? jsonStr(input, 'hint') : '',
      description: jsonStr(list[i], 'description')
    });
  }
  return out;
}

export function parseReferenceCandidates(value: Object | undefined): DshReferenceCandidate[] {
  const list = Array.isArray(value) ? value as Object[] : jsonArr(value, 'items');
  const out: DshReferenceCandidate[] = [];
  for (let i = 0; i < list.length; i++) {
    const path = jsonStr(list[i], 'path');
    if (path.length === 0) {
      continue;
    }
    const isDir = jsonStr(list[i], 'kind') === 'directory';
    out.push({
      path: path,
      isDir: isDir,
      insert: isDir ? ('@' + path + '/') : ('@' + path)
    });
  }
  return out;
}

export function parseFileUploadReceipt(value: Object | undefined): DshUploadedFile | undefined {
  const receiptId = jsonStr(value, 'receiptId');
  if (receiptId.length === 0) {
    return undefined;
  }
  const file = jsonRec(value, 'file');
  return {
    receiptId: receiptId,
    attachmentId: file !== undefined ? jsonStr(file, 'attachmentId') : '',
    name: file !== undefined ? jsonStr(file, 'name') : '',
    bytes: file !== undefined ? jsonNum(file, 'bytes') : 0
  };
}

export function extractBlocksText(contentRaw: Object | undefined): string {
  if (!Array.isArray(contentRaw)) {
    return typeof contentRaw === 'string' ? contentRaw as string : '';
  }
  const arr = contentRaw as Object[];
  const parts: string[] = [];
  for (let i = 0; i < arr.length; i++) {
    const b = arr[i];
    if (typeof b === 'string') {
      parts.push(b as string);
      continue;
    }
    const t = jsonStr(b, 'type');
    if (t === 'text' || t === '') {
      const txt = jsonStr(b, 'text');
      if (txt.length > 0) {
        parts.push(txt);
      }
    }
  }
  return parts.join('\n');
}

export function parseQueuedItems(rawItems: Object[] | undefined): DshQueuedItem[] {
  if (rawItems === undefined) {
    return [];
  }
  const out: DshQueuedItem[] = [];
  for (let i = 0; i < rawItems.length; i++) {
    const row = rawItems[i];
    const id = jsonStr(row, 'id');
    if (id.length === 0) {
      continue;
    }
    const msg = jsonRec(row, 'message');
    const txt = msg !== undefined ? extractBlocksText(jsonField(msg, 'content')).trim() : '';
    out.push({
      id: id,
      placement: jsonStr(row, 'placement', 'queued'),
      rpcId: jsonStr(row, 'rpcId'),
      text: txt.length > 0 ? txt : '[附件消息]'
    });
  }
  return out;
}

export function parseWaterfallPrompt(frame: Object): DshPendingPrompt | undefined {
  const event = jsonStr(frame, 'event');
  const eventId = jsonStr(frame, 'eventId');
  const agentId = jsonStr(frame, 'agentId');
  const request = jsonRec(frame, 'request');
  if (eventId.length === 0 || request === undefined) {
    return undefined;
  }
  if (event === 'approval/request') {
    const toolName = jsonStr(request, 'toolName', '未知工具');
    const reason = jsonStr(request, 'reason');
    const callId = jsonStr(request, 'callId');
    return {
      id: eventId,
      eventId: eventId,
      kind: 'approval',
      agentId: agentId,
      title: '需要授权执行：' + toolName,
      detail: reason,
      toolName: toolName,
      callId: callId,
      reason: reason,
      questions: [],
      resolvedText: ''
    };
  }
  if (event === 'user-questions/request') {
    const rawQs = jsonArr(request, 'questions');
    const questions: DshQuestionSpec[] = [];
    for (let i = 0; i < rawQs.length; i++) {
      const q = rawQs[i];
      const qid = jsonStr(q, 'id', 'q' + i.toString());
      const qText = jsonStr(q, 'question');
      const header = jsonStr(q, 'header');
      const detail = jsonStr(q, 'detail');
      const multi = jsonBool(q, 'multiSelect');
      const intent = jsonRec(q, 'intent');
      const approveLabel = intent !== undefined ? jsonStr(intent, 'approve') : '';
      const rawOpts = jsonArr(q, 'options');
      const options: DshChoiceOption[] = [];
      for (let j = 0; j < rawOpts.length; j++) {
        const lbl = jsonStr(rawOpts[j], 'label');
        if (lbl.length > 0) {
          options.push({
            label: lbl,
            description: jsonStr(rawOpts[j], 'description')
          });
        }
      }
      questions.push({
        id: qid,
        question: qText.length > 0 ? qText : (header.length > 0 ? header : '请确认'),
        detail: detail,
        header: header,
        multiSelect: multi,
        options: options,
        approveLabel: approveLabel
      });
    }
    if (questions.length === 0) {
      return undefined;
    }
    return {
      id: eventId,
      eventId: eventId,
      kind: 'question',
      agentId: agentId,
      title: questions[0].header.length > 0 ? questions[0].header : 'Agent 向你提问',
      detail: questions[0].detail,
      toolName: '',
      callId: '',
      reason: '',
      questions: questions,
      resolvedText: ''
    };
  }
  return undefined;
}

// ───────────────────────── 对话流降噪与轨迹投影引擎 ─────────────────────────

const CONVERSATION_VISIBLE_EVENTS: Set<string> = new Set<string>([
  'user/message',
  'assistant/message',
  'tool/call',
  'tool/result',
  'command/run',
  'command/done',
  'deliverables/presented',
  'subagent/catalog',
  'goal/change',
  'todo/write',
  'llm/retry',
  'api-session/error'
]);

const HIDDEN_USER_BLOCK_KINDS: Set<string> = new Set<string>([
  'agent-instructions',
  'runtime-context',
  'time-context',
  'system-reminder',
  'environment-context'
]);

export function isConversationVisibleEvent(eventType: string): boolean {
  return CONVERSATION_VISIBLE_EVENTS.has(eventType);
}

/**
 * 清理系统注入标签（<system-reminder> / <local-command-caveat> / <environment_context> 等）。
 * 仅在「对话」视图展示时调用；「轨迹」视图保留原始载荷以保证全量排查。
 */
export function sanitizeConversationText(text: string): string {
  if (text.length === 0) {
    return '';
  }
  let cleaned = text
    .replace(/<system-reminder>[\s\S]*?<\/system-reminder>/gi, '')
    .replace(/<local-command-caveat>[\s\S]*?<\/local-command-caveat>/gi, '')
    .replace(/<environment_context>[\s\S]*?<\/environment_context>/gi, '')
    .replace(/<agent-instructions>[\s\S]*?<\/agent-instructions>/gi, '')
    .replace(/<runtime-context>[\s\S]*?<\/runtime-context>/gi, '')
    .replace(/<time-context>[\s\S]*?<\/time-context>/gi, '')
    .trim();
  return cleaned;
}

interface DshSplitBlocksResult {
  text: string;
  reasoning: string;
  attachments: string[];
  toolCalls: Object[];
}

function splitContentBlocks(blocks: Object[]): DshSplitBlocksResult {
  const texts: string[] = [];
  const reasonings: string[] = [];
  const attachments: string[] = [];
  const toolCalls: Object[] = [];

  for (let i = 0; i < blocks.length; i++) {
    const b = blocks[i];
    if (typeof b === 'string') {
      texts.push(b as string);
      continue;
    }
    if (!isPlainObject(b)) {
      continue;
    }
    const bt = jsonStr(b, 'type');
    const bk = jsonStr(b, 'kind');
    if (HIDDEN_USER_BLOCK_KINDS.has(bk) || HIDDEN_USER_BLOCK_KINDS.has(bt)) {
      continue;
    }
    if (bt === 'text' || bt === '') {
      const t = jsonStr(b, 'text');
      if (t.length > 0) {
        texts.push(t);
      }
    } else if (bt === 'reasoning' || bt === 'thinking') {
      const r = firstNonEmptyStr(b, ['reasoning', 'thinking', 'text']);
      if (r.length > 0) {
        reasonings.push(r);
      }
    } else if (bt === 'image') {
      const nm = jsonStr(b, 'name');
      attachments.push(nm.length > 0 ? nm : '图片');
    } else if (bt === 'file') {
      const nm = jsonStr(b, 'name');
      attachments.push(nm.length > 0 ? nm : '文件附件');
    } else if (bt === 'tool-call' || bt === 'tool_call' || bt === 'tool-use' || bt === 'tool_use') {
      toolCalls.push(b);
    }
  }
  const result: DshSplitBlocksResult = {
    text: texts.join('\n\n'),
    reasoning: reasonings.join('\n\n'),
    attachments: attachments,
    toolCalls: toolCalls
  };
  return result;
}

function extractStreamReasoningFallback(streamArr: Object[]): string {
  const parts: string[] = [];
  for (let i = 0; i < streamArr.length; i++) {
    const item = streamArr[i];
    if (!isPlainObject(item)) {
      continue;
    }
    const st = jsonStr(item, 'type');
    if (st === 'reasoning-chunks' || st === 'reasoning') {
      const chunks = jsonArr(item, 'chunks');
      for (let j = 0; j < chunks.length; j++) {
        if (typeof chunks[j] === 'string') {
          parts.push(chunks[j] as string);
        } else {
          const t = firstNonEmptyStr(chunks[j], ['text', 'delta', 'reasoning']);
          if (t.length > 0) {
            parts.push(t);
          }
        }
      }
      const direct = firstNonEmptyStr(item, ['text', 'reasoning']);
      if (direct.length > 0) {
        parts.push(direct);
      }
    }
  }
  return parts.join('');
}

function formatToolArgsSummary(rawArgs: string): string {
  const trimmed = rawArgs.trim();
  if (trimmed.length === 0) {
    return '';
  }
  const parsed = parseJsonSafe(trimmed);
  if (parsed !== undefined && isPlainObject(parsed)) {
    const preferred = firstNonEmptyStr(parsed, ['command', 'cmd', 'path', 'file_path', 'filePath', 'pattern', 'query', 'url', 'objective']);
    if (preferred.length > 0) {
      return preferred.length > 140 ? preferred.substring(0, 140) + '…' : preferred;
    }
  }
  return trimmed.length > 140 ? trimmed.substring(0, 140) + '…' : trimmed;
}

function formatToolResultText(blocks: Object[]): string {
  const parts: string[] = [];
  for (let i = 0; i < blocks.length; i++) {
    const b = blocks[i];
    if (typeof b === 'string') {
      parts.push(b as string);
      continue;
    }
    const t = jsonStr(b, 'text');
    if (t.length > 0) {
      const trimmed = t.trim();
      const parsed = trimmed.startsWith('{') ? parseJsonSafe(trimmed) : undefined;
      if (parsed !== undefined && isPlainObject(parsed)) {
        const outStr = firstNonEmptyStr(parsed, ['output', 'stdout', 'content', 'message', 'text']);
        const errStr = firstNonEmptyStr(parsed, ['stderr', 'error']);
        if (outStr.length > 0 || errStr.length > 0) {
          parts.push([outStr, errStr].filter((s: string) => s.length > 0).join('\n'));
          continue;
        }
      }
      parts.push(t);
    }
  }
  return parts.join('\n').trim();
}

export function createEmptyLiveAttempt(): DshLiveAttempt {
  return {
    active: false,
    attemptId: '',
    turn: 0,
    step: 0,
    startedAt: 0,
    blocks: []
  };
}

export function applyAssistantStreamFrame(live: DshLiveAttempt, frame: Object): DshLiveAttempt {
  const ftype = jsonStr(frame, 'type');
  if (ftype === 'start') {
    return {
      active: true,
      attemptId: jsonStr(frame, 'attemptId'),
      turn: jsonNum(frame, 'turn', 0),
      step: jsonNum(frame, 'step', 0),
      startedAt: Date.now(),
      blocks: []
    };
  }
  if (ftype === 'end') {
    const outcome = jsonRec(frame, 'outcome');
    const okKind = outcome !== undefined ? jsonStr(outcome, 'kind') : '';
    if (okKind === 'committed' || okKind === 'abandoned') {
      return createEmptyLiveAttempt();
    }
    return live;
  }
  if (ftype !== 'chunk') {
    return live;
  }
  const chunk = jsonRec(frame, 'chunk');
  if (chunk === undefined) {
    return live;
  }
  const ctype = jsonStr(chunk, 'type');
  const idx = jsonNum(chunk, 'index', 0);
  const nextBlocks: DshLiveBlock[] = live.blocks.slice();

  let slot = -1;
  for (let i = 0; i < nextBlocks.length; i++) {
    if (nextBlocks[i].index === idx) {
      slot = i;
      break;
    }
  }

  if (ctype === 'block-start') {
    const bType = jsonStr(chunk, 'blockType', 'text');
    const created: DshLiveBlock = {
      index: idx,
      blockType: bType,
      text: '',
      callId: '',
      toolName: '',
      toolArgs: ''
    };
    if (slot >= 0) {
      nextBlocks[slot] = created;
    } else {
      nextBlocks.push(created);
    }
  } else if (ctype === 'text-delta' || ctype === 'reasoning-delta') {
    const delta = jsonStr(chunk, 'text');
    const targetType = ctype === 'reasoning-delta' ? 'reasoning' : 'text';
    if (slot < 0) {
      nextBlocks.push({ index: idx, blockType: targetType, text: delta, callId: '', toolName: '', toolArgs: '' });
    } else {
      const cur = nextBlocks[slot];
      nextBlocks[slot] = {
        index: cur.index,
        blockType: cur.blockType,
        text: cur.text + delta,
        callId: cur.callId,
        toolName: cur.toolName,
        toolArgs: cur.toolArgs
      };
    }
  } else if (ctype === 'tool-call-delta') {
    const id = jsonStr(chunk, 'id');
    const name = jsonStr(chunk, 'name');
    const argsDelta = jsonStr(chunk, 'argumentsDelta');
    if (slot < 0) {
      nextBlocks.push({ index: idx, blockType: 'tool-call', text: '', callId: id, toolName: name, toolArgs: argsDelta });
    } else {
      const cur = nextBlocks[slot];
      nextBlocks[slot] = {
        index: cur.index,
        blockType: 'tool-call',
        text: cur.text,
        callId: id.length > 0 ? id : cur.callId,
        toolName: name.length > 0 ? name : cur.toolName,
        toolArgs: cur.toolArgs + argsDelta
      };
    }
  } else if (ctype === 'block-end') {
    const finalBlock = jsonRec(chunk, 'block');
    if (finalBlock !== undefined) {
      const bt = jsonStr(finalBlock, 'type', slot >= 0 ? nextBlocks[slot].blockType : 'text');
      const txt = firstNonEmptyStr(finalBlock, ['text', 'reasoning', 'thinking']);
      const updated: DshLiveBlock = {
        index: idx,
        blockType: bt,
        text: txt.length > 0 ? txt : (slot >= 0 ? nextBlocks[slot].text : ''),
        callId: firstNonEmptyStr(finalBlock, ['callId', 'id']) || (slot >= 0 ? nextBlocks[slot].callId : ''),
        toolName: firstNonEmptyStr(finalBlock, ['name', 'toolName']) || (slot >= 0 ? nextBlocks[slot].toolName : ''),
        toolArgs: firstNonEmptyStr(finalBlock, ['arguments', 'input']) || (slot >= 0 ? nextBlocks[slot].toolArgs : '')
      };
      if (slot >= 0) {
        nextBlocks[slot] = updated;
      } else {
        nextBlocks.push(updated);
      }
    }
  }

  return {
    active: true,
    attemptId: live.attemptId,
    turn: live.turn,
    step: live.step,
    startedAt: live.startedAt > 0 ? live.startedAt : Date.now(),
    blocks: nextBlocks
  };
}

function makeConvEntry(id: string, seq: number, at: number, kind: string): DshConvEntry {
  return {
    id: id,
    seq: seq,
    at: at,
    kind: kind,
    text: '',
    title: '',
    detail: '',
    toolName: '',
    callId: '',
    toolState: 'running',
    toolArgs: '',
    toolOutput: '',
    model: '',
    durationMs: 0,
    streaming: false,
    attachmentLabels: []
  };
}

interface DshParsedUsage {
  inTokens: number;
  outTokens: number;
  cacheRead: number;
  cacheWrite: number;
}

function parseUsageTokens(usage: Object | undefined): DshParsedUsage {
  if (usage === undefined || !isPlainObject(usage)) {
    const empty: DshParsedUsage = { inTokens: 0, outTokens: 0, cacheRead: 0, cacheWrite: 0 };
    return empty;
  }
  const parsed: DshParsedUsage = {
    inTokens: jsonNum(usage, 'inputTokens', jsonNum(usage, 'uncachedInputTokens', 0)),
    outTokens: jsonNum(usage, 'outputTokens', 0),
    cacheRead: jsonNum(usage, 'cacheReadTokens', 0),
    cacheWrite: jsonNum(usage, 'cacheWriteTokens', 0)
  };
  return parsed;
}

export function projectSessionRecords(
  records: Object[],
  projections?: Object,
  live?: DshLiveAttempt,
  cursor: number = -1
): DshProjectedSession {
  const conv: DshConvEntry[] = [];
  const toolConvIndexByCallId: Map<string, number> = new Map<string, number>();
  const toolTrajStepByCallId: Map<string, DshTrajectoryStep> = new Map<string, DshTrajectoryStep>();
  const toolStartTimeByCallId: Map<string, number> = new Map<string, number>();
  const commandConvById: Map<string, DshConvEntry> = new Map<string, DshConvEntry>();

  const turns: DshTrajectoryTurn[] = [];
  let activeTurnIdx: number = -1;
  let currentStepStartAt: number = 0;
  let currentStepNum: number = 0;
  let turnSeqFallback: number = 0;

  let aggUncachedIn = 0;
  let aggOut = 0;
  let aggCacheRead = 0;
  let aggCacheWrite = 0;
  let aggThinkingMs = 0;
  let aggToolMs = 0;
  let aggTextMs = 0;
  let aggStepCount = 0;

  const ensureTurn = (turnNum: number, at: number, title: string): DshTrajectoryTurn => {
    if (activeTurnIdx >= 0 && activeTurnIdx < turns.length) {
      const existing = turns[activeTurnIdx];
      if (turnNum <= 0 || existing.turnNumber === turnNum) {
        if (title.length > 0 && existing.title.startsWith('轮次 #')) {
          existing.title = title;
        }
        return existing;
      }
    }
    const effectiveNum = turnNum > 0 ? turnNum : (++turnSeqFallback);
    const created: DshTrajectoryTurn = {
      id: 'turn-' + effectiveNum.toString() + '-' + at.toString(),
      turnNumber: effectiveNum,
      title: title.length > 0 ? title : ('轮次 #' + effectiveNum.toString()),
      at: at,
      durationMs: 0,
      thinkingMs: 0,
      toolMs: 0,
      textMs: 0,
      endReason: '',
      steps: []
    };
    activeTurnIdx = turns.length;
    turns.push(created);
    return created;
  };

  const pushStep = (turnObj: DshTrajectoryTurn, step: DshTrajectoryStep): void => {
    turnObj.steps.push(step);
    aggStepCount += 1;
    if (step.kind === 'thinking') {
      turnObj.thinkingMs += step.durationMs;
      aggThinkingMs += step.durationMs;
    } else if (step.kind === 'tool') {
      turnObj.toolMs += step.durationMs;
      aggToolMs += step.durationMs;
    } else if (step.kind === 'text') {
      turnObj.textMs += step.durationMs;
      aggTextMs += step.durationMs;
    }
    if (step.durationMs > 0) {
      turnObj.durationMs += step.durationMs;
    }
  };

  for (let i = 0; i < records.length; i++) {
    const rec = records[i];
    if (jsonStr(rec, 'type') !== 'event') {
      continue;
    }
    const ev = jsonRec(rec, 'event');
    if (ev === undefined) {
      continue;
    }
    const evType = jsonStr(ev, 'type');
    const seq = jsonNum(ev, 'seq', i);
    const time = jsonNum(ev, 'time', 0);
    const data = jsonRec(ev, 'data');

    if (evType === 'turn/start') {
      const tNum = data !== undefined ? jsonNum(data, 'turn', 0) : 0;
      if (tNum > turnSeqFallback) {
        turnSeqFallback = tNum;
      }
      activeTurnIdx = -1;
      ensureTurn(tNum, time, '');
      continue;
    }
    if (evType === 'turn/end') {
      if (activeTurnIdx >= 0 && activeTurnIdx < turns.length) {
        const endingTurn = turns[activeTurnIdx];
        const reasonObj = data !== undefined ? jsonRec(data, 'reason') : undefined;
        endingTurn.endReason = reasonObj !== undefined ? jsonStr(reasonObj, 'kind') : '';
        if (time > endingTurn.at && endingTurn.at > 0 && time - endingTurn.at > endingTurn.durationMs) {
          endingTurn.durationMs = time - endingTurn.at;
        }
      }
      activeTurnIdx = -1;
      continue;
    }
    if (evType === 'step/start') {
      currentStepStartAt = time;
      currentStepNum = data !== undefined ? jsonNum(data, 'step', currentStepNum + 1) : (currentStepNum + 1);
      continue;
    }
    if (evType === 'step/end') {
      currentStepStartAt = 0;
      continue;
    }

    if (evType === 'user/message') {
      const msgObj = data !== undefined ? jsonRec(data, 'message') : undefined;
      const blocks = (data !== undefined && jsonOptArr(data, 'content') !== undefined)
        ? jsonArr(data, 'content')
        : (msgObj !== undefined ? jsonArr(msgObj, 'content') : []);
      const srcObj = data !== undefined
        ? (jsonRec(data, 'source') ?? (msgObj !== undefined ? jsonRec(msgObj, 'source') : undefined))
        : undefined;
      const srcKind = srcObj !== undefined ? jsonStr(srcObj, 'kind') : (data !== undefined ? jsonStr(data, 'kind') : '');
      // DSH 中只有 source.kind === 'user' 属于真实用户输入；
      // 'agent-instructions' / 'runtime-context' / 'time-context' 等系统注入仅保留在轨迹视图中。
      const isHumanUser = srcObj !== undefined ? (srcKind === 'user') : (srcKind === '' || srcKind === 'user');
      const split = splitContentBlocks(blocks);
      const cleanText = sanitizeConversationText(split.text);
      const tNum = data !== undefined ? jsonNum(data, 'turn', 0) : 0;
      const preview = cleanText.length > 0 ? cleanText : (split.text.length > 0 ? split.text : extractBlocksText(blocks));
      const shortTitle = preview.replace(/\s+/g, ' ').trim();
      const turnTitle = isHumanUser
        ? (shortTitle.length > 28 ? shortTitle.substring(0, 28) + '…' : shortTitle)
        : '';
      const turnObj = ensureTurn(tNum, time, turnTitle);

      if (isHumanUser && (cleanText.length > 0 || split.attachments.length > 0)) {
        const entry = makeConvEntry('ev-' + seq.toString(), seq, time, 'user');
        entry.text = cleanText;
        entry.attachmentLabels = split.attachments;
        conv.push(entry);
      }
      const stepLabel = isHumanUser ? 'user' : (srcKind.length > 0 ? srcKind : 'context');
      const baseSummary = shortTitle.length > 48 ? shortTitle.substring(0, 48) + '…' : (shortTitle || (isHumanUser ? '[用户附件]' : '[系统上下文]'));
      pushStep(turnObj, {
        id: 'traj-user-' + seq.toString(),
        seq: seq,
        turnNumber: turnObj.turnNumber,
        stepNumber: currentStepNum,
        kind: isHumanUser ? 'user' : 'system',
        label: stepLabel,
        summary: isHumanUser ? baseSummary : ('[' + stepLabel + '] ' + baseSummary),
        previewText: preview,
        rawJson: stringifyPretty(ev),
        at: time,
        durationMs: 0,
        tokensIn: 0,
        tokensOut: 0,
        tokensCacheRead: 0,
        model: '',
        isError: false
      });
      continue;
    }

    if (evType === 'assistant/message') {
      const msg = data !== undefined ? jsonRec(data, 'message') : undefined;
      const blocks = msg !== undefined ? jsonArr(msg, 'content') : (data !== undefined ? jsonArr(data, 'content') : []);
      const split = splitContentBlocks(blocks);
      let reasoningText = split.reasoning;
      if (reasoningText.length === 0 && data !== undefined) {
        reasoningText = extractStreamReasoningFallback(jsonArr(data, 'stream'));
      }
      const src = msg !== undefined ? jsonRec(msg, 'source') : undefined;
      const model = src !== undefined ? jsonStr(src, 'model') : '';
      const tNum = data !== undefined ? jsonNum(data, 'turn', 0) : 0;
      const sNum = data !== undefined ? jsonNum(data, 'step', currentStepNum) : currentStepNum;
      const stepDuration = (currentStepStartAt > 0 && time >= currentStepStartAt) ? (time - currentStepStartAt) : 0;
      const usageObj = data !== undefined ? jsonField(data, 'usage') : undefined;
      const tokens = parseUsageTokens(usageObj);
      aggUncachedIn += tokens.inTokens;
      aggOut += tokens.outTokens;
      aggCacheRead += tokens.cacheRead;
      aggCacheWrite += tokens.cacheWrite;

      const turnObj = ensureTurn(tNum, time, '');
      const cleanAnswer = sanitizeConversationText(split.text);

      if (reasoningText.trim().length > 0) {
        const rEntry = makeConvEntry('ev-reason-' + seq.toString(), seq, time, 'reasoning');
        rEntry.text = reasoningText.trim();
        rEntry.model = model;
        conv.push(rEntry);
        const rDur = cleanAnswer.length > 0 ? Math.round(stepDuration * 0.45) : stepDuration;
        pushStep(turnObj, {
          id: 'traj-think-' + seq.toString(),
          seq: seq,
          turnNumber: turnObj.turnNumber,
          stepNumber: sNum,
          kind: 'thinking',
          label: 'thinking',
          summary: reasoningText.trim().replace(/\s+/g, ' ').substring(0, 60),
          previewText: reasoningText.trim(),
          rawJson: stringifyPretty(ev),
          at: time,
          durationMs: rDur,
          tokensIn: 0,
          tokensOut: 0,
          tokensCacheRead: 0,
          model: model,
          isError: false
        });
      }

      for (let t = 0; t < split.toolCalls.length; t++) {
        const tc = split.toolCalls[t];
        const tcName = firstNonEmptyStr(tc, ['toolName', 'name', 'tool']);
        if (tcName.length === 0) {
          continue;
        }
        const tcId = firstNonEmptyStr(tc, ['callId', 'id', 'toolCallId']);
        const rawArgs = firstNonEmptyStr(tc, ['arguments', 'args', 'input', 'parameters']);
        const entryId = tcId.length > 0 ? ('call-' + tcId) : ('ev-tc-' + seq.toString() + '-' + t.toString());
        if (tcId.length > 0 && !toolConvIndexByCallId.has(tcId)) {
          const entry = makeConvEntry(entryId, seq, time, 'tool');
          entry.toolName = tcName;
          entry.callId = tcId;
          entry.toolArgs = rawArgs;
          entry.detail = formatToolArgsSummary(rawArgs);
          entry.toolState = 'running';
          toolConvIndexByCallId.set(tcId, conv.length);
          conv.push(entry);
          toolStartTimeByCallId.set(tcId, time);
        }
      }

      if (cleanAnswer.length > 0) {
        const aEntry = makeConvEntry('ev-msg-' + seq.toString(), seq, time, 'assistant');
        aEntry.text = cleanAnswer;
        aEntry.model = model;
        aEntry.durationMs = stepDuration;
        conv.push(aEntry);

        const tDur = reasoningText.trim().length > 0 ? Math.max(0, stepDuration - Math.round(stepDuration * 0.45)) : stepDuration;
        pushStep(turnObj, {
          id: 'traj-text-' + seq.toString(),
          seq: seq,
          turnNumber: turnObj.turnNumber,
          stepNumber: sNum,
          kind: 'text',
          label: 'text',
          summary: cleanAnswer.replace(/\s+/g, ' ').substring(0, 60),
          previewText: cleanAnswer,
          rawJson: stringifyPretty(ev),
          at: time,
          durationMs: tDur,
          tokensIn: tokens.inTokens,
          tokensOut: tokens.outTokens,
          tokensCacheRead: tokens.cacheRead,
          model: model,
          isError: false
        });
      }
      continue;
    }

    if (evType === 'tool/call') {
      const tNum = data !== undefined ? jsonNum(data, 'turn', 0) : 0;
      const sNum = data !== undefined ? jsonNum(data, 'step', currentStepNum) : currentStepNum;
      const name = data !== undefined ? jsonStr(data, 'name', 'tool') : 'tool';
      const callId = data !== undefined ? jsonStr(data, 'callId') : '';
      const argsVal = data !== undefined ? jsonField(data, 'arguments') : undefined;
      const rawArgs = typeof argsVal === 'string' ? argsVal as string : (argsVal !== undefined ? JSON.stringify(argsVal) : '');
      const summary = formatToolArgsSummary(rawArgs);

      if (callId.length > 0 && toolConvIndexByCallId.has(callId)) {
        const idx = toolConvIndexByCallId.get(callId) as number;
        conv[idx].toolName = name;
        conv[idx].toolArgs = rawArgs;
        conv[idx].detail = summary;
        toolStartTimeByCallId.set(callId, time);
      } else {
        const entry = makeConvEntry(callId.length > 0 ? ('call-' + callId) : ('ev-call-' + seq.toString()), seq, time, 'tool');
        entry.toolName = name;
        entry.callId = callId;
        entry.toolArgs = rawArgs;
        entry.detail = summary;
        entry.toolState = 'running';
        if (callId.length > 0) {
          toolConvIndexByCallId.set(callId, conv.length);
          toolStartTimeByCallId.set(callId, time);
        }
        conv.push(entry);
      }

      const turnObj = ensureTurn(tNum, time, '');
      const trajStep: DshTrajectoryStep = {
        id: 'traj-tool-' + (callId.length > 0 ? callId : seq.toString()),
        seq: seq,
        turnNumber: turnObj.turnNumber,
        stepNumber: sNum,
        kind: 'tool',
        label: name,
        summary: summary,
        previewText: rawArgs,
        rawJson: stringifyPretty(ev),
        at: time,
        durationMs: 0,
        tokensIn: 0,
        tokensOut: 0,
        tokensCacheRead: 0,
        model: '',
        isError: false
      };
      if (callId.length > 0) {
        toolTrajStepByCallId.set(callId, trajStep);
      }
      pushStep(turnObj, trajStep);
      continue;
    }

    if (evType === 'tool/result') {
      const msg = data !== undefined ? jsonRec(data, 'message') : undefined;
      const src = msg !== undefined ? jsonRec(msg, 'source') : undefined;
      const callId = src !== undefined ? jsonStr(src, 'callId') : (data !== undefined ? jsonStr(data, 'callId') : '');
      const blocks = msg !== undefined ? jsonArr(msg, 'content') : [];
      const errRec = data !== undefined ? jsonRec(data, 'error') : undefined;
      const firstIsErr = blocks.length > 0 ? jsonBool(blocks[0], 'isError') : false;
      const isErr = errRec !== undefined || firstIsErr;
      const outText = formatToolResultText(blocks);
      const startAt = callId.length > 0 ? (toolStartTimeByCallId.get(callId) ?? 0) : 0;
      const dur = (startAt > 0 && time >= startAt) ? (time - startAt) : 0;

      if (callId.length > 0 && toolConvIndexByCallId.has(callId)) {
        const idx = toolConvIndexByCallId.get(callId) as number;
        conv[idx].toolState = isErr ? 'failed' : 'success';
        conv[idx].toolOutput = outText;
        conv[idx].durationMs = dur;
      } else {
        const entry = makeConvEntry(callId.length > 0 ? ('call-' + callId) : ('ev-res-' + seq.toString()), seq, time, 'tool');
        entry.toolName = '工具结果';
        entry.callId = callId;
        entry.toolState = isErr ? 'failed' : 'success';
        entry.toolOutput = outText;
        entry.durationMs = dur;
        if (callId.length > 0) {
          toolConvIndexByCallId.set(callId, conv.length);
        }
        conv.push(entry);
      }

      if (callId.length > 0 && toolTrajStepByCallId.has(callId)) {
        const step = toolTrajStepByCallId.get(callId) as DshTrajectoryStep;
        step.durationMs = dur;
        step.isError = isErr;
        if (outText.length > 0) {
          step.previewText = (step.previewText.length > 0 ? (step.previewText + '\n\n── 输出 ──\n') : '') + outText;
        }
        if (dur > 0) {
          for (let ti = 0; ti < turns.length; ti++) {
            if (turns[ti].turnNumber === step.turnNumber) {
              turns[ti].toolMs += dur;
              turns[ti].durationMs += dur;
              aggToolMs += dur;
              break;
            }
          }
        }
      }
      continue;
    }

    if (evType === 'todo/write' || evType === 'goal/change' || evType === 'deliverables/presented' || evType === 'subagent/catalog') {
      const entry = makeConvEntry('ev-' + seq.toString(), seq, time, 'status');
      if (evType === 'todo/write') {
        const todos = data !== undefined ? jsonArr(data, 'todos') : [];
        let done = 0;
        const lines: string[] = [];
        for (let j = 0; j < todos.length; j++) {
          const st = jsonStr(todos[j], 'status');
          if (st === 'completed') {
            done += 1;
          }
          const mark = st === 'completed' ? '✓' : (st === 'in_progress' ? '▶' : '○');
          lines.push(mark + ' ' + jsonStr(todos[j], 'content'));
        }
        entry.title = '任务清单 ' + done.toString() + '/' + todos.length.toString();
        entry.detail = lines.join('\n');
      } else if (evType === 'goal/change') {
        const goal = data !== undefined ? jsonRec(data, 'goal') : undefined;
        entry.title = '目标更新：' + (goal !== undefined ? jsonStr(goal, 'objective') : '');
        entry.detail = goal !== undefined ? jsonStr(goal, 'phase') : '';
      } else if (evType === 'deliverables/presented') {
        const files = data !== undefined ? jsonArr(data, 'files') : [];
        const f0 = files.length > 0 ? jsonStr(files[0], 'path') : '';
        entry.title = '产出交付物：' + (f0 || '文件');
      } else {
        entry.title = '子代理：' + (data !== undefined ? jsonStr(data, 'label', 'subagent') : 'subagent');
      }
      conv.push(entry);
      const turnObj = ensureTurn(0, time, '');
      pushStep(turnObj, {
        id: 'traj-' + seq.toString(),
        seq: seq,
        turnNumber: turnObj.turnNumber,
        stepNumber: currentStepNum,
        kind: 'system',
        label: evType,
        summary: entry.title,
        previewText: entry.detail || entry.title,
        rawJson: stringifyPretty(ev),
        at: time,
        durationMs: 0,
        tokensIn: 0,
        tokensOut: 0,
        tokensCacheRead: 0,
        model: '',
        isError: false
      });
      continue;
    }

    if (evType === 'llm/retry' || evType === 'api-session/error') {
      const entry = makeConvEntry('ev-' + seq.toString(), seq, time, 'error');
      entry.title = evType === 'llm/retry'
        ? ('模型请求重试 #' + (data !== undefined ? jsonNum(data, 'retry', 1).toString() : '1'))
        : '会话异常';
      entry.text = data !== undefined ? firstNonEmptyStr(data, ['message', 'provider']) : '';
      conv.push(entry);
      const turnObj = ensureTurn(0, time, '');
      pushStep(turnObj, {
        id: 'traj-err-' + seq.toString(),
        seq: seq,
        turnNumber: turnObj.turnNumber,
        stepNumber: currentStepNum,
        kind: 'error',
        label: evType,
        summary: entry.title,
        previewText: entry.text || stringifyPretty(data),
        rawJson: stringifyPretty(ev),
        at: time,
        durationMs: 0,
        tokensIn: 0,
        tokensOut: 0,
        tokensCacheRead: 0,
        model: '',
        isError: true
      });
      continue;
    }

    if (evType === 'command/run') {
      const commandId = data !== undefined ? jsonStr(data, 'commandId') : '';
      const cmdName = data !== undefined ? jsonStr(data, 'name') : '';
      const cmdArgs = data !== undefined ? jsonStr(data, 'args') : '';
      const cmdTitle = (cmdName.startsWith('/') ? cmdName : '/' + cmdName) + (cmdArgs.length > 0 ? (' ' + cmdArgs) : '');
      const cEntry = makeConvEntry('ev-cmd-' + (commandId.length > 0 ? commandId : seq.toString()), seq, time, 'status');
      cEntry.title = cmdTitle.length > 1 ? cmdTitle : '执行命令';
      cEntry.detail = '执行中…';
      cEntry.toolName = cmdName;
      cEntry.callId = commandId;
      cEntry.toolState = 'running';
      conv.push(cEntry);
      if (commandId.length > 0) {
        commandConvById.set(commandId, cEntry);
      }
      const turnObj = ensureTurn(0, time, '');
      pushStep(turnObj, {
        id: 'traj-cmd-' + seq.toString(),
        seq: seq,
        turnNumber: turnObj.turnNumber,
        stepNumber: currentStepNum,
        kind: 'command',
        label: evType,
        summary: '执行命令 ' + cEntry.title,
        previewText: cmdArgs.length > 0 ? cmdArgs : cEntry.title,
        rawJson: stringifyPretty(ev),
        at: time,
        durationMs: 0,
        tokensIn: 0,
        tokensOut: 0,
        tokensCacheRead: 0,
        model: '',
        isError: false
      });
      continue;
    }

    if (evType === 'command/done') {
      const commandId = data !== undefined ? jsonStr(data, 'commandId') : '';
      const resKind = data !== undefined ? jsonStr(data, 'kind', 'success') : 'success';
      const resText = data !== undefined ? jsonStr(data, 'text') : '';
      const isErr = resKind === 'error';
      if (commandId.length > 0 && commandConvById.has(commandId)) {
        const existing = commandConvById.get(commandId) as DshConvEntry;
        existing.toolState = isErr ? 'failed' : 'success';
        existing.kind = isErr ? 'error' : 'status';
        existing.text = resText;
        existing.detail = resText.length > 0 ? resText : (isErr ? '命令执行失败' : '已完成');
      } else {
        const dEntry = makeConvEntry('ev-cmd-done-' + (commandId.length > 0 ? commandId : seq.toString()),
          seq, time, isErr ? 'error' : 'status');
        dEntry.title = isErr ? '命令执行失败' : '命令已完成';
        dEntry.text = resText;
        dEntry.detail = resText.length > 0 ? resText : (isErr ? '命令执行失败' : '已完成');
        dEntry.callId = commandId;
        dEntry.toolState = isErr ? 'failed' : 'success';
        conv.push(dEntry);
      }
      const turnObj = ensureTurn(0, time, '');
      pushStep(turnObj, {
        id: 'traj-cmd-done-' + seq.toString(),
        seq: seq,
        turnNumber: turnObj.turnNumber,
        stepNumber: currentStepNum,
        kind: 'command',
        label: evType,
        summary: isErr ? '命令失败' : '命令完成',
        previewText: resText.length > 0 ? resText : (isErr ? 'error' : 'success'),
        rawJson: stringifyPretty(ev),
        at: time,
        durationMs: 0,
        tokensIn: 0,
        tokensOut: 0,
        tokensCacheRead: 0,
        model: '',
        isError: isErr
      });
      continue;
    }

    // 内部事件（system/message、compaction/*、permission/preset、sandbox/mode、approval/* 等）：
    // 绝不放入对话流，全部规范收录到轨迹时间线中供点击详情排查。
    if (evType === 'assistant/attempt' || evType === 'request/header' || evType === 'request/context'
      || evType === 'compaction/start' || evType === 'compaction/end' || evType === 'session/end-seed'
      || evType === 'session/title-llm-request' || evType === 'session/title'
      || evType === 'agent/inbox/spliced' || evType === 'llm/retry-started') {
      continue;
    }
    const turnObj = ensureTurn(0, time, '');
    let trajKind = 'system';
    let trajSummary = evType;
    let trajPreview = '';
    if (evType === 'compaction/summary') {
      trajKind = 'compaction';
      trajSummary = '上下文压缩摘要';
      trajPreview = extractBlocksText(data !== undefined ? jsonField(data, 'summary') : undefined);
    } else if (evType === 'permission/preset' || evType === 'sandbox/mode' || evType === 'approval/policy'
      || evType === 'approval/asked' || evType === 'approval/decided') {
      trajKind = 'audit';
      trajSummary = evType;
      trajPreview = data !== undefined ? stringifyPretty(data, 2000) : '';
    } else if (evType === 'system/message' || evType === 'developer/message') {
      trajKind = 'system';
      trajSummary = evType === 'developer/message' ? '开发者指令注入' : '系统提示注入';
      const sm = data !== undefined ? jsonRec(data, 'message') : undefined;
      trajPreview = sm !== undefined ? extractBlocksText(jsonField(sm, 'content')) : '';
    }
    pushStep(turnObj, {
      id: 'traj-int-' + seq.toString(),
      seq: seq,
      turnNumber: turnObj.turnNumber,
      stepNumber: currentStepNum,
      kind: trajKind,
      label: evType,
      summary: trajSummary,
      previewText: trajPreview.length > 0 ? trajPreview : stringifyPretty(data, 2000),
      rawJson: stringifyPretty(ev),
      at: time,
      durationMs: 0,
      tokensIn: 0,
      tokensOut: 0,
      tokensCacheRead: 0,
      model: '',
      isError: false
    });
  }

  // 合入当前实时流式 attempt（如有未落盘片段）
  if (live !== undefined && live.active && live.blocks.length > 0) {
    for (let i = 0; i < live.blocks.length; i++) {
      const b = live.blocks[i];
      if (b.blockType === 'reasoning' || b.blockType === 'thinking') {
        if (b.text.trim().length > 0) {
          const e = makeConvEntry('live-reason-' + b.index.toString(), 9999999 + i, live.startedAt, 'reasoning');
          e.text = b.text;
          e.streaming = true;
          conv.push(e);
        }
      } else if (b.blockType === 'tool-call' || b.blockType === 'tool_call') {
        if (b.toolName.length > 0) {
          const e = makeConvEntry('live-tool-' + (b.callId.length > 0 ? b.callId : b.index.toString()),
            9999999 + i, live.startedAt, 'tool');
          e.toolName = b.toolName;
          e.callId = b.callId;
          e.toolArgs = b.toolArgs;
          e.detail = formatToolArgsSummary(b.toolArgs);
          e.toolState = 'running';
          e.streaming = true;
          conv.push(e);
        }
      } else {
        const clean = sanitizeConversationText(b.text);
        if (clean.length > 0) {
          const e = makeConvEntry('live-text-' + b.index.toString(), 9999999 + i, live.startedAt, 'assistant');
          e.text = clean;
          e.streaming = true;
          conv.push(e);
        }
      }
    }
  }

  // 解析 projections.values
  const pValues = projections !== undefined ? jsonRec(projections, 'values') : undefined;
  const hostTitle = pValues !== undefined ? jsonOptStr(pValues, 'title') : undefined;
  const planObj = pValues !== undefined ? jsonRec(pValues, 'plan') : undefined;
  const msObj = pValues !== undefined ? jsonRec(pValues, 'modelSelection') : undefined;
  let activeModel: DshModelSelection | undefined = undefined;
  if (msObj !== undefined) {
    activeModel = parseModelSelection(jsonField(msObj, 'next'))
      ?? parseModelSelection(jsonField(msObj, 'lastUsed'));
  }

  const sStats = pValues !== undefined ? jsonRec(pValues, 'sessionStats') : undefined;
  const tUsage = pValues !== undefined ? jsonRec(pValues, 'tokenUsage') : undefined;
  const imgLimits = pValues !== undefined ? jsonRec(pValues, 'imageLimits') : undefined;

  const hostLlmMs = sStats !== undefined ? jsonNum(sStats, 'llmMs', 0) : 0;
  const hostToolMs = sStats !== undefined ? jsonNum(sStats, 'toolMs', 0) : 0;
  const llmMs = hostLlmMs > 0 ? hostLlmMs : (aggThinkingMs + aggTextMs);
  const toolMs = hostToolMs > 0 ? hostToolMs : aggToolMs;
  const thinkingMs = aggThinkingMs;
  const totalMs = Math.max(llmMs + toolMs, thinkingMs + aggTextMs + toolMs);
  const decodeMs = sStats !== undefined ? jsonNum(sStats, 'decodeMs', 0) : 0;
  const decodeTokens = sStats !== undefined ? jsonNum(sStats, 'decodeTokens', 0) : 0;
  const tps = decodeMs > 0 && decodeTokens > 0 ? Math.round((decodeTokens * 10000) / decodeMs) / 10 : 0;

  const stats: DshTrajectoryStats = {
    turns: sStats !== undefined && jsonNum(sStats, 'turns', 0) > 0 ? jsonNum(sStats, 'turns', 0) : turns.length,
    steps: sStats !== undefined && jsonNum(sStats, 'steps', 0) > 0 ? jsonNum(sStats, 'steps', 0) : aggStepCount,
    totalMs: totalMs,
    thinkingMs: thinkingMs,
    toolMs: toolMs,
    llmMs: llmMs,
    ttftMs: sStats !== undefined ? jsonNum(sStats, 'ttftMs', 0) : 0,
    ttftSteps: sStats !== undefined ? jsonNum(sStats, 'ttftSteps', 0) : 0,
    decodeMs: decodeMs,
    decodeTokens: decodeTokens,
    tps: tps,
    uncachedInputTokens: tUsage !== undefined ? jsonNum(tUsage, 'uncachedInputTokens', aggUncachedIn) : aggUncachedIn,
    outputTokens: tUsage !== undefined ? jsonNum(tUsage, 'outputTokens', aggOut) : aggOut,
    cacheReadTokens: tUsage !== undefined ? jsonNum(tUsage, 'cacheReadTokens', aggCacheRead) : aggCacheRead,
    cacheWriteTokens: tUsage !== undefined ? jsonNum(tUsage, 'cacheWriteTokens', aggCacheWrite) : aggCacheWrite
  };

  return {
    conversation: conv,
    turns: turns,
    stats: stats,
    title: hostTitle ?? '',
    hasTitle: hostTitle !== undefined && hostTitle.length > 0,
    planActive: planObj !== undefined ? jsonBool(planObj, 'active') : false,
    planPending: planObj !== undefined ? jsonBool(planObj, 'pending') : false,
    modelSelection: activeModel,
    agentPreset: pValues !== undefined ? jsonStr(pValues, 'agentPreset') : '',
    cursor: cursor,
    maxImagesPerMessage: imgLimits !== undefined ? jsonNum(imgLimits, 'maxImagesPerMessage', 10) : 10,
    maxImageBytes: imgLimits !== undefined ? jsonNum(imgLimits, 'maxImageBytes', 20 * 1024 * 1024) : 20 * 1024 * 1024
  };
}

export function extractRawRecordFromEventFrame(value: Object): DshRawRecord | undefined {
  const ev = jsonRec(value, 'event');
  if (ev === undefined) {
    return undefined;
  }
  return {
    seq: jsonNum(ev, 'seq', 0),
    time: jsonNum(ev, 'time', 0),
    type: jsonStr(ev, 'type'),
    raw: value
  };
}

export function formatDurationCompact(ms: number): string {
  if (ms <= 0) {
    return '0ms';
  }
  if (ms < 1000) {
    return Math.round(ms).toString() + 'ms';
  }
  if (ms < 60000) {
    return (Math.round(ms / 100) / 10).toString() + 's';
  }
  const mins = Math.floor(ms / 60000);
  const secs = Math.round((ms % 60000) / 1000);
  return mins.toString() + 'm' + secs.toString() + 's';
}

export function formatTokensCompact(n: number): string {
  if (n < 1000) {
    return n.toString();
  }
  if (n < 1000000) {
    return (Math.round(n / 100) / 10).toString() + 'k';
  }
  return (Math.round(n / 10000) / 100).toString() + 'M';
}
