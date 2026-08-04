begin;

alter table public.customer_profiles
  add column if not exists gender text
    check (gender in ('female','male'));

comment on column public.customer_profiles.gender is
  'Owner-requested customer signup demographic. The public registration path accepts only female or male.';

drop function if exists public.customer_register_verified_phone(
  text, date, text, boolean, boolean, boolean, text
);

create or replace function public.customer_register_verified_phone(
  p_full_name text,
  p_birth_date date,
  p_gender text,
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
  v_gender text := lower(nullif(btrim(p_gender), ''));
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
     or v_name is null or p_birth_date is null or p_birth_date > (timezone('Asia/Singapore', now()))::date
     or v_gender not in ('female','male')
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
    'v163.registration:' || v_actor::text || ':'
    || app.v31_sha256_hex(v_name) || ':' || app.v31_sha256_hex(p_birth_date::text) || ':'
    || v_gender || ':' || v_language || ':' || v_terms.document_version || ':' || v_terms.document_sha256 || ':'
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
    identity_id, auth_user_id, full_name, birth_date, gender, preferred_language
  ) values (v_identity.id, v_actor, v_name, p_birth_date, v_gender, v_language)
  on conflict (identity_id) do update set
    full_name = excluded.full_name, gender = excluded.gender, preferred_language = excluded.preferred_language;
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
      'full_name', p.full_name, 'birth_date', p.birth_date, 'gender', p.gender, 'preferred_language', p.preferred_language
    ) from public.customer_profiles p where p.auth_user_id = v_actor
  ));
end;
$$;

revoke all on function public.customer_register_verified_phone(
  text, date, text, text, boolean, boolean, boolean, text
) from public, anon, authenticated;
grant execute on function public.customer_register_verified_phone(
  text, date, text, text, boolean, boolean, boolean, text
) to authenticated;

revoke all on function public.customer_get_profile() from public, anon, authenticated;
grant execute on function public.customer_get_profile() to authenticated;

comment on function public.customer_register_verified_phone(
  text, date, text, text, boolean, boolean, boolean, text
) is
  'V163 phone customer registration: persists required DOB and owner-requested binary gender with one combined legal/privacy/marketing signup consent.';

commit;
