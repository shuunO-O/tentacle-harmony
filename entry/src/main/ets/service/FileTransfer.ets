import { http } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { TentacleApi } from './TentacleApi';
import { attachmentName } from '../model/FileMarkers';

/** Download into a temporary sandbox file; only copy a successful response to the user-selected URI. */
export async function saveAttachment(context: common.UIAbilityContext, endpoint: string, name: string): Promise<boolean> {
  if (!endpoint.startsWith('/api/files/')) { throw new Error('无效下载地址'); }
  const api = TentacleApi.getInstance();
  const temporary = context.cacheDir + '/tentacle-download-' + Date.now() + '-' + Math.random().toString(36).slice(2);
  const req = http.createHttp();
  let file: fs.File | null = null;
  let writeError = '';
  try {
    file = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    const fd = file.fd;
    req.on('dataReceive', (chunk: ArrayBuffer) => {
      if (writeError) { return; }
      try {
        let written = 0;
        while (written < chunk.byteLength) {
          const n = fs.writeSync(fd, chunk.slice(written));
          if (n <= 0) { throw new Error('文件写入中断'); }
          written += n;
        }
      } catch (e) { writeError = e.message; }
    });
    const ended = new Promise<void>((resolve) => { req.on('dataEnd', () => resolve()); });
    const code = await req.requestInStream(api.getServerUrl() + endpoint, {
      method: http.RequestMethod.GET, header: api.downloadHeaders(), usingCache: false,
      connectTimeout: 10000, readTimeout: 300000,
    });
    await ended;
    if (code === 401) { api.signalUnauthorized(); }
    if (code < 200 || code >= 300) { throw new Error('下载失败 HTTP ' + code); }
    if (writeError) { throw new Error(writeError); }
    fs.closeSync(file); file = null;
    const viewPicker = new picker.DocumentViewPicker(context);
    const destinations = await viewPicker.save({ newFileNames: [attachmentName(name)] });
    if (destinations.length === 0) { return false; }
    const source = fs.openSync(temporary, fs.OpenMode.READ_ONLY);
    let destination: fs.File | null = null;
    try {
      destination = fs.openSync(destinations[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      await fs.copyFile(source.fd, destination.fd);
    } finally {
      fs.closeSync(source);
      if (destination !== null) { fs.closeSync(destination); }
    }
    return true;
  } finally {
    req.destroy();
    if (file !== null) { fs.closeSync(file); }
    try { fs.unlinkSync(temporary); } catch (e) { /* Temporary file may not have been created. */ }
  }
}
