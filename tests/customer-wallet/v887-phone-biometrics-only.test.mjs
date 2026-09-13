/* nestly_v887 — owner ruling 2026-09-13: "i just want the biometrics from phone (not the +add
   passkey) — if is the same thing you can let me know. if not remove it."

   They are not the same thing. A passkey is unlocked BY the phone's biometrics, but the credential
   itself syncs through iCloud Keychain or Google Password Manager — it can reach the customer's
   other devices and a password manager. The phone's own biometrics are the native Keychain
   credential behind NestlyNativeBridge.biometricSignIn, which never leaves the handset. So the
   passkey half is withdrawn and the native half stays.

   What this file protects:
   - the withdrawal is a PRODUCT gate, not a lie about what a browser can do (v669's capability
     invariant must keep answering its own question, or the next person to re-enable passkeys
     re-introduces the WKWebView bug it was written for);
   - no dead control is left behind on either surface;
   - the native biometric sign-in — the thing the owner actually wants — is untouched. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

test('the capability answer is still purely about capability', () => {
  /* Executed, not grepped: if the product gate had been put INSIDE this function it would return
     false for a capable browser, and v669's WKWebView gate would be untestable from then on. */
  const start = app.indexOf('function customerPasskeySupported(');
  const body = app.slice(start, app.indexOf('\n}', start) + 2);
  const context = vm.createContext({
    isSecureContext: true,
    sb: { auth: { registerPasskey() {}, signInWithPasskey() {}, passkey: { list() {} } } }
  });
  context.PublicKeyCredential = function PublicKeyCredential() {};
  vm.runInContext(body, context);
  assert.equal(vm.runInContext('customerPasskeySupported({management:true})', context), true,
    'a capable browser must still answer true — the withdrawal is a product decision, not a capability claim');
});

test('the product gate is off, and both surfaces consult it', () => {
  assert.match(app, /const CUSTOMER_PASSKEYS_OFFERED_V887=false;/);
  const offers = app.match(/customerPasskeySupported\([^)]*\)[^\n;]*CUSTOMER_PASSKEYS_OFFERED_V887/g) || [];
  assert.equal(offers.length, 2, 'the sign-in screen and the Settings card must both be gated');
});

test('the gate is appended, so v669 can still pin the sign-in line', () => {
  /* v669 asserts the head of this line. A prefix would have silently un-pinned its guard. */
  assert.match(app, /const passkeySupported=customerPasskeySupported\(\)&&typeof sb\.auth\.signInWithPasskey==='function'/);
});

test('no dead passkey control is left on either surface', () => {
  assert.doesNotMatch(app, /id="customerPasskeyAdd"/, 'the Settings button is gone with the feature');
  assert.doesNotMatch(app, /<span>Add passkey<\/span>/);
  /* The sign-in icon renders disabled by default, so leaving it visible would be a control that
     can never arm. The web branch hides it. */
  const signIn = app.slice(app.indexOf('if(!passkeySupported&&!nativeShell){'));
  assert.match(signIn.slice(0, 600), /passkeyButton\.hidden=true;/);
});

test('every binding that outlived the button is guarded against its absence', () => {
  for (const guarded of [
    /if\(passkeyAdd\)passkeyAdd\.disabled=true;/,
    /if\(passkeyAdd\)passkeyAdd\.disabled=error\.code==='passkey_disabled';/,
    /if\(passkeyAdd\)passkeyAdd\.onclick=/
  ]) assert.match(app, guarded);
});

test('the phone’s own biometric sign-in is untouched', () => {
  /* This is the half the owner asked to keep. It is the native Keychain credential, not WebAuthn,
     and it is reached through a branch the product gate now makes unconditional on the shell. */
  assert.match(app, /nativeShell\?runBiometricSignIn\(\):runPasskeySignIn\(\)/);
  assert.match(app, /Biometric Sign-In is on for this device/);
  assert.match(app, /Your sign-in is kept only on this device, locked by its biometrics\./);
  assert.match(app, /After you sign in, you can turn on Biometric Sign-In for next time\./);
});

test('nothing was deleted — flipping the constant restores the feature whole', () => {
  for (const path of ['sb.auth.passkey.list()', 'sb.auth.passkey.update(', 'sb.auth.passkey.delete(', 'runPasskeySignIn'])
    assert.ok(app.includes(path), `${path} was deleted rather than gated`);
});
