import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const app=((await readFile(new URL('../../app/index.html',import.meta.url),'utf8'))+'\n'+(await readFile(new URL('../../app/app.js',import.meta.url),'utf8')));
const sql=await readFile(new URL('../../supabase/migrations/20260805040828_nestly_v167_customer_retention_offers.sql',import.meta.url),'utf8');

test('Home offers use one bounded verified-link RPC without caller ownership ids',()=>{
  const customerReader=sql.slice(
    sql.indexOf('create or replace function public.customer_get_home_offers_v167'),
    sql.indexOf('create or replace function public.business_get_visible_promotion_count_v167')
  );
  assert.match(sql,/create or replace function public\.customer_get_home_offers_v167\(\s*p_locale text default 'en'/);
  assert.match(sql,/v_actor uuid := auth\.uid\(\)/);
  assert.match(sql,/from app\.v32_customer_wallet_context\(null\) context/);
  assert.doesNotMatch(customerReader,/p_customer|p_identity|p_business/);
  assert.match(sql,/item_rank<=12/);
  assert.match(sql,/'limit',12/);
  assert.match(sql,/intent\.identity_id=v_identity[\s\S]*intent\.auth_user_id=v_actor[\s\S]*intent\.status='pending'[\s\S]*intent\.expires_at>statement_timestamp\(\)/);
  assert.match(sql,/content\.active[\s\S]*content\.starts_at<=statement_timestamp\(\)[\s\S]*content\.ends_at>statement_timestamp\(\)/);
  assert.match(sql,/asset\.customer_visible/);
  assert.match(sql,/public\.promotion_branch_scopes_v155 mapped/);
  assert.match(sql,/coalesce\(active_branch\.active,true\)/);
  assert.doesNotMatch(sql,/metadata#>'\{branch_scope,branch_ids\}'/);
  assert.match(sql,/revoke all on function public\.customer_get_home_offers_v167\(text\) from public,anon/);
  assert.match(sql,/set search_path to 'pg_catalog','public','app','pg_temp'/);
});

test('customer Home always renders populated, empty, and retryable offer states',()=>{
  const walletRender=app.slice(app.indexOf('async function renderCustomerWallet'),app.indexOf('async function renderCustomerInAppInbox'));
  assert.match(app,/function customerHomeOffersMarkupV167/);
  assert.match(app,/Limited offers/);
  assert.doesNotMatch(app,/Offers for you/);
  assert.match(app,/No offers right now\. New offers from your businesses appear here first\./);
  assert.match(app,/Offers couldn’t load\./);
  assert.match(app,/id="customerOffersRetry"/);
  // v178: the only remaining offers-shelf fetch is Home's, through the timeout-guarded customerRpc.
  assert.match(app,/customerRpc\('customer_get_home_offers_v167',\{p_locale:merchantCopyLocale\(\)\}\)/);
  assert.match(app,/customer-home-offers-track/);
  assert.match(app,/Ends soon/);
  assert.match(app,/if\(!cards\.length\)\{[\s\S]*customerHomeOffersMarkupV167\(offersState\)[\s\S]*customer-first-quest/);
  assert.doesNotMatch(walletRender,/customer_get_actionable_wallet'\);[\s\S]{0,180}if\(error\)return renderCustomerWalletRetry/);
  assert.match(app,/if\(!error&&Array\.isArray\(data\?\.cards\)&&data\.cards\.length\)/);
  /* v322 (A7): the same pair of reads, except a silent tick already asked the first question and
     hands its answer down rather than asking twice. */
  assert.match(walletRender,/if\(businessSlug\)\{\s*const \[\{data,error\},walletResult\]=await Promise\.all\(\[\s*probeCardV322\?Promise\.resolve\(\{data:probeCardV322,error:null\}\)\s*:customerRpc\('customer_get_actionable_business'/);
});

test('new-offer state is versioned, device-local, bounded, and malformed-storage safe',()=>{
  assert.match(app,/CUSTOMER_SEEN_OFFERS_KEY_V167='peekaa\.customer\.offers\.seen\.v1'/);
  assert.match(app,/JSON\.parse\(localStorage\.getItem\(CUSTOMER_SEEN_OFFERS_KEY_V167\)\|\|'\[\]'\)/);
  assert.match(app,/catch\{return new Set\(\)\}/);
  assert.match(app,/\.slice\(-200\)/);
  assert.match(sql,/'version_id',bounded\.id::text\|\|':'\|\|bounded\.version::text/);
  assert.doesNotMatch(app,/CUSTOMER_SEEN_OFFERS_KEY_V167[\s\S]{0,500}customer_id|CUSTOMER_SEEN_OFFERS_KEY_V167[\s\S]{0,500}email/);
});

test('programme offer section remains present for populated, empty, and error states',()=>{
  assert.match(app,/function customerProgrammeOffersMarkupV167/);
  assert.match(app,/data-programme-offers-retry/);
  assert.match(app,/No offers right now\. New offers from this business appear here first\./);
  assert.match(app,/const programmeOffersStatus=promotionsResult\.error\?'error':'ready'/);
  assert.match(app,/offersStatus:programmeOffersStatus/);
});

test('merchant warning uses the same current visibility conditions instead of a raw active count',()=>{
  assert.match(sql,/create or replace function public\.business_get_visible_promotion_count_v167/);
  assert.match(sql,/if not app\.is_salon_owner\(p_business\)/);
  assert.match(sql,/content\.active[\s\S]*content\.starts_at<=statement_timestamp\(\)[\s\S]*content\.ends_at>statement_timestamp\(\)[\s\S]*asset\.customer_visible/);
  // Reworded to plainer English; the warning still fires off the v167 visible count asserted
  // on the next line, not a raw active count.
  assert.match(app,/Customers currently see no offers\./);
  assert.match(app,/customerVisibleCount===0\?/);
  assert.match(app,/business_get_visible_promotion_count_v167/);
});

test('reward progress is formatted, bounded, accessible, and safe for zero-cost rewards',()=>{
  assert.match(app,/new Intl\.NumberFormat\('en-SG'/);
  assert.match(app,/cost>0\?Math\.min\(100,Math\.max\(0,Math\.round\(\(balance\/cost\)\*100\)\)\):100/);
  assert.match(app,/role="progressbar"/);
  assert.match(app,/aria-valuemin="0" aria-valuemax="100"/);
  assert.match(app,/customerPointTotalV103\(loyalty\.balance\|\|0\)/);
  assert.match(app,/customerPointTotalV103\(reward\.remaining_units\|\|0\)/);
  /* v183: the reward row now states the exchange — "150 points → Free facial add-on" — so the
     formatted cost is rendered from the same clamped `cost` the progress bar uses. */
  assert.match(app,/<span class="customer-reward-row-cost-v322">\$\{esc\(customerPointTotalV103\(cost\)\)\} <span class="muted">\$\{esc\(unitWordV322\)\}<\/span><\/span>/);
  assert.match(app,/customerPointTotalV103\(Math\.abs\(delta\)\)/);
  assert.match(app,/customerPointTotalV103\(earned\)/);
  assert.match(app,/is ready to redeem/);
});

// v178: the owner struck the Next-best-action banner off Home twice. Only the
// pending-redemption variant survives, so the old reward/package/appointment
// priority ladder no longer exists to be ordered.
test('fallback guidance follows only available canonical inputs and can suppress itself',()=>{
  const start=app.indexOf('function customerHomeFallbackActionV167');
  const end=app.indexOf('function renderActionableWalletHome',start);
  const block=app.slice(start,end);
  assert.ok(start>=0&&end>start);
  assert.match(block,/if\(!pendingRedemption\)return ''/);
  assert.match(block,/Complete your pending redemption/);
  assert.doesNotMatch(block,/available_now|sessions_remaining|upcoming_appointments|offers\[0\]/);
  assert.doesNotMatch(block,/customer_get_|sb\.rpc/);
});

test('points explanation is neutral, business-specific, dismissible, and versioned',()=>{
  assert.match(app,/peekaa\.customer\.points-explainer\.v1\./);
  assert.match(app,/How rewards work at \$\{esc\(business\.name\|\|'this business'\)\}/);
  assert.match(app,/Collect points here and use them for available rewards\./);
  assert.match(app,/aria-label="Dismiss points explanation"/);
  assert.doesNotMatch(app,/points-explainer[\s\S]{0,600}every visit earns/i);
});
