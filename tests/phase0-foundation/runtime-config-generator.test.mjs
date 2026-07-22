import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

const repoRoot = new URL('../..', import.meta.url);
const source = (relativePath) => readFile(new URL(relativePath, repoRoot), 'utf8');
const NON_PRODUCTION_REF = 'abcdefghijklmnopqrst';
const PUBLISHABLE_KEY = 'sb_publishable_abcdefghijklmnopqrstuvwx';

async function isolatedGenerator(t) {
  const root = await mkdtemp(path.join(tmpdir(), 'frenly-runtime-config-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await Promise.all([
    mkdir(path.join(root, 'app'), { recursive: true }),
    mkdir(path.join(root, 'scripts/runtime-config'), { recursive: true }),
    mkdir(path.join(root, 'config/runtime'), { recursive: true })
  ]);
  await Promise.all([
    writeFile(path.join(root, 'app/runtime-config-loader.js'), await source('app/runtime-config-loader.js')),
    writeFile(path.join(root, 'scripts/runtime-config/generate.mjs'), await source('scripts/runtime-config/generate.mjs')),
    writeFile(path.join(root, 'config/runtime/vercel.template.json'), await source('config/runtime/vercel.template.json'))
  ]);
  return root;
}

function runGenerator(root, args) {
  return spawnSync(process.execPath, ['scripts/runtime-config/generate.mjs', ...args], {
    cwd: root,
    encoding: 'utf8'
  });
}

function validConfig(overrides = {}) {
  return {
    schemaVersion: 1,
    environment: 'staging',
    projectRef: NON_PRODUCTION_REF,
    supabaseUrl: `https://${NON_PRODUCTION_REF}.supabase.co`,
    supabasePublishableKey: PUBLISHABLE_KEY,
    ...overrides
  };
}

test('generator emits a frozen public config and an exact-origin CSP in an isolated root', async (t) => {
  const root = await isolatedGenerator(t);
  const configPath = path.join(root, 'config/runtime/staging.json');
  await writeFile(configPath, `${JSON.stringify(validConfig(), null, 2)}\n`);

  const generated = runGenerator(root, ['--config', configPath]);
  assert.equal(generated.status, 0, generated.stderr);

  const runtime = await readFile(path.join(root, 'app/runtime-config.js'), 'utf8');
  const vercel = JSON.parse(await readFile(path.join(root, 'app/vercel.json'), 'utf8'));
  const csp = vercel.headers[0].headers.find(({ key }) => key === 'Content-Security-Policy').value;

  assert.match(runtime, /^\/\* Generated from an explicit public runtime configuration\./);
  assert.match(runtime, /window\.__FRENLY_RUNTIME_CONFIG__ = Object\.freeze\(/);
  assert.match(runtime, new RegExp(`"projectRef": "${NON_PRODUCTION_REF}"`));
  assert.match(csp, new RegExp(`connect-src 'self' https:\/\/${NON_PRODUCTION_REF}\\.supabase\\.co wss:\/\/${NON_PRODUCTION_REF}\\.supabase\\.co https:\/\/challenges\\.cloudflare\\.com;`));
  assert.doesNotMatch(csp, /connect-src[^;]*\*/);
  assert.doesNotMatch(csp, /\{\{SUPABASE_/);

  const checked = runGenerator(root, ['--config', configPath, '--check']);
  assert.equal(checked.status, 0, checked.stderr);
});

test('generator check detects drift without rewriting generated artifacts', async (t) => {
  const root = await isolatedGenerator(t);
  const configPath = path.join(root, 'config/runtime/staging.json');
  await writeFile(configPath, `${JSON.stringify(validConfig(), null, 2)}\n`);
  assert.equal(runGenerator(root, ['--config', configPath]).status, 0);

  const runtimePath = path.join(root, 'app/runtime-config.js');
  const drift = 'window.__FRENLY_RUNTIME_CONFIG__ = Object.freeze({});\n';
  await writeFile(runtimePath, drift);
  const checked = runGenerator(root, ['--config', configPath, '--check']);

  assert.notEqual(checked.status, 0);
  assert.equal(await readFile(runtimePath, 'utf8'), drift);
  assert.match(checked.stderr, /app\/runtime-config\.js is not generated from/);
});

test('generator rejects production routing in test mode without printing the supplied secret', async (t) => {
  const root = await isolatedGenerator(t);
  const canary = 'CANARY_SERVICE_ROLE_MUST_NOT_PRINT_0ef09a';
  const configPath = path.join(root, 'config/runtime/unsafe.json');
  await writeFile(configPath, `${JSON.stringify(validConfig({
    environment: 'test',
    projectRef: 'gadpooereceldfpfxsod',
    supabaseUrl: 'https://gadpooereceldfpfxsod.supabase.co',
    supabasePublishableKey: `sb_secret_${canary}`
  }), null, 2)}\n`);

  const generated = runGenerator(root, ['--config', configPath]);
  assert.notEqual(generated.status, 0);
  assert.doesNotMatch(`${generated.stdout}\n${generated.stderr}`, new RegExp(canary));
  assert.doesNotMatch(`${generated.stdout}\n${generated.stderr}`, /sb_secret_/);
  await assert.rejects(readFile(path.join(root, 'app/runtime-config.js')), { code: 'ENOENT' });
  await assert.rejects(readFile(path.join(root, 'app/vercel.json')), { code: 'ENOENT' });
});

test('generator escapes markup-capable config content before emitting JavaScript', async (t) => {
  const root = await isolatedGenerator(t);
  const configPath = path.join(root, 'config/runtime/invalid-markup.json');
  const canary = '</script><script>globalThis.compromised=true</script>';
  await writeFile(configPath, `${JSON.stringify(validConfig({ supabasePublishableKey: canary }), null, 2)}\n`);

  const generated = runGenerator(root, ['--config', configPath]);
  assert.notEqual(generated.status, 0);
  assert.doesNotMatch(`${generated.stdout}\n${generated.stderr}`, /compromised=true/);
});
