// Emscripten MODULARIZE + EXPORT_ES6 factory, built by native/box3d/build.sh.
declare const createBox3D: (options?: {
  locateFile?: (path: string) => string;
  wasmBinary?: ArrayBuffer | Uint8Array;
}) => Promise<unknown>;
export default createBox3D;
