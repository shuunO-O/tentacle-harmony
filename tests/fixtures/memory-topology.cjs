// Synthetic co-occurrence fixture from Tentacle Web (1d526e9). No accounts or private data.
'use strict';
  function rng(seed){return()=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed/4294967296;};}
  function rewire(edges,random){
    const result=edges.map(e=>({...e})),key=(a,b)=>a<b?`${a}:${b}`:`${b}:${a}`,seen=new Set(result.map(e=>key(e.a,e.b)));
    for(let i=0;i<edges.length*12;i++){
      const u=Math.floor(random()*result.length),v=Math.floor(random()*result.length);if(u===v)continue;
      const x=result[u],y=result[v];const [a,b]=random()<.5?[x.a,x.b]:[x.b,x.a], [c,d]=random()<.5?[y.a,y.b]:[y.b,y.a];
      if(new Set([a,b,c,d]).size!==4||seen.has(key(a,d))||seen.has(key(c,b)))continue;
      seen.delete(key(x.a,x.b));seen.delete(key(y.a,y.b));result[u]={...x,a,b:d};result[v]={...y,a:c,b};seen.add(key(a,d));seen.add(key(c,b));
    }return result;
  }
  function fixture(total,scenario='memory',seed=2419){
    const random=rng(seed),nodes=[],edges=[],pairs=new Set();
    const terms=['摄影','咖啡','代码','森林','音乐','海边','阅读','设计','散步','电影','植物','旅行','学习','画画','雨声','朋友','笔记','计划','早餐','日落','故事','实验','车站','书店','旋律','运动','相遇','睡眠','写作','山路','晚餐','游戏','跑步','花园','考试','相机','工作','周末','健康','灵感'];
    const add=(type,name)=>{const n={id:nodes.length,type,name};nodes.push(n);return n.id;};
    const connect=(a,b,type)=>{if(a===b)return;const key=[a,b].sort((x,y)=>x-y).join(':');if(pairs.has(key))return;pairs.add(key);edges.push({a,b,type});};
    add('Person','共同人物 A');add('Person','共同人物 B');
    const eventCount=Math.floor(total*.41),personCount=Math.max(4,Math.floor(total*.018)),locationCount=Math.max(5,Math.floor(total*.03));
    for(let i=0;i<personCount;i++)add('Person',`朋友 ${i+1}`);
    const places=[];for(let i=0;i<locationCount;i++)places.push(add('Location',['书店','海边','公园','家中','咖啡馆'][i%5]+` ${Math.floor(i/5)+1}`));
    const concepts=[];while(nodes.length<total-eventCount){const i=concepts.length;concepts.push(add('Concept',terms[i%terms.length]+(i<terms.length?'':` · ${Math.floor(i/terms.length)+1}`)));}
    // A history of co-occurrence evolves through reuse and occasional new interests.
    // No hidden community IDs, topic buckets or node coordinates are produced.
    const co=new Map(concepts.map(i=>[i,new Set()]));let recent=[];
    for(let i=0;i<eventCount;i++){
      const revisit=recent.length&&random()<.68;
      const first=revisit?recent[Math.floor(random()*recent.length)]:concepts[Math.floor(random()*concepts.length)];
      const chosen=new Set([first]);const amount=2+Math.floor(random()*3);
      for(let j=0;j<amount;j++){
        const local=[...co.get(first)];const reuse=local.length&&random()<(scenario==='mixed'?.4:.91);
        chosen.add(reuse?local[Math.floor(random()*local.length)]:concepts[Math.floor(random()*concepts.length)]);
      }
      recent=[...chosen];const event=add('Event',`记忆 ${String(i+1).padStart(3,'0')} · ${nodes[first].name.split(' · ')[0]}`);
      for(const a of chosen){connect(event,a,'MENTIONS');for(const b of chosen)if(a!==b)co.get(a).add(b);}
      // Every event has the same protagonist; most also include the companion.
      connect(0,event,'PARTICIPATED_IN');if(random()<.78)connect(1,event,'PARTICIPATED_IN');
      if(random()<.35)connect(2+Math.floor(random()*personCount),event,'PARTICIPATED_IN');
      if(random()<.3)connect(event,places[Math.floor(random()*places.length)],'OCCURRED_AT');
    }
    if(scenario==='mixed')for(let i=0;i<total*.65;i++)connect(Math.floor(random()*total),Math.floor(random()*total),'ASSOCIATED');
    if(scenario==='random'){
      // Same nodes and exactly the same degree sequence, but relationships rewired.
      return {nodes,edges:rewire(edges,random).map(e=>({...e,type:'ASSOCIATED'}))};
    }
    if(scenario==='fragments'){
      const kept=edges.filter(e=>e.a>=2&&e.b>=2&&e.a%17!==0&&e.b%17!==0);
      return {nodes,edges:kept};
    }
    return {nodes,edges};
  }

// Same node/edge counts as the reported screenshot, with entirely fictional content.
// Event/concept co-occurrence is sparse; two people participate across all regions.
function sparseMemoryFixture() {
  const random=rng(6841), nodes=[], edges=[], seen=new Set();
  const add=(type,name)=>{nodes.push({id:nodes.length,type,name});return nodes.length-1;};
  const link=(a,b,type)=>{const key=[a,b].sort((x,y)=>x-y).join(':');if(a===b||seen.has(key))return;seen.add(key);edges.push({a,b,type});};
  const people=Array.from({length:10},(_,i)=>add('Person','虚构人物 '+i));
  const places=Array.from({length:43},(_,i)=>add('Location','虚构地点 '+i));
  const concepts=Array.from({length:1032},(_,i)=>add('Concept','虚构概念 '+i));
  const events=Array.from({length:186},(_,i)=>add('Event','虚构记忆 '+i));
  for(let i=0;i<events.length;i++){
    link(people[0],events[i],'PARTICIPATED_IN');
    if(random()<.78)link(people[1],events[i],'PARTICIPATED_IN');
    if(random()<.4)link(people[2+i%8],events[i],'PARTICIPATED_IN');
  }
  concepts.forEach((id,i)=>link(events[i%186],id,'MENTIONS'));
  places.forEach((id,i)=>link(events[i%186],id,'OCCURRED_AT'));
  while(edges.length<1952){
    const i=Math.floor(random()*concepts.length),start=Math.floor(i%186/16)*16;
    const event=random()<.94?start+Math.floor(random()*Math.min(16,186-start)):Math.floor(random()*186);
    link(events[event],concepts[i],'MENTIONS');
  }
  return {nodes,edges};
}
module.exports = { fixture, sparseMemoryFixture };
