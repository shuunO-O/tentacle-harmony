// App-private storage is simulated in memory. No real files, credentials, device or backend are read.
const path = require('node:path');
const assert = require('node:assert/strict');

module.exports = async ({ load, root, check, requests, TentacleApi, coreFileKit, json, settle, setRespond }) => {
  const files = new Map(), descriptors = new Map(), directories = new Set();
  let nextFd=1, clock=1, failWrite=false, failRename=false, pauseWrite=null;
  const original=coreFileKit.fileIo;
  const fs = {
    OpenMode:{CREATE:1,READ_WRITE:2,TRUNC:4,WRITE_ONLY:8,READ_ONLY:16},
    async mkdir(name) {directories.add(name);},
    async open(name,mode) {
      if (!directories.has(name.slice(0,name.lastIndexOf('/')))) throw new Error('missing directory');
      if (mode&4 || !files.has(name)) files.set(name,{bytes:Buffer.alloc(0),mtime:clock++});
      const file={fd:nextFd++,name,position:0};descriptors.set(file.fd,file);return file;
    },
    async close(file) {descriptors.delete(typeof file==='number'?file:file.fd);},
    async write(fd,bytes) {
      if (pauseWrite) {const wait=pauseWrite;pauseWrite=null;await wait();}
      if(failWrite) throw new Error('synthetic disk full');
      const file=descriptors.get(fd), old=files.get(file.name), part=Buffer.from(bytes).subarray(0,65536);
      old.bytes=Buffer.concat([old.bytes,part]);old.mtime=clock++;return part.length;
    },
    async rename(source,target) {
      if(failRename) throw new Error('synthetic interrupted rename');
      if(!files.has(source)) throw new Error('missing file');
      files.set(target,files.get(source));files.delete(source);
    },
    async readText(name) {if(!files.has(name)) throw new Error('missing file');return files.get(name).bytes.toString('utf8');},
    async stat(name) {const file=files.get(name);if(!file) throw new Error('missing file');return {size:file.statSize??file.bytes.length,mtime:file.mtime};},
    async listFile(directory) {
      if(!directories.has(directory)) throw new Error('missing directory');
      return [...files.keys()].filter(name=>name.startsWith(directory+'/')&&!name.slice(directory.length+1).includes('/')).map(name=>name.slice(directory.length+1));
    },
    async unlink(name) {files.delete(name);}
  };
  coreFileKit.fileIo=fs;
  const {LocalCache}=load(path.join(root,'service/LocalCache.ets'));
  const {GraphPage}=load(path.join(root,'view/GraphPage.ets'));
  const client = directory => {
    const api=new TentacleApi();api.init({filesDir:directory});return api;
  };
  const envelope = name => JSON.parse(files.get(name).bytes.toString('utf8'));
  const changeEnvelope = (name,change) => {
    const item=envelope(name);change(item);files.get(name).bytes=Buffer.from(JSON.stringify(item));
  };
  const graph={nodes:[{id:'synthetic-node',label:'Concept',name:'模拟节点'}],relationships:[]};
  const summary={nodes:{Concept:1},relationships:0};
  const reply=url=>({ok:true,data:url.endsWith('/summary')?summary:graph});
  const record={local_id:'synthetic-file',filename:'模拟.txt',mime:'text/plain',path:'data/files/synthetic.txt',size:3};
  const bytes=Uint8Array.from([1,2,3]).buffer;

  try {
    await check('local cache survives recreation and writes Unicode fully despite partial writes',async()=>{
      const disk=new LocalCache('/disk/unicode','synthetic-secret');
      const value='模拟数据🦑'.repeat(20000);await disk.write('graph',value);
      const fresh=new LocalCache('/disk/unicode','synthetic-secret');
      assert.equal(await fresh.read('graph',86400000),value);
      assert.equal([...files.keys()].some(name=>name.endsWith('.tmp')),false);assert.equal(descriptors.size,0);
      assert.equal(files.get('/disk/unicode/graph.json').bytes.includes(Buffer.from('synthetic-secret')),false);
      await disk.write('graph','new');assert.equal(await fresh.read('graph',86400000),'new');
    });
    await check('disk full or interrupted atomic replacement preserves the previous valid cache',async()=>{
      const disk=new LocalCache('/disk/atomic','scope');await disk.write('graph','old');
      failWrite=true;await disk.write('graph','new');failWrite=false;assert.equal(await disk.read('graph',100000),'old');
      failRename=true;await disk.write('graph','new');failRename=false;assert.equal(await disk.read('graph',100000),'old');
      assert.equal(descriptors.size,0);assert.equal([...files.keys()].some(name=>name.endsWith('.tmp')),false);
    });
    await check('expired, corrupt and wrong-server cache entries fall back to a miss',async()=>{
      const disk=new LocalCache('/disk/validation','server-a|token-a');await disk.write('graph','snapshot');
      changeEnvelope('/disk/validation/graph.json',item=>{item.savedAt=Date.now()-86400000;});
      assert.equal(await disk.read('graph',1000),null);
      await disk.write('graph','snapshot');files.get('/disk/validation/graph.json').bytes=Buffer.from('{broken');
      assert.equal(await disk.read('graph',1000),null);
      await disk.write('graph','snapshot');assert.equal(await new LocalCache('/disk/validation','server-b|token-b').read('graph',1000),null);
      await assert.rejects(disk.write('../escape','bad'),/Invalid cache key/);
    });
    await check('local cache evicts oldest entries to enforce count and total byte bounds',async()=>{
      const disk=new LocalCache('/disk/quota','scope');
      for(let n=0;n<70;n++) await disk.write('item-'+n,'small');
      const names=await fs.listFile('/disk/quota');assert.equal(names.length,66);assert.equal(names.includes('item-0.json'),false);
      files.get('/disk/quota/'+names[0]).statSize=64*1024*1024;
      await disk.write('recent','small');assert.ok(await disk.size()<=64*1024*1024);assert.equal(await disk.read('recent',10000),'small');
    });
    await check('a cold graph page shows the saved snapshot before a slow refresh finishes',async()=>{
      const api=client('/app/graph');setRespond(reply);await api.getGraphSnapshot();await api.localCache.flush();
      const fresh=client('/app/graph');const originalInstance=TentacleApi.instance;TentacleApi.instance=fresh;
      const releases=[];setRespond(url=>new Promise(resolve=>releases.push(()=>resolve(reply(url)))));
      const page=new GraphPage();page.aboutToAppear();await fresh.restoreGraphCache();await settle();
      assert.equal(page.nodes[0].name,'模拟节点');assert.equal(page.loading,true);assert.equal(fresh.graphFreshAt,0);
      releases.forEach(resolve=>resolve());await settle();assert.equal(page.loading,false);
      page.aboutToDisappear();await fresh.localCache.flush();TentacleApi.instance=originalInstance;
    });
    await check('upload fingerprints survive restart and reuse a still-existing backend record',async()=>{
      const api=client('/app/uploads');setRespond(()=>({ok:true,file:record}));
      await api.uploadImage(bytes,record.filename,record.mime);await api.localCache.flush();
      const fresh=client('/app/uploads');requests.length=0;
      setRespond(url=>{assert.ok(url.endsWith('/api/files'));return {files:[record]};});
      assert.equal((await fresh.uploadImage(bytes,record.filename,record.mime)).local_id,record.local_id);
      assert.equal(requests.length,1);
    });
    await check('image previews survive restart and avoid retransferring cached content',async()=>{
      const api=client('/app/images');setRespond(()=>bytes);const uri=await api.getImageDataUri('synthetic-image','image/png');
      await api.localCache.flush();const fresh=client('/app/images');requests.length=0;
      setRespond(()=>{throw new Error('unexpected network transfer');});
      assert.equal(await fresh.getImageDataUri('synthetic-image','image/png'),uri);assert.equal(requests.length,0);
    });
    await check('logout cancels queued disk writes and removes persisted private cache data',async()=>{
      const api=client('/app/logout');setRespond(reply);await api.getGraphSnapshot();await api.localCache.flush();
      const disk=api.localCache;let release,started;
      const writing=new Promise(resolve=>{started=resolve;});
      pauseWrite=()=>{started();return new Promise(resolve=>{release=resolve;});};
      const pending=disk.write('image-paused','data:image/png;base64,AQID');await writing;api.logout();release();await pending;await disk.flush();
      assert.equal((await fs.listFile('/app/logout/tentacle-cache-v1')).length,0);
      assert.equal(api.peekGraph(),null);assert.equal(descriptors.size,0);
    });
    await check('malformed graph and upload payloads do not block normal backend loading',async()=>{
      const api=client('/app/corrupt');await api.localCache.write('graph','{"graph":null}');await api.localCache.write('uploads','null');
      const fresh=client('/app/corrupt');setRespond(url=>url.endsWith('/upload')?{ok:true,file:record}:reply(url));
      assert.equal((await fresh.getGraphSnapshot()).nodes.length,1);
      assert.equal((await fresh.uploadImage(bytes,record.filename,record.mime)).local_id,record.local_id);await fresh.localCache.flush();
    });
    await check('the settings clear operation removes disk and memory caches but keeps the connection',async()=>{
      const api=client('/app/clear');const server=api.getServerUrl(),token=api.getToken();setRespond(reply);
      await api.getGraphSnapshot();await api.localCache.flush();assert.ok(await api.localCacheBytes()>0);
      await api.clearLocalCache();assert.equal(await api.localCacheBytes(),0);assert.equal(api.peekGraph(),null);
      assert.equal(api.getServerUrl(),server);assert.equal(api.getToken(),token);
    });
  } finally {
    await new LocalCache('/unused','scope').flush();coreFileKit.fileIo=original;
  }
};
