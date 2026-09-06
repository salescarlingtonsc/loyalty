import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');
/* V257: this was a fixed 95000-character window, so growing Record sale silently sliced the
   fourth money path out of view and the count assertion below failed for no behavioural
   reason. Cut at the real section boundary instead. */
const till = app.slice(app.indexOf('async function tillPage'), app.indexOf('async function salesPage(){'));

test('a sale can be credited to the teammate who performed it, not just the till operator', () => {
  // Owner: "under record sale - i must be able to select who is the sales staff to allocate
  // commissions". Every sale was attributed to the signed-in user, so a salon receptionist took
  // the therapist's commission.
  assert.match(till, /id="tillSaleStaff"/);
  assert.match(till, /const tillActingStaffId=tillRoster\.find\(person=>person\.user_id===S\.user\.id\)/);
  assert.match(till, /let tillSaleStaffId=tillActingStaffId/);
  // the roster must actually be loaded, not just my own row
  assert.match(till, /from\('staff'\)\.select\('id,full_name,user_id'\)/);
});

test('every money path uses the attributed teammate', () => {
  // Attribution drives the frozen per-sale commission snapshot.
  /* nestly_v755: this used to be 4 — quick sale, cart finalize, and the two Stripe-Connect-backed
     PayNow QR fingerprint/resume writes (beginPaynowPaymentV142 / resumePaynowPaymentV142). That
     whole payment rail (Razorpay SG has no Connect equivalent) is removed — see
     RAZORPAY_SWAP_SPEC.md — leaving the two money paths that remain: quick sale and cart
     finalize (record_cart_sale). */
  assert.equal((till.match(/tillSaleStaffId\|\|tillStaffId/g) || []).length, 2,
    'quick sale and cart finalize');
  assert.ok(!/p_staff:tillStaffId\b/.test(till), 'no money path may still hardcode the operator');
});

test('re-attributing starts a new attempt instead of replaying the previous one', () => {
  // F024 (audit wave w4b1) removed the LEGACY amount-only card's own copy of this handler (it
  // reset saleIdem=null on change) because that card's RPC, record_sale_by_phone, rejects any
  // teammate but the caller — so this is now the itemized cart flow's single onchange handler,
  // which re-attributes by re-rendering rather than by resetting a key: the finalise/PayNow
  // fingerprints already carry tillSaleStaffId (asserted below), so a change of attribution can
  // never replay the previous teammate's sale without a separate reset.
  // audit F024 (wave 4B1): the legacy amount-only card no longer offers a teammate picker at all
  // (record_sale_by_phone always rejected it), so the only tillSaleStaff control left is the
  // cart's, which re-draws; the cart-finalize key is derived from evalFingerprint() and the
  // attributed teammate travels as p_staff on the finalise call, pinned below.
  const i = till.indexOf("$('tillSaleStaff').onchange");
  const src = till.slice(i, i + 120);
  assert.match(src, /tillSaleStaffId=event\.target\.value\|\|tillActingStaffId;draw\(\)/);
  assert.match(till, /p_staff:tillSaleStaffId\|\|tillStaffId,p_method:tender,p_idempotency_key:finaliseKey/,
    'the attributed teammate must be passed on the same finalise call that carries the stable idempotency key');
});

test('the picker only appears when someone else could have done the work', () => {
  // A one-person shop and F&B never see it; it configures itself instead of needing a setting.
  // F024 (audit wave w4b1): the LEGACY amount-only card's own copy of this picker was removed —
  // record_sale_by_phone (the RPC that card calls) rejects any p_staff other than the caller's
  // own staff row with a 42501, so offering a choice there could only ever fail or lie. The
  // itemized cart flow's picker (record_cart_sale, which DOES accept another teammate) is the
  // one this test now anchors on; the regex tolerates the line break before its own `?`.
  assert.match(till, /tillAttributableStaff\.length>1\s*\?/);
  assert.match(till, /const tillAttributableStaffFor=branchId=>tillRoster\.filter/);
  // Candidates are branch-scoped unless the actor legitimately covers several branches.
  const i = till.indexOf('const tillAttributableStaffFor');
  const src = till.slice(i, i + 340);
  assert.match(src, /canSeeAllTillBranches/);
  assert.match(src, /row\.branch_id===branchId/);
});
