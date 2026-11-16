/**
 * 入口页：自绘覆盖式抽屉导航 + 顶部标题栏
 *
 * 抽屉交互：
 * - 汉堡按钮 / 遮罩点击 开合
 * - 全局横滑手势：右滑展开、左滑收起，全程跟手，松手按位移吸附或弹回
 * - 导航按对话 / 记忆 / 系统分组，线性图标与暖色选中标记
 */

import { Settings, WsEvent, UnauthorizedError, chatStore, terminalStore } from '../model/Types';
import { MaintenanceStatus, SubagentWsEvent, DedupWsEvent, SubagentTask } from '../model/Management';
import { TentacleApi } from '../service/TentacleApi';
import { PhoneIntegration } from '../service/PhoneIntegration';
import { ConnectPanel } from '../view/ConnectPanel';
import { ChatPage } from '../view/ChatPage';
import { StatusPage } from '../view/StatusPage';
import { StatsPage } from '../view/StatsPage';
import { AdminPage } from '../view/AdminPage';
import { GraphPage } from '../view/GraphPage';
import { TerminalPage } from '../view/TerminalPage';
import { SettingsPage } from '../view/SettingsPage';
import { ConfigurationPage } from '../view/ConfigurationPage';
import { PluginsPage } from '../view/PluginsPage';
import { DedupPage } from '../view/DedupPage';
import { SubagentsPage } from '../view/SubagentsPage';
import { enterFade } from '../components/UiKit';

interface NavItem {
  key: string;
  label: string;
  group: string;
  icon: Resource;
  selectedIcon: Resource;
}

@Entry
@Component
struct Index {
  @StorageLink('connected') connected: boolean = false;
  @StorageProp('agentName') agentName: string = 'Tentacle';
  @StorageProp('connState') connState: string = '未连接';
  @State currentView: string = 'chat';
  @StorageLink('phoneOpenChat') @Watch('openPhoneChat') phoneOpenChat: number = 0;
  // 抽屉状态：drawerOpen 控制遮罩/命中；drawerX 为面板实时位移（0=完全展开，-W=收起）
  @State drawerOpen: boolean = false;
  @State drawerX: number = -252;
  @State breathOn: boolean = true;
  @StorageLink('runningSubagents') runningSubagents: number = 0;
  @StorageLink('dedupRunning') dedupRunning: boolean = false;
  @StorageLink('updateAvailable') updateAvailable: boolean = false;
  @StorageLink('pendingChatPrompt') @Watch('applyPendingPrompt') pendingChatPrompt: string = '';
  @StorageLink('appToastSeq') @Watch('showToastCapsule') appToastSeq: number = 0;
  @StorageProp('appToastText') appToastText: string = '';
  @StorageProp('appToastTone') appToastTone: string = 'info';
  @State toastVisible: boolean = false;
  private toastTimer: number = -1;

  private readonly navItems: NavItem[] = [
    { key: 'chat', label: '聊天', group: '对话', icon: $r('app.media.nav_chat'), selectedIcon: $r('app.media.nav_chat_selected') },
    { key: 'subagents', label: '子代理任务', group: '对话', icon: $r('app.media.nav_subagents'), selectedIcon: $r('app.media.nav_subagents_selected') },
    { key: 'admin', label: '记忆库', group: '记忆', icon: $r('app.media.nav_memory'), selectedIcon: $r('app.media.nav_memory_selected') },
    { key: 'graph', label: '图谱', group: '记忆', icon: $r('app.media.nav_graph'), selectedIcon: $r('app.media.nav_graph_selected') },
    { key: 'dedup', label: '概念去重', group: '记忆', icon: $r('app.media.nav_dedup'), selectedIcon: $r('app.media.nav_dedup_selected') },
    { key: 'terminal', label: '终端', group: '系统', icon: $r('app.media.nav_terminal'), selectedIcon: $r('app.media.nav_terminal_selected') },
    { key: 'stats', label: '统计', group: '系统', icon: $r('app.media.nav_stats'), selectedIcon: $r('app.media.nav_stats_selected') },
    { key: 'status', label: '状态', group: '系统', icon: $r('app.media.nav_status'), selectedIcon: $r('app.media.nav_status_selected') },
    { key: 'settings', label: '设置', group: '系统', icon: $r('app.media.nav_settings'), selectedIcon: $r('app.media.nav_settings_selected') },
    { key: 'configuration', label: '应用配置', group: '系统', icon: $r('app.media.nav_configuration'), selectedIcon: $r('app.media.nav_configuration_selected') },
    { key: 'plugins', label: '插件扩展', group: '系统', icon: $r('app.media.nav_plugins'), selectedIcon: $r('app.media.nav_plugins_selected') },
  ];
  private readonly navGroups: string[] = ['对话', '记忆', '系统'];

  private readonly drawerWidth: number = 252;
  private breathTimer: number = -1;
  private dragBaseX: number = -252;

  private wsCb: (evt: WsEvent) => void = (evt: WsEvent) => {
    if (evt.type === 'hello' || evt.type === 'settings') {
      const d = evt.data;
      if (d.agent_name !== undefined) {
        AppStorage.setOrCreate('agentName', d.agent_name);
      }
      if (d.show_reasoning !== undefined) {
        AppStorage.setOrCreate('showReasoning', d.show_reasoning);
      }
      if (d.split_messages !== undefined) {
        AppStorage.setOrCreate('splitMessages', d.split_messages);
      }
    } else if (evt.type === 'unauthorized') {
      AppStorage.setOrCreate('connected', false);
      AppStorage.setOrCreate('connState', '未连接');
    } else if (evt.type === 'terminal_data') {
      terminalStore.append(evt.data.content ?? '');
    } else if (evt.type === 'status.snapshot' || evt.type === 'maintenance.updated') {
      if (evt.type === 'maintenance.updated') {
        const m = evt.data as object as MaintenanceStatus;
        if (m.can_update !== undefined) {
          AppStorage.setOrCreate('updateAvailable', Boolean(m.can_update));
        }
      }
      return;
    } else if (evt.type === 'subagent.updated') {
      const s = evt.data as object as SubagentWsEvent;
      if (Array.isArray(s.tasks)) {
        const active = s.tasks.filter((t: SubagentTask) => t.status === 'running' || t.status === 'queued' || t.status === 'stopping').length;
        AppStorage.setOrCreate('runningSubagents', active);
      }
      return;
    } else if (evt.type === 'dedup.progress') {
      const d = evt.data as object as DedupWsEvent;
      const st = d.run?.status ?? '';
      AppStorage.setOrCreate('dedupRunning', st === 'running' || st === 'scanning');
      return;
    } else if (evt.type === 'phone_action' || evt.type.startsWith('chat_sync')) {
      // PhoneIntegration consumes this hint; it must not alter chat history revisions.
      return;
    } else {
      chatStore.handleWs(evt);
    }
  };

  private connCb: (online: boolean) => void = (online: boolean) => {
    AppStorage.setOrCreate('connState', online ? '已连接' : '重连中…');
  };

  aboutToAppear(): void {
    TentacleApi.getInstance().init(getContext(this));
    TentacleApi.getInstance().onWsEvent(this.wsCb);
    TentacleApi.getInstance().onConn(this.connCb);
    this.tryAutoConnect();
    this.breathTimer = setInterval(() => {
      this.breathOn = !this.breathOn;
    }, 900);
  }

  aboutToDisappear(): void {
    if (this.breathTimer >= 0) {
      clearInterval(this.breathTimer);
      this.breathTimer = -1;
    }
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
      this.toastTimer = -1;
    }
  }

  private showToastCapsule(): void {
    if (!this.appToastText) { return; }
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
    }
    this.toastVisible = true;
    this.toastTimer = setTimeout(() => {
      this.toastVisible = false;
      this.toastTimer = -1;
    }, 2400);
  }

  private applyPendingPrompt(): void {
    if (this.pendingChatPrompt.length > 0) {
      this.currentView = 'chat';
    }
  }

  private headerTitle(): string {
    if (this.currentView === 'chat') {
      return this.agentName;
    }
    const found = this.navItems.find((item: NavItem) => item.key === this.currentView);
    return found !== undefined ? found.label : this.agentName;
  }

  private applySettings(s: Settings): void {
    AppStorage.setOrCreate('agentName', s.agent_name);
    AppStorage.setOrCreate('showReasoning', s.show_reasoning);
    AppStorage.setOrCreate('splitMessages', s.split_messages);
  }

  private onConnected(s: Settings): void {
    this.applySettings(s);
    AppStorage.setOrCreate('connState', '已连接');
    AppStorage.setOrCreate('connected', true);
    TentacleApi.getInstance().connectWs();
    PhoneIntegration.getInstance().connected().catch(() => {});
  }

  private openPhoneChat(): void { this.currentView = 'chat'; }

  private async tryAutoConnect(): Promise<void> {
    const api = TentacleApi.getInstance();
    if (!api.hasSavedServer()) {
      return;
    }
    try {
      const s = await api.autoConnect();
      this.onConnected(s);
    } catch (e) {
      if (e instanceof UnauthorizedError) {
        // 已保存 token 失效，留在连接面板重新登录
      } else {
        // 网络不可达，留在连接面板重试
      }
    }
  }

  private serverHost(): string {
    const url = TentacleApi.getInstance().getServerUrl();
    if (url.length === 0) {
      return '';
    }
    let host = url;
    const idx = host.indexOf('//');
    if (idx >= 0) {
      host = host.substring(idx + 2);
    }
    return host;
  }

  private setDrawer(open: boolean): void {
    const targetX = open ? 0 : -this.drawerWidth;
    animateTo({
      duration: 260,
      curve: Curve.EaseOut,
      onFinish: () => {
        if (!open) {
          this.drawerOpen = false;
        }
      }
    }, () => {
      this.drawerX = targetX;
      if (open) {
        this.drawerOpen = true;
      }
    });
  }

  private switchView(key: string): void {
    this.currentView = key;
    this.setDrawer(false);
  }

  private clamp(v: number, lo: number, hi: number): number {
    if (v < lo) {
      return lo;
    }
    if (v > hi) {
      return hi;
    }
    return v;
  }

  // ---------- 手势 ----------

  private panUpdate(offsetX: number): void {
    this.drawerX = this.clamp(this.dragBaseX + offsetX, -this.drawerWidth, 0);
  }

  private panEnd(): void {
    // 已拖过宽度 45% 则吸附到目标位，否则弹回
    const shownRatio = (this.drawerX + this.drawerWidth) / this.drawerWidth;
    const open = shownRatio > 0.45;
    const startOpen = this.dragBaseX > -this.drawerWidth / 2;
    if (open === startOpen) {
      // 未跨过阈值：弹回原位
      this.setDrawer(startOpen);
    } else {
      this.setDrawer(open);
    }
  }

  private panStart(): void {
    this.dragBaseX = this.drawerX;
    if (this.drawerX > -this.drawerWidth) {
      this.drawerOpen = true;
    }
  }

  // ---------- UI 片段 ----------

  @Builder
  NavMenuItem(item: NavItem) {
    Row({ space: 12 }) {
      Image(this.currentView === item.key ? item.selectedIcon : item.icon)
        .width(19).height(19).objectFit(ImageFit.Contain).accessibilityLevel('no')
      Text(item.label)
        .fontSize(15)
        .fontColor(this.currentView === item.key
          ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_nav_text'))
        .fontWeight(this.currentView === item.key ? FontWeight.Medium : FontWeight.Normal)
        .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (item.key === 'subagents' && this.runningSubagents > 0) {
        Text(this.runningSubagents.toString())
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .backgroundColor($r('app.color.tentacle_accent'))
          .padding({ left: 6, right: 6, top: 1, bottom: 1 })
          .borderRadius(999)
      } else if (item.key === 'dedup' && this.dedupRunning) {
        Column().width(7).height(7).borderRadius(3.5).backgroundColor('#D4A359')
      } else if (item.key === 'status' && this.updateAvailable) {
        Column().width(7).height(7).borderRadius(3.5).backgroundColor($r('app.color.tentacle_ok'))
      }
    }
    .width('100%')
    .height(44)
    .id('nav-' + item.key)
    .padding({ left: 14, right: 12 })
    .borderRadius(12)
    .backgroundColor(this.currentView === item.key
      ? $r('app.color.tentacle_nav_selected') : Color.Transparent)
    .border({ width: { left: 2 }, color: this.currentView === item.key ? $r('app.color.tentacle_accent') : Color.Transparent })
    .alignItems(VerticalAlign.Center)
    .margin({ bottom: 2 })
    .accessibilitySelected(this.currentView === item.key)
    .onClick(() => {
      this.switchView(item.key);
    })
  }

  @Builder
  DrawerPanel() {
    Column() {
      Scroll() {
        Column() {
          ForEach(this.navGroups, (group: string, index: number) => {
            Column() {
              Text(group).fontSize(11).fontColor($r('app.color.tentacle_nav_muted')).width('100%')
                .padding({ left: 14, bottom: 10 })
              ForEach(this.navItems.filter((item: NavItem) => item.group === group), (item: NavItem) => {
                this.NavMenuItem(item)
              }, (item: NavItem) => item.key)
            }.width('100%').margin({ top: index === 0 ? 4 : 18 })
          }, (group: string) => group)
        }.width('100%').padding({ bottom: 12 })
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off)

      if (this.serverHost().length > 0) {
        Text(this.serverHost())
          .fontSize(11)
          .fontColor($r('app.color.tentacle_text_faint'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding({ left: 14, right: 8, top: 10, bottom: 8 })
      }
    }
    .width(this.drawerWidth)
    .height('100%')
    .padding({ top: 16, bottom: 8, left: 14, right: 12 })
    .backgroundColor($r('app.color.tentacle_bg_sidebar'))
    .shadow({
      radius: 24,
      color: '#66000000',
      offsetX: 6,
      offsetY: 0
    })
    .translate({ x: this.drawerX })
  }

  @Builder
  MainContent() {
    if (this.currentView === 'chat') {
      Column() {
        ChatPage()
      }
      .width('100%')
      .height('100%')
      .transition(enterFade())
    } else if (this.currentView === 'configuration') {
      ConfigurationPage()
    } else if (this.currentView === 'plugins') {
      PluginsPage()
    } else if (this.currentView === 'dedup') {
      DedupPage()
    } else if (this.currentView === 'subagents') {
      SubagentsPage()
    } else if (this.currentView === 'status') {
      Column() {
        StatusPage()
      }
      .width('100%')
      .height('100%')
      .transition(enterFade())
    } else if (this.currentView === 'stats') {
      Column() {
        StatsPage()
      }
      .width('100%')
      .height('100%')
      .transition(enterFade())
    } else if (this.currentView === 'admin') {
      Column() {
        AdminPage()
      }
      .width('100%')
      .height('100%')
      .transition(enterFade())
    } else if (this.currentView === 'graph') {
      Column() {
        GraphPage()
      }
      .width('100%')
      .height('100%')
      .transition(enterFade())
    } else if (this.currentView === 'terminal') {
      Column() {
        TerminalPage()
      }
      .width('100%')
      .height('100%')
      .transition(enterFade())
    } else if (this.currentView === 'settings') {
      Column() {
        SettingsPage()
      }
      .width('100%')
      .height('100%')
      .transition(enterFade())
    }
  }

  @Builder
  Header() {
    Row() {
      Row() {
        Text('☰')
          .fontSize(17)
          .fontColor($r('app.color.tentacle_text_dim'))
      }
      .width(40)
      .id('navigation-menu')
      .height(40)
      .borderRadius(20)
      .backgroundColor($r('app.color.tentacle_bg_hover'))
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.setDrawer(!this.drawerOpen);
      })

      Column() {
        Text(this.headerTitle())
          .fontSize(16.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.tentacle_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)

      Row({ space: 5 }) {
        Column()
          .width(6)
          .height(6)
          .borderRadius(3)
          .backgroundColor(this.connState === '已连接'
            ? $r('app.color.tentacle_ok') : $r('app.color.tentacle_danger'))
          .opacity(this.connState === '已连接' ? (this.breathOn ? 1 : 0.35) : 1)
          .animation({ duration: 500, curve: Curve.EaseInOut })
        Text(this.connState)
          .fontSize(11)
          .fontColor($r('app.color.tentacle_text_faint'))
      }
      .alignItems(VerticalAlign.Center)
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .borderRadius(999)
      .backgroundColor($r('app.color.tentacle_bg_hover'))
      .constraintSize({ minWidth: 70 })
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 16 })
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(Color.Transparent)
  }

  build() {
    Column() {
      if (this.connected) {
        Stack({ alignContent: Alignment.TopStart }) {
          // 主内容列
          Column() {
            this.Header()
            Column() {
              this.MainContent()
            }
            .layoutWeight(1)
            .width('100%')
          }
          .width('100%')
          .height('100%')

          // 抽屉层：遮罩 + 面板
          if (this.drawerOpen || this.drawerX > -this.drawerWidth) {
            // 半透明遮罩：点击关闭
            Column()
              .width('100%')
              .height('100%')
              .backgroundColor('#80000000')
              .opacity(this.drawerX > -this.drawerWidth
                ? 1 + this.drawerX / this.drawerWidth : 0)
              .animation({ duration: 200, curve: Curve.EaseOut })
              .position({ x: 0, y: 0 })
              .onClick(() => {
                this.setDrawer(false);
              })

            this.DrawerPanel()
          }

          if (this.toastVisible && this.appToastText.length > 0) {
            Row() {
              Row({ space: 8 }) {
                Column()
                  .width(6)
                  .height(6)
                  .borderRadius(3)
                  .backgroundColor(this.appToastTone === 'danger' ? $r('app.color.tentacle_danger')
                    : this.appToastTone === 'ok' ? $r('app.color.tentacle_ok') : $r('app.color.tentacle_accent'))
                Text(this.appToastText)
                  .fontSize(12)
                  .fontColor($r('app.color.tentacle_text'))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .padding({ left: 14, right: 14, top: 8, bottom: 8 })
              .borderRadius(999)
              .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
              .backgroundColor('#E62B241C')
              .border({
                width: 0.75,
                color: this.appToastTone === 'danger' ? $r('app.color.tentacle_danger') : $r('app.color.tentacle_border_strong')
              })
              .shadow({ radius: 16, color: '#66000000', offsetX: 0, offsetY: 6 })
              .onClick(() => {
                this.toastVisible = false;
              })
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({ left: 20, right: 20, top: 62 })
            .hitTestBehavior(HitTestMode.None)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .gesture(
          PanGesture({ direction: PanDirection.Horizontal, distance: 8 })
            .onActionStart(() => {
              this.panStart();
            })
            .onActionUpdate((event: GestureEvent) => {
              this.panUpdate(event.offsetX);
            })
            .onActionEnd(() => {
              this.panEnd();
            })
        )
      } else {
        ConnectPanel({ onDone: (s: Settings) => this.onConnected(s) })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.tentacle_bg'))
  }
}
