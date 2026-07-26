import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = fileURLToPath(new URL('../..', import.meta.url));
const sourcePath = path.join(root,
  'db/migrations/20260726_nestly_v88_platform_firm_onboarding.sql');
const canonicalPath = path.join(root,
  'supabase/migrations/20260726230000_nestly_v88_platform_firm_onboarding.sql');
const rollbackPath = path.join(root,'db/tests/v88_platform_firm_onboarding.sql');

test('v88 canonical migration is the byte-identical post-v87 mirror', async () => {
  const [source,canonical] = await Promise.all([
    readFile(sourcePath,'utf8'),readFile(canonicalPath,'utf8')
  ]);
  assert.equal(canonical,source);
  assert.match(source,/platform_list_firm_onboarding_v88\s*\(/);
  assert.match(source,/platform_list_firm_attention_v88\s*\(/);
  assert.doesNotMatch(source,/language plpgsql\s+stable\s+security definer/);
});

test('v88 unifies website and prospect firms without duplicate converted rows', async () => {
  const sql = await readFile(sourcePath,'utf8');
  assert.match(sql,/select \* from prospect_anchors\s+union all\s+select \* from business_anchors/i);
  assert.match(sql,/prospect\.converted_business_id=business\.id\s+or prospect\.id=business\.source_prospect_id/i);
  assert.match(sql,/when anchor\.business_id is not null then 'case_won'/i);
  assert.match(sql,/when aged\.activated_at is not null then 'activated'[\s\S]+?when aged\.onboarding_started_at is not null then 'in_progress'[\s\S]+?when aged\.business_id is not null then 'not_started'/i);
  assert.doesNotMatch(sql,/resolved_lane_key='case_won' then 'activated'/i);
  assert.match(sql,/left join lateral \(\s+select subscription_row\.status[\s\S]+?limit 1/i);
  assert.match(sql,/join auth\.users account/i);
  assert.doesNotMatch(sql,/owner_staff\.(?:email|phone)\b/);
});

test('v88 SA reader provides scalable search, attention and immutable-sector handoff fields', async () => {
  const sql = await readFile(sourcePath,'utf8');
  for (const field of [
    'registration_number','sector_assignment_version','sector_bundle_version_id',
    'boss_name','boss_email','boss_phone','last_activity_at','days_unattended',
    'attention_severity','attention_due','next_action_at','branch_count',
    'staff_count','customer_count','subscription_status'
  ]) assert.match(sql,new RegExp(`\\b${field}\\b`),field);
  assert.match(sql,/firm\.updated_at,firm\.row_id\)<\(p_after_updated_at,p_after_id\)/);
  assert.match(sql,/least\(greatest\(coalesce\(p_limit,100\),1\),250\)/);
  assert.match(sql,/'attention_summary',jsonb_build_object\(\s*'due'[\s\S]+?'critical'[\s\S]+?'warning'[\s\S]+?'info'/);
  assert.match(sql,/revoke all on function app\.platform_firm_rows_v88[\s\S]+?from public,anon,authenticated/);
  assert.match(sql,/if not app\.is_super_admin\(\)/);
  assert.match(sql,/create table app\.platform_firm_snapshots_v88/i);
  assert.match(sql,/create table app\.platform_firm_snapshot_rows_v88/i);
  assert.match(sql,/ensure_platform_firm_snapshot_v88\(/i);
  assert.match(sql,/firm\.actor_id=v_actor and firm\.snapshot_at=v_snapshot/i);
  assert.match(sql,/item\.payload\|\|jsonb_build_object/i);
  assert.match(sql,/snapshot token is required after the first page/i);
  assert.match(sql,/least\(anchor\.anchor_updated_at,p_snapshot_at\)/i);
  assert.doesNotMatch(sql,/create or replace function public\.platform_(?:create|publish|assign).*sector.*v88/i);
});

test('v88 rollback evidence exercises website visibility, de-duplication, stale attention and SA denial', async () => {
  const sql = await readFile(rollbackPath,'utf8');
  assert.equal((sql.match(/^\s*begin;\s*$/gim) ?? []).length,1);
  assert.equal((sql.match(/^\s*rollback;\s*$/gim) ?? []).length,1);
  assert.match(sql,/V88 Website Firm/);
  assert.match(sql,/V88 Converted Firm/);
  assert.doesNotMatch(sql,/public\.staff\([^)]*\b(?:email|phone)\b/i);
  assert.match(sql,/attention_severity'<>'critical'/);
  assert.match(sql,/v_page_two_after is distinct from v_page_two_before/);
  assert.match(sql,/snapshot membership changed after capture/);
  assert.match(sql,/onboarding_status'<>'not_started'/);
  assert.match(sql,/non-SA executed the v88 firm reader/);
});
