/** Bound drawing input without altering the full node stored in GraphSnapshot. */
export function graphPreviewText(text: string, limit: number = 128): string {
  if (text.length <= limit) { return text; }
  let end = limit;
  const last = text.charCodeAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) { end--; }
  return text.slice(0, end) + '…';
}

/** Native text shaping is expensive. Fit once per label/font/width, never once per frame. */
export class GraphTextLayout {
  private widths: Map<string, number> = new Map();
  private fits: Map<string, string> = new Map();
  private static readonly LIMIT: number = 256;

  clear(): void { this.widths.clear(); this.fits.clear(); }

  width(text: string, font: string, measure: (text: string) => number): number {
    const key = JSON.stringify([font, text]); const cached = this.widths.get(key);
    if (cached !== undefined) { return cached; }
    const width = measure(text); this.widths.set(key, width);
    if (this.widths.size > GraphTextLayout.LIMIT) { this.widths.delete(this.widths.keys().next().value!); }
    return width;
  }

  fit(text: string, width: number, font: string, measure: (text: string) => number): string {
    const input = graphPreviewText(text); const key = JSON.stringify([font, width, input]);
    const cached = this.fits.get(key); if (cached !== undefined) { return cached; }
    let result = input;
    if (width <= 0) { result = ''; }
    else if (this.width(input, font, measure) > width) {
      const chars = Array.from(input.endsWith('…') ? input.slice(0, -1) : input);
      let low = 0; let high = chars.length;
      if (this.width('…', font, measure) > width) { result = ''; }
      else {
        while (low < high) {
          const middle = Math.ceil((low + high) / 2);
          if (this.width(chars.slice(0, middle).join('') + '…', font, measure) <= width) { low = middle; }
          else { high = middle - 1; }
        }
        result = chars.slice(0, low).join('') + '…';
      }
    }
    this.fits.set(key, result);
    if (this.fits.size > GraphTextLayout.LIMIT) { this.fits.delete(this.fits.keys().next().value!); }
    return result;
  }
}
