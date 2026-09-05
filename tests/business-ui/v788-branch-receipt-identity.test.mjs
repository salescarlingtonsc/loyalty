import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');
const migration = readFileSync(new URL('../../db/migrations/20261006_nestly_v788_branch_receipt_identity_gst.sql', import.meta.url), 'utf8');

/* nestly_v788 (owner ruling 2026-09-06): "shift the company name & UEN number and (GST or not) to
   individual branches, because branches may be different ACRA operating under the same boss.
   When a user from a different branch opens Record sale and makes a transaction, the company
   name and UEN follow, including GST or no GST." Clarified: real GST at checkout, all listed
   prices are before GST, the business-level fields move entirely. */

function slice(from, to) {
  const a = app.indexOf(from), b = app.indexOf(to, a);
  assert.ok(a > -1 && b > a, `${from} … ${to}`);
  return app.slice(a, b);
}
// one till function's body: from its declaration to the next inner function declaration
function tillFn(name) {
  const a = app.indexOf(`function ${name}(`);
  assert.ok(a > -1, name);
  const b = app.indexOf('\n  function ', a + 1);
  return app.slice(a, b > a ? b : a + 8000);
}

// The two helpers are executed, not grepped: a receipt line that never renders proves nothing.
function loadHelpers() {
  const src = slice('function receiptIdentityHtmlV788(', 'function branchIdentityFieldsHtmlV788(');
  const ctx = {esc: s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))};
  vm.runInNewContext(src + '\nthis.receiptIdentityHtmlV788=receiptIdentityHtmlV788;this.gstRowLabelV788=gstRowLabelV788;', ctx);
  return ctx;
}

test('the receipt prints the BRANCH the sale was rung up at, not the business', () => {
  const {receiptIdentityHtmlV788} = loadHelpers();
  const branchA = {legal_name: 'ALPHA BEAUTY PTE. LTD.', registration_number: '202611111A',
    gst_registered: true, gst_registration_number: 'M9-0001111-1', gst_rate_bps: 900};
  const branchB = {legal_name: 'BETA BEAUTY PTE. LTD.', registration_number: '202622222B', gst_registered: false};
  const a = receiptIdentityHtmlV788(branchA, 'Glow Studio', 'Tampines');
  const b = receiptIdentityHtmlV788(branchB, 'Glow Studio', 'Jurong');
  assert.match(a, /<b>ALPHA BEAUTY PTE\. LTD\.<\/b> · Tampines/);
  assert.match(a, /trading as Glow Studio/);
  assert.match(a, /UEN 202611111A/);
  assert.match(a, /GST Reg\. No\. M9-0001111-1/);
  assert.doesNotMatch(a, /Not GST registered/);
  assert.match(b, /<b>BETA BEAUTY PTE\. LTD\.<\/b> · Jurong/);
  assert.match(b, /UEN 202622222B/);
  assert.match(b, /Not GST registered/);
  assert.doesNotMatch(b, /GST Reg\. No\./);
  // one business, two ACRA entities: the two receipts never mention each other's UEN
  assert.doesNotMatch(a, /202622222B/);
  assert.doesNotMatch(b, /202611111A/);
});

test('a branch with no registered name prints the workspace name and no UEN line', () => {
  const {receiptIdentityHtmlV788} = loadHelpers();
  const html = receiptIdentityHtmlV788({}, 'Glow Studio', '');
  assert.match(html, /<b>Glow Studio<\/b>/);
  assert.doesNotMatch(html, /trading as/);
  assert.doesNotMatch(html, /UEN/);
  assert.match(html, /Not GST registered/);
  // no branch at all (the fallback receipt before a branch is chosen) still says who was paid
  assert.match(receiptIdentityHtmlV788(null, 'Glow Studio', ''), /<b>Glow Studio<\/b>/);
});

test('the GST row names the rate that was added on top, and is never "incl."', () => {
  const {gstRowLabelV788} = loadHelpers();
  assert.equal(gstRowLabelV788({gst_rate_bps: 900}), 'GST 9%');
  assert.equal(gstRowLabelV788({gst_rate_bps: 750}), 'GST 7.5%');
  assert.equal(gstRowLabelV788(null), 'GST');
  // the whole till (composer through both receipts) — the only "incl. GST" left is a dictionary key
  const till = slice('async function tillPage()', 'function receiptIdentityHtmlV788(');
  assert.doesNotMatch(till, /incl\. GST/);
  const cart = slice('const gstLine=r.gst_cents>0', 'const totalCls=');
  assert.match(cart, /gstRowLabelV788\(/);
  assert.match(tillFn('drawCartReceipt'), /gstRowLabelV788\(d\.branchIdentityV788\)/);
});

test('the till reads the registration with the branch it already chooses, and hands it to the receipt', () => {
  assert.match(app, /sb\.from\('branches'\)\.select\('id,name,code,is_default,legal_name,registration_number,gst_registered,gst_registration_number,gst_rate_bps'\)\.eq\('business_id',S\.biz\.id\)\.eq\('active',true\)/);
  assert.match(app, /branchIdentityV788:accessibleTillBranches\.find\(branch=>branch\.id===tillBranchId\)\|\|null,/);
  // neither receipt reads the business row for identity any more
  const receipts = tillFn('drawStep3') + tillFn('drawCartReceipt');
  assert.match(receipts, /receiptIdentityHtmlV788\(/);
  assert.doesNotMatch(receipts, /S\.biz\.legal_name/);
  assert.doesNotMatch(receipts, /S\.biz\.registration_number/);
  assert.doesNotMatch(receipts, /S\.biz\.gst_registered/);
});

test('the fields left Business Profile and live on the branch — the Branches form and the profile branch card', () => {
  const brand = slice('function workspaceBrandPanelHtmlV259()', 'function wireWorkspaceBrandV259()');
  assert.doesNotMatch(brand, /id="blegal"|id="buen"/);
  assert.match(brand, /set per branch in <a href="#\/branches">Branches<\/a>/);
  const write = slice("sb.from('businesses').update({name:$('bn').value.trim(),", ".eq('id',S.biz.id);");
  assert.doesNotMatch(write, /legal_name|registration_number/, 'the business save must not blank the firm application identity');
  // the branch form
  const form = slice('function openForm(b){', "$('brSave').onclick=");
  assert.match(form, /branchIdentityFieldsHtmlV788\('br',b\)/);
  const saveBranch = slice("$('brSave').onclick=", 'async function load(){');
  assert.match(saveBranch, /const identityV788=readBranchIdentityFieldsV788\('br'\);/);
  assert.match(saveBranch, /address:\$\('brAddr'\)\.value\.trim\(\)\|\|null,\.\.\.identityV788,/);
  assert.match(saveBranch, /saveBranchFieldsV325\(newBranchIdV788,identityV788\)/, 'a new branch gets its identity after the add RPC returns its id');
  // the profile branch card
  const card = slice('async function loadBranchContactCardV325()', 'host.querySelectorAll');
  assert.match(card, /branchIdentityFieldsHtmlV788\('ciBrV788-'\+esc\(b\.id\),b\)/);
  assert.match(app, /saveBranchFieldsV325\(id,\{phone,address,\.\.\.readBranchIdentityFieldsV788\('ciBrV788-'\+id\)\}\)/);
  // the reader stores blank as NULL and the GST number survives the switch being off
  const reader = slice('function readBranchIdentityFieldsV788(prefix){', 'async function saveBranchFieldsV325');
  assert.match(reader, /legal_name:\(\$\(prefix\+'Legal'\)\?\.value\|\|''\)\.trim\(\)\|\|null/);
  assert.match(reader, /gst_registered:!!\$\(prefix\+'Gst'\)\?\.checked/);
  assert.match(reader, /gst_registration_number:\(\$\(prefix\+'GstNo'\)\?\.value\|\|''\)\.trim\(\)\|\|null/);
});

test('the kernel prices GST from the branch and adds it on top of the discounted net', () => {
  assert.match(migration, /select b\.gst_registered, b\.gst_rate_bps into v_gst_reg, v_gst_bps\n\s+from public\.branches b where b\.id = p_branch and b\.business_id = p_business;/);
  assert.match(migration, /v_gst := round\(v_net::numeric \* v_gst_bps \/ 10000\)::int;/);
  assert.match(migration, /v_total := v_net \+ v_gst;/);
  assert.doesNotMatch(migration, /from public\.businesses where id = p_business;\n\s+if coalesce\(v_gst_reg/, 'the business row must not be the GST authority');
  assert.doesNotMatch(migration, /\(10000 \+ v_gst_bps\)/, 'the inclusive carve-out is gone');
  assert.match(migration, /check \(total_cents = subtotal_cents - discount_total_cents \+ gst_cents\)/);
  assert.match(migration, /add column if not exists gst_rate_bps integer not null default 900/);
  // history keeps its name: every existing branch inherits the business identity it printed
  assert.match(migration, /set legal_name = coalesce\(br\.legal_name, bz\.legal_name\),\n\s+registration_number = coalesce\(br\.registration_number, bz\.registration_number\)/);
});
