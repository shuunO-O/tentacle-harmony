import { ActiveChatRound, ApiFailure, ChatRow, ChatSnapshot, ChatStore, RoundResult, WsEvent } from '../model/Types';
import { historyRows } from '../model/ChatHistory';

/** Restore a process-scoped snapshot before releasing newer WebSocket events. */
export class ChatRecovery {
  private store: ChatStore;
  private fetch: (limit: number) => Promise<ChatSnapshot>;
  private emit: (event: WsEvent) => void;
  private generation: number = 0;
  private pending: Promise<void> | null = null;
  private buffer: WsEvent[] = [];
  private instance: string = '';
  private seq: number = 0;
  private retry: number = -1;
  private supported: boolean | null = null;
  private limit: number = 50;
  private online: boolean = true;

  constructor(store: ChatStore, fetch: (limit: number) => Promise<ChatSnapshot>, emit: (event: WsEvent) => void) {
    this.store = store; this.fetch = fetch; this.emit = emit;
  }

  enabled(): boolean { return this.supported !== false && (this.store.syncing || this.supported === true); }
  setLimit(limit: number): void { this.limit = Math.max(this.limit, Math.min(200, limit)); }
  setOnline(online: boolean): void { this.online = online; }

  reset(clear: boolean = false): void {
    this.generation++; this.pending = null; this.buffer = []; this.instance = ''; this.seq = 0;
    this.supported = null; this.store.syncing = false;
    if (this.retry >= 0) { clearTimeout(this.retry); this.retry = -1; }
    if (clear) { this.store.clear(); }
  }

  disconnected(): void {
    this.generation++; this.pending = null; this.buffer = [];
    this.supported = null; this.store.syncing = true;
    if (this.retry >= 0) { clearTimeout(this.retry); this.retry = -1; }
  }

  receive(event: WsEvent): void {
    if (event.type === 'hello') { this.emit(event); this.synchronize(); return; }
    if (event.chat_seq !== undefined) {
      if (!Number.isSafeInteger(event.chat_seq) || event.chat_seq < 0 || !event.chat_instance) { return; }
      if (this.store.syncing) {
        if (this.buffer.length >= 2048) { this.disconnected(); this.synchronize(); }
        this.buffer.push(event); return;
      }
      if (event.chat_instance !== this.instance) {
        this.synchronize(); this.buffer.push(event); return;
      }
      if (event.chat_seq <= this.seq) { return; }
      this.seq = event.chat_seq;
    }
    this.emit(event);
  }

  synchronize(): Promise<void> {
    if (this.pending !== null) { return this.pending; }
    if (this.supported === false) { return Promise.resolve(); }
    if (this.retry >= 0) { clearTimeout(this.retry); this.retry = -1; }
    const generation = ++this.generation;
    this.store.syncing = true; this.buffer = [];
    this.emit({ type: 'chat_sync_start', data: {} });
    this.pending = this.restore(generation, this.store.revision);
    return this.pending;
  }

  private async restore(generation: number, revision: number): Promise<void> {
    try {
      const snapshot = await this.fetch(this.limit);
      if (generation !== this.generation) { return; }
      if (revision !== this.store.revision) {
        // An HTTP terminal or newer local state won the race; take a fresh boundary.
        this.pending = null; await this.synchronize(); return;
      }
      if (typeof snapshot.instance_id !== 'string' || !snapshot.instance_id || !Number.isInteger(snapshot.seq) ||
        snapshot.seq < 0 || !Array.isArray(snapshot.rounds) || !Array.isArray(snapshot.events) || !Array.isArray(snapshot.finished)) {
        throw new Error('invalid chat snapshot');
      }
      this.apply(snapshot);
      this.instance = snapshot.instance_id; this.seq = snapshot.seq; this.supported = true;
      this.store.syncing = false; this.store.syncError = '';
      const buffered = this.buffer; this.buffer = []; this.pending = null;
      for (const event of buffered) { this.receive(event); }
      this.emit({ type: 'chat_synced', data: {} });
      if (!this.online && snapshot.rounds.length && generation === this.generation) {
        this.retry = setTimeout(() => { this.retry = -1; this.synchronize(); }, 3000);
      }
    } catch (error) {
      if (generation !== this.generation) { return; }
      this.pending = null;
      if (error instanceof ApiFailure && (error.httpStatus === 404 || error.httpStatus === 405)) {
        this.supported = false; this.store.syncing = false; this.store.syncError = '';
        const buffered = this.buffer; this.buffer = [];
        for (const event of buffered) { this.emit(event); }
        this.emit({ type: 'chat_sync_unsupported', data: {} });
      } else {
        this.store.syncError = '聊天状态同步失败，正在重试；不会重发消息';
        this.retry = setTimeout(() => { this.retry = -1; this.synchronize(); }, 3000);
      }
    }
  }

  private apply(snapshot: ChatSnapshot): void {
    const restored = new ChatStore(); restored.rows = historyRows(snapshot.messages);
    for (const event of snapshot.events) {
      if (event.chat_instance !== snapshot.instance_id || !Number.isSafeInteger(event.chat_seq) ||
        (event.chat_seq ?? 0) > snapshot.seq) { throw new Error('invalid snapshot event boundary'); }
    }
    const archived = new Set<string>(snapshot.messages.map((message) => message.round_id ?? ''));
    for (const round of snapshot.rounds) {
      if (typeof round.round_id !== 'string' || !round.round_id || typeof round.phase !== 'string') {
        throw new Error('invalid active round');
      }
      if (round.input !== null && round.input !== undefined && !archived.has(round.round_id)) {
        const input = round.input;
        if (typeof input.content !== 'string') { throw new Error('invalid active input'); }
        if (input.platform === 'system') { restored.addSystem(input.content); }
        else { restored.addUser(input.content, round.created_time, input.images ?? [], input.platform); }
        restored.rows[restored.rows.length - 1].roundId = round.round_id;
      }
      for (const event of snapshot.events) {
        if (event.round?.round_id === round.round_id && !archived.has(round.round_id)) { restored.handleWs(event); }
      }
    }
    for (const outcome of snapshot.finished) {
      if (outcome.status === 'cancelled') {
        for (const row of restored.rows) {
          if (row.group !== null && row.group.roundId === outcome.round_id) { row.group.interrupted = true; }
        }
      }
    }
    const requestId = this.store.activeRequestId;
    const awaiting = this.store.sending || this.store.hasUnconfirmedRequest();
    const ownRoundId = this.store.rows.find((row: ChatRow) => row.group?.requestId === requestId)?.group?.roundId;
    const matches = snapshot.rounds.filter((round: ActiveChatRound) => ownRoundId ?
      round.round_id === ownRoundId : round.request_id === requestId && !!requestId);
    const terminal = snapshot.finished.find((round: RoundResult) => ownRoundId ?
      round.round_id === ownRoundId : round.request_id === requestId && !!requestId);
    if (awaiting && !matches.length && !archived.has(terminal?.round_id ?? '')) {
      // Keep optimistic input and visible partial output when no durable record exists.
      for (const row of this.store.rows) {
        if (row.key === this.store.activeSendKey || row.group?.requestId === requestId) {
          restored.rows = restored.rows.concat([row]);
        }
      }
    }
    for (const row of restored.rows) {
      const previous = this.store.rows.find((old: ChatRow) => row.archiveId > 0 && old.archiveId === row.archiveId);
      if (previous !== undefined) { row.key = previous.key; }
      if (row.group !== null && previous !== undefined && previous.group !== null) {
        row.group.reasoningOpen = previous.group.reasoningOpen; row.group.toolsOpen = previous.group.toolsOpen;
      }
    }
    this.store.rows = restored.rows; this.store.receiving = restored.receiving;
    this.store.activeRound = snapshot.rounds.find((round: ActiveChatRound) => round.phase !== 'queued') ?? snapshot.rounds[0] ?? null;
    this.store.stopping = this.store.activeRound?.stopping ?? false;
    this.store.finishing = this.store.activeRound?.phase === 'finishing';
    this.store.typing = this.store.activeRound !== null && !this.store.finishing;
    this.store.syncHasMore = snapshot.has_more;
    if (awaiting && matches.length === 1) {
      this.store.sending = true; this.store.stopping = matches[0].stopping;
      this.store.finishing = matches[0].phase === 'finishing';
    } else if (awaiting && terminal !== undefined) {
      this.store.finishRequest(terminal);
    } else if (awaiting && this.store.hasUnconfirmedRequest()) {
      this.store.sending = false;
    }
    this.store.revision++;
    if (terminal !== undefined && awaiting) {
      this.emit({ type: 'round_finished', data: { round_id: terminal.round_id, request_id: terminal.request_id,
        source: terminal.source, platform: terminal.platform, status: terminal.status, stop_reason: terminal.stop_reason,
        error: terminal.error ?? undefined, command: terminal.command } });
    }
  }
}
