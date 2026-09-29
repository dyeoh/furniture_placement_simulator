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
  iphone13: { label: 'iPhone 13 · iOS 15 · Safari', caps: { browserName: 'safari',
    'bstack:options': { deviceName: 'iPhone 13', osVersion: '15', realMobile: 'true' } } },
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

async function runDevice(id, cred, build, outDir) {
  const d = DEVICES[id];
  const caps = structuredClone(d.caps);
  Object.assign(caps['bstack:options'], {
    userName: cred.user, accessKey: cred.key, projectName: 'Room Planner bench', buildName: build,
    sessionName: d.label, idleTimeout: 300, debug: 'false', networkLogs: 'false', consoleLogs: 'errors',
  });
  const url = `${BASE}/bench/?${new URLSearchParams({ runs: RUNS, sample: SAMPLE, quality: 'high', targets: 'godot,three' })}`;
  const log = (m) => console.log(`[${id}] ${m}`);
  let driver;
  try {
    driver = await new Builder().usingServer('https://hub.browserstack.com/wd/hub').withCapabilities(caps).build();
    log(`session ${(await driver.getSession()).getId()} · ${url}`);
    await driver.get(url);
    const t0 = Date.now();
    let last = '';
    for (;;) {
      const s = await driver.executeScript('return window.__bench ? { done: window.__bench.done, progress: window.__bench.progress } : null;');
      if (s && s.progress !== last) { log(s.progress); last = s.progress; }
      if (s?.done) break;
      if (Date.now() - t0 > TIMEOUT_MS) throw new Error('timed out');
      await new Promise((r) => setTimeout(r, 10_000));
    }
    const bench = await driver.executeScript('return window.__bench;');
    fs.writeFileSync(path.join(outDir, `${id}.json`), JSON.stringify({ device: d.label, ...bench }, null, 2));
    const ok = !bench.error && bench.results?.length === 2;
    await driver.executeScript(`browserstack_executor: ${JSON.stringify({ action: 'setSessionStatus',
      arguments: { status: ok ? 'passed' : 'failed', reason: ok ? 'bench complete' : String(bench.error || 'incomplete').slice(0, 200) } })}`);
    log(ok ? 'done' : `failed: ${bench.error || 'incomplete'}`);
    return { id, label: d.label, bench };
  } catch (e) {
    log(`error: ${e.message.split('\n')[0]}`);
    try {
      await driver?.executeScript(`browserstack_executor: ${JSON.stringify({ action: 'setSessionStatus',
        arguments: { status: 'failed', reason: e.message.slice(0, 200) } })}`);
    } catch { /* session already gone */ }
    return { id, label: d.label, error: e.message };
  } finally {
    await driver?.quit().catch(() => {});
  }
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
