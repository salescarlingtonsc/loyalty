/* nestly_v571 — the customer names who referred them, and a promotion message can say which
   offer it is about.

   These assert the CONTRACT the browser half must keep, because the server half is proven
   separately by db/tests/v571_referral_attribution_and_inbox_provenance.sql (run against
   production, rolled back). The two properties that matter here and cannot be seen in SQL:

     - a referral code is applied AFTER the join and never before it, so a bad code cannot be
       the reason somebody fails to join a programme;
     - a promotion message shows the offer's own name only when the payload carries one, and
       falls back to the stored title otherwise. Historical messages have no reference and must
       not have a name invented for them. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const appJs = await readFile(path.join(root, 'app/app.js'), 'utf8');

const section = (source, from, to) => {
  const start = source.indexOf(from);
  assert.ok(start > -1, `missing: ${from}`);
  const end = to ? source.indexOf(to, start) : source.length;
  assert.ok(end > start, `missing: ${to}`);
  return source.slice(start, end);
};

test('v571 the referral is applied AFTER the join, never before it', () => {
  const join = section(appJs, 'async function renderCustomerQrJoin()', 'async function renderCustomerClaim()');
  const joinCall = join.indexOf("customerRpc('customer_join_business_from_qr_v89'");
  const applyCall = join.indexOf("sb.rpc('customer_apply_referral_code_v612'");
  assert.ok(joinCall > -1, 'the join still happens');
  assert.ok(applyCall > -1, 'the attribution happens');
  assert.ok(applyCall > joinCall,
    'attribution must follow the join — otherwise a referral code could fail a join');
  /* And it is only reached once the join has actually been accepted: the guard clauses above it
     all return, so the apply sits after the last of them. */
  const refusal = join.lastIndexOf('This programme could not be joined');
  assert.ok(applyCall > refusal, 'attribution sits past every join-failure return');
});

/* nestly_v758 (owner ruling 3, superseding v612): the printed business QR is a plain "join this
   business" code and must NEVER carry or apply a referral. The field v612 put back is gone again
   — this time for good on this path — and the sheet must not read a code out of the v576 share
   store either, nor leave one sitting in the in-memory slot for a later apply. */
test('nestly_v761 the QR/token join sheet keeps an optional TYPED referral field, never a prefilled one', () => {
  const dialog = section(appJs, 'async function confirmCustomerJoinV571(', 'let pendingCustomerJoinReferralV571');
  assert.match(dialog, /<input id="customerJoinReferralV612"(?![^>]*\b(?:value|readonly)\b)[^>]*placeholder=/, 'an empty, editable referral field: no value, no readonly');
  assert.match(dialog, /pendingCustomerJoinReferralV571=typedReferralV761/, 'a typed code rides the in-memory slot only');
  assert.doesNotMatch(dialog, /peekShareReferralV576/, 'the sheet never reads a code out of the v576 store');
  assert.doesNotMatch(dialog, /rememberShareReferralV576/, 'and never writes one back into it either');
  assert.match(dialog, /pendingCustomerJoinReferralV571=''/, 'any leftover referral slot is cleared, not shown');
  assert.match(dialog, /id="customerJoinGoV571"/, 'one Yes');
  assert.match(dialog, /id="customerJoinCancelV571"[^>]*aria-label/, 'and one close, which is a real control');
  // The preview names the business from the key the server actually sends.
  assert.match(dialog, /preview\?\.name\|\|preview\?\.business_name/);
});

test('nestly_v587 referral by shared link still needs nobody to type a code', () => {
  assert.match(appJs, /async function applyShareReferralV576\(slug\)\{/);
  assert.match(appJs, /customer_apply_referral_code_v612/);
});

test('v571 the attribution key is stable across a retried join', () => {
  const join = section(appJs, 'async function renderCustomerQrJoin()', 'async function renderCustomerClaim()');
  assert.match(join, /writeAttemptKey\('nestly\.customer\.joinReferral',`\$\{slug\}:\$\{referralCodeV571\}`\)/,
    'the same business and code must produce the same idempotency key on a retry');
  assert.match(join, /pendingCustomerJoinReferralV571='';/, 'the code is consumed once');
});

test('v571 every server refusal reason has customer-facing wording', () => {
  const source = section(appJs, 'function customerReferralReasonTextV571(', 'let pendingCustomerJoinReferralV571');
  const reasons = ['unknown_code', 'self_referral', 'already_referred', 'referrals_off', 'unknown_business'];
  const ct = key => `[${key}]`;
  const { customerReferralReasonTextV571 } = vm.runInNewContext(
    `${source}; ({customerReferralReasonTextV571})`, { ct });
  for (const reason of reasons) {
    assert.equal(customerReferralReasonTextV571(reason), `[joinReferral${
      { unknown_code: 'Unknown', self_referral: 'Self', already_referred: 'Already',
        referrals_off: 'Off', unknown_business: 'Unknown' }[reason]}V571]`,
      `${reason} must have its own wording`);
  }
  assert.equal(customerReferralReasonTextV571('something_new'), '[joinReferralUnknownV571]',
    'an unmapped reason still says something rather than nothing');
});

test('v571 a promotion message shows the offer name only when the payload carries one', () => {
  const rows = section(appJs, 'const renderedItems=items.map(item=>{', 'return `<article class="customer-inbox-item');
  assert.match(rows, /const line=String\(item\?\.offer_title\|\|item\?\.title\|\|'Inbox update'\)\.trim\(\);/,
    'offer_title leads, the stored title is the fallback — nothing is inferred');
  /* Historical rows: the reader returns null for offer_title, so the expression above must fall
     through to the stored title. Proven by evaluating the same expression. */
  const line = payload => String(payload?.offer_title || payload?.title || 'Inbox update').trim();
  assert.equal(line({ offer_title: null, title: 'New promotion available' }), 'New promotion available',
    'a historical promotion row keeps its stored title');
  assert.equal(line({ offer_title: 'National Day: 50% off first prata', title: 'New promotion available' }),
    'National Day: 50% off first prata', 'a stamped row shows the offer');
  assert.equal(line({ offer_title: null, title: 'Booking confirmed' }), 'Booking confirmed',
    'a non-promotion message is untouched');
});

test('v571 the business logo replaces the monogram only when there is one', () => {
  const rows = section(appJs, 'const renderedItems=items.map(item=>{', '}).join(\'\');');
  assert.match(rows, /const logoV571=customerMediaUrlV95\(business\?\.logo_url\);/);
  assert.match(rows, /logoV571\s*\?`<img class="customer-inbox-avatar-v386 customer-inbox-avatar-logo-v571"/);
  assert.match(rows, /:`<span class="customer-inbox-avatar-v386" aria-hidden="true">\$\{esc\(monogram\)\}<\/span>`/,
    'a business with no logo keeps the monogram');
});
