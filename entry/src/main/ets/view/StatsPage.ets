/**
 * 统计页：余额 / 今天·本周·本月汇总 / Token 堆叠柱状图 / 缓存命中率折线图
 *
 * 数据源：
 * - GET /api/usage?granularity=day|hour&window=N （cache_hit_rate 服务端算好）
 * - GET /api/balance?force=false
 * 图表用 Canvas 自绘，零第三方依赖；颜色取自主题资源同值十六进制
 * （fillStyle 只接受 string，无法直接传 Resource）。
 */

import { TentacleApi } from '../service/TentacleApi';
import { PeriodSummary, UsagePoint, BalanceInfo, ProviderBalance, UsageOptions, UsageOption } from '../model/Types';
import { ActionButton, AppCard, FeedbackBanner, SectionTitle, StatusPill } from '../components/UiKit';

// 与 resources 色板同值：tentacle_ok / tentacle_accent / tentacle_text_dim / border / faint / accent_hover
const COL_CACHED = '#7FA66A';
const COL_UNCACHED = '#D97757';
const COL_OUTPUT = '#A99E8E';
const COL_GRID = '#3D342A';
const COL_TEXT = '#7D7466';
const COL_LINE_DOT = '#E58E6E';

function emptyPeriod(): PeriodSummary {
  const p: PeriodSummary = {
    prompt_tokens: 0,
    completion_tokens: 0,
    total_tokens: 0,
    cached_tokens: 0,
    requests: 0,
  };
  return p;
}

@Component
export struct StatsPage {
  @State gran: string = 'day';
  @State loading: boolean = false;
  @State errText: string = '';
  // 余额
  @State balErr: string = '';
  @State balances: ProviderBalance[] = [];
  @State provider: string = '';
  @State model: string = '';
  @State role: string = '';
  @State options: UsageOptions = { providers: [], models: [], roles: [] };
  @State sumAll: PeriodSummary = emptyPeriod();
  @State filtersOpen: boolean = false;
  private generation: number = 0;
  // 汇总
  @State sumToday: PeriodSummary = emptyPeriod();
  @State sumWeek: PeriodSummary = emptyPeriod();
  @State sumMonth: PeriodSummary = emptyPeriod();
  // 数据点
  @State dayPoints: UsagePoint[] = [];
  @State hourPoints: UsagePoint[] = [];

  private readonly barH: number = 220;
  private readonly lineH: number = 180;
  private barW: number = 0;
  private lineW: number = 0;
  private barReady: boolean = false;
  private lineReady: boolean = false;
  private loadedOnce: boolean = false;
  private barSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private barCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.barSettings);
  private lineSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private lineCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.lineSettings);

  aboutToAppear(): void {
    this.load();
  }

  aboutToDisappear(): void { this.generation++; }

  private filterOptions(kind: string): UsageOption[] {
    if (kind === 'provider') { return this.options.providers; }
    if (kind === 'role') { return this.options.roles; }
    return this.options.models.filter((m: UsageOption) => !this.provider || (m.provider_ids ?? []).includes(this.provider));
  }

  private selectOptions(kind: string): SelectOption[] {
    const options: SelectOption[] = [{ value: '全部' }];
    return options.concat(this.filterOptions(kind).map((o: UsageOption): SelectOption => ({ value: o.label === o.id ? o.label : o.label + ' · ' + o.id })));
  }

  private filterLabel(kind: string, id: string): string {
    const item = this.filterOptions(kind).find((o: UsageOption) => o.id === id);
    return item === undefined ? '全部' : item.label;
  }

  private filter(kind: string, index: number): void {
    const id = index === 0 ? '' : this.filterOptions(kind)[index - 1].id;
    if (kind === 'provider') {
      this.provider = id;
      if (!this.filterOptions('model').some((m: UsageOption) => m.id === this.model)) { this.model = ''; }
    } else if (kind === 'model') { this.model = id; } else { this.role = id; }
    this.load();
  }

  private curPoints(): UsagePoint[] {
    if (this.gran === 'hour') {
      return this.hourPoints;
    }
    return this.dayPoints;
  }

  private fmtTokens(n: number): string {
    if (n >= 100000000) {
      return (n / 100000000).toFixed(1) + '亿';
    }
    if (n >= 10000) {
      return (n / 10000).toFixed(1) + '万';
    }
    return Math.round(n).toString();
  }

  private niceCeil(v: number): number {
    if (v <= 0) {
      return 1;
    }
    const exp = Math.floor(Math.log(v) / Math.LN10);
    const base = Math.pow(10, exp);
    const f = v / base;
    let m: number;
    if (f <= 1) {
      m = 1;
    } else if (f <= 2) {
      m = 2;
    } else if (f <= 5) {
      m = 5;
    } else {
      m = 10;
    }
    return m * base;
  }

  private async load(forceBalance: boolean = false): Promise<void> {
    const seq = ++this.generation;
    this.loading = true;
    this.errText = '';
    const api = TentacleApi.getInstance();
    this.loadBalance(api, seq, forceBalance);
    try {
      const results = await Promise.all([api.getUsage('day', 30, this.provider, this.model, this.role),
        api.getUsage('hour', 48, this.provider, this.model, this.role)]);
      if (seq !== this.generation) { return; }
      const dayRes = results[0];
      this.dayPoints = dayRes.points;
      this.sumToday = dayRes.summary.today;
      this.sumWeek = dayRes.summary.week;
      this.sumMonth = dayRes.summary.month;
      this.sumAll = dayRes.summary.all;
      this.options = dayRes.options;
      const hourRes = results[1];
      this.hourPoints = hourRes.points;
    } catch (e) {
      if (seq !== this.generation) { return; }
      this.errText = e.message;
      this.dayPoints = []; this.hourPoints = [];
      this.sumToday = emptyPeriod(); this.sumWeek = emptyPeriod(); this.sumMonth = emptyPeriod(); this.sumAll = emptyPeriod();
      this.loading = false;
      this.loadedOnce = true;
      this.redrawCharts();
      return;
    }
    this.loading = false;
    this.loadedOnce = true;
    this.redrawCharts();
  }

  private async loadBalance(api: TentacleApi, seq: number, force: boolean): Promise<void> {
    this.balErr = '';
    try {
      const b = await api.getBalance(force, this.provider);
      if (seq !== this.generation) { return; }
      this.balances = b.items;
    } catch (e) {
      if (seq === this.generation) { this.balErr = e.message; }
    }
  }

  private redrawCharts(): void {
    if (!this.loadedOnce) {
      return;
    }
    if (this.barReady) {
      this.drawBar();
    }
    if (this.lineReady) {
      this.drawLine();
    }
  }

  // 圆角矩形路径（仅顶部两角圆角），替代顶层片段 fillRect
  private _roundTopRect(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number,
    r: number): void {
    const rr = Math.min(r, w / 2, h);
    ctx.beginPath();
    ctx.moveTo(x, y + rr);
    ctx.arcTo(x, y, x + rr, y, rr);
    ctx.lineTo(x + w - rr, y);
    ctx.arcTo(x + w, y, x + w, y + rr, rr);
    ctx.lineTo(x + w, y + h);
    ctx.lineTo(x, y + h);
    ctx.closePath();
    ctx.fill();
  }

  // ---------- 堆叠柱状图 ----------

  private drawBar(): void {
    const ctx = this.barCtx;
    const w = this.barW;
    const h = this.barH;
    if (w <= 0 || h <= 0) {
      return;
    }
    ctx.clearRect(0, 0, w, h);
    const pts: UsagePoint[] = this.curPoints();
    const left = 46;
    const right = 8;
    const top = 12;
    const bottom = 22;
    const plotW = w - left - right;
    const plotH = h - top - bottom;
    if (pts.length === 0 || plotW <= 0 || plotH <= 0) {
      ctx.fillStyle = COL_TEXT;
      ctx.font = '13px sans-serif';
      ctx.textAlign = 'center';
      ctx.fillText('暂无数据', w / 2, h / 2);
      return;
    }
    let maxRaw = 0;
    for (let i = 0; i < pts.length; i++) {
      if (pts[i].total_tokens > maxRaw) {
        maxRaw = pts[i].total_tokens;
      }
    }
    const maxV = this.niceCeil(maxRaw);
    // 横向网格 + Y 轴标签（虚线）
    try {
      ctx.setLineDash([3, 3]);
    } catch (e) {
      // 降级为实线
    }
    ctx.font = '10px sans-serif';
    for (let k = 0; k <= 3; k++) {
      const y = top + plotH - plotH * k / 3;
      ctx.strokeStyle = COL_GRID;
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(left, y);
      ctx.lineTo(left + plotW, y);
      ctx.stroke();
      ctx.fillStyle = COL_TEXT;
      ctx.textAlign = 'right';
      ctx.fillText(this.fmtTokens(maxV * k / 3), left - 4, y + 3);
    }
    try {
      ctx.setLineDash([]);
    } catch (e) {
      // 忽略
    }
    // 三层堆叠柱：缓存命中 / 未命中输入 / 输出（顶片段圆角）
    const slotW = plotW / pts.length;
    const barW = Math.min(slotW * 0.66, 24);
    const s = plotH / maxV;
    for (let i = 0; i < pts.length; i++) {
      const p = pts[i];
      const c = Math.max(0, p.cached_tokens);
      const u = Math.max(0, p.prompt_tokens - p.cached_tokens);
      const o = Math.max(0, p.completion_tokens);
      const x0 = left + i * slotW + (slotW - barW) / 2;
      let yBase = top + plotH;
      const pieces: Array<[string, number]> = [];
      if (c > 0) {
        pieces.push([COL_CACHED, c]);
      }
      if (u > 0) {
        pieces.push([COL_UNCACHED, u]);
      }
      if (o > 0) {
        pieces.push([COL_OUTPUT, o]);
      }
      for (let k = 0; k < pieces.length; k++) {
        const color = pieces[k][0];
        const val = pieces[k][1];
        const pxH = val * s;
        const py = yBase;
        ctx.fillStyle = color;
        if (k === pieces.length - 1) {
          // 最上层片段画圆角顶；高度过小时直接整段圆角矩形
          const lowerH = pxH - 4;
          if (lowerH > 0) {
            ctx.fillRect(x0, py - lowerH, barW, lowerH);
            this._roundTopRect(ctx, x0, py - pxH, barW, 4.5, 3);
          } else {
            this._roundTopRect(ctx, x0, py - pxH, barW, pxH, 3);
          }
        } else {
          ctx.fillRect(x0, py - pxH, barW, pxH);
        }
        yBase = py - pxH;
      }
    }
    this.drawXLabels(ctx, pts, left, plotW, h - 8);
  }

  // ---------- 缓存命中率折线 ----------

  private drawLine(): void {
    const ctx = this.lineCtx;
    const w = this.lineW;
    const h = this.lineH;
    if (w <= 0 || h <= 0) {
      return;
    }
    ctx.clearRect(0, 0, w, h);
    const pts: UsagePoint[] = this.curPoints();
    const left = 42;
    const right = 8;
    const top = 10;
    const bottom = 22;
    const plotW = w - left - right;
    const plotH = h - top - bottom;
    if (pts.length === 0 || plotW <= 0 || plotH <= 0) {
      ctx.fillStyle = COL_TEXT;
      ctx.font = '13px sans-serif';
      ctx.textAlign = 'center';
      ctx.fillText('暂无数据', w / 2, h / 2);
      return;
    }
    ctx.font = '10px sans-serif';
    try {
      ctx.setLineDash([3, 3]);
    } catch (e) {
      // 降级为实线
    }
    for (let k = 0; k <= 4; k++) {
      const y = top + plotH - plotH * k / 4;
      ctx.strokeStyle = COL_GRID;
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(left, y);
      ctx.lineTo(left + plotW, y);
      ctx.stroke();
      ctx.fillStyle = COL_TEXT;
      ctx.textAlign = 'right';
      ctx.fillText((k * 25).toString(), left - 4, y + 3);
    }
    try {
      ctx.setLineDash([]);
    } catch (e) {
      // 忽略
    }
    const slotW = plotW / pts.length;
    const xAt = (i: number): number => left + (i + 0.5) * slotW;
    const yAt = (v: number): number => top + (100 - v) * plotH / 100;
    // null 断桥：连续非 null 序列逐段绘制
    let i = 0;
    while (i < pts.length) {
      const v0 = pts[i].cache_hit_rate;
      if (v0 === null) {
        i++;
        continue;
      }
      let j = i + 1;
      while (j < pts.length && pts[j].cache_hit_rate !== null) {
        j++;
      }
      const segLen = j - i;
      // 面积渐变填充（先填充后描边）
      const grad = ctx.createLinearGradient(0, top, 0, top + plotH);
      grad.addColorStop(0, 'rgba(217,119,87,0.20)');
      grad.addColorStop(1, 'rgba(217,119,87,0)');
      ctx.fillStyle = grad;
      ctx.beginPath();
      ctx.moveTo(xAt(i), yAt(v0));
      for (let t = i + 1; t < j; t++) {
        const vt = pts[t].cache_hit_rate;
        if (vt !== null) {
          // 中点二次贝塞尔平滑
          const midX = (xAt(t - 1) + xAt(t)) / 2;
          const prevV = pts[t - 1].cache_hit_rate;
          if (prevV !== null) {
            const midY = (yAt(prevV) + yAt(vt)) / 2;
            ctx.quadraticCurveTo(xAt(t - 1), yAt(prevV), midX, midY);
          }
        }
      }
      const lastIdx = j - 1;
      const lastV = pts[lastIdx].cache_hit_rate;
      if (lastV !== null) {
        ctx.lineTo(xAt(lastIdx), yAt(lastV));
      }
      ctx.lineTo(xAt(lastIdx), top + plotH);
      ctx.lineTo(xAt(i), top + plotH);
      ctx.closePath();
      ctx.fill();

      // 描边（同样的平滑路径）
      ctx.strokeStyle = COL_UNCACHED;
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.moveTo(xAt(i), yAt(v0));
      for (let t = i + 1; t < j; t++) {
        const vt = pts[t].cache_hit_rate;
        if (vt !== null) {
          const prevV = pts[t - 1].cache_hit_rate;
          if (prevV !== null) {
            const midX = (xAt(t - 1) + xAt(t)) / 2;
            const midY = (yAt(prevV) + yAt(vt)) / 2;
            ctx.quadraticCurveTo(xAt(t - 1), yAt(prevV), midX, midY);
          }
        }
      }
      if (lastV !== null) {
        ctx.lineTo(xAt(lastIdx), yAt(lastV));
      }
      ctx.stroke();

      // 数据点圆点
      ctx.fillStyle = COL_LINE_DOT;
      for (let t = i; t < j; t++) {
        const vt = pts[t].cache_hit_rate;
        if (vt !== null) {
          ctx.beginPath();
          ctx.arc(xAt(t), yAt(vt), 2.5, 0, Math.PI * 2);
          ctx.fill();
        }
      }
      i = j;
    }
    this.drawXLabels(ctx, pts, left, plotW, h - 8);
  }

  private drawXLabels(ctx: CanvasRenderingContext2D, pts: UsagePoint[], left: number,
    plotW: number, y: number): void {
    const slotW = plotW / pts.length;
    const step = Math.max(1, Math.ceil(pts.length / 6));
    ctx.fillStyle = COL_TEXT;
    ctx.font = '10px sans-serif';
    ctx.textAlign = 'center';
    for (let i = 0; i < pts.length; i += step) {
      const bucket = pts[i].bucket;
      let label = bucket;
      if (this.gran === 'day') {
        // "2026-08-27" -> "08-27"
        if (bucket.length >= 10) {
          label = bucket.substring(5, 10);
        }
      } else {
        // "2026-08-27 14:00" -> "14:00"
        if (bucket.length >= 16) {
          label = bucket.substring(11, 16);
        }
      }
      ctx.fillText(label, left + (i + 0.5) * slotW, y);
    }
  }

  @Builder
  LegendItem(color: string, label: string) {
    Row({ space: 4 }) {
      Column()
        .width(10)
        .height(10)
        .borderRadius(2)
        .backgroundColor(color)
      Text(label)
        .fontSize(11)
        .fontColor($r('app.color.tentacle_text_dim'))
    }
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        ActionButton({
          label: this.filtersOpen ? '收起筛选 ⌃' : '筛选' + ((this.provider || this.model || this.role) ? ' · 已生效' : '') + ' ⌄',
          tone: (this.provider || this.model || this.role) ? 'accent' : 'secondary',
          compact: true,
          onTap: () => { this.filtersOpen = !this.filtersOpen; }
        })
        Blank()
        ActionButton({
          label: this.loading ? '加载中…' : '刷新余额与图表',
          tone: 'secondary',
          compact: true,
          isEnabled: !this.loading,
          onTap: () => { this.load(true); }
        })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 4, bottom: 8 })

      Scroll() {
        Column({ space: 12 }) {
          if (this.errText.length > 0) {
            FeedbackBanner({ text: this.errText, tone: 'danger' })
          }

          if (this.filtersOpen) {
            AppCard() {
              Column({ space: 8 }) {
                SectionTitle({ title: '统计筛选' })
                Text('供应商').fontSize(12).fontColor($r('app.color.tentacle_text_dim')).width('100%')
                Select(this.selectOptions('provider')).value(this.filterLabel('provider', this.provider)).width('100%').onSelect((i: number) => this.filter('provider', i))
                Text('模型').fontSize(12).fontColor($r('app.color.tentacle_text_dim')).width('100%')
                Select(this.selectOptions('model')).value(this.filterLabel('model', this.model)).width('100%').onSelect((i: number) => this.filter('model', i))
                Text('角色').fontSize(12).fontColor($r('app.color.tentacle_text_dim')).width('100%')
                Select(this.selectOptions('role')).value(this.filterLabel('role', this.role)).width('100%').onSelect((i: number) => this.filter('role', i))
                Row({ space: 8 }) {
                  ActionButton({
                    label: '重置筛选',
                    tone: 'ghost',
                    compact: true,
                    onTap: () => { this.provider = ''; this.model = ''; this.role = ''; this.load(); }
                  })
                  Text('余额只按供应商筛选').fontSize(11).fontColor($r('app.color.tentacle_text_faint'))
                }.width('100%')
              }.width('100%')
            }
          }
          AppCard() {
            Column({ space: 8 }) {
              SectionTitle({ title: '供应商余额' })
              if (this.balErr.length > 0) {
                Text(this.balErr)
                  .fontSize(12)
                  .fontColor($r('app.color.tentacle_text_faint'))
                  .width('100%')
                  .margin({ top: 6 })
              }
              ForEach(this.balances, (account: ProviderBalance) => {
                Column({ space: 4 }) {
                  Text(account.label || account.provider_id).fontSize(14).fontColor($r('app.color.tentacle_text')).width('100%')
                  if (!account.ok) {
                    Text(account.error ?? '余额查询不可用').fontSize(12).fontColor($r('app.color.tentacle_text_faint'))
                  } else {
                    ForEach(account.balances ?? [], (b: BalanceInfo) => {
                      Text((b.currency ?? '') + ' ' + (b.total_balance ?? '-')).fontSize(22).fontColor($r('app.color.tentacle_ok'))
                      Text('充值 ' + (b.topped_up_balance ?? '-') + ' · 赠送 ' + (b.granted_balance ?? '-')).fontSize(11).fontColor($r('app.color.tentacle_text_dim'))
                    }, (b: BalanceInfo) => b.currency ?? '')
                    if (account.is_available === false) { Text('账户当前不可用').fontSize(12).fontColor($r('app.color.tentacle_danger')) }
                  }
                  if (account.fetched_at) { Text('更新于 ' + new Date(account.fetched_at * 1000).toLocaleString()).fontSize(10).fontColor($r('app.color.tentacle_text_faint')) }
                }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 8 })
              }, (account: ProviderBalance) => account.provider_id)
              if (!this.balances.length && !this.balErr) { Text('暂无供应商余额').fontColor($r('app.color.tentacle_text_faint')) }
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
          }

          // 今天 / 本周 / 本月
          AppCard() {
            Row({ space: 8 }) {
              Column({ space: 3 }) {
                Text('今天')
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.tentacle_accent'))
                  .width('100%')
                PeriodRows({ p: this.sumToday })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Column({ space: 3 }) {
                Text('最近7天')
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.tentacle_accent'))
                  .width('100%')
                PeriodRows({ p: this.sumWeek })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Column({ space: 3 }) {
                Text('最近30天')
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.tentacle_accent'))
                  .width('100%')
                PeriodRows({ p: this.sumMonth })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
          }

          AppCard() {
            Column({ space: 4 }) {
              SectionTitle({ title: '累计用量' })
              PeriodRows({ p: this.sumAll })
            }.width('100%')
          }

          AppCard() {
            Column({ space: 10 }) {
              // 粒度分段控件
              Row() {
                Text('按天')
                  .fontSize(13)
                  .fontColor(this.gran === 'day'
                    ? $r('app.color.tentacle_text') : $r('app.color.tentacle_text_dim'))
                  .textAlign(TextAlign.Center)
                  .layoutWeight(1)
                  .height(30)
                  .borderRadius(8)
                  .backgroundColor(this.gran === 'day'
                    ? $r('app.color.tentacle_bg_elevated') : Color.Transparent)
                  .onClick(() => {
                    this.gran = 'day';
                    this.redrawCharts();
                  })
                Text('按小时')
                  .fontSize(13)
                  .fontColor(this.gran === 'hour'
                    ? $r('app.color.tentacle_text') : $r('app.color.tentacle_text_dim'))
                  .textAlign(TextAlign.Center)
                  .layoutWeight(1)
                  .height(30)
                  .borderRadius(8)
                  .backgroundColor(this.gran === 'hour'
                    ? $r('app.color.tentacle_bg_elevated') : Color.Transparent)
                  .onClick(() => {
                    this.gran = 'hour';
                    this.redrawCharts();
                  })
              }
              .padding(3)
              .backgroundColor($r('app.color.tentacle_bg_input'))
              .borderRadius(10)
              .width('100%')

              SectionTitle({ title: 'Token 用量' })

              Row({ space: 12 }) {
                this.LegendItem(COL_CACHED, '命中缓存')
                this.LegendItem(COL_UNCACHED, '未命中输入')
                this.LegendItem(COL_OUTPUT, '输出')
              }
              .width('100%')

              Canvas(this.barCtx)
                .width('100%')
                .height(this.barH)
                .onReady(() => {
                  this.barReady = true;
                  this.drawBar();
                })
                .onAreaChange((oldArea: Area, newArea: Area) => {
                  this.barW = Number(newArea.width);
                  this.drawBar();
                })
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
          }

          AppCard() {
            Column({ space: 10 }) {
              SectionTitle({ title: '缓存命中率（%）' })
              Canvas(this.lineCtx)
                .width('100%')
                .height(this.lineH)
                .onReady(() => {
                  this.lineReady = true;
                  this.drawLine();
                })
                .onAreaChange((oldArea: Area, newArea: Area) => {
                  this.lineW = Number(newArea.width);
                  this.drawLine();
                })
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
          }
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 4, bottom: 14 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.tentacle_bg'))
  }
}

// 汇总三列共用的行块
@Component
struct PeriodRows {
  @Prop p: PeriodSummary;

  build() {
    Column({ space: 2 }) {
      Text('输入 ' + this.fmt(this.p.prompt_tokens))
        .fontSize(11)
        .fontColor($r('app.color.tentacle_text_dim'))
        .width('100%')
      Text('输出 ' + this.fmt(this.p.completion_tokens))
        .fontSize(11)
        .fontColor($r('app.color.tentacle_text_dim'))
        .width('100%')
      Text('缓存 ' + this.fmt(this.p.cached_tokens))
        .fontSize(11)
        .fontColor($r('app.color.tentacle_text_dim'))
        .width('100%')
      Text('次数 ' + this.p.requests.toString())
        .fontSize(11)
        .fontColor($r('app.color.tentacle_text_faint'))
        .width('100%')
    }
    .width('100%')
  }

  private fmt(n: number): string {
    if (n >= 100000000) {
      return (n / 100000000).toFixed(1) + '亿';
    }
    if (n >= 10000) {
      return (n / 10000).toFixed(1) + '万';
    }
    return Math.round(n).toString();
  }
}
