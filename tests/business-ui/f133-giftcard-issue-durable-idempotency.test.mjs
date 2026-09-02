/* Audit F133 — the Sell-a-card idempotency key on the Gift Cards page was a bare page-scoped
   `let issueGiftCardIdempotencyKey=crypto.randomUUID()`, regenerated every time giftcardsPage()
   ran (route re-entry, a reload, or the branch selector calling giftcardsPage() again). A slow
   or lost response followed by any of those re-invocations meant the retry carried an unrelated
   key; issue_gift_card_at_branch_v117 dedupes strictly on (business_id, idempotency_key), so an
   unseen key is a legitimate new issuance — a second real gift card and a second
   sales(kind='gift_card') liability row for one payment.

   Fix: the same writeAttemptKey(slot, fingerprint) / sessionStorage pattern already used by
   gift-card redeem (20 lines below) and membership enroll — the key survives a full
   giftcardsPage() re-invocation because it does not live in a closure. This test executes the
   real writeAttemptKey/clearWriteAttempt functions (unchanged) against a sessionStorage shim to
   prove the durability property the fix depends on, and checks the issue handler's source for
   the specific regression (a bare crypto.randomUUID() reintroduced at the RPC call site). */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

const section = (source, from, to) => {
  const start = source.indexOf(from);
  assert.ok(start > -1, `missing: ${from}`);
  const end = source.indexOf(to, start);
  assert.ok(end > start, `missing: ${to}`);
  return source.slice(start, end);
};

// A minimal, real sessionStorage — writeAttemptKey's whole durability property depends on this
// being backed by storage that outlives a JS closure, unlike the `let` the defect used.
function makeSessionStorage() {
  const store = new Map();
  return {
    getItem: k => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => store.set(k, String(v)),
    removeItem: k => store.delete(k)
  };
}

const writeAttemptSrc = section(app, 'const writeAttemptKey=', 'const clearWriteAttempt=slot=>{try{sessionStorage.removeItem(slot)}catch{}};');
// `const` bindings from runInContext are lexical, not properties of the context object — expose
// them explicitly on globalThis in the same script so the host (this test) can call them.
const exposedSrc = `${writeAttemptSrc}\nconst clearWriteAttempt=slot=>{try{sessionStorage.removeItem(slot)}catch{}};\nglobalThis.writeAttemptKey=writeAttemptKey;globalThis.clearWriteAttempt=clearWriteAttempt;`;
const ctx = {crypto, sessionStorage: makeSessionStorage()};
vm.createContext(ctx);
vm.runInContext(exposedSrc, ctx);

test('F133: writeAttemptKey (the pattern the fix now uses) survives what a page-scoped `let` cannot — a fresh JS scope, i.e. a full page re-invocation', () => {
  const slot = 'nestly.giftCards.issue';
  const fingerprint = JSON.stringify(['biz-1', 'branch-1', 5000, null, null]);
  const firstKey = ctx.writeAttemptKey(slot, fingerprint);

  // Simulate giftcardsPage() being re-invoked (route re-entry / reload / branch-selector
  // onchange) by running writeAttemptKey again in a FRESH vm context that shares only the
  // sessionStorage backing store — exactly what survives a real page re-render, and exactly
  // what a page-scoped `let issueGiftCardIdempotencyKey=crypto.randomUUID()` could not.
  const ctx2 = {crypto, sessionStorage: ctx.sessionStorage};
  vm.createContext(ctx2);
  vm.runInContext(`${writeAttemptSrc}\nglobalThis.writeAttemptKey=writeAttemptKey;`, ctx2);
  const retryKey = ctx2.writeAttemptKey(slot, fingerprint);

  assert.equal(retryKey, firstKey,
    'a retry of the SAME logical sale (same branch/amount/purchaser/recipient) after a page re-invocation must reuse the same idempotency key, or the server treats it as a brand-new issuance');
});

test('F133: a genuinely different sale (any of branch/amount/purchaser/recipient changes) gets a fresh key', () => {
  const slot = 'nestly.giftCards.issue';
  const key1 = ctx.writeAttemptKey(slot, JSON.stringify(['biz-1', 'branch-1', 5000, null, null]));
  const key2 = ctx.writeAttemptKey(slot, JSON.stringify(['biz-1', 'branch-1', 10000, null, null]));
  assert.notEqual(key1, key2, 'a different amount is a different sale and must not replay the previous one');
});

test('F133: clearWriteAttempt resets the slot so the NEXT deliberate sale starts fresh after settlement', () => {
  const slot = 'nestly.giftCards.issue';
  const fingerprint = JSON.stringify(['biz-1', 'branch-1', 5000, null, null]);
  const before = ctx.writeAttemptKey(slot, fingerprint);
  ctx.clearWriteAttempt(slot);
  const after = ctx.writeAttemptKey(slot, fingerprint);
  assert.notEqual(before, after,
    'once a response has settled the slot must not keep replaying the same key for what looks like an identical next sale');
});

test('F133: the Sell-a-card handler uses the durable writeAttemptKey pattern, not a page-scoped closure variable', () => {
  const handler = section(app, "if(canIssue&&$('gsell'))$('gsell').onclick=async()=>{", "if(canRedeem&&$('gredeem'))$('gredeem').onclick=async()=>{");
  assert.doesNotMatch(handler, /issueGiftCardIdempotencyKey=crypto\.randomUUID\(\)/,
    'this was the defect: a bare `let`-scoped uuid is lost across a giftcardsPage() re-invocation, unlike sessionStorage');
  assert.match(handler, /writeAttemptKey\(issueGiftCardSlot,\s*issueFingerprint\)/);
  assert.match(handler, /p_idempotency_key:issueKey/);
  // Settled-response discipline, matching the sibling redeem/enroll writers on this file: clear
  // on success AND on the server's own conflict codes, so a genuinely new attempt starts fresh.
  assert.match(handler, /clearWriteAttempt\(issueGiftCardSlot\)/);
  assert.match(handler, /error\.code==='23505'\|\|error\.code==='40001'/,
    'the issue handler should recognise the same conflict codes the sibling money-writers on this page handle');
});

test('F133: the page-scoped `let issueGiftCardIdempotencyKey=crypto.randomUUID()` closure variable is gone', () => {
  assert.doesNotMatch(app, /let issueGiftCardIdempotencyKey=crypto\.randomUUID\(\);/);
});
