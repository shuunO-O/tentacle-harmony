/**
 * UI 视觉基座：卡片 / 标题 / 按钮 / 徽标 / 轻提示 / 动效小组件
 *
 * 全局统一的暖调低眩光视觉语言（消除原生蓝底默认 Button 与生硬排版）：
 * - AppCard：带发丝边框的卡片面，替代散落的裸 elevated 容器
 * - SectionTitle：accent 竖条 + 文字的分区标题
 * - ActionButton：语义化紧凑按钮（primary / secondary / ghost / danger）
 * - StatusPill：圆角状态徽标（default / accent / ok / warn / danger）
 * - FeedbackBanner：页面内提示/报错横幅
 * - PrimaryButton / GhostButton / DotTyping / CursorBlink / EmptyState / enterFade()
 */

@Builder
function emptyBuilder() {
}

// 统一入场转场：淡入 + 轻微上移
export function enterFade(): TransitionEffect {
  return TransitionEffect.OPACITY
    .combine(TransitionEffect.translate({ y: 8 }))
    .animation({ duration: 240, curve: Curve.EaseOut });
}

@Component
export struct ActionButton {
  @Prop label: string = '';
  @Prop tone: string = 'secondary'; // 'primary' | 'secondary' | 'ghost' | 'danger'
  @Prop compact: boolean = false;
  @Prop isEnabled: boolean = true;
  @Prop fullWidth: boolean = false;
  onTap: () => void = () => {
  };

  private textColor(): ResourceColor {
    if (this.tone === 'primary') {
      return '#FFFFFF';
    }
    if (this.tone === 'danger') {
      return $r('app.color.tentacle_danger');
    }
    if (this.tone === 'accent') {
      return $r('app.color.tentacle_accent');
    }
    if (this.tone === 'ghost') {
      return $r('app.color.tentacle_text_dim');
    }
    return $r('app.color.tentacle_text');
  }

  private bgColor(): ResourceColor {
    if (this.tone === 'primary') {
      return $r('app.color.tentacle_accent');
    }
    if (this.tone === 'danger') {
      return '#26CF6A5F';
    }
    if (this.tone === 'accent') {
      return $r('app.color.tentacle_accent_soft');
    }
    if (this.tone === 'ghost') {
      return Color.Transparent;
    }
    return $r('app.color.tentacle_bg_hover');
  }

  private resolveBorderColor(): ResourceColor {
    if (this.tone === 'danger') {
      return '#55CF6A5F';
    }
    if (this.tone === 'ghost') {
      return $r('app.color.tentacle_border_strong');
    }
    if (this.tone === 'secondary') {
      return $r('app.color.tentacle_border');
    }
    return Color.Transparent;
  }

  build() {
    Button(this.label, { type: ButtonType.Normal })
      .fontSize(this.compact ? 12 : 13)
      .fontWeight(FontWeight.Medium)
      .height(this.compact ? 30 : 36)
      .borderRadius(this.compact ? 9 : 11)
      .fontColor(this.textColor())
      .backgroundColor(this.bgColor())
      .border({
        width: this.tone === 'primary' || this.tone === 'accent' ? 0 : 0.75,
        color: this.resolveBorderColor()
      })
      .padding({ left: this.compact ? 10 : 14, right: this.compact ? 10 : 14 })
      .width(this.fullWidth ? '100%' : 'auto')
      .opacity(this.isEnabled ? 1 : 0.4)
      .enabled(this.isEnabled)
      .onClick(() => {
        if (this.isEnabled) {
          this.onTap();
        }
      })
  }
}

@Component
export struct StatusPill {
  @Prop label: string = '';
  @Prop tone: string = 'default'; // 'default' | 'accent' | 'ok' | 'warn' | 'danger'

  private textColor(): ResourceColor {
    if (this.tone === 'ok') {
      return $r('app.color.tentacle_ok');
    }
    if (this.tone === 'danger') {
      return $r('app.color.tentacle_danger');
    }
    if (this.tone === 'warn') {
      return '#D4A359';
    }
    if (this.tone === 'accent') {
      return $r('app.color.tentacle_accent');
    }
    return $r('app.color.tentacle_text_dim');
  }

  private bgColor(): ResourceColor {
    if (this.tone === 'ok') {
      return '#247FA66A';
    }
    if (this.tone === 'danger') {
      return '#24CF6A5F';
    }
    if (this.tone === 'warn') {
      return '#24D4A359';
    }
    if (this.tone === 'accent') {
      return $r('app.color.tentacle_accent_soft');
    }
    return $r('app.color.tentacle_bg_hover');
  }

  build() {
    Text(this.label)
      .fontSize(10.5)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.textColor())
      .backgroundColor(this.bgColor())
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .borderRadius(999)
      .maxLines(1)
  }
}

@Component
export struct FeedbackBanner {
  @Prop text: string = '';
  @Prop tone: string = 'info'; // 'info' | 'ok' | 'danger'

  build() {
    if (this.text.length > 0) {
      Row({ space: 8 }) {
        Column()
          .width(4)
          .height(14)
          .borderRadius(2)
          .backgroundColor(this.tone === 'danger' ? $r('app.color.tentacle_danger')
            : this.tone === 'ok' ? $r('app.color.tentacle_ok') : $r('app.color.tentacle_accent'))
        Text(this.text)
          .fontSize(12)
          .lineHeight(18)
          .fontColor(this.tone === 'danger' ? $r('app.color.tentacle_danger')
            : this.tone === 'ok' ? $r('app.color.tentacle_ok') : $r('app.color.tentacle_text'))
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 9, bottom: 9 })
      .borderRadius(12)
      .backgroundColor(this.tone === 'danger' ? '#24CF6A5F'
        : this.tone === 'ok' ? '#207FA66A' : $r('app.color.tentacle_accent_soft'))
      .border({
        width: 0.5,
        color: this.tone === 'danger' ? '#55CF6A5F' : $r('app.color.tentacle_border')
      })
    }
  }
}

@Component
export struct AppCard {
  @BuilderParam content: () => void = emptyBuilder;

  build() {
    Column() {
      this.content()
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(14)
    .backgroundColor($r('app.color.tentacle_bg_card'))
    .borderRadius(16)
    .border({ width: 0.5, color: $r('app.color.tentacle_border') })
  }
}

@Component
export struct SectionTitle {
  @Prop title: string = '';

  build() {
    Row({ space: 8 }) {
      Column()
        .width(3)
        .height(14)
        .borderRadius(2)
        .backgroundColor($r('app.color.tentacle_accent'))
      Text(this.title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.tentacle_text'))
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }
}

@Component
export struct PrimaryButton {
  @Prop label: string = '';
  @Prop isEnabled: boolean = true;
  @Prop busy: boolean = false;
  onTap: () => void = () => {
  };

  build() {
    Column() {
      if (this.busy) {
        LoadingProgress()
          .width(20)
          .height(20)
          .color(Color.White)
      } else {
        Text(this.label)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
      }
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height(44)
    .borderRadius(22)
    .linearGradient({
      angle: 180,
      colors: [['#D97757', 0], ['#E58E6E', 1]]
    })
    .opacity(this.isEnabled ? 1 : 0.35)
    .onClick(() => {
      if (this.isEnabled && !this.busy) {
        this.onTap();
      }
    })
  }
}

@Component
export struct GhostButton {
  @Prop label: string = '';
  @Prop isEnabled: boolean = true;
  onTap: () => void = () => {
  };

  build() {
    Row() {
      Text(this.label)
        .fontSize(14)
        .fontColor($r('app.color.tentacle_text_dim'))
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height(40)
    .borderRadius(20)
    .backgroundColor(Color.Transparent)
    .border({ width: 1, color: $r('app.color.tentacle_border_strong') })
    .opacity(this.isEnabled ? 1 : 0.4)
    .onClick(() => {
      if (this.isEnabled) {
        this.onTap();
      }
    })
  }
}

@Component
export struct DotTyping {
  @State lit0: boolean = false;
  @State lit1: boolean = false;
  @State lit2: boolean = false;
  private timers: number[] = [];

  private clearTimers(): void {
    for (let i = 0; i < this.timers.length; i++) {
      clearTimeout(this.timers[i]);
    }
    this.timers = [];
  }

  aboutToAppear(): void {
    this.timers.push(setTimeout(() => {
      this.lit0 = true;
    }, 0));
    this.timers.push(setTimeout(() => {
      this.lit1 = true;
    }, 150));
    this.timers.push(setTimeout(() => {
      this.lit2 = true;
    }, 300));
  }

  aboutToDisappear(): void {
    this.clearTimers();
  }

  build() {
    Row({ space: 4 }) {
      Column()
        .width(5)
        .height(5)
        .borderRadius(2.5)
        .backgroundColor($r('app.color.tentacle_accent'))
        .opacity(this.lit0 ? 1 : 0.25)
        .animation({
          duration: 480,
          iterations: -1,
          playMode: PlayMode.Alternate,
          curve: Curve.EaseInOut
        })
      Column()
        .width(5)
        .height(5)
        .borderRadius(2.5)
        .backgroundColor($r('app.color.tentacle_accent'))
        .opacity(this.lit1 ? 1 : 0.25)
        .animation({
          duration: 480,
          iterations: -1,
          playMode: PlayMode.Alternate,
          curve: Curve.EaseInOut
        })
      Column()
        .width(5)
        .height(5)
        .borderRadius(2.5)
        .backgroundColor($r('app.color.tentacle_accent'))
        .opacity(this.lit2 ? 1 : 0.25)
        .animation({
          duration: 480,
          iterations: -1,
          playMode: PlayMode.Alternate,
          curve: Curve.EaseInOut
        })
    }
    .alignItems(VerticalAlign.Center)
  }
}

@Component
export struct CursorBlink {
  @State on: boolean = true;
  private timer: number = -1;

  aboutToAppear(): void {
    this.timer = setInterval(() => {
      this.on = !this.on;
    }, 450);
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  build() {
    Text('▍')
      .fontSize(14)
      .fontColor($r('app.color.tentacle_accent'))
      .margin({ left: 1 })
      .opacity(this.on ? 1 : 0)
      .animation({ duration: 220, curve: Curve.EaseOut })
  }
}

@Component
export struct EmptyState {
  @Prop glyph: string = '';
  @Prop title: string = '';
  @Prop hint: string = '';

  build() {
    Column({ space: 10 }) {
      Column() {
        Text(this.glyph)
          .fontSize(18)
          .fontColor($r('app.color.tentacle_accent'))
      }
      .width(40)
      .height(40)
      .borderRadius(12)
      .backgroundColor($r('app.color.tentacle_accent_soft'))
      .justifyContent(FlexAlign.Center)

      Text(this.title)
        .fontSize(14)
        .fontColor($r('app.color.tentacle_text_dim'))

      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(12)
          .fontColor($r('app.color.tentacle_text_faint'))
      }
    }
    .alignItems(HorizontalAlign.Center)
  }
}
