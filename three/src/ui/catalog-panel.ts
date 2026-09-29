// The side panel: tools, room size, catalogue, selected-item controls, paint
// swatches, light sliders. ← catalog_panel.gd
//
// Plain DOM, no framework: the panel is small, and a framework's runtime
// would count against this stack in the bundle-size comparison.

import { Color } from 'three';
import type { Catalog } from '../catalog/catalog';
import type { FurnitureItem } from '../catalog/furniture-item';
import { luminance, toHex } from '../color';
import { SWATCHES } from '../paint/painter';
import type { PlacedItem } from '../placement/placed-item';
import type { LightingSettings } from '../room/lighting';
import { MAX_HEIGHT, MIN_HEIGHT } from '../room/room-builder';
import type { WallOpening } from '../room/wall-opening';

export enum Tool { PLACE, PAINT, WALK, LIGHT }
export const TOOL_NAMES = ['Place', 'Paint', 'Walk', 'Light'];

export interface PanelEvents {
  toolSelected(tool: Tool): void;
  itemChosen(item: FurnitureItem): void;
  snapCycled(): void;
  rotatePressed(): void;
  deletePressed(): void;
  finishChosen(key: string): void;
  swatchChosen(color: Color): void;
  paintAllPressed(): void;
  uploadPressed(): void;
  clearPressed(): void;
  cartPressed(): void;
  lightChanged(group: 'sun' | 'ambient' | 'ceiling', key: string, value: number | boolean): void;
  lampChanged(key: 'on' | 'energy' | 'warmth', value: number | boolean): void;
  addLampPressed(): void;
  roomSizeChanged(width: number, depth: number, height: number): void;
  ceilingToggled(on: boolean): void;
}

function el<K extends keyof HTMLElementTagNameMap>(tag: K, cls = '', text = ''): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text) e.textContent = text;
  return e;
}

function button(text: string, onClick: () => void, cls = 'btn'): HTMLButtonElement {
  const b = el('button', cls, text);
  b.type = 'button';
  b.addEventListener('click', onClick);
  return b;
}

export class CatalogPanel {
  readonly root = el('aside', 'panel');
  private toolButtons: HTMLButtonElement[] = [];
  private snapBtn!: HTMLButtonElement;
  private itemsBox = el('div', 'items');
  private selectedBox = el('div', 'section selected');
  private selectedLabel = el('div', 'selected-label');
  private rotateBtn!: HTMLButtonElement;
  private finishSel = el('select', 'finish');
  private lampBox = el('div', 'lamp');
  private catalogBox = el('div', 'section grow');
  private paintBox = el('div', 'section grow');
  private walkBox = el('div', 'section grow');
  private lightBox = el('div', 'section grow');
  private swatchButtons = new Map<string, HTMLButtonElement>();
  private paintLabel = el('div', 'hint');
  private picker = el('input');
  private controls = new Map<string, HTMLInputElement>();
  private syncing = false;
  private roomW!: HTMLInputElement;
  private roomD!: HTMLInputElement;
  private roomH!: HTMLInputElement;
  private ceilingBox!: HTMLInputElement;

  constructor(private catalog: Catalog, private ev: PanelEvents, onWeb = true) {
    const r = this.root;
    r.append(el('h1', '', 'Room Planner'));

    const tools = el('div', 'row tools');
    TOOL_NAMES.forEach((name, i) => {
      const b = button(name, () => ev.toolSelected(i));
      this.toolButtons.push(b);
      tools.append(b);
    });
    r.append(tools);

    const size = el('div', 'row');
    size.append(el('span', 'label', 'Room'));
    this.roomW = this.metres(size, 6);
    size.append(el('span', '', '×'));
    this.roomD = this.metres(size, 5);
    size.append(el('span', '', 'm'));
    r.append(size);
    const height = el('div', 'row');
    height.append(el('span', 'label', 'Height'));
    this.roomH = this.metres(height, 2.7, MIN_HEIGHT, MAX_HEIGHT, 0.05);
    height.append(el('span', '', 'm'));
    this.ceilingBox = this.checkbox(height, 'Ceiling', '', false, (v) => ev.ceilingToggled(v));
    this.ceilingBox.title = 'A ceiling blocks the sun: light comes in through the windows';
    r.append(height);

    // Selected item (Place and Light): furniture gets finishes, lamps get dimmers.
    this.selectedBox.append(this.selectedLabel);
    const actions = el('div', 'row');
    this.rotateBtn = button('Rotate', () => ev.rotatePressed());
    actions.append(this.rotateBtn, button('Remove', () => ev.deletePressed()));
    this.selectedBox.append(actions);
    this.finishSel.addEventListener('change', () => ev.finishChosen(this.finishSel.value));
    this.selectedBox.append(this.finishSel);
    this.checkbox(this.lampBox, 'On', 'lamp/on', true, (v) => ev.lampChanged('on', v));
    this.slider(this.lampBox, 'Brightness', 'lamp/energy', 0, 1, 0.6, (v) => ev.lampChanged('energy', v));
    this.slider(this.lampBox, 'Warmth', 'lamp/warmth', 0, 1, 0.7, (v) => ev.lampChanged('warmth', v));
    this.selectedBox.append(this.lampBox);
    this.selectedBox.hidden = true;
    r.append(this.selectedBox);

    this.snapBtn = button('Snap: Grid 25 cm', () => ev.snapCycled());
    this.catalogBox.append(this.snapBtn, el('div', 'heading', 'Catalogue'), this.itemsBox,
      button('Upload model (.glb)', () => ev.uploadPressed()));
    r.append(this.catalogBox);
    this.refreshItems();

    this.paintBox.append(el('div', 'hint', 'Tap a wall or the floor to paint it'));
    const grid = el('div', 'swatches');
    for (const [name, hex] of SWATCHES) {
      const b = button('', () => ev.swatchChosen(new Color(hex)), 'swatch');
      b.style.background = hex;
      b.title = name;
      b.style.setProperty('--ink', luminance(new Color(hex)) < 0.5 ? '#fff' : '#262626');
      grid.append(b);
      this.swatchButtons.set(hex, b);
    }
    this.paintBox.append(grid, this.paintLabel);
    this.picker.type = 'color';
    this.picker.className = 'picker';
    this.picker.value = '#b7c4a8';
    this.picker.addEventListener('input', () => ev.swatchChosen(new Color(this.picker.value)));
    const pickRow = el('label', 'row');
    pickRow.append(this.picker, el('span', '', 'Custom colour'));
    this.paintBox.append(pickRow, button('Paint all walls', () => ev.paintAllPressed()));
    this.setPaintColor(new Color('#b7c4a8'));
    r.append(this.paintBox);

    const L = this.lightBox;
    L.append(el('div', 'heading', 'Sun'));
    this.slider(L, 'Height', 'sun/elevation', 10, 80, 55, (v) => ev.lightChanged('sun', 'elevation', v));
    this.slider(L, 'Direction', 'sun/azimuth', 0, 360, 330, (v) => ev.lightChanged('sun', 'azimuth', v));
    this.slider(L, 'Brightness', 'sun/energy', 0, 1, 0.5, (v) => ev.lightChanged('sun', 'energy', v));
    this.slider(L, 'Warmth', 'sun/warmth', 0, 1, 0.35, (v) => ev.lightChanged('sun', 'warmth', v));
    this.slider(L, 'Bounce', 'ambient/energy', 0, 1, 0.3, (v) => ev.lightChanged('ambient', 'energy', v));
    this.checkbox(L, 'Ceiling light', 'ceiling/on', false, (v) => ev.lightChanged('ceiling', 'on', v));
    this.slider(L, 'Brightness', 'ceiling/energy', 0, 1, 0.5, (v) => ev.lightChanged('ceiling', 'energy', v));
    this.slider(L, 'Warmth', 'ceiling/warmth', 0, 1, 0.6, (v) => ev.lightChanged('ceiling', 'warmth', v));
    L.append(button('Add floor lamp', () => ev.addLampPressed()),
      el('div', 'hint', 'Tap a lamp to dim it or remove it; drag it to move it.'));
    r.append(L);

    this.walkBox.append(el('div', 'hint',
      'Click the room to look around. WASD to walk, E to pick up or put down. Esc frees the mouse.'));
    r.append(this.walkBox);

    r.append(button('Clear room', () => ev.clearPressed()),
      button(onWeb ? 'Add room to cart' : 'Print layout JSON', () => ev.cartPressed()));
    this.setTool(Tool.PLACE);
  }

  private metres(parent: HTMLElement, value: number, lo = 2, hi = 12, step = 0.1): HTMLInputElement {
    const i = el('input', 'num');
    i.type = 'number';
    i.min = String(lo);
    i.max = String(hi);
    i.step = String(step);
    i.value = String(value);
    i.addEventListener('change', () => {
      if (this.syncing) return;
      const clamp = (x: HTMLInputElement) => Math.min(Math.max(Number(x.value) || Number(x.min), Number(x.min)), Number(x.max));
      this.ev.roomSizeChanged(clamp(this.roomW), clamp(this.roomD), clamp(this.roomH));
    });
    parent.append(i);
    return i;
  }

  private slider(parent: HTMLElement, text: string, key: string, lo: number, hi: number, value: number,
    cb: (v: number) => void): HTMLInputElement {
    const row = el('label', 'row slider');
    row.append(el('span', 'label', text));
    const s = el('input');
    s.type = 'range';
    s.min = String(lo);
    s.max = String(hi);
    s.step = String((hi - lo) / 100);
    s.value = String(value);
    s.addEventListener('input', () => { if (!this.syncing) cb(Number(s.value)); });
    row.append(s);
    parent.append(row);
    this.controls.set(key, s);
    return s;
  }

  private checkbox(parent: HTMLElement, text: string, key: string, value: boolean, cb: (v: boolean) => void): HTMLInputElement {
    const row = el('label', 'row check');
    const c = el('input');
    c.type = 'checkbox';
    c.checked = value;
    c.addEventListener('change', () => { if (!this.syncing) cb(c.checked); });
    row.append(c, el('span', '', text));
    parent.append(row);
    if (key) this.controls.set(key, c);
    return c;
  }

  setRoomSize(width: number, depth: number, height: number, ceiling: boolean): void {
    this.syncing = true;
    this.roomW.value = String(width);
    this.roomD.value = String(depth);
    this.roomH.value = String(height);
    this.ceilingBox.checked = ceiling;
    this.syncing = false;
  }

  setLighting(settings: LightingSettings): void {
    this.syncing = true;
    for (const [group, values] of Object.entries(settings)) {
      for (const [key, v] of Object.entries(values as Record<string, number | boolean>)) this.setControl(`${group}/${key}`, v);
    }
    this.syncing = false;
  }

  private setControl(key: string, v: number | boolean): void {
    const c = this.controls.get(key);
    if (!c) return;
    if (c.type === 'checkbox') c.checked = Boolean(v);
    else c.value = String(v);
  }

  /** Mark the swatch in use and name it; a custom colour shows as its hex. */
  setPaintColor(color: Color): void {
    const hex = toHex(color);
    let name = hex;
    for (const [k, b] of this.swatchButtons) {
      const on = k === hex;
      b.classList.toggle('on', on);
      if (on) name = b.title;
    }
    this.paintLabel.textContent = 'Selected: ' + name;
    this.picker.value = hex;
  }

  refreshItems(): void {
    this.itemsBox.replaceChildren();
    const architecture: FurnitureItem[] = [];
    for (const it of this.catalog.items) {
      if (it.isLight()) continue; // fixtures are added from the Light tool
      if (it.isOpening()) { architecture.push(it); continue; }
      this.itemButton(it);
    }
    if (architecture.length === 0) return;
    this.itemsBox.append(el('div', 'heading', 'Architecture'));
    for (const it of architecture) this.itemButton(it);
  }

  private itemButton(it: FurnitureItem): void {
    const cm = (m: number) => Math.round(m * 100);
    let dims = `${cm(it.size.x)} × ${cm(it.size.z)} × ${cm(it.size.y)} cm`;
    if (it.isOpening()) {
      dims = `${cm(it.size.x)} × ${cm(it.size.y)} cm`;
      if (it.sill > 0) dims += `, sill ${cm(it.sill)} cm`;
    }
    const b = button('', () => this.ev.itemChosen(it), 'item');
    b.dataset.id = it.id;
    b.append(el('strong', '', it.name), el('small', '', dims + (it.estimated ? '  (est.)' : '')));
    this.itemsBox.append(b);
  }

  setTool(tool: Tool): void {
    this.toolButtons.forEach((b, i) => b.classList.toggle('on', i === tool));
    this.catalogBox.hidden = tool !== Tool.PLACE;
    this.paintBox.hidden = tool !== Tool.PAINT;
    this.walkBox.hidden = tool !== Tool.WALK;
    this.lightBox.hidden = tool !== Tool.LIGHT;
    if (tool !== Tool.PLACE && tool !== Tool.LIGHT) this.selectedBox.hidden = true;
  }

  setSnapName(n: string): void {
    this.snapBtn.textContent = 'Snap: ' + n;
  }

  showSelected(p: PlacedItem | null): void {
    if (!p) { this.selectedBox.hidden = true; return; }
    this.selectedBox.hidden = false;
    this.rotateBtn.disabled = false;
    this.selectedLabel.textContent = p.item.name + (p.valid ? '' : '  — doesn\'t fit here');
    if (p.item.isLight()) {
      this.finishSel.hidden = true;
      this.lampBox.hidden = false;
      this.syncing = true;
      this.setControl('lamp/on', p.light.on);
      this.setControl('lamp/energy', p.light.energy);
      this.setControl('lamp/warmth', p.light.warmth);
      this.syncing = false;
      return;
    }
    this.lampBox.hidden = true;
    const keys = p.item.finishChoices(this.catalog.finishes);
    this.finishSel.replaceChildren(...keys.map((k) => {
      const o = el('option', '', this.catalog.finishes[k]?.name ?? k);
      o.value = k;
      return o;
    }));
    this.finishSel.value = p.finish;
    this.finishSel.hidden = keys.length === 0;
  }

  /** A window or door: nothing to rotate, no timber, no light -- just remove. */
  showOpening(op: WallOpening | null): void {
    if (!op) { this.selectedBox.hidden = true; return; }
    this.selectedBox.hidden = false;
    this.rotateBtn.disabled = true;
    this.selectedLabel.textContent = op.item.name + (op.valid ? '' : '  — doesn\'t fit here');
    this.finishSel.hidden = true;
    this.lampBox.hidden = true;
  }
}
