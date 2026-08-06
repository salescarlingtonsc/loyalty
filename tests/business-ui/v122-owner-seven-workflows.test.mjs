import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const app=(readFileSync(new URL('../../app/index.html',import.meta.url),'utf8')+'\n'+readFileSync(new URL('../../app/app.js',import.meta.url),'utf8'));
const migration=readFileSync(new URL(
  '../../supabase/migrations/20260731140000_nestly_v122_owner_seven_workflows.sql',
  import.meta.url
),'utf8');

function section(start,end){
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0,`missing section start: ${start}`);
  assert.ok(to>from,`missing section end: ${end}`);
  return app.slice(from,to);
}

function declaredFunction(name){
  const start=app.indexOf(`function ${name}(`);
  assert.ok(start>=0,`missing function ${name}`);
  const parameterStart=app.indexOf('(',start);
  let parameterDepth=0,bodyStart=-1;
  for(let i=parameterStart;i<app.length;i++){
    if(app[i]==='(')parameterDepth++;
    else if(app[i]===')'&&--parameterDepth===0){
      bodyStart=app.indexOf('{',i+1);break;
    }
  }
  let depth=0;
  for(let i=bodyStart;i<app.length;i++){
    if(app[i]==='{')depth++;
    else if(app[i]==='}'&&--depth===0)return app.slice(start,i+1);
  }
  throw new Error(`unterminated function ${name}`);
}

test('Quick Earn contains no gift-card issue or redemption controls',()=>{
  const till=section('async function tillPage(){','async function salesPage(){');
  assert.doesNotMatch(till,/tGiftAdd|tGiftRedeem|issue_gift_card_at_branch_v117|redeem_gift_card_at_branch_v117/);
  assert.doesNotMatch(till,/type:'giftcard'/);
  assert.match(app,/async function giftcardsPage\(/,
    'gift cards remain available in their dedicated workspace');
});

test('two named staff calendars support contextual click-to-book and persist manual assignment',()=>{
  const appointments=section('async function appointmentsPage(){','/* ---------- waitlist');
  assert.match(appointments,/branchStaff\(branchId\)/);
  assert.match(appointments,/data-staff="\$\{column\.id\}"/);
  assert.match(appointments,/openNewAppointmentForm\(\{[\s\S]*staffId:button\.dataset\.staff/);
  assert.match(appointments,/p_requested_staff:assignment==='auto'\?null:assignment/);
  assert.match(appointments,/p_assignment_mode:assignment==='auto'\?'round_robin':'manual'/);
  assert.match(appointments,/book_appointment_smart_v47/);
  assert.match(app,/\.appointment-layout,.appointment-layout\.form-open\{grid-template-columns:minmax\(0,1fr\)\}/);
  assert.match(app,/\.appointment-form-card\{position:sticky;top:82px;min-width:0;width:100%;max-width:100%\}/,
    'the click-to-book form must not expand the 390px workspace');
});

test('owner rewards overview explains ordered milestones and configured birthday benefit',()=>{
  assert.match(app,/function ownerRewardJourneyV122\(/);
  const grow=section('async function growPage(','/* ---------- Bring-back playbooks');
  assert.match(grow,/Rewards overview/);
  assert.match(grow,/data-reward-milestone/);
  assert.match(grow,/birthday benefit/i);
  assert.doesNotMatch(grow,/href="#\/inventory"/,
    'Inventory is intentionally hidden, so Grow must not link to a dead route');
});

test('product cost produces plain-language margin and safe reward budget guidance',()=>{
  assert.match(migration,/alter table public\.products[\s\S]*add column cost_cents bigint/);
  assert.match(migration,/owner_list_reward_profitability_products_v122/);
  assert.match(migration,/owner_set_product_cost_v122/);
  assert.match(migration,/staff_row\.role='owner'[\s\S]*app\.can_module_write\(p_business,'loyalty'\)/);
  assert.match(migration,/revoke all on function public\.owner_set_product_cost_v122\(uuid,uuid,bigint,bigint\)[\s\S]*grant execute[\s\S]*to authenticated/);
  const source=declaredFunction('productProfitabilityV122');
  const calculate=vm.runInNewContext(`(()=>{${source};return productProfitabilityV122})()`);
  assert.deepEqual(JSON.parse(JSON.stringify(calculate({priceCents:6800,costCents:2400,rewardCostCents:1200}))),{
    priceCents:6800,costCents:2400,grossProfitCents:4400,marginPct:64.7,
    rewardCostCents:1200,profitAfterRewardCents:3200,profitableAfterReward:true
  });
  const inventory=section('async function inventoryPage(){','/* ---------- packages ---------- */');
  assert.match(inventory,/Product cost/);
  assert.match(inventory,/Gross profit/);
  assert.match(inventory,/cost_cents/);
  const grow=section('async function growPage(','/* ---------- Bring-back playbooks');
  assert.match(grow,/data-product-cost-save/);
  assert.match(grow,/owner_set_product_cost_v122/);
  assert.match(grow,/canWriteModule\('loyalty'\)/);
  assert.doesNotMatch(grow,/canWriteModule\('inventory'\)/);
  assert.match(grow,/data-reward-cost-use/);
  assert.match(grow,/data-profit-after-reward/);
  assert.match(grow,/profitAfterRewardCents/);
  assert.match(grow,/pendingRewardEstimateCents/);
  assert.match(grow,/const applyPendingRewardEstimate=\(\)=>/);
  assert.match(grow,/if\(activeSurface===surface\)\{[\s\S]*applyPendingRewardEstimate\(\);[\s\S]*return;/);
  assert.match(grow,/applyPendingRewardEstimate\(\);[\s\S]*document\.querySelectorAll\('\[data-grow-open\]'/);
});

test('customer programmes are grouped by stable business categories without self-linking',()=>{
  const source=declaredFunction('customerBusinessCategoryV122');
  const categorize=vm.runInNewContext(`(()=>{${source};return customerBusinessCategoryV122})()`);
  assert.equal(categorize('Facial spa'),'Personal care');
  assert.equal(categorize('Cafe'),'Food & drink');
  assert.equal(categorize('Pilates studio'),'Fitness');
  assert.equal(categorize('Unmapped trade'),'Other');
  const grid=declaredFunction('customerProgrammeGridMarkupV96');
  assert.match(grid,/customerBusinessCategoryV122/);
  assert.match(grid,/customer-programme-category/);
  assert.doesNotMatch(grid,/\.insert|customer_links/i);
});

test('feedback emits a staff refresh signal and public-review access is score independent',()=>{
  assert.match(migration,/feedback_new/);
  assert.match(migration,/visit_feedback_v122_notify_staff/);
  assert.match(app,/feedback_new:'#\/customers'/);
  const feedback=section('  const loadFeedback=async(opts={})=>{','  await Promise.all([');
  assert.match(feedback,/loadFeedback\(\{highlightShare:true\}\)/);
  assert.doesNotMatch(feedback,/rating>=4|rating===5/);
  assert.match(feedback,/Leave a public review/);
});

test('promotion alerts are explicit-consent, deduplicated, and customer popups are dismissible',()=>{
  assert.match(migration,/promotion_alerts/);
  assert.match(migration,/v122_promotion_new/);
  assert.match(migration,/v122_promotion_expiry/);
  assert.match(migration,/on conflict\(identity_id,dedupe_key\) do nothing/);
  assert.match(migration,/create table public\.promotion_alert_runs_v122/);
  assert.match(migration,/primary key\(promotion_id,source_kind,source_version\)/);
  assert.match(migration,/not exists\([\s\S]*promotion_alert_runs_v122/);
  assert.match(migration,/customer_notification_preferences[\s\S]*opted_in/);
  assert.match(migration,/content\.branch_id is null/);
  assert.match(migration,/content\.starts_at is null or content\.starts_at<=now\(\)/);
  assert.match(migration,/business_media_assets_v95[\s\S]*customer_visible/);
  assert.match(migration,/enqueue_due_promotion_alerts_v122/);
  assert.match(migration,/'\*\/15 \* \* \* \*'/);
  assert.match(migration,/customer_get_pending_promotion_prompt_v122/);
  assert.match(migration,/state\.read_at is null and state\.dismissed_at is null/);
  assert.match(migration,/customer_notification_preferences preference[\s\S]*preference\.topic='promotion_alerts'[\s\S]*preference\.opted_in/);
  assert.match(migration,/preserve_current_promotion_event_v122/);
  assert.match(migration,/case when p_source_kind='v122_promotion_expiry'[\s\S]*jsonb_build_object\('ends_at',v_content\.ends_at\)[\s\S]*else '\{\}'::jsonb end/);
  assert.match(app,/function showCustomerPromotionPopupV122\(/);
  assert.match(app,/Promotion alerts/);
  assert.match(app,/data-promotion-popup-dismiss/);
  const popup=declaredFunction('showCustomerPromotionPopupV122');
  assert.match(popup,/prompt\.event_id/);
  assert.match(popup,/customer_set_in_app_inbox_state/);
  assert.doesNotMatch(popup,/sessionStorage|items\[0\]/);
  const wallet=section('async function renderCustomerWallet(','async function renderCustomerInAppInbox');
  assert.match(wallet,/customer_get_pending_promotion_prompt_v122/);
  assert.match(wallet,/prompt:promotionPromptResult\.error\?null:promotionPromptResult\.data/);
});
