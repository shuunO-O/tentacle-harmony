/**
 * DSH 轻量底部弹窗组件集：
 * 1. DshModelEffortSheet：页内同屏切换模型与思考强度（direct selectModel，不跳设置）
 * 2. DshStepDetailSheet：轨迹单步详情弹窗（概览 / 预览 / Raw JSON）
 * 3. DshNewSessionSheet：选择已有工作区或在受控 workspace 下浏览/新建目录创建会话
 */

import { LengthMetrics } from '@kit.ArkUI';
import {
  DshDirectoryEntry,
  DshDirectoryListing,
  DshModelGroup,
  DshModelOption,
  DshModelSelection,
  DshTrajectoryStep,
  DshWorkspace,
  formatDurationCompact,
  formatTokensCompact
} from './DshModels';
import { ActionButton, FeedbackBanner, SectionTitle } from '../components/UiKit';

@Component
export struct DshModelEffortSheet {
  @Prop @Watch('syncSelectionFromProps') groups: DshModelGroup[] = [];
  @Prop currentSelection?: DshModelSelection = undefined;
  @State selectedProvider: string = '';
  @State selectedModelId: string = '';
  @State selectedEffort: string = '';
  @State saving: boolean = false;
  @State errText: string = '';

  onApply: (provider: string, modelId: string, effort: string) => Promise<void> = async () => {};
  onClose: () => void = () => {};

  aboutToAppear(): void {
    this.syncSelectionFromProps();
  }

  private syncSelectionFromProps(): void {
    if (this.selectedModelId.length > 0) {
      return;
    }
    if (this.currentSelection !== undefined) {
      this.selectedProvider = this.currentSelection.provider;
      this.selectedModelId = this.currentSelection.model;
      this.selectedEffort = this.currentSelection.reasoningEffort;
    } else if (this.groups.length > 0 && this.groups[0].models.length > 0) {
      const first = this.groups[0].models[0];
      this.selectedProvider = first.provider;
      this.selectedModelId = first.modelId;
      this.selectedEffort = first.defaultEffort;
    }
  }

  private findSelectedModel(): DshModelOption | undefined {
    const groups = this.groups;
    const targetProvider = this.selectedProvider;
    const targetModelId = this.selectedModelId;
    for (let g = 0; g < groups.length; g++) {
      const models = groups[g].models;
      for (let m = 0; m < models.length; m++) {
        const mod = models[m];
        if (mod.provider === targetProvider && mod.modelId === targetModelId) {
          return mod;
        }
      }
    }
    return undefined;
  }

  private pickModel(mod: DshModelOption): void {
    this.selectedProvider = mod.provider;
    this.selectedModelId = mod.modelId;
    if (mod.efforts.length === 0) {
      this.selectedEffort = '';
    } else if (mod.efforts.indexOf(this.selectedEffort) < 0) {
      this.selectedEffort = mod.defaultEffort.length > 0 ? mod.defaultEffort : mod.efforts[0];
    }
  }

  private async confirmApply(): Promise<void> {
    if (this.selectedProvider.length === 0 || this.selectedModelId.length === 0 || this.saving) {
      return;
    }
    this.saving = true;
    this.errText = '';
    try {
      await this.onApply(this.selectedProvider, this.selectedModelId, this.selectedEffort);
      this.onClose();
    } catch (e) {
      this.errText = (e as Error).message;
    } finally {
      this.saving = false;
    }
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Text('模型与思考强度')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.tentacle_text'))
          .layoutWeight(1)
        Text('关闭')
          .fontSize(13)
          .fontColor($r('app.color.tentacle_text_dim'))
          .padding(8)
          .onClick(() => this.onClose())
      }.width('100%')

      if (this.errText.length > 0) {
        FeedbackBanner({ text: this.errText, tone: 'danger' })
      }

      if (this.findSelectedModel() !== undefined && (this.findSelectedModel() as DshModelOption).efforts.length > 0) {
        Column({ space: 6 }) {
          Text('思考强度')
            .fontSize(12)
            .fontColor($r('app.color.tentacle_text_dim'))
            .width('100%')
          Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
            ForEach((this.findSelectedModel() as DshModelOption).efforts, (eff: string) => {
              Text(eff)
                .fontSize(12.5)
                .fontWeight(this.selectedEffort === eff ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(this.selectedEffort === eff ? '#FFFFFF' : $r('app.color.tentacle_text'))
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .borderRadius(999)
                .backgroundColor(this.selectedEffort === eff
                  ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_bg_hover'))
                .border({
                  width: 0.75,
                  color: this.selectedEffort === eff
                    ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_border')
                })
                .onClick(() => {
                  this.selectedEffort = eff;
                })
            }, (eff: string) => eff)
          }.width('100%')
        }
        .width('100%')
        .padding(10)
        .borderRadius(12)
        .backgroundColor($r('app.color.tentacle_bg_input'))
      }

      Scroll() {
        Column({ space: 12 }) {
          if (this.groups.length === 0) {
            Text('未获取到可选模型目录')
              .fontSize(13)
              .fontColor($r('app.color.tentacle_text_faint'))
              .padding(24)
              .width('100%')
              .textAlign(TextAlign.Center)
          } else {
            ForEach(this.groups, (grp: DshModelGroup) => {
              Column({ space: 6 }) {
                SectionTitle({ title: grp.name })
                ForEach(grp.models, (mod: DshModelOption) => {
                  Row({ space: 10 }) {
                    Column({ space: 3 }) {
                      Text(mod.modelName)
                        .fontSize(14)
                        .fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.tentacle_text'))
                      if (mod.description.length > 0) {
                        Text(mod.description)
                          .fontSize(11.5)
                          .fontColor($r('app.color.tentacle_text_faint'))
                          .maxLines(2)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                      }
                    }.layoutWeight(1).alignItems(HorizontalAlign.Start)

                    if (this.selectedProvider === mod.provider && this.selectedModelId === mod.modelId) {
                      Text('✓')
                        .fontSize(14)
                        .fontWeight(FontWeight.Bold)
                        .fontColor($r('app.color.tentacle_accent'))
                    }
                  }
                  .width('100%')
                  .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                  .borderRadius(11)
                  .backgroundColor(this.selectedProvider === mod.provider && this.selectedModelId === mod.modelId
                    ? $r('app.color.tentacle_accent_soft') : $r('app.color.tentacle_bg_elevated'))
                  .border({
                    width: 0.75,
                    color: this.selectedProvider === mod.provider && this.selectedModelId === mod.modelId
                      ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_border')
                  })
                  .onClick(() => this.pickModel(mod))
                }, (mod: DshModelOption) => mod.provider + ':' + mod.modelId)
              }.width('100%')
            }, (grp: DshModelGroup) => grp.id)
          }
        }.width('100%').padding({ bottom: 8 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      ActionButton({
        label: this.saving ? '正在应用…' : '应用到当前会话',
        tone: 'primary',
        fullWidth: true,
        isEnabled: !this.saving && this.selectedModelId.length > 0,
        onTap: () => {
          this.confirmApply();
        }
      })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 18, right: 18, top: 10, bottom: 20 })
    .backgroundColor($r('app.color.tentacle_bg_card'))
  }
}

@Component
export struct DshStepDetailSheet {
  @Prop step: DshTrajectoryStep | null = null;
  @State tab: string = 'overview'; // 'overview' | 'preview' | 'raw'
  onClose: () => void = () => {};

  build() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 2 }) {
          Text(this.step !== null ? this.step.label : '步骤详情')
            .fontSize(16.5)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.tentacle_text'))
          if (this.step !== null && this.step.seq > 0) {
            Text('Turn #' + this.step.turnNumber.toString() + ' · seq ' + this.step.seq.toString())
              .fontSize(11)
              .fontFamily('monospace')
              .fontColor($r('app.color.tentacle_text_faint'))
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)

        Text('关闭')
          .fontSize(13)
          .fontColor($r('app.color.tentacle_text_dim'))
          .padding(8)
          .onClick(() => this.onClose())
      }.width('100%')

      Row({ space: 8 }) {
        this.TabPill('overview', '概览')
        this.TabPill('preview', '预览')
        this.TabPill('raw', 'Raw JSON')
      }.width('100%')

      Scroll() {
        Column({ space: 10 }) {
          if (this.step !== null) {
            if (this.tab === 'overview') {
              this.OverviewField('类别', this.step.kind)
              if (this.step.model.length > 0) {
                this.OverviewField('模型', this.step.model)
              }
              this.OverviewField('耗时', this.step.durationMs > 0 ? formatDurationCompact(this.step.durationMs) : '—')
              if (this.step.tokensIn > 0 || this.step.tokensOut > 0) {
                this.OverviewField('Tokens', '输入 ' + formatTokensCompact(this.step.tokensIn)
                  + ' · 输出 ' + formatTokensCompact(this.step.tokensOut)
                  + (this.step.tokensCacheRead > 0 ? ' · 缓存 ' + formatTokensCompact(this.step.tokensCacheRead) : ''))
              }
              if (this.step.at > 0) {
                this.OverviewField('时间', new Date(this.step.at).toLocaleTimeString())
              }
              if (this.step.summary.length > 0) {
                this.OverviewField('摘要', this.step.summary)
              }
            } else if (this.tab === 'preview') {
              Text(this.step.previewText.length > 0 ? this.step.previewText : '（无预览正文）')
                .fontSize(12.5)
                .lineHeight(20)
                .fontColor($r('app.color.tentacle_text'))
                .width('100%')
                .copyOption(CopyOptions.LocalDevice)
            } else {
              Text(this.step.rawJson.length > 0 ? this.step.rawJson : '{}')
                .fontSize(11.5)
                .lineHeight(18)
                .fontFamily('monospace')
                .fontColor($r('app.color.tentacle_text_dim'))
                .width('100%')
                .copyOption(CopyOptions.LocalDevice)
            }
          }
        }.width('100%').padding(12).borderRadius(12).backgroundColor($r('app.color.tentacle_bg_input'))
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 18, right: 18, top: 10, bottom: 20 })
    .backgroundColor($r('app.color.tentacle_bg_card'))
  }

  @Builder
  TabPill(key: string, label: string) {
    Text(label)
      .fontSize(12.5)
      .fontWeight(this.tab === key ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.tab === key ? '#FFFFFF' : $r('app.color.tentacle_text_dim'))
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .borderRadius(999)
      .backgroundColor(this.tab === key ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_bg_hover'))
      .onClick(() => {
        this.tab = key;
      })
  }

  @Builder
  OverviewField(name: string, val: string) {
    Row({ space: 10 }) {
      Text(name)
        .fontSize(12)
        .fontColor($r('app.color.tentacle_text_faint'))
        .width(64)
      Text(val)
        .fontSize(12.5)
        .fontColor($r('app.color.tentacle_text'))
        .layoutWeight(1)
        .copyOption(CopyOptions.LocalDevice)
    }.width('100%').alignItems(VerticalAlign.Top)
  }
}

@Component
export struct DshNewSessionSheet {
  @Prop workspaces: DshWorkspace[] = [];
  @State mode: string = 'dir'; // 'workspace' | 'dir'
  @State listing: DshDirectoryListing = { path: '', home: '', crumbs: [], entries: [], truncated: false };
  @State loadingDir: boolean = false;
  @State creatingDir: boolean = false;
  @State newDirName: string = '';
  @State submitting: boolean = false;
  @State errText: string = '';

  onLoadDir: (path: string) => Promise<DshDirectoryListing> = async () => ({
    path: '', home: '', crumbs: [], entries: [], truncated: false
  });
  onCreateDir: (parentPath: string, name: string) => Promise<string> = async () => '';
  onCreateSession: (dirPath: string, workspaceId: string) => Promise<void> = async () => {};
  onClose: () => void = () => {};

  aboutToAppear(): void {
    this.mode = this.workspaces.length > 0 ? 'workspace' : 'dir';
    this.browse('');
  }

  private async browse(path: string): Promise<void> {
    this.loadingDir = true;
    this.errText = '';
    try {
      this.listing = await this.onLoadDir(path);
    } catch (e) {
      this.errText = (e as Error).message;
    } finally {
      this.loadingDir = false;
    }
  }

  private async handleMakeDir(): Promise<void> {
    const clean = this.newDirName.trim();
    if (clean.length === 0 || this.listing.path.length === 0 || this.submitting) {
      return;
    }
    this.submitting = true;
    this.errText = '';
    try {
      const nextPath = await this.onCreateDir(this.listing.path, clean);
      this.newDirName = '';
      this.creatingDir = false;
      await this.browse(nextPath.length > 0 ? nextPath : this.listing.path);
    } catch (e) {
      this.errText = (e as Error).message;
    } finally {
      this.submitting = false;
    }
  }

  private async handleCreate(path: string, workspaceId: string): Promise<void> {
    if (this.submitting) {
      return;
    }
    this.submitting = true;
    this.errText = '';
    try {
      await this.onCreateSession(path, workspaceId);
    } catch (e) {
      this.errText = (e as Error).message;
      this.submitting = false;
    }
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Text('新建编码会话')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.tentacle_text'))
          .layoutWeight(1)
        Text('关闭')
          .fontSize(13)
          .fontColor($r('app.color.tentacle_text_dim'))
          .padding(8)
          .onClick(() => this.onClose())
      }.width('100%')

      if (this.workspaces.length > 0) {
        Row({ space: 8 }) {
          Text('已有工作区')
            .fontSize(12.5)
            .fontWeight(this.mode === 'workspace' ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.mode === 'workspace' ? '#FFFFFF' : $r('app.color.tentacle_text_dim'))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(999)
            .backgroundColor(this.mode === 'workspace' ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_bg_hover'))
            .onClick(() => {
              this.mode = 'workspace';
            })
          Text('浏览工作目录')
            .fontSize(12.5)
            .fontWeight(this.mode === 'dir' ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.mode === 'dir' ? '#FFFFFF' : $r('app.color.tentacle_text_dim'))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(999)
            .backgroundColor(this.mode === 'dir' ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_bg_hover'))
            .onClick(() => {
              this.mode = 'dir';
              if (this.listing.path.length === 0) {
                this.browse('');
              }
            })
        }.width('100%')
      }

      if (this.errText.length > 0) {
        FeedbackBanner({ text: this.errText, tone: 'danger' })
      }

      if (this.mode === 'workspace' && this.workspaces.length > 0) {
        Scroll() {
          Column({ space: 8 }) {
            ForEach(this.workspaces, (ws: DshWorkspace) => {
              Row({ space: 10 }) {
                Column({ space: 3 }) {
                  Text(ws.title)
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.tentacle_text'))
                  Text(ws.path)
                    .fontSize(11)
                    .fontFamily('monospace')
                    .fontColor($r('app.color.tentacle_text_faint'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)

                Text('新建 ›')
                  .fontSize(12.5)
                  .fontColor($r('app.color.tentacle_accent'))
              }
              .width('100%')
              .padding(12)
              .borderRadius(12)
              .backgroundColor($r('app.color.tentacle_bg_elevated'))
              .border({ width: 0.75, color: $r('app.color.tentacle_border') })
              .onClick(() => this.handleCreate(ws.path, ws.workspaceId))
            }, (ws: DshWorkspace) => ws.workspaceId || ws.path)
          }.width('100%')
        }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
      } else {
        // 受控 workspace 目录选择器
        if (this.listing.path.length > 0) {
          Scroll() {
            Row({ space: 6 }) {
              ForEach(this.listing.crumbs, (c: DshDirectoryEntry, idx: number) => {
                Text((idx > 0 ? '› ' : '') + c.name)
                  .fontSize(11.5)
                  .fontColor($r('app.color.tentacle_accent'))
                  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .borderRadius(8)
                  .backgroundColor($r('app.color.tentacle_bg_hover'))
                  .onClick(() => this.browse(c.path))
              }, (c: DshDirectoryEntry) => c.path)
            }
          }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
        }

        if (this.creatingDir) {
          Row({ space: 8 }) {
            TextInput({ text: this.newDirName, placeholder: '输入新目录名…' })
              .layoutWeight(1)
              .height(38)
              .fontSize(13)
              .fontColor($r('app.color.tentacle_text'))
              .backgroundColor($r('app.color.tentacle_bg_input'))
              .onChange((v: string) => {
                this.newDirName = v;
              })
            ActionButton({
              label: '创建',
              tone: 'primary',
              compact: true,
              isEnabled: !this.submitting && this.newDirName.trim().length > 0,
              onTap: () => {
                this.handleMakeDir();
              }
            })
            ActionButton({
              label: '取消',
              tone: 'ghost',
              compact: true,
              onTap: () => {
                this.creatingDir = false;
                this.newDirName = '';
              }
            })
          }.width('100%')
        }

        Scroll() {
          Column({ space: 6 }) {
            if (this.loadingDir) {
              Text('正在加载目录…').fontSize(13).fontColor($r('app.color.tentacle_text_faint')).padding(24)
            } else if (this.listing.entries.length === 0) {
              Text('当前目录下暂无子文件夹').fontSize(12.5).fontColor($r('app.color.tentacle_text_faint')).padding(20)
            } else {
              ForEach(this.listing.entries, (entry: DshDirectoryEntry) => {
                Row({ space: 10 }) {
                  Text('▸').fontSize(12).fontColor($r('app.color.tentacle_accent'))
                  Text(entry.name)
                    .fontSize(13.5)
                    .fontColor($r('app.color.tentacle_text'))
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text('进入').fontSize(11.5).fontColor($r('app.color.tentacle_text_faint'))
                }
                .width('100%')
                .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                .borderRadius(10)
                .backgroundColor($r('app.color.tentacle_bg_elevated'))
                .onClick(() => this.browse(entry.path))
              }, (entry: DshDirectoryEntry) => entry.path)
            }
          }.width('100%')
        }.width('100%').layoutWeight(1).scrollBar(BarState.Off)

        Row({ space: 8 }) {
          ActionButton({
            label: '+ 新建目录',
            tone: 'secondary',
            isEnabled: !this.submitting && this.listing.path.length > 0,
            onTap: () => {
              this.creatingDir = !this.creatingDir;
            }
          })
          ActionButton({
            label: this.submitting ? '正在创建…' : '在当前目录新建会话',
            tone: 'primary',
            isEnabled: !this.submitting && this.listing.path.length > 0,
            onTap: () => {
              this.handleCreate(this.listing.path, '');
            }
          })
        }.width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 18, right: 18, top: 10, bottom: 20 })
    .backgroundColor($r('app.color.tentacle_bg_card'))
  }
}
