import { TentacleApi } from '../service/TentacleApi';
import { WsEvent } from '../model/Types';
import { SubagentTask, SubagentTurn, SubagentWsEvent, taskStatus } from '../model/Management';
import { ActionButton, AppCard, FeedbackBanner, SectionTitle, StatusPill } from '../components/UiKit';

@Component
export struct SubagentsPage {
  @State tasks: SubagentTask[] = [];
  @State selected: SubagentTask | null = null;
  @State turns: SubagentTurn[] = [];
  @State before: number | null = null;
  @State agentsEnabled: boolean = true;
  @State message: string = '';
  @State loading: boolean = false;
  private visible: boolean = false;
  private timer: number = -1;
  private generation: number = 0;
  private detailSeq: number = 0;
  private wsCb: (evt: WsEvent) => void = (evt: WsEvent) => {
    if (!this.visible || evt.type !== 'subagent.updated') { return; }
    const data = evt.data as object as SubagentWsEvent;
    if (data.enabled !== undefined) { this.agentsEnabled = data.enabled; }
    if (Array.isArray(data.tasks)) {
      this.tasks = data.tasks;
    } else {
      this.refresh();
    }
    if (this.selected !== null && (!data.task_id || data.task_id === this.selected.id)) {
      this.detail(this.selected.id);
    }
  };

  aboutToAppear(): void {
    this.visible = true;
    TentacleApi.getInstance().onWsEvent(this.wsCb);
    this.refresh();
  }

  aboutToDisappear(): void {
    this.visible = false; this.generation++; this.detailSeq++;
    TentacleApi.getInstance().offWsEvent(this.wsCb);
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
  }

  private async refresh(): Promise<void> {
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
    const seq = ++this.generation;
    try {
      const result = await TentacleApi.getInstance().getSubagents();
      if (seq !== this.generation || !this.visible) { return; }
      this.tasks = result.tasks; this.agentsEnabled = result.enabled;
      const activeCount = result.tasks.filter((t: SubagentTask) => t.status === 'running' || t.status === 'queued').length;
      AppStorage.setOrCreate('runningSubagents', activeCount);
      this.message = result.execution_blocked ? '执行环境暂不可用，操作由主代理处理' : result.has_more ? '显示最近 20 个任务' : '';
      if (this.selected !== null && !this.loading) { this.detail(this.selected.id); }
    } catch (e) { if (seq === this.generation) { this.message = '状态更新失败：' + (e as Error).message; } }
    finally {
      if (seq === this.generation && this.visible && this.agentsEnabled) {
        const active = this.tasks.some((t: SubagentTask) => t.status === 'running' || t.status === 'queued');
        this.timer = setTimeout(() => this.refresh(), active ? 5000 : 15000);
      }
    }
  }

  private open(task: SubagentTask): void {
    this.selected = task; this.turns = []; this.before = null; this.detail(task.id);
  }

  private askInChat(task: SubagentTask): void {
    AppStorage.setOrCreate('pendingChatPrompt', '请检查子任务 ' + task.id + '（' + task.objective + '）的当前进展。');
  }

  private statusTone(status: string): string {
    if (status === 'completed') { return 'ok'; }
    if (status === 'failed') { return 'danger'; }
    if (status === 'running') { return 'accent'; }
    if (status === 'queued' || status === 'waiting_input') { return 'warn'; }
    return 'default';
  }

  private async detail(id: string, earlier: boolean = false): Promise<void> {
    const seq = ++this.detailSeq;
    this.loading = true;
    try {
      const result = await TentacleApi.getInstance().getSubagent(id, earlier ? this.before : null);
      if (seq !== this.detailSeq || !this.visible || this.selected?.id !== id) { return; }
      this.selected = result.task;
      const retained = this.turns.filter((t: SubagentTurn) => !result.turns.some((n: SubagentTurn) => n.id === t.id));
      const preserveEarlier = !earlier && retained.some((t: SubagentTurn) => t.id < (result.turns[0]?.id ?? 0));
      this.turns = retained.concat(result.turns).sort((a: SubagentTurn, b: SubagentTurn) => a.id - b.id);
      if (!preserveEarlier) { this.before = result.next_before; }
    } catch (e) { if (seq === this.detailSeq) { this.message = '详情读取失败：' + (e as Error).message; } }
    finally { if (seq === this.detailSeq) { this.loading = false; } }
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        if (this.selected !== null) {
          ActionButton({
            label: '‹ 返回列表',
            tone: 'ghost',
            compact: true,
            onTap: () => { this.detailSeq++; this.selected = null; }
          })
        } else {
          StatusPill({ label: this.agentsEnabled ? '实时追踪已启用' : '未启用', tone: this.agentsEnabled ? 'ok' : 'default' })
        }
        Blank()
        ActionButton({
          label: '刷新',
          tone: 'secondary',
          compact: true,
          onTap: () => { this.refresh(); }
        })
      }.width('100%').padding({ left: 14, right: 14, top: 4, bottom: 8 })

      Scroll() {
        Column({ space: 10 }) {
          if (this.message) {
            FeedbackBanner({ text: this.message, tone: 'info' })
          }
          if (!this.agentsEnabled) {
            AppCard() {
              Text('子代理功能当前未启用，可在「系统配置 → 运行与调度」中打开 subagents 开关。')
                .fontSize(12.5).fontColor($r('app.color.tentacle_text_dim'))
            }
          }
          if (this.selected === null) {
            ForEach(this.tasks, (task: SubagentTask) => {
              AppCard() {
                Column({ space: 8 }) {
                  Row({ space: 8 }) {
                    StatusPill({ label: taskStatus(task.status) + (task.archived ? ' · 归档' : ''), tone: this.statusTone(task.status) })
                    Blank()
                    Text(task.id.slice(0, 8)).fontSize(10.5).fontFamily('monospace').fontColor($r('app.color.tentacle_text_faint'))
                  }.width('100%')
                  Text(task.objective).fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.tentacle_text')).width('100%')
                  Text(task.error || task.result || task.progress || '等待进展…')
                    .fontSize(12).lineHeight(18).fontColor($r('app.color.tentacle_text_dim')).maxLines(3)
                    .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                  Row({ space: 8 }) {
                    ActionButton({
                      label: '查看逐轮记录 ›',
                      tone: 'secondary',
                      compact: true,
                      onTap: () => { this.open(task); }
                    })
                    ActionButton({
                      label: '在对话中询问',
                      tone: 'accent',
                      compact: true,
                      onTap: () => { this.askInChat(task); }
                    })
                  }.width('100%')
                }.width('100%').alignItems(HorizontalAlign.Start)
              }
            }, (task: SubagentTask) => task.id)
            if (this.agentsEnabled && !this.tasks.length) {
              Text('暂无子代理任务记录').fontSize(13).fontColor($r('app.color.tentacle_text_faint')).padding(24)
            }
          } else {
            AppCard() {
              Column({ space: 8 }) {
                Row({ space: 8 }) {
                  StatusPill({ label: taskStatus(this.selected.status), tone: this.statusTone(this.selected.status) })
                  Blank()
                  ActionButton({
                    label: '在对话中询问',
                    tone: 'accent',
                    compact: true,
                    onTap: () => { if (this.selected !== null) { this.askInChat(this.selected); } }
                  })
                }.width('100%')
                SectionTitle({ title: this.selected.objective })
                if (this.selected.progress || this.selected.result) {
                  Text(this.selected.progress || this.selected.result || '')
                    .fontSize(13).lineHeight(19).fontColor($r('app.color.tentacle_text')).copyOption(CopyOptions.LocalDevice)
                }
                if (this.selected.background) {
                  Text('背景：' + this.selected.background).fontSize(12).fontColor($r('app.color.tentacle_text_dim'))
                    .padding(10).borderRadius(10).backgroundColor($r('app.color.tentacle_bg_input')).width('100%')
                }
                if (this.selected.cleanup_error) {
                  FeedbackBanner({ text: '执行环境清理异常，等待主代理处理', tone: 'danger' })
                }
              }.width('100%').alignItems(HorizontalAlign.Start)
            }
            if (this.before !== null) {
              Row() {
                ActionButton({
                  label: this.loading ? '加载中…' : '加载更早轮次',
                  tone: 'ghost',
                  compact: true,
                  isEnabled: !this.loading,
                  onTap: () => { this.detail(this.selected?.id ?? '', true); }
                })
              }.width('100%').justifyContent(FlexAlign.Center)
            }
            ForEach(this.turns, (turn: SubagentTurn) => {
              AppCard() {
                Column({ space: 8 }) {
                  Row({ space: 8 }) {
                    Text('轮次 #' + turn.id).fontSize(13).fontFamily('monospace').fontWeight(FontWeight.Medium).fontColor($r('app.color.tentacle_text'))
                    StatusPill({ label: taskStatus(turn.status), tone: this.statusTone(turn.status) })
                    Blank()
                    Text(new Date(turn.created_at * 1000).toLocaleTimeString()).fontSize(10.5).fontColor($r('app.color.tentacle_text_faint'))
                  }.width('100%')
                  Text(turn.message).fontSize(13).lineHeight(19).fontColor($r('app.color.tentacle_text')).copyOption(CopyOptions.LocalDevice)
                  if (turn.result) {
                    Text(turn.result).fontSize(12.5).lineHeight(18).fontFamily('monospace').fontColor($r('app.color.tentacle_text_dim'))
                      .padding(10).borderRadius(10).backgroundColor($r('app.color.tentacle_bg_input')).width('100%')
                      .copyOption(CopyOptions.LocalDevice)
                  }
                  if (turn.error) { FeedbackBanner({ text: turn.error, tone: 'danger' }) }
                  Text('输入 ' + (turn.usage?.prompt_tokens ?? 0) + ' · 输出 ' + (turn.usage?.completion_tokens ?? 0))
                    .fontSize(10.5).fontFamily('monospace').fontColor($r('app.color.tentacle_text_faint'))
                }.width('100%').alignItems(HorizontalAlign.Start)
              }
            }, (turn: SubagentTurn) => turn.id.toString())
          }
        }.width('100%').padding({ left: 14, right: 14, top: 2, bottom: 20 })
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
    }.width('100%').height('100%').backgroundColor($r('app.color.tentacle_bg'))
  }
}
