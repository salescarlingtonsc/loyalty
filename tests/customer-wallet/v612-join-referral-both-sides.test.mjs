/* nestly_v612 — the join pop-up takes a referral code again, and both parties are rewarded:
 * immediately when the programme sets no spending requirement, or once the referred customer's
 * spending reaches the floor (the untouched v425 sale engine).
 *
 * Owner ruling 2026-08-30, reversing the v587 field removal: "allow user to key in referral
 * code so both parties get the rewards. either immediately if no requirements or receive
 * voucher once requirements (spending) is achieved."
 *
 * The DATABASE behaviour is proven by db/tests/v612_referral_immediate_when_no_floor.sql
 * (17 rolled-back assertions against production: immediate both-sides settle, floor kept,
 * fail-closed pot, no double-pay, guards intact). These pins hold the CLIENT wiring: both
 * join pop-ups carry the code, it survives sign-up, and the customer is told which promise
 * they hold.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const app=readFileSync(new URL('../../app/app.js',import.meta.url),'utf8');
const join=readFileSync(new URL('../../app/join.html',import.meta.url),'utf8');
const migration=readFileSync(new URL('../../db/migrations/20260830_nestly_v612_referral_immediate_when_no_floor.sql',import.meta.url),'utf8');

test('the /join confirm card takes the code and hands it through sign-up',()=>{
  assert.match(join,/id="joinReferral"/,'the optional field is on the camera-scan card');
  assert.match(join,/'nestly\.customer\.shareReferralV576',\s*JSON\.stringify\(\{slug:String\(page\.slug\|\|''\)\.toLowerCase\(\),code:referralCode,at:Date\.now\(\)\}\)/,
    'the code survives sign-up in the v576 share store the wallet auto-applies from');
  assert.match(join,/ref:referralCode/,'and rides the app handoff');
  assert.match(app,/if\(raw\.ref\)pendingCustomerJoinReferralV571=String\(raw\.ref\)/,
    'the app restores it when consuming the handoff');
});

test('both surfaces apply through v612 and the join can never be blocked by a code',()=>{
  const joinRender=app.slice(app.indexOf('async function renderCustomerQrJoin'),app.indexOf('async function renderCustomerClaim'));
  assert.match(joinRender,/customer_apply_referral_code_v612/,'the post-join application names v612');
  assert.ok(joinRender.indexOf('customer_apply_referral_code_v612')>joinRender.indexOf("customerRpc('customer_join_business_from_qr_v89'"),
    'attribution still follows the join');
  assert.match(app,/async function applyShareReferralV576[\s\S]{0,400}?customer_apply_referral_code_v612/,
    'the share-store auto-apply names v612 too');
  assert.doesNotMatch(app,/sb\.rpc\('customer_apply_referral_code_v571'/,
    'no live call site still names the retired v571 binding');
});

test('the customer is told which promise they hold',()=>{
  assert.match(app,/joinReferralPaidNowV612:'Referral applied — you and your friend have both been rewarded\.'/);
  assert.match(app,/joinReferralPaidOnSpendV612:'Referral applied — you and your friend are rewarded once you spend \{floor\} here\.'/);
  const helper=app.slice(app.indexOf('function customerReferralAppliedTextV612'),app.indexOf('function customerReferralReasonTextV571'));
  assert.match(helper,/settled==='immediate'/);
  assert.match(helper,/settled==='on_spend'/);
  assert.match(helper,/money\(floor\)/,'the floor is shown as money, not cents');
});

test('the migration mirrors REGION B and fails closed',()=>{
  assert.match(migration,/perform app\.acquire_loyalty_shared_v480\(v_context\.business_id\);/,
    'an immediate settle is a loyalty value write and takes the v480 fence');
  assert.match(migration,/'referral_reward_points'/,'the sanctioned ledger scope');
  assert.match(migration,/qualifying_sale_id is not distinct from v_ref\.qualified_sale_id/,
    'the batch provenance match is null-safe — null = null is never true in SQL');
  assert.match(migration,/alter column qualifying_sale_id drop not null/,
    'a no-sale settle records the truthful null, never a fabricated sale');
  assert.match(migration,/'on_spend'/,'a floor keeps the sale-settled engine and says so');
  assert.match(migration,/reward_amount_not_set/,'fail-closed reasons survive verbatim');
  assert.match(migration,/revoke all on function public\.customer_apply_referral_code_v612\(text, text, uuid\) from public, anon;/);
});
