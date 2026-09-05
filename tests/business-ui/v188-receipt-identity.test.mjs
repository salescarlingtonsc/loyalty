import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

test('a receipt identifies the company that was actually paid', () => {
  // businesses.legal_name and registration_number already existed but nothing ever asked for
  // them, so every receipt in production printed only a workspace nickname.
  // nestly_v788: the fields now live on the BRANCH (branches may be different ACRA entities
  // under one boss), and both till receipts draw them from one function.
  assert.match(app, /id="\$\{prefix\}Legal"/);
  assert.match(app, /id="\$\{prefix\}Uen"/);
  assert.match(app, /receiptIdentityHtmlV788\(d\.branchIdentityV788,d\.businessName\|\|S\.biz\.name,d\.branchName\)/);
  /* nestly_v654 (owner photo 6: "in a standard receipt must indicate pte ltd (company name) and
     its UEN ... even after i input it"). Two things were wrong and only one of them was here.
     The wording: the form asks for a "Business registration number / UEN" and the receipt said
     "Reg. no.", which is not the term a Singapore customer looks for. The real defect was in the
     database — the partial unique index over registration_number evaluates
     app.normalized_business_identity_v79, which was granted to postgres alone, so an owner typing
     a UEN got 42501 and NOTHING in the form saved. Fixed by nestly_v654's grant. */
  assert.match(app, /UEN \$\{esc\(String\(b\.registration_number\)\)\}/);
  assert.doesNotMatch(app, /Reg\. no\./);
});

test('v654 the fallback receipt names the company too', () => {
  /* drawStep3's non-cart receipt — drawn when a sale finishes without a cart payload — carried no
     company identity at all, so one counter could hand out two receipts and only one of them said
     who had been paid. */
  const fallback = app.slice(app.indexOf('function drawStep3()'), app.indexOf('function drawCartReceipt()'));
  assert.match(fallback, /receiptIdentityHtmlV788\(accessibleTillBranches\.find\(branch=>branch\.id===tillBranchId\)\|\|null,S\.biz\.name,''\)/);
  const identity = app.slice(app.indexOf('function receiptIdentityHtmlV788('), app.indexOf('function gstRowLabelV788('));
  assert.match(identity, /Not GST registered/);
});

test('the trading name is kept when it differs from the registered name', () => {
  const identity = app.slice(app.indexOf('function receiptIdentityHtmlV788('), app.indexOf('function gstRowLabelV788('));
  assert.match(identity, /registered&&trading&&registered!==trading\?`<p class="muted small" data-merchant-content style="margin:0">trading as \$\{esc\(trading\)\}<\/p>`/);
  // and a non-GST branch says so, rather than leaving the customer to wonder
  assert.match(identity, /Not GST registered/);
});

test('the customer sees their points balance as its own line', () => {
  /* nestly_v430 made the line unit-aware; nestly_v438 split the copy: points keeps
     'balance after this visit', but stamps says 'Total stamps earned to date' — the RPC's
     points_total is the LIFETIME pot, which stops matching the card the moment a cycle
     closes ("balance 10" beside a fresh 0/6 card read as a bug on the till). */
  assert.match(app, /Total stamps earned to date: <b>\$\{d\.pointsTotal\}<\/b>/);
  assert.match(app, /Points balance after this visit: <b>\$\{d\.pointsTotal\}<\/b>/);
  assert.ok(!app.includes('· now ${d.pointsTotal} points total'),
    'the balance should not be buried in a tail clause');
});
