-- FRENLY C42 — consumer verified-phone registration contracts.
--
-- Forward-only.  This migration deliberately stores no raw phone number outside
-- auth.users.  A non-blank auth.users.phone with phone_confirmed_at is the only
-- phone-possession authority.  Legal document rows are intentionally not seeded:
-- final document versions and hashes require the owner/legal approval and leave
-- registration fail-closed until supplied through the private operator path.

begin;

insert into app.platform_feature_flags(feature_key, enabled) values
  ('customer_phone_otp', false),
  ('customer_whatsapp_otp', false),
  ('customer_phone_registration', false),
  ('customer_phone_claims', false)
on conflict (feature_key) do nothing;

-- Extend the v30 evidence vocabulary without changing historical migration text.
-- Email proof rules remain explicit; phone can only be a contemporaneous Auth OTP
-- proof and never becomes a copied profile/contact column.
alter table public.customer_contact_proofs
  drop constraint customer_contact_proofs_method_type_check,
  drop constraint customer_contact_proofs_contact_type_check,
  add constraint customer_contact_proofs_contact_type_check
    check (contact_type in ('email', 'phone')),
  add constraint customer_contact_proofs_method_type_check check (
    (contact_type = 'email' and proof_method in (
      'auth_email_confirmation', 'email_otp', 'firm_invitation', 'support_recovery'
    ))
    or (contact_type = 'phone' and proof_method = 'auth_phone_otp')
  );

alter table public.customer_verified_contacts
  drop constraint customer_verified_contacts_contact_type_check,
  add constraint customer_verified_contacts_contact_type_check
    check (contact_type in ('email', 'phone'));

alter table public.customer_identities
  drop constraint customer_identities_created_via_check,
  add constraint customer_identities_created_via_check
    check (created_via in ('wallet_start', 'phone_registration'));

-- These forward allowlists reserve the audited v31 vocabulary for the separately
-- implemented phone-claim route; the raw tables remain fully browser-closed.
alter table public.customer_links
  drop constraint customer_links_verification_method_check,
  add constraint customer_links_verification_method_check
    check (verification_method in ('email_claim', 'firm_invitation', 'phone_claim'));
alter table public.customer_link_claim_attempts
  drop constraint customer_link_claim_attempts_operation_check,
  add constraint customer_link_claim_attempts_operation_check
    check (operation in ('email_claim', 'invitation_claim', 'phone_claim'));
alter table public.customer_link_audit_events
  drop constraint customer_link_audit_events_event_type_check,
  add constraint customer_link_audit_events_event_type_check check (event_type in (
    'email_claim_linked', 'email_claim_not_linked', 'email_claim_rate_limited',
    'phone_claim_linked', 'phone_claim_not_linked', 'phone_claim_rate_limited',
    'invitation_issued', 'invitation_claim_linked', 'invitation_claim_not_linked',
    'invitation_claim_rate_limited', 'link_unlinked'
  ));

-- Only private operators may publish the exact legal text version and content
-- digest.  No placeholder text/hash is treated as a legal acceptance target.
create table app.customer_legal_documents (
  document_key text primary key check (document_key in ('terms', 'privacy')),
  document_version text not null check (length(btrim(document_version)) between 1 and 80),
  document_sha256 text not null check (document_sha256 ~ '^[0-9a-f]{64}$'),
  published_at timestamptz not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table app.customer_legal_documents is
  'Private owner/legal manifest. C42 registration fails closed until active Terms and Privacy rows are approved.';
alter table app.customer_legal_documents enable row level security;
revoke all privileges on table app.customer_legal_documents from public, anon, authenticated;

create table public.customer_profiles (
  identity_id uuid primary key references public.customer_identities(id) on delete restrict,
  auth_user_id uuid not null unique references auth.users(id) on delete restrict,
  full_name text not null check (length(btrim(full_name)) between 1 and 200),
  birth_date date not null,
  preferred_language text not null default 'en'
    check (preferred_language ~ '^[a-z]{2,3}(-[A-Za-z]{2,4})?$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint customer_profiles_identity_auth_fk
    foreign key (identity_id, auth_user_id)
    references public.customer_identities(id, auth_user_id) on delete restrict
);
comment on table public.customer_profiles is
  'Private platform customer profile. Full DOB is never a cross-business wallet projection.';

create table public.customer_legal_acceptances (
  id uuid primary key default gen_random_uuid(),
  identity_id uuid not null references public.customer_identities(id) on delete restrict,
  auth_user_id uuid not null references auth.users(id) on delete restrict,
  document_key text not null check (document_key in ('terms', 'privacy')),
  document_version text not null,
  document_sha256 text not null check (document_sha256 ~ '^[0-9a-f]{64}$'),
  acceptance_hash text not null check (acceptance_hash ~ '^[0-9a-f]{64}$'),
  accepted_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint customer_legal_acceptances_identity_auth_fk
    foreign key (identity_id, auth_user_id)
    references public.customer_identities(id, auth_user_id) on delete restrict,
  constraint customer_legal_acceptances_exact_uk
    unique (identity_id, document_key, document_version, document_sha256)
);
comment on table public.customer_legal_acceptances is
  'Append-only versioned and hashed evidence of separately required Terms and Privacy acceptance.';

create table public.customer_registration_preferences (
  identity_id uuid primary key references public.customer_identities(id) on delete restrict,
  auth_user_id uuid not null unique references auth.users(id) on delete restrict,
  platform_marketing_opted_in boolean not null default false,
  updated_at timestamptz not null default now(),
  constraint customer_registration_preferences_identity_auth_fk
    foreign key (identity_id, auth_user_id)
    references public.customer_identities(id, auth_user_id) on delete restrict
);
comment on table public.customer_registration_preferences is
  'Optional platform-news preference only. It is not merchant marketing consent and phone proof never implies consent.';

create table public.customer_registration_operations (
  id uuid primary key default gen_random_uuid(),
  identity_id uuid not null references public.customer_identities(id) on delete restrict,
  actor_auth_user_id uuid not null references auth.users(id) on delete restrict,
  operation text not null check (operation in ('registration', 'profile_update')),
  idempotency_key text not null check (length(btrim(idempotency_key)) >= 8),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  outcome text not null check (outcome in ('completed', 'rate_limited')),
  response jsonb not null check (jsonb_typeof(response) = 'object'),
  created_at timestamptz not null default now(),
  constraint customer_registration_operations_idempotency_uk
    unique (identity_id, operation, idempotency_key)
);
comment on table public.customer_registration_operations is
  'Append-only registration/profile request evidence. It contains only keyed hashes and safe outcome facts, never raw profile or phone data.';

alter table public.customer_profiles enable row level security;
alter table public.customer_legal_acceptances enable row level security;
alter table public.customer_registration_preferences enable row level security;
alter table public.customer_registration_operations enable row level security;
revoke all privileges on table public.customer_profiles from public, anon, authenticated;
revoke all privileges on table public.customer_legal_acceptances from public, anon, authenticated;
revoke all privileges on table public.customer_registration_preferences from public, anon, authenticated;
revoke all privileges on table public.customer_registration_operations from public, anon, authenticated;

create or replace function app.c42_profile_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_identity text := nullif(current_setting('app.c42_profile_identity', true), '');
begin
  if tg_op = 'DELETE' then
    raise exception 'customer profiles are retained for controlled recovery' using errcode = '23000';
  end if;
  if v_identity is distinct from new.identity_id::text then
    raise exception 'customer profiles may only be written through a self-derived C42 RPC' using errcode = '42501';
  end if;
  if new.birth_date > current_date then
    raise exception 'birth date cannot be in the future' using errcode = '22023';
  end if;
  if tg_op = 'UPDATE' then
    if (new.identity_id, new.auth_user_id, new.birth_date, new.created_at)
        is distinct from (old.identity_id, old.auth_user_id, old.birth_date, old.created_at) then
      raise exception 'customer identity mapping and birth date require controlled recovery' using errcode = '23000';
    end if;
    new.updated_at := now();
  end if;
  return new;
end;
$$;

create or replace function app.c42_evidence_immutable_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception '% is append-only evidence', tg_table_name using errcode = '23000';
end;
$$;

create trigger customer_profiles_guard
  before insert or update or delete on public.customer_profiles
  for each row execute function app.c42_profile_guard();
create trigger customer_legal_acceptances_immutable_guard
  before update or delete on public.customer_legal_acceptances
  for each row execute function app.c42_evidence_immutable_guard();
create trigger customer_registration_operations_immutable_guard
  before update or delete on public.customer_registration_operations
  for each row execute function app.c42_evidence_immutable_guard();

-- This is the deliberately tiny unauthenticated pre-auth capability surface.
-- It reveals no account, provider, or customer state and defaults to both
-- channels disabled. Browser build flags may further disable a channel but
-- cannot turn a server-disabled channel on.
create or replace function public.get_customer_phone_otp_capabilities()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  return jsonb_build_object(
    'sms',
      app.platform_feature_enabled('customer_phone_registration')
      and app.platform_feature_enabled('customer_phone_otp'),
    'whatsapp',
      app.platform_feature_enabled('customer_phone_registration')
      and app.platform_feature_enabled('customer_phone_otp')
      and app.platform_feature_enabled('customer_whatsapp_otp')
  );
end;
$$;

create or replace function public.get_customer_feature_capabilities()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if auth.uid() is null then
    raise exception 'authenticated session required' using errcode = '28000';
  end if;
  return jsonb_build_object(
    'customer_identity', app.platform_feature_enabled('customer_identity'),
    'customer_claims', app.platform_feature_enabled('customer_claims'),
    'customer_wallet', app.platform_feature_enabled('customer_wallet'),
    'customer_actions', app.platform_feature_enabled('customer_actions'),
    'customer_notifications', app.platform_feature_enabled('customer_notifications'),
    'customer_email_otp', app.platform_feature_enabled('customer_email_otp'),
    'customer_phone_otp', app.platform_feature_enabled('customer_phone_otp'),
    'customer_whatsapp_otp', app.platform_feature_enabled('customer_whatsapp_otp'),
    'customer_phone_registration', app.platform_feature_enabled('customer_phone_registration'),
    'customer_phone_claims', app.platform_feature_enabled('customer_phone_claims')
  );
end;
$$;

create or replace function public.customer_register_verified_phone(
  p_full_name text,
  p_birth_date date,
  p_preferred_language text,
  p_accept_terms boolean,
  p_accept_privacy boolean,
  p_platform_marketing_opted_in boolean,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_identity public.customer_identities%rowtype;
  v_existing public.customer_registration_operations%rowtype;
  v_phone text;
  v_phone_confirmed_at timestamptz;
  v_name text := nullif(btrim(p_full_name), '');
  v_language text := lower(nullif(btrim(p_preferred_language), ''));
  v_terms app.customer_legal_documents%rowtype;
  v_privacy app.customer_legal_documents%rowtype;
  v_request_hash text;
  v_response jsonb;
  v_profile_exists boolean;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if not app.platform_feature_enabled('customer_phone_registration')
     or not app.platform_feature_enabled('customer_phone_otp') then
    raise exception 'customer registration is unavailable' using errcode = '0A000';
  end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8
     or v_name is null or p_birth_date is null or p_birth_date > current_date
     or v_language is null or v_language !~ '^[a-z]{2,3}(-[a-z]{2,4})?$'
     or p_accept_terms is not true or p_accept_privacy is not true then
    raise exception 'invalid customer registration request' using errcode = '22023';
  end if;
  p_idempotency_key := btrim(p_idempotency_key);

  select u.phone, u.phone_confirmed_at into v_phone, v_phone_confirmed_at
    from auth.users u where u.id = v_actor for share;
  if not found or v_phone_confirmed_at is null or nullif(btrim(v_phone), '') is null then
    raise exception 'a verified phone is required to register' using errcode = '42501';
  end if;

  select * into v_terms from app.customer_legal_documents d
   where d.document_key = 'terms' and d.active for share;
  select * into v_privacy from app.customer_legal_documents d
   where d.document_key = 'privacy' and d.active for share;
  if not found or v_terms.document_key is null or v_privacy.document_key is null then
    raise exception 'customer registration is unavailable' using errcode = '0A000';
  end if;

  insert into public.customer_identities (auth_user_id, created_via)
  values (v_actor, 'phone_registration')
  on conflict (auth_user_id) do nothing
  returning * into v_identity;
  if not found then
    select * into v_identity from public.customer_identities
     where auth_user_id = v_actor and status = 'active' for share;
  end if;
  if v_identity.id is null then
    raise exception 'customer registration is unavailable' using errcode = '0A000';
  end if;

  v_request_hash := app.v31_sha256_hex(
    'c42.registration:' || v_actor::text || ':'
    || app.v31_sha256_hex(v_name) || ':' || app.v31_sha256_hex(p_birth_date::text) || ':'
    || v_language || ':' || v_terms.document_version || ':' || v_terms.document_sha256 || ':'
    || v_privacy.document_version || ':' || v_privacy.document_sha256 || ':'
    || coalesce(p_platform_marketing_opted_in, false)::text
  );
  perform pg_advisory_xact_lock(hashtextextended(
    'c42:registration:' || v_identity.id::text || ':' || p_idempotency_key, 0
  ));
  select * into v_existing from public.customer_registration_operations o
   where o.identity_id = v_identity.id and o.operation = 'registration'
     and o.idempotency_key = p_idempotency_key for update;
  if found then
    if v_existing.request_hash is distinct from v_request_hash then
      raise exception 'idempotency key was already used for a different registration request' using errcode = '23505';
    end if;
    return v_existing.response;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('c42:registration-rate:' || v_identity.id::text, 0));
  if (select count(*) from public.customer_registration_operations o
       where o.identity_id = v_identity.id and o.operation = 'registration'
         and o.created_at >= now() - interval '15 minutes') >= 5 then
    v_response := jsonb_build_object('outcome', 'try_later', 'retry_after_seconds', 900);
    insert into public.customer_registration_operations (
      identity_id, actor_auth_user_id, operation, idempotency_key, request_hash, outcome, response
    ) values (v_identity.id, v_actor, 'registration', p_idempotency_key, v_request_hash, 'rate_limited', v_response);
    return v_response;
  end if;

  if not exists (
    select 1 from public.customer_verified_contacts c
     where c.identity_id = v_identity.id and c.contact_type = 'phone' and c.status = 'verified'
  ) then
    insert into public.customer_contact_proofs (
      identity_id, auth_user_id, contact_type, proof_method, status, issued_at, expires_at, verified_at
    ) values (
      v_identity.id, v_actor, 'phone', 'auth_phone_otp', 'verified', now(), now() + interval '15 minutes', now()
    );
    insert into public.customer_verified_contacts (
      identity_id, auth_user_id, contact_type, verification_proof_id
    ) select p.identity_id, p.auth_user_id, p.contact_type, p.id
      from public.customer_contact_proofs p
     where p.identity_id = v_identity.id and p.auth_user_id = v_actor
       and p.contact_type = 'phone' and p.proof_method = 'auth_phone_otp'
     order by p.created_at desc limit 1;
  end if;

  select exists(select 1 from public.customer_profiles p where p.identity_id = v_identity.id)
    into v_profile_exists;
  if v_profile_exists and exists (
    select 1 from public.customer_profiles p
     where p.identity_id = v_identity.id and p.birth_date is distinct from p_birth_date
  ) then
    raise exception 'birth date changes require controlled recovery' using errcode = '23000';
  end if;
  perform set_config('app.c42_profile_identity', v_identity.id::text, true);
  insert into public.customer_profiles (
    identity_id, auth_user_id, full_name, birth_date, preferred_language
  ) values (v_identity.id, v_actor, v_name, p_birth_date, v_language)
  on conflict (identity_id) do update set
    full_name = excluded.full_name, preferred_language = excluded.preferred_language;
  perform set_config('app.c42_profile_identity', '', true);

  insert into public.customer_legal_acceptances (
    identity_id, auth_user_id, document_key, document_version, document_sha256, acceptance_hash
  ) values
    (v_identity.id, v_actor, v_terms.document_key, v_terms.document_version, v_terms.document_sha256,
      app.v31_sha256_hex('c42.acceptance:' || v_actor::text || ':terms:' || v_terms.document_sha256)),
    (v_identity.id, v_actor, v_privacy.document_key, v_privacy.document_version, v_privacy.document_sha256,
      app.v31_sha256_hex('c42.acceptance:' || v_actor::text || ':privacy:' || v_privacy.document_sha256))
  on conflict (identity_id, document_key, document_version, document_sha256) do nothing;

  insert into public.customer_registration_preferences (
    identity_id, auth_user_id, platform_marketing_opted_in
  ) values (v_identity.id, v_actor, coalesce(p_platform_marketing_opted_in, false))
  on conflict (identity_id) do update set
    platform_marketing_opted_in = excluded.platform_marketing_opted_in, updated_at = now();

  v_response := jsonb_build_object('outcome', 'registered', 'profile_ready', true);
  insert into public.customer_registration_operations (
    identity_id, actor_auth_user_id, operation, idempotency_key, request_hash, outcome, response
  ) values (v_identity.id, v_actor, 'registration', p_idempotency_key, v_request_hash, 'completed', v_response);
  return v_response;
end;
$$;

create or replace function public.customer_get_profile()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null then raise exception 'authenticated customer session required' using errcode = '28000'; end if;
  if not app.platform_feature_enabled('customer_phone_registration') then
    raise exception 'customer profile is unavailable' using errcode = '0A000';
  end if;
  return jsonb_build_object('profile', (
    select jsonb_build_object(
      'full_name', p.full_name, 'birth_date', p.birth_date, 'preferred_language', p.preferred_language
    ) from public.customer_profiles p where p.auth_user_id = v_actor
  ));
end;
$$;

create or replace function public.customer_update_profile(
  p_full_name text,
  p_preferred_language text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_identity uuid;
  v_name text := nullif(btrim(p_full_name), '');
  v_language text := lower(nullif(btrim(p_preferred_language), ''));
  v_request_hash text;
  v_existing public.customer_registration_operations%rowtype;
  v_response jsonb;
begin
  if v_actor is null then raise exception 'authenticated customer session required' using errcode = '28000'; end if;
  if not app.platform_feature_enabled('customer_phone_registration') then
    raise exception 'customer profile is unavailable' using errcode = '0A000';
  end if;
  if v_name is null or v_language is null or v_language !~ '^[a-z]{2,3}(-[a-z]{2,4})?$'
     or p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'invalid customer profile request' using errcode = '22023';
  end if;
  v_identity := app.v31_current_identity();
  p_idempotency_key := btrim(p_idempotency_key);
  v_request_hash := app.v31_sha256_hex('c42.profile:' || v_actor::text || ':' || app.v31_sha256_hex(v_name) || ':' || v_language);
  perform pg_advisory_xact_lock(hashtextextended('c42:profile:' || v_identity::text || ':' || p_idempotency_key, 0));
  select * into v_existing from public.customer_registration_operations o
   where o.identity_id = v_identity and o.operation = 'profile_update' and o.idempotency_key = p_idempotency_key for update;
  if found then
    if v_existing.request_hash is distinct from v_request_hash then
      raise exception 'idempotency key was already used for a different profile request' using errcode = '23505';
    end if;
    return v_existing.response;
  end if;
  perform set_config('app.c42_profile_identity', v_identity::text, true);
  update public.customer_profiles set full_name = v_name, preferred_language = v_language
   where identity_id = v_identity and auth_user_id = v_actor;
  if not found then raise exception 'customer profile is unavailable' using errcode = '42501'; end if;
  perform set_config('app.c42_profile_identity', '', true);
  v_response := jsonb_build_object('outcome', 'updated');
  insert into public.customer_registration_operations (
    identity_id, actor_auth_user_id, operation, idempotency_key, request_hash, outcome, response
  ) values (v_identity, v_actor, 'profile_update', p_idempotency_key, v_request_hash, 'completed', v_response);
  return v_response;
end;
$$;

-- Claiming is deliberately slug/QR-led, never a platform directory lookup. The
-- outcome remains generic for unknown, absent, duplicate, previously linked, or
-- already-claimed records so a verified phone cannot enumerate merchant clients.
create or replace function public.customer_claim_link_by_verified_phone(
  p_business_slug text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_identity uuid;
  v_slug text := lower(btrim(coalesce(p_business_slug, '')));
  v_phone text;
  v_phone_confirmed_at timestamptz;
  v_phone_norm text;
  v_business uuid;
  v_link_id uuid;
  v_client_id uuid;
  v_candidate_ids uuid[];
  v_candidate_count integer := 0;
  v_existing public.customer_link_claim_attempts%rowtype;
  v_request_hash text;
  v_outcome text;
  v_event_type text;
  v_response jsonb;
begin
  if not app.platform_feature_enabled('customer_claims')
     or not app.platform_feature_enabled('customer_phone_claims')
     or not app.platform_feature_enabled('customer_phone_registration') then
    raise exception 'customer access is unavailable' using errcode = '0A000';
  end if;
  v_identity := app.v31_current_identity();
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8
     or length(v_slug) < 2 or length(v_slug) > 160 then
    raise exception 'invalid customer claim request' using errcode = '22023';
  end if;
  p_idempotency_key := btrim(p_idempotency_key);
  v_request_hash := app.v31_sha256_hex('c42.phone-claim:' || v_slug);
  perform pg_advisory_xact_lock(hashtextextended(
    'c42:phone-claim:' || v_identity::text || ':' || p_idempotency_key, 0
  ));
  select * into v_existing from public.customer_link_claim_attempts a
   where a.identity_id = v_identity and a.operation = 'phone_claim'
     and a.idempotency_key = p_idempotency_key for update;
  if found then
    if v_existing.request_hash is distinct from v_request_hash then
      raise exception 'idempotency key was already used for another claim request' using errcode = '23505';
    end if;
    return v_existing.response;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('c42:phone-claim-rate:' || v_identity::text, 0));
  if (select count(*) from public.customer_link_claim_attempts a
       where a.identity_id = v_identity and a.operation = 'phone_claim'
         and a.created_at >= now() - interval '15 minutes'
         and a.outcome <> 'rate_limited') >= 5 then
    v_outcome := 'rate_limited';
    v_response := jsonb_build_object('outcome', 'try_later', 'retry_after_seconds', 900);
    v_event_type := 'phone_claim_rate_limited';
  else
    select u.phone, u.phone_confirmed_at into v_phone, v_phone_confirmed_at
      from auth.users u where u.id = v_actor for share;
    v_phone_norm := app.norm_phone(v_phone);
    select b.id into v_business from public.businesses b where b.slug = v_slug for share;
    if v_phone_confirmed_at is null or v_phone_norm is null or v_business is null then
      v_outcome := 'not_linked';
      v_response := jsonb_build_object('outcome', 'no_link_created');
      v_event_type := 'phone_claim_not_linked';
    else
      perform pg_advisory_xact_lock(hashtextextended('c42:phone-business-link:' || v_business::text, 0));
      select l.id, l.client_id into v_link_id, v_client_id from public.customer_links l
       where l.identity_id = v_identity and l.business_id = v_business and l.state = 'verified'
       for update;
      if found then
        v_outcome := 'linked';
        v_response := jsonb_build_object('outcome', 'linked');
        v_event_type := 'phone_claim_linked';
      else
        -- Exact one unclaimed record only. Any historical link is retained as
        -- evidence and requires controlled recovery rather than reassignment.
        select coalesce(array_agg(c.id order by c.id), '{}'::uuid[]), count(*)::integer
          into v_candidate_ids, v_candidate_count
          from public.clients c
         where c.business_id = v_business and c.phone_norm = v_phone_norm
           and c.phone_norm is not null
           and not exists (select 1 from public.customer_links prior where prior.client_id = c.id);
        if v_candidate_count = 1 then
          v_link_id := gen_random_uuid();
          v_client_id := v_candidate_ids[1];
          perform set_config('app.customer_link_insert_id', v_link_id::text, true);
          insert into public.customer_links (
            id, business_id, identity_id, auth_user_id, client_id, state, verification_method, verified_at
          ) values (
            v_link_id, v_business, v_identity, v_actor, v_client_id, 'verified', 'phone_claim', now()
          );
          perform set_config('app.customer_link_insert_id', '', true);
          v_outcome := 'linked';
          v_response := jsonb_build_object('outcome', 'linked');
          v_event_type := 'phone_claim_linked';
        else
          v_outcome := 'not_linked';
          v_response := jsonb_build_object('outcome', 'no_link_created');
          v_event_type := 'phone_claim_not_linked';
        end if;
      end if;
    end if;
  end if;

  insert into public.customer_link_claim_attempts (
    identity_id, auth_user_id, business_id, link_id, operation, idempotency_key, request_hash, outcome, response
  ) values (
    v_identity, v_actor, v_business, v_link_id, 'phone_claim', p_idempotency_key,
    v_request_hash, v_outcome, v_response
  );
  insert into public.customer_link_audit_events (
    identity_id, actor_auth_user_id, business_id, client_id, link_id, event_type,
    idempotency_key, request_hash, response
  ) values (
    v_identity, v_actor, v_business, v_client_id, v_link_id, v_event_type,
    p_idempotency_key, v_request_hash, v_response
  );
  return v_response;
end;
$$;

revoke all on function app.c42_profile_guard() from public, anon, authenticated;
revoke all on function app.c42_evidence_immutable_guard() from public, anon, authenticated;
revoke all on function public.get_customer_phone_otp_capabilities() from public, anon, authenticated;
grant execute on function public.get_customer_phone_otp_capabilities() to anon;
grant execute on function public.get_customer_phone_otp_capabilities() to authenticated;
revoke all on function public.get_customer_feature_capabilities() from public, anon;
grant execute on function public.get_customer_feature_capabilities() to authenticated;
revoke all on function public.customer_register_verified_phone(text, date, text, boolean, boolean, boolean, text)
  from public, anon, authenticated;
revoke all on function public.customer_get_profile() from public, anon, authenticated;
revoke all on function public.customer_update_profile(text, text, text) from public, anon, authenticated;
revoke all on function public.customer_claim_link_by_verified_phone(text, text) from public, anon, authenticated;
grant execute on function public.customer_register_verified_phone(text, date, text, boolean, boolean, boolean, text)
  to authenticated;
grant execute on function public.customer_get_profile() to authenticated;
grant execute on function public.customer_update_profile(text, text, text) to authenticated;
grant execute on function public.customer_claim_link_by_verified_phone(text, text) to authenticated;

commit;
