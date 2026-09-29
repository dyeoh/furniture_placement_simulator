// On-screen controls for the walkthrough on touch devices. ← touch_controls.gd
//
// Left of the screen: a floating stick whose base appears under the first
// finger. Right: a look pad, drag to turn. A button toggles carry, another
// leaves Walk. Pointer Events carry touch, pen and mouse alike, so `?touch=1`
// works with a mouse for trying it out.

import { queryParam } from '../web/host-bridge';

const STICK_RADIUS = 60;
const MARGIN = 24;
/** Fraction of the width given to the stick; the rest is the look pad. */
const STICK_ZONE = 0.45;

export function touchWanted(): boolean {
  return matchMedia('(pointer: coarse)').matches || navigator.maxTouchPoints > 0 || queryParam('touch') === '1';
}

export class TouchControls {
  readonly root = document.createElement('div');
  /** Desired walking direction in screen axes: x right, y down (= backwards). */
  readonly vector = { x: 0, y: 0 };
  onLook: ((dx: number, dy: number) => void) | null = null;
  onInteract: (() => void) | null = null;
  onExit: (() => void) | null = null;
  private stickId = -1;
  private origin = { x: 0, y: 0 };
  private lookId = -1;
  private last = { x: 0, y: 0 };
  private base = document.createElement('div');
  private knob = document.createElement('div');
  private grab = document.createElement('button');

  constructor() {
    const r = this.root;
    r.className = 'touch';
    r.hidden = true;
    const stick = document.createElement('div');
    stick.className = 'touch-stick';
    stick.style.width = `${STICK_ZONE * 100}%`;
    this.base.className = 'stick-base';
    this.knob.className = 'stick-knob';
    stick.append(this.base, this.knob);
    const pad = document.createElement('div');
    pad.className = 'touch-look';
    pad.style.left = `${STICK_ZONE * 100}%`;
    const hint = document.createElement('span');
    hint.textContent = 'drag to look around';
    pad.append(hint);
    this.grab.className = 'touch-btn grab';
    this.grab.textContent = 'Pick up';
    this.grab.addEventListener('click', () => this.onInteract?.());
    const exit = document.createElement('button');
    exit.className = 'touch-btn exit';
    exit.textContent = '‹ Planner';
    exit.addEventListener('click', () => this.onExit?.());
    r.append(stick, pad, this.grab, exit);

    stick.addEventListener('pointerdown', (e) => {
      if (this.stickId !== -1) return;
      stick.setPointerCapture(e.pointerId);
      this.stickId = e.pointerId;
      const rect = stick.getBoundingClientRect();
      this.origin = { x: e.clientX - rect.left, y: e.clientY - rect.top };
      this.vector.x = this.vector.y = 0;
      this.draw();
    });
    stick.addEventListener('pointermove', (e) => {
      if (e.pointerId !== this.stickId) return;
      const rect = stick.getBoundingClientRect();
      let x = (e.clientX - rect.left - this.origin.x) / STICK_RADIUS;
      let y = (e.clientY - rect.top - this.origin.y) / STICK_RADIUS;
      const l = Math.hypot(x, y);
      if (l > 1) { x /= l; y /= l; }
      this.vector.x = x;
      this.vector.y = y;
      this.draw();
    });
    const endStick = (e: PointerEvent) => {
      if (e.pointerId !== this.stickId) return;
      this.stickId = -1;
      this.vector.x = this.vector.y = 0;
      this.draw();
    };
    stick.addEventListener('pointerup', endStick);
    stick.addEventListener('pointercancel', endStick);

    pad.addEventListener('pointerdown', (e) => {
      if (this.lookId !== -1) return;
      pad.setPointerCapture(e.pointerId);
      this.lookId = e.pointerId;
      this.last = { x: e.clientX, y: e.clientY };
    });
    // Deltas from this pad's own last position, never movementX: with two
    // fingers down some browsers compute that against the other finger.
    pad.addEventListener('pointermove', (e) => {
      if (e.pointerId !== this.lookId) return;
      this.onLook?.(e.clientX - this.last.x, e.clientY - this.last.y);
      this.last = { x: e.clientX, y: e.clientY };
    });
    const endLook = (e: PointerEvent) => { if (e.pointerId === this.lookId) this.lookId = -1; };
    pad.addEventListener('pointerup', endLook);
    pad.addEventListener('pointercancel', endLook);
    this.draw();
  }

  set visible(v: boolean) { this.root.hidden = !v; }
  get visible(): boolean { return !this.root.hidden; }

  setCarrying(carrying: boolean): void {
    const t = carrying ? 'Put down' : 'Pick up';
    if (this.grab.textContent !== t) this.grab.textContent = t;
  }

  private draw(): void {
    const h = this.root.parentElement?.clientHeight ?? innerHeight;
    const c = this.stickId !== -1 ? this.origin : { x: MARGIN + STICK_RADIUS, y: h - MARGIN - STICK_RADIUS };
    this.base.style.transform = `translate(${c.x - STICK_RADIUS}px, ${c.y - STICK_RADIUS}px)`;
    const kx = c.x + this.vector.x * STICK_RADIUS - 26;
    const ky = c.y + this.vector.y * STICK_RADIUS - 26;
    this.knob.style.transform = `translate(${kx}px, ${ky}px)`;
  }
}
