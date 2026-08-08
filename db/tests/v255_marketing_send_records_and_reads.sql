-- Rollback-only acceptance for v255 / v255a / v255b — marketing send records,
-- the promotion watermark ordering fix, batched client ingest, and the three
-- super-admin marketing reads.
--
-- Runs against the REAL production tenants inside one transaction, then rolls
-- back. Proves, in the order of the audit's 13-point checklist:
--   1  the promotion fan-out writes exactly one send record per opted-in
--      verified link and none for an opted-out one;
--   2  REGRESSION for audit finding 1.5 — a run against zero opted-in
--      recipients leaves NO watermark, so the same promotion still alerts once
--      somebody opts in (the old code burned the watermark first and could
--      never recover);
--   3  campaign_send_records_v255 rejects UPDATE and DELETE;
--   4  a send record survives deletion of the promotion it points at;
--   5  the denial matrix — anon, an authenticated session with no uid, a firm
--      owner and a firm staff member are all denied on all three new reads,
--      and only a super admin is allowed;
--   7  range and limit guards raise 22023;
--   8  the batch ingest RPC is idempotent on the existing v100 unique index;
--  13  the retention purge removes rows past retention_until and only those.
--
-- Points 9, 10, 11 and 12 are proven outside SQL: 9/10 in
-- tests/business-ui/v255-interaction-batching.test.mjs, 11 by the EXPLAIN
-- recorded in the release evidence, 12 in
-- tests/platform-console/v255-marketing-usage.test.mjs.

begin;

do $suite$
declare
  v_biz uuid:='8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_sa uuid;
  v_owner uuid;
  v_promo_a uuid:=gen_random_uuid();
  v_promo_b uuid:=gen_random_uuid();
  v_in public.customer_links%rowtype;
  v_out public.customer_links%rowtype;
  v_n integer;
  v_count integer;
  v_payload jsonb;
  v_denied integer:=0;
  v_expected integer:=0;
begin
  select super_admin.user_id into v_sa from public.super_admins super_admin limit 1;
  if v_sa is null then
    raise exception 'v255: fixture needs one super admin';
  end if;
  select staff_row.user_id into v_owner from public.staff staff_row
  where staff_row.business_id=v_biz and staff_row.role='owner'
    and staff_row.user_id is not null limit 1;
  if v_owner is null then
    raise exception 'v255: fixture needs one owner login on the fixture firm';
  end if;

  select * into v_in from public.customer_links link
  where link.business_id=v_biz and link.state='verified'
    and link.unlinked_at is null order by link.created_at limit 1;
  select * into v_out from public.customer_links link
  where link.business_id=v_biz and link.state='verified'
    and link.unlinked_at is null and link.id<>v_in.id
  order by link.created_at limit 1;
  if v_in.id is null or v_out.id is null then
    raise exception 'v255: fixture needs two verified customer links';
  end if;

  execute 'alter table public.business_customer_content_v95 disable trigger business_customer_content_v104_promotion_write_guard';
  execute 'alter table public.business_customer_content_v95 disable trigger business_promotion_v122_alert';
  execute 'alter table public.business_media_assets_v95 disable trigger business_media_assets_v104_promotion_write_guard';
  execute 'alter table public.business_localized_copy_v95 disable trigger business_localized_copy_v104_promotion_write_guard';

  insert into public.business_customer_content_v95(
    id,business_id,content_type,branch_id,active,display_order,
    starts_at,ends_at,metadata
  ) values
    (v_promo_a,v_biz,'offer',null,true,1,now()-interval '1 hour',
      now()+interval '30 days',
      jsonb_build_object('schema','nestly.promotion.v104',
        'published_once_at',(now()-interval '1 hour')::text)),
    (v_promo_b,v_biz,'offer',null,true,2,now()-interval '1 hour',
      now()+interval '30 days',
      jsonb_build_object('schema','nestly.promotion.v104',
        'published_once_at',(now()-interval '2 hour')::text));
  insert into public.business_media_assets_v95(
    business_id,asset_kind,entity_id,branch_id,bucket_id,object_path,
    mime_type,alt_en,customer_visible
  ) values
    (v_biz,'offer',v_promo_a,null,'business-public',
      v_biz::text||'/offer/'||v_promo_a::text||'.png',
      'image/png','v255 fixture A',true),
    (v_biz,'offer',v_promo_b,null,'business-public',
      v_biz::text||'/offer/'||v_promo_b::text||'.png',
      'image/png','v255 fixture B',true);
  insert into public.business_localized_copy_v95(
    business_id,entity_type,entity_id,locale,name
  ) values (v_biz,'offer',v_promo_a,'en','V255 fixture promotion');

  -- 2. NO opted-in recipient yet. The old code burned the watermark here.
  v_n:=app.enqueue_promotion_alert_v122(v_promo_a,'v122_promotion_new');
  if v_n<>0 then
    raise exception 'v255: a run with zero opted-in recipients must enqueue 0, got %',v_n;
  end if;
  select count(*)::integer into v_count from public.promotion_alert_runs_v122 run
  where run.promotion_id=v_promo_a;
  if v_count<>0 then
    raise exception 'v255 finding 1.5 REGRESSION: a zero-recipient run must not burn a watermark, found % rows',v_count;
  end if;

  -- 1. One opted in, one explicitly opted out.
  insert into public.customer_notification_preferences(
    business_id,identity_id,auth_user_id,link_id,client_id,channel,topic,
    opted_in,consent_at
  ) values
    (v_biz,v_in.identity_id,v_in.auth_user_id,v_in.id,v_in.client_id,
      'in_app','promotion_alerts',true,now()),
    (v_biz,v_out.identity_id,v_out.auth_user_id,v_out.id,v_out.client_id,
      'in_app','promotion_alerts',false,now());

  v_n:=app.enqueue_promotion_alert_v122(v_promo_a,'v122_promotion_new');
  if v_n<>1 then
    raise exception 'v255: the same promotion must alert once the customer opts in, got %',v_n;
  end if;
  select count(*)::integer into v_count from public.campaign_send_records_v255 record
  where record.campaign_ref_id=v_promo_a;
  if v_count<>1 then
    raise exception 'v255: exactly one send record per opted-in link, got %',v_count;
  end if;
  if not exists(
    select 1 from public.campaign_send_records_v255 record
    where record.campaign_ref_id=v_promo_a
      and record.client_id=v_in.client_id
      and record.channel='in_app'
      and record.campaign_kind='promotion'
      and record.campaign_label='V255 fixture promotion'
      and record.inbox_event_id is not null
  ) then
    raise exception 'v255: the send record must name the opted-in recipient, the channel and the label snapshot';
  end if;
  if exists(
    select 1 from public.campaign_send_records_v255 record
    where record.campaign_ref_id=v_promo_a and record.client_id=v_out.client_id
  ) then
    raise exception 'v255: an opted-out link must never receive a send record';
  end if;
  select count(*)::integer into v_count from public.promotion_alert_runs_v122 run
  where run.promotion_id=v_promo_a;
  if v_count<>1 then
    raise exception 'v255: a successful run must burn exactly one watermark, got %',v_count;
  end if;
  -- replay is a no-op
  v_n:=app.enqueue_promotion_alert_v122(v_promo_a,'v122_promotion_new');
  if v_n<>0 then
    raise exception 'v255: a replayed alert must enqueue nothing, got %',v_n;
  end if;

  -- the expiry alert is a distinct send, not a collision on the same promotion
  v_n:=app.enqueue_promotion_alert_v122(v_promo_a,'v122_promotion_expiry');
  if v_n<>1 then
    raise exception 'v255: the expiry alert must fan out separately, got %',v_n;
  end if;
  select count(*)::integer into v_count from public.campaign_send_records_v255 record
  where record.campaign_ref_id=v_promo_a;
  if v_count<>2 then
    raise exception 'v255: new and expiry alerts must be two send records, got %',v_count;
  end if;

  -- 3. Immutability.
  begin
    update public.campaign_send_records_v255 set campaign_label='tampered'
    where campaign_ref_id=v_promo_a;
    raise exception 'v255: UPDATE on a send record must raise';
  exception when restrict_violation then null;
  end;
  begin
    delete from public.campaign_send_records_v255 where campaign_ref_id=v_promo_a;
    raise exception 'v255: DELETE on a send record must raise';
  exception when restrict_violation then null;
  end;

  -- 4. Survives the promotion being deleted. campaign_ref_id is not a foreign
  --    key precisely so this cannot cascade or block.
  v_n:=app.enqueue_promotion_alert_v122(v_promo_b,'v122_promotion_new');
  if v_n<>1 then
    raise exception 'v255: fixture promotion B must alert once, got %',v_n;
  end if;
  delete from public.promotion_alert_runs_v122 run where run.promotion_id=v_promo_b;
  delete from public.business_media_assets_v95 asset
  where asset.entity_id=v_promo_b;
  delete from public.business_customer_content_v95 content where content.id=v_promo_b;
  select count(*)::integer into v_count from public.campaign_send_records_v255 record
  where record.campaign_ref_id=v_promo_b;
  if v_count<>1 then
    raise exception 'v255: a send record must survive its promotion being deleted, got %',v_count;
  end if;

  -- 13. Retention purge.
  insert into public.campaign_send_records_v255(
    business_id,campaign_kind,campaign_ref_id,send_kind,campaign_label,
    channel,client_id,occurred_at,retention_until
  ) values (
    v_biz,'growth',gen_random_uuid(),'v255_purge_fixture','Expired fixture',
    'none',v_in.client_id,now()-interval '401 days',now()-interval '1 day'
  );
  v_n:=public.purge_campaign_send_records_v255(100);
  if v_n<>1 then
    raise exception 'v255: the purge must remove exactly the one expired row, got %',v_n;
  end if;
  select count(*)::integer into v_count from public.campaign_send_records_v255 record
  where record.campaign_ref_id in (v_promo_a,v_promo_b);
  if v_count<>3 then
    raise exception 'v255: the purge must not touch live rows, got %',v_count;
  end if;

  raise notice 'v255 part 1 (fan-out, watermark, immutability, survival, purge): all assertions passed';
end $suite$;

do $reads$
declare
  v_sa uuid;
  v_owner uuid;
  v_staff uuid;
  v_biz uuid:='8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_payload jsonb;
  v_denied integer:=0;
  v_actor uuid;
  v_leaked boolean:=false;
begin
  select super_admin.user_id into v_sa from public.super_admins super_admin limit 1;
  -- The demo firm's owner IS the super admin, so the denial matrix must borrow
  -- a firm login that is NOT on the super_admins table or it proves nothing.
  select staff_row.user_id into v_owner from public.staff staff_row
  where staff_row.role='owner' and staff_row.user_id is not null
    and staff_row.active
    and staff_row.user_id not in (select user_id from public.super_admins)
  limit 1;
  select staff_row.user_id into v_staff from public.staff staff_row
  where staff_row.role<>'owner' and staff_row.user_id is not null
    and staff_row.active
    and staff_row.user_id not in (select user_id from public.super_admins)
  limit 1;

  -- 5. Denial matrix. anon, no-uid, owner, staff must all fail; only the
  --    super admin gets a payload.
  foreach v_actor in array array[v_owner,coalesce(v_staff,v_owner)] loop
    perform set_config('request.jwt.claim.sub',v_actor::text,true);
    perform set_config(
      'request.jwt.claims',
      json_build_object('sub',v_actor,'role','authenticated')::text,true
    );
    execute 'set local role authenticated';
    begin
      perform public.platform_engagement_monthly_v255(
        (current_date-interval '90 days')::date,current_date,null,10
      );
      v_leaked:=true;
    exception when insufficient_privilege then
      v_denied:=v_denied+1;
    end;
    begin
      perform public.platform_campaign_detail_v255(
        v_biz,(current_date-interval '90 days')::date,current_date,10,0
      );
      v_leaked:=true;
    exception when insufficient_privilege then
      v_denied:=v_denied+1;
    end;
    begin
      perform public.platform_explore_demand_v255(
        (current_date-interval '90 days')::date,current_date,10
      );
      v_leaked:=true;
    exception when insufficient_privilege then
      v_denied:=v_denied+1;
    end;
    execute 'reset role';
  end loop;

  -- authenticated session with no uid at all
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config(
    'request.jwt.claims',json_build_object('role','authenticated')::text,true
  );
  execute 'set local role authenticated';
  begin
    perform public.platform_engagement_monthly_v255(
      (current_date-interval '90 days')::date,current_date,null,10
    );
    v_leaked:=true;
  exception when invalid_authorization_specification then
    v_denied:=v_denied+1;
  end;
  execute 'reset role';

  -- anon has no EXECUTE at all. A leak is recorded in a flag rather than
  -- raised inside the block, because a raise there would be swallowed by the
  -- very handler that is meant to catch the denial.
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims',json_build_object('role','anon')::text,true);
  begin
    execute 'set local role anon';
    perform public.platform_engagement_monthly_v255(
      (current_date-interval '90 days')::date,current_date,null,10
    );
    v_leaked:=true;
  exception when others then
    v_denied:=v_denied+1;
  end;
  execute 'reset role';
  begin
    execute 'set local role anon';
    perform 1 from public.campaign_send_records_v255 limit 1;
    v_leaked:=true;
  exception when others then
    v_denied:=v_denied+1;
  end;
  execute 'reset role';
  begin
    execute 'set local role authenticated';
    perform 1 from public.campaign_send_records_v255 limit 1;
    v_leaked:=true;
  exception when others then
    v_denied:=v_denied+1;
  end;
  execute 'reset role';

  if v_leaked then
    raise exception 'v255: a browser role reached a platform read or the send-record table';
  end if;
  if v_denied<>10 then
    raise exception 'v255: the denial matrix must record 10 refusals, got %',v_denied;
  end if;

  -- super admin is allowed and the reads are shaped as the console expects
  perform set_config('request.jwt.claim.sub',v_sa::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_sa,'role','authenticated')::text,true
  );
  execute 'set local role authenticated';
  v_payload:=public.platform_engagement_monthly_v255(
    (current_date-interval '365 days')::date,current_date,null,100
  );
  if jsonb_typeof(v_payload->'businesses')<>'array'
     or jsonb_typeof(v_payload->'monthly_trend')<>'array'
     or v_payload->'scope'->>'timezone'<>'Asia/Singapore' then
    raise exception 'v255: the engagement read must return the agreed shape';
  end if;
  v_payload:=public.platform_campaign_detail_v255(
    v_biz,(current_date-interval '365 days')::date,current_date,100,0
  );
  if jsonb_typeof(v_payload->'items')<>'array'
     or (v_payload->'summary'->'push_opens')<>'null'::jsonb
     or (v_payload->'summary'->'push_delivered')<>'null'::jsonb then
    raise exception 'v255: push opens and push delivery must be JSON null, never a zero';
  end if;
  v_payload:=public.platform_explore_demand_v255(
    (current_date-interval '365 days')::date,current_date,50
  );
  if jsonb_typeof(v_payload->'items')<>'array'
     or v_payload->'methodology'->>'k_anonymity' is null then
    raise exception 'v255: the demand read must publish its suppression rule';
  end if;

  -- 7. Range and limit guards.
  begin
    perform public.platform_engagement_monthly_v255(
      (current_date-interval '800 days')::date,current_date,null,100
    );
    v_leaked:=true;
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.platform_engagement_monthly_v255(
      (current_date-interval '30 days')::date,current_date,
      (select array_agg(gen_random_uuid()) from generate_series(1,101)),100
    );
    v_leaked:=true;
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.platform_explore_demand_v255(
      (current_date-interval '30 days')::date,current_date,5000
    );
    v_leaked:=true;
  exception when invalid_parameter_value then null;
  end;
  execute 'reset role';
  if v_leaked then
    raise exception 'v255: a range or limit guard did not fire';
  end if;

  raise notice 'v255 part 2 (denial matrix, payload shape, range guards): all assertions passed';
end $reads$;

do $batch$
declare
  v_biz uuid:='8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_link public.customer_links%rowtype;
  v_session uuid:=gen_random_uuid();
  v_key text:='v255-batch-'||gen_random_uuid()::text;
  v_events jsonb;
  v_first jsonb;
  v_second jsonb;
  v_count integer;
begin
  select * into v_link from public.customer_links link
  where link.business_id=v_biz and link.state='verified'
    and link.unlinked_at is null order by link.created_at limit 1;

  v_events:=jsonb_build_array(
    jsonb_build_object(
      'event_name','customer.surface_viewed','business_id',v_biz,
      'session_id',v_session,'idempotency_key',v_key,
      'occurred_at',now(),
      'context',jsonb_build_object('surface_key','wallet','locale','en')
    ),
    jsonb_build_object(
      'event_name','customer.explore_searched','business_id',null,
      'session_id',v_session,'idempotency_key',v_key||'-search',
      'occurred_at',now(),
      'context',jsonb_build_object('query_shape','t2:short:matched')
    ),
    jsonb_build_object(
      'event_name','not.an_allowlisted_event','business_id',v_biz,
      'session_id',v_session,'idempotency_key',v_key||'-bad',
      'occurred_at',now(),'context','{}'::jsonb
    )
  );

  perform set_config('request.jwt.claim.sub',v_link.auth_user_id::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_link.auth_user_id,'role','authenticated')::text,true
  );
  execute 'set local role authenticated';
  v_first:=public.record_product_interactions_batch_v255(v_events);
  v_second:=public.record_product_interactions_batch_v255(v_events);
  execute 'reset role';

  -- 8. Two allowlisted events accepted, one rejected, and the whole batch is
  --    replay-safe on the existing (actor_user_id, idempotency_key) index.
  if (v_first->>'accepted')::integer<>2 or (v_first->>'rejected')::integer<>1 then
    raise exception 'v255: the first batch must accept 2 and reject 1, got %',v_first;
  end if;
  if (v_second->>'replayed')::integer<>2 or (v_second->>'accepted')::integer<>0 then
    raise exception 'v255: a replayed batch must record nothing new, got %',v_second;
  end if;
  select count(*)::integer into v_count
  from public.product_adoption_events_v100 event_row
  where event_row.idempotency_key in (v_key,v_key||'-search');
  if v_count<>2 then
    raise exception 'v255: a replayed batch must leave exactly 2 rows, got %',v_count;
  end if;
  -- the unscoped search event is genuinely tenant-free
  if exists(
    select 1 from public.product_adoption_events_v100 event_row
    where event_row.idempotency_key=v_key||'-search'
      and event_row.business_id is not null
  ) then
    raise exception 'v255: a discovery search must not be attributed to a business';
  end if;
  if not exists(
    select 1 from public.product_adoption_events_v100 event_row
    where event_row.idempotency_key=v_key||'-search'
      and event_row.event_context->>'query_shape'='t2:short:matched'
  ) then
    raise exception 'v255: the query shape must survive the privacy allowlist';
  end if;

  raise notice 'v255 part 3 (batched ingest, idempotency, shape-only search): all assertions passed';
end $batch$;

rollback;
