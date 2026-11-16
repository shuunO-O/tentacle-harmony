/**
 * 键值统计行（状态页通用）
 */

@Component
export struct StatRow {
  @Prop k: string = '';
  @Prop v: string = '';

  build() {
    Row() {
      Text(this.k)
        .fontSize(12.5)
        .fontColor($r('app.color.tentacle_text_dim'))
      Blank()
      Text(this.v)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.tentacle_text'))
        .textAlign(TextAlign.End)
        .constraintSize({ maxWidth: '70%' })
    }
    .width('100%')
    .padding({ top: 5, bottom: 5 })
  }
}
