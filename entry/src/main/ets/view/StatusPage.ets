/**
 * 运行状态与主机维护页：核心指标 / 主机更新维护 / 会话与累计用量 / 数据库统计
 *
 * 与 Web StatusPanel 对齐：
 * - 接入 GET/POST /api/maintenance（检查更新 / 应用在线更新 / 请求宿主重启）
 * - 订阅 WS status.snapshot 与 maintenance.updated 实时推进
 * - 保留 subconscious 等字段兼容解析与安全空态处理
 */

import { TentacleApi } from '../service/TentacleApi';
import { WsEvent, StatusData } from '../model/Types';
import { MaintenanceStatus, MaintenanceOperation } from '../model/Management';
import { Meter } from '../components/Meters';
import { StatRow } from '../components/StatRow';
import { ActionButton, AppCard, FeedbackBanner, SectionTitle, StatusPill } from '../components/UiKit';
import { notifyToast } from '../model/UiToast';

@Component
export struct StatusPage {
  @State bond: number = 0;
  @State emotion: number = 0;
  @State miss: number = 0;
  @State drift: number = 0;
  @State lastUpdate: string = '-';
  @State sessionId: string = '-';
  @State sessionStart: string = '-';
  @State accTokens: number = 0;
  @State connections: number = 0;
  @State hbInterval: string = '-';
  @State nextBeat: string = '-';
  @State dbRaw: number = 0;
  @State dbSessions: number = 0;
  @State dbSummaries: number = 0;
  @State dbGoals: number = 0;
  @State dbTasks: number = 0;
  @State dbFiles: number = 0;
  @State dbUsage: number = 0;
  @State hitRateText: string = '-';
  @State hitDetail: string = '';
  @State totPrompt: number = 0;
  @State totCompletion: number = 0;
  @State totTotal: number = 0;
  @State totCached: number = 0;
  @State snapshotTime: string = '-';
  @State maintenance: MaintenanceStatus | null = null;
  @State maintBusyAction: string = '';
  @State maintNotice: string = '';
  @State loading: boolean = false;
  @State errText: string = '';
  private visible: boolean = false;
  private timer: number = -1;
  private generation: number = 0;
  private wsCb: (evt: WsEvent) => void = (evt: WsEvent) => {
    if (!this.visible) { return; }
    if (evt.type === 'status.snapshot') {
      this.applyStatus(evt.data as object as StatusData);
    } else if (evt.type === 'maintenance.updated') {
      this.mergeMaintenance(evt.data as object as MaintenanceStatus);
    }
  };

  aboutToAppear(): void {
    this.visible = true;
    TentacleApi.getInstance().onWsEvent(this.wsCb);
    this.load();
    this.timer = setInterval(() => {
      this.load();
    }, 30000);
  }

  aboutToDisappear(): void {
    this.visible = false;
    this.generation++;
    TentacleApi.getInstance().offWsEvent(this.wsCb);
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private fmtTime(ts: number): string {
    if (!Number.isFinite(ts) || ts <= 0) {
      return '-';
    }
    const d = new Date(ts * 1000);
    const p = (n: number): string => n.toString().padStart(2, '0');
    return p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
  }

  private fmtNum(n: number): string {
    return Math.round(n).toLocaleString();
  }

  private hasSubconscious(): boolean {
    return this.lastUpdate !== '-' || this.bond > 0 || this.emotion > 0 || this.miss > 0 || this.drift > 0;
  }

  private opBusy(): boolean {
    const state = this.maintenance?.operation?.state ?? '';
    return state === 'waiting' || state === 'submitting' || state === 'running';
  }

  private versionBadge(): string {
    const v = this.maintenance?.version?.version ?? '';
    if (!v) { return ''; }
    return v.startsWith('v') ? v : 'v' + v;
  }

  private mergeMaintenance(patch: MaintenanceStatus): void {
    const prev = this.maintenance;
    const merged: MaintenanceStatus = {
      available: patch.available !== undefined ? patch.available : prev?.available,
      can_update: patch.can_update !== undefined ? patch.can_update : prev?.can_update,
      web_allowed: patch.web_allowed !== undefined ? patch.web_allowed : prev?.web_allowed,
      version: patch.version !== undefined ? patch.version : prev?.version,
      check: patch.check !== undefined ? patch.check : prev?.check,
      operation: patch.operation !== undefined ? patch.operation : prev?.operation,
    };
    this.maintenance = merged;
    if (merged.can_update !== undefined) {
      AppStorage.setOrCreate('updateAvailable', Boolean(merged.can_update));
    }
  }

  private applyStatus(d: StatusData): void {
    this.bond = d.subconscious?.bond_level ?? 0;
    this.emotion = d.subconscious?.emotion_score ?? 0;
    this.miss = d.subconscious?.miss_degree ?? 0;
    this.drift = d.subconscious?.drift_level ?? 0;
    this.lastUpdate = this.fmtTime(d.subconscious?.last_update_time ?? 0);
    if (d.session !== null && d.session !== undefined) {
      this.sessionId = d.session.session_id;
      this.sessionStart = this.fmtTime(d.session.start_time);
    } else {
      this.sessionId = '-';
      this.sessionStart = '-';
    }
    this.accTokens = d.tokens?.accumulated ?? 0;
    this.connections = d.connections ?? 0;
    this.snapshotTime = this.fmtTime(d.time ?? 0);
    if (d.heartbeat?.interval_seconds && d.heartbeat.interval_seconds > 0) {
      const sec = d.heartbeat.interval_seconds;
      this.hbInterval = sec >= 60 ? Math.round(sec / 60).toString() + ' 分钟' : sec.toString() + ' 秒';
    } else {
      this.hbInterval = '未配置';
    }
    if (d.heartbeat?.next_beat_at && d.heartbeat.next_beat_at > 0) {
      const remain = Math.max(0, Math.round(d.heartbeat.next_beat_at - (d.time ?? 0)));
      this.nextBeat = Math.floor(remain / 60).toString() + ' 分 ' + (remain % 60).toString() + ' 秒后';
    } else {
      this.nextBeat = '-';
    }
    this.dbRaw = d.db?.raw_messages ?? 0;
    this.dbSessions = d.db?.sessions ?? 0;
    this.dbSummaries = d.db?.summaries ?? 0;
    this.dbGoals = d.db?.goals ?? 0;
    this.dbTasks = d.db?.tasks ?? 0;
    this.dbFiles = d.db?.files ?? 0;
    this.dbUsage = d.db?.usage_logs ?? 0;
    const u = d.usage;
    if (u !== null && u !== undefined) {
      if (u.last !== null && u.last !== undefined) {
        this.hitRateText = u.last.cache_hit_rate !== null ? u.last.cache_hit_rate.toFixed(1) + '%' : '-';
        this.hitDetail = u.last.cached_tokens.toString() + ' / ' + u.last.prompt_tokens.toString() + ' 输入';
      } else {
        this.hitRateText = '-';
        this.hitDetail = '';
      }
      this.totPrompt = u.total?.prompt_tokens ?? 0;
      this.totCompletion = u.total?.completion_tokens ?? 0;
      this.totTotal = u.total?.total_tokens ?? 0;
      this.totCached = u.total?.cached_tokens ?? 0;
    } else {
      this.hitRateText = '-'; this.hitDetail = '';
      this.totPrompt = 0; this.totCompletion = 0; this.totTotal = 0; this.totCached = 0;
    }
  }

  private async load(): Promise<void> {
    const seq = ++this.generation;
    this.loading = true;
    const api = TentacleApi.getInstance();
    try {
      const d = await api.getStatus();
      if (seq !== this.generation) { return; }
      this.applyStatus(d);
      this.errText = '';
    } catch (e) {
      if (seq === this.generation) { this.errText = (e as Error).message; }
    } finally {
      if (seq === this.generation) { this.loading = false; }
    }
    try {
      const m = await api.getMaintenance();
      if (seq !== this.generation) { return; }
      if (m.available !== undefined || m.version !== undefined || m.check !== undefined) {
        this.maintenance = m;
        AppStorage.setOrCreate('updateAvailable', Boolean(m.can_update));
      }
    } catch (_) {
      // 后端未开启或兼容模式无维护接口时不阻塞状态查看
    }
  }

  private async pollOperation(operationId: string): Promise<void> {
    const seq = this.generation;
    const api = TentacleApi.getInstance();
    for (let i = 0; i < 60; i++) {
      if (seq !== this.generation || !this.visible) { return; }
      try {
        const snap = await api.getMaintenance(operationId);
        if (seq !== this.generation) { return; }
        this.maintenance = snap;
        this.maintNotice = '';
        const state = snap.operation?.state ?? '';
        if (state && !['waiting', 'submitting', 'running'].includes(state)) {
          return;
        }
      } catch (_) {
        if (seq === this.generation) {
          this.maintNotice = '连接暂时断开，正在等待服务恢复…';
        }
      }
      await new Promise<void>((resolve) => {
        setTimeout(() => resolve(), 800);
      });
    }
  }

  async runMaintenance(action: string): Promise<void> {
    if (this.maintBusyAction.length > 0 || this.opBusy()) { return; }
    this.maintBusyAction = action;
    this.maintNotice = '';
    const api = TentacleApi.getInstance();
    try {
      let revision = '';
      if (action === 'restart') {
        const cfg = await api.getConfiguration();
        revision = cfg.revision;
      }
      const ver = action === 'update' ? (this.maintenance?.check?.latest ?? '') : '';
      const op: MaintenanceOperation = await api.postMaintenance(action, ver, revision);
      notifyToast('已提交维护指令：' + action, 'ok');
      if (op.id) {
        await this.pollOperation(op.id);
      } else {
        await this.load();
      }
    } catch (e) {
      this.maintNotice = (e as Error).message;
      notifyToast((e as Error).message, 'danger');
    } finally {
      this.maintBusyAction = '';
    }
  }

  private confirmMaintenance(action: string): void {
    if (action === 'check') {
      this.runMaintenance('check');
      return;
    }
    const msg = action === 'restart'
      ? '确定请求宿主重启服务？当前进行中的对话完成后将短暂断开。'
      : '确定升级到版本 ' + (this.maintenance?.check?.latest ?? '') + ' 并重启服务？';
    AlertDialog.show({
      message: msg,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: action === 'restart' ? '重启' : '应用更新',
        action: () => { this.runMaintenance(action); }
      }
    });
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Text('实时服务与宿主状态')
          .fontSize(12)
          .fontColor($r('app.color.tentacle_text_dim'))
          .layoutWeight(1)
        ActionButton({
          label: this.loading ? '刷新中…' : '刷新',
          tone: 'secondary',
          compact: true,
          isEnabled: !this.loading,
          onTap: () => { this.load(); }
        })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 4, bottom: 8 })

      Scroll() {
        Column({ space: 12 }) {
          if (this.errText.length > 0) {
            FeedbackBanner({ text: this.errText, tone: 'danger' })
          }

          // Web 对齐：核心指标 2x2 瓷砖（使用 @Component @Prop 保证异步刷新实时响应）
          Row({ space: 10 }) {
            StatusKpiTile({ label: '活跃 WebSocket', val: this.connections.toString(), sub: '实时连接通道', tone: 'accent' })
            StatusKpiTile({ label: '上下文累积 Token', val: this.fmtNum(this.accTokens), sub: '当前对话窗口' })
          }.width('100%')

          Row({ space: 10 }) {
            StatusKpiTile({ label: '最近缓存命中率', val: this.hitRateText, sub: this.hitDetail || '暂无样本', tone: 'ok' })
            StatusKpiTile({ label: '下次心跳触发', val: this.nextBeat, sub: '间隔 ' + this.hbInterval })
          }.width('100%')

          // Web 对齐：主机维护与版本更新 (/api/maintenance)
          AppCard() {
            Column({ space: 10 }) {
              Row({ space: 8 }) {
                SectionTitle({ title: '主机维护与版本更新' })
                Blank()
                if (this.versionBadge().length > 0) {
                  StatusPill({ label: this.versionBadge(), tone: 'default' })
                }
              }.width('100%')

              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
                Row() {
                  StatusPill({
                    label: this.maintenance?.available ? '维护控制器就绪' : '未装配主机守护',
                    tone: this.maintenance?.available ? 'ok' : 'default'
                  })
                }.margin({ right: 6, bottom: 4 })
                if (this.maintenance?.can_update) {
                  Row() {
                    StatusPill({ label: '可在线升级', tone: 'accent' })
                  }.margin({ right: 6, bottom: 4 })
                }
              }.width('100%')

              if (this.maintenance?.check) {
                Column({ space: 4 }) {
                  Row({ space: 10 }) {
                    Text('当前：' + (this.maintenance.check.current || this.versionBadge() || '—'))
                      .fontSize(12).fontColor($r('app.color.tentacle_text'))
                    if (this.maintenance.check.latest) {
                      Text('最新：' + this.maintenance.check.latest)
                        .fontSize(12).fontFamily('monospace').fontColor($r('app.color.tentacle_accent'))
                    }
                  }.width('100%')
                  if (this.maintenance.check.message) {
                    Text(this.maintenance.check.message)
                      .fontSize(11.5).fontColor($r('app.color.tentacle_text_dim')).width('100%')
                  }
                }
                .width('100%')
                .padding(10)
                .backgroundColor($r('app.color.tentacle_bg_input'))
                .borderRadius(10)
              }

              if (this.maintenance?.operation || this.maintNotice.length > 0) {
                Column({ space: 4 }) {
                  if (this.maintNotice.length > 0) {
                    Text(this.maintNotice).fontSize(12).fontColor($r('app.color.tentacle_danger')).width('100%')
                  } else if (this.maintenance?.operation) {
                    Row({ space: 8 }) {
                      Text('最近操作：' + (this.maintenance.operation.action || '') +
                        (this.maintenance.operation.version ? ' ' + this.maintenance.operation.version : ''))
                        .fontSize(12).fontColor($r('app.color.tentacle_text')).layoutWeight(1)
                      StatusPill({
                        label: this.maintenance.operation.state || '',
                        tone: this.opBusy() ? 'warn' : 'default'
                      })
                    }.width('100%')
                    if (this.maintenance.operation.error) {
                      Text(this.maintenance.operation.error)
                        .fontSize(11.5).fontColor($r('app.color.tentacle_danger')).width('100%')
                    }
                  }
                }
                .width('100%')
                .padding(10)
                .backgroundColor($r('app.color.tentacle_bg_input'))
                .borderRadius(10)
              }

              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
                Row() {
                  ActionButton({
                    label: this.maintBusyAction === 'check' ? '检查中…' : '检查更新',
                    tone: 'secondary',
                    compact: true,
                    isEnabled: Boolean(this.maintenance?.available && this.maintenance?.web_allowed) &&
                      !this.opBusy() && this.maintBusyAction.length === 0,
                    onTap: () => { this.confirmMaintenance('check'); }
                  })
                }.margin({ right: 8, bottom: 6 })
                Row() {
                  ActionButton({
                    label: this.maintBusyAction === 'update' ? '更新中…' : '应用更新',
                    tone: 'primary',
                    compact: true,
                    isEnabled: Boolean(this.maintenance?.available && this.maintenance?.web_allowed &&
                      this.maintenance?.can_update) && !this.opBusy() && this.maintBusyAction.length === 0,
                    onTap: () => { this.confirmMaintenance('update'); }
                  })
                }.margin({ right: 8, bottom: 6 })
                Row() {
                  ActionButton({
                    label: '请求宿主重启',
                    tone: 'danger',
                    compact: true,
                    isEnabled: Boolean(this.maintenance?.available && this.maintenance?.web_allowed) &&
                      !this.opBusy() && this.maintBusyAction.length === 0,
                    onTap: () => { this.confirmMaintenance('restart'); }
                  })
                }.margin({ bottom: 6 })
              }.width('100%')

              if (this.maintenance?.available && !this.maintenance.web_allowed) {
                Text('请先在「设置与安全」中开启访问密码或设备绑定，再远程执行主机维护。')
                  .fontSize(11).fontColor('#D4A359').width('100%')
              }
            }.width('100%')
          }

          if (this.hasSubconscious()) {
            AppCard() {
              Column({ space: 10 }) {
                SectionTitle({ title: '潜意识状态' })
                Meter({ label: '羁绊 bond_level', value: this.bond })
                Meter({ label: '情绪 emotion_score', value: this.emotion, color: $r('app.color.tentacle_accent_hover') })
                Meter({ label: '思念 miss_degree', value: this.miss, color: $r('app.color.tentacle_ok') })
                Meter({ label: '游离 drift_level', value: this.drift, color: $r('app.color.tentacle_danger') })
                StatRow({ k: '最后更新', v: this.lastUpdate })
              }.width('100%')
            }
          }

          AppCard() {
            Column({ space: 2 }) {
              SectionTitle({ title: '当前会话与快照' })
              StatRow({ k: '会话 ID', v: this.sessionId })
              StatRow({ k: '开始时间', v: this.sessionStart })
              StatRow({ k: '服务端快照', v: this.snapshotTime })
            }.width('100%')
          }

          AppCard() {
            Column({ space: 2 }) {
              SectionTitle({ title: '启动以来累计 Token' })
              StatRow({ k: '输入', v: this.fmtNum(this.totPrompt) })
              StatRow({ k: '输出', v: this.fmtNum(this.totCompletion) })
              StatRow({ k: '总计', v: this.fmtNum(this.totTotal) })
              StatRow({ k: '命中缓存', v: this.fmtNum(this.totCached) })
            }.width('100%')
          }

          AppCard() {
            Column({ space: 8 }) {
              SectionTitle({ title: 'Chronicle 数据表统计' })
              Column({ space: 6 }) {
                Row({ space: 8 }) {
                  StatusDbCell({ name: 'raw_messages', countText: this.fmtNum(this.dbRaw) })
                  StatusDbCell({ name: 'sessions', countText: this.fmtNum(this.dbSessions) })
                }.width('100%')
                Row({ space: 8 }) {
                  StatusDbCell({ name: 'summaries', countText: this.fmtNum(this.dbSummaries) })
                  StatusDbCell({ name: 'goals', countText: this.fmtNum(this.dbGoals) })
                }.width('100%')
                Row({ space: 8 }) {
                  StatusDbCell({ name: 'tasks', countText: this.fmtNum(this.dbTasks) })
                  StatusDbCell({ name: 'files', countText: this.fmtNum(this.dbFiles) })
                }.width('100%')
                Row({ space: 8 }) {
                  StatusDbCell({ name: 'usage_logs', countText: this.fmtNum(this.dbUsage) })
                  Blank().layoutWeight(1)
                }.width('100%')
              }.width('100%')
            }.width('100%')
          }
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 2, bottom: 20 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.tentacle_bg'))
  }
}

@Component
struct StatusKpiTile {
  @Prop label: string = '';
  @Prop val: string = '';
  @Prop sub: string = '';
  @Prop tone: string = 'normal';

  build() {
    Column({ space: 5 }) {
      Text(this.label)
        .fontSize(11)
        .fontColor($r('app.color.tentacle_text_faint'))
        .maxLines(1)
      Text(this.val)
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontFamily('monospace')
        .fontColor(this.tone === 'ok' ? $r('app.color.tentacle_ok')
          : this.tone === 'accent' ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_text'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.sub.length > 0) {
        Text(this.sub)
          .fontSize(10.5)
          .fontColor($r('app.color.tentacle_text_dim'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .padding(13)
    .backgroundColor($r('app.color.tentacle_bg_card'))
    .borderRadius(14)
    .border({ width: 0.5, color: $r('app.color.tentacle_border') })
  }
}

@Component
struct StatusDbCell {
  @Prop name: string = '';
  @Prop countText: string = '0';

  build() {
    Row() {
      Text(this.name)
        .fontSize(11.5)
        .fontFamily('monospace')
        .fontColor($r('app.color.tentacle_text_dim'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.countText)
        .fontSize(12.5)
        .fontFamily('monospace')
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.tentacle_text'))
    }
    .layoutWeight(1)
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(10)
    .backgroundColor($r('app.color.tentacle_bg_input'))
  }
}
