/**
 * DSH 附件选择与读取辅助：
 * - 相册图片：走 PhotoViewPicker + 授权 fd + ImageKit 解码重压 JPEG（规避鸿蒙 13900020 沙箱读写限制）
 * - 本机文档：走 DocumentViewPicker + 分块读取原始字节供 fileUploads/upload 上传
 */

import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { dataSharePredicates } from '@kit.ArkData';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';

const MAX_EDGE_PX = 2048;

export interface PickedImagePayload {
  name: string;
  mediaType: string;
  base64: string;
  bytes: number;
}

export interface PickedDocumentPayload {
  name: string;
  buffer: ArrayBuffer;
  bytes: number;
}

function fileNameFromUri(uri: string): string {
  let clean = uri;
  const q = clean.indexOf('?');
  if (q >= 0) {
    clean = clean.substring(0, q);
  }
  const slash = clean.lastIndexOf('/');
  const raw = slash >= 0 ? clean.substring(slash + 1) : clean;
  try {
    return decodeURIComponent(raw) || 'attachment';
  } catch (_) {
    return raw || 'attachment';
  }
}

async function openPhotoFd(ctx: common.Context, uri: string): Promise<number> {
  const helper = photoAccessHelper.getPhotoAccessHelper(ctx);
  try {
    const granted = await helper.requestPhotoUrisReadPermission([uri]);
    if (granted.length > 0) {
      return fs.openSync(granted[0], fs.OpenMode.READ_ONLY).fd;
    }
  } catch (_) {
    // 降级到 getAssets
  }
  const predicates = new dataSharePredicates.DataSharePredicates();
  predicates.equalTo(photoAccessHelper.PhotoKeys.URI, uri);
  const fr = await helper.getAssets({ fetchColumns: [], predicates: predicates });
  let asset: photoAccessHelper.PhotoAsset | null = null;
  try {
    asset = await fr.getFirstObject();
  } finally {
    fr.close();
  }
  if (asset === null) {
    throw new Error('所选图片不存在');
  }
  return await asset.getReadOnlyFd();
}

export async function pickAndEncodePhotos(ctx: common.Context, maxCount: number,
  maxBytes: number): Promise<PickedImagePayload[]> {
  const viewPicker = new photoAccessHelper.PhotoViewPicker();
  const opts = new photoAccessHelper.PhotoSelectOptions();
  opts.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
  opts.maxSelectNumber = Math.max(1, maxCount);
  let uris: string[] = [];
  try {
    const result = await viewPicker.select(opts);
    if (result && result.photoUris) {
      uris = result.photoUris;
    }
  } catch (_) {
    return [];
  }
  const out: PickedImagePayload[] = [];
  const b64 = new util.Base64Helper();
  for (let i = 0; i < uris.length; i++) {
    const uri = uris[i];
    let fd = -1;
    try {
      fd = await openPhotoFd(ctx, uri);
      const src = image.createImageSource(fd);
      const info = await src.getImageInfo();
      const decOpts: image.DecodingOptions = {};
      const scale = Math.max(info.size.width / MAX_EDGE_PX, info.size.height / MAX_EDGE_PX);
      if (scale > 1) {
        decOpts.desiredSize = {
          width: Math.floor(info.size.width / scale),
          height: Math.floor(info.size.height / scale)
        };
      }
      const pm = await src.createPixelMap(decOpts);
      const packer = image.createImagePacker();
      const buf = await packer.packToData(pm, { format: 'image/jpeg', quality: 88 });
      if (buf.byteLength > maxBytes) {
        throw new Error('图片超过大小限制');
      }
      const rawName = fileNameFromUri(uri).replace(/\.[^.]+$/, '') + '.jpg';
      out.push({
        name: rawName,
        mediaType: 'image/jpeg',
        base64: b64.encodeToStringSync(new Uint8Array(buf)),
        bytes: buf.byteLength
      });
    } finally {
      if (fd >= 0) {
        try {
          fs.closeSync(fd);
        } catch (_) {
          // 忽略关句柄错误
        }
      }
    }
  }
  return out;
}

export async function pickDocuments(ctx: common.UIAbilityContext, maxCount: number,
  maxBytes: number = 32 * 1024 * 1024): Promise<PickedDocumentPayload[]> {
  const docPicker = new picker.DocumentViewPicker(ctx);
  let uris: string[] = [];
  try {
    uris = await docPicker.select({ maxSelectNumber: Math.max(1, maxCount) });
  } catch (_) {
    return [];
  }
  const out: PickedDocumentPayload[] = [];
  for (let i = 0; i < uris.length; i++) {
    const uri = uris[i];
    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      const size = fs.statSync(file.fd).size;
      if (size <= 0 || size > maxBytes) {
        throw new Error('文件需非空且不超过 ' + Math.round(maxBytes / (1024 * 1024)).toString() + ' MiB');
      }
      const bytes = new Uint8Array(size);
      let pos = 0;
      while (pos < size) {
        const chunk = new ArrayBuffer(Math.min(256 * 1024, size - pos));
        const count = fs.readSync(file.fd, chunk);
        if (count <= 0) {
          throw new Error('文件读取不完整');
        }
        bytes.set(new Uint8Array(chunk, 0, count), pos);
        pos += count;
      }
      const docItem: PickedDocumentPayload = {
        name: fileNameFromUri(uri),
        buffer: bytes.buffer as ArrayBuffer,
        bytes: size
      };
      out.push(docItem);
    } finally {
      try {
        fs.closeSync(file);
      } catch (_) {
        // 忽略
      }
    }
  }
  return out;
}
