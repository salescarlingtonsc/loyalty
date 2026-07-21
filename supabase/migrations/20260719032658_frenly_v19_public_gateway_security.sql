-- Frenly v19: public traffic terminates at rate-limited Edge Functions.
-- Canonical order: source parity through v17, v18 reporting, v19 gateway, v20 financial.
-- Generated with `supabase migration new frenly_v19_public_gateway_security`.

begin;

create schema if not exists app;

create table if not exists app.public_gateway_rate_limits (
  scope text not null,
  key_hash text not null check (key_hash ~ '^[0-9a-f]{64}$'),
  window_started_at timestamptz not null,
  expires_at timestamptz not null,
  request_count integer not null check (request_count > 0),
  primary key (scope, key_hash)
);

create index if not exists public_gateway_rate_limits_expiry
  on app.public_gateway_rate_limits (expires_at);

alter table public.booking_requests
  add constraint booking_requests_id_business_unique unique (id, business_id);

create table if not exists app.booking_management_tokens (
  id uuid primary key default gen_random_uuid(),
  token_hash bytea not null unique check (octet_length(token_hash) = 32),
  idempotency_hash bytea not null check (octet_length(idempotency_hash) = 32),
  request_fingerprint bytea not null check (octet_length(request_fingerprint) = 32),
  business_id uuid not null references public.businesses(id) on delete cascade,
  booking_request_id uuid,
  appointment_id uuid,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at timestamptz,
  initial_response jsonb not null,
  check (booking_request_id is not null or appointment_id is not null),
  foreign key (booking_request_id, business_id)
    references public.booking_requests(id, business_id) on delete cascade,
  foreign key (appointment_id, business_id)
    references public.appointments(id, business_id) on delete cascade
);

create table if not exists app.booking_management_change_submissions (
  management_token_id uuid not null references app.booking_management_tokens(id) on delete cascade,
  submission_id uuid not null,
  request_fingerprint bytea not null check (octet_length(request_fingerprint) = 32),
  result jsonb not null,
  created_at timestamptz not null default now(),
  primary key (management_token_id, submission_id)
);

create unique index if not exists booking_management_token_request
  on app.booking_management_tokens (booking_request_id)
  where booking_request_id is not null;
create index if not exists booking_management_token_appointment
  on app.booking_management_tokens (appointment_id)
  where appointment_id is not null;
create index if not exists booking_management_token_expiry
  on app.booking_management_tokens (expires_at);
create unique index if not exists booking_management_token_idempotency
  on app.booking_management_tokens (business_id, idempotency_hash);

-- The app schema is not exposed, but RLS remains enabled as defense in depth.
-- No end-user policies exist; service-role RPCs run as their SECURITY DEFINER owner.
alter table app.public_gateway_rate_limits enable row level security;
alter table app.booking_management_tokens enable row level security;
alter table app.booking_management_change_submissions enable row level security;

-- Token-authenticated requests do not manufacture or retain a claimant phone number.
alter table public.change_requests alter column phone drop not null;

-- Authenticated reporting/RLS paths must resolve established app.has_perm,
-- app.can_module and app.can_see_branch helpers. Schema USAGE permits name
-- resolution only; it does not grant CREATE, table access or function EXECUTE.
revoke create on schema app from public, anon, authenticated;
revoke usage on schema app from public, anon;
grant usage on schema app to authenticated, service_role;
revoke all on app.public_gateway_rate_limits from public, anon, authenticated;
revoke all on app.booking_management_tokens from public, anon, authenticated;
revoke all on app.booking_management_change_submissions from public, anon, authenticated;

create or replace function public.internal_gateway_rate_limit(
  p_scope text,
  p_key_hash text,
  p_limit integer,
  p_window_seconds integer)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_row app.public_gateway_rate_limits%rowtype;
begin
  if p_scope !~ '^[a-z][a-z0-9_-]{1,63}$'
     or p_key_hash !~ '^[0-9a-f]{64}$'
     or p_limit not between 1 and 1000
     or p_window_seconds not between 1 and 86400 then
    raise exception using errcode = '22023', message = 'invalid request';
  end if;

  delete from app.public_gateway_rate_limits
   where expires_at < v_now - interval '1 day';

  insert into app.public_gateway_rate_limits
    (scope, key_hash, window_started_at, expires_at, request_count)
  values
    (p_scope, p_key_hash, v_now, v_now + make_interval(secs => p_window_seconds), 1)
  on conflict (scope, key_hash) do update
    set window_started_at = case
          when app.public_gateway_rate_limits.expires_at <= v_now then v_now
          else app.public_gateway_rate_limits.window_started_at end,
        expires_at = case
          when app.public_gateway_rate_limits.expires_at <= v_now
          then v_now + make_interval(secs => p_window_seconds)
          else app.public_gateway_rate_limits.expires_at end,
        request_count = case
          when app.public_gateway_rate_limits.expires_at <= v_now then 1
          else least(p_limit + 1, app.public_gateway_rate_limits.request_count + 1) end
  returning * into v_row;

  return jsonb_build_object(
    'allowed', v_row.request_count <= p_limit,
    'retry_after', greatest(0, ceil(extract(epoch from (v_row.expires_at - v_now)))::integer));
end;
$$;

create or replace function public.internal_public_join_page(p_slug text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app
as $$
declare v_page json;
begin
  if p_slug is null or p_slug !~ '^[a-z0-9][a-z0-9-]{0,62}$' then
    return null;
  end if;
  select public.get_join_page(p_slug) into v_page;
  return v_page::jsonb;
exception when others then
  return null;
end;
$$;

create or replace function public.internal_public_join(
  p_slug text,
  p_name text,
  p_phone text,
  p_email text default null,
  p_consent boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app
as $$
declare
  v_business record;
  v_phone_norm text;
  v_result json;
begin
  if p_slug is null or p_slug !~ '^[a-z0-9][a-z0-9-]{0,62}$'
     or p_name is null or char_length(btrim(p_name)) not between 2 and 100
     or p_phone is null or char_length(p_phone) > 32
     or (p_email is not null and (char_length(p_email) > 254
          or p_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$')) then
    raise exception using errcode = '22023', message = 'invalid request';
  end if;

  select b.id, b.name into v_business
    from public.businesses b
   where b.slug = p_slug and coalesce(b.join_enabled, false)
   limit 1;
  if not found then
    raise exception using errcode = '22023', message = 'invalid request';
  end if;

  v_phone_norm := app.norm_phone(p_phone);
  if v_phone_norm is null then
    raise exception using errcode = '22023', message = 'invalid request';
  end if;

  -- Repeated phone-only signup is deliberately opaque and never mutates PII or consent.
  if exists (
    select 1 from public.clients c
     where c.business_id = v_business.id and c.phone_norm = v_phone_norm
  ) then
    return jsonb_build_object('status', 'ok', 'business_name', v_business.name);
  end if;

  select public.join_program(
    p_slug, btrim(p_name), v_phone_norm,
    nullif(btrim(p_email), ''), coalesce(p_consent, false))
  into v_result;
  return v_result::jsonb;
exception
  when unique_violation then
    return jsonb_build_object('status', 'ok', 'business_name', v_business.name);
end;
$$;

create or replace function public.internal_public_booking_page(p_slug text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app
as $$
declare v_page json;
begin
  if p_slug is null or p_slug !~ '^[a-z0-9][a-z0-9-]{0,62}$' then
    return null;
  end if;
  select public.get_business_public(p_slug) into v_page;
  return v_page::jsonb;
exception when others then
  return null;
end;
$$;

-- A public booking may opt in only the client row created by that same transaction.
-- Knowing an existing phone or email is never proof of identity or consent authority.
create or replace function app.upsert_portal_client(
  p_biz uuid,
  p_name text,
  p_phone text,
  p_email text)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, app
as $$
declare
  v_client uuid;
  v_phone_norm text := app.norm_phone(p_phone);
  v_email text := nullif(btrim(p_email), '');
begin
  perform set_config('app.portal_client_created', '', true);

  select c.id into v_client
    from public.clients c
   where c.business_id = p_biz
     and ((v_phone_norm is not null and c.phone_norm = v_phone_norm)
       or (v_email is not null and lower(c.email) = lower(v_email)))
   order by c.created_at
   limit 1;
  if found then
    return v_client;
  end if;

  insert into public.clients (business_id, full_name, phone, email, marketing_consent)
  values (p_biz, btrim(p_name), nullif(btrim(p_phone), ''), v_email, false)
  on conflict (business_id, phone_norm) where phone_norm is not null do nothing
  returning id into v_client;

  if v_client is not null then
    perform set_config('app.portal_client_created', v_client::text, true);
    return v_client;
  end if;

  -- A concurrent insert won the phone conflict. Treat it as pre-existing.
  select c.id into v_client
    from public.clients c
   where c.business_id = p_biz and c.phone_norm = v_phone_norm
   limit 1;
  return v_client;
end;
$$;

create or replace function app.apply_booking_consent(
  p_biz uuid,
  p_client uuid,
  p_consent boolean)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public, app
as $$
begin
  -- An unchecked box is not a withdrawal, and an existing identity is not mutable
  -- through an unauthenticated booking submission.
  if p_client is null or coalesce(p_consent, false) is false then
    return;
  end if;
  if current_setting('app.portal_client_created', true) is distinct from p_client::text then
    return;
  end if;

  update public.clients
     set marketing_consent = true
   where id = p_client and business_id = p_biz and marketing_consent is false;
  if found then
    insert into public.consents (business_id, client_id, channel, action, source, actor)
    values (p_biz, p_client, 'marketing', 'granted', 'public_booking_v19_new_client', null);
  end if;
  perform set_config('app.portal_client_created', '', true);
end;
$$;

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
  p_request_fingerprint text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app
as $$
declare
  v_business public.businesses%rowtype;
  v_result json;
  v_request uuid;
  v_appointment uuid;
  v_token_expiry timestamptz;
  v_prior jsonb;
  v_prior_fingerprint bytea;
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
     or (p_email is not null and (char_length(p_email) > 254
          or p_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'))
     or (p_phone is not null and p_phone !~ '^\+[1-9][0-9]{7,14}$') then
    raise exception using errcode = '22023', message = 'invalid request';
  end if;

  select b.* into v_business from public.businesses b where b.slug = p_slug limit 1;
  if not found then
    raise exception using errcode = '22023', message = 'invalid request';
  end if;

  select t.initial_response, t.request_fingerprint into v_prior, v_prior_fingerprint
    from app.booking_management_tokens t
   where t.idempotency_hash = decode(p_idempotency_hash, 'hex')
     and t.business_id = v_business.id
   for update;
  if found then
    if v_prior_fingerprint <> decode(p_request_fingerprint, 'hex') then
      return jsonb_build_object('conflict', true);
    end if;
    return v_prior || jsonb_build_object('replayed', true);
  end if;

  if p_preferred < clock_timestamp() + interval '15 minutes'
     or p_preferred > clock_timestamp() + interval '365 days' then
    raise exception using errcode = '22023', message = 'invalid request';
  end if;

  if p_service is not null and not exists (
    select 1 from public.services s
     where s.id = p_service and s.business_id = v_business.id
       and s.active and s.show_on_booking_page
  ) then
    raise exception using errcode = '22023', message = 'invalid request';
  end if;

  if p_table_type is not null and not exists (
    select 1 from public.booking_tables bt
     where bt.id = p_table_type and bt.business_id = v_business.id and bt.active
       and (bt.pax is null or p_party <= bt.pax)
  ) then
    raise exception using errcode = '22023', message = 'invalid request';
  end if;

  select public.request_booking(
    p_slug, btrim(p_name), nullif(btrim(p_email), ''), p_phone,
    p_service, p_party, p_preferred, nullif(btrim(p_notes), ''),
    p_table_type, coalesce(p_consent, false))
  into v_result;

  v_request := nullif(v_result->>'request_id', '')::uuid;
  v_appointment := nullif(v_result->>'appointment_id', '')::uuid;
  if v_request is null and v_appointment is null then
    raise exception using errcode = 'P0001', message = 'invalid request';
  end if;

  v_token_expiry := greatest(clock_timestamp() + interval '30 days', p_preferred + interval '30 days');
  insert into app.booking_management_tokens
    (token_hash, idempotency_hash, request_fingerprint, business_id, booking_request_id, appointment_id,
     expires_at, initial_response)
  values
    (decode(p_token_hash, 'hex'), decode(p_idempotency_hash, 'hex'),
     decode(p_request_fingerprint, 'hex'), v_business.id,
     v_request, v_appointment, v_token_expiry, v_result::jsonb);

  return v_result::jsonb || jsonb_build_object('replayed', false);
end;
$$;

create or replace function public.internal_public_booking_lookup(p_token_hash text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app
as $$
declare v_token app.booking_management_tokens%rowtype;
begin
  if p_token_hash !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'invalid request';
  end if;

  select * into v_token
    from app.booking_management_tokens t
   where t.token_hash = decode(p_token_hash, 'hex')
     and t.revoked_at is null and t.expires_at > clock_timestamp()
   for update;
  if not found then
    raise exception using errcode = '22023', message = 'invalid request';
  end if;

  update app.booking_management_tokens set last_used_at = clock_timestamp()
   where id = v_token.id;

  return (
    select jsonb_build_object(
      'status', coalesce(a.status, br.status),
      'preferred_at', br.preferred_at,
      'starts_at', a.starts_at,
      'service_name', s.name,
      'can_change', a.id is not null and a.status = 'booked' and a.starts_at > clock_timestamp(),
      'expires_at', v_token.expires_at)
      from (select 1) seed
      left join public.booking_requests br on br.id = v_token.booking_request_id
      left join public.appointments a on a.id = coalesce(v_token.appointment_id, br.appointment_id)
      left join public.services s on s.id = coalesce(a.service_id, br.service_id)
  );
end;
$$;

create or replace function public.internal_public_booking_change(
  p_token_hash text,
  p_submission_id uuid,
  p_request_fingerprint text,
  p_kind text,
  p_proposed timestamptz default null,
  p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app
as $$
declare
  v_token app.booking_management_tokens%rowtype;
  v_appt record;
  v_auto boolean;
  v_status text := 'pending';
  v_request uuid;
  v_prior app.booking_management_change_submissions%rowtype;
  v_result jsonb;
begin
  if p_token_hash !~ '^[0-9a-f]{64}$'
     or p_submission_id is null
     or p_request_fingerprint !~ '^[0-9a-f]{64}$'
     or p_kind not in ('cancel', 'reschedule')
     or char_length(coalesce(p_note, '')) > 500
     or (p_kind = 'cancel' and p_proposed is not null)
     or (p_kind = 'reschedule' and p_proposed is null) then
    raise exception using errcode = '22023', message = 'invalid request';
  end if;

  select * into v_token
    from app.booking_management_tokens t
   where t.token_hash = decode(p_token_hash, 'hex')
     and t.revoked_at is null and t.expires_at > clock_timestamp()
   for update;
  if not found then
    raise exception using errcode = '22023', message = 'invalid request';
  end if;

  select * into v_prior
    from app.booking_management_change_submissions s
   where s.management_token_id = v_token.id and s.submission_id = p_submission_id;
  if found then
    if v_prior.request_fingerprint <> decode(p_request_fingerprint, 'hex') then
      return jsonb_build_object('conflict', true);
    end if;
    return v_prior.result || jsonb_build_object('replayed', true);
  end if;

  if p_kind = 'reschedule' and
     (p_proposed < clock_timestamp() + interval '15 minutes'
      or p_proposed > clock_timestamp() + interval '365 days') then
    raise exception using errcode = '22023', message = 'invalid request';
  end if;

  select a.id, a.business_id, a.client_id, a.starts_at, a.ends_at, a.status,
         b.auto_approve_changes
    into v_appt
    from public.appointments a
    join public.businesses b on b.id = a.business_id
   where a.id = v_token.appointment_id and a.business_id = v_token.business_id
     and a.status = 'booked' and a.starts_at > clock_timestamp()
   for update of a;
  if not found then
    raise exception using errcode = '22023', message = 'invalid request';
  end if;

  select cr.id, cr.status into v_request, v_status
    from public.change_requests cr
   where cr.appointment_id = v_appt.id and cr.status = 'pending'
   order by cr.created_at desc
   limit 1;
  if found then
    return jsonb_build_object('conflict', true);
  end if;

  insert into public.change_requests
    (business_id, appointment_id, kind, proposed_at, phone, note, status)
  values
    (v_appt.business_id, v_appt.id, p_kind, p_proposed, null,
     nullif(btrim(p_note), ''), 'pending')
  returning id into v_request;

  v_auto := coalesce(v_appt.auto_approve_changes, false);
  -- Public reschedules always remain pending until the canonical availability,
  -- hours, capacity, staff and overlap engine can approve them.
  if v_auto and p_kind = 'cancel' then
    update public.appointments set status = 'cancelled'
     where id = v_appt.id and business_id = v_appt.business_id and status = 'booked';
    update public.change_requests
       set status = 'approved', decided_at = clock_timestamp()
     where id = v_request;
    v_status := 'approved';
  end if;

  update app.booking_management_tokens set last_used_at = clock_timestamp()
   where id = v_token.id;
  v_result := jsonb_build_object('id', v_request, 'status', v_status);
  insert into app.booking_management_change_submissions
    (management_token_id, submission_id, request_fingerprint, result)
  values
    (v_token.id, p_submission_id, decode(p_request_fingerprint, 'hex'), v_result);
  return v_result || jsonb_build_object('replayed', false);
end;
$$;

create or replace function app.link_booking_management_token()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, app
as $$
begin
  if new.appointment_id is not null
     and (tg_op = 'INSERT' or old.appointment_id is distinct from new.appointment_id) then
    update app.booking_management_tokens
       set appointment_id = new.appointment_id
     where booking_request_id = new.id and business_id = new.business_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_link_booking_management_token on public.booking_requests;
create trigger trg_link_booking_management_token
after insert or update of appointment_id on public.booking_requests
for each row execute function app.link_booking_management_token();

-- New internal RPCs are callable only with the Edge Function's secret/service key.
revoke all on function public.internal_gateway_rate_limit(text,text,integer,integer) from public, anon, authenticated;
revoke all on function public.internal_public_join_page(text) from public, anon, authenticated;
revoke all on function public.internal_public_join(text,text,text,text,boolean) from public, anon, authenticated;
revoke all on function public.internal_public_booking_page(text) from public, anon, authenticated;
revoke all on function public.internal_public_booking_submit(text,text,text,text,uuid,integer,timestamptz,text,uuid,boolean,text,text,text) from public, anon, authenticated;
revoke all on function public.internal_public_booking_lookup(text) from public, anon, authenticated;
revoke all on function public.internal_public_booking_change(text,uuid,text,text,timestamptz,text) from public, anon, authenticated;
revoke all on function app.upsert_portal_client(uuid,text,text,text) from public, anon, authenticated;
revoke all on function app.apply_booking_consent(uuid,uuid,boolean) from public, anon, authenticated;
grant execute on function public.internal_gateway_rate_limit(text,text,integer,integer) to service_role;
grant execute on function public.internal_public_join_page(text) to service_role;
grant execute on function public.internal_public_join(text,text,text,text,boolean) to service_role;
grant execute on function public.internal_public_booking_page(text) to service_role;
grant execute on function public.internal_public_booking_submit(text,text,text,text,uuid,integer,timestamptz,text,uuid,boolean,text,text,text) to service_role;
grant execute on function public.internal_public_booking_lookup(text) to service_role;
grant execute on function public.internal_public_booking_change(text,uuid,text,text,timestamptz,text) to service_role;

-- Remove every legacy public-gateway overload, including signatures reconstructed by transfer.
do $$
declare v_proc regprocedure;
begin
  for v_proc in
    select p.oid::regprocedure
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = any (array[
         'join_program', 'enrol_customer', 'get_join_page',
         'request_booking', 'get_booking_availability', 'get_business_public',
         'list_my_appointments', 'request_change'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', v_proc);
  end loop;
end;
$$;

revoke all on function app.link_booking_management_token() from public, anon, authenticated;

commit;