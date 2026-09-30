// The sim's half of the benchmark: a `{type:"bench"}` message that puts the
// view where a scenario wants it. The Godot build answers the same messages
// (game/src/web/host_bridge.gd), so tests/bench/bench.mjs drives both stacks
// through one contract -- layouts go through the ordinary `{type:"layout"}`.
//
//   {type:"bench", op:"orbit", yaw, pitch, dist}   planner view, fixed angle
//   {type:"bench", op:"walk", x, z, yaw, intent:[x, z]}
//                                                  first person at (x, z),
//                                                  walking with [intent]
//   {type:"bench", op:"stats"}                     -> {type:"bench_stats", ...}

import { Vector3 } from 'three';
import type { Showroom } from '../app/showroom';
import { HEIGHT } from '../walkthrough/shopper';
import { Tool } from '../ui/catalog-panel';

export function installBenchHooks(sim: Showroom): void {
  sim.bridge.on('bench', (m) => {
    switch (m.op) {
      case 'orbit':
        sim.benchIntent = null;
        if (sim.tool !== Tool.PLACE) sim.setTool(Tool.PLACE);
        sim.setOrbit(Number(m.yaw ?? 0.35), Number(m.pitch ?? -0.95), Number(m.dist ?? 9));
        break;
      case 'walk': {
        if (sim.tool !== Tool.WALK) sim.setTool(Tool.WALK);
        if (m.x !== undefined) {
          sim.shopper.position.set(Number(m.x), HEIGHT * 0.5 + 0.05, Number(m.z ?? 0));
          sim.shopper.velocity.set(0, 0, 0);
        }
        if (m.yaw !== undefined) sim.shopper.yaw = Number(m.yaw);
        const i = Array.isArray(m.intent) ? m.intent : [0, 0];
        sim.benchIntent = new Vector3(Number(i[0]), 0, Number(i[1]));
        break;
      }
      case 'stats': {
        const steps = Math.max(sim.physicsSteps, 1);
        const mem = (performance as Performance & { memory?: { usedJSHeapSize: number } }).memory;
        sim.bridge.post({
          type: 'bench_stats',
          engine: 'three',
          physics: sim.backend.name,
          physics_ms: sim.physicsMs / steps,
          physics_steps: sim.physicsSteps,
          ...sim.renderStats(),
          js_heap: mem?.usedJSHeapSize ?? null,
          render_cpu_ms: sim.renderMs / Math.max(sim.renderFrames, 1),
          items: sim.placer.items.length,
          settling: sim.placer.anySettling(),
        });
        sim.physicsMs = 0;
        sim.physicsSteps = 0;
        sim.renderMs = 0;
        sim.renderFrames = 0;
        break;
      }
    }
  });
}
