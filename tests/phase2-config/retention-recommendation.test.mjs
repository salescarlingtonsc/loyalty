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
  const html=((await read('app/index.html'))+'\n'+(await read('app/app.js')));
  assert.match(html,/Create recommended draft/i);
  assert.match(html,/generate_retention_recommendation/i);
  assert.match(html,/refreshLoyaltyPanel\(data\.model,data\.draft_config_version_id,data,'Recommended Grow draft ready\.',false,editorIntent\)/i);
  assert.match(html,/if\(!stableRefresh\)routeMain\.innerHTML=CUI\.loadingState/i);
  assert.match(html,/let versionId=draftVersionId/i);
  /* nestly_v415: the reward writer publishes now (owner, photo 2), so its confirmation names
     what actually happened. */
  assert.match(html,/Reward saved and live for customers/i);
  /* nestly_v415: the recommendation still gets its own line above the editor — a generated draft
     IS worth reading before it reaches customers — but the sentence changed with the banner the
     owner had removed (photo 2). It now says what Save will do rather than telling the owner to
     publish separately, because there is no separate publish on this page any more. */
  assert.match(html,/Review every number below — Save puts it live for customers/i);
});
