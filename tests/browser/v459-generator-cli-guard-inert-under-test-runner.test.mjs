/* V459 — REG-009 follow-up (P1): "the gate is nondeterministic".
 *
 * WHAT WAS ACTUALLY HAPPENING (confirmed by direct reproduction, not assumption). `npm test`
 * genuinely mutated tracked fixture HTMLs, but NOT via the originally-suspected mechanism. The
 * initial theory — that bare `node --test` sweeps up every .mjs file under any directory named
 * `test` OR `tests`, so tests/browser/generate-*.mjs (none of them named *.test.mjs) would run as
 * their own test-runner children with process.argv[1] pointing at themselves, satisfying the old
 * CLI guard `process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url` — does NOT
 * hold on this Node version (confirmed against the official docs and by direct experiment below):
 * node's directory-based default pattern is `**\/test/**` — the SINGULAR `test`, not `tests`. This
 * repo's directories are all named `tests` (plural), so a bare non-test-named file living under
 * tests/browser/ is never independently discovered or executed by node's own file sweep.
 *
 * THE REAL MECHANISM: tests/browser/v448-regen-fixtures-port-safety.test.mjs — a file this very
 * REG-009 wave added — used to spawn the REAL scripts/quality/regen-visual-fixtures.mjs with
 * `cwd` pointed at the real repo root, to prove its $PORT handling. regen-visual-fixtures.mjs
 * runs its ENTIRE generator loop (all ten tests/browser/generate-*.mjs, each a genuine direct
 * invocation with a real writeFile) unconditionally, before either the "port already bound" or
 * "port free, proceeds" branch that test's two cases distinguish. So every `npm test` run
 * genuinely regenerated every checked-in fixture as a side effect of testing port-binding logic —
 * a real, reproducible, `npm test`-triggered mutation of tracked files, racing whatever OTHER
 * test happened to read those same fixtures concurrently. That file has been fixed separately (it
 * now runs the real script against an isolated sandbox via
 * scripts/quality/build-repo-test-sandbox.mjs) — see the git diff on that file for the actual
 * repair. Reproduced live on this tree: with that fix REMOVED, corrupting a fixture and running a
 * real `npm test` silently healed the corruption and reported a false PASS; restoring the fix,
 * the same corruption survived a real `npm test` run and correctly failed the byte-equality
 * parity test that owns it.
 *
 * WHY THIS FILE STILL SHIPS A CLI-INVOCATION GUARD (scripts/quality/is-direct-cli-invocation.mjs)
 * ANYWAY. The directory-sweep theory was wrong, but node's OTHER discovery rule — filename
 * matching `*.test.{mjs,js,cjs}` / `*-test.*` / `test-*.*` / `*_test.*` — is real, and several of
 * these generators have "test" in their names already (generate-v129-trial-TEST-visual.mjs,
 * generate-v105-admin-visual.mjs's sibling v105-admin-visual-fixture.TEST.mjs, etc.) — a rename
 * one character away from `*-test.mjs` is a plausible future mistake, and node's own test runner
 * would then spawn the RENAMED generator as its own child with argv[1] pointing at itself,
 * satisfying the old guard and writing mid-suite exactly the way the original theory described.
 * Guarding on NODE_TEST_CONTEXT closes that whole CLASS of exposure regardless of what a file
 * happens to be named, is free (checked once, computed already), and does not depend on filename
 * discipline holding forever. Section (c) below reproduces this real mechanism precisely: a file
 * whose NAME does match node's test pattern, carrying the pre-fix guard, does get its write
 * branch triggered by a real `node --test` run; carrying the current guard, it does not.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { mkdtemp } from 'node:fs/promises';
import { join } from 'node:path';
import { isDirectCliInvocation } from '../../scripts/quality/is-direct-cli-invocation.mjs';
import { buildRepoTestSandbox } from '../../scripts/quality/build-repo-test-sandbox.mjs';

/* This test file is ITSELF a node:test file, so process.env already carries NODE_TEST_CONTEXT
   (and NODE_TEST_WORKER_ID) from being one of node's own children. Left inherited, a spawned
   `node --test` grandchild does not behave like a fresh, standalone invocation — node's test
   runner detects the inherited context and treats it as `run()` called recursively from within a
   test file, printing a warning and SKIPPING every file rather than running them (verified: with
   NODE_TEST_CONTEXT inherited, a nested `node --test` exits 0 with empty stdout and a
   "run() is being called recursively within a test file. skipping running files." warning on
   stderr). cleanEnv() strips exactly those two variables so a spawned `node --test` behaves the
   way `npm test` actually runs: as a standalone top-level invocation, not nested inside another. */
function cleanEnv(extra = {}) {
  const env = { ...process.env, ...extra };
  delete env.NODE_TEST_CONTEXT;
  delete env.NODE_TEST_WORKER_ID;
  return env;
}

function run(cmd, args, opts = {}) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { env: cleanEnv(), ...opts, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    if (child.stdout) child.stdout.on('data', d => { stdout += d; });
    if (child.stderr) child.stderr.on('data', d => { stderr += d; });
    child.on('exit', code => resolve({ code, stdout, stderr }));
    child.on('error', error => resolve({ code: null, stdout, stderr: stderr + String(error) }));
  });
}

/* ------------------------------------------------------------------------------------- (a) the
   directory-sweep theory, checked directly rather than trusted -------------------------------- */

test('DISPROVES the original theory: a non-test-named file under a `tests/` (plural) dir is NOT discovered by bare `node --test`', async () => {
  const sandbox = await mkdtemp(join(tmpdir(), 'v459-disprove-'));
  try {
    const { mkdir } = await import('node:fs/promises');
    await mkdir(join(sandbox, 'tests', 'browser'), { recursive: true });
    await writeFile(join(sandbox, 'tests', 'browser', 'generate-something.mjs'), "process.stdout.write('GEN_EXECUTED\\n');\n");
    const result = await run(process.execPath, ['--test'], { cwd: sandbox });
    assert.doesNotMatch(result.stdout, /GEN_EXECUTED/, 'a plain .mjs file under tests/browser/ must NOT run just from being in a `tests` (plural) directory');
    assert.match(result.stdout, /ℹ tests 0/, 'node --test must report discovering zero tests here');
  } finally { await rm(sandbox, { recursive: true, force: true }); }
});

test('CONFIRMS the real rule: the SAME file under a `test/` (singular) dir IS discovered and executed', async () => {
  const sandbox = await mkdtemp(join(tmpdir(), 'v459-confirm-'));
  try {
    const { mkdir } = await import('node:fs/promises');
    await mkdir(join(sandbox, 'test', 'browser'), { recursive: true });
    await writeFile(join(sandbox, 'test', 'browser', 'generate-something.mjs'), "process.stdout.write('GEN_EXECUTED\\n');\n");
    const result = await run(process.execPath, ['--test'], { cwd: sandbox });
    assert.match(result.stdout, /GEN_EXECUTED/, 'a plain .mjs file under a SINGULAR test/ directory must be discovered — this is node\'s real, documented rule');
  } finally { await rm(sandbox, { recursive: true, force: true }); }
});

/* ------------------------------------------------------------------------------------- (b) the
   guard function itself ------------------------------------------------------------------------ */

test('isDirectCliInvocation: false when NODE_TEST_CONTEXT is set (simulating a test-runner child), true for a real direct invocation', () => {
  const moduleUrl = 'file:///anywhere/generate-thing.mjs';
  const savedArgv1 = process.argv[1];
  const savedContext = process.env.NODE_TEST_CONTEXT;
  try {
    process.argv[1] = '/anywhere/generate-thing.mjs';
    process.env.NODE_TEST_CONTEXT = 'child-v8';
    assert.equal(isDirectCliInvocation(moduleUrl), false, 'must be inert when a test-runner child sets NODE_TEST_CONTEXT, even with a matching argv[1]');

    delete process.env.NODE_TEST_CONTEXT;
    assert.equal(isDirectCliInvocation(moduleUrl), true, 'must fire for a genuine direct invocation');

    process.argv[1] = '/anywhere/some-other-file.mjs';
    assert.equal(isDirectCliInvocation(moduleUrl), false, 'must not fire when argv[1] does not match this module');
  } finally {
    process.argv[1] = savedArgv1;
    if (savedContext === undefined) delete process.env.NODE_TEST_CONTEXT; else process.env.NODE_TEST_CONTEXT = savedContext;
  }
});

/* ------------------------------------------------------------------------------------- (c) THE
   REAL exposure class: a generator whose FILENAME matches node's test pattern ------------------- */

/** Builds a throwaway file, at `dir`, carrying either the OLD vulnerable guard or the CURRENT
 *  one, named so node's test runner discovers it by NAME (not by directory) — the confirmed real
 *  rule. Named to look exactly like a plausible future generator rename mistake. */
async function writeGuardProbe(dir, { fixed }) {
  const fixturePath = join(dir, 'probe-fixture.txt');
  await writeFile(fixturePath, 'PRISTINE');
  const file = join(dir, 'generate-something-test.mjs'); // matches node's `*-test.mjs` pattern
  const urlImport = fixed
    ? "import {isDirectCliInvocation} from " + JSON.stringify(new URL('../../scripts/quality/is-direct-cli-invocation.mjs', `file://${dir}/`).href) + ";\n"
    : "import {pathToFileURL} from 'node:url';\n";
  const guardCheck = fixed
    ? 'isDirectCliInvocation(import.meta.url)'
    : 'process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url';
  await writeFile(file, `
    import {writeFile} from 'node:fs/promises';
    ${urlImport}
    if(${guardCheck}){
      await writeFile(${JSON.stringify(fixturePath)}, 'REWRITTEN');
    }
  `);
  return { file, fixturePath };
}

test('REPRODUCTION: the OLD guard DOES fire when a generator-shaped file matches node\'s real test-name pattern', async () => {
  const sandbox = await mkdtemp(join(tmpdir(), 'v459-name-vuln-'));
  try {
    const { fixturePath } = await writeGuardProbe(sandbox, { fixed: false });
    const result = await run(process.execPath, ['--test'], { cwd: sandbox });
    assert.match(result.stdout, /ℹ tests 1\b/, `expected the *-test.mjs file to be discovered as exactly one test:\n${result.stdout}`);
    assert.equal(await readFile(fixturePath, 'utf8'), 'REWRITTEN', 'the OLD guard must have fired and written — this is the real, node-documented exposure class');
  } finally { await rm(sandbox, { recursive: true, force: true }); }
});

test('REGRESSION GUARD: the CURRENT guard (isDirectCliInvocation) stays inert on the same discoverable filename', async () => {
  const sandbox = await mkdtemp(join(tmpdir(), 'v459-name-fixed-'));
  try {
    const { fixturePath } = await writeGuardProbe(sandbox, { fixed: true });
    const result = await run(process.execPath, ['--test'], { cwd: sandbox });
    assert.match(result.stdout, /ℹ tests 1\b/, `expected the *-test.mjs file to be discovered as exactly one test:\n${result.stdout}`);
    assert.equal(await readFile(fixturePath, 'utf8'), 'PRISTINE', 'the fixed guard must stay inert: NODE_TEST_CONTEXT is set inside this run, so isDirectCliInvocation() must return false');
  } finally { await rm(sandbox, { recursive: true, force: true }); }
});

/* ------------------------------------------------------------------------------------- (d) the
   real generators still do their real job, direct and regen-style ------------------------------- */

test('direct CLI invocation of a real generator still writes a byte-identical fixture (fix did not break regeneration)', async () => {
  const sandbox = await buildRepoTestSandbox(['generate-v104-promotions-visual.mjs', 'v104-promotions-visual.html']);
  try {
    const generatorPath = join(sandbox, 'tests', 'browser', 'generate-v104-promotions-visual.mjs');
    const fixturePath = join(sandbox, 'tests', 'browser', 'v104-promotions-visual.html');
    const pristine = await readFile(fixturePath, 'utf8');

    const corrupted = pristine.replace(/sha256" content="/, 'sha256" content="deadbeef');
    assert.notEqual(corrupted, pristine, 'setup: expected a sha256 marker to corrupt');
    await writeFile(fixturePath, corrupted);

    // This is the exact invocation regen-visual-fixtures.mjs uses for every generator:
    // `spawn(process.execPath, [join('tests/browser', name)], { stdio: 'ignore' })` — a plain
    // child process, no test-runner involvement, so NODE_TEST_CONTEXT is unset and
    // isDirectCliInvocation() must return true.
    const result = await run(process.execPath, [generatorPath], { cwd: sandbox });
    assert.equal(result.code, 0, `direct invocation must succeed:\n${result.stderr}`);

    const rebuilt = await readFile(fixturePath, 'utf8');
    assert.equal(rebuilt, pristine, 'direct/regen-style invocation must rebuild the exact pristine fixture, overwriting the corruption');
  } finally { await rm(sandbox, { recursive: true, force: true }); }
}, { timeout: 30000 });

test('EVERY tests/browser/generate-*.mjs uses the fixed guard and is inert under a simulated test-runner child', async () => {
  const sandbox = await buildRepoTestSandbox();
  try {
    const { readdir } = await import('node:fs/promises');
    const names = (await readdir(join(sandbox, 'tests', 'browser')))
      .filter(name => name.startsWith('generate-') && name.endsWith('.mjs'));
    assert.ok(names.length >= 10, `expected at least 10 generators, found ${names.length}`);

    for (const name of names) {
      const source = await readFile(join(sandbox, 'tests', 'browser', name), 'utf8');
      assert.match(source, /isDirectCliInvocation\(import\.meta\.url\)/, `${name}: must use the fixed guard, not the old inline check`);
      assert.doesNotMatch(source, /process\.argv\[1\]&&pathToFileURL/, `${name}: the old vulnerable inline guard must be fully gone`);
    }

    const htmlNames = (await readdir(join(sandbox, 'tests', 'browser'))).filter(n => n.endsWith('.html'));
    const htmlBefore = {};
    for (const html of htmlNames) htmlBefore[html] = await readFile(join(sandbox, 'tests', 'browser', html), 'utf8');

    for (const name of names) {
      const result = await run(process.execPath, [join(sandbox, 'tests', 'browser', name)], {
        cwd: sandbox,
        env: cleanEnv({ NODE_TEST_CONTEXT: 'child-v8' }),
      });
      assert.equal(result.code, 0, `${name} under simulated NODE_TEST_CONTEXT must still exit 0 (inert, not crashing):\n${result.stderr}`);
    }

    for (const html of htmlNames) {
      const after = await readFile(join(sandbox, 'tests', 'browser', html), 'utf8');
      assert.equal(after, htmlBefore[html], `${html} must be untouched by any generator run under NODE_TEST_CONTEXT`);
    }
  } finally { await rm(sandbox, { recursive: true, force: true }); }
}, { timeout: 30000 });
