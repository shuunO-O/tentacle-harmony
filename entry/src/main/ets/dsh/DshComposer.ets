/**
 * DSH 底部输入与队列控制栏（严格沿用 ChatPage 干净无内框遮挡的 TextArea 风格）
 *
 * 能力清单：
 * - / 斜杠命令候选浮层（来自 commands/list）
 * - @ 工作区文件引用候选浮层（来自 fileReferences/list）
 * - ＋ 照片/文件上传附件条（来自 fileUploads/upload）
 * - 生成中不锁死输入：空输入显示「■ 停止」，有内容支持入队列（queue）或直接插话（steer）
 * - 输入栏上方展示队列小条，支持逐条「插话」或「移除」
 */

import {
  DshCommandCandidate,
  DshPendingAttachment,
  DshQueuedItem,
  DshReferenceCandidate
} from './DshModels';

@Component
export struct DshComposer {
  @Prop running: boolean = false;
  @Prop sending: boolean = false;
  @Prop commands: DshCommandCandidate[] = [];
  @Prop commandsLoadState: string = 'idle';
  @Prop commandsError: string = '';
  @Prop references: DshReferenceCandidate[] = [];
  @Prop queuedItems: DshQueuedItem[] = [];
  @Prop attachments: DshPendingAttachment[] = [];

  @State draftText: string = '';
  @State inputFocused: boolean = false;
  @State attachMenuOpen: boolean = false;
  private blurTimer: number = -1;
  private refQueryTimer: number = -1;
  private textController: TextAreaController = new TextAreaController();

  onSend: (text: string, mode: string) => void = () => {};
  onExecuteCommand: (line: string) => void = () => {};
  onRefreshCommands: () => void = () => {};
  onCancel: () => void = () => {};
  onUpdateQueue: (itemId: string, action: string) => void = () => {};
  onRemoveAttachment: (id: string) => void = () => {};
  onPickPhoto: () => void = () => {};
  onPickFile: () => void = () => {};
  onQueryRefs: (query: string) => void = () => {};

  aboutToDisappear(): void {
    if (this.blurTimer >= 0) {
      clearTimeout(this.blurTimer);
      this.blurTimer = -1;
    }
    if (this.refQueryTimer >= 0) {
      clearTimeout(this.refQueryTimer);
      this.refQueryTimer = -1;
    }
  }

  private inputLines(): number {
    if (this.draftText.length === 0) {
      return 1;
    }
    const split = this.draftText.split('\n');
    let lines = split.length;
    for (let i = 0; i < split.length; i++) {
      lines += Math.floor(split[i].length / 26);
    }
    return Math.max(1, Math.min(5, lines));
  }

  private focusInput(): void {
    if (this.blurTimer >= 0) {
      clearTimeout(this.blurTimer);
      this.blurTimer = -1;
    }
    this.inputFocused = true;
    try {
      this.getUIContext().getFocusController().requestFocus('dshComposerInput');
    } catch (_) {}
  }

  private isSingleSlashPrefix(): boolean {
    const trimmed = this.draftText.trimStart();
    return trimmed.startsWith('/') && trimmed.indexOf(' ') < 0 && trimmed.indexOf('\n') < 0;
  }

  private matchedCommands(): DshCommandCandidate[] {
    const trimmed = this.draftText.trimStart();
    if (!trimmed.startsWith('/') || trimmed.indexOf(' ') >= 0 || trimmed.indexOf('\n') >= 0) {
      return [];
    }
    const q = trimmed.toLowerCase();
    const out: DshCommandCandidate[] = [];
    for (let i = 0; i < this.commands.length; i++) {
      const c = this.commands[i];
      if (q === '/' || c.name.toLowerCase().indexOf(q) >= 0) {
        out.push(c);
        if (out.length >= 16) {
          break;
        }
      }
    }
    return out;
  }

  private activeAtToken(): string | null {
    const m = /(?:^|\s)@([^\s]*)$/.exec(this.draftText);
    if (m === null) {
      return null;
    }
    return m[1] ?? '';
  }

  private matchedRefs(): DshReferenceCandidate[] {
    const tok = this.activeAtToken();
    if (tok === null) {
      return [];
    }
    const q = tok.toLowerCase();
    const out: DshReferenceCandidate[] = [];
    for (let i = 0; i < this.references.length; i++) {
      const r = this.references[i];
      if (q.length === 0 || r.path.toLowerCase().indexOf(q) >= 0) {
        out.push(r);
        if (out.length >= 16) {
          break;
        }
      }
    }
    return out;
  }

  private insertCommand(cmd: DshCommandCandidate): void {
    if (this.blurTimer >= 0) {
      clearTimeout(this.blurTimer);
      this.blurTimer = -1;
    }
    if (cmd.hint.length === 0) {
      this.draftText = '';
      this.inputFocused = false;
      this.onExecuteCommand(cmd.name);
      return;
    }
    this.draftText = cmd.name + ' ';
    this.focusInput();
  }

  private insertReference(ref: DshReferenceCandidate): void {
    const idx = this.draftText.lastIndexOf('@');
    if (idx < 0) {
      this.draftText = this.draftText + ref.insert + (ref.isDir ? '' : ' ');
    } else {
      this.draftText = this.draftText.substring(0, idx) + ref.insert + (ref.isDir ? '' : ' ');
    }
    if (ref.isDir) {
      const tok = this.activeAtToken();
      if (tok !== null) {
        this.onQueryRefs(tok);
      }
    }
  }

  private hasReadyContent(): boolean {
    if (this.draftText.trim().length > 0) {
      return true;
    }
    for (let i = 0; i < this.attachments.length; i++) {
      if (!this.attachments[i].uploading && this.attachments[i].error.length === 0) {
        return true;
      }
    }
    return false;
  }

  private hasUploadingAttachment(): boolean {
    for (let i = 0; i < this.attachments.length; i++) {
      if (this.attachments[i].uploading) {
        return true;
      }
    }
    return false;
  }

  private triggerSubmit(mode: string): void {
    if (this.sending || this.hasUploadingAttachment()) {
      return;
    }
    const trimmed = this.draftText.trim();
    if (!this.hasReadyContent()) {
      if (this.running) {
        this.onCancel();
      }
      return;
    }
    // 首词命中 commands/list（或命令目录尚为空时单斜杠口令）走 commands/execute
    if (trimmed.startsWith('/')) {
      const spIdx = trimmed.search(/\s/);
      const head = (spIdx >= 0 ? trimmed.substring(0, spIdx) : trimmed).toLowerCase();
      let isKnownCmd = false;
      for (let i = 0; i < this.commands.length; i++) {
        if (this.commands[i].name.toLowerCase() === head) {
          isKnownCmd = true;
          break;
        }
      }
      if (!isKnownCmd && this.commands.length === 0 && /^\/[a-z0-9_-]+$/i.test(head)) {
        isKnownCmd = true;
      }
      if (isKnownCmd) {
        this.draftText = '';
        this.inputFocused = false;
        this.onExecuteCommand(trimmed);
        return;
      }
    }
    const payload = this.draftText;
    this.draftText = '';
    this.onSend(payload, mode);
  }

  private actionEnabled(): boolean {
    if (this.sending || this.hasUploadingAttachment()) {
      return false;
    }
    return this.hasReadyContent() || this.running;
  }

  @Builder
  PopupCandidates() {
    if (this.inputFocused && this.matchedCommands().length > 0) {
      List({ space: 2 }) {
        ForEach(this.matchedCommands(), (cmd: DshCommandCandidate) => {
          ListItem() {
            Row({ space: 8 }) {
              Text(cmd.name)
                .fontSize(13)
                .fontFamily('monospace')
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.tentacle_accent'))
              if (cmd.hint.length > 0) {
                Text(cmd.hint)
                  .fontSize(11)
                  .fontFamily('monospace')
                  .fontColor($r('app.color.tentacle_text_faint'))
              }
              Blank()
              if (cmd.description.length > 0) {
                Text(cmd.description)
                  .fontSize(11.5)
                  .fontColor($r('app.color.tentacle_text_dim'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .constraintSize({ maxWidth: '52%' })
              }
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .borderRadius(10)
            .onClick(() => this.insertCommand(cmd))
          }
        }, (cmd: DshCommandCandidate) => cmd.name)
      }
      .width('100%')
      .height(Math.min(this.matchedCommands().length * 38 + 8, 190))
      .padding(4)
      .borderRadius(16)
      .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
      .backgroundColor('#E62B241C')
      .border({ width: 0.75, color: $r('app.color.tentacle_border_strong') })
      .shadow({ radius: 18, color: '#66000000', offsetX: 0, offsetY: 6 })
      .onTouch((ev: TouchEvent) => {
        if (ev.type === TouchType.Down && this.blurTimer >= 0) {
          clearTimeout(this.blurTimer);
          this.blurTimer = -1;
        }
      })
    } else if (this.inputFocused && this.isSingleSlashPrefix() && this.commands.length === 0) {
      Row({ space: 8 }) {
        Text(this.commandsLoadState === 'loading'
          ? '正在读取可用斜杠指令…'
          : (this.commandsError.length > 0 ? ('指令列表读取失败：' + this.commandsError) : '暂无可用斜杠指令'))
          .fontSize(12)
          .fontColor($r('app.color.tentacle_text_dim'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.commandsLoadState !== 'loading') {
          Text('重试')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.tentacle_accent'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .borderRadius(8)
            .backgroundColor($r('app.color.tentacle_accent_soft'))
            .onClick(() => {
              this.focusInput();
              this.onRefreshCommands();
            })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 10, top: 9, bottom: 9 })
      .borderRadius(14)
      .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
      .backgroundColor('#E62B241C')
      .border({ width: 0.75, color: $r('app.color.tentacle_border_strong') })
      .onTouch((ev: TouchEvent) => {
        if (ev.type === TouchType.Down && this.blurTimer >= 0) {
          clearTimeout(this.blurTimer);
          this.blurTimer = -1;
        }
      })
    } else if (this.inputFocused && this.matchedRefs().length > 0) {
      List({ space: 2 }) {
        ForEach(this.matchedRefs(), (ref: DshReferenceCandidate) => {
          ListItem() {
            Row({ space: 8 }) {
              Text(ref.isDir ? '目录' : '文件')
                .fontSize(10)
                .fontColor($r('app.color.tentacle_accent'))
                .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                .borderRadius(5)
                .backgroundColor($r('app.color.tentacle_accent_soft'))
              Text(ref.path)
                .fontSize(12.5)
                .fontFamily('monospace')
                .fontColor($r('app.color.tentacle_text'))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .borderRadius(10)
            .onClick(() => this.insertReference(ref))
          }
        }, (ref: DshReferenceCandidate) => ref.path)
      }
      .width('100%')
      .height(Math.min(this.matchedRefs().length * 38 + 8, 190))
      .padding(4)
      .borderRadius(16)
      .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
      .backgroundColor('#E62B241C')
      .border({ width: 0.75, color: $r('app.color.tentacle_border_strong') })
      .shadow({ radius: 18, color: '#66000000', offsetX: 0, offsetY: 6 })
      .onTouch((ev: TouchEvent) => {
        if (ev.type === TouchType.Down && this.blurTimer >= 0) {
          clearTimeout(this.blurTimer);
          this.blurTimer = -1;
        }
      })
    }
  }

  @Builder
  QueuedStrip() {
    if (this.queuedItems.length > 0) {
      Column({ space: 4 }) {
        ForEach(this.queuedItems, (q: DshQueuedItem) => {
          Row({ space: 6 }) {
            Text(q.placement === 'steering' ? '插话' : '队列')
              .fontSize(10)
              .fontWeight(FontWeight.Medium)
              .fontColor(q.placement === 'steering' ? '#FFFFFF' : $r('app.color.tentacle_accent'))
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(6)
              .backgroundColor(q.placement === 'steering' ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_accent_soft'))

            Text(q.text)
              .fontSize(12)
              .fontColor($r('app.color.tentacle_text_dim'))
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            if (q.placement !== 'steering') {
              Text('插话')
                .fontSize(11)
                .fontColor($r('app.color.tentacle_accent'))
                .padding({ left: 6, right: 6, top: 3, bottom: 3 })
                .borderRadius(6)
                .backgroundColor($r('app.color.tentacle_bg_hover'))
                .onClick(() => this.onUpdateQueue(q.id, 'steer'))
            }

            Text('✕')
              .fontSize(11)
              .fontColor($r('app.color.tentacle_text_faint'))
              .padding({ left: 6, right: 6, top: 3, bottom: 3 })
              .onClick(() => this.onUpdateQueue(q.id, 'remove'))
          }
          .width('100%')
          .padding({ left: 10, right: 8, top: 6, bottom: 6 })
          .borderRadius(12)
          .backgroundColor('#E629241E')
          .border({ width: 0.5, color: $r('app.color.tentacle_border') })
        }, (q: DshQueuedItem) => q.id)
      }.width('100%')
    }
  }

  build() {
    Column({ space: 6 }) {
      this.QueuedStrip()
      this.PopupCandidates()

      // 悬浮毛玻璃胶囊主体
      Column({ space: 6 }) {
        if (this.attachments.length > 0) {
          Scroll() {
            Row({ space: 6 }) {
              ForEach(this.attachments, (att: DshPendingAttachment) => {
                Row({ space: 5 }) {
                  Text(att.uploading ? '上传中' : (att.error.length > 0 ? '!' : (att.isImage ? '图' : '文')))
                    .fontSize(10.5)
                    .fontColor(att.error.length > 0 ? $r('app.color.tentacle_danger') : $r('app.color.tentacle_accent'))
                  Text(att.name || '附件')
                    .fontSize(11.5)
                    .fontColor($r('app.color.tentacle_text'))
                    .maxLines(1)
                    .constraintSize({ maxWidth: 120 })
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text('×')
                    .fontSize(12)
                    .fontColor($r('app.color.tentacle_text_faint'))
                    .onClick(() => this.onRemoveAttachment(att.id))
                }
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .borderRadius(999)
                .backgroundColor($r('app.color.tentacle_bg_hover'))
                .border({ width: 0.5, color: att.error.length > 0 ? $r('app.color.tentacle_danger') : $r('app.color.tentacle_border') })
              }, (att: DshPendingAttachment) => att.id)
            }
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
          .width(36)
          .height(36)
          .borderRadius(18)
          .justifyContent(FlexAlign.Center)
          .backgroundColor($r('app.color.tentacle_bg_hover'))
          .onClick(() => {
            this.attachMenuOpen = !this.attachMenuOpen;
          })

          TextArea({
            text: this.draftText,
            placeholder: this.running ? '生成中，可继续输入并入队…' : '发消息，/ 命令，@ 文件…',
            controller: this.textController
          })
            .id('dshComposerInput')
            .onChange((v: string) => {
              this.draftText = v;
              const tok = this.activeAtToken();
              if (tok !== null) {
                if (this.refQueryTimer >= 0) {
                  clearTimeout(this.refQueryTimer);
                }
                this.refQueryTimer = setTimeout(() => {
                  this.refQueryTimer = -1;
                  this.onQueryRefs(tok);
                }, 180);
              }
            })
            .onFocus(() => {
              if (this.blurTimer >= 0) {
                clearTimeout(this.blurTimer);
                this.blurTimer = -1;
              }
              this.inputFocused = true;
            })
            .onBlur(() => {
              this.blurTimer = setTimeout(() => {
                this.inputFocused = false;
                this.blurTimer = -1;
              }, 260);
            })
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

          if (this.running && this.hasReadyContent()) {
            Text('插话')
              .fontSize(11.5)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.tentacle_accent'))
              .padding({ left: 9, right: 9, top: 8, bottom: 8 })
              .borderRadius(16)
              .backgroundColor($r('app.color.tentacle_accent_soft'))
              .onClick(() => this.triggerSubmit('steer'))
          }

          Column() {
            Text(this.running && !this.hasReadyContent() ? '■' : '↑')
              .fontSize(this.running && !this.hasReadyContent() ? 13 : 16.5)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
          }
          .width(36)
          .height(36)
          .borderRadius(18)
          .justifyContent(FlexAlign.Center)
          .linearGradient({
            angle: 180,
            colors: this.running && !this.hasReadyContent()
              ? [['#CF6A5F', 0], ['#B6544A', 1]]
              : [['#D97757', 0], ['#E58E6E', 1]]
          })
          .opacity(this.actionEnabled() ? 1 : 0.35)
          .enabled(this.actionEnabled())
          .onClick(() => {
            if (this.running && !this.hasReadyContent()) {
              this.onCancel();
            } else {
              this.triggerSubmit('queue');
            }
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)

        // 紧凑工具芯片行（附件展开选项或 命令 / 引用 快捷触发）
        if (this.attachMenuOpen) {
          Row({ space: 8 }) {
            Text('相册图片')
              .fontSize(12)
              .fontColor($r('app.color.tentacle_text'))
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .borderRadius(999)
              .backgroundColor($r('app.color.tentacle_bg_hover'))
              .onClick(() => {
                this.attachMenuOpen = false;
                this.onPickPhoto();
              })
            Text('本机文件')
              .fontSize(12)
              .fontColor($r('app.color.tentacle_text'))
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .borderRadius(999)
              .backgroundColor($r('app.color.tentacle_bg_hover'))
              .onClick(() => {
                this.attachMenuOpen = false;
                this.onPickFile();
              })
            Blank()
            Text('收起')
              .fontSize(11.5)
              .fontColor($r('app.color.tentacle_text_faint'))
              .padding({ right: 6 })
              .onClick(() => {
                this.attachMenuOpen = false;
              })
          }.width('100%').padding({ left: 4, right: 4, top: 2 })
        } else {
          Row({ space: 6 }) {
            Text('/ 命令')
              .fontSize(11)
              .fontColor($r('app.color.tentacle_text_dim'))
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .borderRadius(999)
              .backgroundColor($r('app.color.tentacle_bg_hover'))
              .onClick(() => {
                if (!this.draftText.trimStart().startsWith('/')) {
                  this.draftText = '/' + this.draftText;
                }
                this.focusInput();
                if (this.commands.length === 0) {
                  this.onRefreshCommands();
                }
              })

            Text('@ 文件')
              .fontSize(11)
              .fontColor($r('app.color.tentacle_text_dim'))
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .borderRadius(999)
              .backgroundColor($r('app.color.tentacle_bg_hover'))
              .onClick(() => {
                const needSpace = this.draftText.length > 0 && !this.draftText.endsWith(' ') && !this.draftText.endsWith('\n');
                this.draftText = this.draftText + (needSpace ? ' @' : '@');
                this.focusInput();
                this.onQueryRefs('');
              })

            Blank()

            if (this.running) {
              Row({ space: 4 }) {
                Column().width(5).height(5).borderRadius(2.5).backgroundColor($r('app.color.tentacle_accent'))
                Text('运行中')
                  .fontSize(10.5)
                  .fontColor($r('app.color.tentacle_accent'))
              }
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            }
          }.width('100%').padding({ left: 4, right: 4 })
        }
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
      .borderRadius(22)
      .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
      .backgroundColor('#E62B241C')
      .border({ width: 0.75, color: $r('app.color.tentacle_border_strong') })
      .shadow({ radius: 22, color: '#66000000', offsetX: 0, offsetY: 8 })
    }
    .width('100%')
    .padding({ left: 10, right: 10, bottom: 10, top: 4 })
  }
}
