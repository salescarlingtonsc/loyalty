/* nestly_v676 — re-tapping "Show QR at counter" brings back the SAME gift QR.
 *
 * Audit F048 (client half) / F056 (server half). A customer who closed the gift QR sheet by any
 * route except "Cancel redemption" left a live pending intent behind. The old handler kept its
 * idempotency key in a page-scoped `let` that onClose nulled and the re-render re-created, so the
 * next tap sent a brand-new key, missed the server's replay branch, and violated the
 * one-pending-QR-per-gift index — a generic "could not be prepared" toast for up to 15 minutes.
 *
 * These EXECUTE the shipped handler (and the shipped writeAttemptKey), rather than grepping for
 * it: the block is lifted verbatim out of app/app.js and run against stubs. The server half is
 * proved against production by db/tests/v676_gift_intent_reopen.sql.
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

const handlerSrc = block(
  "    host.querySelectorAll('[data-customer-gift-redeem]').forEach(button=>{",
  '\n    });');
const keySrc = block('const writeAttemptKey=(slot,fingerprint)=>{',
  'const clearWriteAttempt=slot=>{try{sessionStorage.removeItem(slot)}catch{}};');

/* A gift button and the smallest host that can hand it to querySelectorAll. */
const makeButton = () => {
  const span = { textContent: 'Show QR at counter' };
  return {
    disabled: false, isConnected: true,
    dataset: { customerGiftRedeem: 'welcome:grant-1' },
    querySelector: () => span,
    onclick: null,
    span
  };
};

const run = ({ replies }) => {
  const store = new Map();
  const calls = [];
  const shown = [];
  const toasts = [];
  const button = makeButton();
  const scope = {
    host: { querySelectorAll: () => [button] },
    businessId: 'biz-1',
    b: { name: 'Kopi Lab' },
    sb: {
      rpc: (name, args) => {
        calls.push({ name, args });
        return Promise.resolve(replies(calls.length, args));
      }
    },
    sessionStorage: {
      getItem: k => (store.has(k) ? store.get(k) : null),
      setItem: (k, v) => store.set(k, String(v)),
      removeItem: k => store.delete(k)
    },
    crypto: { randomUUID: () => `key-${store.size}-${calls.length}-${Math.random()}` },
    toast: message => toasts.push(String(message)),
    isWalletSectionCurrent: () => true,
    showPendingRedemptionQr: options => shown.push(options),
    loadRewards: () => {},
    customerCounterMomentV468: async () => {},
    /* nestly_v748: onClose now holds the page's scroll across the two repaints it triggers
       (owner photo 4). Stubbed here — this suite is about the idempotency key, and the hold's
       own behaviour is proved in tests/customer-wallet/v748-qr-close-holds-scroll.test.mjs. */
    customerHoldWalletScrollV748: () => () => {}
  };
  // The shipped block assigns onclick onto every button the host hands it; run it verbatim.
  const names = Object.keys(scope);
  new Function(...names, `${keySrc}\n${handlerSrc}`)(...names.map(n => scope[n]));
  return { button, calls, shown, toasts, store };
};

const pending = (key, id = 'intent-1') => ({
  data: {
    intent_id: id, status: 'pending', gift_kind: 'welcome', reward_label: 'Free drink',
    qr_token: `token-for-${id}`, expires_at: '2026-09-02T12:15:00+08:00', replayed: false
  },
  error: null
});

test('v676 a re-tap after closing the sheet reuses the SAME idempotency key', async () => {
  const rig = run({ replies: () => pending('k') });
  await rig.button.onclick();
  rig.shown[0].onClose();            // "Close — keep pending", the X, Escape, Back — all land here
  await rig.button.onclick();
  assert.equal(rig.calls.length, 2);
  assert.equal(rig.calls[0].name, 'customer_create_gift_intent_v515');
  assert.equal(rig.calls[1].args.p_idempotency_key, rig.calls[0].args.p_idempotency_key,
    'closing the sheet must not retire the key — the re-tap is a retry of the same write');
  assert.equal(rig.shown.length, 2);
  assert.equal(rig.shown[1].intent.qr_token, rig.shown[0].intent.qr_token,
    'the customer must get the same QR back, not a failure');
  assert.deepEqual(rig.toasts, []);
});

test('v676 the key survives a full re-render of the rewards section', async () => {
  const first = run({ replies: () => pending('k') });
  await first.button.onclick();
  const keyBefore = first.calls[0].args.p_idempotency_key;
  // A second wiring pass with the SAME sessionStorage is what loadRewards does behind the sheet.
  const store = first.store;
  const second = run({ replies: () => pending('k') });
  for (const [k, v] of store) second.store.set(k, v);
  await second.button.onclick();
  assert.equal(second.calls[0].args.p_idempotency_key, keyBefore);
});

test('v676 a settled intent retires the key and mints a fresh one', async () => {
  const rig = run({
    replies: n => (n === 1
      ? { data: { intent_id: 'old', status: 'completed', qr_token: 'stale' }, error: null }
      : pending('k', 'intent-2'))
  });
  await rig.button.onclick();
  assert.equal(rig.calls.length, 2, 'a completed replay must be re-minted, never shown as live');
  assert.notEqual(rig.calls[1].args.p_idempotency_key, rig.calls[0].args.p_idempotency_key);
  assert.equal(rig.shown.length, 1);
  assert.equal(rig.shown[0].intent.intent_id, 'intent-2');
});

test('v676 the server sentence for a QR already open is shown to the customer', async () => {
  const rig = run({
    replies: () => ({ data: null,
      error: { code: 'P0001',
        message: 'this gift already has a QR open at the counter — use it, or wait for it to expire' } })
  });
  await rig.button.onclick();
  assert.equal(rig.shown.length, 0);
  assert.match(rig.toasts.join(' '), /already has a QR open at the counter/);
});

test('v676 the gift key is scoped to the gift, so two gifts never share one intent', () => {
  assert.match(handlerSrc,
    /nestly\.customer\.giftIntent:\$\{businessId\}:\$\{giftKind\}:\$\{targetId\}/,
    'the storage slot must name the business and the gift');
  assert.doesNotMatch(handlerSrc, /giftAttemptV515/,
    'the page-scoped key that caused F048 must be gone');
});
