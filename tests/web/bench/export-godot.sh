#!/bin/sh
# Export the Godot working tree to ./web, as CI does, for local benchmarks and
# look comparisons. Needs Godot 4.7.1 (GODOT=...), its web export templates,
# and the nothreads Box3D extension (built here from the submodule if missing;
# needs emsdk 4.0.11 in ~/emsdk).
set -eu
root=$(cd "$(dirname "$0")/../../.." && pwd)
GODOT=${GODOT:-$HOME/Downloads/Godot.app/Contents/MacOS/Godot}
ext=libbox3d_godot.web.template_release.wasm32.nothreads.wasm
if [ ! -f "$root/game/bin/$ext" ]; then
	[ -z "${EMSDK_PYTHON:-}" ] && command -v python3.14 >/dev/null && export EMSDK_PYTHON=$(command -v python3.14)
	. "${EMSDK:-$HOME/emsdk}/emsdk_env.sh" >/dev/null
	# Objects are shared between platforms/targets and scons does not tell a
	# wasm .o from a native one: sweep them first, as upstream's CI does
	# (.github/workflows/godot-macos.yml). A stale mix builds fine and then
	# crashes in box3d_library_init.
	(cd "$root/engine/box3d-godot/godot" && find . ../src -name '*.os' -delete && find . ../src -name '*.o' -delete && rm -f .sconsign.dblite)
	(cd "$root/engine/box3d-godot/godot" && scons -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)" platform=web threads=no target=template_release)
	cp "$root/engine/box3d-godot/godot/demo/addons/box3d/bin/$ext" "$root/game/bin/"
fi
"$GODOT" --headless --path "$root/game" --import >/dev/null 2>&1 || true
"$GODOT" --headless --path "$root/game" --import >/dev/null 2>&1
mkdir -p "$root/web"
"$GODOT" --headless --path "$root/game" --export-release "Web" ../web/index.html >/dev/null 2>&1
cp "$root/game/web/coi-serviceworker.js" "$root/web/"
ls -la "$root/web" | grep -E 'index\.(pck|wasm|side\.wasm|js)$'
