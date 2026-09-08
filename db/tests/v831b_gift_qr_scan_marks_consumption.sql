-- nestly_v831b — the gift QR scan really does burn the benefit.
--
-- OWNER, 2026-09-09: "once the vouchers is used > not able to use again for referral or welcome
-- rewards. also verify if the scanning of qrcode of those rewards we discuss in this session is
-- working in the correct structure."
--
-- v831 made the gates read a CONSUMPTION mark. That is only worth anything if the counter's real
-- redemption route writes one. The route is public.staff_scan_gift_qr_v515, which resolves the QR
-- token to a customer_gift_intents_v515 row and dispatches by gift_kind:
--     welcome   -> public.staff_redeem_welcome_offer_v215
--     referral  -> public.staff_redeem_referral_v420
--     birthday  -> public.staff_confirm_birthday_free_item_v752 (free_item programmes only; a
--                  discount_pct programme is settled earlier by staff_stage_gift_qr_v665)
--     bringback -> public.staff_redeem_bringback_v361
--     tier_perk -> public.staff_issue_tier_benefit_v365
-- Reading that dispatch is not proof. This suite EXECUTES it as the real staff principal.
--
-- Run inside a transaction against production and ROLLED BACK. Tenant: ÉLAN Wellness — the only
-- one carrying all three at once (welcome offer live, referral paid as a VOUCHER, birthday
-- programme live), so the voucher rule the owner confirmed is exercised on real configuration.
-- Both customers are synthetic (+65 8000 0832 / 0833) and never commit.

\set ON_ERROR_STOP on

begin;

do $suite$
declare
  biz uuid := '8ccace3a-9736-447e-bb1e-da842622592d';   -- ÉLAN Wellness
  staff_uid uuid := '8efcffc8-61a5-4235-ad45-54a8954208f9';
  br uuid;
  ph_w text := '80000832';
  ph_f text := '80000833';
  c_w uuid; c_w2 uuid; c_f uuid; c_f2 uuid; c_r uuid;
  g_w uuid; ref_id uuid; g_ref uuid; g_ref_referrer uuid; ent uuid;
  tok text; res jsonb; yr integer := extract(year from now() at time zone 'Asia/Singapore')::integer;
  -- customer_gift_intents_v515 records WHO minted the QR (identity_id/auth_user_id NOT NULL). An
  -- existing live identity stands in for that customer rather than fabricating auth rows; the
  -- scan resolves the reward from the intent's client_id, which is the synthetic customer below.
  idn uuid; idn_uid uuid; cfg uuid; bpv uuid;
  n integer := 0;
begin
  select id into br from public.branches where business_id = biz and active order by created_at limit 1;
  if br is null then raise exception 'setup: no active branch'; end if;
  select ci.id, ci.auth_user_id into idn, idn_uid from public.customer_identities ci
   where ci.auth_user_id is not null and ci.status = 'active' order by ci.created_at desc limit 1;
  if idn is null then raise exception 'setup: no live customer identity to mint the QR as'; end if;
  select b.active_config_version_id, v.id into cfg, bpv
    from public.businesses b
    join public.birthday_program_versions v
      on v.business_id = b.id and v.config_version_id = b.active_config_version_id and v.active
   where b.id = biz
   order by v.sort, v.program_id limit 1;
  if bpv is null then raise exception 'setup: no live birthday programme'; end if;
  -- Become the counter. Every RPC below reads auth.uid() exactly as it does in production.
  perform set_config('request.jwt.claims',
    json_build_object('sub', staff_uid::text, 'role', 'authenticated')::text, true);
  perform app.acquire_loyalty_shared_v480(biz);

  -- =========================================================================================
  -- A. WELCOME GIFT, redeemed by scanning the customer's QR.
  -- =========================================================================================
  insert into public.clients(business_id, full_name, phone) values (biz, 'v831b welcome', ph_w)
    returning id into c_w;
  g_w := app.issue_welcome_offer_v215(biz, c_w);
  n := n + 1;
  if g_w is null then raise exception 'A1 failed: setup could not grant the welcome gift'; end if;
  n := n + 1;
  if app.benefit_consumed_v831(biz, c_w, 'welcome', 'once') then
    raise exception 'A2 failed: an unscanned gift was already marked consumed';
  end if;

  tok := encode(gen_random_bytes(24), 'hex');
  insert into public.customer_gift_intents_v515(
    business_id, identity_id, auth_user_id, client_id, gift_kind, grant_id, quoted_label,
    quoted_min_spend_cents, token_hash, idempotency_key, request_hash, status, expires_at)
  values (biz, idn, idn_uid, c_w, 'welcome', g_w, 'v831b welcome', 0,
    app.v89_sha256(tok), gen_random_uuid(), app.v89_sha256('v831b-a'), 'pending', now() + interval '10 minutes');

  res := public.staff_scan_gift_qr_v515(biz, br, tok, null, gen_random_uuid());
  n := n + 1;
  if res->>'status' is distinct from 'completed' then
    raise exception 'A3 failed: welcome QR scan returned %', coalesce(res::text,'(null)');
  end if;
  n := n + 1;
  if (select status from public.welcome_offer_grants_v215 where id = g_w) is distinct from 'redeemed' then
    raise exception 'A4 failed: the scan did not redeem the welcome grant';
  end if;
  n := n + 1;
  if not app.benefit_consumed_v831(biz, c_w, 'welcome', 'once') then
    raise exception 'A5 failed: the scan redeemed the gift but wrote NO consumption mark — the '
      'counter route bypasses v831';
  end if;

  -- The whole point: delete and sign up again, and the scanned gift does not come back.
  update public.clients set full_name = 'Erased customer', phone = null where id = c_w;
  insert into public.clients(business_id, full_name, phone) values (biz, 'v831b welcome again', ph_w)
    returning id into c_w2;
  n := n + 1;
  if app.issue_welcome_offer_v215(biz, c_w2) is not null then
    raise exception 'A6 failed: a scanned-and-used welcome gift was granted again after a rejoin';
  end if;

  -- Replay: the same QR scanned twice must not mint a second mark.
  res := public.staff_scan_gift_qr_v515(biz, br, tok, null, gen_random_uuid());
  n := n + 1;
  if coalesce((res->>'replayed')::boolean, false) is not true then
    raise exception 'A7 failed: rescanning a completed gift QR was not treated as a replay';
  end if;
  n := n + 1;
  if (select count(*) from public.benefit_consumption_marks_v831 m
       where m.business_id = biz and m.benefit_kind = 'welcome'
         and m.phone_hash = app.v89_sha256(ph_w)) <> 1 then
    raise exception 'A8 failed: the replay wrote a second consumption mark';
  end if;

  -- =========================================================================================
  -- B. REFERRAL VOUCHER, redeemed by scanning. Owner, today: "once the vouchers is used > not
  --    able to use again for referral or welcome rewards."
  -- =========================================================================================
  insert into public.clients(business_id, full_name, phone) values (biz, 'v831b referrer', '80000834')
    returning id into c_r;
  insert into public.clients(business_id, full_name, phone) values (biz, 'v831b friend', ph_f)
    returning id into c_f;
  insert into public.referrals(business_id, referrer_client_id, referred_client_id, status, qualified_at)
  values (biz, c_r, c_f, 'rewarded', now()) returning id into ref_id;
  insert into public.referral_grants_v420(business_id, client_id, referral_id, beneficiary, reward_label)
  values (biz, c_r, ref_id, 'referrer', 'v831b referral gift') returning id into g_ref_referrer;
  insert into public.referral_grants_v420(business_id, client_id, referral_id, beneficiary, reward_label)
  values (biz, c_f, ref_id, 'friend', 'v831b referral gift') returning id into g_ref;

  n := n + 1;
  if app.benefit_consumed_v831(biz, c_f, 'referral_friend', 'once') then
    raise exception 'B1 failed: an unredeemed referral voucher was already marked consumed';
  end if;

  -- The REFERRER redeeming theirs must not burn the FRIEND's side.
  tok := encode(gen_random_bytes(24), 'hex');
  insert into public.customer_gift_intents_v515(
    business_id, identity_id, auth_user_id, client_id, gift_kind, grant_id, quoted_label,
    quoted_min_spend_cents, token_hash, idempotency_key, request_hash, status, expires_at)
  values (biz, idn, idn_uid, c_r, 'referral', g_ref_referrer, 'v831b referral gift', 0,
    app.v89_sha256(tok), gen_random_uuid(), app.v89_sha256('v831b-b0'), 'pending', now() + interval '10 minutes');
  perform public.staff_scan_gift_qr_v515(biz, br, tok, null, gen_random_uuid());
  n := n + 1;
  if app.benefit_consumed_v831(biz, c_f, 'referral_friend', 'once') then
    raise exception 'B2 failed: the referrer''s redemption burned the friend''s referral benefit';
  end if;

  -- Now the friend's own voucher, scanned at the counter.
  tok := encode(gen_random_bytes(24), 'hex');
  insert into public.customer_gift_intents_v515(
    business_id, identity_id, auth_user_id, client_id, gift_kind, grant_id, quoted_label,
    quoted_min_spend_cents, token_hash, idempotency_key, request_hash, status, expires_at)
  values (biz, idn, idn_uid, c_f, 'referral', g_ref, 'v831b referral gift', 0,
    app.v89_sha256(tok), gen_random_uuid(), app.v89_sha256('v831b-b1'), 'pending', now() + interval '10 minutes');
  res := public.staff_scan_gift_qr_v515(biz, br, tok, null, gen_random_uuid());
  n := n + 1;
  if res->>'status' is distinct from 'completed' then
    raise exception 'B3 failed: referral QR scan returned %', coalesce(res::text,'(null)');
  end if;
  n := n + 1;
  if (select status from public.referral_grants_v420 where id = g_ref) is distinct from 'redeemed' then
    raise exception 'B4 failed: the scan did not redeem the friend''s referral voucher';
  end if;
  n := n + 1;
  if not app.benefit_consumed_v831(biz, c_f, 'referral_friend', 'once') then
    raise exception 'B5 failed: the scanned referral voucher wrote no consumption mark';
  end if;

  -- Delete and rejoin: a different referrer's code must not pay this number again.
  update public.clients set full_name = 'Erased customer', phone = null where id = c_f;
  insert into public.clients(business_id, full_name, phone) values (biz, 'v831b friend again', ph_f)
    returning id into c_f2;
  n := n + 1;
  if app.referral_referred_is_new_v683(biz, c_f2) then
    raise exception 'B6 failed: a number whose referral voucher was used is still a new customer';
  end if;

  -- =========================================================================================
  -- C. BIRTHDAY. Both QR branches (free_item via staff_confirm_birthday_free_item_v752, and
  --    discount_pct via staff_stage_gift_qr_v665) settle through this one redeemer, so this is
  --    the join point both scans depend on.
  -- =========================================================================================
  insert into public.customer_birthday_entitlements(
    business_id, identity_id, client_id, config_version_id, birthday_program_version_id,
    birthday_year, status, valid_from, valid_until, benefit_snapshot)
  values (biz, idn, c_w2, cfg, bpv, yr, 'available', now() - interval '1 day', now() + interval '20 days',
          jsonb_build_object('source','v831b'))
  returning id into ent;

  perform set_config('app.c45_entitlement_id', ent::text, true);
  update public.customer_birthday_entitlements set status = 'redeemed' where id = ent;
  perform set_config('app.c45_entitlement_id', '', true);

  n := n + 1;
  if not app.benefit_consumed_v831(biz, c_w2, 'birthday', yr::text) then
    raise exception 'C1 failed: redeeming this year''s birthday wrote no consumption mark';
  end if;
  n := n + 1;
  if app.benefit_consumed_v831(biz, c_w2, 'birthday', (yr + 1)::text) then
    raise exception 'C2 failed: using this year''s birthday also burned next year''s';
  end if;

  -- NEGATIVE CONTROL. Reverse the birthday redemption; the mark must go, proving C1 was caused
  -- by the redemption and not by something already sitting in the table.
  perform set_config('app.c45_entitlement_id', ent::text, true);
  update public.customer_birthday_entitlements set status = 'available' where id = ent;
  perform set_config('app.c45_entitlement_id', '', true);
  n := n + 1;
  if app.benefit_consumed_v831(biz, c_w2, 'birthday', yr::text) then
    raise exception 'C3 failed (negative control): reversing the redemption left the mark, so C1 proved nothing';
  end if;

  raise notice 'nestly_v831b suite: % assertions passed', n;
end
$suite$;

select 'v831b gift-QR suite passed' as result;

rollback;
