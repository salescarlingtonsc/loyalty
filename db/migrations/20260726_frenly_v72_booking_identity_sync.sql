-- FRENLY v72 - VERIFIED CUSTOMER / PUBLIC BOOKING IDENTITY SYNCHRONIZATION
--
-- Forward-only local review candidate. The public browser never supplies a
-- client_id. public-booking validates an optional bearer token and supplies only
-- the verified Auth user UUID; this migration resolves the exact verified
-- tenant relationship in SQL and binds the booking request immutably.
--
-- OUTAGE-FREE ROLLOUT ORDER (DB FIRST):
--   1. Apply this migration. It preserves the v19 13-argument service RPC as a
--      guest wrapper and adds the identity-aware 14-argument overload.
--   2. Deploy public-booking, which calls the 14-argument overload.
--   3. Verify guest, publishable-key, authenticated-bound, replay, and management
--      flows. The 13-argument overload remains for rollback compatibility.

begin;

alter table public.booking_requests
  add column customer_client_id uuid;

alter table public.booking_requests
  add constraint booking_requests_customer_client_business_fk
  foreign key (business_id, customer_client_id)
  references public.clients(business_id, id) on delete restrict;

create index booking_requests_customer_client_status_time_idx
  on public.booking_requests(customer_client_id, status, preferred_at, created_at desc)
  where customer_client_id is not null;

alter table app.booking_management_tokens
  add column authenticated_user_id uuid,
  add column customer_client_id uuid;

alter table app.booking_management_tokens
  add constraint booking_management_tokens_customer_client_business_fk
  foreign key (business_id, customer_client_id)
  references public.clients(business_id, id) on delete restrict;

-- A booking's customer relationship is evidence established at submission time.
-- It is never backfilled from contact text and may not be changed later.
create or replace function app.guard_booking_customer_binding_v72()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if old.customer_client_id is distinct from new.customer_client_id then
    raise exception 'booking customer binding is immutable' using errcode = '23514';
  end if;
  return new;
end
$$;

create trigger trg_guard_booking_customer_binding_v72
before update of customer_client_id on public.booking_requests
for each row execute function app.guard_booking_customer_binding_v72();

create or replace function app.resolve_verified_booking_client_v72(
  p_business uuid,
  p_authenticated_user uuid
)
returns uuid
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select link.client_id
    from public.customer_links link
    join public.customer_identities identity
      on identity.id = link.identity_id
     and identity.auth_user_id = link.auth_user_id
   where link.business_id = p_business
     and link.auth_user_id = p_authenticated_user
     and link.state = 'verified'
     and identity.status = 'active'
   order by link.verified_at desc, link.id
   limit 1
$$;

-- Explicit checked consent from a server-validated, currently verified customer
-- may grant this merchant relationship marketing consent. An unchecked box is a
-- no-op, never a withdrawal. Contact/profile fields are deliberately untouched.
create or replace function app.apply_bound_booking_consent_v72(
  p_business uuid,
  p_client uuid,
  p_authenticated_user uuid,
  p_consent boolean
)
returns void
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if coalesce(p_consent, false) is false then
    return;
  end if;
  if p_authenticated_user is null or not exists (
    select 1
      from public.customer_links link
      join public.customer_identities identity
        on identity.id = link.identity_id
       and identity.auth_user_id = link.auth_user_id
     where link.business_id = p_business
       and link.client_id = p_client
       and link.auth_user_id = p_authenticated_user
       and link.state = 'verified'
       and identity.status = 'active'
  ) then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  update public.clients
     set marketing_consent = true
   where business_id = p_business
     and id = p_client
     and marketing_consent is false;

  insert into public.consents(
    business_id, client_id, channel, action, source, actor
  ) values (
    p_business, p_client, 'marketing', 'granted',
    'authenticated_public_booking_v72', p_authenticated_user
  );
end
$$;

-- Private bound path only. The existing public.request_booking remains the guest
-- path byte-for-byte. In particular, this function never writes public.clients,
-- contact/profile fields. The narrow helper above handles only an explicit,
-- audited consent grant from the validated linked customer.
create or replace function app.request_bound_booking_v72(
  p_business uuid,
  p_client uuid,
  p_authenticated_user uuid,
  p_name text,
  p_email text,
  p_phone text,
  p_service uuid,
  p_party integer,
  p_preferred timestamptz,
  p_notes text,
  p_table_type uuid,
  p_consent boolean
)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_business public.businesses%rowtype;
  v_available integer;
  v_request uuid;
  v_appointment public.appointments%rowtype;
  v_table_type uuid;
  v_duration integer;
begin
  select business.* into v_business
    from public.businesses business
   where business.id = p_business;
  if not found or not exists (
    select 1 from public.clients client
     where client.business_id = p_business and client.id = p_client
  ) then
    raise exception 'invalid request' using errcode = '22023';
  end if;

  perform app.apply_bound_booking_consent_v72(
    p_business, p_client, p_authenticated_user, p_consent
  );

  if p_table_type is null then
    insert into public.booking_requests (
      business_id, customer_client_id, name, email, phone, service_id,
      party_size, preferred_at, notes, status, marketing_consent
    ) values (
      p_business, p_client, btrim(p_name), p_email, p_phone, p_service,
      p_party, p_preferred, p_notes, 'new', coalesce(p_consent, false)
    ) returning id into v_request;
    return json_build_object('status', 'pending', 'request_id', v_request);
  end if;

  select table_type.id into v_table_type
    from public.booking_tables table_type
   where table_type.id = p_table_type
     and table_type.business_id = p_business
     and table_type.active
   for update;
  if v_table_type is null then
    raise exception 'invalid table type' using errcode = '22023';
  end if;

  select availability.available into v_available
    from public.v_table_availability availability
   where availability.table_type_id = p_table_type;
  v_available := coalesce(v_available, 0);

  if v_available > 0 then
    if v_business.booking_auto_confirm then
      v_duration := coalesce((
        select service.duration_min
          from public.services service
         where service.id = p_service and service.business_id = p_business
      ), 60);
      insert into public.appointments (
        business_id, client_id, service_id, starts_at, ends_at,
        status, party_size, source, note, table_type_id
      ) values (
        p_business, p_client, p_service,
        coalesce(p_preferred, clock_timestamp() + interval '1 day'),
        coalesce(p_preferred, clock_timestamp() + interval '1 day')
          + make_interval(mins => greatest(v_duration, 1)),
        'booked', p_party, 'portal', p_notes, p_table_type
      ) returning * into v_appointment;

      insert into public.booking_requests (
        business_id, customer_client_id, name, email, phone, service_id,
        party_size, preferred_at, notes, status, table_type_id,
        appointment_id, marketing_consent
      ) values (
        p_business, p_client, btrim(p_name), p_email, p_phone, p_service,
        p_party, p_preferred, p_notes, 'confirmed', p_table_type,
        v_appointment.id, coalesce(p_consent, false)
      ) returning id into v_request;
      return json_build_object(
        'status', 'confirmed',
        'request_id', v_request,
        'appointment_id', v_appointment.id
      );
    end if;

    insert into public.booking_requests (
      business_id, customer_client_id, name, email, phone, service_id,
      party_size, preferred_at, notes, status, table_type_id,
      expires_at, marketing_consent
    ) values (
      p_business, p_client, btrim(p_name), p_email, p_phone, p_service,
      p_party, p_preferred, p_notes, 'pending', p_table_type,
      case when v_business.booking_hold_minutes > 0
        then clock_timestamp() + make_interval(mins => v_business.booking_hold_minutes)
        else null end,
      coalesce(p_consent, false)
    ) returning id into v_request;
    return json_build_object('status', 'pending', 'request_id', v_request);
  end if;

  if v_business.booking_overflow = 'reject' then
    insert into public.booking_requests (
      business_id, customer_client_id, name, email, phone, service_id,
      party_size, preferred_at, notes, status, table_type_id, marketing_consent
    ) values (
      p_business, p_client, btrim(p_name), p_email, p_phone, p_service,
      p_party, p_preferred,
      btrim(coalesce(p_notes, '') || ' [auto-declined: no capacity]'),
      'declined', p_table_type, coalesce(p_consent, false)
    ) returning id into v_request;
    return json_build_object('status', 'rejected', 'request_id', v_request);
  end if;

  insert into public.booking_requests (
    business_id, customer_client_id, name, email, phone, service_id,
    party_size, preferred_at, notes, status, table_type_id, marketing_consent
  ) values (
    p_business, p_client, btrim(p_name), p_email, p_phone, p_service,
    p_party, p_preferred, p_notes, 'waitlisted', p_table_type,
    coalesce(p_consent, false)
  ) returning id into v_request;

  insert into public.waitlist (
    business_id, client_id, name, phone, service_id, preferred, notes,
    status, booking_request_id, table_type_id
  ) values (
    p_business, p_client, btrim(p_name), p_phone, p_service,
    to_char(coalesce(p_preferred, clock_timestamp()) at time zone 'Asia/Singapore',
      'YYYY-MM-DD HH24:MI'),
    p_notes, 'waiting', v_request, p_table_type
  );
  return json_build_object('status', 'waitlisted', 'request_id', v_request);
end
$$;

create function public.internal_public_booking_submit(
  p_slug text,
  p_name text,
  p_email text,
  p_phone text,
  p_service uuid,
  p_party integer,
  p_preferred timestamptz,
  p_notes text,
  p_table_type uuid,
  p_consent boolean,
  p_token_hash text,
  p_idempotency_hash text,
  p_request_fingerprint text,
  p_authenticated_user uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_business public.businesses%rowtype;
  v_bound_client uuid;
  v_result json;
  v_request uuid;
  v_appointment uuid;
  v_token_expiry timestamptz;
  v_prior jsonb;
  v_prior_fingerprint bytea;
  v_prior_authenticated_user uuid;
  v_prior_client uuid;
begin
  if p_slug is null or p_slug !~ '^[a-z0-9][a-z0-9-]{0,62}$'
     or p_name is null or char_length(btrim(p_name)) not between 2 and 100
     or p_party not between 1 and 50
     or p_preferred is null
     or char_length(coalesce(p_notes, '')) > 1000
     or p_token_hash !~ '^[0-9a-f]{64}$'
     or p_idempotency_hash !~ '^[0-9a-f]{64}$'
     or p_request_fingerprint !~ '^[0-9a-f]{64}$'
     or (p_email is null and p_phone is null)
     or (p_email is not null and (
       char_length(p_email) > 254
       or p_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
     ))
     or (p_phone is not null and p_phone !~ '^\+[1-9][0-9]{7,14}$') then
    raise exception 'invalid request' using errcode = '22023';
  end if;

  select business.* into v_business
    from public.businesses business
   where business.slug = p_slug
   limit 1;
  if not found then
    raise exception 'invalid request' using errcode = '22023';
  end if;

  v_bound_client := app.resolve_verified_booking_client_v72(
    v_business.id, p_authenticated_user
  );

  select token.initial_response, token.request_fingerprint,
         token.authenticated_user_id, token.customer_client_id
    into v_prior, v_prior_fingerprint,
         v_prior_authenticated_user, v_prior_client
    from app.booking_management_tokens token
   where token.idempotency_hash = decode(p_idempotency_hash, 'hex')
     and token.business_id = v_business.id
   for update;
  if found then
    if v_prior_fingerprint <> decode(p_request_fingerprint, 'hex')
       or v_prior_authenticated_user is distinct from p_authenticated_user
       or v_prior_client is distinct from v_bound_client then
      return jsonb_build_object('conflict', true);
    end if;
    return v_prior || jsonb_build_object('replayed', true);
  end if;

  if p_preferred < clock_timestamp() + interval '15 minutes'
     or p_preferred > clock_timestamp() + interval '365 days' then
    raise exception 'invalid request' using errcode = '22023';
  end if;

  if p_service is not null and not exists (
    select 1 from public.services service
     where service.id = p_service
       and service.business_id = v_business.id
       and service.active
       and service.show_on_booking_page
  ) then
    raise exception 'invalid request' using errcode = '22023';
  end if;

  if p_table_type is not null and not exists (
    select 1 from public.booking_tables table_type
     where table_type.id = p_table_type
       and table_type.business_id = v_business.id
       and table_type.active
       and (table_type.pax is null or p_party <= table_type.pax)
  ) then
    raise exception 'invalid request' using errcode = '22023';
  end if;

  if v_bound_client is null then
    select public.request_booking(
      p_slug, btrim(p_name), nullif(btrim(p_email), ''), p_phone,
      p_service, p_party, p_preferred, nullif(btrim(p_notes), ''),
      p_table_type, coalesce(p_consent, false)
    ) into v_result;
  else
    select app.request_bound_booking_v72(
      v_business.id, v_bound_client, p_authenticated_user,
      btrim(p_name), nullif(btrim(p_email), ''), p_phone,
      p_service, p_party, p_preferred, nullif(btrim(p_notes), ''),
      p_table_type, coalesce(p_consent, false)
    ) into v_result;
  end if;

  v_request := nullif(v_result->>'request_id', '')::uuid;
  v_appointment := nullif(v_result->>'appointment_id', '')::uuid;
  if v_request is null and v_appointment is null then
    raise exception 'invalid request' using errcode = 'P0001';
  end if;

  v_token_expiry := greatest(
    clock_timestamp() + interval '30 days',
    p_preferred + interval '30 days'
  );
  insert into app.booking_management_tokens (
    token_hash, idempotency_hash, request_fingerprint,
    business_id, booking_request_id, appointment_id,
    authenticated_user_id, customer_client_id,
    expires_at, initial_response
  ) values (
    decode(p_token_hash, 'hex'), decode(p_idempotency_hash, 'hex'),
    decode(p_request_fingerprint, 'hex'), v_business.id,
    v_request, v_appointment, p_authenticated_user, v_bound_client,
    v_token_expiry, v_result::jsonb
  );

  return v_result::jsonb || jsonb_build_object('replayed', false);
end
$$;

-- Preserve the v19 identity exactly for DB-first deployment and Edge rollback.
-- It is intentionally a guest wrapper; only the Edge service role can call it.
create or replace function public.internal_public_booking_submit(
  p_slug text,
  p_name text,
  p_email text,
  p_phone text,
  p_service uuid,
  p_party integer,
  p_preferred timestamptz,
  p_notes text,
  p_table_type uuid,
  p_consent boolean,
  p_token_hash text,
  p_idempotency_hash text,
  p_request_fingerprint text
)
returns jsonb
language sql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select public.internal_public_booking_submit(
    p_slug, p_name, p_email, p_phone, p_service, p_party, p_preferred,
    p_notes, p_table_type, p_consent, p_token_hash, p_idempotency_hash,
    p_request_fingerprint, null::uuid
  )
$$;

-- v47 conversion is preserved, with one deliberate change: a request that was
-- bound at submission always uses that exact tenant client and never performs a
-- contact-text match/upsert or mutates that client's profile/consent.
create or replace function public.convert_booking_request(p_request uuid)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_request public.booking_requests%rowtype;
  v_client uuid;
  v_branch uuid;
  v_start timestamptz;
  v_duration integer;
  v_booking jsonb;
  v_appointment public.appointments%rowtype;
begin
  select request.* into v_request
    from public.booking_requests request
   where request.id = p_request
   for update;
  if not found then
    raise exception 'booking request not found' using errcode = '22023';
  end if;
  if v_request.appointment_id is not null then
    select * into v_appointment
      from public.appointments appointment
     where appointment.id = v_request.appointment_id
       and appointment.business_id = v_request.business_id;
    return row_to_json(v_appointment);
  end if;

  v_branch := app.default_branch(v_request.business_id);
  if v_branch is null then
    raise exception 'an active default branch is required' using errcode = '22023';
  end if;
  if not app.can_module_write(v_request.business_id, 'appointments')
     or not app.can_see_branch(v_request.business_id, v_branch) then
    raise exception 'appointment write access for the default branch is required'
      using errcode = '42501';
  end if;

  if v_request.customer_client_id is not null then
    select client.id into v_client
      from public.clients client
     where client.id = v_request.customer_client_id
       and client.business_id = v_request.business_id;
    if not found then
      raise exception 'bound booking client is unavailable' using errcode = '23503';
    end if;
  else
    v_client := app.upsert_portal_client(
      v_request.business_id, v_request.name, v_request.phone, v_request.email
    );
    perform app.apply_booking_consent(
      v_request.business_id, v_client, v_request.marketing_consent
    );
  end if;

  v_start := coalesce(
    v_request.preferred_at, clock_timestamp() + interval '1 day'
  );
  select greatest(service.duration_min, 15) into v_duration
    from public.services service
   where service.id = v_request.service_id
     and service.business_id = v_request.business_id;
  v_duration := coalesce(v_duration, 60);
  v_booking := public.book_appointment_smart_v47(
    v_request.business_id, v_client, v_branch, v_request.service_id,
    v_start, v_duration, null, 'round_robin', v_request.notes,
    'booking-request:' || p_request::text
  );
  if v_booking->>'status' = 'conflict' then
    return v_booking::json;
  end if;

  select * into v_appointment
    from public.appointments appointment
   where appointment.id = (v_booking->>'appointment_id')::uuid
     and appointment.business_id = v_request.business_id;
  update public.appointments
     set party_size = v_request.party_size,
         source = 'portal',
         table_type_id = v_request.table_type_id
   where id = v_appointment.id
   returning * into v_appointment;
  update public.booking_requests
     set status = 'confirmed',
         appointment_id = v_appointment.id,
         expires_at = null
   where id = p_request;
  return row_to_json(v_appointment);
end
$$;

-- Global customer reader for Home/Bookings. It is self-scoped through the
-- caller's active identity and verified links, and intentionally omits submitted
-- name, email, phone, notes, internal client IDs, and management capabilities.
create or replace function public.customer_get_booking_requests(
  p_limit integer default 20,
  p_cursor jsonb default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_limit integer;
  v_cursor_created timestamptz;
  v_cursor_id uuid;
  v_result jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if p_limit is null or p_limit not between 1 and 50 then
    raise exception 'invalid booking request limit' using errcode = '22023';
  end if;
  v_limit := p_limit;
  if p_cursor is not null then
    if jsonb_typeof(p_cursor) <> 'object'
       or not (p_cursor ? 'created_at')
       or not (p_cursor ? 'request_id')
       or (select count(*) from jsonb_object_keys(p_cursor)) <> 2
       or jsonb_typeof(p_cursor->'created_at') <> 'string'
       or jsonb_typeof(p_cursor->'request_id') <> 'string'
       or (p_cursor->>'created_at') !~
          '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?(Z|[+-][0-9]{2}:[0-9]{2})$'
       or (p_cursor->>'request_id') !~
          '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
      raise exception 'invalid booking request cursor' using errcode = '22023';
    end if;
    begin
      v_cursor_created := (p_cursor->>'created_at')::timestamptz;
      v_cursor_id := (p_cursor->>'request_id')::uuid;
    exception when others then
      raise exception 'invalid booking request cursor' using errcode = '22023';
    end;
  end if;

  with visible as (
    select request.id,
           business.slug as business_slug,
           business.name as business_name,
           case when request.status = 'new' then 'pending' else request.status end as status,
           request.preferred_at,
           request.party_size,
           service.name as service_name,
           request.created_at
      from public.customer_identities identity
      join public.customer_links link
        on link.identity_id = identity.id
       and link.auth_user_id = identity.auth_user_id
       and link.state = 'verified'
      join public.booking_requests request
        on request.business_id = link.business_id
       and request.customer_client_id = link.client_id
      join app.booking_management_tokens token
        on token.business_id = request.business_id
       and token.booking_request_id = request.id
       and token.customer_client_id = request.customer_client_id
       and token.authenticated_user_id = v_actor
      join public.businesses business on business.id = request.business_id
      left join public.services service
        on service.id = request.service_id
       and service.business_id = request.business_id
     where identity.auth_user_id = v_actor
       and identity.status = 'active'
       and request.appointment_id is null
       and (
         request.status in ('new', 'pending', 'waitlisted')
         or (
           request.status in ('declined', 'expired', 'cancelled')
           and request.created_at >= current_timestamp - interval '90 days'
         )
       )
       and (
         v_cursor_created is null
         or (request.created_at, request.id) < (v_cursor_created, v_cursor_id)
       )
     order by request.created_at desc, request.id desc
     limit v_limit + 1
  ), listed as (
    select * from visible
     order by created_at desc, id desc
     limit v_limit
  )
  select jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'request_id', listed.id,
        'business_slug', listed.business_slug,
        'business_name', listed.business_name,
        'status', listed.status,
        'preferred_at', listed.preferred_at,
        'party_size', listed.party_size,
        'service_name', listed.service_name,
        'created_at', listed.created_at
      ) order by listed.created_at desc, listed.id desc)
      from listed
    ), '[]'::jsonb),
    'truncated', (select count(*) from visible) > v_limit,
    'next_cursor', case
      when (select count(*) from visible) > v_limit then (
        select jsonb_build_object(
          'created_at', listed.created_at,
          'request_id', listed.id
        )
          from listed
         order by listed.created_at asc, listed.id asc
         limit 1
      )
      else null
    end
  ) into v_result;
  return v_result;
end
$$;

revoke all on function app.guard_booking_customer_binding_v72()
  from public, anon, authenticated;
revoke all on function app.resolve_verified_booking_client_v72(uuid,uuid)
  from public, anon, authenticated;
revoke all on function app.apply_bound_booking_consent_v72(uuid,uuid,uuid,boolean)
  from public, anon, authenticated;
revoke all on function app.request_bound_booking_v72(
  uuid,uuid,uuid,text,text,text,uuid,integer,timestamptz,text,uuid,boolean
) from public, anon, authenticated;
revoke all on function public.internal_public_booking_submit(
  text,text,text,text,uuid,integer,timestamptz,text,uuid,boolean,text,text,text
) from public, anon, authenticated;
revoke all on function public.internal_public_booking_submit(
  text,text,text,text,uuid,integer,timestamptz,text,uuid,boolean,text,text,text,uuid
) from public, anon, authenticated;
revoke all on function public.customer_get_booking_requests(integer,jsonb)
  from public, anon, authenticated;
revoke all on function public.convert_booking_request(uuid)
  from public, anon, authenticated;

grant execute on function public.internal_public_booking_submit(
  text,text,text,text,uuid,integer,timestamptz,text,uuid,boolean,text,text,text
) to service_role;
grant execute on function public.internal_public_booking_submit(
  text,text,text,text,uuid,integer,timestamptz,text,uuid,boolean,text,text,text,uuid
) to service_role;
grant execute on function public.customer_get_booking_requests(integer,jsonb)
  to authenticated;
grant execute on function public.convert_booking_request(uuid)
  to authenticated;

-- Fail the migration if the browser ACL or tenant binding shape drifted.
do $v72_catalog_gate$
begin
  if has_function_privilege(
       'anon', 'public.customer_get_booking_requests(integer,jsonb)', 'execute'
     ) or not has_function_privilege(
       'authenticated', 'public.customer_get_booking_requests(integer,jsonb)', 'execute'
     ) then
    raise exception 'v72 customer booking reader has the wrong browser ACL';
  end if;
  if has_function_privilege(
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
    raise exception 'v72 internal booking submit has the wrong role boundary';
  end if;
  if not exists (
    select 1
      from pg_constraint constraint_row
     where constraint_row.conname = 'booking_requests_customer_client_business_fk'
       and constraint_row.conrelid = 'public.booking_requests'::regclass
       and constraint_row.contype = 'f'
  ) then
    raise exception 'v72 booking request tenant FK is missing';
  end if;
end
$v72_catalog_gate$;

commit;
