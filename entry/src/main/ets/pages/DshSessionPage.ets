/**
 * DSH 会话详情页（独立沉浸顶栏，支持对话 / 轨迹双视图、模型与思考强度实时切换、审批与提问卡片）
 */

import { common } from '@kit.AbilityKit';
import { LengthMetrics } from '@kit.ArkUI';
import { DshClient, DshCommandExecResult, DshQuestionAnswerPayload } from '../dsh/DshClient';
import {
  DshChoiceOption,
  DshCommandCandidate,
  DshConvEntry,
  DshModelGroup,
  DshModelOption,
  DshModelSelection,
  DshPendingAttachment,
  DshPendingPrompt,
  DshProjectedSession,
  DshQuestionSpec,
  DshQueuedItem,
  DshReferenceCandidate,
  DshTrajectoryStep,
  formatDurationCompact,
  formatModelCapsule,
  projectSessionRecords
} from '../dsh/DshModels';
import { DshComposer } from '../dsh/DshComposer';
import { DshTrajectoryView } from '../dsh/DshTrajectoryView';
import { DshModelEffortSheet, DshStepDetailSheet } from '../dsh/DshSheets';
import { pickAndEncodePhotos, pickDocuments } from '../dsh/DshMedia';
import { MarkdownBody } from '../components/MarkdownBody';
import { ActionButton, AppCard, FeedbackBanner, StatusPill } from '../components/UiKit';
import { notifyToast } from '../model/UiToast';

interface PendingDocUpload {
  tempId: string;
  name: string;
  buffer: ArrayBuffer;
}

@Entry
@Component
struct DshSessionPage {
  private client: DshClient = DshClient.getInstance();
  private scroller: Scroller = new Scroller();

  @State sessionId: string = '';
  @State viewMode: string = 'chat'; // 'chat' | 'trajectory'
  @State projected: DshProjectedSession = projectSessionRecords([]);
  @State sessionTitle: string = 'DSH 会话';
  @State modelLabel: string = '选择模型';
  @State modelGroups: DshModelGroup[] = [];
  @State flatModels: DshModelOption[] = [];
  @State currentSelection?: DshModelSelection = undefined;

  @State loading: boolean = true;
  @State running: boolean = false;
  @State hasMore: boolean = false;
  @State loadingEarlier: boolean = false;
  @State sending: boolean = false;
  @State errText: string = '';
  @State commands: DshCommandCandidate[] = [];
  @State commandsLoadState: string = 'idle';
  @State commandsError: string = '';
  @State references: DshReferenceCandidate[] = [];
  @State queuedItems: DshQueuedItem[] = [];
  @State pendingPrompts: DshPendingPrompt[] = [];
  @State attachments: DshPendingAttachment[] = [];

  @State expandedIds: Map<string, boolean> = new Map<string, boolean>();
  @State followingBottom: boolean = true;
  @State hasNewMessages: boolean = false;
  @State sheetOpen: boolean = false;
  @State activeSheet: string = ''; // 'model' | 'step' | 'meta'
  @State inspectedStep: DshTrajectoryStep | null = null;
  @State renameDraft: string = '';
  @State metaBusy: boolean = false;

  // 提问作答状态（按 promptId#qid 存储已选 label 与自由输入）
  @State questionSelections: Map<string, string[]> = new Map<string, string[]>();
  @State questionCustoms: Map<string, string> = new Map<string, string>();
  @State promptBusyId: string = '';

  private prevEntryCount: number = 0;
  private hasInitialScrolled: boolean = false;
  private touchingList: boolean = false;
  private userScrolling: boolean = false;
  private autoScrollTimer: number = -1;
  private syncCb: () => void = () => {
    this.pullState();
  };

  aboutToAppear(): void {
    const rawParams = this.getUIContext().getRouter().getParams() as Record<string, Object> | undefined;
    const sid = rawParams && typeof rawParams['sessionId'] === 'string' ? rawParams['sessionId'] as string : '';
    this.sessionId = sid;
    this.client.subscribe(this.syncCb);
    this.pullState();
    if (sid.length > 0) {
      this.client.openSession(sid).catch(() => {});
    }
  }

  aboutToDisappear(): void {
    if (this.autoScrollTimer >= 0) {
      clearTimeout(this.autoScrollTimer);
      this.autoScrollTimer = -1;
    }
    this.client.unsubscribe(this.syncCb);
    this.client.closeSession();
  }

  private pauseFollowing(): void {
    this.followingBottom = false;
    if (this.autoScrollTimer >= 0) {
      clearTimeout(this.autoScrollTimer);
      this.autoScrollTimer = -1;
    }
  }

  private scheduleScrollToBottom(immediate: boolean = false): void {
    if (this.autoScrollTimer >= 0) {
      clearTimeout(this.autoScrollTimer);
    }
    this.autoScrollTimer = setTimeout(() => {
      this.autoScrollTimer = -1;
      if (this.viewMode === 'chat' && this.followingBottom && !this.touchingList && !this.userScrolling) {
        this.hasInitialScrolled = true;
        this.hasNewMessages = false;
        this.scroller.scrollEdge(Edge.Bottom);
      }
    }, immediate ? 0 : 40);
  }

  private openSheet(mode: string): void {
    this.activeSheet = mode;
    this.sheetOpen = true;
  }

  private closeSheet(): void {
    this.sheetOpen = false;
  }

  private currentSheetHeight(): number | SheetSize {
    if (this.activeSheet === 'meta') {
      return 260;
    }
    if (this.activeSheet === 'step') {
      return SheetSize.MEDIUM;
    }
    return SheetSize.LARGE;
  }

  private pullState(): void {
    this.projected = this.client.projected;
    this.loading = this.client.activeSessionLoading;
    this.running = this.client.activeSessionRunning;
    this.hasMore = this.client.activeHasMore;
    this.errText = this.client.lastError;
    this.commands = this.client.activeCommands;
    this.commandsLoadState = this.client.commandsLoadState;
    this.commandsError = this.client.commandsError;
    this.references = this.client.activeReferences;
    this.queuedItems = this.client.activeQueued;
    this.pendingPrompts = this.client.getPromptsForSession(this.sessionId);
    this.modelGroups = this.client.modelCatalog.groups;
    this.flatModels = this.client.modelCatalog.flatModels;

    const sel = this.client.getActiveModelSelection(this.sessionId);
    this.currentSelection = sel;
    this.modelLabel = formatModelCapsule(sel, this.flatModels);

    const summary = this.client.getSessionSummary(this.sessionId);
    if (this.projected.hasTitle) {
      this.sessionTitle = this.projected.title;
    } else if (summary !== undefined) {
      this.sessionTitle = summary.title;
    }

    const nextCount = this.projected.conversation.length;
    const countChanged = nextCount !== this.prevEntryCount;
    const countGrew = nextCount > this.prevEntryCount;
    this.prevEntryCount = nextCount;

    if (nextCount === 0) {
      return;
    }
    if (this.followingBottom) {
      if (!this.touchingList && !this.userScrolling && this.viewMode === 'chat'
        && (!this.hasInitialScrolled || countChanged || this.running)) {
        this.scheduleScrollToBottom();
      }
    } else if (countGrew) {
      this.hasNewMessages = true;
    }
  }

  private isExpanded(id: string): boolean {
    return this.expandedIds.get(id) === true;
  }

  private toggleExpanded(id: string): void {
    const next = new Map<string, boolean>();
    this.expandedIds.forEach((v: boolean, k: string) => next.set(k, v));
    next.set(id, !this.isExpanded(id));
    this.expandedIds = next;
  }

  private async handleLoadEarlier(): Promise<void> {
    if (this.loadingEarlier) {
      return;
    }
    this.pauseFollowing();
    this.loadingEarlier = true;
    try {
      await this.client.loadEarlierMessages();
    } catch (e) {
      notifyToast('加载更早记录失败：' + (e as Error).message, 'danger');
    } finally {
      this.loadingEarlier = false;
    }
  }

  private async handleSend(text: string, mode: string): Promise<void> {
    if (this.sending || this.sessionId.length === 0) {
      return;
    }
    const snapshotAtts = this.attachments.slice();
    this.sending = true;
    this.touchingList = false;
    this.userScrolling = false;
    this.followingBottom = true;
    this.hasNewMessages = false;
    try {
      await this.client.sendPrompt(this.sessionId, text, snapshotAtts, mode);
      this.attachments = [];
      this.scheduleScrollToBottom(true);
    } catch (e) {
      notifyToast('发送失败：' + (e as Error).message, 'danger');
    } finally {
      this.sending = false;
    }
  }

  private async handleExecuteCommand(line: string): Promise<void> {
    if (this.sending || this.sessionId.length === 0) {
      return;
    }
    const snapshotAtts = this.attachments.slice();
    this.sending = true;
    this.touchingList = false;
    this.userScrolling = false;
    this.followingBottom = true;
    try {
      const res: DshCommandExecResult = await this.client.executeCommand(this.sessionId, line, snapshotAtts);
      if (!res.matched) {
        notifyToast('未匹配斜杠指令：' + line.split(' ')[0], 'warn');
        return;
      }
      this.attachments = [];
      if (res.kind === 'error') {
        notifyToast(res.text.length > 0 ? res.text : ('命令执行失败：' + line.split(' ')[0]), 'danger');
      } else {
        notifyToast(res.text.length > 0 ? res.text : ('已执行 ' + line.split(' ')[0]), 'ok');
      }
      this.scheduleScrollToBottom(true);
    } catch (e) {
      notifyToast('命令执行失败：' + (e as Error).message, 'danger');
    } finally {
      this.sending = false;
    }
  }

  private async handlePickPhoto(): Promise<void> {
    const maxAllowed = Math.max(1, this.projected.maxImagesPerMessage);
    const remain = maxAllowed - this.attachments.length;
    if (remain <= 0) {
      notifyToast('已达到单轮附件数量上限', 'warn');
      return;
    }
    try {
      const ctx = this.getUIContext().getHostContext() as common.Context;
      const picked = await pickAndEncodePhotos(ctx, remain, this.projected.maxImageBytes);
      if (picked.length === 0) {
        return;
      }
      const next = this.attachments.slice();
      for (let i = 0; i < picked.length; i++) {
        next.push({
          id: 'img-' + Date.now().toString() + '-' + i.toString(),
          name: picked[i].name,
          isImage: true,
          mediaType: picked[i].mediaType,
          dataBase64: picked[i].base64,
          receiptId: '',
          bytes: picked[i].bytes,
          uploading: false,
          error: ''
        });
      }
      this.attachments = next;
    } catch (e) {
      notifyToast('读取图片失败：' + (e as Error).message, 'danger');
    }
  }

  private async uploadDocAttachment(sessionId: string, tempId: string, name: string, buf: ArrayBuffer): Promise<void> {
    try {
      const uploaded = await this.client.uploadFileBytes(sessionId, buf, name);
      this.patchAttachment(tempId, uploaded.receiptId, uploaded.name || name, '');
    } catch (uploadErr) {
      this.patchAttachment(tempId, '', name, (uploadErr as Error).message);
    }
  }

  private async handlePickFile(): Promise<void> {
    const sid = this.sessionId;
    if (sid.length === 0) {
      return;
    }
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const docs = await pickDocuments(ctx, 5);
      if (docs.length === 0) {
        return;
      }
      const next = this.attachments.slice();
      const pendingUploads: PendingDocUpload[] = [];
      for (let i = 0; i < docs.length; i++) {
        const d = docs[i];
        const tempId = 'file-' + Date.now().toString() + '-' + i.toString();
        next.push({
          id: tempId,
          name: d.name,
          isImage: false,
          mediaType: 'application/octet-stream',
          dataBase64: '',
          receiptId: '',
          bytes: d.bytes,
          uploading: true,
          error: ''
        });
        const uploadEntry: PendingDocUpload = { tempId: tempId, name: d.name, buffer: d.buffer };
        pendingUploads.push(uploadEntry);
      }
      this.attachments = next;
      for (let i = 0; i < pendingUploads.length; i++) {
        const u = pendingUploads[i];
        await this.uploadDocAttachment(sid, u.tempId, u.name, u.buffer);
      }
    } catch (e) {
      notifyToast('读取文件失败：' + (e as Error).message, 'danger');
    }
  }

  private patchAttachment(id: string, receiptId: string, name: string, errMsg: string): void {
    const next: DshPendingAttachment[] = [];
    for (let i = 0; i < this.attachments.length; i++) {
      const cur = this.attachments[i];
      if (cur.id === id) {
        next.push({
          id: cur.id,
          name: name,
          isImage: cur.isImage,
          mediaType: cur.mediaType,
          dataBase64: cur.dataBase64,
          receiptId: receiptId,
          bytes: cur.bytes,
          uploading: false,
          error: errMsg
        });
      } else {
        next.push(cur);
      }
    }
    this.attachments = next;
  }

  private qKey(promptId: string, qid: string): string {
    return promptId + '#' + qid;
  }

  private isOptionSelected(promptId: string, qid: string, label: string): boolean {
    const list = this.questionSelections.get(this.qKey(promptId, qid));
    return list !== undefined && list.indexOf(label) >= 0;
  }

  private toggleQuestionOption(promptId: string, q: DshQuestionSpec, label: string): void {
    const key = this.qKey(promptId, q.id);
    const prev = this.questionSelections.get(key) ?? [];
    let nextVals: string[] = [];
    if (q.multiSelect) {
      if (prev.indexOf(label) >= 0) {
        nextVals = prev.filter((item: string) => item !== label);
      } else {
        nextVals = prev.concat([label]);
      }
    } else {
      nextVals = prev.indexOf(label) >= 0 ? [] : [label];
    }
    const nextMap = new Map<string, string[]>();
    this.questionSelections.forEach((v: string[], k: string) => nextMap.set(k, v));
    nextMap.set(key, nextVals);
    this.questionSelections = nextMap;
  }

  private setQuestionCustom(promptId: string, qid: string, val: string): void {
    const key = this.qKey(promptId, qid);
    const nextMap = new Map<string, string>();
    this.questionCustoms.forEach((v: string, k: string) => nextMap.set(k, v));
    nextMap.set(key, val);
    this.questionCustoms = nextMap;
  }

  private async submitQuestions(prompt: DshPendingPrompt): Promise<void> {
    if (this.promptBusyId.length > 0) {
      return;
    }
    this.promptBusyId = prompt.eventId;
    try {
      const answers: DshQuestionAnswerPayload[] = [];
      for (let i = 0; i < prompt.questions.length; i++) {
        const q = prompt.questions[i];
        const key = this.qKey(prompt.eventId, q.id);
        const sel = this.questionSelections.get(key) ?? [];
        const custom = this.questionCustoms.get(key) ?? '';
        answers.push({ id: q.id, selected: sel, custom: custom });
      }
      await this.client.answerQuestions(prompt, answers);
      notifyToast('已提交回答', 'ok');
    } catch (e) {
      notifyToast('提交失败：' + (e as Error).message, 'danger');
    } finally {
      this.promptBusyId = '';
    }
  }

  @Builder
  TopBar() {
    Row({ space: 8 }) {
      Row() {
        Text('‹')
          .fontSize(22)
          .fontColor($r('app.color.tentacle_text'))
      }
      .width(34)
      .height(34)
      .borderRadius(17)
      .backgroundColor($r('app.color.tentacle_bg_hover'))
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.getUIContext().getRouter().back();
      })

      Text(this.sessionTitle)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.tentacle_text'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .onClick(() => {
          this.renameDraft = this.sessionTitle;
          this.openSheet('meta');
        })

      // 交互式 模型 · 思考强度 胶囊
      Row({ space: 4 }) {
        Text(this.modelLabel)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.tentacle_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 108 })
        Text('▾')
          .fontSize(10)
          .fontColor($r('app.color.tentacle_accent'))
      }
      .padding({ left: 9, right: 8, top: 5, bottom: 5 })
      .borderRadius(999)
      .backgroundColor($r('app.color.tentacle_bg_hover'))
      .border({ width: 0.75, color: $r('app.color.tentacle_border_strong') })
      .onClick(() => {
        if (this.modelGroups.length === 0) {
          this.client.refreshModelCatalog();
        }
        this.openSheet('model');
      })

      // 对话 | 轨迹 切换
      Row({ space: 2 }) {
        Text('对话')
          .fontSize(11.5)
          .fontWeight(this.viewMode === 'chat' ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.viewMode === 'chat' ? '#FFFFFF' : $r('app.color.tentacle_text_dim'))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .borderRadius(999)
          .backgroundColor(this.viewMode === 'chat' ? $r('app.color.tentacle_accent') : Color.Transparent)
          .onClick(() => {
            this.viewMode = 'chat';
          })

        Text('轨迹')
          .fontSize(11.5)
          .fontWeight(this.viewMode === 'trajectory' ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.viewMode === 'trajectory' ? '#FFFFFF' : $r('app.color.tentacle_text_dim'))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .borderRadius(999)
          .backgroundColor(this.viewMode === 'trajectory' ? $r('app.color.tentacle_accent') : Color.Transparent)
          .onClick(() => {
            this.viewMode = 'trajectory';
          })
      }
      .padding(2)
      .borderRadius(999)
      .backgroundColor($r('app.color.tentacle_bg_elevated'))
      .border({ width: 0.5, color: $r('app.color.tentacle_border') })
    }
    .width('100%')
    .height(54)
    .padding({ left: 12, right: 12 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor($r('app.color.tentacle_bg'))
    .border({ width: { bottom: 0.5 }, color: $r('app.color.tentacle_border') })
  }

  @Builder
  ConvEntryView(entry: DshConvEntry) {
    if (entry.kind === 'user') {
      Row() {
        Blank()
        Column({ space: 6 }) {
          if (entry.text.length > 0) {
            Text(entry.text)
              .fontSize(14.5)
              .lineHeight(21)
              .fontColor($r('app.color.tentacle_text'))
              .copyOption(CopyOptions.LocalDevice)
          }
          if (entry.attachmentLabels.length > 0) {
            Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(6), cross: LengthMetrics.vp(6) } }) {
              ForEach(entry.attachmentLabels, (lbl: string, idx: number) => {
                Text('📎 ' + lbl)
                  .fontSize(11)
                  .fontColor($r('app.color.tentacle_text_dim'))
                  .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                  .borderRadius(8)
                  .backgroundColor('#26FFFFFF')
              }, (lbl: string, idx: number) => idx.toString() + ':' + lbl)
            }
          }
        }
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .borderRadius({ topLeft: 18, topRight: 6, bottomLeft: 18, bottomRight: 18 })
        .backgroundColor($r('app.color.tentacle_user_bubble'))
        .constraintSize({ maxWidth: '86%' })
      }.width('100%')
    } else if (entry.kind === 'reasoning') {
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Column().width(6).height(6).borderRadius(3).backgroundColor('#D4A359')
          Text(entry.streaming ? '正在思考…' : '思考过程')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor('#D4A359')
          Blank()
          Text(this.isExpanded(entry.id) || entry.streaming ? '收起 ▴' : '展开 ▾')
            .fontSize(11)
            .fontColor($r('app.color.tentacle_text_faint'))
        }
        .width('100%')
        .onClick(() => this.toggleExpanded(entry.id))

        if (this.isExpanded(entry.id) || entry.streaming) {
          Text(entry.text)
            .fontSize(12.5)
            .lineHeight(19)
            .fontColor($r('app.color.tentacle_text_dim'))
            .width('100%')
            .copyOption(CopyOptions.LocalDevice)
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .borderRadius(12)
      .backgroundColor($r('app.color.tentacle_bg_input'))
      .border({ width: 0.5, color: $r('app.color.tentacle_border') })
    } else if (entry.kind === 'tool') {
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Column()
            .width(6)
            .height(6)
            .borderRadius(3)
            .backgroundColor(entry.toolState === 'failed'
              ? $r('app.color.tentacle_danger')
              : (entry.toolState === 'running' ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_ok')))

          Text(entry.toolName)
            .fontSize(12.5)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.tentacle_text'))

          if (entry.detail.length > 0) {
            Text(entry.detail)
              .fontSize(11.5)
              .fontFamily('monospace')
              .fontColor($r('app.color.tentacle_text_faint'))
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          } else {
            Blank()
          }

          Text(entry.toolState === 'running'
            ? '执行中'
            : (entry.toolState === 'failed'
              ? '失败'
              : (entry.durationMs > 0 ? formatDurationCompact(entry.durationMs) : '完成')))
            .fontSize(10.5)
            .fontFamily('monospace')
            .fontColor(entry.toolState === 'failed'
              ? $r('app.color.tentacle_danger')
              : (entry.toolState === 'running' ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_ok')))

          Text(this.isExpanded(entry.id) ? '▴' : '▾')
            .fontSize(11)
            .fontColor($r('app.color.tentacle_text_faint'))
        }
        .width('100%')
        .onClick(() => this.toggleExpanded(entry.id))

        if (this.isExpanded(entry.id)) {
          if (entry.toolArgs.length > 0) {
            Text('参数：' + entry.toolArgs)
              .fontSize(11.5)
              .fontFamily('monospace')
              .lineHeight(17)
              .fontColor($r('app.color.tentacle_text_dim'))
              .width('100%')
              .padding(8)
              .borderRadius(8)
              .backgroundColor($r('app.color.tentacle_bg'))
              .copyOption(CopyOptions.LocalDevice)
          }
          if (entry.toolOutput.length > 0) {
            Text(entry.toolOutput.length > 3500 ? entry.toolOutput.substring(0, 3500) + '\n…(已截断)' : entry.toolOutput)
              .fontSize(11.5)
              .fontFamily('monospace')
              .lineHeight(17)
              .fontColor(entry.toolState === 'failed' ? $r('app.color.tentacle_danger') : $r('app.color.tentacle_text_dim'))
              .width('100%')
              .padding(8)
              .borderRadius(8)
              .backgroundColor($r('app.color.tentacle_bg'))
              .copyOption(CopyOptions.LocalDevice)
          }
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .borderRadius(12)
      .backgroundColor($r('app.color.tentacle_bg_hover'))
      .border({ width: 0.5, color: $r('app.color.tentacle_border') })
    } else if (entry.kind === 'assistant') {
      Column({ space: 6 }) {
        MarkdownBody({ content: entry.text })
        if (entry.model.length > 0 || entry.streaming) {
          Row({ space: 6 }) {
            if (entry.streaming) {
              Text('输出中…').fontSize(10.5).fontColor($r('app.color.tentacle_accent'))
            } else if (entry.model.length > 0) {
              Text(entry.model + (entry.durationMs > 0 ? (' · ' + formatDurationCompact(entry.durationMs)) : ''))
                .fontSize(10.5)
                .fontFamily('monospace')
                .fontColor($r('app.color.tentacle_text_faint'))
            }
          }.width('100%')
        }
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: 12 })
      .borderRadius({ topLeft: 6, topRight: 18, bottomLeft: 18, bottomRight: 18 })
      .backgroundColor($r('app.color.tentacle_bg_card'))
      .border({ width: 0.5, color: $r('app.color.tentacle_agent_border') })
    } else if (entry.kind === 'status') {
      Column({ space: 4 }) {
        Text(entry.title)
          .fontSize(12.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.tentacle_text_dim'))
        if (entry.detail.length > 0) {
          Text(entry.detail)
            .fontSize(12)
            .lineHeight(18)
            .fontColor($r('app.color.tentacle_text_faint'))
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .borderRadius(10)
      .backgroundColor($r('app.color.tentacle_bg_input'))
      .border({ width: 0.5, color: $r('app.color.tentacle_border') })
      .alignItems(HorizontalAlign.Start)
    } else if (entry.kind === 'error') {
      FeedbackBanner({
        text: entry.title + (entry.text.length > 0 ? (' · ' + entry.text) : ''),
        tone: 'danger'
      })
    }
  }

  @Builder
  PendingPromptsDock() {
    if (this.pendingPrompts.length > 0) {
      Column({ space: 8 }) {
        ForEach(this.pendingPrompts, (prompt: DshPendingPrompt) => {
          AppCard() {
            Column({ space: 10 }) {
              if (prompt.kind === 'approval') {
                Row({ space: 8 }) {
                  StatusPill({ label: '等待授权', tone: 'warn' })
                  Text(prompt.toolName)
                    .fontSize(13.5)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.tentacle_text'))
                    .layoutWeight(1)
                }.width('100%')

                if (prompt.reason.length > 0) {
                  Text(prompt.reason)
                    .fontSize(12.5)
                    .lineHeight(18)
                    .fontColor($r('app.color.tentacle_text_dim'))
                    .width('100%')
                }
                Row({ space: 10 }) {
                  ActionButton({
                    label: '拒绝',
                    tone: 'danger',
                    compact: true,
                    isEnabled: this.promptBusyId.length === 0,
                    onTap: () => {
                      this.promptBusyId = prompt.eventId;
                      this.client.answerApproval(prompt, false)
                        .catch((e: Error) => notifyToast('操作失败：' + e.message, 'danger'))
                        .finally(() => { this.promptBusyId = ''; });
                    }
                  })
                  ActionButton({
                    label: '允许这一次',
                    tone: 'primary',
                    compact: true,
                    isEnabled: this.promptBusyId.length === 0,
                    onTap: () => {
                      this.promptBusyId = prompt.eventId;
                      this.client.answerApproval(prompt, true)
                        .catch((e: Error) => notifyToast('操作失败：' + e.message, 'danger'))
                        .finally(() => { this.promptBusyId = ''; });
                    }
                  })
                }.width('100%').justifyContent(FlexAlign.End)
              } else {
                Row({ space: 8 }) {
                  StatusPill({ label: 'Agent 提问', tone: 'accent' })
                  Text(prompt.title)
                    .fontSize(13.5)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.tentacle_text'))
                    .layoutWeight(1)
                }.width('100%')

                ForEach(prompt.questions, (q: DshQuestionSpec) => {
                  Column({ space: 6 }) {
                    Text(q.question)
                      .fontSize(13)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.tentacle_text'))
                      .width('100%')
                    if (q.detail.length > 0) {
                      Text(q.detail)
                        .fontSize(12)
                        .lineHeight(17)
                        .fontColor($r('app.color.tentacle_text_dim'))
                        .width('100%')
                    }
                    if (q.options.length > 0) {
                      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(6), cross: LengthMetrics.vp(6) } }) {
                        ForEach(q.options, (opt: DshChoiceOption) => {
                          Text(opt.label)
                            .fontSize(12)
                            .fontWeight(this.isOptionSelected(prompt.eventId, q.id, opt.label) ? FontWeight.Medium : FontWeight.Normal)
                            .fontColor(this.isOptionSelected(prompt.eventId, q.id, opt.label) ? '#FFFFFF' : $r('app.color.tentacle_text'))
                            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                            .borderRadius(999)
                            .backgroundColor(this.isOptionSelected(prompt.eventId, q.id, opt.label)
                              ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_bg_hover'))
                            .border({
                              width: 0.75,
                              color: this.isOptionSelected(prompt.eventId, q.id, opt.label)
                                ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_border')
                            })
                            .onClick(() => this.toggleQuestionOption(prompt.eventId, q, opt.label))
                        }, (opt: DshChoiceOption) => opt.label)
                      }.width('100%')
                    }
                    TextInput({
                      text: this.questionCustoms.get(this.qKey(prompt.eventId, q.id)) ?? '',
                      placeholder: '可填写补充说明…'
                    })
                      .height(36)
                      .fontSize(12.5)
                      .fontColor($r('app.color.tentacle_text'))
                      .placeholderColor($r('app.color.tentacle_text_faint'))
                      .backgroundColor($r('app.color.tentacle_bg_input'))
                      .borderRadius(8)
                      .onChange((v: string) => this.setQuestionCustom(prompt.eventId, q.id, v))
                  }.width('100%').alignItems(HorizontalAlign.Start)
                }, (q: DshQuestionSpec) => q.id)

                Row({ space: 10 }) {
                  ActionButton({
                    label: '取消',
                    tone: 'ghost',
                    compact: true,
                    isEnabled: this.promptBusyId.length === 0,
                    onTap: () => {
                      this.promptBusyId = prompt.eventId;
                      this.client.rejectQuestion(prompt)
                        .catch((e: Error) => notifyToast('取消失败：' + e.message, 'danger'))
                        .finally(() => { this.promptBusyId = ''; });
                    }
                  })
                  ActionButton({
                    label: '提交回答',
                    tone: 'primary',
                    compact: true,
                    isEnabled: this.promptBusyId.length === 0,
                    onTap: () => {
                      this.submitQuestions(prompt);
                    }
                  })
                }.width('100%').justifyContent(FlexAlign.End)
              }
            }.width('100%').alignItems(HorizontalAlign.Start)
          }
        }, (prompt: DshPendingPrompt) => prompt.eventId)
      }
      .width('100%')
      .padding({ left: 10, right: 10, bottom: 4 })
    }
  }

  @Builder
  UnifiedSheetBuilder() {
    Column() {
      if (this.activeSheet === 'model') {
        this.ModelSheetBuilder()
      } else if (this.activeSheet === 'step') {
        this.StepSheetBuilder()
      } else if (this.activeSheet === 'meta') {
        this.MetaSheetBuilder()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.tentacle_bg_card'))
  }

  @Builder
  ModelSheetBuilder() {
    DshModelEffortSheet({
      groups: this.modelGroups,
      currentSelection: this.currentSelection,
      onApply: async (provider: string, modelId: string, effort: string): Promise<void> => {
        await this.client.selectModel(this.sessionId, provider, modelId, effort);
        notifyToast('已切换模型：' + modelId + (effort.length > 0 ? (' · ' + effort) : ''), 'ok');
      },
      onClose: () => {
        this.closeSheet();
      }
    })
  }

  @Builder
  StepSheetBuilder() {
    DshStepDetailSheet({
      step: this.inspectedStep,
      onClose: () => {
        this.closeSheet();
      }
    })
  }

  @Builder
  MetaSheetBuilder() {
    Column({ space: 12 }) {
      Row() {
        Text('会话操作')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.tentacle_text'))
          .layoutWeight(1)
        Text('关闭')
          .fontSize(13)
          .fontColor($r('app.color.tentacle_text_dim'))
          .padding(8)
          .onClick(() => {
            this.closeSheet();
          })
      }.width('100%')

      TextInput({ text: this.renameDraft, placeholder: '会话标题…' })
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
          label: this.metaBusy ? '创建分支…' : 'Fork 新分支',
          tone: 'secondary',
          isEnabled: !this.metaBusy,
          onTap: async () => {
            if (this.metaBusy) {
              return;
            }
            this.metaBusy = true;
            try {
              const forked = await this.client.forkSession(this.sessionId);
              this.closeSheet();
              this.sessionId = forked;
              await this.client.openSession(forked);
              notifyToast('已切换到分支会话', 'ok');
            } catch (e) {
              notifyToast('Fork 失败：' + (e as Error).message, 'danger');
            } finally {
              this.metaBusy = false;
            }
          }
        })
        ActionButton({
          label: '保存标题',
          tone: 'primary',
          isEnabled: !this.metaBusy && this.renameDraft.trim().length > 0,
          onTap: async () => {
            if (this.metaBusy) {
              return;
            }
            this.metaBusy = true;
            try {
              await this.client.renameSession(this.sessionId, this.renameDraft.trim());
              this.closeSheet();
              notifyToast('标题已更新', 'ok');
            } catch (e) {
              notifyToast('重命名失败：' + (e as Error).message, 'danger');
            } finally {
              this.metaBusy = false;
            }
          }
        })
      }.width('100%').justifyContent(FlexAlign.End)
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 10, bottom: 24 })
    .backgroundColor($r('app.color.tentacle_bg_card'))
  }

  build() {
    Column() {
      this.TopBar()

      if (this.errText.length > 0) {
        Column() {
          FeedbackBanner({ text: this.errText, tone: 'danger' })
        }.width('100%').padding({ left: 12, right: 12, top: 8 })
      }

      // 对话视图与轨迹视图常驻渲染并通过 Visibility 切换，保留对话列表滚动位置与输入框草稿
      Stack() {
        Column() {
          Stack({ alignContent: Alignment.Bottom }) {
            List({ space: 10, scroller: this.scroller }) {
              if (this.hasMore) {
                ListItem() {
                  Row() {
                    ActionButton({
                      label: this.loadingEarlier ? '加载中…' : '加载更早消息',
                      tone: 'ghost',
                      compact: true,
                      isEnabled: !this.loadingEarlier,
                      onTap: () => {
                        this.handleLoadEarlier();
                      }
                    })
                  }.width('100%').justifyContent(FlexAlign.Center).padding({ top: 6 })
                }
              }

              if (this.loading && this.projected.conversation.length === 0) {
                ListItem() {
                  Text('正在同步会话轨迹…')
                    .fontSize(13)
                    .fontColor($r('app.color.tentacle_text_faint'))
                    .width('100%')
                    .textAlign(TextAlign.Center)
                    .padding(36)
                }
              } else if (this.projected.conversation.length === 0) {
                ListItem() {
                  Text('发送第一条指令开始编码协作')
                    .fontSize(13.5)
                    .fontColor($r('app.color.tentacle_text_faint'))
                    .width('100%')
                    .textAlign(TextAlign.Center)
                    .padding(44)
                }
              } else {
                ForEach(this.projected.conversation, (entry: DshConvEntry) => {
                  ListItem() {
                    this.ConvEntryView(entry)
                  }
                }, (entry: DshConvEntry) => entry.id)
              }
            }
            .width('100%')
            .height('100%')
            .padding({ left: 12, right: 12, top: 8, bottom: 16 })
            .scrollBar(BarState.Off)
            .onWillScroll((offset: number, _state: ScrollState, source: ScrollSource) => {
              if (offset !== 0 && (source === ScrollSource.DRAG || source === ScrollSource.FLING ||
                source === ScrollSource.OTHER_USER_INPUT || source === ScrollSource.SCROLL_BAR ||
                source === ScrollSource.SCROLL_BAR_FLING)) {
                this.userScrolling = true;
                if (offset < 0) {
                  this.pauseFollowing();
                }
              }
            })
            .onDidScroll(() => {
              if (this.viewMode === 'chat' && !this.touchingList && !this.userScrolling && this.scroller.isAtEnd()) {
                this.followingBottom = true;
                this.hasNewMessages = false;
              }
            })
            .onScrollStop(() => {
              this.userScrolling = false;
              if (this.viewMode === 'chat' && !this.touchingList && this.scroller.isAtEnd()) {
                this.followingBottom = true;
                this.hasNewMessages = false;
              }
            })
            .onTouch((ev: TouchEvent) => {
              if (ev.type === TouchType.Down) {
                this.touchingList = true;
                if (this.autoScrollTimer >= 0) {
                  clearTimeout(this.autoScrollTimer);
                  this.autoScrollTimer = -1;
                }
              } else if (ev.type === TouchType.Up || ev.type === TouchType.Cancel) {
                this.touchingList = false;
                if (!this.userScrolling && this.viewMode === 'chat' && this.scroller.isAtEnd()) {
                  this.followingBottom = true;
                  this.hasNewMessages = false;
                }
              }
            })

            if (!this.followingBottom && this.projected.conversation.length > 0) {
              Text(this.hasNewMessages ? '有新消息 ↓' : '回到底部 ↓')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.hasNewMessages ? '#FFFFFF' : $r('app.color.tentacle_text'))
                .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                .borderRadius(999)
                .backgroundColor(this.hasNewMessages ? $r('app.color.tentacle_accent') : '#E62B241C')
                .border({ width: 0.75, color: this.hasNewMessages ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_border_strong') })
                .margin({ bottom: 12 })
                .onClick(() => {
                  this.touchingList = false;
                  this.userScrolling = false;
                  this.followingBottom = true;
                  this.hasNewMessages = false;
                  this.scroller.scrollEdge(Edge.Bottom);
                })
            }
          }
          .width('100%')
          .layoutWeight(1)

          this.PendingPromptsDock()

          DshComposer({
            running: this.running,
            sending: this.sending,
            commands: this.commands,
            commandsLoadState: this.commandsLoadState,
            commandsError: this.commandsError,
            references: this.references,
            queuedItems: this.queuedItems,
            attachments: this.attachments,
            onSend: (text: string, mode: string) => {
              this.handleSend(text, mode);
            },
            onExecuteCommand: (line: string) => {
              this.handleExecuteCommand(line);
            },
            onRefreshCommands: () => {
              this.client.refreshCommands(this.sessionId);
            },
            onCancel: () => {
              this.client.cancelTurn(this.sessionId)
                .catch((e: Error) => notifyToast('停止失败：' + e.message, 'danger'));
            },
            onUpdateQueue: (itemId: string, action: string) => {
              this.client.updateQueueItem(this.sessionId, itemId, action)
                .catch((e: Error) => notifyToast('更新队列失败：' + e.message, 'danger'));
            },
            onRemoveAttachment: (id: string) => {
              this.attachments = this.attachments.filter((a: DshPendingAttachment) => a.id !== id);
            },
            onPickPhoto: () => {
              this.handlePickPhoto();
            },
            onPickFile: () => {
              this.handlePickFile();
            },
            onQueryRefs: (query: string) => {
              this.client.queryReferences(this.sessionId, query).then((refs: DshReferenceCandidate[]) => {
                this.references = refs;
              }).catch(() => {});
            }
          })
        }
        .width('100%')
        .height('100%')
        .visibility(this.viewMode === 'chat' ? Visibility.Visible : Visibility.None)

        Column() {
          DshTrajectoryView({
            turns: this.projected.turns,
            stats: this.projected.stats,
            onSelectStep: (step: DshTrajectoryStep) => {
              this.inspectedStep = step;
              this.openSheet('step');
            }
          })
        }
        .width('100%')
        .height('100%')
        .visibility(this.viewMode === 'trajectory' ? Visibility.Visible : Visibility.None)
      }
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
      }
    })
  }
}
