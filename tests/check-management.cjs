// Synthetic protocol/UI-controller checks; never contact a backend, device or credential store.
const path = require('node:path');
const assert = require('node:assert/strict');

module.exports = async ({ load, root, check, page, requests, terminal, json, settle, ChatStore,
  PendingImage, TentacleApi, coreFileKit, mediaKit, setRespond, setCreateHttp, setResponseCookies }) => {
  const { ConfigurationPage } = load(path.join(root, 'view/ConfigurationPage.ets'));
  const { StatsPage } = load(path.join(root, 'view/StatsPage.ets'));
  const { SubagentsPage } = load(path.join(root, 'view/SubagentsPage.ets'));
  const { StatusPage } = load(path.join(root, 'view/StatusPage.ets'));
  const { splitFileMarkers } = load(path.join(root, 'model/FileMarkers.ets'));
  const api = TentacleApi.getInstance();
  const meta = (id, extra = {}) => terminal(id, extra);
  const event = (store, id, type, data = {}) => store.handleWs({ type, data, round: meta(id) });
  const texts = store => store.rows.filter(r => r.group).flatMap(r => r.group.bubbles.map(b => b.text));
  const begin = id => { const s = new ChatStore(); s.sending = true; s.typing = true; s.activeRequestId = id; s.resetGroup(); return s; };

  await check('final stops typing while sending remains locked until persistence completes', () => {
    const s = begin('own'); event(s, 'own', 'message_delta', { text: 'synthetic reply' });
    event(s, 'own', 'final');
    assert.equal(s.typing, false); assert.equal(s.sending, true); assert.equal(s.receiving, false);
    s.handleWs({ type: 'round_finished', data: meta('own') });
    assert.equal(s.sending, false); assert.deepEqual(json(texts(s)), ['synthetic reply']);
  });
  await check('heartbeat and another client cannot finish or close the current request', () => {
    const s = begin('own'); event(s, 'own', 'message_delta', { text: 'own partial' });
    event(s, 'heartbeat', 'message_delta', { text: 'background' }); event(s, 'heartbeat', 'final');
    s.handleWs({ type: 'round_finished', data: meta('heartbeat', { source: 'heartbeat' }) });
    assert.equal(s.sending, true); assert.equal(s.typing, true); assert.equal(s.receiving, true);
    assert.equal(s.rows.find(r => r.group?.requestId === 'own').group.bubbles[0].streaming, true);
    event(s, 'own', 'message_delta', { text: ' complete' });
    assert.deepEqual(json(texts(s)), ['own partial complete', 'background']);
  });
  await check('a late prior final, terminal or network failure cannot close the new round', () => {
    const s = begin('first'); event(s, 'first', 'message_delta', { text: 'first' });
    s.finishRequest(meta('first')); s.addUser('next', 1); s.activeRequestId = 'second'; s.sending = true; s.typing = true; s.resetGroup();
    event(s, 'second', 'message_delta', { text: 'second partial' });
    event(s, 'first', 'final'); s.handleWs({ type: 'round_finished', data: meta('first') }); s.failRequest('first', 'late timeout');
    assert.equal(s.sending, true); assert.equal(s.typing, true);
    assert.equal(s.rows.at(-1).group.bubbles[0].streaming, true);
  });
  await check('save failures retain partial output and preserve the server failure detail', async () => {
    let release; setRespond(() => new Promise(resolve => { release = resolve; }));
    const p = page(); p.draft.text = 'save failure'; p.send(); await settle();
    const id = p.store.activeRequestId; event(p.store, id, 'message_delta', { text: 'visible partial' }); event(p.store, id, 'final');
    assert.equal(p.isBusy(), true);
    release({ __httpStatus: 500, body: { detail: 'synthetic archive failure', round: meta(id, { status: 'failed', error: 'synthetic archive failure' }) } });
    await settle();
    assert.equal(p.isBusy(), false); assert.equal(p.store.rows.at(-1).group.errorText, 'synthetic archive failure');
    assert.deepEqual(json(texts(p.store)), ['visible partial']); p.aboutToDisappear();
  });
  await check('WS first and HTTP first command receipts each show feedback exactly once', async () => {
    for (const wsFirst of [true, false]) {
      let release; setRespond(url => url.includes('/history') ? { messages: [], has_more: false } : new Promise(resolve => { release = resolve; }));
      const p = page(); p.draft.text = '/synthetic'; p.send(); await settle();
      const id = p.store.activeRequestId;
      const command = { text: 'one command receipt', refresh_history: true };
      const evt = { type: 'round_finished', data: meta(id, { stop_reason: 'command', command }) };
      if (wsFirst) { p.store.handleWs(evt); p.scrollCb(evt); await settle(); }
      release({ ok: true, total_tokens: 0, round: meta(id, { stop_reason: 'command' }), command }); await settle();
      if (!wsFirst) { p.store.handleWs(evt); p.scrollCb(evt); await settle(); }
      assert.equal(p.store.rows.filter(r => r.system?.text === command.text).length, 1);
      p.store.failRequest(id, 'late network error'); assert.equal(p.store.rows.some(r => r.group?.isError), false);
      p.aboutToDisappear();
    }
  });
  await check('command feedback and attachments survive a page change before HTTP returns', async () => {
    let release; setRespond(url => url.includes('/history') ? { messages: [], has_more: false } : new Promise(resolve => { release = resolve; }));
    const old = page(); const file = new PendingImage(); file.localId = 'synthetic-doc'; file.mime = 'text/plain'; old.draft.pending = [file];
    old.draft.text = '/synthetic'; old.send(); await settle(); const id = old.store.activeRequestId;
    old.aboutToDisappear(); old.store.handleWs({ type: 'round_finished', data: meta(id, { command: { text: 'page-change receipt', refresh_history: true } }) });
    const next = page(); next.store = old.store; next.draft = old.draft; next.aboutToAppear(); await settle();
    assert.equal(next.draft.pending.length, 1);
    assert.equal(next.store.rows.filter(r => r.system?.text === 'page-change receipt').length, 1);
    release({ ok: true, total_tokens: 0, round: meta(id), command: { text: 'page-change receipt', refresh_history: true } }); await settle();
    assert.equal(next.store.rows.filter(r => r.system).length, 1); next.aboutToDisappear();
  });
  await check('earlier history uses archive IDs and has_more while preserving row identities', async () => {
    const message = id => ({ id, round_id: 'r' + id, role: 'user', platform: 'harmony', content: 'synthetic ' + id, created_time: 10 - id });
    setRespond(() => ({ messages: [message(30), message(40)], has_more: true }));
    const p = page(); await p.loadHistory(); const original = p.store.rows; p.firstVisible = 1;
    let scrollIndex; p.scroller.scrollToIndex = index => { scrollIndex = index; };
    setRespond(() => ({ messages: [message(10), message(20), message(30), message(40)], has_more: false }));
    await p.loadEarlier(); await new Promise(resolve => setTimeout(resolve, 5));
    assert.deepEqual(json(p.store.rows.map(r => r.archiveId)), [10,20,30,40]);
    assert.equal(p.store.rows[2], original[0]); assert.equal(p.hasMore, false); assert.equal(scrollIndex, 4); p.aboutToDisappear();
  });
  await check('file marker grammar ignores escapes, inline code, fences and incomplete markers', () => {
    const source = 'before [file:tmp/report.pdf] after `code [file:skip]` \\[file:skip2]\n```\n[file:skip3]\n```\n[file:two.txt]\n[file:unfinished';
    const parts = json(splitFileMarkers(source));
    assert.deepEqual(parts.filter(p => p.kind === 'file').map(p => p.text), ['tmp/report.pdf', 'two.txt']);
    assert.ok(parts.filter(p => p.kind === 'text').map(p => p.text).join('').includes('[file:unfinished'));
    for (let n = 0; n < source.length; n++) assert.doesNotThrow(() => splitFileMarkers(source.slice(0,n)));
  });
  await check('document drafts and history do not request document bytes as image previews', async () => {
    const p = page(); const f = new PendingImage(); f.localId = 'synthetic-doc'; f.mime = 'application/pdf'; p.draft.pending = [f];
    let images = 0; p.loadImageData = () => images++;
    p.loadDraftImages(); assert.equal(images, 0);
    setRespond(() => ({ messages: [{ id: 1, role: 'user', content: 'doc', platform: 'harmony', created_time: 1,
      images: [{ local_id: 'synthetic-doc', filename: 'test.pdf', mime: 'application/pdf' }] }], has_more: false }));
    await p.loadHistory(); assert.equal(images, 0); assert.equal(p.store.rows[0].user.images[0].mime, 'application/pdf'); p.aboutToDisappear();
  });

  const period = n => ({ prompt_tokens: n, completion_tokens: n, total_tokens: n * 2, cached_tokens: 0, requests: n });
  const usage = n => ({ points: [], summary: { today: period(n), week: period(n), month: period(n), all: period(n) },
    options: { providers: [{ id: 'p', label: 'Provider' }], models: [{ id: 'm', label: 'Model', provider_ids: ['p'] }], roles: [{ id: 'chat', label: 'Chat' }] } });
  await check('statistics filters apply to both chart granularities and only provider affects balances', async () => {
    setRespond(url => url.includes('/usage') ? usage(4) : { items: [{ provider_id: 'p', label: 'P', ok: false, error: 'not supported' }] });
    const p = new StatsPage(); p.provider = 'p'; p.model = 'm'; p.role = 'chat'; requests.length = 0;
    await p.load(true); await settle();
    const urls = requests.map(r => new URL(r.url, 'https://synthetic.invalid'));
    for (const u of urls.filter(u => u.pathname === '/api/usage')) {
      assert.equal(u.searchParams.get('provider_id'), 'p'); assert.equal(u.searchParams.get('model_id'), 'm'); assert.equal(u.searchParams.get('role'), 'chat');
    }
    const b = urls.find(u => u.pathname === '/api/balance'); assert.equal(b.searchParams.get('force'), 'true'); assert.equal(b.searchParams.has('model_id'), false);
    assert.equal(p.sumAll.requests, 4); assert.equal(p.balances[0].error, 'not supported'); p.aboutToDisappear();
  });
  await check('statistics ignore late old filter results and balance errors leave usage intact', async () => {
    const releases = [];
    setRespond(url => url.includes('/balance') ? Promise.reject(new Error('synthetic balance offline')) : new Promise(resolve => releases.push(resolve)));
    const p = new StatsPage(); const first = p.load(); await settle(); const second = p.load(); await settle();
    releases[2](usage(2)); releases[3](usage(2)); await second;
    releases[0](usage(1)); releases[1](usage(1)); await first; await settle();
    assert.equal(p.sumAll.requests, 2); assert.match(p.balErr, /offline/); assert.equal(p.errText, ''); p.aboutToDisappear();
  });

  const field = (path, kind, value, extra = {}) => ({ path, kind, value, active: value, default: value, label: path, group: 'synthetic',
    choices: [], nullable: false, inheritable: false, protected: false, pending: false, source: 'file', effect: 'round', minimum: null, maximum: null, help: '', ...extra });
  const snapshot = () => ({ revision: 'a'.repeat(64),
    fields: [field('heartbeat.interval_minutes','number',30,{ minimum:0.1, maximum:10080 }), field('roles.chat.model','string','m'),
      field('models.m.defaults.temperature','number',0.7), field('roles.chat.overrides.temperature','number',1,{ inheritable: true, default:0.7 })],
    entities: { providers: [{ id:'p',label:'P',type:'openai_compatible',references:{models:['m'],roles:['chat'],uploads:[],balance:false} }],
      models:[{id:'m',label:'M',name:'synthetic-model',provider:'p',references:['chat']}], roles:[{id:'chat',label:'Chat',model:'m',references:[]}] },
    provider_types:{openai_compatible:{label:'Compatible',auth:'api_key',protocols:['chat','responses'],base_url:'https://synthetic.invalid/v1'}},
    tools:{chat:['file_read']},connection_status:{p:{auth:'api_key',configured:true}},history:[],active_model:{name:'synthetic'},
    active_role:'chat',applying:false,error:null,restart_required:false,restart:{available:true,state:'idle'} });
  const configPage = () => { const p = new ConfigurationPage(); p.visible = true; p.data = snapshot(); return p; };
  await check('configuration sections match Web and preserve edits when navigating between them', () => {
    const p=configPage(); const {configurationSection}=load(path.join(root,'model/ConfigurationNavigation.ets'));
    assert.equal(configurationSection('角色 · chat'),'models');assert.equal(configurationSection('连接 · p'),'models');
    for(const name of ['心跳','公开网页工具','定时任务','功能开关']) assert.equal(configurationSection(name),'runtime');
    assert.equal(configurationSection('服务'),'maintenance');
    p.data.fields[0].group='心跳';p.data.fields[1].group='角色 · chat';p.data.fields[2].group='模型 · m';
    p.edit(p.data.fields[0],'12');p.search='M';p.switchSection('runtime');
    assert.deepEqual(json(p.sectionGroups()),['心跳']);assert.equal(p.group,'心跳');
    p.navigate('角色 · chat');assert.equal(p.inspecting,true);assert.equal(p.section,'models');
    assert.equal(p.draft['heartbeat.interval_minutes'],'12');
    p.preview={changes:[]};p.switchSection('maintenance');assert.equal(p.section,'models');
  });
  await check('configuration inspector separates basic parameters, advanced parameters and tool permissions', () => {
    const p=configPage();p.group='角色 · chat';
    p.data.fields=[field('roles.chat.model','string','m',{group:p.group}),
      field('roles.chat.timeout','integer',60,{group:p.group}),field('roles.chat.tools.enabled','tools',['file_read'],{group:p.group})];
    assert.deepEqual(json(p.editorFields('common').map(f=>f.path)),['roles.chat.model']);
    assert.deepEqual(json(p.editorFields('advanced').map(f=>f.path)),['roles.chat.timeout']);
    assert.deepEqual(json(p.editorFields('tools').map(f=>f.path)),['roles.chat.tools.enabled']);
    p.advancedOpen=true;p.toolsOpen=true;p.navigate('模型 · m');assert.equal(p.advancedOpen,false);assert.equal(p.toolsOpen,false);
    p.toggleProvider('p');assert.equal(p.expandedProviders.includes('p'),true);p.toggleProvider('p');assert.equal(p.expandedProviders.includes('p'),false);
  });
  await check('configuration writes require preview and retain the reviewed revision and numeric types', async () => {
    const p = configPage(); requests.length = 0;
    setRespond((url, opts) => {
      if (opts.method === 'GET') return snapshot();
      return { revision: 'a'.repeat(64), changes: [{ path:'heartbeat.interval_minutes', label:'interval', before:30, after:12, effect:'round' }], status:snapshot() };
    });
    p.edit(p.data.fields[0], '12'); await p.save(); assert.equal(requests.length, 0);
    await p.previewChanges(); assert.equal(requests[0].options.method, 'POST');
    assert.equal(JSON.parse(requests[0].options.extraData).changes['heartbeat.interval_minutes'], 12);
    assert.equal(requests.some(r => r.options.method === 'PUT'), false);
    await p.save();
    const saved = requests.find(r => r.options.method === 'PUT'); assert.equal(JSON.parse(saved.options.extraData).revision, 'a'.repeat(64));
    assert.equal(JSON.parse(saved.options.extraData).changes['heartbeat.interval_minutes'], 12); p.aboutToDisappear();
  });
  await check('editing invalidates a configuration preview, protected values are immutable, and bad numbers stay local', async () => {
    const p = configPage(); requests.length = 0;
    p.preview = {revision:p.data.revision, changes:[{}]}; p.edit(p.data.fields[0], '15'); assert.equal(p.preview, null);
    const secret = field('providers.p.base_url','url','[redacted]',{protected:true}); p.edit(secret,'https://bad.invalid'); assert.equal(p.draft[secret.path], undefined);
    p.edit(p.data.fields[0], ''); await p.previewChanges(); assert.equal(requests.length, 0); assert.match(p.message,/不能为空/); p.aboutToDisappear();
  });
  await check('configuration revision conflict preserves edits and cannot silently save', async () => {
    const p = configPage(); p.edit(p.data.fields[0], '12');
    setRespond(() => ({__httpStatus:409,body:{detail:'synthetic revision conflict'}}));
    await p.previewChanges(); assert.equal(p.preview,null); assert.equal(p.draft['heartbeat.interval_minutes'],'12'); assert.match(p.message,/conflict/);
    const count=requests.length; await p.save(); assert.equal(requests.length,count); p.aboutToDisappear();
  });
  await check('configuration polling cannot overwrite a newly edited draft and inherited values follow model defaults', async () => {
    const p = configPage(); let release; setRespond(() => new Promise(resolve => release=resolve));
    const loading=p.load(); await settle(); p.edit(p.data.fields[0],'13'); release(snapshot()); await loading;
    assert.equal(p.draft['heartbeat.interval_minutes'],'13');
    p.edit(p.data.fields[3], {$inherit:true}); assert.equal(p.value(p.data.fields[3]),0.7);
    p.edit(p.data.fields[2],'0.9'); assert.equal(p.value(p.data.fields[3]),'0.9');
    assert.deepEqual(json(p.changes()['roles.chat.overrides.temperature']),{$inherit:true}); p.aboutToDisappear();
  });
  await check('configuration structure and backup restore preview without applying mutations', async () => {
    const p = configPage(); requests.length=0;
    setRespond(() => ({revision:'a'.repeat(64),changes:[{path:'models.new',label:'new model',before:null,after:'synthetic',effect:'restart'}]}));
    await p.structure([{op:'create',kind:'models',id:'new',value:{provider:'p',name:'synthetic'}}]);
    assert.equal(JSON.parse(requests[0].options.extraData).apply,false);
    p.preview=null; await p.restore('synthetic-backup');
    assert.equal(JSON.parse(requests[1].options.extraData).apply,false);
    assert.equal(JSON.parse(requests[1].options.extraData).backup,'synthetic-backup'); p.aboutToDisappear();
  });
  await check('configuration load handles snapshots without config_version as hierarchical 3-tier layout', async () => {
    const p=new ConfigurationPage(); p.visible=true;
    const snap=snapshot(); snap.fields[0].group='心跳'; snap.fields[1].group='角色 · chat';
    setRespond(() => snap);
    await p.load();
    assert.equal(p.section, 'models');
    assert.equal(p.group, '角色 · chat');
    assert.deepEqual(json(p.expandedModels), ['m']);
    assert.deepEqual(json(p.expandedProviders), ['p']);
    p.aboutToDisappear();
  });
  await check('catalog imports only selected new models and rejects a changed configuration revision', async () => {
    const p=configPage(); requests.length=0;
    p.catalog={revision:p.data.revision,provider:'p',api_style:'chat',models:[{import_id:'new',name:'new-model'},{import_id:'old',name:'old-model',configured:true}]};
    p.catalogProtocol='responses'; p.selectedModels=['new','old'];
    setRespond(() => ({revision:'a'.repeat(64),changes:[{path:'models.new'}]})); p.importModels(); await settle();
    const operations=JSON.parse(requests[0].options.extraData).operations; assert.equal(operations.length,1); assert.equal(operations[0].value.api_style,'responses');
    p.data.revision='b'.repeat(64); const count=requests.length; p.importModels(); await settle(); assert.equal(requests.length,count); assert.match(p.message,/重新读取/); p.aboutToDisappear();
  });
  await check('enabling the device gate enrolls first and persists its cookie before the protected write', async () => {
    requests.length=0;
    setResponseCookies('tentacle_device=synthetic-enrollment; Path=/');
    setRespond(url => url.endsWith('/devices') ? {device_bound:false} : {ok:true});
    await api.setDeviceAuth(true,'synthetic-enrollment-code');
    assert.deepEqual(requests.map(r => new URL(r.url,'https://synthetic.invalid').pathname),['/api/auth/devices','/api/auth/enroll','/api/auth/device_auth']);
    assert.match(requests[2].options.header.Cookie,/tentacle_device=/);
    setResponseCookies('');
  });
  await check('subagent detail ignores a response after switching tasks and earlier pages retain IDs without duplication', async () => {
    const p=new SubagentsPage(); p.visible=true; p.selected={id:'old'};
    let release; setRespond(() => new Promise(resolve => release=resolve)); const pending=p.detail('old'); await settle();
    p.selected={id:'new'}; release({task:{id:'old'},turns:[],next_before:null}); await pending; assert.equal(p.selected.id,'new');
    p.turns=[{id:30},{id:40}]; p.before=30;
    setRespond(() => ({task:{id:'new'},turns:[{id:10},{id:20},{id:30}],next_before:null})); await p.detail('new',true);
    assert.deepEqual(json(p.turns.map(t=>t.id)),[10,20,30,40]); p.aboutToDisappear();
  });
  await check('status handles disabled subconscious and clears stale usage after backend restart', async () => {
    const p=new StatusPage(); p.totTotal=99;
    setRespond(() => ({subconscious:{},session:null,tokens:{accumulated:0},connections:1,heartbeat:{interval_seconds:null,next_beat_at:null},time:1,
      db:{raw_messages:0,sessions:0,summaries:0,goals:0,tasks:0,files:2,usage_logs:3},usage:null}));
    await p.load(); assert.equal(p.bond,0); assert.equal(p.lastUpdate,'-'); assert.equal(p.totTotal,0); assert.equal(p.dbFiles,2); p.aboutToDisappear();
  });

  const savedFiles = new Map(); const opened = new Map(); let nextFd=1, pickerCalls=0, destroyed=0;
  coreFileKit.fileIo = {
    OpenMode:{CREATE:1,READ_WRITE:2,TRUNC:4,WRITE_ONLY:8,READ_ONLY:16},
    openSync(name,mode) {
      if (mode & 4 || !savedFiles.has(name)) savedFiles.set(name,Buffer.alloc(0));
      const f={fd:nextFd++,name,position:0}; opened.set(f.fd,f); return f;
    },
    closeSync(file) { opened.delete(typeof file==='number'?file:file.fd); },
    writeSync(fd,bytes) {
      const f=opened.get(fd), n=Math.min(3,bytes.byteLength);
      savedFiles.set(f.name,Buffer.concat([savedFiles.get(f.name),Buffer.from(bytes).subarray(0,n)])); return n;
    },
    readSync(fd,buffer) {
      const f=opened.get(fd), bytes=savedFiles.get(f.name).subarray(f.position,f.position+buffer.byteLength);
      new Uint8Array(buffer).set(bytes); f.position+=bytes.length; return bytes.length;
    },
    statSync(fd) { return {size:savedFiles.get(opened.get(fd).name).length}; },
    async copyFile(source,destination) { savedFiles.set(opened.get(destination).name,Buffer.from(savedFiles.get(opened.get(source).name))); },
    unlinkSync(name) { savedFiles.delete(name); }
  };
  coreFileKit.picker = {DocumentViewPicker: class {async save() {pickerCalls++;return ['synthetic://saved'];}}};
  const {saveAttachment}=load(path.join(root,'service/FileTransfer.ets'));
  const configureStream = (status, bytes) => setCreateHttp(() => {
    const handlers={};
    return {on(name,fn){handlers[name]=fn;},destroy(){destroyed++;},requestInStream(url,options){
      assert.ok(url.includes('/api/files/'));assert.match(options.header.Cookie,/tentacle_device=/);assert.equal(options.usingCache,false);
      setImmediate(() => {for(const part of bytes) handlers.dataReceive?.(Uint8Array.from(part).buffer);handlers.dataEnd?.();});
      return Promise.resolve(status);
    }};
  });
  await check('authenticated streaming downloads wait for every chunk and clean temporary files', async () => {
    configureStream(200,[[1,2,3,4,5],[6,7,8,9]]); pickerCalls=0;
    const result=await saveAttachment({cacheDir:'/synthetic-cache'},'/api/files/download?path=tmp%2Ftest.bin','test.bin');
    assert.equal(result,true);assert.equal(pickerCalls,1);assert.deepEqual([...savedFiles.get('synthetic://saved')],[1,2,3,4,5,6,7,8,9]);
    assert.equal(opened.size,0);assert.equal([...savedFiles.keys()].some(k=>k.startsWith('/synthetic-cache/')),false);
    setCreateHttp(null);
  });
  await check('download HTTP errors never save an error body as a user attachment', async () => {
    configureStream(401,[[123,125]]);pickerCalls=0;savedFiles.delete('synthetic://saved');
    await assert.rejects(saveAttachment({cacheDir:'/synthetic-cache'},'/api/files/fake/content','test.txt'),/HTTP 401/);
    assert.equal(pickerCalls,0);assert.equal(savedFiles.has('synthetic://saved'),false);assert.equal(opened.size,0);
    assert.equal([...savedFiles.keys()].some(k=>k.startsWith('/synthetic-cache/')),false);assert.ok(destroyed>=2);setCreateHttp(null);
  });
  await check('arbitrary file selection preserves original bytes and enforces the backend size limit', async () => {
    const uri='synthetic://document.txt';savedFiles.set(uri,Buffer.from([0,1,2,255,10]));
    const p=page();const bytes=await p.readDocument(uri);assert.deepEqual([...new Uint8Array(bytes)],[0,1,2,255,10]);
    savedFiles.set(uri,Buffer.alloc(0));await assert.rejects(p.readDocument(uri),/非空/);
    const stat=coreFileKit.fileIo.statSync;coreFileKit.fileIo.statSync=()=>({size:64*1024*1024+1});
    await assert.rejects(p.readDocument(uri),/64 MiB/);coreFileKit.fileIo.statSync=stat;
    assert.equal(opened.size,0);p.aboutToDisappear();
  });
  await check('late increments cannot reopen a completed or uncertain local request', () => {
    const s=begin('retired');event(s,'retired','message_delta',{text:'partial'});s.failRequest('retired','timeout');
    s.activeRequestId='new';s.addUser('new',2);s.sending=true;s.resetGroup();
    const revision=s.revision;event(s,'retired','message_delta',{text:'late'});
    assert.equal(s.revision,revision);assert.equal(s.receiving,false);assert.equal(s.sending,true);
    s.handleWs({type:'round_finished',data:meta('retired')});assert.equal(s.sending,true);
    assert.equal(s.rows[0].group.isError,false);
  });
  await check('history hides only markers backed by actual structured attachment references', () => {
    const {visibleUserText}=load(path.join(root,'model/FileMarkers.ets'));
    assert.equal(visibleUserText('caption\n[file:data/files/test.txt]\n[file:example]', ['data/files/test.txt']), 'caption\n\n[file:example]');
    assert.equal(visibleUserText('[file:example]', []), '[file:example]');
  });
  await check('native media sends authenticated headers only on tap and releases playback on leaving', async () => {
    const {MediaAttachment}=load(path.join(root,'components/MediaAttachment.ets'));
    let created=0,released=0,source,prepared=0,played=0;
    const player={on(){},release:async()=>released++,prepare:async()=>prepared++,play:async()=>played++,duration:1000,
      setMediaSource:async s=>source=s};
    mediaKit.media={createAVPlayer:async()=>{created++;return player;},createMediaSourceWithUrl:(url,headers)=>({url,headers})};
    const component=new MediaAttachment();component.localId='synthetic-video';component.mime='video/mp4';component.surfaceId='synthetic-surface';
    assert.equal(created,0);await component.toggle();assert.equal(created,1);assert.match(source.headers.Cookie,/tentacle_device=/);
    assert.match(source.url,/\/api\/files\/synthetic-video\/content$/);assert.equal(source.url.includes('token='),false);
    await component.stateChanged(player,'initialized');assert.equal(player.surfaceId,'synthetic-surface');assert.equal(prepared,1);
    await component.stateChanged(player,'prepared');assert.equal(played,1);
    component.aboutToDisappear();await settle();assert.equal(released,1);
  });
  await check('mismatched HTTP receipts report uncertainty without finishing a different request', async () => {
    setRespond(() => ({ok:true,total_tokens:0,round:meta('wrong-request')}));
    const p=page();p.draft.text='synthetic';p.send();await settle();
    assert.equal(p.store.sending,false);assert.match(p.store.rows.at(-1).group.errorText,/结果未确认/);p.aboutToDisappear();
  });
  await check('a slow command can confirm an uncertain request once while it is still current', async () => {
    setRespond(() => {throw new Error('timeout');});
    const p=page();const attachment=new PendingImage();attachment.localId='synthetic-attachment';attachment.mime='text/plain';p.draft.pending=[attachment];
    p.draft.text='/slow-command';p.send();await settle();const id=p.store.activeRequestId;assert.equal(p.isBusy(),false);
    const evt={type:'round_finished',data:meta(id,{command:{text:'late confirmed command',refresh_history:false}})};
    p.store.handleWs(evt);p.scrollCb(evt);await settle();p.store.handleWs(evt);p.scrollCb(evt);await settle();
    assert.equal(p.draft.pending.length,1);assert.equal(p.store.rows.filter(r=>r.system?.text==='late confirmed command').length,1);p.aboutToDisappear();
  });
  await check('new configuration roles start with an explicit empty tool selection like Web', async () => {
    const p=configPage();requests.length=0;p.openCreate('roles');p.createParent='m';
    setRespond(()=>({revision:'a'.repeat(64),changes:[{path:'roles.synthetic'}]}));p.create();await settle();
    const operation=JSON.parse(requests[0].options.extraData).operations[0];
    assert.deepEqual(operation.value,{model:'m',tools:{enabled:[]}});assert.equal(JSON.parse(requests[0].options.extraData).apply,false);p.aboutToDisappear();
  });
  await check('Vertex connection creation previews independent credential and GCS fields without reading secrets', async () => {
    const p = configPage();
    p.data.provider_types.google_vertex = { label: 'Vertex', auth: 'adc', protocols: ['gemini_generate'], base_url: 'https://synthetic.invalid' };
    p.openCreate('providers'); p.createType = 'google_vertex'; p.createId = 'vertex';
    p.createProject = 'synthetic-project'; p.createCredentialsEnv = 'SYNTHETIC_VERTEX_CREDENTIALS'; p.createGcsBaseUrl = 'gs://synthetic-bucket/photos';
    requests.length = 0; setRespond(() => ({ revision: p.data.revision, changes: [{ path: 'providers.vertex' }] }));
    p.create(); await settle(); const body = JSON.parse(requests[0].options.extraData);
    assert.equal(body.apply, false); assert.equal(body.operations[0].value.credentials_env, 'SYNTHETIC_VERTEX_CREDENTIALS');
    assert.equal(body.operations[0].value.gcs_base_url, 'gs://synthetic-bucket/photos');
    p.createKind = ''; p.createType = 'openai_compatible'; requests.length = 0; p.createKind = 'providers'; p.create(); await settle();
    assert.equal(JSON.parse(requests[0].options.extraData).operations[0].value.credentials_env, undefined); p.aboutToDisappear();
  });
};
