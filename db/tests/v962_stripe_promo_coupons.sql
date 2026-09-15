-- nestly_v962 rollback suite — a promo code reaches Stripe.
--
-- Run inside a transaction against production and ROLLED BACK. Impersonates a real super admin
-- (public.super_admins) with the v625 Google-OAuth-shaped claims, and real merchant owners.
--
-- What must hold:
--   * a STRIPE firm can now redeem (v961 refused every provider), and the redemption records the
--     provider and asks its caller for a coupon;
--   * a RAZORPAY firm is refused in its OWN words — their offers cannot be created by API at all;
--   * the manual path is untouched (v961 regression);
--   * the executor's two hands work: it reads the redemption's SNAPSHOTTED terms, and records
--     either the coupon it made or the error it hit — never silently claiming success;
--   * request_billing_command_v124 will not mint apply_promo_coupon without both a provider
--     subscription and something to apply, and every other command it already minted still mints.

\set ON_ERROR_STOP on

begin;

do $suite$
declare
  sa uuid; owner_s uuid := gen_random_uuid(); owner_m uuid := gen_random_uuid();
  biz_s uuid := gen_random_uuid();   -- stripe
  biz_r uuid := gen_random_uuid();   -- razorpay
  biz_m uuid := gen_random_uuid();   -- manual
  biz_n uuid := gen_random_uuid();   -- stripe, no provider subscription linked
  got jsonb; intent jsonb; n integer := 0; sqlstate_seen text;
  promo_pct uuid; promo_usd uuid; red uuid;
  row_r public.platform_promo_redemptions_v961%rowtype;
begin
  select user_id into sa from public.super_admins limit 1;
  if sa is null then raise exception 'A0 failed: no super admin to impersonate'; end if;

  insert into auth.users(id,email) values
    (owner_s,'zz-v962-stripe@example.test'), (owner_m,'zz-v962-manual@example.test')
    on conflict (id) do nothing;
  insert into public.businesses(id,name,slug,industry,join_enabled,enabled_modules) values
    (biz_s,'V962 stripe fixture','v962-s-'||substr(biz_s::text,1,8),'test',true,array['dashboard']),
    (biz_r,'V962 razorpay fixture','v962-r-'||substr(biz_r::text,1,8),'test',true,array['dashboard']),
    (biz_m,'V962 manual fixture','v962-m-'||substr(biz_m::text,1,8),'test',true,array['dashboard']),
    (biz_n,'V962 unlinked fixture','v962-n-'||substr(biz_n::text,1,8),'test',true,array['dashboard']);
  insert into public.subscriptions(business_id,billing_provider,status,payment_status,currency,provider_subscription_id) values
    (biz_s,'stripe','active','paid','SGD','sub_v962fixture'),
    (biz_r,'razorpay','active','paid','SGD','sub_rzp_v962'),
    (biz_m,'manual','trialing','not_collected','SGD',null),
    (biz_n,'stripe','incomplete','not_collected','SGD',null);
  insert into public.staff(business_id,user_id,role,active,full_name) values
    (biz_s,owner_s,'owner',true,'V962 Stripe Owner'),
    (biz_m,owner_m,'owner',true,'V962 Manual Owner');

  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', sa, 'role', 'authenticated',
    'amr', jsonb_build_array(jsonb_build_object('method', 'oauth')),
    'app_metadata', jsonb_build_object('providers', jsonb_build_array('google')))::text, true);
  perform set_config('request.jwt.claim.sub', sa::text, true);

  got := public.platform_create_promo_code_v961('V962PCT','percent',2000,null,null,null,null,'suite');
  promo_pct := (got->>'id')::uuid;
  got := public.platform_create_promo_code_v961('V962USD','amount',null,20000,null,null,null,'suite');
  promo_usd := (got->>'id')::uuid;
  got := public.platform_create_promo_code_v961('V962EUR','amount',null,5000,null,null,null,'suite');
  update public.platform_promo_codes_v961 set currency='EUR' where id=(got->>'id')::uuid;

  -- ------------------------------------------------------------------ razorpay says why
  n := n + 1;
  begin
    perform public.business_redeem_promo_code_v961(biz_r,'V962PCT');
    raise exception 'A% failed: a razorpay firm redeemed a promo code', n;
  exception when sqlstate '22023' then
    get stacked diagnostics sqlstate_seen = message_text;
    if sqlstate_seen <> 'promo_razorpay_unsupported' then
      raise exception 'A% failed: razorpay refused with %, expected promo_razorpay_unsupported', n, sqlstate_seen; end if;
  end;

  -- ------------------------------------------------------------------ a stripe firm with no linked subscription
  n := n + 1;
  begin
    perform public.business_redeem_promo_code_v961(biz_n,'V962PCT');
    raise exception 'A% failed: a stripe firm with no linked subscription redeemed', n;
  exception when sqlstate '22023' then
    get stacked diagnostics sqlstate_seen = message_text;
    if sqlstate_seen <> 'promo_no_provider_subscription' then
      raise exception 'A% failed: refused with %, expected promo_no_provider_subscription', n, sqlstate_seen; end if;
  end;

  -- ------------------------------------------------------------------ a fixed amount in the wrong currency
  n := n + 1;
  begin
    perform public.business_redeem_promo_code_v961(biz_s,'V962EUR');
    raise exception 'A% failed: a EUR code was accepted on an SGD stripe subscription', n;
  exception when sqlstate '22023' then
    get stacked diagnostics sqlstate_seen = message_text;
    if sqlstate_seen <> 'promo_currency_mismatch' then
      raise exception 'A% failed: refused with %, expected promo_currency_mismatch', n, sqlstate_seen; end if;
  end;
  -- ...but a PERCENTAGE travels to any currency
  n := n + 1;
  got := public.business_redeem_promo_code_v961(biz_s,'V962PCT');
  if (got->>'status') <> 'ok' or (got->>'provider') <> 'stripe'
     or (got->>'needs_provider_coupon') <> 'true' then
    raise exception 'A% failed: stripe redemption did not ask for a coupon: %', n, got; end if;
  red := (got->>'redemption_id')::uuid;

  n := n + 1;
  select * into row_r from public.platform_promo_redemptions_v961 where id=red;
  if row_r.provider <> 'stripe' or row_r.provider_applied_at is not null then
    raise exception 'A% failed: a fresh stripe redemption is not un-applied', n; end if;

  -- ------------------------------------------------------------------ the manual path is untouched
  n := n + 1;
  got := public.business_redeem_promo_code_v961(biz_m,'V962USD');
  if (got->>'status') <> 'ok' or (got->>'provider') <> 'manual'
     or (got->>'needs_provider_coupon') <> 'false' then
    raise exception 'A% failed: v961 manual behaviour changed: %', n, got; end if;

  -- ------------------------------------------------------------------ minting the command
  n := n + 1;
  begin
    perform public.request_billing_command_v124(biz_m,'apply_promo_coupon',null,null,gen_random_uuid());
    raise exception 'A% failed: a manual firm minted a provider coupon command', n;
  exception when sqlstate '22023' then null; end;

  n := n + 1;
  got := public.request_billing_command_v124(biz_s,'apply_promo_coupon',null,null,gen_random_uuid());
  if (got->>'command_type') <> 'apply_promo_coupon' or (got->>'status') <> 'pending' then
    raise exception 'A% failed: the stripe command did not mint: %', n, got; end if;

  -- every command type that minted before must still mint (the gate was patched, not rewritten)
  n := n + 1;
  got := public.request_billing_command_v124(biz_s,'refresh_payment_method',null,null,gen_random_uuid());
  if (got->>'command_type') <> 'refresh_payment_method' then
    raise exception 'A% failed: patching the gate broke refresh_payment_method', n; end if;
  n := n + 1;
  begin
    perform public.request_billing_command_v124(biz_s,'not_a_command',null,null,gen_random_uuid());
    raise exception 'A% failed: an unknown command type was accepted', n;
  exception when sqlstate '22023' then null; end;

  -- ------------------------------------------------------------------ the executor's two hands
  n := n + 1;
  intent := app.promo_provider_intent_v962(biz_s);
  if (intent->>'has_intent') <> 'true' or (intent->>'discount_kind') <> 'percent'
     or (intent->>'percent_bps') <> '2000'
     or (intent->>'provider_subscription_id') <> 'sub_v962fixture' then
    raise exception 'A% failed: the executor cannot see what to apply: %', n, intent; end if;

  -- the intent is the REDEMPTION's snapshot, not the code's current terms
  n := n + 1;
  update public.platform_promo_codes_v961 set percent_bps=9900 where id=promo_pct;
  intent := app.promo_provider_intent_v962(biz_s);
  if (intent->>'percent_bps') <> '2000' then
    raise exception 'A% failed: editing the code changed what is sent to the provider (%)', n, intent->>'percent_bps'; end if;

  -- a failure is written down, not swallowed
  n := n + 1;
  got := app.promo_provider_applied_v962(red, null, 'Stripe said no');
  select * into row_r from public.platform_promo_redemptions_v961 where id=red;
  if (got->>'status') <> 'error' or row_r.provider_applied_at is not null
     or row_r.provider_error is distinct from 'Stripe said no' then
    raise exception 'A% failed: a provider failure was not recorded', n; end if;

  n := n + 1;
  if not exists(select 1 from public.audit_log where business_id=biz_s
                 and action='promo_provider_coupon_failed') then
    raise exception 'A% failed: a provider failure was not audited', n; end if;

  -- ...and a success clears it
  n := n + 1;
  got := app.promo_provider_applied_v962(red, 'coupon_v962test', null);
  select * into row_r from public.platform_promo_redemptions_v961 where id=red;
  if (got->>'status') <> 'ok' or row_r.provider_coupon_id <> 'coupon_v962test'
     or row_r.provider_applied_at is null or row_r.provider_error is not null then
    raise exception 'A% failed: the applied coupon was not recorded', n; end if;

  n := n + 1;
  if not exists(select 1 from public.audit_log where business_id=biz_s
                 and action='promo_provider_coupon_applied') then
    raise exception 'A% failed: the applied coupon was not audited', n; end if;

  -- an applied redemption is no longer an intent, so a retry cannot double-apply
  n := n + 1;
  intent := app.promo_provider_intent_v962(biz_s);
  if (intent->>'has_intent') <> 'false' then
    raise exception 'A% failed: an applied coupon is still offered to the executor', n; end if;

  -- and the command will not mint again
  n := n + 1;
  begin
    perform public.request_billing_command_v124(biz_s,'apply_promo_coupon',null,null,gen_random_uuid());
    raise exception 'A% failed: a second coupon command minted after the first applied', n;
  exception when sqlstate '22023' then null; end;

  -- ------------------------------------------------------------------ what both surfaces read
  n := n + 1;
  got := public.business_get_promo_state_v961(biz_s);
  if (got->>'provider') <> 'stripe' or (got->>'provider_coupon_id') <> 'coupon_v962test'
     or (got->>'provider_applied_at') is null or (got->>'needs_provider_coupon') <> 'false' then
    raise exception 'A% failed: the promo state hides the provider coupon: %', n, got; end if;

  n := n + 1;
  got := public.business_get_promo_state_v961(biz_r);
  if (got->>'has_promo') <> 'false' or (got->>'can_redeem') <> 'false' then
    raise exception 'A% failed: a razorpay firm was offered a redemption box: %', n, got; end if;
  n := n + 1;
  got := public.business_get_promo_state_v961(biz_n);
  if (got->>'can_redeem') <> 'false' then
    raise exception 'A% failed: a stripe firm with no linked subscription was offered one: %', n, got; end if;

  -- ------------------------------------------------------------------ removed while the call was in flight
  n := n + 1;
  perform public.platform_remove_promo_redemption_v961(biz_m,'suite: remove before the provider returns');
  select id into red from public.platform_promo_redemptions_v961 where business_id=biz_m;
  got := app.promo_provider_applied_v962(red, 'coupon_orphan', null);
  select * into row_r from public.platform_promo_redemptions_v961 where id=red;
  if (got->>'status') <> 'removed_in_flight' or row_r.provider_applied_at is not null
     or row_r.provider_error is null then
    raise exception 'A% failed: an orphaned provider coupon was recorded as a success', n; end if;

  -- ------------------------------------------------------------------ the executor's hands are not the browser's
  perform set_config('request.jwt.claims', jsonb_build_object('sub',owner_s,'role','authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', owner_s::text, true);
  n := n + 1;
  execute 'set local role authenticated';
  begin
    perform app.promo_provider_intent_v962(biz_s);
    execute 'reset role';
    raise exception 'A% failed: a merchant owner can read the executor intent', n;
  exception when insufficient_privilege then execute 'reset role';
  end;

  raise notice 'v962 suite: % assertions passed', n;
end
$suite$;

rollback;
