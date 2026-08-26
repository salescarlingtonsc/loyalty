import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

/* nestly_v542 — a business waiting on Stripe can ask to pay another way.
 *
 * Owner: "i need a back button for firms to change from stripe payment to manual payment."
 * A back LINK would have been worse than none: request_self_serve_manual_application_v159 refuses
 * any account already attached to a business — which every owner on this screen is — so the form
 * it led to was guaranteed to 42501. This asks instead, and asking grants nothing.
 *
 * The database side is proven by db/tests/v542_*.sql (19 assertions, run rolled back against
 * production). These assertions cover the half that lives in the client: that the screen offers
 * the door, that it says plainly the workspace stays shut, and that it cannot be mistaken for a
 * payment.
 */

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');
const migration = readFileSync(
  new URL('../../db/migrations/20260827_nestly_v542_pending_business_may_ask_to_pay_manually.sql',
    import.meta.url), 'utf8');

const card = app.slice(app.indexOf('function selfServeManualSwitchCardV542'),
  app.indexOf('function wireSelfServeManualSwitchV542'));

test('V542 the payment-pending screen offers a way to ask', () => {
  assert.ok(app.includes('${selfServeManualSwitchCardV542(onboarding)}'),
    'the card is rendered on the pending screen');
  assert.ok(app.includes('wireSelfServeManualSwitchV542(onboarding)'), 'and wired');
  assert.match(card, />Request manual payment</);
});

test('V543 the SME copy is exactly what the owner specified', () => {
  /* Owner-supplied wording, 2026-08-27. Pinned verbatim because it is a billing screen: the
     promise it makes about when the account opens is the thing a firm will hold us to. */
  assert.match(card, /Prefer bank transfer or another payment method\?/);
  assert.match(card, /Request manual payment and our team will assist you with the payment details\. Your account will be activated once payment is verified\./);
  assert.match(card, />Request manual payment</, 'the button label');
  const wire = app.slice(app.indexOf('function wireSelfServeManualSwitchV542'),
    app.indexOf('function renderSelfServePaymentPendingV286'));
  assert.match(wire, /Manual payment requested/, 'the settled button label');
  assert.match(wire, /We\u2019ve received your request\. Our team will assist you with the payment details\. You can still pay online below if you prefer\./);
  assert.ok(!/switch(ed)? to manual/i.test(card),
    'the button requests; it does not claim to switch anything');
});

test('V542 the client sends the request and nothing else', () => {
  const wire = app.slice(app.indexOf('function wireSelfServeManualSwitchV542'),
    app.indexOf('function renderSelfServePaymentPendingV286'));
  assert.match(wire, /sb\.rpc\('business_request_manual_payment_v542'/);
  assert.match(wire, /sb\.rpc\('business_get_manual_payment_request_v542'/,
    'an existing request is shown on arrival so the owner is not invited to ask twice');
  /* Matched against the CALLS, not the prose — the copy legitimately says the word "invoice"
     because that is what the team will send. What must not appear is a second RPC. */
  const calls = [...wire.matchAll(/sb\.rpc\('([^']+)'/g)].map((m) => m[1]).sort();
  assert.deepEqual(calls,
    ['business_get_manual_payment_request_v542', 'business_request_manual_payment_v542'],
    'the screen reads its own request and files one — it calls nothing else');
  assert.match(wire, /const key=crypto\.randomUUID\(\)/,
    'one key per screen, so a double tap is the same request');
});

test('V542 the migration relaxes nothing — the old guard is untouched', () => {
  assert.ok(!/create or replace function public\.request_self_serve_manual_application_v159/i.test(migration),
    'the existing guard protects a real case and is not what needed changing');
  assert.match(migration, /approval_status is distinct from 'pending'/,
    'the new door is open only while the business is still awaiting first payment');
  assert.match(migration, /v_onboarding_status is distinct from 'payment_pending'/);
  assert.match(migration, /s\.role = 'owner'\s*\n\s*and s\.active/,
    'and only to an active owner of that exact business');
});

test('V542 the request table is sealed and the ask is superseded by a real payment', () => {
  assert.match(migration, /enable row level security/);
  assert.match(migration, /revoke all on public\.business_manual_payment_requests_v542 from anon, authenticated/,
    'RLS with no policy AND no grants — the RPC is the only way in');
  assert.match(migration, /business_manual_payment_requests_v542_one_open_uk/,
    'one open request per business, or a Super Admin sees duplicates');
  /* The update lives inside a quoted PL/pgSQL literal in the splice, so its quotes are doubled. */
  assert.match(migration, /set status=''superseded''/,
    'a provider-confirmed payment closes the ask in the same transaction');
  assert.match(migration, /activate_self_serve_paid_v130/);
});
