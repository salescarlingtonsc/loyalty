-- Rollback-only acceptance for Nestly V124 Stripe launch pricing.
-- Run after the complete canonical chain on a disposable database.
begin;

create or replace function pg_temp.as_v124_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,
    true
  );
end
$$;
grant execute on function pg_temp.as_v124_user(uuid,text) to public;

do $v124_test$
declare
  v_owner uuid:=gen_random_uuid();
  v_outsider uuid:=gen_random_uuid();
  v_business uuid;
  v_projection_business uuid;
  v_effective timestamptz:=now()-interval '1 second';
  v_preview jsonb;
  v_result jsonb;
  v_command jsonb;
  v_key uuid:=gen_random_uuid();
  v_denied boolean:=false;
  v_conflict boolean:=false;
begin
  if (select count(*) from app.customer_legal_documents d
       where d.active and d.document_version='2026-08-01' and (
         (d.document_key='terms' and d.document_sha256='e581bbd1f20e9b8b1958f75f100950c50d20a9810d82fce8467b1ed74859643f')
         or (d.document_key='privacy' and d.document_sha256='08ee39b8c678552699cf2438b7c0803a5ee441b6426ddee3418e88f04a29ba84')
       ))<>2 then
    raise exception 'V124 live legal manifest does not match the shipped pages';
  end if;
  if pg_get_functiondef('public.customer_get_platform_marketing_preference()'::regprocedure)
       not like '%994400cadc703134d9c8bd3868fe054f94e37153c47c2d2e688064bdc75138c9%'
     or pg_get_functiondef('public.customer_get_platform_marketing_preference()'::regprocedure)
       not like '%08ee39b8c678552699cf2438b7c0803a5ee441b6426ddee3418e88f04a29ba84%' then
    raise exception 'V124 did not preserve prior marketing consent while binding new choices';
  end if;

  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_owner,
     'authenticated','authenticated','v124-owner@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_outsider,
     'authenticated','authenticated','v124-outsider@example.test','',now(),now(),now());
  insert into public.businesses(name,slug,industry,enabled_modules)
  values('Glow Atelier V124','glow-v124-'||substr(v_owner::text,1,8),'beauty',array['dashboard'])
  returning id into v_business;
  insert into public.businesses(name,slug,industry,enabled_modules)
  values('Projection V124','projection-v124-'||substr(v_owner::text,1,8),'beauty',array['dashboard'])
  returning id into v_projection_business;
  insert into public.staff(business_id,user_id,role,full_name,active)
  values(v_business,v_owner,'owner','Olivia Tan',true);
  insert into public.staff(business_id,user_id,role,full_name,active)
  values
    (v_business,null,'manager','Maya Lim',true),
    (v_business,null,'frontdesk','Farah Noor',true),
    (v_business,null,'staff','Chen Wei',true),
    (v_business,null,'staff','Aisha Rahman',true);
  insert into public.super_admins(user_id,email,note)
  values(v_owner,'v124-owner@example.test','rollback-only V124 fixture');
  insert into public.subscriptions(business_id,currency,status)
  values(v_business,'SGD','active'),(v_projection_business,'SGD','active')
  on conflict(business_id) do update set currency='SGD',status='active';

  perform pg_temp.as_v124_user(v_outsider);
  begin
    perform public.preview_billing_plan_catalog_v124(
      'annual','price_v124_annual_base','price_v124_annual_capacity',
      'exclusive',v_effective
    );
  exception when insufficient_privilege then v_denied:=true;
  end;
  reset role;
  if not v_denied then raise exception 'non-super-admin preview was accepted'; end if;

  perform pg_temp.as_v124_user(v_owner);
  v_preview:=public.preview_billing_plan_catalog_v124(
    'annual','price_v124_annual_base','price_v124_annual_capacity',
    'exclusive',v_effective
  );
  if (v_preview->>'base_amount_cents')::integer<>118800
     or (v_preview->>'capacity_block_amount_cents')::integer<>12000
     or (v_preview->>'compare_at_monthly_cents')::integer<>16800 then
    raise exception 'annual V124 preview arithmetic is not exact';
  end if;
  v_result:=public.confirm_billing_plan_catalog_v124(
    'annual','price_v124_annual_base','price_v124_annual_capacity',
    'exclusive',v_effective,v_preview->>'confirmation_hash',
    'rollback-only annual V124 activation'
  );
  v_preview:=public.preview_billing_plan_catalog_v124(
    'monthly','price_v124_monthly_base','price_v124_monthly_capacity',
    'exclusive',v_effective
  );
  if (v_preview->>'base_amount_cents')::integer<>14900
     or (v_preview->>'capacity_block_amount_cents')::integer<>1000 then
    raise exception 'monthly V124 preview arithmetic is not exact';
  end if;
  perform public.confirm_billing_plan_catalog_v124(
    'monthly','price_v124_monthly_base','price_v124_monthly_capacity',
    'exclusive',v_effective,v_preview->>'confirmation_hash',
    'rollback-only monthly V124 activation'
  );

  v_command:=public.request_billing_command_v124(
    v_business,'create_checkout','annual',3000,v_key
  );
  -- Exact replay returns the same durable command.
  if (public.request_billing_command_v124(
        v_business,'create_checkout','annual',3000,v_key
      )->>'command_id')<>v_command->>'command_id' then
    raise exception 'exact V124 request did not replay';
  end if;
  begin
    perform public.request_billing_command_v124(
      v_business,'create_checkout','annual',4000,v_key
    );
  exception when invalid_parameter_value then v_conflict:=true;
  end;
  reset role;
  if not v_conflict then raise exception 'edited V124 replay was accepted'; end if;

  -- A later catalogue rollover must not change provider price IDs already
  -- snapshotted by this durable command and Stripe idempotency key.
  update public.billing_plan_catalog_v124
     set active=false,effective_to=now()
   where cadence='annual' and active and effective_to is null;
  insert into public.billing_plan_catalog_v124(
    currency,cadence,cadence_months,provider_base_price_id,
    provider_capacity_price_id,base_amount_cents,
    capacity_block_amount_cents,tax_behavior,effective_from,created_by
  ) values (
    'SGD','annual',12,'price_v124_annual_base_rollover',
    'price_v124_annual_capacity_rollover',118800,12000,
    'exclusive',now(),v_owner
  );

  perform pg_temp.as_v124_user(null,'service_role');
  v_result:=public.claim_billing_command_v124((v_command->>'command_id')::uuid,v_owner);
  reset role;
  if v_result->>'provider_idempotency_key'
       <> 'nestly:v124:billing-command:'||(v_command->>'command_id')
     or v_result->>'provider_base_price_id'<>'price_v124_annual_base'
     or v_result->>'provider_capacity_price_id'<>'price_v124_annual_capacity'
     or (v_result->>'extra_capacity_blocks')::integer<>2
     or (v_result->>'requested_customer_capacity')::integer<>3000
     or (v_result->>'current_customer_count')::integer<>0 then
    raise exception 'V124 command claim returned incorrect Stripe instructions';
  end if;
  if (select count(*) from public.staff where business_id=v_business)<>5 then
    raise exception 'staff fixture was not preserved';
  end if;

  if not exists(
    select 1 from public.audit_log
     where action='billing.v124_catalog_confirmed'
       and entity='billing_plan_catalog_v124'
  ) then
    raise exception 'V124 catalogue activation was not audited';
  end if;

  -- Provider item truth classifies V124 prices and projects three blocks.
  insert into public.billing_provider_subscriptions(
    business_id,provider_customer_id,provider_subscription_id,status,
    cadence,cadence_months,currency,cancel_at_period_end,livemode,
    provider_event_created_at,provider_event_rank,last_event_id
  ) values (
    v_projection_business,'cus_v124_projection','sub_v124_projection','active',
    'monthly',1,'SGD',false,false,'2026-08-01 04:00:00+00',30,'evt_v124_projection'
  );
  insert into public.billing_provider_subscription_items(
    provider_subscription_id,provider_item_id,item_role,provider_price_id,
    quantity,unit_amount_cents,currency,interval_name,interval_count,
    provider_event_created_at,provider_event_rank,last_event_id
  ) values
    ('sub_v124_projection','si_v124_base','other','price_v124_monthly_base',
     1,14900,'SGD','month',1,'2026-08-01 04:00:00+00',30,'evt_v124_projection'),
    ('sub_v124_projection','si_v124_capacity','other','price_v124_monthly_capacity',
     2,1000,'SGD','month',1,'2026-08-01 04:00:00+00',30,'evt_v124_projection');
  if not exists(
    select 1 from public.billing_provider_subscription_items
     where provider_item_id='si_v124_capacity' and item_role='capacity'
  ) or not exists(
    select 1 from public.billing_subscription_terms_v124
     where business_id=v_projection_business and cadence='monthly'
       and customer_capacity=3000 and capacity_blocks=3
       and provider_capacity_item_id='si_v124_capacity'
  ) then
    raise exception 'provider V124 capacity items were not projected';
  end if;

  -- A processed Stripe subscription snapshot is authoritative: the capacity
  -- add-on omitted from the newer complete item list must be removed locally.
  insert into public.billing_provider_events(
    provider,event_id,event_type,object_id,event_created_at,livemode,
    payload,payload_sha256,processing_status,business_id
  ) values (
    'stripe','evt_v124_without_capacity','customer.subscription.updated',
    'sub_v124_projection','2026-08-01 04:05:00+00',false,
    jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object(
      'id','sub_v124_projection','items',jsonb_build_object(
        'has_more',false,'data',jsonb_build_array(jsonb_build_object('id','si_v124_base'))
      )
    ))),repeat('a',64),'pending',v_projection_business
  );
  update public.billing_provider_events
     set processing_status='processed',processed_at=now()
   where event_id='evt_v124_without_capacity';
  if exists(
    select 1 from public.billing_provider_subscription_items
     where provider_item_id='si_v124_capacity'
  ) or not exists(
    select 1 from public.billing_subscription_terms_v124
     where business_id=v_projection_business and customer_capacity=1000
       and capacity_blocks=1 and provider_capacity_item_id is null
  ) then
    raise exception 'complete Stripe item snapshot did not remove stale capacity';
  end if;

  -- Capacity is customer based. Five staff do not consume it; profile 1001 fails.
  -- A paid legacy invoice without matching V124 terms must not create a new
  -- guarantee window on a later renewal.
  insert into public.billing_provider_invoices(
    business_id,provider_customer_id,provider_subscription_id,
    provider_invoice_id,currency,status,paid_normalized,
    subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,
    amount_paid_cents,amount_remaining_cents,paid_at,livemode,
    provider_event_created_at,provider_event_rank,last_event_id
  ) values (
    v_business,'cus_v124_legacy','sub_v124_legacy','in_v124_legacy','SGD','paid',true,
    14900,0,14900,14900,14900,0,'2026-07-01 04:15:00+00',false,
    '2026-07-01 04:15:01+00',100,'evt_v124_legacy_paid'
  );
  if exists(
    select 1 from public.billing_money_back_windows_v124
     where business_id=v_business
  ) then
    raise exception 'legacy invoice incorrectly created a V124 guarantee window';
  end if;
  insert into public.billing_subscription_terms_v124(
    business_id,provider_subscription_id,cadence,customer_capacity,capacity_blocks,
    provider_base_price_id,provider_event_created_at,last_event_id
  ) values (
    v_business,'sub_v124','annual',1000,1,'price_v124_annual_base',
    '2026-08-01 04:00:00+00','evt_v124_terms'
  );

  -- An exact uncertain capacity command must remain recoverable after the
  -- provider webhook has already projected the requested capacity.
  perform pg_temp.as_v124_user(v_owner);
  v_command:=public.request_billing_command_v124(
    v_business,'change_capacity','annual',3000,gen_random_uuid()
  );
  reset role;
  perform pg_temp.as_v124_user(null,'service_role');
  perform public.claim_billing_command_v124(
    (v_command->>'command_id')::uuid,v_owner
  );
  perform public.complete_billing_command_v77(
    (v_command->>'command_id')::uuid,'uncertain','sub_v124',null,
    'provider_confirmation_pending','rollback-only pending update'
  );
  reset role;
  update public.billing_subscription_terms_v124
     set customer_capacity=3000,capacity_blocks=3
   where business_id=v_business;
  perform pg_temp.as_v124_user(null,'service_role');
  v_result:=public.claim_billing_command_v124(
    (v_command->>'command_id')::uuid,v_owner
  );
  reset role;
  if not coalesce((v_result->>'recovery_required')::boolean,false)
     or (v_result->>'requested_customer_capacity')::integer<>3000 then
    raise exception 'provider-projected uncertain capacity command could not recover';
  end if;
  v_denied:=false;
  perform pg_temp.as_v124_user(v_owner);
  begin
    perform public.request_billing_command_v124(
      v_business,'change_cadence','monthly',2000,gen_random_uuid()
    );
  exception when invalid_parameter_value then v_denied:=true;
  end;
  reset role;
  if not v_denied then
    raise exception 'change_cadence bypassed the increase-only capacity contract';
  end if;
  update public.billing_subscription_terms_v124
     set customer_capacity=1000,capacity_blocks=1
   where business_id=v_business;
  insert into public.clients(business_id,full_name)
  select v_business,'Synthetic Glow customer '||series::text
    from generate_series(1,1000) series;
  begin
    insert into public.clients(business_id,full_name)
    values(v_business,'Synthetic over capacity');
    raise exception 'capacity guard accepted profile 1001';
  exception when check_violation then null;
  end;
  if (select count(*) from public.clients where business_id=v_business)<>1000 then
    raise exception 'capacity denial changed stored customer count';
  end if;

  -- First paid truth fixes one exact 30-day request window. A later invoice and
  -- subscription changes cannot reset it; an out-of-order earlier paid invoice
  -- may correct it backwards only.
  insert into public.billing_provider_invoices(
    business_id,provider_customer_id,provider_subscription_id,
    provider_invoice_id,currency,status,paid_normalized,
    subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,
    amount_paid_cents,amount_remaining_cents,paid_at,livemode,
    provider_event_created_at,provider_event_rank,last_event_id
  ) values
    (v_business,'cus_v124','sub_v124','in_v124_first','SGD','paid',true,
     118800,0,118800,118800,118800,0,'2026-08-01 04:15:00+00',false,
     '2026-08-01 04:15:01+00',100,'evt_v124_paid_first'),
    (v_business,'cus_v124','sub_v124','in_v124_later','SGD','paid',true,
     118800,0,118800,118800,118800,0,'2026-08-10 04:15:00+00',false,
     '2026-08-10 04:15:01+00',100,'evt_v124_paid_later');
  if not exists(
    select 1 from public.billing_money_back_windows_v124
     where business_id=v_business
       and first_paid_invoice_id='in_v124_first'
       and first_paid_at='2026-08-01 04:15:00+00'
       and money_back_request_until='2026-08-31 04:15:00+00'
  ) then
    raise exception 'first paid invoice did not fix the guarantee window';
  end if;
  update public.billing_subscription_terms_v124
     set cadence='monthly',updated_at=now()
   where business_id=v_business;
  if not exists(
    select 1 from public.billing_money_back_windows_v124
     where business_id=v_business
       and money_back_request_until='2026-08-31 04:15:00+00'
  ) then
    raise exception 'cadence change reset the guarantee window';
  end if;
  insert into public.billing_provider_invoices(
    business_id,provider_customer_id,provider_subscription_id,
    provider_invoice_id,currency,status,paid_normalized,
    subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,
    amount_paid_cents,amount_remaining_cents,paid_at,livemode,
    provider_event_created_at,provider_event_rank,last_event_id
  ) values (
    v_business,'cus_v124','sub_v124','in_v124_earlier','SGD','paid',true,
    14900,0,14900,14900,14900,0,'2026-07-30 04:15:00+00',false,
    '2026-08-11 04:15:01+00',100,'evt_v124_paid_earlier'
  );
  if not exists(
    select 1 from public.billing_money_back_windows_v124
     where business_id=v_business
       and first_paid_invoice_id='in_v124_earlier'
       and money_back_request_until='2026-08-29 04:15:00+00'
  ) then
    raise exception 'earlier out-of-order paid truth did not repair the window';
  end if;
end
$v124_test$;

rollback;
