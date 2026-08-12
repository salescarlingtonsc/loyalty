import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* V285 — the audit-A4 findings on Reports, Operations setup, Settings and the workspace chrome.
   One security defect (any staff member could delete a colleague's branch assignment), two
   surfaces that rendered owner-only write UI to everybody, four reports that did not say — or did
   not honour — the branch they covered, and a set of screens that could create a record and then
   never correct or remove it. */

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
/* Tests that grep application code read the CONCATENATION of index.html + app.js: the megascript
   was split out of the page, and either file may hold the markup a check is about. */
const app = readFileSync(resolve(root, 'app/index.html'), 'utf8') +
  readFileSync(resolve(root, 'app/app.js'), 'utf8');
const migration = readFileSync(
  resolve(root, 'db/migrations/20260812_nestly_v285_a4_gap_closure.sql'), 'utf8');
const sqlSuite = readFileSync(resolve(root, 'db/tests/v285_a4_gap_closure.sql'), 'utf8');
const registry = JSON.parse(
  readFileSync(resolve(root, 'docs/design/ps0/writer-registry.json'), 'utf8'));

/* ------------------------------------------------------- P0.1 staff_branches policy split */

test('the FOR ALL staff_branches policy is replaced by per-command policies', () => {
  assert.match(migration, /drop policy if exists staff_branches_all on public\.staff_branches;/,
    'the policy whose owner test lived only in WITH CHECK must be dropped by name');
  for (const [name, command] of [
    ['staff_branches_select', 'select'],
    ['staff_branches_insert', 'insert'],
    ['staff_branches_update', 'update'],
    ['staff_branches_delete', 'delete'],
  ]) {
    assert.match(
      migration,
      new RegExp(`create policy ${name} on public\\.staff_branches\\s*\\n\\s*for ${command} to authenticated`),
      `${name} must be created as a ${command.toUpperCase()}-only policy`);
  }
  assert.doesNotMatch(migration, /create policy \w+ on public\.staff_branches\s*\n?\s*for all/,
    'no replacement policy may be FOR ALL — that shape is the defect');
});

test('only the SELECT policy is member-wide; every write policy names the owner', () => {
  const selectPolicy = migration.match(
    /create policy staff_branches_select on public\.staff_branches[\s\S]*?;/)[0];
  assert.match(selectPolicy, /app\.is_salon_member\(business_id\)/);
  for (const name of ['staff_branches_insert', 'staff_branches_update', 'staff_branches_delete']) {
    const policy = migration.match(new RegExp(`create policy ${name} on public\\.staff_branches[\\s\\S]*?;`))[0];
    assert.match(policy, /app\.is_salon_owner\(business_id\)/, `${name} must test ownership`);
    assert.doesNotMatch(policy, /is_salon_member/, `${name} must not fall back to membership`);
  }
  assert.match(migration, /revoke all on public\.staff_branches from anon;/);
  assert.match(migration, /grant select, insert, update, delete on public\.staff_branches to authenticated;/);
});

test('the rollback suite proves member read, member delete refused, owner delete allowed', () => {
  assert.match(sqlSuite, /a member must still be able to read the branch assignment map/);
  assert.match(sqlSuite, /a member deleted a colleague''s branch assignment/);
  assert.match(sqlSuite, /the owner could not delete a branch assignment/);
  /* A refused DELETE under RLS removes zero rows rather than raising, so the suite has to check
     that the row SURVIVED — asserting only on an error would pass against the broken policy. */
  assert.match(sqlSuite, /get diagnostics v_deleted = row_count;/);
  assert.equal((sqlSuite.match(/^begin;$/gm) || []).length, 1);
  assert.equal((sqlSuite.match(/^rollback;$/gm) || []).length, 1);
  assert.match(sqlSuite, /V285_RESULT ALL PASS/);
});

/* --------------------------------------------------- P0.2 owner-only surfaces say so */

test('Branches and Settings refuse a non-owner with a card instead of a write UI', () => {
  assert.match(app, /function ownerOnlyDeniedCardV285\(title,iconName='settings'\)\{/);
  assert.match(app, /async function branchesPage\(\)\{\s*\n\s*if\(S\.myRole!=='owner'\)return ownerOnlyDeniedCardV285\('Branches','branches'\);/);
  assert.match(app, /async function settingsPage\(\)\{\s*\n\s*if\(S\.myRole!=='owner'\)return ownerOnlyDeniedCardV285\('Settings','settings'\);/);
  /* The gate must come before anything is rendered or read: settingsPage's first read is the
     module registry, branchesPage's is its own markup. */
  const settings = app.slice(app.indexOf('async function settingsPage(){'));
  assert.ok(settings.indexOf("ownerOnlyDeniedCardV285('Settings'") < settings.indexOf('module_registry'),
    'the refusal must be decided before settingsPage reads anything');
  const branches = app.slice(app.indexOf('async function branchesPage(){'));
  assert.ok(branches.indexOf("ownerOnlyDeniedCardV285('Branches'") < branches.indexOf('addBr'),
    'the refusal must be decided before branchesPage paints its controls');
});

test('Staff members inherits the Settings gate rather than carrying a second copy', () => {
  const staffMembers = app.match(/async function staffMembersPage\(\)\{[\s\S]*?\n\}/)[0];
  assert.match(staffMembers, /await settingsPage\(\);/,
    'staffMembersPage renders through settingsPage, so one gate covers both routes');
});

/* --------------------------------------------------------- P1 scope claims */

test('every finance report states the branches its figures cover', () => {
  /* One shared note element id, so the V272 renderer is what answers on all of them. */
  const noteMounts = app.match(/id="reportScopeNoteV272"/g) || [];
  assert.ok(noteMounts.length >= 5,
    `Business Insights plus the four V285 reports must each mount the scope note (found ${noteMounts.length})`);
  for (const page of ['staffPerfPage', 'dailyReportPage', 'expensesPage', 'pnlPage']) {
    const body = app.match(new RegExp(`async function ${page}\\([\\s\\S]*?\\n\\}\\n`))[0];
    assert.match(body, /id="reportScopeNoteV272"/, `${page} must mount the scope note`);
    assert.match(body, /renderReportScopeNoteV272\(isCurrent\)/, `${page} must render the scope note`);
  }
});

test('staff performance reads the branch it claims to cover', () => {
  const body = app.match(/async function staffPerfPage\([\s\S]*?\n\}\n/)[0];
  assert.match(body, /const commissionQueryV285=sb\.from\('sale_commission'\)/);
  assert.match(body, /selectedBranchId\?commissionQueryV285\.eq\('branch_id',selectedBranchId\):commissionQueryV285/,
    'the commission read must be branch-scoped whenever a branch is selected');
  assert.match(body, /p_branch:selectedBranchId\|\|null,p_module:'staffperf'/,
    'the module-scope check must be asked about the same branch');
});

test('the expenses list is scoped like the P&L beside it', () => {
  const body = app.match(/async function expensesPage\([\s\S]*?\n\}\n/)[0];
  assert.match(body, /const expenseQueryV285=sb\.from\('expenses'\)\.select\('\*',\{count:'exact'\}\)\.eq\('business_id',S\.biz\.id\);/);
  assert.match(body, /selectedBranchId\?expenseQueryV285\.eq\('branch_id',selectedBranchId\):expenseQueryV285/);
});

test('the customer intelligence caption reads a branch name that exists', () => {
  const body = app.match(/async function customerIntelligencePage\([\s\S]*?\n\}\n/)[0];
  assert.doesNotMatch(body, /\$\('branchSel'\)/,
    "branchSel is an id this page never rendered — the caption printed the literal words 'Selected branch'");
  assert.match(body, /const branchName=profileBranchScopeLabelV158\(\);/);
  /* The helper it now uses is the top bar's own, and it already answers for the unscoped case. */
  const helper = app.match(/function profileBranchScopeLabelV158\(\)\{[\s\S]*?\n\}/)[0];
  assert.match(helper, /if\(!selectedBranchId\)return 'All branches';/);
});

test('the customer intelligence heading matches the name the rail opened it by', () => {
  const body = app.match(/async function customerIntelligencePage\([\s\S]*?\n\}\n/)[0];
  assert.match(body, /<h1>Customer intelligence<\/h1>/);
  assert.match(app, /customerintel:\['customers','Customer intelligence'\]/,
    'the rail label this page is opened by must still be "Customer intelligence"');
  assert.match(body, /A defensible revenue picture/, 'the old title survives as the subtitle');
});

test('the top bar is the only branch picker on P&L and customer intelligence', () => {
  for (const page of ['pnlPage', 'customerIntelligencePage']) {
    const body = app.match(new RegExp(`async function ${page}\\([\\s\\S]*?\\n\\}\\n`))[0];
    assert.doesNotMatch(body, /id="branchWrap"/, `${page} must not render a second branch picker`);
    assert.doesNotMatch(body, /refreshBranchFilter\(/, `${page} must not wire a second branch picker`);
    assert.match(body, /selectedBranchId/, `${page} must still read the branch chosen at the top`);
  }
});

test('the P&L topbar no longer closes itself twice', () => {
  const body = app.match(/async function pnlPage\([\s\S]*?\n\}\n/)[0];
  const markup = body.match(/M\(\)\.innerHTML=`[\s\S]*?`;/)[0];
  const opens = (markup.match(/<div\b/g) || []).length;
  const closes = (markup.match(/<\/div>/g) || []).length;
  assert.equal(opens, closes, 'the P&L page markup must open and close the same number of divs');
});

/* ------------------------------------------------------------------ P2 CRUD */

test('a bundle can be edited, switched off and deleted', () => {
  assert.match(app, /data-bundle-edit="\$\{b\.id\}"/);
  assert.match(app, /data-bundle-toggle="\$\{b\.id\}"/);
  assert.match(app, /data-bundle-delete="\$\{b\.id\}"/);
  assert.match(app, /sb\.rpc\('update_service_bundle_v285',\{p_business:S\.biz\.id,p_bundle:bundle\.id,\s*\n\s*p_name:null,p_price_cents:null,p_service_ids:null,p_active:!bundle\.active\}\)/,
    'enable/disable must send only the active flag, so it cannot rename or reprice by accident');
  assert.match(app, /sb\.rpc\('delete_service_bundle_v285',\{p_business:S\.biz\.id,p_bundle:bundle\.id\}\)/);
  assert.match(app, /function openBundleEditV285\(bundleId\)\{/);
  assert.match(app, /use Disable instead/, 'the delete confirm must name the reversible alternative');
});

test('the bundle writers exist server-side because the tables are read-only to the browser', () => {
  assert.match(migration, /create or replace function public\.update_service_bundle_v285\(/);
  assert.match(migration, /create or replace function public\.delete_service_bundle_v285\(/);
  for (const raw of [
    'public.update_service_bundle_v285(uuid, uuid, text, integer, uuid[], boolean)',
    'public.delete_service_bundle_v285(uuid, uuid)',
    'public.update_expense_v285(uuid, uuid, integer, text, text)',
  ]) {
    const signature = raw.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    assert.match(migration, new RegExp(`revoke all on function ${signature} from public, anon, authenticated;`),
      `${raw} must revoke the default execute grant`);
    assert.match(migration, new RegExp(`grant execute on function ${signature} to authenticated;`),
      `${raw} must be granted back to authenticated only`);
  }
  assert.match(migration, /app\.can_module_write\(p_business, 'services'\)/);
  assert.match(migration, /app\.has_perm\(p_business, 'view_finance'\)/);
});

test('module templates can be renamed and deleted', () => {
  assert.match(app, /data-template-rename="\$\{t\.id\}"/);
  assert.match(app, /data-template-delete="\$\{t\.id\}"/);
  assert.match(app, /sb\.from\('module_templates'\)\.update\(\{name:next\}\)\s*\n?\s*\.eq\('id',template\.id\)\.eq\('business_id',S\.biz\.id\)/);
  assert.match(app, /sb\.from\('module_templates'\)\.delete\(\)\s*\n?\s*\.eq\('id',template\.id\)\.eq\('business_id',S\.biz\.id\)/);
  assert.match(app, /only the saved shortcut goes/,
    'deleting a template must say that teammates keep the modules they were given');
});

test('a branch can be deleted, but only behind a typed confirmation', () => {
  assert.match(app, /window\.deleteBranchV285=async\(branchId,button\)=>\{/);
  assert.match(app, /if\(branch\.is_default\)return toast\('Your main branch cannot be deleted\.'\)/);
  assert.match(app, /prompt\(`Type the branch name to confirm deletion: \$\{branch\.name\}`\)/);
  assert.match(app, /untick Active in Edit/, 'the confirm must point at the reversible alternative');
  assert.match(app, /sb\.from\('branches'\)\.delete\(\)\.eq\('id',branchId\)\.eq\('business_id',S\.biz\.id\)/);
  assert.match(app, /\$\{b\.is_default\?'':`<button class="btn ghost sm" data-name="\$\{esc\(b\.name\)\}" onclick="deleteBranchV285/,
    'the default branch must not even offer the control');
});

test('a teammate is deactivated, not deleted, unless they never worked', () => {
  assert.match(app, /window\.setStaffActiveV285=async\(id,active,button\)=>\{/);
  assert.match(app, /sb\.from\('staff'\)\.update\(\{active\}\)\.eq\('id',id\)\.eq\('business_id',S\.biz\.id\)/);
  assert.match(app, /onclick="setStaffActiveV285\('\$\{s\.id\}',\$\{s\.active===false\?'true':'false'\}/,
    'the same control must reactivate a switched-off teammate');
  const remove = app.match(/window\.rmStaff=async\(id,btn\)=>\{[\s\S]*?\n  \};/)[0];
  assert.match(remove, /sb\.from\('sales'\)\.select\('id',\{count:'exact',head:true\}\)/);
  assert.match(remove, /sb\.from\('appointments'\)\.select\('id',\{count:'exact',head:true\}\)/);
  assert.match(remove, /if\(worked>0\)\{/, 'a teammate with history must not be deletable at all');
  assert.equal((remove.match(/confirm\(/g) || []).length, 2,
    'deleting a person must pass two separate confirmations');
});

test('an expense can be corrected in place, and the immovable fields stay immovable', () => {
  assert.match(app, /window\.editExpenseV285=\(id\)=>\{/);
  assert.match(app, /sb\.rpc\('update_expense_v285',\{p_business:S\.biz\.id,p_expense:expense\.id,\s*\n?\s*p_amount_cents:amount,p_category:category,p_note:note\|\|null\}\)/);
  assert.match(app, /The date and the branch stay as they are/);
  const fn = migration.match(/create or replace function public\.update_expense_v285\([\s\S]*?\n\$\$;/)[0];
  assert.doesNotMatch(fn, /set[\s\S]*?branch_id\s*=/, 'the branch a cost landed in must not be writable');
  assert.doesNotMatch(fn, /set[\s\S]*?occurred_on\s*=/, 'the period a cost landed in must not be writable');
  assert.match(fn, /a voided expense cannot be edited/);
});

test('the bottle catalogue name and price are editable, and null still means unchanged', () => {
  assert.match(app, /data-bottle-name="\$\{index\}"/);
  assert.match(app, /data-bottle-price="\$\{index\}"/);
  assert.match(app, /p_business:S\.biz\.id,p_product:product\.id,p_name:editedName,p_size_ml:size,p_price_cents:editedPrice/);
  const fn = migration.match(/create or replace function public\.bar_save_bottle_product_v278\([\s\S]*?\n\$\$;/)[0];
  assert.match(fn, /name = coalesce\(v_name, product\.name\)/);
  assert.match(fn, /retail_price_cents = coalesce\(p_price_cents, product\.retail_price_cents\)/);
  assert.match(fn, /set size_ml = p_size_ml,/,
    'clearing the size box is how a product stops being a bottle, so that null is a value, not an omission');
  assert.match(sqlSuite, /a null name or price overwrote the catalogue/);
});

test('a storage shelf can be renamed', () => {
  assert.match(app, /data-location-name="\$\{index\}"/);
  assert.match(app, /locations\[Number\(input\.dataset\.locationName\)\]\.name=input\.value;/);
  assert.match(app, /Every storage place needs a name/,
    'an emptied name must be caught before the server sees it');
});

/* ------------------------------------------------------------------- P3 polish */

test('Get started sends the owner to the roster, not to Modules & plan', () => {
  assert.match(app, /link:'#\/staffmembers',cta:'Add a teammate →'/);
});

test('the global search says why it cannot look instead of doing nothing', () => {
  const lookup = app.match(/function runWorkspaceCustomerLookup\(query\)\{[\s\S]*?\n\}/)[0];
  assert.match(lookup, /toast\('Searching for a customer needs Customers or Record sale access/);
  assert.match(lookup, /toast\([\s\S]*?\);\s*\n\s*return false;/,
    'the toast must fire on the path that returns false');
});

test('the dead package-sell handler is gone and the till keeps selling', () => {
  assert.doesNotMatch(app, /\$\('ksell'\)/, 'no markup has rendered #ksell since selling moved to the till');
  assert.doesNotMatch(app, /\$\('kSaleBranch'\)/);
  assert.match(app, /sb\.rpc\('sell_package_v102'/,
    'the live till call site must survive the dead handler removal');
});

test('the products list uses the shared table skeleton', () => {
  assert.match(app, /<div id="ilist" style="margin-top:8px">\$\{CUI\.tableSkeleton\(\{rows:5,columns:5\}\)\}<\/div>/);
});

/* --------------------------------------------------------- registry reconciliation */

test('every new V285 writer surface is curated in the PS-0 registry', () => {
  const ids = new Set([...registry.writers, ...registry.allowlist].map((entry) => entry.id));
  for (const id of [
    'db.fn:public.update_expense_v285/5',
    'browser.rpc:app/app.js:update_expense_v285',
    'browser.rpc:app/app.js:update_service_bundle_v285',
    'browser.rpc:app/app.js:delete_service_bundle_v285',
    'browser.write:app/app.js:branches:DELETE',
    'browser.write:app/app.js:module_templates:UPDATE',
    'browser.write:app/app.js:module_templates:DELETE',
  ]) {
    assert.ok(ids.has(id), `${id} must be curated in the writer registry`);
  }
});
