import { TentacleApi } from '../service/TentacleApi';
import { DeviceInfo, DeviceRecord, SelfBackup } from '../model/Management';
import { ActionButton, AppCard, FeedbackBanner, SectionTitle, StatusPill } from './UiKit';
import { notifyToast } from '../model/UiToast';

@Component
export struct DeviceSettings {
  @State info: DeviceInfo | null = null;
  @State deviceAuthEnabled: boolean = false;
  @State allowNew: boolean = false;
  @State code: string = '';
  @State message: string = '';
  @State busy: boolean = false;
  private generation: number = 0;

  aboutToAppear(): void { this.load(); }
  aboutToDisappear(): void { this.generation++; }

  private async load(): Promise<void> {
    const seq = ++this.generation;
    try {
      const info = await TentacleApi.getInstance().getDevices();
      if (seq !== this.generation) { return; }
      this.info = info; this.deviceAuthEnabled = info.device_auth; this.allowNew = info.allow_new_devices;
    } catch (e) { if (seq === this.generation) { this.message = (e as Error).message; } }
  }

  private async saveDeviceAuth(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true; this.message = '';
    try {
      await TentacleApi.getInstance().setDeviceAuth(this.deviceAuthEnabled, this.code);
      this.code = ''; this.message = '设备验证已更新';
      notifyToast('设备验证已更新', 'ok');
      await this.load();
    } catch (e) { this.message = (e as Error).message; }
    finally { this.busy = false; }
  }

  private async saveNew(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    try {
      await TentacleApi.getInstance().setNewDevices(this.allowNew);
      this.message = '新设备入口已更新';
      notifyToast('新设备入口已更新', 'ok');
      await this.load();
    }
    catch (e) { this.message = (e as Error).message; }
    finally { this.busy = false; }
  }

  private revoke(device: DeviceRecord): void {
    AlertDialog.show({
      message: '吊销“' + (device.name || device.id) + '”？该设备会立即失去访问权。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '吊销',
        action: async () => {
          if (this.busy) { return; }
          this.busy = true;
          try {
            await TentacleApi.getInstance().revokeDevice(device.id);
            this.message = '已吊销设备';
            notifyToast('已吊销该设备', 'ok');
            await this.load();
          }
          catch (e) { this.message = (e as Error).message; }
          finally { this.busy = false; }
        }
      }
    });
  }

  build() {
    AppCard() {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          SectionTitle({ title: '受信任设备鉴权' })
          Blank()
          if (this.info !== null) {
            StatusPill({
              label: this.info.freeze ? '已冻结' : this.info.device_bound ? '本机已绑定' : '未绑定',
              tone: this.info.freeze ? 'danger' : this.info.device_bound ? 'ok' : 'default'
            })
          }
          ActionButton({
            label: '刷新',
            tone: 'ghost',
            compact: true,
            isEnabled: !this.busy,
            onTap: () => { this.load(); }
          })
        }.width('100%')

        if (this.info !== null) {
          if (this.info.freeze) {
            FeedbackBanner({ text: '主机已冻结设备绑定，请在主机解除冻结', tone: 'danger' })
          }
          Row() {
            Text('仅允许已绑定设备访问').fontSize(13.5).fontColor($r('app.color.tentacle_text')).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.deviceAuthEnabled })
              .selectedColor($r('app.color.tentacle_accent'))
              .enabled(!this.busy && !this.info.freeze)
              .onChange((on: boolean) => this.deviceAuthEnabled = on)
          }.width('100%')

          if (this.deviceAuthEnabled && !this.info.device_bound) {
            TextInput({ text: this.code, placeholder: '主机 gen-code 生成的一次性绑定码' })
              .fontSize(13.5).fontColor($r('app.color.tentacle_text'))
              .backgroundColor($r('app.color.tentacle_bg_input'))
              .border({ width: 0.5, color: $r('app.color.tentacle_border') }).borderRadius(10).height(40)
              .onChange((v: string) => this.code = v)
          }

          ActionButton({
            label: '保存设备验证',
            tone: 'primary',
            compact: true,
            isEnabled: !this.busy && !this.info.freeze,
            onTap: () => { this.saveDeviceAuth(); }
          })

          if (this.info.devices.length > 0) {
            Divider().color($r('app.color.tentacle_border')).margin({ top: 2, bottom: 2 })
            ForEach(this.info.devices, (device: DeviceRecord) => {
              Row({ space: 8 }) {
                Column({ space: 3 }) {
                  Text(device.name || '未命名设备').fontSize(13.5).fontWeight(FontWeight.Medium).fontColor($r('app.color.tentacle_text')).width('100%')
                  Text('绑定于 ' + new Date(device.created * 1000).toLocaleString() +
                    (device.last_seen ? '\n最近活跃 ' + new Date(device.last_seen * 1000).toLocaleString() : ''))
                    .fontSize(11).fontColor($r('app.color.tentacle_text_dim')).width('100%')
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                ActionButton({
                  label: '吊销',
                  tone: 'danger',
                  compact: true,
                  isEnabled: !this.busy,
                  onTap: () => { this.revoke(device); }
                })
              }
              .width('100%')
              .padding(10)
              .borderRadius(10)
              .backgroundColor($r('app.color.tentacle_bg_input'))
            }, (device: DeviceRecord) => device.id)
          }

          Divider().color($r('app.color.tentacle_border')).margin({ top: 2, bottom: 2 })

          Row() {
            Text('允许新设备绑定').fontSize(13.5).fontColor($r('app.color.tentacle_text')).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.allowNew })
              .selectedColor($r('app.color.tentacle_accent'))
              .enabled(!this.busy && this.info.allow_new_devices)
              .onChange((on: boolean) => this.allowNew = on)
          }.width('100%')
          Text(this.info.allow_new_devices ? '关闭后，重新开放需在主机运行 allow-new' : '入口已关闭；请在主机运行 scripts/device_token.py allow-new 重新开放')
            .fontSize(11).fontColor($r('app.color.tentacle_text_faint')).width('100%')
          ActionButton({
            label: '保存新设备入口',
            tone: 'secondary',
            compact: true,
            isEnabled: !this.busy && this.info.allow_new_devices,
            onTap: () => { this.saveNew(); }
          })
        }

        if (this.message) {
          FeedbackBanner({ text: this.message, tone: 'info' })
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
    }
  }
}

@Component
export struct BackupSettings {
  @State items: SelfBackup[] = [];
  @State path: string = '';
  @State message: string = '';
  @State busy: boolean = false;
  private generation: number = 0;

  aboutToAppear(): void { this.load(); }
  aboutToDisappear(): void { this.generation++; }

  private async load(): Promise<void> {
    const seq = ++this.generation;
    try {
      const result = await TentacleApi.getInstance().getBackups(this.path.trim());
      if (seq === this.generation) { this.items = result.items; this.message = ''; }
    } catch (e) { if (seq === this.generation) { this.message = (e as Error).message; } }
  }

  private confirmRestore(item: SelfBackup): void {
    if (this.busy) { return; }
    AlertDialog.show({
      title: '回滚自修改文件',
      message: '确定将 ' + item.source + ' 恢复到 ' + item.timestamp + '？（恢复前会自动快照当前版本）',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '回滚此版本',
        action: () => { this.restore(item); }
      }
    });
  }

  private async restore(item: SelfBackup): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    try {
      await TentacleApi.getInstance().restoreBackup(item.source, item.timestamp);
      await this.load();
      this.message = '已恢复；恢复前版本已由后端自动快照';
      notifyToast('已回滚到选定备份点', 'ok');
    } catch (e) { this.message = (e as Error).message; }
    finally { this.busy = false; }
  }

  build() {
    AppCard() {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          SectionTitle({ title: '自改备份回滚' })
          Blank()
          ActionButton({
            label: '刷新',
            tone: 'ghost',
            compact: true,
            isEnabled: !this.busy,
            onTap: () => { this.load(); }
          })
        }.width('100%')

        Text('恢复前会自动快照当前版本；可按相对路径过滤').fontSize(11.5).fontColor($r('app.color.tentacle_text_dim'))

        Row({ space: 8 }) {
          TextInput({ text: this.path, placeholder: '按路径过滤（留空显示全部）' })
            .layoutWeight(1).height(38).fontSize(13)
            .fontColor($r('app.color.tentacle_text')).backgroundColor($r('app.color.tentacle_bg_input'))
            .border({ width: 0.5, color: $r('app.color.tentacle_border') }).borderRadius(10)
            .onChange((v: string) => this.path = v)
          ActionButton({
            label: '过滤',
            tone: 'secondary',
            compact: true,
            isEnabled: !this.busy,
            onTap: () => { this.load(); }
          })
        }.width('100%')

        if (this.items.length === 0) {
          Text('暂无自修改备份记录').fontSize(12).fontColor($r('app.color.tentacle_text_faint'))
        }

        ForEach(this.items, (item: SelfBackup) => {
          Row({ space: 8 }) {
            Column({ space: 2 }) {
              Text(item.source).fontSize(12.5).fontFamily('monospace').fontColor($r('app.color.tentacle_text'))
                .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(item.timestamp + ' · ' + (item.size_bytes / 1024).toFixed(1) + ' KiB')
                .fontSize(11).fontColor($r('app.color.tentacle_text_dim'))
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            ActionButton({
              label: '回滚',
              tone: 'primary',
              compact: true,
              isEnabled: !this.busy,
              onTap: () => { this.confirmRestore(item); }
            })
          }
          .width('100%')
          .padding(10)
          .borderRadius(10)
          .backgroundColor($r('app.color.tentacle_bg_input'))
        }, (item: SelfBackup) => item.source + ':' + item.timestamp)

        if (this.message) {
          FeedbackBanner({ text: this.message, tone: 'info' })
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
    }
  }
}
