import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');
const migrationPath = 'db/migrations/20260720_frenly_v39_detailed_customer_wallet.sql';
const sqlTestPath = 'db/tests/v39_detailed_customer_wallet.sql';
const functions = [
  ['customer_get_loyalty_details', 'text,jsonb'],
  ['customer_get_reward_catalog', 'text'],
  ['customer_get_packages', 'text,jsonb'],
  ['customer_get_memberships', 'text'],
  ['customer_get_appointments_page', 'text,jsonb']
];

function block(sql,name){
  const start=sql.search(new RegExp(`create or replace function public\\.${name}\\s*\\(`,'i'));
  assert.ok(start>=0,`${name} is missing`);
  const rest=sql.slice(start),end=rest.search(/\ncreate or replace function\b|\nrevoke all on function\b/i);
  return end<0?rest:rest.slice(0,end);
}

test('v39 detailed customer readers are self-scoped authenticated-only RPCs',async()=>{
  const sql=await read(migrationPath);
  for(const [name,signature] of functions){
    const body=block(sql,name);
    assert.match(body,/auth\.uid\s*\(\s*\)/i);
    assert.match(body,/app\.v32_customer_wallet_context\s*\(\s*p_business_slug\s*\)/i);
    assert.match(body,/security definer/i);
    assert.match(body,/set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'/i);
    assert.doesNotMatch(body,/p_(?:business|client|identity)\s+uuid/i);
    assert.match(sql,new RegExp(`revoke all on function public\\.${name}\\(${signature}\\) from public, anon, authenticated`,'i'));
    assert.match(sql,new RegExp(`grant execute on function public\\.${name}\\(${signature}\\) to authenticated`,'i'));
  }
});

test('v39 outputs explicit safe projections and no internal economic or contact fields',async()=>{
  const sql=await read(migrationPath);
  for(const [name] of functions){
    const body=block(sql,name);
    assert.match(body,/jsonb_(?:build_object|agg)\s*\(/i);
    assert.doesNotMatch(body,/'(?:business_id|client_id|identity_id|auth_user_id|actor|sale_id|payment_id|email|phone|notes|internal_name|estimated_cost_cents|credit_cents|price_cents)'/i);
  }
  const catalog=block(sql,'customer_get_reward_catalog');
  assert.match(catalog,/'customer_name'/i);
  assert.match(catalog,/'description'/i);
  assert.match(catalog,/'image_ref'/i);
  assert.match(catalog,/'terms'/i);
  assert.match(catalog,/'eligibility'/i);
  assert.match(catalog,/'claim_method', 'counter'/i);
  assert.doesNotMatch(catalog,/customer_(?:redeem|claim_reward)|redeem_reward\s*\(/i);
});

test('v39 paginates activity, packages, and appointments with bounded opaque cursors',async()=>{
  const sql=await read(migrationPath);
  for(const name of ['customer_get_loyalty_details','customer_get_packages']){
    const body=block(sql,name);
    assert.match(body,/jsonb_typeof\s*\(v_cursor\)\s*<>\s*'object'/i);
    assert.match(body,/least\s*\(\s*greatest[\s\S]*?50\s*\)/i);
    assert.match(body,/'before_at'/i);
    assert.match(body,/'before_id'/i);
    assert.match(body,/'next_cursor'/i);
    assert.match(body,/limit v_limit \+ 1/i);
  }
  const appointments=block(sql,'customer_get_appointments_page');
  assert.match(appointments,/least\s*\(\s*greatest[\s\S]*?50\s*\)/i);
  for(const key of ["'as_of'","'sort_group'","'starts_at'","'id'","'next_cursor'"])
    assert.match(appointments,new RegExp(key,'i'));
  assert.match(appointments,/a\.status = 'booked' and a\.starts_at >= v_as_of then 0 else 1/i);
  assert.match(appointments,/case when sort_group=0 then starts_at end asc/i);
  assert.match(appointments,/case when sort_group=1 then starts_at end desc/i);
  assert.match(appointments,/limit v_limit \+ 1/i);
});

test('v39 capabilities are module- and data-aware and the SPA loads only relevant sections',async()=>{
  const [sql,app]=await Promise.all([read(migrationPath),read('app/index.html')]);
  const caps=block(sql,'customer_portal_capabilities');
  for(const key of ['rewards','activity','appointments','booking_request','packages','membership']){
    assert.match(caps,new RegExp(`'${key}'`,'i'));
  }
  assert.match(caps,/enabled_modules/i);
  assert.match(caps,/exists\s*\(/i);
  assert.match(caps,/'rewards'[\s\S]*?loyalty_programs[\s\S]*?lp\.active[\s\S]*?loyalty_reward_versions/i);
  assert.match(caps,/'activity'[\s\S]*?loyalty_programs[\s\S]*?lp\.active[\s\S]*?points_ledger/i);
  assert.doesNotMatch(block(sql,'customer_get_reward_catalog'),/used_count[\s\S]{0,500}loyalty_redemption_reversals/i,
    'catalog usage limits must count the same immutable redemption rows as the authoritative claim path');
  for(const [name] of functions)assert.match(app,new RegExp(`sb\\.rpc\\('${name}'`,'i'));
  assert.match(app,/capabilities\.rewards\?walletSectionShell/i);
  assert.match(app,/capabilities\.activity\?walletSectionShell/i);
  assert.match(app,/capabilities\.packages\?walletSectionShell/i);
  assert.match(app,/capabilities\.membership\?walletSectionShell/i);
  assert.match(app,/capabilities\.appointments\?walletSectionShell/i);
  assert.match(app,/wallet-skeleton/i);
  assert.match(app,/walletSectionError/i);
  assert.match(app,/walletSectionEmpty/i);
  assert.match(app,/ensureWalletEmptyState\(businessSlug\)/i);
  assert.match(app,/walletSections/i);
  assert.match(app,/Nothing to show yet/i);
  assert.match(app,/Load more/i);
  assert.match(app,/Claims are completed with the team at the counter/i);
  assert.doesNotMatch(app,/sb\.rpc\(['"](?:redeem_reward|redeem_points)['"][\s\S]{0,200}wallet/i);
});

test('v39 rollback suite covers tenant isolation, pagination, capabilities, and raw-table denial',async()=>{
  const suite=await read(sqlTestPath);
  assert.match(suite,/^begin;/im);
  assert.match(suite,/^rollback;/im);
  for(const term of [
    'cross-business','pagination','next_cursor','unknown cursor','disabled module',
    'raw table','PUBLIC','anon','authenticated','search_path','prohibited output key',
    'customer_get_reward_catalog','customer_get_packages','customer_get_memberships',
    'customer_get_appointments_page','customer_get_loyalty_details'
  ]) assert.match(suite,new RegExp(term,'i'),`missing rollback coverage: ${term}`);
});
