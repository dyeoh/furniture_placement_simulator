// Drag, snap, validate and commit furniture. ← placer.gd
//
// Backend-agnostic: bodies go through the seam, picking is ray-vs-AABB over
// the (small) placed list, validation is box arithmetic. The solver's only
// job is the settle after a drop -- an item is PLACED once its body sleeps.

import { Box3, Object3D, Ray, Vector2, Vector3 } from 'three';
import type { Catalog } from '../catalog/catalog';
import type { FurnitureItem } from '../catalog/furniture-item';
import { ALL, FURNITURE } from '../layers';
import { BODY_DYNAMIC, type PhysicsBackend } from '../physics/backend';
import { rayAabb, type RoomBuilder } from '../room/room-builder';
import { PlacedItem, State } from './placed-item';

export enum Snap { FREE, GRID, WALL }
export const SNAP_NAMES = ['Free', 'Grid 25 cm', 'Wall magnet'];

const GRID = 0.25;
/** How close (item edge to wall) before wall-magnet grabs. */
const WALL_PULL = 0.4;
/** A body is not trusted to be asleep before this many seconds. */
const SETTLE_GRACE = 0.25;
/** Give up waiting for sleep: something wedged may jitter forever. */
const SETTLE_TIMEOUT = 4;
/** Closer than this to a wall and a piece shades it. */
const WALL_CONTACT = 0.05;

const snapped = (v: number, step: number) => Math.round(v / step) * step;
const posmod = (a: number, n: number) => ((a % n) + n) % n;

/** Where a pointer ray meets the floor plane, or null. */
export function floorHit(ray: Ray): Vector3 | null {
  const d = ray.direction;
  if (Math.abs(d.y) < 1e-6) return null;
  const t = -ray.origin.y / d.y;
  if (t < 0) return null;
  return ray.at(t, new Vector3());
}

export class Placer {
  backend!: PhysicsBackend;
  room!: RoomBuilder;
  catalog!: Catalog;
  visualRoot!: Object3D;
  snapMode = Snap.GRID;
  items: PlacedItem[] = [];
  dragging: PlacedItem | null = null;
  onChanged: (() => void) | null = null;

  setup(backend: PhysicsBackend, room: RoomBuilder, catalog: Catalog, visualRoot: Object3D): void {
    this.backend = backend;
    this.room = room;
    this.catalog = catalog;
    this.visualRoot = visualRoot;
  }

  private changed(): void { this.onChanged?.(); }

  cycleSnap(): void { this.snapMode = (this.snapMode + 1) % 3; }
  snapName(): string { return SNAP_NAMES[this.snapMode]; }

  // --- lifecycle

  begin(item: FurnitureItem, at = new Vector3()): PlacedItem {
    if (this.dragging) this.cancel();
    const p = new PlacedItem(item);
    p.finish = item.finish;
    p.position.copy(at);
    p.buildVisual(this.visualRoot, this.colorFor(p));
    this.items.push(p);
    this.dragging = p;
    this.dragTo(at);
    return p;
  }

  /** Pick a placed item back up: its body goes, it is a ghost again. */
  lift(p: PlacedItem): void {
    if (p.state === State.CARRIED) return;
    if (this.dragging && this.dragging !== p) this.cancel();
    this.releaseBody(p);
    p.state = State.GHOST;
    this.dragging = p;
    this.dragTo(p.position);
  }

  /** Follow the pointer; [floorPoint] is where the cursor ray meets y = 0. */
  dragTo(floorPoint: Vector3): void {
    const d = this.dragging;
    if (!d) return;
    let p = floorPoint.clone().setY(0);
    if (this.snapMode === Snap.GRID) { p.x = snapped(p.x, GRID); p.z = snapped(p.z, GRID); }
    else if (this.snapMode === Snap.WALL) p = this.wallMagnet(d, p);
    d.position.copy(this.clampToRoom(d, p));
    d.valid = this.validate(d);
    d.syncVisual(false);
    d.setTint(true, d.valid);
  }

  rotate(steps = 1): void {
    if (!this.dragging) return;
    this.dragging.yaw = posmod(this.dragging.yaw + steps, 4);
    this.dragTo(this.dragging.position);
  }

  /** Commit the dragged item; refused when the spot is invalid. */
  drop(): boolean {
    if (!this.dragging || !this.validate(this.dragging)) return false;
    this.commit(this.dragging);
    this.dragging = null;
    this.changed();
    return true;
  }

  cancel(): void {
    if (!this.dragging) return;
    this.remove(this.dragging);
    this.dragging = null;
  }

  remove(p: PlacedItem): void {
    if (p === this.dragging) this.dragging = null;
    this.releaseBody(p);
    p.freeVisual();
    this.items = this.items.filter((o) => o !== p);
    this.changed();
  }

  clear(): void {
    this.dragging = null;
    for (const p of [...this.items]) this.remove(p);
  }

  /** Walkthrough carry: the body goes and the item follows the shopper as a ghost. */
  carry(p: PlacedItem): boolean {
    if (p.state === State.GHOST || p.state === State.CARRIED) return false;
    this.releaseBody(p);
    p.state = State.CARRIED;
    p.setTint(false, true);
    return true;
  }

  /** Would [p], held at [lift] above [pos], pass through another piece? */
  blockedAt(p: PlacedItem, pos: Vector3, lift: number): boolean {
    const rs = p.rotatedSize();
    const box = new Box3(new Vector3(pos.x - rs.x * 0.5, lift, pos.z - rs.z * 0.5),
      new Vector3(pos.x + rs.x * 0.5, lift + rs.y, pos.z + rs.z * 0.5)).expandByScalar(-0.01);
    for (const o of this.items) {
      if (o === p || o.state === State.GHOST || o.state === State.CARRIED) continue;
      if (box.intersectsBox(o.aabb())) return true;
    }
    return false;
  }

  carryTo(p: PlacedItem, floorPoint: Vector3, yaw: number, height: number): void {
    p.position.set(floorPoint.x, 0, floorPoint.z);
    p.yaw = posmod(yaw, 4);
    p.liftY = height;
    p.syncVisual(false);
  }

  /** Let go: the body is created where the item is held and falls from there. */
  dropCarried(p: PlacedItem): void {
    if (p.state !== State.CARRIED) return;
    p.position.copy(this.clampToRoom(p, p.position));
    this.commit(p);
    this.changed();
  }

  /** One cart line per distinct variant: oak and blackwood shelves are two lines. */
  cartLines(): { variant_id: number; quantity: number }[] {
    const counts = new Map<number, number>();
    for (const p of this.items) {
      if (p.state === State.GHOST) continue;
      const vid = p.item.variantFor(p.finish);
      if (vid === 0) continue;
      counts.set(vid, (counts.get(vid) ?? 0) + 1);
    }
    return [...counts].map(([variant_id, quantity]) => ({ variant_id, quantity }));
  }

  setFinish(p: PlacedItem, key: string): void {
    p.finish = key;
    p.setColor(this.colorFor(p));
    this.changed();
  }

  private colorFor(p: PlacedItem) {
    if (p.finish && this.catalog.finishes[p.finish]) return this.catalog.finishColor(p.finish);
    return p.item.color;
  }

  commit(p: PlacedItem): void {
    // A hair above the floor: a body created touching the ground can start
    // life penetrating it by a solver epsilon and pop upward.
    const xf = p.intendedTransform();
    xf.p.y += 0.02;
    p.liftY = 0;
    p.body = this.backend.bodyCreate(p.item.bodyShape(), xf, BODY_DYNAMIC, FURNITURE, ALL);
    p.xf.p.copy(xf.p);
    p.xf.q.copy(xf.q);
    p.state = State.SETTLING;
    p.settleTime = 0;
    p.setTint(false, true);
    p.syncVisual(true);
  }

  private releaseBody(p: PlacedItem): void {
    if (p.body < 0) return;
    // Where the solver left it is the new intended placement.
    const xf = this.backend.bodyGetTransform(p.body, p.xf);
    p.position.set(xf.p.x, 0, xf.p.z);
    p.yaw = nearestQuarter(xf.q);
    this.backend.bodyDestroy(p.body);
    p.body = -1;
  }

  // --- per frame

  /** Pull every body's transform once, after the physics step. */
  syncBodies(): void {
    for (const p of this.items) if (p.body >= 0) this.backend.bodyGetTransform(p.body, p.xf);
  }

  update(dt: number): void {
    for (const p of this.items) {
      this.updateWallContact(p);
      if (p.state === State.SETTLING) {
        p.settleTime += dt;
        p.syncVisual(true);
        if (p.settleTime >= SETTLE_GRACE && (this.backend.bodyIsSleeping(p.body) || p.settleTime > SETTLE_TIMEOUT)) {
          p.state = State.PLACED;
          p.position.set(p.xf.p.x, 0, p.xf.p.z);
          p.valid = this.validate(p);
          this.changed();
        }
      } else if (p.state === State.PLACED || p.state === State.CARRIED) {
        p.syncVisual(true);
      }
    }
  }

  private updateWallContact(p: PlacedItem): void {
    if (p.state === State.GHOST || p.state === State.CARRIED) {
      p.setWallContact(new Vector3(), new Vector3(), new Vector2());
      return;
    }
    const box = p.aabb();
    const h = this.room.halfExtents();
    const c = box.getCenter(new Vector3());
    const s = box.getSize(new Vector3());
    const gaps: [number, Vector3, Vector3, Vector2][] = [
      [box.min.z + h.y, new Vector3(0, 0, 1), new Vector3(c.x, c.y, -h.y), new Vector2(s.x, s.y)],
      [h.y - box.max.z, new Vector3(0, 0, -1), new Vector3(c.x, c.y, h.y), new Vector2(s.x, s.y)],
      [box.min.x + h.x, new Vector3(1, 0, 0), new Vector3(-h.x, c.y, c.z), new Vector2(s.z, s.y)],
      [h.x - box.max.x, new Vector3(-1, 0, 0), new Vector3(h.x, c.y, c.z), new Vector2(s.z, s.y)],
    ];
    let best: (typeof gaps)[number] | null = null;
    for (const g of gaps) if (g[0] < WALL_CONTACT && (!best || g[0] < best[0])) best = g;
    if (!best) p.setWallContact(new Vector3(), new Vector3(), new Vector2());
    else p.setWallContact(best[1], best[2], best[3]);
  }

  anySettling(): boolean {
    return this.items.some((p) => p.state === State.SETTLING);
  }

  // --- validation and snapping

  validate(p: PlacedItem): boolean {
    const box = p.aabb();
    if (!this.room.containsAabb(box)) return false;
    // Shrink a touch so two items snapped flush do not overlap through a shared face.
    const mine = box.clone().expandByScalar(-0.005);
    for (const o of this.items) {
      if (o === p || o.state === State.CARRIED) continue;
      if (mine.intersectsBox(o.aabb())) return false;
    }
    return true;
  }

  clampToRoom(p: PlacedItem, pos: Vector3): Vector3 {
    const h = this.room.halfExtents();
    const rs = p.rotatedSize();
    const out = pos.clone();
    out.x = Math.min(Math.max(out.x, -h.x + rs.x * 0.5), h.x - rs.x * 0.5);
    out.z = Math.min(Math.max(out.z, -h.y + rs.z * 0.5), h.y - rs.z * 0.5);
    return out;
  }

  /** Within WALL_PULL of a wall, pull flush and turn the item's back (local -Z) to it. */
  private wallMagnet(p: PlacedItem, pos: Vector3): Vector3 {
    const grid = () => { pos.x = snapped(pos.x, GRID); pos.z = snapped(pos.z, GRID); return pos; };
    if (!p.item.wallSnap) return grid();
    const h = this.room.halfExtents();
    const d = p.item.size.z * 0.5;
    const dNorth = (pos.z + h.y) - d;
    const dSouth = (h.y - pos.z) - d;
    const dEast = (h.x - pos.x) - d;
    const dWest = (pos.x + h.x) - d;
    const best = Math.min(dNorth, dSouth, dEast, dWest);
    if (best > WALL_PULL) return grid();
    if (best === dNorth) { p.yaw = 0; pos.z = -h.y + d; pos.x = snapped(pos.x, GRID); }
    else if (best === dSouth) { p.yaw = 2; pos.z = h.y - d; pos.x = snapped(pos.x, GRID); }
    else if (best === dEast) { p.yaw = 3; pos.x = h.x - d; pos.z = snapped(pos.z, GRID); }
    else { p.yaw = 1; pos.x = -h.x + d; pos.z = snapped(pos.z, GRID); }
    return pos;
  }

  // --- picking

  pick(ray: Ray): PlacedItem | null {
    let best: PlacedItem | null = null;
    let bestT = Infinity;
    for (const p of this.items) {
      const t = rayAabb(ray, p.aabb());
      if (t >= 0 && t < bestT) { bestT = t; best = p; }
    }
    return best;
  }

  /** Nearest item to a point within [radius], for the walkthrough's grab. */
  nearest(point: Vector3, radius: number): PlacedItem | null {
    let best: PlacedItem | null = null;
    let bestD = radius * radius;
    const c = new Vector3();
    for (const p of this.items) {
      if (p.state === State.GHOST) continue;
      const d = p.aabb().getCenter(c).distanceToSquared(point);
      if (d < bestD) { bestD = d; best = p; }
    }
    return best;
  }
}

/** Quarter turn nearest a rotation's facing (+Z = 0). */
export function nearestQuarter(q: import('three').Quaternion): number {
  const fwd = new Vector3(0, 0, 1).applyQuaternion(q);
  const a = Math.atan2(fwd.x, fwd.z);
  return posmod(Math.round(a / (Math.PI * 0.5)), 4);
}
