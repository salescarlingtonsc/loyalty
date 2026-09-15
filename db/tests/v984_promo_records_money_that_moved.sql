-- nestly_v984 rollback suite — the promo record equals the money that actually moved.
\set ON_ERROR_STOP on
begin;
do $suite$
declare
  sa1 uuid; sa2 uuid; c1 text; c2 text;
  today date := (now() at time zone 'Asia/Singapore')::date;
  biz uuid; red uuid; inv uuid; pay uuid; ev text; got jsonb;
  kinds text[] := array['exact','none','larger'];
  kind text;
  r public.platform_promo_redemptions_v961%rowtype;
  d public.platform_subscription_documents_v156%rowtype;

begin
  select user_id into sa1 from public.super_admins order by user_id limit 1;
  select user_id into sa2 from public.super_admins where user_id <> sa1 order by user_id limit 1;
  if sa2 is null then raise exception 'A0 failed: v984 needs two super admins'; end if;
  c1 := jsonb_build_object('sub',sa1,'role','authenticated','amr',jsonb_build_array(jsonb_build_object('method','oauth')),
        'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text;
  c2 := jsonb_build_object('sub',sa2,'role','authenticated','amr',jsonb_build_array(jsonb_build_object('method','oauth')),
        'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text;
  perform set_config('request.jwt.claims', c1, true);
  perform set_config('request.jwt.claim.sub', sa1::text, true);
  perform public.platform_create_promo_code_v961('V984PCT','percent',2000,null,null,null,null,'suite');

  -- one manual firm, invoiced once, with the discount the case under test needs
  foreach kind in array kinds loop
    biz := gen_random_uuid();
    insert into public.businesses(id,name,slug,industry,join_enabled,enabled_modules)
      values (biz,'V984 '||kind,'v984-'||substr(biz::text,1,8),'test',true,array['dashboard']);
    insert into public.subscriptions(business_id,billing_provider,status,payment_status,currency)
      values (biz,'manual','active','paid','SGD');
    insert into public.platform_billing_contacts_v156(business_id,business_display_name,legal_entity_name,
      billing_address,contact_name,email,recipient_role,created_by,updated_by)
      values (biz,'V984','V984 PTE. LTD.',jsonb_build_object('line1','1 Rd'),'Billing Person',
              'zz-v984-'||substr(biz::text,1,8)||'@example.test','primary',sa1,sa1);

    perform set_config('request.jwt.claims', c1, true);
    perform set_config('request.jwt.claim.sub', sa1::text, true);
    got := public.business_redeem_promo_code_v961(biz,'V984PCT');
    red := (got->>'redemption_id')::uuid;
    got := public.platform_create_manual_invoice_v156(biz,today,today,today,today+365,
      jsonb_build_array(jsonb_build_object('description','Peekaa subscription','quantity',1,'unit_amount_cents',118800)),
      case kind when 'exact' then 23760 when 'none' then 0 else 50000 end,
      gen_random_uuid());
    inv := (got->'document'->>'id')::uuid;
    select * into d from public.platform_subscription_documents_v156 where id=inv;
    ev := 'platform-subscriptions/manual-evidence/'||biz||'/'||inv||'/'||gen_random_uuid()||'.pdf';
    insert into storage.objects(bucket_id,name) values ('sme-private',ev);
    got := public.platform_record_manual_payment_v156(inv,d.balance_due_cents,'PAY-'||kind,today,'6357',ev,gen_random_uuid());
    pay := (got->'payment'->>'id')::uuid;
    perform set_config('request.jwt.claims', c2, true);
    perform set_config('request.jwt.claim.sub', sa2::text, true);
    perform public.platform_verify_manual_payment_v156(pay,'verified',null,gen_random_uuid());
    select * into r from public.platform_promo_redemptions_v961 where id=red;

    if kind = 'none' then
      -- the invoice gave nothing away, so the voucher must survive
      if r.consumed_at is not null then
        raise exception 'A(none) failed: a zero-discount invoice spent the voucher (recorded %)', r.consumed_discount_cents; end if;
    else
      if r.consumed_at is null then
        raise exception 'A(%) failed: a discounted invoice did not spend the voucher', kind; end if;
      if r.consumed_discount_cents is distinct from d.discount_cents then
        raise exception 'A(%) failed: recorded discount % but the invoice gave %',
          kind, r.consumed_discount_cents, d.discount_cents; end if;
      if r.consumed_list_cents is distinct from d.subtotal_cents then
        raise exception 'A(%) failed: recorded list % but the invoice subtotal was %',
          kind, r.consumed_list_cents, d.subtotal_cents; end if;
      -- and the books reconcile: list - discount = what the merchant was billed
      if r.consumed_list_cents - r.consumed_discount_cents <> d.total_cents then
        raise exception 'A(%) failed: list % less discount % does not equal the % billed',
          kind, r.consumed_list_cents, r.consumed_discount_cents, d.total_cents; end if;
    end if;
  end loop;

  -- the provider sweep records no figure it did not observe
  declare
    bizp uuid := gen_random_uuid(); redp uuid;
  begin
    perform set_config('request.jwt.claims', c1, true);
    perform set_config('request.jwt.claim.sub', sa1::text, true);
    insert into public.businesses(id,name,slug,industry,join_enabled,enabled_modules)
      values (bizp,'V984 stripe','v984-s-'||substr(bizp::text,1,8),'test',true,array['dashboard']);
    insert into public.subscriptions(business_id,billing_provider,status,payment_status,currency,provider_subscription_id)
      values (bizp,'stripe','active','paid','SGD','sub_v984');
    got := public.business_redeem_promo_code_v961(bizp,'V984PCT');
    redp := (got->>'redemption_id')::uuid;
    perform public.promo_provider_applied_v962(redp,'coupon_v984',null);
    insert into public.billing_provider_invoices(id,business_id,provider_customer_id,provider_invoice_id,
      currency,status,paid_normalized,subtotal_ex_tax_cents,tax_cents,net_cash_ex_tax_cents,total_cents,
      amount_due_cents,amount_paid_cents,amount_remaining_cents,livemode,provider_event_created_at,
      provider_event_rank,last_event_id,paid_at)
    values (gen_random_uuid(),bizp,'cus_v984','in_v984','SGD','paid',true,11880,0,11880,11880,11880,11880,0,
      false,now()+interval '1 minute',1,'evt_v984',now()+interval '1 minute');
    perform app.consume_provider_promos_v965(50);
    select * into r from public.platform_promo_redemptions_v961 where id=redp;
    if r.consumed_at is null then
      raise exception 'A(stripe) failed: the provider sweep stopped consuming'; end if;
    if r.consumed_discount_cents is not null or r.consumed_list_cents is not null then
      raise exception 'A(stripe) failed: recorded list % / discount % it never observed',
        r.consumed_list_cents, r.consumed_discount_cents; end if;
  end;

  -- and the recomputing consumer is gone for good
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='app' and p.proname='promo_consume_v961') then
    raise exception 'A(drop) failed: app.promo_consume_v961 still exists'; end if;

  raise notice 'v984 suite: every recorded figure equals the money that moved';
end
$suite$;
rollback;
