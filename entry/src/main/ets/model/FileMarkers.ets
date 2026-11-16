@Observed
export class MessagePart {
  kind: string = 'text';
  text: string = '';
}

/** Retain observed text objects so reused ForEach children receive each streaming increment. */
export function reconcileMessageParts(previous: MessagePart[], text: string): MessagePart[] {
  const parsed = splitFileMarkers(text);
  return parsed.map((part: MessagePart, index: number): MessagePart => {
    const current = previous[index];
    if (current !== undefined && current.kind === part.kind &&
      (part.kind === 'text' || current.text === part.text)) {
      if (current.text !== part.text) { current.text = part.text; }
      return current;
    }
    return part;
  });
}

export function messagePartKey(part: MessagePart, index: number): string {
  return part.kind + ':' + index.toString() + (part.kind === 'file' ? ':' + part.text : '');
}

/** Same grammar as Web/outgoing_files: ignore escaped, inline-code and fenced markers. */
export function splitFileMarkers(text: string): MessagePart[] {
  const parts: MessagePart[] = [];
  let offset = 0;
  let last = 0;
  let fence = '';
  const lines = text.match(/[^\n]*\n|[^\n]+$/g) ?? [];
  for (const line of lines) {
    const match = line.replace(/[\r\n]+$/, '').match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
    if (match !== null) {
      const marker = match[1];
      if (!fence) { fence = marker; }
      else if (marker[0] === fence[0] && marker.length >= fence.length && !match[2].trim()) { fence = ''; }
    } else if (!fence) {
      const inline = /(?<!`)(`+)(?!`)[^\r\n]*?(?<!`)\1(?!`)|(?<!\\)\[file:([^\]\r\n]+)\]/g;
      let item = inline.exec(line);
      while (item !== null) {
        if (item[2] !== undefined && item[2].trim()) {
          const start = offset + item.index;
          if (start > last) {
            const p = new MessagePart(); p.text = text.slice(last, start); parts.push(p);
          }
          const p = new MessagePart(); p.kind = 'file'; p.text = item[2].trim(); parts.push(p);
          last = start + item[0].length;
        }
        item = inline.exec(line);
      }
    }
    offset += line.length;
  }
  if (last < text.length) { const p = new MessagePart(); p.text = text.slice(last); parts.push(p); }
  return parts;
}

export function attachmentName(path: string): string {
  const clean = path.replace(/\\/g, '/');
  const name = clean.substring(clean.lastIndexOf('/') + 1).replace(/[\x00-\x1f]/g, '').trim();
  return name && name !== '.' && name !== '..' ? name : 'download';
}

export function isImage(mime: string | undefined): boolean { return (mime ?? '').startsWith('image/'); }

export function visibleUserText(text: string, attachmentPaths: string[]): string {
  let visible = text;
  for (const path of attachmentPaths) {
    if (path) { visible = visible.split('[file:' + path + ']').join(''); }
  }
  return visible.trim();
}
