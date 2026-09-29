// Turn an uploaded GLB/glTF into a catalogue item. ← model_loader.gd
//
// The visual is the model's own scene; the collider is a box the size of its
// bounding box, which settles more predictably than a hull of a hollow piece.
// Models exported in millimetres are common for furniture, so anything
// absurdly large is taken to be mm and scaled down by 1000.

import { Box3, Group, Mesh, Vector3 } from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { srgb } from '../color';
import { FurnitureItem } from './furniture-item';

const MM_THRESHOLD = 50;

export async function fromBuffer(buffer: ArrayBuffer, fileName: string): Promise<FurnitureItem | null> {
  let gltf;
  try {
    gltf = await new GLTFLoader().parseAsync(buffer, '');
  } catch (e) {
    console.warn('ModelLoader: glTF parse failed', e);
    return null;
  }
  const root = gltf.scene;
  root.updateMatrixWorld(true);
  const bounds = new Box3().setFromObject(root, true);
  if (bounds.isEmpty()) {
    console.warn('ModelLoader: model has no mesh geometry');
    return null;
  }
  const raw = bounds.getSize(new Vector3());
  const scale = Math.max(raw.x, raw.y, raw.z) > MM_THRESHOLD ? 0.001 : 1;
  const size = raw.multiplyScalar(scale);
  const centre = bounds.getCenter(new Vector3()).multiplyScalar(scale);

  // Wrap so the collider's centre is the item's origin wherever the pivot is.
  const wrapper = new Group();
  wrapper.name = 'Model';
  root.scale.multiplyScalar(scale);
  root.position.sub(centre);
  wrapper.add(root);
  wrapper.traverse((o) => { if ((o as Mesh).isMesh) { o.castShadow = true; o.receiveShadow = true; } });

  const base = fileName.replace(/\.[^.]+$/, '');
  const it = new FurnitureItem();
  it.id = 'upload-' + base.toLowerCase().replace(/ /g, '-');
  it.name = base;
  it.size.copy(size);
  // Roughly a solid-ish timber piece; uploads carry no mass.
  it.mass = Math.min(Math.max(size.x * size.y * size.z * 120, 3), 150);
  it.wallSnap = size.y > 0.9;
  it.color = srgb(0.8, 0.8, 0.8);
  it.meshScene = wrapper;
  return it;
}

/** Ask for a .glb / .gltf file; resolves to null when the picker is dismissed. */
export function pickFile(): Promise<File | null> {
  return new Promise((resolve) => {
    const i = document.createElement('input');
    i.type = 'file';
    i.accept = '.glb,.gltf,model/gltf-binary';
    i.style.display = 'none';
    i.addEventListener('change', () => { resolve(i.files?.[0] ?? null); i.remove(); });
    i.addEventListener('cancel', () => { resolve(null); i.remove(); });
    document.body.append(i);
    i.click();
  });
}
