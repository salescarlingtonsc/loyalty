-- nestly_v965 rollback suite — the three holes the adversarial probe found stay closed.
\set ON_ERROR_STOP on
begin;
do $suite$
declare
  sa uuid; owner_a uuid := gen_random_uuid();
  biz uuid := gen_random_uuid(); biz_dead uuid := gen_random_uuid();
  got jsonb; red uuid; n integer := 0; seen text; inv uuid := gen_random_uuid();
  row_r public.platform_promo_redemptions_v961%rowtype; promo uuid;
begin
  select user_id into sa from public.super_admins limit 1;
  if sa is null then raise exception 'A0 failed: no super admin'; end if;
  insert into auth.users(id,email) values (owner_a,'zz-v965@example.test') on conflict (id) do nothing;
  insert into public.businesses(id,name,slug,industry,join_enabled,enabled_modules) values
    (biz,'V965 live','v965-a-'||substr(biz::text,1,8),'test',true,array['dashboard']),
    (biz_dead,'V965 dead','v965-d-'||substr(biz_dead::text,1,8),'test',true,array['dashboard']);
  insert into public.subscriptions(business_id,billing_provider,status,payment_status,currency,provider_subscription_id) values
    (biz,'stripe','active','paid','SGD','sub_v965'),
    (biz_dead,'stripe','canceled','paid','SGD','sub_v965_dead');
  insert into public.staff(business_id,user_id,role,active,full_name) values (biz,owner_a,'owner',true,'V965 Owner');
  perform set_config('request.jwt.claims', jsonb_build_object('sub',sa,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text,true);
  perform set_config('request.jwt.claim.sub', sa::text, true);

  got := public.platform_create_promo_code_v961('V965PCT','percent',1500,null,null,null,null,'suite');
  promo := (got->>'id')::uuid;

  -- (2) a subscription that cannot be charged is refused
  n := n + 1;
  begin
    perform public.business_redeem_promo_code_v961(biz_dead,'V965PCT');
    raise exception 'A% failed: a CANCELED stripe subscription accepted a promo code', n;
  exception when sqlstate '22023' then
    get stacked diagnostics seen = message_text;
    if seen <> 'promo_subscription_not_chargeable' then
      raise exception 'A% failed: refused with %, expected promo_subscription_not_chargeable', n, seen; end if;
  end;

  -- a live one still works
  n := n + 1;
  got := public.business_redeem_promo_code_v961(biz,'V965PCT');
  if (got->>'status') <> 'ok' then raise exception 'A% failed: a chargeable stripe firm was refused', n; end if;
  red := (got->>'redemption_id')::uuid;

  -- (3) the code cannot be deleted once it has been used
  n := n + 1;
  begin
    delete from public.platform_promo_codes_v961 where id = promo;
    raise exception 'A% failed: a code with a redemption was deleted, taking the history with it', n;
  exception when foreign_key_violation then null; end;

  -- (1) the consumption sweep
  perform public.promo_provider_applied_v962(red,'coupon_v965',null);
  n := n + 1;
  perform app.consume_provider_promos_v965(50);
  if (select consumed_at from public.platform_promo_redemptions_v961 where id=red) is not null then
    raise exception 'A% failed: consumed with no paid invoice to consume against', n; end if;

  -- an invoice paid BEFORE the coupon went on must not count
  insert into public.billing_provider_invoices(id,business_id,provider_customer_id,provider_invoice_id,currency,status,paid_normalized,subtotal_ex_tax_cents,tax_cents,net_cash_ex_tax_cents,total_cents,amount_due_cents,amount_paid_cents,amount_remaining_cents,livemode,provider_event_created_at,provider_event_rank,last_event_id,paid_at)
  values (inv,biz,'cus_v965','in_v965_before','SGD','paid',true,14800,0,14800,14800,14800,14800,0,false,now() - interval '10 days',1,'evt_in_v965_before',now() - interval '10 days');
  n := n + 1;
  perform app.consume_provider_promos_v965(50);
  if (select consumed_at from public.platform_promo_redemptions_v961 where id=red) is not null then
    raise exception 'A% failed: an invoice paid BEFORE the coupon consumed the promo', n; end if;

  -- one paid after does
  insert into public.billing_provider_invoices(id,business_id,provider_customer_id,provider_invoice_id,currency,status,paid_normalized,subtotal_ex_tax_cents,tax_cents,net_cash_ex_tax_cents,total_cents,amount_due_cents,amount_paid_cents,amount_remaining_cents,livemode,provider_event_created_at,provider_event_rank,last_event_id,paid_at)
  values (gen_random_uuid(),biz,'cus_v965','in_v965_after','SGD','paid',true,14800,0,14800,14800,14800,14800,0,false,now() + interval '1 minute',1,'evt_in_v965_after',now() + interval '1 minute');
  n := n + 1;
  perform app.consume_provider_promos_v965(50);
  select * into row_r from public.platform_promo_redemptions_v961 where id=red;
  if row_r.consumed_at is null or row_r.consumed_payment_reference <> 'in_v965_after' then
    raise exception 'A% failed: a paid invoice after the coupon did not consume the promo', n; end if;
  n := n + 1;
  if row_r.consumed_discount_cents <> 2220 then   -- 15% of $148.00
    raise exception 'A% failed: consumed discount is % not 2220', n, row_r.consumed_discount_cents; end if;

  -- and the firm can be given a NEW code afterwards, which was the whole trap
  n := n + 1;
  begin
    perform public.business_redeem_promo_code_v961(biz,'V965PCT');
    raise exception 'A% failed: the SAME code was redeemable twice', n;
  exception when sqlstate '22023' then
    get stacked diagnostics seen = message_text;
    if seen <> 'promo_already_used' then
      raise exception 'A% failed: refused with %, expected promo_already_used', n, seen; end if;
  end;

  -- the sweep is idempotent
  n := n + 1;
  if (app.consume_provider_promos_v965(50)->>'consumed') <> '0' then
    raise exception 'A% failed: the sweep consumed an already-consumed promo again', n; end if;

  raise notice 'v965 suite: % assertions passed', n;
end
$suite$;
rollback;
