/**
 * Agent 响应组组件：思考/工具调用折叠块 + 消息气泡
 *
 * 折叠块内联实现（不通过 @Builder 按值传参），保证 @ObjectLink 变更可刷新 UI。
 * 气泡与工具项分别抽离为 BubbleItem / ToolCallItemView，以便 ArkTS 观察到其属性变化。
 */

import { MsgGroup, ToolCallItem, Bubble } from '../model/Types';
import { BubbleItem } from './BubbleItem';
import { ToolCallItemView } from './ToolCallItemView';
import { notifyToast } from '../model/UiToast';
import { pasteboard } from '@kit.BasicServicesKit';

@Component
export struct AgentGroupItem {
  @ObjectLink group: MsgGroup;
  @StorageProp('showReasoning') showReasoning: boolean = false;
  onContentChange: () => void = () => {};
  onInspect: () => void = () => {};

  private async copyReply(): Promise<void> {
    const text = this.group.bubbles.map((bubble: Bubble) => bubble.text)
      .filter((part: string) => part.trim().length > 0).join('\n\n');
    if (!text) { return; }
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text));
      notifyToast('已复制回复内容', 'ok');
    } catch (e) { notifyToast('复制失败', 'danger'); }
  }

  @Builder
  GroupContextMenu() {
    Menu() {
      MenuItem({ content: '复制整条回复' })
        .onClick(() => {
          this.copyReply();
        })
    }
  }

  private fmtTime(ts: number): string {
    if (ts <= 0) {
      return '';
    }
    const d = new Date(ts * 1000);
    const p = (n: number): string => n.toString().padStart(2, '0');
    return p(d.getHours()) + ':' + p(d.getMinutes());
  }

  build() {
    Column({ space: 6 }) {
      if (this.group.interrupted) {
        Text('已中断').fontSize(12).fontColor($r('app.color.tentacle_text_dim')).width('100%')
      }
      if (this.group.isError) {
        Text(this.group.errorText)
          .fontSize(14)
          .fontColor($r('app.color.tentacle_danger'))
          .width('100%')
      }
        if (this.group.time > 0) {
          Text(this.fmtTime(this.group.time))
            .fontSize(10)
            .fontColor($r('app.color.tentacle_text_faint'))
            .width('100%')
        }
        if (this.showReasoning && this.group.reasoning.length > 0) {
          Column({ space: 4 }) {
            Row() {
              Text('思考过程')
                .fontSize(13)
                .fontColor($r('app.color.tentacle_text_dim'))
              Blank()
              Text('▾')
                .fontSize(12)
                .fontColor($r('app.color.tentacle_text_faint'))
                .rotate({ angle: this.group.reasoningOpen ? 180 : 0 })
                .animation({ duration: 200, curve: Curve.EaseOut })
            }
            .width('100%')
            .constraintSize({ minHeight: 32 })
            .onClick(() => {
              this.onInspect();
              this.group.reasoningOpen = !this.group.reasoningOpen;
            })
            if (this.group.reasoningOpen) {
              Text(this.group.reasoning)
                .fontSize(13)
                .fontColor($r('app.color.tentacle_text_dim'))
                .lineHeight(20)
                .width('100%')
            }
          }
          .width('100%')
          .padding(10)
          .backgroundColor($r('app.color.tentacle_bg_input'))
          .borderRadius(10)
          .border({ width: 0.5, color: $r('app.color.tentacle_border') })
        }

        if (this.group.tools.length > 0) {
          Column({ space: 4 }) {
            Row() {
              Text('工具调用（' + this.group.tools.length.toString() + '）')
                .fontSize(13)
                .fontColor($r('app.color.tentacle_text_dim'))
              Blank()
              Text('▾')
                .fontSize(12)
                .fontColor($r('app.color.tentacle_text_faint'))
                .rotate({ angle: this.group.toolsOpen ? 180 : 0 })
                .animation({ duration: 200, curve: Curve.EaseOut })
            }
            .width('100%')
            .constraintSize({ minHeight: 32 })
            .onClick(() => {
              this.onInspect();
              this.group.toolsOpen = !this.group.toolsOpen;
            })
            if (this.group.toolsOpen) {
              ForEach(this.group.tools, (t: ToolCallItem, ti: number) => {
                ToolCallItemView({ tool: t })
              }, (t: ToolCallItem, ti: number) => 'tool' + ti.toString())
            }
          }
          .width('100%')
          .padding(10)
          .backgroundColor($r('app.color.tentacle_bg_input'))
          .borderRadius(10)
          .border({ width: 0.5, color: $r('app.color.tentacle_border') })
        }

        ForEach(this.group.bubbles, (b: Bubble, bi: number) => {
          BubbleItem({ bubble: b, onContentChange: this.onContentChange })
        }, (b: Bubble, bi: number) => 'b' + bi.toString())
    }
    .width('100%')
    .bindContextMenu(this.GroupContextMenu(), ResponseType.LongPress)
    .onAreaChange((oldArea: Area, newArea: Area) => {
      // 思考/工具区域也会增高；仅尺寸变化需要跟随，滚动造成的位置变化不触发。
      if (Number(oldArea.height) !== Number(newArea.height)) {
        this.onContentChange();
      }
    })
  }
}
