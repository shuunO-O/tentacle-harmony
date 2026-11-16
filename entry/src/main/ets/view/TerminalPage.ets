/**
 * 终端页：只读回放 agent 的终端操作输出
 *
 * 参考 WebUI 的 xterm.js 回放体验：
 * - 不显示时间戳，只连续输出原始内容
 * - 过滤 ANSI 转义序列（颜色、光标控制等），避免原生 Text 显示乱码
 * - 提供清空、滚动锁定
 */

import { TentacleApi } from '../service/TentacleApi';
import { TerminalStore, TerminalEntry, terminalStore } from '../model/Types';
import { ActionButton, FeedbackBanner, StatusPill } from '../components/UiKit';

@Component
export struct TerminalPage {
  @State store: TerminalStore = terminalStore;
  @State errText: string = '';
  @State autoScroll: boolean = true;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.loadHistory();
  }

  private async loadHistory(): Promise<void> {
    try {
      const since = this.store.entries.length > 0
        ? this.store.entries[this.store.entries.length - 1].ts
        : 0;
      const res = await TentacleApi.getInstance().getTerminalHistory(since);
      if (res.entries.length > 0) {
        const merged = this.store.entries.concat(res.entries);
        this.store.setHistory(merged);
      }
      this.errText = '';
    } catch (e) {
      this.errText = e.message;
    }
  }

  private clear(): void {
    this.store.clear();
  }

  private toggleAutoScroll(): void {
    this.autoScroll = !this.autoScroll;
  }

  // 过滤 ANSI 转义序列，避免原生 Text 把颜色/光标控制字符显示成乱码
  private stripAnsi(s: string): string {
    return s.replace(/\x1B\[[0-?]*[ -/]*[@-~]/g, '');
  }

  private allContent(): string {
    const parts: string[] = [];
    for (let i = 0; i < this.store.entries.length; i++) {
      parts.push(this.stripAnsi(this.store.entries[i].content));
    }
    return parts.join('');
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        StatusPill({ label: this.autoScroll ? '自动滚动锁定' : '自由浏览', tone: this.autoScroll ? 'accent' : 'default' })
        Blank()
        ActionButton({
          label: this.autoScroll ? '解除锁定' : '锁定底部',
          tone: this.autoScroll ? 'accent' : 'secondary',
          compact: true,
          onTap: () => { this.toggleAutoScroll(); }
        })
        ActionButton({
          label: '清屏',
          tone: 'ghost',
          compact: true,
          onTap: () => { this.clear(); }
        })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 4, bottom: 8 })

      if (this.errText.length > 0) {
        Column() {
          FeedbackBanner({ text: this.errText, tone: 'danger' })
        }.padding({ left: 12, right: 12, bottom: 8 })
      }

      Scroll(this.scroller) {
        Text(this.allContent())
          .fontSize(14)
          .fontColor($r('app.color.tentacle_text_dim'))
          .width('100%')
          .lineHeight(22)
          .padding(12)
      }
      .layoutWeight(1)
      .margin({ left: 12, right: 12, bottom: 12 })
      .borderRadius(12)
      .width('100%')
      .backgroundColor($r('app.color.tentacle_bg_input'))
      .border({ width: 0.5, color: $r('app.color.tentacle_border') })
      .onAreaChange((oldArea, newArea) => {
        if (this.autoScroll) {
          this.scroller.scrollEdge(Edge.Bottom);
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.tentacle_bg'))
  }
}
