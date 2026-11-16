/**
 * 单个消息气泡组件
 *
 * 必须抽离成独立组件并配合 @ObjectLink，ArkTS 才能观察到 Bubble.text 的流式增量变化。
 * 视觉：左上收角不对称圆角 + 卡片面 + 平台胶囊标签 + 流式光标。
 */

import { Bubble } from '../model/Types';
import { CursorBlink, enterFade } from './UiKit';
import { MessagePart, reconcileMessageParts, messagePartKey } from '../model/FileMarkers';
import { MessagePartItem } from './MessagePartItem';

@Component
export struct BubbleItem {
  @ObjectLink @Watch('syncParts') bubble: Bubble;
  onContentChange: () => void = () => {};
  @State parts: MessagePart[] = [];

  aboutToAppear(): void { this.syncParts(); }

  private syncParts(): void {
    const next = reconcileMessageParts(this.parts, this.bubble.text);
    if (next.length !== this.parts.length || next.some((part: MessagePart, i: number) => part !== this.parts[i])) {
      this.parts = next;
    }
  }

  build() {
    Column({ space: 5 }) {
      if (this.bubble.platform.length > 0 && this.bubble.platform !== 'web' &&
        this.bubble.platform !== 'harmony') {
        Text(this.bubble.platform)
          .fontSize(10)
          .fontColor($r('app.color.tentacle_accent'))
          .backgroundColor($r('app.color.tentacle_accent_soft'))
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(999)
      }
      ForEach(this.parts, (part: MessagePart) => {
        MessagePartItem({ part: part, onContentChange: this.onContentChange })
      }, (part: MessagePart, i: number) => messagePartKey(part, i))
      if (this.bubble.streaming) {
        Row() {
          CursorBlink()
        }
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor($r('app.color.tentacle_agent_bubble'))
    .borderRadius({
      topLeft: 4,
      topRight: 16,
      bottomLeft: 16,
      bottomRight: 16
    })
    .border({ width: 0.5, color: $r('app.color.tentacle_agent_border') })
    .alignItems(HorizontalAlign.Start)
    .transition(enterFade())
  }
}
