// Isolated logic verification for DSH client, projection, auth cookies, mux streams & denoising.
// Zero real device, server, account, or private conversation data used.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const ts = require(process.env.TYPESCRIPT_MODULE || 'C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');

const root = path.resolve(__dirname, '../entry/src/main/ets');
const loaded = new Map();
const httpRequests = [];
const wsConnections = [];
const prefValues = new Map();
const appStorage = new Map();

let httpHandler = () => ({ responseCode: 200, cookies: '', header: {}, result: '{}' });

const network = {
  http: {
    RequestMethod: { POST: 'POST', GET: 'GET', PUT: 'PUT', DELETE: 'DELETE' },
    HttpDataType: { ARRAY_BUFFER: 1 },
    createHttp: () => ({
      destroy() {},
      request(url, options, callback) {
        httpRequests.push({ url, options });
        Promise.resolve().then(() => httpHandler(url, options)).then(
          res => callback(null, {
            responseCode: res.responseCode ?? 200,
            cookies: res.cookies ?? '',
            header: res.header ?? {},
            result: typeof res.result === 'string' ? res.result : JSON.stringify(res.result ?? {})
          }),
          err => callback({ message: err.message })
        );
      }
    })
  },
  webSocket: {
    createWebSocket: () => {
      const handlers = {};
      const sent = [];
      let closed = false;
      const ws = {
        sent,
        handlers,
        on(ev, cb) { handlers[ev] = cb; },
        emit(ev, err, data) { if (handlers[ev]) handlers[ev](err, data); },
        async connect(url, options) {
          wsConnections.push({ url, options, ws });
          return true;
        },
        async send(text) {
          if (closed) throw new Error('closed');
          sent.push(JSON.parse(text));
          return true;
        },
        async close() { closed = true; return true; }
      };
      return ws;
    }
  }
};

function load(file) {
  file = path.resolve(file);
  if (loaded.has(file)) return loaded.get(file);
  const source = fs.readFileSync(file, 'utf8');
  const transpiled = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true }
  });
  const exports = {};
  loaded.set(file, exports);
  vm.runInNewContext(transpiled.outputText, {
    exports, Error, ArrayBuffer, Uint8Array, Intl, Date, console,
    setTimeout, clearTimeout, setInterval, clearInterval,
    Observed: cls => cls,
    AppStorage: { setOrCreate: (k, v) => appStorage.set(k, v), get: k => appStorage.get(k) },
    require(name) {
      if (name.startsWith('.')) {
        const target = path.resolve(path.dirname(file), name + '.ets');
        if (fs.existsSync(target)) return load(target);
        return {};
      }
      if (name === '@kit.NetworkKit') return network;
      if (name === '@kit.PerformanceAnalysisKit') return { hilog: { info() {}, warn() {}, error() {} } };
      if (name === '@kit.CryptoArchitectureKit') {
        return {
          cryptoFramework: {
            createMd: () => {
              const hash = crypto.createHash('sha256');
              return { update: async b => hash.update(b.data), digest: async () => ({ data: new Uint8Array(hash.digest()) }) };
            }
          }
        };
      }
      if (name === '@kit.ArkTS') {
        return {
          util: {
            generateRandomUUID: () => crypto.randomUUID(),
            TextEncoder: class { encodeInto(t) { return new Uint8Array(Buffer.from(t, 'utf8')); } },
            Base64Helper: class { encodeToStringSync(b) { return Buffer.from(b).toString('base64'); } }
          }
        };
      }
      if (name === '@kit.ArkData') {
        return {
          preferences: {
            getPreferencesSync: () => ({
              getSync: (k, fb) => prefValues.get(k) ?? fb,
              putSync: (k, v) => prefValues.set(k, v),
              flush: () => Promise.resolve()
            })
          }
        };
      }
      return {};
    }
  }, { filename: file });
  return exports;
}

const {
  buildRpcPacket,
  parseRpcResponse,
  sanitizeConversationText,
  projectSessionRecords,
  applyAssistantStreamFrame,
  createEmptyLiveAttempt,
  groupSessionsByWorkspace,
  buildPinnedSessionEntries,
  buildArchivedSessions,
  parseWorkspaceBaseline,
  parseSessionSearchResult,
  parseModelCatalog,
  formatModelCapsule,
  parseDirectoryListing,
  parseWaterfallPrompt,
  isConversationVisibleEvent
} = load(path.join(root, 'dsh/DshModels.ets'));
const { TentacleApi } = load(path.join(root, 'service/TentacleApi.ets'));
const { DshClient } = load(path.join(root, 'dsh/DshClient.ets'));

let passed = 0;
async function check(name, fn) {
  await fn();
  console.log('PASS ' + name);
  passed += 1;
}

const json = v => JSON.parse(JSON.stringify(v));

const settle = async () => {
  for (let i = 0; i < 4; i++) {
    await new Promise(resolve => setImmediate(resolve));
  }
};

(async () => {
  await check('sanitizeConversationText strips system-reminder and environment wrappers while keeping real user text', () => {
    const raw = '<system-reminder>\n# AGENTS.md\nsecret instructions\n</system-reminder>\n\n帮我重构 DSH 页面\n<environment_context>pwd=/repo</environment_context>';
    assert.equal(sanitizeConversationText(raw), '帮我重构 DSH 页面');
    assert.equal(sanitizeConversationText('<local-command-caveat>ignore</local-command-caveat>'), '');
  });

  await check('projectSessionRecords hides system/command/compaction noise in conversation while preserving trajectory & pairing tool calls', () => {
    const records = [
      { type: 'event', event: { type: 'turn/start', seq: 1, time: 1000, data: { turn: 1 } } },
      { type: 'event', event: { type: 'system/message', seq: 2, time: 1005, data: { message: { content: [{ type: 'text', text: 'System prompt' }] } } } },
      { type: 'event', event: { type: 'permission/preset', seq: 3, time: 1006, data: { preset: 'workspace-write' } } },
      {
        type: 'event',
        event: {
          type: 'user/message',
          seq: 4,
          time: 1010,
          data: {
            turn: 1,
            content: [{ type: 'text', text: '<system-reminder>AGENTS rules</system-reminder>\n检查路由文件' }]
          }
        }
      },
      { type: 'event', event: { type: 'step/start', seq: 5, time: 1100, data: { turn: 1, step: 1 } } },
      {
        type: 'event',
        event: {
          type: 'assistant/message',
          seq: 6,
          time: 2300,
          data: {
            turn: 1,
            step: 1,
            message: {
              source: { model: 'deepseek-reasoner' },
              content: [
                { type: 'reasoning', reasoning: '先查看 router 文件结构' },
                { type: 'tool-call', callId: 'call-1', name: 'read_file', arguments: '{"path":"src/router.ts"}' }
              ]
            },
            usage: { inputTokens: 120, outputTokens: 45, cacheReadTokens: 80 }
          }
        }
      },
      { type: 'event', event: { type: 'tool/call', seq: 7, time: 2310, data: { turn: 1, step: 1, callId: 'call-1', name: 'read_file', arguments: '{"path":"src/router.ts"}' } } },
      {
        type: 'event',
        event: {
          type: 'tool/result',
          seq: 8,
          time: 2510,
          data: {
            message: {
              source: { callId: 'call-1' },
              content: [{ type: 'text', text: '{"output":"export const routes = [];"}' }]
            }
          }
        }
      },
      { type: 'event', event: { type: 'compaction/summary', seq: 9, time: 2520, data: { summary: [{ type: 'text', text: 'Compacted earlier turns' }] } } },
      { type: 'event', event: { type: 'step/start', seq: 10, time: 2600, data: { turn: 1, step: 2 } } },
      {
        type: 'event',
        event: {
          type: 'assistant/message',
          seq: 11,
          time: 3600,
          data: {
            turn: 1,
            step: 2,
            message: {
              source: { model: 'deepseek-reasoner' },
              content: [{ type: 'text', text: '路由目前为空数组，位于 `src/router.ts`。' }]
            },
            usage: { inputTokens: 200, outputTokens: 30, cacheReadTokens: 150 }
          }
        }
      },
      { type: 'event', event: { type: 'turn/end', seq: 12, time: 3650, data: { turn: 1, reason: { kind: 'completed' } } } }
    ];

    const proj = projectSessionRecords(records);
    assert.deepEqual(json(proj.conversation.map(c => c.kind)), ['user', 'reasoning', 'tool', 'assistant']);
    assert.equal(proj.conversation[0].text, '检查路由文件');
    assert.equal(proj.conversation[1].text, '先查看 router 文件结构');
    assert.equal(proj.conversation[2].toolName, 'read_file');
    assert.equal(proj.conversation[2].detail, 'src/router.ts');
    assert.equal(proj.conversation[2].toolState, 'success');
    assert.equal(proj.conversation[2].toolOutput, 'export const routes = [];');
    assert.equal(proj.conversation[2].durationMs, 200);
    assert.equal(proj.conversation[3].text, '路由目前为空数组，位于 `src/router.ts`。');

    assert.equal(proj.turns.length, 1);
    assert.equal(proj.stats.uncachedInputTokens, 320);
    assert.equal(proj.stats.outputTokens, 75);
    assert.equal(proj.stats.cacheReadTokens, 230);
    assert.ok(proj.stats.thinkingMs > 0);
    assert.equal(proj.stats.toolMs, 200);
    assert.equal(isConversationVisibleEvent('compaction/summary'), false);
    assert.equal(isConversationVisibleEvent('unknown/future-event'), false);
    assert.equal(isConversationVisibleEvent('command/done'), true);
    assert.equal(isConversationVisibleEvent('assistant/message'), true);
  });

  await check('projectSessionRecords filters system-injected user/message kinds (agent-instructions, runtime-context, time-context) from conversation and projects command flow nodes', () => {
    const records = [
      { type: 'event', event: { type: 'turn/start', seq: 1, time: 1000, data: { turn: 1 } } },
      {
        type: 'event',
        event: {
          type: 'user/message',
          seq: 2,
          time: 1001,
          data: {
            turn: 1,
            source: { kind: 'agent-instructions', changes: [{ path: 'AGENTS.md' }] },
            content: [{ type: 'text', text: '# AGENTS.md\nAlways follow repository rules' }]
          }
        }
      },
      {
        type: 'event',
        event: {
          type: 'user/message',
          seq: 3,
          time: 1002,
          data: {
            turn: 1,
            source: { kind: 'runtime-context' },
            content: [{ type: 'text', text: 'OS=Linux Arch=x64' }]
          }
        }
      },
      {
        type: 'event',
        event: {
          type: 'user/message',
          seq: 4,
          time: 1003,
          data: {
            turn: 1,
            source: { kind: 'time-context', form: 'snapshot' },
            content: [{ type: 'text', text: '2026-11-19 00:00 Asia/Shanghai' }]
          }
        }
      },
      {
        type: 'event',
        event: {
          type: 'user/message',
          seq: 5,
          time: 1004,
          data: {
            turn: 1,
            source: { kind: 'user', rpcId: 'rpc-user-1' },
            content: [{ type: 'text', text: '修复模型切换弹窗打不开的问题' }]
          }
        }
      },
      {
        type: 'event',
        event: {
          type: 'command/run',
          seq: 6,
          time: 1100,
          data: { commandId: 'cmd-1', name: 'compact', source: { kind: 'user' } }
        }
      },
      {
        type: 'event',
        event: {
          type: 'command/done',
          seq: 7,
          time: 1200,
          data: { commandId: 'cmd-1', kind: 'success', text: '已压缩 12 条消息' }
        }
      },
      {
        type: 'event',
        event: {
          type: 'command/run',
          seq: 8,
          time: 1300,
          data: { commandId: 'cmd-2', name: 'unknown', source: { kind: 'user' } }
        }
      },
      {
        type: 'event',
        event: {
          type: 'command/done',
          seq: 9,
          time: 1350,
          data: { commandId: 'cmd-2', kind: 'error', text: '不支持当前上下文' }
        }
      }
    ];

    const proj = projectSessionRecords(records);
    assert.deepEqual(json(proj.conversation.map(c => c.kind)), ['user', 'status', 'error']);
    assert.equal(proj.conversation[0].text, '修复模型切换弹窗打不开的问题');
    assert.equal(proj.conversation[1].title, '/compact');
    assert.equal(proj.conversation[1].detail, '已压缩 12 条消息');
    assert.equal(proj.conversation[1].toolState, 'success');
    assert.equal(proj.conversation[2].title, '/unknown');
    assert.equal(proj.conversation[2].text, '不支持当前上下文');

    assert.equal(proj.turns.length, 1);
    assert.equal(proj.turns[0].title, '修复模型切换弹窗打不开的问题');
    const stepLabels = json(proj.turns[0].steps.map(s => s.label));
    assert.ok(stepLabels.includes('agent-instructions'));
    assert.ok(stepLabels.includes('runtime-context'));
    assert.ok(stepLabels.includes('time-context'));
    assert.ok(stepLabels.includes('user'));
  });

  await check('live assistant-stream deltas incrementally build reasoning, tool calls, and text before commit', () => {
    let live = createEmptyLiveAttempt();
    live = applyAssistantStreamFrame(live, { type: 'start', attemptId: 'att-1', turn: 2, step: 1 });
    live = applyAssistantStreamFrame(live, { type: 'chunk', chunk: { type: 'block-start', index: 0, blockType: 'reasoning' } });
    live = applyAssistantStreamFrame(live, { type: 'chunk', chunk: { type: 'reasoning-delta', index: 0, text: '分析需求' } });
    live = applyAssistantStreamFrame(live, { type: 'chunk', chunk: { type: 'text-delta', index: 1, text: '开始修改。' } });
    live = applyAssistantStreamFrame(live, { type: 'chunk', chunk: { type: 'tool-call-delta', index: 2, id: 'tc-9', name: 'write_file', argumentsDelta: '{"path":"a.ts"}' } });

    const proj = projectSessionRecords([], undefined, live);
    assert.equal(proj.conversation.length, 3);
    assert.equal(proj.conversation[0].kind, 'reasoning');
    assert.equal(proj.conversation[0].streaming, true);
    assert.equal(proj.conversation[1].kind, 'assistant');
    assert.equal(proj.conversation[1].text, '开始修改。');
    assert.equal(proj.conversation[2].kind, 'tool');
    assert.equal(proj.conversation[2].toolName, 'write_file');

    live = applyAssistantStreamFrame(live, { type: 'end', outcome: { kind: 'committed' } });
    assert.equal(live.active, false);
  });

  await check('multipart/form-data RPC response metadata extraction and RPC packet validation', () => {
    const reqJson = buildRpcPacket('rpc-42', 'session/list', { _request: {} });
    const parsedReq = JSON.parse(reqJson);
    assert.equal(parsedReq.type, 'client-request');
    assert.equal(parsedReq.method, 'session/list');

    const boundary = '----dshBoundary99';
    const mpBody = `--${boundary}\r\nContent-Disposition: form-data; name="metadata"\r\nContent-Type: application/json\r\n\r\n{"type":"server-response","rpcId":"rpc-42","result":{"ok":true,"value":{"items":[]}}}\r\n--${boundary}--\r\n`;
    const out = parseRpcResponse(mpBody, 'rpc-42', 'session/list', `multipart/form-data; boundary=${boundary}`);
    assert.equal(out.ok, true);
    assert.equal(out.hasValue, true);

    const voidOut = parseRpcResponse('{"type":"server-response","rpcId":"rpc-99","result":{"ok":true}}', 'rpc-99', '$events/result');
    assert.equal(voidOut.ok, true);
    assert.equal(voidOut.hasValue, false);
  });

  await check('model catalog projection formats capsule label with effort and resolves defaults', () => {
    const raw = {
      default: { provider: 'deepseek', model: 'deepseek-reasoner', reasoningEffort: 'high' },
      groups: [
        {
          id: 'deepseek',
          name: 'DeepSeek',
          models: [
            {
              id: 'deepseek-reasoner',
              name: 'DeepSeek R1',
              reasoning: {
                defaultEffort: 'medium',
                efforts: [{ id: 'low', name: 'Low' }, { id: 'high', name: 'High' }, { id: 'xhigh', name: 'XHigh' }]
              }
            }
          ]
        }
      ]
    };
    const cat = parseModelCatalog(raw);
    assert.equal(cat.flatModels.length, 1);
    assert.deepEqual(json(cat.flatModels[0].efforts), ['low', 'high', 'xhigh']);
    assert.equal(formatModelCapsule(cat.defaultSelection, cat.flatModels), 'DeepSeek R1 · high');
    assert.equal(formatModelCapsule(undefined, cat.flatModels), '选择模型');
  });

  await check('workspace grouping excludes subagent & archived sessions and groups unassigned sessions by cwd', () => {
    const groups = groupSessionsByWorkspace(
      [
        { sessionId: 's1', title: 'S1', titleFromHost: true, cwd: '/ws/app', updatedAt: 100, running: false, blank: false, parentSessionId: '', origin: '', asOfSeq: 5, planActive: false, planPending: false },
        { sessionId: 's2', title: 'Sub', titleFromHost: true, cwd: '/ws/app', updatedAt: 200, running: true, blank: false, parentSessionId: 's1', origin: 'subagent', asOfSeq: 2, planActive: false, planPending: false },
        { sessionId: 's3', title: 'Arch', titleFromHost: true, cwd: '/ws/app', updatedAt: 300, running: false, blank: false, parentSessionId: '', origin: '', asOfSeq: 9, planActive: false, planPending: false },
        { sessionId: 's4', title: 'Other', titleFromHost: true, cwd: '/ws/lib/', updatedAt: 150, running: false, blank: false, parentSessionId: '', origin: '', asOfSeq: 1, planActive: false, planPending: false }
      ],
      [{ workspaceId: 'w1', path: '/ws/app', title: 'App', sessionIds: ['s1'], createdAt: '', updatedAt: '' }],
      ['s3']
    );
    assert.equal(groups.length, 2);
    assert.deepEqual(json(groups[0].sessions.map(s => s.sessionId)), ['s1']);
    assert.deepEqual(json(groups[1].sessions.map(s => s.sessionId)), ['s4']);
    const dir = parseDirectoryListing({ path: '/ws/app', home: '/ws', crumbs: [{ name: 'ws', path: '/ws' }], entries: [{ name: 'src', path: '/ws/app/src', hidden: false }], truncated: false });
    assert.equal(dir.entries[0].name, 'src');
  });

  await check('DshClient authorizes via Netscape cookie, omits duplicate ws Origin, handles selectModel and waterfall approval', async () => {
    httpRequests.length = 0;
    wsConnections.length = 0;
    const api = TentacleApi.getInstance();
    api.serverUrl = 'https://synthetic.tentacle.test';
    api.token = 'tok-secret';
    api.deviceCookie = 'dev-cookie-1';

    httpHandler = (url, options) => {
      if (url.endsWith('/api/subagents/dsh/access')) {
        return {
          responseCode: 200,
          cookies: '#HttpOnly_synthetic.tentacle.test\tFALSE\t/coding/\tTRUE\t0\ttentacle_coding\tcoding-tok-99',
          result: { url: '/coding/' }
        };
      }
      const pkt = JSON.parse(options.extraData);
      if (url.endsWith('/coding/api/session/list')) {
        assert.match(options.header.Cookie, /tentacle_device=dev-cookie-1/);
        assert.match(options.header.Cookie, /tentacle_coding=coding-tok-99/);
        assert.equal(options.header.Origin, 'https://synthetic.tentacle.test');
        assert.equal(options.header['Content-Length'], String(options.extraData.length));
        return {
          responseCode: 200,
          result: {
            type: 'server-response',
            rpcId: pkt.rpcId,
            result: { ok: true, value: { items: [{ sessionId: 'sess-a', cwd: '/work/proj', updatedAt: 999, running: false, blank: false }] } }
          }
        };
      }
      if (url.endsWith('/coding/api/session/modelCatalog')) {
        return {
          responseCode: 200,
          result: { type: 'server-response', rpcId: pkt.rpcId, result: { ok: true, value: { groups: [] } } }
        };
      }
      if (url.endsWith('/coding/api/session/selectModel')) {
        assert.equal(pkt.payload.args.request.model, 'deepseek-reasoner');
        assert.equal(pkt.payload.args.request.reasoningEffort, 'high');
        return {
          responseCode: 200,
          result: {
            type: 'server-response',
            rpcId: pkt.rpcId,
            result: { ok: true, value: { selected: { provider: 'deepseek', model: 'deepseek-reasoner', reasoningEffort: 'high' } } }
          }
        };
      }
      if (url.endsWith('/coding/api/$events/result')) {
        assert.equal(pkt.payload.args.clientId, 'cli-1');
        assert.equal(pkt.payload.args.eventId, 'ev-apr-1');
        assert.equal(pkt.payload.args.outcome.kind, 'result');
        assert.equal(pkt.payload.args.outcome.value, 'allowed-once');
        return {
          responseCode: 200,
          result: { type: 'server-response', rpcId: pkt.rpcId, result: { ok: true } }
        };
      }
      if (url.endsWith('/coding/api/commands/list')) {
        assert.equal(pkt.payload.args.agentId, 'sess-a');
        return {
          responseCode: 200,
          result: {
            type: 'server-response',
            rpcId: pkt.rpcId,
            result: { ok: true, value: [{ name: 'compact', description: 'Compact conversation' }] }
          }
        };
      }
      if (url.endsWith('/coding/api/commands/execute')) {
        assert.equal(pkt.payload.args.agentId, 'sess-a');
        if (pkt.payload.args.line === '/compact') {
          return {
            responseCode: 200,
            result: {
              type: 'server-response',
              rpcId: pkt.rpcId,
              result: { ok: true, value: { commandId: 'cmd-101', result: { kind: 'success', text: '已压缩上下文' } } }
            }
          };
        }
        return {
          responseCode: 200,
          result: { type: 'server-response', rpcId: pkt.rpcId, result: { ok: true } }
        };
      }
      return {
        responseCode: 200,
        result: { type: 'server-response', rpcId: pkt.rpcId, result: { ok: true, value: {} } }
      };
    };

    const client = DshClient.getInstance();
    client.resetAllState();
    const ok = await client.ensureConnected();
    assert.equal(ok, true);
    assert.equal(client.sessions.length, 1);
    assert.equal(wsConnections.length, 1);
    assert.equal(wsConnections[0].url, 'wss://synthetic.tentacle.test/coding/api/remote.mux');
    assert.equal(wsConnections[0].options.header.origin, undefined);
    assert.equal(wsConnections[0].options.header.Origin, undefined);
    assert.match(wsConnections[0].options.header.Cookie, /tentacle_coding=coding-tok-99/);

    // Simulated $events ready + approval/request waterfall frame
    const ws = wsConnections[0].ws;
    const eventsOpen = ws.sent.find(f => f.endpoint === '$events');
    assert.ok(eventsOpen);
    ws.emit('message', null, JSON.stringify({ type: 'item', streamId: eventsOpen.streamId, value: { type: 'ready', clientId: 'cli-1', host: { home: '/home/u' } } }));
    ws.emit('message', null, JSON.stringify({
      type: 'item',
      streamId: eventsOpen.streamId,
      value: { type: 'waterfall', event: 'approval/request', eventId: 'ev-apr-1', agentId: 'sess-a', request: { toolName: 'bash', reason: 'Run tests' } }
    }));
    await settle();
    assert.equal(client.pendingPrompts.length, 1);
    assert.equal(client.pendingPrompts[0].toolName, 'bash');

    await client.answerApproval(client.pendingPrompts[0], true);
    assert.equal(client.pendingPrompts.length, 0);

    const sel = await client.selectModel('sess-a', 'deepseek', 'deepseek-reasoner', 'high');
    assert.equal(sel.reasoningEffort, 'high');

    client.activeSessionId = 'sess-a';
    await client.refreshCommands('sess-a');
    assert.equal(client.commandsLoadState, 'loaded');
    assert.equal(client.activeCommands.length, 1);
    assert.equal(client.activeCommands[0].name, '/compact');

    const cmdOk = await client.executeCommand('sess-a', '/compact', []);
    assert.equal(cmdOk.matched, true);
    assert.equal(cmdOk.kind, 'success');
    assert.equal(cmdOk.text, '已压缩上下文');

    const cmdMiss = await client.executeCommand('sess-a', '/nonexistent', []);
    assert.equal(cmdMiss.matched, false);

    // AskUser prompt parser sanity
    const qPrompt = parseWaterfallPrompt({
      event: 'user-questions/request',
      eventId: 'ev-q-2',
      agentId: 'sess-a',
      request: { questions: [{ id: 'q1', question: 'Keep API?', options: [{ label: 'Yes' }, { label: 'No' }] }] }
    });
    assert.equal(qPrompt.questions[0].options.length, 2);

    client.resetAllState();
  });

  await check('pinned & archived session grouping and search parser', async () => {
    const baseline = parseWorkspaceBaseline({
      items: [
        { workspaceId: 'ws-1', path: '/work/alpha', title: 'Alpha', sessionIds: ['s1', 's2', 's3'], createdAt: '', updatedAt: '' },
        { workspaceId: 'ws-2', path: '/work/beta', title: 'Beta', sessionIds: ['s4'], createdAt: '', updatedAt: '' }
      ],
      archivedSessionIds: ['s3'],
      pinnedSessionIds: ['s4', 's1', 's3']
    });
    assert.deepEqual(json(baseline.pinnedSessionIds), ['s4', 's1', 's3']);
    assert.deepEqual(json(baseline.archivedSessionIds), ['s3']);

    const sessions = [
      { sessionId: 's1', title: 'First', titleFromHost: true, cwd: '/work/alpha', updatedAt: 100, running: false, blank: false, parentSessionId: '', origin: '', asOfSeq: 1, planActive: false, planPending: false },
      { sessionId: 's2', title: 'Second', titleFromHost: true, cwd: '/work/alpha', updatedAt: 200, running: true, blank: false, parentSessionId: '', origin: '', asOfSeq: 2, planActive: false, planPending: false },
      { sessionId: 's3', title: 'Archived', titleFromHost: true, cwd: '/work/alpha', updatedAt: 300, running: false, blank: false, parentSessionId: '', origin: '', asOfSeq: 3, planActive: false, planPending: false },
      { sessionId: 's4', title: 'Pinned Beta', titleFromHost: true, cwd: '/work/beta', updatedAt: 150, running: false, blank: false, parentSessionId: '', origin: '', asOfSeq: 4, planActive: false, planPending: false },
      { sessionId: 's5', title: 'Sub', titleFromHost: true, cwd: '/work/alpha', updatedAt: 400, running: false, blank: false, parentSessionId: 's2', origin: 'subagent', asOfSeq: 5, planActive: false, planPending: false }
    ];

    const pinned = buildPinnedSessionEntries(sessions, baseline.workspaces, baseline.archivedSessionIds, baseline.pinnedSessionIds);
    assert.deepEqual(json(pinned.map(p => p.session.sessionId)), ['s4', 's1']);
    assert.equal(pinned[0].workspaceTitle, 'Beta');
    assert.equal(pinned[1].workspaceTitle, 'Alpha');

    const groupsNoDup = groupSessionsByWorkspace(sessions, baseline.workspaces, baseline.archivedSessionIds, baseline.pinnedSessionIds);
    assert.equal(groupsNoDup.length, 2);
    assert.deepEqual(json(groupsNoDup[0].sessions.map(s => s.sessionId)), ['s2']);
    assert.deepEqual(json(groupsNoDup[1].sessions.map(s => s.sessionId)), []);

    const archived = buildArchivedSessions(sessions, baseline.workspaces, baseline.archivedSessionIds);
    assert.equal(archived.length, 1);
    assert.equal(archived[0].session.sessionId, 's3');
    assert.equal(archived[0].workspaceTitle, 'Alpha');

    const searchRes = parseSessionSearchResult({
      items: [{ sessionId: 's2', snippet: '...matched router config...' }],
      hasMore: true
    });
    assert.equal(searchRes.hasMore, true);
    assert.equal(searchRes.items.length, 1);
    assert.equal(searchRes.items[0].snippet, '...matched router config...');
  });

  await check('DshClient workspace pin/archive/rename/delete & session search RPCs', async () => {
    httpRequests.length = 0;
    wsConnections.length = 0;

    httpHandler = (url, options) => {
      if (url.endsWith('/api/subagents/dsh/access')) {
        return {
          responseCode: 200,
          cookies: '#HttpOnly_synthetic.tentacle.test\tFALSE\t/coding/\tTRUE\t0\ttentacle_coding\tcoding-tok-100',
          result: { url: '/coding/' }
        };
      }
      const pkt = JSON.parse(options.extraData);
      if (url.endsWith('/coding/api/session/list')) {
        return {
          responseCode: 200,
          result: {
            type: 'server-response',
            rpcId: pkt.rpcId,
            result: {
              ok: true,
              value: {
                items: [
                  { sessionId: 'sess-1', cwd: '/work/a', updatedAt: 500, running: true, blank: false },
                  { sessionId: 'sess-2', cwd: '/work/a', updatedAt: 400, running: false, blank: false }
                ]
              }
            }
          }
        };
      }
      if (url.endsWith('/coding/api/workspace/pinSession')) {
        assert.equal(pkt.payload.args.request.sessionId, 'sess-1');
        return {
          responseCode: 200,
          result: { type: 'server-response', rpcId: pkt.rpcId, result: { ok: true, value: { pinnedSessionIds: ['sess-1'] } } }
        };
      }
      if (url.endsWith('/coding/api/workspace/unpinSession')) {
        assert.equal(pkt.payload.args.request.sessionId, 'sess-1');
        return {
          responseCode: 200,
          result: { type: 'server-response', rpcId: pkt.rpcId, result: { ok: true, value: { pinnedSessionIds: [] } } }
        };
      }
      if (url.endsWith('/coding/api/workspace/archiveSession')) {
        assert.equal(pkt.payload.args.request.sessionId, 'sess-1');
        assert.equal(pkt.payload.args.request.stopActivity, true);
        return {
          responseCode: 200,
          result: { type: 'server-response', rpcId: pkt.rpcId, result: { ok: true, value: { archivedSessionIds: ['sess-1'] } } }
        };
      }
      if (url.endsWith('/coding/api/workspace/unarchiveSession')) {
        assert.equal(pkt.payload.args.request.sessionId, 'sess-1');
        return {
          responseCode: 200,
          result: { type: 'server-response', rpcId: pkt.rpcId, result: { ok: true, value: { archivedSessionIds: [] } } }
        };
      }
      if (url.endsWith('/coding/api/workspace/rename')) {
        assert.equal(pkt.payload.args.request.workspaceId, 'ws-a');
        assert.equal(pkt.payload.args.request.title, 'Renamed A');
        return {
          responseCode: 200,
          result: {
            type: 'server-response',
            rpcId: pkt.rpcId,
            result: { ok: true, value: { workspace: { workspaceId: 'ws-a', path: '/work/a', title: 'Renamed A', sessionIds: ['sess-1', 'sess-2'] } } }
          }
        };
      }
      if (url.endsWith('/coding/api/workspace/delete')) {
        assert.equal(pkt.payload.args.request.workspaceId, 'ws-a');
        return {
          responseCode: 200,
          result: { type: 'server-response', rpcId: pkt.rpcId, result: { ok: true, value: { deleted: true } } }
        };
      }
      if (url.endsWith('/coding/api/session/search')) {
        assert.equal(pkt.payload.args.request.query, 'debounce');
        return {
          responseCode: 200,
          result: {
            type: 'server-response',
            rpcId: pkt.rpcId,
            result: { ok: true, value: { items: [{ sessionId: 'sess-2', snippet: 'debounce timer logic' }], hasMore: false } }
          }
        };
      }
      return {
        responseCode: 200,
        result: { type: 'server-response', rpcId: pkt.rpcId, result: { ok: true, value: {} } }
      };
    };

    const client = DshClient.getInstance();
    client.resetAllState();
    await client.ensureConnected();

    const ws = wsConnections[0].ws;
    const wsOpen = ws.sent.find(f => f.endpoint === 'workspace/follow');
    assert.ok(wsOpen);
    ws.emit('message', null, JSON.stringify({
      type: 'item',
      streamId: wsOpen.streamId,
      value: {
        type: 'baseline',
        value: {
          items: [{ workspaceId: 'ws-a', path: '/work/a', title: 'Work A', sessionIds: ['sess-1', 'sess-2'] }],
          archivedSessionIds: [],
          pinnedSessionIds: ['sess-2']
        }
      }
    }));
    await settle();
    assert.deepEqual(json(client.pinnedSessionIds), ['sess-2']);
    assert.equal(client.getPinnedSessions().length, 1);
    assert.equal(client.getWorkspaceGroups(true)[0].sessions.length, 1);

    // Incremental pinned frame
    ws.emit('message', null, JSON.stringify({
      type: 'item',
      streamId: wsOpen.streamId,
      value: { type: 'pinned', pinnedSessionIds: [] }
    }));
    await settle();
    assert.deepEqual(json(client.pinnedSessionIds), []);

    await client.pinSession('sess-1');
    assert.equal(client.isSessionPinned('sess-1'), true);
    await client.unpinSession('sess-1');
    assert.equal(client.isSessionPinned('sess-1'), false);

    await client.pinSession('sess-1');
    await client.archiveSession('sess-1', true);
    assert.equal(client.isSessionArchived('sess-1'), true);
    assert.equal(client.isSessionPinned('sess-1'), false);
    assert.equal(client.getArchivedSessions().length, 1);

    await client.unarchiveSession('sess-1');
    assert.equal(client.isSessionArchived('sess-1'), false);

    const search = await client.searchSessions('debounce');
    assert.equal(search.items.length, 1);
    assert.equal(search.items[0].sessionId, 'sess-2');

    await client.renameWorkspace('ws-a', 'Renamed A');
    assert.equal(client.workspaces[0].title, 'Renamed A');

    await client.deleteWorkspace('ws-a');
    assert.equal(client.workspaces.length, 0);

    client.resetAllState();
  });

  console.log(`${passed} DSH isolated checks passed.`);
})().catch(err => {
  console.error(err);
  process.exitCode = 1;
});
