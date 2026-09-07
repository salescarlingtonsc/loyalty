/* W4c audit (24h production log review, 2026-09-07/08): the customer wallet was calling two RPCs
 * for features the business does not have turned on, producing routine 4xx noise:
 *
 *   1. customer_get_birthday_benefit -> 400 "birthday benefits are unavailable" whenever the
 *      PLATFORM flag customer_birthday_benefits is off. That flag is already mirrored into
 *      customerFeatures at bootstrap (get_customer_feature_capabilities) and already gates this
 *      section's own markup elsewhere on the page (see the customer_birthday_benefits checks near
 *      the birthday participation card). loadRewards' own fetch of it did not carry the same gate.
 *
 *   2. customer_get_effective_tier_v143 -> 403 "loyalty module is unavailable for this business"
 *      whenever the loyalty module is off or no loyalty programme is active. By the time this
 *      call fires, customer_portal_capabilities has already answered exactly that question in
 *      `capabilities.tiers` (true only when the module is on, a tiers programme is active, and a
 *      tier ladder exists — a strict subset of when the RPC would succeed).
 *
 * Both call sites are now gated on the entitlement signal the client already holds at that point
 * in the same render, instead of firing the RPC and discovering the refusal. Each fallback
 * reproduces the exact {data,error} shape the existing (unchanged) error-handling downstream of
 * the call already treats as "not enabled": no console error, no toast, no retry is introduced by
 * either change.
 *
 * These tests EXTRACT the exact ternary statements from app/app.js and EXECUTE them against a
 * stubbed sb/customerRpc, rather than grepping for the gate — a source-pattern match would stay
 * green even if the condition were inverted or the branches swapped.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const app = await readFile(new URL('../../app/app.js', import.meta.url), 'utf8');

const between = (start, end) => {
  const i = app.indexOf(start);
  assert.ok(i >= 0, `missing statement start: ${start}`);
  const j = app.indexOf(end, i + start.length);
  assert.ok(j > i, `missing statement end: ${end}`);
  return app.slice(i, j + end.length);
};

/* ---------------------------------------------------------------------------------------------
   Site 1: customer_get_birthday_benefit, gated on customerFeatures.customer_birthday_benefits
   --------------------------------------------------------------------------------------------- */

test('W4c: the birthday-benefit read is skipped when the platform flag is off', async () => {
  const stmt = between(
    'customerFeatures.customer_birthday_benefits===true',
    ":Promise.resolve({data:null,error:null})");
  // Evaluate the ternary in isolation: build a function that returns its value given the free
  // variables it closes over (customerFeatures, customerRpc, businessSlug).
  const evaluate = new Function('customerFeatures', 'customerRpc', 'businessSlug',
    `return (${stmt});`);

  const calls = [];
  const customerRpc = (name, args) => { calls.push({ name, args }); return Promise.resolve({ data: { ok: true }, error: null }); };

  const skipped = await evaluate({ customer_birthday_benefits: false }, customerRpc, 'kopi-lab');
  assert.equal(calls.length, 0, 'the flag is off: customer_get_birthday_benefit must not be called');
  assert.deepEqual(skipped, { data: null, error: null },
    'the skipped branch reproduces the exact shape the existing !error check downstream already renders as nothing');

  const called = await evaluate({ customer_birthday_benefits: true }, customerRpc, 'kopi-lab');
  assert.equal(calls.length, 1, 'the flag is on: the read still happens');
  assert.equal(calls[0].name, 'customer_get_birthday_benefit');
  assert.deepEqual(calls[0].args, { p_business_slug: 'kopi-lab' });
  assert.deepEqual(called, { data: { ok: true }, error: null });
});

test('W4c: the birthday-benefit gate reads the same flag the section\'s own markup already checks', () => {
  // Both sites must key off the identical bootstrap flag, or a business could show the card while
  // the read behind it is silently skipped (or vice versa).
  assert.match(app, /customerFeatures\.customer_birthday_benefits&&actionableCard\?\.birthday_benefit/,
    'the participation card is gated on this same flag elsewhere on the page');
});

/* ---------------------------------------------------------------------------------------------
   Site 2: customer_get_effective_tier_v143, gated on capabilities.tiers
   --------------------------------------------------------------------------------------------- */

test('W4c: the effective-tier read is skipped when capabilities.tiers is not true', async () => {
  const stmt = between(
    'const effectiveTierRequest=businessId&&capabilities?.tiers===true',
    "message:'loyalty module is unavailable for this business'}});");

  const evaluate = new Function('businessId', 'capabilities', 'sb',
    `${stmt}\n return effectiveTierRequest;`);

  const calls = [];
  const sb = { rpc: (name, args) => { calls.push({ name, args }); return Promise.resolve({ data: { tier: { label: 'Gold' } }, error: null }); } };

  const offResult = await evaluate('biz-1', { tiers: false }, sb);
  assert.equal(calls.length, 0, 'capabilities.tiers is false: customer_get_effective_tier_v143 must not be called');
  assert.equal(offResult.error?.code, '42501',
    'the skipped branch must carry the SAME error code the existing presentation.tier line already');
  // treats as "not_running" (see the ?not_running:error ternary right after this call).
  assert.match(app, /effectiveTierResult\.error\.code==='42501'\?'not_running':'error'/,
    'downstream, a 42501 renders as "not_running" with no console error, toast, or retry');

  const noBusinessResult = await evaluate(null, { tiers: true }, sb);
  assert.equal(calls.length, 0, 'no businessId: still skipped, same as every other businessId-gated read on this render');
  assert.equal(noBusinessResult.error?.code, '42501');

  const onResult = await evaluate('biz-1', { tiers: true }, sb);
  assert.equal(calls.length, 1, 'capabilities.tiers is true and a businessId is known: the read still happens');
  assert.equal(calls[0].name, 'customer_get_effective_tier_v143');
  assert.deepEqual(calls[0].args, { p_business: 'biz-1' });
  assert.deepEqual(onResult, { data: { tier: { label: 'Gold' } }, error: null });
});

test('W4c: capabilities is fetched (customer_portal_capabilities) before the tier gate reads it', () => {
  // The gate only works because `capabilities` is already resolved by the time this statement
  // runs — both come from the same renderCustomerWallet call, and capabilities is awaited first.
  const capabilitiesFetchIndex = app.indexOf("customerRpc('customer_portal_capabilities',args)");
  const gateIndex = app.indexOf('const effectiveTierRequest=businessId&&capabilities?.tiers===true');
  assert.ok(capabilitiesFetchIndex >= 0 && gateIndex > capabilitiesFetchIndex,
    'customer_portal_capabilities must be fetched (and awaited) earlier in source than the gate that reads its answer');
});
