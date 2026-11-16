// Exercise the actual bubble controller while retaining children exactly as ForEach does.
const path = require('node:path');
const assert = require('node:assert/strict');

module.exports = async ({load,root,check,ChatStore,json}) => {
  const {BubbleItem}=load(path.join(root,'components/BubbleItem.ets'));
  const {MarkdownBody}=load(path.join(root,'components/MarkdownBody.ets'));
  const {splitFileMarkers,messagePartKey}=load(path.join(root,'model/FileMarkers.ets'));
  const {parseMarkdown}=load(path.join(root,'model/Markdown.ets'));
  const {Bubble}=load(path.join(root,'model/Types.ets'));
  function mount(bubble) {
    const view=new BubbleItem();view.bubble=bubble;view.aboutToAppear();return {view,children:new Map()};
  }
  function render(component) {
    component.view.syncParts(); // ArkUI @Watch runs on the observed Bubble text update.
    const next=new Map();
    const rendered=component.view.parts.map((part,index)=>{
      const key=messagePartKey(part,index);
      const child=component.children.get(key)??{part,markdown:new MarkdownBody()};
      // A retained itemGenerator is not re-run. The child keeps its original object link.
      next.set(key,child);
      if(child.part.kind==='file') return {kind:'file',text:child.part.text};
      child.markdown.content=child.part.text;child.markdown.updateContent();
      return {kind:'text',blocks:json(child.markdown.blocks)};
    });
    component.children=next;
    const expected=splitFileMarkers(component.view.bubble.text).map(part=>part.kind==='file'
      ?{kind:'file',text:part.text}:{kind:'text',blocks:json(parseMarkdown(part.text))});
    assert.deepEqual(rendered,expected);
  }
  await check('bubble text reaches retained Markdown children at every streaming prefix, including file boundaries',()=>{
    const bubble=new Bubble();const component=mount(bubble);
    const text='# 标题\n\n连续的 **完整内容**，包含表情🦑。\n\n[file:data/files/演示.pdf]\n\n| A | B |\n| --- | --- |\n| 内容 | 结束 |\n\n结尾不能丢失';
    for(let n=1;n<=text.length;n++){bubble.text=text.slice(0,n);render(component);}
    assert.equal(component.view.parts.at(-1).text.endsWith('结尾不能丢失'),true);
  });
  await check('streaming keeps text child identities and an existing attachment card mounted',()=>{
    const bubble=new Bubble();bubble.text='before [file:data/files/demo.pdf] after';const component=mount(bubble);render(component);
    const parts=component.view.parts, before=parts[0], after=parts[2];const card=component.children.get(messagePartKey(parts[1],1));
    card.downloading=true;
    for(const delta of [' 新','的','文字','\n\n最后一段']){bubble.text+=delta;render(component);}
    assert.equal(component.view.parts,parts);assert.equal(component.view.parts[0],before);assert.equal(component.view.parts[2],after);
    assert.equal(component.children.get(messagePartKey(parts[1],1)),card);assert.equal(card.downloading,true);
    assert.equal(after.text,' after 新的文字\n\n最后一段');
  });
  await check('segmented rounds render their complete final text without a history reload',()=>{
    const store=new ChatStore(),components=[];const segments=['第一段 **粗体完整**','附件 [file:data/files/demo.txt] 后面的完整文字'];
    for(let index=0;index<segments.length;index++){
      for(const character of segments[index]){
        store.handleWs({type:'message_delta',data:{text:character,platform:'harmony'}});
        const bubble=store.rows[0].group.bubbles[index];components[index]??=mount(bubble);render(components[index]);
      }
      store.handleWs({type:'message_seg_end',data:{}});render(components[index]);
    }
    store.handleWs({type:'final',data:{}});components.forEach(render);
    assert.deepEqual(json(store.rows[0].group.bubbles.map(b=>b.text)),segments);
    assert.equal(components[1].view.parts.at(-1).text,' 后面的完整文字');
  });
};
