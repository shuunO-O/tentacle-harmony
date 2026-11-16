import { common } from '@kit.AbilityKit';
import { saveAttachment } from '../service/FileTransfer';

@Component
export struct FileDownload {
  endpoint: string = '';
  filename: string = '';
  label: string = '';
  @State busy: boolean = false;
  @State message: string = '';

  private async save(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true; this.message = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const saved = await saveAttachment(context, this.endpoint, this.filename);
      this.message = saved ? '已保存' : '已取消保存';
    } catch (e) { this.message = e.message; }
    finally { this.busy = false; }
  }

  build() {
    Column({ space: 3 }) {
      Button(this.busy ? '下载中…' : this.label || ('↓ ' + this.filename), { type: ButtonType.Normal }).fontSize(12).height(32).borderRadius(8).enabled(!this.busy)
        .fontColor($r('app.color.tentacle_accent')).backgroundColor($r('app.color.tentacle_bg_input'))
        .onClick(() => this.save())
      if (this.message) { Text(this.message).fontSize(11).fontColor($r('app.color.tentacle_text_dim')) }
    }.alignItems(HorizontalAlign.Start).width('100%')
  }
}
