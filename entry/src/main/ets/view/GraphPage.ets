/**
 * 图谱页：Neo4j 知识图谱浏览器
 *
 * 移动端采用半圆轮盘、全量搜索和独立详情页签。
 * - 概览统计（按标签节点数、关系数）
 * - 节点详情：完整属性、入边/出边、点击关联节点跳转
 */

import { TentacleApi } from '../service/TentacleApi';
import { GraphSnapshot } from '../model/GraphSnapshot';
import { GraphScene, graphNodeTitle, graphNodeMatches, graphNodeColor, graphLabelTitle } from '../model/GraphScene';
import { GraphCanvas } from '../components/GraphCanvas';
import { graphPreviewText } from '../model/GraphTextLayout';
import { ActionButton, FeedbackBanner } from '../components/UiKit';
import {
  GraphNode,
  GraphRelationship,
  GraphSummary,
} from '../model/Types';

interface GraphVisit { id: string; index: number; }

@Component
export struct GraphPage {
  // 原始数据
  @State summary: GraphSummary = { nodes: {}, relationships: 0 };
  @State nodes: GraphNode[] = [];

  // 视图状态
  @State activeTab: string = 'graph';
  @State searchText: string = '';
  @State selectedNode: GraphNode | null = null;
  @State activeLabels: Set<string> = new Set(['Event', 'Person', 'Concept', 'Location']);
  @State errText: string = '';
  @State loading: boolean = false;
  @State nodeTotal: number = 0;
  @State searchPage: number = 0;
  @State cacheText: string = '';
  @State snapshotVersion: number = 0;
  @State scene: GraphScene = new GraphScene([], []);
  @State labelFilters: string[] = ['Event', 'Person', 'Concept', 'Location'];
  @State searchMatches: GraphNode[] = [];
  @State detailLimit: number = 40;
  @State centerId: string = '';
  @State wheelIndex: number = 0;
  @State canGoBack: boolean = false;
  @State soundEnabled: boolean = true;
  private browseHistory: GraphVisit[] = [];
  private snapshot: GraphSnapshot | null = null;
  private sequence: number = 0;
  private visible: boolean = false;

  @State allLabels: string[] = ['Event', 'Person', 'Concept', 'Location'];

  aboutToAppear(): void {
    this.visible = true;
    const cached = TentacleApi.getInstance().peekGraph();
    if (cached !== null) { this.applySnapshot(cached); }
    this.load();
  }

  aboutToDisappear(): void { this.visible = false; this.sequence++; }

  private applySnapshot(snapshot: GraphSnapshot): void {
    if (this.snapshot !== snapshot) {
      this.snapshot = snapshot;
      this.summary = snapshot.summary;
      this.nodes = snapshot.nodes;
      const labels = new Set(this.allLabels);
      for (const node of snapshot.nodes) {
        if (!labels.has(node.label)) { labels.add(node.label); this.activeLabels.add(node.label); }
      }
      this.allLabels = Array.from(labels); this.labelFilters = Array.from(this.activeLabels);
      if (this.activeTab === 'graph') { this.rebuildScene(); }
      this.snapshotVersion++;
      if (this.selectedNode !== null) { this.selectedNode = snapshot.findNode(this.selectedNode.id); }
      this.updateFiltered();
    }
    this.cacheText = '快照 ' + new Date(snapshot.updatedAt).toLocaleTimeString();
  }

  private async load(force: boolean = false): Promise<void> {
    const seq = ++this.sequence;
    const api = TentacleApi.getInstance();
    const epoch = api.getCacheEpoch();
    this.loading = true;
    try {
      const saved = await api.restoreGraphCache();
      if (!this.visible || seq !== this.sequence || epoch !== api.getCacheEpoch()) { return; }
      if (saved !== null) { this.applySnapshot(saved); }
      const snapshot = await api.getGraphSnapshot(force);
      if (!this.visible || seq !== this.sequence || epoch !== api.getCacheEpoch()) { return; }
      this.applySnapshot(snapshot);
      this.errText = '';
    } catch (e) {
      if (this.visible && seq === this.sequence && epoch === api.getCacheEpoch()) {
        this.errText = (this.snapshot === null ? '' : '显示上次快照，刷新失败：') + e.message;
      }
    } finally {
      if (this.visible && seq === this.sequence) { this.loading = false; }
    }
  }

  private updateFiltered(reset: boolean = false): void {
    const nodes = this.filteredNodes(); this.nodeTotal = nodes.length;
    if (reset) { this.searchPage = 0; }
    this.searchPage = Math.max(0, Math.min(Math.max(0, Math.ceil(nodes.length / 4) - 1), this.searchPage));
    this.searchMatches = this.searchText.trim() ? nodes.slice(this.searchPage * 4, this.searchPage * 4 + 4) : [];
  }

  private changeSearchPage(delta: number): void {
    this.searchPage += delta; this.updateFiltered();
  }
  private countFor(label: string): number {
    return this.summary.nodes[label] ?? 0;
  }

  private matchesSearch(n: GraphNode, q: string): boolean {
    return graphNodeMatches(n, q);
  }

  private filteredNodes(): GraphNode[] {
    const q = this.searchText.trim().toLowerCase();
    const out: GraphNode[] = [];
    for (let i = 0; i < this.nodes.length; i++) {
      const n = this.nodes[i];
      if (!this.activeLabels.has(n.label)) {
        continue;
      }
      if (q.length > 0 && !this.matchesSearch(n, q)) {
        continue;
      }
      out.push(n);
    }
    return out;
  }

  private findNode(id: string): GraphNode | null {
    return this.snapshot?.findNode(id) ?? null;
  }

  private findNodeName(id: string): string {
    const n = this.findNode(id);
    if (n === null) {
      return id;
    }
    return this.displayName(n);
  }

  private shortEventId(id: string): string {
    if (id.indexOf('Event:') === 0) {
      return id.substring(6);
    }
    return id;
  }

  private displayName(n: GraphNode): string {
    if (n.label === 'Event') {
      return this.shortEventId(n.id);
    }
    return n.name ?? n.id;
  }

  private nodeRelationCount(n: GraphNode): number {
    return this.nodeRelations(n).length;
  }

  private nodeRelations(n: GraphNode): GraphRelationship[] {
    return this.snapshot?.nodeRelations(n.id) ?? [];
  }

  private selectNode(n: GraphNode): void {
    if (this.selectedNode?.id !== n.id) { this.detailLimit = 40; }
    this.selectedNode = this.findNode(n.id) ?? n;

    this.activeTab = 'details';
  }

  private focusNode(n: GraphNode): void {
    this.activeLabels.add(n.label); this.activeLabels = new Set(this.activeLabels);
    this.labelFilters = Array.from(this.activeLabels);
    this.activeTab = 'graph'; this.searchText = ''; this.navigateNode(n); this.updateFiltered(true);
  }

  private rebuildScene(): void {
    if (this.snapshot === null) { return; }
    this.scene = this.snapshot.visualization(this.centerId, this.wheelIndex, this.labelFilters);
    this.centerId = this.scene.centerId; this.wheelIndex = this.scene.wheelIndex;
  }

  private navigateNode(node: GraphNode): void {
    if (this.centerId && this.centerId !== node.id) {
      this.browseHistory.push({ id: this.centerId, index: this.wheelIndex });
      if (this.browseHistory.length > 40) { this.browseHistory.shift(); }
    }
    this.centerId = node.id; this.wheelIndex = 0; this.selectedNode = null;
    this.canGoBack = this.browseHistory.length > 0; this.rebuildScene();
  }

  private browseBack(): void {
    while (this.browseHistory.length) {
      const visit = this.browseHistory.pop()!; const node = this.findNode(visit.id);
      if (node === null || !this.activeLabels.has(node.label)) { continue; }
      this.centerId = visit.id; this.wheelIndex = visit.index; this.selectedNode = null; this.rebuildScene(); break;
    }
    this.canGoBack = this.browseHistory.length > 0;
  }

  private rotateWheel(index: number): void {
    this.wheelIndex = index; this.rebuildScene();
  }
  private tapGraphNode(node: GraphNode): void {
    if (node.id === this.centerId) { this.selectNode(node); } else { this.navigateNode(node); }
  }

  private centerTitle(): string {
    const node = this.findNode(this.centerId); return node === null ? '选择节点开始探索' : graphPreviewText(graphNodeTitle(node));
  }

  private closeDetail(): void {
    this.activeTab = 'graph';
    this.selectedNode = null;
    if (this.activeTab === 'graph') { this.rebuildScene(); }

  }

  private toggleLabel(label: string): void {
    if (this.activeLabels.has(label)) {
      this.activeLabels.delete(label);
    } else {
      this.activeLabels.add(label);
    }
    this.activeLabels = new Set(this.activeLabels);
    this.labelFilters = Array.from(this.activeLabels);
    if (this.selectedNode !== null && !this.activeLabels.has(this.selectedNode.label)) { this.closeDetail(); }
    if (this.activeTab === 'graph') { this.wheelIndex = 0; this.rebuildScene(); }
    this.updateFiltered(true);
  }

  private switchTab(tab: string): void {

    if (tab === 'details' && this.selectedNode === null) { this.selectedNode = this.findNode(this.centerId); }
    this.activeTab = tab;

    if (tab === 'graph') { this.rebuildScene(); }
  }

  private fmtProps(obj: object | undefined): string {
    if (!obj) {
      return '';
    }
    const parts: string[] = [];
    const keys = Object.keys(obj);
    for (let i = 0; i < keys.length; i++) {
      const k = keys[i];
      const v = (obj as Record<string, string>)[k];
      parts.push(k + '=' + v);
    }
    return parts.join(', ');
  }

  private relationDirection(r: GraphRelationship, n: GraphNode): boolean {
    return r.source === n.id;
  }

  private relationOtherId(r: GraphRelationship, n: GraphNode): string {
    if (r.source === n.id) {
      return r.target;
    }
    return r.source;
  }

  private nodeFieldValue(n: GraphNode, key: string): string {
    if (key === 'type') {
      return n.type ?? '';
    }
    if (key === 'summary') {
      return n.summary ?? '';
    }
    if (key === 'content') {
      return n.content ?? '';
    }
    if (key === 'create_time') {
      return n.create_time ?? '';
    }
    return '';
  }

  @Builder
  FilterBar() {
    Column({ space: 10 }) {
      TextInput({ text: this.searchText, placeholder: '搜索记忆、人物或概念…' })
        .height(40).fontSize(13).borderRadius(10)
        .onChange((value: string) => { this.searchText = value; this.updateFiltered(true); })
        .backgroundColor($r('app.color.tentacle_bg_input')).fontColor($r('app.color.tentacle_text')).width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.allLabels, (label: string) => {
          Row({ space: 5 }) {
            Column().width(6).height(6).borderRadius(3).backgroundColor(graphNodeColor(label))
            Text(graphLabelTitle(label) + ' ' + this.countFor(label)).fontSize(11)
              .fontColor(this.activeLabels.has(label) ? $r('app.color.tentacle_text') : $r('app.color.tentacle_text_faint'))
          }.height(30).padding({ left: 9, right: 9 }).borderRadius(8)
            .backgroundColor(this.activeLabels.has(label) ? $r('app.color.tentacle_bg_hover') : Color.Transparent)
            .opacity(this.activeLabels.has(label) ? 1 : 0.5).margin({ right: 5, bottom: 4 }).onClick(() => this.toggleLabel(label))
        }, (label: string) => label)
      }.width('100%')
    }.width('100%').padding({ left: 14, right: 14, top: 10, bottom: 4 })
  }

  @Builder
  TabBar() {
    Row({ space: 4 }) {
      ForEach(['graph', 'details'], (tab: string) => {
        Button(tab === 'graph' ? '关系轮盘' : '节点详情', { type: ButtonType.Normal })
          .fontSize(14).fontColor(this.activeTab === tab ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_text_dim'))
          .backgroundColor(this.activeTab === tab ? $r('app.color.tentacle_accent_soft') : Color.Transparent)
          .borderRadius(9).height(34).layoutWeight(1).onClick(() => this.switchTab(tab))
      }, (tab: string) => tab)
    }.width('100%').padding({ left: 14, right: 14, bottom: 8 })
  }

  @Builder
  GraphSearchResults() {
    if (this.searchText.trim()) {
      Column({ space: 4 }) {
        Row() {
          Text(this.nodeTotal + ' 个匹配节点 · 点击查看关系').fontSize(11).fontColor($r('app.color.tentacle_text_faint')).layoutWeight(1)
          if (this.nodeTotal > 4) {
            Button('‹', { type: ButtonType.Normal }).height(30).width(32).fontSize(16).enabled(this.searchPage > 0)
              .fontColor($r('app.color.tentacle_text')).backgroundColor($r('app.color.tentacle_bg_hover')).borderRadius(8)
              .onClick(() => this.changeSearchPage(-1))
            Text((this.searchPage + 1) + '/' + Math.ceil(this.nodeTotal / 4)).fontSize(12).fontColor($r('app.color.tentacle_text_dim'))
            Button('›', { type: ButtonType.Normal }).height(30).width(32).fontSize(16).enabled((this.searchPage + 1) * 4 < this.nodeTotal)
              .fontColor($r('app.color.tentacle_text')).backgroundColor($r('app.color.tentacle_bg_hover')).borderRadius(8)
              .onClick(() => this.changeSearchPage(1))
          }
        }.width('100%')
        ForEach(this.searchMatches, (node: GraphNode) => {
          Row({ space: 8 }) {
            Column().width(6).height(6).borderRadius(3).backgroundColor(graphNodeColor(node.label))
            Text(this.displayName(node)).fontSize(13).fontColor($r('app.color.tentacle_text')).maxLines(1).layoutWeight(1)
            Text('探索 ›').fontSize(11).fontColor($r('app.color.tentacle_accent'))
          }.width('100%').padding({ top: 5, bottom: 5 }).onClick(() => this.focusNode(node))
        }, (node: GraphNode) => node.id + ':' + this.snapshotVersion)
      }.width('100%').padding({ left: 18, right: 18, bottom: 8 })
    }
  }

  @Builder
  GraphNavigation() {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        if (this.canGoBack) {
          Button('‹ 返回', { type: ButtonType.Normal }).fontSize(12).height(29).borderRadius(8)
            .fontColor($r('app.color.tentacle_text_dim')).backgroundColor($r('app.color.tentacle_bg_hover'))
            .onClick(() => this.browseBack())
        }
        Text(this.centerTitle()).fontSize(13).fontColor($r('app.color.tentacle_text')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        Button('中心详情', { type: ButtonType.Normal }).fontSize(11).height(29).borderRadius(8).enabled(this.centerId.length > 0)
          .fontColor($r('app.color.tentacle_accent')).backgroundColor($r('app.color.tentacle_accent_soft'))
          .onClick(() => { const node = this.findNode(this.centerId); if (node !== null) { this.selectNode(node); } })
      }.width('100%')
      Text('拖动圆弧旋转 · 点小圆切换中心').fontSize(10).fontColor($r('app.color.tentacle_text_faint')).width('100%')
    }.width('100%').padding({ left: 16, right: 16, bottom: 7 })
  }
  @Builder
  NodeDetail() {
    Column({ space: 10 }) {
      Row() {
        Text('节点详情')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.tentacle_text'))
        Blank()
        Button('✕', { type: ButtonType.Normal })
          .fontSize(14)
          .fontColor($r('app.color.tentacle_text_faint'))
          .backgroundColor(Color.Transparent)
          .borderRadius(8)
          .width(32)
          .height(32)
          .onClick(() => {
            this.closeDetail();
          })
      }
      .width('100%')

      if (this.selectedNode !== null) {
        Column({ space: 6 }) {
          Text(this.selectedNode.label)
            .fontSize(12)
            .fontColor($r('app.color.tentacle_accent'))
            .width('100%')
          Text(this.displayName(this.selectedNode))
            .fontSize(17)
            .fontColor($r('app.color.tentacle_text'))
            .fontWeight(FontWeight.Medium)
            .width('100%')
          Text('ID: ' + this.selectedNode.id)
            .fontSize(11)
            .fontColor($r('app.color.tentacle_text_faint'))
            .width('100%')
          Button('探索此节点的关系', { type: ButtonType.Normal }).fontSize(12).height(32).borderRadius(9)
            .fontColor($r('app.color.tentacle_accent')).backgroundColor($r('app.color.tentacle_accent_soft'))
            .onClick(() => { if (this.selectedNode !== null) { this.focusNode(this.selectedNode); } })
        }
        .width('100%')
        .padding(12)
        .backgroundColor($r('app.color.tentacle_bg_input'))
        .borderRadius(10)

        Column({ space: 6 }) {
          Text('属性')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.tentacle_text'))
            .width('100%')

          ForEach(['type', 'summary', 'content', 'create_time'], (key: string, fi: number) => {
            if (this.nodeFieldValue(this.selectedNode!, key).length > 0) {
              Column({ space: 2 }) {
                Text(key)
                  .fontSize(11)
                  .fontColor($r('app.color.tentacle_text_faint'))
                  .width('100%')
                Text(this.nodeFieldValue(this.selectedNode!, key))
                  .fontSize(13)
                  .fontColor($r('app.color.tentacle_text_dim'))
                  .width('100%')
              }
              .width('100%')
              .padding({ top: 4, bottom: 4 })
            }
          }, (key: string, fi: number) => key)
        }
        .width('100%')
        .padding(12)
        .backgroundColor($r('app.color.tentacle_bg_input'))
        .borderRadius(10)

        if (this.nodeRelations(this.selectedNode).length > 0) {
          Column({ space: 6 }) {
            Text('关联（' + this.nodeRelations(this.selectedNode).length.toString() + '）')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.tentacle_text'))
              .width('100%')

            ForEach(this.nodeRelations(this.selectedNode).slice(0, this.detailLimit), (r: GraphRelationship, ri: number) => {
              Column({ space: 2 }) {
                Row() {
                  Text(this.relationDirection(r, this.selectedNode!) ? '→ ' : '← ')
                    .fontSize(12)
                    .fontColor($r('app.color.tentacle_text_faint'))
                  Text(this.findNodeName(this.relationOtherId(r, this.selectedNode!)))
                    .fontSize(13)
                    .fontColor($r('app.color.tentacle_text'))
                    .layoutWeight(1)
                }
                .width('100%')
                .onClick(() => {
                  const other = this.findNode(this.relationOtherId(r, this.selectedNode!));
                  if (other !== null) {
                    this.selectNode(other);
                  }
                })
                Text(r.type)
                  .fontSize(11)
                  .fontColor($r('app.color.tentacle_accent'))
                  .width('100%')
                if (this.fmtProps(r.properties).length > 0) {
                  Text(this.fmtProps(r.properties))
                    .fontSize(11)
                    .fontColor($r('app.color.tentacle_text_dim'))
                    .width('100%')
                }
              }
              .width('100%')
              .padding(10)
              .backgroundColor($r('app.color.tentacle_bg_card'))
              .borderRadius(8)
              .border({ width: 0.5, color: $r('app.color.tentacle_border') })
            }, (r: GraphRelationship, ri: number) => 'rd' + ri.toString() + ':' + this.snapshotVersion.toString() + ':' + this.selectedNode!.id)
            if (this.nodeRelations(this.selectedNode).length > this.detailLimit) {
              Button('加载更多关联', { type: ButtonType.Normal }).fontSize(12).height(32).borderRadius(8)
                .fontColor($r('app.color.tentacle_text_dim')).backgroundColor($r('app.color.tentacle_bg_hover'))
                .onClick(() => this.detailLimit += 40)
            }
          }
          .width('100%')
          .padding(12)
          .backgroundColor($r('app.color.tentacle_bg_input'))
          .borderRadius(10)
        }
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('app.color.tentacle_bg_card'))
    .borderRadius(12)
    .border({ width: 0.5, color: $r('app.color.tentacle_border') })
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Text(this.loading ? (this.snapshot === null ? '正在加载图谱…' : '正在更新快照…') : (this.cacheText || '准备就绪'))
          .fontSize(11.5).fontColor($r('app.color.tentacle_text_dim')).layoutWeight(1)
        ActionButton({
          label: this.loading ? '刷新中…' : '刷新快照',
          tone: 'secondary',
          compact: true,
          isEnabled: !this.loading,
          onTap: () => { this.load(true); }
        })
      }.width('100%').padding({ left: 14, right: 14, top: 4, bottom: 4 })
      if (this.errText) {
        Column() { FeedbackBanner({ text: this.errText, tone: 'danger' }) }.padding({ left: 14, right: 14, bottom: 4 })
      }
      this.FilterBar()
      this.TabBar()
      if (this.activeTab === 'graph') {
        this.GraphSearchResults()
        this.GraphNavigation()
        Column() {
          GraphCanvas({ scene: this.scene, soundEnabled: $soundEnabled,
            onRotate: (index: number) => this.rotateWheel(index),
            onSelect: (node: GraphNode) => this.tapGraphNode(node), onInspect: (node: GraphNode) => this.selectNode(node) })
        }.width('100%').layoutWeight(1).padding({ left: 12, right: 12, bottom: 12 })
        if (this.scene.missingEdges > 0) {
          Text(this.scene.missingEdges + ' 条关系缺少节点端点，未绘制').fontSize(10)
            .fontColor($r('app.color.tentacle_text_faint')).width('100%').padding({ left: 14, bottom: 8 })
        }
      } else {
        Scroll() {
          Column({ space: 12 }) {


            if (this.activeTab === 'details') {
              if (this.selectedNode !== null) { this.NodeDetail() }
              else { Text('选择节点后查看完整详情').fontSize(13).fontColor($r('app.color.tentacle_text_faint')).padding(24) }
            }
          }.width('100%').padding(12)
        }.layoutWeight(1).width('100%').scrollBar(BarState.Auto)
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.tentacle_bg'))

  }
}
