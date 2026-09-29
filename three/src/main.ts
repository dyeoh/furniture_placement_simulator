// Boot: capabilities -> catalogue and models -> renderer -> physics ->
// first frame -> {type:"ready"}. Failures show in #status-notice, which is
// what the browser smoke test (tests/web/smoke.mjs) looks for.

import './ui/styles.css';
import { Catalog } from './catalog/catalog';
import * as ModelLibrary from './catalog/model-library';
import { initialKind } from './physics/factory';
import { makeRenderer, rendererKind, Showroom, webgpuWorks } from './app/showroom';
import { installBenchHooks } from './bench/hooks';
import { texturesLoaded } from './room/surface-materials';
import { queryParam } from './web/host-bridge';

const status = document.getElementById('status')!;
const notice = document.getElementById('status-notice')!;
const detail = document.getElementById('status-detail')!;

function fail(message: string): void {
  notice.textContent = message;
  notice.style.display = 'block';
  document.getElementById('status-bar')!.hidden = true;
}

function hasWebGL2(): boolean {
  try { return !!document.createElement('canvas').getContext('webgl2'); } catch { return false; }
}

async function boot(): Promise<void> {
  performance.mark('sim-boot');
  const wantGpu = queryParam('renderer') === 'webgpu';
  if (wantGpu && !('gpu' in navigator)) return fail('This browser has no WebGPU. Drop ?renderer=webgpu to use WebGL 2.');
  if (!wantGpu && !hasWebGL2()) return fail('This browser has no WebGL 2, which the room planner needs.');

  detail.textContent = 'Loading catalogue and models…';
  const [catalogData] = await Promise.all([Catalog.fetchDefault(), ModelLibrary.preload()]);
  performance.mark('sim-assets');

  detail.textContent = 'Starting…';
  // three's WebGPU backend can need a newer browser than the one that offers
  // WebGPU (Chrome 140 rejects its texture-view swizzle), so try one frame of
  // the real materials first and fall back to WebGL 2 if it throws.
  const useGpu = wantGpu && await webgpuWorks();
  const renderer = await makeRenderer(useGpu ? 'webgpu' : 'webgl');
  const sim = new Showroom(document.getElementById('app')!, renderer, initialKind());
  await sim.start(catalogData);
  installBenchHooks(sim);
  await texturesLoaded();
  // Compile every shader before the first visible frame, so "ready" means usable.
  await renderer.compileAsync?.(sim.scene, sim.camera);
  performance.mark('sim-physics');

  const loop = (t: number) => { sim.frame(t); requestAnimationFrame(loop); };
  requestAnimationFrame((t) => {
    loop(t);
    performance.mark('sim-first-frame');
    status.classList.add('fading');
    // Removed, not hidden: the smoke test waits for #status to leave the DOM, as Godot's shell does.
    setTimeout(() => status.remove(), 500);
    sim.announceReady({ renderer: wantGpu && !useGpu ? 'webgpu-failed-webgl2' : rendererKind(renderer) });
  });
  (window as unknown as { __sim3: Showroom }).__sim3 = sim;
}

boot().catch((e: unknown) => {
  console.error(e);
  fail(`The room planner failed to start: ${e instanceof Error ? e.message : String(e)}`);
});
