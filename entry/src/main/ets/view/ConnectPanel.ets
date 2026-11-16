/**
 * 连接面板：服务器地址 + 鉴权引导（状态驱动）
 *
 * 与 WebUI 登录遮罩语义一致：先探测 /api/auth/state，
 * - 设备验证开启且本机未绑定 -> 显示绑定码输入（主机 scripts/device_token.py gen-code 生成）
 * - 服务端设置密码 -> 显示密码输入
 * - 后端不可达时保持双字段的老行为，点击连接时报错
 */

import { Settings, AuthState } from '../model/Types';
import { TentacleApi } from '../service/TentacleApi';
import { AppCard, PrimaryButton } from '../components/UiKit';

@Component
export struct ConnectPanel {
  onDone: (s: Settings) => void = () => {
  };

  @State serverInput: string = '';
  @State passwordInput: string = '';
  @State deviceCodeInput: string = '';
  @State needEnroll: boolean = false;
  @State needPw: boolean = false;
  @State freezeHint: string = '';
  @State statusText: string = '';
  @State busy: boolean = false;

  aboutToAppear(): void {
    this.serverInput = TentacleApi.getInstance().getServerUrl();
    if (this.serverInput.length === 0) {
      return;
    }
    TentacleApi.getInstance().getAuthState().then((st: AuthState) => {
      this.needEnroll = st.device_auth && !st.device_ok;
      this.needPw = st.has_password;
      if (st.freeze && this.needEnroll) {
        this.freezeHint = '设备验证已被主机脚本紧急冻结（scripts/device_token.py unlock 解除），请用新绑定码重新绑定';
      } else {
        this.freezeHint = '';
      }
    }).catch((e: Error) => {
      // 网络不可达：保持默认双字段，点击连接时再报错
    });
  }

  private connect(): void {
    if (this.busy) {
      return;
    }
    if (this.serverInput.trim().length === 0) {
      this.statusText = '请填写服务器地址';
      return;
    }
    this.busy = true;
    this.statusText = '';
    TentacleApi.getInstance().connectAndAuth(this.serverInput, this.passwordInput, this.deviceCodeInput)
      .then((s: Settings) => {
        this.busy = false;
        this.statusText = '';
        this.passwordInput = '';
        this.deviceCodeInput = '';
        this.onDone(s);
      }).catch((e: Error) => {
        this.busy = false;
        this.statusText = e.message;
      });
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 顶部 accent 光晕
      Circle()
        .width(360)
        .height(360)
        .radialGradient({
          center: [180, 180],
          radius: 180,
          colors: [['#33D97757', 0], ['#00201B16', 1]]
        })
        .position({ x: -100, y: -140 })

      Column({ space: 20 }) {
        Column({ space: 6 }) {
          Text('Tentacle')
            .fontSize(34)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.tentacle_accent'))
            .letterSpacing(3)
          Text('连接你的 Agent 服务器')
            .fontSize(13)
            .fontColor($r('app.color.tentacle_text_dim'))
        }
        .alignItems(HorizontalAlign.Center)

        AppCard() {
          Column({ space: 12 }) {
            TextInput({ text: this.serverInput, placeholder: 'http://192.168.x.x:8420' })
              .onChange((v: string) => {
                this.serverInput = v;
              })
              .backgroundColor($r('app.color.tentacle_bg_input'))
              .fontColor($r('app.color.tentacle_text'))
              .caretColor($r('app.color.tentacle_accent'))
              .borderRadius(12)
              .width('100%')

            if (this.needEnroll) {
              Column({ space: 4 }) {
                Text(this.freezeHint.length > 0 ? this.freezeHint :
                  '设备验证已开启：请在主机运行 scripts/device_token.py gen-code 生成一次性绑定码')
                  .fontSize(11)
                  .fontColor(this.freezeHint.length > 0
                    ? $r('app.color.tentacle_danger') : $r('app.color.tentacle_text_dim'))
                  .width('100%')
                TextInput({ text: this.deviceCodeInput, placeholder: '设备绑定码' })
                  .onChange((v: string) => {
                    this.deviceCodeInput = v;
                  })
                  .backgroundColor($r('app.color.tentacle_bg_input'))
                  .fontColor($r('app.color.tentacle_text'))
                  .caretColor($r('app.color.tentacle_accent'))
                  .borderRadius(12)
                  .width('100%')
              }
              .width('100%')
            }

            if (this.needPw || !this.needEnroll) {
              TextInput({ text: this.passwordInput, placeholder: '访问密码（可选）' })
                .type(InputType.Password)
                .onChange((v: string) => {
                  this.passwordInput = v;
                })
                .backgroundColor($r('app.color.tentacle_bg_input'))
                .fontColor($r('app.color.tentacle_text'))
                .caretColor($r('app.color.tentacle_accent'))
                .borderRadius(12)
                .width('100%')
            }
          }
          .width('100%')
        }

        PrimaryButton({
          label: '连接',
          isEnabled: true,
          busy: this.busy,
          onTap: (): void => {
            this.connect();
          }
        })

        if (this.statusText.length > 0) {
          Text(this.statusText)
            .fontSize(12)
            .fontColor($r('app.color.tentacle_danger'))
            .backgroundColor($r('app.color.tentacle_accent_soft'))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(999)
            .textAlign(TextAlign.Center)
        }

        Blank()
      }
      .width('100%')
      .padding(28)
      .justifyContent(FlexAlign.Center)
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.tentacle_bg'))
    .alignContent(Alignment.TopStart)
  }
}
