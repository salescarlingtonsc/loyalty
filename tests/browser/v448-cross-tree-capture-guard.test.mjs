/* V448 — REG-009: the cross-tree capture guard.
 *
 * verify-v104-promotions-visual.mjs and verify-v142-connect-paynow.mjs fetch their fixture over
 * HTTP, defaulting to port 4173 — a port shared by sibling worktrees and other sessions' own
 * regen servers. If some OTHER session's server answers on that port, the capture used to fetch
 * THEIR fixture, screenshot THEIR render, and print PASS: a real incident (AUDIT-MAP REG-009).
 *
 * This file proves, two ways, that scripts/quality/fixture-cross-tree-guard.mjs actually stops
 * that:
 *   (a) unit-level, against the guard function itself, with a real tiny HTTP server — a matching
 *       fixture resolves, a mismatched one rejects with a message naming both hashes, and an
 *       unreachable server rejects with a guard-labelled message rather than a raw ECONNREFUSED;
 *   (b) end-to-end, by actually spawning the two real capture scripts with their fixture URL env
 *       var pointed at a server deliberately serving the WRONG bytes, and asserting the process
 *       exits non-zero with the guard's message — proving the wiring inside the scripts, not
 *       just the helper they import. Neither capture script needs a browser driver for this: the
 *       guard runs before either script even imports playwright, so this negative control does
 *       not require Chrome to be installed.
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
const V142_FIXTURE = new URL('./v142-connect-paynow-visual.html', import.meta.url);

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
        assert.match(error.message, /does NOT match/);
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

test('verify-v142: a wrong-tree fixture server makes the real capture script abort loudly, no browser needed', async () => {
  const server = await serveBytes('<!doctype html><title>another session\'s v142 fixture</title>');
  try {
    const { code, stdout, stderr } = await runNode('tests/browser/verify-v142-connect-paynow.mjs', {
      ...process.env,
      V142_FIXTURE_URL: server.url,
      PLAYWRIGHT_MODULE: '/nonexistent/would-fail-if-ever-imported/index.js',
    });
    assert.notEqual(code, 0, 'the capture must exit non-zero');
    assert.match(stdout + stderr, /CROSS-TREE CAPTURE GUARD \(v142\)/);
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
