// Do the two builds look alike? Renders the same scenes in the Godot and
// three.js builds (same layout, same camera, UI hidden with ?ui=0) and
// compares them block by block in CIELAB (ΔE2000).
//
//   node tests/web/bench/compare-look.mjs [--godot <dir>] [--three <dir>] [--out <dir>] [--cal key:v,...] [--perf key:v;...]
//
// Prints mean and 90th-percentile ΔE per scene, plus per-surface means for the
// regions named below, and saves both screenshots and a difference heat map.
// Rule of thumb: ΔE < 2 is invisible side by side, < 5 reads as the same
// colour, > 10 is a different colour.

import { chromium } from 'playwright';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { SCENARIOS } from './scenarios.mjs';

const here = path.dirname(new URL(import.meta.url).pathname);
const root = path.resolve(here, '../../..');
const args = process.argv.slice(2);
const opt = (name, def) => { const i = args.indexOf(`--${name}`); return i >= 0 ? args[i + 1] : def; };
const OUT = path.resolve(opt('out', path.join(root, 'bench-results/look')));
const W = 1280, H = 720, BLOCK = 20;

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm', '.css': 'text/css',
  '.json': 'application/json', '.png': 'image/png', '.jpg': 'image/jpeg', '.gltf': 'model/gltf+json' };

export function serve(mounts) {
  const server = http.createServer((req, res) => {
    const [, mount, ...rest] = decodeURIComponent(new URL(req.url, 'http://x').pathname).split('/');
    const dir = mounts[mount];
    let file = dir && path.join(dir, ...rest);
    if (file && fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, 'index.html');
    if (!file || !fs.existsSync(file)) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream' });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise((r) => server.listen(0, '127.0.0.1', () => r({ base: `http://127.0.0.1:${server.address().port}`, close: () => server.close() })));
}

const byName = Object.fromEntries(SCENARIOS.map((s) => [s.name, s]));
/** Scenes to match, each: the messages that set it up and the view. Regions are [x0, y0, x1, y1] in pixels. */
export const SCENES = [
  { name: 'day', messages: byName.showroom.messages, view: { type: 'bench', op: 'orbit' },
    regions: { floor: [560, 470, 700, 560], 'north wall': [600, 60, 680, 110], 'west wall': [360, 320, 420, 380],
      bed: [560, 260, 660, 320], shelf: [700, 110, 790, 200] } },
  { name: 'night', messages: byName.night.messages, view: { type: 'bench', op: 'orbit' },
    regions: { floor: [560, 470, 700, 560], 'north wall': [600, 60, 680, 110], 'west wall': [360, 320, 420, 380],
      bed: [560, 260, 660, 320], 'lamp shade': [556, 346, 594, 378] } },
  { name: 'walk', messages: byName.night.messages,
    view: { type: 'bench', op: 'walk', x: 0.5, z: 2.2, yaw: 0.4, intent: [0, 0] },
    regions: { ceiling: [300, 10, 980, 60], floor: [300, 640, 980, 710], wall: [60, 200, 200, 500] } },
];

// --- colour science, sRGB 8-bit -> CIELAB (D65) -> ΔE2000

function lab([r, g, b]) {
  const lin = (c) => { c /= 255; return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; };
  const [R, G, B] = [lin(r), lin(g), lin(b)];
  const X = (0.4124 * R + 0.3576 * G + 0.1805 * B) / 0.95047;
  const Y = 0.2126 * R + 0.7152 * G + 0.0722 * B;
  const Z = (0.0193 * R + 0.1192 * G + 0.9505 * B) / 1.08883;
  const f = (t) => (t > 216 / 24389 ? Math.cbrt(t) : (24389 / 27 * t + 16) / 116);
  return [116 * f(Y) - 16, 500 * (f(X) - f(Y)), 200 * (f(Y) - f(Z))];
}

function de2000([L1, a1, b1], [L2, a2, b2]) {
  const rad = Math.PI / 180;
  const C1 = Math.hypot(a1, b1), C2 = Math.hypot(a2, b2), Cm = (C1 + C2) / 2;
  const G = 0.5 * (1 - Math.sqrt(Cm ** 7 / (Cm ** 7 + 25 ** 7)));
  const a1p = a1 * (1 + G), a2p = a2 * (1 + G);
  const C1p = Math.hypot(a1p, b1), C2p = Math.hypot(a2p, b2);
  const h = (a, b) => { const v = Math.atan2(b, a) / rad; return v < 0 ? v + 360 : v; };
  const h1 = h(a1p, b1), h2 = h(a2p, b2);
  const dL = L2 - L1, dC = C2p - C1p;
  let dh = h2 - h1;
  if (C1p * C2p === 0) dh = 0; else if (dh > 180) dh -= 360; else if (dh < -180) dh += 360;
  const dH = 2 * Math.sqrt(C1p * C2p) * Math.sin((dh / 2) * rad);
  const Lm = (L1 + L2) / 2, Cmp = (C1p + C2p) / 2;
  let hm = h1 + h2;
  if (C1p * C2p !== 0) hm = Math.abs(h1 - h2) > 180 ? (h1 + h2 + (h1 + h2 < 360 ? 360 : -360)) / 2 : (h1 + h2) / 2;
  const T = 1 - 0.17 * Math.cos((hm - 30) * rad) + 0.24 * Math.cos(2 * hm * rad)
    + 0.32 * Math.cos((3 * hm + 6) * rad) - 0.2 * Math.cos((4 * hm - 63) * rad);
  const SL = 1 + (0.015 * (Lm - 50) ** 2) / Math.sqrt(20 + (Lm - 50) ** 2);
  const SC = 1 + 0.045 * Cmp, SH = 1 + 0.015 * Cmp * T;
  const RT = -2 * Math.sqrt(Cmp ** 7 / (Cmp ** 7 + 25 ** 7)) * Math.sin(60 * Math.exp(-(((hm - 275) / 25) ** 2)) * rad);
  return Math.sqrt((dL / SL) ** 2 + (dC / SC) ** 2 + (dH / SH) ** 2 + RT * (dC / SC) * (dH / SH));
}

// --- capture

export async function capture(browser, url, scene) {
  const page = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: 1 });
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.addInitScript(() => { window.__m = []; addEventListener('message', (e) => { try { window.__m.push(JSON.parse(e.data)); } catch {} }); });
  await page.goto(url);
  await page.waitForFunction(() => window.__m.some((m) => m.type === 'ready'), null, { timeout: 120_000 });
  await page.waitForTimeout(1500);
  for (const m of scene.messages) await page.evaluate((m) => window.postMessage(JSON.stringify(m), '*'), m);
  await page.waitForTimeout(6000); // settle and sleep
  await page.evaluate((m) => window.postMessage(JSON.stringify(m), '*'), scene.view);
  await page.waitForTimeout(1500);
  const png = await page.screenshot();
  // Reduce in the page: shipping 3.7 M pixel values out as JSON costs ~20 s a
  // shot. Only per-block and per-region mean colours come back.
  const means = await page.evaluate(async ({ b64, W, H, BLOCK, regions }) => {
    const img = new Image();
    img.src = 'data:image/png;base64,' + b64;
    await img.decode();
    const c = document.createElement('canvas');
    c.width = W; c.height = H;
    const g = c.getContext('2d');
    g.drawImage(img, 0, 0);
    const px = g.getImageData(0, 0, W, H).data;
    const mean = ([x0, y0, x1, y1]) => {
      let r = 0, gg = 0, b = 0, n = 0;
      for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) { const o = (y * W + x) * 4; r += px[o]; gg += px[o + 1]; b += px[o + 2]; n++; }
      return [r / n, gg / n, b / n];
    };
    const blocks = [];
    for (let y = 0; y + BLOCK <= H; y += BLOCK) for (let x = 0; x + BLOCK <= W; x += BLOCK) blocks.push([x, y, ...mean([x, y, x + BLOCK, y + BLOCK])]);
    const reg = {};
    for (const [k, box] of Object.entries(regions)) reg[k] = mean(box);
    return { blocks, regions: reg };
  }, { b64: png.toString('base64'), W, H, BLOCK, regions: scene.regions });
  await page.close();
  if (errors.length) console.log(`  page errors: ${errors.slice(0, 2).join(' | ')}`);
  return { png, ...means };
}

export function compare(a, b, scene) {
  const bg = (c) => Math.abs(c[0] - 240) < 4 && Math.abs(c[1] - 238) < 4 && Math.abs(c[2] - 233) < 5;
  const blocks = [];
  a.blocks.forEach(([x, y, ...ca], i) => {
    const cb = b.blocks[i].slice(2);
    // Skip background-only blocks (both builds clear to the same colour).
    if (bg(ca) && bg(cb)) return;
    blocks.push({ x, y, de: de2000(lab(ca), lab(cb)) });
  });
  const sorted = blocks.map((k) => k.de).sort((p, q) => p - q);
  const regions = Object.fromEntries(Object.keys(scene.regions).map((name) => {
    const ca = a.regions[name], cb = b.regions[name];
    const la = lab(ca), lb = lab(cb);
    return [name, { de: +de2000(la, lb).toFixed(1), dL: +(lb[0] - la[0]).toFixed(1),
      godot: ca.map(Math.round), three: cb.map(Math.round) }];
  }));
  return {
    mean: +(sorted.reduce((s, v) => s + v, 0) / Math.max(sorted.length, 1)).toFixed(2),
    p90: +sorted[Math.floor(sorted.length * 0.9)].toFixed(2),
    blocks, regions,
  };
}

/** A heat map of per-block ΔE (black 0 .. red 20+) as an SVG, next to the screenshots. */
function heatmap(blocks) {
  const cells = blocks.map((b) => {
    const t = Math.min(b.de / 20, 1);
    return `<rect x="${b.x}" y="${b.y}" width="${BLOCK}" height="${BLOCK}" fill="rgb(${Math.round(255 * t)},${Math.round(40 * (1 - t))},${Math.round(40 * (1 - t))})"/>`;
  });
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}"><rect width="${W}" height="${H}"/>${cells.join('')}</svg>`;
}

async function main() {
  const godot = path.resolve(opt('godot', path.join(root, 'web')));
  const three = path.resolve(opt('three', path.join(root, 'three/dist')));
  const srv = await serve({ godot, three });
  const browser = await chromium.launch({ channel: 'chrome', headless: false, args: ['--ignore-gpu-blocklist'] });
  fs.mkdirSync(OUT, { recursive: true });
  const summary = {};
  for (const scene of SCENES) {
    const cal = opt('cal', '');
    const perf = opt('perf', '');
    const g = await capture(browser, `${srv.base}/godot/?ui=0&quality=high${cal ? `&cal=${cal}` : ''}${perf ? `&perf=${perf}` : ''}`, scene);
    const t = await capture(browser, `${srv.base}/three/?ui=0&quality=high&physics=box3d`, scene);
    fs.writeFileSync(path.join(OUT, `${scene.name}-godot.png`), g.png);
    fs.writeFileSync(path.join(OUT, `${scene.name}-three.png`), t.png);
    const r = compare(g, t, scene);
    fs.writeFileSync(path.join(OUT, `${scene.name}-diff.svg`), heatmap(r.blocks));
    summary[scene.name] = { mean: r.mean, p90: r.p90, regions: r.regions };
    console.log(`\n${scene.name}: mean ΔE ${r.mean}, p90 ${r.p90}`);
    for (const [name, v] of Object.entries(r.regions)) {
      console.log(`  ${name.padEnd(11)} ΔE ${String(v.de).padStart(5)}  ΔL ${String(v.dL).padStart(5)}  godot ${v.godot.join(',').padEnd(12)} three ${v.three.join(',')}`);
    }
  }
  await browser.close();
  srv.close();
  fs.writeFileSync(path.join(OUT, 'summary.json'), JSON.stringify(summary, null, 2));
  console.log(`\nwrote ${path.relative(root, OUT)}/`);
}

// Run as a script, not when imported by calibrate.mjs.
if (process.argv[1] && path.resolve(process.argv[1]) === new URL(import.meta.url).pathname) await main();
