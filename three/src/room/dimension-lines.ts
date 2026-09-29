// Architectural dimension lines: width along an X edge, depth along a Z edge,
// each a bar with end ticks and a label, on the floor just outside the walls,
// and the wall height standing beside the cut end of a wall. ← dimension_lines.gd
//
// They sit on the side facing the camera (the wall the cutaway hid), so they
// are never behind a wall; update() moves them as the view orbits. Bars are
// thin boxes, not line primitives: a one-pixel line vanishes on a phone.

import {
  BoxGeometry, CanvasTexture, Group, LinearFilter, Mesh, MeshBasicMaterial, SRGBColorSpace, Sprite,
  SpriteMaterial, Vector3,
} from 'three';
import { srgb } from '../color';
import type { RoomBuilder } from './room-builder';
import type { Wall } from './wall-opening';

const OFFSET = 0.35;
const BAR = 0.015;
const TICK = 0.25;
const COLOR = srgb(0.22, 0.22, 0.24);
/** Label height as a fraction of the viewport, like Godot's fixed_size Label3D. */
const LABEL_SCREEN_HEIGHT = 0.042;

export class DimensionLines extends Group {
  private room!: RoomBuilder;
  private widthLine: Group | null = null;
  private depthLine: Group | null = null;
  private heightLine: Group | null = null;
  private mat = new MeshBasicMaterial({ color: COLOR });

  build(room: RoomBuilder): void {
    this.room = room;
    this.clear();
    const f = (v: number) => `${v.toFixed(2)} m`;
    this.widthLine = this.line(room.width, f(room.width), new Vector3(1, 0, 0), new Vector3(0, 0, 1));
    this.depthLine = this.line(room.depth, f(room.depth), new Vector3(0, 0, 1), new Vector3(1, 0, 0));
    this.heightLine = this.line(room.wallHeight, f(room.wallHeight), new Vector3(0, 1, 0), new Vector3(1, 0, 0));
    this.add(this.widthLine, this.depthLine, this.heightLine);
    this.update(['south', 'east']);
  }

  /** Move each line to the edge whose wall is cut away (facing the camera). */
  update(hidden: Wall[]): void {
    if (!this.widthLine || !this.depthLine || !this.heightLine) return;
    const h = this.room.halfExtents();
    const out = this.room.wallThickness + OFFSET;
    const z = hidden.includes('south') || !hidden.includes('north') ? h.y + out : -(h.y + out);
    const x = hidden.includes('east') || !hidden.includes('west') ? h.x + out : -(h.x + out);
    this.widthLine.position.set(0, 0.01, z);
    this.depthLine.position.set(x, 0.01, 0);
    // The wall at the opposite X end still stands; measure up its cut end.
    const hx = -Math.sign(x) * (h.x + this.room.wallThickness * 0.5);
    const hz = Math.sign(z) * (h.y + 0.1);
    this.heightLine.position.set(hx, this.room.wallHeight * 0.5, hz);
  }

  private line(length: number, text: string, axis: Vector3, across: Vector3): Group {
    const n = new Group();
    const thick = axis.clone().cross(across);
    thick.set(Math.abs(thick.x), Math.abs(thick.y), Math.abs(thick.z));
    this.bar(n, axis.clone().multiplyScalar(length).addScaledVector(across, BAR).addScaledVector(thick, BAR), new Vector3());
    for (const s of [-1, 1]) {
      this.bar(n, axis.clone().multiplyScalar(BAR).addScaledVector(across, TICK).addScaledVector(thick, BAR),
        axis.clone().multiplyScalar(s * length * 0.5));
    }
    const label = labelSprite(text);
    if (axis.y === 0) label.position.y = 0.18;
    n.add(label);
    return n;
  }

  private bar(parent: Group, size: Vector3, at: Vector3): void {
    const m = new Mesh(new BoxGeometry(size.x, size.y, size.z), this.mat);
    m.position.copy(at);
    m.castShadow = false;
    m.receiveShadow = false;
    parent.add(m);
  }
}

/** Screen-sized, always-on-top text: an outlined label on a canvas texture. */
function labelSprite(text: string): Sprite {
  const scale = 2;
  const font = `600 ${48 * scale / 2}px -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif`;
  const c = document.createElement('canvas');
  const g = c.getContext('2d')!;
  g.font = font;
  const w = Math.ceil(g.measureText(text).width) + 24 * scale;
  const h = 40 * scale;
  c.width = w;
  c.height = h;
  g.font = font;
  g.textAlign = 'center';
  g.textBaseline = 'middle';
  g.lineJoin = 'round';
  g.lineWidth = 6 * scale;
  g.strokeStyle = 'rgba(255,255,255,0.9)';
  g.strokeText(text, w / 2, h / 2);
  g.fillStyle = '#' + COLOR.getHexString();
  g.fillText(text, w / 2, h / 2);
  const t = new CanvasTexture(c);
  t.colorSpace = SRGBColorSpace;
  t.minFilter = LinearFilter;
  const s = new Sprite(new SpriteMaterial({ map: t, depthTest: false, depthWrite: false, sizeAttenuation: false }));
  s.scale.set(LABEL_SCREEN_HEIGHT * (w / h), LABEL_SCREEN_HEIGHT, 1);
  s.renderOrder = 10;
  return s;
}
