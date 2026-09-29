#!/bin/sh
# Compile Box3D (the engine submodule's C sources) plus shim.c to a
# single-threaded wasm module for the Three.js build.
#
# Same toolchain pin and flags as the Godot web extension
# (.github/workflows/deploy-web.yml, engine/box3d-godot/godot/SConstruct):
# Emscripten 4.0.11, -msimd128 -msse2 (Box3D maps wasm onto its SSE2 path),
# no threads. Needs emsdk: EMSDK=~/emsdk by default.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
box3d="$root/engine/box3d-godot"
out="$here/../../src/physics/box3d"

if ! command -v emcc >/dev/null 2>&1; then
	EMSDK=${EMSDK:-$HOME/emsdk}
	# emsdk needs Python >= 3.10; macOS's CommandLineTools python is 3.9.
	if [ -z "${EMSDK_PYTHON:-}" ] && command -v python3.14 >/dev/null 2>&1; then
		export EMSDK_PYTHON=$(command -v python3.14)
	fi
	. "$EMSDK/emsdk_env.sh" >/dev/null
fi

mkdir -p "$out"
emcc -O3 -flto -msimd128 -msse2 -DNDEBUG -DBOX3D_NO_THREADS \
	-I"$box3d/include" -I"$box3d/src" \
	"$box3d"/src/*.c "$here/shim.c" \
	-sMODULARIZE=1 -sEXPORT_ES6=1 -sENVIRONMENT=web,worker \
	-sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=33554432 \
	-sFILESYSTEM=0 -sASSERTIONS=0 \
	-sEXPORTED_FUNCTIONS=_malloc,_free \
	-sEXPORTED_RUNTIME_METHODS=HEAPF32,HEAP32 \
	-o "$out/box3d.js"
ls -la "$out"/box3d.*
