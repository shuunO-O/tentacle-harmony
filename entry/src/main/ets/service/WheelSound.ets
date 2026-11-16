import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { resourceManager } from '@kit.LocalizationKit';

/** Preloaded local UI sounds. Late loads and page exits cannot retain a player or raw-file FD. */
export class WheelSound {
  private static cleanup: Promise<void> = Promise.resolve();
  private pool: media.SoundPool | null = null;
  private manager: resourceManager.ResourceManager | null = null;
  private files: string[] = [];
  private ready: Set<number> = new Set();
  private tickId: number = -1;
  private selectId: number = -1;
  private epoch: number = 0;
  private active: boolean = false;
  private pending: Promise<boolean> = Promise.resolve(false);

  start(manager: resourceManager.ResourceManager): Promise<boolean> {
    const epoch = ++this.epoch; this.active = true;
    const previous = WheelSound.cleanup;
    this.pending = this.prepare(manager, epoch, previous);
    return this.pending;
  }

  private async prepare(manager: resourceManager.ResourceManager, epoch: number, previous: Promise<void>): Promise<boolean> {
    try {
      await previous;
      if (epoch !== this.epoch) { return false; }
      const pool = await media.createSoundPool(1, { usage: audio.StreamUsage.STREAM_USAGE_GAME, rendererFlags: 0 });
      if (epoch !== this.epoch) { await pool.release(); return false; }
      this.pool = pool; this.manager = manager;
      pool.on('loadComplete', (id: number) => { if (epoch === this.epoch) { this.ready.add(id); } });
      pool.on('error', () => { if (epoch === this.epoch) { this.ready.clear(); } });
      this.tickId = await this.load(manager, pool, 'wheel_tick.wav', epoch);
      if (epoch !== this.epoch) { return false; }
      this.selectId = await this.load(manager, pool, 'wheel_select.wav', epoch);
      return epoch === this.epoch && this.tickId > 0 && this.selectId > 0;
    } catch (e) { if (epoch === this.epoch) { this.active = false; this.ready.clear(); } return false; }
  }

  private async load(manager: resourceManager.ResourceManager, pool: media.SoundPool, name: string, epoch: number): Promise<number> {
    const fd = await manager.getRawFd(name);
    if (epoch !== this.epoch) { await manager.closeRawFd(name); return -1; }
    this.files.push(name);
    return pool.load(fd.fd, fd.offset, fd.length);
  }

  play(select: boolean = false): void {
    const pool = this.pool; const id = select ? this.selectId : this.tickId;
    if (!this.active || pool === null || !this.ready.has(id)) { return; }
    try { pool.play(id, { loop: 0, leftVolume: select ? 0.3 : 0.22, rightVolume: select ? 0.3 : 0.22 }).catch(() => {}); } catch (e) {}
  }

  release(): void {
    this.active = false; this.epoch++; this.ready.clear();
    const pending = this.pending;
    const cleanup = async (): Promise<void> => {
      await pending;
      const pool = this.pool; const manager = this.manager; const files = this.files;
      this.pool = null; this.manager = null; this.files = []; this.tickId = -1; this.selectId = -1;
      if (pool !== null) { try { await pool.release(); } catch (e) {} }
      if (manager !== null) { for (const name of files) { try { await manager.closeRawFd(name); } catch (e) {} } }
    };
    WheelSound.cleanup = WheelSound.cleanup.then(cleanup, cleanup);
  }
}
