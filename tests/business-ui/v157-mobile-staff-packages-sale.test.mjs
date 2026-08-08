import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const app = (readFileSync(new URL('../../app/index.html',import.meta.url),'utf8')+'\n'+readFileSync(new URL('../../app/app.js',import.meta.url),'utf8'));

function section(start, end) {
  const from = app.indexOf(start);
  assert.ok(from >= 0, `missing section start: ${start}`);
  const to = app.indexOf(end, from + start.length);
  assert.ok(to > from, `missing section end: ${end}`);
  return app.slice(from, to);
}

const recordSale = section('function drawCartComposer(){', 'async function servicesPage()');
const services = section('async function servicesPage()', 'async function referralsPage()');
const packages = section('async function packagesPage()', '/* ---------- branches (owner-only) ----------');
/* V243: end marker follows the CSV-import block out of settingsPage. Same region, same intent. */
const settings = section('async function settingsPage()', '  /* ---------- billing (read-only) ---------- */');

test('V157 hides next-phase customer payment controls from owner settings', () => {
  assert.doesNotMatch(settings, /data-settab="payments"/);
  assert.doesNotMatch(settings, /id="setpanel-payments"/);
  assert.doesNotMatch(settings, /loadMerchantPaymentsV142\(\)/);
});

test('V157 hides inventory deduction setup while preserving services catalogue management', () => {
  assert.match(services, /const showServiceProductDeductionV157=false/);
  assert.match(services, /if\(showServiceProductDeductionV157\)\{/);
  assert.match(services, /M\(\)\.insertAdjacentHTML\('beforeend',`<div class="card" style="margin-top:16px"><b>Products used per service<\/b>/);
});

test('V157 keeps Record sale focused by collapsing package sales and showing item quantities', () => {
  assert.match(recordSale, /const selectedCatalogQty=\(type,id\)=>saleLines\.reduce/);
  assert.match(recordSale, /String\(line\.ref\)===String\(id\)/);
  assert.doesNotMatch(recordSale, /line\.ref_id/);
  assert.match(recordSale, /class="choice-button \$\{image\?'has-image':''\} \$\{qty\?'is-selected':''\}"/);
  assert.match(recordSale, /class="till-choice-image"/);
  assert.match(recordSale, /class="till-choice-qty"/);
  assert.match(recordSale, /aria-label="\$\{qty\} selected"/);
  assert.match(recordSale, /<details class="till-sale-package-options"><summary>Sell package<\/summary>/);
  /* V211: this used to assert `const ownedPackages=''` — it pinned the STUB that emptied the
     owned-package list. That stub is why an owner could not spend a session a customer had
     already paid for, and it stood in direct contradiction to the v102 test, which requires the
     till to show owned packages and consume sessions. The owner reported the symptom directly:
     "i still dont see the package here in record sale - not able to use sessions".
     The compactness this test protects is real and is still asserted above: package SALES stay
     collapsed behind the <details> summary. Spending an existing session is the common act at a
     counter and is not hidden. */
  assert.match(recordSale, /const ownedPackages=ownedPkgs\.length/);
  assert.match(recordSale, /Use an existing customer package/);
});

test('V157 reorganises Packages into My packages and Customer packages without a sale form', () => {
  assert.match(packages, /Manage prepaid sessions\. Sell packages from Record sale\./);
  assert.match(packages, /data-package-tab="plans">My packages/);
  assert.match(packages, /data-package-tab="customers">Customer packages/);
  assert.match(packages, /id="kCustomerSearch" type="search" placeholder="Name or phone"/);
  assert.match(packages, /filter\(k=>!query\|\|\[k\.client_name,k\.client_phone,k\.plan_name\]\.some/);
  assert.doesNotMatch(packages, /id="ksell"/);
  assert.doesNotMatch(packages, /fetchAllRowsResult\(\(\)=>sb\.from\('clients'\)/);
});

test('V157 preserves package-session audit correction wording', () => {
  assert.match(packages, /Use Undo session use only when a package session was deducted by mistake/);
  assert.match(packages, />Undo session use<\/button>/);
  assert.match(packages, /Session added back · no refund/);
  assert.doesNotMatch(packages, />Restore session<\/button>/);
});
