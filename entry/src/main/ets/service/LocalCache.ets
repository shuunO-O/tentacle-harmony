import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

const MAX_BYTES: number = 64 * 1024 * 1024;
const MAX_ENTRY_BYTES: number = 8 * 1024 * 1024;
const MAX_ENTRIES: number = 66;
interface CacheEnvelope { version: number; scope: string; savedAt: number; value: string; }
interface CacheFile { name: string; size: number; modified: number; }

export async function cacheHash(value: string): Promise<string> {
  const md = cryptoFramework.createMd('SHA256');
  await md.update({ data: new util.TextEncoder().encodeInto(value) });
  const digest = await md.digest();
  let result = '';
  for (const byte of digest.data) { result += byte.toString(16).padStart(2, '0'); }
  return result;
}

/** Private app storage. All instances share an IO queue so logout cannot race a pending write. */
export class LocalCache {
  private static queue: Promise<void> = Promise.resolve();
  private active: boolean = true;
  private scope: Promise<string>;
  private root: string;

  constructor(root: string, scopeSource: string) {
    this.root = root;
    this.scope = cacheHash(scopeSource).catch(() => '');
  }

  private enqueue<T>(action: () => Promise<T>): Promise<T> {
    const task = LocalCache.queue.then(action);
    LocalCache.queue = task.then(() => {}, () => {});
    return task;
  }

  private path(key: string): string {
    if (!/^[a-z0-9-]{1,100}$/.test(key)) { throw new Error('Invalid cache key'); }
    return this.root + '/' + key + '.json';
  }

  private async unlink(path: string): Promise<void> {
    try { await fs.unlink(path); } catch (e) { /* Eviction is best effort. */ }
  }

  read(key: string, maxAge: number): Promise<string | null> {
    return this.enqueue<string | null>(async () => {
      if (!this.active) { return null; }
      const scope = await this.scope;
      if (!scope || !this.active) { return null; }
      const path = this.path(key);
      try {
        const stat = await fs.stat(path);
        if (stat.size <= 0 || stat.size > MAX_ENTRY_BYTES) { await this.unlink(path); return null; }
        const item = JSON.parse(await fs.readText(path)) as CacheEnvelope;
        if (!this.active) { return null; }
        if (item.version !== 1 || item.scope !== scope || typeof item.value !== 'string' ||
          !Number.isFinite(item.savedAt) || item.savedAt > Date.now() + 60000 || Date.now() - item.savedAt > maxAge) {
          await this.unlink(path); return null;
        }
        return item.value;
      } catch (e) { await this.unlink(path); return null; }
    });
  }

  write(key: string, value: string): Promise<void> {
    return this.enqueue<void>(async () => {
      if (!this.active) { return; }
      const scope = await this.scope;
      if (!scope || !this.active) { return; }
      const path = this.path(key);
      const temporary = path + '.tmp';
      let file: fs.File | null = null;
      try {
        try { await fs.mkdir(this.root); } catch (e) { /* Directory may already exist. */ }
        const envelope: CacheEnvelope = { version: 1, scope: scope, savedAt: Date.now(), value: value };
        const bytes = new util.TextEncoder().encodeInto(JSON.stringify(envelope));
        if (bytes.byteLength > MAX_ENTRY_BYTES) { await this.unlink(path); return; }
        file = await fs.open(temporary, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        let written = 0;
        while (written < bytes.byteLength && this.active) {
          const chunk = bytes.slice(written, Math.min(written + 256 * 1024, bytes.byteLength));
          const count = await fs.write(file.fd, chunk.buffer);
          if (count <= 0) { throw new Error('Incomplete cache write'); }
          written += count;
        }
        await fs.close(file); file = null;
        if (!this.active) { return; }
        await fs.rename(temporary, path);
        await this.prune();
      } catch (e) { /* Cache failures must not fail the network operation or destroy the last snapshot. */ }
      finally {
        if (file !== null) { try { await fs.close(file); } catch (e) {} }
        await this.unlink(temporary);
      }
    });
  }

  remove(key: string): Promise<void> {
    return this.enqueue<void>(async () => { if (this.active) { await this.unlink(this.path(key)); } });
  }

  private async files(): Promise<CacheFile[]> {
    const result: CacheFile[] = [];
    try {
      for (const name of await fs.listFile(this.root)) {
        if (!/^[a-z0-9-]{1,100}\.json(\.tmp)?$/.test(name)) { continue; }
        const stat = await fs.stat(this.root + '/' + name);
        if (name.endsWith('.tmp')) { await this.unlink(this.root + '/' + name); continue; }
        result.push({ name: name, size: stat.size, modified: stat.mtime });
      }
    } catch (e) { /* A missing cache directory is an empty cache. */ }
    return result;
  }

  private async prune(): Promise<void> {
    const files = await this.files();
    files.sort((a: CacheFile, b: CacheFile) => a.modified - b.modified);
    let total = 0;
    for (const file of files) { total += file.size; }
    let count = files.length;
    for (const file of files) {
      if (total <= MAX_BYTES && count <= MAX_ENTRIES) { break; }
      await this.unlink(this.root + '/' + file.name); total -= file.size; count--;
    }
  }

  size(): Promise<number> {
    return this.enqueue<number>(async () => {
      let total = 0;
      for (const file of await this.files()) { total += file.size; }
      return total;
    });
  }

  closeAndClear(): Promise<void> {
    this.active = false;
    return this.enqueue<void>(async () => {
      for (const file of await this.files()) { await this.unlink(this.root + '/' + file.name); }
    });
  }

  flush(): Promise<void> { return LocalCache.queue; }
}
