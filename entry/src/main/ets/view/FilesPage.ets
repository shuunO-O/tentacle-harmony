import { TentacleApi } from '../service/TentacleApi';
import { FileRecord } from '../model/Types';
import { FileDownload } from '../components/FileDownload';
import { ActionButton, AppCard, FeedbackBanner, StatusPill } from '../components/UiKit';

@Component
export struct FilesPage {
  @State files: FileRecord[] = [];
  @State search: string = '';
  @State message: string = '';
  @State busy: boolean = false;
  private generation: number = 0;

  aboutToAppear(): void { this.load(); }
  aboutToDisappear(): void { this.generation++; }
  private async load(): Promise<void> {
    const seq = ++this.generation;
    try {
      const result = await TentacleApi.getInstance().getFiles();
      if (seq === this.generation) { this.files = result.files; this.message = ''; }
    } catch (e) { if (seq === this.generation) { this.message = (e as Error).message; } }
  }

  private remove(file: FileRecord): void {
    AlertDialog.show({
      message: '删除“' + file.filename + '”？历史中的此附件将无法访问。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '删除',
        action: async () => {
          if (this.busy) { return; }
          this.busy = true;
          try { await TentacleApi.getInstance().deleteFile(file.local_id); await this.load(); }
          catch (e) { this.message = (e as Error).message; }
          finally { this.busy = false; }
        }
      }
    });
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        TextInput({ text: this.search, placeholder: '搜索文件名或类型…' })
          .layoutWeight(1).height(38).fontSize(13)
          .fontColor($r('app.color.tentacle_text')).backgroundColor($r('app.color.tentacle_bg_input'))
          .border({ width: 0.5, color: $r('app.color.tentacle_border') }).borderRadius(10)
          .onChange((v: string) => this.search = v)
        ActionButton({
          label: '刷新',
          tone: 'secondary',
          compact: true,
          isEnabled: !this.busy,
          onTap: () => { this.load(); }
        })
      }.width('100%')

      if (this.message) { FeedbackBanner({ text: this.message, tone: 'danger' }) }

      List({ space: 10 }) {
        ForEach(this.files.filter((f: FileRecord) => !this.search || (f.filename + ' ' + f.mime).toLowerCase().includes(this.search.toLowerCase())), (file: FileRecord) => {
          ListItem() {
            AppCard() {
              Column({ space: 8 }) {
                Row({ space: 8 }) {
                  Text(file.filename).fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.tentacle_text'))
                    .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  StatusPill({ label: (file.size / 1024).toFixed(1) + ' KiB' })
                }.width('100%')
                Text(file.mime).fontSize(11).fontFamily('monospace').fontColor($r('app.color.tentacle_text_faint'))
                Row({ space: 8 }) {
                  Column() {
                    FileDownload({ endpoint: '/api/files/' + encodeURIComponent(file.local_id) + '/content', filename: file.filename, label: '保存到本机' })
                  }.layoutWeight(1)
                  ActionButton({
                    label: '删除',
                    tone: 'danger',
                    compact: true,
                    isEnabled: !this.busy,
                    onTap: () => { this.remove(file); }
                  })
                }.width('100%')
              }.width('100%').alignItems(HorizontalAlign.Start)
            }
          }
        }, (file: FileRecord) => file.local_id)
      }.width('100%').layoutWeight(1)

      if (!this.files.length && !this.message) {
        Text('暂无托管附件文件').fontSize(13).fontColor($r('app.color.tentacle_text_faint')).padding(20)
      }
    }.width('100%').height('100%').padding({ left: 14, right: 14, top: 8, bottom: 14 }).backgroundColor($r('app.color.tentacle_bg'))
  }
}
