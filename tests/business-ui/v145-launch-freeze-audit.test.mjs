import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

const appPath = new URL('../../app/index.html', import.meta.url);
const app = fs.readFileSync(appPath, 'utf8');
const dbMigrationPath = new URL('../../db/migrations/20260803_nestly_v145_launch_freeze_metrics.sql', import.meta.url);

function section(start, end) {
  const from = app.indexOf(start);
  assert.notEqual(from, -1, `missing section start: ${start}`);
  const to = app.indexOf(end, from + start.length);
  assert.notEqual(to, -1, `missing section end: ${end}`);
  return app.slice(from, to);
}

test('dashboard uses Singapore dates and labels every mixed metric scope', () => {
  const dashboard = section('async function dashboard()', '/* ---------- customers ---------- */');
  assert.match(dashboard, /const today=sgDateInputValue\(\),d30=shiftSgDateInput\(today,-29\)/);
  assert.doesNotMatch(dashboard, /toISOString\(\)\.slice\(0,10\)/);
  assert.match(dashboard, /Valid visits/);
  assert.match(dashboard, /New customer members/);
  assert.match(dashboard, /Inactive customers/);
  assert.match(dashboard, /availability\?\.sales===false/);
  assert.match(dashboard, /availability\?\.clients!==false/);
  assert.doesNotMatch(dashboard, /key:'points'/,
    'the simplified dashboard must not restore a mixed-scope points KPI');
  assert.doesNotMatch(dashboard, /key:'credit'/,
    'the simplified dashboard must not restore a mixed-scope credit KPI');
  assert.doesNotMatch(dashboard, /points_issued\|\|0/,
    'an unavailable Loyalty metric must never collapse into a plausible zero');
  assert.doesNotMatch(dashboard, /credit_liability_cents\|\|0/,
    'unavailable business-wide credit must never collapse into a plausible zero');
  assert.match(dashboard, /customerMetricsAvailable&&\{key:'new'/,
    'customer-count detail must be omitted when Clients is unavailable');
  assert.match(dashboard, /dashboardReportRetry/);
  assert.match(dashboard, /requestGate\.begin\(\)/);
  assert.match(dashboard, /await renderReportingScopeSelectorV155\(load,isDashboardCurrent,'dashboardReportingScopeWrap'\);[\s\S]*if\(isDashboardCurrent\(\)\)await load\(\)/,
    'the dashboard must load once after its reporting scope is initialized');
  assert.match(dashboard, /querySelectorAll\('input\[type="date"\]'\)\.forEach/);
  assert.doesNotMatch(dashboard, /Record a sale[\s\S]*Add appointment[\s\S]*Find a customer[\s\S]*Set up rewards/,
    'the removed dashboard task-card row must not return');
  assert.doesNotMatch(dashboard, /Services and goods sold|dashboardSaleMixV141|sale_items/,
    'unreconcilable gross item mix must stay hidden');
});

test('Singapore report date arithmetic advances calendar dates without UTC offset drift', () => {
  const start=app.indexOf('const shiftSgDateInput=');
  const end=app.indexOf('\nasync function fetchAllRows',start);
  assert.ok(start>=0&&end>start,'Singapore date-shift helper is missing');
  const source=app.slice(start,end);
  const shift=new Function(`${source};return shiftSgDateInput`)();
  assert.equal(shift('2026-08-03',1),'2026-08-04');
  assert.equal(shift('2026-08-03',-29),'2026-07-05');
  assert.equal(shift('2028-02-28',1),'2028-02-29');
});

test('Singapore weekdays and month spans ignore a non-Singapore device timezone', () => {
  const start=app.indexOf('const sgCalendarWeekday=');
  const end=app.indexOf('/* Canonical inactivity age',start);
  assert.ok(start>=0&&end>start,'timezone-independent calendar helpers are missing');
  const originalTz=process.env.TZ;
  try{
    process.env.TZ='America/New_York';
    const helpers=new Function(`${app.slice(start,end)};return {sgCalendarWeekday,calendarMonthSpan}`)();
    assert.equal(helpers.sgCalendarWeekday('2026-08-03'),1,'Singapore Monday must remain Monday');
    assert.equal(helpers.sgCalendarWeekday('2026-08-02'),0,'Singapore Sunday must remain Sunday');
    assert.equal(helpers.calendarMonthSpan('2026-07-02','2026-08-01'),1,
      'July-to-August must render as a multi-month P&L range west of UTC');
    assert.equal(helpers.calendarMonthSpan('2026-08-01','2026-08-31'),0);
  }finally{
    if(originalTz===undefined)delete process.env.TZ;else process.env.TZ=originalTz;
  }
  const reports=section('async function reportsPage()', '/* ---------- get started');
  assert.match(reports,/const weekday=sgCalendarWeekday\(day\)/);
  assert.doesNotMatch(reports,/new Date\(`\$\{day\}T00:00:00\+08:00`\)\.getDay\(\)/);
  const pnl=section('async function pnlPage()', '/* ---------- settings ---------- */');
  assert.match(pnl,/const spanMonths=calendarMonthSpan\(from,to\)/);
});

test('customer inactivity uses complete Singapore calendar days at midnight boundaries', () => {
  const helperStart=app.indexOf('const sgDateInputValue=');
  const helperEnd=app.indexOf('const REPORT_MAX_RANGE_DAYS=',helperStart);
  assert.ok(helperStart>=0&&helperEnd>helperStart,'Singapore inactivity helper is missing');
  const daysSince=new Function(`${app.slice(helperStart,helperEnd)};return completeSgCalendarDaysSince`)();
  const justBeforeSgMidnight='2026-08-02T15:59:59.000Z';
  const justAfterSgMidnight=new Date('2026-08-02T16:00:01.000Z');
  assert.equal(daysSince(justBeforeSgMidnight,justAfterSgMidnight),1,
    'crossing Singapore midnight advances one complete calendar day even when only two seconds elapsed');
  assert.equal(daysSince('2026-08-02T00:00:00.000Z',new Date('2026-08-02T15:59:59.000Z')),0);

  const pbStart=app.indexOf('function pbComputeCandidates(');
  const pbEnd=app.indexOf('async function pbActivateCampaign',pbStart);
  const compute=new Function('completeSgCalendarDaysSince',`${app.slice(pbStart,pbEnd)};return pbComputeCandidates`)(daysSince);
  const candidate={id:'customer-1',full_name:'Boundary customer',phone:'81234567'};
  const audience={clients:[candidate],byClient:new Map([[candidate.id,{net:3,lastIso:justBeforeSgMidnight}]])};
  assert.equal(compute(audience,1,3,justAfterSgMidnight).length,1,
    'the bring-back threshold matches the canonical at-least calendar-day rule');
  assert.equal(compute(audience,2,3,justAfterSgMidnight).length,0);
});

test('customer reward expiry countdown follows Singapore calendar dates, not rounded elapsed time', () => {
  const helperStart=app.indexOf('const sgDateInputValue=');
  const helperEnd=app.indexOf('const REPORT_MAX_RANGE_DAYS=',helperStart);
  assert.ok(helperStart>=0&&helperEnd>helperStart,'Singapore calendar expiry helper is missing');
  const helpers=new Function(`${app.slice(helperStart,helperEnd)};return {daysUntil:completeSgCalendarDaysUntil,date:sgDateInputValue}`)();
  const expiry='2026-08-04T16:00:00.000Z'; // 5 Aug 2026, 00:00 Singapore
  assert.equal(helpers.daysUntil(expiry,new Date('2026-08-03T15:59:59.000Z')),2,
    'one second before Singapore midnight the expiry is still two calendar dates away');
  assert.equal(helpers.daysUntil(expiry,new Date('2026-08-03T16:00:01.000Z')),1,
    'one second after Singapore midnight the countdown advances by one day');
  assert.equal(helpers.date(new Date(expiry)),'2026-08-05','the displayed expiry date must stay the Singapore date');
  const client=section('async function clientDetail(id)', '/* ---------- sales ---------- */');
  assert.match(client,/const expiryDate=nextExp\?sgDateInputValue\(new Date\(nextExp\.expires_at\)\):null/);
  assert.match(client,/completeSgCalendarDaysUntil\(nextExp\.expires_at\)/);
  assert.doesNotMatch(client,/Math\.round\(\(new Date\(nextExp\.expires_at\)\.getTime\(\)-Date\.now\(\)\)\/dayMs\)/);
});

test('lifecycle answer reads the server metrics object and withholds unclassifiable empty coverage', () => {
  const start=app.indexOf('function lifecycleAnswerProjection(');
  const end=app.indexOf('\nfunction expenseAmountProjection(',start);
  assert.ok(start>=0&&end>start,'lifecycle answer projection is missing');
  const project=new Function(`${app.slice(start,end)};return lifecycleAnswerProjection`)();
  const nonZero=project({status:'ok',metrics:{existing_returning_customers:7,new_customers:3},coverage:{eligible_transactions:12,identified_transactions:10,identified_transaction_pct:83.33}});
  assert.equal(nonZero.usable,true);
  assert.equal(nonZero.metrics.existing_returning_customers,7);
  assert.equal(nonZero.metrics.new_customers,3);
  assert.equal(nonZero.identifiedTransactionPct,83.33);
  assert.equal(project({status:'no_data',metrics:{existing_returning_customers:0},coverage:{eligible_transactions:0,identified_transactions:0}}).usable,false);
  assert.equal(project({status:'ok',metrics:{existing_returning_customers:0},coverage:{eligible_transactions:5,identified_transactions:0}}).usable,false);
  const reports = section('async function reportsPage()', '/* ---------- get started');
  assert.match(reports,/const c=lifecycleAnswerProjection\(current\),p=lifecycleAnswerProjection\(prior\)/);
  assert.match(reports,/const cm=c\.metrics,pm=p\.usable\?p\.metrics:null/);
  assert.match(reports,/Identity coverage:/);
  assert.match(reports,/No zero is inferred/);
  assert.doesNotMatch(reports,/c\.existing_returning_customers|c\.new_customers|c\.reactivated_customers/);
});

test('expense list preserves original currency and reconciles the exact base-currency amount', () => {
  const start=app.indexOf('function expenseAmountProjection(');
  const end=app.indexOf('\nasync function fetchAllRows',start);
  assert.ok(start>=0&&end>start,'expense amount projection is missing');
  const project=new Function(`${app.slice(start,end)};return expenseAmountProjection`)();
  assert.deepEqual(project({amount_cents:100,currency:'USD',fx_rate_to_base:'1.5'},'SGD'),{
    valid:true,originalLabel:'USD 1.00',baseLabel:'SGD 1.50',baseCents:150,showBase:true
  });
  assert.equal(project({amount_cents:100,currency:'USD',fx_rate_to_base:null},'SGD').valid,false);
  const expenses=section('async function expensesPage()', '/* ---------- P&L ---------- */');
  assert.match(expenses,/expenseAmountProjection\(e,S\.biz\.currency\|\|'SGD'\)/);
  assert.match(expenses,/used in P&amp;L/);
  assert.match(expenses,/Unavailable — invalid currency conversion metadata/);
  assert.doesNotMatch(expenses,/<td>\$\{money\(e\.amount_cents\)\}<\/td>/);
});

test('valid visit helper removes reversal rows and their original visits everywhere retention is derived', () => {
  assert.match(app, /function validVisitSales\(rows\)/);
  const client = section('async function clientDetail(id)', '/* ---------- sales ---------- */');
  assert.match(client, /const validVisits=validVisitSales\(allSl\|\|\[\]\)/);
  assert.match(client, /const netVisits=validVisits\.length/);
  assert.match(client, /const lastVisitIso=validVisits/);
  const audience = section('async function pbLoadAudience()', 'function pbComputeCandidates');
  assert.match(audience, /require_module_scope_v145[\s\S]*p_module:'retention'/);
  assert.match(audience, /const validVisits=validVisitSales\(sales\)/);
  assert.doesNotMatch(audience, /s\.reversal_of\?-1:1/);
  assert.doesNotMatch(app, /pbAudienceCache/, 'bring-back audience must be re-read after sales or reversals');
});

test('daily report reuses the canonical dashboard visit projection instead of counting transaction rows', () => {
  const daily = section('async function dailyReportPage()', '/* ---------- expenses ---------- */');
  assert.match(daily, /sb\.rpc\('get_dashboard_summary'/);
  assert.match(daily, /require_module_scope_v145[\s\S]*p_module:'dailyreport'/);
  assert.match(daily, /require_module_scope_v145[\s\S]*p_module:'clients'/);
  assert.match(daily, /const columns=clientsAvailable[\s\S]*'\*, clients\(full_name,phone\)/);
  assert.match(daily, /Customer details unavailable/);
  assert.match(daily, /const visits=Number\(summary\.visits\|\|0\)/);
  assert.match(daily, /const uniqueCustomerRecords=Number\(summary\.unique_customers\|\|0\)/);
  assert.match(daily, /Gift-card issuance amount recorded/);
  assert.doesNotMatch(daily, /Gift-card sales recorded/);
  assert.match(daily, /Signed revenue by kind/);
  assert.match(daily, /C\('drC2',\{type:'bar'/);
  assert.match(daily, /backgroundColor:kindValues\.map\(value=>value<0\?'#C83F35':coral\)/);
  assert.match(daily, /scales:\{y:\{beginAtZero:true\}\}/);
  assert.doesNotMatch(daily, /C\('drC2',\{type:'doughnut'/);
  assert.doesNotMatch(daily, /reduce\(\(n,r\)=>n\+\(r\.reversal_of\?-1:1\),0\)/);
});

test('P&L charts use complete server aggregates and Singapore dates, never capped raw reads', () => {
  const pnl = section('async function pnlPage()', '/* ---------- settings ---------- */');
  assert.match(pnl, /const today=sgDateInputValue\(\),d30=shiftSgDateInput\(today,-29\)/);
  assert.match(pnl, /sum\.expenses_by_category/);
  assert.match(pnl, /sum\.monthly/);
  assert.doesNotMatch(pnl, /sb\.from\('expenses'\)/);
  assert.doesNotMatch(pnl, /sb\.from\('sales'\)/);
  assert.match(pnl, /Accrual revenue vs expenses by month/);
  assert.match(pnl, /Cash-basis revenue/);
  assert.match(pnl, /Cash-basis revenue less/);
  assert.match(pnl, /Selected-branch expenses/);
  assert.match(pnl, /excludes business-wide overhead/);
  assert.match(pnl, /Gift card issuance is deferred revenue/);
  assert.match(pnl, /Only recorded eligible payments count toward cash-basis revenue/);
  assert.match(pnl, /No expenses recorded in this scope/,
    'an empty category aggregate must explain the absence instead of leaving a blank chart canvas');
  assert.doesNotMatch(pnl, /Gift card sales are cash collected/);
  assert.doesNotMatch(pnl, /Revenue \(money collected\)|Net cash \(money collected less expenses\)/);
  assert.match(pnl, /reportRangeValidation\(from,to\)/);
});

test('staff performance excludes non-revenue ledger rows from revenue while retaining full traceability', () => {
  const helperStart=app.indexOf('function staffPerformanceAggregation(');
  const helperEnd=app.indexOf('\nfunction waitlistTodaySummary(',helperStart);
  assert.ok(helperStart>=0&&helperEnd>helperStart,'staff performance aggregation helper is missing');
  const aggregate=new Function(`${app.slice(helperStart,helperEnd)};return staffPerformanceAggregation`)();
  const rows=Array.from({length:1001},(_,index)=>({sale_id:`revenue-${index}`,staff_id:'staff-1',amount_cents:1,commission_cents:0,counts_as_revenue:true}));
  rows.push(
    {sale_id:'gift-card',staff_id:'staff-1',amount_cents:10000,commission_cents:0,counts_as_revenue:false},
    {sale_id:'reversal',staff_id:'staff-1',amount_cents:-400,commission_cents:-40,counts_as_revenue:true}
  );
  const result=aggregate(rows,[{id:'staff-1',full_name:'Aisha'}]);
  assert.equal(result.byStaff['staff-1'].ledgerRecords,1003);
  assert.equal(result.byStaff['staff-1'].revenueRecords,1002);
  assert.equal(result.byStaff['staff-1'].revenue,601,
    'gift-card issuance is excluded while the signed reversal reduces attributed revenue');
  assert.equal(result.byStaff['staff-1'].commission,-40);
  const staff = section('async function staffPerfPage(drillId)', '/* ---------- daily report ---------- */');
  assert.match(staff, /fetchAllRows\(\(\)=>sb\.from\('sale_commission'\)/);
  assert.match(staff, /require_module_scope_v145[\s\S]*p_module:'staffperf'/);
  assert.match(staff, /Signed ledger records/);
  assert.match(staff, /Ledger records/);
  assert.match(staff, /counts_as_revenue/);
  assert.match(staff, /Revenue records/);
  assert.match(staff, /Revenue excludes rows whose immutable sale policy marks them non-revenue/);
  assert.match(staff, /Revenue treatment/);
  assert.match(staff, />Non-revenue</);
  assert.match(staff, /Apply the new range to refresh staff performance/);
  assert.match(staff, /Apply the new range to refresh these ledger records/);
  assert.match(staff, /p_module:'clients'/);
  assert.match(staff, /const clientsAvailable=!clientsScopeResult\?\.error/);
  assert.match(staff, /Customer details unavailable/);
  assert.match(staff, /cid&&clientName\[cid\]\?`<a href="#\/client\/\$\{cid\}"/);
});

test('Reports states the period, branch and business-wide scopes without claiming one common scope', () => {
  const reports = section('async function reportsPage()', '/* ---------- get started');
  assert.doesNotMatch(reports, /All answers below use this same period and branch/);
  assert.match(reports, /Loyalty flow \(business-wide, selected period\)/);
  assert.match(reports, /Liabilities \(business-wide, now\)/);
  assert.match(reports, /Active members \(business-wide, now\)/);
  assert.match(reports, /const busyGate=createLatestRequestGate/);
  assert.match(reports, /const returningGate=createLatestRequestGate/);
  assert.match(reports, /const canSeeReturningAnswer=canReadModule\('clients'\)&&hasRoleCapability\('view_finance'\)/);
  assert.match(reports, /moneyGate\.invalidate\(\);busyGate\.invalidate\(\);returningGate\.invalidate\(\)/);
  assert.match(reports, /p_module:'reports'/);
  assert.match(reports, /p_module:'sales'/);
  assert.match(reports, /const exportScope=lastScope/);
  assert.match(reports, /clientsAvailable:d\.availability\?\.clients_export===true/);
  assert.match(reports, /Customer details unavailable/);
  assert.match(reports, /No zero is inferred/);
  assert.match(reports, /creditLiabilityAvailable\?money\(liab\):'Unavailable'/);
  assert.doesNotMatch(reports, /credit_liability_cents\|\|0/,
    'branch-limited Reports must not render unavailable business credit as zero');
  assert.match(reports, /Non-revenue sale amounts recorded/);
  assert.match(reports, /sale ledger amounts, not verified payment or cash-collection totals/);
  assert.doesNotMatch(reports, /Cash collected, not revenue|real cash in the drawer/);
  assert.match(reports, /if\(lastScope!==exportScope\)/);
  assert.doesNotMatch(reports, /sb\.from\('sales'\)[\s\S]*reversalRows.*reduce/,
    'money reconciliation must come from the server aggregate, not a capped raw read');
});

test('Reports machine-readable scope agrees with every availability flag', () => {
  const sql = fs.readFileSync(dbMigrationPath, 'utf8');
  const from=sql.indexOf('create or replace function public.get_reports_summary(');
  const to=sql.indexOf('-- Existing P&L summary now owns its chart aggregates.',from);
  assert.ok(from>=0&&to>from,'V145 Reports RPC definition is missing');
  const reportsSql=sql.slice(from,to);
  assert.match(reportsSql, /'points', case when v_loyalty_available[\s\S]*then 'business_wide_selected_period'[\s\S]*else 'unavailable_without_complete_loyalty_scope' end/);
  assert.match(reportsSql, /'credit_liability', case when v_credit_liability_available[\s\S]*else 'unavailable_without_complete_business_reports_and_sales_source_scope' end/);
  assert.match(reportsSql, /'gift_card_liability', case when v_gift_cards_available[\s\S]*else 'unavailable_without_complete_giftcards_scope' end/);
  assert.match(reportsSql, /'active_memberships', case when v_memberships_available[\s\S]*then 'business_wide_current'[\s\S]*else 'unavailable_without_complete_memberships_scope' end/);
  assert.doesNotMatch(reportsSql, /'liabilities',\s*'business_wide_current'/,
    'the removed one-size-fits-all liability scope must not return');
});

test('Reports loads only the answers the user opened', () => {
  const reports = section('async function reportsPage()', '/* ---------- get started');
  assert.match(reports,/Run report/);
  assert.match(reports,/const answerLoaders=\[/);
  assert.match(reports,/const runOpenAnswers=\(\)=>Promise\.all\(answerLoaders/);
  assert.match(reports,/\.filter\(\(\[id\]\)=>\$\(id\)\?\.open\)/);
  assert.doesNotMatch(reports,/runAll\(|Promise\.all\(\[runMoney\(\),runBusy\(\),runReturning\(\)\]\)/);
  assert.match(reports,/refreshBranchFilter\(\(\)=>\{invalidateAnswers\(\);runOpenAnswers\(\)/);

  const money=reports.slice(reports.indexOf('async function runMoney()'),reports.indexOf('const appointmentSummary='));
  assert.match(money,/get_reports_summary/);
  assert.doesNotMatch(money,/appointments|staff_hours|get_customer_lifecycle_v107/);
  const busy=reports.slice(reports.indexOf('async function runBusy()'),reports.indexOf('async function runReturning()'));
  assert.match(busy,/appointmentRows/);
  assert.doesNotMatch(busy,/get_reports_summary|get_customer_lifecycle_v107/);
  const returning=reports.slice(reports.indexOf('async function runReturning()'),reports.indexOf('const answerLoaders='));
  assert.match(returning,/get_customer_lifecycle_v107/);
  assert.doesNotMatch(returning,/get_reports_summary|appointmentRows|scheduledCapacityHours/);
});

test('Reports capacity subtracts the clipped overlap of cross-midnight staff blocks on every Singapore day', () => {
  const reports=section('async function reportsPage()', '/* ---------- get started');
  assert.match(reports,/const sgDayInstantOverlapMinutes=/);
  assert.match(reports,/filter\(block=>block\.staff_id===schedule\.staff_id\)[\s\S]*sgDayInstantOverlapMinutes\(day,block\.starts_at,block\.ends_at\)[\s\S]*filter\(Boolean\)/);
  assert.doesNotMatch(reports,/localStart\.toISOString\(\)\.slice\(0,10\)===day/,
    'overnight blocks must not be assigned only to their start day');
});

test('customer profile never converts inaccessible facets into plausible zero values', () => {
  const client = section('async function clientDetail(id)', '/* ---------- sales ---------- */');
  for (const module of ['sales','loyalty','retention','appointments','memberships','packages','referrals']) {
    assert.match(client, new RegExp(`confirmCompleteFacet\\('${module}'\\)`));
  }
  assert.match(client, /require_module_scope_v145/);
  assert.match(client, /No partial totals are shown/);
  assert.match(client, /Some profile figures are unavailable/);
  assert.match(client, /canReadSales\?`<div class="card kpi"/);
  assert.match(client, /loyaltyFactsAvailable\?`<div class="card kpi"/);
  assert.match(client, /canReadLoyalty\?`<section class="card c360-rewards-card" id="c360-loyalty"/);
  assert.match(client, /canReadRetention\?`<div class="card"><b>Retention reward history/);
  assert.match(client, /activitySources\.length\?/);
  assert.match(client, /Sales and reward figures are hidden because this role does not have access/);
  assert.match(client, /loadReversalWorkflows\(id,0\)/);
  assert.match(client, /fetchAllRowsResult\(\(\)=>sb\.from\('appointments'\)/);
  assert.match(client, /fetchAllRowsResult\(\(\)=>sb\.from\('memberships'\)/);
  assert.match(client, /staff_get_customer_actionable_loyalty_v145/);
  assert.match(client, /Loyalty balances and reward availability are temporarily unavailable/);
  assert.match(client, /Peekaa has not replaced them with zero/);
  assert.match(client, /id="c360LoyaltyRetry"/);
  assert.doesNotMatch(client, /from\('client_points_balance'\)|from\('client_credit_balance'\)|from\('points_batches'\)|from\('loyalty_rewards'\)/,
    'Customer 360 must not infer actionable loyalty facts from independent raw reads');
  assert.doesNotMatch(client, /pts>=r\.cost_points|prog\.redeem_points-pts|rwList/,
    'reward readiness must be the server projection, not browser arithmetic');
});

test('customer directory and CSV reuse one bounded actionable balance projection', () => {
  const customers=section('async function clientsPage()', 'async function clientDetail(id)');
  assert.match(customers,/const customerDirectoryPage=/);
  assert.match(customers,/const allCustomerDirectoryRows=async/);
  assert.match(customers,/while\(total===null\|\|offset<total\)/);
  assert.match(customers,/loyalty_available===true/);
  assert.match(customers,/Points and spendable credit are unavailable because complete Loyalty access could not be confirmed/);
  assert.match(customers,/No zero is inferred/);
  assert.doesNotMatch(customers,/from\('client_points_balance'\)|from\('client_credit_balance'\)/,
    'directory and CSV must not diverge from the V145 server projection');
});

test('customer profile proves owner-wide or every assigned staff branch without demanding admin scope from employees', () => {
  const client = section('async function clientDetail(id)', '/* ---------- sales ---------- */');
  assert.match(client, /const isProfileAdmin=S\.myRole==='owner'\|\|S\.myRole==='manager'/);
  assert.match(client, /profileScopeBranchIds=isProfileAdmin\?\[null\]:\[\]/);
  assert.match(client, /visibleBranchesForCurrentUser\(\)/);
  assert.match(client, /profileScopeBranchIds=\(branches\|\|\[\]\)\.map\(branch=>branch\.id\)/);
  assert.match(client, /Promise\.all\(profileScopeBranchIds\.map\(branchId=>[\s\S]*p_branch:branchId/);
  assert.match(client, /access across every branch assigned to this staff account/);
  assert.match(client, /Visible visits/);
  assert.match(client, /Visible sales total/);
  assert.match(client, /Business-wide points/);
  assert.match(client, /Business-wide spendable credit/);
  assert.match(client, /Staff view scope/);
  assert.match(client, /Sales, visits and appointments cover every branch assigned to this staff account/);
  assert.match(client, /Points, rewards and spendable credit are business-wide customer balances/);
  assert.match(client, /Peekaa does not mix hidden branch sales into the visible totals/);
  assert.match(client, /Business-wide balance, earning and next unlock/);
  assert.match(client, /id="c360ScopeRetry"/);
  assert.match(client, /if\(\$\('c360ScopeRetry'\)\)\$\('c360ScopeRetry'\)\.onclick=\(\)=>clientDetail\(id\)/);
  assert.doesNotMatch(client, /profileScopeLoadError\?'<button[^']*c360ScopeRetry/,
    'every unconfirmed facet state needs a retry, not only branch-list failures');
  assert.doesNotMatch(client, /require_module_scope_v145',\{p_business:S\.biz\.id,p_branch:null,p_module:module\}/,
    'employee facet checks must not be hard-coded to the admin-only null-branch scope');
});

test('optional Customer 360 reads fail locally without hiding verified profile facts', () => {
  const client = section('async function clientDetail(id)', '/* ---------- sales ---------- */');
  const fatalLine=client.match(/const facetQueryError=([^;]+);/)?.[1]||'';
  assert.doesNotMatch(fatalLine,/feedbackError|birthdayError|loyaltyProjectionError/);
  assert.match(client,/Feedback is temporarily unavailable\. The rest of this customer profile remains current/);
  assert.match(client,/Birthday benefit temporarily unavailable/);
  assert.match(client,/No birthday status is inferred/);
  assert.match(client,/Correction actions are temporarily unavailable/);
  assert.match(client,/Verified customer history and totals remain visible/);
  assert.match(client,/Reverse controls are withheld/);
  assert.match(client,/id="c360FeedbackRetry"[\s\S]{0,120}>Reload profile</);
  assert.match(client,/id="c360BirthdayRetry"[\s\S]{0,120}>Reload profile</);
  assert.match(client,/id="c360LoyaltyRetry"[\s\S]{0,120}>Reload profile</);
  assert.match(client,/if\(\$\('c360FeedbackRetry'\)\)\$\('c360FeedbackRetry'\)\.onclick=\(\)=>clientDetail\(id\)/);
  assert.match(client,/if\(\$\('c360BirthdayRetry'\)\)\$\('c360BirthdayRetry'\)\.onclick=\(\)=>clientDetail\(id\)/);
  assert.match(client,/if\(\$\('c360LoyaltyRetry'\)\)\$\('c360LoyaltyRetry'\)\.onclick=\(\)=>clientDetail\(id\)/);
  assert.doesNotMatch(client,/Sale and reward correction history could not be confirmed\. No partial totals are shown/);
});

test('gift-card surface describes issuance without implying that payment was collected', () => {
  const giftcards=section('async function giftcardsPage()', '/* ---------- appointments ---------- */');
  assert.match(giftcards,/Issue a gift card/);
  assert.match(giftcards,/Issue card and generate code/);
  assert.match(giftcards,/does not record or prove that payment was collected/);
  assert.match(giftcards,/issue_gift_card_at_branch_v117/);
  assert.match(giftcards,/Issue the first card from the transaction panel/);
  assert.doesNotMatch(giftcards,/Sell a gift card|Sell card and generate code|Sell the first card/);
});

test('read-only Expenses renders one access notice, not a duplicate banner', () => {
  const expenses=section('async function expensesPage()', '/* ---------- P&L ---------- */');
  assert.equal((expenses.match(/Read-only expenses access/g)||[]).length,1);
});

test('launch setup progress contains only persisted observable completion steps', () => {
  const setup = section('async function setupPage()', '/* ---------- staff performance ---------- */');
  assert.doesNotMatch(setup, /Share your booking page|done:true/);
  assert.match(setup, /from\('services'\)[\s\S]*eq\('active',true\)/);
  assert.match(setup, /from\('products'\)[\s\S]*eq\('active',true\)/);
  assert.match(setup, /configuration_status','published'/);
  assert.match(setup, /from\('staff'\)[\s\S]*eq\('active',true\)/);
  assert.match(setup, /done:\(sv\|\|\[\]\)\.length>0\|\|\(pr\|\|\[\]\)\.length>0/);
  assert.match(setup, /title:'Publish loyalty earning settings'/);
  assert.match(setup, /Add and publish reward milestones separately in Grow/,
    'an active programme without a reward must not be described as completed reward setup');
  assert.match(setup, /done:canReadModule\('loyalty'\)&&\(lp\|\|\[\]\)\.length>0/,
    'a paused or disabled Loyalty module must not be marked complete');
  assert.doesNotMatch(setup,/Points per dollar and a redeem threshold/);
  /* V170 owner decision (supersedes the V145 blanket rule for this ONE step): a solo
     owner-operator — the declared beachhead customer — could never reach full completion
     because "Add your team" only ticked at 2+ staff. An explicit, undoable
     "I run this on my own" is observable user intent, session-scoped because no server
     field exists for team size. Every other step must still be persisted and observable. */
  assert.match(setup, /done:soloOwner\|\|activeStaffCount>1/);
  assert.match(setup, /I run this on my own/);
  assert.doesNotMatch(setup, /setupTeamSkipped|Just me for now/);
  assert.match(setup, /done:\(cl\|\|\[\]\)\.length>0/);
  assert.match(app, /'Publish loyalty earning settings':'发布忠诚积分赚取设置'/);
  assert.match(app, /'Publish loyalty earning settings':'Terbitkan tetapan perolehan kesetiaan'/);
  assert.match(app, /'An active published earning programme is available\. Add and publish reward milestones separately in Grow\.':'已有一个生效且已发布的积分赚取方案。请在“增长”中另行添加并发布奖励里程碑。'/);
  assert.match(app, /'An active published earning programme is available\. Add and publish reward milestones separately in Grow\.':'Program perolehan aktif yang telah diterbitkan tersedia\. Tambah dan terbitkan pencapaian ganjaran secara berasingan dalam Grow\.'/);
  assert.match(setup, /Customer-linked eligible sales can earn loyalty when an active published programme applies\./);
  assert.doesNotMatch(setup, /Every sale you record for a customer earns loyalty automatically/);
  assert.match(app, /'Customer-linked eligible sales can earn loyalty when an active published programme applies\.':'当生效且已发布的忠诚方案适用时，关联顾客的合资格销售可赚取忠诚积分。'/);
  assert.match(app, /'Customer-linked eligible sales can earn loyalty when an active published programme applies\.':'Jualan layak yang dipautkan kepada pelanggan boleh memperoleh mata kesetiaan apabila program aktif yang diterbitkan terpakai\.'/);
});

test('loyalty automation copy is conditional on eligible sales and effective published programmes', () => {
  const customers=section('async function clientDetail(id)', '/* ---------- sales ---------- */');
  const sales=section('async function tillPage()', '/* ---------- sales ---------- */');
  const loyalty=section('async function loyaltyPage(', '/* ---------- referrals ---------- */');
  assert.match(sales,/applies points only when an active published loyalty programme makes it eligible/);
  assert.match(customers,/Record an eligible first purchase; points are earned only when an active published loyalty programme applies/);
  assert.match(loyalty,/workspaceTemplateHtmlV97\('classicEligibleEarning'/);
  assert.match(loyalty,/workspaceTemplateHtmlV97\('stampsEligibleEarning'/);
  assert.doesNotMatch(sales,/loyalty points and retention rewards fire automatically/);
  assert.doesNotMatch(customers,/start earning points and unlock loyalty automatically/);
  assert.doesNotMatch(loyalty,/Every sale earns points automatically|Customers collect stamps automatically as they spend/);
  for(const key of ['classicEligibleEarning','stampsEligibleEarning']){
    assert.match(app,new RegExp(`${key}:Object\\.freeze\\(\\{en:`));
  }
  assert.match(app, /'Record a sale — eligible customer-linked sales apply active published loyalty and retention rules':'记录销售 — 合资格且关联顾客的销售会应用生效且已发布的忠诚与回流规则'/);
  assert.match(app, /'Record a sale — eligible customer-linked sales apply active published loyalty and retention rules':'Rekod jualan — jualan layak yang dipautkan kepada pelanggan menggunakan peraturan kesetiaan dan pengekalan aktif yang diterbitkan'/);
  assert.match(app, /'Record an eligible first purchase; points are earned only when an active published loyalty programme applies\.':'记录一笔合资格的首次消费；只有在生效且已发布的忠诚方案适用时才会赚取积分。'/);
  assert.match(app, /'Record an eligible first purchase; points are earned only when an active published loyalty programme applies\.':'Rekod pembelian pertama yang layak; mata diperoleh hanya apabila program kesetiaan aktif yang diterbitkan terpakai\.'/);
});

test('existing referral, legacy sale and package paths never promise points while authority is off', () => {
  const customers=section('async function clientsPage()', 'async function clientDetail(id)');
  const till=section('async function tillPage()', '/* ---------- sales ---------- */');
  const referrals=section('async function referralsPage()', '/* ---------- memberships ---------- */');
  const packages=section('async function packagesPage()', 'async function branchesPage()');
  const receiptStart=app.indexOf('function legacySaleReceiptV145(');
  const receiptEnd=app.indexOf('\nfunction giftCardAbilitiesV102',receiptStart);
  assert.ok(receiptStart>=0&&receiptEnd>receiptStart,'legacy sale receipt truth helper is missing');
  const receipt=new Function(`${app.slice(receiptStart,receiptEnd)};return legacySaleReceiptV145`)();
  assert.deepEqual(receipt({pointsEarned:12,pointsTotal:112,duplicate:false}),{
    heading:'Done',message:'+12 points',pointsEarned:12,pointsTotal:112,duplicate:false
  });
  assert.deepEqual(receipt({pointsEarned:0,pointsTotal:100,duplicate:false}),{
    heading:'Done',message:'No points earned for this purchase.',pointsEarned:0,pointsTotal:null,duplicate:false
  });
  assert.deepEqual(receipt({pointsEarned:0,pointsTotal:100,duplicate:true}),{
    heading:'Already recorded',message:'This sale was already recorded — no extra points added.',pointsEarned:0,pointsTotal:null,duplicate:true
  });
  assert.match(till,/id="tConfirm"[\s\S]{0,180}Record sale<\/button>/);
  assert.match(till,/Sale recorded\. The screen is ready for the next customer\./);
  assert.match(till,/legacySaleReceiptV145\(doneInfo\)/);
  assert.doesNotMatch(till,/Save & add points|Points added\. The screen|pointsEarned\|\|0} points/);

  assert.match(customers,/referral linked — reward eligibility is checked at the first qualifying sale and requires an enabled referral programme/);
  assert.doesNotMatch(customers,/reward fires on their first qualifying sale/);
  assert.match(referrals,/const referralEnabled=p\?\.enabled===true/);
  assert.match(referrals,/Referral programme is Off\. Referral links are saved, but no reward is paid while it remains Off/);
  assert.match(referrals,/referralEnabled[\s\S]*workspaceTemplateHtmlV97\('referralEnabledOutcome'/);
  assert.doesNotMatch(referrals,/lands on the referrer's account automatically/);
  assert.match(app,/referralEnabledOutcome:Object\.freeze\(\{en:/);
  assert.match(app,/'Customer added \+ referral linked — reward eligibility is checked at the first qualifying sale and requires an enabled referral programme\.':'顾客已添加并关联推荐；系统会在首次合资格销售时检查奖励资格，且推荐计划必须已启用。'/);
  assert.match(app,/'Customer added \+ referral linked — reward eligibility is checked at the first qualifying sale and requires an enabled referral programme\.':'Pelanggan ditambah dan rujukan dipautkan — kelayakan ganjaran disemak pada jualan layak pertama dan memerlukan program rujukan yang diaktifkan\.'/);

  assert.match(till,/Package purchases are eligible for points once at purchase when an active published loyalty programme applies/);
  assert.match(packages,/Make package purchases eligible for loyalty points/);
  assert.match(packages,/points are earned only when an active published loyalty programme applies/);
  assert.match(packages,/Package purchases are now eligible for points; a sale still requires an active published loyalty programme/);
  assert.doesNotMatch(`${till}\n${packages}`,/Package purchases earn points once|Package purchases will earn points once|Award loyalty points when a package is purchased/);
  assert.match(app,/'Make package purchases eligible for loyalty points':'让配套购买符合忠诚积分资格'/);
  assert.match(app,/'Make package purchases eligible for loyalty points':'Jadikan pembelian pakej layak untuk mata kesetiaan'/);
});

test('public waitlist confirmation describes the existing manual queue and no automatic delivery', () => {
  const portal=section('async function renderPortal(slug)', 'async function boot()');
  assert.match(portal,/manual waitlist queue/);
  assert.match(portal,/business may contact you if a suitable spot opens; Peekaa does not send an automatic waitlist message/);
  assert.doesNotMatch(portal,/we'll message you the moment a spot opens|we'll be in touch as soon as a spot opens/);
});

test('manual booking requests state only persisted review status and never promise a response', () => {
  const portal=section('async function renderPortal(slug)', 'async function boot()');
  assert.match(portal,/This saves a request for manual review; the business may approve or reject it/);
  assert.match(portal,/Your booking request is saved for manual review/);
  assert.match(portal,/Use your private link to check the current status, or contact the business directly/);
  assert.match(portal,/Request saved for manual review — check the private link for its current status/);
  assert.match(portal,/biz\.booking_auto_confirm\?'Confirm booking':'Send booking request'/);
  assert.match(portal,/Request cancellation/);
  assert.match(portal,/Send a cancellation request\?/);
  assert.doesNotMatch(portal,/usually within a few hours|will confirm shortly|you'll hear back soon|the team will confirm/);
  assert.match(app,/'Your booking request is saved for manual review\.':'您的预订申请已保存，等待人工审核。'/);
  assert.match(app,/'Your booking request is saved for manual review\.':'Permintaan tempahan anda disimpan untuk semakan manual\.'/);
  assert.match(app,/'Request saved for manual review — check the private link for its current status\.':'申请已保存，等待人工审核 — 请通过私人链接查看当前状态。'/);
  assert.match(app,/'Request saved for manual review — check the private link for its current status\.':'Permintaan disimpan untuk semakan manual — semak status semasa melalui pautan peribadi\.'/);
});

test('report question cards issue one remote answer request per user action', () => {
  const reports=section('async function reportsPage()', '/* ---------- get started');
  assert.match(reports,/const scriptedAnswerToggles=new WeakSet\(\)/);
  assert.match(reports,/scriptedAnswerToggles\.add\(details\);details\.open=true/);
  assert.match(reports,/if\(scriptedAnswerToggles\.delete\(event\.currentTarget\)\)return/);
});

test('waitlist terminal booked rows are labelled as conversions, never proven seating', () => {
  const helperStart=app.indexOf('function waitlistTodaySummary(');
  const helperEnd=app.indexOf('\nasync function fetchAllRows(',helperStart);
  assert.ok(helperStart>=0&&helperEnd>helperStart,'waitlist summary helper is missing');
  const summarize=new Function(`${app.slice(helperStart,helperEnd)};return waitlistTodaySummary`)();
  const start=Date.parse('2026-08-03T00:00:00.000Z');
  const summary=summarize([
    {id:'seat-now',status:'booked',created_at:'2026-08-03T01:00:00.000Z'},
    {id:'future-appointment',status:'booked',created_at:'2026-08-03T02:00:00.000Z'},
    {id:'waiting',status:'waiting',created_at:'2026-08-03T03:00:00.000Z'}
  ],start);
  assert.equal(summary.bookedToday,2,'the shared terminal state cannot distinguish physical seating from future booking');
  const waitlist=section('async function waitlistPage(){','/* ---------- inventory ---------- */');
  assert.match(waitlist,/Resolved as booked today/);
  assert.match(waitlist,/Terminal booked rows added today; this does not prove physical seating/);
  assert.doesNotMatch(waitlist,/Seated today|<div class="l">Converted<\/div>/);
});

test('Grow rollback history has no silent twenty-version cap', () => {
  const retention = section('async function retentionPage(', '/* ---------- Grow: one customer journey');
  assert.match(retention, /fetchAllRowsResult\(\(\)=>sb\.from\('firm_config_versions'\)/);
  assert.match(retention, /select\('id,version_no,status,published_at,snapshot_hash',\{count:'exact'\}\)/);
  assert.doesNotMatch(retention, /status',\['published','superseded'\]\)[\s\S]{0,160}limit\(20\)/);
});

test('branch filter fails closed and never runs reports against an unconfirmed scope', () => {
  const branchFilter = section('async function refreshBranchFilter(', '/* ---------- dashboard ---------- */');
  assert.match(branchFilter, /Branch list unavailable/);
  assert.match(branchFilter, /const retry=wrap\.querySelector\('button'\)/);
  assert.match(branchFilter, /retry\.onclick=\(\)=>refreshBranchFilter\(onChange,isCurrent,targetId\)/);
  const catchStart=branchFilter.indexOf('catch(e)');
  const firstOnChange=branchFilter.indexOf('onChange();',catchStart);
  const catchReturn=branchFilter.indexOf('return;',catchStart);
  assert.ok(catchStart>=0&&catchReturn>catchStart&&(firstOnChange<0||catchReturn<firstOnChange),
    'branch-load failure must return before invoking a report callback');
});

test('report range validation is Gregorian, ordered and bounded', () => {
  const start=app.indexOf('function reportRangeValidation(');
  const end=app.indexOf('\nfunction ',start+10);
  assert.ok(start>=0&&end>start,'range validator is missing');
  const source=app.slice(start,end);
  assert.match(source,/REPORT_MAX_RANGE_DAYS/);
  assert.match(source,/days>maxDays/);
  assert.match(app,/const REPORT_MAX_RANGE_DAYS=1827/);
});

test('launch-incomplete Stored value is unreachable and Studio remains management-only', () => {
  const grow = section('async function growPage(', '/* ---------- Program Studio');
  assert.doesNotMatch(grow, /data-grow-open="storedvalue"/);
  const route = section('async function route()', '/* ---------- customer wallet ---------- */');
  assert.match(route, /if\(pageKey==='storedvalue'\)[\s\S]*Stored value is not available for launch/);
  const studio = section('async function studioPage(', '/* ---------------- Overview');
  assert.match(studio, /sessionStorage\.getItem\(reviewKey\)!=='1'/);
  assert.match(studio, /return nav\('#\/grow'\)/);
  assert.match(studio, /studioPublishReviewPage/);
  const publishGate = section('async function studioPublishReviewPage(', 'async function studioPage(');
  /* v170 product decision: owners were confirming blind, so the gate now DOES summarise the
     ordinary programme numbers (a BEFORE/AFTER of the loyalty_programs fields). The honesty
     assertion moves with it — the page must still disclaim the surfaces it does not diff
     (rewards, birthday, bring-back) instead of implying completeness. */
  assert.match(publishGate, /does not summarise reward, birthday or bring-back field values/);
  assert.match(publishGate, /What changes for customers/);
  assert.match(publishGate, /Reward and birthday changes are listed in their editors/);
  assert.match(publishGate, /No changes to earning or programme numbers in this draft/);
  assert.match(publishGate, /Could not load the comparison/);
  assert.match(publishGate, /Server-confirmed advanced-action safety/);
  assert.doesNotMatch(publishGate, /Confirm the exact existing reward and bring-back changes/);
  assert.doesNotMatch(app,/coming soon|not implemented|under construction|demo data|sample data/i,
    'deployable application source must not advertise placeholder behavior');
});

test('launch inbox exposes only preferences that affect the current in-app channel', () => {
  const inbox = section('async function renderCustomerInAppInbox(', 'async function renderCustomerNotificationPreferences(');
  assert.match(inbox, /Keep this reminder in my inbox/);
  assert.match(inbox, /Nothing changes until you select Save/);
  assert.match(inbox, /p_quiet_hours_timezone:null[\s\S]*p_quiet_hours_start:null[\s\S]*p_quiet_hours_end:null/);
  assert.match(inbox, /That reminder could not be saved\. Try again\./);
  assert.doesNotMatch(inbox, /customerInboxQuiet|Quiet hours are active|future interruptive channel|IANA timezone/,
    'launch UI must not show controls or claims that do not affect the current in-app delivery channel');
});

test('launch billing copy stays template-assisted and preserves the prospective no-refund policy', () => {
  const billing = section('async function loadBillingConfig()', '/* ---------- customer sign-up QR ---------- */');
  assert.match(billing, /Template-assisted promotion wording/);
  assert.match(billing, /does not use generative AI/);
  assert.doesNotMatch(billing, /AI-assisted promotion/,
    'the current deterministic wording helper must not be sold as generative AI');

  assert.equal(fs.existsSync(dbMigrationPath), true, 'V145 database migration must exist');
  const sql = fs.readFileSync(dbMigrationPath, 'utf8');
  assert.match(sql, /create or replace function public\.get_business_billing_v124[\s\S]*Promotions and template-assisted promotion wording/);
  assert.match(sql, /create or replace function public\.get_self_serve_checkout_v130[\s\S]*Promotions and template-assisted promotion wording/);
  assert.doesNotMatch(sql, /AI-assisted promotion/);
  assert.match(sql, /'money_back_days', case[\s\S]*legal_document_version < '2026-08-03' then 30[\s\S]*else null/);
  assert.match(sql, /'refund_policy', case[\s\S]*then 'legacy_30_day_request'[\s\S]*else 'non_refundable_after_payment'/);
  assert.doesNotMatch(sql, /'money_back_days',\s*30\s*,/,
    'V145 must not overwrite V144 with an unconditional money-back promise');
});

test('Grow hides the unfinished reward image storage control while preserving saved images', () => {
  const loyalty = section('async function loyaltyPage(', 'async function promotionsPage(');
  const editorStart=loyalty.indexOf('function openRewardEditor(reward)');
  const editorEnd=loyalty.indexOf('\n  async function saveReward',editorStart);
  const saveEnd=loyalty.indexOf('\n  const ra=',editorEnd);
  assert.ok(editorStart>=0&&editorEnd>editorStart&&saveEnd>editorEnd,
    'reward editor and save handler must remain identifiable');
  const editor=loyalty.slice(editorStart,saveEnd);
  assert.doesNotMatch(editor, /Image reference|Storage path or image URL|v27 storage contract|id="rwImage"/,
    'launch UI must not expose the incomplete low-level image storage workflow');
  assert.match(editor, /image_ref:editorReward\?\.image_ref\?\?null/,
    'saving an existing reward must preserve its stored image reference');
  const customerCatalog = section('async function renderCustomerWallet(', 'async function renderCustomerInAppInbox(');
  assert.match(customerCatalog, /r\.image_ref/,
    'already-published reward images must continue to render customer-side');
});

test('V145 database migration encodes valid-visit, scope and complete P&L contracts', () => {
  assert.equal(fs.existsSync(dbMigrationPath), true, 'V145 database migration must exist');
  const sql = fs.readFileSync(dbMigrationPath, 'utf8');
  assert.match(sql, /create or replace function public\.get_dashboard_summary/);
  assert.match(sql, /create or replace function public\.require_module_scope_v145/);
  assert.match(sql, /create or replace function public\.get_dashboard_summary[\s\S]*security definer/);
  assert.match(sql, /s\.reversal_of is null/);
  assert.match(sql, /not exists[\s\S]*r\.reversal_of = s\.id/);
  assert.match(sql, /'scope'/);
  assert.match(sql, /'expenses_by_category'/);
  assert.match(sql, /coalesce\(nullif\(btrim\(e\.category\), ''\), 'Uncategorised'\)/,
    'P&L must group null or blank expense categories without crashing or dropping their amounts');
  assert.match(sql, /'monthly'/);
  assert.match(sql, /at time zone 'Asia\/Singapore'/);
  assert.match(sql, /app\.require_branch_module_v94\(p_business, p_branch, 'reports', 'r'\)/);
  assert.match(sql, /app\.can_module_read_at_v94\(p_business, branch\.id, 'reports'\)/);
  assert.match(sql, /explicit_branch_required_for_partial_report_scope/);
  assert.match(sql, /app\.reports_gift_card_liability_v49b\([\s\S]*p_business, p_branch[\s\S]*\)/);
  assert.match(sql, /create or replace function app\.reports_gift_card_liability_v49b[\s\S]*app\.metric_module_scope_available_v145\(p_business, p_branch, 'reports'\)/);
  assert.match(sql, /app\.metric_module_scope_available_v145\(p_business, null, 'giftcards'\)/);
  assert.match(sql, /create or replace function public\.get_reports_summary[\s\S]*security definer[\s\S]*set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'/);
  assert.match(sql, /create or replace function app\.platform_metric_source_scope_available_v145/);
  assert.match(sql, /create or replace function public\.get_reports_summary[\s\S]*require_metric_module_scope_v145\([\s\S]*p_business, p_branch, 'reports'[\s\S]*platform_metric_source_scope_available_v145\([\s\S]*p_business, p_branch, 'sales'/,
    'Reports must fail closed when its Sales-derived platform source is disabled without requiring a Reports-only reader to access raw Sales');
  assert.match(sql, /create or replace function public\.get_revenue_summary[\s\S]*language plpgsql[\s\S]*stable[\s\S]*security definer/);
  assert.match(sql, /revoke all on function public\.get_dashboard_summary/);
  assert.match(sql, /revoke all on function public\.get_revenue_summary/);
  assert.match(sql, /report date range cannot exceed 1827 days/g);
  assert.match(sql, /perform app\.require_metric_module_scope_v145\(p_business, p_branch, 'pnl'\)/);
  assert.match(sql, /perform app\.require_metric_module_scope_v145\(p_business, p_branch, 'sales'\)/);
  assert.match(sql, /perform app\.require_metric_module_scope_v145\(p_business, p_branch, 'expenses'\)/);
  assert.match(sql, /create or replace function public\.list_customer_redemption_history_v145/);
  assert.match(sql, /create or replace function public\.staff_get_customer_actionable_loyalty_v145/);
  assert.match(sql, /create or replace function public\.staff_list_customers_v129/);
  assert.match(sql, /create or replace view public\.sale_commission[\s\S]*with \(security_invoker = on\)[\s\S]*sale\.counts_as_revenue/);
  assert.match(sql, /create or replace view public\.sale_commission[\s\S]*when sale\.commission_flat_cents is not null[\s\S]*end as commission_cents,[\s\S]*sale\.commission_flat_cents as flat_cents,[\s\S]*sale\.counts_as_revenue/,
    'V145 must preserve flat-over-percentage commission arithmetic and append revenue classification after the established view columns');
  assert.match(sql, /'loyalty_available', v_loyalty_available/);
  assert.match(sql, /create or replace function public\.get_dashboard_summary[\s\S]*v_loyalty_available := app\.metric_module_scope_available_v145\([\s\S]*p_business, p_branch, 'loyalty'[\s\S]*'points_issued', case when v_loyalty_available then/,
    'Dashboard points must be gated by the caller\'s complete effective Loyalty scope');
  assert.match(sql, /'availability', jsonb_build_object\([\s\S]*'loyalty', v_loyalty_available/);
  assert.match(sql, /when not v_loyalty_available then 'unavailable_without_complete_loyalty_scope'/);
  assert.match(sql, /when not v_program_enabled then 0::bigint/);
  assert.match(sql, /least\(coalesce\(points\.units, 0\), coalesce\(batches\.units, 0\)\)/);
  assert.match(sql, /greatest\(coalesce\(sum\(ledger\.amount_cents\), 0\), 0\)::bigint/);
  assert.match(sql, /greatest\(least\(ledger_balance\.units, batch_balance\.units\), 0\)/);
  assert.match(sql, /reward_version\.claim_available_from/);
  assert.match(sql, /usage\.used_count < reward_version\.usage_limit/);
  assert.match(sql, /not exists \([\s\S]*public\.loyalty_reward_branches restriction/);
  assert.match(sql, /app\.platform_feature_enabled\('customer_qr_redemption'\)/);
  assert.match(sql, /grant execute on function public\.staff_get_customer_actionable_loyalty_v145/);
  assert.match(sql, /create or replace function public\.staff_list_visit_feedback_v145/);
  assert.match(sql, /create or replace function public\.staff_list_gift_cards_v145/);
  assert.match(sql, /p_limit = 0 then null/);
  assert.match(sql, /'bounded'', v_limit is not null/);
  assert.match(sql, /create trigger trg_v145_config_publish_guard/);
  assert.match(sql, /create or replace function app\.v145_program_rule_pause_lift_guard[\s\S]*rule\.config_version_id = business\.active_config_version_id[\s\S]*rule\.active/);
  assert.match(sql, /create or replace function app\.reconcile_v145_incomplete_program_rule_pauses/);
  assert.match(sql, /'00000000-0000-0000-0000-000000000000'::uuid/,
    'migration-created safety pauses must use deterministic system provenance');
  assert.doesNotMatch(sql, /owner_staff\.user_id/,
    'migration reconciliation must not attribute a system action to an arbitrary owner');
  assert.match(sql, /'STUDIO_RULE_EMERGENCY_PAUSE'/);
  assert.match(sql, /'source','v145_launch_reconciliation'/);
  assert.match(sql, /revoke all on function app\.reconcile_v145_incomplete_program_rule_pauses\(\)/);
});

test('Studio labels migration-created pauses as Peekaa launch safety without changing owner provenance', () => {
  const studio = section('function studioActiveEmergencyPause(', 'function studioSetRuleActive(');
  assert.match(studio, /STUDIO_LAUNCH_SAFETY_ACTOR='00000000-0000-0000-0000-000000000000'/);
  assert.match(studio, /String\(actor\)===STUDIO_LAUNCH_SAFETY_ACTOR\?'Peekaa launch safety':String\(actor\)/);
  assert.match(app, /const pauseActor=studioEmergencyPauseActorLabel\(ep\?\.actor\)/);
  assert.match(app, /pauseActor\?`By \$\{esc\(pauseActor\)\}/,
    'non-system actors must continue to render through the same audited actor field');
});
