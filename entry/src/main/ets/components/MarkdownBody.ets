import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { MarkdownBlock, MarkdownSpan, MarkdownCell, MarkdownTableRow, parseMarkdown, isMarkdownLink } from '../model/Markdown';
import { notifyToast } from '../model/UiToast';

@Component
export struct MarkdownBody {
  @Prop @Watch('updateContent') content: string = '';
  @State blocks: MarkdownBlock[] = [];
  onContentChange: () => void = () => {};

  aboutToAppear(): void {
    this.updateContent();
  }

  private updateContent(): void {
    this.blocks = parseMarkdown(this.content);
  }

  private openLink(url: string): void {
    if (!isMarkdownLink(url)) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.startAbility({ action: 'ohos.want.action.viewData', uri: url }).catch(() => {
      notifyToast('无法打开链接', 'danger');
    });
  }

  private async copyCode(code: string): Promise<void> {
    if (!code) { return; }
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, code));
      notifyToast('代码已复制', 'ok');
    } catch (_) {
      notifyToast('复制失败', 'danger');
    }
  }

  @Builder
  InlineText(spans: MarkdownSpan[], size: number = 15, strong: boolean = false, align: TextAlign = TextAlign.Start) {
    Text() {
      ForEach(spans, (span: MarkdownSpan, idx: number) => {
        Span(span.text)
          .fontWeight(span.bold || strong ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(span.italic ? FontStyle.Italic : FontStyle.Normal)
          .fontFamily(span.code ? 'monospace' : 'HarmonyOS Sans')
          .fontColor(span.url.length > 0 ? $r('app.color.tentacle_accent') : $r('app.color.tentacle_text'))
          .decoration({ type: span.strike ? TextDecorationType.LineThrough :
            (span.url.length > 0 ? TextDecorationType.Underline : TextDecorationType.None) })
          .textBackgroundStyle({ color: span.code ? $r('app.color.tentacle_bg_input') : Color.Transparent,
            radius: 3 })
          .onClick(() => this.openLink(span.url))
      }, (span: MarkdownSpan, idx: number) => idx.toString() + ':' + span.text + ':' + span.url +
        ':' + span.bold.toString() + span.italic.toString() + span.code.toString() + span.strike.toString())
    }
    .fontSize(size)
    .textAlign(align)
    .lineHeight(size + 7)
    .fontColor($r('app.color.tentacle_text'))
    .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
    .width('100%')
  }

  @Builder
  Table(block: MarkdownBlock) {
    Scroll() {
      Column() {
        ForEach(block.rows, (row: MarkdownTableRow, ri: number) => {
          Row() {
            ForEach(row.cells, (cell: MarkdownCell, ci: number) => {
              Column() {
                this.InlineText(cell.spans, 13, ri === 0, cell.align === 'right' ? TextAlign.End :
                  (cell.align === 'center' ? TextAlign.Center : TextAlign.Start))
              }
              .width(144)
              .padding(10)
              .alignItems(cell.align === 'right' ? HorizontalAlign.End : HorizontalAlign.Start)
              .border({ width: 0.5, color: $r('app.color.tentacle_border') })
            }, (cell: MarkdownCell, ci: number) => ci.toString())
          }
          .backgroundColor(ri === 0 ? $r('app.color.tentacle_bg_input') : Color.Transparent)
          .alignItems(VerticalAlign.Top)
        }, (row: MarkdownTableRow, ri: number) => ri.toString())
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Auto)
    .width('100%')
  }

  build() {
    Column({ space: 8 }) {
      ForEach(this.blocks, (block: MarkdownBlock, idx: number) => {
        if (block.kind === 'code') {
          Column({ space: 6 }) {
            Row() {
              Text(block.language.length > 0 ? block.language : 'code')
                .fontSize(10.5)
                .fontFamily('monospace')
                .fontColor($r('app.color.tentacle_text_faint'))
              Blank()
              Text('复制')
                .fontSize(10.5)
                .fontColor($r('app.color.tentacle_text_dim'))
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .borderRadius(6)
                .backgroundColor($r('app.color.tentacle_bg_hover'))
                .onClick(() => this.copyCode(block.text))
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            Scroll() {
              Text(block.text)
                .fontFamily('monospace')
                .fontSize(13)
                .lineHeight(20)
                .fontColor($r('app.color.tentacle_text'))
                .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Auto)
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(10)
          .backgroundColor($r('app.color.tentacle_bg_input'))
          .borderRadius(8)
        } else if (block.kind === 'table') {
          this.Table(block)
        } else if (block.kind === 'rule') {
          Divider().color($r('app.color.tentacle_border')).margin({ top: 4, bottom: 4 })
        } else if (block.kind === 'list') {
          Row({ space: 8 }) {
            Text(block.prefix)
              .fontSize(15)
              .fontColor($r('app.color.tentacle_text_dim'))
              .constraintSize({ minWidth: 16 })
            Column() {
              this.InlineText(block.spans)
            }
            .layoutWeight(1)
          }
          .padding({ left: block.level * 12 })
          .alignItems(VerticalAlign.Top)
          .width('100%')
        } else if (block.kind === 'quote') {
          Column() {
            this.InlineText(block.spans)
          }
          .width('100%')
          .padding({ left: 10, top: 4, bottom: 4 })
          .border({ width: { left: 3 }, color: $r('app.color.tentacle_accent') })
        } else {
          this.InlineText(block.spans, block.kind === 'heading' ? Math.max(16, 24 - block.level * 2) : 15,
            block.kind === 'heading')
        }
      }, (block: MarkdownBlock, idx: number) => idx.toString() + ':' + block.source)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .onAreaChange((oldArea: Area, newArea: Area) => {
      if (Number(oldArea.height) !== Number(newArea.height)) {
        this.onContentChange();
      }
    })
  }
}
