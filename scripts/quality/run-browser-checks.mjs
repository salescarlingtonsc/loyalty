#!/usr/bin/env node
/**
 * Run the real-browser walkthroughs.  `npm run test:browser`
 *
 * WHY IT EXISTS: tests/browser/verify-reward-overview-owner.mjs drives the Rewards owner page in
 * a real Chromium and asserts on measured layout, console errors and RPC usage — the only check
 * in the repo that can see the page actually render. Nothing ran it. It was not in `npm test`
 * (it is not a node:test file), not in CI, and not in any npm script, so it sat unrun long
 * enough for its expectations to freeze several releases behind the page.
 *
 * PLAYWRIGHT IS NOT VENDORED, DELIBERATELY. It is a ~100 MB dependency with its own browser
 * download, and this repo ships a static app. So this runner LOOKS for a browser driver and
 * says loudly what it found:
 *
 *   - $PLAYWRIGHT_MODULE   an absolute path to a playwright / playwright-core entry point
 *                          (e.g. .../node_modules/playwright-core/index.js — the index file,
 *                          not the package directory)
 *   - a resolvable `playwright` or `playwright-core` in node_modules
 *
 * and, for the browser binary itself, $PLAYWRIGHT_EXECUTABLE_PATH — required when using
 * playwright-core, which ships no browsers.
 *
 * When neither resolves it SKIPS and exits 0, printing exactly what to set. That is a
 * deliberate choice: failing the build on a machine that was never going to have Chromium turns
 * a coverage gap into a workflow blocker, and the thing this whole change is about is making
 * gaps visible instead of silent. CI installs the driver and gets the real run; the skip banner
 * is loud enough that "it skipped" cannot be mistaken for "it passed".
 *
 * The fixture is served over http (not file://) because the page fetches its own assets. The
 * server binds an EPHEMERAL port rather than 4173: that port is used by
 * scripts/quality/regen-visual-fixtures.mjs and by other checkouts of this repo, and a
 * collision there fails with a confusing 404 rather than "address in use".
 */
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const require = createRequire(join(repoRoot, 'package.json'));

const CHECKS = [
  {
    script: 'tests/browser/verify-reward-overview-owner.mjs',
    urlEnv: 'REWARD_OVERVIEW_FIXTURE_URL',
    fixture: '/tests/browser/reward-overview-owner-visual.html',
  },
  /* V448 (REG-009): verify-v441-preview-dock-scope.mjs boots the REAL app (real router, real
     bundles), which needs app/ as its docroot — the chunks it loads are absolute paths like
     /app-core.js?b=… that only resolve when the server root IS app/, not the repo root this
     runner's own server serves for the reward-overview check above. Rather than force it through
     that repo-root server (which would require a docroot it cannot use), it is `standalone`:
     the script already spawns and probes its OWN docroot=app/ server (on its own port, 4441 by
     default, distinct from this runner's ephemeral one), so it only needs the resolved
     playwright driver forwarded — no fixture/urlEnv wiring. This was previously runnable only by
     hand; registering it here puts it in `npm run test:browser`, which is already the job CI
     runs (.github/workflows/production-baseline.yml, "browser-walkthrough"), so no separate
     workflow or npm script was needed. */
  {
    script: 'tests/browser/verify-v441-preview-dock-scope.mjs',
    standalone: true,
  },
];

function resolvePlaywright() {
  if (process.env.PLAYWRIGHT_MODULE) {
    return { specifier: process.env.PLAYWRIGHT_MODULE, source: '$PLAYWRIGHT_MODULE' };
  }
  for (const name of ['playwright', 'playwright-core']) {
    try {
      return { specifier: require.resolve(name), source: `node_modules/${name}` };
    } catch { /* not installed */ }
  }
  return null;
}

function skip(reason) {
  const line = '='.repeat(78);
  process.stdout.write([
    '', line,
    'BROWSER CHECKS SKIPPED — NOT PASSED.',
    line,
    `  ${reason}`,
    '',
    '  These are the only checks that render the Rewards owner page in a real browser.',
    '  Skipping them means nothing was verified about how that page actually paints.',
    '',
    '  To run them, point the runner at a driver and a browser binary:',
    '',
    '    npm i -D playwright && npx playwright install chromium',
    '    npm run test:browser',
    '',
    '  or, with an existing playwright-core somewhere on this machine:',
    '',
    '    PLAYWRIGHT_MODULE=/abs/path/to/playwright-core/index.js \\',
    '    PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \\',
    '    npm run test:browser',
    '',
    '  PLAYWRIGHT_MODULE must be the entry FILE, not the package directory.',
    line, '',
  ].join('\n'));
}

const driver = resolvePlaywright();
if (!driver) {
  skip('No playwright module resolved (checked $PLAYWRIGHT_MODULE, playwright, playwright-core).');
  process.exit(0);
}
/* playwright-core ships no browsers. Launching it without an executable path fails deep inside
   the driver with a message about a missing revision, which reads like a broken test. */
if (/playwright-core/.test(driver.specifier) && !process.env.PLAYWRIGHT_EXECUTABLE_PATH) {
  skip(
    `Found playwright-core (${driver.source}) but no $PLAYWRIGHT_EXECUTABLE_PATH. `
    + 'playwright-core ships no browser binary, so there is nothing to launch.'
  );
  process.exit(0);
}
process.stdout.write(`Browser driver: ${driver.specifier}  (via ${driver.source})\n`);

const MIME = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.css': 'text/css', '.json': 'application/json', '.png': 'image/png',
  '.svg': 'image/svg+xml', '.webmanifest': 'application/manifest+json',
};

const server = createServer(async (req, res) => {
  try {
    const path = normalize(decodeURIComponent(req.url.split('?')[0])).replace(/^(\.\.[/\\])+/, '');
    const file = join(repoRoot, path);
    if (!file.startsWith(repoRoot)) { res.writeHead(403); return res.end(); }
    const body = await readFile(file);
    res.writeHead(200, { 'content-type': MIME[extname(file)] || 'application/octet-stream' });
    res.end(body);
  } catch { res.writeHead(404); res.end('not found'); }
});

const run = (script, env) => new Promise((ok, fail) => {
  const child = spawn(process.execPath, [script], { cwd: repoRoot, stdio: 'inherit', env });
  child.on('error', fail);
  child.on('exit', code => (code === 0 ? ok() : fail(new Error(`${script} exited ${code}`))));
});

let failed = 0;
await new Promise(ok => server.listen(0, '127.0.0.1', ok));
const { port } = server.address();
try {
  for (const check of CHECKS) {
    process.stdout.write(`\n── ${check.script}\n`);
    const env = check.standalone
      ? { ...process.env, PLAYWRIGHT_MODULE: driver.specifier }
      : {
          ...process.env,
          PLAYWRIGHT_MODULE: driver.specifier,
          [check.urlEnv]: `http://127.0.0.1:${port}${check.fixture}`,
        };
    try {
      await run(check.script, env);
      process.stdout.write(`   ok\n`);
    } catch (error) {
      failed += 1;
      process.stdout.write(`   FAILED: ${error.message}\n`);
    }
  }
} finally {
  server.close();
}

if (failed) {
  process.stdout.write(`\n${failed} browser check(s) failed.\n`);
  process.exit(1);
}
process.stdout.write('\nAll browser checks passed.\n');
