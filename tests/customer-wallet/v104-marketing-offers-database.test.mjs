import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const migrationUrl=new URL(
  '../../supabase/migrations/20260729170000_nestly_v104_marketing_offers.sql',
  import.meta.url
);
const mirrorUrl=new URL(
  '../../db/migrations/20260729_nestly_v104_marketing_offers.sql',
  import.meta.url
);
const fixtureUrl=new URL(
  '../../db/tests/v104_marketing_offers.sql',
  import.meta.url
);
const concurrencyUrl=new URL(
  '../../db/tests/v104_marketing_offers_concurrency.mjs',
  import.meta.url
);
const rollbackUrl=new URL(
  '../../db/cutover/v104_marketing_offers.rollback.sql',
  import.meta.url
);

const functionBlock=(sql,schema,name,nextMarker)=>{
  const start=sql.indexOf(`create or replace function ${schema}.${name}`);
  const end=nextMarker
    ?sql.indexOf(nextMarker,start+1)
    :sql.length;
  assert.ok(start>=0&&end>start,`missing ${schema}.${name}`);
  return sql.slice(start,end);
};

test('v104 launch entitlement uses a full-day exclusive boundary and one shared business lock',async()=>{
  const sql=await readFile(migrationUrl,'utf8');
  assert.match(
    sql,
    /timestamptz '2026-11-01 00:00:00\+08'/,
    'the complimentary period must include every instant of 31 October SG'
  );
  assert.doesNotMatch(sql,/2026-10-31 23:59:59\+08/);
  assert.match(sql,/max_published_offers integer not null[\s\S]*between 0 and 100/);
  assert.match(sql,/create table public\.business_promotion_entitlements_v104/);
  assert.match(sql,/create table public\.business_promotion_attempt_receipts_v104/);
  assert.match(
    sql,
    /alter table public\.business_promotion_attempt_receipts_v104[\s\S]*enable row level security/
  );
  assert.match(
    sql,
    /revoke all privileges on table public\.business_promotion_attempt_receipts_v104[\s\S]*from public,anon,authenticated/
  );

  const lock=functionBlock(
    sql,'app','v104_lock_promotion_business',
    'create or replace function app.v104_effective_promotion_entitlement'
  );
  assert.match(lock,/pg_advisory_xact_lock/);
  assert.match(lock,/'nestly\.v104\.promotion:'\|\|p_business::text/);

  for(const name of [
    'platform_set_promotion_entitlement_v104',
    'business_save_promotion_v104',
    'business_create_promotion_draft_v104',
    'business_finalize_promotion_v104'
  ]){
    const block=functionBlock(sql,'public',name,'create or replace function ');
    assert.match(
      block,
      /perform app\.v104_lock_promotion_business\(p_business\)/,
      `${name} must serialize on the same per-business lock`
    );
  }
});

test('v104 direct offer content, media and copy bypasses are trigger-guarded',async()=>{
  const sql=await readFile(migrationUrl,'utf8');
  for(const [table,trigger,error] of [
    [
      'business_customer_content_v95',
      'business_customer_content_v104_promotion_write_guard',
      'promotion_v104_rpc_required'
    ],
    [
      'business_media_assets_v95',
      'business_media_assets_v104_promotion_write_guard',
      'promotion_media_v104_rpc_required'
    ],
    [
      'business_localized_copy_v95',
      'business_localized_copy_v104_promotion_write_guard',
      'promotion_copy_v104_rpc_required'
    ]
  ]){
    assert.match(sql,new RegExp(
      `create trigger ${trigger}[\\s\\S]*on public\\.${table}`
    ));
    assert.match(sql,new RegExp(error));
  }
  assert.match(sql,/old\.content_type='offer'[\s\S]*new\.content_type='offer'/);
  assert.match(sql,/old\.asset_kind='offer'[\s\S]*new\.asset_kind='offer'/);
  assert.match(sql,/old\.entity_type='offer'[\s\S]*new\.entity_type='offer'/);
  assert.doesNotMatch(
    sql,
    /v_touches_offer[\s\S]{0,240}app\.is_super_admin\(\)/,
    'super admins must use the receipt, quota and image-bound v104 RPC too'
  );
});

test('v104 global draft creation is replay-safe and remains available after quota or cutoff',async()=>{
  const sql=await readFile(migrationUrl,'utf8');
  const create=functionBlock(
    sql,'public','business_create_promotion_draft_v104',
    'create or replace function public.business_finalize_promotion_v104'
  );
  const receiptAt=create.indexOf(
    'from public.business_promotion_attempt_receipts_v104'
  );
  const ownerAt=create.lastIndexOf('if not app.is_salon_owner(p_business)');
  const validationAt=create.indexOf('if p_branch is not null');
  assert.ok(
    receiptAt>=0&&ownerAt>receiptAt&&validationAt>ownerAt,
    'exact replay must return before mutable owner and field checks'
  );
  assert.match(
    create,
    /if not app\.is_salon_owner\(p_business\) then[\s\S]*raise exception 'owner_required'/,
    'a super admin may inspect or control entitlement, but cannot start a merchant-authored draft'
  );
  assert.match(create,/p_promotion_id is null[\s\S]*p_attempt_key is null/);
  assert.match(create,/'action','create_draft'/);
  assert.match(create,/where receipt\.business_id=p_business[\s\S]*receipt\.attempt_key=p_attempt_key/);
  assert.match(create,/v_receipt\.created_by is distinct from v_actor/);
  assert.match(
    create,
    /v_receipt\.created_by is distinct from v_actor[\s\S]*not app\.is_super_admin\(\)[\s\S]*promotion_receipt_replay_forbidden/,
    'super admin authority is limited to exact receipt recovery'
  );
  assert.match(create,/promotion_attempt_key_reused/);
  assert.match(
    create.slice(create.indexOf('return v_receipt.response_payload')),
    /if not app\.is_salon_owner\(p_business\) then[\s\S]*owner_required/,
    'fresh draft creation must remain merchant-owner-only'
  );
  assert.match(create,/if p_branch is not null/);
  assert.match(create,/id,business_id,content_type/);
  assert.match(create,/p_promotion_id,p_business,'offer'/);
  assert.doesNotMatch(
    create,
    /promotion_creation_window_closed|promotion_publish_limit_reached|now\(\)>=v_entitlement\.complimentary_until/,
    'private drafts are not quota- or launch-window-gated'
  );
  assert.match(create,/business_promotion_attempt_receipts_v104/);
  assert.match(create,/'replayed',true/);
  assert.match(create,/'replayed',false/);
});

test('v104 finalizer is replay-safe and atomic across content, copy, global media and first-publication quota',async()=>{
  const sql=await readFile(migrationUrl,'utf8');
  const finalize=functionBlock(
    sql,'public','business_finalize_promotion_v104',
    'create or replace function public.business_get_promotion_editor_v104'
  );
  const receiptAt=finalize.indexOf('from public.business_promotion_attempt_receipts_v104');
  const storageAt=finalize.indexOf('app.v95_storage_object_is_publishable');
  const contentLockAt=finalize.indexOf('from public.business_customer_content_v95 content');
  assert.ok(
    receiptAt>=0&&storageAt>receiptAt&&contentLockAt>storageAt,
    'exact replay must return before storage and optimistic validation'
  );
  assert.match(
    finalize,
    /if not app\.is_salon_owner\(p_business\) then[\s\S]*raise exception 'owner_required'/,
    'fresh publication must use the same owner authority as the upload path and browser surface'
  );
  assert.match(finalize,/v_receipt\.created_by is distinct from v_actor/);
  assert.match(
    finalize,
    /v_receipt\.created_by is distinct from v_actor[\s\S]*not app\.is_super_admin\(\)[\s\S]*promotion_receipt_replay_forbidden/,
    'super admin authority is limited to exact finalization receipt recovery'
  );
  assert.match(
    finalize.slice(finalize.indexOf('return v_receipt.response_payload')),
    /if not app\.is_salon_owner\(p_business\) then[\s\S]*owner_required/,
    'fresh finalization must remain merchant-owner-only'
  );
  assert.match(finalize,/if p_branch is not null/);
  assert.match(finalize,/promotion_attempt_key_reused/);
  assert.match(finalize,/v_first_adoption:=p_publish[\s\S]*not\(v_content\.metadata \? 'published_once_at'\)/);
  assert.match(finalize,/now\(\)>=v_entitlement\.complimentary_until/);
  assert.match(finalize,/promotion_publish_limit_reached/);
  assert.match(finalize,/content\.metadata \? 'published_once_at'/);
  assert.match(finalize,/'published_once_at',case when p_publish/);
  assert.match(finalize,/asset\.branch_id is not distinct from p_branch[\s\S]*for update/);
  assert.match(finalize,/v_target_media\.version<>p_expected_target_media_version/);
  assert.match(finalize,/promotion_target_media_version_conflict/);
  assert.match(finalize,/promotion_image_required/);
  assert.match(finalize,/customer_visible=p_publish/);
  assert.match(finalize,/found and p_publish and not v_applicable_media\.customer_visible/);
  assert.match(finalize,/app\.v104_promotion_media_write','on'/);
  assert.match(finalize,/app\.v104_promotion_write','on'/);
  assert.match(finalize,/app\.v104_promotion_copy_write','on'/);
  assert.match(finalize,/'previous_object_path'/);
  assert.match(finalize,/business_promotion_attempt_receipts_v104/);

  const legacySave=functionBlock(
    sql,'public','business_save_promotion_v104',
    'create or replace function public.business_create_promotion_draft_v104'
  );
  assert.match(
    legacySave,
    /Every mutable save now requires a stable attempt key[\s\S]*raise exception 'promotion_finalize_rpc_required'/
  );
});

test('v104 editor returns hidden draft photos plus the exact global media version',async()=>{
  const sql=await readFile(migrationUrl,'utf8');
  const editor=functionBlock(
    sql,'public','business_get_promotion_editor_v104',
    'create or replace function public.customer_get_promotions_v104'
  );
  for(const field of [
    'branch_id','publish_state','starts_at','ends_at','display_order',
    'content_version','copy_version','name','tagline','description','terms',
    'metadata','image_url','image_alt','media_asset_id','media_version',
    'image_customer_visible','media_versions_by_scope'
  ]){
    assert.match(editor,new RegExp(`'${field}'`));
  }
  assert.doesNotMatch(
    editor,
    /asset\.customer_visible[\s\S]{0,160}order by/,
    'owner editor must reload a hidden draft image'
  );
  assert.match(editor,/coalesce\(asset\.branch_id::text,'global'\)/);
  assert.match(editor,/'media_version',asset\.version/);
  assert.match(editor,/limit 100/);
  assert.match(editor,/'quota_used'/);
  assert.match(editor,/'quota_remaining'/);
  assert.match(editor,/now\(\)<v_entitlement\.complimentary_until/);
});

test('v104 customer reader is verified-link, global-only, image, date and two-card bound',async()=>{
  const sql=await readFile(migrationUrl,'utf8');
  const reader=functionBlock(sql,'public','customer_get_promotions_v104','-- Finite browser ACLs');
  assert.match(reader,/app\.v31_current_identity\(\)/);
  assert.match(reader,/link\.state='verified'/);
  assert.match(reader,/verified_customer_link_required/);
  assert.match(reader,/p_branch is not null/);
  assert.match(reader,/content\.branch_id is null/);
  assert.match(reader,/asset\.branch_id is null/);
  assert.match(reader,/asset\.customer_visible/);
  assert.match(reader,/media\.url is not null/);
  assert.match(reader,/content\.starts_at is null or content\.starts_at<=now\(\)/);
  assert.match(reader,/content\.ends_at>now\(\)/);
  assert.match(reader,/order by content\.display_order,content\.starts_at desc nulls last,[\s\S]*limit 2/);
  assert.match(reader,/'limit',2/);
});

test('v104 rollback-only fixture covers exact failure, retry and synchronization criteria',async()=>{
  const fixture=await readFile(fixtureUrl,'utf8');
  for(const phrase of [
    'manager read owner-only promotion editor',
    'foreign owner read another tenant promotion editor',
    'super admin created a fresh promotion draft',
    'denied super-admin draft mutated content or receipt',
    'lost draft-create response did not replay exactly',
    'super admin could not replay exact recorded receipt',
    'super admin changed payload on an existing attempt key',
    'super admin performed a fresh promotion finalization',
    'denied super-admin finalization mutated promotion state',
    'legacy v95 owner offer writer bypassed v104 authority',
    'super admin generic offer writer bypassed v104 authority',
    'legacy v95 owner offer media writer bypassed v104 authority',
    'legacy v95 owner offer copy writer bypassed v104 authority',
    'promotion published without a customer-visible image',
    'lost publish response did not replay exactly',
    'stale active replacement changed old image/copy or lost orphan',
    'draft photo was not atomically stored',
    'hidden draft photo did not reload in editor',
    'draft photo did not publish without reselecting',
    'unpublishing an offer incorrectly restored a quota slot',
    'branch-scoped promotion draft was created',
    'company-wide two-card promotion projection is wrong',
    'branch-scoped customer promotion reader was allowed',
    'stale global failure changed copy/image or linked orphan',
    'editor did not expose refreshed global media version',
    'refreshed global retry did not replace exact scope',
    'active legacy conversion bypassed v104 allocation quota',
    'active legacy conversion did not allocate one slot',
    'unlinked customer read business promotions',
    'private draft was blocked after quota or cutoff',
    'original creator lost-response replay failed after owner revocation',
    'orphaned NULL-created_by receipt replayed for non-owner',
    'first publication succeeded after publishing window closed',
    'closed launch window invalidated an existing publication',
    'v104 promotion ACL is not finite and authenticated-only'
  ]){
    assert.match(fixture,new RegExp(phrase.replaceAll(/[.*+?^${}()|[\]\\]/g,'\\$&')));
  }
});

test('v104 true two-session harness proves one winner at slots 9/10',async()=>{
  const concurrency=await readFile(concurrencyUrl,'utf8');
  assert.match(concurrency,/pg_sleep\(2\)/);
  assert.match(concurrency,/Promise\.all\(\[/);
  assert.match(concurrency,/exactly one competing publication must win/);
  assert.match(concurrency,/promotion_publish_limit_reached/);
  assert.match(concurrency,/quota_used:10/);
  assert.match(concurrency,/active_count:10/);
  assert.match(concurrency,/contender_active_count:1/);
  assert.match(concurrency,/contender_receipt_count:1/);
});

test('v104 source and mirror are exact and rollback removes authority without deleting truth',async()=>{
  const [migration,mirror,rollback]=await Promise.all([
    readFile(migrationUrl,'utf8'),
    readFile(mirrorUrl,'utf8'),
    readFile(rollbackUrl,'utf8')
  ]);
  assert.equal(mirror,migration);
  for(const name of [
    'platform_set_promotion_entitlement_v104',
    'business_save_promotion_v104',
    'business_create_promotion_draft_v104',
    'business_finalize_promotion_v104',
    'business_get_promotion_editor_v104',
    'customer_get_promotions_v104'
  ]){
    assert.match(
      rollback,
      new RegExp(`drop function if exists public\\.${name}`)
    );
  }
  for(const trigger of [
    'business_customer_content_v104_promotion_write_guard',
    'business_media_assets_v104_promotion_write_guard',
    'business_localized_copy_v104_promotion_write_guard'
  ]){
    assert.match(rollback,new RegExp(`drop trigger if exists ${trigger}`));
  }
  assert.match(rollback,/drop function if exists app\.v104_lock_promotion_business/);
  assert.match(
    rollback,
    /preserve promotion entitlements, idempotency receipts and all[\s\S]*authored v95 records/
  );
  assert.doesNotMatch(rollback,/drop table|truncate|delete from public\./i);
});
