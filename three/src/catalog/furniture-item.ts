// One catalogue entry: what a piece of furniture *is*. ← furniture_item.gd
//
// Sizes are metres, X = width, Y = height, Z = depth -- scene axes, not the
// store's W x D x H order. The conversion happens once, here.

import { Color, Vector3 } from 'three';
import type { BoxShape } from '../physics/backend';
import { forName as modelForName } from './model-names';

export interface FinishDef { name?: string; color?: string }
export type Finishes = Record<string, FinishDef>;

export interface ItemDict {
  id?: string; name?: string;
  size_mm?: number[]; size?: number[];
  mass?: number; wall_snap?: boolean; variant_id?: number;
  variants?: Record<string, number>;
  estimated?: boolean; finish?: string; color?: string;
  model?: string; shape?: string; sill_mm?: number; sill?: number;
}

export class FurnitureItem {
  id = '';
  name = '';
  /** Full extents in metres (width, height, depth). */
  size = new Vector3(1, 1, 1);
  mass = 10;
  /** Pull flush to the nearest wall in wall-magnet snap mode. */
  wallSnap = false;
  /** Shopify variant when [variants] has no entry for the chosen finish; 0 = not for sale. */
  variantId = 0;
  /** Shopify variant per finish key. */
  variants: Record<string, number> = {};
  /** Key into Catalog.finishes; drives the tint. */
  finish = '';
  color = new Color(0.8, 0.7, 0.55);
  estimated = false;
  /** Generic CC0 model (ModelLibrary key) fitted to [size]; '' = use [shapeKind]. */
  model = '';
  /** Generated geometry (bed, rack, lamp, window, door); '' = plain slab. */
  shapeKind = '';
  /** Openings only: bottom edge height above the floor, metres. */
  sill = 0;
  /** An uploaded model's scene (ModelLoader), cloned per placed piece; null for catalogue items. */
  meshScene: import('three').Object3D | null = null;

  static fromDict(d: ItemDict, finishes: Finishes): FurnitureItem {
    const it = new FurnitureItem();
    it.id = String(d.id ?? '');
    it.name = String(d.name ?? it.id);
    if (d.size_mm) {
      const mm = d.size_mm;
      it.size.set(mm[0], mm[2], mm[1]).multiplyScalar(0.001);
    } else if (d.size) {
      it.size.set(d.size[0], d.size[1], d.size[2]);
    }
    it.mass = Number(d.mass ?? 10);
    it.wallSnap = Boolean(d.wall_snap ?? false);
    it.variantId = Number(d.variant_id ?? 0);
    for (const [k, v] of Object.entries(d.variants ?? {})) it.variants[k] = Number(v);
    it.estimated = Boolean(d.estimated ?? false);
    it.finish = String(d.finish ?? '');
    // A default finish the product cannot be bought in would put the wrong
    // variant in the cart, so fall back to the first one it comes in.
    const keys = Object.keys(it.variants);
    if (keys.length > 0 && !(it.finish in it.variants)) it.finish = keys[0];
    if (finishes[it.finish]) it.color = new Color(finishes[it.finish].color ?? '#c0a080');
    else if (d.color) it.color = new Color(d.color);
    it.model = String(d.model ?? '');
    it.shapeKind = String(d.shape ?? '');
    it.sill = d.sill_mm !== undefined ? d.sill_mm * 0.001 : Number(d.sill ?? 0);
    if (it.model === '' && it.shapeKind === '') {
      it.shapeKind = FurnitureItem.shapeForName(it.name);
      if (it.shapeKind === '') it.model = modelForName(it.name);
    }
    return it;
  }

  /** Pieces that get generated geometry rather than a generic model. */
  static shapeForName(name: string): string {
    const n = name.toLowerCase();
    if (n.includes('lamp')) return 'lamp';
    if (n.includes('rack')) return 'rack';
    if (n.includes('bed') && !n.includes('bedside')) return 'bed';
    return '';
  }

  isLight(): boolean {
    return this.shapeKind === 'lamp';
  }

  /** A window or door: placed in a wall by Openings, not on the floor by Placer. */
  isOpening(): boolean {
    return this.shapeKind === 'window' || this.shapeKind === 'door';
  }

  variantFor(finishKey: string): number {
    return this.variants[finishKey] ?? this.variantId;
  }

  /** Finishes the picker offers: those the store sells this piece in, or all. */
  finishChoices(all: Finishes): string[] {
    const keys = Object.keys(this.variants);
    if (keys.length === 0) return Object.keys(all);
    return Object.keys(all).filter((k) => k in this.variants);
  }

  volume(): number {
    return Math.max(this.size.x * this.size.y * this.size.z, 1e-4);
  }

  /** Collider with density from the catalogue mass: a 70 kg bed and an 8 kg side table differ. */
  bodyShape(): BoxShape {
    return { size: this.size.clone(), density: this.mass / this.volume(), friction: 0.8 };
  }
}
