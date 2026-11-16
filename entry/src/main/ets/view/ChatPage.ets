/**
 * 聊天页
 *
 * 布局：消息列表与输入 dock 纵向占位，Stack 只承载图片预览浮层。
 * 气泡：用户侧渐变暖棕 + 右下收角；agent 侧卡片面 + 左上收角。
 */

import {
  ChatStore,
  ChatRow,
  MsgGroup,
  Bubble,
  WsEvent,
  chatStore,
  ChatDraft,
  chatDraft,
  MsgImage,
  PendingImage,
  UserMsg,
  SendResult,
  ApiFailure,
  FileRecord,
  ChatStopTarget,
} from '../model/Types';
import { TentacleApi } from '../service/TentacleApi';
import { PhoneIntegration } from '../service/PhoneIntegration';
import { ChatCommand, CommandCatalog, matchChatCommands } from '../model/ChatCommands';
import { estimateWrappedLines } from '../model/ConfigurationNavigation';
import { historyRows } from '../model/ChatHistory';
import { AgentGroupItem } from '../components/AgentGroupItem';
import { ActionButton, DotTyping, FeedbackBanner, enterFade } from '../components/UiKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { FileDownload } from '../components/FileDownload';
import { MediaAttachment } from '../components/MediaAttachment';
import { isImage, visibleUserText } from '../model/FileMarkers';
import { BusinessError } from '@kit.BasicServicesKit';
import { dataSharePredicates } from '@kit.ArkData';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KeyCode } from '@kit.InputKit';
import { common } from '@kit.AbilityKit';

const MAX_PENDING_IMAGES = 10;
const MAX_IMAGE_BYTES = 20 * 1024 * 1024;
const MAX_DECODE_EDGE = 2048;

function guessImageMime(uri: string): string {
  const lower = uri.toLowerCase();
  if (lower.endsWith('.png')) {
    return 'image/png';
  }
  if (lower.endsWith('.gif')) {
    return 'image/gif';
  }
  if (lower.endsWith('.webp')) {
    return 'image/webp';
  }
  return 'image/jpeg';
}

function baseNameOf(uri: string): string {
  let s = uri;
  const q = s.indexOf('?');
  if (q >= 0) {
    s = s.substring(0, q);
  }
  const slash = s.lastIndexOf('/');
  if (slash >= 0) {
    s = s.substring(slash + 1);
  }
  if (s.length === 0) {
    s = 'photo';
  }
  return s;
}

function errMsg(e: Object): string {
  const be = e as BusinessError;
  if (typeof be.message === 'string' && be.message.length > 0) {
    const withCode: string = typeof be.code === 'number' ? be.message + '(' + be.code.toString() + ')' : be.message;
    return withCode;
  }
  return String(e);
}

@Component
export struct ChatPage {
  @State store: ChatStore = chatStore;
  @State @Watch('loadDraftImages') draft: ChatDraft = chatDraft;
  @State previewUrl: string = '';
  @State commandMatches: ChatCommand[] = [];
  @State commandCatalog: ChatCommand[] = [];
  @State commandActiveIndex: number = 0;
  @State inputFocused: boolean = false;
  @State historyError: string = '';
  @State followingLatest: boolean = true;
  @State hasNewMessages: boolean = false;
  @State fileLibraryOpen: boolean = false;
  @State attachmentSheetOpen: boolean = false;
  @State fileLibrary: FileRecord[] = [];
  @State fileLibrarySearch: string = '';
  @State fileLibraryBusy: boolean = false;
  private fileLibrarySeq: number = 0;
  private historyPending: boolean = false;
  private touchingList: boolean = false;
  private userScrolling: boolean = false;
  private followRequested: boolean = false;
  private inputController: TextAreaController = new TextAreaController();
  private commandScroller: Scroller = new Scroller();
  private composing: boolean = false;
  private inputBlurTimer: number = -1;
  private historyLoadSeq: number = 0;
  private scrollTimer: number = -1;
  private pageVisible: boolean = false;
  @State hasMore: boolean = false;
  @State loadingEarlier: boolean = false;
  private historyLimit: number = 50;
  private firstVisible: number = 0;
  private syncAnchorKey: number = 0;
  private syncAnchorY: number = 0;
  // local_id -> base64 data URI（图片内容带 cookie 抓取，Image 组件直连 URL 无法携带）
  @State imgUris: Record<string, string> = {};
  scroller: Scroller = new Scroller();
  private scrollCb: (evt: WsEvent) => void = (evt: WsEvent) => {
    if (evt.type === 'chat_sync_start') {
      this.historyLoadSeq++;
      this.syncAnchorKey = !this.followingLatest ? this.store.rows[this.firstVisible]?.key ?? 0 : 0;
      try { this.syncAnchorY = this.scroller.getItemRect(this.firstVisible + 1).y; } catch (_) { this.syncAnchorY = 0; }
      return;
    }
    if (evt.type === 'chat_synced') {
      this.hasMore = this.store.syncHasMore && this.historyLimit < 200;
      this.historyError = ''; this.loadVisibleImages(); this.consumeCommand();
      if (this.syncAnchorKey && !this.followingLatest) {
        this.hasNewMessages = true;
        const index = this.store.rows.findIndex((row: ChatRow) => row.key === this.syncAnchorKey);
        if (index >= 0) {
          setTimeout(() => {
            if (!this.pageVisible || this.followingLatest) { return; }
            this.scroller.scrollToIndex(index + 1, false, ScrollAlign.START);
            if (this.syncAnchorY) { this.scroller.scrollBy(0, -this.syncAnchorY); }
          }, 0);
        }
      } else { this.scrollToBottom(); }
      return;
    }
    if (evt.type === 'chat_sync_unsupported') { this.loadHistory(); return; }
    if (evt.type === 'round_finished') {
      this.consumeCommand();
    }
    if (evt.type === 'message' || evt.type === 'message_delta' || evt.type === 'message_seg_end' ||
      evt.type === 'final' || evt.type === 'thinking' || evt.type === 'thinking_delta' ||
      evt.type === 'text' || evt.type === 'text_delta' || evt.type === 'tool_call' ||
      evt.type === 'tool_result' || evt.type === 'error') {
      if (!this.followingLatest && (evt.type === 'message' || evt.type === 'message_delta' ||
        evt.type === 'text' || evt.type === 'text_delta' || evt.type === 'error')) {
        this.hasNewMessages = true;
      }
      this.scrollToBottom();
    }
  };
  private connCb: (online: boolean) => void = (online: boolean) => {
    if (online && !TentacleApi.getInstance().chatSyncEnabled()) {
      this.loadHistory();
    }
  };

  aboutToAppear(): void {
    this.pageVisible = true;
    TentacleApi.getInstance().onWsEvent(this.scrollCb);
    TentacleApi.getInstance().onConn(this.connCb);
    this.loadVisibleImages();
    this.loadDraftImages();
    this.scrollToBottom();
    if (this.store.pendingCommand !== null) { this.consumeCommand(); }
    else if (TentacleApi.getInstance().chatSyncEnabled()) { TentacleApi.getInstance().synchronizeChat(); }
    else { this.loadHistory(); }
    this.consumePendingPrompt();
    this.loadCommandCatalog();
  }

  private consumePendingPrompt(): void {
    const prompt = AppStorage.get<string>('pendingChatPrompt') ?? '';
    if (prompt.length > 0) {
      this.draft.text = prompt;
      AppStorage.setOrCreate('pendingChatPrompt', '');
    }
  }

  private fillStarterPrompt(cmd: string): void {
    this.draft.text = cmd + ' ';
    this.commandMatches = matchChatCommands(this.draft.text, this.commandCatalog);
    try {
      this.getUIContext().getFocusController().requestFocus('chatInput');
      this.inputController.caretPosition(this.draft.text.length);
    } catch (_) {
      // 焦点恢复失败时保留草稿
    }
  }

  private async loadCommandCatalog(): Promise<void> {
    try {
      const result: CommandCatalog = await TentacleApi.getInstance().getChatCommands();
      this.commandCatalog = result.commands ?? [];
    } catch (e) {
      // 提示目录加载失败不影响输入，命令仍由后端识别。
      this.commandCatalog = [];
    }
  }

  aboutToDisappear(): void {
    this.fileLibrarySeq++;
    this.pageVisible = false;
    TentacleApi.getInstance().offWsEvent(this.scrollCb);
    TentacleApi.getInstance().offConn(this.connCb);
    // 已离开的页面不能用迟到的响应改写共享聊天状态。
    this.historyLoadSeq = this.historyLoadSeq + 1;
    if (this.scrollTimer >= 0) {
      clearTimeout(this.scrollTimer);
      this.scrollTimer = -1;
    }
    if (this.inputBlurTimer >= 0) {
      clearTimeout(this.inputBlurTimer);
      this.inputBlurTimer = -1;
    }
  }

  private scrollToBottom(): void {
    if (!this.followingLatest) {
      return;
    }
    if (this.touchingList || this.userScrolling) {
      this.followRequested = true;
      return;
    }
    if (this.scrollTimer >= 0) {
      // 节流而非防抖：连续高速增量也要定期跟随，不能一直推迟滚动。
      return;
    }
    // 等列表把新行布局完成后再滚动，避免仍停在旧内容的位置。
    this.scrollTimer = setTimeout(() => {
      this.scrollTimer = -1;
      if (this.touchingList || this.userScrolling) {
        this.followRequested = true;
      } else if (this.followingLatest && !this.scroller.isAtEnd()) {
        this.scroller.scrollEdge(Edge.Bottom);
      }
    }, 50);
  }

  private pauseFollowing(offset: number, source: ScrollSource): void {
    if (offset !== 0 && (source === ScrollSource.DRAG || source === ScrollSource.FLING ||
      source === ScrollSource.OTHER_USER_INPUT || source === ScrollSource.SCROLL_BAR ||
      source === ScrollSource.SCROLL_BAR_FLING)) {
      this.userScrolling = true;
      if (this.scrollTimer >= 0) {
        clearTimeout(this.scrollTimer);
        this.scrollTimer = -1;
      }
      if (offset < 0) {
        this.pauseForInspection();
      }
    }
  }

  private pauseForInspection(): void {
    this.followingLatest = false;
    this.followRequested = false;
    if (this.scrollTimer >= 0) {
      clearTimeout(this.scrollTimer);
      this.scrollTimer = -1;
    }
  }

  private handleListTouch(type: TouchType): void {
    if (type === TouchType.Down) {
      this.touchingList = true;
      if (this.scrollTimer >= 0) {
        clearTimeout(this.scrollTimer);
        this.scrollTimer = -1;
        this.followRequested = true;
      }
    } else if (type === TouchType.Up || type === TouchType.Cancel) {
      this.touchingList = false;
      if (!this.userScrolling) {
        this.finishListScroll();
      }
    }
  }

  private finishListScroll(): void {
    this.userScrolling = false;
    this.checkScrollEnd();
    if (!this.touchingList && this.followRequested) {
      this.followRequested = false;
      this.scrollToBottom();
    }
  }

  private checkScrollEnd(): void {
    // 手势/惯性/回弹尚未结束时，边界检测不能提前恢复自动滚动。
    if (!this.touchingList && !this.userScrolling && this.scroller.isAtEnd()) {
      this.followingLatest = true;
      this.hasNewMessages = false;
    }
  }

  private jumpToLatest(): void {
    this.touchingList = false;
    this.userScrolling = false;
    this.followRequested = false;
    this.followingLatest = true;
    this.hasNewMessages = false;
    this.scrollToBottom();
    if (this.historyPending) {
      this.historyPending = false;
      this.loadHistory();
    }
  }

  private loadVisibleImages(): void {
    for (let i = 0; i < this.store.rows.length; i++) {
      const user = this.store.rows[i].user;
      if (user !== null) {
        for (let j = 0; j < user.images.length; j++) {
          const img = user.images[j];
          if (isImage(img.mime)) { this.loadImageData(img.local_id, img.mime ?? 'image/jpeg'); }
        }
      }
    }
  }

  private loadDraftImages(): void {
    if (!this.pageVisible) {
      return;
    }
    for (let i = 0; i < this.draft.pending.length; i++) {
      const pending = this.draft.pending[i];
      if (!pending.uploading && pending.localId.length > 0 && isImage(pending.mime)) {
        this.loadImageData(pending.localId, pending.mime || 'image/jpeg');
      }
    }
  }

  private imgSrc(localId: string): string {
    const u = this.imgUris[localId];
    return u !== undefined ? u : '';
  }

  private loadImageData(localId: string, mime: string): void {
    if (this.imgSrc(localId).length > 0) {
      return;
    }
    TentacleApi.getInstance().getImageDataUri(localId, mime).then((uri: string) => {
      this.imgUris[localId] = uri;
    }).catch((e: Error) => {
      // 图片加载失败保持占位
    });
  }

  private async loadHistory(forceRefresh: boolean = false, earlier: boolean = false): Promise<void> {
    if (!earlier && TentacleApi.getInstance().chatSyncEnabled()) {
      await TentacleApi.getInstance().synchronizeChat(); return;
    }
    const seq = this.historyLoadSeq + 1;
    this.historyLoadSeq = seq;
    if (this.store.sending || this.store.receiving) {
      // 未归档的本轮输出已由入口页持续接收，切回时继续展示它。
      return;
    }
    const revision = this.store.revision;
    try {
      const data = await TentacleApi.getInstance().getHistory(this.historyLimit);
      if (seq !== this.historyLoadSeq) {
        return;
      }
      if (!this.followingLatest && this.store.rows.length > 0 && !forceRefresh && !earlier) {
        // 用户已开始阅读旧消息；重新生成列表会丢失当前阅读位置。
        this.historyPending = true;
        this.hasNewMessages = true;
        return;
      }
      // 先在临时状态中完整解析，成功后一次替换，不逐行改写全局列表。
      let rows = historyRows(data.messages);
      let inserted = 0;
      const anchor = this.firstVisible;
      let anchorY = 0;
      if (earlier && this.store.rows.length > 0) {
        try { anchorY = this.scroller.getItemRect(anchor + 1).y; } catch (e) { /* Off-screen anchor. */ }
        const oldest = this.store.rows[0].archiveId;
        if (!(oldest > 0)) { return; }
        const prefix = rows.filter((r: ChatRow) => r.archiveId < oldest);
        inserted = prefix.length;
        rows = prefix.concat(this.store.rows);
      }
      if (this.store.replaceHistory(rows, revision)) {
        this.loadVisibleImages();
        this.hasMore = data.has_more && this.historyLimit < 200;
        this.historyError = '';
        if (earlier) {
          this.followingLatest = false;
          setTimeout((): void => {
            if (!this.pageVisible) { return; }
            this.scroller.scrollToIndex(anchor + inserted + 1, false, ScrollAlign.START);
            if (anchorY !== 0) { this.scroller.scrollBy(0, -anchorY); }
          }, 0);
        } else { this.scrollToBottom(); }
      }
    } catch (e) {
      if (seq !== this.historyLoadSeq) {
        return;
      }
      // 历史加载失败不阻塞聊天
      this.historyError = '聊天记录同步失败，请稍后重新进入聊天页';
      if (forceRefresh) {
        this.store.addError('命令已执行，但聊天记录刷新失败，请重新进入聊天页');
      }
    }
  }

  private async loadEarlier(): Promise<void> {
    if (this.loadingEarlier || this.store.sending || this.store.receiving) { return; }
    this.loadingEarlier = true;
    this.historyLimit = Math.min(200, this.historyLimit + 50);
    TentacleApi.getInstance().setChatSyncLimit(this.historyLimit);
    try { await this.loadHistory(false, true); } finally { this.loadingEarlier = false; }
  }

  private async consumeCommand(): Promise<void> {
    const command = this.store.pendingCommand;
    if (command === null || !this.pageVisible) { return; }
    this.store.pendingCommand = null;
    if (command.refresh_history) { await this.loadHistory(true); }
    this.store.addSystem(command.text);
    this.scrollToBottom();
  }

  private hasUploading(): boolean {
    for (let i = 0; i < this.draft.pending.length; i++) {
      if (this.draft.pending[i].uploading || this.draft.pending[i].localId.length === 0) {
        return true;
      }
    }
    return false;
  }

  private async pickAndAttach(): Promise<void> {
    const remaining = MAX_PENDING_IMAGES - this.draft.pending.length;
    if (remaining <= 0) {
      this.store.addError('单轮最多 10 个附件');
      this.scrollToBottom();
      return;
    }
    let uris: string[] = [];
    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      const opts = new photoAccessHelper.PhotoSelectOptions();
      opts.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      opts.maxSelectNumber = remaining;
      const result: photoAccessHelper.PhotoSelectResult = await picker.select(opts);
      if (result && result.photoUris && result.photoUris.length > 0) {
        uris = result.photoUris;
      }
    } catch (e) {
      // 用户取消选图不提示
      return;
    }
    for (let i = 0; i < uris.length; i++) {
      await this.attachOne(uris[i]);
    }
  }

  private chooseAttachment(): void {
    this.fileLibraryOpen = false;
    this.attachmentSheetOpen = true;
  }

  private chooseAttachmentSource(source: string): void {
    this.attachmentSheetOpen = false;
    setTimeout(() => {
      if (!this.pageVisible) { return; }
      if (source === 'photos') { this.pickAndAttach(); } else { this.pickFiles(); }
    }, 200);
  }

  private async openFileLibrary(): Promise<void> {
    const seq = ++this.fileLibrarySeq;
    const api = TentacleApi.getInstance();
    const epoch = api.getCacheEpoch();
    this.fileLibraryOpen = true; this.fileLibraryBusy = true;
    this.attachmentSheetOpen = true;
    this.fileLibrary = []; this.fileLibrarySearch = '';
    try {
      const result = await api.getFiles();
      if (this.pageVisible && seq === this.fileLibrarySeq && epoch === api.getCacheEpoch()) {
        this.fileLibrary = result.files;
      }
    } catch (e) {
      if (this.pageVisible && seq === this.fileLibrarySeq && epoch === api.getCacheEpoch()) {
        this.historyError = '读取已有文件失败：' + e.message;
      }
    } finally { if (seq === this.fileLibrarySeq) { this.fileLibraryBusy = false; } }
  }

  private attachExisting(file: FileRecord): void {
    if (this.draft.pending.length >= MAX_PENDING_IMAGES) {
      this.historyError = '当前无法添加附件，单轮最多 10 个'; return;
    }
    if (this.draft.pending.some((pending: PendingImage) => pending.localId === file.local_id)) { return; }
    const item = new PendingImage();
    item.uri = 'tentacle-file:' + file.local_id;
    item.localId = file.local_id; item.filename = file.filename; item.mime = file.mime;
    this.draft.pending = this.draft.pending.concat([item]);
    this.attachmentSheetOpen = false; this.fileLibraryOpen = false;
    if (isImage(file.mime)) { this.loadImageData(file.local_id, file.mime); }
  }

  private async pickFiles(): Promise<void> {
    const remaining = MAX_PENDING_IMAGES - this.draft.pending.length;
    if (remaining <= 0) { this.historyError = '单轮最多 10 个附件'; return; }
    try {
      const viewPicker = new picker.DocumentViewPicker(this.getUIContext().getHostContext() as common.UIAbilityContext);
      const uris = await viewPicker.select({ maxSelectNumber: remaining });
      for (const uri of uris) { await this.attachOne(uri, true); }
    } catch (e) { this.historyError = '文件选择未完成：' + e.message; }
  }

  private async readDocument(uri: string): Promise<ArrayBuffer> {
    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      const size = fs.statSync(file.fd).size;
      if (size <= 0 || size > 64 * 1024 * 1024) { throw new Error('文件需非空且不超过 64 MiB'); }
      const bytes = new Uint8Array(size);
      let position = 0;
      while (position < size) {
        const chunk = new ArrayBuffer(Math.min(256 * 1024, size - position));
        const count = fs.readSync(file.fd, chunk);
        if (count <= 0) { throw new Error('文件读取不完整，请重新选择'); }
        bytes.set(new Uint8Array(chunk, 0, count), position);
        position += count;
      }
      return bytes.buffer;
    } finally { fs.closeSync(file); }
  }

  private async attachOne(uri: string, document: boolean = false): Promise<void> {
    if (uri.length === 0 || this.draft.pending.length >= MAX_PENDING_IMAGES) {
      return;
    }
    for (let i = 0; i < this.draft.pending.length; i++) {
      if (this.draft.pending[i].uri === uri) {
        return;
      }
    }
    const item = new PendingImage();
    item.uri = uri;
    item.filename = baseNameOf(uri);
    try { item.filename = decodeURIComponent(item.filename); } catch (e) { /* Keep the URI basename. */ }
    item.uploading = true;
    this.draft.pending = this.draft.pending.concat([item]);
    try {
      const data: ArrayBuffer = document ? await this.readDocument(uri) : await this.readUriBytes(uri);
      // 照片已经重编码为 JPEG；文档按原字节上传，由后端检测类型。
      const mime = document ? 'application/octet-stream' : 'image/jpeg';
      if (!document) { item.filename = item.filename.replace(/\.[^.]+$/, '') + '.jpg'; }
      const record = await TentacleApi.getInstance().uploadImage(data, item.filename, mime);
      if (!this.draft.pending.includes(item)) {
        return;
      }
      const done = new PendingImage();
      done.uri = item.uri;
      done.localId = record.local_id;
      done.filename = record.filename && record.filename.length > 0 ? record.filename : item.filename;
      done.mime = record.mime && record.mime.length > 0 ? record.mime : mime;
      done.uploading = false;
      const next: PendingImage[] = [];
      for (let i = 0; i < this.draft.pending.length; i++) {
        next.push(this.draft.pending[i] === item ? done : this.draft.pending[i]);
      }
      this.draft.pending = next;
      if (isImage(done.mime)) { this.loadImageData(done.localId, done.mime); }
    } catch (e) {
      this.draft.pending = this.draft.pending.filter((p: PendingImage) => p !== item);
      const msg = e instanceof Error ? e.message : String(e);
      this.store.addError(item.filename + ': ' + msg);
      this.scrollToBottom();
    }
  }

  private quietClose(file: number): void {
    try {
      fs.closeSync(file);
    } catch (e) {
      // 关闭失败可忽略
    }
  }

  private async openGrantAndFd(uri: string): Promise<number> {
    const ctx = getContext(this);
    const helper = photoAccessHelper.getPhotoAccessHelper(ctx);
    let granted: string[] = [];
    try {
      granted = await helper.requestPhotoUrisReadPermission([uri]);
      hilog.info(0x0000, 'TentacleImg', 'grant n=%{public}d', granted.length);
    } catch (eGrant) {
      hilog.error(0x0000, 'TentacleImg', 'grant fail %{public}s', errMsg(eGrant));
    }
    if (granted.length > 0) {
      try {
        const fd = fs.openSync(granted[0], fs.OpenMode.READ_ONLY).fd;
        hilog.info(0x0000, 'TentacleImg', 'granted open fd=%{public}d', fd);
        return fd;
      } catch (eOpen) {
        hilog.error(0x0000, 'TentacleImg', 'granted open fail %{public}s', errMsg(eOpen));
      }
    }
    const fd = await this.openAssetFd(uri);
    hilog.info(0x0000, 'TentacleImg', 'asset fd=%{public}d', fd);
    return fd;
  }

  private async openAssetFd(uri: string): Promise<number> {
    const ctx = getContext(this);
    const helper = photoAccessHelper.getPhotoAccessHelper(ctx);
    const predicates = new dataSharePredicates.DataSharePredicates();
    predicates.equalTo(photoAccessHelper.PhotoKeys.URI, uri);
    const fetchOpts: photoAccessHelper.FetchOptions = {
      fetchColumns: [],
      predicates: predicates,
    };
    const fr = await helper.getAssets(fetchOpts);
    let asset: photoAccessHelper.PhotoAsset | null = null;
    try {
      asset = await fr.getFirstObject();
    } finally {
      fr.close();
    }
    if (asset === null) {
      throw new Error('所选图片记录不存在');
    }
    try {
      return await asset.getReadOnlyFd();
    } catch (eFd) {
      throw new Error('getReadOnlyFd失败:' + errMsg(eFd));
    }
  }

  private async decodeFdToJpeg(fd: number): Promise<ArrayBuffer> {
    // fs 字节读写对媒体授权 fd 全面拒止(13900020)，fd 只能交给图像解码链消费
    const raw = image.createImageSource(fd);
    hilog.info(0x0000, 'TentacleImg', 'decode src=%{public}s', typeof raw);
    if (typeof raw === 'undefined' || raw === null) {
      throw new Error('createImageSource(fd)返回空');
    }
    const src = raw;
    const info = await src.getImageInfo();
    const decOpts: image.DecodingOptions = {};
    const scale = Math.max(info.size.width / MAX_DECODE_EDGE, info.size.height / MAX_DECODE_EDGE);
    if (scale > 1) {
      decOpts.desiredSize = { width: Math.floor(info.size.width / scale), height: Math.floor(info.size.height / scale) };
    }
    const pk = await src.createPixelMap(decOpts);
    const packer = image.createImagePacker();
    const packOpts: image.PackingOption = { format: 'image/jpeg', quality: 88 };
    const data = await packer.packToData(pk, packOpts);
    hilog.info(0x0000, 'TentacleImg', 'packed bytes=%{public}d', data.byteLength);
    if (data.byteLength > MAX_IMAGE_BYTES) {
      throw new Error('图片超过大小限制（20 MiB）');
    }
    return data;
  }

  private async readUriBytes(uri: string): Promise<ArrayBuffer> {
    // 新版安全访问机制：fs 层对媒体 uri 与授权 fd 的字节读写全部拒止，
    // 唯一可行路径是授权开 fd → ImageKit 解码 → 重编码 JPEG
    let fd = -1;
    let fdErrText = '';
    try {
      fd = await this.openGrantAndFd(uri);
    } catch (eFd) {
      fdErrText = errMsg(eFd);
      hilog.error(0x0000, 'TentacleImg', 'fd fail %{public}s', fdErrText);
    }
    if (fd < 0) {
      throw new Error('读取图片失败：无法获得授权句柄(' + fdErrText + ')');
    }
    try {
      return await this.decodeFdToJpeg(fd);
    } finally {
      this.quietClose(fd);
    }
  }

  private removePendingAt(idx: number): void {
    const out: PendingImage[] = [];
    for (let i = 0; i < this.draft.pending.length; i++) {
      if (i !== idx) {
        out.push(this.draft.pending[i]);
      }
    }
    this.draft.pending = out;
  }

  private send(): void {
    const text = this.draft.text.trim();
    const imgs: MsgImage[] = [];
    for (let i = 0; i < this.draft.pending.length; i++) {
      const p = this.draft.pending[i];
      if (!p.uploading && p.localId.length > 0) {
        const mi: MsgImage = {
          local_id: p.localId,
          filename: p.filename,
          mime: p.mime.length > 0 ? p.mime : 'image/jpeg'
        };
        imgs.push(mi);
      }
    }
    if ((text.length === 0 && imgs.length === 0) || this.isBusy()) {
      return;
    }
    if (this.hasUploading()) {
      this.store.addError('图片还在上传中，请稍候…');
      this.scrollToBottom();
      return;
    }
    this.draft.text = '';
    this.closeCommandPalette();
    this.jumpToLatest();
    this.store.sending = true;
    this.store.stopping = false; this.store.finishing = false;
    this.store.typing = true;
    const ids: string[] = [];
    for (let i = 0; i < imgs.length; i++) {
      ids.push(imgs[i].local_id);
    }
    this.store.addUser(text.length > 0 ? text : '[图片]', Date.now() / 1000, imgs);
    const sendKey = this.store.rows[this.store.rows.length - 1].key;
    this.store.activeSendKey = sendKey;
    const requestId = 'harmony-' + Date.now().toString(36) + '-' + sendKey.toString(36) + '-' +
      Math.random().toString(36).substring(2, 12);
    this.store.activeRequestId = requestId;
    for (let i = 0; i < imgs.length; i++) {
      if (isImage(imgs[i].mime)) { this.loadImageData(imgs[i].local_id, imgs[i].mime ?? 'image/jpeg'); }
    }
    const sentAttachments = this.draft.pending;
    this.store.commandAttachments = sentAttachments;
    this.store.commandDraft = this.draft;
    this.draft.pending = [];
    this.store.resetGroup();
    this.scrollToBottom();
    this.dispatchSend(sendKey, requestId, text, ids);
  }

  private async dispatchSend(sendKey: number, requestId: string, text: string, ids: string[]): Promise<void> {
    try {
      const live = await PhoneIntegration.getInstance().prepareRound(requestId);
      if (this.store.activeSendKey !== sendKey) {
        return;
      }
      let result: SendResult;
      try {
        result = await TentacleApi.getInstance().sendChat(text, ids, requestId, live);
      } catch (e) {
        if (this.store.activeSendKey !== sendKey) {
          return;
        }
        if (await PhoneIntegration.getInstance().handleSendRejection(requestId, e as Error)) {
          if (this.store.activeSendKey !== sendKey) {
            return;
          }
          result = await TentacleApi.getInstance().sendChat(text, ids, requestId, undefined);
        } else {
          throw e as Error;
        }
      }
      if (this.store.activeSendKey !== sendKey) {
        return;
      }
      if (result.round === undefined || result.round.request_id !== requestId) {
        throw new Error('服务端未返回对应回合的处理结果');
      }
      const finished = this.store.finishRequest(result.round, result.command);
      PhoneIntegration.getInstance().finishRound(requestId, result.round.status);
      if (this.store.pendingCommand !== null) { await this.consumeCommand(); }
      else if (finished && this.pageVisible && result.round.status === 'completed') { this.loadHistory(); }
    } catch (e) {
      if (this.store.activeSendKey !== sendKey) {
        return;
      }
      const err = e as Error;
      // HTTP 失败或超时均解除本次等待；不自动重发，迟到的 WS 输出仍正常显示。
      if (err instanceof ApiFailure && err.round !== undefined && err.round.request_id === requestId) {
        this.store.finishRequest(err.round);
      } else {
        this.store.failRequest(requestId, err.message);
      }
      PhoneIntegration.getInstance().finishRound(requestId,
        err instanceof ApiFailure && err.round !== undefined ? err.round.status : 'unconfirmed');
      this.scrollToBottom();
    }
  }

  private isBusy(): boolean {
    return this.store.sending || this.store.receiving || this.store.activeRound !== null || this.store.syncing;
  }

  private actionLabel(): string {
    if (this.store.syncing) { return '正在同步…'; }
    const round = this.store.activeRound;
    const matches = round !== null && this.store.stopTarget()?.round_id === round.round_id;
    if (this.store.finishing || matches && round?.phase === 'finishing') { return '正在保存…'; }
    if (this.store.stopping || matches && round?.stopping) { return '正在停止…'; }
    return this.store.stopTarget() !== null ? '停止当前回合' : '发送消息';
  }

  private actionEnabled(): boolean {
    const round = this.store.activeRound;
    const matches = round !== null && this.store.stopTarget()?.round_id === round.round_id;
    if (this.store.syncing || this.store.stopping || this.store.finishing ||
      matches && (round?.stopping || round?.phase === 'finishing')) { return false; }
    return this.store.stopTarget() !== null || !this.isBusy() && (!!this.draft.text.trim() || this.draft.pending.length > 0);
  }

  private sameStopTarget(target: ChatStopTarget): boolean {
    const current = this.store.stopTarget();
    return current !== null && (!target.round_id || current.round_id === target.round_id) &&
      (!target.request_id || current.request_id === target.request_id);
  }

  private async stop(): Promise<void> {
    const target = this.store.stopTarget();
    if (target === null || !this.actionEnabled()) { return; }
    this.store.stopping = true; this.historyError = '';
    try {
      const result = await TentacleApi.getInstance().stopChat(target);
      if (!this.sameStopTarget(target)) { return; }
      this.store.stopping = result.accepted;
      this.store.finishing = result.state === 'finishing';
      if (!result.accepted && result.state !== 'finishing') {
        this.historyError = result.state === 'ambiguous' ? '回合标识不唯一，正在重新同步' : '回合状态已变化，正在重新同步';
        await TentacleApi.getInstance().synchronizeChat();
      }
    } catch (error) {
      if (!this.sameStopTarget(target)) { return; }
      this.store.stopping = false;
      this.historyError = error instanceof ApiFailure && (error.httpStatus === 404 || error.httpStatus === 405) ?
        '服务器未提供停止接口，请更新后端' : '停止请求未确认，请重试停止；不会重发消息';
    }
  }

  private closeCommandPalette(): void {
    this.commandMatches = [];
    this.commandActiveIndex = 0;
  }

  private selectCommand(index: number): void {
    if (index < 0 || index >= this.commandMatches.length) {
      return;
    }
    this.draft.text = this.commandMatches[index].value;
    this.closeCommandPalette();
    try {
      this.getUIContext().getFocusController().requestFocus('chatInput');
      this.inputController.caretPosition(this.draft.text.length);
    } catch (e) {
      // 页面切换时可能无法恢复焦点，命令文本仍保留在输入框。
    }
  }

  private handleInputKey(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down || this.composing) {
      return false;
    }
    const shifted = event.getModifierKeyState !== undefined && event.getModifierKeyState(['Shift']);
    if (this.commandMatches.length > 0) {
      if (event.keyCode === KeyCode.KEYCODE_DPAD_DOWN || event.keyCode === KeyCode.KEYCODE_DPAD_UP) {
        const step = event.keyCode === KeyCode.KEYCODE_DPAD_DOWN ? 1 : -1;
        this.commandActiveIndex = (this.commandActiveIndex + step + this.commandMatches.length) %
          this.commandMatches.length;
        this.commandScroller.scrollToIndex(this.commandActiveIndex);
        return true;
      }
      if (event.keyCode === KeyCode.KEYCODE_TAB || (event.keyCode === KeyCode.KEYCODE_ENTER && !shifted)) {
        this.selectCommand(this.commandActiveIndex);
        return true;
      }
      if (event.keyCode === KeyCode.KEYCODE_ESCAPE) {
        this.closeCommandPalette();
        return true;
      }
    }
    if (event.keyCode === KeyCode.KEYCODE_ENTER && !shifted) {
      this.send();
      return true;
    }
    return false;
  }

  // 输入行数（按换行与视觉折行估算，5 行封顶），驱动悬浮胶囊内 TextArea 自适应高度
  private inputLines(): number {
    return estimateWrappedLines(this.draft.text, 5, 26);
  }

  private dockSpacerHeight(): number {
    let h = 92 + (this.inputLines() - 1) * 21;
    if (this.store.typing || this.store.usageLine.length > 0) {
      h += 36;
    }
    if (this.draft.pending.length > 0) {
      h += 74;
    }
    return h;
  }

  @Builder
  UserBubble(user: UserMsg) {
    Column({ space: 8 }) {
      if (user.platform && user.platform !== 'harmony' && user.platform !== 'web') {
        Text(user.platform).fontSize(10).fontColor($r('app.color.tentacle_accent')).width('100%').textAlign(TextAlign.End)
      }
      if (user.images.length > 0) {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.End }) {
          ForEach(user.images, (img: MsgImage) => {
            if ((img.mime ?? '').startsWith('audio/') || (img.mime ?? '').startsWith('video/')) {
              MediaAttachment({ localId: img.local_id, filename: img.filename, mime: img.mime ?? '' })
            } else if (!isImage(img.mime)) {
              FileDownload({ endpoint: '/api/files/' + encodeURIComponent(img.local_id) + '/content', filename: img.filename })
            } else if (this.imgSrc(img.local_id).length > 0) {
              Image(this.imgSrc(img.local_id))
                .width(168)
                .height(168)
                .borderRadius(14)
                .objectFit(ImageFit.Cover)
                .onClick(() => {
                  this.previewUrl = this.imgSrc(img.local_id);
                })
            } else {
              Column() {
                LoadingProgress()
                  .width(22)
                  .height(22)
                  .color($r('app.color.tentacle_accent'))
              }
              .justifyContent(FlexAlign.Center)
              .width(168)
              .height(168)
              .borderRadius(14)
              .backgroundColor($r('app.color.tentacle_bg_input'))
              .border({ width: 0.5, color: $r('app.color.tentacle_border') })
            }
          }, (img: MsgImage, idx: number) => img.local_id + idx.toString())
        }
        .width('100%')
      }
      if (user.text.length > 0) {
        Row() {
          Blank()
          Text(user.text)
            .copyOption(CopyOptions.LocalDevice)
            .fontSize(15)
            .fontColor('#F3EDE3')
            .backgroundColor($r('app.color.tentacle_user_bubble'))
            .linearGradient({
              angle: 180,
              colors: [['#46382A', 0], ['#3E3327', 1]]
            })
            .borderRadius({
              topLeft: 16,
              topRight: 16,
              bottomLeft: 16,
              bottomRight: 4
            })
            .padding({ left: 12, right: 12, top: 9, bottom: 9 })
            .lineHeight(22)
            .constraintSize({ maxWidth: '80%' })
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }
    }
    .width('100%')
  }

  @Builder
  PendingThumb(p: PendingImage, idx: number) {
    Stack({ alignContent: Alignment.TopEnd }) {
      if (p.uploading || p.localId.length === 0) {
        Column() {
          LoadingProgress()
            .width(22)
            .height(22)
            .color($r('app.color.tentacle_accent'))
        }
        .justifyContent(FlexAlign.Center)
        .width(64)
        .height(64)
        .borderRadius(12)
        .backgroundColor($r('app.color.tentacle_bg_input'))
        .border({ width: 0.5, color: $r('app.color.tentacle_border') })
      } else {
        if (!isImage(p.mime)) {
          Text(p.filename).fontSize(10).fontColor($r('app.color.tentacle_text')).maxLines(3).width(64).height(64).padding(4)
            .backgroundColor($r('app.color.tentacle_bg_input'))
        } else if (this.imgSrc(p.localId).length > 0) {
          Image(this.imgSrc(p.localId))
            .width(64)
            .height(64)
            .borderRadius(12)
            .objectFit(ImageFit.Cover)
            .onClick(() => {
              this.previewUrl = this.imgSrc(p.localId);
            })
        } else {
          Column() {
            LoadingProgress()
              .width(22)
              .height(22)
              .color($r('app.color.tentacle_accent'))
          }
          .justifyContent(FlexAlign.Center)
          .width(64)
          .height(64)
          .borderRadius(12)
          .backgroundColor($r('app.color.tentacle_bg_input'))
          .border({ width: 0.5, color: $r('app.color.tentacle_border') })
        }
      }
      if (!p.uploading && p.localId.length > 0) {
        Text('✕')
          .fontSize(11)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .width(18)
          .height(18)
          .borderRadius(9)
          .backgroundColor('#99000000')
          .margin(3)
          .onClick(() => {
            this.removePendingAt(idx);
          })
      }
    }
    .width(64)
    .height(64)
    .clip(true)
  }

  @Builder
  CommandPalette() {
    List({ scroller: this.commandScroller }) {
      ForEach(this.commandMatches, (item: ChatCommand, idx: number) => {
        ListItem() {
          Row({ space: 10 }) {
            Text(item.value)
              .fontSize(12.5)
              .fontFamily('monospace')
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.tentacle_accent'))
            Text(item.description)
              .fontSize(11.5)
              .fontColor($r('app.color.tentacle_text_dim'))
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.End)
          }
          .alignItems(VerticalAlign.Center)
          .width('100%')
          .padding({ left: 12, right: 12, top: 9, bottom: 9 })
          .borderRadius(12)
          .backgroundColor(idx === this.commandActiveIndex
            ? $r('app.color.tentacle_accent_soft') : Color.Transparent)
        }
        .onClick(() => {
          this.selectCommand(idx);
        })
      }, (item: ChatCommand) => item.value)
    }
    .width('100%')
    .height(Math.min(this.commandMatches.length * 40 + 8, 210))
    .scrollBar(BarState.Auto)
    .padding(4)
    .borderRadius(20)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
    .backgroundColor('#E62B241C')
    .border({ width: 0.75, color: $r('app.color.tentacle_border_strong') })
    .shadow({ radius: 20, color: '#66000000', offsetX: 0, offsetY: 8 })
    .margin({ bottom: 8 })
    .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
  }

  @Builder
  AttachmentChoice(symbol: string, title: string, detail: string, action: () => void) {
    Row({ space: 14 }) {
      Text(symbol).fontSize(18).fontColor($r('app.color.tentacle_accent')).width(42).height(42).textAlign(TextAlign.Center)
        .backgroundColor($r('app.color.tentacle_accent_soft')).borderRadius(12)
      Column({ space: 4 }) {
        Text(title).fontSize(15).fontColor($r('app.color.tentacle_text')).width('100%')
        Text(detail).fontSize(11).fontColor($r('app.color.tentacle_text_faint')).width('100%')
      }.layoutWeight(1)
      Text('›').fontSize(22).fontColor($r('app.color.tentacle_text_faint'))
    }.width('100%').padding({ top: 12, bottom: 12 }).onClick(action)
  }

  @Builder
  AttachmentSheet() {
    Column({ space: 12 }) {
      Row() {
        Text(this.fileLibraryOpen ? '从记忆库选择文件' : '添加附件').fontSize(19).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.tentacle_text')).layoutWeight(1)
        Text('关闭').fontSize(13).fontColor($r('app.color.tentacle_text_dim')).padding(10)
          .onClick(() => this.attachmentSheetOpen = false)
      }.width('100%')
      if (this.fileLibraryOpen) {
        TextInput({ text: this.fileLibrarySearch, placeholder: '搜索已上传的文件' }).height(40).fontSize(13)
          .fontColor($r('app.color.tentacle_text')).backgroundColor($r('app.color.tentacle_bg_input'))
          .onChange((value: string) => this.fileLibrarySearch = value)
        if (this.fileLibraryBusy) {
          Text('正在读取文件列表…').fontSize(13).fontColor($r('app.color.tentacle_text_faint')).padding(20)
        } else if (!this.fileLibrary.length) {
          Text('记忆库中暂无文件').fontSize(13).fontColor($r('app.color.tentacle_text_faint')).padding(20)
        }
        List({ space: 6 }) {
          ForEach(this.fileLibrary.filter((file: FileRecord) => file.filename.toLowerCase().includes(this.fileLibrarySearch.toLowerCase())), (file: FileRecord) => {
            ListItem() {
              Row({ space: 12 }) {
                Text('↳').fontSize(18).fontColor($r('app.color.tentacle_accent')).width(28)
                Column({ space: 4 }) {
                  Text(file.filename).fontSize(14).fontColor($r('app.color.tentacle_text')).width('100%').maxLines(2)
                  Text((file.size / 1024).toFixed(1) + ' KiB').fontSize(11).fontColor($r('app.color.tentacle_text_faint')).width('100%')
                }.layoutWeight(1)
                Text(this.draft.pending.some((p: PendingImage) => p.localId === file.local_id) ? '已添加' : '添加')
                  .fontSize(12).fontColor($r('app.color.tentacle_accent'))
              }.width('100%').padding(12).backgroundColor($r('app.color.tentacle_bg_input')).borderRadius(10)
            }.onClick(() => this.attachExisting(file))
          }, (file: FileRecord) => file.local_id)
        }.width('100%').layoutWeight(1)
      } else {
        Text('每条消息最多 10 个附件').fontSize(12).fontColor($r('app.color.tentacle_text_faint')).width('100%')
        Column() {
          this.AttachmentChoice('▧', '照片', '从相册选择图片', () => this.chooseAttachmentSource('photos'))
          Divider().color($r('app.color.tentacle_border'))
          this.AttachmentChoice('↥', '本机文件', '文档、音频或视频', () => this.chooseAttachmentSource('files'))
          Divider().color($r('app.color.tentacle_border'))
          this.AttachmentChoice('▤', '记忆库文件', '选用已上传的文件', () => this.openFileLibrary())
        }.width('100%')
      }
    }.width('100%').height('100%').padding({ left: 22, right: 22, top: 6, bottom: 24 })
      .backgroundColor($r('app.color.tentacle_bg_card'))
  }

  @Builder
  Dock() {
    Column({ space: 8 }) {
      if (!this.followingLatest || this.hasNewMessages) {
        Row() {
          Row({ space: 6 }) {
            Text(this.hasNewMessages ? '有新消息 ↓' : '回到底部 ↓')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.hasNewMessages ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_text'))
          }
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .borderRadius(999)
          .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
          .backgroundColor('#E62B241C')
          .border({
            width: 0.75,
            color: this.hasNewMessages ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_border_strong')
          })
          .shadow({ radius: 14, color: '#4D000000', offsetX: 0, offsetY: 4 })
          .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
          .onClick(() => this.jumpToLatest())
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
      }

      if (this.historyError.length > 0 || this.store.syncError.length > 0) {
        FeedbackBanner({ text: this.historyError || this.store.syncError, tone: 'danger' })
      }

      if (this.store.typing || this.store.usageLine.length > 0) {
        Row({ space: 8 }) {
          if (this.store.typing) {
            Row({ space: 6 }) {
              DotTyping()
              Text('正在处理')
                .fontSize(11)
                .fontColor($r('app.color.tentacle_text_dim'))
            }
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(999)
            .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
            .backgroundColor('#CC292219')
            .border({ width: 0.5, color: $r('app.color.tentacle_border') })
          }
          if (this.store.usageLine.length > 0) {
            Text(this.store.usageLine)
              .fontSize(10.5)
              .fontFamily('monospace')
              .fontColor($r('app.color.tentacle_text_dim'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .borderRadius(999)
              .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
              .backgroundColor('#CC292219')
              .border({ width: 0.5, color: $r('app.color.tentacle_border') })
              .layoutWeight(this.store.typing ? 1 : 0)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      if (this.inputFocused && this.commandMatches.length > 0 && !this.isBusy()) {
        this.CommandPalette()
      }

      // 悬浮胶囊主体
      Column({ space: 6 }) {
        if (this.draft.pending.length > 0) {
          Scroll() {
            Row({ space: 8 }) {
              ForEach(this.draft.pending, (p: PendingImage, idx: number) => {
                this.PendingThumb(p, idx)
              }, (p: PendingImage, idx: number) => (p.localId.length > 0 ? p.localId : 'up') + idx.toString())
            }
            .padding({ left: 4, right: 4, top: 4 })
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
        }

        Row({ space: 6 }) {
          Row() {
            Text('＋')
              .fontSize(19)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.tentacle_text_dim'))
          }
          .width(38)
          .height(38)
          .borderRadius(19)
          .justifyContent(FlexAlign.Center)
          .backgroundColor($r('app.color.tentacle_bg_hover'))
          .onClick(() => {
            this.chooseAttachment();
          })

          TextArea({ text: this.draft.text, placeholder: '发消息，或输入 / 查看命令…', controller: this.inputController })
            .id('chatInput')
            .onChange((v: string, preview?: PreviewText) => {
              const wasComposing = this.composing;
              this.composing = preview !== undefined && preview.value.length > 0;
              if (v !== this.draft.text || wasComposing !== this.composing) {
                this.draft.text = v;
                this.commandMatches = this.composing ? [] : matchChatCommands(v, this.commandCatalog);
                this.commandActiveIndex = 0;
                this.commandScroller.scrollEdge(Edge.Top);
              }
            })
            .onFocus(() => {
              if (this.inputBlurTimer >= 0) {
                clearTimeout(this.inputBlurTimer);
                this.inputBlurTimer = -1;
              }
              this.inputFocused = true;
            })
            .onBlur(() => {
              // 给候选项点击留出时间，避免失焦先移除菜单、吞掉点击。
              this.inputBlurTimer = setTimeout(() => {
                this.inputFocused = false;
                this.closeCommandPalette();
                this.inputBlurTimer = -1;
              }, 100);
            })
            .onKeyEventDispatch((event: KeyEvent): boolean => this.handleInputKey(event))
            .backgroundColor(Color.Transparent)
            .placeholderColor($r('app.color.tentacle_text_faint'))
            .placeholderFont({ size: 14 })
            .fontColor($r('app.color.tentacle_text'))
            .caretColor($r('app.color.tentacle_accent'))
            .fontSize(15)
            .height(Math.max(38, 18 + this.inputLines() * 21))
            .lineHeight(21)
            .layoutWeight(1)
            .padding({ left: 6, right: 6, top: 8, bottom: 8 })

          Column() {
            Text(this.store.stopTarget() !== null ? '■' : '↑')
              .fontSize(this.store.stopTarget() !== null ? 13 : 16.5)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
          }
          .width(38)
          .height(38)
          .borderRadius(19)
          .justifyContent(FlexAlign.Center)
          .linearGradient({
            angle: 180,
            colors: this.store.stopTarget() !== null
              ? [['#CF6A5F', 0], ['#B6544A', 1]]
              : [['#D97757', 0], ['#E58E6E', 1]]
          })
          .opacity(this.actionEnabled() ? 1 : 0.35)
          .enabled(this.actionEnabled())
          .accessibilityText(this.actionLabel())
          .onClick(() => {
            if (this.store.stopTarget() !== null) { this.stop(); } else { this.send(); }
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 6, bottom: 6 })
      .borderRadius(28)
      .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
      .backgroundColor('#D92B241C')
      .border({
        width: this.inputFocused ? 1 : 0.75,
        color: this.inputFocused ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_border_strong')
      })
      .shadow({ radius: 22, color: '#66000000', offsetX: 0, offsetY: 8 })
      .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
    }
    .width('100%')
    .padding({ left: 12, right: 12, bottom: 12, top: 22 })
    .linearGradient({
      angle: 180,
      colors: [['#00201B16', 0], ['#B8201B16', 0.45], ['#F0201B16', 1]]
    })
    .hitTestBehavior(HitTestMode.None)
    .onAreaChange((oldArea: Area, newArea: Area) => {
      if (Number(oldArea.height) !== Number(newArea.height)) {
        this.scrollToBottom();
      }
    })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      List({ space: 14, scroller: this.scroller }) {
        ListItem() {
          if (this.hasMore) {
            Row() {
              ActionButton({
                label: this.loadingEarlier ? '加载中…' : '加载更早的对话',
                tone: 'ghost',
                compact: true,
                isEnabled: !this.loadingEarlier && !this.isBusy(),
                onTap: () => { this.loadEarlier(); }
              })
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({ top: 4, bottom: 4 })
          }
        }
        ForEach(this.store.rows, (row: ChatRow, idx: number) => {
          if (row.kind === 'user' && row.user !== null) {
            ListItem() {
              this.UserBubble(row.user)
            }
            .transition(enterFade())
          } else if (row.kind === 'system' && row.system !== null) {
            ListItem() {
              Row() {
                Text(row.system.text)
                  .fontSize(12)
                  .fontColor($r('app.color.tentacle_text_dim'))
                  .textAlign(TextAlign.Center)
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .borderRadius(12)
                  .backgroundColor($r('app.color.tentacle_bg_input'))
                  .border({ width: 0.5, color: $r('app.color.tentacle_border') })
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
            }
            .transition(enterFade())
          } else if (row.kind === 'group' && row.group !== null) {
            ListItem() {
              AgentGroupItem({ group: row.group, onContentChange: () => this.scrollToBottom(),
                onInspect: () => this.pauseForInspection() })
            }
            .transition(enterFade())
          }
        }, (row: ChatRow) => row.key.toString())

        ListItem() {
          Column().width('100%').height(this.dockSpacerHeight())
        }
      }
      .width('100%')
      .height('100%')
      .padding({ left: 12, right: 12, top: 6 })
      .scrollBar(BarState.Off)
      .onWillScroll((offset: number, state: ScrollState, source: ScrollSource) => {
        this.pauseFollowing(offset, source);
      })
      .onDidScroll(() => this.checkScrollEnd())
      .onScrollIndex((start: number) => { this.firstVisible = Math.max(0, start - 1); })
      .onScrollStop(() => this.finishListScroll())
      .onTouch((event: TouchEvent) => this.handleListTouch(event.type))
      .onAreaChange((oldArea: Area, newArea: Area) => {
        if (Number(oldArea.height) !== Number(newArea.height)) {
          this.scrollToBottom();
        }
      })

      if (this.store.rows.length === 0) {
        Column({ space: 14 }) {
          Column() {
            Text('✦')
              .fontSize(22)
              .fontColor($r('app.color.tentacle_accent'))
          }
          .width(52)
          .height(52)
          .borderRadius(16)
          .backgroundColor($r('app.color.tentacle_accent_soft'))
          .border({ width: 0.75, color: $r('app.color.tentacle_border_strong') })
          .justifyContent(FlexAlign.Center)

          Text('开始对话吧')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.tentacle_text'))

          Text('私人对话与记忆保存在你的主服务中，直接聊，或输入 / 查看命令')
            .fontSize(12.5)
            .fontColor($r('app.color.tentacle_text_dim'))
            .textAlign(TextAlign.Center)
            .constraintSize({ maxWidth: 280 })
            .lineHeight(19)

          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
            ForEach([
              ['/help 查看命令', '/help'],
              ['/session 开启新会话', '/session'],
              ['/compress 整理记忆', '/compress'],
              ['/model current 当前模型', '/model current'],
            ], (chip: string[]) => {
              Text(chip[0])
                .fontSize(12)
                .fontColor($r('app.color.tentacle_text'))
                .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                .margin(4)
                .borderRadius(999)
                .backgroundColor($r('app.color.tentacle_bg_card'))
                .border({ width: 0.75, color: $r('app.color.tentacle_border') })
                .onClick(() => this.fillStarterPrompt(chip[1]))
            }, (chip: string[]) => chip[1])
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 4 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ bottom: 88 })
      }

      this.Dock()

      if (this.previewUrl.length > 0) {
        Stack({ alignContent: Alignment.TopEnd }) {
          Column() {
            Image(this.previewUrl)
              .objectFit(ImageFit.Contain)
              .width('100%')
              .layoutWeight(1)
          }
          .justifyContent(FlexAlign.Center)
          .width('100%')
          .height('100%')
          .onClick(() => {
            this.previewUrl = '';
          })

          Text('✕')
            .fontSize(15)
            .fontColor('#FFFFFF')
            .textAlign(TextAlign.Center)
            .width(34)
            .height(34)
            .borderRadius(17)
            .backgroundColor('#80201B16')
            .border({ width: 0.75, color: '#40FFFFFF' })
            .margin({ top: 14, right: 16 })
            .onClick(() => {
              this.previewUrl = '';
            })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#EC000000')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.tentacle_bg'))
    .alignContent(Alignment.Bottom)
    .bindSheet($$this.attachmentSheetOpen, this.AttachmentSheet(), {
      height: 400, showClose: false, dragBar: true, backgroundColor: $r('app.color.tentacle_bg_card'),
      onDisappear: () => { this.fileLibraryOpen = false; this.fileLibrarySeq++; }
    })
  }
}
