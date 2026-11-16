// Synthetic OS and network only. Never connects to a phone, Push Kit, or backend.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_MODULE || 'C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const root = path.resolve(__dirname, '../entry/src/main/ets');
let checks = 0;
async function check(name, fn) { await fn(); checks++; console.log('PASS ' + name); }

function rig() {
  const loaded = new Map(), values = new Map(), app = new Map(), calls = [], acks = [], states = [];
  let publish = async () => 17, save = async () => {}, start = async () => ({ resultCode: 0 });
  let notification = async () => {};
  let token = async () => 'synthetic-push-token';
  const api = {
    getServerUrl: () => 'https://synthetic.invalid', onWsEvent(cb) { this.event = cb; }, onPhoneReset() {},
    setPhoneIdentity() {}, registerPhone: async () => ({ registered: true, push_configured: true }),
    unregisterPhone: async () => ({}), phoneState: async () => states.shift() || ({ actions: [], rounds: [] }),
    phoneReceipt: async (...args) => acks.push(args),
  };
  const reminders = {
    ReminderType: { REMINDER_TYPE_CALENDAR: 1 },
    ActionButtonType: { ACTION_BUTTON_TYPE_CLOSE: 0, ACTION_BUTTON_TYPE_SNOOZE: 1 },
    publishReminder: async value => { calls.push(['alarm', value]); return publish(value); },
    cancelReminder: async id => calls.push(['cancel', id]),
  };
  const liveViewManager = {
    LayoutType: { LAYOUT_TYPE_PROGRESS: 3 }, CapsuleType: { CAPSULE_TYPE_TEXT: 1 },
    isLiveViewEnabled: async () => true,
    startLiveView: async view => { calls.push(['start', view]); return start(view); },
    stopLiveView: async view => { calls.push(['stop', view]); return { resultCode: 0 }; },
  };
  function load(file) {
    file = path.resolve(file);
    if (loaded.has(file)) return loaded.get(file);
    const source = fs.readFileSync(file, 'utf8');
    const out = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } });
    const exports = {}; loaded.set(file, exports);
    vm.runInNewContext(out.outputText, {
      exports, console, Error, Observed: cls => cls, setInterval: () => 1, clearInterval() {},
      AppStorage: { setOrCreate: (key, value) => app.set(key, value) },
      require(name) {
        if (name.endsWith('/TentacleApi')) return { TentacleApi: { getInstance: () => api } };
        if (name.startsWith('.')) return load(path.resolve(path.dirname(file), name + '.ets'));
        if (name === '@kit.PerformanceAnalysisKit') return { hilog: { info() {}, warn() {} } };
        if (name === '@kit.AbilityKit') return { wantAgent: {
          getWantAgent: async value => value, OperationType: { START_ABILITY: 0 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 0 },
        } };
        if (name === '@kit.BackgroundTasksKit') return { reminderAgentManager: reminders };
        if (name === '@kit.NotificationKit') return { notificationManager: { requestEnableNotification: () => notification() } };
        if (name === '@kit.LiveViewKit') return { liveViewManager };
        if (name === '@kit.PushKit') return { pushService: { getToken: () => token() } };
        if (name === '@kit.ArkTS') return { util: { generateRandomUUID: () => require('node:crypto').randomUUID() } };
        if (name === '@kit.ArkData') return { preferences: { getPreferencesSync: () => ({
          getSync: (key, fallback) => values.get(key) ?? fallback,
          putSync: (key, value) => values.set(key, value), flush: () => save(),
        }) } };
        throw new Error('Unexpected import ' + name);
      },
    }, { filename: file });
    return exports;
  }
  const { PhoneIntegration } = load(path.join(root, 'service/PhoneIntegration.ets'));
  const { PhoneNative } = load(path.join(root, 'service/PhoneNative.ets'));
  const phone = new PhoneIntegration();
  phone.init({ applicationInfo: { name: 'synthetic.app' } });
  phone.foreground = true; phone.alarms = true; phone.registeredServer = api.getServerUrl();
  return { phone, api, PhoneNative, load, calls, acks, values, app, states,
    setPublish: fn => { publish = fn; }, setSave: fn => { save = fn; }, setStart: fn => { start = fn; },
    setNotification: fn => { notification = fn; }, setToken: fn => { token = fn; } };
}
const action = () => ({ id: 'a'.repeat(32), kind: 'alarm.create', title: 'Synthetic reminder',
  at: Date.now() + 3600000, expires_at: Date.now() + 3500000 });

async function runPhoneChecks() {
  checks = 0;
  await check('ordinary Push token binding does not enable or create a live view', async () => {
    const r = rig(); const registrations = [];
    r.api.registerPhone = async body => { registrations.push(body); return { registered: true, push_configured: true }; };
    assert.equal(await r.phone.refreshPushToken(), 'synthetic-push-token');
    assert.equal(registrations.length, 1);
    assert.equal(registrations[0].push_token, 'synthetic-push-token');
    assert.equal(registrations[0].live_view, false);
    assert.equal(r.calls.length, 0);
  });
  await check('failed Push token retrieval does not send an empty registration or expose private errors', async () => {
    const r = rig(); let registered = false;
    r.api.registerPhone = async () => { registered = true; return {}; };
    r.setToken(async () => { throw Object.assign(new Error('synthetic-private-token-error'), { code: 1009400002 }); });
    await assert.rejects(r.phone.refreshPushToken(), /推送标识获取失败.*1009400002/);
    assert.equal(registered, false);
    assert.doesNotMatch(r.app.get('phoneStatus'), /synthetic-private-token-error/);
  });
  await check('a token completing after connection changes cannot bind under the new connection', async () => {
    const r = rig(); let release, registered = false;
    r.api.registerPhone = async () => { registered = true; return {}; };
    r.setToken(() => new Promise(resolve => { release = resolve; }));
    const pending = r.phone.refreshPushToken();
    while (!release) await new Promise(resolve => setImmediate(resolve));
    r.phone.disconnect(); release('synthetic-late-token');
    await assert.rejects(pending, /连接已变化/);
    assert.equal(registered, false);
    assert.equal(r.phone.getPushToken(), '');
  });
  await check('missing backend endpoints show an update error without blaming notification permissions', async () => {
    const r = rig();
    const { ApiFailure } = r.load(path.join(root, 'model/Types.ets'));
    for (const code of [404, 405, 403, 503]) {
      r.api.registerPhone = async () => { throw new ApiFailure('synthetic-private-server-detail', undefined, code); };
      await assert.rejects(r.phone.configure(true, false), new RegExp('HTTP ' + code));
      const message = r.app.get('phoneStatus');
      assert.match(message, new RegExp('HTTP ' + code));
      assert.doesNotMatch(message, /通知|synthetic-private-server-detail/);
      assert.equal(r.phone.registeredServer, '');
    }
    assert.equal(r.calls.length, 0);
  });
  await check('notification failure stops before backend registration and preserves its system code', async () => {
    const r = rig(); let registered = false;
    r.api.registerPhone = async () => { registered = true; return { registered: true }; };
    r.setNotification(async () => { throw Object.assign(new Error('synthetic-private-error'), { code: 1600004 }); });
    await assert.rejects(r.phone.configure(true, false), /通知.*1600004/);
    assert.equal(registered, false);
    assert.doesNotMatch(r.app.get('phoneStatus'), /synthetic-private-error|服务器/);
  });
  await check('registration network and authentication errors stay distinct and a retry can recover', async () => {
    const r = rig();
    const { UnauthorizedError } = r.load(path.join(root, 'model/Types.ets'));
    r.api.registerPhone = async () => { throw new UnauthorizedError(); };
    await assert.rejects(r.phone.configure(true, false), /登录已失效/);
    r.api.registerPhone = async () => { throw new Error('synthetic-secret-url'); };
    await assert.rejects(r.phone.configure(true, false), /检查服务器连接/);
    assert.doesNotMatch(r.app.get('phoneStatus'), /synthetic-secret-url/);
    r.api.registerPhone = async () => ({ registered: true, push_configured: false });
    await r.phone.configure(true, false);
    assert.equal(r.app.get('phoneStatus'), '手机能力已连接');
  });
  await check('native alarms preserve the requested date and receive success only from the OS', async () => {
    const r = rig(), input = action();
    await r.phone.execute(input);
    const alarm = r.calls.find(c => c[0] === 'alarm')[1], date = new Date(input.at);
    assert.deepEqual(JSON.parse(JSON.stringify(alarm.dateTime)), { year: date.getFullYear(), month: date.getMonth() + 1,
      day: date.getDate(), hour: date.getHours(), minute: date.getMinutes(), second: date.getSeconds() });
    assert.equal(alarm.ringDuration, 60);
    assert.deepEqual(r.acks[0], [input.id, 'executed', '17']);
  });
  await check('duplicate delivery and process recreation never create the same alarm twice', async () => {
    const r = rig(), input = action();
    await r.phone.execute(input); await r.phone.execute(input);
    assert.equal(r.calls.filter(c => c[0] === 'alarm').length, 1);
    r.phone.receipts = JSON.parse(r.values.get('receipts:' + r.api.getServerUrl()));
    await r.phone.execute(input);
    assert.equal(r.calls.filter(c => c[0] === 'alarm').length, 1);
  });
  await check('OS permission failure produces failure, never an alarm success receipt', async () => {
    const r = rig(); r.setPublish(async () => { throw new Error('synthetic permission denied'); });
    await r.phone.execute(action());
    assert.equal(r.acks[0][1], 'failed');
  });
  await check('a crash after entering the OS boundary stays unknown rather than replaying', async () => {
    const r = rig(), input = action();
    r.phone.receipts = [{ id: input.id, status: 'unknown', result: 'synthetic interrupted' }];
    await r.phone.execute(input);
    assert.equal(r.calls.length, 0); assert.equal(r.acks[0][1], 'unknown');
  });
  await check('failed persistence prevents any OS side effect', async () => {
    const r = rig(); r.setSave(async () => { throw new Error('synthetic disk full'); });
    await assert.rejects(r.phone.execute(action()));
    assert.equal(r.calls.length, 0); assert.equal(r.acks.length, 0);
  });
  await check('expired and malformed alarm commands cannot reach the OS', async () => {
    const r = rig();
    await r.phone.execute({ ...action(), expires_at: Date.now() - 1 });
    await r.phone.execute({ ...action(), id: 'b'.repeat(32), at: NaN });
    assert.equal(r.calls.length, 0); assert.equal(r.acks.every(a => a[1] === 'failed'), true);
  });
  await check('disconnecting while the OS responds cannot acknowledge under a new connection', async () => {
    const r = rig(); let release;
    r.setPublish(() => new Promise(resolve => { release = resolve; }));
    const pending = r.phone.execute(action());
    while (!release) await new Promise(resolve => setImmediate(resolve));
    r.phone.disconnect(); release(42); await pending;
    assert.equal(r.acks.length, 0);
    assert.equal(JSON.parse(r.values.get('receipts:' + r.api.getServerUrl()))[0].status, 'executed');
  });
  await check('disabled phone features add no network or native work to sending', async () => {
    const r = rig(); r.phone.alarms = false; r.phone.live = false;
    assert.equal(await r.phone.prepareRound('synthetic'), undefined);
    assert.equal(r.calls.length, 0);
  });
  await check('thinking starts once; a timeout is not completion; terminal state ends the right live view', async () => {
    const r = rig(); r.phone.live = true;
    const meta = await r.phone.prepareRound('synthetic-request');
    assert.equal(meta.event, 'PROGRESS');
    await r.phone.finishRound('other-request', 'completed');
    await r.phone.finishRound('synthetic-request', 'unconfirmed');
    assert.equal(r.calls.filter(c => c[0] === 'stop').length, 0);
    await r.phone.finishRound('synthetic-request', 'completed');
    const stopped = r.calls.find(c => c[0] === 'stop')[1];
    assert.equal(stopped.id, meta.activity_id); assert.equal(stopped.liveViewData.primary.title, '回复完成');
    await r.phone.finishRound('synthetic-request', 'completed');
    assert.equal(r.calls.filter(c => c[0] === 'stop').length, 1);
  });
  await check('native live view rejection never attaches nonexistent activity metadata to chat', async () => {
    const r = rig(); r.phone.live = true; r.setStart(async () => ({ resultCode: 123 }));
    assert.equal(await r.phone.prepareRound('synthetic'), undefined);
    assert.equal(r.phone.rounds.length, 0);
  });
  await check('returning to the foreground reconciles a missed terminal event without chat history writes', async () => {
    const r = rig(); r.phone.live = true;
    await r.phone.prepareRound('synthetic-request');
    r.states.push({ actions: [], rounds: [{ request_id: 'synthetic-request', status: 'failed' }] });
    await r.phone.sync();
    const stopped = r.calls.find(c => c[0] === 'stop')[1];
    assert.equal(stopped.liveViewData.primary.title, '本轮已结束');
  });
  await check('send rejection distinguishes plugin live_view / stale identity from DeviceAccessGate 403', async () => {
    const r = rig(); r.phone.live = true;
    const { ApiFailure } = r.load(path.join(root, 'model/Types.ets'));
    const meta = await r.phone.prepareRound('synthetic-rejected');
    assert.ok(meta);
    assert.equal(await r.phone.handleSendRejection('synthetic-rejected', new ApiFailure('新设备入口已关闭', undefined, 403)), false);
    assert.equal(r.calls.filter(c => c[0] === 'stop').length, 0);
    assert.equal(await r.phone.handleSendRejection('synthetic-rejected', new ApiFailure('鸿蒙插件配置已禁用实况窗同步', undefined, 403)), true);
    assert.equal(r.calls.filter(c => c[0] === 'stop').length, 1);
    assert.match(r.app.get('phoneStatus'), /禁用实况窗同步/);
  });
  console.log(`${checks} phone checks passed.`);
  return checks;
}
module.exports = runPhoneChecks;
if (require.main === module) runPhoneChecks().catch(error => { console.error(error); process.exitCode = 1; });
