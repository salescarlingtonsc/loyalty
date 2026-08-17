/* V257 — four owner-reported defects in the Record sale (till) cart and confirm screen.
   Each test pins the MECHANISM that was wrong, not the presence of a control. */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const app = readFileSync(new URL('../../app/index.html', import.meta.url), 'utf8')
  + '\n' + readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');
const migration = readFileSync(
  new URL('../../db/migrations/20260809_nestly_v257_bundle_finalise_rehash.sql', import.meta.url), 'utf8');

function section(start, end) {
  const from = app.indexOf(start);
  assert.ok(from >= 0, `missing section start: ${start}`);
  const to = app.indexOf(end, from + start.length);
  assert.ok(to > from, `missing section end: ${end}`);
  return app.slice(from, to);
}

const till = section('async function tillPage(){', 'async function salesPage(){');
const composer = section('function drawCartComposer(){', 'async function applySvTender(){');
const receipt = section('function drawCartReceipt(){', '/* A phone handed in from the global app-bar search');

test('BUG 1 — a bundle tile carries the same quantity badge a service tile does, counting bundle lines', () => {
  // The badge markup is REUSED, not reinvented: same class, same aria shape as the service tile.
  assert.match(composer, /const qty=selectedCatalogQty\('bundle',bundle\.id\);/);
  assert.match(composer, /data-add-bundle="\$\{esc\(bundle\.id\)\}"[\s\S]{0,400}?class="till-choice-qty" data-workspace-i18n aria-label="\$\{qty\} selected"/);
  assert.match(composer, /class="choice-button \$\{qty\?'is-selected':''\}" data-add-bundle/);
  // It must count BUNDLE lines. selectedCatalogQty reads cartSaleLines by line.type, and a bundle
  // is its own line type — the services it expands into exist only in the server's evaluation.
  assert.match(till, /const selectedCatalogQty=\(type,id\)=>saleLines\.reduce\(\(sum,line\)=>sum\+\(line\.type===type/);
  assert.match(till, /cart\.push\(\{lineId:crypto\.randomUUID\(\),type:'bundle',ref:bundle\.id,/);
});

test('BUG 2 — selling a package shows a count, survives the redraw, and says so out loud', () => {
  // (a) a countable indicator. Package lines are EXTRA lines, one line per sale (each carries its
  //     own idempotency key), so the count is a line count and must not read line.qty.
  assert.match(till, /function selectedPlanCountV257\(type,id\)\{/);
  assert.match(till, /return extraLines\(\)\.reduce\(\(sum,line\)=>sum\+\(\(line\.type===type&&String\(line\.ref\)===String\(id\)\)\?1:0\),0\);/);
  assert.match(composer, /const qty=selectedPlanCountV257\('package',p\.id\);/);
  assert.match(composer, /data-plan="package"[\s\S]{0,320}?class="till-choice-qty" data-workspace-i18n aria-label="\$\{qty\} selected"/);
  /* (b) the list of plans no longer collapses on the redraw that adding a line triggers.
     V373 replaced the <details> drawer with the Add item sheet, which keeps the same guarantee
     structurally rather than by remembering a flag: the sheet is a dialog mounted on
     document.body, so the redraw that follows every add cannot close it, and the tab it is on
     is state that survives the repaint. */
  assert.match(till, /let tillAddSheetV373=null;/);
  assert.match(composer, /document\.body\.insertAdjacentHTML\('beforeend',`<div class="modal till-add-sheet-v373" id="tillAddSheetV373"/);
  assert.match(composer, /\{key:'sellpackage',label:'Sell package'\}/);
  // Adding a line redraws the route only; the sheet is repainted in place, never re-opened.
  assert.match(composer, /if\(tillAddSheetV373\)paintTillAddSheetV373\(\);/);
  assert.match(composer, /tillAddSheetV373\.tab=button\.dataset\.tillTabV373;/);
  // (c) visible confirmation, not only a screen-reader announcement.
  // Reuses the reviewed v97 named template rather than an interpolated literal, which the
  // workspace-localization acceptance suite forbids for runtime copy.
  assert.match(till, /toast\(workspaceTemplateTextV97\('itemAdded',\{item:plan\.name\}\)\);/);
  // Errors are still surfaced, never swallowed: a failed extra sets _status and raises the banner.
  assert.match(till, /if\(res\.error\)\{anyExtraFailed=true;l\._status='failed';/);
  assert.match(till, /checkoutError='The sale is safe\. Some items could not be completed\./);
});

test('BUG 3 — the split stays (two sale kinds), the confirm screen states ONE amount to collect', () => {
  // The two write paths are NOT merged: the cart finalises through record_cart_sale and a package
  // is still its own sell_package_v102 row of kind='package' with its own policy.
  assert.match(till, /sb\.rpc\('record_cart_sale'/);
  assert.match(till, /sb\.rpc\('sell_package_v102'/);
  assert.match(till, /function extrasTotalCents\(\)\{return extraLines\(\)\.reduce/);
  // What changed is the arithmetic the owner is shown: one combined figure, plain-words reason.
  assert.match(composer, /const collectBaseV257=\(hasSale&&evalResult&&evalState!=='error'\)/);
  assert.match(composer, /<span>Total to collect<\/span><span>\$\{money\(collectBaseV257\+extrasTotalCents\(\)\)\}<\/span>/);
  assert.match(composer, /the customer pays one amount/);
  assert.doesNotMatch(composer, /Also processing \(charged separately\)/);
  // The single primary button names the whole amount it will collect, not just the kernel total.
  assert.match(till, /const dueV257=\(svTender\?svTender\.remaining_due_cents:evalResult\.total_cents\)\+extrasTotalCents\(\);/);
  // V373 renamed the button to the owner's own words; the FIGURE it names is unchanged.
  assert.match(till, / Record sale · \$\{money\(dueV257\)\}/);
  // The receipt totals both records afterwards, excluding anything that failed.
  assert.match(receipt, /d\.extras\.filter\(x=>x\.status!=='failed'\)\.reduce/);
  assert.match(receipt, /<span>Total collected<\/span>/);
});

test('BUG 4 — the stale re-price happens ONCE; a second stale stops instead of re-offering the same confirm', () => {
  // Client: the recovery counts its own re-evaluations, so the identical screen can never be
  // redrawn forever behind a Confirm button that appears to do nothing.
  assert.match(till, /let staleReevaluationsV257=0;/);
  assert.match(till, /staleReevaluationsV257\+=1;/);
  assert.match(till, /if\(staleReevaluationsV257>1\)\{[\s\S]{0,400}?evalState='error';evalResult=null;clearExpiry\(\);draw\(\);return;\}/);
  assert.match(till, /This price could not be locked, so nothing was charged\./);
  // The counter resets wherever a checkout genuinely restarts — otherwise the SECOND honest
  // drift of a shift would be reported as a dead end.
  assert.match(till, /evalState='idle';evalResult=null;evalError=null;staleConfirm=false;staleReevaluationsV257=0;/);
  assert.match(till, /evalResult=null;evalError=null;staleConfirm=false;staleReevaluationsV257=0;payError=null;clearExpiry\(\);/);
  assert.match(till, /function startNewCheckout\(\)\{payError=null;saleCommitted=false;staleConfirm=false;staleReevaluationsV257=0;/);
  // Server: the cause. record_cart_sale re-priced bundle-expanded lines at the member services'
  // LIST prices, so the cart hash never matched and every finalise raised stale_evaluation.
  // The token now carries each expanded line's origin and the finaliser replays the allocation.
  assert.match(migration, /bundle_id/);
  assert.match(migration, /jsonb_build_object\(''bundle_id'', v_bsrc\[j\], ''bundle_qty'', v_bsrcqty\[j\]\)/);
  assert.match(migration, /app\.ps1c_bundle_lines_v204\(p_business, v257_bid, v257_bqty\)/);
  // The drift guard is redirected, not removed: a changed bundle still fails stale.
  assert.match(migration, /the bundle on line % changed since evaluation; re-evaluate/);
  assert.match(migration, /using errcode = ''P0001''/);
});
