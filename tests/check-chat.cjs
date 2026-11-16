// Isolated logic verification: no device, server, account, or conversation data.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_MODULE || 'C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const root = path.resolve(__dirname, '../entry/src/main/ets');
const loaded = new Map();
const requests = [];
const SYNTHETIC_COMMANDS = [
  { value: '/model current', description: '模拟当前模型' },
  { value: '/model use synthetic-model', description: '模拟切换' },
  { value: '/cache', description: '模拟缓存' },
  { value: '/cache status', description: '模拟状态' },
  { value: '/cache clear', description: '模拟清理' },
  { value: '/help', description: '模拟帮助' }
];
const commandResult = text => ({ ok: true, total_tokens: 0,
  command: { text, refresh_history: true } });
let commandCatalogReply = SYNTHETIC_COMMANDS;
let respond = url => url.includes('/history') ? { messages: [] } : commandResult('模拟命令反馈');
let responseCookies = '';
const prefValues = new Map();
const appStorage = new Map();
let wsOptions;
let createHttpOverride = null;
const coreFileKit = {};
const mediaKit = {};
const KeyCode = { KEYCODE_DPAD_DOWN: 2013, KEYCODE_DPAD_UP: 2012,
  KEYCODE_TAB: 2049, KEYCODE_ENTER: 2054, KEYCODE_ESCAPE: 2070 };
class Scroller { scrollEdge() {} scrollToIndex() {} isAtEnd() { return false; } }
class TextAreaController { caretPosition() {} }
const network = {
  http: {
    RequestMethod: { POST: 'POST', GET: 'GET', PUT: 'PUT', DELETE: 'DELETE' },
    HttpDataType: { ARRAY_BUFFER: 1 },
    createHttp: () => createHttpOverride ? createHttpOverride() : ({
      destroy() {},
      request(url, options, callback) {
        requests.push({ url, options });
        Promise.resolve().then(() => url.endsWith('/api/chat/commands')
          ? { commands: commandCatalogReply } : respond(url, options)).then(
          result => {
            if (url.endsWith('/api/chat/send') && !result.round && !result.__httpStatus) {
              const requestId = JSON.parse(options.extraData).request_id;
              result = { ...result, round: terminal(requestId, { command: result.command }) };
            }
            callback(null, { responseCode: result.__httpStatus || 200, cookies: responseCookies,
              result: options.expectDataType === 1 ? result : JSON.stringify(result.__httpStatus ? result.body : result) });
          },
          error => callback({ message: error.message })
        );
      }
    })
  },
  webSocket: { createWebSocket: () => ({ on() {},
    connect(url, options) { wsOptions = options; return Promise.resolve(); },
    close() { return Promise.resolve(); }
  }) }
};
function load(file) {
  file = path.resolve(file);
  if (loaded.has(file)) return loaded.get(file);
  let source = fs.readFileSync(file, 'utf8');
  if (file.includes(path.sep + 'view' + path.sep) || ['MediaAttachment.ets','BubbleItem.ets','MarkdownBody.ets','GraphCanvas.ets'].some(name=>file.endsWith(name))) {
    // Compile actual non-UI methods; ArkUI rendering is checked by hvigor.
    const boundaries = [source.indexOf('  @Builder'), source.indexOf('  build()')].filter(n => n >= 0);
    source = source.slice(0, Math.min(...boundaries)) + '\n}';
    source = source.replace(/export struct (\w+)/, 'export class $1')
      .replace(/@Component\s*/g, '').replace(/@(State|Prop|Link|ObjectLink)\s+/g, '').replace(/@Watch\('[^']+'\)\s*/g, '');
  }
  const result = ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  }});
  const exports = {};
  loaded.set(file, exports);
  vm.runInNewContext(result.outputText, {
    exports, Error, ArrayBuffer, Uint8Array, console, setTimeout, clearTimeout, setInterval, clearInterval,
    Observed: cls => cls, TouchType: { Down: 0, Up: 1, Cancel: 3 },
    AppStorage: { setOrCreate: (key, value) => appStorage.set(key, value), get: key => appStorage.get(key) },
    ScrollSource: { DRAG: 0, FLING: 1, OTHER_USER_INPUT: 3, SCROLL_BAR: 4, SCROLL_BAR_FLING: 5, SCROLLER: 6 },
    Scroller, TextAreaController, KeyType: { Down: 0, Up: 1 }, Edge: { Bottom: 1 }, ScrollAlign: { START: 0 },
    RenderingContextSettings: class {}, CanvasRenderingContext2D: class {},
    XComponentController: class {},
    require(name) {
      if (name.startsWith('.')) {
        const imported = path.resolve(path.dirname(file), name + '.ets');
        if (fs.existsSync(imported) && !name.includes('/components/')) return load(imported);
        return {};
      }
      if (name === '@kit.NetworkKit') return network;
      if (name === '@kit.CoreFileKit') return coreFileKit;
      if (name === '@kit.MediaKit') return mediaKit;
      if (name === '@kit.AudioKit') return { audio: { StreamUsage: { STREAM_USAGE_GAME: 11 } } };
      if (name === '@kit.CryptoArchitectureKit') return { cryptoFramework: { createMd: () => {
        const hash = require('node:crypto').createHash('sha256');
        return { update: async blob => { hash.update(blob.data); }, digest: async () => ({ data: new Uint8Array(hash.digest()) }) };
      } } };
      if (name === '@kit.InputKit') return { KeyCode };
      if (name === '@kit.PerformanceAnalysisKit') return { hilog: { info() {}, warn() {}, error() {} } };
      if (name === '@kit.ArkTS') return { util: { TextEncoder: class {
        encodeInto(text) { return new Uint8Array(Buffer.from(text,'utf8')); }
      }, Base64Helper: class {
        encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); }
      } } };
      if (name === '@kit.ArkData') return { preferences: { getPreferencesSync: () => ({
        getSync: (key, fallback) => prefValues.get(key) ?? fallback,
        putSync: (key, value) => prefValues.set(key, value), flush: () => Promise.resolve()
      }) } };
      return {};
    }
  }, { filename: file });
  return exports;
}
const { matchChatCommands } = load(path.join(root, 'model/ChatCommands.ets'));
const { ChatStore, PendingImage, ChatDraft } = load(path.join(root, 'model/Types.ets'));
const { ChatPage } = load(path.join(root, 'view/ChatPage.ets'));
const { TentacleApi } = load(path.join(root, 'service/TentacleApi.ets'));
const settle = async () => { for (let i = 0; i < 3; i++) await new Promise(resolve => setImmediate(resolve)); };
const json = value => JSON.parse(JSON.stringify(value));
function terminal(requestId, extra = {}) {
  return { round_id: 'round-' + requestId, request_id: requestId, source: 'user', platform: 'harmony',
    status: 'completed', stop_reason: 'complete', error: null, ...extra };
}
function sentBody(request) {
  const body = JSON.parse(request.options.extraData);
  assert.match(body.request_id, /^harmony-/);
  const { request_id, ...rest } = body; return rest;
}
function page() {
  const p = new ChatPage();
  p.store = new ChatStore();
  p.draft = new ChatDraft();
  p.commandCatalog = SYNTHETIC_COMMANDS;
  p.pageVisible = true;
  p.getUIContext = () => ({ getFocusController: () => ({ requestFocus() {} }) });
  return p;
}
function key(code, shift = false) {
  return { type: 0, keyCode: KeyCode[code], getModifierKeyState: () => shift };
}
let checks = 0;
async function check(name, fn) {
  await fn();
  checks++;
  console.log('PASS ' + name);
}
(async () => {
  await check('command suggestions come from the backend, including new names', async () => {
    const catalog = [{ value: '/new-backend-command', description: '新增模拟指令' }];
    commandCatalogReply = catalog;
    const p = page(); await p.loadCommandCatalog();
    assert.deepEqual(json(matchChatCommands(' /NEW', p.commandCatalog)), catalog);
    for (const text of ['', 'hello', 'hello /help', '/help\n', '/unknown']) {
      assert.equal(matchChatCommands(text, p.commandCatalog).length, 0);
    }
    assert.equal(requests.at(-1).url, '/api/chat/commands');
    commandCatalogReply = SYNTHETIC_COMMANDS;
  });
  await check('commands use the unified chat endpoint and generic result', async () => {
    respond = url => url.includes('/history') ? { messages: [] } : commandResult('模拟命令反馈');
    requests.length = 0;
    const p = page(); p.draft.text = ' /model current '; p.send();
    assert.equal(p.isBusy(), true);
    await settle();
    assert.deepEqual(requests.map(r => r.url), ['/api/chat/send', '/api/chat/history?limit=50']);
    assert.deepEqual(sentBody(requests[0]), { text: '/model current', platform: 'harmony' });
    assert.equal(p.store.rows.at(-1).system.text, '模拟命令反馈');
    assert.equal(p.store.rows.some(row => row.group && !row.group.bubbles.length), false);
    assert.equal(p.isBusy(), false);
  });
  await check('unknown commands use the same route and retain attachments after the backend result', async () => {
    requests.length = 0;
    const p = page(); p.draft.text = '/unknown "参数"';
    const image = new PendingImage(); image.localId = 'synthetic-image'; p.draft.pending = [image];
    p.send(); await settle();
    const sent = requests.find(request => request.url === '/api/chat/send');
    assert.ok(sent);
    assert.deepEqual(sentBody(sent), {
      text: '/unknown "参数"', platform: 'harmony', files: ['synthetic-image']
    });
    assert.equal(p.draft.pending.length, 1);
  });
  await check('backend refresh flag refreshes history before showing command feedback', async () => {
    requests.length = 0;
    respond = url => url.includes('/history')
      ? { messages: [{ role: 'user', content: '模拟保留消息', platform: 'harmony', created_time: 1 }] }
      : commandResult('模拟回退反馈');
    const p = page(); p.store.addUser('模拟被回退消息', 2); p.draft.text = '/ROLLBACK';
    p.send(); await settle();
    assert.deepEqual(requests.map(r => r.url), ['/api/chat/send', '/api/chat/history?limit=50']);
    assert.equal(p.store.rows[0].user.text, '模拟保留消息');
    assert.equal(p.store.rows[1].system.text, '模拟回退反馈');
    assert.equal(p.isBusy(), false);
  });
  await check('history refresh failure remains visible and releases command state', async () => {
    respond = url => { if (url.includes('/history')) throw new Error('offline'); return commandResult('模拟回退反馈'); };
    const p = page(); p.draft.text = '/rollback'; p.send(); await settle();
    assert.ok(p.store.rows.some(r => r.group && r.group.errorText.includes('刷新失败')));
    assert.equal(p.isBusy(), false);
  });
  await check('HTTP timeout releases busy state without waiting for a missing final event', async () => {
    respond = () => { throw new Error('request timed out'); };
    for (const text of ['/compress', '普通模拟输入']) {
      const p = page(); p.draft.text = text; p.send(); await settle();
      assert.ok(p.store.rows.some(r => r.group && r.group.errorText.includes('结果未确认')));
      assert.equal(p.isBusy(), false);
      assert.equal(p.store.typing, false);
    }
  });
  await check('duplicate sends are blocked while a request awaits its response', async () => {
    let release;
    respond = () => new Promise(resolve => { release = resolve; });
    requests.length = 0;
    const p = page(); p.draft.text = '/help'; p.send(); await settle();
    p.draft.text = '/cache status'; p.send(); await settle();
    assert.equal(requests.length, 1);
    assert.equal(p.draft.text, '/cache status');
    release({ ok: true, total_tokens: 0, command: { text: '模拟帮助', refresh_history: false } });
    await settle();
    assert.equal(p.isBusy(), false);
  });
  await check('ordinary and image-only messages preserve the existing chat route', async () => {
    respond = () => ({ ok: true, total_tokens: 0 }); requests.length = 0;
    for (const text of ['普通模拟消息', '/']) {
      const p = page(); p.draft.text = text; p.send(); await settle();
      assert.equal(requests.filter(r => r.url.endsWith('/api/chat/send')).at(-1).url, '/api/chat/send');
      assert.equal(JSON.parse(requests.filter(r => r.url.endsWith('/api/chat/send')).at(-1).options.extraData).platform, 'harmony');
    }
    const p = page(); const image = new PendingImage(); image.localId = 'synthetic'; p.draft.pending = [image];
    p.send(); await settle();
    assert.deepEqual(JSON.parse(requests.filter(r => r.url.endsWith('/api/chat/send')).at(-1).options.extraData).files, ['synthetic']);
    assert.equal(p.draft.pending.length, 0);
  });
  await check('keyboard wraps backend candidates, selects before sending, and supports dismissal', () => {
    const p = page(); p.draft.text = '/cache'; p.commandMatches = matchChatCommands('/cache', p.commandCatalog);
    assert.equal(p.handleInputKey(key('KEYCODE_DPAD_UP')), true);
    assert.equal(p.commandActiveIndex, 2);
    assert.equal(p.handleInputKey(key('KEYCODE_DPAD_DOWN')), true);
    assert.equal(p.commandActiveIndex, 0);
    p.commandActiveIndex = 1;
    const before = requests.length;
    assert.equal(p.handleInputKey(key('KEYCODE_ENTER')), true);
    assert.equal(p.draft.text, '/cache status');
    assert.equal(p.commandMatches.length, 0);
    assert.equal(requests.length, before);
    p.commandMatches = matchChatCommands('/cache', p.commandCatalog);
    assert.equal(p.handleInputKey(key('KEYCODE_ESCAPE')), true);
    assert.equal(p.commandMatches.length, 0);
    assert.equal(p.handleInputKey(key('KEYCODE_ENTER', true)), false);
    p.composing = true;
    assert.equal(p.handleInputKey(key('KEYCODE_ENTER')), false);
  });
  await check('persisted device authentication is restored and sent with chat and WebSocket', async () => {
    prefValues.set('server_url', 'https://example.test');
    prefValues.set('device_cookie', 'synthetic-device-credential');
    prefValues.set('token', 'synthetic-password-session');
    const api = new TentacleApi(); api.init({});
    respond = () => commandResult('模拟反馈'); requests.length = 0;
    await api.sendChat('/help', [], 'harmony-auth-check');
    assert.equal(requests[0].options.header.Cookie, 'tentacle_device=synthetic-device-credential');
    assert.equal(requests[0].options.header.Authorization, 'Bearer synthetic-password-session');
    api.connectWs();
    assert.equal(wsOptions.header.Cookie, 'tentacle_device=synthetic-device-credential');
    api.disconnectWs();
    api.saveConfig();
    assert.equal(prefValues.get('device_cookie'), 'synthetic-device-credential');
  });
  await check('both cookie formats work and enrollment survives API recreation', async () => {
    const api = new TentacleApi(); api.init({});
    assert.equal(api.extractDeviceCookie('tentacle_device=synthetic-new; Path=/; HttpOnly'), 'synthetic-new');
    assert.equal(api.extractDeviceCookie('#HttpOnly_example.test\tFALSE\t/\tTRUE\t100\ttentacle_device\tsynthetic-new'), 'synthetic-new');
    responseCookies = 'tentacle_device=synthetic-new; Path=/; HttpOnly';
    respond = () => ({ ok: true });
    await api.enroll('synthetic-code', '模拟设备');
    const restored = new TentacleApi(); restored.init({});
    assert.equal(restored.deviceCookie, 'synthetic-new');
    responseCookies = '';
  });
  await check('protected images and uploads use device authentication', async () => {
    const api = new TentacleApi(); api.init({}); requests.length = 0;
    respond = () => new Uint8Array([1, 2, 3]).buffer;
    assert.equal(await api.getImageDataUri('synthetic-image', 'image/png'), 'data:image/png;base64,AQID');
    assert.equal(requests[0].options.header.Cookie, 'tentacle_device=synthetic-new');
    respond = () => ({ ok: true, file: { local_id: 'synthetic-upload', filename: 'synthetic.png' } });
    await api.uploadImage(new ArrayBuffer(0), 'synthetic.png', 'image/png');
    assert.equal(requests.at(-1).options.header.Cookie, 'tentacle_device=synthetic-new');
  });
  await check('new history preserves every message, platform and server segment order', async () => {
    const segments = ['第一段', '含空行的代码\n\n仍在同一段'];
    respond = () => ({ messages: [
      { id: 101, round_id: 'r', role: 'user', content: '模拟用户', platform: 'harmony', created_time: 10 },
      { id: 103, round_id: 'r', role: 'assistant', platform: 'web', created_time: 10, content: '先检查', segments: ['先检查'] },
      { id: 108, round_id: 'r', role: 'assistant', platform: 'qq', created_time: 9, content: '外发成功', segments: ['外发成功'] },
      { id: 109, round_id: 'r', role: 'assistant', platform: 'web', created_time: 8, content: segments.join('\n\n'), segments }
    ], has_more: true });
    const p = page(); await p.loadHistory();
    assert.deepEqual(json(p.store.rows.map(r => r.archiveId)), [101,103,108,109]);
    assert.deepEqual(json(p.store.rows.filter(r => r.group).flatMap(r => r.group.bubbles.map(b => [b.text,b.platform]))),
      [['先检查','web'],['外发成功','qq'],...segments.map(s => [s,'web'])]);
    assert.equal(p.hasMore, true);
    p.aboutToDisappear();
  });
  await check('empty segments stay empty and file marker examples stay plain history text', async () => {
    respond = () => ({ messages: [
      { id: 1, round_id: 'r', role: 'assistant', platform: 'web', created_time: 1, content: '不自行重建', segments: [] },
      { id: 2, round_id: 'r', role: 'assistant', platform: 'web', created_time: 2,
        content: '[send_message][qq]example[/send_message]', segments: ['[send_message][qq]example[/send_message]'] }
    ], has_more: false });
    const p = page(); await p.loadHistory();
    assert.equal(p.store.rows[0].group.bubbles.length, 0);
    assert.equal(p.store.rows[1].group.bubbles[0].text, '[send_message][qq]example[/send_message]');
    p.aboutToDisappear();
  });
  await check('history requests bypass cache and refresh rows with new identities', async () => {
    respond = () => ({ messages: [
      { role: 'user', content: '模拟用户', created_time: 1 },
      { role: 'assistant', platform: 'harmony', created_time: 2,
        content: '模拟最新答复', segments: ['模拟最新答复'] }
    ] });
    const p = page(); requests.length = 0;
    await p.loadHistory();
    const oldKeys = p.store.rows.map(row => row.key);
    await p.loadHistory();
    assert.equal(requests.at(-1).options.usingCache, false);
    assert.ok(p.store.rows.every(row => !oldKeys.includes(row.key)));
    assert.equal(p.store.rows[1].group.bubbles[0].text, '模拟最新答复');
    p.aboutToDisappear();
  });
  await check('returning during a live reply keeps the unarchived message and busy state', async () => {
    const p = page(); p.store.addUser('模拟尚未归档输入', 1); p.store.sending = true;
    p.store.handleWs({ type: 'message_delta', data: { text: '模拟尚未归档答复', platform: 'harmony' } });
    const liveRows = p.store.rows;
    const count = requests.length;
    p.aboutToAppear(); await settle();
    assert.equal(requests.slice(count).filter(r => r.url.includes('/history')).length, 0);
    assert.equal(p.store.rows, liveRows);
    assert.equal(p.store.sending, true);
    assert.equal(p.store.receiving, true);
    p.aboutToDisappear();
  });
  await check('late history cannot overwrite a reply received and finished during the request', async () => {
    let release;
    respond = () => new Promise(resolve => { release = resolve; });
    const p = page(); p.store.addUser('模拟已存在输入', 1);
    const loading = p.loadHistory(); await settle();
    p.store.handleWs({ type: 'message_delta', data: { text: '模拟刚收到答复', platform: 'harmony' } });
    p.store.handleWs({ type: 'final', data: {} });
    const liveRows = p.store.rows;
    release({ messages: [] }); await loading;
    assert.equal(p.store.rows, liveRows);
    assert.equal(p.store.rows[1].group.bubbles[0].text, '模拟刚收到答复');
    p.aboutToDisappear();
  });
  await check('leaving and revisiting invalidates the old page response', async () => {
    const releases = [];
    respond = () => new Promise(resolve => { releases.push(resolve); });
    const oldPage = page(); oldPage.aboutToAppear(); await settle();
    oldPage.aboutToDisappear();
    const newPage = page(); newPage.store = oldPage.store;
    newPage.aboutToAppear(); await settle();
    releases[1]({ messages: [{ role: 'user', content: '模拟新页面快照', created_time: 2 }] });
    await settle();
    releases[0]({ messages: [{ role: 'user', content: '模拟旧页面快照', created_time: 1 }] });
    await settle();
    assert.equal(newPage.store.rows[0].user.text, '模拟新页面快照');
    newPage.aboutToDisappear();
  });
  await check('reconnection reloads history and unregisters the connection listener on exit', async () => {
    const api = TentacleApi.getInstance();
    const before = api.connListeners.length;
    respond = () => ({ messages: [{ role: 'user', content: '模拟首次快照', created_time: 1 }] });
    const p = page(); p.aboutToAppear(); await settle();
    assert.equal(api.connListeners.length, before + 1);
    respond = () => ({ messages: [{ role: 'user', content: '模拟重连快照', created_time: 2 }] });
    api.notifyConn(true); await settle();
    assert.equal(p.store.rows[0].user.text, '模拟重连快照');
    p.aboutToDisappear();
    assert.equal(api.connListeners.length, before);
  });
  await check('a malformed snapshot preserves the existing rows and exposes a refresh error', async () => {
    const p = page(); p.store.addUser('模拟保留消息', 1);
    const rows = p.store.rows;
    respond = () => ({ messages: [
      { role: 'user', content: '模拟部分历史', created_time: 0 },
      { role: 'assistant', content: null, created_time: 1 }
    ] });
    await p.loadHistory();
    assert.equal(p.store.rows, rows);
    assert.ok(p.historyError.includes('同步失败'));
    p.aboutToDisappear();
  });
  await check('a completed REST round recovers when its WebSocket final was missed', async () => {
    respond = () => ({ messages: [] });
    const p = page(); p.aboutToAppear(); await settle();
    respond = url => url.includes('/history') ? { messages: [
      { role: 'user', content: '模拟本轮输入', created_time: 1 },
      { role: 'assistant', platform: 'harmony', created_time: 2,
        content: '模拟完整归档答复', segments: ['模拟完整归档答复'] }
    ] } : { ok: true, total_tokens: 0 };
    p.draft.text = '模拟本轮输入'; p.send();
    p.store.handleWs({ type: 'message_delta', data: { text: '模拟部分答复', platform: 'harmony' } });
    await settle();
    assert.equal(p.store.sending, false);
    assert.equal(p.store.receiving, false);
    assert.equal(p.store.rows[1].group.bubbles[0].text, '模拟完整归档答复');
    p.aboutToDisappear();
  });
  await check('a late completed request cannot unlock a newer round', async () => {
    const releases = [];
    respond = () => new Promise(resolve => { releases.push(resolve); });
    const p = page(); p.draft.text = '模拟第一轮'; p.send(); await settle();
    const firstId = p.store.activeRequestId;
    p.store.handleWs({ type: 'round_finished', data: terminal(firstId) });
    p.draft.text = '模拟第二轮'; p.send(); await settle();
    releases[0]({ ok: true, total_tokens: 0 }); await settle();
    assert.equal(p.store.sending, true);
    releases[1]({ ok: true, total_tokens: 0 }); await settle();
    assert.equal(p.store.sending, false);
    p.aboutToDisappear();
  });
  const { parseMarkdown, parseMarkdownInline, isMarkdownLink } = load(path.join(root, 'model/Markdown.ets'));
  const plain = spans => spans.map(s => s.text).join('');
  await check('Markdown headings, paragraphs, quotes and nested list indentation', () => {
    const blocks = parseMarkdown('# C#\n\nhello **world**\n\n> quoted\n> second\n\n- first\n  - nested\n1. numbered\n- [x] done\n\n---');
    assert.deepEqual(json(blocks.map(b => b.kind)), ['heading', 'paragraph', 'quote', 'list', 'list', 'list', 'list', 'rule']);
    assert.equal(plain(blocks[0].spans), 'C#');
    assert.equal(plain(blocks[2].spans), 'quoted\nsecond');
    assert.equal(blocks[4].level, 1);
    assert.equal(blocks[5].prefix, '1.');
    assert.equal(blocks[6].prefix, '☑');
  });
  await check('Markdown inline formatting preserves literal code, escapes and intraword underscores', () => {
    const spans = parseMarkdownInline('**粗体** *斜体* ~~删除~~ `**原样**` \\*文字\\* foo_bar_baz ***兼有***');
    assert.equal(plain(spans), '粗体 斜体 删除 **原样** *文字* foo_bar_baz 兼有');
    assert.ok(spans.find(s => s.text === '粗体').bold);
    assert.ok(spans.find(s => s.text === '斜体').italic);
    assert.ok(spans.find(s => s.text === '删除').strike);
    assert.ok(spans.find(s => s.text === '**原样**').code);
    assert.ok(spans.find(s => s.text === '兼有').bold && spans.find(s => s.text === '兼有').italic);
  });
  await check('Markdown code fences preserve blank lines and render unfinished streaming code', () => {
    const blocks = parseMarkdown('before\n\n```ts\nconst a = "**literal**";\n\nline\n```\n\nafter');
    assert.equal(blocks[1].kind, 'code');
    assert.equal(blocks[1].language, 'ts');
    assert.equal(blocks[1].text, 'const a = "**literal**";\n\nline');
    assert.equal(parseMarkdown('~~~\nunfinished')[0].text, 'unfinished');
    assert.equal(plain(parseMarkdownInline('尚未 **完成')), '尚未 **完成');
    assert.equal(parseMarkdown('````\n```\n````')[0].text, '```');
  });
  await check('Markdown tables preserve escaped pipes, inline-code pipes, alignment and short rows', () => {
    const block = parseMarkdown('| name | value |\n| :--- | ---: |\n| a\\|b | `x|y` |\n| short |')[0];
    assert.equal(block.kind, 'table');
    assert.equal(block.rows.length, 3);
    assert.equal(plain(block.rows[1].cells[0].spans), 'a|b');
    assert.equal(plain(block.rows[1].cells[1].spans), 'x|y');
    assert.equal(block.rows[0].cells[1].align, 'right');
    assert.equal(plain(block.rows[2].cells[1].spans), '');
  });
  await check('Markdown links handle balanced parentheses and never execute HTML or unsafe schemes', () => {
    const spans = parseMarkdownInline('[**docs**](https://example.com/a_(b)) [bad](javascript:alert(1)) <https://example.com> <script> ![alt](https://example.com/x.png)');
    assert.equal(spans.find(s => s.text === 'docs').url, 'https://example.com/a_(b)');
    assert.equal(spans.find(s => s.text === 'bad').url, '');
    assert.ok(plain(spans).includes('<script>'));
    assert.ok(plain(spans).includes('【图片：alt】'));
    for (const url of ['javascript:alert(1)', 'file:///tmp/a', 'https://example.com\nfoo']) assert.equal(isMarkdownLink(url), false);
  });
  await check('every prefix of a streamed Markdown answer can be parsed', () => {
    const text = '# 标题\n\n**bold** [link](https://example.com)\n\n| A | B |\n| --- | --- |\n| x | y |\n\n```js\nhello\n```';
    for (let i = 0; i <= text.length; i++) assert.ok(Array.isArray(parseMarkdown(text.slice(0, i))));
  });
  // 模拟 ArkUI 的实际复用规则：相同 key 不重新执行 itemGenerator。
  const markdownView = fs.readFileSync(path.join(root, 'components/MarkdownBody.ets'), 'utf8');
  const blockKeyExpression = markdownView.match(/\}, \(block: MarkdownBlock, idx: number\) => ([^\n]+)\)/)[1];
  const blockKey = (block, idx) => vm.runInNewContext(blockKeyExpression, { block, idx });
  function reconcileMarkdown(text, cached) {
    const blocks = parseMarkdown(text);
    const next = new Map();
    const rendered = blocks.map((block, idx) => {
      const id = blockKey(block, idx);
      const view = cached.has(id) ? cached.get(id) : json(block);
      next.set(id, view);
      return view;
    });
    return { cached: next, rendered, expected: json(blocks) };
  }
  await check('streaming Markdown refreshes reused paragraphs, headings, lists, quotes, code and tables', () => {
    for (const text of [
      '你好，很高兴见到你。有什么事吗？',
      '# 完整标题\n\n正文 **粗体内容** 与 `code`',
      '- 第一条内容\n- 第二条完整内容\n\n> 完整引用',
      '```ts\nconst text = "完整代码";\nconsole.log(text);\n```',
      '| 标题一 | 标题二 |\n| --- | --- |\n| 完整内容一 | 完整内容二 |'
    ]) {
      let cached = new Map();
      for (let i = 1; i <= text.length; i++) {
        const result = reconcileMarkdown(text.slice(0, i), cached);
        assert.deepEqual(json(result.rendered), result.expected, `stale Markdown subtree at character ${i}`);
        cached = result.cached;
      }
    }
  });
  await check('closing Markdown formatting changes rendering even when the displayed text is unchanged', () => {
    for (const [before, after] of [['*word*', '**word**'], ['- [ ] task', '- [x] task'],
      ['[link](https://example.com/old)', '[link](https://example.com/new)']]) {
      const first = reconcileMarkdown(before, new Map());
      const second = reconcileMarkdown(after, first.cached);
      assert.deepEqual(json(second.rendered), second.expected);
    }
  });
  await check('segmented WebSocket output reaches the rendered Markdown completely before any history reload', () => {
    const store = new ChatStore();
    const caches = [];
    const segments = ['第一段 **完整内容**', '第二段 `code` 和结束文字'];
    for (let s = 0; s < segments.length; s++) {
      let cached = new Map();
      for (let i = 0; i < segments[s].length; i++) {
        store.handleWs({ type: 'message_delta', data: { text: segments[s][i], platform: 'harmony' } });
        const bubble = store.rows[0].group.bubbles[s];
        const result = reconcileMarkdown(bubble.text, cached);
        assert.deepEqual(json(result.rendered), result.expected);
        cached = result.cached;
      }
      store.handleWs({ type: 'message_seg_end', data: {} });
      caches.push(cached);
    }
    store.handleWs({ type: 'final', data: {} });
    assert.deepEqual(json(store.rows[0].group.bubbles.map(b => b.text)), segments);
    assert.ok(store.rows[0].group.bubbles.every(b => !b.streaming));
  });
  await check('draft text and attachments survive page recreation, including a late upload callback', async () => {
    const old = page(); old.draft.text = '模拟未发送草稿\n第二行';
    let release;
    old.readUriBytes = () => Promise.resolve(new ArrayBuffer(1));
    respond = () => new Promise(resolve => { release = resolve; });
    const uploading = old.attachOne('preview.jpg'); await settle();
    old.aboutToDisappear();
    const next = page(); next.draft = old.draft;
    assert.equal(next.draft.text, '模拟未发送草稿\n第二行');
    assert.equal(next.draft.pending[0].uploading, true);
    release({ file: { local_id: 'synthetic-id', filename: 'preview.jpg', mime: 'image/jpeg' } });
    await uploading;
    assert.equal(next.draft.pending[0].localId, 'synthetic-id');
    assert.equal(next.draft.pending[0].uploading, false);
    next.aboutToDisappear();
  });
  await check('new deltas while reading old messages show one hint and do not move the viewport', async () => {
    const p = page(); let scrolls = 0; p.scroller.scrollEdge = () => scrolls++;
    p.scrollToBottom(); p.pauseFollowing(-30, 0);
    for (let i = 0; i < 5; i++) p.scrollCb({ type: 'message_delta', data: { text: '模拟增量' } });
    await new Promise(resolve => setTimeout(resolve, 70));
    assert.equal(scrolls, 0); assert.equal(p.followingLatest, false); assert.equal(p.hasNewMessages, true);
    p.jumpToLatest(); await new Promise(resolve => setTimeout(resolve, 70));
    assert.equal(scrolls, 1); assert.equal(p.followingLatest, true); assert.equal(p.hasNewMessages, false);
    p.aboutToDisappear();
  });
  await check('returning to a draft reloads completed attachment previews and ignores uploading placeholders', () => {
    const p = page(); p.pageVisible = true;
    const complete = new PendingImage(); complete.localId = 'mock-complete'; complete.mime = 'image/png';
    const uploading = new PendingImage(); uploading.uploading = true;
    p.draft.pending = [complete, uploading];
    const fetched = []; p.loadImageData = (id, mime) => fetched.push({ id, mime });
    p.loadDraftImages(); assert.deepEqual(fetched, [{ id: 'mock-complete', mime: 'image/png' }]);
    p.aboutToDisappear();
  });
  await check('continuous delta traffic scrolls periodically instead of postponing until streaming ends', async () => {
    const p = page(); let scrolls = 0; p.scroller.scrollEdge = () => scrolls++;
    for (let i = 0; i < 10; i++) {
      p.scrollCb({ type: 'message_delta', data: { text: 'mock-delta' } });
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    assert.ok(scrolls >= 1);
    p.aboutToDisappear();
  });
  await check('programmatic movement and layout updates do not disable following; manual return restores it', () => {
    const p = page(); p.pauseFollowing(-20, 6); assert.equal(p.followingLatest, true);
    p.pauseFollowing(-20, 3); assert.equal(p.followingLatest, false);
    p.scrollCb({ type: 'thinking_delta', data: { content: '模拟思考' } });
    assert.equal(p.hasNewMessages, false);
    p.hasNewMessages = true; p.scroller.isAtEnd = () => true; p.finishListScroll();
    assert.equal(p.followingLatest, true); assert.equal(p.hasNewMessages, false);
    p.aboutToDisappear();
  });
  await check('a history response cannot replace the viewport after the user starts reading old rows', async () => {
    const p = page(); p.store.addUser('模拟保留位置', 1); const rows = p.store.rows;
    let release; respond = () => new Promise(resolve => { release = resolve; });
    const loading = p.loadHistory(); await settle(); p.pauseFollowing(-40, 0);
    release({ messages: [] }); await loading;
    assert.equal(p.store.rows, rows); assert.equal(p.historyPending, true);
    respond = () => ({ messages: [{ role: 'user', content: '模拟新快照', created_time: 2 }] });
    p.jumpToLatest(); await settle();
    assert.equal(p.store.rows[0].user.text, '模拟新快照');
    p.aboutToDisappear();
  });

  await check('touching the bottom cancels queued following until the gesture finishes', async () => {
    const p = page(); let scrolls = 0; p.scroller.scrollEdge = () => scrolls++;
    p.scrollToBottom(); p.handleListTouch(0);
    p.scrollCb({ type: 'thinking_delta', data: { content: 'mock-thinking' } });
    await new Promise(resolve => setTimeout(resolve, 70));
    assert.equal(scrolls, 0);
    p.handleListTouch(1);
    await new Promise(resolve => setTimeout(resolve, 70));
    assert.equal(scrolls, 1);
    p.aboutToDisappear();
  });
  await check('bottom drag and rebound cannot resume following while a finger or fling is active', async () => {
    const p = page(); let scrolls = 0; p.scroller.scrollEdge = () => scrolls++;
    p.scroller.isAtEnd = () => true;
    p.handleListTouch(0); p.pauseFollowing(-18, 0);
    p.checkScrollEnd(); assert.equal(p.followingLatest, false);
    p.scrollCb({ type: 'message_delta', data: { text: 'mock-delta' } });
    p.handleListTouch(1); p.checkScrollEnd();
    assert.equal(p.followingLatest, false);
    await new Promise(resolve => setTimeout(resolve, 70)); assert.equal(scrolls, 0);
    p.finishListScroll(); assert.equal(p.followingLatest, true); assert.equal(p.hasNewMessages, false);
    p.aboutToDisappear();
  });
  await check('touch release does not fight a continuing fling, and an already reached edge needs no scroll command', async () => {
    const p = page(); let scrolls = 0; p.scroller.scrollEdge = () => scrolls++;
    p.handleListTouch(0); p.pauseFollowing(30, 0);
    p.scrollCb({ type: 'tool_call', data: { name: 'mock-tool' } });
    p.handleListTouch(1); await new Promise(resolve => setTimeout(resolve, 70));
    assert.equal(scrolls, 0); assert.equal(p.userScrolling, true);
    p.scroller.isAtEnd = () => true; p.finishListScroll();
    await new Promise(resolve => setTimeout(resolve, 70)); assert.equal(scrolls, 0);
    p.aboutToDisappear();
  });
  await check('opening a tool or thinking panel preserves the reading position when its height grows', async () => {
    const p = page(); let scrolls = 0; p.scroller.scrollEdge = () => scrolls++;
    p.scrollToBottom(); p.pauseForInspection(); p.scrollToBottom();
    p.scrollCb({ type: 'tool_result', data: { result: 'mock-result' } });
    await new Promise(resolve => setTimeout(resolve, 70));
    assert.equal(scrolls, 0); assert.equal(p.followingLatest, false); assert.equal(p.hasNewMessages, false);
    p.aboutToDisappear();
  });
  await check('a tool-only round still follows after the group finishes laying out', async () => {
    const p = page(); let scrolls = 0; p.scroller.scrollEdge = () => scrolls++;
    p.store.handleWs({ type: 'thinking_delta', data: { content: 'mock-thinking' } });
    p.store.handleWs({ type: 'tool_call', data: { name: 'mock-tool' } });
    assert.equal(p.store.rows[0].group.bubbles.length, 0);
    p.scrollCb({ type: 'tool_call', data: { name: 'mock-tool' } });
    p.scrollToBottom();
    await new Promise(resolve => setTimeout(resolve, 70)); assert.equal(scrolls, 1);
    p.aboutToDisappear();
  });
  await require('./check-management.cjs')({ load, root, check, page, requests, network, terminal, json, settle,
    ChatStore, PendingImage, TentacleApi, coreFileKit, mediaKit,
    setRespond: fn => { respond = fn; }, setCreateHttp: fn => { createHttpOverride = fn; },
    setResponseCookies: value => { responseCookies = value; } });
  await require('./check-cache.cjs')({ load, root, check, page, requests, TentacleApi, json, settle,
    setRespond: fn => { respond = fn; } });
  await require('./check-local-cache.cjs')({ load, root, check, requests, TentacleApi, coreFileKit, json, settle,
    setRespond: fn => { respond = fn; } });
  await require('./check-streaming-view.cjs')({ load, root, check, ChatStore, json });
  await require('./check-graph-scene.cjs')({ load, root, check, json, mediaKit, settle });
  await require('./check-chat-recovery.cjs')({ load, root, check, page, requests, json, settle, TentacleApi,
    setRespond: fn => { respond = fn; } });
  await require('./check-plugins.cjs')({ load, root, check, page, requests, json, settle, TentacleApi,
    setRespond: fn => { respond = fn; }, appStorage });
  await check('phone registration retains HTTP status for JSON and proxy HTML errors', async () => {
    const { ApiFailure } = load(path.join(root, 'model/Types.ets'));
    const api = new TentacleApi();
    api.serverUrl = 'https://synthetic.invalid';
    try {
      for (const body of ['{"detail":"Not Found"}', '<html>synthetic proxy error</html>']) {
        createHttpOverride = () => ({ destroy() {}, request(url, options, callback) {
          callback(null, { responseCode: 404, result: body });
        } });
        await assert.rejects(api.registerPhone({ device_id: 'synthetic-device', secret: 'synthetic-secret',
          alarms: true, live_view: false, push_token: '', timezone: 'Asia/Shanghai' }),
        error => error instanceof ApiFailure && error.httpStatus === 404);
      }
    } finally { createHttpOverride = null; }
  });
  checks += await require('./check-phone.cjs')();
  console.log(`${checks} isolated checks passed.`);
})().catch(error => { console.error(error); process.exitCode = 1; });
