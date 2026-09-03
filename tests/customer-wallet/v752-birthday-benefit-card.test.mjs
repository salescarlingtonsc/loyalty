/* nestly_v752 — the birthday gift joins the QR-gift vocabulary (client half).
 *
 * Owner ruling 2026-09-04: the birthday gift becomes a structured benefit (same editor/mechanism
 * as a tier benefit) and the customer must be able to see it in the app and let staff scan its
 * QR — the same door welcome/bringback/referral already have.
 *
 * These EXECUTE the shipped source (lifted verbatim out of app/app.js), rather than grepping for
 * it, matching the pattern tests/customer-wallet/v676-gift-qr-retap.test.mjs sets: extract the
 * exact object-literal / merge block and run it against a stub payload.
 *
 * WHAT THIS DOES NOT COVER (time-boxed scope, documented rather than silently skipped): the full
 * wallet render pass (entitlementCardV429 producing the actual "Show QR at counter" DOM) is not
 * executed here — that would need lifting the whole customer-wallet render closure, which this
 * pass did not have budget to isolate safely. The server-side contract (customer_get_birthday_
 * benefit returning an 'id' only while available/in-window, and the derived label) is proved by
 * db/tests/v752_birthday_gift_is_a_benefit.sql (assertions A1-A5), which is the part nestly_v752
 * actually changed on the server. This file proves the two client-side additions: the gift_kind
 * label vocabulary, and the RPC-result-to-entitlement-card adapter.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const app = await readFile(new URL('../../app/app.js', import.meta.url), 'utf8');

const block = (start, end) => {
  const i = app.indexOf(start);
  assert.ok(i >= 0, `missing block: ${start}`);
  const j = app.indexOf(end, i);
  assert.ok(j > i, `missing end marker for ${start}`);
  return app.slice(i, j + end.length);
};

test('GIFT_KIND_LABEL_V665 carries a birthday entry', () => {
  const src = block(
    "const GIFT_KIND_LABEL_V665=Object.freeze({",
    "birthday:'Birthday gift'});");
  // eslint-disable-next-line no-new-func
  const map = new Function(`return ${src.slice(src.indexOf('Object.freeze'))}`)();
  assert.equal(map.birthday, 'Birthday gift');
  assert.equal(map.tier_perk, 'Tier perk');
});

test('entitlementSourceChipV429 carries a birthday entry', () => {
  const src = block(
    "const entitlementSourceChipV429=",
    "birthday:'Birthday gift'};");
  const literal = src.slice(src.indexOf('{'));
  // eslint-disable-next-line no-new-func
  const map = new Function(`return ${literal}`)();
  assert.equal(map.birthday, 'Birthday gift');
});

test('the birthday RPC result is adapted into an entitlementCardV429-shaped row only when available and only once', () => {
  const src = block(
    'const birthdayBenefitDataV752=',
    '\n    }');
  // Reconstruct the tiny adapter in isolation, faithful to the shipped shape (an object with
  // .error/.data, matching every other customerRpc() result this file merges).
  const run = (birthdayBenefitResultV752) => {
    const entitlementsV429 = [];
    // eslint-disable-next-line no-new-func
    const fn = new Function('birthdayBenefitResultV752', 'entitlementsV429', src + '\nreturn entitlementsV429;');
    return fn(birthdayBenefitResultV752, entitlementsV429);
  };

  // Available, in-window, unused: a card is pushed with the id needed for the QR button.
  const available = run({
    error: null,
    data: {
      status: 'available', id: 'entitlement-1',
      display: '10% off, up to 5.00', label: 'THIS TYPED TEXT MUST NOT SURVIVE',
      description: 'A birthday treat on us.',
      validity: { available_from: '2026-09-01T00:00:00Z', available_until: '2026-09-08T00:00:00Z' }
    }
  });
  assert.equal(available.length, 1);
  assert.equal(available[0].source, 'birthday');
  assert.equal(available[0].id, 'entitlement-1');
  // The derived server sentence wins over any typed label that might be present on the payload.
  assert.equal(available[0].label, '10% off, up to 5.00');

  // Redeemed: the server never sends an id for a spent entitlement (app.c45_safe_birthday_
  // entitlement, nestly_v752), so no card — proving the client needs no eligibility arithmetic
  // of its own, the same fail-closed rule the welcome/bringback/referral cards already follow.
  const redeemed = run({ error: null, data: { status: 'redeemed', id: null, display: '10% off' } });
  assert.equal(redeemed.length, 0);

  // Not yet activated / no programme: no card.
  const unavailable = run({ error: null, data: { status: 'unavailable' } });
  assert.equal(unavailable.length, 0);

  // RPC error: fail closed, no card.
  const errored = run({ error: { message: 'boom' }, data: null });
  assert.equal(errored.length, 0);
});
