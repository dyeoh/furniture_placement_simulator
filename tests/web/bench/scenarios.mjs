// Benchmark scenarios. Each is a list of messages posted to the sim through
// the host contract both builds already speak ({type:"layout"} etc.), then a
// steady-state sample. Nothing here reaches into either engine directly.

import fs from 'node:fs';
import path from 'node:path';

const here = path.dirname(new URL(import.meta.url).pathname);
const showroom = JSON.parse(fs.readFileSync(path.join(here, '../../../three/tests/fixtures/showroom.json'), 'utf8'));

const NIGHT_LIGHTING = {
  sun: { elevation: 30, azimuth: 250, energy: 0.1, warmth: 0.9 },
  ambient: { energy: 0.3 },
  ceiling: { on: true, energy: 0.4, warmth: 0.7 },
};

/** [count] pieces on a 0.9 m grid in a 12 x 12 m room, cycling through the catalogue. */
function crowd(count) {
  const ids = ['se-side-table', 'lutra-bedside-table', 'lutra-shoe-cabinet', 'moto-coffee-table', 'gu-shelf'];
  const items = [];
  const per = 13;
  for (let i = 0; i < count; i++) {
    const gx = i % per, gz = Math.floor(i / per);
    items.push({ id: ids[i % ids.length], x: (gx - (per - 1) / 2) * 0.9, z: (gz - (per - 1) / 2) * 0.9, yaw: 0, finish: '' });
  }
  return { type: 'layout', version: 1, room: { width: 12, depth: 12, height: 2.7, ceiling: false, openings: [] }, items, paint: {} };
}

const EMPTY = { type: 'layout', version: 1, room: { width: 6, depth: 5, height: 2.7, ceiling: false, openings: [] }, items: [], paint: {} };

export const SCENARIOS = [
  { name: 'empty', desc: 'default room, nothing placed', messages: [EMPTY], settleMs: 1500 },
  { name: 'showroom', desc: '7 pieces + a window, sun shadows (the README screenshot)', messages: [showroom], settleMs: 5000 },
  { name: 'night', desc: 'ceiling on, ceiling light + 2 shadowed lamps (4 shadow casters)',
    messages: [{ ...showroom, room: { ...showroom.room, ceiling: true }, lighting: NIGHT_LIGHTING,
      items: [...showroom.items,
        { id: 'floor-lamp', x: -1.2, z: 1.6, yaw: 0, finish: '', light: { on: true, energy: 0.8, warmth: 0.8 } },
        { id: 'floor-lamp', x: 2.5, z: -1.4, yaw: 0, finish: '', light: { on: true, energy: 0.6, warmth: 0.7 } }] }],
    settleMs: 5000 },
  // Sampled straight away: this one measures the drop -- 150 bodies settling at once.
  { name: 'drop-150', desc: '150 pieces dropped at once in a 12 x 12 m room, sampled while they settle', messages: [crowd(150)], settleMs: 300 },
  { name: 'crowd-150', desc: 'the same 150 pieces once asleep', messages: [], settleMs: 6000 },
  // Needs the bench hook (three has it; Godot answers only once host_bridge.gd does).
  { name: 'walk', desc: 'first person through the showroom, shoving the coffee table', hook: true,
    messages: [showroom, { type: 'bench', op: 'walk', x: 0.5, z: 2.2, yaw: 0, intent: [0, -1] }], settleMs: 4000 },
];
