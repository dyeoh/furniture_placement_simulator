// Boots the exported web build in real browser engines and checks it comes
// up. Run by CI against the fresh export before it is deployed, so a build
// that only breaks in Safari (WebKit) or on a phone never reaches Pages.
//
//   node tests/web/smoke.mjs web                       # serve ./web locally
//   node tests/web/smoke.mjs https://…/planner/        # or hit a deployed URL
//
// "Comes up" means: the sim posted its {type:"ready"} message, the loading
// overlay is gone, and nothing was logged at console.error. An engine whose
// headless GPU stack has no WebGL 2 is reported as SKIPPED, not failed --
// that is a limitation of the runner, not the build -- unless
// SMOKE_REQUIRE_ALL=1.

import { chromium, webkit, firefox, devices } from 'playwright';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const READY_TIMEOUT_MS = 180_000; // wasm compile on a shared runner is slow
const MIME = {
  '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm',
  '.pck': 'application/octet-stream', '.png': 'image/png', '.json': 'application/json',
};

function serve(dir) {
  const server = http.createServer((req, res) => {
    let file = path.join(dir, decodeURIComponent(new URL(req.url, 'http://x').pathname));
    if (fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, 'index.html');
    if (!fs.existsSync(file)) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream' });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({
    url: `http://127.0.0.1:${server.address().port}/`,
    close: () => server.close(),
  })));
}

const CASES = [
  { name: 'chromium', browser: chromium,
    launch: { args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] } },
  { name: 'chromium mobile, ?quality=low', browser: chromium, device: devices['Pixel 5'],
    query: '?quality=low', expectQuality: 'low',
    launch: { args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] } },
  { name: 'webkit', browser: webkit },
  { name: 'firefox', browser: firefox },
];

async function run(base, c) {
  const browser = await c.browser.launch({ headless: true, ...(c.launch || {}) });
  const context = await browser.newContext(c.device || {});
  const page = await context.newPage();
  const errors = [];
  page.on('console', (msg) => { if (msg.type() === 'error') errors.push(msg.text()); });
  page.on('pageerror', (err) => errors.push(`pageerror: ${err.message}`));
  // coi-serviceworker reloads the page once it has registered, aborting the
  // first load's fetches (WebKit reports that as "Load failed"). Only the
  // load that actually boots the sim is judged.
  page.on('framenavigated', (frame) => { if (frame === page.mainFrame()) errors.length = 0; });
  // The sim posts to window.parent; at top level that is the page itself.
  await page.addInitScript(() => {
    window.__sim = { ready: false, quality: null };
    window.addEventListener('message', (ev) => {
      try {
        const m = JSON.parse(ev.data);
        if (m && m.type === 'ready') { window.__sim.ready = true; window.__sim.quality = m.quality || null; }
      } catch (e) { /* not ours */ }
    });
  });

  const started = Date.now();
  let outcome;
  try {
    await page.goto(base + (c.query || ''), { waitUntil: 'domcontentloaded' });
    await page.waitForFunction(() => {
      const notice = document.querySelector('#status-notice');
      return window.__sim.ready || (notice && notice.textContent.trim().length > 0);
    }, null, { timeout: READY_TIMEOUT_MS });
    const state = await page.evaluate(() => ({
      ready: window.__sim.ready,
      quality: window.__sim.quality,
      notice: (document.querySelector('#status-notice') || {}).textContent || '',
    }));
    if (!state.ready) {
      const missingGL = /WebGL/i.test(state.notice);
      if (missingGL && !process.env.SMOKE_REQUIRE_ALL) {
        outcome = { skipped: true, reason: `no WebGL 2 in this headless engine: ${state.notice.trim()}` };
      } else {
        outcome = { failed: true, reason: `loader notice: ${state.notice.trim()}` };
      }
    } else {
      // The overlay fades out over the first frame.
      await page.waitForFunction(() => !document.getElementById('status'), null, { timeout: 10_000 });
      const problems = [];
      if (c.expectQuality && state.quality !== c.expectQuality) {
        problems.push(`quality: expected ${c.expectQuality}, got ${state.quality}`);
      }
      if (errors.length) problems.push(...errors.map((e) => `console.error: ${e}`));
      outcome = problems.length ? { failed: true, reason: problems.join('\n    ') }
        : { ok: true, quality: state.quality };
    }
  } catch (err) {
    outcome = { failed: true, reason: `${err.message}${errors.length ? '\n    ' + errors.join('\n    ') : ''}` };
  } finally {
    await browser.close();
  }
  outcome.seconds = ((Date.now() - started) / 1000).toFixed(1);
  return outcome;
}

const target = process.argv[2];
if (!target) { console.error('usage: node tests/web/smoke.mjs <dir|url>'); process.exit(2); }
const local = !/^https?:/.test(target) ? await serve(target) : null;
const base = local ? local.url : target;

let failed = 0;
for (const c of CASES) {
  const r = await run(base, c);
  const tag = r.ok ? 'OK  ' : r.skipped ? 'SKIP' : 'FAIL';
  console.log(`[${tag}] ${c.name} (${r.seconds}s)${r.ok ? `  quality=${r.quality}` : ''}`);
  if (r.reason) console.log(`    ${r.reason}`);
  if (r.failed) failed++;
}
if (local) local.close();
console.log(failed ? `\n${failed} FAILED` : '\nALL PASSED');
process.exit(failed ? 1 : 0);
