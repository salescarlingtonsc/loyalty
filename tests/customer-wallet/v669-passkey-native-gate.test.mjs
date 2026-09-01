import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

/* nestly_v669 (owner: "the passkey is not working" — in the iOS app). Inside the Capacitor
   WKWebView every feature probe the app runs comes back true — secure context, a
   PublicKeyCredential global, a supabase-js with the passkey functions — and yet the WebAuthn
   ceremony can never complete: Apple restricts platform passkey prompts to Safari-class apps,
   and the relying-party domain can never match capacitor://localhost. So the Face ID button
   armed itself and failed on every tap. The fix is one capability gate in
   customerPasskeySupported(), which every passkey surface must consult.

   These tests EXTRACT that function from app.js and EXECUTE it under both environment shapes,
   because the bug being guarded is exactly a truthy feature-detection that lies in one runtime —
   a source grep would have passed before the fix too. */

const appSource = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

function extractFunction(name) {
  const start = appSource.indexOf(`function ${name}(`);
  assert.ok(start >= 0, `${name} exists in app.js`);
  const end = appSource.indexOf('\n}', start);
  return appSource.slice(start, end + 2);
}

function runSupported({ native, management = false, secure = true, withApi = true } = {}) {
  const context = vm.createContext({
    isSecureContext: secure,
    sb: { auth: withApi ? {
      registerPasskey: () => {},
      signInWithPasskey: () => {},
      passkey: { list: () => {} },
    } : {} },
  });
  context.PublicKeyCredential = function PublicKeyCredential() {};
  if (native) context.Capacitor = { isNativePlatform: () => true };
  vm.runInContext(extractFunction('customerPasskeySupported'), context);
  return vm.runInContext(`customerPasskeySupported({management:${management}})`, context);
}

test('a capable web browser still passes the capability check', () => {
  assert.equal(runSupported({ native: false }), true);
  assert.equal(runSupported({ native: false, management: true }), true);
});

test('the iOS shell fails the capability check even though every probe is true', () => {
  /* The decisive case: identical environment, plus the Capacitor native marker. Before v669
     this returned true and armed a button that could only fail. */
  assert.equal(runSupported({ native: true }), false);
  assert.equal(runSupported({ native: true, management: true }), false);
});

test('the gate did not weaken the pre-existing requirements', () => {
  assert.equal(runSupported({ native: false, secure: false }), false, 'insecure context still refused');
  assert.equal(runSupported({ native: false, withApi: false }), false, 'a supabase-js without the API still refused');
});

test('the sign-in screen consults the shared helper rather than its own probe', () => {
  /* The bug survived as long as it did because the sign-in screen duplicated the check inline
     and the two could drift. Structural pin only — the behaviour itself is executed above. */
  assert.match(appSource, /const passkeySupported=customerPasskeySupported\(\)&&typeof sb\.auth\.signInWithPasskey==='function'/);
});

test('the shell surfaces route to native Face ID, never to a WebAuthn attempt', () => {
  /* v670 superseded v669's "coming soon" copy with the real feature: in the shell the button
     runs the Keychain credential unlock, and only the web branch ever reaches WebAuthn. */
  assert.match(appSource, /nativeShell\?runBiometricSignIn\(\):runPasskeySignIn\(\)/);
  assert.match(appSource, /After you sign in, you can turn on Face ID for next time\./);
  assert.match(appSource, /Face ID sign-in is off\. Turn it on when the app offers it/);
});
