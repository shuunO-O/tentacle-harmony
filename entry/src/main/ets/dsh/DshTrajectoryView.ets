/**
 * DSH 轨迹标签页（手机端适配版）：
 * - 上方直接渲染可折叠「轮次 / 步骤」时间线（点击单步触发详情弹窗）
 * - 底部固定渲染「耗时占比条 + 总耗时 / TTFT / TPS / Token 统计卡片」
 */

import {
  DshTrajectoryStats,
  DshTrajectoryStep,
  DshTrajectoryTurn,
  formatDurationCompact,
  formatTokensCompact
} from './DshModels';

@Component
export struct DshTrajectoryView {
  @Prop turns: DshTrajectoryTurn[] = [];
  @Prop stats: DshTrajectoryStats = {
    turns: 0,
    steps: 0,
    totalMs: 0,
    thinkingMs: 0,
    toolMs: 0,
    llmMs: 0,
    ttftMs: 0,
    ttftSteps: 0,
    decodeMs: 0,
    decodeTokens: 0,
    tps: 0,
    uncachedInputTokens: 0,
    outputTokens: 0,
    cacheReadTokens: 0,
    cacheWriteTokens: 0
  };
  @State collapsedTurns: Map<string, boolean> = new Map<string, boolean>();
  onSelectStep: (step: DshTrajectoryStep) => void = () => {};

  private isTurnCollapsed(turnId: string): boolean {
    return this.collapsedTurns.get(turnId) === true;
  }

  private toggleTurn(turnId: string): void {
    const next = new Map<string, boolean>();
    this.collapsedTurns.forEach((v: boolean, k: string) => next.set(k, v));
    next.set(turnId, !this.isTurnCollapsed(turnId));
    this.collapsedTurns = next;
  }

  private stepBadgeColor(step: DshTrajectoryStep): ResourceColor {
    if (step.isError || step.kind === 'error') {
      return $r('app.color.tentacle_danger');
    }
    if (step.kind === 'thinking') {
      return '#D4A359';
    }
    if (step.kind === 'tool') {
      return $r('app.color.tentacle_ok');
    }
    if (step.kind === 'text') {
      return $r('app.color.tentacle_accent');
    }
    if (step.kind === 'user') {
      return $r('app.color.tentacle_text');
    }
    return $r('app.color.tentacle_text_faint');
  }

  private stepTag(step: DshTrajectoryStep): string {
    if (step.kind === 'thinking') {
      return '思考';
    }
    if (step.kind === 'tool') {
      return '工具';
    }
    if (step.kind === 'text') {
      return '回复';
    }
    if (step.kind === 'user') {
      return '用户';
    }
    if (step.kind === 'compaction') {
      return '压缩';
    }
    if (step.kind === 'audit') {
      return '审计';
    }
    if (step.kind === 'command') {
      return '命令';
    }
    if (step.kind === 'error') {
      return '错误';
    }
    return '系统';
  }

  private ratioFlex(partMs: number, denomMs: number): number {
    if (denomMs <= 0 || partMs <= 0) {
      return 0;
    }
    return Math.max(4, Math.round((partMs / denomMs) * 100));
  }

  @Builder
  BottomSummaryBar() {
    Column({ space: 8 }) {
      // 比例耗时条
      Column({ space: 5 }) {
        Row() {
          Text(this.stats.turns.toString() + ' 轮次 · ' + this.stats.steps.toString() + ' 步骤')
            .fontSize(11.5)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.tentacle_text'))
          Blank()
          Text('总耗时 ' + formatDurationCompact(this.stats.totalMs))
            .fontSize(11)
            .fontFamily('monospace')
            .fontColor($r('app.color.tentacle_text_dim'))
        }.width('100%')

        Row({ space: 2 }) {
          if (this.stats.totalMs <= 0) {
            Column()
              .height(6)
              .layoutWeight(1)
              .borderRadius(3)
              .backgroundColor($r('app.color.tentacle_bg_hover'))
          } else {
            if (this.stats.thinkingMs > 0) {
              Column()
                .height(6)
                .layoutWeight(this.ratioFlex(this.stats.thinkingMs, this.stats.totalMs))
                .borderRadius(3)
                .backgroundColor('#D4A359')
            }
            if (this.stats.toolMs > 0) {
              Column()
                .height(6)
                .layoutWeight(this.ratioFlex(this.stats.toolMs, this.stats.totalMs))
                .borderRadius(3)
                .backgroundColor($r('app.color.tentacle_ok'))
            }
            if (Math.max(0, this.stats.llmMs - this.stats.thinkingMs) > 0) {
              Column()
                .height(6)
                .layoutWeight(this.ratioFlex(Math.max(0, this.stats.llmMs - this.stats.thinkingMs), this.stats.totalMs))
                .borderRadius(3)
                .backgroundColor($r('app.color.tentacle_accent'))
            }
          }
        }.width('100%')

        Row({ space: 12 }) {
          Row({ space: 4 }) {
            Column().width(6).height(6).borderRadius(3).backgroundColor('#D4A359')
            Text('思考 ' + formatDurationCompact(this.stats.thinkingMs))
              .fontSize(10.5).fontColor($r('app.color.tentacle_text_faint'))
          }
          Row({ space: 4 }) {
            Column().width(6).height(6).borderRadius(3).backgroundColor($r('app.color.tentacle_ok'))
            Text('工具 ' + formatDurationCompact(this.stats.toolMs))
              .fontSize(10.5).fontColor($r('app.color.tentacle_text_faint'))
          }
          Row({ space: 4 }) {
            Column().width(6).height(6).borderRadius(3).backgroundColor($r('app.color.tentacle_accent'))
            Text('生成 ' + formatDurationCompact(Math.max(0, this.stats.llmMs - this.stats.thinkingMs)))
              .fontSize(10.5).fontColor($r('app.color.tentacle_text_faint'))
          }
        }.width('100%')
      }

      Divider().color($r('app.color.tentacle_border'))

      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text('输入 / 输出').fontSize(10).fontColor($r('app.color.tentacle_text_faint'))
          Text(formatTokensCompact(this.stats.uncachedInputTokens) + ' / ' + formatTokensCompact(this.stats.outputTokens))
            .fontSize(11.5).fontFamily('monospace').fontColor($r('app.color.tentacle_text'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)

        Column({ space: 2 }) {
          Text('缓存命中').fontSize(10).fontColor($r('app.color.tentacle_text_faint'))
          Text(formatTokensCompact(this.stats.cacheReadTokens))
            .fontSize(11.5).fontFamily('monospace').fontColor($r('app.color.tentacle_ok'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)

        Column({ space: 2 }) {
          Text('TTFT').fontSize(10).fontColor($r('app.color.tentacle_text_faint'))
          Text(this.stats.ttftMs > 0 ? formatDurationCompact(this.stats.ttftMs) : '—')
            .fontSize(11.5).fontFamily('monospace').fontColor($r('app.color.tentacle_text'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)

        Column({ space: 2 }) {
          Text('TPS').fontSize(10).fontColor($r('app.color.tentacle_text_faint'))
          Text(this.stats.tps > 0 ? (this.stats.tps.toString() + '/s') : '—')
            .fontSize(11.5).fontFamily('monospace').fontColor($r('app.color.tentacle_accent'))
        }.layoutWeight(1).alignItems(HorizontalAlign.End)
      }.width('100%')
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 12 })
    .backgroundColor($r('app.color.tentacle_bg_card'))
    .border({ width: { top: 0.75 }, color: $r('app.color.tentacle_border_strong') })
  }

  build() {
    Column() {
      // 上方直接列出轮次与步骤时间线
      Scroll() {
        Column({ space: 10 }) {
          if (this.turns.length === 0) {
            Text('暂无轨迹记录')
              .fontSize(13)
              .fontColor($r('app.color.tentacle_text_faint'))
              .padding(32)
              .width('100%')
              .textAlign(TextAlign.Center)
          } else {
            ForEach(this.turns, (turn: DshTrajectoryTurn) => {
              Column({ space: 6 }) {
                Row({ space: 8 }) {
                  Text(this.isTurnCollapsed(turn.id) ? '▸' : '▾')
                    .fontSize(12)
                    .fontColor($r('app.color.tentacle_accent'))
                  Text('轮次 #' + turn.turnNumber.toString())
                    .fontSize(12)
                    .fontFamily('monospace')
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.tentacle_accent'))
                  Text(turn.title)
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.tentacle_text'))
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (turn.durationMs > 0) {
                    Text(formatDurationCompact(turn.durationMs))
                      .fontSize(11)
                      .fontFamily('monospace')
                      .fontColor($r('app.color.tentacle_text_faint'))
                  }
                }
                .width('100%')
                .padding({ top: 4, bottom: 4 })
                .onClick(() => this.toggleTurn(turn.id))

                if (!this.isTurnCollapsed(turn.id)) {
                  Column({ space: 5 }) {
                    ForEach(turn.steps, (step: DshTrajectoryStep) => {
                      Row({ space: 8 }) {
                        Column()
                          .width(6)
                          .height(6)
                          .borderRadius(3)
                          .backgroundColor(this.stepBadgeColor(step))

                        Text(this.stepTag(step))
                          .fontSize(10.5)
                          .fontColor(this.stepBadgeColor(step))
                          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                          .borderRadius(6)
                          .backgroundColor($r('app.color.tentacle_bg_hover'))

                        Column({ space: 2 }) {
                          Text(step.label)
                            .fontSize(12.5)
                            .fontWeight(FontWeight.Medium)
                            .fontColor($r('app.color.tentacle_text'))
                            .maxLines(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                          if (step.summary.length > 0 && step.summary !== step.label) {
                            Text(step.summary)
                              .fontSize(11)
                              .fontColor($r('app.color.tentacle_text_faint'))
                              .maxLines(1)
                              .textOverflow({ overflow: TextOverflow.Ellipsis })
                          }
                        }.layoutWeight(1).alignItems(HorizontalAlign.Start)

                        if (step.durationMs > 0) {
                          Text(formatDurationCompact(step.durationMs))
                            .fontSize(11)
                            .fontFamily('monospace')
                            .fontColor($r('app.color.tentacle_text_dim'))
                        }
                        if (step.tokensOut > 0) {
                          Text(formatTokensCompact(step.tokensOut) + ' tok')
                            .fontSize(10.5)
                            .fontFamily('monospace')
                            .fontColor($r('app.color.tentacle_text_faint'))
                        }
                        Text('›')
                          .fontSize(14)
                          .fontColor($r('app.color.tentacle_text_faint'))
                      }
                      .width('100%')
                      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
                      .borderRadius(10)
                      .backgroundColor($r('app.color.tentacle_bg_elevated'))
                      .border({ width: 0.5, color: $r('app.color.tentacle_border') })
                      .onClick(() => this.onSelectStep(step))
                    }, (step: DshTrajectoryStep) => step.id)
                  }.width('100%').padding({ left: 8 })
                }
              }
              .width('100%')
              .padding(12)
              .borderRadius(14)
              .backgroundColor($r('app.color.tentacle_bg_card'))
              .border({ width: 0.75, color: $r('app.color.tentacle_border') })
            }, (turn: DshTrajectoryTurn) => turn.id)
          }
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 16 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      // 底部固定：耗时占比条与 Token/TTFT/TPS 统计卡片
      this.BottomSummaryBar()
    }
    .width('100%')
    .height('100%')
  }
}
