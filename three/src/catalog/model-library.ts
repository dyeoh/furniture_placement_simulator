// Generic CC0 furniture models (Poly Haven) standing in for the store's
// products, which publish no geometry. ← model_library.gd
//
// A model is stretched per axis into the catalogue item's box; the collider is
// still the box, so nothing physical depends on the mesh. Each model's albedo
// is tinted towards the chosen finish: divide by the model's own mean colour,
// multiply by the finish.
//
// Every model is loaded up front (preload) rather than on first use, the way
// the Godot export has them all in its .pck before the first frame.

import { Box3, Color, Group, Mesh, MeshStandardMaterial, Object3D, Vector3 } from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { normalised } from '../color';

const DIR = 'assets/models/';

/** mean: linear mean albedo of the main wood texture; yaw: turn so the front faces +Z. */
export const MODELS: Record<string, { mean: [number, number, number]; yaw: number }> = {
  wooden_display_shelves_01: { mean: [0.522, 0.304, 0.165], yaw: -Math.PI * 0.5 },
  modern_wooden_cabinet: { mean: [0.050, 0.025, 0.010], yaw: 0 },
  drawer_cabinet: { mean: [0.187, 0.105, 0.051], yaw: 0 },
  side_table_01: { mean: [0.243, 0.109, 0.040], yaw: 0 },
  wooden_table_02: { mean: [0.253, 0.078, 0.024], yaw: 0 },
  modern_ceiling_lamp_01: { mean: [0.5, 0.5, 0.5], yaw: 0 },
};

/** A tint never brighter than this many times the texture, so highlights do not blow out. */
const MAX_GAIN = 3;

const scenes = new Map<string, Object3D>();
const bounds = new Map<string, Box3>();

export async function preload(names = Object.keys(MODELS)): Promise<void> {
  const loader = new GLTFLoader();
  await Promise.all(names.map(async (name) => {
    const gltf = await loader.loadAsync(`${DIR}${name}/${name}.gltf`);
    const scene = gltf.scene;
    enableBakedAo(scene);
    const turned = new Group();
    turned.rotation.y = MODELS[name].yaw;
    turned.add(scene);
    turned.updateMatrixWorld(true);
    bounds.set(name, new Box3().setFromObject(turned, true));
    turned.remove(scene);
    scenes.set(name, scene);
  }));
}

export function has(model: string): boolean {
  return model in MODELS && scenes.has(model);
}

/** Size of the model as authored, for pieces used at their own scale (the ceiling fitting). */
export function naturalSize(model: string): Vector3 {
  const b = bounds.get(model);
  return b ? b.getSize(new Vector3()) : new Vector3(0.3, 0.3, 0.3);
}

/** The model fitted into a box of [size] centred on the returned node's origin. */
export function instantiate(model: string, size: Vector3): Group | null {
  const scene = scenes.get(model);
  const b = bounds.get(model);
  if (!scene || !b) return null;
  const bs = b.getSize(new Vector3());
  const s = new Vector3(size.x / Math.max(bs.x, 1e-3), size.y / Math.max(bs.y, 1e-3), size.z / Math.max(bs.z, 1e-3));
  // Bounds were measured with the yaw applied: turn, then stretch, then recentre.
  const turned = new Group();
  turned.rotation.y = MODELS[model].yaw;
  turned.add(scene.clone(true));
  const fitted = new Group();
  fitted.scale.copy(s);
  fitted.position.copy(b.getCenter(new Vector3()).multiply(s).negate());
  fitted.add(turned);
  const wrapper = new Group();
  wrapper.name = 'Model_' + model;
  wrapper.add(fitted);
  wrapper.traverse((o) => {
    if ((o as Mesh).isMesh) { o.castShadow = true; o.receiveShadow = true; }
  });
  return wrapper;
}

/** Retint every surface towards [color]. Materials are cloned once per placed item. */
export function tint(node: Object3D, model: string, color: Color): void {
  const mean = MODELS[model]?.mean ?? [0.5, 0.5, 0.5];
  const t = normalised(color, mean);
  const gain = Math.max(t.r, t.g, t.b);
  if (gain > MAX_GAIN) t.multiplyScalar(MAX_GAIN / gain);
  node.traverse((o) => {
    const mesh = o as Mesh;
    if (!mesh.isMesh) return;
    if (!mesh.userData.ownsMaterial) {
      mesh.material = Array.isArray(mesh.material) ? mesh.material.map((m) => m.clone()) : mesh.material.clone();
      mesh.userData.ownsMaterial = true;
    }
    for (const m of Array.isArray(mesh.material) ? mesh.material : [mesh.material]) {
      if ((m as MeshStandardMaterial).isMeshStandardMaterial) (m as MeshStandardMaterial).color.copy(t);
    }
  });
}

/** Meshes that should not throw shadows (a lamp fitting around its own bulb). */
export function setCastsShadow(node: Object3D, casts: boolean): void {
  node.traverse((o) => { if ((o as Mesh).isMesh) o.castShadow = casts; });
}

/**
 * Poly Haven packs AO, roughness and metalness into one "ARM" texture. The
 * glTF references it for roughness/metal only; wire its red channel up as
 * ambient occlusion too, as the Godot project does.
 */
function enableBakedAo(root: Object3D): void {
  root.traverse((o) => {
    const mesh = o as Mesh;
    if (!mesh.isMesh) return;
    for (const m of Array.isArray(mesh.material) ? mesh.material : [mesh.material]) {
      const sm = m as MeshStandardMaterial;
      if (sm.isMeshStandardMaterial && sm.roughnessMap && sm.roughnessMap === sm.metalnessMap) {
        sm.aoMap = sm.roughnessMap;
      }
    }
  });
}
