import { TentacleApi } from '../service/TentacleApi';
import { WsEvent } from '../model/Types';
import { DedupStatus, DedupPair, DedupNode, DedupAuditEntry, DedupWsEvent, taskStatus } from '../model/Management';
import { ActionButton, AppCard, FeedbackBanner, SectionTitle, StatusPill } from '../components/UiKit';
import { notifyToast } from '../model/UiToast';

@Component
export struct DedupPage {
  @State mode: string = 'pairs'; // 'pairs' | 'audit'
  @State data: DedupStatus | null = null;
  @State auditEntries: DedupAuditEntry[] = [];
  @State auditActor: string = 'all';
  @State auditOffset: number = 0;
  @State auditTotal: number = 0;
  @State filter: string = 'pending';
  @State pageOffset: number = 0;
  @State topK: string = '5';
  @State maxPairs: string = '200';
  @State message: string = '';
  @State busy: boolean = false;
  private visible: boolean = false;
  private generation: number = 0;
  private timer: number = -1;
  private filters: string[] = ['pending', 'merged', 'independent', 'different', 'all'];
  private wsCb: (evt: WsEvent) => void = (evt: WsEvent) => {
    if (!this.visible || evt.type !== 'dedup.progress') { return; }
    const d = evt.data as object as DedupWsEvent;
    if (d.run !== undefined && this.data !== null) {
      this.data = { run: d.run, counts: d.counts ?? this.data.counts, pairs: this.data.pairs };
    }
    if (this.mode === 'pairs' && d.event && d.event !== 'progress') {
      this.load();
    }
  };

  aboutToAppear(): void {
    this.visible = true;
    TentacleApi.getInstance().onWsEvent(this.wsCb);
    this.load();
  }

  aboutToDisappear(): void {
    this.visible = false; this.generation++;
    TentacleApi.getInstance().offWsEvent(this.wsCb);
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
  }

  private async load(): Promise<void> {
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
    const seq = ++this.generation;
    try {
      if (this.mode === 'audit') {
        const audit = await TentacleApi.getInstance().getDedupAudit(this.auditActor, this.auditOffset);
        if (seq !== this.generation || !this.visible) { return; }
        this.auditEntries = audit.entries ?? [];
        this.auditTotal = audit.total ?? 0;
      } else {
        const result = await TentacleApi.getInstance().getDedup(this.filter, this.pageOffset);
        if (seq !== this.generation || !this.visible) { return; }
        this.data = result;
        AppStorage.setOrCreate('dedupRunning', result.run?.status === 'running');
        if (result.run?.status === 'running') { this.timer = setTimeout(() => this.load(), 3000); }
      }
    } catch (e) { if (seq === this.generation) { this.message = (e as Error).message; } }
  }

  private start(): void {
    const top = Number(this.topK); const max = Number(this.maxPairs);
    if (!Number.isInteger(top) || top < 1 || top > 20 || !Number.isInteger(max) || max < 1 || max > 1000) {
      this.message = '候选数需在 1～20、本轮配对上限需在 1～1000 之间'; return;
    }
    AlertDialog.show({
      message: '扫描会自动合并高置信同义概念，并将概念名称和少量记忆摘要发送给模型评估。确认开始？',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '开始扫描', action: () => this.run('start', '', '', '', top, max) }
    });
  }

  private async run(action: string, id: string = '', keep: string = '', policy: string = '', top: number = 5, max: number = 200): Promise<void> {
    if (this.busy) { return; }
    this.busy = true; this.message = ''; this.generation++;
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
    try {
      const api = TentacleApi.getInstance();
      if (action === 'start') { await api.startDedup(top, max); this.pageOffset = 0; notifyToast('已启动扫描', 'ok'); }
      else if (action === 'cancel') { await api.cancelDedup(); notifyToast('已请求停止扫描', 'info'); }
      else { await api.decideDedup(id, action, keep, policy); notifyToast('操作已提交', 'ok'); }
      await this.load();
    } catch (e) { this.message = (e as Error).message; }
    finally { this.busy = false; }
  }

  private decide(id: string, action: string, keep: string, policy: string): void {
    if (action !== 'merge') { this.run(action, id, keep, policy); return; }
    AlertDialog.show({
      message: '确认合并到所选节点？相关关系会迁移，后端保留原节点记录与快照。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '合并', action: () => this.run(action, id, keep, policy) }
    });
  }

  private stateCount(f: string): number {
    if (this.data === null) { return 0; }
    if (f === 'all') {
      let sum = 0;
      for (const k of Object.keys(this.data.counts)) { sum += this.data.counts[k] ?? 0; }
      return sum;
    }
    return this.data.counts[f] ?? 0;
  }

  build() {
    Column() {
      Row({ space: 6 }) {
        Row({ space: 4 }) {
          ActionButton({
            label: '候选配对',
            tone: this.mode === 'pairs' ? 'primary' : 'secondary',
            compact: true,
            onTap: () => { this.mode = 'pairs'; this.load(); }
          })
          ActionButton({
            label: '审计日志',
            tone: this.mode === 'audit' ? 'primary' : 'secondary',
            compact: true,
            onTap: () => { this.mode = 'audit'; this.load(); }
          })
        }.layoutWeight(1)
        ActionButton({
          label: '刷新',
          tone: 'secondary',
          compact: true,
          isEnabled: !this.busy,
          onTap: () => { this.load(); }
        })
      }.width('100%').padding({ left: 14, right: 14, top: 4, bottom: 8 })

      Scroll() {
        Column({ space: 12 }) {
          if (this.message) {
            FeedbackBanner({ text: this.message, tone: 'info' })
          }

          if (this.mode === 'pairs') {
            AppCard() {
              Column({ space: 10 }) {
                Text('高置信同义概念自动合并，不确定或冲突项由人工裁决').fontSize(12).fontColor($r('app.color.tentacle_text_dim'))
                Row({ space: 8 }) {
                  Column({ space: 4 }) {
                    Text('Top-K (1~20)').fontSize(11).fontColor($r('app.color.tentacle_text_faint'))
                    TextInput({ text: this.topK, placeholder: '5' })
                      .height(36).fontSize(13).fontColor($r('app.color.tentacle_text'))
                      .backgroundColor($r('app.color.tentacle_bg_input'))
                      .border({ width: 0.5, color: $r('app.color.tentacle_border') }).borderRadius(9)
                      .onChange((v: string) => this.topK = v)
                  }.layoutWeight(1).alignItems(HorizontalAlign.Start)

                  Column({ space: 4 }) {
                    Text('最大配对数 (1~1000)').fontSize(11).fontColor($r('app.color.tentacle_text_faint'))
                    TextInput({ text: this.maxPairs, placeholder: '200' })
                      .height(36).fontSize(13).fontColor($r('app.color.tentacle_text'))
                      .backgroundColor($r('app.color.tentacle_bg_input'))
                      .border({ width: 0.5, color: $r('app.color.tentacle_border') }).borderRadius(9)
                      .onChange((v: string) => this.maxPairs = v)
                  }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                }.width('100%')

                Row({ space: 8 }) {
                  if (this.data?.run?.status === 'running') {
                    ActionButton({
                      label: '停止扫描',
                      tone: 'danger',
                      compact: true,
                      isEnabled: !this.busy,
                      onTap: () => { this.run('cancel'); }
                    })
                  } else {
                    ActionButton({
                      label: '启动扫描并合并',
                      tone: 'primary',
                      compact: true,
                      isEnabled: !this.busy,
                      onTap: () => { this.start(); }
                    })
                  }
                  if (this.data?.run) {
                    StatusPill({
                      label: taskStatus(this.data.run.status) + ' · ' + this.data.run.checked.toString() + ' 对',
                      tone: this.data.run.status === 'running' ? 'warn' : 'default'
                    })
                  }
                }.width('100%')

                if (this.data?.run?.message) {
                  Text(this.data.run.message).fontSize(11.5).fontColor($r('app.color.tentacle_text_dim')).width('100%')
                }
              }.width('100%')
            }

            // 横向状态筛选胶囊
            Scroll() {
              Row({ space: 6 }) {
                ForEach(this.filters, (f: string) => {
                  Text((f === 'all' ? '全部' : taskStatus(f)) + ' ' + this.stateCount(f).toString())
                    .fontSize(11.5)
                    .fontColor(this.filter === f ? '#FFFFFF' : $r('app.color.tentacle_text_dim'))
                    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                    .borderRadius(999)
                    .backgroundColor(this.filter === f ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_bg_card'))
                    .border({ width: 0.5, color: this.filter === f ? Color.Transparent : $r('app.color.tentacle_border') })
                    .onClick(() => { this.filter = f; this.pageOffset = 0; this.load(); })
                }, (f: string) => f)
              }.padding({ bottom: 2 })
            }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')

            if ((this.data?.pairs.length ?? 0) === 0) {
              AppCard() {
                Text('当前筛选下暂无候选概念配对').fontSize(12.5).fontColor($r('app.color.tentacle_text_faint'))
              }
            } else {
              ForEach(this.data?.pairs ?? [], (pair: DedupPair) => {
                DedupPairCard({ pair: pair, busy: this.busy,
                  onAction: (id: string, action: string, keep: string, policy: string) => this.decide(id, action, keep, policy) })
              }, (pair: DedupPair) => pair.id)
            }

            Row({ space: 10 }) {
              ActionButton({
                label: '上一页',
                tone: 'secondary',
                compact: true,
                isEnabled: !this.busy && this.pageOffset > 0,
                onTap: () => { this.pageOffset = Math.max(0, this.pageOffset - 30); this.load(); }
              })
              Text('第 ' + (Math.floor(this.pageOffset / 30) + 1) + ' 页').fontSize(12).fontColor($r('app.color.tentacle_text_dim'))
              ActionButton({
                label: '下一页',
                tone: 'secondary',
                compact: true,
                isEnabled: !this.busy && (this.data?.pairs.length ?? 0) === 30,
                onTap: () => { this.pageOffset += 30; this.load(); }
              })
            }.width('100%').justifyContent(FlexAlign.Center)
          } else {
            // Audit Log Mode
            Row({ space: 6 }) {
              ForEach([['all', '全部'], ['manual', '人工裁决'], ['automatic', '自动扫描']], (item: string[]) => {
                Text(item[1])
                  .fontSize(11.5)
                  .fontColor(this.auditActor === item[0] ? '#FFFFFF' : $r('app.color.tentacle_text_dim'))
                  .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                  .borderRadius(999)
                  .backgroundColor(this.auditActor === item[0] ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_bg_card'))
                  .border({ width: 0.5, color: this.auditActor === item[0] ? Color.Transparent : $r('app.color.tentacle_border') })
                  .onClick(() => { this.auditActor = item[0]; this.auditOffset = 0; this.load(); })
              }, (item: string[]) => item[0])
            }.width('100%')

            if (this.auditEntries.length === 0) {
              AppCard() {
                Text('暂无审计日志记录').fontSize(12.5).fontColor($r('app.color.tentacle_text_faint'))
              }
            } else {
              ForEach(this.auditEntries, (entry: DedupAuditEntry) => {
                AppCard() {
                  Column({ space: 4 }) {
                    Row({ space: 6 }) {
                      StatusPill({ label: entry.actor, tone: entry.actor === 'manual' ? 'accent' : 'default' })
                      Text(entry.action).fontSize(12.5).fontFamily('monospace').fontColor($r('app.color.tentacle_text')).layoutWeight(1)
                      if (entry.status) { StatusPill({ label: entry.status }) }
                    }.width('100%')
                    if (entry.reference) {
                      Text('目标：' + entry.reference).fontSize(11).fontFamily('monospace').fontColor($r('app.color.tentacle_text_dim'))
                    }
                    if (entry.created) {
                      Text(new Date(entry.created * 1000).toLocaleString()).fontSize(10.5).fontColor($r('app.color.tentacle_text_faint'))
                    }
                  }.width('100%').alignItems(HorizontalAlign.Start)
                }
              }, (entry: DedupAuditEntry) => entry.id)
            }
          }
        }.width('100%').padding({ left: 14, right: 14, top: 2, bottom: 20 })
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
    }.width('100%').height('100%').backgroundColor($r('app.color.tentacle_bg'))
  }
}

@Component
struct DedupPairCard {
  @Prop pair: DedupPair;
  @Prop busy: boolean = false;
  @State keep: string = '';
  @State policy: string = 'reject';
  onAction: (id: string, action: string, keep: string, policy: string) => void = () => {};

  aboutToAppear(): void {
    this.keep = this.pair.choice?.keep_id ?? this.pair.data.preview.left.id;
    this.policy = this.pair.choice?.policy ?? 'reject';
  }

  private sameProbText(): string {
    const p = this.pair.data.score?.probabilities?.['2'];
    return p !== undefined ? '同义 ' + (p * 100).toFixed(1) + '%' : '';
  }

  @Builder
  Evidence(tag: string, node: DedupNode) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        StatusPill({ label: tag, tone: 'accent' })
        Text(node.name).fontSize(13.5).fontWeight(FontWeight.Medium).fontColor($r('app.color.tentacle_text')).layoutWeight(1)
      }.width('100%')
      Text(node.id).fontSize(10.5).fontFamily('monospace').fontColor($r('app.color.tentacle_text_faint'))
      if (node.aliases?.length) { Text('别名：' + node.aliases.join('、')).fontSize(11.5).fontColor($r('app.color.tentacle_text_dim')) }
      if (node.first_context) { Text(node.first_context).fontSize(11.5).fontColor($r('app.color.tentacle_text_dim')) }
      ForEach(node.events ?? [], (event: string) => { Text('· ' + event).fontSize(11.5).fontColor($r('app.color.tentacle_text_dim')) },
        (event: string, i: number) => i.toString() + event)
    }.width('100%').padding(10).borderRadius(10).backgroundColor($r('app.color.tentacle_bg_input')).alignItems(HorizontalAlign.Start)
  }

  build() {
    AppCard() {
      Column({ space: 10 }) {
        Row({ space: 6 }) {
          StatusPill({
            label: taskStatus(this.pair.state) + (this.pair.data.automatic ? ' · 自动' : ''),
            tone: this.pair.state === 'merged' ? 'ok' : this.pair.state === 'pending' ? 'warn' : 'default'
          })
          if (this.sameProbText().length > 0) {
            StatusPill({ label: this.sameProbText(), tone: 'ok' })
          }
          Blank()
          Text(this.pair.id).fontSize(10).fontFamily('monospace').fontColor($r('app.color.tentacle_text_faint'))
        }.width('100%')

        if (this.pair.data.reason || this.pair.data.error_code) {
          Text(this.pair.data.reason + (this.pair.data.error_code ? ' · ' + this.pair.data.error_code : ''))
            .fontSize(11.5).fontColor($r('app.color.tentacle_text_dim')).width('100%')
        }

        this.Evidence('概念 A', this.pair.data.preview.left)
        this.Evidence('概念 B', this.pair.data.preview.right)

        if (this.pair.data.preview.conflicts?.length) {
          FeedbackBanner({ text: '关系属性冲突：' + JSON.stringify(this.pair.data.preview.conflicts), tone: 'info' })
        }

        if (this.pair.state === 'pending' || this.pair.state === 'different') {
          Row({ space: 8 }) {
            ActionButton({
              label: '保留 A 并合并',
              tone: 'primary',
              compact: true,
              isEnabled: !this.busy && !this.pair.operation,
              onTap: () => { this.onAction(this.pair.id, 'merge', this.pair.data.preview.left.id, this.policy); }
            })
            ActionButton({
              label: '保留 B 并合并',
              tone: 'primary',
              compact: true,
              isEnabled: !this.busy && !this.pair.operation,
              onTap: () => { this.onAction(this.pair.id, 'merge', this.pair.data.preview.right.id, this.policy); }
            })
          }.width('100%')

          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            Row() {
              ActionButton({
                label: '标为独立',
                tone: 'secondary',
                compact: true,
                isEnabled: !this.busy && !this.pair.operation,
                onTap: () => { this.onAction(this.pair.id, 'independent', this.keep, this.policy); }
              })
            }.margin({ right: 8, bottom: 4 })
            Row() {
              ActionButton({
                label: '刷新证据',
                tone: 'ghost',
                compact: true,
                isEnabled: !this.busy && !this.pair.operation,
                onTap: () => { this.onAction(this.pair.id, 'refresh', this.keep, this.policy); }
              })
            }.margin({ right: 8, bottom: 4 })
            Row() {
              ActionButton({
                label: '重评',
                tone: 'ghost',
                compact: true,
                isEnabled: !this.busy && !this.pair.operation,
                onTap: () => { this.onAction(this.pair.id, 'reevaluate', this.keep, this.policy); }
              })
            }.margin({ bottom: 4 })
          }.width('100%')
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
    }
  }
}
