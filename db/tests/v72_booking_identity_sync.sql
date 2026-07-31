-- Rollback-only v72 verified customer / public booking identity synchronization suite.
-- Run after the complete canonical chain through v72 in a disposable database.
begin;

create or replace function pg_temp.as_v72_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub', p_uid, 'role', p_role
  )::text, true);
end
$$;
grant execute on function pg_temp.as_v72_user(uuid,text) to public;

do $v72_test$
declare
  v_user uuid := gen_random_uuid();
  v_other_user uuid := gen_random_uuid();
  v_business uuid;
  v_other_business uuid;
  v_slug text := 'v72-booking-' || substr(gen_random_uuid()::text, 1, 8);
  v_other_slug text := 'v72-other-' || substr(gen_random_uuid()::text, 1, 8);
  v_client uuid;
  v_other_client uuid;
  v_identity uuid;
  v_successor_identity uuid;
  v_link uuid := gen_random_uuid();
  v_successor_link uuid := gen_random_uuid();
  v_request uuid;
  v_saturation_request uuid;
  v_guest_request uuid;
  v_old_terminal_request uuid;
  v_terminal_request uuid;
  v_result jsonb;
  v_reader jsonb;
  v_reader_before jsonb;
  v_cursor jsonb;
  v_item jsonb;
  v_seen_requests uuid[] := array[]::uuid[];
  v_recent_terminal_requests uuid[] := array[]::uuid[];
  v_latest_request uuid;
  v_preferred timestamptz := date_trunc(
    'second', clock_timestamp() + interval '2 days'
  );
  v_i integer;
  v_terminal_status text;
  v_original_name text := 'V72 Existing Merchant Client';
begin
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  ) values
    (
      '00000000-0000-0000-0000-000000000000',
      v_user, 'authenticated', 'authenticated',
      'v72-' || substr(v_user::text, 1, 8) || '@example.test',
      '', clock_timestamp(), clock_timestamp(), clock_timestamp()
    ),
    (
      '00000000-0000-0000-0000-000000000000',
      v_other_user, 'authenticated', 'authenticated',
      'v72-' || substr(v_other_user::text, 1, 8) || '@example.test',
      '', clock_timestamp(), clock_timestamp(), clock_timestamp()
    );

  insert into public.businesses(name, slug, industry, enabled_modules)
  values (
    'V72 booking identity fixture', v_slug, 'test',
    array['appointments','bookings']
  )
  returning id into v_business;
  insert into public.businesses(name, slug, industry, enabled_modules)
  values ('V72 foreign fixture', v_other_slug, 'test', array['appointments'])
  returning id into v_other_business;

  -- v89's later default-closed gate applies to the authenticated bound-booking
  -- path under test. Explicitly enable that capability on a full-final replay.
  if to_regclass('public.business_customer_capabilities_v89') is not null then
    execute
      'insert into public.business_customer_capabilities_v89(
         business_id,booking_enabled,redemption_enabled,appointment_changes_enabled
       ) values ($1,true,false,false)'
      using v_business;
  end if;

  insert into public.clients(business_id, full_name, email, phone)
  values (
    v_business, v_original_name, 'merchant-owned@example.test', '+65 8000 0072'
  ) returning id into v_client;
  insert into public.clients(business_id, full_name)
  values (v_other_business, 'V72 Foreign Client')
  returning id into v_other_client;

  insert into public.customer_identities(auth_user_id)
  values (v_user) returning id into v_identity;
  perform set_config('app.customer_link_insert_id', v_link::text, true);
  insert into public.customer_links(
    id, business_id, identity_id, auth_user_id, client_id, state,
    verification_method, verified_at
  ) values (
    v_link, v_business, v_identity, v_user, v_client, 'verified',
    'email_claim', clock_timestamp()
  );
  perform set_config('app.customer_link_insert_id', '', true);

  v_result := public.internal_public_booking_submit(
    v_slug, 'Submitted Booking Name', null, '+6581234567',
    null, 2, v_preferred, 'safe fixture note',
    null, true, repeat('1', 64), repeat('2', 64), repeat('3', 64), v_user
  );
  v_request := (v_result->>'request_id')::uuid;
  if v_result->>'status' is distinct from 'pending'
     or v_result->>'replayed' is distinct from 'false'
     or not exists (
       select 1 from public.booking_requests request
        where request.id = v_request
          and request.business_id = v_business
          and request.customer_client_id = v_client
     ) then
    raise exception 'verified customer booking was not bound to the exact merchant client';
  end if;
  if not exists (
    select 1 from app.booking_management_tokens token
     where token.booking_request_id = v_request
       and token.authenticated_user_id = v_user
       and token.customer_client_id = v_client
  ) then
    raise exception 'management replay evidence omitted the authenticated binding';
  end if;
  if exists (
    select 1 from public.clients client
     where client.id = v_client
       and (
         client.full_name is distinct from v_original_name
         or client.email is distinct from 'merchant-owned@example.test'
         or client.phone is distinct from '+65 8000 0072'
       )
  ) then
    raise exception 'booking silently propagated submitted/global profile data into merchant client';
  end if;
  if not exists (
    select 1 from public.clients client
     where client.business_id = v_business
       and client.id = v_client
       and client.marketing_consent
  ) or (
    select count(*)
      from public.consents consent
     where consent.business_id = v_business
       and consent.client_id = v_client
       and consent.channel = 'marketing'
       and consent.action = 'granted'
       and consent.source = 'authenticated_public_booking_v72'
       and consent.actor = v_user
  ) <> 1 then
    raise exception 'explicit consent was not attributed to the authenticated customer';
  end if;
  if exists (
    select 1 from public.consents consent
     where consent.business_id = v_business
       and consent.client_id = v_client
       and consent.action = 'withdrawn'
       and consent.source = 'authenticated_public_booking_v72'
  ) then
    raise exception 'v72 explicit booking consent recorded an unexpected withdrawal';
  end if;

  v_result := public.internal_public_booking_submit(
    v_slug, 'Submitted Booking Name', null, '+6581234567',
    null, 2, v_preferred, 'safe fixture note',
    null, true, repeat('1', 64), repeat('2', 64), repeat('3', 64), v_user
  );
  if v_result->>'replayed' is distinct from 'true'
     or (v_result->>'request_id')::uuid is distinct from v_request then
    raise exception 'exact bound booking replay did not return the original result';
  end if;
  if (
    select count(*)
      from public.consents consent
     where consent.business_id = v_business
       and consent.client_id = v_client
       and consent.source = 'authenticated_public_booking_v72'
  ) <> 1 then
    raise exception 'exact replay duplicated the explicit consent event';
  end if;

  perform app.apply_bound_booking_consent_v72(
    v_business, v_client, v_user, false
  );
  if exists (
    select 1 from public.consents consent
     where consent.business_id = v_business
       and consent.client_id = v_client
       and consent.action = 'withdrawn'
       and consent.source = 'authenticated_public_booking_v72'
  ) then
    raise exception 'unchecked consent was treated as a withdrawal';
  end if;

  v_result := public.internal_public_booking_submit(
    v_slug, 'Submitted Booking Name', null, '+6581234567',
    null, 2, v_preferred, 'safe fixture note',
    null, true, repeat('1', 64), repeat('2', 64), repeat('3', 64), v_other_user
  );
  if v_result->>'conflict' is distinct from 'true' then
    raise exception 'changed authenticated context did not conflict';
  end if;

  v_result := public.internal_public_booking_submit(
    v_slug, 'Guest Booking', null, '+6587654321',
    null, 1, clock_timestamp() + interval '3 days', null,
    null, false, repeat('4', 64), repeat('5', 64), repeat('6', 64), null
  );
  v_guest_request := (v_result->>'request_id')::uuid;
  if exists (
    select 1 from public.booking_requests request
     where request.id = v_guest_request and request.customer_client_id is not null
  ) or exists (
    select 1 from app.booking_management_tokens token
     where token.booking_request_id = v_guest_request
       and (token.authenticated_user_id is not null or token.customer_client_id is not null)
  ) then
    raise exception 'guest submission behavior gained an identity binding';
  end if;

  begin
    update public.booking_requests
       set customer_client_id = null
     where id = v_request;
    raise exception 'immutable booking customer binding was changed';
  exception when check_violation then null;
  end;

  begin
    insert into public.booking_requests(
      business_id, customer_client_id, name, phone, party_size,
      preferred_at, status, marketing_consent
    ) values (
      v_business, v_other_client, 'Cross tenant', '+6580000072', 1,
      clock_timestamp() + interval '4 days', 'new', false
    );
    raise exception 'cross-tenant customer binding was accepted';
  exception when foreign_key_violation then null;
  end;

  perform pg_temp.as_v72_user(v_user);
  v_reader := public.customer_get_booking_requests(20);
  reset role;
  if jsonb_array_length(v_reader->'items') <> 1
     or v_reader->'items'->0->>'request_id' is distinct from v_request::text
     or v_reader->'items'->0->>'business_slug' is distinct from v_slug
     or v_reader->'items'->0->>'status' is distinct from 'pending' then
    raise exception 'self-scoped booking reader omitted or misprojected the bound request: %',
      v_reader;
  end if;
  if v_reader::text ~* '(submitted booking name|81234567|merchant-owned@example|customer_client_id)'
     or v_reader::text like '%' || v_client::text || '%' then
    raise exception 'reader leaked a submitted contact or bound client id';
  end if;

  -- More than one page of older active requests must remain traversable without
  -- duplicates, while the newest request always appears first.
  for v_i in 1..25 loop
    insert into public.booking_requests(
      business_id, customer_client_id, name, phone, party_size,
      preferred_at, status, marketing_consent, created_at
    ) values (
      v_business, v_client, 'Active page fixture ' || v_i, '+6580000072', 1,
      v_preferred + make_interval(mins => v_i), 'new', false,
      clock_timestamp() + make_interval(secs => v_i)
    ) returning id into v_latest_request;

    insert into app.booking_management_tokens(
      token_hash, idempotency_hash, request_fingerprint,
      business_id, booking_request_id, authenticated_user_id,
      customer_client_id, expires_at, initial_response
    ) values (
      extensions.digest('v72-active-token-' || v_i, 'sha256'),
      extensions.digest('v72-active-idempotency-' || v_i, 'sha256'),
      extensions.digest('v72-active-fingerprint-' || v_i, 'sha256'),
      v_business, v_latest_request, v_user, v_client,
      v_preferred + interval '60 days',
      jsonb_build_object('status', 'pending', 'request_id', v_latest_request)
    );
  end loop;

  v_cursor := null;
  loop
    perform pg_temp.as_v72_user(v_user);
    v_reader := public.customer_get_booking_requests(10, v_cursor);
    reset role;
    for v_item in select value from jsonb_array_elements(v_reader->'items')
    loop
      if (v_item->>'request_id')::uuid = any(v_seen_requests) then
        raise exception 'keyset booking pagination returned a duplicate request';
      end if;
      v_seen_requests := array_append(
        v_seen_requests, (v_item->>'request_id')::uuid
      );
    end loop;
    if array_length(v_seen_requests, 1) = jsonb_array_length(v_reader->'items')
       and v_reader->'items'->0->>'request_id' is distinct from v_latest_request::text then
      raise exception 'older unresolved requests starved the newest active request';
    end if;
    exit when not (v_reader->>'truncated')::boolean;
    if v_reader->'next_cursor' is null then
      raise exception 'truncated booking page omitted its keyset cursor';
    end if;
    v_cursor := v_reader->'next_cursor';
  end loop;
  if array_length(v_seen_requests, 1) <> 26
     or not (v_request = any(v_seen_requests)) then
    raise exception 'keyset booking pagination omitted an active request';
  end if;
  perform pg_temp.as_v72_user(v_user);
  begin
    perform public.customer_get_booking_requests(
      10, '{"created_at":"not-a-time","request_id":"not-a-uuid"}'::jsonb
    );
    raise exception 'malformed booking cursor was accepted';
  exception when invalid_parameter_value then null;
  end;
  reset role;

  -- Recent terminal requests remain visible so staff decisions do not silently
  -- disappear from My Frenly. Old terminal history is bounded to 90 days.
  foreach v_terminal_status in array array['declined','expired','cancelled']
  loop
    insert into public.booking_requests(
      business_id, customer_client_id, name, phone, party_size,
      preferred_at, status, marketing_consent, created_at
    ) values (
      v_business, v_client, 'Recent terminal ' || v_terminal_status,
      '+6580000072', 1, v_preferred, v_terminal_status, false,
      clock_timestamp() - interval '1 day'
    ) returning id into v_terminal_request;
    v_recent_terminal_requests := array_append(
      v_recent_terminal_requests, v_terminal_request
    );
    insert into app.booking_management_tokens(
      token_hash, idempotency_hash, request_fingerprint,
      business_id, booking_request_id, authenticated_user_id,
      customer_client_id, expires_at, initial_response
    ) values (
      extensions.digest('v72-terminal-token-' || v_terminal_status, 'sha256'),
      extensions.digest('v72-terminal-idempotency-' || v_terminal_status, 'sha256'),
      extensions.digest('v72-terminal-fingerprint-' || v_terminal_status, 'sha256'),
      v_business, v_terminal_request, v_user, v_client,
      v_preferred + interval '60 days',
      jsonb_build_object(
        'status', v_terminal_status, 'request_id', v_terminal_request
      )
    );
  end loop;

  insert into public.booking_requests(
    business_id, customer_client_id, name, phone, party_size,
    preferred_at, status, marketing_consent, created_at
  ) values (
    v_business, v_client, 'Old terminal excluded', '+6580000072', 1,
    v_preferred, 'declined', false, clock_timestamp() - interval '91 days'
  ) returning id into v_old_terminal_request;
  insert into app.booking_management_tokens(
    token_hash, idempotency_hash, request_fingerprint,
    business_id, booking_request_id, authenticated_user_id,
    customer_client_id, expires_at, initial_response
  ) values (
    extensions.digest('v72-old-terminal-token', 'sha256'),
    extensions.digest('v72-old-terminal-idempotency', 'sha256'),
    extensions.digest('v72-old-terminal-fingerprint', 'sha256'),
    v_business, v_old_terminal_request, v_user, v_client,
    v_preferred + interval '60 days',
    jsonb_build_object(
      'status', 'declined', 'request_id', v_old_terminal_request
    )
  );

  perform pg_temp.as_v72_user(v_user);
  v_reader := public.customer_get_booking_requests(50);
  reset role;
  foreach v_terminal_request in array v_recent_terminal_requests
  loop
    if not exists (
      select 1
        from jsonb_array_elements(v_reader->'items') as item(value)
       where item.value->>'request_id' = v_terminal_request::text
         and item.value->>'status' in ('declined','expired','cancelled')
    ) then
      raise exception 'recent terminal booking request disappeared from My Frenly';
    end if;
  end loop;
  if exists (
    select 1
      from jsonb_array_elements(v_reader->'items') as item(value)
     where item.value->>'request_id' = v_old_terminal_request::text
  ) then
    raise exception 'terminal booking older than 90 days remained visible';
  end if;

  -- Confirmed rows are owned by the appointments reader. Even more than the
  -- public-reader limit must not starve or falsely truncate an active request.
  perform pg_temp.as_v72_user(v_user);
  v_reader_before := public.customer_get_booking_requests(20);
  reset role;
  for v_i in 1..60 loop
    insert into public.booking_requests(
      business_id, customer_client_id, name, phone, party_size,
      preferred_at, status, marketing_consent
    ) values (
      v_business, v_client, 'Confirmed saturation ' || v_i, '+6580000072', 1,
      v_preferred + make_interval(mins => v_i), 'confirmed', false
    ) returning id into v_saturation_request;

    insert into app.booking_management_tokens(
      token_hash, idempotency_hash, request_fingerprint,
      business_id, booking_request_id, authenticated_user_id,
      customer_client_id, expires_at, initial_response
    ) values (
      extensions.digest('v72-confirmed-token-' || v_i, 'sha256'),
      extensions.digest('v72-confirmed-idempotency-' || v_i, 'sha256'),
      extensions.digest('v72-confirmed-fingerprint-' || v_i, 'sha256'),
      v_business, v_saturation_request, v_user, v_client,
      v_preferred + interval '60 days',
      jsonb_build_object(
        'status', 'confirmed', 'request_id', v_saturation_request
      )
    );
  end loop;

  perform pg_temp.as_v72_user(v_user);
  v_reader := public.customer_get_booking_requests(20);
  reset role;
  if v_reader is distinct from v_reader_before then
    raise exception 'confirmed saturation starved active booking requests: %',
      v_reader;
  end if;
  if exists (
    select 1
      from jsonb_array_elements(v_reader->'items') as item(value)
     where item.value->>'status' = 'confirmed'
  ) then
    raise exception 'confirmed booking duplicated the appointments feed';
  end if;

  -- A replacement identity may form a new verified relationship with the same
  -- merchant client, but immutable submission evidence remains with v_user.
  perform set_config('app.customer_link_transition_id', v_link::text, true);
  update public.customer_links
     set state = 'unlinked',
         unlinked_at = clock_timestamp(),
         unlinked_by_auth_user_id = v_user,
         updated_at = clock_timestamp()
   where business_id = v_business
     and identity_id = v_identity
     and state = 'verified';
  perform set_config('app.customer_link_transition_id', '', true);

  insert into public.customer_identities(auth_user_id)
  values (v_other_user) returning id into v_successor_identity;
  perform set_config('app.customer_link_insert_id', v_successor_link::text, true);
  insert into public.customer_links(
    id, business_id, identity_id, auth_user_id, client_id, state,
    verification_method, verified_at
  ) values (
    v_successor_link, v_business, v_successor_identity, v_other_user, v_client, 'verified',
    'email_claim', clock_timestamp()
  );
  perform set_config('app.customer_link_insert_id', '', true);

  perform pg_temp.as_v72_user(v_user);
  if jsonb_array_length(public.customer_get_booking_requests(20)->'items') <> 0 then
    raise exception 'unlinked submitter retained current-link booking visibility';
  end if;
  reset role;

  perform pg_temp.as_v72_user(v_other_user);
  if jsonb_array_length(public.customer_get_booking_requests(20)->'items') <> 0 then
    raise exception 'successor identity inherited predecessor booking evidence';
  end if;
  reset role;

  if to_regprocedure(
       'public.internal_public_booking_submit(text,text,text,text,uuid,integer,timestamptz,text,uuid,boolean,text,text,text)'
     ) is null
     or to_regprocedure(
       'public.internal_public_booking_submit(text,text,text,text,uuid,integer,timestamptz,text,uuid,boolean,text,text,text,uuid)'
     ) is null
     or has_function_privilege(
       'anon', 'public.customer_get_booking_requests(integer,jsonb)', 'execute'
     ) or not has_function_privilege(
       'authenticated', 'public.customer_get_booking_requests(integer,jsonb)', 'execute'
     ) or has_function_privilege(
       'authenticated',
       'public.internal_public_booking_submit(text,text,text,text,uuid,integer,timestamptz,text,uuid,boolean,text,text,text)',
       'execute'
     ) or not has_function_privilege(
       'service_role',
       'public.internal_public_booking_submit(text,text,text,text,uuid,integer,timestamptz,text,uuid,boolean,text,text,text)',
       'execute'
     ) or has_function_privilege(
       'authenticated',
       'public.internal_public_booking_submit(text,text,text,text,uuid,integer,timestamptz,text,uuid,boolean,text,text,text,uuid)',
       'execute'
     ) or not has_function_privilege(
       'service_role',
       'public.internal_public_booking_submit(text,text,text,text,uuid,integer,timestamptz,text,uuid,boolean,text,text,text,uuid)',
       'execute'
     ) then
    raise exception 'v72 browser role ACL is not least privilege';
  end if;

  if to_regprocedure(
       'public.staff_decide_booking_request_v73(uuid,uuid,text,uuid)'
     ) is not null then
    if pg_get_functiondef('public.convert_booking_request(uuid)'::regprocedure)
         !~ 'staff_decide_booking_request_v73' then
      raise exception 'later v73 conversion wrapper did not preserve v72 semantics';
    end if;
  elsif pg_get_functiondef('public.convert_booking_request(uuid)'::regprocedure)
          !~ 'customer_client_id is not null'
     or pg_get_functiondef('public.convert_booking_request(uuid)'::regprocedure)
          !~ 'app.upsert_portal_client' then
    raise exception 'v72 conversion did not preserve bound and guest paths';
  end if;

  raise notice 'v72 booking identity synchronization suite: ALL PASS';
end
$v72_test$;

rollback;
