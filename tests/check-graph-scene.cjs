// Synthetic indexed topology, rotary geometry, touch and mocked audio. No device/backend data.
const path=require('node:path');
const fs=require('node:fs');
const assert=require('node:assert/strict');
const {sparseMemoryFixture}=require('./fixtures/memory-topology.cjs');

module.exports=async({load,root,check,json,mediaKit,settle})=>{
  const {GraphSnapshot}=load(path.join(root,'model/GraphSnapshot.ets'));
  const {GraphWheel,WheelGeometry,WheelTickGate,wheelSlots,WHEEL_WINDOW,WHEEL_STEP}=load(path.join(root,'model/GraphWheel.ets'));
  const {GraphCanvas}=load(path.join(root,'components/GraphCanvas.ets'));
  const {GraphPage}=load(path.join(root,'view/GraphPage.ets'));
  const {WheelSound}=load(path.join(root,'service/WheelSound.ets'));
  const {GraphTextLayout,graphPreviewText}=load(path.join(root,'model/GraphTextLayout.ets'));
  const nodes=[{id:'person',label:'Person',name:'模拟人物'},{id:'a',label:'Concept',name:'概念 A'},
    {id:'b',label:'Event',name:'事件 B'},{id:'c',label:'Location',name:'地点 C'},{id:'loose',label:'Concept',name:'独立节点'}];
  const edges=[{source:'person',target:'a',type:'KNOWS'},{source:'person',target:'b',type:'REMEMBERS'},
    {source:'a',target:'b',type:'RELATES'},{source:'a',target:'b',type:'ALSO'},
    {source:'b',target:'a',type:'BACK'},{source:'person',target:'person',type:'SELF'}];
  const snapshot=()=>new GraphSnapshot({nodes:{},relationships:edges.length},{nodes,relationships:edges});
  const labels=['Concept','Event','Location','Person'];
  function star(count=3000){
    const records=[{id:'hub',label:'Person',name:'虚构中心'},...Array.from({length:count},(_,i)=>({id:'n'+String(i).padStart(5,'0'),label:'Concept',name:'概念 '+i}))];
    const links=records.slice(1).map(n=>({source:'hub',target:n.id,type:'KNOWS'}));
    return new GraphSnapshot({nodes:{Person:1,Concept:count},relationships:links.length},{nodes:records,relationships:links});
  }
  function mounted(source=star(33)){
    const widget=new GraphCanvas();widget.scene=source.visualization();widget.soundEnabled=true;widget.startSound=()=>{};
    widget.onRotate=index=>{widget.scene=source.visualization(widget.scene.centerId,index);widget.sceneChanged();};
    widget.canvasWidth=360;widget.canvasHeight=360;widget.aboutToAppear();return widget;
  }
  function context(calls){
    const ctx={measureText:text=>({width:[...text].reduce((sum,c)=>sum+(/[^\x00-\x7F]/.test(c)?1:.55),0)*Number((ctx.font||'16vp').match(/([\d.]+)vp/)?.[1]||16)})};
    for(const method of ['clearRect','fillRect','beginPath','closePath','arc','ellipse','fill','stroke','moveTo','lineTo','fillText']){
      ctx[method]=(...args)=>{for(const value of args)if(typeof value==='number')assert.ok(Number.isFinite(value));const call=[method,...args];call.font=ctx.font;calls.push(call);};
    }
    return ctx;
  }
  function tapFocused(widget){
    const node=widget.scene.nodes.find(n=>n.raw.id!==widget.scene.centerId&&n.wheelIndex===widget.wheel.index());
    const point=widget.point(node,widget.geometry());widget.tap({fingerList:[{localX:point.x,localY:point.y}]});
  }
  function finishNavigation(widget){
    widget.advanceNavigation(widget.navigationStartedAt+220);
    widget.advanceNavigation(widget.navigationStartedAt+300);
  }

  await check('a 3000-neighbor wheel prepares only seven neighbors and retains every raw node and relation',()=>{
    const source=star(),scene=source.visualization();
    assert.equal(source.nodes.length,3001);assert.equal(source.relationships.length,3000);
    assert.equal(scene.nodes.length,WHEEL_WINDOW+1);assert.equal(scene.edges.length,WHEEL_WINDOW);
    assert.equal(scene.neighborTotal,3000);assert.equal(scene.wheelIndex,0);assert.equal(source.nodeRelations('hub').length,3000);
    assert.equal(source.visualization(),scene);
  });
  await check('rotating to every detent reaches all neighbors without duplicates within a window',()=>{
    const source=star(153),reached=new Set();
    for(let index=0;index<153;index++){
      const scene=source.visualization('hub',index);assert.ok(scene.nodes.length<=WHEEL_WINDOW+1);
      assert.equal(new Set(scene.nodes.map(n=>n.raw.id)).size,scene.nodes.length);
      const focus=scene.nodes.find(n=>n.raw.id!=='hub'&&n.wheelIndex===scene.wheelIndex);
      assert.ok(focus);reached.add(focus.raw.id);
    }
    assert.equal(reached.size,153);assert.equal(source.visualization('hub',153).wheelIndex,0);
    assert.equal(source.visualization('hub',-1).wheelIndex,152);assert.equal(source.visualization('hub',NaN).wheelIndex,0);
    for(let count=0;count<7;count++){
      const local=star(count),ids=new Set();
      for(let i=0;i<Math.max(1,count);i++)for(const n of local.visualization('hub',i).nodes)if(n.raw.id!=='hub')ids.add(n.raw.id);
      assert.equal(ids.size,count);
    }
  });
  await check('wheel caches are bounded and filters share one canonical key',()=>{
    const source=star(130),scene=source.visualization('hub',0,labels);
    assert.equal(source.visualization('hub',0,labels.slice().reverse()),scene);
    for(let index=0;index<13;index++)source.visualization('hub',index,labels);
    assert.equal(source.scenes.size,8);assert.notEqual(source.visualization('hub',0,labels),scene);
    assert.equal(source.visualization('hub',0,[]).nodes.length,0);
  });
  await check('neighbor-to-neighbor edges, parallel/reverse relations and self loops retain their original records',()=>{
    const scene=snapshot().visualization();assert.equal(scene.nodes.length,3);assert.equal(scene.edges.length,4);assert.equal(scene.relationshipCount,6);
    const pair=scene.edges.find(e=>e.source.raw.id==='a'&&e.target.raw.id==='b');
    assert.equal(pair.relations.length,3);assert.equal(pair.forward,true);assert.equal(pair.backward,true);
    assert.deepEqual(json(pair.relations.map(e=>e.type).sort()),['ALSO','BACK','RELATES']);assert.match(pair.title(),/\+2$/);
    assert.ok(scene.edges.some(e=>e.source===e.target));
  });
  await check('dangling endpoints and isolated nodes stay accessible without fabricating connections',()=>{
    const source=new GraphSnapshot({nodes:{},relationships:7},{nodes,relationships:edges.concat({source:'missing',target:'a',type:'BAD'})});
    assert.equal(source.visualization().missingEdges,1);assert.equal(source.findNode('missing'),null);
    assert.equal(source.visualization('loose').nodes.length,1);assert.equal(source.visualization('loose').neighborTotal,0);
    const concepts=source.visualization('person',0,['Concept']);assert.equal(concepts.centerId,'a');assert.ok(concepts.nodes.every(n=>n.raw.label==='Concept'));
  });
  await check('a sparse 1271-node 1952-edge memory can focus any chosen node with a bounded wheel',()=>{
    const data=sparseMemoryFixture(),records=data.nodes.map(n=>({id:String(n.id),label:n.type,name:n.name}));
    const links=data.edges.map(e=>({source:records[e.a].id,target:records[e.b].id,type:e.type}));
    const source=new GraphSnapshot({nodes:{},relationships:links.length},{nodes:records,relationships:links});
    for(const id of ['0','100','1000','1270']){const scene=source.visualization(id);assert.equal(scene.centerId,id);assert.ok(scene.nodes.length<=8);}
    assert.equal(source.nodes.length,1271);assert.equal(source.relationships.length,1952);
  });
  await check('rotary geometry keeps the core fixed, wraps smoothly and handles tiny/empty neighbor sets',()=>{
    const wheel=new GraphWheel();wheel.set(153,0);wheel.turn(WHEEL_STEP*.4);assert.ok(Math.abs(wheel.position-152.6)<1e-8);
    assert.equal(wheel.index(),0);assert.ok(Math.abs(wheel.offset(0)-.4)<1e-8);
    wheel.turn(WHEEL_STEP*.3);assert.equal(wheel.index(),152);wheel.snap();assert.equal(wheel.position,152);
    for(const [w,h] of [[360,360],[300,240],[600,400]]){
      const g=new WheelGeometry(w,h),top=g.point(0),side=g.point(1);
      assert.equal(g.x,w/2);assert.ok(g.y>h);assert.ok(top.y>20&&top.y<h);assert.ok(side.x>top.x);
      assert.ok(Math.abs(Math.hypot(top.x-g.x,top.y-g.y)-g.orbit)<1e-8);
    }
    for(let count=0;count<7;count++){wheel.set(count,1000);assert.equal(wheel.index(),Math.max(0,count-1));assert.ok(wheelSlots(wheel.position,count).length<=count);}
  });
  await check('arc dragging rotates neighbors, snaps on release and taps use the same projection',async()=>{
    const widget=mounted(),g=widget.geometry(),start=g.point(0),end=g.point(-1.3),sound=[];widget.sounds={play:select=>sound.push(select),release(){}};
    widget.panStart({fingerList:[{localX:start.x,localY:start.y}]});
    widget.pan({offsetX:end.x-start.x,offsetY:end.y-start.y});assert.equal(widget.scene.wheelIndex,1);
    assert.ok(Math.abs(widget.wheel.position-1.3)<1e-8);assert.equal(g.x,widget.geometry().x);assert.equal(g.y,widget.geometry().y);
    widget.panEnd();const deadline=Date.now()+1000;
    while(widget.rotating&&Date.now()<deadline)await new Promise(resolve=>setTimeout(resolve,25));
    assert.equal(widget.wheel.position,1);assert.equal(sound.length,1);
    const focus=widget.scene.nodes.find(n=>n.raw.id!=='hub'&&n.wheelIndex===1),point=widget.point(focus,widget.geometry());let selected;
    widget.onSelect=node=>selected=node.id;widget.tap({fingerList:[{localX:point.x,localY:point.y}]});
    assert.equal(selected,undefined);finishNavigation(widget);assert.equal(selected,focus.raw.id);
    let inspected;widget.onInspect=node=>inspected=node.id;widget.tap({fingerList:[{localX:g.x,localY:g.y-g.core+45}]});assert.equal(inspected,'hub');widget.aboutToDisappear();
  });
  await check('detent ticks are throttled, never repeated after a pause, and muting suppresses both interaction sounds',()=>{
    const gate=new WheelTickGate();gate.reset(0);
    assert.equal(gate.crossed(0,0),false);assert.equal(gate.crossed(1,0),true);assert.equal(gate.crossed(2,20),false);
    assert.equal(gate.crossed(2,1000),false);assert.equal(gate.crossed(3,1000),true);
    const widget=mounted(),sound=[];widget.sounds={play:()=>sound.push(1),release(){}};widget.soundEnabled=false;
    widget.step(1);tapFocused(widget);assert.equal(sound.length,0);widget.aboutToDisappear();
  });
  await check('navigation moves the selected circle before committing once, then expands only its local neighbors',()=>{
    const source=star(33),widget=mounted(source),g=widget.geometry(),origin=widget.scene,calls=[],sounds=[];
    widget.context=context(calls);widget.sounds={play:()=>sounds.push(1),release(){}};let commits=0;
    widget.onSelect=node=>{commits++;widget.scene=source.visualization(node.id);widget.sceneChanged();};
    const selected=origin.nodes.find(n=>n.raw.id!=='hub'&&n.wheelIndex===0);
    tapFocused(widget);const started=widget.navigationStartedAt;
    assert.equal(widget.navigationPhase,1);assert.equal(widget.scene,origin);assert.equal(commits,0);
    tapFocused(widget);widget.step(1);widget.panStart({fingerList:[{localX:g.x,localY:50}]});
    assert.equal(widget.rotating,false);assert.equal(sounds.length,1);
    widget.advanceNavigation(started+110);widget.paint();assert.equal(widget.scene,origin);
    assert.ok(calls.some(c=>c[0]==='arc'&&c[3]>g.nodeRadius&&c[3]<g.core));
    widget.advanceNavigation(started+220);assert.equal(commits,1);assert.equal(widget.navigationPhase,3);
    assert.equal(widget.scene.centerId,selected.raw.id);assert.ok(widget.scene.nodes.length<=8);
    const neighbor=widget.scene.nodes.find(n=>n.raw.id!==widget.scene.centerId),p=widget.point(neighbor,g);
    assert.equal(p.x,g.x);assert.equal(p.y,g.y);assert.equal(widget.radius(neighbor,g),8);
    const expanded=widget.navigationStartedAt;widget.advanceNavigation(expanded+140);widget.paint();
    assert.ok(widget.point(neighbor,g).y<g.y);assert.ok(widget.radius(neighbor,g)<g.nodeRadius);
    widget.advanceNavigation(expanded+280);widget.paint();assert.equal(widget.navigationPhase,0);
    assert.equal(widget.radius(neighbor,g),g.nodeRadius);assert.equal(commits,1);assert.equal(sounds.length,1);
    widget.aboutToDisappear();
  });
  await check('leaving or replacing a scene cancels navigation and a rejected selection cannot lock input',()=>{
    const source=star(10),widget=mounted(source);let commits=0;widget.onSelect=()=>commits++;
    tapFocused(widget);widget.ready=true;widget.requestPaint();widget.aboutToDisappear();
    assert.equal(widget.frame,-1);assert.equal(widget.navigationPhase,0);widget.advanceNavigation(Date.now()+1000);assert.equal(commits,0);
    widget.aboutToAppear();tapFocused(widget);widget.scene=source.visualization('hub',2);widget.sceneChanged();
    assert.equal(widget.navigationPhase,0);assert.equal(commits,0);
    tapFocused(widget);widget.advanceNavigation(widget.navigationStartedAt+220);assert.equal(commits,1);
    assert.equal(widget.navigationPhase,2);widget.advanceNavigation(widget.navigationStartedAt+300);assert.equal(widget.navigationPhase,0);
    widget.step(1);assert.equal(widget.wheel.index(),3);widget.aboutToDisappear();
  });
  await check('long Event navigation reuses fixed-size labels across morph and expansion frames',()=>{
    const source=new GraphSnapshot({nodes:{},relationships:1},{nodes:[nodes[0],{id:'event',label:'Event',summary:'虚构事件 '.repeat(1400),content:'完整虚构正文 '.repeat(2000)}],
      relationships:[{source:'person',target:'event',type:'REMEMBERS'}]});
    const widget=mounted(source),calls=[];widget.context=context(calls);let measures=0,queries=0;
    const measure=widget.context.measureText;widget.context.measureText=text=>{measures++;return measure(text);};
    widget.onSelect=node=>{queries++;widget.scene=source.visualization(node.id);widget.sceneChanged();};
    widget.paint();tapFocused(widget);const started=widget.navigationStartedAt;
    widget.advanceNavigation(started+10);widget.paint();const warmed=measures;
    for(let t=20;t<220;t+=10){widget.advanceNavigation(started+t);widget.paint();}
    assert.equal(measures,warmed,'morph must reuse fixed font/width keys');
    widget.advanceNavigation(started+220);const expansion=widget.navigationStartedAt;
    widget.advanceNavigation(expansion+100);widget.paint();const revealWarm=measures;
    for(let t=110;t<=280;t+=10){widget.advanceNavigation(expansion+t);widget.paint();}
    assert.equal(measures,revealWarm);assert.equal(queries,1);assert.ok(measures<120);widget.aboutToDisappear();
  });
  await check('wheel draw commands stay bounded and leaving cancels pending paint work',()=>{
    const widget=mounted(star()),calls=[];widget.context=context(calls);widget.paint();
    assert.ok(calls.some(c=>c[0]==='arc'&&c[3]===widget.geometry().core));assert.ok(calls.some(c=>c[0]==='fillText'&&c[1]==='当前节点'));
    assert.ok(calls.some(c=>c[0]==='lineTo'));assert.ok(calls.length<550);
    widget.ready=true;widget.requestPaint();assert.notEqual(widget.frame,-1);widget.aboutToDisappear();assert.equal(widget.frame,-1);
    assert.equal(widget.snapTimer,-1);
  });
  await check('long Event summaries do not cause per-character text measurements on every frame',()=>{
    const records=[{id:'hub',label:'Person',name:'模拟中心'},...Array.from({length:40},(_,i)=>({
      id:'event-'+i,label:'Event',summary:'模拟事件 '+i+' '+ 'x'.repeat(2500),content:'模拟完整正文 '.repeat(1000)
    }))];
    const links=records.slice(1).map(n=>({source:'hub',target:n.id,type:'PARTICIPATED_IN'}));
    const source=new GraphSnapshot({nodes:{},relationships:links.length},{nodes:records,relationships:links});
    const widget=mounted(source),calls=[];widget.context=context(calls);let measures=0;
    widget.context.measureText=text=>{measures++;return {width:text.length*8};};
    try{
      widget.paint();const first=measures;
      for(let frame=0;frame<12;frame++)widget.paint();
      assert.ok(first<120,'initial native measureText calls: '+first);
      assert.equal(measures-first,0,'unchanged Event labels must reuse measured text');
    }finally{widget.aboutToDisappear();}
  });
  await check('canvas labels use density-aware sizes and associated nodes have readable proportions',()=>{
    const widget=mounted(),calls=[];widget.context=context(calls);widget.paint();
    const text=calls.filter(call=>call[0]==='fillText');assert.ok(text.every(call=>/vp/.test(call.font)));
    assert.ok(text.some(call=>call.font==='500 16vp sans-serif'));assert.ok(text.some(call=>call.font==='500 20vp sans-serif'));
    for(const [w,h] of [[300,240],[360,360],[600,400]]){
      const g=new WheelGeometry(w,h);assert.ok(g.nodeRadius>=36);assert.ok(g.core/g.nodeRadius<2.7);assert.ok(g.core/g.nodeRadius>1.7);
      const a=g.point(0),b=g.point(1);assert.ok(Math.hypot(a.x-b.x,a.y-b.y)>g.nodeRadius*2);
    }
    widget.aboutToDisappear();
  });
  await check('native sound switch updates the controlling value immediately and repeated mute changes affect playback',()=>{
    const widget=mounted(),played=[];widget.sounds={play:()=>played.push(1),release(){}};
    widget.setSoundEnabled(false);assert.equal(widget.soundEnabled,false);tapFocused(widget);assert.equal(played.length,0);
    widget.setSoundEnabled(true);assert.equal(widget.soundEnabled,true);assert.equal(played.length,1);
    widget.setSoundEnabled(false);tapFocused(widget);assert.equal(played.length,1);
    const canvas=fs.readFileSync(path.join(root,'components/GraphCanvas.ets'),'utf8');
    const page=fs.readFileSync(path.join(root,'view/GraphPage.ets'),'utf8');
    assert.match(canvas,/@Link soundEnabled/);assert.match(canvas,/ToggleType.Switch/);assert.match(page,/soundEnabled: \$soundEnabled/);
    assert.doesNotMatch(page,/NodeList|RelationList|'nodes'|'relations'/);widget.aboutToDisappear();
  });
  await check('drawing previews omit heavy Event payloads while node details retain their complete original content',()=>{
    const event={id:'event',label:'Event',summary:'模拟摘要 '.repeat(1200),content:'模拟正文 '.repeat(2500),create_time:'synthetic-time'};
    const source=new GraphSnapshot({nodes:{},relationships:1},{nodes:[nodes[0],event],relationships:[{source:'person',target:'event',type:'REMEMBERS'}]});
    const drawn=source.visualization().find('event').raw;
    assert.ok(drawn.name.length<=129);assert.equal(drawn.summary,undefined);assert.equal(drawn.content,undefined);
    const page=new GraphPage();page.applySnapshot(source);page.selectNode(drawn);
    assert.equal(page.selectedNode.summary,event.summary);assert.equal(page.selectedNode.content,event.content);assert.equal(page.selectedNode.create_time,event.create_time);
    const preview=graphPreviewText('a'.repeat(127)+'😀后续');assert.ok(!/[\uD800-\uDBFF]…$/.test(preview));
  });
  await check('rotating an Event-heavy hub uses bounded pair lookups instead of rescanning incident relations',()=>{
    const source=star(600);source.nodeRelations=()=>{throw new Error('wheel must use pair index');};
    let reads=0;const get=source.pairs.get.bind(source.pairs);source.pairs.get=key=>{reads++;return get(key);};
    for(let index=0;index<20;index++)source.visualization('hub',index);
    assert.ok(reads<=20*36);assert.ok(source.filtered.size<=16);
  });
  await check('text fitting uses bounded caches, distinguishes fonts and widths, and avoids splitting emoji',()=>{
    const layout=new GraphTextLayout();let reads=0;const measure=text=>{reads++;return [...text].length*10;};
    const first=layout.fit('😀'.repeat(5000),60,'16vp',measure);const cold=reads;
    assert.ok([...first].length<=6);assert.ok(cold<12);assert.ok(!/[\uD800-\uDBFF]…$/.test(first));
    assert.equal(layout.fit('😀'.repeat(5000),60,'16vp',measure),first);assert.equal(reads,cold);
    layout.fit('😀'.repeat(5000),80,'16vp',measure);assert.ok(reads>cold);
    const before=reads;layout.fit('😀'.repeat(5000),80,'20vp',measure);assert.ok(reads>before);
    for(let i=0;i<600;i++)layout.fit('模拟文本 '+i,40,'16vp',measure);
    assert.ok(layout.fits.size<=256);assert.ok(layout.widths.size<=256);layout.clear();assert.equal(layout.widths.size,0);
  });
  await check('the wheel footer has no duplicate detail or center-selection action buttons',()=>{
    const canvas=fs.readFileSync(path.join(root,'components/GraphCanvas.ets'),'utf8');
    assert.doesNotMatch(canvas,/WheelButton\('详情'|设为中心|chooseFocus/);
    const widget=mounted();let selected,inspected;widget.onSelect=node=>selected=node.id;widget.onInspect=node=>inspected=node.id;
    tapFocused(widget);finishNavigation(widget);assert.ok(selected);const g=widget.geometry();widget.tap({fingerList:[{localX:g.x,localY:g.y-g.core+45}]});assert.equal(inspected,'hub');widget.aboutToDisappear();
  });
  await check('details use a separate tab and returning preserves the center and rotary detent',()=>{
    const page=new GraphPage(),source=star(33);page.applySnapshot(source);page.rotateWheel(20);
    const next=page.scene.nodes.find(n=>n.raw.id!=='hub'&&n.wheelIndex===20).raw;
    page.selectNode(next);assert.equal(page.activeTab,'details');assert.equal(page.centerId,'hub');assert.equal(page.wheelIndex,20);
    page.closeDetail();assert.equal(page.activeTab,'graph');assert.equal(page.wheelIndex,20);
    page.tapGraphNode(next);assert.equal(page.centerId,next.id);assert.equal(page.canGoBack,true);
    page.browseBack();assert.equal(page.centerId,'hub');assert.equal(page.wheelIndex,20);
    page.selectNode(next);assert.equal(page.activeTab,'details');page.closeDetail();assert.equal(page.activeTab,'graph');
    assert.equal(page.nodeRelations(source.nodes[0]).length,33);page.searchText='概念 32';page.updateFiltered();page.focusNode(page.searchMatches[0]);assert.equal(page.centerId,'n00032');
    assert.doesNotMatch(fs.readFileSync(path.join(root,'view/GraphPage.ets'),'utf8'),/bindSheet|DetailSheet|detailOpen/);page.aboutToDisappear();
  });
  await check('filters and refreshing while reading details repair a deleted center when returning to the wheel',()=>{
    const page=new GraphPage();page.applySnapshot(snapshot());page.selectNode(nodes[0]);page.toggleLabel('Person');
    assert.equal(page.selectedNode,null);assert.equal(page.activeTab,'graph');assert.notEqual(page.centerId,'person');
    page.selectNode(nodes[1]);page.applySnapshot(new GraphSnapshot({nodes:{Concept:1},relationships:0},{nodes:[nodes[4]],relationships:[]}));
    page.closeDetail();assert.equal(page.centerId,'loose');assert.equal(page.scene.nodes.length,1);
  });

  function poolMock(){
    const handlers={},played=[],loaded=[];let releases=0;
    const pool={on:(name,cb)=>handlers[name]=cb,load:async(...args)=>{loaded.push(args);return loaded.length;},
      play:async(id,params)=>{played.push({id,params});return 1;},release:async()=>{releases++;}};
    return {pool,handlers,played,loaded,get releases(){return releases;}};
  }
  await check('local sounds play only after loadComplete and release both pool and raw descriptors',async()=>{
    const before=mediaKit.media.createSoundPool,mock=poolMock(),closed=[];
    mediaKit.media.createSoundPool=async()=>mock.pool;
    const manager={getRawFd:async()=>({fd:4,offset:100,length:2048}),closeRawFd:async name=>closed.push(name)};
    try{
      const sound=new WheelSound();assert.equal(await sound.start(manager),true);sound.play();assert.equal(mock.played.length,0);
      mock.handlers.loadComplete(1);sound.play();mock.handlers.loadComplete(2);sound.play(true);
      assert.deepEqual(mock.played.map(p=>p.id),[1,2]);assert.equal(mock.played[0].params.loop,0);assert.ok(mock.played[0].params.leftVolume<=.3);
      sound.release();await WheelSound.cleanup;assert.equal(mock.releases,1);assert.deepEqual(closed.sort(),['wheel_select.wav','wheel_tick.wav']);
      sound.play();assert.equal(mock.played.length,2);
    }finally{mediaKit.media.createSoundPool=before;}
  });
  await check('leaving during asynchronous sound loading closes a late descriptor and cannot play it',async()=>{
    const before=mediaKit.media.createSoundPool,mock=poolMock(),closed=[];let finishFd;
    mediaKit.media.createSoundPool=async()=>mock.pool;
    const manager={getRawFd:()=>new Promise(resolve=>finishFd=resolve),closeRawFd:async name=>closed.push(name)};
    try{
      const sound=new WheelSound(),pending=sound.start(manager);await settle();assert.ok(finishFd);sound.release();
      finishFd({fd:8,offset:0,length:1024});assert.equal(await pending,false);await WheelSound.cleanup;
      assert.equal(mock.releases,1);assert.equal(mock.loaded.length,0);assert.deepEqual(closed,['wheel_tick.wav']);
      mock.handlers.loadComplete(1);sound.play();assert.equal(mock.played.length,0);
    }finally{mediaKit.media.createSoundPool=before;}
  });
  await check('sound creation completing after exit releases its pool without opening files',async()=>{
    const before=mediaKit.media.createSoundPool,mock=poolMock();let finishCreate,opened=0;
    mediaKit.media.createSoundPool=()=>new Promise(resolve=>finishCreate=resolve);
    try{
      const sound=new WheelSound(),pending=sound.start({getRawFd:async()=>{opened++;return {fd:1,offset:0,length:1024};},closeRawFd:async()=>{}});
      await settle();sound.release();finishCreate(mock.pool);assert.equal(await pending,false);await WheelSound.cleanup;
      assert.equal(mock.releases,1);assert.equal(opened,0);
    }finally{mediaKit.media.createSoundPool=before;}
  });
};
