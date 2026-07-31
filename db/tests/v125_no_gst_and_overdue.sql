-- Rollback-only acceptance for Nestly V125 no-GST subscription billing.
-- Run after the complete canonical chain on a disposable database.
begin;

create or replace function pg_temp.as_v125_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',json_build_object(
    'sub',p_uid,'role',p_role
  )::text,true);
end
$$;
grant execute on function pg_temp.as_v125_user(uuid,text) to public;

do $v125$
declare
  v_owner uuid:=gen_random_uuid();
  v_outsider uuid:=gen_random_uuid();
  v_business uuid;
  v_client uuid;
  v_effective timestamptz:=now()-interval '1 second';
  v_preview jsonb;
  v_result jsonb;
  v_denied boolean:=false;
  v_count integer;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_owner,
     'authenticated','authenticated','v125-owner@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_outsider,
     'authenticated','authenticated','v125-outsider@example.test','',now(),now(),now());
  insert into public.businesses(name,slug,industry,enabled_modules)
  values('Glow Atelier V125','glow-v125-'||substr(v_owner::text,1,8),'beauty',array['dashboard'])
  returning id into v_business;
  update public.business_workspace_controls_v94
     set approval_status='approved',decided_at=now(),
       decision_reason='rollback-only V125 fixture',version=version+1,
       updated_at=now()
   where business_id=v_business;
  insert into public.staff(business_id,user_id,role,full_name,active)
  values(v_business,v_owner,'owner','Olivia Tan',true);
  insert into public.super_admins(user_id,email,note)
  values(v_owner,'v125-owner@example.test','rollback-only V125 fixture');
  insert into public.subscriptions(business_id,currency,status)
  values(v_business,'SGD','active')
  on conflict(business_id) do update set currency='SGD',status='active';

  -- Model a pre-upgrade historical row by temporarily removing only the V125
  -- boundary inside this rollback transaction. The migration assertion must
  -- abort rather than silently rewrite financial evidence.
  alter table public.subscriptions disable trigger subscriptions_no_gst_v125;
  alter table public.subscriptions drop constraint subscriptions_no_gst_v125_check;
  update public.subscriptions
     set period_subtotal_cents=118800,period_tax_cents=1,
       period_total_cents=118801,tax_behavior='exclusive'
   where business_id=v_business;
  v_denied:=false;
  begin
    perform app.assert_no_platform_billing_tax_v125();
  exception when check_violation then v_denied:=true;
  end;
  if not v_denied then
    raise exception 'historical-tax migration preflight did not abort';
  end if;
  update public.subscriptions
     set period_tax_cents=0,period_total_cents=118800
   where business_id=v_business;
  alter table public.subscriptions
    add constraint subscriptions_no_gst_v125_check
      check (coalesce(period_tax_cents,0)=0);
  alter table public.subscriptions enable trigger subscriptions_no_gst_v125;

  insert into public.clients(business_id,full_name,phone)
  values(v_business,'Mei Lin','+6590004567') returning id into v_client;

  if not exists(
    select 1 from public.platform_billing_tax_policy_v125
     where singleton and gst_registered=false
       and tax_collection_enabled=false
       and provider_price_tax_behavior='exclusive'
  ) then
    raise exception 'V125 no-GST operator policy is missing';
  end if;

  perform pg_temp.as_v125_user(v_owner);
  begin
    perform public.preview_billing_plan_catalog_v125(
      'annual','price_v125_bad_base','price_v125_bad_capacity',
      'inclusive',v_effective
    );
  exception when invalid_parameter_value then v_denied:=true;
  end;
  if not v_denied then
    raise exception 'inclusive Stripe Price proposal was accepted';
  end if;
  v_preview:=public.preview_billing_plan_catalog_v125(
    'annual','price_v125_annual_base','price_v125_annual_capacity',
    'exclusive',v_effective
  );
  perform public.confirm_billing_plan_catalog_v125(
    'annual','price_v125_annual_base','price_v125_annual_capacity',
    'exclusive',v_effective,v_preview->>'confirmation_hash',
    'rollback-only V125 annual activation'
  );
  reset role;

  insert into public.billing_provider_subscriptions(
    business_id,provider_customer_id,provider_subscription_id,status,
    cadence,cadence_months,currency,cancel_at_period_end,
    current_period_start,current_period_end,livemode,
    provider_event_created_at,provider_event_rank,last_event_id
  ) values (
    v_business,'cus_v125','sub_v125','past_due','annual',12,'SGD',false,
    '2026-08-01 00:00:00+08','2027-08-01 00:00:00+08',false,
    '2026-08-01 00:00:00+00',30,'evt_v125_subscription'
  );

  -- Stripe does not guarantee webhook ordering. An invoice arriving before the
  -- V124 terms projection must still be rejected at the platform boundary.
  begin
    insert into public.billing_provider_invoices(
      business_id,provider_customer_id,provider_subscription_id,
      provider_invoice_id,currency,status,paid_normalized,
      subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,
      amount_paid_cents,amount_remaining_cents,due_at,livemode,
      provider_event_created_at,provider_event_rank,last_event_id
    ) values (
      v_business,'cus_v125','sub_v125','in_v125_invoice_first_tax_bad',
      'SGD','open',false,118800,10692,129492,129492,0,129492,
      '2026-08-01 00:00:00+08',false,
      '2026-07-31 23:59:59+00',29,'evt_v125_invoice_first_tax_bad'
    );
    raise exception 'invoice-first non-zero GST was accepted before V124 terms';
  exception when check_violation then null;
  end;
  if exists(
    select 1 from public.billing_provider_invoices
     where provider_invoice_id='in_v125_invoice_first_tax_bad'
  ) then
    raise exception 'rejected invoice-first tax evidence remained stored';
  end if;

  insert into public.billing_subscription_terms_v124(
    business_id,provider_subscription_id,cadence,customer_capacity,
    capacity_blocks,provider_base_price_id,provider_event_created_at,last_event_id
  ) values (
    v_business,'sub_v125','annual',1000,1,'price_v125_annual_base',
    '2026-08-01 00:00:00+00','evt_v125_terms'
  );
  update public.subscriptions
     set billing_provider='stripe',billing_cadence='annual',cadence_months=12,
       provider_customer_id='cus_v125',provider_subscription_id='sub_v125',
       period_subtotal_cents=118800,period_tax_cents=0,
       period_total_cents=118800,tax_behavior='exclusive',
       payment_status='past_due',next_payment_at='2026-08-01 00:00:00+08'
   where business_id=v_business;
  insert into public.billing_provider_invoices(
    business_id,provider_customer_id,provider_subscription_id,
    provider_invoice_id,currency,status,paid_normalized,
    subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,
    amount_paid_cents,amount_remaining_cents,due_at,livemode,
    provider_event_created_at,provider_event_rank,last_event_id
  ) values (
    v_business,'cus_v125','sub_v125','in_v125_due','SGD','open',false,
    118800,0,118800,118800,0,118800,'2026-08-01 00:00:00+08',false,
    '2026-08-01 00:00:00+00',40,'evt_v125_invoice'
  );

  begin
    insert into public.billing_provider_invoices(
      business_id,provider_customer_id,provider_subscription_id,
      provider_invoice_id,currency,status,paid_normalized,
      subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,
      amount_paid_cents,amount_remaining_cents,due_at,livemode,
      provider_event_created_at,provider_event_rank,last_event_id
    ) values (
      v_business,'cus_v125','sub_v125','in_v125_tax_bad','SGD','open',false,
      118800,10692,129492,129492,0,129492,'2026-08-01 00:00:00+08',false,
      '2026-08-01 00:00:01+00',41,'evt_v125_tax_bad'
    );
    raise exception 'non-zero GST invoice was accepted';
  exception when check_violation then null;
  end;

  perform pg_temp.as_v125_user(v_owner);
  v_result:=public.get_business_billing_v125(v_business);
  if v_result#>>'{tax_policy,label}'<>'GST not charged'
     or (v_result#>>'{tax_policy,tax_cents}')::integer<>0
     or (v_result->>'period_tax_cents')::integer<>0
     or (v_result->>'period_total_cents')::integer
        <>(v_result->>'period_subtotal_cents')::integer then
    raise exception 'owner no-GST billing projection is wrong: %',v_result;
  end if;
  reset role;

  perform pg_temp.as_v125_user(v_outsider);
  begin
    perform public.get_business_billing_v125(v_business);
    raise exception 'outsider read V125 billing';
  exception when insufficient_privilege then null;
  end;
  reset role;

  perform pg_temp.as_v125_user(v_owner);
  v_result:=public.run_subscription_lifecycle_v94('2026-08-14');
  reset role;
  if exists(
    select 1 from public.business_subscription_lifecycle_v94
     where business_id=v_business and workspace_paused
  ) then
    raise exception 'owner workspace paused before day 14';
  end if;
  perform pg_temp.as_v125_user(v_owner);
  if not app.is_salon_member(v_business) then
    raise exception 'owner lost access on overdue day 13';
  end if;
  reset role;

  perform pg_temp.as_v125_user(v_owner);
  v_result:=public.run_subscription_lifecycle_v94('2026-08-15');
  reset role;
  if not exists(
    select 1 from public.business_subscription_lifecycle_v94
     where business_id=v_business and workspace_paused and overdue_day=14
  ) then
    raise exception 'owner workspace did not pause on day 14';
  end if;
  select count(*) into v_count from public.clients
   where id=v_client and business_id=v_business;
  if v_count<>1 then
    raise exception 'day-14 pause deleted customer value identity';
  end if;

  update public.billing_provider_invoices
     set status='paid',paid_normalized=true,amount_paid_cents=118800,
       amount_remaining_cents=0,paid_at='2026-08-15 01:00:00+08',
       provider_event_created_at='2026-08-15 00:00:01+00',
       provider_event_rank=100,last_event_id='evt_v125_paid'
   where provider_invoice_id='in_v125_due';
  perform pg_temp.as_v125_user(v_owner);
  v_result:=public.run_subscription_lifecycle_v94('2026-08-16');
  reset role;
  if not exists(
    select 1 from public.business_subscription_lifecycle_v94
     where business_id=v_business and state='current' and not workspace_paused
  ) then
    raise exception 'provider-paid recovery did not reopen the workspace';
  end if;
end
$v125$;

rollback;
