/* V286 — Record sale (tillPage): the catalogue that outlived its branch, and the PayNow attempt
   that Back threw away.

   Two money defects, both invisible to a test that only checks a function exists:

   (1) loadCatalog was the ONE async path on this surface with no epoch guard. Switching branch
       mid-load cleared `catalog`, but the redraw's loadCatalog() bounced off `catalogLoading`, so
       the in-flight response published the OLD branch's items (and the previous customer's
       entitlements) under the NEW branch. Those items are ones the server deliberately withheld,
       so evaluate_checkout rejected them and the till looked broken with no way to recover.

   (2) Back during a live PayNow QR killed the poll and the on-screen attempt but left the stored
       sessionStorage request behind — the customer paid a sale the server fulfilled, the cashier
       saw nothing and took the money again, and the surviving slot could later resume that
       customer's QR inside an unrelated sale. nestly_v755: PayNow QR (Stripe Connect) itself is
       now retired — Razorpay SG has no equivalent — so this defect class is moot; the tests below
       pin its absence instead of deleting the section outright.

   Both are ORDER/GUARD properties, so they are pinned in source. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const root = resolve(import.meta.dirname, '../..');
const app = readFileSync(resolve(root, 'app/app.js'), 'utf8');

function section(start, end) {
  const from = app.indexOf(start);
  assert.notEqual(from, -1, `missing start marker: ${start}`);
  const to = app.indexOf(end, from + start.length);
  assert.notEqual(to, -1, `missing end marker: ${end}`);
  return app.slice(from, to);
}

const till = section('async function tillPage', 'async function salesPage(){');
const loadCatalog = section('  async function loadCatalog(){', '  function drawCartComposer(){');

/* ------------------------------------------------------------------ (1) catalogue epoch */

test('V286: loadCatalog captures the branch/customer it fetched for', () => {
  assert.match(loadCatalog, /const forBranchV286=tillBranchId, forClientV286=cust\?cust\.client_id:null, forWalkinV286=walkin;/);
  // Captured BEFORE the fetch, not after — otherwise it reads the already-changed value.
  assert.ok(loadCatalog.indexOf('forBranchV286=tillBranchId') < loadCatalog.indexOf('Promise.all(['),
    'the epoch must be captured before the fetch is issued');
});

test('V286: a stale catalogue response is discarded instead of published', () => {
  const guard = /if\(tillBranchId!==forBranchV286\|\|\(cust\?cust\.client_id:null\)!==forClientV286\|\|walkin!==forWalkinV286\)\{draw\(\);return;\}/;
  assert.match(loadCatalog, guard);
  // The bail must sit AFTER catalogLoading is released (so the redraw can re-issue the load for
  // the branch actually on screen) and BEFORE anything assigns the catalogue.
  const bail = loadCatalog.search(guard);
  assert.ok(loadCatalog.indexOf('catalogLoading=false;') < bail, 'catalogLoading must be released before bailing');
  assert.ok(bail < loadCatalog.indexOf('catalog={'), 'the stale response must never reach catalog=');
  assert.ok(bail < loadCatalog.indexOf('catalogueSelectionEnabled=false'),
    'a stale response must not flip the checkout mode either');
});

test('V286: the composer re-issues the load once the stale one bails', () => {
  // This is what makes the bail self-healing: catalog is still null, so the next draw refetches.
  assert.match(till, /if\(catalog===null&&!catalogError\)loadCatalog\(\);/);
});

/* ------------------------------------------------------------------ (2) PayNow, retired (v755) */

/* nestly_v755: the whole V142 PayNow-QR-via-Stripe-Connect payment attempt (the reason Back used
   to refuse and a deliberate abandon used to clear a stored provider request) is removed —
   Razorpay SG has no Stripe Connect equivalent. See RAZORPAY_SWAP_SPEC.md. These two tests used
   to pin that removed behaviour; they now pin its absence instead of being deleted outright, so a
   reintroduction of a provider-backed till payment attempt is caught here too. */

test('v755: Back no longer guards on a (removed) PayNow attempt', () => {
  const back = section('  function backToPhoneStep(){', '  function draw(){');
  assert.doesNotMatch(back, /paynowAttempt/);
  assert.doesNotMatch(till, /id="tPaynowReopen"/);
  assert.doesNotMatch(till, /renderPaynowDialogV142/);
});

test('v755: a deliberate abandon no longer touches a (removed) stored PayNow request', () => {
  const clear = section('  function clearCheckoutState({abandon=false}={}){', '  function resetToStart(){');
  assert.doesNotMatch(clear, /clearPaynowRequestV142/);
  assert.doesNotMatch(till, /resumePaynowPaymentV142/);
  assert.doesNotMatch(till, /readPaynowRequestV142/);
});

test('V286: every checkout-abandoning call site passes abandon:true', () => {
  for (const marker of [
    // Back to the keypad, full reset, walk-in switch, branch change, finalise.
    /function backToPhoneStep\(\)\{[\s\S]*?clearCheckoutState\(\{abandon:true\}\)/,
    /function resetToStart\(\)\{\n\s*clearCheckoutState\(\{abandon:true\}\)/,
    /if\(!canOfferWalkin\(\)\)return;\n\s*clearCheckoutState\(\{abandon:true\}\)/,
    /cart=\[\];catalog=null;catalogError=null;clearCheckoutState\(\{abandon:true\}\)/,
    /checkoutError=null;clearCheckoutState\(\{abandon:true\}\);step=3/,
  ]) assert.match(till, marker);
});

/* ------------------------------------------------------------------ regressions this must not cause */

test('V286: the idempotency discipline is untouched', () => {
  // One stable finalise key, cleared with the checkout state. (v755: the second, PayNow-specific
  // request/fingerprint idempotency scheme this test used to also pin is retired along with that
  // payment rail — see the "PayNow, retired" tests above.)
  assert.match(till, /clearWriteAttempt\(FINALISE_SLOT\);/);
  assert.match(till, /p_idempotency_key:finaliseKey/);
});

test('V286: the itemized composer still offers the staff-attribution picker (V287)', () => {
  // The commission snapshot follows p_staff; the default catalogue path must let the counter
  // credit the teammate who did the work, not whoever is signed in.
  const composer = section('  function drawCartComposer(){', '  async function applySvTender(){');
  assert.match(composer, /const staffPickerV287=tillAttributableStaff\.length>1/);
  assert.match(till, /\$\{staffPickerV287\}/);
  assert.match(till, /p_staff:tillSaleStaffId\|\|tillStaffId,p_method:tender,p_idempotency_key:finaliseKey/);
});
