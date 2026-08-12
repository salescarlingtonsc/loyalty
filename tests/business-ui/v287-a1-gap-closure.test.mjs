import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

/* V287 — audit A1 gap closure (Dashboard / Customers / Customer 360 / Record sale / Sales).
   Every assertion below pins a defect that was live on this commit, not a style preference. */

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
/* Same read-site as every other business-ui test: the application code is the CONCATENATION of
   the markup file and the script file. */
const app = fs.readFileSync(path.join(repo, 'app/index.html'), 'utf8') + '\n'
  + fs.readFileSync(path.join(repo, 'app/app.js'), 'utf8');

function section(start, end) {
  const from = app.indexOf(start);
  assert.notEqual(from, -1, `missing start marker: ${start}`);
  const to = app.indexOf(end, from + start.length);
  assert.notEqual(to, -1, `missing end marker: ${end}`);
  return app.slice(from, to);
}

const dashboard = section('async function dashboard(){', '/* ---------- customers ---------- */');
const customers = section('async function clientsPage(){', 'async function clientDetail(id){');
const profile = section('async function clientDetail(id){', '/* ---------- quick earn (');
const till = section('async function tillPage', 'async function salesPage(){');
const sales = section('async function salesPage(){', '/* ---------- services ---------- */');

/* ------------------------------------------------------------------ BLOCKER 1 */

test('V287 BLOCKER: the birthday redeem card no longer references an undeclared identifier', () => {
  // `(ctxBr||[]).map(...)` was the ONLY reference to ctxBr anywhere in the file, and it was
  // declared nowhere: building the markup threw a ReferenceError and killed the entire
  // customer profile whenever a birthday benefit was available.
  assert.doesNotMatch(app, /\(ctxBr\|\|\[\]\)/);
  // The only surviving mention is the comment that records why it was a blocker.
  assert.equal((app.match(/\bctxBr\b/g) || []).length, 1);
  // The list is loaded the way every other branch selector on this surface loads it.
  assert.match(profile, /const \{branches\}=await visibleBranchesForCurrentUser\(\);\s*\n\s*birthdayBranchesV287=activeBranchesForScopeV217\(branches\);/);
  assert.match(profile, /birthdayBranchesV287\.map\(branch=>`<option value="\$\{esc\(branch\.id\)\}"/);
});

test('V287 the birthday branch load is gated, aborts on a stale route, and fails soft', () => {
  // Only fetched when the picker would actually render...
  assert.match(profile, /const birthdayNeedsBranchPickerV287=birthdayBenefitsEnabled&&!birthdayError&&canRedeemBirthday/);
  assert.match(profile, /birthdayBenefit\.status==='available'&&birthdayBenefit\.cta==='show_at_counter'/);
  // ...and a failure degrades to "no selector" with an honest sentence, never a crash.
  assert.match(profile, /catch\(branchError\)\{console\.error\(branchError\);birthdayBranchesV287=\[\]\}/);
  assert.match(profile, /if\(!isClientDetailCurrent\(\)\)return;/);
  assert.match(profile, /The branch list could not be loaded, so this benefit cannot be redeemed here yet/);
});

/* This is the general form of the blocker: scripts/quality/undeclared-identifiers.mjs only
   inspects VERSION-SUFFIXED names (fooV287), so a bare identifier like ctxBr escaped it
   entirely. Pin the bare identifiers this template actually depends on. */
test('V287 every identifier the birthday redeem template uses is declared', () => {
  for (const name of ['birthdayBenefit', 'birthdayError', 'birthdayBenefitsEnabled',
    'canRedeemBirthday', 'birthdayStatusLabel', 'birthdayNeedsBranchPickerV287',
    'birthdayBranchesV287']) {
    assert.ok(
      new RegExp(`(const|let|var)\\s+${name}\\b`).test(profile)
      || new RegExp(`\\{[^}]*\\b${name}\\b[^}]*\\}=`).test(profile)
      || new RegExp(`\\{data:[A-Za-z0-9_]+,error:${name}\\}`).test(profile)
      || new RegExp(`\\{data:${name},error:`).test(profile),
      `${name} is used by the birthday card but never declared in clientDetail`);
  }
});

/* ------------------------------------------------------------------ MAJOR 2 */

test('V287 MAJOR: the default catalogue checkout has a staff attribution picker', () => {
  // record_cart_sale sends p_staff, but the catalogue composer offered no way to set it, so
  // every commission on the DEFAULT checkout path went to whoever was signed in.
  const composer = till.slice(till.indexOf('function drawCartComposer(){'));
  assert.match(composer, /const staffPickerV287=tillAttributableStaff\.length>1/);
  assert.match(composer, /<label for="tillSaleStaff">Who made this sale\?<\/label>/);
  assert.match(composer, /<select id="tillSaleStaff"/);
  // Mounted in the composer markup, right after the branch picker.
  assert.match(composer, /\$\{branchPicker\}\s*\n\s*\$\{staffPickerV287\}/);
});

test('V287 the composer picker reuses the legacy candidate rule, default and handler', () => {
  const composer = till.slice(till.indexOf('function drawCartComposer(){'));
  assert.match(composer, /const tillAttributableStaff=tillAttributableStaffFor\(tillBranchId\);/);
  assert.match(composer, /if\(!tillAttributableStaff\.some\(person=>person\.id===tillSaleStaffId\)\)tillSaleStaffId=tillActingStaffId;/);
  assert.match(composer, /\$\('tillSaleStaff'\)\.onchange=event=>\{\s*\n\s*tillSaleStaffId=event\.target\.value\|\|tillActingStaffId;draw\(\);/);
  // Attribution reaches the server unchanged: this is still the value record_cart_sale sends.
  assert.match(till, /p_branch:tillBranchId,p_staff:tillSaleStaffId\|\|tillStaffId,p_method:tender/);
});

/* ------------------------------------------------------------------ MAJOR 3 */

test('V287 MAJOR: the orphaned reporting-scope selectors that double-loaded two pages are gone', () => {
  // Their target wrappers were deleted by V225. renderReportingScopeSelectorV155 calls onChange
  // immediately when the wrapper is missing, so Dashboard and Customers each ran their full
  // load twice on every open.
  assert.doesNotMatch(app, /id="dashboardReportingScopeWrap"/);
  assert.doesNotMatch(app, /id="clientReportingScopeWrap"/);
  assert.doesNotMatch(dashboard, /renderReportingScopeSelectorV155\(/);
  assert.doesNotMatch(customers, /renderReportingScopeSelectorV155\(/);
  // Exactly one load each remains.
  assert.equal((dashboard.match(/if\(isDashboardCurrent\(\)\)await load\(\)/g) || []).length, 1);
  assert.equal((customers.match(/^ {2}load\(\);$/gm) || []).length, 1);
  // The scope itself is untouched — it still reaches the RPCs.
  assert.match(dashboard, /currentReportingScopePayloadV155/);
  assert.match(customers, /currentReportingScopePayloadV155/);
  // And the selector function itself is still live for the surfaces that DO render a wrapper.
  assert.match(app, /async function renderReportingScopeSelectorV155\(/);
});

/* ------------------------------------------------------------------ MAJOR 4 */

test('V287 MAJOR: the Sales ledger gets the responsive table enhancer', () => {
  assert.match(app, /const customerUiRoutes=new Set\(\['till','clients','client','sales',/);
  // Membership drives exactly these two things and nothing else.
  assert.equal((app.match(/customerUiRoutes\.has\(/g) || []).length, 1);
  assert.match(app, /const enhanceCustomerUi=customerUiRoutes\.has\(page\[0\]\);/);
  assert.equal((app.match(/enhanceCustomerUi/g) || []).length, 3);
  // The table it is for.
  assert.match(sales, /<table data-responsive="true">/);
});

/* ------------------------------------------------------------------ MAJOR 6 */

test('V287 MAJOR: the Inactive customers tile counts the same group it drills through to', () => {
  // It used to add 30-59 and 60+ together, then navigate to the 30-59 bucket only.
  assert.doesNotMatch(dashboard, /Number\(inactive60Response\.data\?\.matching_customers\)\|\|0\)\)/);
  assert.match(dashboard, /const inactiveTotal=inactiveResponse\.error\?'Unavailable':String\(Number\(inactiveResponse\.data\?\.total\)\|\|0\);/);
  /* V290 supersedes the V287 narrowing: the 'all_inactive' bucket is now server-expressible,
     so the tile counts ALL inactive again and drills to exactly that set — the original
     goal V287 could not reach without a migration. */
  assert.match(app, /all_inactive/);
  /* V288: the drill carries the bucket key itself rather than a day number. */
  assert.match(dashboard, /if\(key==='inactive'\)pendingCustomerInactivity='30_59';/);
  // ...and it says so, both on the tile and in its definition.
    // V290: the 30–59 hint went with the narrowing it explained.
    // V290: the tile's definition now describes the all-inactive union instead of the 30–59 window.
  assert.match(app, /No valid visit for at least 30 complete Singapore days/);
  // 60+ customers are still reported, by the card that links to their own bucket.
  /* V288: an unread 60+ count travels as null, never as 0, and the card links to the 60+
     audience it actually counted. */
  assert.match(dashboard, /inactive60Total:inactive60Response\.error\?null:Number\(inactive60Response\.data\?\.matching_customers\)\|\|0/);
  assert.match(app, /data-insight-inactive="60_plus"/);
});

/* ------------------------------------------------------------------ MAJOR 9 (part) */

test('V287 the Sales page no longer pulls the whole customer table it never read', () => {
  assert.doesNotMatch(sales, /from\('clients'\)\.select\('id,full_name'/);
  assert.doesNotMatch(sales, /\{data:cl,error:clientError\}/);
  assert.doesNotMatch(sales, /clientError/);
  // Customer names still arrive embedded on the sale rows, which is what the filter reads.
  assert.match(sales, /select\('\*, clients\(full_name\), staff\(full_name\)'\)/);
  assert.match(sales, /const salesLoadError=staffError;/);
});

/* ------------------------------------------------------------------ MINOR 10 */

test('V287 the Sales ledger states a permission limit instead of painting it as no rows', () => {
  assert.match(sales, /if\(!canReadModule\('sales'\)\)\{/);
  assert.match(sales, /title:'Sales access needed'/);
  assert.match(sales, /This is a permission limit, not an empty ledger/);
  // The guard runs before any ledger query.
  assert.ok(sales.indexOf("canReadModule('sales')") < sales.indexOf("sb.from('staff')"),
    'the denied card must be decided before the page queries anything');
});

/* ------------------------------------------------------------------ MINOR 11 */

test('V287 the last bare record id in the Sales audit disclosure is labelled', () => {
  assert.doesNotMatch(app, /details:`Corrected by \$\{/);
  assert.match(app, /Original sale row, later corrected\. Audit record id of the correction: \$\{/);
  // The two V267 lines are unchanged; all three now read the same way.
  assert.match(app, /Compensating reversal row\. Audit record id of the sale it reverses: \$\{s\.reversal_of\}/);
  assert.match(app, /Original sale row, fully reversed\. Audit record id of the reversal: \$\{w\.reversal_sale_id\}/);
});

/* ------------------------------------------------------------------ MINOR 13 */

test('V287 the unreachable dashboard metric modal and the duplicate cart binding are gone', () => {
  // Every metric definition carries a route, so the `else` that opened this modal could never
  // be taken after V225 made each tile a direct link.
  assert.doesNotMatch(app, /function openDashboardMetricDetailV141\(/);
  assert.doesNotMatch(app, /openDashboardMetricDetailV141\(key,/);
  assert.doesNotMatch(app, /id="dashboardMetricModal"/);
  for (const key of ['visits', 'revenue', 'new', 'inactive']) {
    assert.match(dashboard, new RegExp(`${key}:\\{label:[^}]*route:'#/`),
      `${key} must still carry the route the tile navigates to`);
  }
  // The second, byte-identical [data-use-package] binding is removed; one remains.
  assert.equal((till.match(/document\.querySelectorAll\('\[data-use-package\]'\)/g) || []).length, 1);
  assert.match(till, /data-use-package="\$\{esc\(item\.client_package_id\)\}"/);
});

/* ------------------------------------------------------------------ MINOR 14 */

test('V287 the sales ledger intro speaks the low-literacy register', () => {
  assert.doesNotMatch(sales, /Immutable rows are kept for audit/);
  assert.doesNotMatch(sales, /compensating rows/);
  assert.doesNotMatch(sales, /Historical sales ledger, corrections and reversals/);
  assert.match(sales, /Every sale you have recorded\. Fix or cancel one here\./);
  assert.match(sales, /A sale is never deleted\. Cancel one and both rows stay, so the numbers always add up\./);
});
