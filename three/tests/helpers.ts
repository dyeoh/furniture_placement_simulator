// Headless fixtures: the real catalogue, both physics backends, no renderer.

import fs from 'node:fs';
import path from 'node:path';
import { Group, Vector3 } from 'three';
import { Catalog, type CatalogDict } from '../src/catalog/catalog';
import type { PhysicsBackend } from '../src/physics/backend';
import { Box3DBackend } from '../src/physics/box3d';
import { RapierBackend } from '../src/physics/rapier';
import { Placer } from '../src/placement/placer';
import { Openings } from '../src/room/openings';
import { RoomBuilder } from '../src/room/room-builder';

const ROOT = path.resolve(import.meta.dir, '..');

export function catalog(): Catalog {
  const c = new Catalog();
  const file = path.join(ROOT, '../game/data/catalog.json');
  c.loadDict(JSON.parse(fs.readFileSync(file, 'utf8')) as CatalogDict);
  return c;
}

export const BACKENDS: [string, () => Promise<PhysicsBackend>][] = [
  ['box3d', () => Box3DBackend.create({ wasmBinary: fs.readFileSync(path.join(ROOT, 'src/physics/box3d/box3d.wasm')) })],
  ['rapier', () => RapierBackend.create()],
];

export interface World { backend: PhysicsBackend; room: RoomBuilder; placer: Placer; openings: Openings; catalog: Catalog }

export async function world(make: () => Promise<PhysicsBackend>): Promise<World> {
  const backend = await make();
  backend.setGravity(new Vector3(0, -9.8, 0));
  const room = new RoomBuilder();
  room.build(backend);
  const cat = catalog();
  const placer = new Placer();
  placer.setup(backend, room, cat, new Group());
  const openings = new Openings();
  openings.setup(room, cat);
  return { backend, room, placer, openings, catalog: cat };
}

/** Step until nothing is settling (or [maxSeconds] of simulated time pass). */
export function settle(w: World, maxSeconds = 6): number {
  const dt = 1 / 60;
  let t = 0;
  do {
    w.backend.step(dt);
    w.placer.syncBodies();
    w.placer.update(dt);
    t += dt;
  } while (w.placer.anySettling() && t < maxSeconds);
  return t;
}
