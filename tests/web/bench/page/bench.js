// The bench page's engine. Plain ES2019 in a classic script: it must run on
// iOS 16 Safari (iPhone 11 on BrowserStack) without a build step.
(function () {
  'use strict';
  var q = new URLSearchParams(location.search);
  var RUNS = Number(q.get('runs') || 3);
  // Rotates which build goes first; a driver that reloads the page per run
  // (browserstack.mjs) passes the run number so the rotation carries on.
  var OFFSET = Number(q.get('offset') || 0);
  var SAMPLE_MS = Number(q.get('sample') || 5000);
  var QUALITY = q.get('quality') || 'high';
  // ?measure=1 asks the builds for render timing (Godot's viewport timestamp
  // capture, which crashed WebKit on Linux CI, so it is opt-in).
  var MEASURE = q.get('measure') === '1';
  var READY_TIMEOUT_MS = 180000;
  var DEFAULT_URLS = { godot: '../', three: '../three/?physics=box3d', 'three-rapier': '../three/?physics=rapier' };
  // ?targets=godot,three or label=url pairs, e.g. godot-old=/old/
  var TARGETS = (q.get('targets') || 'godot,three').split(',').map(function (t) {
    var eq = t.indexOf('=');
    return eq < 0 ? { name: t, url: DEFAULT_URLS[t] } : { name: t.slice(0, eq), url: t.slice(eq + 1) };
  });
  var wanted = q.get('scenarios');
  var SCENARIOS = window.BENCH_SCENARIOS.filter(function (s) { return !wanted || wanted.split(',').indexOf(s.name) >= 0; });

  var stage = document.getElementById('stage');
  var statusEl = document.getElementById('status');
  var state = window.__bench = { done: false, error: null, progress: '', env: env(), results: null, runs: [] };

  function say(text) { state.progress = text; statusEl.textContent = text; }
  function wait(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

  function env() {
    var gl = null;
    try {
      var c = document.createElement('canvas').getContext('webgl2');
      var d = c && c.getExtension('WEBGL_debug_renderer_info');
      gl = c ? (d ? c.getParameter(d.UNMASKED_RENDERER_WEBGL) : 'webgl2') : 'none';
    } catch (e) { gl = 'error'; }
    return { ua: navigator.userAgent, dpr: window.devicePixelRatio, screen: [screen.width, screen.height],
      viewport: [innerWidth, innerHeight], cores: navigator.hardwareConcurrency || null,
      memoryGB: navigator.deviceMemory || null, gpu: gl, webgpu: 'gpu' in navigator };
  }

  function withQuery(url, extra) { return url + (url.indexOf('?') < 0 ? '?' : '&') + extra; }

  /** Load a build in a fresh iframe; resolves once it posts {type:"ready"}. */
  function load(target) {
    stage.innerHTML = '';
    var frame = document.createElement('iframe');
    var inbox = [];
    var onMessage = function (ev) {
      if (ev.source !== frame.contentWindow || typeof ev.data !== 'string') return;
      try { inbox.push(JSON.parse(ev.data)); } catch (e) { /* not ours */ }
    };
    window.addEventListener('message', onMessage);
    var t0 = performance.now();
    frame.src = withQuery(target.url, 'quality=' + QUALITY);
    stage.appendChild(frame);
    return new Promise(function (resolve, reject) {
      var poll = setInterval(function () {
        var ready = inbox.filter(function (m) { return m.type === 'ready'; })[0];
        var doc = null;
        try { doc = frame.contentDocument; } catch (e) { /* cross-origin: no notice to read */ }
        var notice = doc && doc.getElementById('status-notice');
        if (ready) {
          clearInterval(poll);
          resolve({ frame: frame, inbox: inbox, ready: ready, readyMs: performance.now() - t0,
            close: function () { window.removeEventListener('message', onMessage); stage.innerHTML = ''; } });
        } else if (notice && notice.textContent.trim()) {
          clearInterval(poll); window.removeEventListener('message', onMessage);
          reject(new Error('loader: ' + notice.textContent.trim()));
        } else if (performance.now() - t0 > READY_TIMEOUT_MS) {
          clearInterval(poll); window.removeEventListener('message', onMessage);
          reject(new Error('never ready'));
        }
      }, 100);
    });
  }

  function send(sim, msg) { sim.frame.contentWindow.postMessage(JSON.stringify(msg), '*'); }

  /** Bytes the build pulled over the network (same origin, so transferSize is visible). */
  function transferred(win) {
    var total = 0;
    try {
      var nav = win.performance.getEntriesByType('navigation')[0];
      if (nav) total += nav.transferSize || 0;
      win.performance.getEntriesByType('resource').forEach(function (r) { total += r.transferSize || 0; });
    } catch (e) { return null; }
    return total;
  }

  function sampleFrames(win, ms) {
    return new Promise(function (resolve) {
      // Callback time, not the rAF timestamp: after a long task queued frames
      // carry near-identical timestamps, which reads as impossibly fast frames.
      var deltas = [], last = 0, t0 = win.performance.now();
      function tick() {
        var t = win.performance.now();
        if (last) deltas.push(t - last);
        last = t;
        if (t - t0 < ms) win.requestAnimationFrame(tick); else resolve(deltas);
      }
      win.requestAnimationFrame(tick);
    });
  }

  function pct(sorted, p) { return sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))] : null; }
  function round(v, n) { return v == null ? null : Math.round(v * Math.pow(10, n)) / Math.pow(10, n); }

  async function stats(sim) {
    sim.inbox.length = 0;
    send(sim, { type: 'bench', op: 'stats', measure: MEASURE });
    for (var i = 0; i < 20; i++) {
      var s = sim.inbox.filter(function (m) { return m.type === 'bench_stats'; })[0];
      if (s) return s;
      await wait(50);
    }
    return null;
  }

  async function runTarget(target, runIndex) {
    say('run ' + (runIndex + 1) + '/' + RUNS + ' · ' + target.name + ' · loading');
    var sim = await load(target);
    var win = sim.frame.contentWindow;
    await wait(1500);
    var out = { target: target.name, run: runIndex, ready: sim.ready, readyMs: Math.round(sim.readyMs),
      bytes: transferred(win), scenarios: {} };
    var refresh = null;
    for (var i = 0; i < SCENARIOS.length; i++) {
      var sc = SCENARIOS[i];
      say('run ' + (runIndex + 1) + '/' + RUNS + ' · ' + target.name + ' · ' + sc.name);
      sc.messages.forEach(function (m) { send(sim, m); });
      // Wait until the sim holds the layout's pieces before the settle timer
      // starts: a new room size makes the three.js build rebuild its world
      // asynchronously, and a slow phone takes a while to build 150 pieces,
      // so a fixed wait can sample the room before the layout lands.
      var layout = sc.messages.filter(function (m) { return m.type === 'layout'; }).pop();
      if (layout) {
        var want = (layout.items || []).length;
        for (var tries = 0; tries < 300; tries++) {
          var st0 = await stats(sim);
          if (st0 && st0.items === want) break;
          await wait(100);
        }
      }
      await wait(sc.settleMs);
      await stats(sim); // reset the engine's counters
      var d = (await sampleFrames(win, SAMPLE_MS)).sort(function (a, b) { return a - b; });
      var st = await stats(sim);
      var mean = d.reduce(function (a, b) { return a + b; }, 0) / Math.max(d.length, 1);
      var p50 = pct(d, 0.5);
      // The display's refresh interval, from the idle room: vsync cannot be
      // switched off on a phone, so slow frames are judged against it.
      // Floored at 240 Hz: an uncapped desktop run has no refresh to speak of.
      if (refresh === null && sc.name === 'empty') refresh = Math.max(p50, 1000 / 240);
      var slowAt = (refresh || 1000 / 60) * 1.5;
      var mem = null;
      try { mem = win.performance.memory ? win.performance.memory.usedJSHeapSize : null; } catch (e) { /* Safari */ }
      var wasm = null;
      try { wasm = win.__wasmMemoryBytes ? win.__wasmMemoryBytes() : null; } catch (e) { /* no probe */ }
      out.scenarios[sc.name] = {
        frames: d.length, fps: round(1000 / mean, 1), p50: round(p50, 2), p95: round(pct(d, 0.95), 2),
        p99: round(pct(d, 0.99), 2), slowPct: round(100 * d.filter(function (x) { return x > slowAt; }).length / Math.max(d.length, 1), 1),
        physicsMs: st ? round(st.physics_ms, 3) : null, drawCalls: st ? st.calls : null,
        renderCpuMs: st && st.render_cpu_ms != null ? round(st.render_cpu_ms, 2) : null,
        jsHeapMB: mem == null ? null : round(mem / 1048576, 1), wasmMB: wasm == null ? null : round(wasm / 1048576, 1),
      };
      if (sc.name === 'walk') send(sim, { type: 'bench', op: 'orbit' });
    }
    out.refreshMs = round(refresh, 2);
    sim.close();
    return out;
  }

  function median(values) {
    var v = values.filter(function (x) { return typeof x === 'number'; }).sort(function (a, b) { return a - b; });
    return v.length ? v[Math.floor(v.length / 2)] : null;
  }

  function combine(runs) {
    var byTarget = {};
    runs.forEach(function (r) { (byTarget[r.target] = byTarget[r.target] || []).push(r); });
    return Object.keys(byTarget).map(function (name) {
      var rs = byTarget[name];
      var scenarios = {};
      SCENARIOS.forEach(function (sc) {
        var keys = Object.keys(rs[0].scenarios[sc.name] || {});
        scenarios[sc.name] = {};
        keys.forEach(function (k) { scenarios[sc.name][k] = median(rs.map(function (r) { return (r.scenarios[sc.name] || {})[k]; })); });
      });
      return {
        target: name, runs: rs.length, ready: rs[0].ready, refreshMs: median(rs.map(function (r) { return r.refreshMs; })),
        // The first visit is the cold load a shopper sees; later ones hit the HTTP cache.
        coldReadyMs: rs[0].readyMs, coldBytes: rs[0].bytes, warmReadyMs: median(rs.slice(1).map(function (r) { return r.readyMs; })),
        scenarios: scenarios,
      };
    });
  }

  function report(results) {
    var h = ['<h2>Room Planner bench</h2><div class="desc">' + state.env.ua + '<br>GPU: ' + state.env.gpu +
      ' · DPR ' + state.env.dpr + ' · ' + state.env.viewport.join('×') + ' · quality=' + QUALITY + ' · ' + RUNS + ' runs</div>'];
    h.push('<table><tr><th>build</th><th>cold ready ms</th><th>warm ready ms</th><th>transferred MB</th><th>refresh ms</th></tr>');
    results.forEach(function (r) {
      h.push('<tr><td>' + r.target + '</td><td>' + r.coldReadyMs + '</td><td>' + (r.warmReadyMs == null ? '—' : r.warmReadyMs) +
        '</td><td>' + (r.coldBytes == null ? '—' : (r.coldBytes / 1048576).toFixed(2)) + '</td><td>' + r.refreshMs + '</td></tr>');
    });
    h.push('</table>');
    SCENARIOS.forEach(function (sc) {
      h.push('<h2>' + sc.name + '</h2><div class="desc">' + sc.desc + '</div><table><tr><th>build</th><th>fps</th><th>p50</th><th>p95</th><th>p99</th><th>slow %</th><th>physics ms</th><th>draws</th><th>wasm MB</th></tr>');
      results.forEach(function (r) {
        var s = r.scenarios[sc.name] || {};
        var f = function (v) { return v == null ? '—' : v; };
        h.push('<tr><td>' + r.target + '</td><td>' + f(s.fps) + '</td><td>' + f(s.p50) + '</td><td>' + f(s.p95) + '</td><td>' + f(s.p99) +
          '</td><td>' + f(s.slowPct) + '</td><td>' + f(s.physicsMs) + '</td><td>' + f(s.drawCalls) + '</td><td>' + f(s.wasmMB) + '</td></tr>');
      });
      h.push('</table>');
    });
    var el = document.getElementById('report');
    el.innerHTML = h.join('');
    el.hidden = false;
    stage.hidden = true;
  }

  async function main() {
    await wait(300);
    for (var run = 0; run < RUNS; run++) {
      // Rotate the order each run so drift does not always land on the same build.
      for (var k = 0; k < TARGETS.length; k++) {
        var t = TARGETS[(k + run + OFFSET) % TARGETS.length];
        try { state.runs.push(await runTarget(t, run)); }
        catch (e) { state.runs.push({ target: t.name, run: run, error: String(e && e.message || e) }); }
      }
    }
    var ok = state.runs.filter(function (r) { return !r.error; });
    state.results = combine(ok);
    state.errors = state.runs.filter(function (r) { return r.error; });
    report(state.results);
    say('done' + (state.errors.length ? ' · ' + state.errors.length + ' failed run(s)' : ''));
    state.done = true;
  }

  main().catch(function (e) { state.error = String(e && e.stack || e); state.done = true; say('failed: ' + state.error); });
})();
