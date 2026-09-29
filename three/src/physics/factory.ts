// Backend choice: `?physics=box3d|rapier`, `B` to swap. ← physics_factory.gd
//
// Each engine is its own dynamic import, so the bundle and load metrics only
// ever count the one in use.

import type { PhysicsBackend } from './backend';

export type BackendKind = 'box3d' | 'rapier';

export function initialKind(): BackendKind {
  const q = new URLSearchParams(location.search).get('physics');
  return q === 'rapier' ? 'rapier' : 'box3d';
}

export function other(kind: BackendKind): BackendKind {
  return kind === 'box3d' ? 'rapier' : 'box3d';
}

export async function createBackend(kind: BackendKind): Promise<PhysicsBackend> {
  if (kind === 'rapier') {
    const { RapierBackend } = await import('./rapier');
    return RapierBackend.create();
  }
  const [{ Box3DBackend }, { default: wasmUrl }] = await Promise.all([
    import('./box3d'), import('./box3d/box3d.wasm?url')]);
  return Box3DBackend.create({ locateFile: () => wasmUrl });
}
