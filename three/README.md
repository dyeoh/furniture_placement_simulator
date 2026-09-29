# Room Planner — three.js build

A port of the Godot simulator (`../game`) to three.js, built so the two web
stacks can be benchmarked side by side on the same content. It speaks the same
`postMessage` contract (`ready`, `layout`, `catalog`, `clear`, `add_to_cart`)
and loads the Godot project's own models, textures and `data/catalog.json` —
nothing is copied or converted.

**Ported:** place / drag / rotate / three snap modes with a physics settle,
windows and doors in the walls (a real hole, so the sun comes through), paint,
lighting (sun, bounce, ceiling light, floor lamps with shadows, the ceiling),
Sims-style cutaway, first-person walk with shove and carry, touch controls,
quality tiers, the host bridge, and the layout contract.
**Not ported:** glTF uploads and on-screen dimension lines.

## Stack

| | |
|---|---|
| Runtime / package manager | Bun |
| Bundler | Vite, TypeScript (strict) |
| Renderer | three `WebGLRenderer` (WebGL 2, like Godot's Compatibility renderer); `?renderer=webgpu` uses `WebGPURenderer` |
| Physics | Box3D compiled to wasm (`native/box3d`) — the same engine the Godot build ships — or Rapier (`?physics=rapier`); `B` swaps live |
| UI | plain DOM, no framework |

Stock `MeshStandardMaterial` only, no shader patching, so the WebGPU path keeps
working. Godot's triplanar mapping is baked into box UVs instead
(`room/surface-materials.ts`).

## Layout

`src/` mirrors `game/src/` file for file (`room_builder.gd` →
`room/room-builder.ts`, …), and each file names its original at the top.

```
native/box3d/   shim.c (flat C API over Box3D + the character mover), build.sh
src/
  main.ts       boot: catalogue + models -> renderer -> physics -> first frame -> "ready"
  app/          showroom.ts (renderer, cameras, input, frame loop), quality.ts
  physics/      backend.ts (the seam), box3d.ts, rapier.ts, factory.ts
  catalog/ room/ placement/ paint/ walkthrough/ ui/ web/
  bench/        hooks.ts: the {type:"bench"} messages the benchmark drives
tests/          bun test — placement, settle, wall magnet, walk + shove, layout round-trip, on both engines
```

## Commands

```sh
bun install
bun run box3d        # build src/physics/box3d/box3d.{js,wasm}; needs emsdk 4.0.11 (~/emsdk)
bun run dev          # http://localhost:5174
bun run test
bun run build        # dist/, with the Godot assets copied alongside
```

The Box3D wasm is a build output (gitignored), built the same way CI builds
the Godot extension: Emscripten 4.0.11, `-msimd128 -msse2`, no threads.

URL flags: `?physics=box3d|rapier`, `?renderer=webgpu`, `?quality=low|high`,
`?touch=1`, `?host=<origin>`, `?ui=0` (no panel/HUD, for look comparisons).

**Browser floor:** Safari / iOS 16.4, Chrome 91, Firefox 89. Box3D is built
with WebAssembly SIMD, and three.js itself ships class static blocks; both
arrived in Safari 16.4. An inline check in `index.html` shows a notice below
that, since the module bundle would fail to parse there and say nothing.

## Benchmark

```sh
cd ../tests/web
node smoke.mjs ../../three/dist                 # boots in Chromium, WebKit, Firefox, phone
node bench/bench.mjs                            # headed Chrome, real GPU, uncapped
node bench/bench.mjs --godot ../../web          # against a local Godot export instead of Pages
```

Each build runs in an `<iframe>` on a host page, as in the store, and is driven
only through the shared message contract; frame times are sampled inside the
sim's frame. Results go to `bench-results/` as JSON and a markdown table.
Scenarios live in `tests/web/bench/scenarios.mjs`. The `walk` scenario needs
the `{type:"bench"}` hook, which the Godot build does not have yet.

## Known differences from the Godot build

- Lighting is the same set of lights and shadow budgets, but Godot's
  Compatibility renderer sums light passes in gamma space, so its image is
  somewhat brighter and warmer. Energies are mapped ×π to three's physical units.
- No backlight translucency on lamp shades in three's standard material; the
  shade's emissive glow is raised to stand in for it.
- The planner/walk scene is identical in draw structure (one draw per mesh, no
  instancing) so the comparison stays like for like.
