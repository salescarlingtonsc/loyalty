import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* V265 (owner rulings, 2026-08-09):
   A. one tick, broad scope - Nestly Technologies Pte Ltd and its partners, by push, in-app,
      email, SMS, WhatsApp, phone CALL and other marketing channels;
   B. "the customers may be distributed to peekaa partners for marketing purpose only" - which
      REVERSES the v2 promise that partners never receive contact details;
   C. withdrawal is in-app only - no admin email address in the consent copy;
   D. Peekaa stops immediately, partners are told to stop within 10 business days.

   What this file protects, because each is a way the change could look done and be theatre:
   - the tick is genuinely optional and never pre-ticked (a pre-ticked box is not a choice);
   - the copy a customer reads BEFORE ticking states the partner sharing, in those words;
   - the retired "partners never receive" promise is gone from BOTH customer surfaces;
   - ticking also fires the v263 master grant, so the tick and the switches cannot disagree;
   - the consent SCOPE advances, so a v2 tick is never counted as agreement to v3. */

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const appJs = readFileSync(resolve(repoRoot, 'app/app.js'), 'utf8');
const indexHtml = readFileSync(resolve(repoRoot, 'app/index.html'), 'utf8');
const appSource = `${indexHtml}\n${appJs}`;
const migration = readFileSync(
  resolve(repoRoot, 'db/migrations/20260810_nestly_v265_marketing_consent_scope.sql'),
  'utf8'
);

function block(anchor, endMarker) {
  const from = appSource.indexOf(anchor);
  assert.ok(from >= 0, `missing anchor: ${anchor}`);
  const to = appSource.indexOf(endMarker, from + anchor.length);
  assert.ok(to > from, `missing end marker after ${anchor}`);
  return appSource.slice(from, to);
}

/* The label element the customer reads at signup, and the Profile card that lets them
   change their mind. Everything asserted about "the copy" is asserted against these two. */
const signupTick = block('for="customerSignupMarketing"', '</fieldset>');
const marketingCard = block('id="customerMarketingPreference"', '</section>');
const consentSurfaces = [
  ['signup tick', signupTick],
  ['Profile marketing card', marketingCard]
];

test('V265: the signup marketing tick exists, is optional, and is never pre-checked', () => {
  assert.match(signupTick, /id="customerSignupMarketing" type="checkbox"/);
  assert.match(signupTick, /\(Optional\)/);
  /* Checked only from the customer's own in-progress answer - never a literal `checked`
     and never a truthy default. */
  assert.match(signupTick, /\$\{customerRegistrationState\.marketingOptedIn\?'checked':''\}/);
  assert.doesNotMatch(signupTick, /type="checkbox" checked/);
  assert.doesNotMatch(appSource, /p_platform_marketing_opted_in:true/);
});

test('V265: both consent surfaces name Nestly Technologies Pte Ltd', () => {
  for (const [name, copy] of consentSurfaces) {
    assert.match(copy, /Nestly Technologies Pte\.? Ltd\.?/i, `${name} does not name the operating company`);
  }
});

test('V265: both consent surfaces list every channel, including phone call', () => {
  for (const [name, copy] of consentSurfaces) {
    for (const channel of [/push notification/i, /in-app message/i, /email/i, /SMS/i, /WhatsApp/i, /phone call/i, /other marketing channels/i]) {
      assert.match(copy, channel, `${name} does not name ${channel}`);
    }
  }
});

test('V265: both consent surfaces state partner sharing, for marketing purposes only', () => {
  for (const [name, copy] of consentSurfaces) {
    assert.match(copy, /contact details may be shared with/i, `${name} does not state that details may be shared`);
    assert.match(copy, /partners for marketing purposes only/i, `${name} does not limit the sharing to marketing`);
    /* Permission, not a description of current practice: there is no partner-distribution
       pipeline today, so "may be shared" is the only honest tense. */
    assert.doesNotMatch(copy, /we share your contact details|we send your details to partners/i);
  }
});

test('V265: the retired "partners never receive contact details" promise is gone from both surfaces', () => {
  // Superseded by owner ruling B (2026-08-09): partners DO receive customer contact details.
  for (const [name, copy] of consentSurfaces) {
    assert.doesNotMatch(copy, /partners never receive/i, `${name} still carries the retired promise`);
    assert.doesNotMatch(copy, /does not provide partners/i, `${name} still carries the retired promise`);
  }
});

test('V265: withdrawal is in-app, and no admin email address appears in the consent copy', () => {
  // Owner ruling C: "can inapp alone settle it? so i will not need to receive any email" - yes.
  assert.match(signupTick, /Profile → Communications/);
  assert.match(marketingCard, /#\/customer\/communications/);
  for (const [name, copy] of consentSurfaces) {
    assert.doesNotMatch(copy, /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/, `${name} contains an email address`);
    assert.doesNotMatch(copy, /mailto:/i, `${name} contains a mailto link`);
  }
  /* Withdrawal must be at least as easy as the tick: Communications is a card in Profile,
     one tap from the account area. */
  assert.match(appSource, /id="customerCommunicationsEntry"/);
  assert.match(appSource, /href="#\/customer\/communications"/);
});

test('V265: the timeframe is stated accurately - Peekaa immediately, partners within 10 business days', () => {
  for (const [name, copy] of consentSurfaces) {
    assert.match(copy, /stops sending straight away/i, `${name} does not say Peekaa stops immediately`);
    assert.match(copy, /Partners are told to stop within 10 business days/i, `${name} does not state the partner timeframe`);
    /* Never imply partner sending stops instantly - the system cannot make that true. */
    assert.doesNotMatch(copy, /partners stop (immediately|straight away)/i, `${name} overstates partner behaviour`);
  }
});

test('V265: granting marketing consent also fires the v263 master grant', () => {
  assert.match(appJs, /async function grantAllCommunicationsV265\(\)/);
  assert.match(
    appJs,
    /grantAllCommunicationsV265[\s\S]{0,400}?sb\.rpc\('customer_set_all_communications_v263',\{p_enabled:true\}\)/,
    'the master grant must reuse customer_set_all_communications_v263, not re-implement it'
  );
  /* Signup: consent is recorded by the registration RPC first, then the grant follows. */
  const registration = block("registerRequest:async()=>{", 'resolveDestination:');
  const rpcAt = registration.indexOf("sb.rpc('customer_register_verified_phone'");
  const grantAt = registration.indexOf('grantAllCommunicationsV265');
  assert.ok(rpcAt >= 0 && grantAt > rpcAt, 'the v263 grant must follow the consent record at signup');
  assert.match(registration, /if\(!result\.error&&customerSignupMarketingOptedIn\(\)\)await grantAllCommunicationsV265\(\)/);

  /* Profile: same order, and a failed grant is reported rather than papered over, so the
     Communications screen can never be contradicted by a success message here. */
  const save = block("const marketingSave=$('customerProfileMarketingSave')", "$('customerProfilePasswordSave')");
  const setAt = save.indexOf("sb.rpc('customer_set_platform_marketing_preference'");
  const saveGrantAt = save.indexOf('grantAllCommunicationsV265');
  assert.ok(setAt >= 0 && saveGrantAt > setAt, 'the v263 grant must follow the consent write in Profile');
  assert.match(save, /could not be turned back on/);
});

test('V265: the consent scope version advances rather than reusing the v2 scope', () => {
  assert.match(migration, /2026-08-10-partner-sharing-v3/);
  /* prepare, capture and reader must all pin the SAME new scope, or a grant records
     evidence its own reader rejects (the exact drift v175 had to repair). */
  for (const fn of [
    /create or replace function app\.v92_prepare_platform_marketing_preference\(\)[\s\S]*?\$\$;/,
    /create or replace function app\.v92_capture_platform_marketing_consent\(\)[\s\S]*?\$\$;/,
    /create or replace function public\.customer_get_platform_marketing_preference\(\)[\s\S]*?\$\$;/
  ]) {
    const body = migration.match(fn);
    assert.ok(body, `migration does not replace ${fn}`);
    assert.match(body[0], /2026-08-10-partner-sharing-v3/);
    assert.doesNotMatch(body[0], /2026-08-06-selected-partners-v2/);
  }
  /* Consent given under the narrower v2 wording must not read as agreement to v3. */
  assert.match(migration, /update public\.customer_registration_preferences[\s\S]{0,200}set platform_marketing_opted_in = false/);
  /* History stays readable: the events check constraint keeps admitting v1 and v2. */
  assert.match(migration, /'2026-07-28-selected-partners-v1'/);
  assert.match(migration, /'2026-08-06-selected-partners-v2'/);
});

test('V265: the migration keeps the function ACLs closed to anon', () => {
  assert.match(migration, /revoke all on function public\.customer_get_platform_marketing_preference\(\)\s*\n\s*from public, anon, authenticated;/);
  assert.match(migration, /grant execute on function public\.customer_get_platform_marketing_preference\(\)\s*\n\s*to authenticated;/);
  for (const fn of ['app.v92_prepare_platform_marketing_preference', 'app.v92_capture_platform_marketing_consent']) {
    assert.ok(
      new RegExp(`revoke all on function ${fn.replace('.', '\\.')}\\(\\)\\s*\\n\\s*from public, anon, authenticated;`).test(migration),
      `${fn} is not revoked from public, anon, authenticated`
    );
    assert.ok(!new RegExp(`grant execute on function ${fn.replace('.', '\\.')}`).test(migration),
      `${fn} is a trigger function and must not be granted to a browser role`);
  }
  assert.match(migration, /^begin;$/m);
  assert.match(migration, /^commit;$/m);
});

test('V265: no legal-compliance claim is asserted in customer-facing consent copy', () => {
  // CLAUDE.md: flag ⚖️ items for counsel, never assert compliance.
  for (const [name, copy] of consentSurfaces) {
    assert.doesNotMatch(copy, /PDPA[- ]compliant|in accordance with the PDPA|legally compliant/i, `${name} asserts compliance`);
  }
});
