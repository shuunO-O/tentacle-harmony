/**
 * DSH 编码台一级入口页：工作区与会话列表
 *
 * 交互设计（与用户对齐）：
 * - 顶部跨会话待响应汇总条（工具授权 / Agent 提问一键直达）+ 工作区/会话级徽标提醒
 * - 搜索框支持本地即时筛选标题/路径 + 防抖触发服务端 session/search 全文检索并展示命中摘要
 * - 状态筛选胶囊：全部 / 运行中 / 待响应 / 已归档（实时计数）
 * - 顶部独立「置顶会话」聚合区（跨工作区直达，不与工作区分组重复展示）
 * - 工作区分组支持智能默认展开、点击折叠/展开、快速新建、重命名与移除（仅移出列表不删磁盘文件）
 * - 会话操作支持打开、置顶/取消置顶、重命名、Fork 新分支、归档与已归档恢复
 * - 支持列表下拉刷新（Refresh）并保留顶部快捷刷新按钮
 */

import { DshClient } from '../dsh/DshClient';
import {
  DshDirectoryListing,
  DshPendingPrompt,
  DshPinnedSessionEntry,
  DshSession,
  DshWorkspace,
  DshWorkspaceGroup,
  formatModelCapsule
} from '../dsh/DshModels';
import { DshNewSessionSheet } from '../dsh/DshSheets';
import { ActionButton, AppCard, FeedbackBanner, StatusPill } from '../components/UiKit';
import { notifyToast } from '../model/UiToast';

interface FilterTabItem {
  key: string;
  label: string;
  count: number;
  highlight: boolean;
}

@Component
export struct DshListPage {
  private client: DshClient = DshClient.getInstance();
  @State groups: DshWorkspaceGroup[] = [];
  @State workspaces: DshWorkspace[] = [];
  @State pinnedEntries: DshPinnedSessionEntry[] = [];
  @State archivedEntries: DshPinnedSessionEntry[] = [];
  @State pendingPrompts: DshPendingPrompt[] = [];

  @State ready: boolean = false;
  @State connecting: boolean = false;
  @State muxConnected: boolean = false;
  @State refreshing: boolean = false;
  @State errText: string = '';

  @State query: string = '';
  @State statusFilter: string = 'all'; // 'all' | 'running' | 'pending' | 'archived'
  @State searchingRemote: boolean = false;
  @State searchSnippets: Map<string, string> = new Map<string, string>();
  @State collapsedGroups: Map<string, boolean> = new Map<string, boolean>();

  @State sheetOpen: boolean = false;
  @State activeSheet: string = ''; // 'new' | 'menu' | 'workspace'
  @State menuSession: DshSession | null = null;
  @State renameMode: boolean = false;
  @State renameDraft: string = '';

  @State menuWorkspace: DshWorkspaceGroup | null = null;
  @State wsRenameMode: boolean = false;
  @State wsRenameDraft: string = '';
  @State wsDeleteConfirm: boolean = false;
  @State actionBusy: boolean = false;

  private searchTimer: number = -1;
  private searchSeq: number = 0;

  private syncCb: () => void = () => {
    this.pullClientState();
  };

  aboutToAppear(): void {
    this.client.subscribe(this.syncCb);
    this.pullClientState();
    this.initConnect();
  }

  aboutToDisappear(): void {
    if (this.searchTimer >= 0) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
    this.client.unsubscribe(this.syncCb);
  }

  private pullClientState(): void {
    this.ready = this.client.ready;
    this.connecting = this.client.connecting;
    this.muxConnected = this.client.muxConnected;
    this.errText = this.client.lastError;
    this.workspaces = this.client.workspaces;
    this.pendingPrompts = this.client.pendingPrompts;
    this.pinnedEntries = this.client.getPinnedSessions();
    this.archivedEntries = this.client.getArchivedSessions();
    this.groups = this.client.getWorkspaceGroups(true);
  }

  private async initConnect(): Promise<void> {
    if (this.client.ready) {
      this.client.refreshSessions().catch(() => {});
      return;
    }
    await this.client.ensureConnected();
  }

  private async refreshNow(silentToast: boolean = false): Promise<void> {
    if (!this.client.ready) {
      await this.client.ensureConnected();
      return;
    }
    try {
      await this.client.refreshSessions();
      if (!silentToast) {
        notifyToast('DSH 会话列表已刷新', 'ok');
      }
    } catch (e) {
      this.errText = (e as Error).message;
    }
  }

  private async handlePullRefresh(): Promise<void> {
    this.refreshing = true;
    try {
      await this.refreshNow(true);
    } finally {
      this.refreshing = false;
    }
  }

  private onQueryChanged(val: string): void {
    this.query = val;
    if (this.searchTimer >= 0) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
    const clean = val.trim();
    if (clean.length === 0) {
      this.searchSeq += 1;
      this.searchingRemote = false;
      if (this.searchSnippets.size > 0) {
        this.searchSnippets = new Map<string, string>();
      }
      return;
    }
    if (!this.ready) {
      return;
    }
    const seq = ++this.searchSeq;
    this.searchingRemote = true;
    this.searchTimer = setTimeout(() => {
      this.searchTimer = -1;
      this.executeRemoteSearch(clean, seq);
    }, 320);
  }

  private async executeRemoteSearch(cleanQuery: string, seq: number): Promise<void> {
    try {
      const res = await this.client.searchSessions(cleanQuery);
      if (seq !== this.searchSeq) {
        return;
      }
      const next = new Map<string, string>();
      for (let i = 0; i < res.items.length; i++) {
        const it = res.items[i];
        if (!next.has(it.sessionId)) {
          next.set(it.sessionId, it.snippet);
        }
      }
      this.searchSnippets = next;
    } catch (_) {
      if (seq === this.searchSeq) {
        this.searchSnippets = new Map<string, string>();
      }
    } finally {
      if (seq === this.searchSeq) {
        this.searchingRemote = false;
      }
    }
  }

  private promptsForSession(sessionId: string): DshPendingPrompt[] {
    const out: DshPendingPrompt[] = [];
    for (let i = 0; i < this.pendingPrompts.length; i++) {
      const p = this.pendingPrompts[i];
      if (p.agentId === sessionId) {
        out.push(p);
      }
    }
    return out;
  }

  private sessionPromptTag(sessionId: string): string {
    const list = this.promptsForSession(sessionId);
    if (list.length === 0) {
      return '';
    }
    for (let i = 0; i < list.length; i++) {
      if (list[i].kind === 'approval') {
        return '待审批';
      }
    }
    return '待回答';
  }

  private groupPendingCount(grp: DshWorkspaceGroup): number {
    let total = 0;
    for (let i = 0; i < grp.sessions.length; i++) {
      total += this.promptsForSession(grp.sessions[i].sessionId).length;
    }
    return total;
  }

  private groupRunningCount(grp: DshWorkspaceGroup): number {
    let total = 0;
    for (let i = 0; i < grp.sessions.length; i++) {
      if (grp.sessions[i].running) {
        total += 1;
      }
    }
    return total;
  }

  private countActiveRunning(): number {
    let count = 0;
    for (let i = 0; i < this.pinnedEntries.length; i++) {
      if (this.pinnedEntries[i].session.running) {
        count += 1;
      }
    }
    for (let i = 0; i < this.groups.length; i++) {
      count += this.groupRunningCount(this.groups[i]);
    }
    return count;
  }

  private countPendingSessions(): number {
    const seen = new Set<string>();
    for (let i = 0; i < this.pendingPrompts.length; i++) {
      const aid = this.pendingPrompts[i].agentId;
      if (aid.length > 0) {
        seen.add(aid);
      }
    }
    return seen.size > 0 ? seen.size : this.pendingPrompts.length;
  }

  private filterTabs(): FilterTabItem[] {
    const runningCount = this.countActiveRunning();
    const pendingCount = this.countPendingSessions();
    const archivedCount = this.archivedEntries.length;
    return [
      { key: 'all', label: '全部', count: 0, highlight: false },
      { key: 'running', label: '运行中', count: runningCount, highlight: false },
      { key: 'pending', label: '待响应', count: pendingCount, highlight: pendingCount > 0 },
      { key: 'archived', label: '已归档', count: archivedCount, highlight: false }
    ];
  }

  private matchesSessionFilter(session: DshSession, wsTitle: string, wsPath: string): boolean {
    if (this.statusFilter === 'running' && !session.running) {
      return false;
    }
    if (this.statusFilter === 'pending' && this.promptsForSession(session.sessionId).length === 0) {
      return false;
    }
    const q = this.query.trim().toLowerCase();
    if (q.length === 0) {
      return true;
    }
    if (this.searchSnippets.has(session.sessionId)) {
      return true;
    }
    if (session.title.toLowerCase().indexOf(q) >= 0 || session.cwd.toLowerCase().indexOf(q) >= 0) {
      return true;
    }
    if (wsTitle.toLowerCase().indexOf(q) >= 0 || wsPath.toLowerCase().indexOf(q) >= 0) {
      return true;
    }
    return false;
  }

  private filteredPinnedEntries(): DshPinnedSessionEntry[] {
    if (this.statusFilter === 'archived') {
      return [];
    }
    const out: DshPinnedSessionEntry[] = [];
    for (let i = 0; i < this.pinnedEntries.length; i++) {
      const item = this.pinnedEntries[i];
      if (this.matchesSessionFilter(item.session, item.workspaceTitle, item.workspacePath)) {
        out.push(item);
      }
    }
    return out;
  }

  private filteredArchivedEntries(): DshPinnedSessionEntry[] {
    if (this.statusFilter !== 'archived') {
      return [];
    }
    const q = this.query.trim().toLowerCase();
    if (q.length === 0) {
      return this.archivedEntries;
    }
    const out: DshPinnedSessionEntry[] = [];
    for (let i = 0; i < this.archivedEntries.length; i++) {
      const item = this.archivedEntries[i];
      if (this.searchSnippets.has(item.session.sessionId)
        || item.session.title.toLowerCase().indexOf(q) >= 0
        || item.session.cwd.toLowerCase().indexOf(q) >= 0
        || item.workspaceTitle.toLowerCase().indexOf(q) >= 0
        || item.workspacePath.toLowerCase().indexOf(q) >= 0) {
        out.push(item);
      }
    }
    return out;
  }

  private filteredGroups(): DshWorkspaceGroup[] {
    const filter = this.statusFilter;
    if (filter === 'archived') {
      return [];
    }
    const q = this.query.trim().toLowerCase();
    const groups = this.groups;
    const snippets = this.searchSnippets;
    const out: DshWorkspaceGroup[] = [];
    for (let i = 0; i < groups.length; i++) {
      const g = groups[i];
      const wsMatch = q.length > 0
        && (g.title.toLowerCase().indexOf(q) >= 0 || g.path.toLowerCase().indexOf(q) >= 0);
      const matched: DshSession[] = [];
      for (let j = 0; j < g.sessions.length; j++) {
        const s = g.sessions[j];
        if (filter === 'running' && !s.running) {
          continue;
        }
        if (filter === 'pending' && this.promptsForSession(s.sessionId).length === 0) {
          continue;
        }
        if (q.length === 0 || wsMatch || snippets.has(s.sessionId)
          || s.title.toLowerCase().indexOf(q) >= 0 || s.cwd.toLowerCase().indexOf(q) >= 0) {
          matched.push(s);
        }
      }
      if (filter === 'all') {
        if (q.length === 0 || matched.length > 0 || wsMatch) {
          out.push({
            key: g.key,
            workspaceId: g.workspaceId,
            path: g.path,
            title: g.title,
            sessions: matched
          });
        }
      } else if (matched.length > 0) {
        out.push({
          key: g.key,
          workspaceId: g.workspaceId,
          path: g.path,
          title: g.title,
          sessions: matched
        });
      }
    }
    return out;
  }

  private defaultExpandedGroupKeys(list: DshWorkspaceGroup[]): Set<string> {
    const expanded = new Set<string>();
    const nonEmpty: DshWorkspaceGroup[] = [];
    for (let i = 0; i < list.length; i++) {
      const g = list[i];
      if (g.sessions.length > 0) {
        nonEmpty.push(g);
      }
      if (this.groupRunningCount(g) > 0 || this.groupPendingCount(g) > 0) {
        expanded.add(g.key);
      }
    }
    if (nonEmpty.length <= 3) {
      for (let i = 0; i < nonEmpty.length; i++) {
        expanded.add(nonEmpty[i].key);
      }
    } else {
      const ranked = nonEmpty.slice().sort((a: DshWorkspaceGroup, b: DshWorkspaceGroup) => {
        const ta = a.sessions.length > 0 ? a.sessions[0].updatedAt : 0;
        const tb = b.sessions.length > 0 ? b.sessions[0].updatedAt : 0;
        return tb - ta;
      });
      const limit = Math.min(2, ranked.length);
      for (let i = 0; i < limit; i++) {
        expanded.add(ranked[i].key);
      }
    }
    return expanded;
  }

  private isGroupCollapsed(grp: DshWorkspaceGroup, visibleList: DshWorkspaceGroup[]): boolean {
    if (this.query.trim().length > 0 || this.statusFilter === 'running' || this.statusFilter === 'pending') {
      return false;
    }
    const explicit = this.collapsedGroups.get(grp.key);
    if (explicit !== undefined) {
      return explicit;
    }
    const defaults = this.defaultExpandedGroupKeys(visibleList);
    return !defaults.has(grp.key);
  }

  private toggleGroupCollapse(grp: DshWorkspaceGroup, visibleList: DshWorkspaceGroup[]): void {
    const currentlyCollapsed = this.isGroupCollapsed(grp, visibleList);
    const next = new Map<string, boolean>();
    this.collapsedGroups.forEach((v: boolean, k: string) => next.set(k, v));
    next.set(grp.key, !currentlyCollapsed);
    this.collapsedGroups = next;
  }

  private sessionRowKey(session: DshSession, prefix: string): string {
    const snippet = this.searchSnippets.get(session.sessionId) ?? '';
    const promptTag = this.sessionPromptTag(session.sessionId);
    const pinnedFlag = this.client.isSessionPinned(session.sessionId) ? '1' : '0';
    return prefix + ':' + session.sessionId + ':' + (session.running ? '1' : '0')
      + ':' + session.updatedAt.toString() + ':' + session.title + ':' + promptTag + ':' + pinnedFlag
      + ':' + snippet.length.toString();
  }

  private promptSessionTitle(prompt: DshPendingPrompt): string {
    if (prompt.agentId.length === 0) {
      return '当前会话';
    }
    const summary = this.client.getSessionSummary(prompt.agentId);
    if (summary !== undefined && summary.title.length > 0) {
      return summary.title;
    }
    return prompt.agentId.substring(0, 8);
  }

  private promptBrief(prompt: DshPendingPrompt): string {
    if (prompt.kind === 'approval') {
      return '待授权 · ' + (prompt.toolName.length > 0 ? prompt.toolName : '工具调用');
    }
    return '待回答 · ' + (prompt.title.length > 0 ? prompt.title : 'Agent 提问');
  }

  private formatRelativeTime(tsMs: number): string {
    if (tsMs <= 0) {
      return '';
    }
    const diff = Date.now() - tsMs;
    if (diff < 60 * 1000) {
      return '刚刚';
    }
    if (diff < 60 * 60 * 1000) {
      return Math.floor(diff / 60000).toString() + ' 分钟前';
    }
    if (diff < 24 * 60 * 60 * 1000) {
      return Math.floor(diff / 3600000).toString() + ' 小时前';
    }
    const d = new Date(tsMs);
    return (d.getMonth() + 1).toString() + '/' + d.getDate().toString();
  }

  private pushSession(sessionId: string): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/DshSessionPage',
      params: { sessionId: sessionId }
    }).catch((err: Error) => {
      notifyToast('打开会话失败：' + err.message, 'danger');
    });
  }

  private async quickCreateInGroup(grp: DshWorkspaceGroup): Promise<void> {
    if (this.actionBusy) {
      return;
    }
    this.actionBusy = true;
    try {
      const sid = await this.client.createSessionInDirectory(grp.path, grp.workspaceId);
      this.pushSession(sid);
    } catch (e) {
      notifyToast('新建会话失败：' + (e as Error).message, 'danger');
    } finally {
      this.actionBusy = false;
    }
  }

  private openNewSheet(): void {
    this.activeSheet = 'new';
    this.sheetOpen = true;
  }

  private closeSheet(): void {
    this.sheetOpen = false;
  }

  private currentSheetHeight(): number | SheetSize {
    if (this.activeSheet === 'menu') {
      if (this.renameMode) {
        return 250;
      }
      if (this.menuSession !== null && this.client.isSessionArchived(this.menuSession.sessionId)) {
        return 250;
      }
      return 410;
    }
    if (this.activeSheet === 'workspace') {
      return this.wsRenameMode || this.wsDeleteConfirm ? 280 : 320;
    }
    return SheetSize.LARGE;
  }

  private openSessionMenu(session: DshSession): void {
    this.menuSession = session;
    this.renameMode = false;
    this.renameDraft = session.title;
    this.activeSheet = 'menu';
    this.sheetOpen = true;
  }

  private openWorkspaceMenu(grp: DshWorkspaceGroup): void {
    this.menuWorkspace = grp;
    this.wsRenameMode = false;
    this.wsRenameDraft = grp.title;
    this.wsDeleteConfirm = false;
    this.activeSheet = 'workspace';
    this.sheetOpen = true;
  }

  private async submitRename(): Promise<void> {
    if (this.menuSession === null || this.actionBusy) {
      return;
    }
    const clean = this.renameDraft.trim();
    if (clean.length === 0) {
      return;
    }
    this.actionBusy = true;
    try {
      await this.client.renameSession(this.menuSession.sessionId, clean);
      this.closeSheet();
      notifyToast('已重命名会话', 'ok');
    } catch (e) {
      notifyToast('重命名失败：' + (e as Error).message, 'danger');
    } finally {
      this.actionBusy = false;
    }
  }

  private async togglePinTargetSession(): Promise<void> {
    if (this.menuSession === null || this.actionBusy) {
      return;
    }
    const sid = this.menuSession.sessionId;
    const pinned = this.client.isSessionPinned(sid);
    this.actionBusy = true;
    try {
      if (pinned) {
        await this.client.unpinSession(sid);
        notifyToast('已取消置顶', 'ok');
      } else {
        await this.client.pinSession(sid);
        notifyToast('已置顶会话', 'ok');
      }
      this.closeSheet();
    } catch (e) {
      notifyToast((pinned ? '取消置顶失败：' : '置顶失败：') + (e as Error).message, 'danger');
    } finally {
      this.actionBusy = false;
    }
  }

  private async archiveTargetSession(): Promise<void> {
    if (this.menuSession === null || this.actionBusy) {
      return;
    }
    const target = this.menuSession;
    this.actionBusy = true;
    try {
      await this.client.archiveSession(target.sessionId, target.running);
      this.closeSheet();
      notifyToast(target.running ? '已停止任务并归档，可在「已归档」恢复' : '已归档会话，可在「已归档」恢复', 'ok');
    } catch (e) {
      notifyToast('归档失败：' + (e as Error).message, 'danger');
    } finally {
      this.actionBusy = false;
    }
  }

  private async unarchiveSessionById(sessionId: string): Promise<void> {
    if (this.actionBusy) {
      return;
    }
    this.actionBusy = true;
    try {
      await this.client.unarchiveSession(sessionId);
      if (this.sheetOpen) {
        this.closeSheet();
      }
      notifyToast('已恢复到会话列表', 'ok');
    } catch (e) {
      notifyToast('恢复失败：' + (e as Error).message, 'danger');
    } finally {
      this.actionBusy = false;
    }
  }

  private async forkTargetSession(): Promise<void> {
    if (this.menuSession === null || this.actionBusy) {
      return;
    }
    this.actionBusy = true;
    try {
      const forkedId = await this.client.forkSession(this.menuSession.sessionId);
      this.closeSheet();
      notifyToast('已创建分支会话', 'ok');
      this.pushSession(forkedId);
    } catch (e) {
      notifyToast('Fork 失败：' + (e as Error).message, 'danger');
    } finally {
      this.actionBusy = false;
    }
  }

  private async submitWorkspaceRename(): Promise<void> {
    if (this.menuWorkspace === null || this.menuWorkspace.workspaceId.length === 0 || this.actionBusy) {
      return;
    }
    const clean = this.wsRenameDraft.trim();
    if (clean.length === 0) {
      return;
    }
    this.actionBusy = true;
    try {
      await this.client.renameWorkspace(this.menuWorkspace.workspaceId, clean);
      this.closeSheet();
      notifyToast('工作区名称已更新', 'ok');
    } catch (e) {
      notifyToast('重命名工作区失败：' + (e as Error).message, 'danger');
    } finally {
      this.actionBusy = false;
    }
  }

  private async confirmWorkspaceDelete(): Promise<void> {
    if (this.menuWorkspace === null || this.menuWorkspace.workspaceId.length === 0 || this.actionBusy) {
      return;
    }
    this.actionBusy = true;
    try {
      await this.client.deleteWorkspace(this.menuWorkspace.workspaceId);
      this.closeSheet();
      notifyToast('已从列表移除工作区（本地文件保留）', 'ok');
    } catch (e) {
      notifyToast('移除工作区失败：' + (e as Error).message, 'danger');
    } finally {
      this.actionBusy = false;
    }
  }

  @Builder
  UnifiedSheetBuilder() {
    Column() {
      if (this.activeSheet === 'menu') {
        this.SessionActionSheetBuilder()
      } else if (this.activeSheet === 'workspace') {
        this.WorkspaceActionSheetBuilder()
      } else if (this.activeSheet === 'new') {
        this.NewSessionSheetBuilder()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.tentacle_bg_card'))
  }

  @Builder
  NewSessionSheetBuilder() {
    DshNewSessionSheet({
      workspaces: this.workspaces,
      onLoadDir: async (p: string): Promise<DshDirectoryListing> => await this.client.listDirectory(p),
      onCreateDir: async (parent: string, name: string): Promise<string> => await this.client.createDirectory(parent, name),
      onCreateSession: async (dirPath: string, wsId: string): Promise<void> => {
        const sid = await this.client.createSessionInDirectory(dirPath, wsId);
        this.closeSheet();
        this.pushSession(sid);
      },
      onClose: () => {
        this.closeSheet();
      }
    })
  }

  @Builder
  SessionActionSheetBuilder() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 2 }) {
          Text(this.menuSession !== null ? this.menuSession.title : '会话操作')
            .fontSize(16.5)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.tentacle_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.menuSession !== null) {
            Text(this.menuSession.cwd || this.menuSession.sessionId)
              .fontSize(11)
              .fontFamily('monospace')
              .fontColor($r('app.color.tentacle_text_faint'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)

        Text('关闭')
          .fontSize(13)
          .fontColor($r('app.color.tentacle_text_dim'))
          .padding(8)
          .onClick(() => {
            this.closeSheet();
          })
      }.width('100%')

      if (this.renameMode) {
        TextInput({ text: this.renameDraft, placeholder: '输入新会话标题…' })
          .height(42)
          .fontSize(14)
          .fontColor($r('app.color.tentacle_text'))
          .backgroundColor($r('app.color.tentacle_bg_input'))
          .borderRadius(10)
          .onChange((v: string) => {
            this.renameDraft = v;
          })
        Row({ space: 10 }) {
          ActionButton({
            label: '取消',
            tone: 'ghost',
            isEnabled: !this.actionBusy,
            onTap: () => {
              this.renameMode = false;
            }
          })
          ActionButton({
            label: this.actionBusy ? '保存中…' : '保存标题',
            tone: 'primary',
            isEnabled: !this.actionBusy && this.renameDraft.trim().length > 0,
            onTap: () => {
              this.submitRename();
            }
          })
        }.width('100%').justifyContent(FlexAlign.End)
      } else if (this.menuSession !== null && this.client.isSessionArchived(this.menuSession.sessionId)) {
        Column({ space: 8 }) {
          ActionButton({
            label: '打开查看历史记录',
            tone: 'primary',
            fullWidth: true,
            onTap: () => {
              if (this.menuSession !== null) {
                const sid = this.menuSession.sessionId;
                this.closeSheet();
                this.pushSession(sid);
              }
            }
          })
          ActionButton({
            label: this.actionBusy ? '恢复中…' : '恢复到会话列表',
            tone: 'secondary',
            fullWidth: true,
            isEnabled: !this.actionBusy,
            onTap: () => {
              if (this.menuSession !== null) {
                this.unarchiveSessionById(this.menuSession.sessionId);
              }
            }
          })
        }.width('100%')
      } else {
        Column({ space: 8 }) {
          ActionButton({
            label: '打开对话与轨迹',
            tone: 'primary',
            fullWidth: true,
            onTap: () => {
              if (this.menuSession !== null) {
                const sid = this.menuSession.sessionId;
                this.closeSheet();
                this.pushSession(sid);
              }
            }
          })
          ActionButton({
            label: this.menuSession !== null && this.client.isSessionPinned(this.menuSession.sessionId)
              ? '取消置顶' : '置顶到列表顶部',
            tone: 'secondary',
            fullWidth: true,
            isEnabled: !this.actionBusy,
            onTap: () => {
              this.togglePinTargetSession();
            }
          })
          ActionButton({
            label: '重命名会话',
            tone: 'secondary',
            fullWidth: true,
            isEnabled: !this.actionBusy,
            onTap: () => {
              this.renameMode = true;
            }
          })
          ActionButton({
            label: this.actionBusy ? '处理中…' : '从当前点 Fork 新分支',
            tone: 'secondary',
            fullWidth: true,
            isEnabled: !this.actionBusy,
            onTap: () => {
              this.forkTargetSession();
            }
          })
          ActionButton({
            label: this.menuSession !== null && this.menuSession.running
              ? '停止任务并归档会话' : '归档会话（可随时恢复）',
            tone: 'danger',
            fullWidth: true,
            isEnabled: !this.actionBusy,
            onTap: () => {
              this.archiveTargetSession();
            }
          })
        }.width('100%')
      }
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 10, bottom: 24 })
    .backgroundColor($r('app.color.tentacle_bg_card'))
  }

  @Builder
  WorkspaceActionSheetBuilder() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 2 }) {
          Text(this.menuWorkspace !== null ? this.menuWorkspace.title : '工作区操作')
            .fontSize(16.5)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.tentacle_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.menuWorkspace !== null && this.menuWorkspace.path.length > 0) {
            Text(this.menuWorkspace.path)
              .fontSize(11)
              .fontFamily('monospace')
              .fontColor($r('app.color.tentacle_text_faint'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)

        Text('关闭')
          .fontSize(13)
          .fontColor($r('app.color.tentacle_text_dim'))
          .padding(8)
          .onClick(() => {
            this.closeSheet();
          })
      }.width('100%')

      if (this.wsRenameMode) {
        TextInput({ text: this.wsRenameDraft, placeholder: '输入新的工作区显示名称…' })
          .height(42)
          .fontSize(14)
          .fontColor($r('app.color.tentacle_text'))
          .backgroundColor($r('app.color.tentacle_bg_input'))
          .borderRadius(10)
          .onChange((v: string) => {
            this.wsRenameDraft = v;
          })
        Row({ space: 10 }) {
          ActionButton({
            label: '取消',
            tone: 'ghost',
            isEnabled: !this.actionBusy,
            onTap: () => {
              this.wsRenameMode = false;
            }
          })
          ActionButton({
            label: this.actionBusy ? '保存中…' : '保存名称',
            tone: 'primary',
            isEnabled: !this.actionBusy && this.wsRenameDraft.trim().length > 0,
            onTap: () => {
              this.submitWorkspaceRename();
            }
          })
        }.width('100%').justifyContent(FlexAlign.End)
      } else if (this.wsDeleteConfirm) {
        FeedbackBanner({
          text: '确认从 DSH 工作区列表移除「' + (this.menuWorkspace !== null ? this.menuWorkspace.title : '')
            + '」？此操作仅移出工作区列表，不会删除磁盘上的任何目录与文件。',
          tone: 'warn'
        })
        Row({ space: 10 }) {
          ActionButton({
            label: '取消',
            tone: 'ghost',
            isEnabled: !this.actionBusy,
            onTap: () => {
              this.wsDeleteConfirm = false;
            }
          })
          ActionButton({
            label: this.actionBusy ? '移除中…' : '确认移除',
            tone: 'danger',
            isEnabled: !this.actionBusy,
            onTap: () => {
              this.confirmWorkspaceDelete();
            }
          })
        }.width('100%').justifyContent(FlexAlign.End)
      } else {
        Column({ space: 8 }) {
          ActionButton({
            label: '+ 在此工作区新建会话',
            tone: 'primary',
            fullWidth: true,
            isEnabled: !this.actionBusy,
            onTap: () => {
              if (this.menuWorkspace !== null) {
                const target = this.menuWorkspace;
                this.closeSheet();
                this.quickCreateInGroup(target);
              }
            }
          })
          ActionButton({
            label: '重命名工作区',
            tone: 'secondary',
            fullWidth: true,
            isEnabled: !this.actionBusy,
            onTap: () => {
              this.wsRenameMode = true;
            }
          })
          ActionButton({
            label: '从列表移除工作区',
            tone: 'danger',
            fullWidth: true,
            isEnabled: !this.actionBusy,
            onTap: () => {
              this.wsDeleteConfirm = true;
            }
          })
        }.width('100%')
      }
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 10, bottom: 24 })
    .backgroundColor($r('app.color.tentacle_bg_card'))
  }

  @Builder
  PendingPromptsBanner() {
    if (this.pendingPrompts.length > 0) {
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Column().width(7).height(7).borderRadius(3.5).backgroundColor('#D4A359')
          Text('有 ' + this.pendingPrompts.length.toString() + ' 项等待处理')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#F2D08B')
          Blank()
          if (this.pendingPrompts.length === 1 && this.pendingPrompts[0].agentId.length > 0) {
            Text('立即处理 ›')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor('#D4A359')
          }
        }
        .width('100%')
        .onClick(() => {
          if (this.pendingPrompts.length > 0 && this.pendingPrompts[0].agentId.length > 0) {
            this.pushSession(this.pendingPrompts[0].agentId);
          }
        })

        Column({ space: 6 }) {
          ForEach(this.pendingPrompts.slice(0, 3), (prompt: DshPendingPrompt) => {
            Row({ space: 8 }) {
              Text(prompt.kind === 'approval' ? '授权' : '提问')
                .fontSize(10.5)
                .fontWeight(FontWeight.Medium)
                .fontColor('#201B16')
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(6)
                .backgroundColor('#D4A359')

              Column({ space: 2 }) {
                Text(this.promptSessionTitle(prompt))
                  .fontSize(12.5)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.tentacle_text'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.promptBrief(prompt))
                  .fontSize(11)
                  .fontColor($r('app.color.tentacle_text_dim'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)

              Text('前往 ›')
                .fontSize(11.5)
                .fontColor('#D4A359')
            }
            .width('100%')
            .padding({ left: 10, right: 10, top: 8, bottom: 8 })
            .borderRadius(10)
            .backgroundColor('#241E17')
            .border({ width: 0.5, color: '#59D4A359' })
            .onClick(() => {
              if (prompt.agentId.length > 0) {
                this.pushSession(prompt.agentId);
              }
            })
          }, (prompt: DshPendingPrompt) => prompt.eventId)
        }.width('100%')
      }
      .width('100%')
      .padding(12)
      .borderRadius(14)
      .backgroundColor('#2B2318')
      .border({ width: 0.75, color: '#80D4A359' })
    }
  }

  @Builder
  SessionItemCard(session: DshSession, workspaceBadge: string, isArchivedItem: boolean, showPinnedBadge: boolean) {
    Column({ space: 6 }) {
      Row({ space: 10 }) {
        Column()
          .width(7)
          .height(7)
          .borderRadius(3.5)
          .backgroundColor(this.sessionPromptTag(session.sessionId).length > 0
            ? '#D4A359'
            : (session.running ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_text_faint')))

        Column({ space: 3 }) {
          Row({ space: 6 }) {
            Text(session.title)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.tentacle_text'))
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (session.updatedAt > 0) {
              Text(this.formatRelativeTime(session.updatedAt))
                .fontSize(11)
                .fontColor($r('app.color.tentacle_text_faint'))
            }
          }.width('100%')

          Row({ space: 6 }) {
            if (this.sessionPromptTag(session.sessionId).length > 0) {
              Text(this.sessionPromptTag(session.sessionId))
                .fontSize(10)
                .fontWeight(FontWeight.Medium)
                .fontColor('#F2D08B')
                .padding({ left: 6, right: 6, top: 1.5, bottom: 1.5 })
                .borderRadius(6)
                .backgroundColor('#33D4A359')
            }
            if (session.running) {
              Text('运行中')
                .fontSize(10.5)
                .fontColor($r('app.color.tentacle_accent'))
            }
            if (showPinnedBadge) {
              Text('置顶')
                .fontSize(10)
                .fontColor($r('app.color.tentacle_accent'))
                .padding({ left: 5, right: 5, top: 1.5, bottom: 1.5 })
                .borderRadius(6)
                .backgroundColor($r('app.color.tentacle_accent_soft'))
            }
            if (workspaceBadge.length > 0) {
              Text(workspaceBadge)
                .fontSize(10)
                .fontColor($r('app.color.tentacle_text_dim'))
                .padding({ left: 6, right: 6, top: 1.5, bottom: 1.5 })
                .borderRadius(6)
                .backgroundColor($r('app.color.tentacle_bg_hover'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: 112 })
            }
            if (session.modelSelection !== undefined) {
              Text(formatModelCapsule(session.modelSelection, this.client.modelCatalog.flatModels))
                .fontSize(10.5)
                .fontFamily('monospace')
                .fontColor($r('app.color.tentacle_text_faint'))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            } else {
              Text(session.sessionId.substring(0, 8))
                .fontSize(10.5)
                .fontFamily('monospace')
                .fontColor($r('app.color.tentacle_text_faint'))
            }
          }.width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (isArchivedItem) {
          ActionButton({
            label: '恢复',
            tone: 'secondary',
            compact: true,
            isEnabled: !this.actionBusy,
            onTap: () => {
              this.unarchiveSessionById(session.sessionId);
            }
          })
        } else {
          Text('···')
            .fontSize(16)
            .fontColor($r('app.color.tentacle_text_dim'))
            .padding({ left: 8, right: 6, top: 6, bottom: 6 })
            .onClick(() => this.openSessionMenu(session))
        }
      }.width('100%')

      if ((this.searchSnippets.get(session.sessionId) ?? '').length > 0) {
        Text('匹配：' + (this.searchSnippets.get(session.sessionId) ?? ''))
          .fontSize(11.5)
          .lineHeight(16.5)
          .fontColor($r('app.color.tentacle_text_dim'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding({ left: 8, right: 8, top: 5, bottom: 5 })
          .borderRadius(8)
          .backgroundColor($r('app.color.tentacle_bg_input'))
      }
    }
    .width('100%')
    .padding({ left: 10, right: 8, top: 10, bottom: 10 })
    .borderRadius(11)
    .backgroundColor($r('app.color.tentacle_bg_elevated'))
    .border({
      width: 0.5,
      color: this.sessionPromptTag(session.sessionId).length > 0
        ? '#80D4A359' : $r('app.color.tentacle_border')
    })
    .onClick(() => this.pushSession(session.sessionId))
  }

  build() {
    Column() {
      // 顶部状态与动作条
      Row({ space: 8 }) {
        StatusPill({
          label: this.connecting ? '连接 DSH…' : (this.muxConnected ? '实时同步' : (this.ready ? '已就绪' : '未连接')),
          tone: this.muxConnected ? 'ok' : (this.ready ? 'accent' : 'default')
        })
        Blank()
        ActionButton({
          label: '+ 新建会话',
          tone: 'primary',
          compact: true,
          isEnabled: this.ready && !this.connecting,
          onTap: () => {
            this.openNewSheet();
          }
        })
        ActionButton({
          label: '刷新',
          tone: 'secondary',
          compact: true,
          isEnabled: !this.connecting && !this.refreshing,
          onTap: () => {
            this.refreshNow();
          }
        })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 4, bottom: 8 })

      if (this.ready || this.groups.length > 0 || this.pinnedEntries.length > 0 || this.archivedEntries.length > 0) {
        // 搜索栏（支持本地筛选 + 服务端全文检索）
        Row({ space: 6 }) {
          TextInput({ text: this.query, placeholder: '搜索工作区、会话标题或对话内容…' })
            .layoutWeight(1)
            .height(38)
            .fontSize(13.5)
            .fontColor($r('app.color.tentacle_text'))
            .placeholderColor($r('app.color.tentacle_text_faint'))
            .backgroundColor($r('app.color.tentacle_bg_input'))
            .borderRadius(12)
            .border({ width: 0.5, color: $r('app.color.tentacle_border') })
            .padding({ left: 12, right: 12 })
            .onChange((v: string) => {
              this.onQueryChanged(v);
            })

          if (this.searchingRemote) {
            Text('检索中')
              .fontSize(11)
              .fontColor($r('app.color.tentacle_text_faint'))
              .padding({ left: 4, right: 4 })
          } else if (this.query.length > 0) {
            Text('清除')
              .fontSize(12)
              .fontColor($r('app.color.tentacle_text_dim'))
              .padding({ left: 8, right: 8, top: 6, bottom: 6 })
              .borderRadius(8)
              .backgroundColor($r('app.color.tentacle_bg_hover'))
              .onClick(() => {
                this.onQueryChanged('');
              })
          }
        }
        .width('100%')
        .padding({ left: 14, right: 14, bottom: 8 })

        // 状态筛选胶囊：全部 / 运行中 / 待响应 / 已归档
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.filterTabs(), (tab: FilterTabItem) => {
              Row({ space: 5 }) {
                Text(tab.label)
                  .fontSize(12)
                  .fontWeight(this.statusFilter === tab.key ? FontWeight.Medium : FontWeight.Normal)
                  .fontColor(this.statusFilter === tab.key
                    ? '#FFFFFF'
                    : (tab.highlight ? '#F2D08B' : $r('app.color.tentacle_text_dim')))
                if (tab.count > 0) {
                  Text(tab.count.toString())
                    .fontSize(10.5)
                    .fontFamily('monospace')
                    .fontColor(this.statusFilter === tab.key
                      ? '#FFFFFF'
                      : (tab.highlight ? '#201B16' : $r('app.color.tentacle_text_faint')))
                    .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                    .borderRadius(999)
                    .backgroundColor(this.statusFilter === tab.key
                      ? '#33FFFFFF'
                      : (tab.highlight ? '#D4A359' : $r('app.color.tentacle_bg_hover')))
                }
              }
              .padding({ left: 11, right: 11, top: 5.5, bottom: 5.5 })
              .borderRadius(999)
              .backgroundColor(this.statusFilter === tab.key
                ? $r('app.color.tentacle_accent')
                : (tab.highlight ? '#33D4A359' : $r('app.color.tentacle_bg_elevated')))
              .border({
                width: 0.5,
                color: this.statusFilter === tab.key
                  ? $r('app.color.tentacle_accent')
                  : (tab.highlight ? '#80D4A359' : $r('app.color.tentacle_border'))
              })
              .onClick(() => {
                this.statusFilter = tab.key;
              })
            }, (tab: FilterTabItem) => tab.key + ':' + tab.count.toString() + ':' + (this.statusFilter === tab.key ? '1' : '0'))
          }
          .padding({ left: 14, right: 14 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .margin({ bottom: 8 })
      }

      Refresh({ refreshing: $$this.refreshing }) {
        Scroll() {
          Column({ space: 12 }) {
            if (this.errText.length > 0) {
              FeedbackBanner({ text: this.errText, tone: 'danger' })
            }

            this.PendingPromptsBanner()

            if (this.connecting && this.groups.length === 0 && this.pinnedEntries.length === 0) {
              AppCard() {
                Column({ space: 8 }) {
                  Text('正在唤醒并连接 Tentacle DSH 编程工作区…')
                    .fontSize(13.5)
                    .fontColor($r('app.color.tentacle_text'))
                  Text('首次启动可能需要几秒钟，请稍候。')
                    .fontSize(12)
                    .fontColor($r('app.color.tentacle_text_faint'))
                }.width('100%').alignItems(HorizontalAlign.Start)
              }
            } else if (this.statusFilter === 'archived') {
              if (this.filteredArchivedEntries().length === 0) {
                AppCard() {
                  Column({ space: 6 }) {
                    Text(this.query.trim().length > 0 ? '未找到匹配的已归档会话' : '暂无已归档会话')
                      .fontSize(14)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.tentacle_text'))
                    Text('在任意会话的「···」菜单中选择归档后，会话会收纳在此，随时可一键恢复。')
                      .fontSize(12.5)
                      .lineHeight(18)
                      .fontColor($r('app.color.tentacle_text_dim'))
                  }.width('100%').alignItems(HorizontalAlign.Start)
                }
              } else {
                AppCard() {
                  Column({ space: 8 }) {
                    Row({ space: 8 }) {
                      Text('已归档会话')
                        .fontSize(13.5)
                        .fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.tentacle_text'))
                      Text(this.filteredArchivedEntries().length.toString())
                        .fontSize(11)
                        .fontFamily('monospace')
                        .fontColor($r('app.color.tentacle_text_faint'))
                        .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                        .borderRadius(999)
                        .backgroundColor($r('app.color.tentacle_bg_hover'))
                      Blank()
                    }.width('100%')

                    Column({ space: 6 }) {
                      ForEach(this.filteredArchivedEntries(), (item: DshPinnedSessionEntry) => {
                        this.SessionItemCard(item.session, item.workspaceTitle, true, false)
                      }, (item: DshPinnedSessionEntry) => this.sessionRowKey(item.session, 'arc'))
                    }.width('100%')
                  }.width('100%').alignItems(HorizontalAlign.Start)
                }
              }
            } else if (this.filteredPinnedEntries().length === 0 && this.filteredGroups().length === 0) {
              AppCard() {
                Column({ space: 10 }) {
                  Text(this.ready
                    ? (this.statusFilter === 'running'
                      ? '当前没有运行中的会话'
                      : (this.statusFilter === 'pending' ? '当前没有等待响应的会话' : '暂无符合条件的编码会话'))
                    : '尚未连接到 DSH 服务')
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.tentacle_text'))
                  Text(this.ready
                    ? (this.statusFilter !== 'all' || this.query.trim().length > 0
                      ? '可以清空搜索词或切回「全部」查看所有工作区会话。'
                      : '点击右上角「+ 新建会话」，可在 Tentacle 工作目录下开始新的编程会话。')
                    : '请确认服务端已开启 DSH 子代理能力并下拉或点击刷新重试。')
                    .fontSize(12.5)
                    .lineHeight(18)
                    .fontColor($r('app.color.tentacle_text_dim'))
                  Row({ space: 8 }) {
                    if (this.ready && (this.statusFilter !== 'all' || this.query.trim().length > 0)) {
                      ActionButton({
                        label: '查看全部',
                        tone: 'secondary',
                        compact: true,
                        onTap: () => {
                          this.statusFilter = 'all';
                          this.onQueryChanged('');
                        }
                      })
                    } else if (this.ready) {
                      ActionButton({
                        label: '+ 新建会话',
                        tone: 'primary',
                        compact: true,
                        onTap: () => {
                          this.openNewSheet();
                        }
                      })
                    } else {
                      ActionButton({
                        label: '重新连接',
                        tone: 'primary',
                        compact: true,
                        onTap: () => {
                          this.refreshNow();
                        }
                      })
                    }
                  }
                }.width('100%').alignItems(HorizontalAlign.Start)
              }
            } else {
              // 顶部独立「置顶会话」聚合区
              if (this.filteredPinnedEntries().length > 0) {
                AppCard() {
                  Column({ space: 9 }) {
                    Row({ space: 8 }) {
                      Column()
                        .width(4)
                        .height(15)
                        .borderRadius(2)
                        .backgroundColor($r('app.color.tentacle_accent'))
                      Text('置顶会话')
                        .fontSize(13.5)
                        .fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.tentacle_text'))
                      Text(this.filteredPinnedEntries().length.toString())
                        .fontSize(11)
                        .fontFamily('monospace')
                        .fontColor($r('app.color.tentacle_accent'))
                        .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                        .borderRadius(999)
                        .backgroundColor($r('app.color.tentacle_accent_soft'))
                      Blank()
                    }.width('100%')

                    Column({ space: 6 }) {
                      ForEach(this.filteredPinnedEntries(), (item: DshPinnedSessionEntry) => {
                        this.SessionItemCard(item.session, item.workspaceTitle, false, true)
                      }, (item: DshPinnedSessionEntry) => this.sessionRowKey(item.session, 'pin'))
                    }.width('100%')
                  }.width('100%').alignItems(HorizontalAlign.Start)
                }
              }

              // 工作区分组（可折叠 / 展开 + 工作区管理）
              ForEach(this.filteredGroups(), (grp: DshWorkspaceGroup) => {
                AppCard() {
                  Column({ space: 10 }) {
                    Row({ space: 8 }) {
                      Row({ space: 8 }) {
                        Text(this.isGroupCollapsed(grp, this.filteredGroups()) ? '▸' : '▾')
                          .fontSize(12)
                          .fontColor($r('app.color.tentacle_accent'))
                          .width(12)

                        Column({ space: 2 }) {
                          Row({ space: 6 }) {
                            Text(grp.title)
                              .fontSize(14)
                              .fontWeight(FontWeight.Medium)
                              .fontColor($r('app.color.tentacle_text'))
                              .maxLines(1)
                              .textOverflow({ overflow: TextOverflow.Ellipsis })
                              .constraintSize({ maxWidth: 160 })

                            Text(grp.sessions.length.toString())
                              .fontSize(10.5)
                              .fontFamily('monospace')
                              .fontColor($r('app.color.tentacle_text_faint'))
                              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                              .borderRadius(999)
                              .backgroundColor($r('app.color.tentacle_bg_hover'))

                            if (this.groupPendingCount(grp) > 0) {
                              Text('待响应 ' + this.groupPendingCount(grp).toString())
                                .fontSize(10)
                                .fontWeight(FontWeight.Medium)
                                .fontColor('#F2D08B')
                                .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                                .borderRadius(999)
                                .backgroundColor('#33D4A359')
                            } else if (this.groupRunningCount(grp) > 0) {
                              Text('运行中 ' + this.groupRunningCount(grp).toString())
                                .fontSize(10)
                                .fontColor($r('app.color.tentacle_accent'))
                                .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                                .borderRadius(999)
                                .backgroundColor($r('app.color.tentacle_accent_soft'))
                            }
                          }

                          if (grp.path.length > 0) {
                            Text(grp.path)
                              .fontSize(10.5)
                              .fontFamily('monospace')
                              .fontColor($r('app.color.tentacle_text_faint'))
                              .maxLines(1)
                              .textOverflow({ overflow: TextOverflow.Ellipsis })
                          }
                        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                      }
                      .layoutWeight(1)
                      .onClick(() => {
                        this.toggleGroupCollapse(grp, this.filteredGroups());
                      })

                      ActionButton({
                        label: '+ 新建',
                        tone: 'ghost',
                        compact: true,
                        isEnabled: !this.actionBusy,
                        onTap: () => {
                          this.quickCreateInGroup(grp);
                        }
                      })

                      if (grp.workspaceId.length > 0) {
                        Text('···')
                          .fontSize(16)
                          .fontColor($r('app.color.tentacle_text_dim'))
                          .padding({ left: 6, right: 4, top: 4, bottom: 4 })
                          .onClick(() => {
                            this.openWorkspaceMenu(grp);
                          })
                      }
                    }.width('100%')

                    if (!this.isGroupCollapsed(grp, this.filteredGroups())) {
                      if (grp.sessions.length === 0) {
                        Text('该工作区下暂无未置顶会话')
                          .fontSize(12)
                          .fontColor($r('app.color.tentacle_text_faint'))
                          .padding({ left: 20, top: 2, bottom: 2 })
                      } else {
                        Column({ space: 6 }) {
                          ForEach(grp.sessions, (session: DshSession) => {
                            this.SessionItemCard(session, '', false, false)
                          }, (session: DshSession) => this.sessionRowKey(session, grp.key))
                        }.width('100%')
                      }
                    }
                  }.width('100%').alignItems(HorizontalAlign.Start)
                }
              }, (grp: DshWorkspaceGroup) => grp.key + ':' + grp.title + ':' + grp.sessions.length.toString()
                + ':' + (this.isGroupCollapsed(grp, this.filteredGroups()) ? '0' : '1')
                + ':' + this.groupPendingCount(grp).toString() + ':' + this.groupRunningCount(grp).toString())
            }
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 2, bottom: 24 })
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
      }
      .onRefreshing(() => {
        this.handlePullRefresh();
      })
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.tentacle_bg'))
    .bindSheet($$this.sheetOpen, this.UnifiedSheetBuilder(), {
      height: this.currentSheetHeight(),
      dragBar: true,
      backgroundColor: $r('app.color.tentacle_bg_card'),
      onDisappear: () => {
        this.activeSheet = '';
        this.renameMode = false;
        this.wsRenameMode = false;
        this.wsDeleteConfirm = false;
      }
    })
  }
}
