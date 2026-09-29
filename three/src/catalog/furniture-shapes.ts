// Generated furniture for pieces no generic model suits -- a bed, a rack, a
// floor lamp, the plain slab fallback -- and the windows and doors that go in
// the walls. ← furniture_shapes.gd
//
// Parts are boxes and cylinders inside the item's box, so the collider (still
// the box) is honest. Every timber part shares the one material passed in,
// which is what lets a finish change retint the whole piece.

import {
  BackSide, BoxGeometry, BufferGeometry, CylinderGeometry, FrontSide, Group, Material, Matrix4,
  Mesh, MeshStandardMaterial, Object3D, SphereGeometry, Vector3,
} from 'three';
import { srgb } from '../color';
import { boxUVs, SETS } from '../room/surface-materials';

const LEG = 0.05;

export function build(shape: string, size: Vector3, wood: MeshStandardMaterial | null): Group {
  const root = new Group();
  root.name = 'Shape_' + shape;
  switch (shape) {
    case 'bed': bed(root, size, wood!); break;
    case 'rack': rack(root, size, wood!); break;
    case 'lamp': lamp(root, size); break;
    case 'window': windowFrame(root, size); break;
    case 'door': door(root, size); break;
    default: part(root, new BoxGeometry(size.x, size.y, size.z), new Vector3(), wood!);
  }
  return root;
}

/** Headboard on -Z (the back wall-magnet snaps to a wall), mattress inset on top. */
function bed(root: Group, size: Vector3, wood: MeshStandardMaterial): void {
  const half = size.clone().multiplyScalar(0.5);
  const headT = Math.min(0.05, size.z * 0.05);
  const frameH = Math.min(0.12, size.y * 0.35);
  const legH = Math.min(0.15, size.y * 0.3);
  const mattressH = Math.max(size.y - legH - frameH, 0.05);
  const bodyZ = size.z - headT;
  for (const sx of [-1, 1]) {
    for (const sz of [-1, 1]) {
      box(root, new Vector3(LEG, legH, LEG), new Vector3(
        sx * (half.x - LEG * 0.5 - 0.02), -half.y + legH * 0.5,
        sz * (bodyZ * 0.5 - LEG * 0.5 - 0.02) + headT * 0.5), wood);
    }
  }
  box(root, new Vector3(size.x, frameH, bodyZ), new Vector3(0, -half.y + legH + frameH * 0.5, headT * 0.5), wood);
  box(root, new Vector3(size.x, size.y, headT), new Vector3(0, 0, -half.z + headT * 0.5), wood);
  const fabric = new MeshStandardMaterial({ color: srgb(0.93, 0.92, 0.89), roughness: 1 });
  box(root, new Vector3(size.x - 0.06, mattressH, bodyZ - 0.06),
    new Vector3(0, -half.y + legH + frameH + mattressH * 0.5, headT * 0.5), fabric);
}

/** Two A-frames and a rail. */
function rack(root: Group, size: Vector3, wood: MeshStandardMaterial): void {
  const half = size.clone().multiplyScalar(0.5);
  const bar = 0.035;
  for (const sx of [-1, 1]) {
    const x = sx * (half.x - bar * 0.5);
    const legLen = Math.sqrt(size.y * size.y + half.z * half.z);
    for (const sz of [-1, 1]) {
      const leg = box(root, new Vector3(bar, legLen, bar), new Vector3(x, 0, sz * half.z * 0.5), wood);
      leg.rotation.x = -sz * Math.atan2(half.z, size.y);
    }
    box(root, new Vector3(bar, bar, size.z), new Vector3(x, -half.y + bar * 0.5, 0), wood);
  }
  const rail = part(root, new CylinderGeometry(0.015, 0.015, size.x, 12), new Vector3(0, half.y - 0.03, 0), wood);
  rail.rotation.z = Math.PI * 0.5;
}

/** Where a lamp's bulb sits above its centre: the pole's tip, mid-shade. */
export function bulbHeight(size: Vector3): number {
  return size.y * 0.5 - size.y * 0.28 * 0.5;
}

/**
 * Weighted base, slim pole, an open fabric drum round a bulb. The light itself
 * is added by PlacedItem. Godot's fabric uses backlight translucency; three's
 * standard material has none, so PlacedItem gives the shade a stronger
 * emissive glow instead (see SHADE_GLOW there).
 */
function lamp(root: Group, size: Vector3): void {
  const half = size.clone().multiplyScalar(0.5);
  const metal = new MeshStandardMaterial({ color: srgb(0.15, 0.15, 0.16), metalness: 0.8, roughness: 0.35 });
  const baseR = Math.min(half.x, half.z) * 0.6;
  part(root, new CylinderGeometry(baseR, baseR, 0.02, 32), new Vector3(0, -half.y + 0.01, 0), metal);
  const shadeH = size.y * 0.28;
  const poleH = size.y - shadeH * 0.5 - 0.02;
  part(root, new CylinderGeometry(0.012, 0.012, poleH, 12), new Vector3(0, -half.y + 0.02 + poleH * 0.5, 0), metal);
  const top = Math.min(half.x, half.z) * 0.85;
  const bottom = Math.min(half.x, half.z);
  const shadeAt = new Vector3(0, half.y - shadeH * 0.5, 0);
  const fabric = new MeshStandardMaterial({ color: srgb(0.96, 0.93, 0.86), roughness: 1, side: FrontSide });
  const shade = part(root, new CylinderGeometry(top, bottom, shadeH, 48, 1, true), shadeAt, fabric);
  shade.name = 'Shade';
  // The shade does not cast: real fabric passes most of its light, and a
  // solid one throws hard bands up and down the wall.
  shade.castShadow = false;
  const lining = new MeshStandardMaterial({ color: srgb(0.5, 0.47, 0.42), roughness: 1, side: BackSide });
  const li = part(root, new CylinderGeometry(top, bottom, shadeH, 48, 1, true), shadeAt, lining);
  li.name = 'Lining';
  li.castShadow = false;
  const glass = new MeshStandardMaterial({ color: srgb(1, 0.98, 0.94) });
  const b = part(root, new SphereGeometry(0.035, 16, 12), new Vector3(0, bulbHeight(size), 0), glass);
  b.scale.y = 0.08 / 0.07;
  b.name = 'Bulb';
  b.castShadow = false;
}

/**
 * A white casement: frame, sill board, a mullion when wide, a transom when
 * tall, and glass. [size] is (width, height, wall thickness) centred on the
 * wall's middle plane, +Z into the room. Frame parts are tagged `caster`: on a
 * cut-away wall they keep their shadow, so the sun patch on the floor has bars.
 */
function windowFrame(root: Group, size: Vector3): void {
  const half = size.clone().multiplyScalar(0.5);
  const f = 0.06;
  const d = size.z + 0.04;
  const paint = trim();
  const caster = (m: Mesh) => { m.userData.caster = true; return m; };
  for (const s of [-1, 1]) {
    caster(box(root, new Vector3(size.x, f, d), new Vector3(0, s * (half.y - f * 0.5), 0), paint));
    caster(box(root, new Vector3(f, size.y - f * 2, d), new Vector3(s * (half.x - f * 0.5), 0, 0), paint));
  }
  if (size.x > 1.5) caster(box(root, new Vector3(f * 0.6, size.y - f * 2, d * 0.6), new Vector3(), paint));
  if (size.y > 1.6) {
    caster(box(root, new Vector3(size.x - f * 2, f * 0.6, d * 0.6), new Vector3(0, half.y - size.y / 3, 0), paint));
  }
  const board = caster(box(root, new Vector3(size.x + 0.08, 0.03, 0.14),
    new Vector3(0, -half.y - 0.015, half.z + 0.05), paint));
  board.name = 'Sill';
  const glass = new MeshStandardMaterial({
    color: srgb(0.82, 0.9, 0.95), transparent: true, opacity: 0.12, roughness: 0.05, depthWrite: false,
  });
  const pane = box(root, new Vector3(size.x - f * 2, size.y - f * 2, 0.012), new Vector3(), glass);
  pane.castShadow = false;
  pane.name = 'Glass';
}

/** A closed door on the room side of the wall: architrave, a two-panel leaf, a lever. */
function door(root: Group, size: Vector3): void {
  const half = size.clone().multiplyScalar(0.5);
  const f = 0.07;
  const face = half.z;
  const paint = trim();
  for (const s of [-1, 1]) {
    box(root, new Vector3(f, size.y, 0.03), new Vector3(s * (half.x - f * 0.5), 0, face + 0.015), paint);
  }
  box(root, new Vector3(size.x, f, 0.03), new Vector3(0, half.y - f * 0.5, face + 0.015), paint);
  const leafW = size.x - f * 2;
  const leafH = size.y - f;
  const leafY = -f * 0.5;
  box(root, new Vector3(leafW, leafH, 0.02), new Vector3(0, leafY, face + 0.01), paint).name = 'Leaf';
  const panelW = leafW - 0.2;
  const panelH = (leafH - 0.3) * 0.5;
  for (const s of [-1, 1]) {
    box(root, new Vector3(panelW, panelH, 0.008), new Vector3(0, leafY + s * (panelH * 0.5 + 0.05), face + 0.024), paint);
  }
  const metal = new MeshStandardMaterial({ color: srgb(0.2, 0.2, 0.21), metalness: 0.8, roughness: 0.3 });
  const hx = leafW * 0.5 - 0.08;
  const hy = 1 - half.y;
  box(root, new Vector3(0.05, 0.12, 0.012), new Vector3(hx, hy, face + 0.026), metal);
  box(root, new Vector3(0.12, 0.02, 0.02), new Vector3(hx - 0.05, hy + 0.02, face + 0.05), metal);
}

function trim(): MeshStandardMaterial {
  return new MeshStandardMaterial({ color: srgb(0.95, 0.94, 0.91), roughness: 0.5 });
}

function box(root: Object3D, size: Vector3, at: Vector3, mat: Material): Mesh {
  return part(root, new BoxGeometry(size.x, size.y, size.z), at, mat);
}

const _m = new Matrix4();

/** Add a part at [at]. Timber gets object-space box UVs so the grain follows the piece. */
function part(root: Object3D, geo: BufferGeometry, at: Vector3, mat: Material): Mesh {
  const mesh = new Mesh(geo, mat);
  mesh.position.copy(at);
  mesh.castShadow = true;
  mesh.receiveShadow = true;
  const m = mat as MeshStandardMaterial;
  if (m.map) boxUVs(geo, _m.makeTranslation(at.x, at.y, at.z), SETS.oak_veneer_01.size);
  root.add(mesh);
  return mesh;
}
