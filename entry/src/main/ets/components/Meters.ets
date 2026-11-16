/**
 * 潜意识属性仪表（label + 进度条）
 */

@Component
export struct Meter {
  @Prop label: string = '';
  @Prop value: number = 0;
  @Prop color: ResourceColor = $r('app.color.tentacle_accent');

  private clamped(): number {
    let v = this.value;
    if (v < 0) {
      v = 0;
    }
    if (v > 100) {
      v = 100;
    }
    return v;
  }

  build() {
    Column({ space: 4 }) {
      Row() {
        Text(this.label)
          .fontSize(13)
          .fontColor($r('app.color.tentacle_text_dim'))
        Blank()
        Text(this.value.toFixed(1))
          .fontSize(13)
          .fontColor($r('app.color.tentacle_text'))
      }
      .width('100%')

      Progress({ value: this.clamped(), total: 100, type: ProgressType.Linear })
        .color(this.color)
        .backgroundColor($r('app.color.tentacle_bg_input'))
        .style({ strokeWidth: 6 })
        .width('100%')
        .height(6)
    }
    .width('100%')
  }
}
