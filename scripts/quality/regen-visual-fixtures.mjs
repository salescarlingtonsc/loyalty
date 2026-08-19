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
 * DELIBERATELY EXCLUDED: tests/browser/reward-overview-owner-visual.html and
 * tests/browser/v181-onboarding-board.html were already stale before the 2026-08-18 UI standard
 * work, and their tests do not assert byte equality, so they pass either way. Regenerating them
 * sweeps ~400 lines of unrelated drift into your diff. They are worth a separate look; until
 * then this script restores them to HEAD so they stay out of the way.
 */
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readdirSync } from 'node:fs';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const PORT = 4173;
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

  await run('git', ['checkout', '--',
    'tests/browser/reward-overview-owner-visual.html',
    'tests/browser/v181-onboarding-board.html'], { stdio: 'ignore' }).catch(() => {});

  await new Promise(ok => server.listen(PORT, '127.0.0.1', ok));
  const env = { ...process.env, PLAYWRIGHT_EXECUTABLE_PATH: CHROME };
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
