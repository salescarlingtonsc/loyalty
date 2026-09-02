-- Rollback-only v684 acceptance suite — a retired offer that alerted customers can be deleted.
--
-- Audit finding F028: business_delete_promotion_v183 chooses its branch on `active`, so an offer
-- the owner has already "Ended" falls into the hard-delete branch. That branch never released
-- public.promotion_alert_runs_v122, whose promotion_id FK is ON DELETE RESTRICT, so the delete
-- raised 23503 and the client printed "That change couldn't be saved." The offer could never be
-- removed — and only for the offers that had actually reached a customer, because the watermark
-- row exists exactly when a fan-out enqueued somebody.
--
-- The tenant is built from scratch inside this transaction: an owner login, an approved unpaused
-- business with a subscription row, a real client with a verified customer link opted in to
-- promotion alerts, and an offer published through the REAL publish path (an active false->true
-- update firing app.promotion_publication_v122_alert -> app.enqueue_promotion_alert_v122). Nothing
-- here is discovered in production and nothing is hand-inserted into the watermark table.
--
-- SECTION 1 — the fixture is the real thing.
--   S1-T1  Publishing enqueued at least one inbox event, wrote exactly one watermark row, and
--          wrote a campaign_send_records_v255 send record. Without this the rest proves nothing.
--   S1-T2  "End" retires: mode='retired', the row survives with active=false and ends_at<=now().
--   S1-T3  The retire branch does NOT release the watermark. A retired offer still exists, so its
--          watermark must still mute the fan-out; this is the guard against "fixing" F028 by
--          moving the release up into the shared path.
--
-- SECTION 2 — the delete the owner could never complete.
--   S2-T1  Delete succeeds: mode='deleted'.
--   S2-T2  The content row, its localized copy and its branch scopes are gone.
--   S2-T3  The offer's watermark rows are gone — released, not orphaned.
--   S2-T4  The audit trail SURVIVES: the campaign_send_records_v255 rows and the customer's
--          in-app inbox event are still there, still naming the promotion.
--   S2-T5  One audit_log 'promotion.deleted' row records alert_runs_released=1 and the
--          published_once_at that proves this offer had been published.
--
-- SECTION 3 — nothing else moved.
--   S3-T1  A second offer of the same tenant keeps its own watermark row: the release is scoped
--          to the promotion being deleted.
--   S3-T2  The FK is still ON DELETE RESTRICT. The fix is a route that releases, not a schema
--          that stopped guarding — a direct DELETE of the second offer's content row still fails.
--
-- Run against production; everything is inside one transaction that rolls back.
begin;
create temporary table v684_evidence(test text, detail text) on commit drop;

create or replace function pg_temp.as_v684_user(p_uid uuid) returns void language plpgsql as $fn$
begin
  execute 'reset role';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end
$fn$;
grant execute on function pg_temp.as_v684_user(uuid) to public;

do $v684$
declare
  v_owner uuid := gen_random_uuid();
  v_customer uuid := gen_random_uuid();
  v_biz uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_client uuid := gen_random_uuid();
  v_identity uuid := gen_random_uuid();
  v_link uuid := gen_random_uuid();
  v_offer uuid := gen_random_uuid();
  v_other uuid := gen_random_uuid();
  v_published_at timestamptz := now() - interval '30 days';
  v_res json;
  v_row public.business_customer_content_v95%rowtype;
  v_count integer;
  v_sends integer;
  v_inbox integer;
  v_detail jsonb;
  v_err text;
begin
  -- ------------------------------------------------------------------ fixture: the tenant
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
          'v684-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',v_customer,'authenticated','authenticated',
          'v684-customer-'||substr(v_customer::text,1,8)||'@example.test','',now(),now(),now());

  insert into public.businesses(id,name,slug,industry,enabled_modules,points_mode)
  values (v_biz,'V684 Fixture Tenant','v684-'||substr(v_biz::text,1,8),'retail',
          array['dashboard','clients','sales','loyalty'],'redeem');
  insert into public.staff(business_id,user_id,role,full_name,active)
  values (v_biz,v_owner,'owner','V684 Owner',true);
  -- Without an approved, unpaused workspace every module resolves to 'disabled' and the RPC
  -- refuses before it reaches the work — a refusal that reads exactly like a passing test.
  update public.business_workspace_controls_v94
     set approval_status='approved', decided_by=v_owner, decided_at=now(),
         decision_reason='v684 rollback fixture', version=version+1, updated_at=now()
   where business_id=v_biz;
  update public.business_subscription_lifecycle_v94
     set workspace_paused=false where business_id=v_biz;
  insert into public.subscriptions(business_id) values (v_biz) on conflict do nothing;
  insert into public.branches(id,business_id,name) values (v_branch,v_biz,'V684 Main');

  -- ------------------------------------------------------- fixture: a real, opted-in customer
  insert into public.clients(id,business_id,full_name,phone)
  values (v_client,v_biz,'V684 Customer','8'||lpad((floor(random()*9999999))::text,7,'0'));
  insert into public.customer_identities(id,auth_user_id,created_via)
  values (v_identity,v_customer,'wallet_start');
  -- app.v31_link_immutable_guard only accepts a link created by a route that names the id.
  perform set_config('app.customer_link_insert_id',v_link::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,
                                    state,verification_method,verified_at)
  values (v_link,v_biz,v_identity,v_customer,v_client,'verified','qr_join',now());
  perform set_config('app.customer_link_insert_id','',true);
  insert into public.customer_notification_preferences(
    business_id,identity_id,auth_user_id,link_id,client_id,channel,topic,opted_in,consent_at)
  values (v_biz,v_identity,v_customer,v_link,v_client,'in_app','promotion_alerts',true,now());

  -- --------------------------------------------------- fixture: two offers, created UNpublished
  perform set_config('app.v104_promotion_write','on',true);
  insert into public.business_customer_content_v95(
    id,business_id,content_type,branch_id,active,display_order,starts_at,ends_at,metadata)
  values
    (v_offer,v_biz,'offer',null,false,1,v_published_at,now()+interval '30 days',
     jsonb_build_object('schema','nestly.promotion.v104',
                        'published_once_at',v_published_at::text)),
    (v_other,v_biz,'offer',null,false,2,v_published_at,now()+interval '30 days',
     jsonb_build_object('schema','nestly.promotion.v104',
                        'published_once_at',(v_published_at - interval '1 hour')::text));
  insert into public.promotion_branch_scopes_v155(business_id,promotion_id,branch_id)
  values (v_biz,v_offer,v_branch);
  perform set_config('app.v104_promotion_write','',true);

  perform set_config('app.v104_promotion_copy_write','on',true);
  insert into public.business_localized_copy_v95(business_id,entity_type,entity_id,locale,name)
  values (v_biz,'offer',v_offer,'en','V684 Ended Offer'),
         (v_biz,'offer',v_other,'en','V684 Other Offer');
  perform set_config('app.v104_promotion_copy_write','',true);

  -- The customer-visible photo app.enqueue_promotion_alert_v122 demands before it alerts anybody.
  perform set_config('app.v104_promotion_media_write','on',true);
  insert into public.business_media_assets_v95(
    business_id,asset_kind,entity_id,branch_id,bucket_id,object_path,mime_type,alt_en,
    customer_visible)
  values (v_biz,'offer',v_offer,null,'business-public',
          v_biz::text||'/offer/'||v_offer::text||'.png','image/png','V684 fixture offer',true),
         (v_biz,'offer',v_other,null,'business-public',
          v_biz::text||'/offer/'||v_other::text||'.png','image/png','V684 other offer',true);
  perform set_config('app.v104_promotion_media_write','',true);

  -- ---------------------------------------------------------------- SECTION 1: the real publish
  -- active false -> true is what the editor's Publish does; the v122 trigger does the rest.
  perform set_config('app.v104_promotion_write','on',true);
  update public.business_customer_content_v95 set active=true
   where id in (v_offer,v_other) and business_id=v_biz;
  perform set_config('app.v104_promotion_write','',true);

  select count(*)::integer into v_count from public.promotion_alert_runs_v122 run
   where run.promotion_id=v_offer;
  select count(*)::integer into v_inbox from public.customer_in_app_inbox_events event
   where event.business_id=v_biz and event.source_kind='v122_promotion_new';
  select count(*)::integer into v_sends from public.campaign_send_records_v255 record
   where record.business_id=v_biz and record.campaign_ref_id=v_offer;
  if v_count <> 1 then
    raise exception 'S1-T1 FAIL: publishing wrote % watermark rows, expected exactly 1 — the '
      'fixture never reproduced the finding', v_count;
  end if;
  if v_inbox < 1 then
    raise exception 'S1-T1 FAIL: publishing alerted nobody (% inbox events); the watermark above '
      'would then be the v255 finding 1.5 shape, not a real fan-out', v_inbox;
  end if;
  if v_sends < 1 then
    raise exception 'S1-T1 FAIL: publishing wrote no campaign_send_records_v255 row';
  end if;
  insert into v684_evidence values('S1-T1',
    'a real publish alerted '||v_inbox||' customer(s), burned 1 watermark, recorded '||v_sends||' send(s)');

  -- "End", pressed by the owner through the same RPC the button calls.
  perform pg_temp.as_v684_user(v_owner);
  v_res := public.business_delete_promotion_v183(v_biz, v_offer, null);
  reset role;
  if coalesce(v_res->>'mode','') <> 'retired' then
    raise exception 'S1-T2 FAIL: End returned %, expected mode=retired', coalesce(v_res::text,'null');
  end if;
  select * into v_row from public.business_customer_content_v95 where id=v_offer;
  if v_row.id is null or v_row.active or v_row.ends_at > now() then
    raise exception 'S1-T2 FAIL: End left the offer as active=%, ends_at=%',
      v_row.active, v_row.ends_at;
  end if;
  insert into v684_evidence values('S1-T2','End retires: row kept, active=false, ends_at pulled back');

  select count(*)::integer into v_count from public.promotion_alert_runs_v122 run
   where run.promotion_id=v_offer;
  if v_count <> 1 then
    raise exception 'S1-T3 FAIL: retiring released the watermark (% rows left). A retired offer '
      'still exists and must still be muted', v_count;
  end if;
  insert into v684_evidence values('S1-T3','retire does not touch the watermark');

  -- ------------------------------------------------------------------- SECTION 2: the delete
  perform pg_temp.as_v684_user(v_owner);
  begin
    v_res := public.business_delete_promotion_v183(v_biz, v_offer, null);
    v_err := null;
  exception when others then
    v_err := sqlstate||' '||sqlerrm; v_res := null;
  end;
  reset role;
  if v_err is not null then
    raise exception 'S2-T1 FAIL (F028 REGRESSION): deleting a retired, alerted offer raised %', v_err;
  end if;
  if coalesce(v_res->>'mode','') <> 'deleted' then
    raise exception 'S2-T1 FAIL: Delete returned %, expected mode=deleted', coalesce(v_res::text,'null');
  end if;
  insert into v684_evidence values('S2-T1','the owner can delete a retired offer that alerted customers');

  if exists (select 1 from public.business_customer_content_v95 where id=v_offer) then
    raise exception 'S2-T2 FAIL: the content row survived a mode=deleted receipt';
  end if;
  if exists (select 1 from public.business_localized_copy_v95
              where business_id=v_biz and entity_type='offer' and entity_id=v_offer) then
    raise exception 'S2-T2 FAIL: the localized copy was left behind';
  end if;
  if exists (select 1 from public.promotion_branch_scopes_v155 where promotion_id=v_offer) then
    raise exception 'S2-T2 FAIL: the branch scope was left behind';
  end if;
  insert into v684_evidence values('S2-T2','content row, copy and branch scope are gone');

  select count(*)::integer into v_count from public.promotion_alert_runs_v122 run
   where run.promotion_id=v_offer;
  if v_count <> 0 then
    raise exception 'S2-T3 FAIL: % watermark rows still point at a deleted promotion', v_count;
  end if;
  insert into v684_evidence values('S2-T3','the spent watermark was released, not orphaned');

  select count(*)::integer into v_count from public.campaign_send_records_v255 record
   where record.business_id=v_biz and record.campaign_ref_id=v_offer;
  if v_count <> v_sends then
    raise exception 'S2-T4 FAIL: the send record did not survive the delete (% of %)',
      v_count, v_sends;
  end if;
  select count(*)::integer into v_count from public.customer_in_app_inbox_events event
   where event.business_id=v_biz and event.source_kind='v122_promotion_new';
  if v_count <> v_inbox then
    raise exception 'S2-T4 FAIL: the customer inbox lost % of % alerts', v_inbox - v_count, v_inbox;
  end if;
  insert into v684_evidence values('S2-T4',
    'the evidence outlives the offer: '||v_sends||' send record(s) and '||v_inbox||' inbox alert(s) intact');

  select count(*)::integer into v_count from public.audit_log
   where business_id=v_biz and action='promotion.deleted' and entity_id=v_offer;
  if v_count <> 1 then
    raise exception 'S2-T5 FAIL: % audit rows for the delete, expected 1', v_count;
  end if;
  select detail into v_detail from public.audit_log
   where business_id=v_biz and action='promotion.deleted' and entity_id=v_offer;
  if coalesce((v_detail->>'alert_runs_released')::integer,-1) <> 1 then
    raise exception 'S2-T5 FAIL: the audit row records alert_runs_released=%, expected 1',
      v_detail->>'alert_runs_released';
  end if;
  if coalesce(v_detail->>'published_once_at','') = '' then
    raise exception 'S2-T5 FAIL: the audit row does not record that this offer had been published';
  end if;
  insert into v684_evidence values('S2-T5',
    'one audit row, alert_runs_released=1, published_once_at recorded');

  -- --------------------------------------------------------------- SECTION 3: nothing else moved
  select count(*)::integer into v_count from public.promotion_alert_runs_v122 run
   where run.promotion_id=v_other;
  if v_count <> 1 then
    raise exception 'S3-T1 FAIL: the sibling offer has % watermark rows, expected 1 — the release '
      'is not scoped to the promotion being deleted', v_count;
  end if;
  insert into v684_evidence values('S3-T1','the sibling offer keeps its own watermark');

  if (select confdeltype from pg_constraint
       where conname='promotion_alert_runs_v122_promotion_id_fkey') <> 'r' then
    raise exception 'S3-T2 FAIL: the RESTRICT foreign key was loosened; the guard is gone';
  end if;
  begin
    perform set_config('app.v104_promotion_write','on',true);
    delete from public.business_customer_content_v95 where id=v_other and business_id=v_biz;
    perform set_config('app.v104_promotion_write','',true);
    raise exception 'S3-T2 FAIL: a raw DELETE erased an alerted promotion; the FK no longer guards';
  exception when foreign_key_violation then
    perform set_config('app.v104_promotion_write','',true);
  end;
  insert into v684_evidence values('S3-T2',
    'the FK still refuses every route but the audited one');
end
$v684$;

select test, detail from v684_evidence order by test;

rollback;
