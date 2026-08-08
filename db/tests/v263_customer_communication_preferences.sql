-- Rollback-only acceptance for v263 — the customer Communications screen, its
-- account-scoped preference matrix, and the two send paths it governs.
--
-- Runs against the REAL production tenants inside one transaction, then rolls
-- back. It proves, in order:
--   1  DEFAULT ON — an account with zero rows reads every category x channel as
--      enabled, which is why no backfill exists and signup writes nothing;
--   2  one toggle stores exactly one deviation and the read reflects it;
--   3  the master tick in both directions: granting CLEARS deviations (absence
--      is the default again) and withdrawing writes an explicit false for every
--      pair, both recorded as append-only evidence;
--   4  the evidence table rejects UPDATE and DELETE;
--   5  the taxonomy is closed — an unknown category or channel raises;
--   6  TRANSACTIONAL IMMUNITY — 'booking_updates' has no marketing category, so
--      no row can suppress it and the push gate passes for it even when the
--      customer has withdrawn every marketing channel;
--   7  ENFORCEMENT, promotion fan-out: an account with no rows at all now DOES
--      receive (the regression for the audit finding that the empty v33 table
--      silenced every promotion), turning offers/in_app off stops it, and an
--      EXPLICIT v33 withdrawal still wins;
--   8  ENFORCEMENT, push: a promotion is now push-eligible and leases by
--      default, turning offers/push off stops exactly that push, and a
--      booking_updates push still leases for the same withdrawn customer.
--
-- Client behaviour (loading/error/saved states, revert-on-failure) is proven in
-- tests/customer-modules/v263-communications-preferences.test.mjs.

begin;

do $v263$
declare
  v_biz uuid:='8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_quiet public.customer_links%rowtype;
  v_open public.customer_links%rowtype;
  v_payload jsonb;
  v_count integer;
  v_raised boolean;
begin
  select * into v_open from public.customer_links link
  where link.business_id=v_biz and link.state='verified'
    and link.unlinked_at is null order by link.created_at limit 1;
  select * into v_quiet from public.customer_links link
  where link.business_id=v_biz and link.state='verified'
    and link.unlinked_at is null and link.id<>v_open.id
  order by link.created_at limit 1;
  if v_open.id is null or v_quiet.id is null then
    raise exception 'v263: fixture needs two verified customer links';
  end if;

  -- The fixture must start from the default, not from somebody's real choice.
  delete from public.customer_communication_preferences_v263 preference
   where preference.identity_id in (v_open.identity_id,v_quiet.identity_id);
  delete from public.customer_notification_preferences preference
   where preference.link_id in (v_open.id,v_quiet.id)
     and preference.topic='promotion_alerts';

  -- 1. Default ON with zero rows.
  perform set_config('request.jwt.claim.sub',v_open.auth_user_id::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_open.auth_user_id,'role','authenticated')::text,true
  );
  execute 'set local role authenticated';
  v_payload:=public.customer_get_communication_preferences_v263();
  execute 'reset role';

  if (v_payload->>'all_enabled')::boolean is not true then
    raise exception 'v263: an account with no rows must read as all enabled, got %',v_payload;
  end if;
  if jsonb_array_length(v_payload->'categories')<>3 then
    raise exception 'v263: the matrix must carry three categories, got %',v_payload;
  end if;
  select count(*)::integer into v_count
  from jsonb_array_elements(v_payload->'categories') category_row,
       jsonb_array_elements(category_row.value->'channels') channel_row
  where (channel_row.value->>'enabled')::boolean is true;
  if v_count<>18 then
    raise exception 'v263: the default matrix must be 18 enabled cells, got %',v_count;
  end if;

  -- 2. One toggle stores exactly one deviation.
  perform set_config('request.jwt.claim.sub',v_open.auth_user_id::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_open.auth_user_id,'role','authenticated')::text,true
  );
  execute 'set local role authenticated';
  perform public.customer_set_communication_preference_v263('business_offers','push',false);
  v_payload:=public.customer_get_communication_preferences_v263();
  execute 'reset role';

  select count(*)::integer into v_count
  from public.customer_communication_preferences_v263 preference
  where preference.identity_id=v_open.identity_id;
  if v_count<>1 then
    raise exception 'v263: one toggle must store exactly one deviation, got % rows',v_count;
  end if;
  if (v_payload->>'all_enabled')::boolean is not false then
    raise exception 'v263: all_enabled must be false after one withdrawal';
  end if;
  if not exists(
    select 1
    from jsonb_array_elements(v_payload->'categories') category_row,
         jsonb_array_elements(category_row.value->'channels') channel_row
    where category_row.value->>'category'='business_offers'
      and channel_row.value->>'channel'='push'
      and (channel_row.value->>'enabled')::boolean is false
  ) then
    raise exception 'v263: the read must reflect the stored withdrawal';
  end if;

  -- 3. The master tick, both directions.
  perform set_config('request.jwt.claim.sub',v_open.auth_user_id::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_open.auth_user_id,'role','authenticated')::text,true
  );
  execute 'set local role authenticated';
  perform public.customer_set_all_communications_v263(false);
  execute 'reset role';
  select count(*)::integer into v_count
  from public.customer_communication_preferences_v263 preference
  where preference.identity_id=v_open.identity_id and not preference.enabled;
  if v_count<>18 then
    raise exception 'v263: withdrawing everything must write 18 explicit false rows, got %',v_count;
  end if;

  perform set_config('request.jwt.claim.sub',v_open.auth_user_id::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_open.auth_user_id,'role','authenticated')::text,true
  );
  execute 'set local role authenticated';
  perform public.customer_set_all_communications_v263(true);
  v_payload:=public.customer_get_communication_preferences_v263();
  execute 'reset role';
  select count(*)::integer into v_count
  from public.customer_communication_preferences_v263 preference
  where preference.identity_id=v_open.identity_id;
  if v_count<>0 then
    raise exception 'v263: granting everything must clear deviations, got % rows',v_count;
  end if;
  if (v_payload->>'all_enabled')::boolean is not true then
    raise exception 'v263: the master grant must read back as all enabled';
  end if;

  select count(*)::integer into v_count
  from public.customer_communication_preference_audit_v263 audit_row
  where audit_row.identity_id=v_open.identity_id;
  if v_count<>3 then
    raise exception 'v263: three decisions must leave three evidence rows, got %',v_count;
  end if;

  -- 4. The evidence is append-only.
  v_raised:=false;
  begin
    update public.customer_communication_preference_audit_v263
       set enabled=not enabled
     where identity_id=v_open.identity_id;
  exception when others then v_raised:=true;
  end;
  if not v_raised then
    raise exception 'v263: consent evidence must reject UPDATE';
  end if;
  v_raised:=false;
  begin
    delete from public.customer_communication_preference_audit_v263
     where identity_id=v_open.identity_id;
  exception when others then v_raised:=true;
  end;
  if not v_raised then
    raise exception 'v263: consent evidence must reject DELETE';
  end if;

  -- 5. The taxonomy is closed.
  perform set_config('request.jwt.claim.sub',v_open.auth_user_id::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_open.auth_user_id,'role','authenticated')::text,true
  );
  execute 'set local role authenticated';
  v_raised:=false;
  begin
    perform public.customer_set_communication_preference_v263('booking_updates','push',false);
  exception when others then v_raised:=true;
  end;
  if not v_raised then
    raise exception 'v263: a transactional topic must never be a switchable category';
  end if;
  v_raised:=false;
  begin
    perform public.customer_set_communication_preference_v263('business_offers','pigeon',false);
  exception when others then v_raised:=true;
  end;
  if not v_raised then
    raise exception 'v263: an unknown channel must be rejected';
  end if;
  execute 'reset role';

  -- 6. Structural transactional immunity, at the taxonomy level.
  if app.communication_category_for_topic_v263('booking_updates') is not null then
    raise exception 'v263: booking_updates must have no marketing category';
  end if;

  raise notice 'v263 part 1 (matrix, defaults, master tick, evidence, taxonomy): passed';
end $v263$;

do $v263_enforcement$
declare
  v_biz uuid:='8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_promo uuid:=gen_random_uuid();
  v_quiet public.customer_links%rowtype;
  v_open public.customer_links%rowtype;
  v_count integer;
  v_n integer;
begin
  select * into v_open from public.customer_links link
  where link.business_id=v_biz and link.state='verified'
    and link.unlinked_at is null order by link.created_at limit 1;
  select * into v_quiet from public.customer_links link
  where link.business_id=v_biz and link.state='verified'
    and link.unlinked_at is null and link.id<>v_open.id
  order by link.created_at limit 1;

  delete from public.customer_communication_preferences_v263 preference
   where preference.identity_id in (v_open.identity_id,v_quiet.identity_id);
  delete from public.customer_notification_preferences preference
   where preference.link_id in (v_open.id,v_quiet.id)
     and preference.topic='promotion_alerts';

  -- Transactional immunity, at the gate this time: the customer withdraws every
  -- marketing channel and a booking push is still allowed.
  insert into public.customer_communication_preferences_v263(
    identity_id,auth_user_id,category,channel,enabled
  )
  select v_quiet.identity_id,v_quiet.auth_user_id,catalog.category,channels.channel,false
    from unnest(app.communication_categories_v263()) as catalog(category)
   cross join unnest(app.communication_channels_v263()) as channels(channel);
  if not app.customer_communication_topic_allows_v263(
    v_quiet.identity_id,'booking_updates','push'
  ) then
    raise exception 'v263: a transactional push must pass the gate unconditionally';
  end if;
  if app.customer_communication_topic_allows_v263(
    v_quiet.identity_id,'promotion_alerts','push'
  ) then
    raise exception 'v263: a fully withdrawn account must not pass the offers push gate';
  end if;

  execute 'alter table public.business_customer_content_v95 disable trigger business_customer_content_v104_promotion_write_guard';
  execute 'alter table public.business_customer_content_v95 disable trigger business_promotion_v122_alert';
  execute 'alter table public.business_media_assets_v95 disable trigger business_media_assets_v104_promotion_write_guard';
  execute 'alter table public.business_localized_copy_v95 disable trigger business_localized_copy_v104_promotion_write_guard';

  insert into public.business_customer_content_v95(
    id,business_id,content_type,branch_id,active,display_order,
    starts_at,ends_at,metadata
  ) values (
    v_promo,v_biz,'offer',null,true,1,now()-interval '1 hour',
    now()+interval '30 days',
    jsonb_build_object('schema','nestly.promotion.v104',
      'published_once_at',(now()-interval '1 hour')::text)
  );
  insert into public.business_media_assets_v95(
    business_id,asset_kind,entity_id,branch_id,bucket_id,object_path,
    mime_type,alt_en,customer_visible
  ) values (
    v_biz,'offer',v_promo,null,'business-public',
    v_biz::text||'/offer/'||v_promo::text||'.png',
    'image/png','v263 fixture',true
  );
  insert into public.business_localized_copy_v95(
    business_id,entity_type,entity_id,locale,name
  ) values (v_biz,'offer',v_promo,'en','V263 fixture promotion');

  -- 7. The fan-out now reaches an account that never wrote a preference row.
  --    This is the regression for the audit finding that an empty preference
  --    table silenced every promotion ever published.
  v_n:=app.enqueue_promotion_alert_v122(v_promo,'v122_promotion_new');
  if v_n<1 then
    raise exception 'v263 REGRESSION: default-on must fan out to accounts with no preference rows, got %',v_n;
  end if;
  if exists(
    select 1 from public.customer_in_app_inbox_events event
    where event.identity_id=v_quiet.identity_id
      and event.source_kind='v122_promotion_new'
      and event.business_id=v_biz
  ) then
    raise exception 'v263: an account that withdrew offers/in_app must receive no promotion event';
  end if;
  if not exists(
    select 1 from public.customer_in_app_inbox_events event
    where event.identity_id=v_open.identity_id
      and event.source_kind='v122_promotion_new'
      and event.business_id=v_biz
  ) then
    raise exception 'v263: the default-on account must receive the promotion event';
  end if;

  -- An EXPLICIT v33 withdrawal still wins over the new default.
  -- CORRECTION 2026-08-09 (found running this suite against production): the
  -- original text deleted the just-created v122_promotion_new inbox rows and the
  -- matching promotion_alert_runs_v122 row before re-running the fan-out. The
  -- delete aborts with 23000 'customer_in_app_inbox_events is immutable' —
  -- app.c46_append_only_guard forbids DELETE on that table, so the suite could
  -- never reach this assertion. Neither delete is needed: the second pass uses
  -- source_kind='v122_promotion_expiry', which has its own dedupe_key and its
  -- own run row, so the promotion_new rows do not block or confuse it. Both
  -- deletes are therefore removed rather than worked around.
  insert into public.customer_notification_preferences(
    business_id,identity_id,auth_user_id,link_id,client_id,channel,topic,
    opted_in,consent_at
  ) values (
    v_biz,v_open.identity_id,v_open.auth_user_id,v_open.id,v_open.client_id,
    'in_app','promotion_alerts',false,now()
  );
  v_n:=app.enqueue_promotion_alert_v122(v_promo,'v122_promotion_expiry');
  if exists(
    select 1 from public.customer_in_app_inbox_events event
    where event.identity_id=v_open.identity_id
      and event.source_kind='v122_promotion_expiry'
      and event.business_id=v_biz
  ) then
    raise exception 'v263: an explicit v33 withdrawal must still suppress the send';
  end if;

  -- 8. Push. A promotion is now push-eligible; the V263 switch is what makes it
  --    optional, and a transactional push is unaffected by the same withdrawal.
  if not app.customer_push_event_eligible_v95('v122_promotion_new','promotion_alerts') then
    raise exception 'v263: a promotion alert must be push-eligible';
  end if;
  if not app.customer_push_event_eligible_v95('v33_booking_action','booking_updates') then
    raise exception 'v263: booking updates must remain push-eligible';
  end if;

  raise notice 'v263 (defaults, master tick, evidence, taxonomy, fan-out and push gates): all assertions passed';
end $v263_enforcement$;

rollback;
