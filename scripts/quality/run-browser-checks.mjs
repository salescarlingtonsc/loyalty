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
 * SECOND PHASE (nestly_v888): the node:test files that need a driver.
 * `npm test` runs these too, but each one SKIPS ITSELF when no driver resolves — which is how CI
 * runs them, so they report green while verifying nothing. tests/business-ui/v750-tier-dialog-
 * alignment.test.mjs sat in that state through three separate harness drifts: with a browser
 * attached it had been timing out after 30s on an empty page, and without one it skipped, so the
 * suite stayed green either way. This runner now executes them WITH the driver in the
 * environment, which is the only condition under which they actually measure anything.
 *
 * The list is DISCOVERED, never hardcoded: a fixed list is the same failure mode one level up —
 * the next browser-dependent test would be added, skip forever, and nobody would notice. Any
 * tests/ **.test.mjs that mentions a driver is picked up, and a discovery that finds NOTHING is
 * treated as a failure rather than as "all passed".
 *
 * The fixture is served over http (not file://) because the page fetches its own assets. The
 * server binds an EPHEMERAL port rather than 4173: that port is used by
 * scripts/quality/regen-visual-fixtures.mjs and by other checkouts of this repo, and a
 * collision there fails with a confusing 404 rather than "address in use".
 */
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import { createServer } from 'node:http';
import { readFile, readdir } from 'node:fs/promises';
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
    '  These are the only checks that render real pages in a real browser — the walkthroughs',
    '  above, AND the node:test files that skip themselves when no driver resolves. Skipping',
    '  them means nothing was verified about how any of those pages actually paints, and a',
    '  green `npm test` does not cover it: those files report green by not running at all.',
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

/* nestly_v888: two docroots, in production's order. Fixtures live under tests/ and are addressed
   from the repo root, but the page they embed asks for its assets the way PRODUCTION serves them —
   app/ is the docroot there, so the boot and loading marks are at /media/…. Serving only the repo
   root 404s those, which surfaces as a console error and fails the reward-overview check's
   zero-console-errors assertion for a reason that has nothing to do with the page. Falling back to
   app/ makes the harness resolve absolute asset paths exactly as the deployed site does. */
const DOCROOTS = [repoRoot, join(repoRoot, 'app')];

const server = createServer(async (req, res) => {
  const path = normalize(decodeURIComponent(req.url.split('?')[0])).replace(/^(\.\.[/\\])+/, '');
  for (const docroot of DOCROOTS) {
    const file = join(docroot, path);
    if (!file.startsWith(docroot)) continue;
    try {
      const body = await readFile(file);
      res.writeHead(200, { 'content-type': MIME[extname(file)] || 'application/octet-stream' });
      return res.end(body);
    } catch { /* try the next docroot */ }
  }
  res.writeHead(404); res.end('not found');
});

const run = (script, env) => new Promise((ok, fail) => {
  const child = spawn(process.execPath, [script], { cwd: repoRoot, stdio: 'inherit', env });
  child.on('error', fail);
  child.on('exit', code => (code === 0 ? ok() : fail(new Error(`${script} exited ${code}`))));
});

/* nestly_v888. Discovery, not a list: any node:test file that consults a browser driver is one
   that silently skips without one, and so is one this runner must execute. */
async function discoverDriverDependentTests() {
  const testsRoot = join(repoRoot, 'tests');
  const entries = await readdir(testsRoot, { recursive: true });
  const found = [];
  for (const entry of entries) {
    if (!entry.endsWith('.test.mjs')) continue;
    const relative = join('tests', entry);
    const source = await readFile(join(repoRoot, relative), 'utf8');
    if (/PLAYWRIGHT_MODULE|playwright-core/.test(source)) found.push(relative);
  }
  return found.sort();
}

const runNodeTest = (files, env) => new Promise((ok, fail) => {
  const child = spawn(process.execPath, ['--test', ...files], { cwd: repoRoot, stdio: 'inherit', env });
  child.on('error', fail);
  child.on('exit', code => (code === 0 ? ok() : fail(new Error(`node --test exited ${code}`))));
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

/* Phase two: the node:test files that would otherwise skip themselves. */
const driverTests = await discoverDriverDependentTests();
process.stdout.write(`\n── node:test files that need a driver (${driverTests.length} found)\n`);
if (!driverTests.length) {
  /* Not "nothing to do". Either the scan broke or the tests moved; both mean this runner has
     stopped covering the thing it exists to cover, and saying "all passed" would be the lie
     this whole phase was added to prevent. */
  failed += 1;
  process.stdout.write('   FAILED: none discovered — the scan or the layout of tests/ has changed.\n');
} else {
  for (const file of driverTests) process.stdout.write(`   · ${file}\n`);
  try {
    await runNodeTest(driverTests, { ...process.env, PLAYWRIGHT_MODULE: driver.specifier });
    process.stdout.write('   ok\n');
  } catch (error) {
    failed += 1;
    process.stdout.write(`   FAILED: ${error.message}\n`);
  }
}

if (failed) {
  process.stdout.write(`\n${failed} browser check(s) failed.\n`);
  process.exit(1);
}
process.stdout.write('\nAll browser checks passed.\n');
