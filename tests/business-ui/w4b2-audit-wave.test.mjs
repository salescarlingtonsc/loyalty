/* W4B2 audit wave — regressions for F026, F029 (client-side portion), F030, F031, F032.

   Each test extracts the real source of the function/expression under test and EXECUTES it
   against stub globals, so the assertions fail when behaviour regresses rather than when
   the spelling changes. F029's server-side rules (min lengths, publish window) are mirrored
   CLIENT-SIDE only, per the finding — these tests cover that client validation and the
   owner-facing error-text mapping, not a server change.
*/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const appJs = await readFile(path.join(root, 'app/app.js'), 'utf8');
const section = (from, to) => {
  const a = appJs.indexOf(from); assert.ok(a > -1, `missing: ${from}`);
  const b = appJs.indexOf(to, a); assert.ok(b > a, `missing: ${to} after ${from}`);
  return appJs.slice(a, b);
};

/* ================================================================== F026 */
/* Referrals "How to use it" step 3 must use the same reward-kind-aware wording as the settings
   card above it, instead of always assuming points. */

test('F026 referral step-3 amount uses the reward kind, not always points', () => {
  const startMarker = "referralEnabled\n        ?workspaceTemplateHtmlV97('referralEnabledOutcome',{amount:";
  const endMarker = "})\n        :'The programme is Off.";
  const startIdx = appJs.indexOf(startMarker);
  assert.ok(startIdx > -1, `missing: ${startMarker}`);
  const exprStart = startIdx + startMarker.length;
  const endIdx = appJs.indexOf(endMarker, exprStart);
  assert.ok(endIdx > exprStart, `missing: ${endMarker}`);
  const src = appJs.slice(exprStart, endIdx);
  // src is exactly the JS expression that computes the `amount` template variable.
  const fn = vm.runInNewContext(
    `(function(referralKindV429,p,growReferralAmountWordV425){ return (${src}); })`,
    {}
  );
  const growReferralAmountWordV425 = (kind, amount) =>
    kind === 'stamps' ? `${amount} stamp(s)` : `${amount} point(s)`;

  // Stamps programme: must NOT fall back to hardcoded "point(s)" wording.
  assert.equal(
    fn('stamps', { reward_kind: 'stamps', reward_points: 3 }, growReferralAmountWordV425),
    '3 stamp(s)'
  );
  // Points programme: unchanged behaviour.
  assert.equal(
    fn('points', { reward_points: 200 }, growReferralAmountWordV425),
    '200 point(s)'
  );
  // Voucher/free-gift programme: names the actual gift, matching the settings card above it.
  assert.equal(
    fn('voucher', { reward_label: 'Free coffee' }, growReferralAmountWordV425),
    'Free coffee'
  );
  assert.equal(
    fn('voucher', { reward_label: '  ' }, growReferralAmountWordV425),
    'a free gift'
  );
});

/* ================================================================== F030 */
/* The "Selected branches" checklist must never offer an inactive/unpaid branch — the server
   (`foreign_or_inactive_branch_scope`, v155 migration) refuses one anyway, but only after the
   photo has already been uploaded, so filtering must happen up front. */

test('F030 promotionBranches is filtered through activeBranchesForScopeV217', async () => {
  const helper = section('function activeBranchesForScopeV217(branches=[]){', '\n}') + '\n}';
  const block = section('let promotionBranches=[];', 'promotionBranches=activeBranchesForScopeV217(promotionBranches);')
    + 'promotionBranches=activeBranchesForScopeV217(promotionBranches);';
  const src = `${helper}\n(async function(visibleBranchesForCurrentUser){\n${block}\nreturn promotionBranches;\n})`;
  const branches = [
    { id: 'b1', name: 'Active branch', active: true },
    { id: 'b2', name: 'Switched off', active: false },
    { id: 'b3', name: 'Undeclared (treated active)' },
  ];
  const runner = vm.runInNewContext(src, {});
  const result = await runner(async () => ({ branches }));
  assert.deepEqual(result.map(b => b.id), ['b1', 'b3']);
});

/* ================================================================== F031 */
/* The Delete/End button on the Promotions page must guard against a stale render exactly like
   its sibling controls (Show on Home, #/grow/offers delete) — it must not toast success or
   re-render a page the owner has already navigated away from. */

function buildDeleteHandler({ rpcError = null, navigateAwayAfterRpc = false } = {}) {
  const src = section(
    "host.querySelectorAll('[data-promotion-delete]').forEach(button=>button.onclick=async()=>{",
    '\n  const pageRoot='
  ) + "\n  const pageRoot=host.querySelector('.promotion-studio'),\n    isPromotionCurrent=()=>S.biz?.id===businessId&&promotionPageCurrentV104(pageRoot,host);";
  const promotionPageCurrentV104 = (pageRoot, host) => Boolean(pageRoot?.isConnected && host?.contains?.(pageRoot));
  const promotionsPageCalls = [];
  const toasts = [];
  const button = {
    dataset: { promotionDelete: 'promo-1', promotionPublished: '', promotionName: 'Grand Opening' },
    isConnected: true,
    onclick: null,
  };
  const host = {
    querySelectorAll: sel => (sel === '[data-promotion-delete]' ? [button] : []),
    querySelector: () => ({ isConnected: true }),
    contains: () => true,
  };
  const context = {
    host,
    businessId: 'biz-1',
    S: { biz: { id: 'biz-1' } },
    confirmActionV386: async () => true,
    CUI: { setButtonBusy: () => {} },
    sb: {
      rpc: async () => {
        if (navigateAwayAfterRpc) context.S.biz.id = 'biz-OTHER'; // owner switched businesses mid-flight
        return { error: rpcError };
      },
    },
    toast: message => toasts.push(String(message)),
    ownerErrorText: error => String(error?.message || error),
    promotionsPage: id => promotionsPageCalls.push(id),
    promotionPageCurrentV104,
  };
  vm.createContext(context);
  vm.runInContext(src, context);
  return { button, promotionsPageCalls, toasts };
}

test('F031 delete/end still completes normally when the page stays current', async () => {
  const { button, promotionsPageCalls, toasts } = buildDeleteHandler();
  await button.onclick();
  assert.deepEqual(promotionsPageCalls, [null]);
  assert.match(toasts.join(' '), /retired|deleted/i);
});

test('F031 delete/end does NOT toast success or re-render after navigating away mid-flight', async () => {
  const { button, promotionsPageCalls, toasts } = buildDeleteHandler({ navigateAwayAfterRpc: true });
  await button.onclick();
  assert.deepEqual(promotionsPageCalls, [], 'promotionsPage(null) must not run against a stale page');
  assert.deepEqual(toasts, [], 'no success toast for a write the owner is no longer looking at');
});

test('F031 a real RPC error still surfaces normally when the page is current', async () => {
  const { button, promotionsPageCalls, toasts } = buildDeleteHandler({ rpcError: { message: 'boom' } });
  await button.onclick();
  assert.deepEqual(promotionsPageCalls, []);
  assert.match(toasts.join(' '), /boom/);
});

/* ================================================================== F032 */
/* Pressing "+ Add" for a brand-new promotion (no selectedPromotionId) must never inherit a
   stale interrupted-finalize/create receipt's id — doing so silently hijacks the new draft onto
   the old promotion. */

function computeWorkingPromotionId({ selected, selectedPromotionId, pendingFinalize, pendingCreate }) {
  const src = section(
    'let pendingCreate=readSessionValue(createPendingStorageKey),',
    'createOutcomeUnconfirmed=Boolean(\n      pendingCreate?.promotionId===workingPromotionId&&!selected\n    );'
  ) + 'createOutcomeUnconfirmed=Boolean(\n      pendingCreate?.promotionId===workingPromotionId&&!selected\n    );';
  const fn = vm.runInNewContext(
    `(function(selected,selectedPromotionId,readSessionValue,createPendingStorageKey,pendingStorageKey,crypto){\n${src}\nreturn {workingPromotionId,createConfirmed,interruptedPromotionId};\n})`,
    {}
  );
  const store = { create: pendingCreate || null, finalize: pendingFinalize || null };
  const readSessionValue = key => (key === 'createKey' ? store.create : store.finalize);
  const crypto = { randomUUID: () => 'FRESH-UUID' };
  return fn(selected, selectedPromotionId, readSessionValue, 'createKey', 'finalizeKey', crypto);
}

test('F032 "+ Add" with no selection gets a fresh id even when an interrupted finalize is pending', () => {
  const result = computeWorkingPromotionId({
    selected: null,
    selectedPromotionId: null,
    pendingFinalize: { promotionId: 'OLD-INTERRUPTED-ID' },
    pendingCreate: null,
  });
  assert.equal(result.workingPromotionId, 'FRESH-UUID', 'must not hijack the stale interrupted id');
  assert.equal(result.createConfirmed, false);
});

test('F032 explicitly opening the interrupted promotion still resolves to its own id', () => {
  const result = computeWorkingPromotionId({
    selected: null,
    selectedPromotionId: 'OLD-INTERRUPTED-ID',
    pendingFinalize: { promotionId: 'OLD-INTERRUPTED-ID' },
    pendingCreate: null,
  });
  assert.equal(result.workingPromotionId, 'OLD-INTERRUPTED-ID');
});

test("F032 opening an existing promotion by id still uses that promotion's own id", () => {
  const result = computeWorkingPromotionId({
    selected: { id: 'REAL-PROMO' },
    selectedPromotionId: 'REAL-PROMO',
    pendingFinalize: null,
    pendingCreate: null,
  });
  assert.equal(result.workingPromotionId, 'REAL-PROMO');
  assert.equal(result.createConfirmed, true);
});

/* ================================================================== F029 (client side) */
/* runSave must refuse fields that violate the server's own min/max lengths, and the publish
   end-date-in-the-future rule, before the code ever reaches the photo upload. The owner-facing
   text for the raw server tokens must no longer be the misleading generic error string either. */

test('F029 the owner-facing error mapping understands the promotion validation tokens', () => {
  const rulesSrc = section('const OWNER_ERROR_NOISE_RULES_V170=[', '\n];') + '\n];';
  const ownerErrorTextSrc = section('const ownerErrorText=error=>{', '\n};') + '\n};';
  const ownerErrorText = vm.runInNewContext(`${rulesSrc}\n${ownerErrorTextSrc}\nownerErrorText`, {});
  assert.doesNotMatch(
    ownerErrorText({ message: 'valid_promotion_draft_fields_required' }),
    /reopen it/i
  );
  assert.match(ownerErrorText({ message: 'valid_promotion_draft_fields_required' }), /70|600/);
  assert.match(ownerErrorText({ message: 'valid_promotion_finalize_fields_required' }), /characters|limits/i);
  assert.match(ownerErrorText({ message: 'promotion_publishing_window_closed' }), /publishing window|Peekaa/i);
  assert.match(ownerErrorText({ message: 'owner_required' }), /business owner/i);
});

function buildPromotionFieldGuards() {
  const src = section(
    "if(!draft.offerFacts)return toast('Add the exact offer.');",
    "return toast('The end date/time has already passed — choose a later end date to publish.');"
  ) + "return toast('The end date/time has already passed — choose a later end date to publish.');";
  return vm.runInNewContext(
    `(function(draft,publish,unpublish,toast,PROMOTION_COPY_POLICY_V104){\n${src}\n})`,
    {}
  );
}

const validDraft = () => ({
  offerFacts: 'Buy one get one free',
  name: 'Grand Opening',
  description: 'Come celebrate our grand opening with us this weekend only, everyone welcome!',
  starts_at: new Date(Date.now() - 86400000).toISOString(),
  ends_at: new Date(Date.now() + 86400000).toISOString(),
  ctaKind: 'book',
  ctaLabel: 'Book now',
  occasion: '',
  terms: '',
});
const ctaPolicy = { ctas: { book: true, programme: true, counter: true } };

test('F029 a too-short headline (below the server\'s 2-70) is refused before upload', () => {
  const guards = buildPromotionFieldGuards();
  const toasts = [];
  guards({ ...validDraft(), name: 'A' }, true, false, m => toasts.push(m), ctaPolicy);
  assert.match(toasts.join(' '), /2.*70/);
});

test('F029 a too-short customer message (below the server\'s 10-600) is refused', () => {
  const guards = buildPromotionFieldGuards();
  const toasts = [];
  guards({ ...validDraft(), description: 'short' }, true, false, m => toasts.push(m), ctaPolicy);
  assert.match(toasts.join(' '), /10.*600/);
});

test('F029 an occasion outside 2-80 (when provided) is refused', () => {
  const guards = buildPromotionFieldGuards();
  const toasts = [];
  guards({ ...validDraft(), occasion: 'x'.repeat(81) }, true, false, m => toasts.push(m), ctaPolicy);
  assert.match(toasts.join(' '), /2.*80/);
});

test('F029 publishing with an end date already in the past is refused', () => {
  const guards = buildPromotionFieldGuards();
  const toasts = [];
  guards(
    { ...validDraft(), starts_at: new Date(Date.now() - 7200000).toISOString(), ends_at: new Date(Date.now() - 3600000).toISOString() },
    true, false, m => toasts.push(m), ctaPolicy
  );
  assert.match(toasts.join(' '), /already passed|future/i);
});

test('F029 saving a draft (not publishing) with a past end date is NOT refused by the publish-window rule', () => {
  const guards = buildPromotionFieldGuards();
  const toasts = [];
  // starts_at < ends_at still required, so keep both in the past but ordered correctly.
  guards(
    { ...validDraft(), starts_at: new Date(Date.now() - 7200000).toISOString(), ends_at: new Date(Date.now() - 3600000).toISOString() },
    false, false, m => toasts.push(m), ctaPolicy
  );
  assert.equal(toasts.length, 0, 'draft save must not enforce the publish-only future-end-date rule');
});

test('F029 a fully valid draft passes every guard without any toast', () => {
  const guards = buildPromotionFieldGuards();
  const toasts = [];
  guards(validDraft(), true, false, m => toasts.push(m), ctaPolicy);
  assert.deepEqual(toasts, []);
});
