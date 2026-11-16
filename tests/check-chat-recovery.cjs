// Synthetic snapshots and mock HTTP only; no phone or private conversations.
const assert = require('node:assert/strict');
const path = require('node:path');

module.exports = async ({ load, root, check, page, requests, setRespond, settle, json, TentacleApi }) => {
  const { ChatRecovery } = load(path.join(root, 'service/ChatRecovery.ets'));
  const { ChatStore, ApiFailure } = load(path.join(root, 'model/Types.ets'));
  const meta = (id = 'r1', request = 'q1') => ({ round_id: id, request_id: request, source: 'user', platform: 'harmony' });
  const active = (extra = {}) => ({ ...meta(), phase: 'running', stopping: false, created_time: 1,
    input: { content: 'synthetic input', platform: 'harmony', images: [] }, ...extra });
  const delta = (text, seq = 1, extra = {}) => ({ type: 'message_delta', data: { text }, round: meta(),
    chat_instance: 'instance-a', chat_seq: seq, ...extra });
  const snapshot = (extra = {}) => ({ messages: [], has_more: false, rounds: [], events: [], finished: [],
    instance_id: 'instance-a', seq: 0, ...extra });
  const outcome = (extra = {}) => ({ ...meta(), status: 'completed', stop_reason: 'end', error: null, ...extra });
  const texts = store => store.rows.filter(row => row.group).flatMap(row => row.group.bubbles.map(b => b.text));
  function rig(fetch, observer = () => {}) {
    const store = new ChatStore(), events = [];
    const recovery = new ChatRecovery(store, fetch, event => {
      events.push(event);
      if (!event.type.startsWith('chat_sync')) store.handleWs(event);
      observer(event);
    });
    return { store, recovery, events };
  }
  function begin(p) {
    const store = p.store; store.addUser('synthetic input', 1); store.activeSendKey = store.rows.at(-1).key;
    store.activeRequestId = 'q1'; store.sending = true; store.typing = true; store.resetGroup();
    store.handleWs(delta('visible partial'));
  }

  await check('recovery restores in-flight output and releases only newer events without duplicate deltas', async () => {
    let release;
    const r = rig(() => new Promise(resolve => { release = resolve; }));
    const pending = r.recovery.synchronize();
    r.recovery.receive(delta('A', 2)); r.recovery.receive(delta('B', 3));
    release(snapshot({ seq: 2, rounds: [active()], events: [delta('A', 2)] })); await pending;
    assert.deepEqual(json(texts(r.store)), ['AB']);
    assert.equal(r.store.rows.filter(row => row.user).length, 1);
    assert.deepEqual(json(r.store.stopTarget()), { round_id: 'r1', request_id: 'q1' });
    r.recovery.receive(delta('B', 3)); assert.deepEqual(json(texts(r.store)), ['AB']); r.recovery.reset();
  });
  await check('archived rounds are never replayed and interrupted history remains visibly incomplete', async () => {
    const r = rig(async () => snapshot({ seq: 3, rounds: [active({ phase: 'finishing' })], events: [delta('duplicate', 2)],
      messages: [{ id: 10, round_id: 'r1', role: 'assistant', content: 'partial', segments: ['partial'],
        platform: 'harmony', created_time: 1, interrupted: true }] }));
    await r.recovery.synchronize(); assert.deepEqual(json(texts(r.store)), ['partial']);
    assert.equal(r.store.rows[0].group.interrupted, true);
    assert.equal(r.store.activeRound.phase, 'finishing'); r.recovery.reset();
  });
  await check('old snapshot responses cannot overwrite a new server or login scope', async () => {
    let release; const r = rig(() => new Promise(resolve => { release = resolve; }));
    const pending = r.recovery.synchronize(); r.recovery.reset(true); r.store.addUser('new scope', 2);
    release(snapshot({ messages: [{ id: 1, round_id: 'old', role: 'user', content: 'old scope', platform: 'web', created_time: 1 }] }));
    await pending; assert.equal(r.store.rows[0].user.text, 'new scope'); assert.equal(r.store.syncing, false);
  });
  await check('malformed recovery preserves the old timeline and exposes retry state', async () => {
    const r = rig(async () => snapshot({ messages: [{ content: null }] })); r.store.addUser('retained', 1);
    const rows = r.store.rows; await r.recovery.synchronize();
    assert.equal(r.store.rows, rows); assert.match(r.store.syncError, /同步失败/); r.recovery.reset();
  });
  await check('a timed-out local request can recover its running round and stop target', async () => {
    const r = rig(async () => snapshot({ seq: 2, rounds: [active({ stopping: true })], events: [delta('recovered', 2)] }));
    begin(r); r.store.failRequest('q1', 'synthetic timeout'); await r.recovery.synchronize();
    assert.equal(r.store.sending, true); assert.equal(r.store.stopping, true);
    assert.deepEqual(json(texts(r.store)), ['recovered']); r.recovery.reset();
  });
  await check('a missed cancelled terminal unlocks only its request and keeps archived partial text', async () => {
    const r = rig(async () => snapshot({ seq: 4, finished: [outcome({ status: 'cancelled', stop_reason: 'cancelled' })],
      messages: [{ id: 2, round_id: 'r1', role: 'assistant', platform: 'harmony', content: 'partial', segments: ['partial'], created_time: 1 }] }));
    begin(r); await r.recovery.synchronize();
    assert.equal(r.store.sending, false); assert.equal(r.store.rows[0].group.interrupted, true);
    assert.equal(r.store.rows[0].group.isError, false); assert.deepEqual(json(texts(r.store)), ['partial']); r.recovery.reset();
  });
  await check('server restart preserves uncertain local text without replaying a request', async () => {
    const r = rig(async () => snapshot({ instance_id: 'restarted-instance' }));
    begin(r); r.store.failRequest('q1', 'synthetic disconnect'); await r.recovery.synchronize();
    assert.deepEqual(json(texts(r.store)), ['visible partial']);
    assert.equal(r.store.sending, false); assert.equal(r.store.rows.at(-1).group.unconfirmed, true); r.recovery.reset();
  });
  await check('unsupported sync endpoints fall back once and release buffered legacy events', async () => {
    let count = 0;
    const r = rig(async () => { count++; throw new ApiFailure('Not Found', undefined, 404); });
    const pending = r.recovery.synchronize(); r.recovery.receive(delta('legacy', 1)); await pending;
    assert.deepEqual(json(texts(r.store)), ['legacy']); assert.equal(r.recovery.enabled(), false);
    await r.recovery.synchronize(); assert.equal(count, 1); r.recovery.reset();
  });
  await check('an HTTP terminal arriving during recovery forces a fresh snapshot boundary', async () => {
    let release, calls = 0;
    const archived = { id: 4, round_id: 'r1', role: 'assistant', content: 'final text', segments: ['final text'], platform: 'harmony', created_time: 1 };
    const r = rig(() => ++calls === 1 ? new Promise(resolve => { release = resolve; }) : Promise.resolve(snapshot({ messages: [archived], finished: [outcome()] })));
    begin(r); const pending = r.recovery.synchronize(); r.store.finishRequest(outcome());
    release(snapshot({ seq: 2, rounds: [active()], events: [delta('stale partial', 2)] })); await pending;
    assert.equal(calls, 2); assert.deepEqual(json(texts(r.store)), ['final text']);
    assert.equal(r.store.sending, false); assert.equal(r.store.activeRound, null); r.recovery.reset();
  });
  await check('a reconnect rechecks sync capability after a backend upgrade', async () => {
    let upgraded = false;
    const r = rig(async () => { if (!upgraded) throw new ApiFailure('Not Found', undefined, 404); return snapshot(); });
    await r.recovery.synchronize(); assert.equal(r.recovery.enabled(), false);
    upgraded = true; r.recovery.disconnected(); await r.recovery.synchronize();
    assert.equal(r.recovery.enabled(), true); assert.equal(r.store.syncing, false); r.recovery.reset();
  });
  await check('snapshot event boundaries are validated before replacing visible history', async () => {
    const r = rig(async () => snapshot({ seq: 2, rounds: [active()], events: [delta('invalid future', 3)] }));
    r.store.addUser('keep visible', 1); const rows = r.store.rows;
    await r.recovery.synchronize(); assert.equal(r.store.rows, rows); assert.match(r.store.syncError, /同步失败/); r.recovery.reset();
  });
  await check('a missed terminal for a restored foreign round clears stopping state', async () => {
    const r = rig(async () => snapshot()); r.store.activeRound = active({ request_id: null, source: 'heartbeat' });
    r.store.stopping = true; await r.recovery.synchronize();
    assert.equal(r.store.activeRound, null); assert.equal(r.store.stopping, false); assert.equal(r.store.typing, false); r.recovery.reset();
  });
  await check('recovery keeps expanded history limits and draft attachments across snapshot replacement', async () => {
    const p = page(); p.draft.text = 'retained draft'; p.draft.pending = [{ localId: 'synthetic-file', uploading: false }];
    let requestedLimit = 0;
    const r = rig(async limit => { requestedLimit = limit; return snapshot(); });
    p.store = r.store; r.recovery.setLimit(150); r.recovery.setLimit(50); await r.recovery.synchronize();
    assert.equal(requestedLimit, 150); assert.equal(p.draft.text, 'retained draft'); assert.equal(p.draft.pending.length, 1);
    r.recovery.reset(); p.aboutToDisappear();
  });
  await check('stop acceptance keeps sending locked until the original cancelled terminal', async () => {
    const p = page(); begin(p); requests.length = 0;
    setRespond(() => ({ accepted: true, state: 'stopping', round_id: 'r1', request_id: 'q1' }));
    await p.stop(); assert.equal(p.store.sending, true); assert.equal(p.store.stopping, true);
    assert.equal(p.actionEnabled(), false); assert.equal(p.actionLabel(), '正在停止…');
    assert.deepEqual(JSON.parse(requests.at(-1).options.extraData), { round_id: 'r1', request_id: 'q1' });
    p.store.handleWs({ type: 'round_finished', data: outcome({ status: 'cancelled', stop_reason: 'cancelled' }) });
    assert.equal(p.isBusy(), false); assert.deepEqual(json(texts(p.store)), ['visible partial']);
    assert.equal(p.store.rows.at(-1).group.interrupted, true); p.aboutToDisappear();
  });
  await check('a late stop response cannot change a newer request', async () => {
    let release; const p = page(); begin(p);
    setRespond(() => new Promise(resolve => { release = resolve; }));
    const pending = p.stop(); await settle(); p.store.finishRequest(outcome());
    p.store.activeRequestId = 'q2'; p.store.sending = true; p.store.resetGroup();
    release({ accepted: true, state: 'stopping' }); await pending;
    assert.equal(p.store.stopping, false); assert.equal(p.store.sending, true); p.aboutToDisappear();
  });
  await check('failed stop requests are retryable and never resend chat input', async () => {
    const p = page(); begin(p); requests.length = 0;
    setRespond(() => { throw new Error('synthetic offline'); }); await p.stop();
    assert.equal(p.store.sending, true); assert.equal(p.store.stopping, false); assert.equal(p.actionEnabled(), true);
    assert.match(p.historyError, /重试停止/); assert.ok(requests.every(request => request.url.includes('/api/chat/stop')));
    p.aboutToDisappear();
  });
  await check('finishing rounds disable stop while persistence is pending', async () => {
    const p = page(); begin(p); p.store.handleWs({ type: 'final', data: {}, round: meta() });
    requests.length = 0; await p.stop(); assert.equal(requests.length, 0);
    assert.equal(p.store.sending, true); assert.equal(p.actionLabel(), '正在保存…'); p.aboutToDisappear();
  });
  await check('a queued local request remains stoppable while another round is saving', async () => {
    const p = page(); p.store.activeRequestId = 'queued-local'; p.store.sending = true; p.store.resetGroup();
    p.store.activeRound = active({ request_id: null, source: 'heartbeat', phase: 'finishing' });
    assert.equal(p.actionEnabled(), true); assert.equal(p.actionLabel(), '停止当前回合'); p.aboutToDisappear();
  });
  await check('restored heartbeat rounds can be stopped with their server round ID', async () => {
    const p = page(); p.store.activeRound = active({ source: 'heartbeat', request_id: null, input: null });
    setRespond(() => ({ accepted: true, state: 'stopping' })); requests.length = 0; await p.stop();
    assert.deepEqual(JSON.parse(requests.at(-1).options.extraData), { round_id: 'r1' });
    assert.equal(p.store.stopping, true); p.aboutToDisappear();
  });
  await check('sync restoration keeps archive row keys and the manual reading anchor', async () => {
    const p = page(); p.followingLatest = false; let target = -1;
    p.scroller.getItemRect = () => ({ y: 17 }); p.scroller.scrollToIndex = index => { target = index; };
    p.scroller.scrollBy = () => {};
    const message = id => ({ id, round_id: 'history-' + id, role: 'user', content: 'synthetic ' + id, platform: 'harmony', created_time: id });
    const r = rig(async () => snapshot({ messages: [message(1), message(2)], has_more: true }), event => p.scrollCb(event));
    p.store = r.store;
    r.store.rows = load(path.join(root, 'model/ChatHistory.ets')).historyRows([message(1)]);
    const key = r.store.rows[0].key; await r.recovery.synchronize();
    await new Promise(resolve => setTimeout(resolve, 5));
    assert.equal(r.store.rows[0].key, key); assert.equal(target, 1); assert.equal(p.followingLatest, false);
    assert.equal(p.hasMore, true); r.recovery.reset(); p.aboutToDisappear();
  });
};
