-- nestly_v751 — deleting an account does not reset the welcome offer or the referral bonus.
--
-- OWNER, 2026-09-04: "how to prevent abuse, where people delete and reinstall again to receive
-- rewards".
--
-- THE HOLE. v749 releases the phone number on deletion (the auth row is tombstoned, the client
-- rows lose their phone). A person can therefore register the same number again, scan the same
-- join QR, and be a brand-new customer: app.issue_welcome_offer_v215 sees a client with no sales
-- and issues the welcome gift again; app.referral_referred_is_new_v683 sees no sales and no old
-- link and lets a friend "refer" them again. Both are join-time rewards, and both are what a
-- delete-and-reinstall loop farms.
--
-- THE FIX. Deletion leaves a MARK, not a name: for every business the customer was joined to,
-- the SHA-256 of the normalised phone (never the phone itself) and the moment of deletion. The
-- two join-time reward gates consult the mark: a number deleted at THIS business within the last
-- 365 days gets no welcome offer and does not count as a new customer for a referral. Everything
-- else about the new account is normal — they can join, earn stamps and points from real spend,
-- book, and be messaged. Only the "new customer" gifts are withheld.
--
-- Why a hash, and why per business: the mark must survive the erasure it is created in, so it
-- cannot carry PII (the whole point of v749 is that no row names the person afterwards). A
-- one-way hash of the 8-digit number is enough to recognise a re-registration and useless to
-- anyone who reads the table. Per business, because both rewards are per business: deleting after
-- joining cafe A must not cost you the welcome gift at cafe B you never visited.
--
-- Window: 365 days (assumption, not an owner ruling — see the constant in
-- app.phone_recently_deleted_v751; change it there).
--
-- Not backfilled: the four deletions before this migration erased the numbers they would need.
-- They are all the owner's own test accounts.

begin;

create table if not exists public.customer_deletion_marks_v751 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid references public.businesses(id) on delete cascade,
  phone_hash text not null check (phone_hash ~ '^[0-9a-f]{64}$'),
  request_id uuid references public.account_deletion_requests(id) on delete set null,
  deleted_at timestamptz not null default now()
);
create index if not exists customer_deletion_marks_v751_lookup
  on public.customer_deletion_marks_v751 (business_id, phone_hash, deleted_at desc);
alter table public.customer_deletion_marks_v751 enable row level security;
revoke all on table public.customer_deletion_marks_v751 from public, anon, authenticated;
comment on table public.customer_deletion_marks_v751 is
  'nestly_v751. One row per (business, hashed phone) left behind by a customer self-service '
  'account deletion. Carries no PII: the hash is SHA-256 of app.norm_phone(). Read only by the '
  'join-time reward gates (welcome offer, referral new-customer test). business_id NULL = the '
  'platform-level mark taken from the auth phone.';

-- ---------------------------------------------------------------------------------------------
-- 1. The question the reward gates ask.
-- ---------------------------------------------------------------------------------------------
create or replace function app.phone_recently_deleted_v751(p_business uuid, p_client uuid)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
  select exists (
    select 1
      from public.clients c
      join public.customer_deletion_marks_v751 m
        on m.business_id = c.business_id
       and m.phone_hash = app.v89_sha256(c.phone_norm)
     where c.id = p_client
       and c.business_id = p_business
       and c.phone_norm is not null
       and m.deleted_at > now() - interval '365 days'
  );
$function$;
revoke all on function app.phone_recently_deleted_v751(uuid, uuid) from public, anon, authenticated;
comment on function app.phone_recently_deleted_v751(uuid, uuid) is
  'nestly_v751. TRUE when this client''s phone was deleted from THIS business by a customer '
  'self-service deletion in the last 365 days. Internal: consulted by the join-time reward gates.';

-- ---------------------------------------------------------------------------------------------
-- 2. Gate one: the welcome offer. Byte-identical to the live v215 issuer plus one early return.
-- ---------------------------------------------------------------------------------------------
create or replace function app.issue_welcome_offer_v215(p_business uuid, p_client uuid)
returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_offer public.business_welcome_offers_v215%rowtype;
  v_ok boolean;
  v_grant uuid;
begin
  if p_business is null or p_client is null then return null; end if;

  select * into v_offer
  from public.business_welcome_offers_v215
  where business_id = p_business;
  if not found or not v_offer.active then return null; end if;

  if v_offer.reward_catalog_kind = 'custom' then
    v_ok := true;
  elsif v_offer.reward_catalog_kind = 'service' then
    select true into v_ok from public.services
    where id = v_offer.reward_catalog_id and business_id = p_business and active;
  else
    select true into v_ok from public.products
    where id = v_offer.reward_catalog_id and business_id = p_business and active;
  end if;
  if not coalesce(v_ok, false) then return null; end if;

  if exists(
    select 1 from public.sales
    where business_id = p_business and client_id = p_client and reversal_of is null
  ) then
    return null;
  end if;

  -- nestly_v751: a number that deleted its account here in the last year is a returning
  -- customer, not a new one. No welcome gift a second time.
  if app.phone_recently_deleted_v751(p_business, p_client) then
    return null;
  end if;

  insert into public.welcome_offer_grants_v215(
    business_id, client_id, min_spend_cents,
    reward_catalog_kind, reward_catalog_id, reward_label, expires_at
  ) values (
    p_business, p_client, v_offer.min_spend_cents,
    v_offer.reward_catalog_kind, v_offer.reward_catalog_id, v_offer.reward_label,
    case when v_offer.expiry_days is null then null
         else now() + make_interval(days => v_offer.expiry_days) end
  )
  on conflict (business_id, client_id) do nothing
  returning id into v_grant;

  return v_grant;
end
$function$;
revoke all on function app.issue_welcome_offer_v215(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 3. Gate two: the referral "new customer" test. Byte-identical to v683 plus one predicate.
-- ---------------------------------------------------------------------------------------------
create or replace function app.referral_referred_is_new_v683(p_business uuid, p_client uuid)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
  select p_business is not null
     and p_client is not null
     and not exists (
       select 1
         from public.sales s
        where s.business_id = p_business
          and s.client_id = p_client
          and s.reversal_of is null
          and coalesce(s.amount_cents, 0) > 0
          and not exists (
            select 1 from public.sales r
             where r.business_id = s.business_id and r.reversal_of = s.id
          )
     )
     and not exists (
       select 1
         from public.customer_links l
        where l.business_id = p_business
          and l.client_id = p_client
          and l.state = 'verified'
          and coalesce(l.verified_at, l.created_at) < now() - interval '7 days'
     )
     -- nestly_v751: deleting and re-registering the same number does not make a new customer.
     and not app.phone_recently_deleted_v751(p_business, p_client);
$function$;
revoke all on function app.referral_referred_is_new_v683(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 4. The deletion writes the marks. Byte-identical to v750 plus the two inserts.
-- ---------------------------------------------------------------------------------------------
create or replace function public.customer_delete_account_v749(p_confirmation text, p_idempotency_key text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_key text := btrim(coalesce(p_idempotency_key,''));
  v_identity public.customer_identities%rowtype;
  v_request public.account_deletion_requests%rowtype;
  v_link record;
  v_client public.clients%rowtype;
  v_blocked jsonb := '[]'::jsonb;
  v_erased jsonb := '[]'::jsonb;
  v_sv integer;
  v_fields jsonb;
  v_erasure uuid;
  v_unlinked uuid[];
  v_reference text;
  v_receipt jsonb;
  v_auth_phone text;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if coalesce(p_confirmation,'') <> 'DELETE' then
    raise exception 'type DELETE to confirm' using errcode = '22023';
  end if;
  if length(v_key) not between 8 and 200 then
    raise exception 'invalid idempotency key' using errcode = '22023';
  end if;

  -- A business login is not a customer account. It keeps the email closure route.
  if exists (select 1 from public.staff s where s.user_id = v_actor and s.active)
     or exists (select 1 from public.super_admins sa where sa.user_id = v_actor) then
    raise exception 'business logins are closed by Peekaa: email admin.peekaa@gmail.com or speak to your consultant'
      using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_actor::text, 749));

  v_reference := 'self-service:v749:' || v_key;

  -- Replay: the recorded outcome, nothing re-run.
  select * into v_request from public.account_deletion_requests r
   where r.subject_ref = v_actor and r.resolution_reference = v_reference
   order by r.requested_at desc limit 1;
  if v_request.id is not null then
    return jsonb_build_object('status','duplicate_ignored','request_id',v_request.id,
      'completed_at',v_request.completed_at);
  end if;

  select * into v_identity from public.customer_identities ci where ci.auth_user_id = v_actor for update;

  -- nestly_v750: the ONE refusal is real money (stored value). A kept bottle stays with the
  -- business under the anonymised client row; it is not a reason to keep a person's name.
  if v_identity.id is not null then
    for v_link in
      select l.id, l.business_id, l.client_id, b.name as business_name
        from public.customer_links l
        join public.businesses b on b.id = l.business_id
       where l.identity_id = v_identity.id and l.state = 'verified' and l.client_id is not null
       order by l.created_at
    loop
      select count(*)::integer into v_sv
        from public.sv_lots lot join public.sv_accounts account on account.id = lot.account_id
       where account.business_id = v_link.business_id and account.client_id = v_link.client_id;
      if v_sv > 0 then
        v_blocked := v_blocked || jsonb_build_object('business_id', v_link.business_id,
          'business_name', v_link.business_name, 'stored_value_lots', v_sv);
      end if;
    end loop;
    if jsonb_array_length(v_blocked) > 0 then
      return jsonb_build_object('status','refused','reason','holdings_outstanding','businesses',v_blocked);
    end if;
  end if;

  -- The audit row, opened and closed by the customer themself.
  insert into public.account_deletion_requests(
    subject_auth_user_id, subject_ref, idempotency_key, requested_at, response_due_at, updated_at,
    status, claimed_at, claimed_by, completed_at, operator_note, resolution_code, resolution_reference
  ) values (
    v_actor, v_actor, v_key, now(), now() + interval '30 days', now(),
    'completed', now(), v_actor, now(), 'self-service in-app deletion (nestly_v749)',
    'deleted_where_permitted', v_reference
  ) returning * into v_request;

  -- nestly_v751: the platform-level mark, taken from the auth phone BEFORE it is nulled.
  select u.phone into v_auth_phone from auth.users u where u.id = v_actor;
  if app.norm_phone(v_auth_phone) is not null then
    insert into public.customer_deletion_marks_v751(business_id, phone_hash, request_id)
    values (null, app.v89_sha256(app.norm_phone(v_auth_phone)), v_request.id);
  end if;

  if v_identity.id is not null then
    -- 2a. Every joined business: anonymise the client row, record the erasure, unlink.
    for v_link in
      select l.id, l.business_id, l.client_id
        from public.customer_links l
       where l.identity_id = v_identity.id and l.state = 'verified' and l.client_id is not null
       order by l.created_at
    loop
      select * into v_client from public.clients c
       where c.id = v_link.client_id and c.business_id = v_link.business_id for update;
      if v_client.id is null then continue; end if;
      -- nestly_v751: the per-business mark, from the client's phone BEFORE it is nulled.
      if v_client.phone_norm is not null then
        insert into public.customer_deletion_marks_v751(business_id, phone_hash, request_id)
        values (v_link.business_id, app.v89_sha256(v_client.phone_norm), v_request.id);
      end if;
      v_fields := jsonb_build_object(
        'full_name', v_client.full_name is not null, 'phone', v_client.phone is not null,
        'email', v_client.email is not null, 'birth_date', v_client.birth_date is not null,
        'gender', v_client.gender is not null, 'notes', v_client.notes is not null,
        'tags', coalesce(cardinality(v_client.tags),0) > 0, 'referral_code', v_client.referral_code is not null);
      update public.clients c
         set full_name = 'Erased customer', phone = null, email = null, birth_date = null,
             gender = null, notes = null, tags = array[]::text[], referral_code = null,
             marketing_consent = false
       where c.id = v_client.id and c.business_id = v_link.business_id;
      v_unlinked := app.unlink_client_links_for_erasure_v473(v_link.business_id, v_client.id, v_actor);
      if not exists (select 1 from public.client_erasures_v290 e
                      where e.business_id = v_link.business_id and e.client_id = v_client.id) then
        insert into public.client_erasures_v290(business_id, client_id, actor, reason, idempotency_key, erased_fields)
        values (v_link.business_id, v_client.id, v_actor, 'customer deleted their own Peekaa account',
                left('v749:' || v_key || ':' || v_client.id::text, 200), v_fields)
        returning id into v_erasure;
      end if;
      insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
      values (v_link.business_id, v_actor, 'CLIENT_ERASED_V290', 'clients', v_client.id,
        jsonb_build_object('erasure_id', v_erasure, 'reason', 'customer self-service account deletion',
          'request_id', v_request.id, 'erased_fields', v_fields, 'unlinked_links', to_jsonb(v_unlinked)));
      v_erased := v_erased || jsonb_build_object('business_id', v_link.business_id, 'client_id', v_client.id);
    end loop;

    -- 2b. The platform-level record.
    perform set_config('app.c42_profile_identity', v_identity.id::text, true);
    perform set_config('app.c42_profile_erasure_v749', v_identity.id::text, true);
    update public.customer_profiles p
       set full_name = 'Deleted account', gender = null, birth_date = date '1900-01-01'
     where p.identity_id = v_identity.id;
    perform set_config('app.c42_profile_identity', '', true);
    perform set_config('app.c42_profile_erasure_v749', '', true);

    update public.customer_verified_contacts c
       set status = 'revoked', revoked_at = now()
     where c.identity_id = v_identity.id and c.status = 'verified';
    update public.customer_push_subscriptions_v95 s
       set status = 'revoked', revoked_at = now(), updated_at = now()
     where s.identity_id = v_identity.id and s.status = 'active';
    update public.customer_notification_preferences n
       set opted_in = false, updated_at = now()
     where n.identity_id = v_identity.id and n.opted_in;
    update public.customer_identities ci
       set status = 'disabled', qr_token_hash = null, updated_at = now()
     where ci.id = v_identity.id;
  end if;

  -- 2c. The login. Sessions and credentials go; the row is tombstoned, banned and soft-deleted.
  delete from auth.sessions where user_id = v_actor;
  delete from auth.refresh_tokens where user_id = v_actor::text;
  delete from auth.identities where user_id = v_actor;
  delete from auth.mfa_factors where user_id = v_actor;
  delete from auth.webauthn_credentials where user_id = v_actor;
  delete from auth.one_time_tokens where user_id = v_actor;
  update auth.users u
     set email = 'deleted-' || v_actor::text || '@deleted.peekaa.invalid',
         phone = null, phone_confirmed_at = null, phone_change = '', phone_change_token = '',
         email_change = '', email_change_token_new = '', email_change_token_current = '',
         encrypted_password = null, confirmation_token = '', recovery_token = '',
         reauthentication_token = '',
         raw_user_meta_data = jsonb_build_object('deleted_v749', true),
         banned_until = 'infinity'::timestamptz, deleted_at = now(), updated_at = now()
   where u.id = v_actor;

  v_receipt := jsonb_build_object('status','deleted','request_id',v_request.id,
    'completed_at',v_request.completed_at,'businesses_erased',v_erased,
    'identity_disabled', v_identity.id is not null);
  return v_receipt;
end;
$function$;

revoke all on function public.customer_delete_account_v749(text, text) from public, anon;
grant execute on function public.customer_delete_account_v749(text, text) to authenticated, service_role;

commit;
