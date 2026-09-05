import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../../',import.meta.url);
const [source,deploy,fixture,app]=await Promise.all([
  readFile(new URL('db/migrations/20260722_frenly_v49_billing_projection_rpc.sql',root),'utf8'),
  readFile(new URL('supabase/migrations/20260722134000_frenly_v49_billing_projection_rpc.sql',root),'utf8'),
  readFile(new URL('db/tests/v49_billing_projection.sql',root),'utf8'),
  Promise.all([readFile(new URL('app/index.html',root),'utf8'),readFile(new URL('app/app.js',root),'utf8')]).then(f=>f.join('\n'))
]);

const section=(start,end)=>{
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.notEqual(from,-1,`missing ${start}`);
  assert.notEqual(to,-1,`missing ${end}`);
  return app.slice(from,to);
};

test('v49 source and canonical deployment are byte-identical and atomic',()=>{
  assert.equal(deploy,source);
  assert.match(source,/^-- FRENLY v49[\s\S]*\nbegin;/);
  assert.equal((source.match(/^\s*begin\s*;\s*$/gim)||[]).length,1);
  assert.equal((source.match(/^\s*commit\s*;\s*$/gim)||[]).length,1);
});

test('v49 billing RPC is a pinned definer with active owner-only tenancy authorization',()=>{
  assert.match(source,/create or replace function public\.get_business_billing_v49\(p_business uuid\)[\s\S]*security definer[\s\S]*set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'/i);
  assert.match(source,/v_actor uuid := auth\.uid\(\)/);
  assert.match(source,/staff_member\.business_id = p_business[\s\S]*staff_member\.user_id = v_actor[\s\S]*staff_member\.active/);
  assert.match(source,/staff_member\.active[\s\S]*staff_member\.role = 'owner'/);
  assert.match(source,/raise exception 'active business owner access is required' using errcode = '42501'/);
  assert.doesNotMatch(source,/app\.is_salon_member\(p_business\)/);
});

test('v49 exposes only the finite billing projection and keeps the seat helper private',()=>{
  for(const key of [
    'business_id','status','currency','base_price_cents','included_seats',
    'per_seat_price_cents','billable_seats','extra_seats','monthly_total_cents',
    'trial_ends_at','current_period_start','current_period_end'
  ]) assert.match(source,new RegExp(`'${key}'`));
  assert.doesNotMatch(source,/'business_name'|'note'|'email'|'phone'|'secret'/);
  assert.match(source,/v_billable_seats := app\.billable_seats\(p_business\)/);
  assert.match(source,/revoke all privileges on function public\.get_business_billing_v49\(uuid\)[\s\S]*from public, anon, authenticated;[\s\S]*grant execute[\s\S]*to authenticated;/i);
  assert.doesNotMatch(source,/grant execute on function app\.billable_seats/i);
  assert.doesNotMatch(source,/\bto anon\s*;/i);
});

test('v49 rollback suite checks ACL, projection math, owner access, and non-owner/inactive/cross-business/anon denial',()=>{
  assert.equal((fixture.match(/^\s*begin\s*;\s*$/gim)||[]).length,1);
  assert.equal((fixture.match(/^\s*rollback\s*;\s*$/gim)||[]).length,1);
  assert.match(fixture,/has_function_privilege\('authenticated','app\.billable_seats\(uuid\)'::regprocedure,'execute'\)/);
  assert.match(fixture,/v49_owner_allowed/);
  assert.match(fixture,/v49_non_owner_denied/);
  assert.match(fixture,/active same-business non-owner billing read/);
  assert.match(fixture,/v49_inactive_denied/);
  assert.match(fixture,/v49_cross_business_denied/);
  assert.match(fixture,/v_other_business/);
  assert.match(fixture,/V49 Inactive Owner/);
  assert.match(fixture,/inactive owner billing read/);
  assert.match(fixture,/V49 Other Tenant Owner/);
  assert.match(fixture,/active owner from another business billing read/);
  assert.match(fixture,/v49_anon_denied/);
  assert.match(fixture,/select count\(\*\) into v_key_count from jsonb_object_keys\(v_result\)/);
  assert.match(fixture,/if v_key_count<>12/);
  assert.match(fixture,/do \$v49_done\$[\s\S]*raise notice 'v49 billing projection suite: ALL PASS'/i);
  assert.match(fixture,/monthly_total_cents'\)::bigint<>5500/);
});

test('owner-only Settings uses the V124 projection and generic retryable errors without raw database text',()=>{
  const billing=section('async function loadBillingConfig()','/* ---------- customer sign-up QR ---------- */');
  assert.match(app,/if\(pageKey==='settings'&&S\.myRole!=='owner'\)[\s\S]*Only the owner can open Settings\./);
  /* nestly_v758: the card reads get_business_billing_v758, which returns the v125 projection plus
     a server-computed summary and payment method, and falls back to v125 itself where v758 is not
     deployed yet. The V49 guarantee is unchanged — Settings renders from the OWNER-scoped billing
     projection and from nothing else — so it is pinned on that read and on the fallback inside it,
     rather than on a name the projection has outgrown. */
  assert.match(billing,/fetchBusinessBillingV758\(S\.biz\.id\)/);
  assert.match(app,/async function fetchBusinessBillingV758\(businessId\)\{[\s\S]{0,600}?sb\.rpc\('get_business_billing_v758',\{p_business:businessId\}\)[\s\S]{0,400}?sb\.rpc\('get_business_billing_v125',\{p_business:businessId\}\)/);
  assert.doesNotMatch(billing,/sb\.rpc\('get_business_billing_v(?!758)/,'no second, different billing read');
  /* nestly_v784: this page formats money through moneyShortV758 (SGD, hardcoded on purpose). */
  assert.match(billing,/moneyShortV758\(/);
  /* nestly_v664: the card prices from the server's capacity tiers, so the per-1,000 block amount
     is no longer part of what it renders. What must stay pinned is that the amount comes from the
     projection and is multiplied by the branch units Stripe is asked for. */
  assert.match(billing,/tierForCapacityV664\('annual',selectedCapacity\)/);
  assert.match(billing,/const total=unit\*units;/);
  assert.doesNotMatch(billing,/S\.biz\?\.currency|S\.biz\.currency/);
  assert.doesNotMatch(billing,/v_business_billing|error\.message|requestError\?\.message|console\.(?:error|warn)/);
  assert.match(billing,/Billing details could not load\. Check your connection and try again\./);
  assert.match(billing,/id="billingRetry"/);
  assert.match(billing,/\$\('billingRetry'\)\.onclick=\(\)=>loadBillingConfig\(\)/);
  assert.match(billing,/role="alert"/);
});
