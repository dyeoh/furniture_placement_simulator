// One piece of furniture in the room: a catalogue item plus where it is and
// what the solver is doing with it. ← placed_item.gd
//
// An item has a physics body only once let go of. While dragged it is a ghost
// -- a mesh following the pointer -- because a rigid body driven around by the
// cursor fights every other body it passes through.

import {
  Box3, BoxGeometry, Color, Group, Matrix4, Mesh, MeshBasicMaterial, MeshStandardMaterial,
  Object3D, PointLight, Quaternion, Vector2, Vector3,
} from 'three';
import type { FurnitureItem } from '../catalog/furniture-item';
import { build as buildShape, bulbHeight } from '../catalog/furniture-shapes';
import * as ModelLibrary from '../catalog/model-library';
import { srgb } from '../color';
import { warmthColor } from '../room/lighting';
import { blob, BLOB_LIFT } from '../room/occlusion';
import * as SurfaceMaterials from '../room/surface-materials';
import { disposeTree } from '../room/wall-opening';
import { xform, type Xform } from '../physics/backend';

export enum State { GHOST, SETTLING, PLACED, CARRIED }

export interface LampState { on: boolean; energy: number; warmth: number }

export interface PlacedDict { id: string; x: number; z: number; yaw: number; finish: string; light?: LampState }

const LIGHT_MAX_ENERGY = 3;
const LIGHT_RANGE = 5;
const BULB_GLOW = 4;
/**
 * The shade's own glow per unit of lamp energy. Godot adds 0.12 on top of
 * backlight translucency; three's standard material has no backlight, so the
 * light the fabric would let through is folded in here.
 */
const SHADE_GLOW = 0.45;
const WALL_CONTACT_STRENGTH = 0.3;
const UP = new Vector3(0, 1, 0);

/** Lamp shadows are cube maps: off on low spec, and only for lamps the showroom picks. */
export const lampShadows = { allowed: true };

export class PlacedItem {
  state = State.GHOST;
  /** Yaw in quarter turns 0..3: keeps AABBs exact, so overlap is a plain box test. */
  yaw = 0;
  /** Centre of the footprint on the floor (y is the bottom face). */
  position = new Vector3();
  finish = '';
  body = -1;
  /** The body's transform as of the last physics sync (valid while body >= 0). */
  xf: Xform = xform();
  valid = true;
  settleTime = 0;
  /** Height above the floor for the intended transform (a carried piece). */
  liftY = 0;
  light: LampState = { on: true, energy: 0.6, warmth: 0.7 };

  node: Group | null = null;
  private tintMesh: Mesh | null = null;
  private ghostMat: MeshBasicMaterial | null = null;
  private woodMat: MeshStandardMaterial | null = null;
  private modelNode: Group | null = null;
  /** An uploaded model's clone; geometry shared with the catalogue item. */
  private uploadNode: Object3D | null = null;
  private lamp: PointLight | null = null;
  private bulbMat: MeshStandardMaterial | null = null;
  private shadeMat: MeshStandardMaterial | null = null;
  private wallBlob: Mesh | null = null;
  private wallKey = '';

  constructor(public item: FurnitureItem) {}

  angle(): number { return this.yaw * Math.PI * 0.5; }

  /** Footprint extents after rotation: quarter turns swap width and depth. */
  rotatedSize(): Vector3 {
    const s = this.item.size;
    return this.yaw % 2 === 1 ? new Vector3(s.z, s.y, s.x) : s.clone();
  }

  centre(): Vector3 {
    return this.position.clone().setY(this.position.y + this.item.size.y * 0.5);
  }

  /** From the live body when there is one (it may have tipped), else the intended placement. */
  aabb(useBody = true): Box3 {
    if (useBody && this.body >= 0) {
      const m = _m.makeRotationFromQuaternion(this.xf.q).elements;
      const h = this.item.size;
      const ext = new Vector3(
        Math.abs(m[0]) * h.x + Math.abs(m[4]) * h.y + Math.abs(m[8]) * h.z,
        Math.abs(m[1]) * h.x + Math.abs(m[5]) * h.y + Math.abs(m[9]) * h.z,
        Math.abs(m[2]) * h.x + Math.abs(m[6]) * h.y + Math.abs(m[10]) * h.z).multiplyScalar(0.5);
      return new Box3(this.xf.p.clone().sub(ext), this.xf.p.clone().add(ext));
    }
    return new Box3().setFromCenterAndSize(this.centre(), this.rotatedSize());
  }

  intendedTransform(): Xform {
    return xform(this.centre().setY(this.position.y + this.item.size.y * 0.5 + this.liftY),
      new Quaternion().setFromAxisAngle(UP, this.angle()));
  }

  // --- visuals

  buildVisual(parent: Object3D, color: Color): void {
    this.node = new Group();
    this.node.name = 'Item_' + this.item.id;
    parent.add(this.node);
    if (this.item.meshScene) {
      // An upload: its materials are not ours to tint, like Godot's mesh_scene.
      this.uploadNode = this.item.meshScene.clone(true);
      this.node.add(this.uploadNode);
    } else if (this.item.model && ModelLibrary.has(this.item.model)) {
      this.modelNode = ModelLibrary.instantiate(this.item.model, this.item.size);
      if (this.modelNode) {
        this.node.add(this.modelNode);
        ModelLibrary.tint(this.modelNode, this.item.model, color);
      }
    } else {
      this.woodMat = SurfaceMaterials.wood(color);
      this.node.add(buildShape(this.item.shapeKind, this.item.size, this.woodMat));
    }
    if (this.item.isLight()) {
      this.lamp = new PointLight(0xffffff, 1, LIGHT_RANGE, 1.2);
      this.lamp.castShadow = false;
      this.lamp.shadow.mapSize.set(1024, 1024);
      this.lamp.shadow.bias = -0.002;
      this.lamp.position.set(0, bulbHeight(this.item.size), 0);
      this.node.add(this.lamp);
      this.bulbMat = (this.node.getObjectByName('Bulb') as Mesh | undefined)?.material as MeshStandardMaterial ?? null;
      this.shadeMat = (this.node.getObjectByName('Shade') as Mesh | undefined)?.material as MeshStandardMaterial ?? null;
      this.applyLight();
    }
    // Validity overlay: a translucent shell, so any visual gets the same green/red.
    const s = this.item.size;
    this.ghostMat = new MeshBasicMaterial({ color: srgb(0.3, 0.9, 0.4), transparent: true, opacity: 0.35, depthWrite: false });
    this.tintMesh = new Mesh(new BoxGeometry(s.x + 0.02, s.y + 0.02, s.z + 0.02), this.ghostMat);
    this.tintMesh.castShadow = false;
    this.tintMesh.visible = false;
    this.node.add(this.tintMesh);
    this.syncVisual(false);
  }

  setColor(color: Color): void {
    if (this.woodMat) SurfaceMaterials.tint(this.woodMat, 'oak_veneer_01', color);
    else if (this.modelNode) ModelLibrary.tint(this.modelNode, this.item.model, color);
  }

  setLightShadow(on: boolean): void {
    if (this.lamp) this.lamp.castShadow = on && lampShadows.allowed;
  }

  lightCastsShadow(): boolean {
    return this.lamp?.castShadow ?? false;
  }

  setLight(on: boolean, energy: number, warmth: number): void {
    const c = (v: number) => Math.min(Math.max(v, 0), 1);
    this.light = { on, energy: c(energy), warmth: c(warmth) };
    this.applyLight();
  }

  applyLight(): void {
    if (!this.lamp) return;
    const l = this.light;
    const color = warmthColor(l.warmth);
    this.lamp.visible = l.on;
    this.lamp.intensity = l.energy * LIGHT_MAX_ENERGY * Math.PI;
    this.lamp.color.copy(color);
    for (const [m, glow] of [[this.bulbMat, BULB_GLOW], [this.shadeMat, SHADE_GLOW]] as const) {
      if (!m) continue;
      m.emissive.copy(l.on ? color : new Color(0, 0, 0));
      m.emissiveIntensity = l.energy * glow;
    }
  }

  /**
   * Darken the wall behind the piece. [inward] is the wall's normal into the
   * room, [centre] the middle of the outline on the wall, [size] that outline.
   * A zero [inward] clears it.
   */
  setWallContact(inward: Vector3, centre: Vector3, size: Vector2): void {
    const r = (v: number) => Math.round(v * 100);
    const key = inward.lengthSq() === 0 ? ''
      : `${inward.x},${inward.z}|${r(centre.x)},${r(centre.y)},${r(centre.z)}|${r(size.x)},${r(size.y)}`;
    if (key === this.wallKey || !this.node) return;
    this.wallKey = key;
    if (this.wallBlob) {
      this.wallBlob.removeFromParent();
      this.wallBlob.geometry.dispose();
      (this.wallBlob.material as MeshBasicMaterial).dispose();
      this.wallBlob = null;
    }
    if (!key) return;
    this.wallBlob = blob(size, WALL_CONTACT_STRENGTH);
    this.wallBlob.name = 'WallContact';
    const along = UP.clone().cross(inward);
    this.wallBlob.quaternion.setFromRotationMatrix(new Matrix4().makeBasis(along, UP, inward));
    this.wallBlob.position.copy(centre).addScaledVector(inward, BLOB_LIFT);
    // World-anchored like Godot's top_level: a sibling of the item, not a child.
    this.node.parent?.add(this.wallBlob);
  }

  hasWallContact(): boolean { return this.wallKey !== ''; }

  setTint(show: boolean, ok: boolean): void {
    if (!this.tintMesh || !this.ghostMat) return;
    this.tintMesh.visible = show;
    this.ghostMat.color.copy(ok ? srgb(0.3, 0.9, 0.4) : srgb(0.95, 0.3, 0.25));
    this.ghostMat.opacity = ok ? 0.35 : 0.4;
  }

  setHighlight(on: boolean): void {
    if (!this.tintMesh || !this.ghostMat) return;
    if (on) {
      this.tintMesh.visible = true;
      this.ghostMat.color.copy(srgb(1, 0.85, 0.3));
      this.ghostMat.opacity = 0.25;
    } else if (this.state !== State.GHOST) {
      this.tintMesh.visible = false;
    }
  }

  /** The visual follows the body when there is one, the intended placement otherwise. */
  syncVisual(fromBody: boolean): void {
    if (!this.node) return;
    const xf = fromBody && this.body >= 0 ? this.xf : this.intendedTransform();
    this.node.position.copy(xf.p);
    this.node.quaternion.copy(xf.q);
  }

  freeVisual(): void {
    this.setWallContact(new Vector3(), new Vector3(), new Vector2());
    if (this.node) {
      this.node.removeFromParent();
      // Model geometry is shared with the library; only dispose what we built.
      if (!this.modelNode && !this.uploadNode) disposeTree(this.node);
      this.lamp?.shadow.map?.dispose();
    }
    this.node = null;
    this.tintMesh = null;
    this.woodMat = null;
    this.modelNode = null;
    this.uploadNode = null;
    this.lamp = null;
    this.bulbMat = null;
    this.shadeMat = null;
    this.wallBlob = null;
    this.wallKey = '';
  }

  toDict(): PlacedDict {
    const r = (v: number) => Math.round(v * 1000) / 1000;
    const d: PlacedDict = { id: this.item.id, x: r(this.position.x), z: r(this.position.z), yaw: this.yaw, finish: this.finish };
    if (this.item.isLight()) d.light = { ...this.light };
    return d;
  }
}

const _m = new Matrix4();
