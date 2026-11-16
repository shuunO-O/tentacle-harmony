// Synthetic plugin protocol, PluginsPage, ConfigurationPage, and tool-badge checks.
const path = require('node:path');
const assert = require('node:assert/strict');

module.exports = async ({ load, root, check, page, requests, json, settle, TentacleApi, setRespond, appStorage }) => {
  const { PluginsPage } = load(path.join(root, 'view/PluginsPage.ets'));
  const { ConfigurationPage } = load(path.join(root, 'view/ConfigurationPage.ets'));
  const { PhoneIntegration } = load(path.join(root, 'service/PhoneIntegration.ets'));
  const { parseToolSourceBadge, parseKeyValueLines } = load(path.join(root, 'model/Plugins.ets'));
  const { ApiFailure } = load(path.join(root, 'model/Types.ets'));
  const api = TentacleApi.getInstance();

  const pluginSnapshot = (extra = {}) => ({
    revision: 'p'.repeat(64),
    plugins: [
      {
        id: 'harmony',
        kind: 'local',
        enabled: true,
        trusted: true,
        bundled: true,
        saved_enabled: true,
        saved_trusted: true,
        status: 'active',
        error: null,
        manifest: {
          id: 'harmony',
          name: '鸿蒙手机联动',
          version: '1.0.0',
          description: 'Synthetic harmony plugin',
          permissions: ['tools:register', 'web:routes'],
          optional_env: ['HUAWEI_PUSH_PROJECT_ID'],
          config_schema: {
            action_wait_seconds: { key: 'action_wait_seconds', label: '等待秒数', type: 'number', default: 12 },
            allow_alarms: { key: 'allow_alarms', label: '允许闹钟', type: 'boolean', default: true },
            allow_live_view: { key: 'allow_live_view', label: '允许实况窗', type: 'boolean', default: true },
          },
        },
        permission_details: [
          { permission: 'tools:register', level: 'low', summary: '注册工具' },
          { permission: 'web:routes', level: 'high', summary: '挂载路由' },
        ],
        config: { action_wait_seconds: 12, allow_alarms: true, allow_live_view: true },
        saved_config: { action_wait_seconds: 12, allow_alarms: true, allow_live_view: true },
        disabled_tools: [],
        saved_disabled_tools: [],
        tools: [{ raw_name: 'phone_alarm', name: 'p_harmony__phone_alarm', description: 'Alarm', enabled: true }],
        env_vars: ['HUAWEI_PUSH_PROJECT_ID'],
        env_status: { HUAWEI_PUSH_PROJECT_ID: false },
        missing_env: [],
        pending_restart: false,
      },
      {
        id: 'weather',
        kind: 'local',
        enabled: false,
        trusted: false,
        bundled: false,
        saved_enabled: false,
        saved_trusted: false,
        status: 'pending',
        manifest: {
          id: 'weather',
          name: '天气',
          version: '0.1.0',
          config_schema: {
            domains: { key: 'domains', label: '域名', type: 'string_list', default: [] },
          },
        },
        tools: [{ raw_name: 'forecast', name: 'p_weather__forecast', enabled: false }],
        env_vars: [],
        missing_env: [],
        pending_restart: false,
      },
    ],
    mcp_servers: [
      {
        id: 'github',
        kind: 'mcp',
        enabled: true,
        trusted: true,
        status: 'active',
        transport: 'stdio',
        tools: [{ raw_name: 'search', name: 'mcp_github__search', enabled: true }],
        env_vars: ['GITHUB_TOKEN'],
        env_status: { GITHUB_TOKEN: true },
        missing_env: [],
        mcp_config: {
          enabled: true,
          trusted: true,
          transport: 'stdio',
          command: 'npx',
          args: ['-y', '@synthetic/mcp-github'],
          env: {},
          env_secrets: { GITHUB_PERSONAL_ACCESS_TOKEN: 'GITHUB_TOKEN' },
          timeout_seconds: 30,
          disabled_tools: [],
        },
        saved_config: {
          enabled: true,
          trusted: true,
          transport: 'stdio',
          command: 'npx',
          args: ['-y', '@synthetic/mcp-github'],
          env: {},
          env_secrets: { GITHUB_PERSONAL_ACCESS_TOKEN: 'GITHUB_TOKEN' },
          timeout_seconds: 30,
          disabled_tools: [],
        },
      },
    ],
    permission_catalog: {},
    restart_required: false,
    restart: { available: true, state: 'idle' },
    ...extra,
  });

  await check('harmony companion endpoints use /api/plugins/ext/harmony/* without legacy paths', async () => {
    const prevUrl = api.serverUrl;
    requests.length = 0;
    api.serverUrl = 'https://synthetic.invalid';
    api.setPhoneIdentity('synthetic-device-id-1234', 's'.repeat(32));
    try {
      setRespond(url => {
        if (url.endsWith('/register')) return { registered: true, push_configured: false };
        if (url.endsWith('/state')) return { actions: [], rounds: [] };
        return { ok: true };
      });
      await api.registerPhone({
        device_id: 'synthetic-device-id-1234',
        secret: 's'.repeat(32),
        push_token: '',
        timezone: 'Asia/Shanghai',
        alarms: true,
        live_view: true,
      });
      await api.phoneState();
      await api.phoneReceipt('a'.repeat(32), 'executed', '17');
      await api.unregisterPhone();
      const paths = requests.map(r => r.options.method + ' ' + new URL(r.url, 'https://synthetic.invalid').pathname);
      assert.deepEqual(paths, [
        'POST /api/plugins/ext/harmony/register',
        'GET /api/plugins/ext/harmony/state',
        'POST /api/plugins/ext/harmony/actions/' + 'a'.repeat(32) + '/receipt',
        'DELETE /api/plugins/ext/harmony/register',
      ]);
      assert.equal(paths.some(p => p.includes('/api/harmony/')), false);
    } finally {
      api.setPhoneIdentity('', '');
      api.serverUrl = prevUrl;
    }
  });

  await check('sendChat puts live view metadata under client_meta.live_view without top-level phone_live_view', async () => {
    requests.length = 0;
    setRespond((url, opts) => ({
      ok: true,
      total_tokens: 1,
      round: {
        round_id: 'r1',
        request_id: JSON.parse(opts.extraData).request_id,
        source: 'user',
        platform: 'harmony',
        status: 'completed',
        stop_reason: 'complete',
        error: null,
      },
    }));
    await api.sendChat('hello', [], 'harmony-meta-check', { activity_id: 11, event: 'PROGRESS' });
    const body = JSON.parse(requests.at(-1).options.extraData);
    assert.deepEqual(body.client_meta, { live_view: { activity_id: 11, event: 'PROGRESS' } });
    assert.equal('phone_live_view' in body, false);
  });

  await check('chat send retries once without client_meta when live_view is disabled or phone identity is stale, but not on DeviceAccessGate 403', async () => {
    const phone = PhoneIntegration.getInstance();
    const origPrepare = phone.prepareRound;
    const origFinish = phone.finishRound;
    const finished = [];
    phone.prepareRound = async () => ({ activity_id: 17, event: 'PROGRESS' });
    phone.finishRound = async (id, status) => { finished.push([id, status]); };
    try {
      // Case 1: allow_live_view=false -> 403 with 实况窗 -> retries once without client_meta
      requests.length = 0;
      let calls = 0;
      setRespond((url, opts) => {
        if (url.includes('/history')) return { messages: [], has_more: false };
        calls++;
        if (calls === 1) return { __httpStatus: 403, body: { detail: '鸿蒙插件配置已禁用实况窗同步' } };
        return { ok: true, total_tokens: 1 };
      });
      const p1 = page();
      p1.draft.text = 'synthetic message';
      p1.send();
      await settle();
      const sendBodies1 = requests.filter(r => r.url.endsWith('/api/chat/send')).map(r => JSON.parse(r.options.extraData));
      assert.equal(sendBodies1.length, 2);
      assert.deepEqual(sendBodies1[0].client_meta, { live_view: { activity_id: 17, event: 'PROGRESS' } });
      assert.equal('client_meta' in sendBodies1[1], false);
      assert.equal(p1.store.sending, false);
      assert.match(appStorage.get('phoneStatus'), /禁用实况窗同步/);
      p1.aboutToDisappear();

      // Case 2: stale phone identity -> 403 手机未注册 -> clears identity and retries once
      requests.length = 0;
      api.setPhoneIdentity('synthetic-stale-id-1234', 's'.repeat(32));
      calls = 0;
      setRespond((url) => {
        if (url.includes('/history')) return { messages: [], has_more: false };
        calls++;
        if (calls === 1) return { __httpStatus: 403, body: { detail: '手机未注册或登录已变化，请重新连接' } };
        return { ok: true, total_tokens: 1 };
      });
      const p2 = page();
      p2.draft.text = 'synthetic stale';
      p2.send();
      await settle();
      const sendReqs2 = requests.filter(r => r.url.endsWith('/api/chat/send'));
      assert.equal(sendReqs2.length, 2);
      assert.equal(sendReqs2[0].options.header['X-Tentacle-Device'], 'synthetic-stale-id-1234');
      assert.equal('X-Tentacle-Device' in sendReqs2[1].options.header, false);
      assert.match(appStorage.get('phoneStatus'), /注册已失效/);
      p2.aboutToDisappear();

      // Case 3: DeviceAccessGate 403 -> must NOT retry
      requests.length = 0;
      setRespond(() => ({ __httpStatus: 403, body: { detail: '新设备入口已关闭' } }));
      const p3 = page();
      p3.draft.text = 'blocked gate';
      p3.send();
      await settle();
      assert.equal(requests.filter(r => r.url.endsWith('/api/chat/send')).length, 1);
      assert.equal(p3.store.rows.at(-1).group.isError, true);
      p3.aboutToDisappear();
    } finally {
      phone.prepareRound = origPrepare;
      phone.finishRound = origFinish;
      api.setPhoneIdentity('', '');
    }
  });

  await check('parseToolSourceBadge formats plugin and MCP namespaces while leaving built-in tools clean', () => {
    assert.equal(parseToolSourceBadge('p_harmony__phone_alarm'), '插件 · harmony');
    assert.equal(parseToolSourceBadge('p_browser__browser'), '插件 · browser');
    assert.equal(parseToolSourceBadge('mcp_github__search_code'), 'MCP · github');
    assert.equal(parseToolSourceBadge('schedule_list'), '');
    assert.equal(parseToolSourceBadge('p_incomplete'), '');
  });

  await check('PluginsPage edits local plugin config, validates numbers, toggles disabled_tools, writes .env, and manages MCP & restart', async () => {
    const p = new PluginsPage();
    p.visible = true;
    requests.length = 0;
    setRespond((url, opts) => {
      if (url === '/api/plugins' && opts.method === 'GET') return pluginSnapshot();
      if (url === '/api/plugins/local/harmony/decision' && opts.method === 'POST') {
        return pluginSnapshot({ restart_required: true });
      }
      if (url.startsWith('/api/plugins/local/weather') && opts.method === 'DELETE') {
        return pluginSnapshot({ plugins: [pluginSnapshot().plugins[0]] });
      }
      if (url === '/api/plugins/env' && opts.method === 'POST') {
        return { ok: true, name: 'HUAWEI_PUSH_PROJECT_ID', configured: true };
      }
      if (url === '/api/plugins/mcp/notion' && opts.method === 'POST') {
        return pluginSnapshot();
      }
      if (url === '/api/plugins/mcp/github/reconnect' && opts.method === 'POST') {
        return pluginSnapshot();
      }
      if (url.startsWith('/api/plugins/mcp/github') && opts.method === 'DELETE') {
        return pluginSnapshot({ mcp_servers: [] });
      }
      if (url === '/api/plugins/restart' && opts.method === 'POST') {
        return { available: true, state: 'waiting' };
      }
      return pluginSnapshot();
    });

    await p.load();
    assert.equal(p.snapshot.plugins.length, 2);
    assert.equal(p.localNumericInputs.harmony.action_wait_seconds, '12');

    // Invalid number stays local without HTTP request
    const beforeInvalid = requests.length;
    p.setLocalNumericInput('harmony', 'action_wait_seconds', 'abc');
    await p.decideLocal(p.snapshot.plugins[0], true);
    assert.equal(requests.length, beforeInvalid);
    assert.match(p.message, /有效数值/);

    // Valid config + disabled_tools decision
    p.setLocalNumericInput('harmony', 'action_wait_seconds', '20');
    p.setLocalConfigValue('harmony', 'allow_live_view', false);
    p.toggleLocalTool('harmony', p.snapshot.plugins[0].tools[0], false);
    await p.decideLocal(p.snapshot.plugins[0], true);
    const decisionReq = requests.find(r => r.url.endsWith('/api/plugins/local/harmony/decision'));
    assert.deepEqual(JSON.parse(decisionReq.options.extraData), {
      revision: 'p'.repeat(64),
      enabled: true,
      trusted: true,
      config: { action_wait_seconds: 20, allow_alarms: true, allow_live_view: false },
      disabled_tools: ['phone_alarm'],
    });
    assert.equal(p.snapshot.restart_required, true);

    // .env write clears secret from component state immediately
    p.openEnvModal('HUAWEI_PUSH_PROJECT_ID');
    p.envSecretValue = 'synthetic-secret-value-never-retained';
    await p.saveEnvSecret();
    assert.equal(p.envSecretValue, '');
    assert.equal(p.envTargetName, '');
    const envReq = requests.find(r => r.url.endsWith('/api/plugins/env'));
    assert.deepEqual(JSON.parse(envReq.options.extraData), {
      name: 'HUAWEI_PUSH_PROJECT_ID',
      value: 'synthetic-secret-value-never-retained',
    });

    // Delete non-bundled plugin
    await p.deleteLocal('weather');
    assert.ok(requests.some(r => r.url.endsWith('/api/plugins/local/weather?revision=' + 'p'.repeat(64) + '&delete_files=true') && r.options.method === 'DELETE'));

    // MCP create (streamable_http), toggle+reconnect, delete
    p.openNewMcp();
    p.mcpId = 'notion';
    p.mcpTransport = 'streamable_http';
    p.mcpUrl = 'https://synthetic.invalid/mcp';
    p.mcpAuthBearerEnv = 'NOTION_TOKEN';
    p.mcpHeaderSecretsText = 'X-Api-Key=NOTION_KEY';
    p.mcpHeadersText = 'X-Client=tentacle';
    p.mcpDisabledToolsText = 'drop_all, delete_page';
    await p.saveMcp();
    const mcpSaveReq = requests.find(r => r.url.endsWith('/api/plugins/mcp/notion'));
    assert.deepEqual(JSON.parse(mcpSaveReq.options.extraData), {
      revision: 'p'.repeat(64),
      config: {
        enabled: true,
        trusted: true,
        transport: 'streamable_http',
        url: 'https://synthetic.invalid/mcp',
        headers: { 'X-Client': 'tentacle' },
        header_secrets: { 'X-Api-Key': 'NOTION_KEY' },
        auth_bearer_env: 'NOTION_TOKEN',
        timeout_seconds: 30,
        disabled_tools: ['drop_all', 'delete_page'],
      },
    });
    assert.throws(() => parseKeyValueLines('INVALID_LINE_NO_EQ'), /KEY=VALUE/);

    await p.toggleMcp(p.snapshot.mcp_servers[0], false);
    assert.ok(requests.some(r => r.url.endsWith('/api/plugins/mcp/github/reconnect') && r.options.method === 'POST'));
    await p.deleteMcp('github');
    assert.ok(requests.some(r => r.url.endsWith('/api/plugins/mcp/github?revision=' + 'p'.repeat(64)) && r.options.method === 'DELETE'));

    // Restart request
    await p.performRestart();
    assert.ok(requests.some(r => r.url.endsWith('/api/plugins/restart') && r.options.method === 'POST'));
    p.aboutToDisappear();
  });

  await check('ConfigurationPage filters plugins.items.*, edits string_list as arrays, and submits .env credentials safely', async () => {
    const p = new ConfigurationPage();
    p.visible = true;
    const baseSnapshot = {
      revision: 'c'.repeat(64),
      config_version: 2,
      fields: [
        { path: 'web_tools.api_key_env', label: '网页工具密钥', kind: 'env', value: 'PARALLEL_API_KEY', active: 'PARALLEL_API_KEY',
          default: '', group: '公开网页工具', choices: [], nullable: false, inheritable: false, protected: false, pending: false,
          source: 'file', effect: 'restart', minimum: null, maximum: null, help: '', configured: false },
        { path: 'custom.allowlist', label: '白名单', kind: 'string_list', value: ['a.invalid'], active: ['a.invalid'],
          default: [], group: '公开网页工具', choices: [], nullable: false, inheritable: false, protected: false, pending: false,
          source: 'file', effect: 'restart', minimum: null, maximum: null, help: '' },
        { path: 'plugins.items.harmony.enabled', label: '启用插件', kind: 'boolean', value: true, active: true,
          default: false, group: '插件 · 鸿蒙手机联动', choices: [], nullable: false, inheritable: false, protected: false, pending: false,
          source: 'file', effect: 'restart', minimum: null, maximum: null, help: '' },
      ],
      entities: { providers: [], models: [], roles: [] },
      provider_types: {},
      tools: {},
      connection_status: {},
      history: [],
      active_role: 'chat',
      active_model: { name: 'synthetic', provider_id: null, model_id: null, api_style: 'chat' },
      applying: false,
      error: null,
      restart_required: false,
      restart: { available: true, state: 'idle' },
    };
    p.data = baseSnapshot;
    p.group = '公开网页工具';

    assert.deepEqual(json(p.groups()), ['公开网页工具']);
    assert.equal(p.editorFields('all').some(f => f.path.startsWith('plugins.items.')), false);
    assert.equal(p.text(baseSnapshot.fields[1]), 'a.invalid');

    // string_list edit submits string[] in preview & save
    const { parseStringListLines } = load(path.join(root, 'model/Plugins.ets'));
    p.edit(baseSnapshot.fields[1], parseStringListLines(' one.invalid \n\n two.invalid '));
    assert.deepEqual(json(p.changes()['custom.allowlist']), ['one.invalid', 'two.invalid']);

    // dirty draft blocks opening .env editor
    p.openEnvEditor(baseSnapshot.fields[0]);
    assert.equal(p.envTargetPath, '');
    assert.match(p.message, /先保存或放弃/);

    // clean state submits /api/configuration/environment and clears secret
    p.draft = {};
    requests.length = 0;
    setRespond((url, opts) => {
      if (url === '/api/configuration/environment' && opts.method === 'POST') {
        return { status: { ...baseSnapshot, revision: 'd'.repeat(64) } };
      }
      return { ...baseSnapshot, revision: 'd'.repeat(64) };
    });
    p.openEnvEditor(baseSnapshot.fields[0]);
    assert.equal(p.envTargetPath, 'web_tools.api_key_env');
    p.envSecretValue = 'sk-synthetic-config-secret';
    await p.saveEnvSecret();
    assert.equal(p.envSecretValue, '');
    assert.equal(p.envTargetPath, '');
    const envCall = requests.find(r => r.url.endsWith('/api/configuration/environment'));
    assert.deepEqual(JSON.parse(envCall.options.extraData), {
      path: 'web_tools.api_key_env',
      value: 'sk-synthetic-config-secret',
      revision: 'c'.repeat(64),
    });
    p.aboutToDisappear();
  });

  await check('StatusPage /api/maintenance check, restart, and WebSocket updates', async () => {
    const api = TentacleApi.getInstance();
    const prevServerUrl = api.serverUrl;
    api.serverUrl = 'https://synthetic.invalid';
    const { StatusPage } = load(path.join(root, 'view/StatusPage.ets'));
    const statusBody = {
      time: 1700000100,
      connections: 2,
      tokens: { accumulated: 1200 },
      session: { session_id: 'sess-init', start_time: 1700000000 },
      subconscious: null,
      heartbeat: { interval_seconds: 600, next_beat_at: 1700000700 },
      db: { raw_messages: 10, sessions: 1, summaries: 1, goals: 0, tasks: 0, files: 0, usage_logs: 2 },
      usage: null,
    };
    const maintBody = {
      available: true,
      can_update: true,
      web_allowed: true,
      version: { version: '1.2.3', install_mode: 'wheel' },
      check: { current: '1.2.3', latest: '1.2.4', update_available: true, summary: 'fix' },
      operation: null,
    };
    setRespond((url, opts) => {
      if (url.endsWith('/api/status')) { return statusBody; }
      if (url.includes('/api/maintenance') && opts.method !== 'POST') { return maintBody; }
      if (url.endsWith('/api/configuration')) {
        return { revision: 'rev-maint', fields: [], entities: { providers: [], models: [], roles: [] },
          provider_types: {}, tools: {}, backups: [], apply_state: 'idle', applying: false, restart_required: false,
          restart: { state: 'idle' } };
      }
      if (url.endsWith('/api/maintenance') && opts.method === 'POST') {
        return { id: '' };
      }
      return {};
    });

    const s = new StatusPage();
    try {
      s.aboutToAppear();
      await settle();
      assert.equal(s.sessionId, 'sess-init');
      assert.equal(s.maintenance.version.version, '1.2.3');
      assert.equal(appStorage.get('updateAvailable'), true);

      requests.length = 0;
      await s.runMaintenance('check');
      const checkCall = requests.find(r => r.url.endsWith('/api/maintenance') && r.options.method === 'POST');
      assert.deepEqual(JSON.parse(checkCall.options.extraData), { action: 'check' });

      requests.length = 0;
      await s.runMaintenance('restart');
      const restartCall = requests.find(r => r.url.endsWith('/api/maintenance') && r.options.method === 'POST');
      assert.deepEqual(JSON.parse(restartCall.options.extraData), { action: 'restart', revision: 'rev-maint' });

      s.wsCb({
        type: 'maintenance.updated',
        data: { available: true, can_update: false, check: { latest: '1.2.4', update_available: false } },
      });
      assert.equal(appStorage.get('updateAvailable'), false);
      s.wsCb({
        type: 'status.snapshot',
        data: {
          time: 1700000200,
          session: { session_id: 'sess-ws', start_time: 1700000000 },
          db: { raw_messages: 42 },
        },
      });
      assert.equal(s.sessionId, 'sess-ws');
      assert.equal(s.dbRaw, 42);
    } finally {
      s.aboutToDisappear();
      api.serverUrl = prevServerUrl;
    }
  });

  await check('ConfigurationPage 4-section taxonomy, field search, model creation, and reembed restart', async () => {
    const { configurationPathSection, estimateWrappedLines } = load(path.join(root, 'model/ConfigurationNavigation.ets'));
    assert.equal(configurationPathSection('providers.main.type'), 'models');
    assert.equal(configurationPathSection('models.gpt.vision'), 'models');
    assert.equal(configurationPathSection('roles.chat.model'), 'models');
    assert.equal(configurationPathSection('memory.decay'), 'memory');
    assert.equal(configurationPathSection('concepts.enabled'), 'memory');
    assert.equal(configurationPathSection('embeddings.dim'), 'memory');
    assert.equal(configurationPathSection('webui.host'), 'channels');
    assert.equal(configurationPathSection('qqbot.token'), 'channels');
    assert.equal(configurationPathSection('media_inputs.max'), 'channels');
    assert.equal(configurationPathSection('heartbeat.interval'), 'runtime');

    assert.equal(estimateWrappedLines('', 5, 28), 1);
    assert.equal(estimateWrappedLines('hello', 5, 28), 1);
    assert.equal(estimateWrappedLines('a'.repeat(57), 5, 28), 3);
    assert.equal(estimateWrappedLines('中'.repeat(15), 5, 28), 2);
    assert.equal(estimateWrappedLines('a\nb\nc\nd\ne\nf', 5, 28), 5);

    const api = TentacleApi.getInstance();
    const prevServerUrl = api.serverUrl;
    api.serverUrl = 'https://synthetic.invalid';
    const { ConfigurationPage } = load(path.join(root, 'view/ConfigurationPage.ets'));
    const snap = {
      revision: 'rev-cfg',
      fields: [
        { path: 'models.m1.label', label: '模型名称', value: 'M1', kind: 'text', group: '模型 · m1', help: '别名' },
        { path: 'models.m1.vision', label: '视觉能力', value: false, kind: 'boolean', group: '模型 · m1', help: '支持图片输入' },
      ],
      entities: {
        providers: [{ id: 'prov-1', type: 'openai' }],
        models: [{ id: 'm1', provider: 'prov-1' }],
        roles: [],
      },
      provider_types: { openai: { auth: 'api_key', api_style: 'responses', protocols: ['chat', 'responses'] } },
      tools: {},
      backups: [],
      apply_state: 'idle',
      applying: false,
      restart_required: false,
      restart: { state: 'idle' },
    };
    setRespond((url, opts) => {
      if (url.endsWith('/api/configuration/structure') && opts.method === 'POST') {
        return { revision: 'rev-cfg', valid: true, changes: [{ path: 'models.m-new', summary: '新增模型' }], warnings: [] };
      }
      if (url.endsWith('/api/configuration/restart') && opts.method === 'POST') {
        return { state: 'waiting' };
      }
      return snap;
    });

    const p = new ConfigurationPage();
    try {
      p.aboutToAppear();
      await settle();
      p.group = '模型 · m1';
      p.edit(snap.fields[1], true);
      p.showDirtyOnly = true;
      assert.deepEqual(json(p.visibleEditorFields('all').map(f => f.path)), ['models.m1.vision']);
      p.showDirtyOnly = false;
      p.fieldSearch = '图片';
      assert.deepEqual(json(p.visibleEditorFields('all').map(f => f.path)), ['models.m1.vision']);
      p.fieldSearch = '';
      p.draft = {};

      p.openCreate('models', 'prov-1');
      p.createId = 'm-new';
      p.createName = 'gpt-synthetic';
      p.createApiStyle = 'responses';
      p.createContextWindow = '262144';
      p.createVision = true;
      p.createLabel = 'Synthetic';
      requests.length = 0;
      p.create();
      await settle();
      const structCall = requests.find(r => r.url.endsWith('/api/configuration/structure'));
      assert.deepEqual(JSON.parse(structCall.options.extraData), {
        revision: 'rev-cfg',
        apply: false,
        operations: [{
          op: 'create',
          kind: 'models',
          id: 'm-new',
          value: {
            provider: 'prov-1',
            name: 'gpt-synthetic',
            api_style: 'responses',
            context_window: 262144,
            vision: true,
            label: 'Synthetic',
          },
        }],
      });

      requests.length = 0;
      await api.restartApplication('rev-reembed', true);
      const restartCall = requests.find(r => r.url.endsWith('/api/configuration/restart'));
      assert.deepEqual(JSON.parse(restartCall.options.extraData), { revision: 'rev-reembed', reembed: true });
    } finally {
      p.aboutToDisappear();
      api.serverUrl = prevServerUrl;
    }
  });

  await check('DedupPage uses /api/memory/dedup*, supports reevaluate, audit log, and WS progress', async () => {
    const api = TentacleApi.getInstance();
    const prevServerUrl = api.serverUrl;
    api.serverUrl = 'https://synthetic.invalid';
    const { DedupPage } = load(path.join(root, 'view/DedupPage.ets'));
    setRespond((url, opts) => {
      if (url.includes('/api/memory/dedup/audit')) {
        return { total: 1, entries: [{ id: 1, actor: 'user', action: 'merged', pair_id: 'pair-7', created_at: 1700000000 }] };
      }
      if (url.includes('/api/memory/dedup?') || url.endsWith('/api/memory/dedup')) {
        return { run: { status: 'running', stage: 'scan' }, counts: { pending: 2, merged: 1 }, pairs: [] };
      }
      return { ok: true };
    });

    const d = new DedupPage();
    try {
      d.aboutToAppear();
      await settle();
      assert.equal(appStorage.get('dedupRunning'), true);
      assert.ok(requests.some(r => r.url.includes('/api/memory/dedup?state=pending&offset=0')));

      requests.length = 0;
      await d.run('reevaluate', 'pair-7');
      assert.ok(requests.some(r => r.url.endsWith('/api/memory/dedup/pair-7/reevaluate') && r.options.method === 'POST'));

      d.wsCb({
        type: 'dedup.progress',
        data: { event: 'progress', run: { status: 'completed', stage: 'done' }, counts: { pending: 0, merged: 3 } },
      });
      assert.equal(d.data.run.status, 'completed');
      assert.equal(d.data.counts.merged, 3);

      d.mode = 'audit';
      requests.length = 0;
      await d.load();
      assert.ok(requests.some(r => r.url.includes('/api/memory/dedup/audit?actor=all&offset=0')));
      assert.equal(d.auditTotal, 1);
      assert.equal(d.auditEntries.length, 1);
    } finally {
      d.aboutToDisappear();
      api.serverUrl = prevServerUrl;
    }
  });

  await check('SubagentsPage handles subagent.updated WS and pre-fills chat prompt via askInChat', async () => {
    const api = TentacleApi.getInstance();
    const prevServerUrl = api.serverUrl;
    api.serverUrl = 'https://synthetic.invalid';
    const { SubagentsPage } = load(path.join(root, 'view/SubagentsPage.ets'));
    setRespond(() => ({ enabled: true, execution_blocked: false, has_more: false, tasks: [] }));
    const s = new SubagentsPage();
    try {
      s.aboutToAppear();
      await settle();
      s.wsCb({
        type: 'subagent.updated',
        data: {
          enabled: true,
          tasks: [{ id: 'sub-9', status: 'running', objective: 'Check synthetic logs', final_summary: '', created_at: 1 }],
        },
      });
      assert.equal(s.tasks.length, 1);
      assert.equal(s.tasks[0].id, 'sub-9');
      s.askInChat(s.tasks[0]);
      assert.match(appStorage.get('pendingChatPrompt'), /sub-9/);
      assert.match(appStorage.get('pendingChatPrompt'), /Check synthetic logs/);
    } finally {
      s.aboutToDisappear();
      api.serverUrl = prevServerUrl;
    }
  });

  await check('ConfigurationPage ignores identical numeric string edits and updateSettings omits agent_name', async () => {
    const { isConfigValueSameAsSaved } = load(path.join(root, 'model/ConfigurationNavigation.ets'));
    const numField = { path: 'heartbeat.interval', label: '心跳', kind: 'number', group: '心跳', value: 30, active: 30,
      default: 30, effect: 'round', source: 'user', choices: [], nullable: false, inheritable: false, protected: false,
      pending: false, minimum: null, maximum: null, help: '' };
    assert.equal(isConfigValueSameAsSaved(numField, '30'), true);
    assert.equal(isConfigValueSameAsSaved(numField, '12'), false);
    assert.equal(isConfigValueSameAsSaved(numField, ''), false);

    const api = TentacleApi.getInstance();
    const prevServerUrl = api.serverUrl;
    api.serverUrl = 'https://synthetic.invalid';
    requests.length = 0;
    setRespond(() => ({ agent_name: 'Tentacle', show_reasoning: true, split_messages: false, has_password: false }));
    try {
      await api.updateSettings(true, false);
      const putCall = requests.find(r => r.url.endsWith('/api/settings') && r.options.method === 'PUT');
      assert.deepEqual(JSON.parse(putCall.options.extraData), { show_reasoning: true, split_messages: false });
    } finally {
      api.serverUrl = prevServerUrl;
    }
  });
};
