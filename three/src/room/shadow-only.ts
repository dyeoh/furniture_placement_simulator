// Meshes drawn only into shadow maps: cut-away walls, their window frames and
// the planner-view ceiling. Godot calls this SHADOW_CASTING_SETTING_SHADOWS_ONLY.
//
// Not a render layer: three's shadow pass tests object layers against the
// *viewing* camera (WebGLShadowMap.renderObject), so a layer the view does not
// see never reaches a shadow map either. Instead the mesh keeps its layer and
// swaps to a material that writes neither colour nor depth; the shadow pass
// draws it with its own depth material regardless.

import { Mesh, MeshBasicMaterial, type Material } from 'three';

const HIDDEN = new MeshBasicMaterial({ colorWrite: false, depthWrite: false });
HIDDEN.name = 'shadow-only';

export function setShadowOnly(mesh: Mesh, on: boolean): void {
  const saved = mesh.userData.shadowOnlySaved as Material | Material[] | undefined;
  if (on && !saved) {
    mesh.userData.shadowOnlySaved = mesh.material;
    mesh.material = HIDDEN;
  } else if (!on && saved) {
    mesh.material = saved;
    delete mesh.userData.shadowOnlySaved;
  }
}
