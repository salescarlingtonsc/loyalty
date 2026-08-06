import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const app=(fs.readFileSync(path.join(root,'app/index.html'),'utf8')+'\n'+fs.readFileSync(path.join(root,'app/app.js'),'utf8'));
const between=(start,end)=>app.slice(app.indexOf(start),app.indexOf(end,app.indexOf(start)));

test('every mapped module and literal control passes the V123 readiness inventory',()=>{
  const run=spawnSync(process.execPath,['scripts/quality/module-button-readiness.mjs','--strict'],{cwd:root,encoding:'utf8'});
  assert.equal(run.status,0,run.stdout+run.stderr);
  const report=JSON.parse(run.stdout);
  // Module counts stay exact: gaining or losing a module surface is a decision worth noticing.
  // (Products/Inventory returning to the business rail in V184 is part of the move from 25.)
  assert.equal(report.business.expected,27);
  assert.equal(report.platform.expected,12);
  // The raw button count is a floor, not an equality. It moves on nearly every UI edit and an
  // exact number produced churn without signal; --strict above already fails on any unwired,
  // unlabeled, hidden-route or non-semantic control, which is the property that matters.
  assert.ok(report.controls.buttons>=296,`button count fell to ${report.controls.buttons}`);
  assert.deepEqual(report.controls.hiddenRouteTargets,[]);
  assert.deepEqual(report.controls.nonSemanticClickTargets,[]);
});

test('Get started uses active catalogue records without advertising the unavailable Inventory surface',()=>{
  const setup=between('async function setupPage(){','/* ---------- staff performance');
  assert.doesNotMatch(setup,/S\.biz\.enabled_modules|from\('service_products'\)|#\/inventory|usesInventory/);
  assert.match(setup,/from\('products'\)[\s\S]*eq\('active',true\)/);
  assert.match(setup,/Add your services or products/);
});

test('all application clipboard actions use one honest recoverable helper',()=>{
  const helper=between('async function copyTextToClipboard','function killCharts');
  assert.match(helper,/navigator\.clipboard\?\.writeText/);
  assert.match(helper,/await navigator\.clipboard\.writeText/);
  assert.match(helper,/catch/);
  assert.match(helper,/button\.disabled=true/);
  assert.equal((app.match(/navigator\.clipboard\.writeText/g)||[]).length,1);
  // 1 definition + 8 call sites. The count is a floor-with-teeth: the single
  // navigator.clipboard.writeText above already proves nothing bypasses the helper, so this
  // only has to keep pace as copy surfaces are added (v151 invite links added one).
  assert.ok((app.match(/copyTextToClipboard\(/g)||[]).length>=9,'every remaining copy surface must use the shared helper');
  for(const id of ['copyRef','cp','cpJoin','copyManage'])assert.match(app,new RegExp(`id="${id}"`));
  assert.match(app,/\$\('cp'\)\.onclick=async\(\)=>copyTextToClipboard/);
});

test('staff performance drill-down is a semantic keyboard link',()=>{
  const staff=between('async function staffPerfPage','async function staffPerfDrill');
  assert.doesNotMatch(staff,/<tr[^>]*onclick=/);
  assert.doesNotMatch(staff,/click a row/i);
  // The separate "select a staff name" instruction is gone because the staff NAME is now the
  // link itself — the affordance is the control, so prose explaining it is redundant. Assert
  // that stronger property directly instead of the wording.
  assert.match(staff,/<a[^>]+href="#\/staffperf\/\$\{[\s\S]{0,120}<b>\$\{[^}]*names\[k\]/,
    'the staff name itself must be the keyboard-reachable drill-down link');
});

test('bundle creation uses one replay-safe server writer and disables the initiating control',()=>{
  const services=between('async function servicesPage','/* ---------- loyalty');
  assert.match(services,/sb\.rpc\('create_service_bundle_v123'/);
  assert.doesNotMatch(services,/from\('bundles'\)\.insert/);
  // The raw disabled=true/false pair moved to the shared CUI.setButtonBusy helper, which sets
  // button.disabled and aria-busy and restores both on busy:false. The invariant under test —
  // the initiating control is disabled for the duration and re-enabled only if still mounted —
  // is unchanged; only the mechanism is now shared.
  assert.match(services,/CUI\.setButtonBusy\(badd3,\{busy:true/);
  assert.match(services,/if\(badd3\.isConnected\)CUI\.setButtonBusy\(badd3,\{busy:false\}\)/);
});

test('V123 bundle migration removes direct write authority and makes one atomic keyed write',()=>{
  const migration=fs.readFileSync(path.join(root,'db/migrations/20260731_nestly_v123_module_button_readiness.sql'),'utf8');
  assert.match(migration,/revoke insert,update,delete,truncate on table public\.bundles/);
  assert.match(migration,/create or replace function public\.create_service_bundle_v123/);
  assert.match(migration,/app\.can_module_write\(p_business,'services'\)/);
  assert.match(migration,/pg_advisory_xact_lock/);
  assert.match(migration,/idempotency key reused with a different bundle/);
  assert.match(migration,/insert into public\.bundles/);
  assert.match(migration,/insert into public\.bundle_items/);
  assert.match(migration,/grant execute on function public\.create_service_bundle_v123/);
});

test('daily and P&L reports invalidate stale exports and reject obsolete responses',()=>{
  const daily=between('async function dailyReportPage','async function pnlPage');
  const pnl=between('async function pnlPage','/* ---------- settings');
  for(const source of [daily,pnl]){
    assert.match(source,/createReportRequestGate/);
    assert.match(source,/\.onchange=.*invalidate/);
    assert.match(source,/\.disabled=true/);
  }
  assert.match(app,/@media\(max-width:767px\)\{[\s\S]*\.topbar>\.row\{min-width:0;max-width:100%;flex-wrap:wrap\}/);
  assert.match(app,/@media\(max-width:960px\)\{[\s\S]*\.charts,\.split\{grid-template-columns:1fr\}/);
  assert.match(app,/\.split>\*\{min-width:0;max-width:100%\}/);
  assert.match(app,/#slist\{min-width:0;max-width:100%;overflow-x:auto/);
});

test('report scope change during a pending request restores the primary action for retry',()=>{
  const helperSource=between('function createLatestRequestGate','function nav(h)');
  const makeGate=new Function(`${helperSource}; return createReportRequestGate;`)();
  let current=true;
  const runButton={disabled:false,isConnected:true};
  const gate=makeGate(()=>current,()=>runButton);

  const firstIsLatest=gate.begin();
  assert.equal(runButton.disabled,true,'a pending request disables its primary action');
  assert.equal(firstIsLatest(),true);

  assert.equal(gate.invalidate(),true,'the current report accepts the scope invalidation');
  assert.equal(runButton.disabled,false,'scope change restores Generate/Run immediately');
  assert.equal(firstIsLatest(),false,'the pending response is now stale');

  const retryIsLatest=gate.begin();
  assert.equal(runButton.disabled,true,'the user can start a fresh request');
  assert.equal(retryIsLatest(),true,'the retry owns the latest generation');
  runButton.disabled=false;
  assert.equal(runButton.disabled,false,'a successful retry can restore the action');

  current=false;runButton.disabled=true;
  assert.equal(gate.invalidate(),false,'a detached route is not mutated');
  assert.equal(runButton.disabled,true,'a detached route button is left untouched');
});

test('report request rejection renders a current-route retry and every P&L export includes scope and KPIs',()=>{
  const helperSource=between('function createLatestRequestGate','function nav(h)');
  const setRetry=new Function(`${helperSource}; return setReportRetryState;`)();
  let current=true,retries=0,html='';
  const retryButton={onclick:null};
  const runButton={disabled:true,isConnected:true};
  const body={isConnected:true,querySelector:selector=>selector==='#reportRetry'?retryButton:null};
  Object.defineProperty(body,'innerHTML',{set:value=>{html=value},get:()=>html});

  assert.equal(setRetry(()=>current,runButton,body,'Report could not be loaded.','reportRetry',()=>{retries+=1}),true);
  assert.equal(runButton.disabled,false);
  assert.match(html,/Report could not be loaded\./);
  assert.equal(typeof retryButton.onclick,'function');
  retryButton.onclick();assert.equal(retries,1);
  current=false;runButton.disabled=true;html='unchanged';
  assert.equal(setRetry(()=>current,runButton,body,'obsolete','reportRetry',()=>{}),false);
  assert.equal(html,'unchanged');assert.equal(runButton.disabled,true);

  const daily=between('async function dailyReportPage','async function pnlPage');
  const pnl=between('async function pnlPage','/* ---------- settings');
  assert.match(daily,/Daily report could not be generated\.[\s\S]*drRetry/);
  assert.match(pnl,/P&L summary could not be loaded\./);
  assert.match(pnl,/try\{\s*summaryResult=await sb\.rpc/);
  assert.doesNotMatch(pnl,/sb\.from\('expenses'\)|sb\.from\('sales'\)/);
  assert.match(pnl,/sum\.expenses_by_category/);
  assert.match(pnl,/sum\.monthly/);
  for(const row of ['cash_basis_revenue_earned_and_settled','revenue_accrual'])assert.match(pnl,new RegExp(`'summary','${row}'`));
  assert.match(pnl,/'summary',lastSummary\.branchSpecific\?'selected_branch_expenses_business_overhead_excluded':'all_business_expenses'/);
  assert.match(pnl,/'summary',lastSummary\.branchSpecific\?'cash_basis_revenue_less_selected_branch_expenses':'cash_basis_revenue_less_all_business_expenses'/);
  assert.match(pnl,/\['scope','from'/);
  assert.match(pnl,/csvRows\(rows\)/);
});
