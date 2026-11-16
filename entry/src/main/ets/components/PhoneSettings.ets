import { PhoneIntegration } from '../service/PhoneIntegration';
import { ActionButton, AppCard, SectionTitle } from './UiKit';

@Component
export struct PhoneSettings {
  @StorageLink('phoneAlarms') alarms: boolean = false;
  @StorageLink('phoneLiveView') live: boolean = false;
  @StorageLink('phoneStatus') status: string = '尚未启用';
  @State busy: boolean = false;
  @State pushToken: string = '';

  private async configure(alarms: boolean, live: boolean): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    try { await PhoneIntegration.getInstance().configure(alarms, live); }
    catch (_) { /* PhoneIntegration preserves the specific failed setup step. */ }
    finally { this.busy = false; }
  }

  private async refreshPushToken(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    try { this.pushToken = await PhoneIntegration.getInstance().refreshPushToken(); }
    catch (_) { /* PhoneIntegration preserves the failed setup step. */ }
    finally { this.busy = false; }
  }

  build() {
    AppCard() {
      Column({ space: 12 }) {
        SectionTitle({ title: '手机能力' })
        Row() {
          Column({ space: 3 }) {
            Text('允许 Agent 设置闹钟').fontSize(14).fontColor($r('app.color.tentacle_text'))
            Text('从本机聊天发起，成功后由系统按时响铃').fontSize(11).fontColor($r('app.color.tentacle_text_faint'))
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.alarms }).enabled(!this.busy)
            .selectedColor($r('app.color.tentacle_accent'))
            .onChange((value: boolean) => this.configure(value, this.live))
        }.width('100%')
        Row() {
          Column({ space: 3 }) {
            Text('回复实况窗（调测）').fontSize(14).fontColor($r('app.color.tentacle_text'))
            Text('显示思考中与回复完成；后台更新需要云端推送').fontSize(11).fontColor($r('app.color.tentacle_text_faint'))
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.live }).enabled(!this.busy)
            .selectedColor($r('app.color.tentacle_accent'))
            .onChange((value: boolean) => this.configure(this.alarms, value))
        }.width('100%')
        Text(this.status).fontSize(12).fontColor($r('app.color.tentacle_text_dim')).width('100%')
        Text('服务端开关、闹钟等待超时与华为推送凭据可在「插件扩展 → harmony」管理')
          .fontSize(11).fontColor($r('app.color.tentacle_text_faint')).width('100%')
        Row({ space: 8 }) {
          ActionButton({
            label: this.busy ? '正在连接…' : '重新连接手机能力',
            tone: 'primary',
            compact: true,
            isEnabled: !this.busy && (this.alarms || this.live),
            onTap: () => { this.configure(this.alarms, this.live); }
          })
          ActionButton({
            label: '推送调测标识',
            tone: 'secondary',
            compact: true,
            isEnabled: !this.busy,
            onTap: () => { this.refreshPushToken(); }
          })
        }.width('100%')
        if (this.pushToken) {
          Text(this.pushToken).fontSize(11).fontColor($r('app.color.tentacle_text_faint'))
            .copyOption(CopyOptions.LocalDevice).width('100%')
        }
      }.width('100%')
    }
  }
}
