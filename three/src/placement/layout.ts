// The room as data: size, ceiling, openings, items, paint, lighting. ← layout.gd
//
// This is the contract with the outside world, byte-compatible with the
// Godot build's: the host page receives it on every change, a backend swap
// rebuilds from it, the tests round-trip it, and the benchmark drives both
// stacks by posting it.

import { Color, Vector3 } from 'three';
import { toHex } from '../color';
import type { Lighting, LightingSettings } from '../room/lighting';
import type { Openings } from '../room/openings';
import { SURFACES, type RoomBuilder, type Surface } from '../room/room-builder';
import type { OpeningDict } from '../room/wall-opening';
import { State, type PlacedDict } from './placed-item';
import type { Placer } from './placer';

export const VERSION = 1;

export interface LayoutDict {
  version?: number;
  room?: { width?: number; depth?: number; height?: number; ceiling?: boolean; openings?: OpeningDict[] };
  items?: PlacedDict[];
  paint?: Partial<Record<Surface, string>>;
  lighting?: LightingSettings;
}

export function capture(placer: Placer, room: RoomBuilder, lighting?: Lighting, openings?: Openings): LayoutDict {
  const paint: Partial<Record<Surface, string>> = {};
  for (const s of SURFACES) paint[s] = toHex(room.paintColor(s));
  const data: LayoutDict = {
    version: VERSION,
    room: { width: room.width, depth: room.depth, height: room.wallHeight, ceiling: room.hasCeiling,
      openings: openings ? openings.toArray() : [] },
    items: placer.items.filter((p) => p.state !== State.GHOST).map((p) => p.toDict()),
    paint,
  };
  if (lighting) data.lighting = lighting.toDict();
  return data;
}

/**
 * Rebuild from a capture. Items are committed straight to bodies -- they drop
 * the couple of centimetres and settle. The room's size is the caller's job.
 */
export function restore(data: LayoutDict, placer: Placer, room: RoomBuilder, lighting?: Lighting,
  openings?: Openings): void {
  const r = data.room && typeof data.room === 'object' ? data.room : {};
  if ('ceiling' in r) room.setCeiling(Boolean(r.ceiling));
  if (openings && Array.isArray(r.openings)) openings.restore(r.openings);
  placer.clear();
  const quiet = placer.onChanged;
  placer.onChanged = null;
  for (const d of data.items ?? []) {
    if (!d || typeof d !== 'object') continue;
    const item = placer.catalog.find(String(d.id ?? ''));
    if (!item) { console.warn(`Layout: unknown item '${d.id}' skipped`); continue; }
    const at = new Vector3(Number(d.x ?? 0), 0, Number(d.z ?? 0));
    const p = placer.begin(item, at);
    p.yaw = Number(d.yaw ?? 0) % 4;
    p.finish = String(d.finish ?? item.finish);
    placer.setFinish(p, p.finish);
    // The stored position is exact -- but keep it inside the walls in case
    // the room shrank; anything that then overlaps is flagged, not lost.
    p.position.copy(placer.clampToRoom(p, at));
    p.valid = placer.validate(p);
    if (d.light && typeof d.light === 'object' && item.isLight()) {
      p.setLight(Boolean(d.light.on ?? true), Number(d.light.energy ?? 0.6), Number(d.light.warmth ?? 0.7));
    }
    placer.dragging = null;
    placer.commit(p);
  }
  placer.onChanged = quiet;
  for (const [s, hex] of Object.entries(data.paint ?? {})) room.paint(s as Surface, new Color(hex as string));
  if (lighting && data.lighting && typeof data.lighting === 'object') lighting.fromDict(data.lighting);
  placer.onChanged?.();
}
