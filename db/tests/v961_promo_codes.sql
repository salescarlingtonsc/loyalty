-- nestly_v961 rollback suite — promo codes off a merchant's first payment.
--
-- Run inside a transaction against production and ROLLED BACK. Impersonates a real super admin
-- (public.super_admins) with the v625 Google-OAuth-shaped claims, and a real merchant owner.
--
-- The three rulings under test (2026-09-15):
--   A. the merchant redeems it themselves, and a super admin may do it for them, through ONE path;
--   B. manual firms only — a provider-billed firm is refused;
--   C. first payment only — one live redemption per business, and once consumed, no second code.
--
-- Plus the enumeration rule: a wrong code, a retired code, an expired code, a used-up code and a
-- code belonging to ANOTHER firm must be indistinguishable from each other.

\set ON_ERROR_STOP on

begin;

do $suite$
declare
  sa uuid; owner_uid uuid := gen_random_uuid(); outsider uuid := gen_random_uuid();
  biz uuid := gen_random_uuid(); biz_other uuid := gen_random_uuid(); biz_stripe uuid := gen_random_uuid();
  got jsonb; n integer := 0; sqlstate_seen text;
  promo_pct uuid; promo_amt uuid; promo_locked uuid; promo_dead uuid; promo_expired uuid; promo_capped uuid;
  red public.platform_promo_redemptions_v961%rowtype;
  cnt integer;
  errs text[] := '{}';
begin
  select user_id into sa from public.super_admins limit 1;
  if sa is null then raise exception 'A0 failed: no super admin to impersonate'; end if;

  insert into public.businesses(id,name,slug,industry,join_enabled,enabled_modules) values
    (biz,'V961 promo fixture','v961-a-'||substr(biz::text,1,8),'test',true,array['dashboard']),
    (biz_other,'V961 other firm','v961-b-'||substr(biz_other::text,1,8),'test',true,array['dashboard']),
    (biz_stripe,'V961 stripe firm','v961-c-'||substr(biz_stripe::text,1,8),'test',true,array['dashboard']);
  insert into public.subscriptions(business_id,billing_provider,status,payment_status,currency) values
    (biz,'manual','trialing','not_collected','SGD'),
    (biz_other,'manual','trialing','not_collected','SGD'),
    (biz_stripe,'stripe','active','paid','SGD');
  -- staff.user_id is FK to auth.users, so the owner needs to exist there first (rolled back).
  insert into auth.users(id,email) values
    (owner_uid,'zz-v961-owner@example.test'),
    (outsider,'zz-v961-outsider@example.test')
    on conflict (id) do nothing;
  insert into public.staff(business_id,user_id,role,active,full_name)
  values (biz,owner_uid,'owner',true,'V961 Owner');

  -- ------------------------------------------------------------------ creation is super-admin only
  perform set_config('request.jwt.claims', jsonb_build_object('sub',owner_uid,'role','authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', owner_uid::text, true);
  n := n + 1;
  begin
    perform public.platform_create_promo_code_v961('OWNER_MADE_THIS','percent',2000,null,null,null,null,null);
    raise exception 'A% failed: a merchant owner created a promo code', n;
  exception when insufficient_privilege then null; end;

  n := n + 1;
  begin
    perform public.platform_list_promo_codes_v961();
    raise exception 'A% failed: a merchant owner listed promo codes', n;
  exception when insufficient_privilege then null; end;

  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', sa, 'role', 'authenticated',
    'amr', jsonb_build_array(jsonb_build_object('method', 'oauth')),
    'app_metadata', jsonb_build_object('providers', jsonb_build_array('google')))::text, true);
  perform set_config('request.jwt.claim.sub', sa::text, true);

  -- ------------------------------------------------------------------ validation on create
  n := n + 1;
  begin
    perform public.platform_create_promo_code_v961('AB','percent',2000,null,null,null,null,null);
    raise exception 'A% failed: a 2-character code was accepted', n;
  exception when sqlstate '22023' then null; end;

  n := n + 1;
  begin
    perform public.platform_create_promo_code_v961('ABC CAFE 20','percent',2000,null,null,null,null,null);
    raise exception 'A% failed: a code with spaces was accepted', n;
  exception when sqlstate '22023' then null; end;

  n := n + 1;
  begin
    perform public.platform_create_promo_code_v961('PCT_TOO_BIG','percent',10001,null,null,null,null,null);
    raise exception 'A% failed: a percent above 100%% was accepted', n;
  exception when sqlstate '22023' then null; end;

  n := n + 1;
  begin
    perform public.platform_create_promo_code_v961('AMT_ZERO','amount',null,0,null,null,null,null);
    raise exception 'A% failed: a zero-amount code was accepted', n;
  exception when sqlstate '22023' then null; end;

  n := n + 1;
  begin
    perform public.platform_create_promo_code_v961('BACKDATED','percent',2000,null,null,null,app.sg_today()-1,null);
    raise exception 'A% failed: a code expiring in the past was accepted', n;
  exception when sqlstate '22023' then null; end;

  -- ------------------------------------------------------------------ the owner's own example
  got := public.platform_create_promo_code_v961('ABC_CAFE_20_OFF','percent',2000,null,biz,null,null,'owner example');
  promo_locked := (got->>'id')::uuid;
  n := n + 1;
  if (got->>'code_norm') <> 'ABC_CAFE_20_OFF' or (got->>'percent_bps') <> '2000'
     or (got->>'restricted_business_id') <> biz::text then
    raise exception 'A% failed: the locked code was not stored as asked: %', n, got; end if;

  -- lower case and stray spaces are the same code
  n := n + 1;
  begin
    perform public.platform_create_promo_code_v961('  abc_cafe_20_off ','percent',2000,null,null,null,null,null);
    raise exception 'A% failed: a case/whitespace variant created a second code', n;
  exception when unique_violation then null; end;

  got := public.platform_create_promo_code_v961('SAVE200','amount',null,20000,null,null,null,'$200 off');
  promo_amt := (got->>'id')::uuid;
  got := public.platform_create_promo_code_v961('OPEN20','percent',2000,null,null,null,null,null);
  promo_pct := (got->>'id')::uuid;
  got := public.platform_create_promo_code_v961('RETIRED','percent',5000,null,null,null,null,null);
  promo_dead := (got->>'id')::uuid;
  perform public.platform_set_promo_code_active_v961(promo_dead,false,'suite: retire it');
  got := public.platform_create_promo_code_v961('CAPPED1','percent',1000,null,null,1,null,null);
  promo_capped := (got->>'id')::uuid;
  got := public.platform_create_promo_code_v961('EXPIRESTODAY','percent',1000,null,null,null,app.sg_today(),null);
  promo_expired := (got->>'id')::uuid;
  -- expire it by moving the date back behind the constraint the RPC enforces
  update public.platform_promo_codes_v961 set expires_on = app.sg_today() - 1 where id = promo_expired;

  -- ------------------------------------------------------------------ the arithmetic
  n := n + 1;
  if app.promo_discount_cents_v961('percent',2000,null,14800) <> 2960 then
    raise exception 'A% failed: 20%% of $148.00 came out as %', n,
      app.promo_discount_cents_v961('percent',2000,null,14800); end if;
  n := n + 1;
  if app.promo_discount_cents_v961('amount',null,20000,14800) <> 14800 then
    raise exception 'A% failed: a $200 code took more than the $148 bill', n; end if;
  n := n + 1;
  if app.promo_discount_cents_v961('percent',2000,null,null) is not null then
    raise exception 'A% failed: a percent resolved without a list amount', n; end if;
  n := n + 1;
  if app.promo_discount_cents_v961('percent',10000,null,118800) <> 118800 then
    raise exception 'A% failed: 100%% off did not clear the bill', n; end if;

  -- ------------------------------------------------------------------ RULING B: provider-billed
  n := n + 1;
  begin
    perform public.business_redeem_promo_code_v961(biz_stripe,'OPEN20');
    raise exception 'A% failed: a stripe firm redeemed a promo code', n;
  exception when sqlstate '22023' then
    get stacked diagnostics sqlstate_seen = message_text;
    if sqlstate_seen <> 'promo_provider_billed' then
      raise exception 'A% failed: stripe firm refused with the wrong error: %', n, sqlstate_seen; end if;
  end;

  -- ------------------------------------------------------------------ the enumeration rule
  -- Every one of these must answer identically, or the box tells a merchant what exists.
  foreach got in array array[to_jsonb('NO_SUCH_CODE'::text), to_jsonb('RETIRED'::text),
                             to_jsonb('EXPIRESTODAY'::text)]
  loop
    n := n + 1;
    begin
      perform public.business_redeem_promo_code_v961(biz_other, got #>> '{}');
      raise exception 'A% failed: % was accepted', n, got;
    exception when sqlstate '22023' then
      get stacked diagnostics sqlstate_seen = message_text;
      errs := errs || sqlstate_seen;
    end;
  end loop;
  -- a code locked to ANOTHER firm, asked for by this one
  n := n + 1;
  begin
    perform public.business_redeem_promo_code_v961(biz_other,'ABC_CAFE_20_OFF');
    raise exception 'A% failed: another firm redeemed a locked code', n;
  exception when sqlstate '22023' then
    get stacked diagnostics sqlstate_seen = message_text;
    errs := errs || sqlstate_seen;
  end;
  n := n + 1;
  if (select count(distinct e) from unnest(errs) e) <> 1 or errs[1] <> 'promo_code_not_found' then
    raise exception 'A% failed: rejections are distinguishable: %', n, errs; end if;

  -- ------------------------------------------------------------------ RULING A: the merchant redeems
  perform set_config('request.jwt.claims', jsonb_build_object('sub',owner_uid,'role','authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', owner_uid::text, true);

  n := n + 1;
  begin
    perform public.business_redeem_promo_code_v961(biz_other,'OPEN20');
    raise exception 'A% failed: an owner redeemed against a business that is not theirs', n;
  exception when insufficient_privilege then null; end;

  got := public.business_redeem_promo_code_v961(biz,'abc_cafe_20_off');   -- typed in lower case
  n := n + 1;
  if (got->>'status') <> 'ok' or (got->>'percent_bps') <> '2000' then
    raise exception 'A% failed: the owner could not redeem their own voucher: %', n, got; end if;

  n := n + 1;
  select * into red from public.platform_promo_redemptions_v961 where business_id=biz and removed_at is null;
  if red.redeemed_by <> owner_uid or red.redeemed_by_super_admin then
    raise exception 'A% failed: the redemption was not attributed to the owner', n; end if;

  -- the terms are SNAPSHOTTED: retiring the code later must not un-promise it
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', sa, 'role', 'authenticated',
    'amr', jsonb_build_array(jsonb_build_object('method', 'oauth')),
    'app_metadata', jsonb_build_object('providers', jsonb_build_array('google')))::text, true);
  perform set_config('request.jwt.claim.sub', sa::text, true);
  perform public.platform_set_promo_code_active_v961(promo_locked,false,'suite: retire after redemption');
  n := n + 1;
  got := public.business_get_promo_state_v961(biz);
  if (got->>'has_promo') <> 'true' or (got->>'percent_bps') <> '2000' then
    raise exception 'A% failed: retiring the code changed a redemption already made: %', n, got; end if;

  -- ------------------------------------------------------------------ RULING C: one at a time
  n := n + 1;
  begin
    perform public.business_redeem_promo_code_v961(biz,'OPEN20');
    raise exception 'A% failed: a second code was held alongside the first', n;
  exception when sqlstate '22023' then
    get stacked diagnostics sqlstate_seen = message_text;
    if sqlstate_seen <> 'promo_already_held' then
      raise exception 'A% failed: second code refused with the wrong error: %', n, sqlstate_seen; end if;
  end;

  -- re-presenting the SAME code is idempotent, not an error
  n := n + 1;
  got := public.business_redeem_promo_code_v961(biz,'ABC_CAFE_20_OFF');
  if (got->>'status') <> 'already_redeemed' then
    raise exception 'A% failed: re-presenting the same code was not idempotent: %', n, got; end if;

  -- a super admin can swap it before the payment happens
  n := n + 1;
  perform public.platform_remove_promo_redemption_v961(biz,'suite: swap the voucher');
  if exists(select 1 from public.platform_promo_redemptions_v961 where business_id=biz and removed_at is null) then
    raise exception 'A% failed: the pending redemption was not removed', n; end if;
  n := n + 1;
  if (select redeemed_count from public.platform_promo_codes_v961 where id=promo_locked) <> 0 then
    raise exception 'A% failed: removing a redemption did not return the allowance', n; end if;

  -- the super admin applies one on the merchant's behalf — same path
  got := public.business_redeem_promo_code_v961(biz,'SAVE200');
  n := n + 1;
  select * into red from public.platform_promo_redemptions_v961 where business_id=biz and removed_at is null;
  if not red.redeemed_by_super_admin or red.amount_cents <> 20000 then
    raise exception 'A% failed: the super-admin application did not record correctly', n; end if;

  -- ------------------------------------------------------------------ a capped code runs out
  perform public.business_redeem_promo_code_v961(biz_other,'CAPPED1');
  n := n + 1;
  if (select redeemed_count from public.platform_promo_codes_v961 where id=promo_capped) <> 1 then
    raise exception 'A% failed: the cap counter did not move', n; end if;

  -- ------------------------------------------------------------------ consuming it
  n := n + 1;
  perform app.promo_consume_v961(biz, 14800, 'SUITE-REF-1');
  select * into red from public.platform_promo_redemptions_v961 where business_id=biz and removed_at is null;
  if red.consumed_at is null or red.consumed_list_cents <> 14800
     or red.consumed_discount_cents <> 14800 then   -- $200 code, capped at the $148 bill
    raise exception 'A% failed: consumption recorded %/% ', n, red.consumed_list_cents, red.consumed_discount_cents; end if;

  n := n + 1;
  if red.consumed_payment_reference <> 'SUITE-REF-1' then
    raise exception 'A% failed: the payment reference was not stamped on', n; end if;

  -- consuming twice does nothing the second time
  n := n + 1;
  perform app.promo_consume_v961(biz, 99900, 'SUITE-REF-2');
  select * into red from public.platform_promo_redemptions_v961 where business_id=biz and removed_at is null;
  if red.consumed_payment_reference <> 'SUITE-REF-1' then
    raise exception 'A% failed: a consumed redemption was consumed again', n; end if;

  -- and once used, that business has had its promo
  n := n + 1;
  begin
    perform public.business_redeem_promo_code_v961(biz,'OPEN20');
    raise exception 'A% failed: a business redeemed a second code after using one', n;
  exception when sqlstate '22023' then
    get stacked diagnostics sqlstate_seen = message_text;
    if sqlstate_seen <> 'promo_already_used' then
      raise exception 'A% failed: wrong error after a used promo: %', n, sqlstate_seen; end if;
  end;

  n := n + 1;
  begin
    perform public.platform_remove_promo_redemption_v961(biz,'suite: try to remove history');
    raise exception 'A% failed: a consumed redemption was removed', n;
  exception when sqlstate '22023' then null; end;

  -- ------------------------------------------------------------------ audit
  n := n + 1;
  if (select count(distinct action) from public.audit_log
       where business_id in (biz,biz_other)
         and action in ('promo_code_redeemed','promo_code_consumed','promo_redemption_removed')) <> 3 then
    raise exception 'A% failed: the promo lifecycle is not fully audited', n; end if;

  -- ------------------------------------------------------------------ an outsider sees nothing
  perform set_config('request.jwt.claims', jsonb_build_object('sub',outsider,'role','authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', outsider::text, true);
  n := n + 1;
  begin
    perform public.business_get_promo_state_v961(biz);
    raise exception 'A% failed: an outsider read a business promo state', n;
  exception when insufficient_privilege then null; end;
  /* RLS is never enforced for the table OWNER, which is who a DO block runs as, so these last
     probes drop to the role a real request arrives on. Without this they pass on an unprotected
     table — the first draft of this suite did exactly that. */
  n := n + 1;
  execute 'set local role authenticated';
  select count(*) into cnt from public.platform_promo_redemptions_v961;
  execute 'reset role';
  if cnt <> 0 then
    raise exception 'A% failed: an outsider can read % redemptions', n, cnt; end if;

  -- ...and the merchant's own owner sees their redemption but never the code table.
  perform set_config('request.jwt.claims', jsonb_build_object('sub',owner_uid,'role','authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', owner_uid::text, true);
  n := n + 1;
  execute 'set local role authenticated';
  select count(*) into cnt from public.platform_promo_codes_v961;
  execute 'reset role';
  if cnt <> 0 then
    raise exception 'A% failed: a merchant owner can read % promo codes', n, cnt; end if;

  /* The owner reads their promo through the RPC, which is the real path and the one that must work
     for a trialing firm awaiting its first payment (app.is_salon_member would not — it demands an
     operational workspace, which such a firm is not). */
  n := n + 1;
  got := public.business_get_promo_state_v961(biz);
  if (got->>'has_promo') <> 'true' or (got->>'amount_cents') <> '20000'
     or (got->>'consumed_at') is null then
    raise exception 'A% failed: the owner cannot read back their own consumed promo: %', n, got; end if;

  -- ...but not another firm's.
  n := n + 1;
  begin
    perform public.business_get_promo_state_v961(biz_other);
    raise exception 'A% failed: an owner read another firm''s promo state', n;
  exception when insufficient_privilege then null; end;

  raise notice 'v961 suite: % assertions passed', n;
end
$suite$;

rollback;
