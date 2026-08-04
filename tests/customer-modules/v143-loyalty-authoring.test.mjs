import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');
const appSection=(source,start,end)=>source.slice(source.indexOf(start),source.indexOf(end,source.indexOf(start)));

test('reward editor starts from the complete active product economics projection but remains custom',async()=>{
  const app=await read('app/index.html');
  const loyalty=appSection(app,'async function loyaltyPage(','async function retentionPage(');
  assert.match(loyalty,/owner_list_reward_profitability_products_v122/);
  assert.match(loyalty,/Start from a product/);
  assert.match(loyalty,/Custom reward/);
  assert.match(loyalty,/Reward name customers see \*/);
  assert.match(loyalty,/sells for[\s\S]*company cost[\s\S]*All reward fields remain editable/);
  assert.match(loyalty,/\$\('rwCustomerName'\)\.value=product\.name/);
  assert.match(loyalty,/\$\('rwEstimate'\)\.value=companyCost==null\?'':/);
});

test('company give-up budget calculates a positive whole points price from displayed cost per point',async()=>{
  const app=await read('app/index.html');
  const loyalty=appSection(app,'async function loyaltyPage(','async function retentionPage(');
  assert.match(loyalty,/Company cost budget/);
  assert.match(loyalty,/Estimated company cost per point/);
  assert.match(loyalty,/const points=Math\.max\(1,Math\.ceil\(budget\/pointCost\)\)/);
  assert.match(loyalty,/estimatedPointCostCents=pointCostSamples\.length/);
  assert.match(loyalty,/reward_credit_cents\)\/Number\(p\.redeem_points\):1/);
});

test('recommended firm tiers are basis-aware, snapshot-chained and never auto-published',async()=>{
  const [app,migration]=await Promise.all([
    read('app/index.html'),read('db/migrations/20260802_nestly_v143_effective_reward_tier_boundaries.sql')
  ]);
  const loyalty=appSection(app,'async function loyaltyPage(','async function retentionPage(');
  for(const name of['Member','Plus','VIP'])assert.match(migration,new RegExp(`\\('${name}'`));
  assert.match(migration,/case when p_basis='visits' then 5 else 500 end/);
  assert.match(migration,/case when p_basis='visits' then 12 else 1500 end/);
  assert.match(loyalty,/id="trDefaults"/);
  assert.match(loyalty,/addRecommendedLoyaltyTiersV143/);
  assert.match(loyalty,/Recommended tiers added[\s\S]*Nothing was published/);
});

test('recommended tiers use one stable replay-safe server operation instead of three browser writes',async()=>{
  const [app,migration]=await Promise.all([
    read('app/index.html'),read('db/migrations/20260802_nestly_v143_effective_reward_tier_boundaries.sql')
  ]);
  const loyalty=appSection(app,'async function loyaltyPage(','async function retentionPage(');
  const defaultsHandler=appSection(loyalty,"const defaults=$('trDefaults');","const ta=$('trAdd');");
  assert.match(app,/async function addRecommendedLoyaltyTiersV143\(/);
  assert.match(defaultsHandler,/writeAttemptKey\(recommendedTierDefaultsSlot/);
  assert.match(defaultsHandler,/addRecommendedLoyaltyTiersV143\(/);
  assert.match(defaultsHandler,/clearWriteAttempt\(recommendedTierDefaultsSlot\)/);
  assert.doesNotMatch(defaultsHandler,/for\s*\([^)]*defaultTierTemplates/);
  assert.doesNotMatch(defaultsHandler,/crypto\.randomUUID\(\)/);
  assert.match(migration,/create table app\.loyalty_tier_default_operations_v143/);
  assert.match(migration,/unique\s*\(business_id,actor_id,idempotency_key\)/);
  assert.match(migration,/create or replace function public\.add_recommended_loyalty_tiers_v143/);
  assert.match(migration,/pg_advisory_xact_lock/);
  assert.match(migration,/status','existing_tiers'/);
  assert.match(migration,/grant execute on function public\.add_recommended_loyalty_tiers_v143[\s\S]*to authenticated/);
});

test('a later loyalty draft preserves V143 tier effective boundaries',async()=>{
  const migration=await read('db/migrations/20260802_nestly_v143_effective_reward_tier_boundaries.sql');
  const clone=migration.slice(
    migration.indexOf('create or replace function public.create_loyalty_config_draft'),
    migration.indexOf('create table app.loyalty_tier_default_operations_v143')
  );
  assert.match(clone,/perk_note,sort,active,effective_from,expires_at/);
  assert.match(clone,/perk_note,sort,active,effective_from,expires_at[\s\S]*from public\.loyalty_tier_versions/);
});

test('tier editor adds stable reward shortcuts and persists one visible benefit per line',async()=>{
  const [app,migration]=await Promise.all([
    read('app/index.html'),read('db/migrations/20260802_nestly_v143_effective_reward_tier_boundaries.sql')
  ]);
  const loyalty=appSection(app,'async function loyaltyPage(','async function retentionPage(');
  assert.match(loyalty,/Tier benefits/);
  assert.match(loyalty,/One customer benefit per line/);
  assert.match(loyalty,/class="btn ghost sm trBenefitReward" data-reward-id=/);
  assert.match(loyalty,/perk_note:String\(\$\('trBenefits'\)\.value/);
  assert.match(loyalty,/benefits\.map\(benefit=>`<li>/);
  assert.match(migration,/regexp_split_to_table\(coalesce\(v_current\.perk_note,''\),E'\\\\r\?\\\\n'\)/);
  assert.match(migration,/'benefits',coalesce/);
});

test('customer renderer consumes the structured current tier without object coercion',async()=>{
  const app=await read('app/index.html');
  assert.match(app,/const currentTierLabel=String\(tier\.current\?\.label\|\|tier\.current\|\|tier\.label\|\|''\)\.trim\(\)/);
  assert.match(app,/currentTierBenefits=Array\.isArray\(tier\.current\?\.benefits\)/);
  assert.match(app,/currentTierBenefits\.map\(benefit=>`<li>/);
  assert.doesNotMatch(app,/esc\(tier\.current\|\|tier\.label\)/);
});
