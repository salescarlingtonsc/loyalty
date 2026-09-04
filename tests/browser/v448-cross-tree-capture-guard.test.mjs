/* V448/V459 — REG-009: the cross-tree capture guard.
 *
 * verify-v104-promotions-visual.mjs fetches its fixture over
 * HTTP, defaulting to port 4173 — a port shared by sibling worktrees and other sessions' own
 * regen servers. If some OTHER session's server answers on that port, the capture used to fetch
 * THEIR fixture, screenshot THEIR render, and print PASS: a real incident (AUDIT-MAP REG-009).
 *
 * This file proves, several ways, that scripts/quality/fixture-cross-tree-guard.mjs actually
 * stops that:
 *   (a) unit-level, against the guard function itself, with a real tiny HTTP server — a matching
 *       fixture resolves, a mismatched one rejects with a message naming both hashes, and an
 *       unreachable server rejects with a guard-labelled message rather than a raw ECONNREFUSED;
 *   (b) end-to-end, by actually spawning the real capture script with its fixture URL env var
 *       pointed at a server deliberately serving the WRONG bytes, and asserting the process
 *       exits non-zero with the guard's message — proving the wiring inside the script, not
 *       just the helper it imports. The capture script needs no browser driver for this: the
 *       guard runs before it even imports playwright, so this negative control does not require
 *       Chrome to be installed;
 *   (c) NESTLY_V459 — the two-marker poll, mirroring the failure Agent B hit that (a)/(b) do not
 *       cover: a static file server can keep answering from a DELETED docroot's stale inode
 *       forever, with no error. assertFixtureMatchesTree() now polls (bounded attempts, not one
 *       shot) and — when markers are supplied — separately verifies a named CSS marker and a
 *       named JS marker, not just the byte hash. Proved below: the poll actually retries (a
 *       server that starts wrong and turns correct mid-poll is accepted); a locally-wrong marker
 *       fails fast with its own diagnostic (not a hash mismatch); and the env-override on the
 *       real capture scripts (V104_CSS_MARKER etc.) lets the SAME script be aimed at a
 *       byte-identical-but-conceptually-unfixed tree for a negative control — a hash match alone
 *       would have let this through.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { assertFixtureMatchesTree } from '../../scripts/quality/fixture-cross-tree-guard.mjs';

const root = new URL('../../', import.meta.url);
const V104_FIXTURE = new URL('./v104-promotions-visual.html', import.meta.url);

/** Serves fixed `body` bytes for every request until closed. Returns {url, close}. */
async function serveBytes(body) {
  const server = createServer((req, res) => { res.writeHead(200, { 'content-type': 'text/html' }); res.end(body); });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const { port } = server.address();
  return { url: `http://127.0.0.1:${port}/fixture.html`, close: () => new Promise(ok => server.close(ok)) };
}

function runNode(scriptPath, env) {
  return new Promise(resolve => {
    const child = spawn(process.execPath, [scriptPath], { cwd: fileURLToPath(root), env, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.on('data', d => { stdout += d; });
    child.stderr.on('data', d => { stderr += d; });
    child.on('exit', code => resolve({ code, stdout, stderr }));
  });
}

/* --------------------------------------------------------- (a) the guard function, unit-level */

test('assertFixtureMatchesTree resolves when the served bytes match the local fixture', async () => {
  const bytes = await readFile(V104_FIXTURE);
  const server = await serveBytes(bytes);
  try {
    await assert.doesNotReject(
      assertFixtureMatchesTree({ servedUrl: server.url, localFixtureUrl: V104_FIXTURE, label: 'v104' })
    );
  } finally { await server.close(); }
});

test('assertFixtureMatchesTree REJECTS when the served bytes are a different tree\'s fixture', async () => {
  const server = await serveBytes('<!doctype html><title>a different session\'s build</title>');
  try {
    await assert.rejects(
      assertFixtureMatchesTree({ servedUrl: server.url, localFixtureUrl: V104_FIXTURE, label: 'v104' }),
      error => {
        assert.match(error.message, /CROSS-TREE CAPTURE GUARD \(v104\)/);
        assert.match(error.message, /sha256 [a-f0-9]{64}/);
        assert.match(error.message, /never matched/);
        return true;
      }
    );
  } finally { await server.close(); }
});

test('assertFixtureMatchesTree REJECTS with a guard-labelled message when the server is unreachable', async () => {
  const server = await serveBytes('anything');
  await server.close(); // now nothing is listening on server.url
  await assert.rejects(
    assertFixtureMatchesTree({ servedUrl: server.url, localFixtureUrl: V104_FIXTURE, label: 'v104' }),
    error => {
      assert.match(error.message, /CROSS-TREE CAPTURE GUARD \(v104\)/);
      assert.match(error.message, /could not fetch/);
      return true;
    }
  );
});

/* ------------------------------------------------------ (b) the real capture scripts, end-to-end */

test('verify-v104: a wrong-tree fixture server makes the real capture script abort loudly, no browser needed', async () => {
  const server = await serveBytes('<!doctype html><title>another session\'s v104 fixture</title>');
  try {
    const { code, stdout, stderr } = await runNode('tests/browser/verify-v104-promotions-visual.mjs', {
      ...process.env,
      V104_FIXTURE_URL: server.url,
      PLAYWRIGHT_MODULE: '/nonexistent/would-fail-if-ever-imported/index.js',
    });
    assert.notEqual(code, 0, 'the capture must exit non-zero');
    assert.match(stdout + stderr, /CROSS-TREE CAPTURE GUARD \(v104\)/);
    // Proves the guard ran BEFORE the (deliberately broken) playwright import was ever reached.
    assert.doesNotMatch(stdout + stderr, /would-fail-if-ever-imported/);
  } finally { await server.close(); }
});

test('verify-v104: a matching fixture server passes the guard (proceeds to the playwright import)', async () => {
  const bytes = await readFile(V104_FIXTURE);
  const server = await serveBytes(bytes);
  try {
    // A deliberately-broken PLAYWRIGHT_MODULE: if the guard passes, the script proceeds to
    // `import(...)` that path and fails there instead — proving the guard did NOT fire on a
    // correct fixture, without needing a real browser driver installed.
    const { stdout, stderr } = await runNode('tests/browser/verify-v104-promotions-visual.mjs', {
      ...process.env,
      V104_FIXTURE_URL: server.url,
      PLAYWRIGHT_MODULE: '/nonexistent/proves-the-guard-passed/index.js',
    });
    const output = stdout + stderr;
    assert.doesNotMatch(output, /CROSS-TREE CAPTURE GUARD/, 'the guard must not fire on a byte-identical fixture');
    assert.match(output, /proves-the-guard-passed/, 'execution must have reached the playwright import');
  } finally { await server.close(); }
});

/* ------------------------------------------------------------- (c) the two-marker poll (V459) */

/** Serves `firstBody` for the first `switchAfter` requests, then `secondBody` forever. Models a
 *  server transitioning from stale to fresh mid-poll. */
async function serveBytesThatChange(firstBody, secondBody, switchAfter) {
  let count = 0;
  const server = createServer((req, res) => {
    count += 1;
    res.writeHead(200, { 'content-type': 'text/html' });
    res.end(count <= switchAfter ? firstBody : secondBody);
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const { port } = server.address();
  return { url: `http://127.0.0.1:${port}/fixture.html`, close: () => new Promise(ok => server.close(ok)) };
}

test('assertFixtureMatchesTree POLLS: a server that starts wrong and becomes correct mid-poll is accepted, not failed on the first miss', async () => {
  const bytes = await readFile(V104_FIXTURE);
  // Wrong for the first 2 requests, correct from the 3rd — well inside the default 8-attempt budget.
  const server = await serveBytesThatChange('<!doctype html><title>stale</title>', bytes, 2);
  try {
    await assert.doesNotReject(
      assertFixtureMatchesTree({ servedUrl: server.url, localFixtureUrl: V104_FIXTURE, label: 'v104', delayMs: 20 }),
      'a transiently-stale server (e.g. mid-restart) must be accepted once it starts answering correctly, not rejected on the very first poll'
    );
  } finally { await server.close(); }
});

test('assertFixtureMatchesTree with markers: a locally-wrong marker fails immediately with its own diagnostic (not a network error)', async () => {
  const bytes = await readFile(V104_FIXTURE);
  const server = await serveBytes(bytes);
  const start = Date.now();
  try {
    await assert.rejects(
      assertFixtureMatchesTree({
        servedUrl: server.url, localFixtureUrl: V104_FIXTURE, label: 'v104',
        markers: { css: '.this-css-rule-does-not-exist-anywhere', js: 'function customerPromotionCardV104' },
      }),
      error => {
        assert.match(error.message, /CROSS-TREE CAPTURE GUARD \(v104\)/);
        assert.match(error.message, /CSS marker itself does not appear/);
        return true;
      }
    );
    // Must fail on the local pre-check, before ever polling the network — proven by elapsed time
    // staying far under what 8 network polls at the default 250ms delay would take.
    assert.ok(Date.now() - start < 500, 'a locally-wrong marker must be caught before any network poll, not after exhausting the poll budget');
  } finally { await server.close(); }
});

test('assertFixtureMatchesTree with markers: a served fixture missing the JS marker (despite a correct CSS marker) fails, naming which half', async () => {
  // A hand-built page that is NOT the real fixture, so its hash will not match either — but it
  // carries the CSS marker while omitting the JS one, so the failure message's per-marker
  // breakdown can be checked independently of the hash mismatch it also reports.
  const server = await serveBytes(
    '<style>.customer-promotion-card{position:relative;overflow:hidden;border-radius:18px}</style><script>/* no v104 function here */</script>'
  );
  try {
    await assert.rejects(
      assertFixtureMatchesTree({
        servedUrl: server.url, localFixtureUrl: V104_FIXTURE, label: 'v104', delayMs: 20,
        markers: {
          css: '.customer-promotion-card{position:relative;overflow:hidden;border-radius:18px',
          js: 'function customerPromotionCardV104',
        },
      }),
      error => {
        assert.match(error.message, /CSS marker OK/, 'the CSS half really did match — this failure is about the JS half specifically');
        assert.match(error.message, /JS marker MISSING/);
        return true;
      }
    );
  } finally { await server.close(); }
});

test('verify-v104: V104_CSS_MARKER env override lets the SAME script reject a byte-identical-but-conceptually-unfixed tree', async () => {
  // The server serves the REAL, byte-identical, hash-matching v104 fixture — proving that a hash
  // match alone is not what this test is exercising. The override names a CSS rule this fixture
  // does not currently carry (standing in for "the marker an older/different build would need"),
  // which is exactly the "negative control against an unfixed tree" the marker override exists
  // for: the same script, pointed at the same correct URL, now refuses because the marker it was
  // told to require is absent.
  const bytes = await readFile(V104_FIXTURE);
  const server = await serveBytes(bytes);
  try {
    const { code, stdout, stderr } = await runNode('tests/browser/verify-v104-promotions-visual.mjs', {
      ...process.env,
      V104_FIXTURE_URL: server.url,
      V104_CSS_MARKER: '.this-css-rule-belongs-to-an-unfixed-tree-only',
      PLAYWRIGHT_MODULE: '/nonexistent/would-fail-if-ever-imported/index.js',
    });
    assert.notEqual(code, 0, 'must reject despite the byte hash matching, because the required marker is absent');
    assert.match(stdout + stderr, /CROSS-TREE CAPTURE GUARD \(v104\)/);
    assert.match(stdout + stderr, /CSS marker itself does not appear/);
    assert.doesNotMatch(stdout + stderr, /would-fail-if-ever-imported/);
  } finally { await server.close(); }
});
