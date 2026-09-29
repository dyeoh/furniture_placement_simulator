// Places windows and doors: drag one from the catalogue along the walls, drop
// it where it fits. The Placer's counterpart for things in a wall. ← openings.gd

import { Box3, Ray, Vector3 } from 'three';
import type { Catalog } from '../catalog/catalog';
import type { FurnitureItem } from '../catalog/furniture-item';
import { floorHit } from '../placement/placer';
import { boxOf, rayAabb, RoomBuilder, WALLS } from './room-builder';
import { WallOpening, type OpeningDict, type Wall } from './wall-opening';

/** Clearance from a corner and between two openings on one wall. */
const GAP = 0.1;
/** A window's head stays this far under the ceiling. */
const HEAD_ROOM = 0.05;

export class Openings {
  room!: RoomBuilder;
  catalog!: Catalog;
  dragging: WallOpening | null = null;
  onChanged: (() => void) | null = null;
  private liftedFrom: { wall: Wall; offset: number } | null = null;

  setup(room: RoomBuilder, catalog: Catalog): void {
    this.room = room;
    this.catalog = catalog;
    for (const op of room.openings) op.offset = this.clampOffset(op, op.wall, op.offset);
    for (const op of room.openings) {
      op.valid = this.validate(op);
      this.build(op);
    }
  }

  /** Start dragging a new opening on the first wall the camera can see. */
  begin(item: FurnitureItem): WallOpening {
    if (this.dragging) this.cancel();
    const op = new WallOpening(item);
    op.ghost = true;
    op.wall = WALLS.find((w) => !this.room.hiddenWalls.includes(w)) ?? 'north';
    op.offset = this.clampOffset(op, op.wall, 0);
    this.room.openings.push(op);
    this.dragging = op;
    this.liftedFrom = null;
    this.refresh(op, null);
    return op;
  }

  /** Put an opening straight onto a wall, for scripts and tests. */
  place(item: FurnitureItem, wall: Wall, offset: number): WallOpening {
    const op = new WallOpening(item);
    op.wall = wall;
    op.offset = this.clampOffset(op, wall, offset);
    this.room.openings.push(op);
    this.refresh(op, null);
    this.onChanged?.();
    return op;
  }

  lift(op: WallOpening): void {
    if (this.dragging) this.cancel();
    this.liftedFrom = { wall: op.wall, offset: op.offset };
    op.ghost = true;
    this.dragging = op;
    op.setTint(true, op.valid);
  }

  /** Move the dragged opening to where a ray meets a visible wall, or the nearest one over the floor. */
  dragRay(ray: Ray): void {
    if (!this.dragging) return;
    const hit = this.wallHit(ray);
    if (!hit) return;
    const old = this.dragging.wall;
    this.dragging.wall = hit.wall;
    this.dragging.offset = this.clampOffset(this.dragging, hit.wall, hit.offset);
    this.refresh(this.dragging, old);
  }

  drop(): boolean {
    const op = this.dragging;
    if (!op || !op.valid) return false;
    op.ghost = false;
    op.setTint(false, true);
    this.dragging = null;
    this.liftedFrom = null;
    this.onChanged?.();
    return true;
  }

  cancel(): void {
    const op = this.dragging;
    if (!op) return;
    this.dragging = null;
    if (!this.liftedFrom) { this.removeOp(op); return; }
    const old = op.wall;
    op.wall = this.liftedFrom.wall;
    op.offset = this.liftedFrom.offset;
    op.ghost = false;
    this.liftedFrom = null;
    this.refresh(op, old);
    op.setTint(!op.valid, op.valid);
  }

  remove(op: WallOpening): void {
    if (op === this.dragging) { this.dragging = null; this.liftedFrom = null; }
    this.removeOp(op);
    this.onChanged?.();
  }

  private removeOp(op: WallOpening): void {
    this.room.openings = this.room.openings.filter((o) => o !== op);
    op.freeVisual();
    this.room.rebuildWall(op.wall);
  }

  clear(): void {
    this.dragging = null;
    this.liftedFrom = null;
    const walls = new Set<Wall>();
    for (const op of this.room.openings) { walls.add(op.wall); op.freeVisual(); }
    this.room.openings = [];
    for (const w of walls) this.room.rebuildWall(w);
  }

  private refresh(op: WallOpening, oldWall: Wall | null): void {
    for (const o of this.room.openings) o.valid = this.validate(o);
    if (oldWall && oldWall !== op.wall) this.room.rebuildWall(oldWall);
    this.room.rebuildWall(op.wall);
    this.build(op);
    for (const o of this.room.openings) {
      if (o !== op && (o.wall === op.wall || o.wall === oldWall)) o.setTint(!o.valid, o.valid);
    }
  }

  private build(op: WallOpening): void {
    const parent = this.room.openingsNode(op.wall);
    if (!parent) return;
    if (!op.node) op.buildVisual(parent, this.room.wallThickness);
    else if (op.node.parent !== parent) parent.add(op.node);
    op.node!.position.copy(this.room.openingLocalPosition(op));
    op.setCut(this.room.isCut(op.wall));
  }

  // --- validation

  clampOffset(op: WallOpening, wall: Wall, offset: number): number {
    const lim = this.room.runHalf(wall) - op.width() * 0.5 - GAP;
    if (lim < 0) return 0;
    return Math.min(Math.max(offset, -lim), lim);
  }

  validate(op: WallOpening): boolean {
    const half = this.room.runHalf(op.wall);
    const s = op.span();
    if (s.x < -half + GAP - 1e-4 || s.y > half - GAP + 1e-4) return false;
    if (op.head() > this.room.wallHeight - HEAD_ROOM + 1e-4) return false;
    for (const o of this.room.openings) {
      if (o === op || o.wall !== op.wall) continue;
      const t = o.span();
      if (s.x < t.y + GAP - 1e-4 && t.x < s.y + GAP - 1e-4) return false;
    }
    return true;
  }

  // --- picking

  wallHit(ray: Ray): { wall: Wall; offset: number } | null {
    let best: Wall | null = null;
    let bestT = Infinity;
    for (const w of WALLS) {
      if (this.room.hiddenWalls.includes(w)) continue;
      const t = rayAabb(ray, boxOf(this.room.wallBox(w)));
      if (t >= 0 && t < bestT) { bestT = t; best = w; }
    }
    if (best) {
      const p = ray.at(bestT, new Vector3());
      return { wall: best, offset: RoomBuilder.runAxis(best) === 0 ? p.x : p.z };
    }
    const f = floorHit(ray);
    if (!f) return null;
    const h = this.room.halfExtents();
    const dist: Record<Wall, number> = { north: f.z + h.y, south: h.y - f.z, east: h.x - f.x, west: f.x + h.x };
    let bestD = Infinity;
    for (const w of WALLS) {
      if (this.room.hiddenWalls.includes(w)) continue;
      if (dist[w] < bestD) { bestD = dist[w]; best = w; }
    }
    if (!best) return null;
    return { wall: best, offset: RoomBuilder.runAxis(best) === 0 ? f.x : f.z };
  }

  pick(ray: Ray): [WallOpening | null, number] {
    let best: WallOpening | null = null;
    let bestT = Infinity;
    for (const op of this.room.openings) {
      if (this.room.hiddenWalls.includes(op.wall) || op === this.dragging) continue;
      const t = rayAabb(ray, this.worldAabb(op));
      if (t >= 0 && t < bestT) { bestT = t; best = op; }
    }
    return [best, bestT];
  }

  /** The opening's box in world space, a little proud of both wall faces. */
  worldAabb(op: WallOpening): Box3 {
    const c = this.room.wallBox(op.wall).centre.clone();
    const axis = RoomBuilder.runAxis(op.wall);
    const size = new Vector3();
    size.setComponent(axis, op.width());
    size.setComponent(2 - axis, this.room.wallThickness + 0.1);
    size.y = op.height();
    c.setComponent(axis, op.offset);
    c.y = op.sill() + op.height() * 0.5;
    return new Box3().setFromCenterAndSize(c, size);
  }

  // --- serialisation

  toArray(): OpeningDict[] {
    const out: OpeningDict[] = [];
    for (const op of this.room.openings) {
      if (op !== this.dragging) out.push(op.toDict());
      else if (this.liftedFrom) {
        out.push({ id: op.item.id, wall: this.liftedFrom.wall, offset: Math.round(this.liftedFrom.offset * 1000) / 1000 });
      }
    }
    return out;
  }

  restore(data: unknown[]): void {
    this.clear();
    for (const d of data) {
      if (!d || typeof d !== 'object') continue;
      const rec = d as Partial<OpeningDict>;
      const item = this.catalog.find(String(rec.id ?? ''));
      const wall = String(rec.wall ?? '') as Wall;
      if (!item || !item.isOpening() || !WALLS.includes(wall)) {
        console.warn(`Layout: opening '${rec.id}' on '${wall}' skipped`);
        continue;
      }
      const op = new WallOpening(item);
      op.wall = wall;
      op.offset = this.clampOffset(op, wall, Number(rec.offset ?? 0));
      this.room.openings.push(op);
    }
    const walls = new Set<Wall>();
    for (const op of this.room.openings) { op.valid = this.validate(op); walls.add(op.wall); }
    for (const w of walls) this.room.rebuildWall(w);
    for (const op of this.room.openings) this.build(op);
  }
}
