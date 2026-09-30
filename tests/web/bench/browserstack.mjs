// Run the bench page on real devices through BrowserStack Automate.
//
//   node tests/web/bench/browserstack.mjs [--devices m32,pixel7,...] [--runs 3]
//        [--sample 5000] [--base https://dyeoh.github.io/furniture_placement_simulator]
//
// Credentials come from tests/web/.env.browserstack (gitignored):
//   BROWSERSTACK_USERNAME=...
//   BROWSERSTACK_ACCESS_KEY=...
//
// Each device opens <base>/bench/?... (the page does all the measuring) and
// this polls window.__bench over WebDriver until it is done. Selenium rather
// than Playwright: BrowserStack drives real iPhones only over WebDriver.
// Devices run in parallel up to the plan's limit. Results go to
// bench-results/browserstack-<stamp>/: one JSON per device plus report.md.

import { Builder } from 'selenium-webdriver';
import fs from 'node:fs';
import path from 'node:path';
import { markdown } from './bench.mjs';

const here = path.dirname(new URL(import.meta.url).pathname);
const root = path.resolve(here, '../../..');
const args = process.argv.slice(2);
const opt = (name, def) => { const i = args.indexOf(`--${name}`); return i >= 0 ? args[i + 1] : def; };

const BASE = opt('base', 'https://dyeoh.github.io/furniture_placement_simulator').replace(/\/$/, '');
const RUNS = opt('runs', '3');
const SAMPLE = opt('sample', '5000');
const TIMEOUT_MS = 45 * 60_000;

/** The agreed spread, low end to high end. Names as BrowserStack lists them (automate/browsers.json). */
const DEVICES = {
  m32: { label: 'Samsung Galaxy M32 · Android 11 · Chrome', caps: { browserName: 'chrome',
    'bstack:options': { deviceName: 'Samsung Galaxy M32', osVersion: '11.0', realMobile: 'true' } } },
  pixel7: { label: 'Google Pixel 7 · Android 13 · Chrome', caps: { browserName: 'chrome',
    'bstack:options': { deviceName: 'Google Pixel 7', osVersion: '13.0', realMobile: 'true' } } },
  // The older iPhone: an A14 on iOS 17. Both builds need WebAssembly SIMD
  // (iOS 16.4+), so the iOS 15 devices BrowserStack offers cannot run them.
  iphone12: { label: 'iPhone 12 · iOS 17 · Safari', caps: { browserName: 'safari',
    'bstack:options': { deviceName: 'iPhone 12', osVersion: '17', realMobile: 'true' } } },
  iphone16: { label: 'iPhone 16 · iOS 18 · Safari', caps: { browserName: 'safari',
    'bstack:options': { deviceName: 'iPhone 16', osVersion: '18', realMobile: 'true' } } },
  win11: { label: 'Windows 11 · Chrome latest', caps: { browserName: 'Chrome', browserVersion: 'latest',
    'bstack:options': { os: 'Windows', osVersion: '11', resolution: '1920x1080' } } },
  mac: { label: 'macOS Tahoe · Safari 26', caps: { browserName: 'Safari', browserVersion: '26.4',
    'bstack:options': { os: 'OS X', osVersion: 'Tahoe', resolution: '1920x1080' } } },
};

function credentials() {
  const file = path.join(here, '../.env.browserstack');
  const env = { ...process.env };
  if (fs.existsSync(file)) {
    for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
      const m = line.match(/^\s*([A-Z_]+)\s*=\s*(.*?)\s*$/);
      if (m) env[m[1]] = m[2].replace(/^["']|["']$/g, '');
    }
  }
  if (!env.BROWSERSTACK_USERNAME || !env.BROWSERSTACK_ACCESS_KEY) {
    throw new Error('BrowserStack credentials missing: create tests/web/.env.browserstack');
  }
  return { user: env.BROWSERSTACK_USERNAME, key: env.BROWSERSTACK_ACCESS_KEY };
}

async function plan({ user, key }) {
  const res = await fetch('https://api.browserstack.com/automate/plan.json', {
    headers: { Authorization: 'Basic ' + Buffer.from(`${user}:${key}`).toString('base64') },
  });
  if (!res.ok) throw new Error(`BrowserStack plan check failed: ${res.status}`);
  return res.json();
}

/** No progress change for this long: the page is stuck (a hung tab keeps no clock). */
const STALL_MS = 6 * 60_000;

function median(values) {
  const v = values.filter((x) => typeof x === 'number').sort((a, b) => a - b);
  return v.length ? v[Math.floor(v.length / 2)] : null;
}

/** The bench page's own combine, over run records gathered from several page loads. */
function combine(runs) {
  const byTarget = {};
  for (const r of runs) (byTarget[r.target] ??= []).push(r);
  return Object.entries(byTarget).map(([target, rs]) => {
    const scenarios = {};
    for (const name of Object.keys(rs[0].scenarios)) {
      scenarios[name] = Object.fromEntries(Object.keys(rs[0].scenarios[name])
        .map((k) => [k, median(rs.map((r) => r.scenarios[name]?.[k]))]));
    }
    return { target, runs: rs.length, ready: rs[0].ready, refreshMs: median(rs.map((r) => r.refreshMs)),
      coldReadyMs: rs[0].readyMs, coldBytes: rs[0].bytes,
      warmReadyMs: median(rs.slice(1).map((r) => r.readyMs)), scenarios };
  });
}

/**
 * One page load = one run of both builds. A fresh page per run, because
 * iOS Safari kept the first Godot iframe's wasm memory around and the second
 * Godot load in the same page never finished (iPhone 12, 2026-09-30).
 */
async function onePageRun(driver, run, log) {
  const url = `${BASE}/bench/?${new URLSearchParams({ runs: '1', offset: String(run), sample: SAMPLE,
    quality: 'high', targets: 'godot,three' })}`;
  await driver.get(url);
  const t0 = Date.now();
  let last = '';
  let changed = Date.now();
  let missing = 0;
  for (;;) {
    const s = await driver.executeScript('return window.__bench ? { done: window.__bench.done, progress: window.__bench.progress } : null;');
    if (!s) {
      // The page itself is gone: the tab crashed or reloaded under us.
      if (++missing >= 3) throw new Error(`page lost after "${last}" (tab crashed or reloaded)`);
    } else {
      missing = 0;
      if (s.progress !== last) { log(s.progress); last = s.progress; changed = Date.now(); }
      if (s.done) break;
    }
    if (Date.now() - changed > STALL_MS) throw new Error(`stalled at "${last}"`);
    if (Date.now() - t0 > TIMEOUT_MS) throw new Error('timed out');
    await new Promise((r) => setTimeout(r, 10_000));
  }
  // As a JSON string: Safari's WebDriver refuses to transfer the object itself.
  return JSON.parse(await driver.executeScript('return JSON.stringify(window.__bench);'));
}

async function runDevice(id, cred, build, outDir) {
  const d = DEVICES[id];
  const caps = structuredClone(d.caps);
  Object.assign(caps['bstack:options'], {
    userName: cred.user, accessKey: cred.key, projectName: 'Room Planner bench', buildName: build,
    sessionName: d.label, idleTimeout: 300, debug: 'false', networkLogs: 'false', consoleLogs: 'errors',
  });
  const log = (m) => console.log(`[${id}] ${m}`);
  let driver;
  const runs = [];
  const errors = [];
  let env = null;
  try {
    driver = await new Builder().usingServer('https://hub.browserstack.com/wd/hub').withCapabilities(caps).build();
    log(`session ${(await driver.getSession()).getId()}`);
    for (let run = 0; run < Number(RUNS); run++) {
      try {
        const bench = await onePageRun(driver, run, log);
        env ??= bench.env;
        runs.push(...bench.runs.filter((r) => !r.error).map((r) => ({ ...r, run })));
        errors.push(...bench.runs.filter((r) => r.error).map((r) => ({ ...r, run })));
      } catch (e) {
        // Keep what earlier runs gave; a crashed tab ends this device.
        errors.push({ run, error: e.message.split('\n')[0] });
        log(`run ${run + 1} failed: ${e.message.split('\n')[0]}`);
        break;
      }
    }
  } catch (e) {
    errors.push({ error: e.message.split('\n')[0] });
    log(`error: ${e.message.split('\n')[0]}`);
  }
  const results = runs.length ? combine(runs) : [];
  const ok = results.length === 2 && errors.length === 0;
  const bench = { env, results, runs, errors, done: true };
  if (results.length) fs.writeFileSync(path.join(outDir, `${id}.json`), JSON.stringify({ device: d.label, ...bench }, null, 2));
  try {
    await driver?.executeScript(`browserstack_executor: ${JSON.stringify({ action: 'setSessionStatus',
      arguments: { status: ok ? 'passed' : 'failed', reason: ok ? 'bench complete' : String(errors[0]?.error || 'incomplete').slice(0, 200) } })}`);
  } catch { /* session already gone */ }
  await driver?.quit().catch(() => {});
  log(ok ? 'done' : `partial: ${results.map((r) => `${r.target} x${r.runs}`).join(', ') || 'no results'}`);
  return { id, label: d.label, bench, error: ok ? null : errors[0]?.error };
}

async function main() {
  const cred = credentials();
  const p = await plan(cred);
  const ids = opt('devices', Object.keys(DEVICES).join(',')).split(',');
  for (const id of ids) if (!DEVICES[id]) throw new Error(`unknown device ${id}; one of ${Object.keys(DEVICES).join(', ')}`);
  const parallel = Math.max(1, p.parallel_sessions_max_allowed - p.parallel_sessions_running);
  console.log(`BrowserStack ${p.automate_plan} plan · ${parallel} parallel · ${ids.length} device(s) · ${BASE}`);

  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const outDir = path.join(root, 'bench-results', `browserstack-${stamp}`);
  fs.mkdirSync(outDir, { recursive: true });
  const build = `bench ${stamp.slice(0, 16)}`;

  const queue = [...ids];
  const done = [];
  await Promise.all(Array.from({ length: Math.min(parallel, ids.length) }, async () => {
    while (queue.length) done.push(await runDevice(queue.shift(), cred, build, outDir));
  }));

  const order = (r) => ids.indexOf(r.id);
  done.sort((a, b) => order(a) - order(b));
  const parts = [`# Room Planner on real devices (${build})`, '',
    `Godot vs three.js, both on Box3D, served from ${BASE}. Median of ${RUNS} runs, ${SAMPLE} ms samples, quality=high.`,
    '"slow %" is frames longer than 1.5x the display refresh interval (vsync cannot be turned off on a phone).'];
  for (const r of done) {
    parts.push('', r.bench?.results?.length ? markdown(r.bench, r.label) : `## ${r.label}\n\nno results: ${r.error || r.bench?.error}`);
  }
  fs.writeFileSync(path.join(outDir, 'report.md'), parts.join('\n') + '\n');
  console.log(`\nwrote ${path.relative(root, outDir)}/report.md`);
}

await main();
