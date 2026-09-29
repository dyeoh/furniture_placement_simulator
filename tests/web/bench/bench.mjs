// Run the bench page (tests/web/bench/page) locally in Chrome and save its
// results. The page does the measuring; this only serves the builds the way
// GitHub Pages does and reads back window.__bench, exactly as
// browserstack.mjs does on real devices.
//
//   node tests/web/bench/bench.mjs [--runs 3] [--sample 5000] [--quality high]
//        [--targets godot,three,three-rapier] [--scenarios empty,showroom]
//        [--mount name=<dir>]... [--headless] [--channel chrome|chromium]
//
// Layout served, as on Pages: web/ at /, three/dist at /three/, the bench page
// at /bench/. --mount adds a directory at /<name>/ for A/B runs, e.g.
//   --mount old=/tmp/web-oldcore --targets godot=/,godot-old=/old/
//
// Headed Chrome with vsync and the frame cap off by default, so desktop
// numbers show headroom; --headless is for CI smoke only (software GL).

import { chromium } from 'playwright';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { execFileSync } from 'node:child_process';

const here = path.dirname(new URL(import.meta.url).pathname);
const root = path.resolve(here, '../../..');
const args = process.argv.slice(2);
const opt = (name, def) => { const i = args.indexOf(`--${name}`); return i >= 0 ? args[i + 1] : def; };
const many = (name) => args.flatMap((a, i) => (a === `--${name}` ? [args[i + 1]] : []));
const HEADLESS = args.includes('--headless');

const MIME = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.wasm': 'application/wasm',
  '.css': 'text/css', '.json': 'application/json', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.gltf': 'model/gltf+json', '.bin': 'application/octet-stream', '.pck': 'application/octet-stream',
};
const gzipCache = new Map();

/** Longest-prefix mounts, gzip like GitHub Pages (everything but images). */
export function servePages(mounts) {
  const prefixes = Object.keys(mounts).sort((a, b) => b.length - a.length);
  const server = http.createServer((req, res) => {
    const p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    const prefix = prefixes.find((m) => p === m.replace(/\/$/, '') || p.startsWith(m));
    if (!prefix) { res.writeHead(404); res.end(); return; }
    const dir = mounts[prefix];
    let file = path.join(dir, p.slice(prefix.length));
    if (!file.startsWith(dir)) { res.writeHead(403); res.end(); return; }
    if (fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, 'index.html');
    if (!fs.existsSync(file)) { res.writeHead(404); res.end(); return; }
    const type = MIME[path.extname(file)] || 'application/octet-stream';
    if (/gzip/.test(req.headers['accept-encoding'] || '') && !type.startsWith('image/')) {
      let body = gzipCache.get(file);
      if (!body) { body = zlib.gzipSync(fs.readFileSync(file), { level: 6 }); gzipCache.set(file, body); }
      res.writeHead(200, { 'Content-Type': type, 'Content-Encoding': 'gzip', 'Content-Length': body.length });
      res.end(body);
      return;
    }
    res.writeHead(200, { 'Content-Type': type });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({
    base: `http://127.0.0.1:${server.address().port}`, close: () => server.close(),
  })));
}

/** Markdown for a page result set (also used by browserstack.mjs). */
export function markdown(bench, title) {
  const { env, results, errors } = bench;
  const lines = [`## ${title}`, '', `${env.ua}`, '', `GPU: ${env.gpu} · DPR ${env.dpr} · viewport ${env.viewport.join('×')}` +
    ` · cores ${env.cores ?? '?'} · memory ${env.memoryGB ?? '?'} GB`, '',
    '| build | cold ready (ms) | warm ready (ms) | transferred (MB) | refresh (ms) |', '|---|---:|---:|---:|---:|'];
  for (const r of results) {
    lines.push(`| ${r.target} | ${r.coldReadyMs} | ${r.warmReadyMs ?? '—'} | ${r.coldBytes == null ? '—' : (r.coldBytes / 1048576).toFixed(2)} | ${r.refreshMs} |`);
  }
  const names = Object.keys(results[0]?.scenarios ?? {});
  for (const sc of names) {
    lines.push('', `**${sc}**`, '', '| build | fps | p50 | p95 | p99 | slow % | physics ms | draws | wasm MB |',
      '|---|---:|---:|---:|---:|---:|---:|---:|---:|');
    for (const r of results) {
      const s = r.scenarios[sc] ?? {};
      const f = (v) => (v == null ? '—' : v);
      lines.push(`| ${r.target} | ${f(s.fps)} | ${f(s.p50)} | ${f(s.p95)} | ${f(s.p99)} | ${f(s.slowPct)} | ${f(s.physicsMs)} | ${f(s.drawCalls)} | ${f(s.wasmMB)} |`);
    }
  }
  if (errors?.length) lines.push('', `Failed runs: ${errors.map((e) => `${e.target} run ${e.run + 1}: ${e.error}`).join('; ')}`);
  return lines.join('\n');
}

export function pageQuery() {
  const q = new URLSearchParams();
  q.set('runs', opt('runs', '3'));
  q.set('sample', opt('sample', '5000'));
  q.set('quality', opt('quality', 'high'));
  q.set('targets', opt('targets', 'godot,three'));
  if (opt('scenarios')) q.set('scenarios', opt('scenarios'));
  return q.toString();
}

async function main() {
  const web = path.join(root, 'web');
  const threeDist = path.join(root, 'three/dist');
  if (!fs.existsSync(path.join(web, 'index.html'))) throw new Error('no Godot export in web/ (tests/web/bench/export-godot.sh)');
  if (!fs.existsSync(path.join(threeDist, 'index.html'))) throw new Error('no three build (cd three && bun run build)');
  execFileSync('node', [path.join(here, 'build-page.mjs'), path.join(root, 'bench-results/.page')], { stdio: 'ignore' });
  const mounts = { '/': web, '/three/': threeDist, '/bench/': path.join(root, 'bench-results/.page') };
  for (const m of many('mount')) {
    const [name, dir] = m.split(/=(.*)/s);
    mounts[`/${name}/`] = path.resolve(dir);
  }
  const srv = await servePages(mounts);
  const channel = opt('channel', HEADLESS ? 'chromium' : 'chrome');
  const launchArgs = HEADLESS
    ? ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist']
    : ['--disable-gpu-vsync', '--disable-frame-rate-limit', '--enable-unsafe-webgpu', '--ignore-gpu-blocklist'];
  const browser = await chromium.launch({ headless: HEADLESS, args: launchArgs, ...(channel === 'chromium' ? {} : { channel }) });
  const page = await browser.newPage({ viewport: { width: 1280, height: 720 }, deviceScaleFactor: 1 });
  page.on('pageerror', (e) => console.log('pageerror', e.message));

  // Warm the GPU process and shader caches on a throwaway visit per build.
  for (const t of opt('targets', 'godot,three').split(',')) {
    await page.goto(`${srv.base}/bench/?${new URLSearchParams({ runs: '1', sample: '200', targets: t, scenarios: 'empty' })}`);
    await page.waitForFunction(() => window.__bench?.done, null, { timeout: 300_000 });
  }

  const url = `${srv.base}/bench/?${pageQuery()}`;
  console.log(`${channel} ${browser.version()} · ${HEADLESS ? 'headless' : 'headed, uncapped'} · ${url.replace(srv.base, '')}`);
  await page.goto(url);
  let last = '';
  for (;;) {
    const s = await page.evaluate(() => ({ done: window.__bench?.done, progress: window.__bench?.progress }));
    if (s.progress !== last) { console.log(`  ${s.progress}`); last = s.progress; }
    if (s.done) break;
    await page.waitForTimeout(1000);
  }
  const bench = await page.evaluate(() => window.__bench);
  await browser.close();
  srv.close();
  if (bench.error) throw new Error(bench.error);

  const outDir = path.join(root, 'bench-results');
  fs.mkdirSync(outDir, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  fs.writeFileSync(path.join(outDir, `${stamp}.json`), JSON.stringify(bench, null, 2));
  const md = markdown(bench, `Local · ${channel} ${browser.version()}`);
  fs.writeFileSync(path.join(outDir, `${stamp}.md`), md + '\n');
  console.log('\n' + md + `\n\nwrote bench-results/${stamp}.{json,md}`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === new URL(import.meta.url).pathname) await main();
