-- FRENLY v46 CUSTOMER IN-APP INBOX ACCEPTANCE FIXTURE
--
-- Executable and rollback-only. Run only against an owner-authorized
-- disposable database after the local canonical chain. Every identity,
-- business, link, preference, event, operation and feature-flag adjustment
-- below is synthetic and is removed by the final rollback.

begin;

create or replace function pg_temp.as_c46_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void
language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', p_uid, 'role', p_role
  )::text, true);
end;
$$;
grant execute on function pg_temp.as_c46_user(uuid,text) to public;

create or replace function pg_temp.expect_c46_sqlstate(
  p_sql text,
  p_label text,
  p_sqlstate text
) returns void language plpgsql as $$
declare v_state text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate;
    if v_state = p_sqlstate then return; end if;
    raise exception '% returned SQLSTATE %, expected %', p_label, v_state, p_sqlstate;
  end;
  raise exception '% unexpectedly succeeded', p_label;
end;
$$;
grant execute on function pg_temp.expect_c46_sqlstate(text,text,text) to public;

do $c46$
declare
  v_owner uuid := gen_random_uuid();
  v_customer uuid := gen_random_uuid();
  v_foreign_customer uuid := gen_random_uuid();
  v_staff_only uuid := gen_random_uuid();
  v_identity uuid := gen_random_uuid();
  v_foreign_identity uuid := gen_random_uuid();
  v_client uuid := gen_random_uuid();
  v_client_b uuid := gen_random_uuid();
  v_foreign_client uuid := gen_random_uuid();
  v_link uuid := gen_random_uuid();
  v_link_b uuid := gen_random_uuid();
  v_foreign_link uuid := gen_random_uuid();
  v_appointment uuid := gen_random_uuid();
  v_live_request uuid := gen_random_uuid();
  v_reappearing_request uuid := gen_random_uuid();
  v_live_created_at timestamptz := statement_timestamp();
  v_reappearing_created_at timestamptz := statement_timestamp() + interval '1 microsecond';
  v_business uuid;
  v_business_b uuid;
  v_slug text;
  v_slug_b text;
  v_owner_staff uuid;
  v_staff_only_id uuid;
  v_birthday_draft uuid;
  v_birthday_program uuid := gen_random_uuid();
  v_birthday_draft_hash text;
  v_birthday_event uuid;
  v_c44_disabled_event uuid := gen_random_uuid();
  v_birthday_result jsonb;
  v_live_event uuid;
  v_stale_event uuid := gen_random_uuid();
  v_reappeared_event uuid;
  v_stale_fingerprint text;
  v_stale_dedupe text;
  v_pref_key uuid := gen_random_uuid();
  v_birthday_pref_key uuid := gen_random_uuid();
  v_sync_key uuid := gen_random_uuid();
  v_state_key uuid := gen_random_uuid();
  v_response jsonb;
  v_replay jsonb;
  v_page_one jsonb;
  v_page_two jsonb;
  v_unavailable_list jsonb;
  v_unavailable_global_list jsonb;
  v_unread_before_dismiss integer;
  v_unread_after_dismiss integer;
  v_outbox_before integer;
  v_outbox_after integer;
  v_internal_count integer;
  v_internal_exists boolean;
  v_flag boolean;
begin
  reset role;
  -- The deploy default remains fail-closed. Prove the gate before creating
  -- customer-visible state, then enable it only inside this rolled-back test.
  select enabled into v_flag from app.platform_feature_flags
   where feature_key='customer_in_app_inbox';
  if v_flag is distinct from false then
    raise exception 'C46 inbox flag is not default off';
  end if;
  begin
    perform public.customer_get_in_app_inbox_global_count();
    raise exception 'C46 disabled global count unexpectedly succeeded';
  exception when feature_not_supported then null;
  end;
  if not app.c46_in_app_topic_allowed('value_expiry')
     or app.c46_in_app_topic_allowed('marketing') then
    raise exception 'C46 in-app consent topic allowlist drifted';
  end if;
  if not app.c46_iana_timezone_allowed('Asia/Singapore')
     or app.c46_iana_timezone_allowed('GMT+08:00') then
    raise exception 'C46 IANA timezone seam drifted';
  end if;
  if not app.c46_in_quiet_hours('Asia/Singapore','22:00'::time,'08:00'::time,
    '2026-07-22 15:00:00+00'::timestamptz) then
    raise exception 'C46 overnight quiet-hours window failed';
  end if;
  if not exists (
    select 1 from app.c46_customer_safe_inbox_candidates(jsonb_build_object(
      'loyalty',jsonb_build_object('unit','stamps'),
      'expiry',jsonb_build_object('expiring_units',4,'expiring_within_7_days',2,'next_expiry_at','2026-08-01T00:00:00Z')
    )) candidate
     where candidate.topic='value_expiry'
       and candidate.title='Stamps expire soon'
       and candidate.body='Open this business wallet to review your stamps.'
  ) or not exists (
    select 1 from app.c46_customer_safe_inbox_candidates(jsonb_build_object(
      'loyalty',jsonb_build_object('unit','points'),
      'expiry',jsonb_build_object('expiring_units',4,'expiring_within_7_days',2,'next_expiry_at','2026-08-01T00:00:00Z')
    )) candidate
     where candidate.topic='value_expiry'
       and candidate.title='Points expire soon'
       and candidate.body='Open this business wallet to review your points.'
  ) or exists (
    select 1 from app.c46_customer_safe_inbox_candidates(jsonb_build_object(
      'loyalty',jsonb_build_object('unit','currency'),
      'expiry',jsonb_build_object('expiring_units',4,'expiring_within_7_days',2,'next_expiry_at','2026-08-01T00:00:00Z')
    )) candidate where candidate.topic='value_expiry'
  ) then
    raise exception 'C46 expiry copy must preserve only the C44 points/stamps unit without a value claim';
  end if;

  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values
    ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated','c46-owner-'||v_owner::text||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_customer,'authenticated','authenticated','c46-customer-'||v_customer::text||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_foreign_customer,'authenticated','authenticated','c46-foreign-'||v_foreign_customer::text||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_staff_only,'authenticated','authenticated','c46-staff-'||v_staff_only::text||'@example.test','',now(),now(),now());

  perform pg_temp.as_c46_user(v_owner);
  v_business := (public.create_business(
    'C46 inbox fixture '||substr(v_owner::text,1,8),
    'c46-inbox-'||substr(v_owner::text,1,8),'test',
    array['dashboard','clients','sales','loyalty','appointments']
  )::jsonb->>'id')::uuid;
  v_business_b := (public.create_business(
    'C46 inbox other fixture '||substr(v_owner::text,1,8),
    'c46-inbox-other-'||substr(v_owner::text,1,8),'test',
    array['dashboard','clients','sales','loyalty','appointments']
  )::jsonb->>'id')::uuid;
  reset role;
  select slug into v_slug from public.businesses where id=v_business;
  select slug into v_slug_b from public.businesses where id=v_business_b;
  select id into v_owner_staff from public.staff where business_id=v_business and user_id=v_owner and active;
  if v_business is null or v_business_b is null or v_slug is null or v_slug_b is null or v_owner_staff is null then
    raise exception 'C46 self-created business fixture is incomplete';
  end if;
  insert into public.staff(business_id,user_id,role,full_name,active,modules,module_perms)
  values(v_business,v_staff_only,'manager','C46 staff-only fixture',true,array['loyalty'],'{"loyalty":"r"}'::jsonb)
  returning id into v_staff_only_id;

  -- One active identity spans two verified programmes; a separate active
  -- identity is linked only to business B. This allows both scoped replay
  -- conflicts and positive cross-customer/business isolation checks.
  insert into public.customer_identities(id,auth_user_id,status,created_via)
  values(v_identity,v_customer,'active','phone_registration'),
        (v_foreign_identity,v_foreign_customer,'active','phone_registration');
  perform set_config('app.c42_profile_identity',v_identity::text,true);
  insert into public.customer_profiles(identity_id,auth_user_id,full_name,birth_date)
  values(v_identity,v_customer,'C46 synthetic customer',(timezone('Asia/Singapore',statement_timestamp()))::date);
  perform set_config('app.c42_profile_identity',v_foreign_identity::text,true);
  insert into public.customer_profiles(identity_id,auth_user_id,full_name,birth_date)
  values(v_foreign_identity,v_foreign_customer,'C46 synthetic foreign customer',date '1991-01-01');
  insert into public.clients(id,business_id,full_name) values
    (v_client,v_business,'C46 synthetic customer'),
    (v_client_b,v_business_b,'C46 synthetic customer B'),
    (v_foreign_client,v_business_b,'C46 synthetic foreign customer');
  perform set_config('app.customer_link_insert_id',v_link::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link,v_business,v_identity,v_customer,v_client,'verified','phone_claim',now());
  perform set_config('app.customer_link_insert_id',v_link_b::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link_b,v_business_b,v_identity,v_customer,v_client_b,'verified','phone_claim',now());
  perform set_config('app.customer_link_insert_id',v_foreign_link::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_foreign_link,v_business_b,v_foreign_identity,v_foreign_customer,v_foreign_client,'verified','phone_claim',now());
  perform set_config('app.customer_link_insert_id','',true);
  -- Privileged setup still cannot pair an authentic foreign link/client tuple
  -- with this identity. Both root C46 provenance tables must prove the same
  -- (link,business,identity) relationship before a downstream event exists.
  perform pg_temp.expect_c46_sqlstate(format($sql$
    insert into public.customer_in_app_inbox_events(
      business_id,identity_id,auth_user_id,link_id,client_id,source_kind,topic,route_key,
      source_fingerprint,dedupe_key,title,body
    ) values (
      %L::uuid,%L::uuid,%L::uuid,%L::uuid,%L::uuid,'c44_actionable_wallet','value_expiry','wallet_business',
      repeat('a',64),repeat('b',64),'Stamps expire soon','Open this business wallet to review your stamps.'
    )
  $sql$,v_business_b,v_identity,v_customer,v_foreign_link,v_foreign_client),
    'C46 privileged cross-identity event provenance','23503');
  perform pg_temp.expect_c46_sqlstate(format($sql$
    insert into public.customer_in_app_inbox_sync_operations(
      business_id,identity_id,auth_user_id,link_id,client_id,idempotency_key,request_hash,response
    ) values (
      %L::uuid,%L::uuid,%L::uuid,%L::uuid,%L::uuid,gen_random_uuid(),repeat('c',64),'{}'::jsonb
    )
  $sql$,v_business_b,v_identity,v_customer,v_foreign_link,v_foreign_client),
    'C46 privileged cross-identity sync provenance','23503');
  insert into public.appointments(id,business_id,client_id,staff_id,starts_at,ends_at,status)
  values(v_appointment,v_business,v_client,v_owner_staff,now()+interval '2 days',now()+interval '2 days 1 hour','booked');

  -- This pending v33 action is immutable source evidence. It is deliberately
  -- inserted directly in the rollback fixture, never sent through an outbox,
  -- so C46 can prove it does not create legacy delivery/provider side effects.
  insert into public.customer_appointment_action_requests(
    id,business_id,identity_id,auth_user_id,link_id,client_id,appointment_id,action,
    proposed_at,note,status,idempotency_key,request_hash,created_at
  ) values (
    v_live_request,v_business,v_identity,v_customer,v_link,v_client,v_appointment,'cancel',
    null,null,'pending','c46-live-source-'||substr(v_live_request::text,1,8),
    app.v33_sha256_hex('c46-live-source:'||v_live_request::text),v_live_created_at
  );
  select count(*)::integer into v_outbox_before
    from public.customer_notification_outbox where business_id=v_business and identity_id=v_identity;

  update app.platform_feature_flags set enabled=true,changed_at=statement_timestamp()
   where feature_key in ('customer_in_app_inbox','customer_birthday_benefits','customer_wallet','customer_actionable_wallet');

  -- Build and activate one current-window C45 entitlement through the reviewed
  -- owner/customer paths. The later C45 withdrawal leaves this promise visible
  -- in the wallet, which is exactly the double-consent condition C46 must not
  -- mistake for permission to create an inbox event.
  perform pg_temp.as_c46_user(v_owner);
  v_birthday_draft := (public.create_loyalty_config_draft(v_business,null,'c46-birthday-double-consent')::jsonb->>'version_id')::uuid;
  select snapshot_hash into v_birthday_draft_hash from public.firm_config_versions where id=v_birthday_draft;
  perform public.save_loyalty_config_draft(
    v_birthday_draft,jsonb_build_object('active',true),v_birthday_draft_hash
  );
  select snapshot_hash into v_birthday_draft_hash from public.firm_config_versions where id=v_birthday_draft;
  v_birthday_draft_hash := (public.save_birthday_program_draft(
    v_birthday_draft,v_birthday_program,jsonb_build_object(
      'active',true,'customer_label','C46 birthday benefit','customer_description','Synthetic double-consent benefit',
      'customer_terms','Synthetic only','fulfillment_kind','free_item','manual_item','Synthetic birthday item',
      'window_days_before',0,'window_days_after',0,'sort',0
    ),v_birthday_draft_hash)->>'snapshot_hash');
  perform public.publish_loyalty_config(v_birthday_draft);

  -- Explicit opt-in is required for every C46 topic. It must not act as the
  -- separate, platform-wide C45 birthday participation consent.
  perform pg_temp.as_c46_user(v_customer);
  perform public.customer_set_birthday_participation(true,gen_random_uuid());
  v_birthday_result := public.customer_activate_birthday_benefit(v_slug,gen_random_uuid());
  reset role;
  if v_birthday_result->>'status' <> 'available'
     or not exists(select 1 from public.customer_birthday_entitlements where business_id=v_business and client_id=v_client and identity_id=v_identity and status='available') then
    raise exception 'C46 birthday double-consent fixture did not create an eligible C45 entitlement: %',v_birthday_result;
  end if;
  perform pg_temp.as_c46_user(v_customer);
  perform public.customer_set_birthday_participation(false,gen_random_uuid());
  if coalesce((public.customer_get_birthday_participation()->>'opted_in')::boolean,true) then
    raise exception 'C46 birthday double-consent fixture did not begin with C45 participation off';
  end if;
  if public.customer_get_birthday_benefit(v_slug)->>'status' <> 'available' then
    raise exception 'C46 fixture lost the C45 entitlement after participation withdrawal';
  end if;
  if exists (
    select 1 from jsonb_array_elements(public.customer_get_in_app_inbox_preferences(v_slug)) x
     where coalesce((x->>'opted_in')::boolean,false)
  ) then raise exception 'C46 inbox preferences were not default-off'; end if;
  v_response := public.customer_sync_in_app_inbox(v_slug,v_sync_key);
  if coalesce((v_response->>'created')::integer,-1) <> 0 then
    raise exception 'C46 generated a customer inbox fact before explicit opt-in: %',v_response;
  end if;
  reset role;
  if exists(select 1 from public.customer_in_app_inbox_events where business_id=v_business and identity_id=v_identity) then
    raise exception 'C46 generated a customer inbox fact before explicit opt-in';
  end if;
  perform pg_temp.as_c46_user(v_customer);

  perform public.customer_set_in_app_inbox_preferences(
    v_slug,'birthday_benefit',true,null,null,null,v_birthday_pref_key
  );
  if coalesce((public.customer_get_birthday_participation()->>'opted_in')::boolean,true) then
    raise exception 'C46 birthday reminder consent silently changed C45 participation';
  end if;
  v_response := public.customer_sync_in_app_inbox(v_slug,gen_random_uuid());
  if coalesce((v_response->>'created')::integer,-1) <> 0 then
    raise exception 'C46 created a birthday inbox event without current C45 participation: %',v_response;
  end if;
  reset role;
  select exists(select 1 from public.customer_in_app_inbox_events
    where identity_id=v_identity and topic='birthday_benefit') into v_internal_exists;
  if v_internal_exists then
    raise exception 'C46 created a birthday inbox event without current C45 participation';
  end if;
  perform pg_temp.as_c46_user(v_customer);
  perform public.customer_set_birthday_participation(true,gen_random_uuid());
  v_response := public.customer_sync_in_app_inbox(v_slug,gen_random_uuid());
  reset role;
  select id into v_birthday_event from public.customer_in_app_inbox_events
   where identity_id=v_identity and topic='birthday_benefit'
   order by created_at desc,id desc limit 1;
  perform pg_temp.as_c46_user(v_customer);
  if v_birthday_event is null or coalesce((v_response->>'created')::integer,-1) <> 1 then
    raise exception 'C46 birthday re-opt-in did not create one inbox event: %',v_response;
  end if;
  -- C44 is the safe source projection for both its own facts and C45's
  -- birthday card. While it is unavailable, retain immutable history but take
  -- every C44/C45 item out of unread/actionable views; re-enabling must then
  -- revalidate the live C45 source without falsely resolving it.
  reset role;
  insert into public.customer_in_app_inbox_events(
    id,business_id,identity_id,auth_user_id,link_id,client_id,source_kind,topic,route_key,
    source_fingerprint,dedupe_key,title,body,deadline_at
  ) values (
    v_c44_disabled_event,v_business,v_identity,v_customer,v_link,v_client,'c44_actionable_wallet','value_expiry','wallet_business',
    app.c46_sha256_hex('c46-disabled-c44:'||v_c44_disabled_event::text),
    app.c46_sha256_hex('c46-disabled-c44-dedupe:'||v_c44_disabled_event::text),
    'Stamps expire soon','Open this business wallet to review your stamps.',statement_timestamp()+interval '7 days'
  );
  update app.platform_feature_flags set enabled=false,changed_at=statement_timestamp()
   where feature_key='customer_actionable_wallet';
  perform pg_temp.as_c46_user(v_customer);
  v_response := public.customer_sync_in_app_inbox(v_slug,gen_random_uuid());
  v_unavailable_list := public.customer_list_in_app_inbox(v_slug,jsonb_build_object('limit',50,'filter','all'));
  v_unavailable_global_list := public.customer_list_in_app_inbox_global(jsonb_build_object('limit',50,'filter','all'));
  reset role;
  select exists(select 1 from public.customer_in_app_inbox_resolutions
    where event_id in (v_birthday_event,v_c44_disabled_event)) into v_internal_exists;
  perform pg_temp.as_c46_user(v_customer);
  if coalesce((v_response->>'source_available')::boolean,true)
     or v_internal_exists
     or coalesce((public.customer_get_in_app_inbox_count(v_slug)->>'unread_count')::integer,-1) <> 0
     or coalesce((public.customer_get_in_app_inbox_global_count()->>'unread_count')::integer,-1) <> 0
     or (select count(*) from jsonb_array_elements(v_unavailable_list->'items') x
          where x->>'event_id' in (v_birthday_event::text,v_c44_disabled_event::text)) <> 2
     or (select count(*) from jsonb_array_elements(v_unavailable_global_list->'items') x
          where x->>'event_id' in (v_birthday_event::text,v_c44_disabled_event::text)) <> 2
     or exists(
       select 1 from jsonb_array_elements(v_unavailable_list->'items') x
        where x->>'event_id' in (v_birthday_event::text,v_c44_disabled_event::text)
          and (x->>'state' <> 'source_unavailable' or x->>'route_key' is not null
               or coalesce((x->>'action_available')::boolean,true))
     ) or exists(
       select 1 from jsonb_array_elements(v_unavailable_global_list->'items') x
        where x->>'event_id' in (v_birthday_event::text,v_c44_disabled_event::text)
          and (x->>'state' <> 'source_unavailable' or x->>'route_key' is not null
               or coalesce((x->>'action_available')::boolean,true))
     ) or jsonb_array_length(public.customer_list_in_app_inbox(v_slug,jsonb_build_object('limit',50,'filter','unread'))->'items') <> 0
     or jsonb_array_length(public.customer_list_in_app_inbox_global(jsonb_build_object('limit',50,'filter','unread'))->'items') <> 0 then
    raise exception 'C46 disabled C44 source did not make C44/C45 history unavailable, non-actionable, and unread-excluded: % / %',
      v_unavailable_list,v_unavailable_global_list;
  end if;
  reset role;
  update app.platform_feature_flags set enabled=true,changed_at=statement_timestamp()
   where feature_key='customer_actionable_wallet';
  perform pg_temp.as_c46_user(v_customer);
  v_response := public.customer_sync_in_app_inbox(v_slug,gen_random_uuid());
  reset role;
  select exists(select 1 from public.customer_in_app_inbox_resolutions
    where event_id=v_birthday_event) into v_internal_exists;
  perform pg_temp.as_c46_user(v_customer);
  if coalesce((v_response->>'source_available')::boolean,false) is not true
     or v_internal_exists
     or coalesce((public.customer_get_in_app_inbox_count(v_slug)->>'unread_count')::integer,-1) <> 1
     or not exists(
       select 1 from jsonb_array_elements(public.customer_list_in_app_inbox(v_slug,jsonb_build_object('limit',50,'filter','all'))->'items') x
        where x->>'event_id'=v_birthday_event::text and x->>'state'='unread'
          and x->>'route_key'='wallet_business' and coalesce((x->>'action_available')::boolean,false)
     ) then
    raise exception 'C46 re-enabled C44 source falsely resolved or failed to reactivate the live C45 inbox fact: %',v_response;
  end if;
  perform public.customer_set_birthday_participation(false,gen_random_uuid());
  v_response := public.customer_sync_in_app_inbox(v_slug,gen_random_uuid());
  reset role;
  select exists(select 1 from public.customer_in_app_inbox_resolutions
    where event_id=v_birthday_event) into v_internal_exists;
  perform pg_temp.as_c46_user(v_customer);
  if not v_internal_exists
     or coalesce((public.customer_get_in_app_inbox_count(v_slug)->>'unread_count')::integer,-1) <> 0
     or public.customer_get_birthday_benefit(v_slug)->>'status' <> 'available' then
    raise exception 'C46 C45 withdrawal did not resolve/suppress birthday inbox history while retaining the entitlement: %',v_response;
  end if;
  v_response := public.customer_set_in_app_inbox_preferences(
    v_slug,'booking_updates',true,' Asia/Singapore ','22:00'::time,'08:00'::time,v_pref_key
  );
  v_replay := public.customer_set_in_app_inbox_preferences(
    v_slug,'booking_updates',true,'Asia/Singapore','22:00'::time,'08:00'::time,v_pref_key
  );
  if v_response is distinct from v_replay or v_response->>'quiet_hours_timezone' <> 'Asia/Singapore' then
    raise exception 'C46 preference exact replay/IANA trimming failed: %, %',v_response,v_replay;
  end if;
  perform pg_temp.expect_c46_sqlstate(format(
    'select public.customer_set_in_app_inbox_preferences(%L,%L,false,%L,%L::time,%L::time,%L::uuid)',
    v_slug,'booking_updates','Asia/Singapore','22:00','08:00',v_pref_key
  ),'C46 preference changed-key conflict','40001');

  v_sync_key := gen_random_uuid();
  v_response := public.customer_sync_in_app_inbox(v_slug,v_sync_key);
  v_replay := public.customer_sync_in_app_inbox(v_slug,v_sync_key);
  if v_response is distinct from v_replay or coalesce((v_response->>'created')::integer,-1) <> 1 then
    raise exception 'C46 same-key sync was not an exact single creation replay: %, %',v_response,v_replay;
  end if;
  reset role;
  select id into v_live_event from public.customer_in_app_inbox_events
   where business_id=v_business and identity_id=v_identity and source_kind='v33_booking_action'
   order by created_at,id limit 1;
  select count(*) into v_internal_count from public.customer_in_app_inbox_sync_operations
    where identity_id=v_identity and idempotency_key=v_sync_key;
  perform pg_temp.as_c46_user(v_customer);
  if v_live_event is null or v_internal_count <> 1 then
    raise exception 'C46 sync dedupe evidence is incomplete';
  end if;
  perform pg_temp.expect_c46_sqlstate(format(
    'select public.customer_sync_in_app_inbox(%L,%L::uuid)',v_slug_b,v_sync_key
  ),'C46 sync cross-business changed-key conflict','40001');

  -- A fact which has stopped being authoritative is resolved, not mutated or
  -- deleted. When its exact immutable v33 source reappears, C46 emits the next
  -- deterministic cycle as a fresh unread event.
  reset role;
  v_stale_fingerprint := app.c46_sha256_hex(jsonb_build_object(
    'source','v33-booking-action','request_id',v_reappearing_request,'action','cancel',
    'proposed_at',null,'created_at',v_reappearing_created_at
  )::text);
  v_stale_dedupe := app.c46_sha256_hex(jsonb_build_object(
    'business_id',v_business,'identity_id',v_identity,'source_kind','v33_booking_action',
    'source_fingerprint',v_stale_fingerprint,'source_cycle',0
  )::text);
  insert into public.customer_in_app_inbox_events(
    id,business_id,identity_id,auth_user_id,link_id,client_id,source_kind,topic,route_key,
    source_fingerprint,dedupe_key,title,body,deadline_at
  ) values (
    v_stale_event,v_business,v_identity,v_customer,v_link,v_client,'v33_booking_action','booking_updates','wallet_business',
    v_stale_fingerprint,v_stale_dedupe,'Appointment request received',
    'Open this business wallet to review your appointment request.',null
  );
  perform pg_temp.as_c46_user(v_customer);
  perform public.customer_sync_in_app_inbox(v_slug,gen_random_uuid());
  reset role;
  select exists(select 1 from public.customer_in_app_inbox_resolutions
    where event_id=v_stale_event) into v_internal_exists;
  if not v_internal_exists then
    raise exception 'C46 stale source was not resolved as immutable history';
  end if;
  insert into public.customer_appointment_action_requests(
    id,business_id,identity_id,auth_user_id,link_id,client_id,appointment_id,action,
    proposed_at,note,status,idempotency_key,request_hash,created_at
  ) values (
    v_reappearing_request,v_business,v_identity,v_customer,v_link,v_client,v_appointment,'cancel',
    null,null,'pending','c46-reappear-source-'||substr(v_reappearing_request::text,1,8),
    app.v33_sha256_hex('c46-reappear-source:'||v_reappearing_request::text),v_reappearing_created_at
  );
  perform pg_temp.as_c46_user(v_customer);
  perform public.customer_sync_in_app_inbox(v_slug,gen_random_uuid());
  reset role;
  select id into v_reappeared_event from public.customer_in_app_inbox_events
   where identity_id=v_identity and source_fingerprint=v_stale_fingerprint and id<>v_stale_event
   order by created_at desc,id desc limit 1;
  select exists(select 1 from public.customer_in_app_inbox_resolutions
    where event_id=v_reappeared_event) into v_internal_exists;
  perform pg_temp.as_c46_user(v_customer);
  if v_reappeared_event is null
     or v_internal_exists then
    raise exception 'C46 resolved source did not recur as a new unread cycle';
  end if;

  v_response := public.customer_set_in_app_inbox_state(v_slug,v_reappeared_event,'read',v_state_key);
  v_replay := public.customer_set_in_app_inbox_state(v_slug,v_reappeared_event,'read',v_state_key);
  reset role;
  select count(*) into v_internal_count from public.customer_in_app_inbox_state_operations
    where identity_id=v_identity and event_id=v_reappeared_event and idempotency_key=v_state_key;
  perform pg_temp.as_c46_user(v_customer);
  if v_response is distinct from v_replay
     or v_internal_count <> 1 then
    raise exception 'C46 same-key state replay did not retain exactly one operation';
  end if;
  perform pg_temp.expect_c46_sqlstate(format(
    'select public.customer_set_in_app_inbox_state(%L,%L::uuid,%L,%L::uuid)',
    v_slug,v_reappeared_event,'unread',v_state_key
  ),'C46 state changed-key conflict','40001');

  -- Dismissal is terminal. Make this event unread, dismiss it, then exercise
  -- both later read and unread requests: their immutable operation evidence is
  -- accepted but the stored/effective state stays dismissed and the event stays
  -- absent from all list/count views.
  perform public.customer_set_in_app_inbox_state(v_slug,v_reappeared_event,'unread',gen_random_uuid());
  v_unread_before_dismiss := (public.customer_get_in_app_inbox_count(v_slug)->>'unread_count')::integer;
  v_response := public.customer_set_in_app_inbox_state(v_slug,v_reappeared_event,'dismiss',gen_random_uuid());
  if v_response->>'state' <> 'dismissed' then
    raise exception 'C46 dismiss did not return its effective terminal state: %',v_response;
  end if;
  v_unread_after_dismiss := (public.customer_get_in_app_inbox_count(v_slug)->>'unread_count')::integer;
  v_response := public.customer_set_in_app_inbox_state(v_slug,v_reappeared_event,'read',gen_random_uuid());
  if v_response->>'state' <> 'dismissed' then
    raise exception 'C46 read resurrected a dismissed inbox event: %',v_response;
  end if;
  v_response := public.customer_set_in_app_inbox_state(v_slug,v_reappeared_event,'unread',gen_random_uuid());
  reset role;
  select exists(select 1 from public.customer_in_app_inbox_state
    where event_id=v_reappeared_event and dismissed_at is not null) into v_internal_exists;
  perform pg_temp.as_c46_user(v_customer);
  if v_response->>'state' <> 'dismissed'
     or not v_internal_exists
     or v_unread_after_dismiss <> v_unread_before_dismiss-1
     or (public.customer_get_in_app_inbox_count(v_slug)->>'unread_count')::integer <> v_unread_after_dismiss
     or exists(select 1 from jsonb_array_elements(public.customer_list_in_app_inbox(v_slug,jsonb_build_object('limit',50,'filter','all'))->'items') x where x->>'event_id'=v_reappeared_event::text) then
    raise exception 'C46 terminal dismissal did not exclude the event from stored state, list, or count: %',v_response;
  end if;

  -- Bounded cursor pagination is deterministic and resolved historical items
  -- never expose a deep link/CTA route back into a programme.
  v_page_one := public.customer_list_in_app_inbox(v_slug,jsonb_build_object('limit',1,'filter','all'));
  if jsonb_array_length(v_page_one->'items') <> 1 or v_page_one->'next_cursor' is null then
    raise exception 'C46 bounded first page/cursor failed: %',v_page_one;
  end if;
  v_page_two := public.customer_list_in_app_inbox(v_slug,v_page_one->'next_cursor');
  if jsonb_array_length(v_page_two->'items') < 1
     or v_page_one#>>'{items,0,event_id}' = v_page_two#>>'{items,0,event_id}' then
    raise exception 'C46 cursor pagination duplicated or omitted a page: %, %',v_page_one,v_page_two;
  end if;
  if exists(
    select 1 from jsonb_array_elements(public.customer_list_in_app_inbox(v_slug,jsonb_build_object('limit',50,'filter','all'))->'items') x
     where x->>'event_id'=v_stale_event::text and x->>'route_key' is not null
  ) then raise exception 'C46 resolved history exposed an actionable deep link'; end if;

  -- A foreign customer, a staff-only principal, and anonymous callers cannot
  -- discover this link, its event, or a cross-business state action.
  perform pg_temp.as_c46_user(v_foreign_customer);
  perform pg_temp.expect_c46_sqlstate(format(
    'select public.customer_get_in_app_inbox_count(%L)',v_slug
  ),'C46 foreign customer business isolation','42501');
  perform pg_temp.as_c46_user(v_staff_only);
  perform pg_temp.expect_c46_sqlstate(format(
    'select public.customer_get_in_app_inbox_count(%L)',v_slug
  ),'C46 staff-only customer isolation','42501');
  perform pg_temp.as_c46_user(v_customer);
  perform pg_temp.expect_c46_sqlstate(format(
    'select public.customer_set_in_app_inbox_state(%L,%L::uuid,%L,%L::uuid)',
    v_slug_b,v_reappeared_event,'read',gen_random_uuid()
  ),'C46 cross-business event isolation','42501');
  perform pg_temp.as_c46_user(null,'anon');
  perform pg_temp.expect_c46_sqlstate(
    'select public.customer_get_in_app_inbox_global_count()',
    'C46 anonymous inbox isolation','42501');
  reset role;

  select count(*)::integer into v_outbox_after
    from public.customer_notification_outbox where business_id=v_business and identity_id=v_identity;
  if v_outbox_after <> v_outbox_before then
    raise exception 'C46 wrote legacy customer_notification_outbox/provider evidence: before %, after %',v_outbox_before,v_outbox_after;
  end if;
  if has_table_privilege('anon','public.customer_in_app_inbox_events','select')
     or has_table_privilege('authenticated','public.customer_in_app_inbox_state','insert') then
    raise exception 'C46 raw inbox tables are browser-accessible';
  end if;
  if v_staff_only_id is null then raise exception 'C46 staff-only synthetic fixture is missing'; end if;
  raise notice 'v46 customer in-app inbox fixture: ALL PASS (rollback-only synthetic coverage)';
end;
$c46$;

rollback;
