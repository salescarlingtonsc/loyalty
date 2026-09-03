-- nestly_v750 — a kept bottle no longer blocks a customer from deleting their account.
--
-- OWNER, 2026-09-04, on the v749 dialog refusing with "Bistro 999 still holds stored value or
-- items for you": "there's no gift or outstanding rewards - fix this issue and allow for deletion".
--
-- v749 copied erase_client_v290's three refusals wholesale. Two of them do not belong in a
-- SELF-SERVICE deletion:
--   * bar_bottles — a bottle in storage is the BUSINESS's record of property it keeps. Anonymising
--     the client row does not lose that record (the bottle still points at the same client id, and
--     the audit row records the erasure), it only stops naming the person — which is exactly what
--     the person asked for. The customer surface does not even show the bottle in the wallet the
--     owner screenshotted, so the refusal read as a bug, not a safeguard.
--   * (credit_ledger was already dropped in v749: loyalty value is forfeited by consent.)
-- What stays: stored value (sv_lots) — real money the customer paid in. That is refused until the
-- business settles it, because Peekaa cannot forfeit cash by a tap.
--
-- The dialog copy in app/app.js changes in the same version: the refusal names stored value only,
-- and "What is forfeited" says that items a business keeps for you can no longer be matched to you.
-- Behaviour is otherwise byte-identical to v749.

begin;

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
  'nestly_v749/v750. Customer self-service account deletion (App Store 5.1.1(v)). Anonymises every '
  'joined client row and unlinks it, tombstones the platform profile, revokes contacts and push, '
  'disables the identity, deletes all auth sessions/credentials and soft-deletes + bans the auth '
  'user. Refuses business logins (42501) and outstanding stored value (refused; v750 dropped the '
  'kept-bottle refusal). Ledgers are retained anonymised. Idempotent on (customer, key).';

commit;
