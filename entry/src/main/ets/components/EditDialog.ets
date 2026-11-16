/**
 * 通用编辑对话框（goal / task 创建与编辑）
 */

import { FieldDef } from '../model/Types';
import { ActionButton } from './UiKit';

@CustomDialog
export struct EditDialog {
  controller: CustomDialogController;
  title: string = '';
  fields: FieldDef[] = [];
  onConfirm: (fields: FieldDef[]) => void = () => {
  };

  private optIndex(f: FieldDef): number {
    const i = f.options.indexOf(f.value);
    if (i >= 0) {
      return i;
    }
    return 0;
  }

  private selectOptions(opts: string[]): SelectOption[] {
    const out: SelectOption[] = [];
    for (let i = 0; i < opts.length; i++) {
      const o: SelectOption = { value: opts[i] };
      out.push(o);
    }
    return out;
  }

  build() {
    Column({ space: 10 }) {
      Text(this.title)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.tentacle_text'))
        .width('100%')

      ForEach(this.fields, (f: FieldDef, fi: number) => {
        Column({ space: 4 }) {
          Text(f.label)
            .fontSize(13)
            .fontColor($r('app.color.tentacle_text_dim'))
            .width('100%')
          if (f.type === 'select') {
            Select(this.selectOptions(f.options))
              .selected(this.optIndex(f))
              .value(f.value)
              .font({ size: 14 })
              .fontColor($r('app.color.tentacle_text'))
              .backgroundColor($r('app.color.tentacle_bg_input'))
              .borderRadius(8)
              .onSelect((index: number) => {
                f.value = f.options[index];
              })
              .width('100%')
          } else {
            TextArea({ text: f.value, placeholder: f.placeholder })
              .onChange((v: string) => {
                f.value = v;
              })
              .height(f.type === 'textarea' ? 90 : 44)
              .backgroundColor($r('app.color.tentacle_bg_input'))
              .borderRadius(8)
              .fontSize(14)
              .fontColor($r('app.color.tentacle_text'))
              .width('100%')
          }
        }
        .width('100%')
      }, (f: FieldDef, fi: number) => 'f' + fi.toString())

      Row({ space: 10 }) {
        Column() {
          ActionButton({
            label: '取消',
            tone: 'ghost',
            fullWidth: true,
            onTap: () => { this.controller.close(); }
          })
        }.layoutWeight(1)
        Column() {
          ActionButton({
            label: '确定',
            tone: 'primary',
            fullWidth: true,
            onTap: () => {
              this.onConfirm(this.fields);
              this.controller.close();
            }
          })
        }.layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .padding(16)
    .backgroundColor($r('app.color.tentacle_bg_elevated'))
    .borderRadius(16)
    .width('92%')
  }
}
