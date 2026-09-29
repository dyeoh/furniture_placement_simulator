// Two tiers, so a 2017 phone gets a usable planner rather than a slideshow. ← quality.gd
//
// Low spec renders 3D at 70% and drops the expensive shadows. Chosen up front
// from `?quality=low|high` or a weak-looking device, else by a watchdog: if
// frames average slower than 30 fps for a few seconds after start-up, drop
// once and stay there.

import { queryParam } from '../web/host-bridge';

const SLOW_FRAME_MS = 33;
/** Shader compilation and the first settle make everything look slow. */
const GRACE_SECONDS = 6;
const WINDOW_SECONDS = 3;
export const RENDER_SCALE_LOW = 0.7;

export class Quality {
  low = false;
  /** A hint or a weak device decided; the watchdog stays out of it. */
  forced = false;
  onChanged: ((low: boolean) => void) | null = null;
  private elapsed = 0;
  private window = 0;
  private frames = 0;

  decide(): void {
    const hint = queryParam('quality');
    if (hint === 'low' || hint === 'high') {
      this.low = hint === 'low';
      this.forced = true;
    } else if (Quality.deviceLooksSlow()) {
      this.low = true;
      this.forced = true;
    }
  }

  /** 2 GB / 2 cores is the 2016 phone tier. */
  static deviceLooksSlow(): boolean {
    const nav = navigator as Navigator & { deviceMemory?: number };
    return (nav.deviceMemory ?? 8) <= 2 || (navigator.hardwareConcurrency || 4) <= 2;
  }

  label(): string { return this.low ? 'low' : 'high'; }

  /** Once per rendered frame. */
  watch(dt: number): void {
    if (this.low || this.forced) return;
    this.elapsed += dt;
    if (this.elapsed < GRACE_SECONDS) return;
    this.window += dt;
    this.frames += 1;
    if (this.window < WINDOW_SECONDS) return;
    const avgMs = (this.window / this.frames) * 1000;
    this.window = 0;
    this.frames = 0;
    if (avgMs > SLOW_FRAME_MS) {
      this.low = true;
      this.onChanged?.(true);
    }
  }
}
