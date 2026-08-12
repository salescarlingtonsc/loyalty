import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

/* V288 — audit gap closure for the Dashboard and the Programmes Overview/History tables.
   Every assertion below pins a defect that was live on the previous commit, not a preference. */

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
const grow = section('async function growPage(', 'async function studioPublishReviewPage(');
const programmeEntries = section('const growProgrammeEntriesV271=', 'const growOverviewRowsV271=');

/* ------------------------------------------------------------------ MAJOR 1 */

test('V288 MAJOR: a failed inactive-60 read is never rendered as a reassuring zero', () => {
  // It used to substitute a literal 0 for a count the page never received.
  assert.doesNotMatch(dashboard, /inactive60Total:inactive60Response\.error\?0:/);
  assert.match(dashboard, /inactive60Total:inactive60Response\.error\?null:Number\(inactive60Response\.data\?\.matching_customers\)\|\|0/);
  // The business-health row states that it could not be read, instead of "0 ... · Stable".
  assert.match(app, /const retentionUnreadV288=inactive60Total===null\|\|inactive60Total===undefined;/);
  assert.match(app, /const retentionStatus=retentionUnreadV288\?'Could not be read':Number\(inactive60Total\)>0\?'Needs attention':'Stable';/);
  assert.match(app, /retentionUnreadV288\?'Retry the inactive customer count above':`\$\{Number\(inactive60Total\)\|\|0\} inactive 60\+ days`/);
});

test('V288 a lone inactive-60 failure now reaches the existing retry button', () => {
  assert.match(dashboard, /customerMetricsAvailable&&\(inactiveResponse\.error\|\|inactive60Response\.error\)\?/);
  assert.match(dashboard, /Inactive customer counts could not be loaded\./);
  assert.match(dashboard, /id="dashboardInactiveRetry"/);
  assert.match(dashboard, /status\.querySelector\('#dashboardInactiveRetry'\)\?\.addEventListener\('click',load\)/);
});

/* ------------------------------------------------------------------ MAJOR 2 */

test('V288 MAJOR: the 60+ insight links to the 60+ audience it counted, not to 60-89', () => {
  // The card counts inactive_60_plus; linking into 60_89 silently dropped everyone 90+.
  assert.doesNotMatch(app, /data-insight-inactive="60_89"/);
  assert.match(app, /data-insight-inactive="60_plus"/);
  // The drill carries a bucket key, not a day number the destination had to re-guess.
  assert.match(dashboard, /if\(key==='inactive'\)pendingCustomerInactivity='30_59';/);
  assert.match(dashboard, /pendingCustomerInactivity=link\.dataset\.insightInactive\|\|'60_plus'/);
});

test('V288 the Customers page can actually show the 60+ audience', () => {
  // Resolved from the directory rows the page already holds — no server bucket is involved,
  // and staff_list_customers_v155 is still only asked for the four buckets it supports.
  assert.match(customers, /if\(bucket==='60_plus'\)return !never&&days>=60;/);
  assert.match(customers, /const pendingInactiveBucketV288=key=>\{/);
  /* V290 extends the resolver with 'all_inactive'; the guarantee (named buckets pass through) holds. */
  assert.match(app, /if\(\['30_59','60_89','60_plus','90_plus','never','all_inactive'\]\.includes\(raw\)\)return raw;/)
  // Visible in the filter control, so it can be seen and cleared.
  assert.match(app, /<option value="60_plus">Inactive 60\+ days<\/option>/);
  // And nameable as an audience for export / campaign prep.
  assert.match(app, /'60_plus':\{label:'Inactive 60\+ days'/);
  assert.match(app, /if\(!never&&days>=60\)buckets\['60_plus'\]\.customers\.push\(customer\);/);
  // The help text no longer claims every option is mutually exclusive.
  assert.match(app, /Inactive 60\+ days is the combined 60–89 and 90\+ audience/);
});

/* ------------------------------------------------------------------ MAJOR 3 */

test('V288 MAJOR: a scheduled promotion is not listed under Ongoing programmes', () => {
  // The inline derivation read ends_at and never starts_at.
  assert.doesNotMatch(programmeEntries, /state:ended\?'ended':promotion\?\.active===true\?'live':'draft'/);
  assert.match(programmeEntries, /const lifecycle=promotionLifecycleV186\(promotion\);/);
  assert.match(programmeEntries, /state:lifecycle\.state,/);
  // Only an ended promotion carries a "Ran until" date into History.
  assert.match(programmeEntries, /ended:lifecycle\.state==='ended'\?\(promotion\?\.ends_at\|\|null\):null/);
  // The predicate itself is unchanged and still names 'scheduled' for a future start.
  assert.match(app, /if\(starts&&starts>now\)return \{state:'scheduled',live:false,/);
  // The Overview table still admits only live rows, so 'scheduled' is excluded by construction.
  assert.match(app, /const growOverviewRowsV271=growProgrammeEntriesV271\.filter\(entry=>entry\.state==='live'\);/);
  assert.match(app, /const growHistoryRowsV271=growProgrammeEntriesV271\.filter\(entry=>entry\.state==='ended'\|\|entry\.state==='retired'\);/);
});

/* ------------------------------------------------------------------ MAJOR 4 */

test('V288 MAJOR: the Today schedule respects the selected branch on first paint', () => {
  assert.match(dashboard, /let appliedDashboardScopeV141=\{from:d30,to:today,branchId:selectedBranchId\|\|null,/);
  // ...and is re-fetched once, and only once, if the resolved branch differs.
  assert.match(dashboard, /const previousScheduleBranchV288=appliedDashboardScopeV141\.branchId;/);
  assert.match(dashboard, /if\(previousScheduleBranchV288!==appliedDashboardScopeV141\.branchId\)\{\s*\n\s*loadDashboardScheduleGlanceV180\(dashboardRoot,appliedDashboardScopeV141\.branchId,scheduleDateInputV252\?\.value\|\|null\);/);
});

/* ------------------------------------------------------------------ MAJOR 5 */

test('V288 MAJOR: a category drill does not survive a fresh navigation to Programmes', () => {
  assert.match(grow, /async function growPage\(routedSurface,hashParam,routedFocus=null,\{fromRouteV288=false\}=\{\}\)\{/);
  assert.match(grow, /if\(fromRouteV288\)growTopicV229='';/);
  // Every ROUTE entry marks itself; in-page re-renders deliberately do not.
  for (const route of [
    /grow:\(hashParam,routedFocus\)=>growPage\('overview',hashParam,routedFocus,\{fromRouteV288:true\}\)/,
    /loyalty:\(hashParam,routedFocus\)=>growPage\('rewards',hashParam,routedFocus,\{fromRouteV288:true\}\)/,
    /retention:\(hashParam,routedFocus\)=>growPage\('winback',hashParam,routedFocus,\{fromRouteV288:true\}\)/,
    /studio:hashParam=>growPage\('studio',hashParam,null,\{fromRouteV288:true\}\)/,
    /storedvalue:hashParam=>growPage\('storedvalue',hashParam,null,\{fromRouteV288:true\}\)/
  ]) assert.match(app, route);
  // The tile drill and the in-page re-renders keep the owner where they are.
  assert.match(grow, /growTopicV229=tile\.dataset\.growTopicV229;\s*\n\s*growPage\(routedSurface,hashParam,routedFocus\)\.catch\(fail\);/);
});
