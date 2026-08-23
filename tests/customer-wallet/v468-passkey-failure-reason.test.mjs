import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* V468 (owner photo B8: "Enable now" circled, "not working").
   The screenshot showed the prompt ALREADY displaying "Passkey setup was not completed" — so the
   button had run and the ceremony had failed, and the only thing the screen could say was a
   sentence with no reason in it. That is the defect this file pins: not that the click is dead
   (it is not — the handler re-enables and stays bound), but that a failure was unreportable.

   EXECUTED, not grepped: the mapper is extracted and called, because a regex over the source
   would pass just as happily on a function that returned the generic sentence for everything. */

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(resolve(repoRoot, 'app/app.js'), 'utf8');

const slice = (start, end) => {
  const from = app.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = app.indexOf(end, from + start.length);
  assert.ok(to > from, `missing end after ${start}`);
  return app.slice(from, to);
};

const message = new Function(
  `${slice('function customerPasskeyErrorMessage(', '\nasync function maybeOfferCustomerPasskeySetup')}
   return customerPasskeyErrorMessage;`)();

test('V468 a cancelled Face ID sheet is not reported as a broken setup', () => {
  /* The commonest outcome by far, and it is not a fault: the browser throws NotAllowedError when
     the person dismisses the sheet, when it times out, or when the page is not focused. Telling
     them "setup was not completed. You can add it later from Profile." invites them to press the
     button forever, which is exactly what the owner did. */
  for (const name of ['NotAllowedError', 'AbortError']) {
    const setup = message({ name }, { action: 'setup' });
    assert.match(setup, /cancelled or timed out/);
    assert.match(setup, /Enable now/, 'it must say how to retry, here and now');
    assert.doesNotMatch(setup, /add it later from Profile/, 'a cancel is not a dead end');
    assert.match(message({ name }, { action: 'sign-in' }), /cancelled or timed out/);
  }
});

test('V468 an unrecognised failure carries its own reason instead of a shrug', () => {
  const out = message({ code: 'webauthn_rp_id_mismatch', message: 'rp id does not match origin' },
    { action: 'setup' });
  assert.match(out, /Passkey setup was not completed/, 'the plain-English line survives');
  assert.match(out, /rp id does not match origin/,
    'the reason must reach the screen — it is the only channel back from the customer device');
});

test('V468 a reason-less unknown error still reads as a sentence, not a dangling bracket', () => {
  const out = message({}, { action: 'setup' });
  assert.equal(out, 'Passkey setup was not completed. You can add it later from Profile.');
  assert.doesNotMatch(out, /\(\)/);
});

test('V468 the codes that already had plain-English answers keep them, unchanged', () => {
  /* These were correct before and must not regress into the new "(code)" shape. */
  assert.equal(message({ code: 'passkey_disabled' }, { action: 'setup' }),
    'Face ID and passkeys aren’t available yet. Use your password.');
  assert.equal(message({ code: 'webauthn_credential_exists' }, { action: 'setup' }),
    'This device already has a passkey for this account.');
  assert.match(message({ code: 'webauthn_verification_failed' }, { action: 'setup' }),
    /current Peekaa domain/);
  assert.match(message({ code: 'phone_not_confirmed' }, { action: 'setup' }),
    /Finish account verification/);
});

test('V468 neither passkey button can be stranded by a thrown WebAuthn rejection', () => {
  /* registerPasskey resolves {error} for a server refusal but THROWS for a browser-side
     rejection. An unhandled throw left the button disabled and the status stuck on "Follow your
     device prompt…" — a dead dialog, and silent, because an async onclick's rejection reaches no
     handler. Both call sites must funnel a throw into the same error path. */
  const sites = [...app.matchAll(/try\{\(\{error\}=await sb\.auth\.registerPasskey\(\)\|\|\{\}\)\}catch\(thrown\)\{error=thrown\}/g)];
  assert.equal(sites.length, 2, 'the signup prompt and the Profile card both guard the throw');
  assert.doesNotMatch(app, /const \{error\}=await sb\.auth\.registerPasskey\(\);/,
    'no unguarded registerPasskey call may remain');
});
