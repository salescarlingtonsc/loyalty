/* nestly_v758 — the friend's referral link opens a confirmation sheet, the printed QR does not.
 *
 * Owner rulings, implemented together because they are two halves of one policy:
 *
 *   3. The business QR (#/join?token=…) is a plain "join this business" code. It must never
 *      show, read or apply a referral — not the field v612 put back on that sheet, and not a
 *      code sitting in the v576 share store for that slug from an earlier friend link.
 *   4. The friend's link (#/wallet/<slug>?ref=CODE) must open THE SAME styled confirmation sheet
 *      — logo, "Join <business>?", the code shown read-only — for both signed-out and signed-in
 *      visitors, exactly once per visit, before the join/registration it leads into.
 *
 * These are source-contract tests (the style already used by the sibling v571/v587/v604/v612
 * suites in this directory): they pin the exact call sites and guards rather than driving a full
 * DOM, because the surrounding router and dialog plumbing already has its own executable coverage
 * for repaint/staleness races (v604) and the join RPC sequencing (v571).
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const app=readFileSync(new URL('../../app/app.js',import.meta.url),'utf8');

const section=(from,to)=>{
  const start=app.indexOf(from);
  assert.ok(start>-1,`missing: ${from}`);
  const end=to?app.indexOf(to,start):app.length;
  assert.ok(end>start,`missing: ${to}`);
  return app.slice(start,end);
};

test('a) the QR/token join sheet offers an optional typed referral field and applies no stored code',()=>{
  const dialog=section('async function confirmCustomerJoinV571(','let pendingCustomerJoinReferralV571');
  assert.match(dialog,/<input id="customerJoinReferralV612"(?![^>]*\b(?:value|readonly)\b)[^>]*placeholder=/,'an empty, editable referral input (nestly_v761) — never prefilled, never read-only');
  assert.match(dialog,/pendingCustomerJoinReferralV571=typedReferralV761/,'what was typed is what gets applied; empty means nothing');
  assert.doesNotMatch(dialog,/peekShareReferralV576/,'never reads a code out of the v576 share store');
  assert.doesNotMatch(dialog,/rememberShareReferralV576/,'never writes one back into it either');
  assert.match(dialog,/pendingCustomerJoinReferralV571=''/,'any leftover referral slot is cleared, not carried');
  // The join-page handoff (join.html's own optional field) is likewise never restored here.
  assert.doesNotMatch(app,/if\(raw\.ref\)pendingCustomerJoinReferralV571=String\(raw\.ref\)/,
    'the app-side handoff consumer no longer restores a referral for this path');
});

test('b) a fresh ?ref= arming a wallet link records the slug and resets the ask-once flag',()=>{
  const capture=section("if(h.startsWith('#/wallet/')&&h.includes('?')){","if(h.startsWith('#/customer?')){");
  assert.match(capture,/const refCode=new URLSearchParams\(queryPart\|\|''\)\.get\('ref'\)\|\|'';/);
  assert.match(capture,/rememberShareReferralV576\(refSlug,refCode\);/,'the code still lands in the v576 store');
  assert.match(capture,/pendingReferralSheetSlugV576=refSlug;customerReferralAskedThisVisitV576=false;/,
    'a fresh link arms the sheet and clears any earlier answer, mirroring the v599 join-token rule');
});

test('b) confirmCustomerShareReferralV576 resolves the business by slug and shows the code read-only',()=>{
  const start=app.indexOf('async function confirmCustomerShareReferralV576(');
  const end=app.indexOf('\n}\n',start)+3;
  const body=app.slice(start,end);
  assert.match(body,/publicGateway\('public-booking',\{method:'GET',query:`\?slug=\$\{encodeURIComponent\(slug\)\}`\}\)/,
    'resolves the business name the same way the public booking portal does, by slug — no token involved');
  assert.match(body,/const code=peekShareReferralV576\(slug\);/,'reads the stored share-link code');
  assert.match(body,/id="customerJoinReferralV612"/,'reuses the same field id so the Yes handler contract is unchanged');
  assert.match(body,/value="\$\{esc\(code\)\}" readonly/,'the code is shown but cannot be edited');
  assert.match(body,/joinConfirmTitleV571.*business:name/,'names the business when the preview resolves');
  assert.match(body,/joinConfirmTitleUnknownV571/,'falls back to the generic title when it does not');
  assert.match(body,/const dismiss=\(\)=>\{clearShareReferralV576\(\);close\(false\)\};/,
    'dismissing drops the stored code rather than leaving it to fire on a later visit');
});

test('c) both the signed-out and signed-in wallet routes gate on the same sheet before proceeding',()=>{
  const signedOut=section('const directCustomerDestination=normalizeCustomerDestination(h);',"if(!S.user&&h==='#/join'){");
  assert.match(signedOut,/confirmCustomerShareReferralV576\(destinationSlugV576,isRouteCurrent\)/,
    'signed-out: the sheet runs before renderCustomerRegistration is reached');
  assert.match(signedOut,/if\(!proceed\)\{\s*clearShareReferralV576\(\);pendingReferralSheetSlugV576='';/,
    'a No clears the stored code so it cannot silently reapply later');

  const walletDispatch=section("if(h==='#/wallet'||h.startsWith('#/wallet/')){","\n    /* V288 (audit A2, HIGH 4)");
  assert.match(walletDispatch,/confirmCustomerShareReferralV576\(slugForSheetV576,isRouteCurrent\)/,
    'signed-in: the sheet runs before the wallet (or not-joined) render');
  assert.match(walletDispatch,/return renderCustomerWallet\(walletSlugV576\);/,
    'a Yes (or nothing pending) falls through to the existing wallet render, which still auto-applies via applyShareReferralV576');
});

test('c) a Yes on the ref-link path never invents a new join RPC — it reuses the existing paths',()=>{
  // Signed-out Yes: same pendingCustomerBusinessSlug + renderCustomerRegistration wiring the
  // token-join direct-destination case already used before this feature existed.
  const signedOut=section('const directCustomerDestination=normalizeCustomerDestination(h);',"if(!S.user&&h==='#/join'){");
  assert.match(signedOut,/pendingCustomerBusinessSlug=destinationSlugV576;/);
  assert.match(signedOut,/return renderCustomerRegistration\(isRouteCurrent\);/);
  // Signed-in Yes when not yet a member: renderCustomerWallet's own renderCustomerNotJoinedV289
  // is untouched and still sends the customer through #/claim?business=<slug>.
  const notJoined=section('function renderCustomerNotJoinedV289(businessSlug){','function customerLoadReferenceV389');
  assert.match(notJoined,/nav\('#\/claim\?business='\+encodeURIComponent\(String\(businessSlug\|\|''\)\)\)/);
  // And the code itself is applied by the wallet render's existing fire-and-forget call —
  // no new RPC name appears anywhere in this feature.
  assert.match(app,/if\(businessSlug\)applyShareReferralV576\(businessSlug\)\.catch\(\(\)=>\{\}\);/);
});
