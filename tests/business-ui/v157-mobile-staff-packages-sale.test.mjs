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
const packages = section('async function packagesPage(options)', '/* ---------- branches (owner-only) ----------');
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
  /* V257 kept package SALES collapsed behind a <details> drawer. V373 moves them into the Add
     item sheet's "Sell package" tab, which protects the same thing more strongly: they are not
     on the main screen at all, and the sheet cannot be collapsed by a redraw. */
  assert.match(recordSale, /\{key:'sellpackage',label:'Sell package'\}/);
  assert.match(recordSale, /sellpackage:canPkg&&\(catalog\.packages\|\|\[\]\)\.length>0/);
  /* V211: this used to assert `const ownedPackages=''` — it pinned the STUB that emptied the
     owned-package list. That stub is why an owner could not spend a session a customer had
     already paid for, and it stood in direct contradiction to the v102 test, which requires the
     till to show owned packages and consume sessions. The owner reported the symptom directly:
     "i still dont see the package here in record sale - not able to use sessions".
     The compactness this test protects is real and is still asserted above: package SALES stay
     off the main screen (V373: inside the Add item sheet's own tab). Spending an existing session
     is the common act at a counter and is not hidden. */
  assert.match(recordSale, /const ownedPackages=ownedPkgs\.length/);
  assert.match(recordSale, /Use an existing customer package/);
});

test('V157 reorganises Packages into My packages and Customer packages without a sale form', () => {
  assert.match(packages, /Manage prepaid sessions\. Sell packages from Record sale\./);
  /* nestly_v584 (owner photo 12: the Customer packages tab ringed with an arrow into the Serve &
     sell rail — "put under new modules under serve & sell"). The two halves V157 separated are
     still separate; they are now two destinations rather than two tabs, because they are two
     different jobs — one is setup, the other is a counter action. One builder still renders both,
     so the split cannot drift. */
  assert.match(packages, /const packagesViewV584=options&&options\.view==='customers'\?'customers':'plans';/);
  assert.match(packages, /\$\{packagesViewV584==='plans'\?`<section class="package-panel-v157" id="pkgPanelPlans"/);
  assert.match(packages, /\$\{packagesViewV584==='customers'\?`<section class="package-panel-v157" id="pkgPanelCustomers"/);
  assert.doesNotMatch(packages, /data-package-tab=/);
  assert.match(app, /custpackages:\(\)=>packagesPage\(\{view:'customers'\}\)/);
  assert.match(packages, /id="kCustomerSearch" type="search" placeholder="Name or phone"/);
  /* nestly_v612 (owner: "i need subtab for (all/active/used up) within the module"). The search
     predicate is named now, because the status tabs count against it too — the counts on the tabs
     must describe the rows the SEARCH already narrowed, not the whole table, or "Active (1)" would
     contradict an empty list. */
  assert.match(packages, /const matchesQueryV612=k=>!query\|\|\[k\.client_name,k\.client_phone,k\.plan_name\]\.some/);
  assert.match(packages, /const searched=packageRows\.filter\(matchesQueryV612\)/);
  assert.match(packages, /packageStatusV612==='active'\?Number\(k\.remaining\)>0&&k\.status!=='expired':Number\(k\.remaining\)===0/,
    'used up is no sessions left; active is sessions left AND a window still open');
  assert.doesNotMatch(packages, /id="ksell"/);
  assert.doesNotMatch(packages, /fetchAllRowsResult\(\(\)=>sb\.from\('clients'\)/);
});

test('V157 preserves package-session audit correction wording', () => {
  assert.match(packages, /Use Undo session use only when a package session was deducted by mistake/);
  assert.match(packages, />Undo session use<\/button>/);
  assert.match(packages, /Session added back · no refund/);
  assert.doesNotMatch(packages, />Restore session<\/button>/);
});
