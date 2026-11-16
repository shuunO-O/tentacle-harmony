/**
 * 单个工具调用项组件
 *
 * 抽离为独立组件并配合 @ObjectLink，确保 tool_result 回填时 UI 刷新。
 */

import { ToolCallItem } from '../model/Types';
import { parseToolSourceBadge } from '../model/Plugins';

@Component
export struct ToolCallItemView {
  @ObjectLink tool: ToolCallItem;

  build() {
    Column({ space: 3 }) {
      Row({ space: 6 }) {
        Column()
          .width(5)
          .height(5)
          .borderRadius(2.5)
          .backgroundColor($r('app.color.tentacle_accent'))
        Text(this.tool.name)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.tentacle_accent'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (parseToolSourceBadge(this.tool.name).length > 0) {
          Text(parseToolSourceBadge(this.tool.name))
            .fontSize(10)
            .fontColor($r('app.color.tentacle_accent'))
            .backgroundColor($r('app.color.tentacle_accent_soft'))
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(999)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      if (this.tool.arguments.length > 0) {
        Text(this.tool.arguments)
          .fontSize(12)
          .fontColor($r('app.color.tentacle_text_faint'))
          .maxLines(5)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      if (this.tool.hasResult) {
        Text(this.tool.result)
          .fontSize(12)
          .fontColor($r('app.color.tentacle_text_dim'))
          .maxLines(5)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .padding(8)
    .backgroundColor($r('app.color.tentacle_bg_hover'))
    .borderRadius(8)
    .border({ width: 0.5, color: $r('app.color.tentacle_border') })
  }
}
