// Tune the Godot build's lighting gains until it looks like the three.js
// build (Lighting.GAINS in game/src/room/lighting.gd). Three is rendered
// once per scene; Godot is re-rendered with `?cal=key:value,...` for each
// candidate, so nothing is re-exported during the search.
//
//   node tests/web/bench/calibrate.mjs [--rounds 2]
//
// Coordinate descent on the mean block ΔE2000 over the compare-look scenes,
// in multiplicative steps (x1.25, then x1.1, then x1.04). Prints the best
// gains to bake into GAINS.

import { chromium } from 'playwright';
import path from 'node:path';
import { capture, compare, SCENES, serve } from './compare-look.mjs';

const here = path.dirname(new URL(import.meta.url).pathname);
const root = path.resolve(here, '../../..');
const args = process.argv.slice(2);
const ROUNDS = Number(args[args.indexOf('--rounds') + 1] || 2);
const START = { sun: 1, ambient: 1, fill: 1, ceiling: 1, lamp: 1, glow: 1, falloff: 1, exposure: 1.15 };
// --params a,b limits which gains move (the rest stay at their --start values).
const PARAMS = args.indexOf('--params') >= 0 ? args[args.indexOf('--params') + 1].split(',') : null;
const STEPS = [1.25, 1.1, 1.04];

const srv = await serve({ godot: path.join(root, 'web'), three: path.join(root, 'three/dist') });
const browser = await chromium.launch({ channel: 'chrome', headless: false, args: ['--ignore-gpu-blocklist'] });

// Sequential on purpose: in headed Chrome only the front tab gets animation
// frames, so parallel tabs would never render (or report ready).
const three = [];
for (const sc of SCENES) three.push(await capture(browser, `${srv.base}/three/?ui=0&quality=high&physics=box3d`, sc));

/**
 * Which scenes each gain can change. The night scenes run the sun at 0.1 and
 * the day scene has no lamps or ceiling light, so re-rendering only what a
 * gain touches halves the search. The final line re-scores everything.
 */
const ALL = SCENES.map((_, i) => i);
const byName = (...names) => names.map((n) => SCENES.findIndex((s) => s.name === n));
const AFFECTS = { sun: byName('day'), fill: byName('day'), ceiling: byName('night', 'walk'),
  lamp: byName('night', 'walk'), glow: byName('night', 'walk'), falloff: byName('night', 'walk'), ambient: ALL, exposure: ALL };

const key = (g) => Object.entries(g).map(([k, v]) => `${k}:${v.toFixed(4)}`).join(',');
const sceneCache = new Map();
async function sceneScore(g, i) {
  const ck = `${i}|${key(g)}`;
  if (!sceneCache.has(ck)) {
    const shot = await capture(browser, `${srv.base}/godot/?ui=0&quality=high&cal=${key(g)}`, SCENES[i]);
    sceneCache.set(ck, compare(shot, three[i], SCENES[i]).mean);
  }
  return sceneCache.get(ck);
}
async function score(g, base, which) {
  const per = base ? [...base.per] : [];
  for (const i of which) per[i] = await sceneScore(g, i);
  const s = per.reduce((a, b) => a + b, 0) / per.length;
  console.log(`  ${s.toFixed(2)} [${per.map((v) => v.toFixed(1)).join(' ')}]  ${key(g)}`);
  return { s, per };
}

const startArg = args.indexOf('--start') >= 0 ? args[args.indexOf('--start') + 1] : '';
let best = { ...START };
for (const part of startArg.split(',').filter(Boolean)) { const [k, v] = part.split(':'); best[k] = Number(v); }
let bestR = await score(best, null, ALL);
for (let round = 0; round < ROUNDS; round++) {
  for (const step of STEPS) {
    for (const k of Object.keys(best).filter((k) => !PARAMS || PARAMS.includes(k))) {
      for (const dir of [1, -1]) {
        for (;;) {
          const cand = { ...best, [k]: best[k] * (dir > 0 ? step : 1 / step) };
          const r = await score(cand, bestR, AFFECTS[k]);
          if (r.s + 0.02 < bestR.s) { best = cand; bestR = r; } else break;
        }
      }
    }
  }
}
const final = await score(best, null, ALL);
const bestScore = final.s;
await browser.close();
srv.close();
console.log(`\nbest mean ΔE ${bestScore.toFixed(2)}`);
console.log(JSON.stringify(Object.fromEntries(Object.entries(best).map(([k, v]) => [k, +v.toFixed(3)]))));
