// Offline visual review of the real ArkTS graph geometry and Canvas drawing methods.
// Uses synthetic data only; never opens the app or connects to its backend.
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.TYPESCRIPT_MODULE || 'C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const {fixture,sparseMemoryFixture} = require('./fixtures/memory-topology.cjs');
const output = path.resolve(__dirname, '../.cache/graph-preview');
fs.mkdirSync(output, {recursive: true});
const sources = ['model/GraphWheel', 'model/GraphTextLayout', 'model/GraphSnapshot', 'model/GraphScene', 'components/GraphCanvas'];
const modules = {'service/WheelSound':'exports.WheelSound=class { release(){} play(){} };'};
for (const id of sources) {
  let source = fs.readFileSync(path.resolve(__dirname, '../entry/src/main/ets', id + '.ets'), 'utf8');
  if (id.endsWith('GraphCanvas')) {
    source = source.slice(0, source.indexOf('  @Builder')) + '\n}';
    source = source.replace('export struct GraphCanvas', 'export class GraphCanvas')
      .replace(/@Component\s*/g, '').replace(/@(State|Prop|Link|ObjectLink)\s+/g, '').replace(/@Watch\('[^']+'\)\s*/g, '')
      .replace(/new CanvasRenderingContext2D\(new RenderingContextSettings\(true\)\)/, 'null');
  }
  modules[id] = ts.transpileModule(source, {compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  }}).outputText;
}
const data = process.argv.includes('--sparse') ? sparseMemoryFixture() : fixture(1271);
const nodes = data.nodes.map(n => ({id: String(n.id).padStart(5,'0'), label: n.type,
  name: process.argv.includes('--long-events') && n.type==='Event' ? undefined : n.name,
  summary: process.argv.includes('--long-events') && n.type==='Event' ? n.name+' · 模拟长摘要 '+ '事件内容'.repeat(625) : undefined,
  content: process.argv.includes('--long-events') && n.type==='Event' ? '模拟详情正文'.repeat(1000) : undefined }));
const edges = data.edges.map(e => ({source: nodes[e.a].id, target: nodes[e.b].id, type: e.type}));
const html = `<!doctype html><meta charset="utf-8"><title>虚构图谱 · 实际绘制代码</title>
<style>body{margin:0;background:#211c16;color:#d9cfc1;font-family:system-ui;display:flex;justify-content:center;gap:28px;padding:24px}section{width:360px}h3{font-size:15px;font-weight:500}canvas{display:block;border:1px solid #362e25;border-radius:12px 12px 0 0;width:360px;height:340px;touch-action:none}p{font-size:12px;color:#9b9183}.footer{background:#2b241c;padding:12px;border-radius:0 0 12px 12px;font-size:12px}.row{display:flex;align-items:center;gap:8px;margin-bottom:8px}.name{flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}button{background:#3c3025;border:0;color:#d0b99c;padding:7px 10px;border-radius:8px;cursor:pointer}.hint{margin:16px 0;padding:12px;background:#2b241c;min-height:28px;font-size:12px}</style>
<section><h3 id="first-title">围绕人物探索</h3><canvas id="overview" width="1080" height="1020"></canvas><div class="footer" id="overview-footer"></div><p id="stats"></p><div class="hint" id="overview-info">拖动圆弧旋转；详情显示在这个独立区域。</div></section>
<section><h3 id="second-title">点击相邻记忆后</h3><canvas id="detail" width="1080" height="1020"></canvas><div class="footer" id="detail-footer"></div><p>虚构数据 · 当前绘制代码 · 此预览不代表手机实测。</p><div class="hint" id="detail-info">节点详情不会覆盖轮盘。</div></section>
<script>
window.Observed=cls=>cls;
const modules=${JSON.stringify(modules)}, loaded={};
function load(id){if(loaded[id])return loaded[id];const out={};loaded[id]=out;
new Function('exports','require',modules[id])(out, name=>{const parts=id.split('/');parts.pop();for(const p of name.split('/')){if(p==='..')parts.pop();else if(p!=='.')parts.push(p);}return load(parts.join('/'));});return out;}
const {GraphSnapshot}=load('model/GraphSnapshot'), {GraphCanvas}=load('components/GraphCanvas');
const start=performance.now(),snapshot=new GraphSnapshot({nodes:{},relationships:${edges.length}},{nodes:${JSON.stringify(nodes)},relationships:${JSON.stringify(edges)}});
const scene=snapshot.visualization(),duration=performance.now()-start;
function render(id,scene){const canvas=document.getElementById(id),ctx=canvas.getContext('2d');ctx.scale(3,3);
const fontProperty=Object.getOwnPropertyDescriptor(CanvasRenderingContext2D.prototype,'font');
Object.defineProperty(ctx,'font',{get:()=>fontProperty.get.call(ctx),set:value=>fontProperty.set.call(ctx,value.replace(/vp/g,'px'))});
let textMeasures=0;const nativeMeasure=ctx.measureText.bind(ctx);ctx.measureText=value=>{textMeasures++;return nativeMeasure(value);};
const widget=new GraphCanvas();widget.scene=scene;widget.soundEnabled=true;widget.startSound=()=>{};widget.canvasWidth=360;widget.canvasHeight=340;widget.context=ctx;widget.aboutToAppear();widget.ready=true;
function update(){widget.paint();document.getElementById(id+'-footer').innerHTML='<div class="row"><span class="name">'+(widget.focusTitle||'暂无关联')+'</span></div><div class="row"><button data-action="prev">‹</button><span>'+widget.focusPosition+'</span><button data-action="next">›</button><span class="name"></span><label>音效 <input type="checkbox" data-action="sound" '+(widget.soundEnabled?'checked':'')+'></label></div>';}
widget.onRotate=index=>{widget.scene=snapshot.visualization(widget.scene.centerId,index);widget.sceneChanged();update();};
widget.onSelect=node=>{widget.scene=snapshot.visualization(node.id);widget.sceneChanged();update();};
widget.onInspect=node=>document.getElementById(id+'-info').textContent='节点详情：'+node.name+' · '+node.label+' · '+snapshot.nodeRelations(node.id).length+' 条原始关系';
let start=null;
canvas.onpointerdown=event=>{const box=canvas.getBoundingClientRect();start={x:event.clientX-box.left,y:event.clientY-box.top,moved:false};canvas.setPointerCapture(event.pointerId);widget.panStart({fingerList:[{localX:start.x,localY:start.y}]});};
canvas.onpointermove=event=>{if(!start)return;const box=canvas.getBoundingClientRect(),dx=event.clientX-box.left-start.x,dy=event.clientY-box.top-start.y;if(Math.hypot(dx,dy)>4)start.moved=true;if(start.moved){widget.pan({offsetX:dx,offsetY:dy});update();}};
canvas.onpointerup=event=>{if(!start)return;const box=canvas.getBoundingClientRect();if(start.moved)widget.panEnd();else{widget.rotating=false;widget.tap({fingerList:[{localX:event.clientX-box.left,localY:event.clientY-box.top}]});}start=null;update();};
document.getElementById(id+'-footer').onclick=event=>{const action=event.target.dataset.action;if(action==='sound')return;if(action==='prev')widget.step(-1);if(action==='next')widget.step(1);update();};
document.getElementById(id+'-footer').onchange=event=>{if(event.target.dataset.action==='sound'){widget.setSoundEnabled(event.target.checked);update();}};
update();const firstMeasures=textMeasures;for(let frame=0;frame<12;frame++)widget.paint();
widget.previewMetrics={firstMeasures,warmMeasures:textMeasures-firstMeasures};return widget;}
window.wheelPreview=render('overview',scene);
const next=scene.nodes.find(n=>n.raw.label==='Event')||scene.nodes.find(n=>n.raw.id!==scene.centerId);
const detail=snapshot.visualization(next.raw.id);render('detail',detail);
document.getElementById('first-title').textContent='当前：'+scene.find(scene.centerId).raw.name+' · 关系轮盘';
document.getElementById('second-title').textContent='点击后：'+detail.find(detail.centerId).raw.name;
document.getElementById('stats').textContent='全库 '+snapshot.nodes.length+' 节点 / '+snapshot.relationships.length+' 关系；本页 '+scene.nodes.length+' 节点 / '+scene.relationshipCount+' 关系';
window.result={totalNodes:snapshot.nodes.length,totalEdges:snapshot.relationships.length,preparedNodes:scene.nodes.length,drawnConnections:scene.edges.length,neighborCount:scene.neighborTotal,desktopIndexAndScopeMs:duration,textMeasurements:wheelPreview.previewMetrics};
</script>`;
fs.writeFileSync(path.join(output, 'index.html'), html);
if (process.argv.includes('--render')) (async () => {
  const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'C:/Users/shuun/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
  const browser = await chromium.launch({headless:true,channel:'chrome'});
  try {
    const page = await browser.newPage({viewport:{width:810,height:635},deviceScaleFactor:1});
    const errors=[];page.on('pageerror',error=>errors.push(error.message));
    await page.goto('file:///' + path.join(output,'index.html').replace(/\\/g,'/'));
    if(errors.length)throw new Error(errors.join('\n'));
    if(process.argv.includes('--check-interaction')){
      const canvas=await page.locator('#overview').boundingBox();
      const gesture=await page.evaluate(()=>{const g=wheelPreview.geometry();return {start:g.point(0),end:g.point(-1.4)};});
      await page.mouse.move(canvas.x+gesture.start.x,canvas.y+gesture.start.y);
      await page.mouse.down();await page.mouse.move(canvas.x+gesture.end.x,canvas.y+gesture.end.y,{steps:8});await page.mouse.up();
      await page.waitForFunction(()=>!wheelPreview.rotating);
      const rotary=await page.evaluate(()=>({index:wheelPreview.scene.wheelIndex,count:wheelPreview.scene.nodes.length,center:wheelPreview.scene.centerId}));
      if(rotary.index!==1||rotary.count>8)throw new Error('Rotary pointer interaction failed: '+JSON.stringify(rotary));
      const core=await page.evaluate(()=>{const g=wheelPreview.geometry();return {x:g.x,y:g.y-g.core+45};});
      await page.mouse.click(canvas.x+core.x,canvas.y+core.y);
      if(!(await page.locator('#overview-info').textContent()).startsWith('节点详情：'))throw new Error('Independent inspector did not update');
      if(await page.evaluate(()=>wheelPreview.scene.centerId)!==rotary.center)throw new Error('Inspecting changed wheel center');
      await page.locator('#overview-footer input[data-action="sound"]').uncheck();
      if(await page.evaluate(()=>wheelPreview.soundEnabled)!==false)throw new Error('Sound did not turn off');
      await page.locator('#overview-footer input[data-action="sound"]').check();
      if(await page.evaluate(()=>wheelPreview.soundEnabled)!==true)throw new Error('Sound did not turn on');
      await page.evaluate(()=>{wheelPreview.step(-1);document.getElementById('overview-info').textContent='拖动圆弧旋转；详情显示在这个独立区域。';});
      console.log('PASS pointer rotation, detent snap and independent detail area');
      const target=await page.evaluate(()=>{const w=wheelPreview,n=w.scene.nodes.find(n=>n.raw.id!==w.scene.centerId&&n.wheelIndex===w.wheel.index());return {id:n.raw.id,...w.point(n,w.geometry())};});
      await page.mouse.click(canvas.x+target.x,canvas.y+target.y);
      await page.waitForFunction(()=>wheelPreview.navigationPhase===3);
      if(await page.evaluate(()=>wheelPreview.scene.centerId)!==target.id)throw new Error('Animated navigation chose the wrong center');
      await page.waitForFunction(()=>wheelPreview.navigationPhase===0&&wheelPreview.frame===-1);
      if(await page.evaluate(()=>wheelPreview.scene.nodes.length)>8)throw new Error('Animation expanded beyond the local window');
      console.log('PASS pointer selection morphs, reveals neighbors and stops scheduling frames');
    }
    if(process.argv.includes('--transition-frames')){
      const frames=await page.evaluate(()=>{
        const w=wheelPreview;w.ready=false;if(w.frame>=0){clearTimeout(w.frame);w.frame=-1;}
        w.cancelNavigation();w.scene=snapshot.visualization();w.sceneChanged();w.paint();
        const canvas=document.getElementById('overview'),frames=[];
        const capture=label=>{w.paint();frames.push({label,url:canvas.toDataURL()});};
        const node=w.scene.nodes.find(n=>n.raw.id!==w.scene.centerId&&n.wheelIndex===w.wheel.index());
        const p=w.point(node,w.geometry());w.tap({fingerList:[{localX:p.x,localY:p.y}]});
        const start=w.navigationStartedAt;capture('点击关联节点');
        w.advanceNavigation(start+110);capture('110ms · 移入中心');
        w.advanceNavigation(start+219);capture('220ms · 展开为半圆');
        w.advanceNavigation(start+220);const expand=w.navigationStartedAt;
        w.advanceNavigation(expand+55);capture('275ms · 新关系向外扩散');
        w.advanceNavigation(expand+140);capture('360ms · 关联节点展开');
        w.advanceNavigation(expand+280);capture('500ms · 完成');return frames;
      });
      const sheet=await browser.newPage({viewport:{width:972,height:662},deviceScaleFactor:1});
      await sheet.setContent('<style>body{background:#211c16;color:#e5dacb;font:14px system-ui;display:grid;grid-template-columns:repeat(3,300px);gap:18px;padding:12px;margin:0}img{width:300px;border-radius:10px}p{margin:0 0 8px}</style>'+frames.map(f=>'<div><p>'+f.label+'</p><img src="'+f.url+'"></div>').join(''));
      await sheet.screenshot({path:path.join(output,'transition.png')});await sheet.close();
    }
    console.log(await page.evaluate(()=>window.result));
    await page.screenshot({path:path.join(output,'preview.png')});
  } finally { await browser.close(); }
})().catch(error=>{console.error(error);process.exitCode=1;});
else console.log(path.join(output,'index.html'));
