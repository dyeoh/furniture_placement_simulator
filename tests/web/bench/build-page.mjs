// Assemble the bench page into [out] (default ../../../web/bench): the static
// page plus scenarios.js, serialised from scenarios.mjs so the browser and the
// Node drivers share one set of scenarios.
//
//   node tests/web/bench/build-page.mjs [out]

import fs from 'node:fs';
import path from 'node:path';
import { SCENARIOS } from './scenarios.mjs';

const here = path.dirname(new URL(import.meta.url).pathname);
const out = path.resolve(process.argv[2] || path.join(here, '../../../web/bench'));
fs.mkdirSync(out, { recursive: true });
for (const f of ['index.html', 'bench.js']) fs.copyFileSync(path.join(here, 'page', f), path.join(out, f));
fs.writeFileSync(path.join(out, 'scenarios.js'), `window.BENCH_SCENARIOS = ${JSON.stringify(SCENARIOS)};\n`);
console.log(`bench page -> ${out}`);
