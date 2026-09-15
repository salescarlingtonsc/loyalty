-- nestly_v966 rollback suite — a spent voucher can be closed out, and only a spent one.
\set ON_ERROR_STOP on
begin;
do $suite$
declare
  sa uuid; owner_a uuid := gen_random_uuid();
  biz uuid := gen_random_uuid();
  got jsonb; red uuid; n integer := 0; seen text;
  promo_a uuid; promo_b uuid; cnt integer;
  row_r public.platform_promo_redemptions_v961%rowtype;
begin
  select user_id into sa from public.super_admins limit 1;
  if sa is null then raise exception 'A0 failed: no super admin'; end if;
  insert into auth.users(id,email) values (owner_a,'zz-v966@example.test') on conflict (id) do nothing;
  insert into public.businesses(id,name,slug,industry,join_enabled,enabled_modules) values
    (biz,'V966 firm','v966-'||substr(biz::text,1,8),'test',true,array['dashboard']);
  insert into public.subscriptions(business_id,billing_provider,status,payment_status,currency) values
    (biz,'manual','active','paid','SGD');
  insert into public.staff(business_id,user_id,role,active,full_name) values (biz,owner_a,'owner',true,'V966 Owner');
  perform set_config('request.jwt.claims', jsonb_build_object('sub',sa,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text,true);
  perform set_config('request.jwt.claim.sub', sa::text, true);

  got := public.platform_create_promo_code_v961('V966FIRST','percent',2000,null,null,null,null,'suite');
  promo_a := (got->>'id')::uuid;
  got := public.platform_create_promo_code_v961('V966SECOND','amount',null,500,null,null,null,'suite');
  promo_b := (got->>'id')::uuid;

  got := public.business_redeem_promo_code_v961(biz,'V966FIRST');
  red := (got->>'redemption_id')::uuid;

  -- (1) an UNSPENT redemption cannot be released — remove is the verb for that one
  n := n + 1;
  begin
    perform public.platform_release_promo_redemption_v966(biz,'suite reason');
    raise exception 'A% failed: released a promo that was never used', n;
  exception when sqlstate '22023' then
    get stacked diagnostics seen = message_text;
    if seen <> 'promo_not_used_yet' then
      raise exception 'A% failed: refused with %, expected promo_not_used_yet', n, seen; end if;
  end;

  -- spend it
  perform app.promo_consume_v961(biz, 14800, 'pay_v966_first');
  n := n + 1;
  select * into row_r from public.platform_promo_redemptions_v961 where id = red;
  if row_r.consumed_at is null then raise exception 'A% failed: the fixture promo never consumed', n; end if;

  -- (2) the trap this closes: no new code while the spent one is still the firm current promo
  n := n + 1;
  begin
    perform public.business_redeem_promo_code_v961(biz,'V966SECOND');
    raise exception 'A% failed: a second code was taken without a release', n;
  exception when sqlstate '22023' then
    get stacked diagnostics seen = message_text;
    if seen <> 'promo_already_used' then
      raise exception 'A% failed: refused with %, expected promo_already_used', n, seen; end if;
  end;

  -- (3) release needs a reason
  n := n + 1;
  begin
    perform public.platform_release_promo_redemption_v966(biz,'x');
    raise exception 'A% failed: released with a 1-character reason', n;
  exception when sqlstate '22023' then
    get stacked diagnostics seen = message_text;
    if seen <> 'promo_reason_required' then
      raise exception 'A% failed: refused with %, expected promo_reason_required', n, seen; end if;
  end;

  -- (4) release is super-admin only
  n := n + 1;
  perform set_config('request.jwt.claims', jsonb_build_object('sub',owner_a,'role','authenticated')::text,true);
  perform set_config('request.jwt.claim.sub', owner_a::text, true);
  begin
    perform public.platform_release_promo_redemption_v966(biz,'owner should not be able to');
    raise exception 'A% failed: a business OWNER released their own spent promo', n;
  exception when sqlstate '42501' then null; end;
  perform set_config('request.jwt.claims', jsonb_build_object('sub',sa,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text,true);
  perform set_config('request.jwt.claim.sub', sa::text, true);

  -- (5) remove still refuses a spent redemption — v961's history guard is untouched
  n := n + 1;
  begin
    perform public.platform_remove_promo_redemption_v961(biz,'should not delete history');
    raise exception 'A% failed: remove deleted a consumed redemption', n;
  exception when sqlstate '22023' then
    get stacked diagnostics seen = message_text;
    if seen <> 'promo_already_used' then
      raise exception 'A% failed: remove refused with %, expected promo_already_used', n, seen; end if;
  end;

  -- (6) the release itself
  n := n + 1;
  select redeemed_count into cnt from public.platform_promo_codes_v961 where id = promo_a;
  got := public.platform_release_promo_redemption_v966(biz,'goodwill voucher for the new year');
  if (got->>'status') <> 'ok' then raise exception 'A% failed: release did not return ok', n; end if;

  -- (7) history is intact and the code keeps its count — release is not remove
  n := n + 1;
  select * into row_r from public.platform_promo_redemptions_v961 where id = red;
  if row_r.released_at is null or row_r.released_by <> sa
     or row_r.removed_at is not null or row_r.consumed_at is null
     or row_r.consumed_payment_reference <> 'pay_v966_first' then
    raise exception 'A% failed: release damaged the redemption record', n; end if;
  n := n + 1;
  if (select redeemed_count from public.platform_promo_codes_v961 where id = promo_a) <> cnt then
    raise exception 'A% failed: release changed redeemed_count (it is not a removal)', n; end if;

  -- (8) the firm is no longer holding anything
  n := n + 1;
  got := public.business_get_promo_state_v961(biz);
  if (got ? 'redemption_id') and (got->>'redemption_id') is not null then
    raise exception 'A% failed: a released promo is still the firm current promo: %', n, got; end if;

  -- (9) and THAT is the point — a new code is now accepted
  n := n + 1;
  got := public.business_redeem_promo_code_v961(biz,'V966SECOND');
  if (got->>'status') <> 'ok' then
    raise exception 'A% failed: a new code was refused after release: %', n, got; end if;
  n := n + 1;
  if (got->>'discount_kind') <> 'amount' or (got->>'amount_cents') <> '500' then
    raise exception 'A% failed: the new redemption carries the wrong discount: %', n, got; end if;

  -- (10) releasing is not repeatable against the row it already released
  n := n + 1;
  begin
    perform public.platform_release_promo_redemption_v966(biz,'second release attempt');
    raise exception 'A% failed: released the fresh unspent redemption', n;
  exception when sqlstate '22023' then
    get stacked diagnostics seen = message_text;
    if seen <> 'promo_not_used_yet' then
      raise exception 'A% failed: refused with %, expected promo_not_used_yet', n, seen; end if;
  end;

  -- (11) the console count separates what is held now from what was ever spent
  n := n + 1;
  select (c->>'live_redemptions')::integer into cnt
    from jsonb_array_elements(public.platform_list_promo_codes_v961()->'items') c
   where coalesce(c->>'code_norm', c->>'code') = 'V966FIRST';
  if cnt <> 0 then
    raise exception 'A% failed: a released redemption still counts as live (%)', n, cnt; end if;
  n := n + 1;
  select (c->>'consumed_redemptions')::integer into cnt
    from jsonb_array_elements(public.platform_list_promo_codes_v961()->'items') c
   where coalesce(c->>'code_norm', c->>'code') = 'V966FIRST';
  if cnt <> 1 then
    raise exception 'A% failed: a released redemption lost its consumed history (%)', n, cnt; end if;

  -- (12) nothing to release once the firm holds only a fresh code and it is removed
  n := n + 1;
  perform public.platform_remove_promo_redemption_v961(biz,'clearing the fresh one');
  begin
    perform public.platform_release_promo_redemption_v966(biz,'nothing left to release');
    raise exception 'A% failed: released with no current redemption', n;
  exception when sqlstate '42704' then
    get stacked diagnostics seen = message_text;
    if seen <> 'no_promo_to_release' then
      raise exception 'A% failed: refused with %, expected no_promo_to_release', n, seen; end if;
  end;

  raise notice 'v966 suite: % assertions passed', n;
end
$suite$;
rollback;
