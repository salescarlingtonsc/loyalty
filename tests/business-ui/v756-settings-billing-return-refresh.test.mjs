/* NESTLY v756 — the Settings billing card polls itself after a Razorpay return.
 *
 * After Razorpay checkout the browser returns to `/#/settings?billing=processing`. The card
 * used to render once from the pre-payment payload (get_business_billing_v125's own response,
 * fetched before the webhook lands) and never refresh until a manual reload. This executes the
 * real polling primitives added in app/app.js — settingsBillingReturnStateV756,
 * settingsBillingReturnSignatureV756, settingsBillingReturnStripV756 and the standalone
 * settingsBillingReturnPollV756 — rather than grepping source text, per
 * docs: "Source-regex tests are vacuous".
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

const blockStart = app.indexOf('function settingsBillingReturnStateV756(){');
const blockEnd = app.indexOf('let settingsBillingPollActiveV756=false;');
assert.ok(blockStart > -1, 'settingsBillingReturnStateV756 must exist');
assert.ok(blockEnd > blockStart, 'settingsBillingPollActiveV756 marker must exist after the block');
const pollBlock = app.slice(blockStart, blockEnd) + 'let settingsBillingPollActiveV756=false;\n';

function makeSandbox(initialHash) {
  const sandbox = {
    location: { hash: initialHash, search: '', pathname: '/business' },
    history: { replaceState: (_s, _t, url) => { sandbox.__lastUrl = url; sandbox.location.hash = '#' + String(url).split('#')[1] || ''; } },
    setTimeout,
    clearTimeout,
    console,
    URLSearchParams
  };
  const context = vm.createContext(sandbox);
  vm.runInContext(pollBlock, context);
  return context;
}

test('settingsBillingReturnStateV756 reads billing=processing from the hash query', () => {
  const ctx = makeSandbox('#/settings?billing=processing');
  assert.equal(ctx.settingsBillingReturnStateV756().processing, true);
});

test('settingsBillingReturnStateV756 is false for a normal settings visit', () => {
  const ctx = makeSandbox('#/settings?tab=billing');
  assert.equal(ctx.settingsBillingReturnStateV756().processing, false);
});

test('settingsBillingReturnStripV756 removes billing= but keeps sibling hash params', () => {
  const ctx = makeSandbox('#/settings?tab=billing&billing=processing');
  ctx.settingsBillingReturnStripV756();
  assert.equal(ctx.location.hash.includes('billing=processing'), false);
  assert.match(ctx.location.hash, /tab=billing/);
});

test('settingsBillingReturnSignatureV756 changes when status, provider id or capacity change', () => {
  const ctx = makeSandbox('#/settings?billing=processing');
  const before = ctx.settingsBillingReturnSignatureV756({ status: 'trialing', provider: {} }, 1000);
  const afterStatus = ctx.settingsBillingReturnSignatureV756({ status: 'active', provider: {} }, 1000);
  const afterProvider = ctx.settingsBillingReturnSignatureV756({ status: 'trialing', provider: { subscription_id: 'sub_1' } }, 1000);
  const afterCapacity = ctx.settingsBillingReturnSignatureV756({ status: 'trialing', provider: {} }, 5000);
  assert.notEqual(before, afterStatus);
  assert.notEqual(before, afterProvider);
  assert.notEqual(before, afterCapacity);
  assert.equal(before, ctx.settingsBillingReturnSignatureV756({ status: 'trialing', provider: {} }, 1000));
});

/* The actual poll loop: stub fetchState to return the OLD state twice, then a changed state on
   the 3rd call. Real setTimeout with a tiny interval drives the loop through the ticks — no
   fake-timer library exists in this repo's test deps, so this mirrors how other business-ui
   tests here drive async app.js logic with real (short) timers. */
test('poller calls onChange exactly once, after the 3rd tick, and stops (no further fetches)', async () => {
  const ctx = makeSandbox('#/settings?billing=processing');
  const oldState = { status: 'trialing', provider: {} };
  const newState = { status: 'active', provider: { subscription_id: 'sub_9' } };
  const baseline = ctx.settingsBillingReturnSignatureV756(oldState, 1000);

  let fetchCalls = 0;
  let onChangeCalls = 0;
  let onTimeoutCalls = 0;
  let lastPayload = null;

  await new Promise((resolve, reject) => {
    ctx.settingsBillingReturnPollV756({
      baseline,
      intervalMs: 5,
      maxAttempts: 45,
      fetchState: async () => {
        fetchCalls += 1;
        const state = fetchCalls < 3 ? oldState : newState;
        const capacity = fetchCalls < 3 ? 1000 : 8000;
        return { signature: ctx.settingsBillingReturnSignatureV756(state, capacity), payload: state };
      },
      onChange: (payload) => {
        onChangeCalls += 1;
        lastPayload = payload;
        // give any stray extra tick a moment to prove it does NOT happen, then assert.
        setTimeout(() => {
          try {
            assert.equal(fetchCalls, 3, 'must stop fetching right after the 3rd (changed) tick');
            assert.equal(onChangeCalls, 1, 'onChange must fire exactly once');
            assert.equal(onTimeoutCalls, 0, 'onTimeout must never fire on a success path');
            assert.equal(lastPayload.status, 'active');
            resolve();
          } catch (e) { reject(e); }
        }, 30);
      },
      onTimeout: () => { onTimeoutCalls += 1; }
    });
  });
});

test('poller calls onTimeout (not onChange) when the state never changes', async () => {
  const ctx = makeSandbox('#/settings?billing=processing');
  const oldState = { status: 'trialing', provider: {} };
  const baseline = ctx.settingsBillingReturnSignatureV756(oldState, 1000);
  let fetchCalls = 0, onChangeCalls = 0, onTimeoutCalls = 0;

  await new Promise((resolve, reject) => {
    ctx.settingsBillingReturnPollV756({
      baseline,
      intervalMs: 2,
      maxAttempts: 3,
      fetchState: async () => {
        fetchCalls += 1;
        return { signature: ctx.settingsBillingReturnSignatureV756(oldState, 1000), payload: oldState };
      },
      onChange: () => { onChangeCalls += 1; },
      onTimeout: () => {
        onTimeoutCalls += 1;
        try {
          assert.equal(fetchCalls, 3, 'must attempt exactly maxAttempts times before timing out');
          assert.equal(onChangeCalls, 0);
          assert.equal(onTimeoutCalls, 1);
          resolve();
        } catch (e) { reject(e); }
      }
    });
  });
});

test('poller respects isCancelled and performs no further fetches once cancelled', async () => {
  const ctx = makeSandbox('#/settings?billing=processing');
  const oldState = { status: 'trialing', provider: {} };
  const baseline = ctx.settingsBillingReturnSignatureV756(oldState, 1000);
  let fetchCalls = 0;
  let cancelled = false;

  ctx.settingsBillingReturnPollV756({
    baseline,
    intervalMs: 5,
    maxAttempts: 45,
    isCancelled: () => cancelled,
    fetchState: async () => {
      fetchCalls += 1;
      return { signature: ctx.settingsBillingReturnSignatureV756(oldState, 1000), payload: oldState };
    },
    onChange: () => { throw new Error('must not fire after cancel'); },
    onTimeout: () => { throw new Error('must not fire after cancel'); }
  });

  // let it run once, then cancel — mirrors navigating away from Settings (wrap.isConnected
  // becomes false in the real loadBillingConfig() call site).
  await new Promise((resolve) => setTimeout(resolve, 8));
  cancelled = true;
  const seenAfterCancel = fetchCalls;
  await new Promise((resolve) => setTimeout(resolve, 40));
  assert.equal(fetchCalls, seenAfterCancel, 'no fetch should happen after isCancelled() flips true');
});

/* Wiring check: loadBillingConfig must be the only caller, must reuse get_business_billing_v125
   (never a new RPC), and must gate capacity on the freshly-fetched terms rather than a hardcoded
   lowest tier — asserted structurally (not a broad grep) against the call site itself. */
test('loadBillingConfig wires the poller onto its own get_business_billing_v125 read, gated on billing=processing', () => {
  const fnStart = app.indexOf('async function loadBillingConfig(){');
  const fnEnd = app.indexOf('\n/* ---------- customer sign-up QR ---------- */');
  assert.ok(fnStart > -1 && fnEnd > fnStart, 'loadBillingConfig anchors must exist');
  const fn = app.slice(fnStart, fnEnd);
  assert.match(fn, /billingReturnStateV756\.processing&&!settingsBillingPollActiveV756/);
  assert.match(fn, /settingsBillingReturnPollV756\(/);
  // reuses the same RPC inside the poll's fetchState — no new/second billing RPC introduced.
  const fetchStateBlock = fn.slice(fn.indexOf('fetchState:async'), fn.indexOf('onChange:'));
  assert.match(fetchStateBlock, /sb\.rpc\('get_business_billing_v125',\{p_business:S\.biz\.id\}\)/);
  assert.doesNotMatch(fn, /sb\.rpc\('get_self_serve_checkout_v130'/, 'must not invent a new RPC for this poll');
  // capacity default comes from the freshly fetched terms, not a hardcoded lowest tier.
  assert.match(fn, /currentCapacity=Math\.max\(minimumCapacity,Number\(b\.terms\?\.customer_capacity\|\|0\)\)/);
  // success path strips the query the same way the rest of the file rewrites the hash.
  assert.match(fn, /onChange:\(\)=>\{[\s\S]{0,80}settingsBillingReturnStripV756\(\)/);
});
