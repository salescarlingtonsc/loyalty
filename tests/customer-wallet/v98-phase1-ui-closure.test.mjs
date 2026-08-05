import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const app=await readFile(new URL('../../app/index.html',import.meta.url),'utf8');
const between=(start,end)=>{
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0&&to>from,`missing section ${start}`);
  return app.slice(from,to);
};

test('campaign UI distinguishes reward entitlement, actual receipt, and observed returns',()=>{
  const campaigns=between('/* ---------- Bring-back playbooks','/* ---------- referrals ---------- */');
  for(const phrase of [
    'reward entitlement','customer history','merchant fulfilment','observed return',
    'Measurement not started','manual receipt confirmation','Descriptive only'
  ])assert.match(campaigns,new RegExp(phrase,'i'));
  for(const misleading of [
    /offers? sent/i,/reward sent/i,/brought back/i,/extra customers?/i,/extra sales/i,
    /more came back/i,/proves? how many/i,/prove the lift/i
  ])assert.doesNotMatch(campaigns,misleading);
  assert.match(campaigns,/it is not a provider delivery receipt/i);
});

test('campaign results consume v99 descriptive fields and withdraw superseded v50 assumptions',()=>{
  const results=between('function pbResultsHtml','async function pbRecordReturns');
  for(const field of [
    'campaign_status','measurement_status','grant_records','verified_exposures',
    'legacy_or_unverified_grants','measurement_started_at','measurement_ends_at',
    'minimum_sample_per_arm','observed_return_rate_difference_bps','measurement_note'
  ])assert.match(results,new RegExp(field));
  for(const superseded of [
    /r\.status\b/,/offers_issued/,/attribution_ends_at/,/exposure_verified/,
    /statistical_evidence_verified/,/statistically_significant/,/net_lift_bps/,
    /incremental_returns/,/incremental_revenue_cents/,/grant_cost_cents/
  ])assert.doesNotMatch(results,superseded);
  assert.match(results,/No lift, ROI, delivery, or statistical-significance claim is made/);
  assert.match(results,/hasWindow&&\['active','completed'\]\.includes\(campaignStatus\)/);
});

test('staff mobile shell keeps permitted daily jobs in a persistent bottom dock',()=>{
  const shell=between('function staffMobileActionsHtml','/* Global action cluster');
  assert.match(shell,/canReadModule\('till'\).*canReadModule\('clients'\).*hasRoleCapability\('create_sales'\)/s);
  assert.match(shell,/canScanRedemption=canScanCustomerRedemption\(\{[\s\S]*loyaltyWritable:canWriteModule\('loyalty'\)/);
  assert.match(shell,/canViewAppts=canReadModule\('appointments'\)/);
  for(const id of ['staffMobileQuickEarn','staffMobileScan','staffMobileAppointments','staffMobileMore']){
    assert.match(shell,new RegExp(`id="${id}"`));
  }
  assert.match(shell,/navHtml\(page,'mobile-nav'\)/);
  assert.match(app,/\.staff-mobile-dock\{position:fixed;left:0;right:0;bottom:0/);
  assert.match(app,/@media\(max-width:960px\)[\s\S]*\.global-quick\{display:none\}/);
  assert.match(app,/pendingTillRedemptionScan=true/);
  assert.match(app,/if\(canScanRedemption\(\)\)requestAnimationFrame/);
  assert.match(app,/\$\('tScanRedemption'\)\?\.click\(\)/);
});

test('mobile navigation controls unique drawers and does not reset window scroll',()=>{
  const navigation=between('function navHtml','/* Global action cluster');
  assert.match(navigation,/function navHtml\(page,idPrefix='nav'\)/);
  assert.match(navigation,/aria-controls="\$\{idPrefix\}-\$\{g\.key\}"/);
  assert.match(navigation,/document\.getElementById\(el\.getAttribute\('aria-controls'\)\)/);
  assert.doesNotMatch(navigation,/scrollTo\(0|location\.reload/);
  const render=between('function renderShell','const M=');
  assert.match(render,/priorWindowX=window\.scrollX,priorWindowY=window\.scrollY/);
  assert.match(render,/window\.scrollTo\(priorWindowX,Math\.min\(priorWindowY,maxY\)\)/);
});

test('customer home keeps a healthy server-ranked card primary and otherwise uses finite fallback guidance',()=>{
  const home=between('function customerHomeNextActionMarkup','async function renderCustomerWallet');
  assert.match(home,/const primary=actionableCards\[0\]/);
  assert.match(home,/customerHomeNextActionMarkup\(primary\)/);
  assert.match(home,/customerHomeFallbackActionV167/);
  assert.match(home,/Next best action/);
  assert.match(home,/actionableWalletActionText\(card\)/);
  assert.match(home,/return ''/);
  assert.match(home,/href="#\/wallet\/\$\{slug\}"/);
  assert.doesNotMatch(home,/data-workspace-i18n|workspaceLocale/,
    'customer surfaces remain English-only and outside workspace localisation');
});

test('new staff-facing labels have reviewed Chinese and Malay translations',()=>{
  const curated=between('const WORKSPACE_COPY_V97=','const WORKSPACE_GENERATED_COPY_V97=');
  for(const source of ['Scan QR','More','Reward entitlements','Measurement not started','Prepare rewards']){
    const escaped=source.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
    const matches=[...curated.matchAll(new RegExp(`'${escaped}':'([^']+)'`,'g'))];
    assert.equal(matches.length,2,`${source} must have zh-CN and ms translations`);
    assert.ok(matches.every(match=>match[1]!==source));
  }
});
