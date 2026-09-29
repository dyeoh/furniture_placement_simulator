// ← game/tests/test_placement.gd and test_backends.gd: the same checks, on both engines.

import { describe, expect, test } from 'bun:test';
import { Vector3 } from 'three';
import { State } from '../src/placement/placed-item';
import { Snap } from '../src/placement/placer';
import * as Layout from '../src/placement/layout';
import { BACKENDS, settle, world } from './helpers';

for (const [name, make] of BACKENDS) {
  describe(name, () => {
    test('a dropped piece settles on the floor and is placed', async () => {
      const w = await world(make);
      const p = w.placer.begin(w.catalog.find('se-side-table')!, new Vector3(0.3, 0, 0.4));
      expect(w.placer.drop()).toBe(true);
      const t = settle(w);
      expect(p.state).toBe(State.PLACED);
      expect(t).toBeLessThan(4.5);
      expect(p.aabb().min.y).toBeCloseTo(0, 2);
      expect(p.position.x).toBeCloseTo(0.25, 2); // grid snap
      expect(p.valid).toBe(true);
      w.backend.shutdown();
    });

    test('overlaps and out-of-room drops are refused', async () => {
      const w = await world(make);
      w.placer.begin(w.catalog.find('moto-coffee-table')!, new Vector3(0, 0, 0));
      expect(w.placer.drop()).toBe(true);
      settle(w);
      w.placer.begin(w.catalog.find('se-side-table')!, new Vector3(0.1, 0, 0));
      expect(w.placer.dragging!.valid).toBe(false);
      expect(w.placer.drop()).toBe(false);
      w.backend.shutdown();
    });

    test('wall magnet turns the back to the nearest wall and pulls it flush', async () => {
      const w = await world(make);
      w.placer.snapMode = Snap.WALL;
      const p = w.placer.begin(w.catalog.find('segu-shelf')!, new Vector3(2.7, 0, 0.6));
      expect(p.yaw).toBe(3);
      expect(p.aabb(false).max.x).toBeCloseTo(3, 5);
      expect(w.placer.drop()).toBe(true);
      settle(w);
      expect(p.valid).toBe(true);
      w.backend.shutdown();
    });

    test('the shopper walks, stays on the floor and shoves a light piece', async () => {
      const w = await world(make);
      const { Shopper } = await import('../src/walkthrough/shopper');
      const table = w.placer.begin(w.catalog.find('se-side-table')!, new Vector3(0, 0, 0));
      w.placer.drop();
      settle(w);
      const shopper = new Shopper();
      shopper.setup(w.backend, w.placer, new Vector3(0, 0, 1.5));
      const z0 = table.xf.p.z;
      for (let i = 0; i < 180; i++) {
        shopper.step(new Vector3(0, 0, -1), 1 / 60);
        w.backend.step(1 / 60);
        w.placer.syncBodies();
        w.placer.update(1 / 60);
      }
      expect(shopper.grounded).toBe(true);
      expect(shopper.feet().y).toBeGreaterThan(-0.05);
      expect(shopper.feet().y).toBeLessThan(0.1);
      expect(table.xf.p.z).toBeLessThan(z0 - 0.2);
      w.backend.shutdown();
    });

    test('layout round-trips through capture and restore', async () => {
      const w = await world(make);
      w.openings.place(w.catalog.find('window')!, 'west', -1.2);
      w.placer.begin(w.catalog.find('logos-tv-unit')!, new Vector3(0, 0, -2));
      w.placer.rotate(2);
      w.placer.drop();
      w.placer.setFinish(w.placer.items[0], 'blackwood');
      settle(w);
      const before = Layout.capture(w.placer, w.room, undefined, w.openings);
      Layout.restore(JSON.parse(JSON.stringify(before)), w.placer, w.room, undefined, w.openings);
      settle(w);
      // A restore re-drops every piece, so a solver may settle it a millimetre off.
      const after = Layout.capture(w.placer, w.room, undefined, w.openings);
      const [a, b] = [after.items![0], before.items![0]];
      expect(Math.abs(a.x - b.x)).toBeLessThan(0.005);
      expect(Math.abs(a.z - b.z)).toBeLessThan(0.005);
      expect({ ...after, items: [] }).toEqual({ ...before, items: [] });
      expect({ ...a, x: 0, z: 0 }).toEqual({ ...b, x: 0, z: 0 });
      expect(w.placer.cartLines()).toEqual([{ variant_id: 48061572940017, quantity: 1 }]);
      w.backend.shutdown();
    });
  });
}
