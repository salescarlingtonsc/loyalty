import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const require = createRequire(import.meta.url);
const runtimeConfig = require('../../app/runtime-config-loader.js');
const root = new URL('../..', import.meta.url);
const read = (relativePath) => readFile(new URL(relativePath, root), 'utf8');

const NON_PRODUCTION_REF = 'abcdefghijklmnopqrst';
const PRODUCTION_REF = 'gadpooereceldfpfxsod';
const PUBLISHABLE_KEY = 'sb_publishable_abcdefghijklmnopqrstuvwx';

function remoteConfig(overrides = {}) {
  return {
    schemaVersion: 1,
    environment: 'test',
    projectRef: NON_PRODUCTION_REF,
    supabaseUrl: `https://${NON_PRODUCTION_REF}.supabase.co`,
    supabasePublishableKey: PUBLISHABLE_KEY,
    ...overrides
  };
}

function legacyJwt(role, { header = { alg: 'HS256', typ: 'JWT' }, signature = 'signature' } = {}) {
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
  return `${encode(header)}.${encode({ role })}.${signature}`;
}

function captureError(action) {
  try {
    action();
  } catch (error) {
    return error;
  }
  assert.fail('Expected runtime configuration validation to fail.');
}

test('runtime configuration API and validated values are immutable', () => {
  const validated = runtimeConfig.validate(remoteConfig());

  assert.ok(Object.isFrozen(runtimeConfig));
  assert.ok(Object.isFrozen(validated));
  assert.deepEqual(validated, remoteConfig());
  assert.throws(() => {
    validated.projectRef = PRODUCTION_REF;
  }, TypeError);
});

test('all declared environments have explicit accepted routing semantics', () => {
  for (const environment of ['development', 'test', 'staging']) {
    assert.equal(runtimeConfig.validate(remoteConfig({ environment })).environment, environment);
  }

  const production = remoteConfig({
    environment: 'production',
    projectRef: PRODUCTION_REF,
    supabaseUrl: `https://${PRODUCTION_REF}.supabase.co`
  });
  assert.equal(runtimeConfig.validate(production).projectRef, PRODUCTION_REF);

  for (const environment of ['development', 'staging']) {
    assert.equal(captureError(() => runtimeConfig.validate({ ...production, environment })).code,
      'CONFIG_ENVIRONMENT_BOUNDARY');
  }
  assert.equal(captureError(() => runtimeConfig.validate(remoteConfig({ environment: 'production' }))).code,
    'CONFIG_ENVIRONMENT_BOUNDARY');

  const local = {
    schemaVersion: 1,
    environment: 'development',
    projectRef: 'local',
    supabaseUrl: 'http://127.0.0.1:54321',
    supabasePublishableKey: PUBLISHABLE_KEY
  };
  assert.equal(runtimeConfig.validate(local).supabaseUrl, 'http://127.0.0.1:54321');
  assert.equal(runtimeConfig.validate({ ...local, environment: 'test' }).environment, 'test');
  assert.equal(captureError(() => runtimeConfig.validate({ ...local, environment: 'staging' })).code, 'CONFIG_PROJECT_REF');
  assert.equal(captureError(() => runtimeConfig.validate({ ...local, environment: 'production' })).code, 'CONFIG_PROJECT_REF');
});

test('missing, misspelled, coerced, and extended schemas fail closed', () => {
  assert.equal(captureError(() => runtimeConfig.require({})).code, 'CONFIG_MISSING');
  assert.equal(captureError(() => runtimeConfig.validate(null)).code, 'CONFIG_MISSING');
  assert.equal(captureError(() => runtimeConfig.validate([])).code, 'CONFIG_MISSING');

  for (const field of Object.keys(remoteConfig())) {
    const candidate = remoteConfig();
    delete candidate[field];
    assert.equal(captureError(() => runtimeConfig.validate(candidate)).code, 'CONFIG_SCHEMA', field);
  }

  assert.equal(captureError(() => runtimeConfig.validate({ ...remoteConfig(), unexpected: true })).code, 'CONFIG_SCHEMA');
  assert.equal(captureError(() => runtimeConfig.validate(remoteConfig({ schemaVersion: '1' }))).code, 'CONFIG_SCHEMA');
  assert.equal(captureError(() => runtimeConfig.validate(remoteConfig({ environment: 'Production' }))).code, 'CONFIG_ENVIRONMENT');
  assert.equal(captureError(() => runtimeConfig.validate(remoteConfig({ environment: true }))).code, 'CONFIG_ENVIRONMENT');
  assert.equal(captureError(() => runtimeConfig.validate(remoteConfig({ projectRef: null }))).code, 'CONFIG_PROJECT_REF');
  assert.equal(captureError(() => runtimeConfig.validate(remoteConfig({ supabaseUrl: null }))).code, 'CONFIG_URL');
  assert.equal(captureError(() => runtimeConfig.validate(remoteConfig({ supabasePublishableKey: null }))).code, 'CONFIG_KEY');
});

test('test mode refuses the production project before browser boot', () => {
  const error = captureError(() => runtimeConfig.validate(remoteConfig({
    projectRef: PRODUCTION_REF,
    supabaseUrl: `https://${PRODUCTION_REF}.supabase.co`
  })));

  assert.equal(error.name, 'RuntimeConfigError');
  assert.equal(error.code, 'CONFIG_ENVIRONMENT_BOUNDARY');
  assert.equal(error.message, 'Frenly runtime configuration is unavailable.');
});

test('Supabase URL must be an exact origin whose hostname matches projectRef', () => {
  const invalid = [
    [`https://${NON_PRODUCTION_REF}.supabase.co/path`, 'CONFIG_URL'],
    [`https://${NON_PRODUCTION_REF}.supabase.co/?token=canary`, 'CONFIG_URL'],
    [`https://${NON_PRODUCTION_REF}.supabase.co/#fragment`, 'CONFIG_URL'],
    [`https://user:password@${NON_PRODUCTION_REF}.supabase.co`, 'CONFIG_URL'],
    [`https://${NON_PRODUCTION_REF}.supabase.co:444`, 'CONFIG_PROJECT_REF'],
    [`http://${NON_PRODUCTION_REF}.supabase.co`, 'CONFIG_PROJECT_REF'],
    ['https://example.com', 'CONFIG_URL']
  ];

  for (const [supabaseUrl, code] of invalid) {
    assert.equal(captureError(() => runtimeConfig.validate(remoteConfig({ supabaseUrl }))).code, code, supabaseUrl);
  }

  assert.equal(captureError(() => runtimeConfig.validate(remoteConfig({ projectRef: 'bbbbbbbbbbbbbbbbbbbb' }))).code,
    'CONFIG_PROJECT_REF');
  assert.equal(captureError(() => runtimeConfig.validate(remoteConfig({ projectRef: 'short' }))).code,
    'CONFIG_PROJECT_REF');
});

test('only publishable keys and structurally complete legacy anon JWTs are accepted', () => {
  assert.equal(runtimeConfig.validate(remoteConfig()).supabasePublishableKey, PUBLISHABLE_KEY);
  const anon = legacyJwt('anon');
  assert.equal(runtimeConfig.validate(remoteConfig({ supabasePublishableKey: anon })).supabasePublishableKey, anon);

  const rejected = [
    'sb_publishable_',
    ' sb_publishable_abcdefghijklmnopqrstuvwx',
    'Bearer sb_publishable_abcdefghijklmnopqrstuvwx',
    'sb_secret_CANARY_DO_NOT_PRINT_abcdefghijklmnop',
    legacyJwt('service_role'),
    legacyJwt('authenticated'),
    legacyJwt('ANON'),
    'header.not-base64.signature',
    `.${Buffer.from(JSON.stringify({ role: 'anon' })).toString('base64url')}.`,
    'only.two-parts'
  ];

  for (const key of rejected) {
    assert.equal(captureError(() => runtimeConfig.validate(remoteConfig({ supabasePublishableKey: key }))).code,
      'CONFIG_KEY');
  }
});

test('validation errors and failure UI never disclose supplied configuration material', () => {
  const canary = 'CANARY_RUNTIME_SECRET_7a340dd7';
  const raw = remoteConfig({ supabasePublishableKey: `sb_secret_${canary}` });
  const error = captureError(() => runtimeConfig.validate(raw));
  const rendered = { innerHTML: '' };
  runtimeConfig.renderFailure(rendered);

  assert.equal(error.code, 'CONFIG_KEY');
  assert.doesNotMatch(`${error.name}\n${error.message}\n${error.stack}`, new RegExp(canary));
  assert.doesNotMatch(rendered.innerHTML, new RegExp(canary));
  assert.doesNotMatch(rendered.innerHTML, /supabase|projectRef|publishable|service_role|sb_secret/i);
  assert.match(rendered.innerHTML, /Frenly is unavailable/);
  assert.match(rendered.innerHTML, /role="alert"/);
});

function bootstrapThroughClient(source) {
  const start = source.indexOf('const RUNTIME_CONFIG=');
  const client = source.indexOf('const sb=window.supabase.createClient', start);
  const end = source.indexOf(';', client) + 1;
  assert.ok(start >= 0 && client > start && end > client, 'Expected runtime bootstrap and Supabase client creation.');
  return source.slice(start, end);
}

for (const page of ['app/index.html', 'app/join.html']) {
  test(`${page} loads and validates runtime config before client or network bootstrap`, async () => {
    const source = await read(page);
    const configScript = source.indexOf('<script src="/runtime-config.js"></script>');
    const loaderScript = source.indexOf('<script src="/runtime-config-loader.js"></script>');
    const supabaseScript = source.indexOf('@supabase/supabase-js');
    const requireCall = source.indexOf('window.FrenlyRuntimeConfig.require(window)');
    const createClient = source.indexOf('window.supabase.createClient');
    const firstFetch = source.indexOf('fetch(');

    assert.ok(configScript >= 0 && configScript < loaderScript);
    assert.ok(loaderScript < supabaseScript);
    assert.ok(supabaseScript < requireCall);
    assert.ok(requireCall < createClient);
    if (firstFetch >= 0) assert.ok(createClient < firstFetch);

    let renderCount = 0;
    let clientCount = 0;
    const canary = 'CANARY_CONFIG_SHOULD_NOT_ESCAPE';
    const context = {
      document: { getElementById: () => ({}) },
      window: {
        FrenlyRuntimeConfig: {
          require() {
            throw new Error(canary);
          },
          renderFailure() {
            renderCount += 1;
          }
        },
        supabase: {
          createClient() {
            clientCount += 1;
          }
        }
      }
    };

    assert.throws(() => vm.runInNewContext(bootstrapThroughClient(source), context),
      /Frenly runtime configuration is unavailable/);
    assert.equal(renderCount, 1);
    assert.equal(clientCount, 0);
  });
}
