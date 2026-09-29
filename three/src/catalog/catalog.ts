// The list of things that can be placed. ← catalog.gd
//
// Loaded from data/catalog.json (the Godot project's own file). The host page
// can replace it with the live collection. Fixtures -- a floor lamp, windows,
// a door -- are appended to every catalogue and never reach the cart.

import { Color } from 'three';
import { srgb } from '../color';
import { FurnitureItem, type Finishes, type ItemDict } from './furniture-item';

export const FIXTURES: ItemDict[] = [
  { id: 'floor-lamp', name: 'Floor lamp', size_mm: [420, 420, 1600], mass: 6,
    wall_snap: false, variant_id: 0, shape: 'lamp', color: '#e8e0d0' },
  { id: 'window', name: 'Window', size_mm: [1200, 150, 1200], sill_mm: 900,
    variant_id: 0, shape: 'window', color: '#f4f2ee' },
  { id: 'tall-window', name: 'Tall window', size_mm: [900, 150, 2000], sill_mm: 100,
    variant_id: 0, shape: 'window', color: '#f4f2ee' },
  { id: 'wide-window', name: 'Wide window', size_mm: [2400, 150, 1400], sill_mm: 700,
    variant_id: 0, shape: 'window', color: '#f4f2ee' },
  { id: 'door', name: 'Door', size_mm: [900, 150, 2100], sill_mm: 0,
    variant_id: 0, shape: 'door', color: '#f4f2ee' },
];

export interface CatalogDict { finishes?: Finishes; items?: ItemDict[] }

export class Catalog {
  items: FurnitureItem[] = [];
  finishes: Finishes = {};
  onChanged: (() => void) | null = null;

  static async fetchDefault(url = 'data/catalog.json'): Promise<CatalogDict> {
    const res = await fetch(url);
    if (!res.ok) throw new Error(`Catalog: cannot load ${url} (${res.status})`);
    return res.json();
  }

  loadDict(data: CatalogDict): void {
    if (data.finishes) this.finishes = data.finishes;
    this.items = [];
    for (const d of data.items ?? []) {
      if (d && typeof d === 'object') this.items.push(FurnitureItem.fromDict(d, this.finishes));
    }
    for (const f of FIXTURES) this.items.push(FurnitureItem.fromDict(f, this.finishes));
    this.onChanged?.();
  }

  find(id: string): FurnitureItem | null {
    return this.items.find((it) => it.id === id) ?? null;
  }

  finishColor(key: string): Color {
    const f = this.finishes[key];
    return f ? new Color(f.color ?? '#c0a080') : srgb(0.75, 0.63, 0.5);
  }
}
