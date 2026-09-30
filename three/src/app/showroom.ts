// The showroom: one room, a catalogue, four tools. ← showroom.gd
//
//   Place  drag furniture in from the catalogue, rotate, drop; it settles.
//          Windows and doors slide along the walls instead.
//   Paint  pick a swatch, tap a wall or the floor.
//   Walk   first person: WASD, mouse look, E to carry / drop, bump into things.
//   Light  swing the sun, dim the ambient and ceiling light, add floor lamps.
//
// Keys: 1-4 tools, Tab cycles, R rotate, S snap, Delete remove, Esc cancel,
// B swap physics backend (Box3D <-> Rapier, same layout), [ ] shove force.
// Right-drag orbits, wheel zooms; on touch one finger orbits, two pinch.
//
// Everything physical goes through the PhysicsBackend seam; this file owns
// the renderer, cameras, input and wiring only.

import {
  AgXToneMapping, Group, Object3D, PCFShadowMap, PerspectiveCamera,
  Ray, Raycaster, Scene, Vector2, Vector3, WebGLRenderer,
} from 'three';
import { Catalog } from '../catalog/catalog';
import type { FurnitureItem } from '../catalog/furniture-item';
import { Painter } from '../paint/painter';
import type { PhysicsBackend } from '../physics/backend';
import { createBackend, other, type BackendKind } from '../physics/factory';
import * as Layout from '../placement/layout';
import { lampShadows, State, type PlacedItem } from '../placement/placed-item';
import { floorHit, Placer } from '../placement/placer';
import { Lighting } from '../room/lighting';
import { Openings } from '../room/openings';
import { DimensionLines } from '../room/dimension-lines';
import * as ModelLoader from '../catalog/model-loader';
import { MAX_HEIGHT, MIN_HEIGHT, RoomBuilder } from '../room/room-builder';
import { setMaxAnisotropy } from '../room/surface-materials';
import { disposeTree, type WallOpening } from '../room/wall-opening';
import { CatalogPanel, Tool, TOOL_NAMES } from '../ui/catalog-panel';
import { TouchControls, touchWanted } from '../ui/touch-controls';
import { Shopper } from '../walkthrough/shopper';
import { HostBridge, queryParam } from '../web/host-bridge';
import { Quality, RENDER_SCALE_LOW } from './quality';

const DEFAULT_ROOM = new Vector2(6, 5);
/** Lamps whose light casts shadows at once: each is a cube map, six extra passes. */
const LAMP_SHADOWS = 2;
const PHYSICS_HZ = 60;
const MAX_PHYSICS_STEPS = 8;

/** The subset of WebGLRenderer the showroom uses, which WebGPURenderer also has. */
export interface AnyRenderer {
  domElement: HTMLCanvasElement;
  setPixelRatio(r: number): void;
  setSize(w: number, h: number, updateStyle?: boolean): void;
  render(scene: Scene, camera: PerspectiveCamera): unknown;
  shadowMap: { enabled: boolean; type: number };
  toneMapping: number;
  toneMappingExposure: number;
  info: { render: { calls?: number; drawCalls?: number; triangles: number }; programs?: unknown[] | null };
  capabilities?: { getMaxAnisotropy(): number };
  compileAsync?(scene: Object3D, camera: PerspectiveCamera): Promise<unknown>;
}

/** Which GPU API actually draws: three's WebGPURenderer falls back to WebGL 2 without an adapter. */
export function rendererKind(r: AnyRenderer): 'webgl' | 'webgpu' | 'webgpu-fallback-webgl2' {
  const backend = (r as unknown as { backend?: { isWebGPUBackend?: boolean } }).backend;
  if (!backend) return 'webgl';
  return backend.isWebGPUBackend ? 'webgpu' : 'webgpu-fallback-webgl2';
}

/**
 * Render one frame of the materials the showroom uses (textured standard
 * material, a shadow-casting light) on an offscreen WebGPU renderer.
 */
export async function webgpuWorks(): Promise<boolean> {
  try {
    const three = await import('three/webgpu');
    const r = new three.WebGPURenderer({ antialias: false });
    await r.init();
    if (!(r as unknown as { backend: { isWebGPUBackend?: boolean } }).backend.isWebGPUBackend) { r.dispose(); return false; }
    r.setSize(64, 64);
    r.shadowMap.enabled = true;
    const scene = new three.Scene();
    const cam = new three.PerspectiveCamera(50, 1, 0.1, 10);
    cam.position.set(0, 0, 3);
    const tex = new three.DataTexture(new Uint8Array([255, 255, 255, 255]), 1, 1);
    tex.needsUpdate = true;
    const mesh = new three.Mesh(new three.BoxGeometry(), new three.MeshStandardMaterial({ map: tex }));
    mesh.castShadow = mesh.receiveShadow = true;
    const light = new three.DirectionalLight(0xffffff, 1);
    light.castShadow = true;
    light.position.set(1, 2, 3);
    scene.add(mesh, light, new three.PointLight(0xffffff, 1));
    await r.renderAsync(scene, cam);
    r.dispose();
    return true;
  } catch (e) {
    console.warn('WebGPU unusable here, falling back to WebGL 2:', e);
    return false;
  }
}

export async function makeRenderer(kind: 'webgl' | 'webgpu'): Promise<AnyRenderer> {
  if (kind === 'webgpu') {
    const { WebGPURenderer } = await import('three/webgpu');
    const r = new WebGPURenderer({ antialias: false });
    await r.init();
    return r as unknown as AnyRenderer;
  }
  // No MSAA: the Godot build runs Compatibility with MSAA off (project.godot).
  return new WebGLRenderer({ antialias: false, powerPreference: 'high-performance' }) as unknown as AnyRenderer;
}

export class Showroom {
  backend!: PhysicsBackend;
  backendKind: BackendKind;
  room = new RoomBuilder();
  catalog = new Catalog();
  placer = new Placer();
  openings = new Openings();
  painter = new Painter();
  shopper = new Shopper();
  bridge = new HostBridge();
  lighting = new Lighting();
  quality = new Quality();

  scene = new Scene();
  camera = new PerspectiveCamera(55, 1, 0.05, 100);
  private visualRoot = new Group();
  private panel!: CatalogPanel;
  private hud = document.createElement('div');
  private hudText = '';
  private touch: TouchControls | null = null;
  private dims: DimensionLines | null = null;
  /** `?ui=0`: no panel, HUD or dimension lines, for look comparisons (compare-look.mjs). */
  private uiHidden = queryParam('ui') === '0';

  tool = Tool.PLACE;
  private yaw = 0.35;
  private pitch = -0.95;
  private dist = 9;
  private orbiting = false;
  private pressDrag = false;
  private selected: PlacedItem | null = null;
  private selectedOpening: WallOpening | null = null;
  private fingers = new Map<number, Vector2>();
  private pinchSpan = 0;
  private keys = new Set<string>();
  private accumulator = 0;
  private lastTime = 0;
  private swapping = false;
  private raycaster = new Raycaster();
  /** Walk intent injected by the bench (x right, z back), in place of keys. */
  benchIntent: Vector3 | null = null;
  /** Physics step milliseconds accumulated since the bench last read them. */
  physicsMs = 0;
  physicsSteps = 0;

  constructor(private host: HTMLElement, public renderer: AnyRenderer, kind: BackendKind) {
    this.backendKind = kind;
  }

  async start(catalogData: import('../catalog/catalog').CatalogDict): Promise<void> {
    const r = this.renderer;
    r.shadowMap.enabled = true;
    // Godot's Compatibility renderer has no soft-shadow filtering; plain PCF matches it.
    r.shadowMap.type = PCFShadowMap;
    r.toneMapping = AgXToneMapping;
    r.toneMappingExposure = 1.15;
    if (r.capabilities) setMaxAnisotropy(Math.min(r.capabilities.getMaxAnisotropy(), 16));
    this.host.append(r.domElement);
    r.domElement.tabIndex = 0;

    this.catalog.loadDict(catalogData);
    this.room.width = DEFAULT_ROOM.x;
    this.room.depth = DEFAULT_ROOM.y;
    this.scene.add(this.visualRoot);
    this.lighting.setup(this.scene, this.scene, this.room.wallHeight);
    this.lighting.onChanged = () => this.onLayoutChanged();
    this.buildUi();

    this.bridge.on('catalog', (d) => {
      this.catalog.loadDict(d as import('../catalog/catalog').CatalogDict);
      this.panel.refreshItems();
    });
    this.bridge.on('layout', (d) => { void this.restoreLayout(d as Layout.LayoutDict); });
    this.bridge.on('clear', () => this.placer.clear());

    this.quality.decide();
    this.quality.onChanged = () => { this.applyQuality(); this.syncLightSources(); };
    this.applyQuality();

    await this.startBackend();
    this.resize();
    window.addEventListener('resize', () => this.resize());
    this.bindInput();
  }

  /** Post "ready" once the first frame is on screen, as the Godot build does after its first scene. */
  announceReady(extra: Record<string, unknown> = {}): void {
    this.bridge.setup({ quality: this.quality.label(), engine: 'three', physics: this.backendKind, ...extra });
  }

  private applyQuality(): void {
    const low = this.quality.low;
    this.renderer.setPixelRatio(devicePixelRatio * (low ? RENDER_SCALE_LOW : 1));
    this.lighting.setLowSpec(low);
    lampShadows.allowed = !low;
    this.resize();
  }

  private resize(): void {
    const w = this.host.clientWidth || innerWidth;
    const h = this.host.clientHeight || innerHeight;
    this.renderer.setSize(w, h, true);
    this.camera.aspect = w / Math.max(h, 1);
    this.camera.updateProjectionMatrix();
  }

  // --- setup

  private buildUi(): void {
    this.panel = new CatalogPanel(this.catalog, {
      toolSelected: (t) => this.setTool(t),
      itemChosen: (it) => this.spawnItem(it),
      snapCycled: () => this.cycleSnap(),
      rotatePressed: () => this.placer.rotate(),
      deletePressed: () => this.deleteSelected(),
      finishChosen: (key) => {
        const p = this.placer.dragging ?? this.selected;
        if (p) this.placer.setFinish(p, key);
      },
      swatchChosen: (c) => { this.painter.color = c.clone(); this.panel.setPaintColor(c); },
      paintAllPressed: () => { this.painter.applyAllWalls(); this.onLayoutChanged(); },
      uploadPressed: () => { void this.upload(); },
      clearPressed: () => this.placer.clear(),
      cartPressed: () => this.bridge.post({ type: 'add_to_cart', items: this.placer.cartLines() }),
      lightChanged: (group, key, value) => {
        if (group === 'sun') this.lighting.setSun(key as 'elevation', Number(value));
        else if (group === 'ambient') this.lighting.setAmbient(Number(value));
        else this.lighting.setCeiling(key as 'on', value);
      },
      lampChanged: (key, value) => {
        const p = this.placer.dragging ?? this.selected;
        if (!p || !p.item.isLight()) return;
        const l = { ...p.light, [key]: value };
        p.setLight(Boolean(l.on), Number(l.energy), Number(l.warmth));
        this.placer.onChanged?.();
      },
      addLampPressed: () => this.spawnItem(this.catalog.find('floor-lamp')),
      roomSizeChanged: (w, d, h) => {
        this.room.width = w;
        this.room.depth = d;
        this.room.wallHeight = Math.min(Math.max(h, MIN_HEIGHT), MAX_HEIGHT);
        this.dist = Math.min(Math.max(Math.max(w, d) * 1.5, 2.5), 20);
        void this.startBackend();
      },
      ceilingToggled: (on) => {
        this.room.setCeiling(on);
        this.syncLightSources();
        this.onLayoutChanged();
      },
    });
    this.host.append(this.panel.root);
    this.panel.setLighting(this.lighting.toDict());
    this.panel.setRoomSize(this.room.width, this.room.depth, this.room.wallHeight, this.room.hasCeiling);
    this.panel.setSnapName(this.placer.snapName());
    this.hud.className = 'hud';
    this.host.append(this.hud);
    if (this.uiHidden) { this.panel.root.hidden = true; this.hud.hidden = true; }

    if (touchWanted()) {
      this.touch = new TouchControls();
      this.touch.onLook = (dx, dy) => this.shopper.turn(dx * 0.005, dy * 0.005);
      this.touch.onInteract = () => this.shopper.interact();
      this.touch.onExit = () => this.setTool(Tool.PLACE);
      this.host.append(this.touch.root);
    }
  }

  /** (Re)build the world on the chosen backend, carrying the layout across. */
  async startBackend(kind: BackendKind = this.backendKind, pending: Layout.LayoutDict | null = null): Promise<void> {
    if (this.swapping) return;
    this.swapping = true;
    try {
      this.openings.cancel();
      let layout = pending;
      if (this.backend) {
        layout ??= this.capture();
        this.shopper.release();
        this.placer.clear();
        this.backend.shutdown();
      }
      for (const c of [...this.visualRoot.children]) { this.visualRoot.remove(c); disposeTree(c); }
      this.room.openings.forEach((op) => { op.node = null; });

      this.backendKind = kind;
      this.backend = await createBackend(kind);
      this.backend.setGravity(new Vector3(0, -9.8, 0));
      this.room.build(this.backend);
      this.room.buildVisuals(this.visualRoot);
      this.dims = new DimensionLines();
      this.visualRoot.add(this.dims);
      this.dims.build(this.room);
      this.openings.setup(this.room, this.catalog);
      this.openings.onChanged = () => this.onLayoutChanged();
      this.lighting.setRoomHeight(this.room.wallHeight);
      this.placer.setup(this.backend, this.room, this.catalog, this.visualRoot);
      this.placer.onChanged = () => this.onLayoutChanged();
      this.painter.setup(this.room);
      this.shopper.setup(this.backend, this.placer, new Vector3(0, 0, this.room.depth * 0.5 - 1));
      if (layout) Layout.restore(layout, this.placer, this.room, this.lighting, this.openings);
      this.syncLightSources();
      this.setTool(this.tool);
    } finally {
      this.swapping = false;
    }
  }

  async restoreLayout(data: Layout.LayoutDict): Promise<void> {
    // A different room size means new walls and bodies: full rebuild.
    const r = data.room ?? {};
    const w = Number(r.width ?? this.room.width);
    const d = Number(r.depth ?? this.room.depth);
    const h = Math.min(Math.max(Number(r.height ?? this.room.wallHeight), MIN_HEIGHT), MAX_HEIGHT);
    const near = (a: number, b: number) => Math.abs(a - b) < 1e-5;
    if (!near(w, this.room.width) || !near(d, this.room.depth) || !near(h, this.room.wallHeight)) {
      this.room.width = w;
      this.room.depth = d;
      this.room.wallHeight = h;
      await this.startBackend(this.backendKind, data);
    } else {
      Layout.restore(data, this.placer, this.room, this.lighting, this.openings);
    }
    this.panel.setLighting(this.lighting.toDict());
    this.panel.setRoomSize(this.room.width, this.room.depth, this.room.wallHeight, this.room.hasCeiling);
  }

  /** Tell Lighting what light the room actually has: ceiling, glass, lamps that are on. */
  private syncLightSources(): void {
    let glass = 0;
    for (const op of this.room.openings) if (op.cutsWall() && op.valid && !op.ghost) glass += op.width() * op.height();
    this.lighting.setRoom(this.room.hasCeiling, glass, this.room.width * this.room.depth,
      Math.hypot(this.room.width, this.room.depth));
    let energy = 0;
    let warm = 0;
    for (const p of this.placer.items) {
      if (p.item.isLight() && p.state !== State.GHOST && p.light.on) {
        energy += p.light.energy;
        warm += p.light.warmth * p.light.energy;
      }
    }
    this.lighting.setLamps(energy, energy > 0 ? warm / energy : 0.7);
    this.pickLampShadows();
  }

  /** Shadows for the LAMP_SHADOWS lit lamps nearest the camera. */
  private pickLampShadows(): void {
    const eye = this.camera.position;
    const lit = this.placer.items
      .filter((p) => p.item.isLight() && p.state !== State.GHOST && p.light.on)
      .sort((a, b) => a.position.distanceToSquared(eye) - b.position.distanceToSquared(eye));
    for (const p of this.placer.items) {
      if (!p.item.isLight()) continue;
      const rank = lit.indexOf(p);
      // A phone shadows one lamp, as the Godot build does (Lighting.PERF "lamps").
      p.setLightShadow(rank >= 0 && rank < (this.touch ? 1 : LAMP_SHADOWS));
    }
  }

  capture(): Layout.LayoutDict {
    return Layout.capture(this.placer, this.room, this.lighting, this.openings);
  }

  // --- tools

  setTool(tool: Tool): void {
    if (this.tool === Tool.WALK && tool !== Tool.WALK) {
      if (document.pointerLockElement) document.exitPointerLock();
      if (this.shopper.carrying) this.shopper.interact();
    }
    this.tool = tool;
    this.panel.setTool(tool);
    if (this.touch) {
      this.touch.visible = tool === Tool.WALK;
      this.panel.root.hidden = this.touch.visible || this.uiHidden;
    }
    if (this.dims) this.dims.visible = tool !== Tool.WALK && !this.uiHidden;
    this.painter.clearHover();
    if (this.placer.backend) this.pickLampShadows();
    if (tool !== Tool.PLACE && this.placer.dragging) this.placer.cancel();
    if (tool !== Tool.PLACE) this.openings.cancel();
    this.select(null);
  }

  private cycleSnap(): void {
    this.placer.cycleSnap();
    this.panel.setSnapName(this.placer.snapName());
    if (this.placer.dragging) this.placer.dragTo(this.placer.dragging.position);
  }

  spawnItem(item: FurnitureItem | null): void {
    if (!item) return;
    if (item.isOpening()) {
      this.setTool(Tool.PLACE);
      if (this.placer.dragging) this.placer.cancel();
      const op = this.openings.begin(item);
      this.pressDrag = false;
      this.selectOpening(op);
      return;
    }
    this.openings.cancel();
    if (this.tool !== Tool.LIGHT || !item.isLight()) this.setTool(Tool.PLACE);
    this.placer.begin(item, new Vector3());
    this.pressDrag = false;
    this.select(this.placer.dragging);
  }

  /** Upload a .glb/.gltf: it joins the catalogue and is picked up straight away. */
  private async upload(): Promise<void> {
    const file = await ModelLoader.pickFile();
    if (!file) return;
    const item = await ModelLoader.fromBuffer(await file.arrayBuffer(), file.name);
    if (!item) return;
    this.catalog.items.push(item);
    this.panel.refreshItems();
    this.spawnItem(item);
  }

  private select(p: PlacedItem | null): void {
    if (this.selectedOpening) { this.selectedOpening.setHighlight(false); this.selectedOpening = null; }
    if (this.selected && this.selected !== p) this.selected.setHighlight(false);
    this.selected = p;
    if (p && p.state !== State.GHOST) p.setHighlight(true);
    this.panel.showSelected(p);
  }

  private selectOpening(op: WallOpening | null): void {
    this.select(null);
    this.selectedOpening = op;
    if (op && !op.ghost) op.setHighlight(true);
    this.panel.showOpening(op);
  }

  private deleteSelected(): void {
    if (this.openings.dragging || this.selectedOpening) {
      this.openings.remove((this.openings.dragging ?? this.selectedOpening)!);
      this.select(null);
      return;
    }
    if (this.placer.dragging) this.placer.remove(this.placer.dragging);
    else if (this.selected) this.placer.remove(this.selected);
    this.select(null);
  }

  // --- input

  private pointerRay(clientX: number, clientY: number): Ray {
    const rect = this.renderer.domElement.getBoundingClientRect();
    const ndc = new Vector2(((clientX - rect.left) / rect.width) * 2 - 1, -((clientY - rect.top) / rect.height) * 2 + 1);
    this.raycaster.setFromCamera(ndc, this.camera);
    return this.raycaster.ray.clone();
  }

  private bindInput(): void {
    const c = this.renderer.domElement;
    c.addEventListener('contextmenu', (e) => e.preventDefault());
    c.addEventListener('wheel', (e) => {
      e.preventDefault();
      if (this.tool === Tool.WALK) return;
      this.dist = Math.min(Math.max(this.dist * (e.deltaY < 0 ? 0.9 : 1.1), 2.5), 20);
    }, { passive: false });
    c.addEventListener('pointerdown', (e) => {
      c.focus();
      if (e.pointerType === 'touch') {
        this.fingers.set(e.pointerId, new Vector2(e.clientX, e.clientY));
        if (this.fingers.size === 2) { this.pinchSpan = this.fingerSpan(); this.orbiting = false; return; }
        if (this.fingers.size > 2) return;
      }
      c.setPointerCapture(e.pointerId);
      this.onPointer('down', e);
    });
    c.addEventListener('pointermove', (e) => {
      if (e.pointerType === 'touch' && this.fingers.has(e.pointerId)) {
        const prev = this.fingers.get(e.pointerId)!;
        const moved = new Vector2(e.clientX - prev.x, e.clientY - prev.y);
        prev.set(e.clientX, e.clientY);
        if (this.fingers.size === 2 && this.tool !== Tool.WALK) {
          const span = this.fingerSpan();
          if (this.pinchSpan > 1 && span > 1) this.dist = Math.min(Math.max(this.dist * this.pinchSpan / span, 2.5), 20);
          this.pinchSpan = span;
          return;
        }
        this.onPointer('move', e, moved);
        return;
      }
      this.onPointer('move', e, new Vector2(e.movementX, e.movementY));
    });
    const up = (e: PointerEvent) => {
      const wasPinch = e.pointerType === 'touch' && this.fingers.size >= 2;
      this.fingers.delete(e.pointerId);
      if (wasPinch) { this.orbiting = false; return; }
      this.onPointer('up', e);
    };
    c.addEventListener('pointerup', up);
    c.addEventListener('pointercancel', up);
    window.addEventListener('keydown', (e) => {
      if ((e.target as HTMLElement)?.tagName === 'INPUT' || (e.target as HTMLElement)?.tagName === 'SELECT') return;
      this.keys.add(e.code);
      if (!e.repeat) this.onKey(e);
    });
    window.addEventListener('keyup', (e) => this.keys.delete(e.code));
    window.addEventListener('blur', () => this.keys.clear());
    document.addEventListener('mousemove', (e) => {
      if (this.tool === Tool.WALK && document.pointerLockElement === c) {
        this.shopper.turn(e.movementX * 0.0035, e.movementY * 0.0035);
      }
    });
  }

  private fingerSpan(): number {
    const [a, b] = [...this.fingers.values()];
    return a.distanceTo(b);
  }

  private onKey(e: KeyboardEvent): void {
    switch (e.code) {
      case 'Digit1': this.setTool(Tool.PLACE); break;
      case 'Digit2': this.setTool(Tool.PAINT); break;
      case 'Digit3': this.setTool(Tool.WALK); break;
      case 'Digit4': this.setTool(Tool.LIGHT); break;
      case 'Tab': e.preventDefault(); this.setTool((this.tool + 1) % TOOL_NAMES.length); break;
      case 'KeyR': this.placer.rotate(); break;
      case 'KeyS': if (this.tool === Tool.PLACE) this.cycleSnap(); break;
      case 'Delete': case 'Backspace': this.deleteSelected(); break;
      case 'Escape':
        if (this.tool === Tool.WALK) break; // the browser releases pointer lock itself
        if (this.openings.dragging) { this.openings.cancel(); this.select(null); }
        else if (this.placer.dragging) { this.placer.cancel(); this.select(null); }
        break;
      case 'KeyB': void this.startBackend(other(this.backendKind)); break;
      case 'BracketLeft': this.shopper.shoveForce = Math.max(50, this.shopper.shoveForce - 50); break;
      case 'BracketRight': this.shopper.shoveForce += 50; break;
      case 'KeyE': if (this.tool === Tool.WALK) this.shopper.interact(); break;
    }
  }

  private orbit(rel: Vector2): void {
    this.yaw -= rel.x * 0.006;
    this.pitch = Math.min(Math.max(this.pitch - rel.y * 0.006, -1.5), -0.15);
  }

  private onPointer(kind: 'down' | 'up' | 'move', e: PointerEvent, rel = new Vector2()): void {
    switch (this.tool) {
      case Tool.PLACE: this.inputPlace(kind, e, rel); break;
      case Tool.PAINT: this.inputPaint(kind, e, rel); break;
      case Tool.WALK: this.inputWalk(kind, e); break;
      case Tool.LIGHT: this.inputLight(kind, e, rel); break;
    }
  }

  private inputPlace(kind: 'down' | 'up' | 'move', e: PointerEvent, rel: Vector2): void {
    if (kind === 'down') {
      if (e.button === 2 || e.button === 1) { this.orbiting = true; return; }
      if (e.button !== 0) return;
      const ray = this.pointerRay(e.clientX, e.clientY);
      if (this.openings.dragging) {
        // Sticky, like furniture: the press lands it, release drops.
        this.openings.dragRay(ray);
        this.pressDrag = true;
      } else if (this.placer.dragging) {
        // A finger gives no motion before the press, so land it under the pointer.
        const hit = floorHit(ray);
        if (hit) this.placer.dragTo(hit);
        this.pressDrag = true;
      } else {
        const hit = this.placer.pick(ray);
        const [opening] = this.openings.pick(ray);
        if (hit && hit.state !== State.CARRIED) {
          this.placer.lift(hit);
          this.pressDrag = true;
          this.select(hit);
        } else if (opening) {
          this.openings.lift(opening);
          this.pressDrag = true;
          this.selectOpening(opening);
        } else {
          this.select(null);
          this.orbiting = true;
        }
      }
    } else if (kind === 'up') {
      if (this.pressDrag && this.openings.dragging) {
        if (this.openings.drop()) this.select(null);
      } else if (this.pressDrag && this.placer.dragging) {
        // Release is the drop. If it does not fit, keep it on the cursor.
        if (this.placer.drop()) this.select(null);
      }
      this.pressDrag = false;
      this.orbiting = false;
    } else if (this.orbiting) {
      this.orbit(rel);
    } else if (this.openings.dragging) {
      this.openings.dragRay(this.pointerRay(e.clientX, e.clientY));
      this.panel.showOpening(this.openings.dragging);
    } else if (this.placer.dragging) {
      const hit = floorHit(this.pointerRay(e.clientX, e.clientY));
      if (hit) {
        this.placer.dragTo(hit);
        this.panel.showSelected(this.placer.dragging);
      }
    }
  }

  private inputPaint(kind: 'down' | 'up' | 'move', e: PointerEvent, rel: Vector2): void {
    if (kind === 'down') {
      if (e.button === 2 || e.button === 1) { this.orbiting = true; return; }
      const surface = this.room.pickSurface(this.pointerRay(e.clientX, e.clientY));
      if (surface) { if (this.painter.apply(surface)) this.onLayoutChanged(); }
      else this.orbiting = true;
    } else if (kind === 'up') {
      this.orbiting = false;
    } else if (this.orbiting) {
      this.orbit(rel);
    } else if (e.pointerType !== 'touch') {
      this.painter.setHover(this.room.pickSurface(this.pointerRay(e.clientX, e.clientY)));
    }
  }

  /** A lamp being dragged behaves as in Place; a press on a placed lamp lifts it. */
  private inputLight(kind: 'down' | 'up' | 'move', e: PointerEvent, rel: Vector2): void {
    if (this.placer.dragging) {
      const p = this.placer.dragging;
      this.inputPlace(kind, e, rel);
      if (!this.placer.dragging && this.placer.items.includes(p)) this.select(p);
      return;
    }
    if (kind === 'down') {
      if (e.button === 2 || e.button === 1) { this.orbiting = true; return; }
      const hit = this.placer.pick(this.pointerRay(e.clientX, e.clientY));
      if (hit && hit.item.isLight() && hit.state !== State.CARRIED) {
        this.placer.lift(hit);
        this.pressDrag = true;
        this.select(hit);
      } else {
        this.select(null);
        this.orbiting = true;
      }
    } else if (kind === 'up') {
      this.orbiting = false;
    } else if (this.orbiting) {
      this.orbit(rel);
    }
  }

  private inputWalk(kind: 'down' | 'up' | 'move', e: PointerEvent): void {
    if (e.pointerType === 'touch' || kind !== 'down') return;
    const c = this.renderer.domElement;
    if (document.pointerLockElement !== c) void c.requestPointerLock();
    else if (e.button === 0) this.shopper.interact();
  }

  private walkIntent(): Vector3 {
    if (this.benchIntent) return this.benchIntent;
    const v = new Vector3();
    const k = this.keys;
    if (k.has('KeyW') || k.has('ArrowUp')) v.z -= 1;
    if (k.has('KeyS') || k.has('ArrowDown')) v.z += 1;
    if (k.has('KeyA') || k.has('ArrowLeft')) v.x -= 1;
    if (k.has('KeyD') || k.has('ArrowRight')) v.x += 1;
    if (this.touch?.visible) { v.x += this.touch.vector.x; v.z += this.touch.vector.y; }
    return v;
  }

  // --- frame

  /** One animation frame: fixed-rate physics like Godot's _physics_process, then render. */
  frame(now: number): void {
    const dt = this.lastTime ? Math.min((now - this.lastTime) / 1000, 0.25) : 1 / PHYSICS_HZ;
    this.lastTime = now;
    if (!this.swapping) {
      const step = 1 / PHYSICS_HZ;
      this.accumulator += dt;
      let n = 0;
      while (this.accumulator >= step && n < MAX_PHYSICS_STEPS) {
        if (this.tool === Tool.WALK) this.shopper.step(this.walkIntent(), step);
        this.backend.step(step);
        this.physicsMs += this.backend.lastStepMs;
        this.physicsSteps += 1;
        this.placer.syncBodies();
        this.placer.update(step);
        this.accumulator -= step;
        n++;
      }
      if (n === MAX_PHYSICS_STEPS) this.accumulator = 0;
    }
    this.quality.watch(dt);
    this.updateCamera();
    this.updateHud();
    this.touch?.setCarrying(this.shopper.carrying !== null);
    const r0 = performance.now();
    this.renderer.render(this.scene, this.camera);
    this.renderMs += performance.now() - r0;
    this.renderFrames++;
  }
  /** CPU time spent in renderer.render() since the bench last read it. */
  renderMs = 0;
  renderFrames = 0;

  /** Planner orbit, set directly (the bench drives the same view on both stacks). */
  setOrbit(yaw: number, pitch: number, dist: number): void {
    this.yaw = yaw;
    this.pitch = pitch;
    this.dist = dist;
  }

  private updateCamera(): void {
    const cam = this.camera;
    if (this.tool === Tool.WALK) {
      cam.position.copy(this.shopper.eye());
      cam.rotation.copy(this.shopper.lookEuler());
      cam.updateMatrixWorld();
      this.room.updateCutaway(new Vector3(), false);
      return;
    }
    cam.rotation.set(this.pitch, this.yaw, 0, 'YXZ');
    cam.position.set(0, 0, this.dist).applyEuler(cam.rotation);
    // Godot's h_offset: slide the view right so the side panel does not cover the room.
    cam.position.addScaledVector(new Vector3(1, 0, 0).applyEuler(cam.rotation), -this.dist * 0.11);
    cam.updateMatrixWorld();
    this.room.updateCutaway(cam.getWorldDirection(new Vector3()), true);
    this.dims?.update(this.room.hiddenWalls);
  }

  private updateHud(): void {
    const lines: string[] = [];
    lines.push(`Backend: ${this.backend?.name ?? '…'}   (B to swap)${this.quality.low ? '   ·   low-spec mode' : ''}`);
    switch (this.tool) {
      case Tool.PLACE:
        lines.push('PLACE — tap a catalogue item, drag, tap to drop');
        lines.push(`Snap: ${this.placer.snapName()} (S)   Rotate: R   Orbit: right-drag`);
        if (this.placer.dragging) {
          lines.push(`Holding ${this.placer.dragging.item.name} — ${this.placer.dragging.valid ? 'fits' : "doesn't fit"}`);
        } else if (this.openings.dragging) {
          lines.push(`Holding ${this.openings.dragging.item.name} — slide it along a wall; ${this.openings.dragging.valid ? 'fits' : "doesn't fit"}`);
        }
        break;
      case Tool.PAINT:
        lines.push('PAINT — tap a wall or the floor');
        if (this.painter.hover) lines.push(`Over: ${this.painter.hover}`);
        break;
      case Tool.WALK:
        lines.push(this.touch ? 'WALK — stick to move, drag to look, walk into things to shove them'
          : 'WALK — click to look, WASD, E carry/drop, Esc frees mouse');
        lines.push(`Shove force: ${Math.round(this.shopper.shoveForce)} N ([ ])`);
        if (this.shopper.carrying) lines.push(`Carrying ${this.shopper.carrying.item.name}`);
        break;
      case Tool.LIGHT:
        lines.push('LIGHT — sliders for the sun and ceiling light; tap a lamp to dim it, drag to move it');
        if (this.placer.dragging) lines.push(`Placing ${this.placer.dragging.item.name} — tap to drop`);
        break;
    }
    let placed = 0;
    let bad = 0;
    for (const p of this.placer.items) {
      if (p.state === State.GHOST) continue;
      placed++;
      if (!p.valid) bad++;
    }
    lines.push(`Items: ${placed}${this.placer.anySettling() ? '   settling…' : ''}${bad ? `   ${bad} not fitting` : ''}`);
    const text = lines.join('\n');
    if (text !== this.hudText) { this.hudText = text; this.hud.textContent = text; }
  }

  private onLayoutChanged(): void {
    if (!this.placer.room) return;
    this.syncLightSources();
    this.bridge.post({ type: 'layout', ...this.capture() });
    if (this.selected) this.panel.showSelected(this.selected);
    else if (this.selectedOpening) this.panel.showOpening(this.selectedOpening);
  }

  /** Frame statistics the bench reads (renderer side only; frame times are page-side). */
  renderStats(): { calls: number; triangles: number } {
    // WebGPURenderer: drawCalls is per frame and `calls` counts render() calls
    // cumulatively; WebGLRenderer: `calls` is per frame.
    const r = this.renderer.info.render;
    return { calls: r.drawCalls ?? r.calls ?? 0, triangles: r.triangles };
  }
}
