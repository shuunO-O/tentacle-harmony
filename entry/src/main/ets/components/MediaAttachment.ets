import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { TentacleApi } from '../service/TentacleApi';
import { FileDownload } from './FileDownload';
import { ActionButton } from './UiKit';

/** Playback starts on tap and carries the same REST credentials as attachment downloads. */
@Component
export struct MediaAttachment {
  localId: string = '';
  filename: string = '';
  mime: string = '';
  @State playerState: string = 'idle';
  @State message: string = '';
  @State elapsed: number = 0;
  @State duration: number = 0;
  private player: media.AVPlayer | null = null;
  private surface: XComponentController = new XComponentController();
  private surfaceId: string = '';
  private generation: number = 0;

  aboutToDisappear(): void {
    this.generation++;
    const player = this.player;
    this.player = null;
    if (player !== null) { player.release().catch(() => {}); }
  }

  private async stateChanged(player: media.AVPlayer, state: string): Promise<void> {
    if (this.player !== player) { return; }
    this.playerState = state;
    try {
      if (state === 'initialized') {
        if (this.mime.startsWith('video/')) {
          if (!this.surfaceId) { throw new Error('视频画面尚未准备好，请重试'); }
          player.surfaceId = this.surfaceId;
        }
        await player.prepare();
      } else if (state === 'prepared') {
        this.duration = player.duration;
        await player.play();
      }
    } catch (e) { this.message = e.message; this.playerState = 'error'; }
  }

  private async toggle(): Promise<void> {
    if (this.playerState === 'loading' || this.playerState === 'initialized') { return; }
    try {
      if (this.player !== null && this.playerState !== 'error') {
        if (this.playerState === 'playing') { await this.player.pause(); }
        else {
          if (this.playerState === 'completed') { this.player.seek(0); }
          await this.player.play();
        }
        return;
      }
      const seq = ++this.generation;
      const old = this.player; this.player = null;
      if (old !== null) { await old.release(); }
      this.playerState = 'loading'; this.message = '';
      const player = await media.createAVPlayer();
      if (seq !== this.generation) { await player.release(); return; }
      this.player = player;
      player.on('stateChange', (state: string) => { this.stateChanged(player, state); });
      player.on('timeUpdate', (time: number) => { if (this.player === player) { this.elapsed = time; } });
      player.on('error', (error: BusinessError) => {
        if (this.player === player) { this.message = '播放失败：' + error.message; this.playerState = 'error'; }
      });
      const api = TentacleApi.getInstance();
      const source = media.createMediaSourceWithUrl(api.getServerUrl() + '/api/files/' + encodeURIComponent(this.localId) + '/content', api.downloadHeaders());
      await player.setMediaSource(source);
    } catch (e) { this.message = e.message; this.playerState = 'error'; }
  }

  build() {
    Column({ space: 6 }) {
      Text(this.filename).fontSize(13).fontColor($r('app.color.tentacle_text')).width('100%')
      if (this.mime.startsWith('video/')) {
        XComponent({ id: 'attachment-' + this.localId, type: XComponentType.SURFACE, controller: this.surface })
          .width('100%').height(180).backgroundColor('#000000')
          .onLoad(() => { this.surfaceId = this.surface.getXComponentSurfaceId(); })
      }
      ActionButton({
        label: this.playerState === 'playing' ? '暂停' : this.playerState === 'loading' || this.playerState === 'initialized' ? '准备中…' : '播放',
        tone: 'accent',
        compact: true,
        onTap: () => { this.toggle(); }
      })
      if (this.duration > 0) {
        Slider({ value: this.elapsed, min: 0, max: this.duration, step: 1000 }).width('100%')
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.End && this.player !== null) { this.player.seek(value); }
          })
        Text(Math.floor(this.elapsed / 1000) + ' / ' + Math.floor(this.duration / 1000) + ' 秒').fontSize(11).fontColor($r('app.color.tentacle_text_dim'))
      }
      if (this.message) { Text(this.message).fontSize(12).fontColor($r('app.color.tentacle_danger')) }
      FileDownload({ endpoint: '/api/files/' + encodeURIComponent(this.localId) + '/content', filename: this.filename })
    }.width('100%').padding(8).alignItems(HorizontalAlign.Start)
  }
}
