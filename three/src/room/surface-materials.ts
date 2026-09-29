// PBR materials for the room and generated furniture parts. ← surface_materials.gd
//
// Three CC0 texture sets (albedo, normal, roughness). Godot maps them
// triplanar in the shader; stock three materials have no triplanar mode and
// this build avoids shader patching (it would break the WebGPU renderer), so
// the same projection is baked into the UVs instead: boxUVs() gives every
// face of a box one texture repeat per [size] metres of real edge, which is
// exactly what triplanar on an axis-aligned box computes.
//
// Painting and finishes set `color`, a tint over the texture, normalised by
// the set's mean albedo so a wall painted Sage comes out Sage.

import {
  BufferGeometry, Color, DataTexture, Float32BufferAttribute, Matrix3, Matrix4,
  MeshStandardMaterial, RepeatWrapping, SRGBColorSpace, Texture, TextureLoader, Vector2, Vector3,
} from 'three';
import { normalised } from '../color';

const DIR = 'assets/textures/';

export type SetName = 'plaster_grey_04' | 'laminate_floor_02' | 'oak_veneer_01';

/** Real-world edge in metres and linear mean albedo, measured by the Godot project. */
export const SETS: Record<SetName, { size: number; mean: [number, number, number] }> = {
  plaster_grey_04: { size: 1.5, mean: [0.294, 0.273, 0.217] },
  laminate_floor_02: { size: 1.7, mean: [0.330, 0.218, 0.126] },
  oak_veneer_01: { size: 1.83, mean: [0.355, 0.207, 0.095] },
};

const loader = new TextureLoader();
const textures = new Map<string, Texture>();
let anisotropy = 1;

export function setMaxAnisotropy(n: number): void {
  anisotropy = n;
  for (const t of textures.values()) t.anisotropy = n;
}

function tex(set: SetName, map: 'diff' | 'nor_gl' | 'rough'): Texture {
  const key = `${set}/${map}`;
  let t = textures.get(key);
  if (!t) {
    // Headless (bun test): no DOM to decode images with, so an empty texture.
    t = typeof document === 'undefined' ? new Texture() : loader.load(`${DIR}${set}/${set}_${map}_1k.jpg`);
    t.wrapS = t.wrapT = RepeatWrapping;
    t.anisotropy = anisotropy;
    if (map === 'diff') t.colorSpace = SRGBColorSpace;
    textures.set(key, t);
  }
  return t;
}

/** Resolve once every texture referenced so far has loaded, for "ready". */
export function texturesLoaded(): Promise<void> {
  return Promise.all([...textures.values()].map((t) =>
    t.image ? Promise.resolve() : new Promise<void>((resolve) => {
      const check = () => (t.image ? resolve() : setTimeout(check, 30));
      check();
    }))).then(() => undefined);
}

/** Painted plaster: relief only, the paint is the colour. [withAo]: the mesh carries a seam AO map on uv1. */
export function plaster(color: Color): MeshStandardMaterial {
  const m = new MeshStandardMaterial({ color, roughness: 0.92, metalness: 0 });
  m.normalMap = tex('plaster_grey_04', 'nor_gl');
  m.normalScale = new Vector2(0.5, 0.5);
  return m;
}

/** Laminate planks, matte-ish so a low sun does not turn the floor into one highlight. */
export function floor(color: Color): MeshStandardMaterial {
  const m = new MeshStandardMaterial({ roughness: 0.72, metalness: 0 });
  m.map = tex('laminate_floor_02', 'diff');
  m.normalMap = tex('laminate_floor_02', 'nor_gl');
  m.normalScale = new Vector2(0.8, 0.8);
  tint(m, 'laminate_floor_02', color);
  return m;
}

export function wood(color: Color): MeshStandardMaterial {
  const m = new MeshStandardMaterial({ roughness: 1, metalness: 0 });
  m.map = tex('oak_veneer_01', 'diff');
  m.normalMap = tex('oak_veneer_01', 'nor_gl');
  m.normalScale = new Vector2(0.7, 0.7);
  m.roughnessMap = tex('oak_veneer_01', 'rough');
  tint(m, 'oak_veneer_01', color);
  return m;
}

/** Seam AO on the mesh's uv1, ambient only (three's aoMap never darkens direct light). */
export function setAo(m: MeshStandardMaterial, ao: DataTexture): void {
  ao.channel = 1;
  m.aoMap = ao;
  m.needsUpdate = true;
}

export function tint(m: MeshStandardMaterial, set: SetName, color: Color): void {
  m.color.copy(m.map ? normalised(color, SETS[set].mean) : color);
}

const _p = new Vector3();
const _n = new Vector3();
const _nm = new Matrix3();

/**
 * Box-projected UVs: each vertex takes the two coordinates across its face
 * normal, in metres, divided by [size]. [frame] maps the geometry into the
 * space the grain is anchored to -- the world for room surfaces (so a wall
 * split round a window stays one continuous plaster), the piece for timber
 * (so the grain moves with it when carried).
 */
export function boxUVs(geo: BufferGeometry, frame: Matrix4, size: number): void {
  const pos = geo.getAttribute('position');
  const nor = geo.getAttribute('normal');
  const uv = new Float32Array(pos.count * 2);
  _nm.getNormalMatrix(frame);
  for (let i = 0; i < pos.count; i++) {
    _p.fromBufferAttribute(pos, i).applyMatrix4(frame);
    _n.fromBufferAttribute(nor, i).applyMatrix3(_nm);
    const ax = Math.abs(_n.x), ay = Math.abs(_n.y), az = Math.abs(_n.z);
    let u: number, v: number;
    if (ay >= ax && ay >= az) { u = _p.x; v = _p.z; }
    else if (ax >= az) { u = _p.z; v = _p.y; }
    else { u = _p.x; v = _p.y; }
    uv[i * 2] = u / size;
    uv[i * 2 + 1] = v / size;
  }
  geo.setAttribute('uv', new Float32BufferAttribute(uv, 2));
}

/** A second UV set (three's `uv1`) from a function of each vertex in [frame]'s space. */
export function uv1From(geo: BufferGeometry, frame: Matrix4, f: (p: Vector3) => [number, number]): void {
  const pos = geo.getAttribute('position');
  const uv = new Float32Array(pos.count * 2);
  for (let i = 0; i < pos.count; i++) {
    _p.fromBufferAttribute(pos, i).applyMatrix4(frame);
    const [u, v] = f(_p);
    uv[i * 2] = u;
    uv[i * 2 + 1] = v;
  }
  geo.setAttribute('uv1', new Float32BufferAttribute(uv, 2));
}
