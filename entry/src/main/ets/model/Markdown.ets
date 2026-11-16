/** 原生 Markdown 展示模型。HTML 始终按文字展示，链接只接受 HTTP(S)。 */
export class MarkdownSpan {
  text: string = '';
  bold: boolean = false;
  italic: boolean = false;
  strike: boolean = false;
  code: boolean = false;
  url: string = '';
}

export class MarkdownCell {
  spans: MarkdownSpan[] = [];
  align: string = 'left';
}

export class MarkdownTableRow {
  cells: MarkdownCell[] = [];
}

export class MarkdownBlock {
  source: string = '';
  kind: string = 'paragraph';
  spans: MarkdownSpan[] = [];
  text: string = '';
  level: number = 0;
  prefix: string = '';
  language: string = '';
  rows: MarkdownTableRow[] = [];
}

export function isMarkdownLink(url: string): boolean {
  return /^https?:\/\/[^\s<>]+$/i.test(url);
}

function plainSpan(text: string): MarkdownSpan {
  const span = new MarkdownSpan();
  span.text = text;
  return span;
}

function linkEnd(text: string, start: number): number {
  let depth = 1;
  for (let i = start; i < text.length; i++) {
    if (text[i] === '\\') {
      i++;
    } else if (text[i] === '(') {
      depth++;
    } else if (text[i] === ')' && --depth === 0) {
      return i;
    }
  }
  return -1;
}

export function parseMarkdownInline(text: string, depth: number = 0): MarkdownSpan[] {
  if (depth > 6) {
    return [plainSpan(text)];
  }
  const out: MarkdownSpan[] = [];
  let plain = '';
  let i = 0;
  while (i < text.length) {
    const ch = text[i];
    let spans: MarkdownSpan[] = [];
    let end = i;
    if (ch === '\\' && i + 1 < text.length && /[\\`*{}\[\]()#+\-.!_>|~]/.test(text[i + 1])) {
      plain += text[i + 1];
      i += 2;
      continue;
    }
    if (ch === '`') {
      let size = 1;
      while (text[i + size] === '`') {
        size++;
      }
      const marker = '`'.repeat(size);
      const close = text.indexOf(marker, i + size);
      if (close >= 0) {
        const span = plainSpan(text.substring(i + size, close).replace(/\n/g, ' '));
        span.code = true;
        spans = [span];
        end = close + size;
      }
    } else if (ch === '[' || (ch === '!' && text[i + 1] === '[')) {
      const image = ch === '!';
      const labelStart = i + (image ? 2 : 1);
      const labelEnd = text.indexOf('](', labelStart);
      if (labelEnd >= 0) {
        const close = linkEnd(text, labelEnd + 2);
        if (close >= 0) {
          const label = text.substring(labelStart, labelEnd);
          let url = text.substring(labelEnd + 2, close).trim().split(/\s+["']/)[0];
          if (url.startsWith('<') && url.endsWith('>')) {
            url = url.substring(1, url.length - 1);
          }
          spans = image ? [plainSpan('【图片：' + (label || '图片') + '】')] : parseMarkdownInline(label, depth + 1);
          for (let j = 0; j < spans.length; j++) {
            spans[j].url = !image && isMarkdownLink(url) ? url : '';
          }
          end = close + 1;
        }
      }
    } else if (ch === '<') {
      const close = text.indexOf('>', i + 1);
      if (close >= 0 && isMarkdownLink(text.substring(i + 1, close))) {
        const span = plainSpan(text.substring(i + 1, close));
        span.url = span.text;
        spans = [span];
        end = close + 1;
      }
    } else if (ch === '*' || ch === '_' || ch === '~') {
      const tail = text.substring(i);
      let marker = ch;
      if (tail.startsWith('***') || tail.startsWith('___')) {
        marker = ch.repeat(3);
      } else if (tail.startsWith(ch.repeat(2))) {
        marker = ch.repeat(2);
      }
      const intraword = ch === '_' && i > 0 && /[\p{L}\p{N}]/u.test(text[i - 1]);
      const close = text.indexOf(marker, i + marker.length);
      if (!intraword && (ch !== '~' || marker === '~~') && close > i + marker.length &&
        !/\s/.test(text[i + marker.length]) && !/\s/.test(text[close - 1])) {
        spans = parseMarkdownInline(text.substring(i + marker.length, close), depth + 1);
        for (let j = 0; j < spans.length; j++) {
          spans[j].bold = spans[j].bold || (ch !== '~' && marker.length >= 2);
          spans[j].italic = spans[j].italic || (ch !== '~' && marker.length !== 2);
          spans[j].strike = spans[j].strike || ch === '~';
        }
        end = close + marker.length;
      }
    }
    if (end > i) {
      if (plain.length > 0) {
        out.push(plainSpan(plain));
        plain = '';
      }
      for (let j = 0; j < spans.length; j++) {
        out.push(spans[j]);
      }
      i = end;
    } else {
      plain += ch;
      i++;
    }
  }
  if (plain.length > 0) {
    out.push(plainSpan(plain));
  }
  return out;
}

function tableCells(line: string): string[] {
  let text = line.trim();
  if (text.startsWith('|')) {
    text = text.substring(1);
  }
  if (text.endsWith('|') && !text.endsWith('\\|')) {
    text = text.substring(0, text.length - 1);
  }
  const cells: string[] = [];
  let cell = '';
  let codeMarker = '';
  for (let i = 0; i < text.length; i++) {
    if (text[i] === '\\' && i + 1 < text.length) {
      cell += text[i] + text[++i];
    } else if (text[i] === '`') {
      let marker = '`';
      while (text[i + 1] === '`') {
        marker += text[++i];
      }
      codeMarker = codeMarker === marker ? '' : (codeMarker || marker);
      cell += marker;
    } else if (text[i] === '|' && codeMarker.length === 0) {
      cells.push(cell.trim());
      cell = '';
    } else {
      cell += text[i];
    }
  }
  cells.push(cell.trim());
  return cells;
}

function isTableDivider(line: string): boolean {
  const cells = tableCells(line);
  return cells.length > 0 && cells.every((cell: string) => /^:?-{3,}:?$/.test(cell));
}

function isBlockStart(line: string): boolean {
  return /^\s*$|^ {0,3}(?:#{1,6}\s|>|`{3,}|~{3,}|(?:[-+*]|\d+[.)])\s)|^\s*(?:\*\s*){3,}$|^\s*(?:-\s*){3,}$|^\s*(?:_\s*){3,}$/.test(line);
}

export function parseMarkdown(text: string): MarkdownBlock[] {
  const lines = text.replace(/\r\n?/g, '\n').split('\n');
  const blocks: MarkdownBlock[] = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (line.trim().length === 0) {
      i++;
      continue;
    }
    const start = i;
    const block = new MarkdownBlock();
    const fence = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
    const heading = line.match(/^ {0,3}(#{1,6})\s+(.+?)\s*$/);
    const list = line.match(/^(\s*)([-+*]|\d+[.)])\s+(.*)$/);
    if (fence !== null) {
      block.kind = 'code';
      block.language = fence[2].trim();
      const body: string[] = [];
      i++;
      while (i < lines.length) {
        const close = lines[i].trim();
        if (close.length >= fence[1].length && close.split('').every((c: string) => c === fence[1][0])) {
          i++;
          break;
        }
        body.push(lines[i++]);
      }
      block.text = body.join('\n');
    } else if (i + 1 < lines.length && line.includes('|') && isTableDivider(lines[i + 1]) &&
      tableCells(line).length === tableCells(lines[i + 1]).length) {
      block.kind = 'table';
      const dividers = tableCells(lines[i + 1]);
      const tableLines: string[] = [line];
      i += 2;
      while (i < lines.length && lines[i].includes('|') && lines[i].trim().length > 0 && !isBlockStart(lines[i])) {
        tableLines.push(lines[i++]);
      }
      for (let r = 0; r < tableLines.length; r++) {
        const row = new MarkdownTableRow();
        const values = tableCells(tableLines[r]);
        for (let c = 0; c < dividers.length; c++) {
          const cell = new MarkdownCell();
          cell.spans = parseMarkdownInline(values[c] ?? '');
          cell.align = dividers[c].endsWith(':') ? (dividers[c].startsWith(':') ? 'center' : 'right') : 'left';
          row.cells.push(cell);
        }
        block.rows.push(row);
      }
    } else if (/^\s*(?:(?:\*\s*){3,}|(?:-\s*){3,}|(?:_\s*){3,})$/.test(line)) {
      block.kind = 'rule';
      i++;
    } else if (heading !== null) {
      block.kind = 'heading';
      block.level = heading[1].length;
      block.spans = parseMarkdownInline(heading[2].replace(/\s+#+\s*$/, ''));
      i++;
    } else if (/^ {0,3}>/.test(line)) {
      block.kind = 'quote';
      const quote: string[] = [];
      while (i < lines.length && /^ {0,3}>/.test(lines[i])) {
        quote.push(lines[i++].replace(/^ {0,3}>\s?/, ''));
      }
      block.spans = parseMarkdownInline(quote.join('\n'));
    } else if (list !== null) {
      block.kind = 'list';
      block.level = Math.min(Math.floor(list[1].replace(/\t/g, '    ').length / 2), 6);
      block.prefix = /^\d/.test(list[2]) ? list[2] : '•';
      let body = list[3];
      const task = body.match(/^\[([ xX])\]\s+(.*)$/);
      if (task !== null) {
        block.prefix = task[1] === ' ' ? '☐' : '☑';
        body = task[2];
      }
      block.spans = parseMarkdownInline(body);
      i++;
    } else {
      const body: string[] = [line];
      i++;
      if (i < lines.length && /^ {0,3}(?:={3,}|-{3,})\s*$/.test(lines[i])) {
        block.kind = 'heading';
        block.level = lines[i].trim().startsWith('=') ? 1 : 2;
        i++;
      } else {
        while (i < lines.length && !isBlockStart(lines[i]) &&
          !(i + 1 < lines.length && lines[i].includes('|') && isTableDivider(lines[i + 1]))) {
          body.push(lines[i++]);
        }
      }
      block.spans = parseMarkdownInline(body.join('\n'));
    }
    // 每次解析会生成新的普通对象；内容改变时必须重建对应的 ArkUI 子树。
    // 使用原文也能区分仅样式、链接或表格单元格改变而纯文本相同的情况。
    block.source = lines.slice(start, i).join('\n');
    blocks.push(block);
  }
  return blocks;
}
