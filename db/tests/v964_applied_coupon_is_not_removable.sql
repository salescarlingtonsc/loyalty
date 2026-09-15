-- nestly_v964 rollback suite — a coupon live at Stripe is not forgettable here.
\set ON_ERROR_STOP on
begin;
do $suite$
declare
  sa uuid; owner_s uuid := gen_random_uuid(); biz uuid := gen_random_uuid();
  got jsonb; red uuid; n integer := 0; seen text;
begin
  select user_id into sa from public.super_admins limit 1;
  if sa is null then raise exception 'A0 failed: no super admin'; end if;
  insert into auth.users(id,email) values (owner_s,'zz-v964@example.test') on conflict (id) do nothing;
  insert into public.businesses(id,name,slug,industry,join_enabled,enabled_modules)
  values (biz,'V964 fixture','v964-'||substr(biz::text,1,8),'test',true,array['dashboard']);
  insert into public.subscriptions(business_id,billing_provider,status,payment_status,currency,provider_subscription_id)
  values (biz,'stripe','active','paid','SGD','sub_v964fixture');
  insert into public.staff(business_id,user_id,role,active,full_name) values (biz,owner_s,'owner',true,'V964 Owner');
  perform set_config('request.jwt.claims', jsonb_build_object('sub',sa,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text,true);
  perform set_config('request.jwt.claim.sub', sa::text, true);

  perform public.platform_create_promo_code_v961('V964PCT','percent',1000,null,biz,null,null,'suite');
  got := public.business_redeem_promo_code_v961(biz,'V964PCT');
  red := (got->>'redemption_id')::uuid;

  -- not yet at Stripe: still removable, which is the case the button exists for
  n := n + 1;
  got := public.platform_remove_promo_redemption_v961(biz,'suite: still removable before Stripe');
  if (got->>'status') <> 'ok' then
    raise exception 'A% failed: a promo that never reached Stripe was not removable', n; end if;

  -- redeem again and mark it live at the provider
  got := public.business_redeem_promo_code_v961(biz,'V964PCT');
  red := (got->>'redemption_id')::uuid;
  perform public.promo_provider_applied_v962(red,'coupon_v964',null);

  n := n + 1;
  begin
    perform public.platform_remove_promo_redemption_v961(biz,'suite: try to forget a live coupon');
    raise exception 'A% failed: a coupon live at Stripe was removed here', n;
  exception when sqlstate '22023' then
    get stacked diagnostics seen = message_text;
    if seen <> 'promo_live_at_provider' then
      raise exception 'A% failed: refused with %, expected promo_live_at_provider', n, seen; end if;
  end;

  n := n + 1;
  if (select removed_at from public.platform_promo_redemptions_v961 where id=red) is not null then
    raise exception 'A% failed: the refusal still removed the row', n; end if;

  raise notice 'v964 suite: % assertions passed', n;
end
$suite$;
rollback;
