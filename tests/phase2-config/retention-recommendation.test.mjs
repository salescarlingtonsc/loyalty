import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
const root=new URL('../..',import.meta.url);
const read=p=>readFile(new URL(p,root),'utf8');
const path='db/migrations/20260720_frenly_v35_retention_recommendation_drafts.sql';

test('recommendations use catalog aggregates and create an inactive editable draft',async()=>{
  const sql=await read(path);
  assert.match(sql,/average_service_cents/i);
  assert.match(sql,/average_product_cents/i);
  assert.match(sql,/create_loyalty_config_draft/i);
  assert.match(sql,/'active',false/i);
  assert.doesNotMatch(sql, /'id'\s*,\s*v_reward_id/i,
    'new recommended rewards must let the safe v36 editor allocate their identity');
  assert.doesNotMatch(sql,/publish_loyalty_config/i);
  assert.match(sql,/'published',false/i);
});
test('recommendation runs are owner-only, retry-safe and contain no customer data',async()=>{
  const sql=await read(path);
  assert.match(sql,/app\.is_salon_owner\(p_business\)/i);
  assert.match(sql,/unique \(business_id,idempotency_key\)/i);
  assert.match(sql,/idempotency key conflicts with changed business inputs/i);
  assert.doesNotMatch(sql,/public\.clients|full_name|email|phone/i);
  assert.match(sql,/revoke all on public\.retention_recommendation_runs from public,anon,authenticated/i);
});
test('recommendation behavior is explicit heuristic text, not a financial rule',async()=>{
  const sql=await read(path);
  assert.match(sql,/transparent starting heuristics, not platform rules/i);
  assert.match(sql,/fulfillment_kind','manual_item'/i);
  assert.match(sql,/estimated_cost_cents',0/i);
  assert.match(sql,/Replace this with an item or service that fits your margins/i);
});
test('owner UI opens and edits the generated draft before an explicit publish',async()=>{
  const html=await read('app/index.html');
  assert.match(html,/Create recommended draft/i);
  assert.match(html,/generate_retention_recommendation/i);
  assert.match(html,/loyaltyPage\(data\.model,data\.draft_config_version_id,data\)/i);
  assert.match(html,/let versionId=draftVersionId/i);
  assert.match(html,/Draft reward saved/i);
  assert.match(html,/publish only when it fits your business/i);
});
