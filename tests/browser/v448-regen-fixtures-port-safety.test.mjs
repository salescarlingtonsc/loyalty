/* V448 — REG-009: port safety in scripts/quality/regen-visual-fixtures.mjs.
 *
 * The regen script used to hardcode PORT=4173 and never tell the two Chrome-capture scripts
 * what URL to hit — they fell back to their OWN 4173 default. That happened to line up, but it
 * is exactly the "trust the shared default" assumption that let one session's capture silently
 * record another session's tree (REG-009; see fixture-cross-tree-guard.mjs). This file proves,
 * executing the real code, that the fix holds:
 *
 *   (a) visual-fixture-urls.mjs derives V104_FIXTURE_URL / V142_FIXTURE_URL from whatever port
 *       is passed in — not a baked-in 4173 — so regen-visual-fixtures.mjs cannot regress to
 *       silently defaulting again;
 *   (b) NEGATIVE CONTROL, the real script: with a port already bound by something else, running
 *       `node scripts/quality/regen-visual-fixtures.mjs PORT=<taken>` refuses to start rather
 *       than colliding with whatever else is listening, and says so.
 *   (c) POSITIVE CONTROL, the real script: on a free, caller-chosen port it binds successfully
 *       (proving $PORT is honoured, not just the 4173 default).
 *
 * (b)/(c) run the real generator scripts (fast — no browser — and verified separately to
 * reproduce byte-identical fixtures on this tree), then hit the bind step; the Chrome-capture
 * phase after that needs a browser driver this environment may not have in CI, so the process is
 * killed right after the bind step's outcome is observed rather than waiting for that phase.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { visualFixtureUrls } from '../../scripts/quality/visual-fixture-urls.mjs';

const root = fileURLToPath(new URL('../../', import.meta.url));

test('visualFixtureUrls derives both URLs from the given port, not a hardcoded one', () => {
  assert.deepEqual(visualFixtureUrls(4173), {
    V104_FIXTURE_URL: 'http://127.0.0.1:4173/tests/browser/v104-promotions-visual.html',
    V142_FIXTURE_URL: 'http://127.0.0.1:4173/tests/browser/v142-connect-paynow-visual.html',
  });
  // A different port produces different URLs — proves it is a real function of the input, not a
  // constant that happens to print 4173.
  const other = visualFixtureUrls(48173);
  assert.equal(other.V104_FIXTURE_URL, 'http://127.0.0.1:48173/tests/browser/v104-promotions-visual.html');
  assert.equal(other.V142_FIXTURE_URL, 'http://127.0.0.1:48173/tests/browser/v142-connect-paynow-visual.html');
});

async function freePort() {
  return new Promise((resolve, reject) => {
    const probe = createServer();
    probe.once('error', reject);
    probe.listen(0, '127.0.0.1', () => {
      const { port } = probe.address();
      probe.close(() => resolve(port));
    });
  });
}

/** Runs the real regen script, killing it once it has either bound the server or refused to. */
function runRegenUntilBindOutcome(port) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, ['scripts/quality/regen-visual-fixtures.mjs'], {
      cwd: root,
      env: { ...process.env, PORT: String(port) },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let output = '';
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(safetyNet);
      child.kill('SIGKILL');
      resolve(result);
    };
    child.stdout.on('data', d => { output += d; check(); });
    child.stderr.on('data', d => { output += d; check(); });
    child.on('exit', code => finish({ code, output }));
    function check() {
      // Bind refused: the script throws and exits — the 'exit' handler above resolves it.
      // Bind succeeded: nothing in the script prints a "listening" line, so instead detect that
      // it has moved past the generator phase (its own progress log) into the capture phase.
      if (/\(Chrome capture\)/.test(output)) finish({ code: null, output, bound: true });
    }
    // Safety net so a genuinely hung process cannot leave the suite waiting forever.
    const safetyNet = setTimeout(() => finish({ code: null, output, timedOut: true }), 20000);
  });
}

test('regen-visual-fixtures: refuses to start when $PORT is already bound by something else', async () => {
  const port = await freePort();
  const blocker = createServer((q, r) => r.end('occupying this port'));
  await new Promise((ok, fail) => { blocker.once('error', fail); blocker.listen(port, '127.0.0.1', ok); });
  try {
    const { code, output } = await runRegenUntilBindOutcome(port);
    assert.notEqual(code, 0, 'must exit non-zero rather than colliding with the occupied port');
    assert.match(output, /already bound by something else/);
    assert.match(output, /ANOTHER SESSION'S server/);
    assert.doesNotMatch(output, /\(Chrome capture\)/, 'must never reach the capture phase on a blocked port');
  } finally { await new Promise(ok => blocker.close(ok)); }
}, { timeout: 25000 });

test('regen-visual-fixtures: binds and proceeds on a free, caller-chosen $PORT (not just 4173)', async () => {
  const port = await freePort();
  const { output, bound, timedOut } = await runRegenUntilBindOutcome(port);
  assert.ok(!timedOut, `did not observe a bind outcome within the timeout:\n${output.slice(-800)}`);
  assert.ok(bound, `expected the script to reach the Chrome-capture phase on a free port:\n${output.slice(-800)}`);
  assert.doesNotMatch(output, /already bound by something else/);
}, { timeout: 25000 });
