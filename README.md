# Furniture Placement Simulator

A web-embeddable room planner for a furniture store, built on **Box3D** (Erin
Catto's 3D physics engine) with Godot 4.7. Shoppers drop pieces from the
catalogue into a room and watch them physically settle, paint the walls and
floor Sims-style, then walk through the room in first person — bumping into,
carrying and re-arranging what they placed.

The physics core is lifted from the
[monster-brawler POC](../godot_game_sample): the same `PhysicsBackend` seam
with a Box3D implementation and a Godot/Jolt fallback, switchable at runtime.
Everything else is new.

The POC catalogue is seeded from [Naco Design's Design Lab
collection](https://nacodesign.com/collections/design-lab), using the
dimensions their product pages publish; the Shopify section in `shopify/`
replaces it with the live collection at runtime.

## What it does

| | |
|---|---|
| **Place** | Tap a catalogue item, drag it in, rotate in quarter turns, drop. Three live-switchable snap modes: free, 25 cm grid, wall magnet. Overlaps and out-of-room drops are refused (green/red ghost). A dropped piece is a rigid body until it falls asleep, then it is *placed*. |
| **Paint** | Swatches (wall paints + the store's five timbers) or a colour picker; tap a wall or the floor. Walls between the camera and the room are cut away. |
| **Walk** | First-person capsule mover. Walking into furniture shoves it (450 N, tunable live) — a side table skids, a bed does not. `E` carries a piece and drops it wherever you are. |
| **Uploads** | Drop a `.glb`/`.gltf` in and it becomes a catalogue item: bounding-box collider (convex hull optional), mm-exported models auto-scaled. |
| **Store** | Runs in an `<iframe>` on the Shopify page. The page sends the collection as the catalogue; the sim sends the layout on every change and "add to cart" with variant ids. |

## Setup (local)

Requires Godot 4.7.1, `scons` and `cmake` (`brew install scons cmake`).

```sh
git clone --recurse-submodules git@github.com:dyeoh/furniture_placement_simulator.git
cd furniture_placement_simulator/engine/box3d-godot/godot
scons platform=macos arch=arm64 target=editor        # adjust for your platform
cp -R demo/bin/libbox3d_godot.macos.editor.framework ../../../game/bin/
cd ../../.. && godot --path game
```

The extension binary is not committed — the engine is a submodule built from
source. Without it the project still runs on the Godot/Jolt fallback and says
so in the HUD.

### Controls

`1` `2` `3` Place / Paint / Walk (`Tab` cycles) · `R` rotate · `S` cycle snap
· `Delete` remove · `Esc` cancel drag / free the mouse · right-drag orbit ·
wheel zoom · **Walk:** click to look, `WASD`, `E` carry/drop, `[` `]` shove
force · `B` swap physics backend (the layout survives the swap).

## Tests

```sh
GODOT=~/Downloads/Godot.app/Contents/MacOS/Godot     # or wherever yours is
$GODOT --headless --path game --import               # twice on a fresh clone
$GODOT --headless --path game --script res://tests/test_backends.gd
$GODOT --headless --path game --script res://tests/test_placement.gd
```

Both run on both backends. `tools/capture_shots.gd` renders screenshots into
`shots/`; it must run **without** `--headless`.

## Web build and the store

The web build is single-threaded on purpose: a Shopify storefront cannot send
the COOP/COEP headers a threaded (SharedArrayBuffer) build needs, so a
threaded module would fail to link inside the store. It uses the
Compatibility renderer, the only one that runs on the web.

**Deploy:** `.github/workflows/deploy-web.yml` builds the no-threads wasm
extension from the submodule, exports the project and publishes it to GitHub
Pages on every push to `main`. It also runs `test_placement.gd` on the Godot
backend. Nothing web-related needs to be installed locally.

**Local web export (optional):** install Emscripten 4.0.11 and the Godot 4.7.1
export templates (~1.2 GB), then

```sh
cd engine/box3d-godot/godot && scons platform=web threads=no target=template_release
cp demo/bin/libbox3d_godot.web.*.wasm ../../../game/bin/
cd ../../.. && godot --headless --path game --export-release Web ../web/index.html
```

**Embed in Shopify:** Online Store → Themes → Edit code → Sections → add
`room-planner`, paste `shopify/room-planner.liquid`, then add the "Room
planner" section to a page and pick the collection. The section passes the
store's origin to the sim (`?host=`), sends the collection as the catalogue
(dimensions parsed from each description as `W x D x H` mm), stores the
layout in `sessionStorage`, and turns "Add room to cart" into `/cart/add.js`.

## Architecture notes

**The physics layer is abstracted.** Nothing in `src/placement`,
`src/walkthrough` or `src/room` calls an engine directly; `PhysicsBackend`
has a Box3D implementation and a Godot/Jolt one. Box3D is v0.1.0 and its C API
is still moving, so the project must survive a breaking upstream change, and
`B` lets the feel of the two solvers be compared on the same layout.

The Jolt mover was rebuilt on `PhysicsServer3D.body_test_motion()` (what
`CharacterBody3D` uses) with a short ground probe; the brawler's
`cast_motion` + `collide_shape` approximation was unstable under Jolt. Both
backends now stand a capsule within 6 mm of each other.

**Furniture is a ghost while it moves.** Dragging, carrying and restoring all
drive a mesh, not a body; the body exists only between a drop and the next
pick-up. A rigid body pulled around by a cursor fights everything it passes
through, and one held at chest height blocks the mover carrying it.

**Picking is game-side.** Ray-vs-AABB over the placed list and the five room
boxes, because the two backends return different collider handles and the
seam has no reverse body→id map. Quarter-turn rotation keeps every AABB exact,
which is what lets overlap validation be a plain box test.

**Layout is the contract.** `Layout.capture()` is what the host page
receives, what a backend swap rebuilds from, and what the tests round-trip.

## Known limitations

- Catalogue pieces render as tinted boxes; the store publishes no 3D models.
  Uploaded glTF replaces the box for that item.
- Wall magnet assumes a rectangular room with the item's back on local −Z.
- Walkthrough is keyboard/mouse; on touch devices Place and Paint work, Walk
  does not yet have an on-screen stick.
- `add_to_cart` uses the first available variant; the store's timber finish
  variants are not mapped to the finish picker yet.
