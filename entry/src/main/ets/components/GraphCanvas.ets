import { GraphNode } from '../model/Types';
import { GraphScene, PlacedNode, PlacedEdge, graphNodeTitle, graphNodeColor, graphLabelTitle } from '../model/GraphScene';
import { GraphWheel, WheelGeometry, WheelPoint, WheelTickGate } from '../model/GraphWheel';
import { WheelSound } from '../service/WheelSound';
import { GraphTextLayout } from '../model/GraphTextLayout';

/** A virtual semicircular wheel; only input and finite transitions schedule frames. */
@Component
export struct GraphCanvas {
  @ObjectLink @Watch('sceneChanged') scene: GraphScene;
  @Link soundEnabled: boolean;
  onRotate: (index: number) => void = () => {};
  onSelect: (node: GraphNode) => void = () => {};
  onInspect: (node: GraphNode) => void = () => {};
  @State focusTitle: string = '';
  @State focusPosition: string = '';
  @State soundUnavailable: boolean = false;
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private wheel: GraphWheel = new GraphWheel();
  private ticks: WheelTickGate = new WheelTickGate();
  private sounds: WheelSound = new WheelSound();
  private textLayout: GraphTextLayout = new GraphTextLayout();
  private focusNode: GraphNode | null = null;
  private canvasWidth: number = 0;
  private canvasHeight: number = 0;
  private active: boolean = false;
  private ready: boolean = false;
  private rotating: boolean = false;
  private lastCenter: string = '';
  private publishedIndex: number = -1;
  private frame: number = -1;
  private startX: number = 0;
  private startY: number = 0;
  private lastAngle: number = 0;
  private angularDrag: boolean = true;
  private lastOffset: number = 0;
  private snapTimer: number = -1;
  private snapFrom: number = 0;
  private snapDelta: number = 0;
  private snapFrame: number = 0;
  private snapStartedAt: number = 0;
  // 0 idle, 1 move into the hub, 2 await the new local scene, 3 reveal its neighbors.
  private navigationPhase: number = 0;
  private navigationNode: PlacedNode | null = null;
  private navigationScene: GraphScene | null = null;
  private navigationPoint: WheelPoint = { x: 0, y: 0 };
  private navigationStartedAt: number = 0;
  private navigationProgress: number = 0;

  aboutToAppear(): void { this.active = true; this.sceneChanged(); this.startSound(); }
  aboutToDisappear(): void {
    this.active = false; this.ready = false; this.rotating = false; this.sounds.release();
    this.cancelSnap(); this.cancelNavigation();
    if (this.frame >= 0) { clearTimeout(this.frame); this.frame = -1; }
  }

  private startSound(): void {
    try {
      const host = this.getUIContext().getHostContext();
      if (host !== undefined) {
        this.sounds.start(host.resourceManager).then((ok: boolean) => { if (this.active) { this.soundUnavailable = !ok; } });
      }
    } catch (e) { this.soundUnavailable = true; }
  }

  private sceneChanged(): void {
    if (this.navigationPhase === 2 && this.scene.centerId === this.navigationNode?.raw.id) {
      this.navigationPhase = 3; this.navigationProgress = 0; this.navigationStartedAt = Date.now();
      this.navigationScene = this.scene;
    } else if (this.navigationPhase !== 0 && this.scene !== this.navigationScene) { this.cancelNavigation(); }
    const changed = this.lastCenter !== this.scene.centerId || this.wheel.count !== this.scene.neighborTotal;
    if (changed) { this.cancelSnap(); this.rotating = false; }
    if (changed || !this.rotating) { this.wheel.set(this.scene.neighborTotal, this.scene.wheelIndex); }
    else { this.wheel.set(this.scene.neighborTotal, this.wheel.position); }
    this.lastCenter = this.scene.centerId; this.publishedIndex = this.scene.wheelIndex;
    if (changed) { this.rotating = false; this.ticks.reset(this.wheel.index()); }
    this.updateFocus(); this.requestPaint();
  }

  private updateFocus(): void {
    const node = this.scene.nodes.find((node: PlacedNode) => node.raw.id !== this.scene.centerId && node.wheelIndex === this.wheel.index());
    this.focusNode = node?.raw ?? null;
    this.focusTitle = node === undefined ? '' : graphNodeTitle(node.raw);
    this.focusPosition = this.scene.neighborTotal ? (this.wheel.index() + 1) + ' / ' + this.scene.neighborTotal : '没有直接关联';
  }

  private requestPaint(): void {
    if (!this.active || !this.ready || this.frame >= 0) { return; }
    this.frame = setTimeout(() => {
      this.frame = -1;
      if (this.active && this.ready) {
        this.advanceNavigation(Date.now()); this.paint();
        if (this.navigationPhase !== 0) { this.requestPaint(); }
      }
    }, this.navigationPhase === 0 ? 24 : 16);
  }

  private beginNavigation(node: PlacedNode, point: WheelPoint): void {
    this.cancelSnap(); this.rotating = false;
    this.navigationNode = node; this.navigationScene = this.scene; this.navigationPoint = point;
    this.navigationPhase = 1; this.navigationProgress = 0; this.navigationStartedAt = Date.now(); this.requestPaint();
  }

  private advanceNavigation(now: number): void {
    if (this.navigationPhase === 0) { return; }
    if (this.navigationPhase === 2) {
      // A rejected or stale selection must never leave input locked.
      if (now - this.navigationStartedAt >= 300) { this.cancelNavigation(); }
      return;
    }
    this.navigationProgress = Math.max(0, Math.min(1, (now - this.navigationStartedAt) / (this.navigationPhase === 1 ? 220 : 280)));
    if (this.navigationProgress < 1) { return; }
    if (this.navigationPhase === 3) { this.cancelNavigation(); return; }
    const node = this.navigationNode;
    this.navigationPhase = 2; this.navigationStartedAt = now;
    if (node !== null) { this.onSelect(node.raw); }
  }

  private cancelNavigation(): void {
    this.navigationPhase = 0; this.navigationProgress = 0; this.navigationNode = null; this.navigationScene = null;
  }

  private sceneOpacity(): number {
    return this.navigationPhase === 1 || this.navigationPhase === 2 ? 1 - this.moveProgress() : 1;
  }
  private moveProgress(): number {
    const p = this.navigationProgress; return p * p * (3 - 2 * p);
  }
  private reveal(node: PlacedNode): number {
    if (this.navigationPhase !== 3) { return 1; }
    const delay = Math.min(0.15, Math.abs(node.wheelOffset) * 0.05);
    const p = Math.max(0, Math.min(1, (this.navigationProgress - delay) / (1 - delay)));
    return 1 - Math.pow(1 - p, 3);
  }
  private radius(node: PlacedNode, geometry: WheelGeometry): number {
    return node.raw.id === this.scene.centerId ? geometry.core : 8 + (geometry.nodeRadius - 8) * this.reveal(node);
  }

  private publishRotation(): void {
    const index = this.wheel.index();
    if (index !== this.publishedIndex) {
      this.publishedIndex = index;
      if (this.ticks.crossed(index, Date.now()) && this.soundEnabled) { this.sounds.play(); }
      this.updateFocus(); this.onRotate(index);
    }
    this.requestPaint();
  }

  private panStart(event: GestureEvent): void {
    if (this.navigationPhase !== 0 || !event.fingerList.length || !this.scene.neighborTotal) { return; }
    this.cancelSnap();
    this.rotating = true; const point = event.fingerList[0];
    this.startX = point.localX; this.startY = point.localY;
    const geometry = this.geometry(); this.lastAngle = geometry.angle(this.startX, this.startY); this.lastOffset = 0;
    this.angularDrag = Math.hypot(this.startX - geometry.x, this.startY - geometry.y) > geometry.core * 0.45;
  }

  private pan(event: GestureEvent): void {
    if (!this.rotating) { return; }
    const geometry = this.geometry();
    if (!this.angularDrag) {
      this.wheel.turn((event.offsetX - this.lastOffset) / geometry.core * 0.75); this.lastOffset = event.offsetX;
      this.publishRotation(); return;
    }
    const angle = geometry.angle(this.startX + event.offsetX, this.startY + event.offsetY);
    let delta = angle - this.lastAngle;
    if (delta > Math.PI) { delta -= Math.PI * 2; } else if (delta < -Math.PI) { delta += Math.PI * 2; }
    this.lastAngle = angle; this.wheel.turn(delta); this.publishRotation();
  }

  private panEnd(): void {
    if (!this.rotating) { return; }
    this.snapFrom = this.wheel.position; this.snapDelta = this.wheel.offset(this.wheel.index()); this.snapFrame = 0; this.snapStartedAt = Date.now();
    this.advanceSnap();
  }
  private advanceSnap(): void {
    this.snapTimer = -1;
    if (!this.active) { return; }
    const progress = Math.min(1, Math.max(++this.snapFrame / 8, (Date.now() - this.snapStartedAt) / 120));
    this.wheel.set(this.scene.neighborTotal, this.snapFrom + this.snapDelta * (1 - Math.pow(1 - progress, 3)));
    if (progress >= 1) { this.rotating = false; this.wheel.snap(); }
    else { this.snapTimer = setTimeout(() => this.advanceSnap(), 16); }
    this.publishRotation();
  }
  private cancelSnap(): void { if (this.snapTimer >= 0) { clearTimeout(this.snapTimer); this.snapTimer = -1; } }
  private step(delta: number): void {
    if (this.navigationPhase !== 0) { return; }
    this.cancelSnap(); this.rotating = false;
    this.wheel.set(this.scene.neighborTotal, this.wheel.index() + delta); this.publishRotation();
  }
  private geometry(): WheelGeometry { return new WheelGeometry(this.canvasWidth, this.canvasHeight); }
  private point(node: PlacedNode, geometry: WheelGeometry): WheelPoint {
    if (node.raw.id === this.scene.centerId) { return { x: geometry.x, y: geometry.y }; }
    const target = geometry.point(node.wheelOffset + this.wheel.offset(this.scene.wheelIndex));
    const p = this.reveal(node);
    return { x: geometry.x + (target.x - geometry.x) * p, y: geometry.y + (target.y - geometry.y) * p };
  }

  private tap(event: GestureEvent): void {
    if (this.navigationPhase !== 0 || !event.fingerList.length) { return; }
    const finger = event.fingerList[0]; const geometry = this.geometry();
    for (const node of this.scene.nodes) {
      if (node.raw.id === this.scene.centerId) { continue; }
      const point = this.point(node, geometry);
      if (Math.hypot(point.x - finger.localX, point.y - finger.localY) <= geometry.nodeRadius + 9) {
        if (this.soundEnabled) { this.sounds.play(true); } this.beginNavigation(node, point); return;
      }
    }
    if (Math.hypot(finger.localX - geometry.x, finger.localY - geometry.y) <= geometry.core) {
      const center = this.scene.find(this.scene.centerId); if (center !== null) { this.onInspect(center.raw); }
    }
  }

  private setSoundEnabled(enabled: boolean): void {
    this.soundEnabled = enabled;
    if (enabled && !this.soundUnavailable) { this.sounds.play(); }
  }

  private short(text: string, width: number, font: string = '500 16vp sans-serif'): string {
    return this.textLayout.fit(text, width, font, (value: string) => this.context.measureText(value).width);
  }

  private arrow(x: number, y: number, angle: number): void {
    const ctx = this.context; ctx.beginPath();
    ctx.moveTo(x - Math.cos(angle - 0.5) * 6, y - Math.sin(angle - 0.5) * 6);
    ctx.lineTo(x, y); ctx.lineTo(x - Math.cos(angle + 0.5) * 6, y - Math.sin(angle + 0.5) * 6); ctx.stroke();
  }

  private paintEdge(edge: PlacedEdge, geometry: WheelGeometry): void {
    if (edge.source === edge.target) { return; }
    const ctx = this.context; const a = this.point(edge.source, geometry); const b = this.point(edge.target, geometry);
    const margin = geometry.nodeRadius;
    if (edge.source.raw.id !== this.scene.centerId && (a.x < -margin / 2 || a.x > this.canvasWidth + margin / 2 || a.y < -margin || a.y > this.canvasHeight + margin) ||
      edge.target.raw.id !== this.scene.centerId && (b.x < -margin / 2 || b.x > this.canvasWidth + margin / 2 || b.y < -margin || b.y > this.canvasHeight + margin)) { return; }
    const direct = edge.source.raw.id === this.scene.centerId || edge.target.raw.id === this.scene.centerId;
    const focused = edge.source.raw.id === this.focusNode?.id || edge.target.raw.id === this.focusNode?.id;
    const length = Math.max(1, Math.hypot(b.x - a.x, b.y - a.y)); const dx = (b.x - a.x) / length; const dy = (b.y - a.y) / length;
    const ar = this.radius(edge.source, geometry); const br = this.radius(edge.target, geometry);
    if (length <= ar + br + 12) { return; }
    const alpha = this.sceneOpacity() * Math.min(this.reveal(edge.source), this.reveal(edge.target));
    const ax = a.x + dx * (ar + 6); const ay = a.y + dy * (ar + 6);
    const bx = b.x - dx * (br + 6); const by = b.y - dy * (br + 6);
    ctx.globalAlpha = alpha * (direct ? focused ? 0.95 : 0.5 : 0.18);
    ctx.strokeStyle = direct ? '#D49A7B' : '#998975'; ctx.lineWidth = direct ? focused ? 2 : 1.2 : 0.7;
    ctx.beginPath(); ctx.moveTo(ax, ay); ctx.lineTo(bx, by); ctx.stroke();
    if (edge.forward) { this.arrow(bx, by, Math.atan2(dy, dx)); }
    if (edge.backward) { this.arrow(ax, ay, Math.atan2(-dy, -dx)); }
    if (direct && focused && length - ar - br > 42) {
      ctx.globalAlpha = alpha; ctx.font = '13vp sans-serif'; ctx.textAlign = 'center';
      const title = this.short(edge.title(), 170, '13vp sans-serif');
      const width = this.textLayout.width(title, '13vp sans-serif', (value: string) => ctx.measureText(value).width);
      const x = (ax + bx) / 2; const y = (ay + by) / 2;
      ctx.fillStyle = '#191510'; ctx.fillRect(x - width / 2 - 5, y - 13, width + 10, 21);
      ctx.fillStyle = '#DEC5A8'; ctx.fillText(title, x, y + 2);
    }
    ctx.globalAlpha = 1;
  }

  private paintNode(node: PlacedNode, geometry: WheelGeometry): void {
    const point = this.point(node, geometry); const radius = this.radius(node, geometry);
    if (point.x + radius < 0 || point.x - radius > this.canvasWidth || point.y + radius < 0 || point.y - radius > this.canvasHeight) { return; }
    const ctx = this.context; const focus = node.wheelIndex === this.wheel.index();
    const alpha = this.sceneOpacity() * this.reveal(node);
    ctx.globalAlpha = alpha; ctx.beginPath(); ctx.arc(point.x, point.y, radius, 0, Math.PI * 2);
    ctx.fillStyle = focus ? '#332A21' : '#24201A'; ctx.fill();
    ctx.strokeStyle = graphNodeColor(node.raw.label); ctx.lineWidth = focus ? 2 : 1; ctx.globalAlpha = alpha * (focus ? 1 : 0.65); ctx.stroke();
    ctx.globalAlpha = alpha * Math.max(0, (this.reveal(node) - 0.65) / 0.35);
    // Always fit to the final size: moving radii must not invalidate text caches every frame.
    this.paintNodeText(node, point, geometry.nodeRadius);
    if (focus) {
      ctx.font = '11vp sans-serif'; ctx.fillStyle = '#CBBBA5'; ctx.fillText('点击进入', point.x, point.y + radius + 20);
    }
    ctx.globalAlpha = 1;
  }

  private paintNodeText(node: PlacedNode, point: WheelPoint, radius: number): void {
    const ctx = this.context;
    ctx.textAlign = 'center'; ctx.font = '12vp sans-serif'; ctx.fillStyle = graphNodeColor(node.raw.label);
    ctx.fillText(graphLabelTitle(node.raw.label), point.x, point.y - 18);
    ctx.font = '500 16vp sans-serif'; ctx.fillStyle = '#F0E8DC';
    const title = graphNodeTitle(node.raw); const line = this.short(title, radius * 2 - 16);
    if (line !== title) {
      const first = line.slice(0, -1); ctx.fillText(first, point.x, point.y + 3);
      ctx.fillText(this.short(title.slice(first.length), radius * 2 - 16), point.x, point.y + 25);
    } else { ctx.fillText(line, point.x, point.y + 12); }
  }

  private paintMovingNode(geometry: WheelGeometry): void {
    const node = this.navigationNode; if (node === null) { return; }
    const ctx = this.context; const p = this.moveProgress();
    const x = this.navigationPoint.x + (geometry.x - this.navigationPoint.x) * p;
    const y = this.navigationPoint.y + (geometry.y - this.navigationPoint.y) * p;
    const radius = geometry.nodeRadius + (geometry.core - geometry.nodeRadius) * p;
    ctx.globalAlpha = 1; ctx.beginPath(); ctx.arc(x, y, radius, 0, Math.PI * 2);
    ctx.fillStyle = '#2B241C'; ctx.fill(); ctx.strokeStyle = graphNodeColor(node.raw.label); ctx.lineWidth = 2 - p * 0.5;
    ctx.globalAlpha = 1 - p; ctx.stroke(); ctx.strokeStyle = '#78604C'; ctx.globalAlpha = p; ctx.stroke();
    ctx.globalAlpha = 1 - p;
    this.paintNodeText(node, { x: x, y: y + (45 - radius) * p }, geometry.nodeRadius);
    ctx.globalAlpha = p;
    ctx.textAlign = 'center'; ctx.fillStyle = '#C3AE93'; ctx.font = '12vp sans-serif'; ctx.fillText('当前节点', x, y - radius + 30);
    ctx.fillStyle = '#F0E8DC'; ctx.font = '500 20vp sans-serif';
    ctx.fillText(this.short(graphNodeTitle(node.raw), geometry.core * 1.7, '500 20vp sans-serif'), x, y - radius + 57);
    ctx.globalAlpha = 1;
  }

  private paintCore(geometry: WheelGeometry): void {
    const ctx = this.context; const center = this.scene.find(this.scene.centerId); if (center === null) { return; }
    const top = geometry.y - geometry.core;
    ctx.globalAlpha = this.sceneOpacity(); ctx.beginPath(); ctx.arc(geometry.x, geometry.y, geometry.core, Math.PI, Math.PI * 2);
    ctx.fillStyle = '#2B241C'; ctx.fill(); ctx.strokeStyle = '#78604C'; ctx.lineWidth = 1.5; ctx.stroke();
    ctx.beginPath(); ctx.arc(geometry.x, geometry.y, geometry.core - 8, Math.PI + 0.14, Math.PI * 2 - 0.14);
    ctx.strokeStyle = '#3B3025'; ctx.lineWidth = 1; ctx.stroke();
    ctx.textAlign = 'center'; ctx.fillStyle = '#C3AE93'; ctx.font = '12vp sans-serif'; ctx.fillText('当前节点', geometry.x, top + 30);
    ctx.fillStyle = '#F0E8DC'; ctx.font = '500 20vp sans-serif'; ctx.fillText(this.short(graphNodeTitle(center.raw), geometry.core * 1.7, '500 20vp sans-serif'), geometry.x, top + 57);
    ctx.fillStyle = graphNodeColor(center.raw.label); ctx.font = '13vp sans-serif';
    const self = this.scene.edges.find((edge: PlacedEdge) => edge.source === edge.target && edge.source === center);
    const stats = graphLabelTitle(center.raw.label) + ' · ' + this.scene.neighborTotal + ' 个关联' + (self === undefined ? '' : ' · 自身 ' + self.relations.length);
    ctx.fillText(this.short(stats, geometry.core * 1.8, '13vp sans-serif'), geometry.x, top + 81);
    ctx.globalAlpha = 1;
  }

  private paint(): void {
    if (this.canvasWidth <= 0 || this.canvasHeight <= 0) { return; }
    const ctx = this.context; const geometry = this.geometry();
    ctx.clearRect(0, 0, this.canvasWidth, this.canvasHeight); ctx.fillStyle = '#191510'; ctx.fillRect(0, 0, this.canvasWidth, this.canvasHeight);
    if (!this.scene.nodes.length) { return; }
    ctx.beginPath(); ctx.ellipse(geometry.x, geometry.y, geometry.orbitX, geometry.orbit, 0, Math.PI + 0.12, Math.PI * 2 - 0.12);
    ctx.strokeStyle = '#30291F'; ctx.lineWidth = 1;
    ctx.globalAlpha = 0.8 * this.sceneOpacity() * (this.navigationPhase === 3 ? this.navigationProgress : 1); ctx.stroke(); ctx.globalAlpha = 1;
    for (const edge of this.scene.edges) { this.paintEdge(edge, geometry); }
    for (const node of this.scene.nodes) {
      if (node.raw.id !== this.scene.centerId && !((this.navigationPhase === 1 || this.navigationPhase === 2) && node === this.navigationNode)) { this.paintNode(node, geometry); }
    }
    this.paintCore(geometry);
    ctx.globalAlpha = this.sceneOpacity();
    for (let i = -17; i <= 17; i++) {
      if (Math.abs(i) < 4) { continue; }
      const angle = -Math.PI / 2 + i * 0.08 - this.wheel.position % 1 * 0.08;
      const r = geometry.core - 15; const long = i % 4 === 0 ? 7 : 4;
      ctx.beginPath(); ctx.moveTo(geometry.x + Math.cos(angle) * r, geometry.y + Math.sin(angle) * r);
      ctx.lineTo(geometry.x + Math.cos(angle) * (r - long), geometry.y + Math.sin(angle) * (r - long));
      ctx.strokeStyle = '#6A5440'; ctx.lineWidth = 1; ctx.stroke();
    }
    ctx.globalAlpha = 1;
    if (this.navigationPhase === 1 || this.navigationPhase === 2) { this.paintMovingNode(geometry); }
  }

  @Builder
  WheelButton(label: string, action: () => void) {
    Button(label, { type: ButtonType.Normal }).height(36).constraintSize({ minWidth: 36 }).fontSize(13).borderRadius(8)
      .fontColor($r('app.color.tentacle_text_dim')).backgroundColor($r('app.color.tentacle_bg_hover')).onClick(action)
  }

  build() {
    Column({ space: 0 }) {
      Stack() {
        Canvas(this.context).width('100%').height('100%')
          .onReady(() => { this.textLayout.clear(); this.ready = true; this.requestPaint(); })
          .onAreaChange((oldArea: Area, area: Area) => {
            const width = Number(area.width); const height = Number(area.height);
            if (width !== this.canvasWidth || height !== this.canvasHeight) { this.cancelNavigation(); }
            this.canvasWidth = width; this.canvasHeight = height; this.requestPaint();
          })
          .priorityGesture(GestureGroup(GestureMode.Exclusive,
            PanGesture({ direction: PanDirection.All, fingers: 1, distance: 4 })
              .onActionStart((event: GestureEvent) => this.panStart(event)).onActionUpdate((event: GestureEvent) => this.pan(event))
              .onActionEnd(() => this.panEnd()).onActionCancel(() => this.panEnd()),
            TapGesture().onAction((event: GestureEvent) => this.tap(event))
          ))
        if (!this.scene.nodes.length) {
          Text('暂无可显示的节点').fontSize(13).fontColor($r('app.color.tentacle_text_faint')).hitTestBehavior(HitTestMode.None)
        }
      }.width('100%').layoutWeight(1).clip(true).zIndex(0)
      Column({ space: 7 }) {
        Row({ space: 7 }) {
          Text(this.focusTitle || '搜索节点开始探索').fontSize(15)
            .fontColor($r('app.color.tentacle_text')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        }.width('100%')
        Row({ space: 7 }) {
          this.WheelButton('‹', () => this.step(-1))
          Text(this.focusPosition).fontSize(14).fontColor($r('app.color.tentacle_text_dim'))
          this.WheelButton('›', () => this.step(1))
          Blank()
          Text(this.soundUnavailable ? '音效不可用' : '音效').fontSize(12).fontColor($r('app.color.tentacle_text_dim'))
          Toggle({ type: ToggleType.Switch, isOn: this.soundEnabled }).width(48).height(32)
            .selectedColor($r('app.color.tentacle_accent')).accessibilityText('图谱音效')
            .onChange((enabled: boolean) => this.setSoundEnabled(enabled))
        }.width('100%')
      }.width('100%').padding(10).backgroundColor($r('app.color.tentacle_bg_card')).zIndex(1)
    }.width('100%').height('100%').clip(true).borderRadius(12).border({ width: 0.5, color: $r('app.color.tentacle_border') })
  }
}
