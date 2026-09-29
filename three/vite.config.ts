import { defineConfig, type Plugin } from 'vite';
import fs from 'node:fs';
import path from 'node:path';

// The Godot project's assets and catalogue are served as-is, never copied into
// this tree: both stacks must load byte-identical models, textures and data or
// the benchmark compares different content. Dev serves them from ../game; the
// build copies them next to the bundle.
const GAME = path.resolve(import.meta.dirname, '../game');
const SHARED = ['assets/models', 'assets/textures', 'data'];
const SKIP = /\.(import|uid)$/;

const MIME: Record<string, string> = {
  '.json': 'application/json', '.gltf': 'model/gltf+json', '.bin': 'application/octet-stream',
  '.jpg': 'image/jpeg', '.png': 'image/png',
};

function sharedGameFiles(): Plugin {
  return {
    name: 'shared-game-files',
    configureServer(server) {
      server.middlewares.use((req, res, next) => {
        const url = decodeURIComponent((req.url || '').split('?')[0]).replace(/^\//, '');
        if (!SHARED.some((dir) => url.startsWith(dir + '/')) || SKIP.test(url)) return next();
        const file = path.join(GAME, url);
        if (!file.startsWith(GAME) || !fs.existsSync(file)) return next();
        res.setHeader('Content-Type', MIME[path.extname(file)] || 'application/octet-stream');
        fs.createReadStream(file).pipe(res);
      });
    },
    writeBundle(options) {
      const out = options.dir || 'dist';
      for (const dir of SHARED) {
        fs.cpSync(path.join(GAME, dir), path.join(out, dir), {
          recursive: true,
          filter: (src) => !SKIP.test(src),
        });
      }
    },
  };
}

export default defineConfig({
  // Relative, so the build works under /three/ on Pages and from a file server.
  base: './',
  publicDir: false,
  plugins: [sharedGameFiles()],
  build: {
    target: 'es2022',
    // Keep wasm as a separate, cacheable file rather than inlined base64.
    assetsInlineLimit: 0,
    reportCompressedSize: true,
  },
  server: { port: 5174 },
});
