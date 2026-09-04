/* nestly_v752 — the birthday gift becomes a real benefit: same editor, same till, customer QR.
 *
 * Owner ruling (2026-09-04, confirmed in a follow-up question): "Birthday rewards must also have
 * the same function as tier membership rewards — the mechanism is wired correctly (not just
 * typing words, but real objectives like example discount for whole bill or selected items)."
 * Clarified further: ONE benefit, using the SAME editor as a tier benefit, and the customer must
 * be able to see the birthday reward in their customer app so they can let the business scan the
 * QR code.
 *
 * The server half is proved against production by
 * db/tests/v752_birthday_gift_is_a_benefit.sql (A1-A5, rolled back). These pin the browser half,
 * and — following tests/customer-wallet/v676-gift-qr-retap.test.mjs and
 * tests/customer-wallet/v501-tier-perks-reach-the-customer.test.mjs — EXECUTE the shipped blocks
 * lifted verbatim out of app/app.js against stubs, rather than grepping for them.
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

/* =================================================================================================
 * 1. renderCustomerWallet's birthday-entitlement-to-entitlementsV429 transformation. The customer
 *    wallet gives the birthday gift a card through the SAME entitlementCardV429 renderer that
 *    already draws welcome/bringback/referral gifts (and therefore the SAME "Show QR at counter"
 *    button, verified separately below) — this block is what makes that reuse work: it never
 *    pushes a birthday row unless the server itself says the entitlement is 'available' AND
 *    carries an id (app.c45_safe_birthday_entitlement only sets 'id' on a live, in-window,
 *    unredeemed entitlement — see the migration's part 3b).
 * ================================================================================================= */
test('a live birthday entitlement becomes an entitlementsV429 row with source birthday', () => {
  const src = block(
    "    const birthdayBenefitDataV752=!birthdayBenefitResultV752?.error?birthdayBenefitResultV752?.data:null;",
    '\n    }');
  const run = birthdayBenefitResultV752 => {
    const entitlementsV429 = [];
    new Function('entitlementsV429', 'birthdayBenefitResultV752', src)(entitlementsV429, birthdayBenefitResultV752);
    return entitlementsV429;
  };

  const available = run({
    data: {
      status: 'available', id: 'ent-1', display: '10% off, up to 5.00',
      description: 'A birthday treat on us.',
      validity: { available_from: '2026-09-01T00:00:00Z', available_until: '2026-09-30T23:59:59Z' }
    }
  });
  assert.equal(available.length, 1);
  assert.deepEqual(available[0], {
    source: 'birthday', id: 'ent-1', label: '10% off, up to 5.00',
    granted_at: '2026-09-01T00:00:00Z', expires_at: '2026-09-30T23:59:59Z',
    min_spend_cents: 0, instructions: 'A birthday treat on us.'
  });

  // No id (status !== 'available', or the entitlement genuinely does not exist yet) -> no row.
  assert.equal(run({ data: { status: 'unavailable' } }).length, 0);
  assert.equal(run({ data: { status: 'available' } }).length, 0);
  assert.equal(run({ data: null }).length, 0);
  assert.equal(run({ error: { message: 'boom' }, data: { status: 'available', id: 'ent-2' } }).length, 0);
});

/* =================================================================================================
 * 2. The gift-QR button is fully generic already (nestly_v515/v676): reusing it for a birthday
 *    entitlement needs ZERO new client code, because it reads gift_kind and target straight off
 *    the button's own dataset. This proves gift_kind:'birthday' threads through the shipped
 *    handler exactly like 'welcome' does in v676's own suite — same handler, different kind.
 * ================================================================================================= */
test('Show QR at counter mints a birthday gift intent through the shared handler', async () => {
  const handlerSrc = block(
    "    host.querySelectorAll('[data-customer-gift-redeem]').forEach(button=>{",
    '\n    });');
  const keySrc = block('const writeAttemptKey=(slot,fingerprint)=>{',
    'const clearWriteAttempt=slot=>{try{sessionStorage.removeItem(slot)}catch{}};');

  const span = { textContent: 'Show QR at counter' };
  const button = {
    disabled: false, isConnected: true,
    dataset: { customerGiftRedeem: 'birthday:ent-1' },
    querySelector: () => span, onclick: null
  };
  const store = new Map();
  const calls = [];
  const shown = [];
  const scope = {
    host: { querySelectorAll: () => [button] },
    businessId: 'biz-1',
    b: { name: 'Kopi Lab' },
    sb: { rpc: (name, args) => { calls.push({ name, args }); return Promise.resolve({
      data: { intent_id: 'intent-1', status: 'pending', gift_kind: 'birthday',
        reward_label: '10% off, up to 5.00', min_spend_cents: 0,
        qr_token: 'tok-abc', expires_at: '2026-09-01T00:15:00Z', replayed: false },
      error: null
    }); } },
    sessionStorage: {
      getItem: k => (store.has(k) ? store.get(k) : null),
      setItem: (k, v) => store.set(k, String(v)),
      removeItem: k => store.delete(k)
    },
    crypto: { randomUUID: () => `key-${calls.length}` },
    toast: () => {},
    isWalletSectionCurrent: () => true,
    showPendingRedemptionQr: options => shown.push(options),
    loadRewards: () => {},
    customerCounterMomentV468: async () => {},
    customerHoldWalletScrollV748: () => () => {}
  };
  const names = Object.keys(scope);
  new Function(...names, `${keySrc}\n${handlerSrc}`)(...names.map(n => scope[n]));

  await button.onclick();
  await new Promise(r => setTimeout(r, 0));

  assert.equal(calls.length, 1);
  assert.equal(calls[0].name, 'customer_create_gift_intent_v515');
  assert.equal(calls[0].args.p_gift_kind, 'birthday');
  assert.equal(calls[0].args.p_target, 'ent-1');
  assert.equal(shown.length, 1);
  assert.equal(shown[0].qrRoute, 'gift-redeem');
});

/* =================================================================================================
 * 3. applyStagedTierPerkV665's new birthday branch (nestly_v752): a staged discount whose
 *    gift_kind is 'birthday' sets appliedBirthdayV752, not appliedTierBenefitV656 — the flag
 *    app.ps1c_plan_checkout's new p_birthday parameter actually reads (via runEvaluate, proved
 *    separately by the p_birthday-forwarding assertion below). A failed re-price rolls BOTH flags
 *    back to their previous values, exactly as it already did for the tier flag alone.
 * ================================================================================================= */
test('a staged birthday discount sets appliedBirthdayV752, and a refusal rolls it back', async () => {
  const src = block(
    '    async function applyStagedTierPerkV665(staged){',
    '\n    }');
  const build = (evaluateResults) => {
    const toasts = [];
    const wrapped = `
      let appliedTierBenefitV656=null, appliedBirthdayV752=false;
      const isTillCurrent=()=>true;
      const catalog0={};let catalog=catalog0;
      const draw=()=>{};
      const workspaceTemplateTextV97=(key,vars)=>String(vars&&vars.item||key);
      const runEvaluate=async()=>{
        state.calls.push({tier:appliedTierBenefitV656,birthday:appliedBirthdayV752});
        return evaluateResults[state.calls.length-1<evaluateResults.length?state.i++:state.i-1];
      };
      ${src}
      return {
        run: applyStagedTierPerkV665,
        state: () => ({ tier: appliedTierBenefitV656, birthday: appliedBirthdayV752 })
      };
    `;
    const state = { calls: [], i: 0 };
    const factory = new Function('toast', 'evaluateResults', 'state', wrapped);
    const built = factory(m => toasts.push(String(m)), evaluateResults, state);
    return { built, calls: state.calls, toasts };
  };

  // Success: the flag is set BEFORE runEvaluate is called (evaluate_checkout must see it).
  {
    const { built, calls } = build([true]);
    await built.run({ gift_kind: 'birthday', benefit_id: 'ent-1', reward_label: '10% off' });
    assert.equal(built.state().birthday, true);
    assert.equal(built.state().tier, null);
    assert.equal(calls.length, 1);
    assert.deepEqual(calls[0], { tier: null, birthday: true });
  }

  // A tier_perk staged discount still sets the ORIGINAL flag, never the birthday one.
  {
    const { built } = build([true]);
    await built.run({ gift_kind: 'tier_perk', benefit_id: 'tb-1', reward_label: '20% off' });
    assert.equal(built.state().tier, 'tb-1');
    assert.equal(built.state().birthday, false);
  }

  // Refusal (evaluate_checkout says false): both flags roll back to their previous values, and
  // a second runEvaluate call re-prices without the birthday flag.
  {
    const { built, calls, toasts } = build([false, true]);
    await built.run({ gift_kind: 'birthday', benefit_id: 'ent-1', reward_label: '10% off' });
    assert.equal(built.state().birthday, false);
    assert.equal(calls.length, 2);
    assert.deepEqual(calls[0], { tier: null, birthday: true });
    assert.deepEqual(calls[1], { tier: null, birthday: false });
    assert.equal(toasts.length, 1);
    assert.match(toasts[0], /could not be applied/);
  }
});

/* =================================================================================================
 * 4. runEvaluate forwards p_birthday to evaluate_checkout exactly the way it forwards
 *    p_tier_benefit — the wire the till's own staged/applied state rides on.
 * ================================================================================================= */
test('runEvaluate sends p_birthday alongside p_tier_benefit to evaluate_checkout', () => {
  const src = app.slice(
    app.indexOf("    const {data,error}=await sb.rpc('evaluate_checkout',{p_business:S.biz.id,p_branch:tillBranchId||null,"),
    app.indexOf('p_birthday:cust?appliedBirthdayV752:false});') + 'p_birthday:cust?appliedBirthdayV752:false});'.length
  );
  assert.match(src, /p_tier_benefit:cust\?appliedTierBenefitV656:null/);
  assert.match(src, /p_birthday:cust\?appliedBirthdayV752:false/);
});

/* =================================================================================================
 * 5. The checkout-panel discount line names a birthday gift the same way it names a tier benefit
 *    (nestly_v657) — reading birthday_benefit_mode/item/capped instead of tier_benefit_*, so the
 *    counter reads "10% off, up to 5.00 · Free V752 Birthday Cupcake" style scope text rather than
 *    a bare "Discount".
 * ================================================================================================= */
test('the checkout effect line labels a birthday_benefit source, capped and scoped', () => {
  const src = block(
    '    const tierModeV657=String(e.tier_benefit_mode||\'\');',
    ':`Discount${scopeTxt}`;');
  const wrapped = `
    const scopeTxt='';
    ${src}
    return labelV370;
  `;
  const run = e => new Function('e', wrapped)(e);

  assert.equal(run({
    source: 'birthday_benefit', label: '10% off, up to 5.00',
    birthday_benefit_mode: 'bill', birthday_benefit_capped: true
  }), '10% off, up to 5.00 (capped)');

  assert.equal(run({
    source: 'birthday_benefit', label: 'Free item',
    birthday_benefit_mode: 'item', birthday_benefit_item: 'V752 Birthday Cupcake'
  }), 'Free item · V752 Birthday Cupcake');

  // A tier benefit keeps reading its own fields, unaffected by the new birthday branch.
  assert.equal(run({
    source: 'tier_benefit', label: '20% off', tier_benefit_mode: 'bill', tier_benefit_capped: false
  }), '20% off');
});
