// Only fictional graph/file metadata and mocked requests. No device or server access.
const path = require('node:path');
const assert = require('node:assert/strict');

module.exports = async ({ load, root, check, page, requests, TentacleApi, json, settle, setRespond }) => {
  const { GraphPage } = load(path.join(root, 'view/GraphPage.ets'));
  const { GraphSnapshot } = load(path.join(root, 'model/GraphSnapshot.ets'));
  const graph = {
    nodes: Array.from({length: 180}, (_, n) => ({id: 'node-' + n, label: 'Concept', name: 'Synthetic ' + n})),
    relationships: [ {source:'node-0',target:'node-1',type:'LINK'}, {source:'node-0',target:'node-0',type:'SELF'} ]
  };
  const summary = {nodes: {Concept: 180}, relationships: 2};
  const reply = url => ({ok:true, data: url.endsWith('/summary') ? summary : graph});
  const file = {local_id:'synthetic-cached',filename:'test.txt',mime:'text/plain',path:'data/files/test.txt',size:3};
  const bytes = (...values) => Uint8Array.from(values).buffer;

  await check('graph cache coalesces requests, reuses indexed snapshot, expires and force refreshes', async () => {
    const api = new TentacleApi(); setRespond(reply); requests.length = 0;
    const [a,b] = await Promise.all([api.getGraphSnapshot(),api.getGraphSnapshot()]);
    assert.equal(a,b); assert.equal(requests.length,2);
    assert.equal(await api.getGraphSnapshot(),a); assert.equal(requests.length,2);
    assert.equal(a.findNode('node-1').name,'Synthetic 1'); assert.equal(a.nodeRelations('node-0').length,2);
    assert.equal(a.nodeRelations('missing').length,0);
    await api.getGraphSnapshot(true); assert.equal(requests.length,4);
    api.graphFreshAt = Date.now() - 31000;
    await api.getGraphSnapshot(); assert.equal(requests.length,6);
  });
  await check('graph page shows cached data immediately and keeps it if background refresh fails', async () => {
    const api = TentacleApi.getInstance(); api.clearCaches(); setRespond(reply);
    const snapshot = await api.getGraphSnapshot(); api.graphFreshAt = 0;
    const rejects=[]; setRespond(() => new Promise((_, r) => {rejects.push(r);}));
    const p = new GraphPage(); p.aboutToAppear();
    assert.equal(p.nodes.length,180); assert.ok(p.scene.nodes.length<=8); assert.equal(p.loading,true);
    await settle(); rejects.forEach(reject=>reject(new Error('synthetic offline')));
    await settle(); assert.equal(p.nodes.length,180); assert.match(p.errText,/显示上次快照/);
    assert.equal(api.peekGraph(),snapshot); p.aboutToDisappear();
  });
  await check('graph searches the complete snapshot without restoring removed list views', () => {
    const p = new GraphPage(); p.applySnapshot(new GraphSnapshot(summary,graph));
    assert.equal(p.searchMatches.length,0); assert.equal(p.nodeTotal,180);
    p.searchText='Synthetic 179'; p.updateFiltered(true);
    assert.deepEqual(json(p.searchMatches.map(n=>n.id)),['node-179']);
    p.searchText='Synthetic'; p.updateFiltered(true); const reached=new Set();
    for(let i=0;i<45;i++){for(const node of p.searchMatches)reached.add(node.id);p.changeSearchPage(1);}
    assert.equal(reached.size,180);assert.ok(p.searchMatches.length<=4);
    assert.equal(p.nodeRelationCount(graph.nodes[0]),2);
  });
  await check('late graph replies cannot cross logout or overwrite a recreated page', async () => {
    const api = TentacleApi.getInstance(); api.clearCaches();
    const releases=[]; setRespond(url => new Promise(resolve=>releases.push(()=>resolve(reply(url)))));
    const old = new GraphPage(); old.aboutToAppear(); await settle(); old.aboutToDisappear(); api.logout();
    setRespond(reply); const next=new GraphPage(); next.aboutToAppear(); await settle();
    const snapshot=api.peekGraph(); releases.forEach(fn=>fn()); await settle();
    assert.equal(old.nodes.length,0); assert.equal(api.peekGraph(),snapshot); assert.equal(next.nodes.length,180);
    next.aboutToDisappear();
  });
  await check('graph writes invalidate freshness and a failed graph response never poisons the snapshot', async () => {
    const api = new TentacleApi(); setRespond(reply); const first=await api.getGraphSnapshot();
    api.notifyWs({type:'round_finished',data:{}}); assert.equal(api.graphFreshAt,0);
    setRespond(()=>({ok:false,error:'synthetic unavailable'})); await assert.rejects(api.getGraphSnapshot(),/unavailable/);
    assert.equal(api.peekGraph(),first);
    setRespond(reply); await api.getGraphSnapshot();
    setRespond(()=>({ok:true})); await api.decideDedup('pair','merge','node-0','keep'); assert.equal(api.graphFreshAt,0);
  });
  await check('identical uploads share one transfer and reuse a server-verified record', async () => {
    const api = new TentacleApi(); let uploads=0, listings=0;
    setRespond(url=>{ if(url.endsWith('/upload')){uploads++;return {ok:true,file};} listings++;return {files:[file]}; });
    const [a,b] = await Promise.all([api.uploadImage(bytes(1,2,3),'test.txt','text/plain'),api.uploadImage(bytes(1,2,3),'test.txt','text/plain')]);
    assert.equal(uploads,1); assert.equal(a.local_id,b.local_id);
    await api.uploadImage(bytes(1,2,3),'test.txt','text/plain'); assert.equal(uploads,1); assert.equal(listings,1);
    await api.uploadImage(bytes(3,2,1),'test.txt','text/plain'); assert.equal(uploads,2);
    await api.uploadImage(bytes(1,2,3),'renamed.txt','text/plain'); assert.equal(uploads,3);
  });
  await check('deleted cached uploads are uploaded again; failed transfers can be retried', async () => {
    const api = new TentacleApi(); let uploads=0;
    setRespond(url=>url.endsWith('/upload') ? (++uploads,{ok:true,file}) : {files:[]});
    await api.uploadImage(bytes(1,2,3),'test.txt','text/plain');
    await api.uploadImage(bytes(1,2,3),'test.txt','text/plain'); assert.equal(uploads,2);
    setRespond(()=>{throw new Error('synthetic offline');});
    await assert.rejects(api.uploadImage(bytes(9),'test.txt','text/plain'),/offline/);
    setRespond(()=>({ok:true,file})); assert.equal((await api.uploadImage(bytes(9),'test.txt','text/plain')).local_id,file.local_id);
  });
  await check('late upload and image replies cannot populate caches after authentication changes', async () => {
    const api = new TentacleApi(); let release;
    setRespond(()=>new Promise(resolve=>{release=resolve;}));
    const upload=api.uploadImage(bytes(1),'test.txt','text/plain'); await settle(); api.logout(); release({ok:true,file});
    await assert.rejects(upload,/连接已变化/); assert.equal(api.uploaded.size,0);
    const image=api.getImageDataUri('same-id','image/png'); await settle(); api.logout(); release(bytes(1));
    await assert.rejects(image,/连接已变化/); assert.equal(api.imageCache.size,0);
  });
  await check('existing server attachments enter the shared draft without uploading their bytes', async () => {
    setRespond(()=>({files:[file]})); const p=page(); requests.length=0;
    await p.openFileLibrary(); assert.equal(p.fileLibrary.length,1); p.attachExisting(p.fileLibrary[0]); p.attachExisting(file);
    assert.equal(p.draft.pending.length,1); assert.equal(p.draft.pending[0].localId,file.local_id);
    assert.equal(requests.length,1); assert.ok(requests[0].url.endsWith('/api/files'));
    p.aboutToDisappear();
    const next=page(); next.draft=p.draft; assert.equal(next.draft.pending[0].localId,file.local_id); next.aboutToDisappear();
  });
  await check('image requests coalesce and retained previews have a fixed bound', async () => {
    const api=new TentacleApi(); setRespond(()=>bytes(1,2,3)); requests.length=0;
    const [a,b]=await Promise.all([api.getImageDataUri('shared','image/png'),api.getImageDataUri('shared','image/png')]);
    assert.equal(a,b); assert.equal(requests.length,1);
    for(let n=0;n<30;n++) await api.getImageDataUri('preview-'+n,'image/png');
    assert.equal(api.imageCache.size,24); assert.equal(api.imageCache.has('shared'),false);
    api.signalUnauthorized(); assert.equal(api.imageCache.size,0); assert.equal(api.peekGraph(),null);
  });
  await check('a late server file listing cannot reopen a closed picker or cross login scopes', async () => {
    const p=page(); let release; setRespond(()=>new Promise(resolve=>{release=resolve;}));
    const pending=p.openFileLibrary(); await settle(); p.aboutToDisappear(); release({files:[file]}); await pending;
    assert.equal(p.fileLibrary.length,0);
    const next=page(); const second=next.openFileLibrary(); await settle(); TentacleApi.getInstance().logout();
    release({files:[file]}); await second; assert.equal(next.fileLibrary.length,0); next.aboutToDisappear();
  });
};
