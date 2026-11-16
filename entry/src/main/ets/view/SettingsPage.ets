/**
 * 设置页：对话显示开关 / 本地缓存 / 访问密码 / 设备与手机能力
 */

import { Settings } from '../model/Types';
import { TentacleApi } from '../service/TentacleApi';
import { ActionButton, AppCard, FeedbackBanner, SectionTitle } from '../components/UiKit';
import { notifyToast } from '../model/UiToast';
import { DeviceSettings, BackupSettings } from '../components/SettingsExtras';
import { PhoneSettings } from '../components/PhoneSettings';

@Component
export struct SettingsPage {
  @StorageLink('showReasoning') showReasoning: boolean = false;
  @StorageLink('splitMessages') splitMessages: boolean = true;
  @State passwordInput: string = '';
  @State msg: string = '';
  @State pwdMsg: string = '';
  @State cacheSize: string = '正在读取…';
  @State cacheBusy: boolean = false;
  private cacheSequence: number = 0;

  aboutToAppear(): void { this.loadCacheSize(); }
  aboutToDisappear(): void { this.cacheSequence++; }

  private async loadCacheSize(): Promise<void> {
    const seq = ++this.cacheSequence;
    const bytes = await TentacleApi.getInstance().localCacheBytes();
    if (seq === this.cacheSequence) { this.cacheSize = (bytes / 1024 / 1024).toFixed(1) + ' MiB / 64 MiB'; }
  }

  private async clearCache(): Promise<void> {
    if (this.cacheBusy) { return; }
    this.cacheBusy = true;
    try {
      await TentacleApi.getInstance().clearLocalCache();
      await this.loadCacheSize();
      notifyToast('本地缓存已清理', 'ok');
    }
    finally { this.cacheBusy = false; }
  }

  private applySettings(s: Settings): void {
    AppStorage.setOrCreate('agentName', s.agent_name);
    AppStorage.setOrCreate('showReasoning', s.show_reasoning);
    AppStorage.setOrCreate('splitMessages', s.split_messages);
  }

  private async saveSettings(): Promise<void> {
    this.msg = '';
    try {
      const s = await TentacleApi.getInstance().updateSettings(this.showReasoning, this.splitMessages);
      this.applySettings(s);
      this.msg = '基础设置已同步保存';
      notifyToast('界面偏好已保存', 'ok');
      setTimeout(() => {
        this.msg = '';
      }, 2500);
    } catch (e) {
      this.msg = (e as Error).message;
    }
  }

  private async savePassword(): Promise<void> {
    this.pwdMsg = '';
    try {
      const res = await TentacleApi.getInstance().setPassword(this.passwordInput);
      this.passwordInput = '';
      if (res.has_password) {
        TentacleApi.getInstance().logout();
        AppStorage.setOrCreate('connected', false);
        AppStorage.setOrCreate('connState', '未连接');
        AlertDialog.show({
          message: '密码已设置，请使用新密码重新登录',
          confirm: { value: '好的', action: () => {} }
        });
      } else {
        this.pwdMsg = '访问密码已清除';
        notifyToast('访问密码已清除', 'ok');
      }
    } catch (e) {
      this.pwdMsg = (e as Error).message;
    }
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 12 }) {
          AppCard() {
            Column({ space: 12 }) {
              SectionTitle({ title: '对话显示' })

              Row() {
                Column({ space: 2 }) {
                  Text('显示思考过程（reasoning）')
                    .fontSize(14)
                    .fontColor($r('app.color.tentacle_text'))
                  Text('在助手回复卡片上方折叠展示推理过程')
                    .fontSize(11)
                    .fontColor($r('app.color.tentacle_text_faint'))
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.showReasoning })
                  .selectedColor($r('app.color.tentacle_accent'))
                  .onChange((on: boolean) => {
                    if (on !== this.showReasoning) {
                      this.showReasoning = on;
                    }
                  })
              }
              .width('100%')

              Row() {
                Column({ space: 2 }) {
                  Text('按自然分段拆分消息')
                    .fontSize(14)
                    .fontColor($r('app.color.tentacle_text'))
                  Text('模型多段回复时拆分为独立气泡（与 WebUI 同步）')
                    .fontSize(11)
                    .fontColor($r('app.color.tentacle_text_faint'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.splitMessages })
                  .selectedColor($r('app.color.tentacle_accent'))
                  .onChange((on: boolean) => {
                    if (on !== this.splitMessages) {
                      this.splitMessages = on;
                    }
                  })
              }
              .width('100%')

              Text('伴侣名字已迁移至「应用配置」，此处仅保留界面与安全设置。')
                .fontSize(11)
                .fontColor($r('app.color.tentacle_text_faint'))
                .width('100%')

              Row({ space: 10 }) {
                ActionButton({
                  label: '保存设置',
                  tone: 'primary',
                  compact: true,
                  onTap: () => { this.saveSettings(); }
                })
                if (this.msg.length > 0) {
                  Text(this.msg).fontSize(12).fontColor($r('app.color.tentacle_text_dim'))
                }
              }
              .width('100%')
            }
            .width('100%')
          }

          AppCard() {
            Column({ space: 10 }) {
              SectionTitle({ title: '本机缓存' })
              Text('图谱快照、图片预览与上传复用索引缓存在本地，重启保留。')
                .fontSize(12).fontColor($r('app.color.tentacle_text_dim')).width('100%')
              Row({ space: 10 }) {
                Text(this.cacheSize).fontSize(12).fontFamily('monospace').fontColor($r('app.color.tentacle_text_faint')).layoutWeight(1)
                ActionButton({
                  label: this.cacheBusy ? '清理中…' : '清理缓存',
                  tone: 'secondary',
                  compact: true,
                  isEnabled: !this.cacheBusy,
                  onTap: () => { this.clearCache(); }
                })
              }.width('100%')
            }.width('100%')
          }

          AppCard() {
            Column({ space: 10 }) {
              SectionTitle({ title: 'Web / 客户端访问密码' })
              Text('新密码（留空提交则清除密码）')
                .fontSize(12.5)
                .fontColor($r('app.color.tentacle_text_dim'))
                .width('100%')
              TextInput({ text: this.passwordInput, placeholder: '输入新密码…' })
                .type(InputType.Password)
                .onChange((v: string) => {
                  this.passwordInput = v;
                })
                .backgroundColor($r('app.color.tentacle_bg_input'))
                .fontColor($r('app.color.tentacle_text'))
                .caretColor($r('app.color.tentacle_accent'))
                .border({ width: 0.5, color: $r('app.color.tentacle_border') })
                .borderRadius(10)
                .height(40)
                .width('100%')

              Row({ space: 10 }) {
                ActionButton({
                  label: '更新密码',
                  tone: 'primary',
                  compact: true,
                  onTap: () => { this.savePassword(); }
                })
                if (this.pwdMsg.length > 0) {
                  Text(this.pwdMsg).fontSize(12).fontColor($r('app.color.tentacle_text_dim'))
                }
              }
              .width('100%')
            }
            .width('100%')
          }

          DeviceSettings()
          PhoneSettings()
          BackupSettings()
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 8, bottom: 20 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.tentacle_bg'))
  }
}
