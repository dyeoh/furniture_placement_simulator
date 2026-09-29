// Sims-style surface painting: pick a swatch, tap a wall or the floor. ← painter.gd

import { Color } from 'three';
import { srgb } from '../color';
import { SURFACES, type RoomBuilder, type Surface } from '../room/room-builder';

/** Wall paints, then timber tones matching the catalogue finishes. */
export const SWATCHES: [string, string][] = [
  ['Chalk', '#eeebe3'], ['Linen', '#e3d9c6'], ['Sage', '#b7c4a8'],
  ['Eucalyptus leaf', '#7f9a7a'], ['Clay', '#c9967a'], ['Terracotta', '#b3624a'],
  ['Ochre', '#d9a441'], ['Slate', '#6c7480'], ['Ink', '#2f3540'],
  ['Blush', '#e8c4c0'], ['Sky', '#b9cfe0'], ['Charcoal', '#3d3b3a'],
  ['American Oak', '#d2b48c'], ['Eucalyptus', '#b58a5a'], ['Blackwood', '#6b4a2f'],
  ['Japanese Black', '#2b2b2e'], ['Pale concrete', '#cfcac2'], ['Warm white', '#f6f1e7'],
];

const HOVER_GLOW = srgb(0.35, 0.33, 0.25);

export class Painter {
  room!: RoomBuilder;
  color = new Color('#b7c4a8');
  hover: Surface | '' = '';

  setup(room: RoomBuilder): void {
    this.room = room;
    this.hover = '';
  }

  setHover(surface: Surface | ''): void {
    if (surface === this.hover) return;
    this.setEmission(this.hover, false);
    this.hover = surface;
    this.setEmission(this.hover, true);
  }

  clearHover(): void { this.setHover(''); }

  apply(surface: Surface | ''): boolean {
    if (!surface || !this.room.materials.has(surface)) return false;
    this.room.paint(surface, this.color);
    return true;
  }

  applyAllWalls(): void {
    for (const s of SURFACES) if (s !== 'floor') this.room.paint(s, this.color);
  }

  /** Hover as a faint emissive lift, so the preview never lies about the swatch. */
  private setEmission(surface: Surface | '', on: boolean): void {
    const m = surface ? this.room.materials.get(surface) : undefined;
    if (!m) return;
    m.emissive.copy(on ? HOVER_GLOW : new Color(0, 0, 0));
  }
}
