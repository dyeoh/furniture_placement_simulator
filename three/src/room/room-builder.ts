// One rectangular room: a floor slab, four walls and an optional ceiling. ← room_builder.gd
//
// Bodies go through the PhysicsBackend seam only. Every box is recorded in
// [boxes]; the floor's top is y = 0 and the interior is centred on the origin,
// so "is this inside the room" is a plain half-extent compare.
//
// A wall's body stays one solid box; its visual is rebuilt from segments
// around each window so the sun comes in through it.

import {
  Box3, BoxGeometry, Group, Matrix4, Mesh, MeshStandardMaterial, Object3D, Quaternion, Ray,
  Vector2, Vector3, Vector4,
} from 'three';
import { srgb } from '../color';
import { ALL, ROOM } from '../layers';
import { setShadowOnly } from './shadow-only';
import { BODY_STATIC, type PhysicsBackend } from '../physics/backend';
import { floorAo, wallAo } from './occlusion';
import * as SurfaceMaterials from './surface-materials';
import { disposeTree, type Wall, type WallOpening } from './wall-opening';

export type Surface = 'floor' | Wall;
export const SURFACES: Surface[] = ['floor', 'north', 'east', 'south', 'west'];
export const WALLS: Wall[] = ['north', 'east', 'south', 'west'];
const VISUAL_FLOOR_THICKNESS = 0.08;
const SKIRTING_HEIGHT = 0.12;
const SKIRTING_DEPTH = 0.015;
const CEILING_THICKNESS = 0.12;
export const MIN_HEIGHT = 2.2;
export const MAX_HEIGHT = 4.0;
const CAP_COLOR = srgb(0.24, 0.24, 0.26);

export interface RoomBox { surface: Surface; centre: Vector3; size: Vector3; inward: Vector3 }

interface WallNode { root: Group; body: Group; trim: Group; openings: Group; cap: Mesh | null; crown: Group | null }

export class RoomBuilder {
  width = 6;
  depth = 5;
  wallHeight = 2.7;
  wallThickness = 0.15;
  /** Thick so a mover a few cm inside the floor is pushed up, not out of the underside. */
  floorThickness = 1;
  hasCeiling = false;
  openings: WallOpening[] = [];

  boxes: RoomBox[] = [];
  bodyIds: number[] = [];

  floorMesh: Mesh | null = null;
  walls = new Map<Wall, WallNode>();
  materials = new Map<Surface, MeshStandardMaterial>();
  ceiling: Mesh | null = null;
  /** Walls the cutaway is hiding -- the ones between camera and room. */
  hiddenWalls: Wall[] = [];

  defaultWallColor = srgb(0.93, 0.91, 0.86);
  /** The laminate's own colour, so the untouched floor is the photograph. */
  defaultFloorColor = srgb(0.61, 0.5, 0.39);
  skirtingColor = srgb(0.96, 0.95, 0.93);
  private paintColors = new Map<Surface, import('three').Color>();
  private skirtingMat: MeshStandardMaterial | null = null;
  private capMat: MeshStandardMaterial | null = null;
  private cutState = new Map<Wall, boolean>();
  private ceilingMode = -1;
  private capsOn = -1;

  halfExtents(): Vector2 {
    return new Vector2(this.width * 0.5, this.depth * 0.5);
  }

  containsAabb(b: Box3): boolean {
    // Epsilon: an item clamped flush to a wall lands a float ulp past the
    // bound, and a settled body rests a solver's allowed penetration into it
    // (Rapier leaves ~0.2 mm). Godot uses 0.1 mm; 1 mm keeps both engines honest.
    const EPS = 1e-3;
    const h = this.halfExtents();
    return b.min.x >= -h.x - EPS && b.max.x <= h.x + EPS
      && b.min.z >= -h.y - EPS && b.max.z <= h.y + EPS
      && b.min.y >= -0.001 && b.max.y <= this.wallHeight + EPS;
  }

  build(backend: PhysicsBackend): void {
    this.boxes = [];
    this.bodyIds = [];
    const h = this.halfExtents();
    const wt = this.wallThickness;
    const wh = this.wallHeight;
    const wy = wh * 0.5;
    this.box(backend, 'floor', new Vector3(0, -this.floorThickness * 0.5, 0),
      new Vector3(this.width + wt * 2, this.floorThickness, this.depth + wt * 2), new Vector3(0, 1, 0));
    // "north" is -Z, away from the default camera. North and south span the corners.
    this.box(backend, 'north', new Vector3(0, wy, -h.y - wt * 0.5), new Vector3(this.width + wt * 2, wh, wt), new Vector3(0, 0, 1));
    this.box(backend, 'south', new Vector3(0, wy, h.y + wt * 0.5), new Vector3(this.width + wt * 2, wh, wt), new Vector3(0, 0, -1));
    this.box(backend, 'east', new Vector3(h.x + wt * 0.5, wy, 0), new Vector3(wt, wh, this.depth), new Vector3(-1, 0, 0));
    this.box(backend, 'west', new Vector3(-h.x - wt * 0.5, wy, 0), new Vector3(wt, wh, this.depth), new Vector3(1, 0, 0));
  }

  private box(backend: PhysicsBackend, surface: Surface, centre: Vector3, size: Vector3, inward: Vector3): void {
    this.boxes.push({ surface, centre, size, inward });
    this.bodyIds.push(backend.bodyCreate({ size, friction: 0.9 },
      { p: centre.clone(), q: new Quaternion() }, BODY_STATIC, ROOM, ALL));
  }

  wallBox(surface: Surface): RoomBox {
    return this.boxes.find((b) => b.surface === surface)!;
  }

  // --- wall geometry

  /** World axis a wall runs along: 0 (X) for north/south, 2 (Z) for east/west. */
  static runAxis(surface: Surface): 0 | 2 {
    return surface === 'north' || surface === 'south' ? 0 : 2;
  }

  /** Interior half-length of a wall's run. */
  runHalf(surface: Surface): number {
    const h = this.halfExtents();
    return RoomBuilder.runAxis(surface) === 0 ? h.x : h.y;
  }

  /** Wall frame: origin on the wall's centre, local X along the run, local +Z into the room. */
  wallMatrix(surface: Surface): Matrix4 {
    const b = this.wallBox(surface);
    const q = new Quaternion().setFromAxisAngle(new Vector3(0, 1, 0), Math.atan2(b.inward.x, b.inward.z));
    return new Matrix4().compose(b.centre, q, new Vector3(1, 1, 1));
  }

  /** Along-wall world coordinate to the wall's local X. */
  private localX(surface: Surface, offset: number): number {
    const basisX = new Vector3().setFromMatrixColumn(this.wallMatrix(surface), 0);
    return offset * (RoomBuilder.runAxis(surface) === 0 ? basisX.x : basisX.z);
  }

  openingLocalPosition(op: WallOpening): Vector3 {
    return new Vector3(this.localX(op.wall, op.offset), op.sill() + op.height() * 0.5 - this.wallHeight * 0.5, 0);
  }

  // --- visuals

  buildVisuals(parent: Object3D): void {
    this.walls.clear();
    this.materials.clear();
    this.paintColors.clear();
    this.cutState.clear();
    this.ceilingMode = -1;
    this.capsOn = -1;
    this.hiddenWalls = [];
    this.skirtingMat = new MeshStandardMaterial({ color: this.skirtingColor, roughness: 0.45 });
    this.capMat = new MeshStandardMaterial({ color: CAP_COLOR, roughness: 1 });
    for (const b of this.boxes) {
      if (b.surface === 'floor') {
        // The slab is a metre thick for the mover; draw a thin top instead.
        const full = new Vector2(b.size.x, b.size.z);
        const geo = new BoxGeometry(full.x, VISUAL_FLOOR_THICKNESS, full.y);
        const at = new Vector3(b.centre.x, -VISUAL_FLOOR_THICKNESS * 0.5, b.centre.z);
        const m = new Matrix4().makeTranslation(at.x, at.y, at.z);
        SurfaceMaterials.boxUVs(geo, m, SurfaceMaterials.SETS.laminate_floor_02.size);
        SurfaceMaterials.uv1From(geo, m, (p) => [p.x / full.x + 0.5, p.z / full.y + 0.5]);
        const mat = SurfaceMaterials.floor(this.defaultFloorColor);
        SurfaceMaterials.setAo(mat, floorAo(full, this.halfExtents()));
        const mesh = new Mesh(geo, mat);
        mesh.position.copy(at);
        mesh.receiveShadow = true;
        mesh.castShadow = true;
        mesh.name = 'Room_floor';
        parent.add(mesh);
        this.floorMesh = mesh;
        this.materials.set('floor', mat);
        continue;
      }
      const wall = b.surface as Wall;
      const root = new Group();
      root.name = 'Room_' + wall;
      root.matrixAutoUpdate = true;
      this.wallMatrix(wall).decompose(root.position, root.quaternion, root.scale);
      const node: WallNode = { root, body: new Group(), trim: new Group(), openings: new Group(), cap: null, crown: null };
      root.add(node.body, node.trim, node.openings);
      parent.add(root);
      this.walls.set(wall, node);
      this.materials.set(wall, SurfaceMaterials.plaster(this.defaultWallColor));
      this.rebuildWall(wall);
    }
    this.buildCeiling(parent);
  }

  /** Plaster segments and trim for one wall, around its openings. */
  rebuildWall(surface: Wall): void {
    const node = this.walls.get(surface);
    if (!node) return;
    for (const g of [node.body, node.trim]) {
      for (const c of [...g.children]) { g.remove(c); disposeTree(c); }
    }
    const size = this.wallBox(surface).size;
    const run = RoomBuilder.runAxis(surface) === 0 ? size.x : size.z;
    const t = this.wallThickness;
    const wh = this.wallHeight;
    const mat = this.materials.get(surface)!;

    const holes: Vector4[] = [];
    const gaps: Vector2[] = [];
    for (const op of this.openings) {
      if (op.wall !== surface) continue;
      const lx = this.localX(surface, op.offset);
      const x0 = lx - op.width() * 0.5;
      const x1 = lx + op.width() * 0.5;
      if (op.cutsWall()) holes.push(new Vector4(x0, x1, op.sill(), op.head()));
      if (op.sill() < SKIRTING_HEIGHT + 0.01) gaps.push(new Vector2(x0, x1));
    }

    const inner = this.runHalf(surface);
    this.setWallAo(surface);
    const wallM = this.wallMatrix(surface);
    for (const seg of RoomBuilder.wallSegments(run, wh, holes)) {
      const at = new Vector3((seg.x + seg.z) * 0.5, (seg.y + seg.w) * 0.5 - wh * 0.5, 0);
      const geo = new BoxGeometry(seg.z - seg.x, seg.w - seg.y, t);
      const local = new Matrix4().makeTranslation(at.x, at.y, at.z);
      // World-anchored grain so the plaster runs on across a window.
      SurfaceMaterials.boxUVs(geo, wallM.clone().multiply(local), SurfaceMaterials.SETS.plaster_grey_04.size);
      // uv1 is the point's place on the whole wall: one continuous AO map.
      SurfaceMaterials.uv1From(geo, local, (p) => [p.x / run + 0.5, 0.5 - p.y / wh]);
      const mesh = new Mesh(geo, mat);
      mesh.position.copy(at);
      mesh.castShadow = true;
      mesh.receiveShadow = true;
      node.body.add(mesh);
    }

    const face = t * 0.5;
    for (const span of RoomBuilder.subtractSpans(new Vector2(-run * 0.5, run * 0.5), gaps)) {
      this.trimBox(node.trim, new Vector3(span.y - span.x, SKIRTING_HEIGHT, SKIRTING_DEPTH),
        new Vector3((span.x + span.y) * 0.5, SKIRTING_HEIGHT * 0.5 - wh * 0.5, face + SKIRTING_DEPTH * 0.5), this.skirtingMat!);
    }
    node.cap = this.trimBox(node.trim, new Vector3(run, 0.012, t), new Vector3(0, wh * 0.5 + 0.006, 0), this.capMat!);
    node.cap.visible = this.capsOn === 1;
    node.crown = new Group();
    node.crown.visible = this.hasCeiling;
    node.trim.add(node.crown);
    this.trimBox(node.crown, new Vector3(inner * 2, 0.09, 0.018), new Vector3(0, wh * 0.5 - 0.045, face + 0.009), this.skirtingMat!);
    this.trimBox(node.crown, new Vector3(inner * 2, 0.035, 0.04), new Vector3(0, wh * 0.5 - 0.0175, face + 0.02), this.skirtingMat!);

    if (this.cutState.has(surface)) this.applyCut(surface, this.cutState.get(surface)!);
  }

  /**
   * Rectangles (x0, y0, x1, y1 in local X and height above the floor)
   * covering a wall minus its holes. Columns are cut at every hole edge;
   * overlapping holes merge.
   */
  static wallSegments(run: number, height: number, holes: Vector4[]): Vector4[] {
    const clampX = (x: number) => Math.min(Math.max(x, -run * 0.5), run * 0.5);
    const xs = [-run * 0.5, run * 0.5];
    for (const h of holes) xs.push(clampX(h.x), clampX(h.y));
    xs.sort((a, b) => a - b);
    const out: Vector4[] = [];
    for (let i = 0; i < xs.length - 1; i++) {
      const a = xs[i], b = xs[i + 1];
      if (b - a < 1e-4) continue;
      const mid = (a + b) * 0.5;
      const cover: Vector2[] = [];
      for (const h of holes) {
        if (mid > h.x && mid < h.y) {
          cover.push(new Vector2(Math.min(Math.max(h.z, 0), height), Math.min(Math.max(h.w, 0), height)));
        }
      }
      for (const span of RoomBuilder.subtractSpans(new Vector2(0, height), cover)) {
        out.push(new Vector4(a, span.x, b, span.y));
      }
    }
    return out;
  }

  /** [whole] minus the union of [cuts], as sorted spans. */
  static subtractSpans(whole: Vector2, cuts: Vector2[]): Vector2[] {
    const sorted = [...cuts].sort((p, q) => p.x - q.x);
    const out: Vector2[] = [];
    let at = whole.x;
    for (const c of sorted) {
      if (c.x > at + 1e-4) out.push(new Vector2(at, Math.min(c.x, whole.y)));
      at = Math.max(at, c.y);
      if (at >= whole.y) break;
    }
    if (whole.y - at > 1e-4) out.push(new Vector2(at, whole.y));
    return out;
  }

  private setWallAo(surface: Wall): void {
    const size = this.wallBox(surface).size;
    const run = RoomBuilder.runAxis(surface) === 0 ? size.x : size.z;
    SurfaceMaterials.setAo(this.materials.get(surface)!, wallAo(run, this.wallHeight, this.runHalf(surface), this.hasCeiling));
  }

  private trimBox(parent: Object3D, size: Vector3, at: Vector3, mat: MeshStandardMaterial): Mesh {
    const mesh = new Mesh(new BoxGeometry(size.x, size.y, size.z), mat);
    mesh.position.copy(at);
    mesh.castShadow = false;
    mesh.receiveShadow = true;
    parent.add(mesh);
    return mesh;
  }

  private buildCeiling(parent: Object3D): void {
    // Past the outside of the walls, so no sun slips in along a wall top.
    const over = this.wallThickness * 2 + 0.2;
    const geo = new BoxGeometry(this.width + over, CEILING_THICKNESS, this.depth + over);
    SurfaceMaterials.boxUVs(geo, new Matrix4(), SurfaceMaterials.SETS.plaster_grey_04.size);
    this.ceiling = new Mesh(geo, SurfaceMaterials.plaster(srgb(0.97, 0.96, 0.94)));
    this.ceiling.position.set(0, this.wallHeight + CEILING_THICKNESS * 0.5, 0);
    this.ceiling.name = 'Room_ceiling';
    this.ceiling.visible = false;
    this.ceiling.receiveShadow = true;
    parent.add(this.ceiling);
  }

  setCeiling(on: boolean): void {
    this.hasCeiling = on;
    this.ceilingMode = -1;
    for (const w of WALLS) {
      const node = this.walls.get(w);
      if (!node) continue;
      if (node.crown) node.crown.visible = on;
      this.setWallAo(w);
    }
  }

  paint(surface: Surface, color: import('three').Color): void {
    const m = this.materials.get(surface);
    if (!m) return;
    this.paintColors.set(surface, color.clone());
    SurfaceMaterials.tint(m, surface === 'floor' ? 'laminate_floor_02' : 'plaster_grey_04', color);
  }

  paintColor(surface: Surface): import('three').Color {
    return this.paintColors.get(surface) ?? (surface === 'floor' ? this.defaultFloorColor : this.defaultWallColor);
  }

  /**
   * Sims-style cutaway: hide the walls between the camera and the room. A cut
   * wall still casts its shadow, and in the planner view the ceiling is
   * shadow-only: lit as the covered room it is, while the view stays open.
   */
  updateCutaway(cameraForward: Vector3, enabled: boolean): void {
    this.hiddenWalls = [];
    for (const b of this.boxes) {
      if (b.surface === 'floor' || !this.walls.has(b.surface)) continue;
      const wall = b.surface as Wall;
      const cut = enabled && b.inward.dot(cameraForward) >= 0.05;
      if (cut) this.hiddenWalls.push(wall);
      if (this.cutState.get(wall) !== cut) {
        this.cutState.set(wall, cut);
        this.applyCut(wall, cut);
      }
    }
    const caps = enabled ? 1 : 0;
    if (caps !== this.capsOn) {
      this.capsOn = caps;
      for (const node of this.walls.values()) if (node.cap) node.cap.visible = enabled;
    }
    if (!this.ceiling) return;
    // 0 none, 1 shadow only (planner), 2 solid (walkthrough).
    const mode = !this.hasCeiling ? 0 : enabled ? 1 : 2;
    if (mode !== this.ceilingMode) {
      this.ceilingMode = mode;
      this.ceiling.visible = mode !== 0;
      this.ceiling.castShadow = true;
      setShadowOnly(this.ceiling, mode === 1);
    }
  }

  private applyCut(surface: Wall, cut: boolean): void {
    const node = this.walls.get(surface)!;
    for (const c of node.body.children) setShadowOnly(c as Mesh, cut);
    node.trim.visible = !cut;
    for (const op of this.openings) if (op.wall === surface) op.setCut(cut);
  }

  isCut(surface: Wall): boolean {
    return this.cutState.get(surface) ?? false;
  }

  openingsNode(surface: Wall): Group | null {
    return this.walls.get(surface)?.openings ?? null;
  }

  /** Which surface a ray hits first. Cut-away walls are not there to hit. */
  pickSurface(ray: Ray): Surface | '' {
    let best: Surface | '' = '';
    let bestT = Infinity;
    for (const b of this.boxes) {
      if (this.hiddenWalls.includes(b.surface as Wall)) continue;
      const t = rayAabb(ray, boxOf(b));
      if (t >= 0 && t < bestT) { bestT = t; best = b.surface; }
    }
    return best;
  }
}

export function boxOf(b: RoomBox): Box3 {
  return new Box3().setFromCenterAndSize(b.centre, b.size);
}

const _hit = new Vector3();

/** Entry distance of a ray into a box, or -1 for a miss (0 from inside). */
export function rayAabb(ray: Ray, box: Box3): number {
  if (box.containsPoint(ray.origin)) return 0;
  const p = ray.intersectBox(box, _hit);
  return p ? p.distanceTo(ray.origin) : -1;
}
