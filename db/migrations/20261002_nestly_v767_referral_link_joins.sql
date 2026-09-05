-- nestly_v767 — a friend's referral link joins the business by itself.
--
-- OWNER, 2026-09-05: "press onto referral link or scanned referral qrcode or scanned business
-- qrcode > after completed the sign up process > do not need to ask me to scan the business
-- again. i would have automatically joined their business". Ruled "Yes, auto-join".
--
-- BEFORE. A share link (#/wallet/<slug>?ref=<CODE>) carried the code through sign-up, but the
-- only writer that could create the membership was public.customer_join_business_from_qr_v89,
-- which demands the business's opaque join-QR token. A new customer who arrived by referral
-- therefore signed up, landed on the claim screen, and still had to find and scan the counter
-- QR before the code could even be applied. Half of them never did.
--
-- NOW. public.customer_join_business_by_referral_v767(slug, code, key) creates the same verified
-- link the QR path creates, with the same guards (verified mobile, completed profile, the same
-- client-by-phone reuse and the same "existing verified relationship cannot be joined
-- automatically" refusal), keyed on a different proof of business consent: a referral code that
-- belongs to a customer OF THAT BUSINESS, while that business has referrals switched on and
-- joining enabled. A code is business-issued in the only sense that matters — the business
-- configured the programme and one of its own customers handed the code out — so it carries the
-- same authority as the printed QR. The code itself is NOT applied here: the app applies it
-- through customer_apply_referral_code_v612 on the first wallet render, exactly as before, so the
-- new-customer rule (v683) and the deleted-number rule (v751) keep deciding whether anyone is paid.
--
-- Recorded distinctly: verification_method 'referral_join', claim operation 'referral_join', audit
-- events 'referral_join_linked' / 'referral_join_replayed'. Nothing reads these as anything but
-- "a verified link"; the distinction is for the record.

begin;

alter table public.customer_links
  drop constraint customer_links_verification_method_check,
  add constraint customer_links_verification_method_check
  check(verification_method in ('email_claim','firm_invitation','phone_claim','qr_join','qr_scan','referral_join'));

alter table public.customer_link_claim_attempts
  drop constraint customer_link_claim_attempts_operation_check,
  add constraint customer_link_claim_attempts_operation_check
  check(operation in (
    'email_claim','invitation_claim','phone_claim','relationship_sync','qr_join','referral_join'
  ));

alter table public.customer_link_audit_events
  drop constraint customer_link_audit_events_event_type_check,
  add constraint customer_link_audit_events_event_type_check
  check(event_type in (
    'email_claim_linked','email_claim_not_linked','email_claim_rate_limited',
    'phone_claim_linked','phone_claim_not_linked','phone_claim_rate_limited',
    'invitation_issued','invitation_claim_linked','invitation_claim_not_linked',
    'invitation_claim_rate_limited','link_unlinked','relationship_sync_linked',
    'qr_join_linked','qr_join_replayed','qr_join_not_linked',
    'referral_join_linked','referral_join_replayed'
  ));

create or replace function public.customer_join_business_by_referral_v767(
  p_business_slug text, p_code text, p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_identity uuid;
  v_slug text := lower(btrim(coalesce(p_business_slug,'')));
  v_code text := nullif(upper(btrim(coalesce(p_code,''))),'');
  v_business public.businesses%rowtype;
  v_referrer uuid;
  v_auth_phone text; v_phone_confirmed_at timestamptz; v_phone text;
  v_profile public.customer_profiles%rowtype;
  v_client uuid; v_link uuid; v_existing public.customer_link_claim_attempts%rowtype;
  v_hash text; v_response jsonb; v_event text;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode='28000';
  end if;
  if not app.platform_feature_enabled('customer_qr_join') then
    raise exception 'customer join is unavailable' using errcode='0A000';
  end if;
  if p_idempotency_key is null or v_slug = '' or v_code is null or char_length(v_code) > 32 then
    raise exception 'invalid referral join request' using errcode='22023';
  end if;
  v_identity := app.v31_current_identity();
  v_hash := app.v89_sha256(v_slug || ':' || v_code);
  perform pg_advisory_xact_lock(hashtextextended(
    'v767:join:' || v_identity::text || ':' || p_idempotency_key::text, 0));
  select * into v_existing from public.customer_link_claim_attempts attempt
   where attempt.identity_id = v_identity and attempt.operation = 'referral_join'
     and attempt.idempotency_key = p_idempotency_key::text for update;
  if found then
    if v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with another referral join' using errcode='23505';
    end if;
    return v_existing.response || jsonb_build_object('replayed', true);
  end if;

  -- The business must accept joins, run a referral programme, and the code must belong to one of
  -- ITS customers. Any miss is one refusal: the app does not learn which part failed.
  select b.* into v_business from public.businesses b
   where b.slug = v_slug and coalesce(b.join_enabled, false) for share;
  if not found then
    raise exception 'referral link is invalid or the business is not accepting joins' using errcode='22023';
  end if;
  if not exists (
    select 1 from public.referral_programs rp
     where rp.business_id = v_business.id and coalesce(rp.enabled, false)
  ) then
    raise exception 'referral link is invalid or the business is not accepting joins' using errcode='22023';
  end if;
  select c.id into v_referrer from public.clients c
   where c.business_id = v_business.id and c.referral_code = v_code limit 1;
  if v_referrer is null then
    raise exception 'referral link is invalid or the business is not accepting joins' using errcode='22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'v89:business-customer:' || v_business.id::text || ':' || v_identity::text, 0));
  select link.id, link.client_id into v_link, v_client
    from public.customer_links link
   where link.business_id = v_business.id and link.identity_id = v_identity
     and link.auth_user_id = v_actor and link.state = 'verified' for update;
  if found then
    v_response := jsonb_build_object('outcome','linked','business_id',v_business.id,
      'business_slug',v_business.slug,'business_name',v_business.name,
      'link_id',v_link,'replayed',true);
    v_event := 'referral_join_replayed';
  else
    select auth_user.phone, auth_user.phone_confirmed_at
      into v_auth_phone, v_phone_confirmed_at
      from auth.users auth_user where auth_user.id = v_actor for share;
    v_phone := app.norm_phone(v_auth_phone);
    if v_phone_confirmed_at is null or v_phone is null then
      raise exception 'verified customer mobile is required' using errcode='42501';
    end if;
    select * into v_profile from public.customer_profiles profile
     where profile.identity_id = v_identity and profile.auth_user_id = v_actor;
    if not found then
      raise exception 'completed customer profile is required' using errcode='42501';
    end if;
    select client.id into v_client from public.clients client
     where client.business_id = v_business.id and client.phone_norm = v_phone for update;
    if found and exists (
      select 1 from public.customer_links prior
       where prior.business_id = v_business.id and prior.client_id = v_client
         and prior.state = 'verified'
    ) then
      raise exception 'this business relationship cannot be joined automatically' using errcode='42501';
    end if;
    if v_client is null then
      insert into public.clients(business_id, full_name, phone, birth_date, marketing_consent)
      values (v_business.id, v_profile.full_name, v_phone, v_profile.birth_date, false)
      returning id into v_client;
    end if;
    v_link := gen_random_uuid();
    perform set_config('app.customer_link_insert_id', v_link::text, true);
    insert into public.customer_links(
      id, business_id, identity_id, auth_user_id, client_id, state, verification_method, verified_at
    ) values (
      v_link, v_business.id, v_identity, v_actor, v_client, 'verified', 'referral_join', now()
    );
    perform set_config('app.customer_link_insert_id', '', true);
    v_response := jsonb_build_object('outcome','linked','business_id',v_business.id,
      'business_slug',v_business.slug,'business_name',v_business.name,
      'link_id',v_link,'replayed',false);
    v_event := 'referral_join_linked';
  end if;
  insert into public.customer_link_claim_attempts(
    identity_id, auth_user_id, business_id, link_id, operation, idempotency_key,
    request_hash, outcome, response
  ) values (
    v_identity, v_actor, v_business.id, v_link, 'referral_join',
    p_idempotency_key::text, v_hash, 'linked', v_response
  );
  insert into public.customer_link_audit_events(
    identity_id, actor_auth_user_id, business_id, client_id, link_id, event_type,
    idempotency_key, request_hash, response
  ) values (
    v_identity, v_actor, v_business.id, v_client, v_link, v_event,
    p_idempotency_key::text, v_hash, v_response
  );
  return v_response;
end
$function$;
revoke all on function public.customer_join_business_by_referral_v767(text, text, uuid) from public, anon;
grant execute on function public.customer_join_business_by_referral_v767(text, text, uuid) to authenticated, service_role;
comment on function public.customer_join_business_by_referral_v767(text, text, uuid) is
  'nestly_v767. A signed-in customer joins a business through a friend''s referral code: the same '
  'verified link the join QR creates, gated on the business accepting joins, running referrals, '
  'and the code belonging to one of its customers. The code is applied separately by '
  'customer_apply_referral_code_v612.';

commit;
