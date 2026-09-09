import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

/* nestly_v860: biometric APP LOCK for the iOS shell — a re-auth gate the customer can turn on
   to require their face/fingerprint (or the device passcode, iOS's own fallback) whenever the
   app should be gated shut, reached through NestlyNativeBridge.appLock. Separate from the v670
   sign-in credential: this never reads or writes the stored phone/password, it only asks "is
   this still the device owner?" and remembers an on/off preference. Same discipline as the v670
   suite this is modelled on: these tests EXECUTE the bridge layer against stubbed plugin shapes,
   because the whole contract is defensive — every method must answer inertly on the web, on a
   native build without the plugin, on a native build whose Swift plugin predates these methods
   (the JS bundle ships ahead of the App Store review, so this WILL happen in production), and on
   a plugin that throws or answers with a shape it was never promised. A caller must never need
   its own try/catch ladder, and a malformed or partial native answer must never leak upward as a
   truthy success. */

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
  return window.NestlyNativeBridge;
}
const appLockOf = (options) => loadBridge(options).appLock;

test('on the web every app-lock method is inert and safe', async () => {
  const b = appLockOf({ native: false });
  assert.deepEqual({ ...await b.available() }, { available: false, biometry: 'none' });
  assert.deepEqual({ ...await b.authenticate() }, { status: 'unavailable' });
  assert.equal(await b.enabled(), false);
  assert.equal(await b.setEnabled(true), false);
});

test('a native build without the plugin behaves like the web, not like a crash', async () => {
  const b = appLockOf({ native: true, plugin: undefined });
  assert.deepEqual({ ...await b.available() }, { available: false, biometry: 'none' });
  assert.deepEqual({ ...await b.authenticate() }, { status: 'unavailable' });
  assert.equal(await b.enabled(), false);
  assert.equal(await b.setEnabled(true), false);
});

test('a native build with an OLD plugin (pre-v860) degrades the new methods safely', async () => {
  /* This is exactly what an installed build looks like the moment the JS bundle ships to
     peekaa.asia ahead of the App Store review landing: the Swift side still only has the v670
     sign-in methods. */
  const oldPlugin = {
    availability: async () => ({ available: true, biometry: 'faceId' }),
    enrolled: async () => ({ enrolled: true }),
    store: async () => ({ status: 'ok' }),
    retrieve: async () => ({ status: 'missing' }),
    clear: async () => ({ status: 'ok' }),
    // authenticate / lockPreference / setLockPreference intentionally absent.
  };
  const bridge = loadBridge({ native: true, plugin: oldPlugin });
  const b = bridge.appLock;
  /* available() must answer for THIS BUILD, not merely for the phone. The old plugin still has
     `availability`, so asking the phone alone would answer "yes, Face ID is right here" — and
     Settings would then paint a switch that nothing behind it can honour, and a customer who
     tapped it would be told their phone has no biometrics, which is false and unfixable. The
     honest answer is that the lock is not available on this build. */
  assert.deepEqual({ ...await b.available() }, { available: false, biometry: 'none' });
  /* And the v670 sign-in half, which this build genuinely CAN do, keeps working — the tightened
     answer above must not have taken Biometric Sign-In away from builds that already had it. */
  assert.deepEqual({ ...await bridge.biometricSignIn.availability() }, { available: true, biometry: 'faceId' });
  assert.equal(await bridge.biometricSignIn.enrolled(), true);
  assert.deepEqual({ ...await b.authenticate() }, { status: 'unavailable' });
  assert.equal(await b.enabled(), false);
  assert.equal(await b.setEnabled(true), false);
});

test('the happy path round-trips through the plugin, reason capped and defaulted', async () => {
  const calls = [];
  const b = appLockOf({ native: true, plugin: {
    availability: async () => ({ available: true, biometry: 'faceId' }),
    authenticate: async (args) => { calls.push(args); return { status: 'ok' }; },
    lockPreference: async () => ({ enabled: true }),
    setLockPreference: async (args) => { calls.push(args); return { status: 'ok', enabled: args.enabled }; },
  } });

  assert.deepEqual({ ...await b.available() }, { available: true, biometry: 'faceId' });

  assert.deepEqual({ ...await b.authenticate({ reason: 'x'.repeat(200) }) }, { status: 'ok' });
  assert.equal(calls[0].reason.length, 120, 'reason is capped at 120 chars before it reaches native');
  assert.equal(calls[0].reason, 'x'.repeat(120));

  assert.deepEqual({ ...await b.authenticate() }, { status: 'ok' });
  assert.equal(calls[1].reason, 'Unlock Peekaa', 'default reason when the caller supplies none');

  assert.equal(await b.enabled(), true);

  assert.equal(await b.setEnabled(true), true);
  assert.deepEqual({ ...calls[2] }, { enabled: true });

  assert.equal(await b.setEnabled(false), true);
  assert.deepEqual({ ...calls[3] }, { enabled: false });
});

test('authenticate passes through only a recognised status, dropping any extra fields', async () => {
  for (const status of ['ok', 'canceled', 'failed', 'lockout', 'unavailable']) {
    const b = appLockOf({ native: true, plugin: {
      authenticate: async () => ({ status, extra: 'should never leak through the bridge' }),
    } });
    assert.deepEqual({ ...await b.authenticate() }, { status }, `status '${status}' passes through cleanly`);
  }
});

test('an unrecognised authenticate status degrades to failure, never bubbles up raw', async () => {
  const b = appLockOf({ native: true, plugin: {
    authenticate: async () => ({ status: 'jackpot' }),
  } });
  assert.deepEqual({ ...await b.authenticate() }, { status: 'failed' });
});

test('a throwing plugin degrades to failure, never to success', async () => {
  const throwing = () => { throw new Error('native fault'); };
  const b = appLockOf({ native: true, plugin: {
    availability: throwing, authenticate: throwing, lockPreference: throwing, setLockPreference: throwing,
  } });
  assert.deepEqual({ ...await b.available() }, { available: false, biometry: 'none' });
  assert.deepEqual({ ...await b.authenticate() }, { status: 'failed' });
  assert.equal(await b.enabled(), false);
  assert.equal(await b.setEnabled(true), false);
});

test('setEnabled only reports true when the plugin echoes back the requested value', async () => {
  const mismatched = appLockOf({ native: true, plugin: {
    setLockPreference: async () => ({ status: 'ok', enabled: false }),
  } });
  assert.equal(await mismatched.setEnabled(true), false, 'plugin echoed a different value than requested');

  const badStatus = appLockOf({ native: true, plugin: {
    setLockPreference: async () => ({ status: 'nope', enabled: true }),
  } });
  assert.equal(await badStatus.setEnabled(true), false, 'a non-ok status is never success, even if enabled matches');

  const truthyNotBoolean = appLockOf({ native: true, plugin: {
    setLockPreference: async () => ({ status: 'ok', enabled: 1 }),
  } });
  assert.equal(await truthyNotBoolean.setEnabled(true), false, '1 is not === true');
});

test('enabled() treats a non-boolean flag as false', async () => {
  const b = appLockOf({ native: true, plugin: {
    lockPreference: async () => ({ enabled: 'yes' }),
  } });
  assert.equal(await b.enabled(), false);
});

test('the native project actually carries the app-lock methods the bridge talks to', () => {
  /* The v185 lesson in native form, same as the v670 suite: the JS half can be green while the
     Swift half was never wired up. Pin the pieces a build needs. */
  const swift = readFileSync(new URL('../../ios/App/App/BiometricCredential.swift', import.meta.url), 'utf8');
  assert.match(swift, /CAPPluginMethod\(name: "authenticate", returnType: CAPPluginReturnPromise\)/);
  assert.match(swift, /CAPPluginMethod\(name: "lockPreference", returnType: CAPPluginReturnPromise\)/);
  assert.match(swift, /CAPPluginMethod\(name: "setLockPreference", returnType: CAPPluginReturnPromise\)/);
  assert.match(swift, /\.deviceOwnerAuthentication\b/, 'the app-lock gate allows the passcode fallback');
  assert.match(swift, /\.deviceOwnerAuthenticationWithBiometrics/, 'availability() still reports biometry only');
  assert.match(swift, /asia\.peekaa\.app\.lock\.enabled/, 'the UserDefaults key backing the on/off preference');

  const plist = readFileSync(new URL('../../ios/App/App/Info.plist', import.meta.url), 'utf8');
  assert.match(plist, /unlock the app/, 'the biometric usage string now covers the app lock, not just sign-in');
});
