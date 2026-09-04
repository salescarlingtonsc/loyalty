-- nestly_v764 — a deleted-and-re-registered number gets no second birthday gift, and a deleted
-- login no longer breaks the auth server.
--
-- OWNER, 2026-09-05: "when customer redeemed new welcome rewards and birthday rewards & delete
-- account and sign up again > they must not abuse the welcome / birthday rewards (if their
-- birthday rewards happen to be on the window of sign up)".
--
-- THE HOLE (birthday). v751 closed the welcome offer and the referral bonus with a hashed-phone
-- mark left behind by every self-service deletion. The birthday gift was made auto-granting on
-- the same day (v753) and never consulted that mark: its idempotency key is (business, client,
-- birthday_year), and a re-registration is a NEW client row, so a number that deleted its
-- account and rejoined inside its birthday window was granted the gift a second time. Three
-- readers had to agree, or the customer would be shown an invitation the server then refuses:
--   1. app.v753_birthday_evaluate_and_grant  — the auto-grant on link / DOB / opt-in: returns.
--   2. public.customer_activate_birthday_benefit — the explicit Activate tap: 42501 (the same
--      'birthday benefits are unavailable' it already raises when no programme is live).
--   3. app.c45_customer_birthday_benefit_for_context — the preview: no 'ready_to_activate'.
-- Same window and same per-business scope as v751 (app.phone_recently_deleted_v751, 365 days):
-- deleting after joining cafe A never costs you the birthday gift at cafe B.
--
-- THE HOLE (auth). v749 tombstones a deleted login with banned_until = 'infinity'. The auth
-- server (GoTrue) scans that column into a Go time and cannot read 'infinity': the sign-out
-- the app performs straight after a deletion answered 500 (auth logs, 2026-09-04 03:48-03:56Z,
-- "/logout ... unsupported Scan ... banned_until"), and every dashboard/admin operation on
-- such a user — including hard-deleting it — fails the same way. A ban until a concrete
-- far-future instant is the same ban and is readable. The four existing tombstones are
-- repaired here; nothing else about them changes.
--
-- Not backfilled (birthday): the deletions before v751 erased the numbers a mark would need.

begin;

-- Numbered v764: this change was first applied to production under the name v763 in the same
-- hour another session shipped its own nestly_v763 (self-serve activation by tier). Same
-- semantics, new name; the v763-named helper is replaced below and dropped at the end.

-- ---------------------------------------------------------------------------------------------
-- 0. The one far-future instant every tombstone uses.
-- ---------------------------------------------------------------------------------------------
create or replace function app.v764_tombstone_ban_until()
returns timestamptz
language sql
immutable
set search_path to 'pg_catalog','pg_temp'
as $function$
  select timestamptz '2999-12-31 00:00:00+00';
$function$;
revoke all on function app.v764_tombstone_ban_until() from public, anon, authenticated;
comment on function app.v764_tombstone_ban_until() is
  'nestly_v764. banned_until for a v749-tombstoned login. Finite so GoTrue can read the row; '
  'far enough to be permanent.';

-- ---------------------------------------------------------------------------------------------
-- 1. The auto-grant. Byte-identical to v753 plus one early return.
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.v753_birthday_evaluate_and_grant(
  p_business_id uuid,
  p_client_id uuid,
  p_identity_id uuid,
  p_birth_date date,
  p_as_of timestamp with time zone
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_opted_in boolean;
  v_program public.birthday_program_versions%rowtype;
  v_window record;
begin
  if p_birth_date is null then
    return;
  end if;

  -- nestly_v764: a number that deleted its account at THIS business in the last year is a
  -- returning customer, not a new one. The auto-grant is the join-time reward this loop farms.
  if app.phone_recently_deleted_v751(p_business_id, p_client_id) then
    return;
  end if;

  -- Same consent gate the live read (app.c45_customer_birthday_benefit_for_context) and the
  -- explicit activate RPC (public.customer_activate_birthday_benefit) both enforce. This
  -- function only removes the extra "activate" tap for a customer who HAS already opted in --
  -- it never grants anything to a customer who has not.
  select coalesce(p.opted_in, false) into v_opted_in
    from (select 1) one
    left join public.customer_birthday_participation p on p.identity_id = p_identity_id;
  if not coalesce(v_opted_in, false) then
    return;
  end if;

  -- Same programme resolution nestly_v560 patched into the read path: the accruing programme's
  -- loyalty_program_versions.active draft-snapshot flag is deliberately NOT consulted here --
  -- the birthday benefit is its own programme.
  select bpv.* into v_program
    from public.businesses b
    join public.birthday_program_versions bpv
      on bpv.config_version_id = b.active_config_version_id
     and bpv.business_id = b.id and bpv.active
   where b.id = p_business_id
     and 'loyalty' = any(coalesce(b.enabled_modules, '{}'::text[]))
   order by bpv.sort, bpv.program_id
   limit 1;
  if not found then
    return;
  end if;

  select * into v_window
    from app.c45_birthday_window(p_birth_date, v_program.window_days_before,
      v_program.window_days_after, p_as_of, v_program.window_mode);
  if not found then
    -- Outside the current SG window: nothing to grant now. The live read path stays untouched
    -- and keeps showing any prior immutable promise as history.
    return;
  end if;

  -- The (business_id, client_id, birthday_year) unique constraint is the one-per-window/year
  -- rule; ON CONFLICT DO NOTHING makes this call idempotent no matter how many times either
  -- trigger below re-fires it for the same customer (a second link event, a DOB write that
  -- resolves to the same value, or a race between the two triggers). An existing entitlement,
  -- whether written by this function or by the customer's own "activate" tap, is left exactly
  -- as it is.
  insert into public.customer_birthday_entitlements(
    business_id, client_id, identity_id, config_version_id, birthday_program_version_id,
    birthday_year, status, valid_from, valid_until, benefit_snapshot
  ) values (
    p_business_id, p_client_id, p_identity_id, v_program.config_version_id, v_program.id,
    v_window.birthday_year, 'available', v_window.valid_from, v_window.valid_until,
    app.c45_benefit_snapshot(v_program)
  )
  on conflict (business_id, client_id, birthday_year) do nothing;
end
$function$;
revoke all on function app.v753_birthday_evaluate_and_grant(uuid,uuid,uuid,date,timestamptz)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 2. The explicit Activate tap. Byte-identical to v560 plus one refusal.
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.customer_activate_birthday_benefit(p_business_slug text, p_idempotency_key uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_context record; v_as_of timestamptz:=statement_timestamp(); v_program public.birthday_program_versions%rowtype;
  v_window record; v_entitlement public.customer_birthday_entitlements%rowtype;
  v_op public.customer_birthday_activation_operations%rowtype; v_request_hash text;
begin
  select * into v_context from app.c45_customer_birthday_context(p_business_slug) limit 1;
  if p_idempotency_key is null then raise exception 'birthday benefits are unavailable' using errcode='22023'; end if;
  v_request_hash:=app.c45_hash(jsonb_build_object('business_slug',lower(btrim(p_business_slug)))::text);
  select * into v_op from public.customer_birthday_activation_operations
   where identity_id=v_context.identity_id and business_id=v_context.business_id and idempotency_key=p_idempotency_key for share;
  if found then
    if v_op.request_hash is distinct from v_request_hash then raise exception 'birthday activation conflicts with an existing operation' using errcode='40001'; end if;
    select * into v_entitlement from public.customer_birthday_entitlements where id=v_op.entitlement_id;
    return app.c45_safe_birthday_entitlement(v_entitlement,v_as_of);
  end if;
  if not exists(select 1 from public.customer_birthday_participation p where p.identity_id=v_context.identity_id and p.auth_user_id=auth.uid() and p.opted_in) then
    raise exception 'birthday benefits are unavailable' using errcode='42501';
  end if;
  select bpv.* into v_program from public.businesses b
   -- nestly_v560: the loyalty_program_versions.active join is gone (see the context reader).
   join public.birthday_program_versions bpv on bpv.config_version_id=b.active_config_version_id and bpv.business_id=b.id and bpv.active
   where b.id=v_context.business_id and 'loyalty'=any(coalesce(b.enabled_modules,'{}'::text[]))
   order by bpv.sort,bpv.program_id limit 1 for update of bpv;
  if not found then raise exception 'birthday benefits are unavailable' using errcode='42501'; end if;
  -- nestly_v764: same rule as the auto-grant — a recently deleted number cannot tap its way in.
  if app.phone_recently_deleted_v751(v_context.business_id, v_context.client_id) then
    raise exception 'birthday benefits are unavailable' using errcode='42501';
  end if;
  -- nestly_v424: the fifth argument. Without it this call is the 4-argument overload, which knows
  -- only about window_days_before/after, and a month-mode programme silently enforced one day.
  select * into v_window from app.c45_birthday_window(v_context.birth_date,v_program.window_days_before,v_program.window_days_after,v_as_of,v_program.window_mode);
  if not found then raise exception 'birthday benefits are unavailable' using errcode='42501'; end if;
  select * into v_entitlement from public.customer_birthday_entitlements
   where business_id=v_context.business_id and client_id=v_context.client_id and birthday_year=v_window.birthday_year for update;
  if found then
    insert into public.customer_birthday_activation_operations(identity_id,business_id,client_id,idempotency_key,request_hash,entitlement_id)
    values(v_context.identity_id,v_context.business_id,v_context.client_id,p_idempotency_key,v_request_hash,v_entitlement.id);
    return app.c45_safe_birthday_entitlement(v_entitlement,v_as_of);
  end if;
  insert into public.customer_birthday_entitlements(
    business_id,client_id,identity_id,config_version_id,birthday_program_version_id,birthday_year,
    status,valid_from,valid_until,benefit_snapshot
  ) values(
    v_context.business_id,v_context.client_id,v_context.identity_id,v_program.config_version_id,v_program.id,v_window.birthday_year,
    'available',v_window.valid_from,v_window.valid_until,app.c45_benefit_snapshot(v_program)
  ) returning * into v_entitlement;
  insert into public.customer_birthday_activation_operations(identity_id,business_id,client_id,idempotency_key,request_hash,entitlement_id)
  values(v_context.identity_id,v_context.business_id,v_context.client_id,p_idempotency_key,v_request_hash,v_entitlement.id);
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(v_context.business_id,auth.uid(),'ACTIVATE_BIRTHDAY_BENEFIT','customer_birthday_entitlements',v_entitlement.id,jsonb_build_object('status','available'));
  return app.c45_safe_birthday_entitlement(v_entitlement,v_as_of);
exception when unique_violation then
  -- The per-customer/year uniqueness is the re-publish and concurrent-activate
  -- backstop. A caller retries through the same idempotency key for the exact
  -- immutable promise; changed inputs fail through the hash check above.
  select * into v_entitlement from public.customer_birthday_entitlements
   where business_id=v_context.business_id and client_id=v_context.client_id and birthday_year=v_window.birthday_year;
  if v_entitlement.id is null then raise; end if;
  insert into public.customer_birthday_activation_operations(identity_id,business_id,client_id,idempotency_key,request_hash,entitlement_id)
  values(v_context.identity_id,v_context.business_id,v_context.client_id,p_idempotency_key,v_request_hash,v_entitlement.id)
  on conflict (identity_id,business_id,idempotency_key) do nothing;
  return app.c45_safe_birthday_entitlement(v_entitlement,v_as_of);
end $function$;
revoke all on function public.customer_activate_birthday_benefit(text, uuid) from public, anon;
grant execute on function public.customer_activate_birthday_benefit(text, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 3. The preview. Byte-identical to v752 plus one predicate on the invitation branch.
-- ---------------------------------------------------------------------------------------------
create or replace function app.c45_customer_birthday_benefit_for_context(
  p_business_id uuid, p_client_id uuid, p_identity_id uuid, p_birth_date date,
  p_as_of timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_entitlement public.customer_birthday_entitlements%rowtype;
  v_program public.birthday_program_versions%rowtype;
  v_window record;
  v_opted_in boolean := false;
  v_display text;
begin
  select * into v_entitlement
    from public.customer_birthday_entitlements e
   where e.business_id = p_business_id and e.client_id = p_client_id
     and e.identity_id = p_identity_id and e.valid_until > p_as_of
   order by e.valid_until desc, e.activated_at desc
   limit 1;
  if found then
    return app.c45_safe_birthday_entitlement(v_entitlement, p_as_of);
  end if;
  select coalesce(p.opted_in, false) into v_opted_in
    from (select 1) one
    left join public.customer_birthday_participation p on p.identity_id = p_identity_id;
  select bpv.* into v_program
    from public.businesses b
    join public.birthday_program_versions bpv
      on bpv.config_version_id = b.active_config_version_id
     and bpv.business_id = b.id and bpv.active
   where b.id = p_business_id
     and 'loyalty' = any(coalesce(b.enabled_modules, '{}'::text[]))
   order by bpv.sort, bpv.program_id
   limit 1;
  if found then
    select * into v_window
      from app.c45_birthday_window(p_birth_date, v_program.window_days_before,
        v_program.window_days_after, p_as_of, v_program.window_mode);
    if found then
      select * into v_entitlement
        from public.customer_birthday_entitlements e
       where e.business_id = p_business_id and e.client_id = p_client_id
         and e.identity_id = p_identity_id and e.birthday_year = v_window.birthday_year
       order by e.activated_at desc
       limit 1;
      if found then return app.c45_safe_birthday_entitlement(v_entitlement, p_as_of); end if;
      -- nestly_v764: no "ready to activate" invitation for a number that deleted its account
      -- here in the last year; the activate RPC refuses it, so the preview must not offer it.
      if coalesce(v_opted_in, false)
         and not app.phone_recently_deleted_v751(p_business_id, p_client_id) then
        -- nestly_v752: the same derived sentence app.c45_benefit_snapshot gives a live
        -- entitlement, computed here BEFORE one exists yet (the customer has not tapped
        -- Activate), so the pre-activation preview and the post-activation card never disagree.
        v_display := case when v_program.fulfillment_kind = 'discount_pct'
          then app.v657_discount_label(v_program.discount_percent, v_program.discount_scope,
            v_program.max_discount_cents)
          else app.v369_benefit_label('free_item', null, v_program.product_id,
            v_program.manual_item, v_program.manual_item)
        end;
        return jsonb_build_object(
          'label', v_program.customer_label,
          'description', v_program.customer_description,
          'terms', v_program.customer_terms,
          'kind', v_program.fulfillment_kind,
          'display', v_display,
          'status', 'ready_to_activate',
          'validity', jsonb_build_object('available_from', v_window.valid_from, 'available_until', v_window.valid_until),
          'cta', 'activate'
        );
      end if;
    end if;
  end if;
  select * into v_entitlement
    from public.customer_birthday_entitlements e
   where e.business_id = p_business_id and e.client_id = p_client_id
     and e.identity_id = p_identity_id
   order by e.birthday_year desc, e.valid_until desc, e.activated_at desc
   limit 1;
  if found then return app.c45_safe_birthday_entitlement(v_entitlement, p_as_of); end if;
  return null;
end
$function$;
revoke all on function app.c45_customer_birthday_benefit_for_context(uuid, uuid, uuid, date, timestamptz)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 4. The deletion. Byte-identical to v751 except the ban instant.
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
         banned_until = app.v764_tombstone_ban_until(), deleted_at = now(), updated_at = now()
   where u.id = v_actor;

  v_receipt := jsonb_build_object('status','deleted','request_id',v_request.id,
    'completed_at',v_request.completed_at,'businesses_erased',v_erased,
    'identity_disabled', v_identity.id is not null);
  return v_receipt;
end;
$function$;
revoke all on function public.customer_delete_account_v749(text, text) from public, anon;
grant execute on function public.customer_delete_account_v749(text, text) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 5. Repair the tombstones already written with the unreadable value.
-- ---------------------------------------------------------------------------------------------
-- Guarded: the local test harness's auth.users has no banned_until column (the snapshot carries
-- only the columns the app's own fixtures write); production has it. Resolved at run time.
do $repair$
begin
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'auth' and table_name = 'users' and column_name = 'banned_until'
  ) then
    execute $q$
      update auth.users u
         set banned_until = app.v764_tombstone_ban_until(), updated_at = now()
       where u.deleted_at is not null
         and u.raw_user_meta_data @> '{"deleted_v749": true}'::jsonb
         and u.banned_until = 'infinity'::timestamptz
    $q$;
  end if;
end
$repair$;

-- The helper this change first shipped under (see the header); nothing references it once the
-- deletion RPC above is replaced.
drop function if exists app.v763_tombstone_ban_until();

commit;
