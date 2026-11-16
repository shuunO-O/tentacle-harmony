/** Virtual rotary wheel: geometry and hit testing never traverse the whole graph. */
export const WHEEL_STEP: number = 0.45;
export const WHEEL_WINDOW: number = 7;
export interface WheelSlot { index: number; offset: number; }
export interface WheelPoint { x: number; y: number; }

export function wheelPosition(value: number, count: number): number {
  if (!Number.isFinite(value) || count <= 1) { return 0; }
  return count >= WHEEL_WINDOW ? ((value % count) + count) % count : Math.max(0, Math.min(count - 1, value));
}

export function wheelSlots(value: number, count: number): WheelSlot[] {
  const current = Math.round(wheelPosition(value, count)) % Math.max(1, count);
  const result: WheelSlot[] = [];
  for (let offset = -3; offset <= 3; offset++) {
    let index = current + offset;
    if (count >= WHEEL_WINDOW) { index = (index + count) % count; }
    if (index >= 0 && index < count) { result.push({ index: index, offset: offset }); }
  }
  return result;
}

export class GraphWheel {
  count: number = 0;
  position: number = 0;
  set(count: number, position: number): void { this.count = Math.max(0, count); this.position = wheelPosition(position, this.count); }
  index(): number { return Math.round(this.position) % Math.max(1, this.count); }
  turn(radians: number): void { this.position = wheelPosition(this.position - radians / WHEEL_STEP, this.count); }
  snap(): void { this.position = this.index(); }
  offset(index: number): number {
    let delta = index - this.position;
    if (this.count >= WHEEL_WINDOW) {
      if (delta > this.count / 2) { delta -= this.count; }
      if (delta < -this.count / 2) { delta += this.count; }
    }
    return delta;
  }
}

export class WheelGeometry {
  x: number;
  y: number;
  orbit: number;
  orbitX: number;
  core: number;
  nodeRadius: number;
  constructor(width: number, height: number) {
    this.x = width / 2;
    this.nodeRadius = Math.max(36, Math.min(50, width * 0.13));
    this.core = Math.max(76, Math.min(120, width * 0.29));
    this.y = height + this.core * 0.08;
    this.orbitX = Math.max(this.core + this.nodeRadius + 28, width * 0.68);
    this.orbit = Math.max(this.core + this.nodeRadius + 42, this.y - this.nodeRadius - 30);
  }
  point(offset: number): WheelPoint {
    const angle = -Math.PI / 2 + offset * WHEEL_STEP;
    return { x: this.x + Math.cos(angle) * this.orbitX, y: this.y + Math.sin(angle) * this.orbit };
  }
  angle(x: number, y: number): number { return Math.atan2((y - this.y) / this.orbit, (x - this.x) / this.orbitX); }
}

/** Crossing a detent produces at most one short tick; rapid rotations never queue audio. */
export class WheelTickGate {
  private index: number = -1;
  private last: number = -Infinity;
  reset(index: number): void { this.index = index; this.last = -Infinity; }
  crossed(index: number, now: number): boolean {
    if (index === this.index) { return false; }
    this.index = index;
    if (now - this.last < 65) { return false; }
    this.last = now; return true;
  }
}
