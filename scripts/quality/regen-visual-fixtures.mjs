#!/usr/bin/env node
/**
 * Regenerate the browser visual fixtures and re-capture the two Chrome evidence sets.
 *
 *   node scripts/quality/regen-visual-fixtures.mjs
 *
 * WHEN YOU NEED THIS: after ANY change to app/index.html CSS or to a render function in
 * app/app.js. Eight fixtures under tests/browser/ embed a verbatim copy of the production
 * stylesheet plus a SHA-256 of the source they were built from, and two tests compare against
 * real Chrome measurements captured from those fixtures. Skip this and the suite fails with
 * "must come from current production source" — which is the fixture being stale, not a bug in
 * your change.
 *
 * Run `npm run bundle-stamp` FIRST if you edited app/app.js, so the generated surface bundles
 * are current before the fixtures are rebuilt from them.
 *
 * EXPECT NOISE FROM v142: its capture mints fresh idempotency UUIDs on every run, so
 * docs/qa/evidence/v142-connect-paynow-pos/ always shows a diff even when nothing changed.
 * Check `git diff` on its metrics.json before committing — if the only differences are
 * *_idempotency_key values, revert that directory rather than committing the churn.
 *
 * PREVIOUSLY EXCLUDED, NOW REGENERATED: this script used to `git checkout --` two fixtures
 * back to HEAD after generating them — reward-overview-owner-visual.html and
 * v181-onboarding-board.html — because their tests did not assert byte equality and the drift
 * was noisy. The first of those is the Rewards owner page, and holding it 33 hunks behind
 * production is exactly how a Rewards regression stays invisible: its only test read a SHA out
 * of the stale artifact, so regenerating it FAILED the suite and staying stale passed it. It is
 * now covered by tests/business-ui/reward-overview-fixture-parity.test.mjs, which asserts byte
 * equality the way the other six fixtures do, and nothing is checked out any more.
 *
 * tests/browser/v181-onboarding-board.html is generated here too, and (nestly_v448) is now
 * covered the same way: tests/business-ui/v181-onboarding-board-fixture-parity.test.mjs asserts
 * byte equality against buildOnboardingBoardVisualFixture(), exported from
 * tests/browser/generate-v181-onboarding-board-visual.mjs for that purpose.
 *
 * PORT SAFETY (nestly_v448, REG-009). This used to hardcode PORT=4173 and NOT tell the two
 * Chrome-capture scripts what URL to hit, so they fell back to their own 4173 default — which
 * happened to line up here, but is exactly the shared-port assumption that let one session's
 * capture silently record another session's tree when the two DIDN'T agree (see
 * fixture-cross-tree-guard.mjs). Now: PORT is overridable via $PORT (default stays 4173 for
 * back-compat); the server refuses to start if that port is already bound by something else,
 * rather than colliding with it; and V104_FIXTURE_URL / V142_FIXTURE_URL are always set to THIS
 * run's own server, so the captures can never coast on a same-numbered default.
 */
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readdirSync } from 'node:fs';
import { visualFixtureUrls } from './visual-fixture-urls.mjs';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const PORT = Number(process.env.PORT || 4173);
const CHROME = process.env.PLAYWRIGHT_EXECUTABLE_PATH
  || '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';

/* The fixtures these two verify scripts measure are served over http, not file://, because the
   pages fetch their own assets. A tiny static server for the repo root is all they need. */
const MIME = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.css': 'text/css', '.json': 'application/json', '.png': 'image/png',
  '.svg': 'image/svg+xml', '.webmanifest': 'application/manifest+json',
};

function run(cmd, args, opts = {}) {
  return new Promise((ok, fail) => {
    const child = spawn(cmd, args, { cwd: repoRoot, stdio: 'inherit', ...opts });
    child.on('exit', code => (code === 0 ? ok() : fail(new Error(`${cmd} ${args.join(' ')} exited ${code}`))));
    child.on('error', fail);
  });
}

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

try {
  const generators = readdirSync(join(repoRoot, 'tests/browser'))
    .filter(name => name.startsWith('generate-') && name.endsWith('.mjs'))
    .sort();
  for (const name of generators) {
    process.stdout.write(`  ${name}\n`);
    await run(process.execPath, [join('tests/browser', name)], { stdio: 'ignore' });
  }

  await new Promise((resolveListen, rejectListen) => {
    const onError = (error) => { server.removeListener('listening', onListening); rejectListen(error); };
    const onListening = () => { server.removeListener('error', onError); resolveListen(); };
    server.once('error', onError);
    server.once('listening', onListening);
    server.listen(PORT, '127.0.0.1');
  }).catch(error => {
    if (error && error.code === 'EADDRINUSE') {
      throw new Error(
        `Port ${PORT} is already bound by something else — refusing to start. That is very likely `
        + `ANOTHER SESSION'S server (4173 is the shared default across worktrees; see REG-009), and `
        + `this script's own captures must hit only ITS OWN server, never whatever else answers `
        + `that port. Re-run with PORT=<a free port> node scripts/quality/regen-visual-fixtures.mjs.`
      );
    }
    throw error;
  });
  const env = {
    ...process.env,
    PLAYWRIGHT_EXECUTABLE_PATH: CHROME,
    /* Always point the captures at THIS run's own server, by construction — never at whatever
       happens to default inside the capture scripts themselves. */
    ...visualFixtureUrls(PORT),
  };
  for (const script of [
    'tests/browser/verify-v104-promotions-visual.mjs',
    'tests/browser/verify-v142-connect-paynow.mjs',
  ]) {
    process.stdout.write(`  ${script.split('/').pop()} (Chrome capture)\n`);
    await run(process.execPath, [script], { env, stdio: 'ignore' });
  }
  process.stdout.write('\nFixtures and Chrome evidence regenerated. Run `npm test` next.\n');
} finally {
  server.close();
}
