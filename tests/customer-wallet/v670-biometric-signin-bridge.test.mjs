import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

/* nestly_v670: Face ID sign-in for the iOS shell — a Keychain credential behind a biometric
   access control, reached through NestlyNativeBridge.biometricSignIn. These tests EXECUTE the
   bridge layer against stubbed plugin shapes, because its whole contract is defensive: every
   method must answer inertly on the web, on a native build without the plugin, and on a plugin
   that throws — a caller must never need its own try/catch ladder, and a malformed native
   answer must never leak upward as a truthy success. */

const bridgeSource = readFileSync(new URL('../../app/native-bridge.js', import.meta.url), 'utf8');

function loadBridge({ native = true, plugin } = {}) {
  const window = {
    Capacitor: {
      isNativePlatform: () => native,
      getPlatform: () => 'ios',
      Plugins: plugin ? { BiometricCredential: plugin } : {},
    },
    navigator: { onLine: true },
    location: { href: 'https://localhost/' },
    addEventListener() {}, dispatchEvent() {}, open() {},
    CustomEvent: class { constructor(type, init) { this.type = type; Object.assign(this, init); } },
  };
  const context = vm.createContext({ window, CustomEvent: window.CustomEvent, URL, console });
  vm.runInContext(bridgeSource, context);
  return window.NestlyNativeBridge.biometricSignIn;
}

test('on the web every method is inert and safe', async () => {
  const b = loadBridge({ native: false });
  assert.deepEqual({ ...await b.availability() }, { available: false, biometry: 'none' });
  assert.equal(await b.enrolled(), false);
  assert.equal(await b.store({ phone: '+6581234567', password: 'pw' }), false);
  assert.deepEqual({ ...await b.retrieve() }, { status: 'unavailable' });
  assert.equal(await b.clear(), true, 'clearing nothing is success, not an error');
});

test('a native build without the plugin behaves like the web, not like a crash', async () => {
  const b = loadBridge({ native: true, plugin: undefined });
  assert.deepEqual({ ...await b.availability() }, { available: false, biometry: 'none' });
  assert.deepEqual({ ...await b.retrieve() }, { status: 'unavailable' });
});

test('the happy path round-trips through the plugin', async () => {
  const calls = [];
  const b = loadBridge({ native: true, plugin: {
    availability: async () => ({ available: true, biometry: 'faceId' }),
    enrolled: async () => ({ enrolled: true }),
    store: async (args) => { calls.push(args); return { status: 'ok' }; },
    retrieve: async () => ({ status: 'ok', phone: '+6581234567', password: 'pw' }),
    clear: async () => ({ status: 'ok' }),
  } });
  assert.deepEqual({ ...await b.availability() }, { available: true, biometry: 'faceId' });
  assert.equal(await b.enrolled(), true);
  assert.equal(await b.store({ phone: '+6581234567', password: 'pw' }), true);
  assert.deepEqual(calls.map(c => ({ ...c })), [{ phone: '+6581234567', password: 'pw' }]);
  assert.deepEqual({ ...await b.retrieve() }, { status: 'ok', phone: '+6581234567', password: 'pw' });
  assert.equal(await b.clear(), true);
});

test('a throwing or malformed plugin degrades to failure, never to success', async () => {
  const throwing = () => { throw new Error('native fault'); };
  const b = loadBridge({ native: true, plugin: {
    availability: throwing, enrolled: throwing, store: throwing, retrieve: throwing, clear: throwing,
  } });
  assert.deepEqual({ ...await b.availability() }, { available: false, biometry: 'none' });
  assert.equal(await b.enrolled(), false);
  assert.equal(await b.store({ phone: 'p', password: 'x' }), false);
  assert.deepEqual({ ...await b.retrieve() }, { status: 'failed' });
  assert.equal(await b.clear(), false);

  const weird = loadBridge({ native: true, plugin: {
    retrieve: async () => ({ status: 'jackpot', password: '??' }),
    store: async () => ({ status: 'nearly' }),
    enrolled: async () => ({ enrolled: 'yes' }),
  } });
  assert.deepEqual({ ...await weird.retrieve() }, { status: 'failed' }, 'an unrecognised status is failure');
  assert.equal(await weird.store({ phone: 'p', password: 'x' }), false);
  assert.equal(await weird.enrolled(), false, 'a non-boolean enrolled is false');
});

test('store refuses an empty credential before it reaches the plugin', async () => {
  let reached = false;
  const b = loadBridge({ native: true, plugin: { store: async () => { reached = true; return { status: 'ok' }; } } });
  assert.equal(await b.store({}), false);
  assert.equal(await b.store({ phone: '+6581234567' }), false);
  assert.equal(reached, false);
});

test('the native project actually carries the plugin the bridge talks to', () => {
  /* The v185 lesson in native form: the JS half can be green while the Swift half was never
     registered. Pin the three registration points a build needs. */
  const swift = readFileSync(new URL('../../ios/App/App/BiometricCredential.swift', import.meta.url), 'utf8');
  assert.match(swift, /jsName = "BiometricCredential"/);
  assert.match(swift, /biometryCurrentSet/);
  assert.match(swift, /kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly/);
  const controller = readFileSync(new URL('../../ios/App/App/AppViewController.swift', import.meta.url), 'utf8');
  assert.match(controller, /registerPluginInstance\(BiometricCredentialPlugin\(\)\)/);
  const storyboard = readFileSync(new URL('../../ios/App/App/Base.lproj/Main.storyboard', import.meta.url), 'utf8');
  assert.match(storyboard, /customClass="AppViewController"/);
  /* nestly_v745: the storyboard pin above passed for three builds in which the plugin was never
     registered, because the root controller is constructed in code. THIS is the authority — the
     one line that decides whether capacitorDidLoad() ever runs. */
  const scene = readFileSync(new URL('../../ios/App/App/SceneDelegate.swift', import.meta.url), 'utf8');
  assert.match(scene, /rootViewController = AppViewController\(\)/);
  assert.doesNotMatch(scene, /rootViewController = CAPBridgeViewController\(\)/);
  const pbxproj = readFileSync(new URL('../../ios/App/App.xcodeproj/project.pbxproj', import.meta.url), 'utf8');
  assert.match(pbxproj, /BiometricCredential\.swift in Sources/);
  assert.match(pbxproj, /AppViewController\.swift in Sources/);
  const plist = readFileSync(new URL('../../ios/App/App/Info.plist', import.meta.url), 'utf8');
  assert.match(plist, /NSFaceIDUsageDescription/);
});
