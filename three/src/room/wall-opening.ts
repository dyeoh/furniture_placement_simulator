// A window or door set into one wall. ← wall_opening.gd
//
// Architecture, not furniture: no body, never reaches the cart. Placement is
// one number, [offset] along the wall's run (X for north/south, Z for
// east/west); height comes from the catalogue's sill.

import { BoxGeometry, Group, Mesh, MeshBasicMaterial, Object3D, Vector2, Vector3 } from 'three';
import type { FurnitureItem } from '../catalog/furniture-item';
import { build } from '../catalog/furniture-shapes';
import { setShadowOnly } from './shadow-only';
import { srgb } from '../color';

export type Wall = 'north' | 'east' | 'south' | 'west';

export interface OpeningDict { id: string; wall: string; offset: number }

export class WallOpening {
  wall: Wall = 'north';
  offset = 0;
  valid = true;
  /** Being dragged (new from the catalogue, or lifted off a wall). */
  ghost = false;
  node: Group | null = null;
  /** On a cut-away wall: hidden, except the frame keeps casting its shadow. */
  cut = false;
  private tintMesh: Mesh | null = null;
  private tintMat: MeshBasicMaterial | null = null;

  constructor(public item: FurnitureItem) {}

  width(): number { return this.item.size.x; }
  height(): number { return this.item.size.y; }
  sill(): number { return this.item.sill; }
  head(): number { return this.item.sill + this.item.size.y; }
  cutsWall(): boolean { return this.item.shapeKind === 'window'; }

  /** Along-wall span [lo, hi]. */
  span(): Vector2 {
    return new Vector2(this.offset - this.width() * 0.5, this.offset + this.width() * 0.5);
  }

  toDict(): OpeningDict {
    return { id: this.item.id, wall: this.wall, offset: Math.round(this.offset * 1000) / 1000 };
  }

  /** Frame, glass or leaf in the wall's frame, local +Z into the room. */
  buildVisual(parent: Object3D, wallThickness: number): void {
    this.freeVisual();
    this.node = new Group();
    this.node.name = 'Opening_' + this.item.id;
    parent.add(this.node);
    const size = new Vector3(this.width(), this.height(), wallThickness);
    this.node.add(build(this.item.shapeKind, size, null));
    this.tintMat = new MeshBasicMaterial({ transparent: true, depthWrite: false });
    this.tintMesh = new Mesh(new BoxGeometry(size.x + 0.04, size.y + 0.04, size.z + 0.04), this.tintMat);
    this.tintMesh.castShadow = false;
    this.node.add(this.tintMesh);
    this.setCut(this.cut);
  }

  setCut(cut: boolean): void {
    this.cut = cut;
    if (!this.node) return;
    this.node.traverse((o) => {
      if (!(o as Mesh).isMesh || o === this.tintMesh) return;
      if (o.userData.caster) {
        // Shadow only: the sun patch on the floor keeps its window bars.
        setShadowOnly(o as Mesh, cut);
      } else {
        o.visible = !cut;
      }
    });
    this.setTint(this.ghost || !this.valid, this.valid);
  }

  /** Same colours as PlacedItem: green fits, red does not, yellow selected. */
  setTint(show: boolean, ok: boolean): void {
    if (!this.tintMesh || !this.tintMat) return;
    this.tintMesh.visible = show && !this.cut;
    this.tintMat.color.copy(ok ? srgb(0.3, 0.9, 0.4) : srgb(0.95, 0.3, 0.25));
    this.tintMat.opacity = ok ? 0.35 : 0.4;
  }

  setHighlight(on: boolean): void {
    if (!this.tintMesh || !this.tintMat) return;
    if (on) {
      this.tintMesh.visible = !this.cut;
      this.tintMat.color.copy(srgb(1, 0.85, 0.3));
      this.tintMat.opacity = 0.25;
    } else {
      this.setTint(this.ghost || !this.valid, this.valid);
    }
  }

  freeVisual(): void {
    if (this.node) {
      this.node.removeFromParent();
      disposeTree(this.node);
    }
    this.node = null;
    this.tintMesh = null;
    this.tintMat = null;
  }
}

/** Free the GPU buffers of a subtree built by us (never shared glTF data). */
export function disposeTree(root: Object3D): void {
  root.traverse((o) => {
    const m = o as Mesh;
    if (m.isMesh) m.geometry.dispose();
  });
}
