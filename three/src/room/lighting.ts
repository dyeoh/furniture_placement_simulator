// The room's light: a sun the shopper swings round the sky, a ceiling light,
// and ambient standing in for bounce. Floor lamps are furniture
// (PlacedItem). ← lighting.gd
//
// Ambient is bounce from the light actually in the room -- daylight through
// the windows (all of it without a ceiling), the ceiling light, the lamps --
// tinted by them. Everything off under a ceiling and the room goes dark.
//
// Units: Godot's light energies are unitless; three's lights are physical,
// where a white Lambert surface facing a light of intensity pi reflects 1.0.
// So every Godot energy is multiplied by PI here. Godot's Compatibility
// renderer also sums light passes in gamma space, which three does not, so
// the two will not match pixel for pixel; they carry the same lights and
// shadow budgets, which is what the benchmark needs.

import {
  AmbientLight, Color, DirectionalLight, Euler, Group, Object3D, PointLight, Scene, Vector3,
} from 'three';
import { srgb } from '../color';
import * as ModelLibrary from '../catalog/model-library';

const SUN_MAX = 1;
const AMBIENT_MAX = 1;
const CEILING_MAX = 3;
const COOL = [0.92, 0.95, 1.0];
const WARM = [1.0, 0.72, 0.45];
const BOUNCE_CEILING = 0.35;
const BOUNCE_LAMP = 0.25;
const GLAZING_GAIN = 2.5;
const AMBIENT_GAIN = 2;
const AMBIENT_FLOOR = 0.02;
const DAYLIGHT = [0.78, 0.78, 0.79];
const FILL_ENERGY = 0.12;
const PI = Math.PI;

export interface LightingSettings {
  sun: { elevation: number; azimuth: number; energy: number; warmth: number };
  ambient: { energy: number };
  ceiling: { on: boolean; energy: number; warmth: number };
}

export const DEFAULTS: LightingSettings = {
  sun: { elevation: 55, azimuth: 330, energy: 0.5, warmth: 0.35 },
  ambient: { energy: 0.3 },
  ceiling: { on: false, energy: 0.5, warmth: 0.6 },
};

/** Daylight to candle, lerped in sRGB like Godot's Color.lerp. */
export function warmthColor(w: number): Color {
  const t = Math.min(Math.max(w, 0), 1);
  return srgb(COOL[0] + (WARM[0] - COOL[0]) * t, COOL[1] + (WARM[1] - COOL[1]) * t, COOL[2] + (WARM[2] - COOL[2]) * t);
}

export class Lighting {
  settings: LightingSettings = structuredClone(DEFAULTS);
  sun!: DirectionalLight;
  fill!: DirectionalLight;
  ambient!: AmbientLight;
  ceilingLight!: PointLight;
  ceilingFitting: Group | null = null;
  onChanged: (() => void) | null = null;
  private fittingSize = new Vector3();
  private hasCeiling = false;
  private glazing = 0;
  private lampEnergy = 0;
  private lampWarmth = 0.7;
  private lowSpec = false;
  private extent = 0;

  setup(scene: Scene, parent: Object3D, roomHeight: number): void {
    scene.background = srgb(0.94, 0.93, 0.9);
    this.sun = new DirectionalLight(0xffffff, 1);
    this.sun.castShadow = true;
    this.sun.shadow.mapSize.set(4096, 4096);
    this.sun.shadow.bias = -0.0005;
    this.sun.shadow.normalBias = 0.02;
    parent.add(this.sun, this.sun.target);
    this.fill = new DirectionalLight(0xffffff, FILL_ENERGY * PI);
    this.fill.position.copy(dirFromEuler(-30, 150).multiplyScalar(-10));
    parent.add(this.fill, this.fill.target);
    this.ambient = new AmbientLight(0xffffff, 0.3 * PI);
    parent.add(this.ambient);

    this.ceilingLight = new PointLight(0xffffff, 1, 9, 1);
    this.ceilingLight.castShadow = true;
    this.ceilingLight.shadow.mapSize.set(1024, 1024);
    this.ceilingLight.shadow.bias = -0.002;
    parent.add(this.ceilingLight);
    // The model is nearly a metre of cord and globe; two thirds keeps it above eye level.
    this.fittingSize = ModelLibrary.naturalSize('modern_ceiling_lamp_01').multiplyScalar(0.65);
    this.ceilingFitting = ModelLibrary.instantiate('modern_ceiling_lamp_01', this.fittingSize);
    if (this.ceilingFitting) {
      // The globe wraps the bulb; letting it cast would shadow its own light.
      ModelLibrary.setCastsShadow(this.ceilingFitting, false);
      parent.add(this.ceilingFitting);
    }
    this.setRoomHeight(roomHeight);
    this.apply();
  }

  setRoomHeight(h: number): void {
    let drop = 0.6;
    if (this.ceilingFitting) {
      this.ceilingFitting.position.set(0, h - this.fittingSize.y * 0.5, 0);
      drop = this.fittingSize.y;
    }
    this.ceilingLight.position.set(0, h - drop + 0.15, 0);
  }

  /** Low spec: no ceiling-light shadow, a tighter, smaller sun shadow map. */
  setLowSpec(low: boolean): void {
    this.lowSpec = low;
    this.ceilingLight.castShadow = !low;
    const size = low ? 2048 : 4096;
    if (this.sun.shadow.mapSize.x !== size) {
      this.sun.shadow.mapSize.set(size, size);
      this.sun.shadow.map?.dispose();
      this.sun.shadow.map = null;
    }
    this.applyShadowDistance();
  }

  setSun(key: keyof LightingSettings['sun'], v: number): void { this.settings.sun[key] = v; this.apply(); }
  setAmbient(v: number): void { this.settings.ambient.energy = v; this.apply(); }
  setCeiling(key: keyof LightingSettings['ceiling'], v: number | boolean): void {
    (this.settings.ceiling as Record<string, number | boolean>)[key] = v;
    this.apply();
  }

  apply(): void {
    const s = this.settings.sun;
    // Godot's sun shines along -Z of its basis; three's from position to target.
    this.sun.position.copy(dirFromEuler(-s.elevation, s.azimuth).multiplyScalar(-15));
    this.sun.intensity = s.energy * SUN_MAX * PI;
    this.sun.color.copy(warmthColor(s.warmth));
    const c = this.settings.ceiling;
    this.ceilingLight.visible = c.on;
    this.ceilingLight.intensity = c.energy * CEILING_MAX * PI;
    this.ceilingLight.color.copy(warmthColor(c.warmth));
    this.applyBounce();
    this.onChanged?.();
  }

  setRoom(hasCeiling: boolean, windowArea: number, floorArea: number, extent = 0): void {
    this.hasCeiling = hasCeiling;
    this.glazing = windowArea / Math.max(floorArea, 0.01);
    if (extent > 0) { this.extent = extent; this.applyShadowDistance(); }
    this.applyBounce();
  }

  /** Spread the sun's shadow map over the room and a margin, not 25 m of nothing. */
  private applyShadowDistance(): void {
    let d = this.extent <= 0 ? 25 : Math.min(Math.max(this.extent * 1.5, 8), 25);
    if (this.lowSpec) d = Math.min(d, 12);
    const cam = this.sun.shadow.camera;
    const half = d * 0.5;
    cam.left = -half; cam.right = half; cam.top = half; cam.bottom = -half;
    cam.near = 0.5; cam.far = 40;
    cam.updateProjectionMatrix();
  }

  setLamps(totalEnergy: number, meanWarmth: number): void {
    this.lampEnergy = totalEnergy;
    this.lampWarmth = meanWarmth;
    this.applyBounce();
  }

  daylightIn(): number {
    const e = this.settings.sun.energy;
    return e * (!this.hasCeiling ? 1 : Math.min(Math.max(this.glazing * GLAZING_GAIN, 0), 1));
  }

  private applyBounce(): void {
    const day = this.daylightIn();
    const c = this.settings.ceiling;
    const ceilE = c.on ? c.energy * BOUNCE_CEILING : 0;
    const lampE = this.lampEnergy * BOUNCE_LAMP;
    const bounce = day + ceilE + lampE;
    const daylight = srgb(DAYLIGHT[0], DAYLIGHT[1], DAYLIGHT[2]);
    const col = daylight.clone();
    if (bounce > 1e-4) {
      const sunCol = daylight.clone().lerp(warmthColor(this.settings.sun.warmth), 0.25);
      col.copy(sunCol.multiplyScalar(day))
        .add(warmthColor(c.warmth).multiplyScalar(ceilE))
        .add(warmthColor(this.lampWarmth).multiplyScalar(lampE))
        .multiplyScalar(1 / bounce);
    }
    const energy = this.settings.ambient.energy * AMBIENT_MAX * bounce * AMBIENT_GAIN;
    this.ambient.color.copy(col);
    this.ambient.intensity = Math.max(AMBIENT_FLOOR, energy) * PI;
    this.fill.intensity = FILL_ENERGY * (day / 0.5) * PI;
  }

  toDict(): LightingSettings {
    return structuredClone(this.settings);
  }

  fromDict(d: Partial<LightingSettings>): void {
    for (const group of Object.keys(DEFAULTS) as (keyof LightingSettings)[]) {
      const src = d[group] as Record<string, unknown> | undefined;
      if (!src || typeof src !== 'object') continue;
      const dst = this.settings[group] as Record<string, unknown>;
      for (const key of Object.keys(DEFAULTS[group])) if (key in src) dst[key] = src[key];
    }
    this.apply();
  }
}

/** Direction a Godot node with rotation (pitch, yaw) in degrees faces (-Z). */
function dirFromEuler(pitchDeg: number, yawDeg: number): Vector3 {
  const e = new Euler(pitchDeg * PI / 180, yawDeg * PI / 180, 0, 'YXZ');
  return new Vector3(0, 0, -1).applyEuler(e);
}
