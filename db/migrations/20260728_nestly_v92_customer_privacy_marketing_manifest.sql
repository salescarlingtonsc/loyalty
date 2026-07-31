-- NESTLY v92 - CUSTOMER PRIVACY MARKETING MANIFEST
--
-- Advances only the active Privacy Notice to the 28 July 2026 wording that
-- describes optional Nestly and selected-partner marketing. Terms remain on
-- their independently versioned v80 document. Existing acceptance evidence is
-- append-only and continues to retain the exact version and digest accepted.

begin;

lock table app.customer_legal_documents in share row exclusive mode;

do $v92_customer_privacy_marketing_manifest$
begin
  if not exists (
    select 1
      from app.customer_legal_documents d
     where d.document_key = 'privacy'
       and (
         (
           d.document_version = '2026-07-26'
           and d.document_sha256 = 'e3b82c000904491591d1d077052099b50f9a25e5a1ebd1e2a587da0789e274b0'
           and d.published_at = timestamptz '2026-07-26 00:00:00+08:00'
           and d.active
         )
         or (
           d.document_version = '2026-07-28'
           and d.document_sha256 = '994400cadc703134d9c8bd3868fe054f94e37153c47c2d2e688064bdc75138c9'
           and d.published_at = timestamptz '2026-07-28 00:00:00+08:00'
           and d.active
         )
       )
  ) then
    raise exception 'customer legal manifest conflicts with approved Nestly privacy notice'
      using errcode = '23505';
  end if;

  update app.customer_legal_documents d
     set document_version = '2026-07-28',
         document_sha256 = '994400cadc703134d9c8bd3868fe054f94e37153c47c2d2e688064bdc75138c9',
         published_at = timestamptz '2026-07-28 00:00:00+08:00',
         updated_at = timestamptz '2026-07-28 00:00:00+08:00'
   where d.document_key = 'privacy'
     and d.document_version = '2026-07-26'
     and d.document_sha256 = 'e3b82c000904491591d1d077052099b50f9a25e5a1ebd1e2a587da0789e274b0'
     and d.published_at = timestamptz '2026-07-26 00:00:00+08:00'
     and d.active;

  if (
    select count(*)
      from app.customer_legal_documents d
     where d.document_key = 'privacy'
       and d.document_version = '2026-07-28'
       and d.document_sha256 = '994400cadc703134d9c8bd3868fe054f94e37153c47c2d2e688064bdc75138c9'
       and d.published_at = timestamptz '2026-07-28 00:00:00+08:00'
       and d.active
  ) <> 1 then
    raise exception 'approved Nestly privacy notice was not published exactly'
      using errcode = '23514';
  end if;
end
$v92_customer_privacy_marketing_manifest$;

-- The earlier boolean was explicitly limited to platform news. It cannot be
-- silently expanded to partner marketing, so prior true values are reset and
-- only an explicit v92 choice can create evidence for the broader scope.
update public.customer_registration_preferences
   set platform_marketing_opted_in = false,
       updated_at = now()
 where platform_marketing_opted_in;

alter table public.customer_registration_preferences
  add column marketing_scope_version text,
  add column marketing_privacy_sha256 text
    check (marketing_privacy_sha256 is null or marketing_privacy_sha256 ~ '^[0-9a-f]{64}$');

comment on table public.customer_registration_preferences is
  'Current optional Nestly and selected-partner marketing choice. A true value is effective only with matching immutable v92 consent evidence; it is never merchant marketing consent.';

create table public.customer_platform_marketing_consent_events (
  id uuid primary key default gen_random_uuid(),
  identity_id uuid not null references public.customer_identities(id) on delete restrict,
  auth_user_id uuid not null references auth.users(id) on delete restrict,
  opted_in boolean not null,
  scope_version text not null check (scope_version = '2026-07-28-selected-partners-v1'),
  privacy_version text not null,
  privacy_sha256 text not null check (privacy_sha256 ~ '^[0-9a-f]{64}$'),
  source text not null check (source in ('signup', 'customer_profile')),
  idempotency_key text,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  occurred_at timestamptz not null default now(),
  constraint customer_platform_marketing_consent_identity_auth_fk
    foreign key (identity_id, auth_user_id)
    references public.customer_identities(id, auth_user_id) on delete restrict
);
comment on table public.customer_platform_marketing_consent_events is
  'Private append-only evidence for optional Nestly and selected-partner marketing grants and withdrawals. Merchant marketing consent remains separate.';

alter table public.customer_platform_marketing_consent_events enable row level security;
revoke all privileges on table public.customer_platform_marketing_consent_events
  from public, anon, authenticated;
create unique index customer_platform_marketing_consent_idempotency_uk
  on public.customer_platform_marketing_consent_events (identity_id, idempotency_key)
  where idempotency_key is not null;

create or replace function app.v92_platform_marketing_consent_immutable()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'platform marketing consent evidence is append-only' using errcode = '23000';
end;
$$;

create trigger customer_platform_marketing_consent_immutable
before update or delete on public.customer_platform_marketing_consent_events
for each row execute function app.v92_platform_marketing_consent_immutable();

create or replace function app.v92_prepare_platform_marketing_preference()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if new.platform_marketing_opted_in then
    new.marketing_scope_version := '2026-07-28-selected-partners-v1';
    new.marketing_privacy_sha256 := '994400cadc703134d9c8bd3868fe054f94e37153c47c2d2e688064bdc75138c9';
  else
    new.marketing_scope_version := null;
    new.marketing_privacy_sha256 := null;
  end if;
  return new;
end;
$$;

create trigger customer_registration_preferences_v92_prepare
before insert or update of platform_marketing_opted_in
on public.customer_registration_preferences
for each row execute function app.v92_prepare_platform_marketing_preference();

create or replace function app.v92_capture_platform_marketing_consent()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_source text := coalesce(nullif(current_setting('app.v92_marketing_source', true), ''), 'signup');
  v_idempotency_key text := nullif(current_setting('app.v92_marketing_idempotency_key', true), '');
  v_privacy app.customer_legal_documents%rowtype;
begin
  if tg_op = 'UPDATE'
     and new.platform_marketing_opted_in is not distinct from old.platform_marketing_opted_in
     and v_idempotency_key is null then
    return new;
  end if;
  if v_source not in ('signup', 'customer_profile') then
    raise exception 'invalid platform marketing consent source' using errcode = '22023';
  end if;
  select * into v_privacy
    from app.customer_legal_documents d
   where d.document_key = 'privacy' and d.active
   for share;
  if not found
     or v_privacy.document_version <> '2026-07-28'
     or v_privacy.document_sha256 <> '994400cadc703134d9c8bd3868fe054f94e37153c47c2d2e688064bdc75138c9' then
    raise exception 'platform marketing consent document is unavailable' using errcode = '0A000';
  end if;
  insert into public.customer_platform_marketing_consent_events (
    identity_id, auth_user_id, opted_in, scope_version,
    privacy_version, privacy_sha256, source, idempotency_key, request_hash
  ) values (
    new.identity_id, new.auth_user_id, new.platform_marketing_opted_in,
    '2026-07-28-selected-partners-v1', v_privacy.document_version,
    v_privacy.document_sha256, v_source, v_idempotency_key,
    app.v31_sha256_hex(
      'v92.platform-marketing:' || new.auth_user_id::text || ':'
      || new.platform_marketing_opted_in::text || ':'
      || v_privacy.document_sha256 || ':' || coalesce(v_idempotency_key, 'signup')
    )
  );
  return new;
end;
$$;

create trigger customer_registration_preferences_v92_evidence
after insert or update of platform_marketing_opted_in
on public.customer_registration_preferences
for each row execute function app.v92_capture_platform_marketing_consent();

create or replace function public.customer_get_platform_marketing_preference()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  return coalesce((
    select jsonb_build_object(
      'opted_in',
        p.platform_marketing_opted_in
        and p.marketing_scope_version = '2026-07-28-selected-partners-v1'
        and p.marketing_privacy_sha256 = '994400cadc703134d9c8bd3868fe054f94e37153c47c2d2e688064bdc75138c9'
        and exists (
          select 1
            from public.customer_platform_marketing_consent_events e
           where e.identity_id = p.identity_id
             and e.auth_user_id = v_actor
             and e.opted_in
             and e.scope_version = p.marketing_scope_version
             and e.privacy_sha256 = p.marketing_privacy_sha256
        ),
      'scope_version', '2026-07-28-selected-partners-v1',
      'updated_at', p.updated_at
    )
      from public.customer_registration_preferences p
     where p.auth_user_id = v_actor
  ), jsonb_build_object(
    'opted_in', false,
    'scope_version', '2026-07-28-selected-partners-v1',
    'updated_at', null
  ));
end;
$$;

create or replace function public.customer_set_platform_marketing_preference(
  p_opted_in boolean,
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
  v_existing public.customer_platform_marketing_consent_events%rowtype;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if p_opted_in is null
     or p_idempotency_key is null
     or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'invalid platform marketing preference request' using errcode = '22023';
  end if;
  p_idempotency_key := btrim(p_idempotency_key);
  v_identity := app.v31_current_identity();
  perform pg_advisory_xact_lock(hashtextextended(
    'v92:platform-marketing:' || v_identity::text || ':' || p_idempotency_key, 0
  ));
  select * into v_existing
    from public.customer_platform_marketing_consent_events e
   where e.identity_id = v_identity and e.idempotency_key = p_idempotency_key
   for update;
  if found then
    if v_existing.opted_in is distinct from p_opted_in then
      raise exception 'idempotency key was already used for a different marketing preference'
        using errcode = '23505';
    end if;
    return jsonb_build_object('outcome', 'updated', 'opted_in', v_existing.opted_in);
  end if;
  perform set_config('app.v92_marketing_source', 'customer_profile', true);
  perform set_config('app.v92_marketing_idempotency_key', p_idempotency_key, true);
  update public.customer_registration_preferences p
     set platform_marketing_opted_in = p_opted_in,
         updated_at = now()
   where p.identity_id = v_identity and p.auth_user_id = v_actor;
  if not found then
    raise exception 'customer marketing preference is unavailable' using errcode = '42501';
  end if;
  perform set_config('app.v92_marketing_source', '', true);
  perform set_config('app.v92_marketing_idempotency_key', '', true);
  return jsonb_build_object('outcome', 'updated', 'opted_in', p_opted_in);
end;
$$;

revoke all on function public.customer_get_platform_marketing_preference()
  from public, anon, authenticated;
revoke all on function public.customer_set_platform_marketing_preference(boolean, text)
  from public, anon, authenticated;
revoke all on function app.v92_prepare_platform_marketing_preference()
  from public, anon, authenticated;
revoke all on function app.v92_capture_platform_marketing_consent()
  from public, anon, authenticated;
revoke all on function app.v92_platform_marketing_consent_immutable()
  from public, anon, authenticated;
grant execute on function public.customer_get_platform_marketing_preference()
  to authenticated;
grant execute on function public.customer_set_platform_marketing_preference(boolean, text)
  to authenticated;

commit;
