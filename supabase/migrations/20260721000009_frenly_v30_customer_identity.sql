-- FRENLY v30 - CUSTOMER IDENTITY FOUNDATION
--
-- Local review candidate. Do not apply until the phase release gate is accepted.
-- This establishes a platform identity only. It deliberately creates no business
-- relationship, customer link, claim, wallet read, or access to public.clients.

begin;

-- Private release controls are created before the first customer RPC so every
-- later migration can fail closed. Browser roles never receive table or helper
-- access; public capability reads are exposed only through an allowlisted RPC.
create table if not exists app.platform_feature_flags (
  feature_key text primary key check (feature_key ~ '^[a-z][a-z0-9_]{2,63}$'),
  enabled boolean not null default false,
  changed_at timestamptz not null default now(),
  changed_by uuid
);
insert into app.platform_feature_flags(feature_key, enabled)
values ('customer_identity', false)
on conflict (feature_key) do nothing;
alter table app.platform_feature_flags enable row level security;
revoke all privileges on table app.platform_feature_flags from public, anon, authenticated;

create or replace function app.platform_feature_enabled(p_feature_key text)
returns boolean language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select coalesce((select f.enabled from app.platform_feature_flags f
                    where f.feature_key = $1), false)
$$;
revoke all on function app.platform_feature_enabled(text) from public, anon, authenticated;

create table public.customer_identities (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique references auth.users(id) on delete restrict,
  status text not null default 'active' check (status in ('active', 'disabled')),
  created_via text not null default 'wallet_start' check (created_via in ('wallet_start')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint customer_identities_identity_auth_uk unique (id, auth_user_id)
);

create table public.customer_contact_proofs (
  id uuid primary key default gen_random_uuid(),
  identity_id uuid not null references public.customer_identities(id) on delete restrict,
  auth_user_id uuid not null references auth.users(id) on delete restrict,
  -- Phone proof is deferred. A shared or recycled phone is never authority for
  -- this MVP, so v30 records verified email evidence only.
  contact_type text not null check (contact_type = 'email'),
  proof_method text not null check (proof_method in (
    'auth_email_confirmation', 'email_otp', 'firm_invitation', 'support_recovery'
  )),
  status text not null check (status in ('verified', 'expired', 'revoked')),
  issued_at timestamptz not null default now(),
  expires_at timestamptz not null,
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  constraint customer_contact_proofs_expiry_check check (expires_at > issued_at),
  constraint customer_contact_proofs_state_check check (
    (status = 'verified' and verified_at is not null)
    or (status in ('expired', 'revoked') and verified_at is null)
  ),
  constraint customer_contact_proofs_method_type_check
    check (contact_type = 'email'),
  constraint customer_contact_proofs_identity_auth_fk
    foreign key (identity_id, auth_user_id)
    references public.customer_identities(id, auth_user_id) on delete restrict,
  constraint customer_contact_proofs_identity_contact_uk
    unique (id, identity_id, auth_user_id, contact_type)
);

create table public.customer_verified_contacts (
  id uuid primary key default gen_random_uuid(),
  identity_id uuid not null references public.customer_identities(id) on delete restrict,
  auth_user_id uuid not null references auth.users(id) on delete restrict,
  contact_type text not null check (contact_type = 'email'),
  verification_proof_id uuid not null unique,
  status text not null default 'verified' check (status in ('verified', 'revoked')),
  verified_at timestamptz not null default now(),
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  constraint customer_verified_contacts_revocation_check check (
    (status = 'verified' and revoked_at is null)
    or (status = 'revoked' and revoked_at is not null)
  ),
  constraint customer_verified_contacts_proof_integrity_fk
    foreign key (verification_proof_id, identity_id, auth_user_id, contact_type)
    references public.customer_contact_proofs(id, identity_id, auth_user_id, contact_type)
    on delete restrict,
  constraint customer_verified_contacts_identity_auth_fk
    foreign key (identity_id, auth_user_id)
    references public.customer_identities(id, auth_user_id) on delete restrict
);

create unique index customer_verified_contacts_active_identity_contact_uk
  on public.customer_verified_contacts (identity_id, contact_type)
  where status = 'verified';

create index customer_contact_proofs_identity_time_idx
  on public.customer_contact_proofs (identity_id, created_at desc);

create table public.customer_identity_audit_events (
  id uuid primary key default gen_random_uuid(),
  identity_id uuid not null references public.customer_identities(id) on delete restrict,
  actor_auth_user_id uuid not null references auth.users(id) on delete restrict,
  event_type text not null check (event_type in ('identity_created')),
  idempotency_key text not null check (length(btrim(idempotency_key)) >= 8),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{32}$'),
  response jsonb not null check (jsonb_typeof(response) = 'object'),
  created_at timestamptz not null default now(),
  constraint customer_identity_audit_events_idempotency_uk
    unique (identity_id, event_type, idempotency_key)
);

create index customer_identity_audit_events_identity_time_idx
  on public.customer_identity_audit_events (identity_id, created_at desc);

alter table public.customer_identities enable row level security;
alter table public.customer_contact_proofs enable row level security;
alter table public.customer_verified_contacts enable row level security;
alter table public.customer_identity_audit_events enable row level security;

-- There are intentionally no browser-role policies. Customer access exists only
-- through the allowlisted, self-derived customer_* RPCs below.
revoke all privileges on table public.customer_identities
  from public, anon, authenticated;
revoke all privileges on table public.customer_contact_proofs
  from public, anon, authenticated;
revoke all privileges on table public.customer_verified_contacts
  from public, anon, authenticated;
revoke all privileges on table public.customer_identity_audit_events
  from public, anon, authenticated;

create or replace function app.customer_identity_mapping_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if new.auth_user_id is distinct from old.auth_user_id then
    raise exception 'customer identity auth mapping is immutable' using errcode = '23000';
  end if;
  return new;
end;
$$;

create trigger customer_identities_mapping_guard
  before update on public.customer_identities
  for each row execute function app.customer_identity_mapping_guard();

create or replace function app.customer_contact_proof_immutable_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'customer contact proofs are append-only evidence' using errcode = '23000';
end;
$$;

create trigger customer_contact_proofs_immutable_guard
  before update or delete on public.customer_contact_proofs
  for each row execute function app.customer_contact_proof_immutable_guard();

create or replace function app.customer_identity_audit_immutable_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'customer identity audit events are append-only' using errcode = '23000';
end;
$$;

create trigger customer_identity_audit_events_immutable_guard
  before update or delete on public.customer_identity_audit_events
  for each row execute function app.customer_identity_audit_immutable_guard();

create or replace function public.customer_create_identity(p_idempotency_key text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_identity public.customer_identities%rowtype;
  v_email_confirmed_at timestamptz;
  v_proof_id uuid;
  v_created boolean := false;
  v_existing_hash text;
  v_request_hash text := md5('customer_create_identity:v1');
  v_response jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if not app.platform_feature_enabled('customer_identity') then
    raise exception 'customer access is unavailable' using errcode = '0A000';
  end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'idempotency key must contain at least 8 characters' using errcode = '22023';
  end if;
  p_idempotency_key := btrim(p_idempotency_key);

  select u.email_confirmed_at
    into v_email_confirmed_at
    from auth.users u
   where u.id = v_actor
   for share;
  if not found then
    raise exception 'authenticated user no longer exists' using errcode = '28000';
  end if;
  if v_email_confirmed_at is null or not exists (
    select 1 from auth.users u
     where u.id = v_actor and nullif(btrim(u.email), '') is not null
  ) then
    raise exception 'a verified email is required to create a customer identity'
      using errcode = '42501';
  end if;

  insert into public.customer_identities (auth_user_id)
  values (v_actor)
  on conflict (auth_user_id) do nothing
  returning * into v_identity;
  v_created := found;

  if not v_created then
    select * into v_identity
      from public.customer_identities
     where auth_user_id = v_actor;
  end if;

  -- An identity is platform-scoped. This proof is for the authenticated email
  -- only; it creates no client relationship. Phone proof is deferred from v30.
  select a.request_hash, a.response into v_existing_hash, v_response
    from public.customer_identity_audit_events a
   where a.identity_id = v_identity.id
     and a.event_type = 'identity_created'
     and a.idempotency_key = p_idempotency_key;
  if v_existing_hash is not null and v_existing_hash <> v_request_hash then
    raise exception 'idempotency key was already used for another request'
      using errcode = '22023';
  end if;
  if v_response is not null then
    return v_response;
  end if;

  if v_created then
    insert into public.customer_contact_proofs (
      identity_id, auth_user_id, contact_type, proof_method, status,
      issued_at, expires_at, verified_at
    ) values (
      v_identity.id, v_actor, 'email', 'auth_email_confirmation', 'verified',
      now(), now() + interval '15 minutes', now()
    ) returning id into v_proof_id;

    insert into public.customer_verified_contacts (
      identity_id, auth_user_id, contact_type, verification_proof_id
    ) values (v_identity.id, v_actor, 'email', v_proof_id);

    v_response := jsonb_build_object(
      'identity_id', v_identity.id, 'status', v_identity.status,
      'created_at', v_identity.created_at, 'created', true
    );
    insert into public.customer_identity_audit_events (
      identity_id, actor_auth_user_id, event_type, idempotency_key, request_hash, response
    ) values (
      v_identity.id, v_actor, 'identity_created', p_idempotency_key, v_request_hash, v_response
    );
  end if;

  return coalesce(v_response, jsonb_build_object(
    'identity_id', v_identity.id,
    'status', v_identity.status,
    'created_at', v_identity.created_at,
    'created', v_created
  ));
end;
$$;

create or replace function public.customer_get_identity()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_identity public.customer_identities%rowtype;
  v_contact_types jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if not app.platform_feature_enabled('customer_identity') then
    raise exception 'customer access is unavailable' using errcode = '0A000';
  end if;

  select * into v_identity
    from public.customer_identities
   where auth_user_id = v_actor;
  if not found then
    return jsonb_build_object('identity', null);
  end if;

  select coalesce(jsonb_agg(c.contact_type order by c.contact_type), '[]'::jsonb)
    into v_contact_types
    from public.customer_verified_contacts c
   where c.identity_id = v_identity.id
     and c.status = 'verified';

  return jsonb_build_object(
    'identity_id', v_identity.id,
    'status', v_identity.status,
    'created_at', v_identity.created_at,
    'verified_contact_types', v_contact_types
  );
end;
$$;

revoke all on function app.customer_identity_mapping_guard()
  from public, anon, authenticated;
revoke all on function app.customer_contact_proof_immutable_guard()
  from public, anon, authenticated;
revoke all on function app.customer_identity_audit_immutable_guard()
  from public, anon, authenticated;
revoke all on function public.customer_create_identity(text)
  from public, anon, authenticated;
revoke all on function public.customer_get_identity()
  from public, anon, authenticated;
grant execute on function public.customer_create_identity(text) to authenticated;
grant execute on function public.customer_get_identity() to authenticated;

commit;
