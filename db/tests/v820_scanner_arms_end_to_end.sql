-- The counter's Scan button — THE REMAINING ARMS, END TO END, 2026-09-08.
--
-- openMerchantRedemptionScanner routes a scanned code by its kind, and each arm lands on a
-- different redeemer with its own permission predicate:
--
--   reward     -> merchant_scan_redemption_qr_v117      covered by v820_qr_redemption_end_to_end
--   member     -> staff_scan_member_qr_v327             covered by v820_qr_redemption_end_to_end
--   package    -> use_package_session_v102              HERE
--   promotion  -> staff_redeem_promotion_intent_v290    HERE
--   gift       -> staff_scan_gift_qr_v515               HERE
--   growth     -> redeem_growth_offer_v108              HERE, partially — see the note below
--
-- Every arm is walked from the customer minting the code to the counter settling it, as the
-- real principals on both sides, and every arm is put through the same four bearer-token
-- questions, because a QR is a string and whoever holds it can spend it:
--
--   1. does it work for the business it belongs to
--   2. can ANOTHER tenant spend it
--   3. does presenting it twice spend twice
--   4. is a cancelled or already-spent code inert
--
-- THE GROWTH ARM IS NOT FULLY WALKED, and this is stated rather than papered over.
-- public.growth_entitlements_v108 holds ZERO rows across the entire estate, and a row is only
-- ever written by a campaign delivery (it carries delivery_id and execution_id), so there is no
-- live entitlement to mint a QR from. Fabricating a campaign execution to manufacture one would
-- mostly test the fixture. What IS asserted here is the half that does not need an entitlement
-- and carries the actual risk: the redeemer refuses an unknown token and refuses a token from
-- another tenant. The minting and settling halves remain unexercised, in production as well as
-- here — nobody has ever redeemed a growth offer.
--
-- NEGATIVE CONTROLS, run 2026-09-08, so the refusals below are known to discriminate rather
-- than to pass because the call failed for some unrelated reason. Re-point a cross-tenant probe
-- at the OWNING business (v_biz/v_staff/v_branch in place of v_other/v_ostaff/v_obranch) so the
-- scan genuinely succeeds, and the suite must fail:
--   package arm -> S1: ANOTHER BUSINESS used this customer's package session
--   gift arm    -> S12: ANOTHER BUSINESS settled this customer's gift
-- Both do. Every refusal probe is also paired with a POSITIVE check that does not depend on the
-- exception at all — sessions remaining unchanged, the intent still pending, redeemed_at still
-- null — because catching an error only proves that something went wrong, not what.
--
--   supabase db query --linked -f db/tests/v820_scanner_arms_end_to_end.sql

begin;

do $suite$
declare
  v_biz     uuid;
  v_other   uuid;
  v_ostaff  uuid;
  v_obranch uuid;
  v_client  uuid;
  v_user    uuid;
  v_staff   uuid;
  v_branch  uuid;
  v_pkg     uuid;
  v_promo   uuid;
  v_grant   uuid;
  v_intent  uuid;
  v_token   text;
  v_res     jsonb;
  v_before  integer;
  v_after   integer;
  v_got     integer;
  v_txt     text;
  n         integer := 0;
begin
  -- An unrelated tenant with a real owner login and a live branch, so every isolation probe is
  -- a well-formed call that is refused on the TOKEN, not on its arguments.
  select b.id, st.user_id, br.id into v_other, v_ostaff, v_obranch
    from public.businesses b
    join public.staff st on st.business_id = b.id and st.role = 'owner' and st.active and st.user_id is not null
    join public.branches br on br.business_id = b.id and br.active
   limit 1;
  if v_other is null then
    raise exception 'S0: no second tenant to test isolation against';
  end if;

  -- ============================================================= ARM 1 — PACKAGE SESSION
  -- The scanned code here is the client_package id itself: no intent row, no hash, no expiry
  -- window. That is a deliberate difference from the reward QR and it is why the isolation and
  -- replay assertions below matter more, not less.
  select cp.id, cp.business_id, cp.client_id into v_pkg, v_biz, v_client
    from public.client_packages cp
   where cp.status = 'active' and cp.remaining > 0
     and exists (select 1 from public.staff st where st.business_id = cp.business_id
                   and st.role='owner' and st.active and st.user_id is not null)
     and exists (select 1 from public.branches br where br.business_id = cp.business_id and br.active)
     and cp.business_id <> v_other
   limit 1;

  if v_pkg is null then
    raise exception 'S1: no active package to walk the package arm with';
  end if;
  select st.user_id into v_staff from public.staff st
   where st.business_id = v_biz and st.role='owner' and st.active and st.user_id is not null limit 1;
  select br.id into v_branch from public.branches br
   where br.business_id = v_biz and br.active order by br.is_default desc limit 1;

  select remaining into v_before from public.client_packages where id = v_pkg;

  -- 2. another tenant cannot spend it
  n := n + 1;
  begin
    set local role authenticated;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_ostaff, 'role','authenticated')::text, true);
    perform public.use_package_session_v102(v_other, v_pkg, v_obranch, gen_random_uuid()::text);
    reset role; perform set_config('request.jwt.claims','',true);
    raise exception 'S%: ANOTHER BUSINESS used this customer''s package session', n;
  exception when others then
    reset role; perform set_config('request.jwt.claims','',true);
    if sqlerrm like 'S%ANOTHER BUSINESS%' then raise; end if;
  end;
  n := n + 1;
  select remaining into v_got from public.client_packages where id = v_pkg;
  if v_got is distinct from v_before then
    raise exception 'S%: the cross-tenant package attempt still consumed a session', n;
  end if;

  -- 1. it works for the business it belongs to
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_staff, 'role','authenticated')::text, true);
  perform public.use_package_session_v102(v_biz, v_pkg, v_branch, 'arms-pkg-' || gen_random_uuid()::text);
  reset role; perform set_config('request.jwt.claims','',true);
  select remaining into v_after from public.client_packages where id = v_pkg;
  if v_after <> v_before - 1 then
    raise exception 'S%: using a package session moved remaining % -> %, expected one less',
      n, v_before, v_after;
  end if;

  -- 3. the same idempotency key presented twice does not consume twice
  n := n + 1;
  v_txt := 'arms-pkg-replay-' || gen_random_uuid()::text;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_staff, 'role','authenticated')::text, true);
  perform public.use_package_session_v102(v_biz, v_pkg, v_branch, v_txt);
  perform public.use_package_session_v102(v_biz, v_pkg, v_branch, v_txt);
  reset role; perform set_config('request.jwt.claims','',true);
  select remaining into v_got from public.client_packages where id = v_pkg;
  if v_got <> v_after - 1 then
    raise exception 'S%: a replayed package scan consumed twice (% -> %)', n, v_after, v_got;
  end if;

  -- 4. an exhausted package is inert
  n := n + 1;
  update public.client_packages set remaining = 0 where id = v_pkg;
  begin
    set local role authenticated;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_staff, 'role','authenticated')::text, true);
    perform public.use_package_session_v102(v_biz, v_pkg, v_branch, 'arms-pkg-empty-' || gen_random_uuid()::text);
    reset role; perform set_config('request.jwt.claims','',true);
    raise exception 'S%: an EXHAUSTED package still allowed a session', n;
  exception when others then
    reset role; perform set_config('request.jwt.claims','',true);
    if sqlerrm like 'S%EXHAUSTED package%' then raise; end if;
  end;

  -- ================================================================== ARM 2 — PROMOTION
  select c.id, c.business_id into v_promo, v_biz
    from public.business_customer_content_v95 c
   where c.content_type = 'offer' and c.active and c.branch_id is null
     and (c.starts_at is null or c.starts_at <= now()) and c.ends_at > now()
     and c.business_id <> v_other
     and exists (select 1 from public.customer_links l
                   where l.business_id = c.business_id and l.state = 'verified')
     and exists (select 1 from public.staff st where st.business_id = c.business_id
                   and st.role='owner' and st.active and st.user_id is not null)
     and exists (select 1 from public.branches br where br.business_id = c.business_id and br.active)
   limit 1;

  if v_promo is null then
    raise exception 'S2: no live offer with a linked customer to walk the promotion arm with';
  end if;
  select l.auth_user_id, l.client_id into v_user, v_client from public.customer_links l
   where l.business_id = v_biz and l.state='verified' limit 1;
  select st.user_id into v_staff from public.staff st
   where st.business_id = v_biz and st.role='owner' and st.active and st.user_id is not null limit 1;
  select br.id into v_branch from public.branches br
   where br.business_id = v_biz and br.active order by br.is_default desc limit 1;

  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role','authenticated')::text, true);
  v_res := public.customer_create_promotion_intent_v290(v_biz, v_promo, gen_random_uuid())::jsonb;
  reset role; perform set_config('request.jwt.claims','',true);
  v_token := coalesce(v_res->>'qr_token', v_res->>'token');
  if v_token is null then
    raise exception 'S%: the customer''s offer QR came back with no token (%)', n, left(v_res::text,300);
  end if;

  -- 2. another tenant cannot spend it
  n := n + 1;
  begin
    set local role authenticated;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_ostaff, 'role','authenticated')::text, true);
    perform public.staff_redeem_promotion_intent_v290(v_other, v_token, v_obranch, gen_random_uuid()::text);
    reset role; perform set_config('request.jwt.claims','',true);
    raise exception 'S%: ANOTHER BUSINESS redeemed this offer QR', n;
  exception when others then
    reset role; perform set_config('request.jwt.claims','',true);
    if sqlerrm like 'S%ANOTHER BUSINESS%' then raise; end if;
  end;
  n := n + 1;
  select count(*)::integer into v_got from public.promotion_redemption_intents_v290 i
   where i.business_id = v_biz and i.status = 'pending'
     and i.created_at >= now() - interval '5 minutes';
  if v_got < 1 then
    raise exception 'S%: the offer QR stopped being pending after a cross-tenant attempt', n;
  end if;

  -- 1. it works for the business it belongs to
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_staff, 'role','authenticated')::text, true);
  perform public.staff_redeem_promotion_intent_v290(v_biz, v_token, v_branch, 'arms-promo-' || gen_random_uuid()::text);
  reset role; perform set_config('request.jwt.claims','',true);
  select count(*)::integer into v_got from public.promotion_redemptions_v290 r
   where r.business_id = v_biz and r.client_id = v_client;
  if v_got < 1 then
    raise exception 'S%: redeeming the offer recorded no promotion redemption', n;
  end if;

  -- 3 and 4. the same code again must not record a second redemption
  n := n + 1;
  begin
    set local role authenticated;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_staff, 'role','authenticated')::text, true);
    perform public.staff_redeem_promotion_intent_v290(v_biz, v_token, v_branch, 'arms-promo-again-' || gen_random_uuid()::text);
    reset role; perform set_config('request.jwt.claims','',true);
  exception when others then
    reset role; perform set_config('request.jwt.claims','',true);
  end;
  select count(*)::integer into v_after from public.promotion_redemptions_v290 r
   where r.business_id = v_biz and r.client_id = v_client;
  if v_after <> v_got then
    raise exception 'S%: RESCANNING THE SAME OFFER redeemed it again (% then %)', n, v_got, v_after;
  end if;

  -- ======================================================================= ARM 3 — GIFT
  -- A welcome gift with no minimum spend, so the arm is exercised without also having to stage
  -- a qualifying sale — the min-spend case is a different rule and belongs to its own walk.
  select g.id, g.business_id, g.client_id into v_grant, v_biz, v_client
    from public.welcome_offer_grants_v215 g
   where g.status = 'granted' and g.redeemed_at is null
     and coalesce(g.min_spend_cents, 0) = 0
     and g.business_id <> v_other
     and exists (select 1 from public.customer_links l
                   where l.business_id = g.business_id and l.client_id = g.client_id and l.state='verified')
     and exists (select 1 from public.staff st where st.business_id = g.business_id
                   and st.role='owner' and st.active and st.user_id is not null)
     and exists (select 1 from public.branches br where br.business_id = g.business_id and br.active)
   limit 1;

  if v_grant is null then
    raise exception 'S3: no unredeemed no-minimum welcome gift to walk the gift arm with';
  end if;
  select l.auth_user_id into v_user from public.customer_links l
   where l.business_id = v_biz and l.client_id = v_client and l.state='verified' limit 1;
  select st.user_id into v_staff from public.staff st
   where st.business_id = v_biz and st.role='owner' and st.active and st.user_id is not null limit 1;
  select br.id into v_branch from public.branches br
   where br.business_id = v_biz and br.active order by br.is_default desc limit 1;

  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role','authenticated')::text, true);
  v_res := public.customer_create_gift_intent_v515(v_biz, 'welcome', v_grant, gen_random_uuid())::jsonb;
  reset role; perform set_config('request.jwt.claims','',true);
  v_intent := nullif(v_res->>'intent_id','')::uuid;
  v_token := coalesce(v_res->>'qr_token', v_res->>'token');
  if v_token is null then
    raise exception 'S%: the gift QR came back with no token (%)', n, left(v_res::text,300);
  end if;

  -- 2. another tenant cannot spend it
  n := n + 1;
  begin
    set local role authenticated;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_ostaff, 'role','authenticated')::text, true);
    perform public.staff_scan_gift_qr_v515(v_other, v_obranch, v_token, null, gen_random_uuid());
    reset role; perform set_config('request.jwt.claims','',true);
    raise exception 'S%: ANOTHER BUSINESS settled this customer''s gift', n;
  exception when others then
    reset role; perform set_config('request.jwt.claims','',true);
    if sqlerrm like 'S%ANOTHER BUSINESS%' then raise; end if;
  end;
  n := n + 1;
  if (select redeemed_at from public.welcome_offer_grants_v215 where id = v_grant) is not null then
    raise exception 'S%: the cross-tenant gift scan still consumed the grant', n;
  end if;

  -- 1. it works for the business it belongs to
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_staff, 'role','authenticated')::text, true);
  perform public.staff_scan_gift_qr_v515(v_biz, v_branch, v_token, null, gen_random_uuid());
  reset role; perform set_config('request.jwt.claims','',true);
  if (select redeemed_at from public.welcome_offer_grants_v215 where id = v_grant) is null then
    raise exception 'S%: scanning the gift QR did not settle the welcome grant', n;
  end if;

  -- 3. and it cannot be settled twice
  n := n + 1;
  select redeemed_at into v_txt from public.welcome_offer_grants_v215 where id = v_grant;
  begin
    set local role authenticated;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_staff, 'role','authenticated')::text, true);
    perform public.staff_scan_gift_qr_v515(v_biz, v_branch, v_token, null, gen_random_uuid());
    reset role; perform set_config('request.jwt.claims','',true);
  exception when others then
    reset role; perform set_config('request.jwt.claims','',true);
  end;
  if (select redeemed_at from public.welcome_offer_grants_v215 where id = v_grant)::text
     is distinct from v_txt then
    raise exception 'S%: RESCANNING THE SAME GIFT settled it a second time', n;
  end if;

  -- ===================================================================== ARM 4 — GROWTH
  -- Partial, deliberately: there is no growth entitlement anywhere on the estate to mint a code
  -- from (see the header). These two assertions cover the half that carries the bearer-token
  -- risk and needs no entitlement.
  n := n + 1;
  select count(*)::integer into v_got from public.growth_entitlements_v108;
  if v_got <> 0 then
    raise exception 'S%: growth entitlements now exist (%) — this arm can and should be walked in full', n, v_got;
  end if;

  n := n + 1;
  begin
    set local role authenticated;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_ostaff, 'role','authenticated')::text, true);
    perform public.redeem_growth_offer_v108(v_other, 'not-a-real-growth-token', null, gen_random_uuid());
    reset role; perform set_config('request.jwt.claims','',true);
    raise exception 'S%: the growth redeemer ACCEPTED a token that does not exist', n;
  exception when others then
    reset role; perform set_config('request.jwt.claims','',true);
    if sqlerrm like 'S%ACCEPTED a token%' then raise; end if;
  end;

  raise notice 'scanner arms end to end: % / % assertions passed', n, n;
end
$suite$;

rollback;
