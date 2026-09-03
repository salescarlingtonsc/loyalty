-- nestly_v749 — a customer can delete their own Peekaa account from inside the app.
--
-- OWNER, 2026-09-04 (App Store Review, Guideline 5.1.1(v)): "i need to enable account deletion -
-- for iOS purpose. it should delete the customer account entirely as per iOS."
--
-- This REVERSES the v188 ruling ("do not allow firms or users to delete account") for CUSTOMER
-- accounts only. Apple requires that an app which lets a person create an account also lets them
-- delete it, in-app, without a support conversation. The iOS shell registers customers
-- (phone + password / OTP); business workspaces are never created in the iOS app
-- (renderNativeBusinessCompanion), so a business login keeps the email closure route and is
-- REFUSED here — deleting a workspace owner would orphan a tenant and its billing.
--
-- WHAT "DELETE" MEANS HERE, precisely, because the sentence on the button must be true:
--   1. Every business the customer is currently joined to: the clients row is anonymised exactly
--      the way the owner-side erase_client_v290 does it (name, phone, email, birth date, gender,
--      notes, tags, referral code → gone) and the customer_links row is moved to 'unlinked' through
--      app.unlink_client_links_for_erasure_v473, so no business surface resolves this person again.
--      Each erasure is recorded in client_erasures_v290 so the existing "Erased customer" banner and
--      the v473 repair invariants keep holding.
--   2. The platform-level customer record: customer_profiles is overwritten (name, gender, and —
--      via a new GUC the c42 guard admits — birth date), every verified contact is revoked, every
--      push subscription is revoked, the identity is 'disabled' and its QR token hash cleared.
--   3. The login itself (auth.users): every session, refresh token, OAuth identity, MFA factor and
--      WebAuthn credential is deleted; the row's email, phone, password and metadata are replaced
--      with a tombstone; banned_until = infinity and deleted_at = now(). The phone number becomes
--      free again, so the same person can register a NEW account later — it starts clean.
--   4. A completed account_deletion_requests row (claimed and resolved by the customer themself,
--      resolution 'deleted_where_permitted') is the audit evidence, and get_account_deletion_request_v131
--      keeps reading it unchanged.
--
-- WHAT IS DELIBERATELY KEPT, and why:
--   * Sales, points_ledger, credit_ledger, stamps, appointments — the accounting record of money
--     that changed hands. They stop naming a person (the client row is anonymised); they are never
--     deleted. The dialog says so, and so does the Privacy Notice.
--   * auth.users is NOT hard-deleted: ~70 tables reference it with ON DELETE RESTRICT (every audit
--     and evidence table names the actor). A tombstoned, banned, soft-deleted row with no
--     credentials is the deletion GoTrue itself performs for a soft delete, and it is the only
--     shape that keeps the evidence tables consistent.
--   * The v188 revoke on request_account_deletion_v131 stays. The email route still exists for
--     businesses and for anyone who prefers a human.
--
-- REFUSALS (fail closed, change nothing):
--   * a business login (active staff row, or a super admin) → 42501 with a sentence naming the route;
--   * outstanding stored value (sv_lots) or kept property (bar bottles) at any joined business →
--     status 'refused' naming the businesses. Those are real money and real goods; Peekaa cannot
--     forfeit them by a tap. Loyalty points, stamps and in-store credit ARE forfeited — the dialog
--     states it in the customer's own words before the button enables.
--
-- Idempotent on (customer, key): a replay returns the recorded outcome. A second key after a
-- completed deletion cannot happen — the login no longer authenticates.

begin;

-- ---------------------------------------------------------------------------------------------
-- 1. The c42 profile guard admits an erasure. Behaviour is byte-identical for every other caller.
-- ---------------------------------------------------------------------------------------------
create or replace function app.c42_profile_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_identity text := nullif(current_setting('app.c42_profile_identity', true), '');
  -- nestly_v749: set only by public.customer_delete_account_v749, transaction-local, to the
  -- identity being erased. It admits the one write the C42 rule otherwise forbids: replacing the
  -- birth date. The identity/auth mapping and created_at stay immutable even then.
  v_erasure text := nullif(current_setting('app.c42_profile_erasure_v749', true), '');
begin
  if tg_op = 'DELETE' then
    raise exception 'customer profiles are retained for controlled recovery' using errcode = '23000';
  end if;
  if v_identity is distinct from new.identity_id::text then
    raise exception 'customer profiles may only be written through a self-derived C42 RPC' using errcode = '42501';
  end if;
  if new.birth_date > (timezone('Asia/Singapore', now()))::date then
    raise exception 'birth date cannot be in the future' using errcode = '22023';
  end if;
  if tg_op = 'UPDATE' then
    if (new.identity_id, new.auth_user_id, new.created_at)
        is distinct from (old.identity_id, old.auth_user_id, old.created_at) then
      raise exception 'customer identity mapping requires controlled recovery' using errcode = '23000';
    end if;
    if new.birth_date is distinct from old.birth_date
       and v_erasure is distinct from new.identity_id::text then
      raise exception 'customer identity mapping and birth date require controlled recovery' using errcode = '23000';
    end if;
    new.updated_at := now();
  end if;
  return new;
end;
$function$;

-- ---------------------------------------------------------------------------------------------
-- 2. The deletion itself.
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
  v_bottles integer;
  v_fields jsonb;
  v_erasure uuid;
  v_unlinked uuid[];
  v_reference text;
  v_receipt jsonb;
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

  -- Refusals first, before any write: real money and real goods cannot be forfeited by a tap.
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
      select count(*)::integer into v_bottles
        from public.bar_bottles bottle
       where bottle.business_id = v_link.business_id and bottle.client_id = v_link.client_id
         and bottle.status in ('stored','called','at_table','expired');
      if v_sv > 0 or v_bottles > 0 then
        v_blocked := v_blocked || jsonb_build_object('business_id', v_link.business_id,
          'business_name', v_link.business_name, 'stored_value_lots', v_sv, 'bottles_in_storage', v_bottles);
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

comment on function public.customer_delete_account_v749(text, text) is
  'nestly_v749. Customer self-service account deletion (App Store 5.1.1(v)). Anonymises every '
  'joined client row and unlinks it, tombstones the platform profile, revokes contacts and push, '
  'disables the identity, deletes all auth sessions/credentials and soft-deletes + bans the auth '
  'user. Refuses business logins (42501) and outstanding stored value or kept property (refused). '
  'Ledgers are retained anonymised. Idempotent on (customer, key).';

commit;
