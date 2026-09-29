// Faked ambient occlusion. ← occlusion.gd
//
// Neither renderer being compared has SSAO on the web, so the cues that sell
// "a room" are supplied by hand: AO maps darkening the floor and walls into
// their seams (ambient only), and a soft dark quad on the wall behind a piece
// standing against it.

import {
  DataTexture, DoubleSide, LinearFilter, LinearMipmapLinearFilter, Mesh, MeshBasicMaterial,
  PlaneGeometry, RedFormat, RGBAFormat, UnsignedByteType, Vector2,
} from 'three';

export const BLOB_MARGIN = 0.18;
export const BLOB_LIFT = 0.004;
const SEAM_DEPTH = 0.5;
const SEAM_FALLOFF = 0.12;
const WALL_AO_SIZE = [256, 128] as const;
const FLOOR_AO_SIZE = [256, 256] as const;
const BLOB_RES = 64;

const aoCache = new Map<string, DataTexture>();
const blobCache = new Map<string, DataTexture>();

export function seam(d: number): number {
  return 1 - SEAM_DEPTH * Math.exp(-Math.max(d, 0) / SEAM_FALLOFF);
}

/**
 * AO for one wall's inside face, spanning its whole [run] by [height]: uv1
 * (0, 0) is the top of the -X end. Darkens into both inside corners at
 * +/-[inner], the floor, and the ceiling when there is one.
 */
export function wallAo(run: number, height: number, inner: number, withCeiling: boolean): DataTexture {
  const key = `w${run.toFixed(3)}/${height.toFixed(3)}/${inner.toFixed(3)}/${withCeiling}`;
  const hit = aoCache.get(key);
  if (hit) return hit;
  const [sx, sy] = WALL_AO_SIZE;
  const across = Array.from({ length: sx }, (_, i) => seam(inner - Math.abs(((i + 0.5) / sx - 0.5) * run)));
  const down = Array.from({ length: sy }, (_, j) => {
    const y = (1 - (j + 0.5) / sy) * height;
    return seam(y) * (withCeiling ? seam(height - y) : 1);
  });
  const t = separable(across, down);
  aoCache.set(key, t);
  return t;
}

/** AO for the floor spanning [full] (walls included), darkening toward the inside faces at [half]. */
export function floorAo(full: Vector2, half: Vector2): DataTexture {
  const key = `f${full.x.toFixed(3)}/${full.y.toFixed(3)}/${half.x.toFixed(3)}/${half.y.toFixed(3)}`;
  const hit = aoCache.get(key);
  if (hit) return hit;
  const [sx, sy] = FLOOR_AO_SIZE;
  const across = Array.from({ length: sx }, (_, i) => seam(half.x - Math.abs(((i + 0.5) / sx - 0.5) * full.x)));
  const down = Array.from({ length: sy }, (_, j) => seam(half.y - Math.abs(((j + 0.5) / sy - 0.5) * full.y)));
  const t = separable(across, down);
  aoCache.set(key, t);
  return t;
}

/**
 * Greyscale texture whose texel (i, j) is across[i] * down[j]. Row 0 is the
 * top of the image as Godot lays it out, so the texture is not flipped:
 * DataTexture rows start at v = 0 and uv1 v runs top-down.
 */
function separable(across: number[], down: number[]): DataTexture {
  const w = across.length, h = down.length;
  const data = new Uint8Array(w * h);
  let k = 0;
  for (let j = 0; j < h; j++) {
    for (let i = 0; i < w; i++) {
      data[k++] = Math.round(Math.min(Math.max(across[i] * down[j], 0), 1) * 255);
    }
  }
  const t = new DataTexture(data, w, h, RedFormat, UnsignedByteType);
  t.generateMipmaps = true;
  t.minFilter = LinearMipmapLinearFilter;
  t.magFilter = LinearFilter;
  t.needsUpdate = true;
  return t;
}

/**
 * Alpha for a soft rounded rectangle: fully dark over the footprint, fading
 * out over BLOB_MARGIN around it -- the Godot blob shader's SDF, baked.
 */
function blobTexture(footprint: Vector2): DataTexture {
  const key = `${footprint.x.toFixed(2)}x${footprint.y.toFixed(2)}`;
  const hit = blobCache.get(key);
  if (hit) return hit;
  const inner = footprint.clone().multiplyScalar(0.5);
  const data = new Uint8Array(BLOB_RES * BLOB_RES * 4);
  const r = 0.06;
  for (let j = 0; j < BLOB_RES; j++) {
    for (let i = 0; i < BLOB_RES; i++) {
      const px = ((i + 0.5) / BLOB_RES - 0.5) * (inner.x + BLOB_MARGIN) * 2;
      const py = ((j + 0.5) / BLOB_RES - 0.5) * (inner.y + BLOB_MARGIN) * 2;
      const qx = Math.abs(px) - inner.x + r, qy = Math.abs(py) - inner.y + r;
      const d = Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - r;
      const x = Math.min(Math.max((d + 0.06) / (BLOB_MARGIN + 0.06), 0), 1);
      const a = 1 - x * x * (3 - 2 * x);
      const o = (j * BLOB_RES + i) * 4;
      data[o] = data[o + 1] = data[o + 2] = data[o + 3] = Math.round(a * 255);
    }
  }
  const t = new DataTexture(data, BLOB_RES, BLOB_RES, RGBAFormat, UnsignedByteType);
  t.magFilter = LinearFilter;
  t.minFilter = LinearFilter;
  t.needsUpdate = true;
  blobCache.set(key, t);
  return t;
}

/** A soft-edged quad for an outline of [footprint] metres, in its local XY plane (normal +Z). */
export function blob(footprint: Vector2, strength: number): Mesh {
  const size = footprint.clone().addScalar(BLOB_MARGIN * 2);
  const mat = new MeshBasicMaterial({
    color: 0x000000, alphaMap: blobTexture(footprint), transparent: true,
    opacity: strength, depthWrite: false, side: DoubleSide,
  });
  const m = new Mesh(new PlaneGeometry(size.x, size.y), mat);
  m.castShadow = false;
  m.receiveShadow = false;
  m.name = 'ContactShadow';
  return m;
}
