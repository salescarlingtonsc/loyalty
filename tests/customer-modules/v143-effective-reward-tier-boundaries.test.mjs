import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');
const sourcePath='db/migrations/20260802_nestly_v143_effective_reward_tier_boundaries.sql';
const mirrorPath='supabase/migrations/20260802143000_nestly_v143_effective_reward_tier_boundaries.sql';

test('v143 source and deployment migration are exact safe mirrors',async()=>{
  const [source,mirror]=await Promise.all([read(sourcePath),read(mirrorPath)]);
  assert.equal(source,mirror);
  assert.match(source,/^-- PEEKAA v143 - EFFECTIVE REWARD AND TIER BOUNDARIES/m);
  assert.doesNotMatch(source,/drop\s+(?:table|schema)|disable\s+row\s+level\s+security/i);
});

test('tier windows use one exclusive server boundary in storage and projections',async()=>{
  const source=await read(sourcePath);
  assert.match(source,/alter table public\.loyalty_tier_versions[\s\S]*?effective_from timestamptz[\s\S]*?expires_at timestamptz/);
  assert.match(source,/expires_at>effective_from/);
  assert.match(source,/effective_from is null or effective_from<=statement_timestamp\(\)/);
  assert.match(source,/expires_at is null or expires_at>statement_timestamp\(\)/);
  assert.match(source,/create or replace function app\.loyalty_tier_for/);
  assert.match(source,/create or replace function public\.customer_get_effective_tier_v143/);
});

test('tier writer is owner bounded, optimistic and browser ACL closed by default',async()=>{
  const source=await read(sourcePath);
  const writer=source.slice(
    source.indexOf('create or replace function public.save_loyalty_tier_draft_v143'),
    source.indexOf('create or replace function app.loyalty_tier_for')
  );
  assert.match(writer,/app\.c45_owner_loyalty_write/);
  assert.match(writer,/draft configuration changed; reload before saving/);
  assert.match(writer,/tier expiration must be after its effective time/);
  assert.match(writer,/revoke all on function public\.save_loyalty_tier_draft_v143[\s\S]*?grant execute[\s\S]*?to authenticated/);
});

test('owner UI authors and labels reward and tier windows in Kuala Lumpur time',async()=>{
  const app=await read('app/index.html');
  assert.match(app,/timeZone:'Asia\/Kuala_Lumpur'/);
  assert.match(app,/boundaryInstant=\(value\)=>value\?`\$\{value\}:00\+08:00`:null/);
  assert.match(app,/claim_available_from:boundaryInstant\(\$\('rwFrom'\)\.value\)/);
  assert.match(app,/claim_available_until:boundaryInstant\(\$\('rwUntil'\)\.value\)/);
  assert.match(app,/save_loyalty_tier_draft_v143/);
  assert.match(app,/effective_from:boundaryInstant\(\$\('trFrom'\)\.value\)/);
  assert.match(app,/expires_at:boundaryInstant\(\$\('trUntil'\)\.value\)/);
  for(const label of['Live','Scheduled','Ended','Paused'])assert.match(app,new RegExp(`label:'${label}'`));
});

test('customer path replaces legacy tier data and keeps out-of-window reward actions disabled',async()=>{
  const app=await read('app/index.html');
  assert.match(app,/customer_get_effective_tier_v143/);
  assert.match(app,/presentation\.tier=effectiveTierResult\.error\?\{\}/);
  assert.match(app,/not_started:'Available soon'/);
  assert.match(app,/ended:'Offer ended'/);
  assert.match(app,/customerRewardCanRedeem\(r,redemptionEnabled\)/);
});

test('rollback evidence covers permissions, invalid windows, disabled and persistence states',async()=>{
  const sql=await read('db/tests/v143_effective_reward_tier_boundaries.sql');
  assert.match(sql,/^begin;/m);
  assert.match(sql,/^rollback;/m);
  assert.match(sql,/non-owner changed a tier window/i);
  assert.match(sql,/invalid tier window persisted/i);
  assert.match(sql,/future tier affected the customer before its boundary/i);
  assert.match(sql,/ended tier affected the customer at its exclusive boundary/i);
  assert.match(sql,/disabled Loyalty exposed effective tier progress/i);
});
