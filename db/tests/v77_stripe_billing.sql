-- Rollback-only acceptance for Nestly v77 Stripe billing.
-- Run after the canonical chain through 20260726120000 in a disposable database.
begin;

create or replace function pg_temp.as_v77_user(
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
grant execute on function pg_temp.as_v77_user(uuid,text) to public;

do $v77_test$
declare
  v_owner uuid := gen_random_uuid();
  v_business uuid;
  v_foreign_business uuid;
  v_result jsonb;
  v_command jsonb;
  v_key uuid := gen_random_uuid();
  v_conflict boolean := false;
  v_payload jsonb;
  v_paid_payload jsonb;
  v_refund uuid;
  v_effective timestamptz;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000',v_owner,
    'authenticated','authenticated',
    'v77-owner-'||substr(v_owner::text,1,8)||'@example.test','',
    now(),now(),now()
  );
  insert into public.businesses(name,slug,industry,enabled_modules)
  values(
    'V77 Stripe fixture','v77-stripe-'||substr(v_owner::text,1,8),
    'test',array['dashboard']
  ) returning id into v_business;
  insert into public.staff(business_id,user_id,role,full_name,active)
  values(v_business,v_owner,'owner','V77 Owner',true);
  insert into public.super_admins(user_id,email,note)
  values(
    v_owner,'v77-owner-'||substr(v_owner::text,1,8)||'@example.test',
    'rollback-only v77 fixture'
  );
  insert into public.businesses(name,slug,industry,enabled_modules)
  values(
    'V77 foreign fixture','v77-foreign-'||substr(v_owner::text,1,8),
    'test',array['dashboard']
  ) returning id into v_foreign_business;
  insert into public.subscriptions(business_id,currency)
  values(v_business,'SGD')
  on conflict(business_id) do update set currency='SGD';
  insert into public.billing_price_catalog(
    currency,cadence,cadence_months,provider_base_price_id,
    provider_seat_price_id,base_amount_cents,per_seat_amount_cents,
    included_seats,tax_behavior,created_by
  ) values
    ('SGD','quarterly',3,'price_v77_q_base','price_v77_q_seat',7500,3000,1,'exclusive',v_owner),
    ('SGD','half_yearly',6,'price_v77_h_base','price_v77_h_seat',15000,6000,1,'exclusive',v_owner),
    ('SGD','annual',12,'price_v77_a_base','price_v77_a_seat',30000,12000,1,'exclusive',v_owner);

  -- Newer subscription event establishes quarterly provider truth.
  v_payload := jsonb_build_object(
    'id','evt_v77_sub_new','type','customer.subscription.updated',
    'livemode',false,'api_version','2025-06-30.basil',
    'data',jsonb_build_object('object',jsonb_build_object(
      'id','sub_v77','customer','cus_v77','status','active','currency','sgd',
      'metadata',jsonb_build_object('business_id',v_business),
      'cancel_at_period_end',false,
      'items',jsonb_build_object('data',jsonb_build_array(jsonb_build_object(
        'id','si_v77_base','quantity',1,'current_period_start',1785038400,
        'current_period_end',1792987200,
        'price',jsonb_build_object(
          'id','price_v77_q_base','unit_amount',7500,'currency','sgd',
          'recurring',jsonb_build_object('interval','month','interval_count',3)
        )
      )))
    ))
  );
  perform pg_temp.as_v77_user(null,'service_role');
  perform public.ingest_stripe_billing_event_v77(
    'evt_v77_sub_new','customer.subscription.updated','sub_v77',
    '2026-07-26 12:00:00+00',false,v_payload,repeat('a',64)
  );
  v_result := public.apply_stripe_billing_event_v77('evt_v77_sub_new');
  reset role;
  if v_result->>'status' <> 'processed'
     or not exists(
       select 1 from public.subscriptions
        where business_id=v_business and status='active'
          and billing_cadence='quarterly' and cadence_months=3
          and provider_subscription_id='sub_v77'
     ) then
    raise exception 'quarterly provider subscription was not normalized';
  end if;

  -- An event delivered later but created earlier must not regress the projection.
  v_payload := jsonb_set(
    jsonb_set(v_payload,'{id}','"evt_v77_sub_old"'),
    '{data,object,status}','"past_due"'
  );
  perform pg_temp.as_v77_user(null,'service_role');
  perform public.ingest_stripe_billing_event_v77(
    'evt_v77_sub_old','customer.subscription.updated','sub_v77',
    '2026-07-26 11:00:00+00',false,v_payload,repeat('b',64)
  );
  perform public.apply_stripe_billing_event_v77('evt_v77_sub_old');
  reset role;
  if not exists(
    select 1 from public.subscriptions
     where business_id=v_business and status='active'
       and billing_cadence='quarterly'
  ) then
    raise exception 'older subscription event regressed provider state';
  end if;

  -- Stripe represents a normal annual recurring Price as year/1. The provider
  -- item keeps that raw interval while the subscription projection stores 12.
  v_payload := jsonb_build_object(
    'id','evt_v77_sub_annual','type','customer.subscription.updated',
    'livemode',false,'api_version','2025-06-30.basil',
    'data',jsonb_build_object('object',jsonb_build_object(
      'id','sub_v77','customer','cus_v77','status','active','currency','sgd',
      'metadata',jsonb_build_object('business_id',v_business),
      'cancel_at_period_end',false,
      'items',jsonb_build_object('data',jsonb_build_array(jsonb_build_object(
        'id','si_v77_base','quantity',1,'current_period_start',1792987200,
        'current_period_end',1824523200,
        'price',jsonb_build_object(
          'id','price_v77_a_base','unit_amount',30000,'currency','sgd',
          'recurring',jsonb_build_object('interval','year','interval_count',1)
        )
      )))
    ))
  );
  perform pg_temp.as_v77_user(null,'service_role');
  perform public.ingest_stripe_billing_event_v77(
    'evt_v77_sub_annual','customer.subscription.updated','sub_v77',
    '2026-07-26 12:01:00+00',false,v_payload,repeat('c',64)
  );
  perform public.apply_stripe_billing_event_v77('evt_v77_sub_annual');
  reset role;
  if not exists(
    select 1 from public.subscriptions
     where business_id=v_business and billing_cadence='annual'
       and cadence_months=12
  ) or not exists(
    select 1 from public.billing_provider_subscription_items
     where provider_item_id='si_v77_base' and interval_name='year'
       and interval_count=1
  ) then
    raise exception 'annual Stripe year/1 cadence was not normalized to 12 months';
  end if;

  -- Failure creates an attempt and provider retry time, never paid truth.
  v_payload := jsonb_build_object(
    'id','evt_v77_invoice_failed','type','invoice.payment_failed',
    'livemode',false,'data',jsonb_build_object('object',jsonb_build_object(
      'id','in_v77','customer','cus_v77','subscription','sub_v77',
      'payment_intent','pi_v77','currency','sgd','status','open',
      'collection_method','charge_automatically',
      'total_excluding_tax',10000,'total',10900,'amount_due',10900,
      'amount_paid',0,'amount_remaining',10900,
      'period_start',1785038400,'period_end',1792987200,
      'next_payment_attempt',1785200000
    ))
  );
  perform pg_temp.as_v77_user(null,'service_role');
  perform public.ingest_stripe_billing_event_v77(
    'evt_v77_invoice_failed','invoice.payment_failed','in_v77',
    '2026-07-26 12:05:00+00',false,v_payload,repeat('c',64)
  );
  perform public.apply_stripe_billing_event_v77('evt_v77_invoice_failed');
  reset role;
  if exists(
    select 1 from public.billing_provider_invoices
     where provider_invoice_id='in_v77' and (paid_normalized or paid_at is not null)
  ) then
    raise exception 'invoice.payment_failed created paid truth';
  end if;

  -- invoice.paid is the normalizing paid event and captures net cash ex GST.
  v_payload := jsonb_set(
    jsonb_set(
      jsonb_set(
        jsonb_set(v_payload,'{id}','"evt_v77_invoice_paid"'),
        '{type}','"invoice.paid"'
      ),
      '{data,object,status}','"paid"'
    ),
    '{data,object,amount_paid}','10900'
  );
  v_payload := jsonb_set(v_payload,'{data,object,amount_remaining}','0');
  v_payload := jsonb_set(
    v_payload,'{data,object,status_transitions}',
    '{"paid_at":1785067560}'::jsonb
  );
  v_paid_payload := v_payload;
  perform pg_temp.as_v77_user(null,'service_role');
  perform public.ingest_stripe_billing_event_v77(
    'evt_v77_invoice_paid','invoice.paid','in_v77',
    '2026-07-26 12:06:00+00',false,v_payload,repeat('d',64)
  );
  perform public.apply_stripe_billing_event_v77('evt_v77_invoice_paid');
  reset role;
  if not exists(
    select 1 from public.billing_provider_invoices
     where provider_invoice_id='in_v77' and paid_normalized
       and status='paid' and amount_paid_cents=10900
       and tax_cents=900 and net_cash_ex_tax_cents=10000
  ) then
    raise exception 'invoice.paid did not create normalized paid truth';
  end if;

  -- The older failed event can be applied again without regressing paid truth.
  perform pg_temp.as_v77_user(null,'service_role');
  perform public.apply_stripe_billing_event_v77('evt_v77_invoice_failed');
  reset role;
  if not exists(
    select 1 from public.billing_provider_invoices
     where provider_invoice_id='in_v77' and paid_normalized and status='paid'
  ) then
    raise exception 'older failed event regressed normalized paid truth';
  end if;

  -- Subscription deletion remains lifecycle-authoritative even if a final
  -- invoice is paid afterwards.
  v_payload := jsonb_build_object(
    'id','evt_v77_sub_deleted','type','customer.subscription.deleted',
    'livemode',false,'data',jsonb_build_object('object',jsonb_build_object(
      'id','sub_v77','customer','cus_v77','status','canceled','currency','sgd',
      'metadata',jsonb_build_object('business_id',v_business),
      'cancel_at_period_end',false,'canceled_at',1785068400,
      'items',jsonb_build_object('data',jsonb_build_array(jsonb_build_object(
        'id','si_v77_base','quantity',1,
        'price',jsonb_build_object(
          'id','price_v77_q_base','unit_amount',7500,'currency','sgd',
          'recurring',jsonb_build_object('interval','month','interval_count',3)
        )
      )))
    ))
  );
  perform pg_temp.as_v77_user(null,'service_role');
  perform public.ingest_stripe_billing_event_v77(
    'evt_v77_sub_deleted','customer.subscription.deleted','sub_v77',
    '2026-07-26 12:20:00+00',false,v_payload,repeat('f',64)
  );
  perform public.apply_stripe_billing_event_v77('evt_v77_sub_deleted');
  reset role;

  v_payload := jsonb_build_object(
    'id','evt_v77_final_paid','type','invoice.paid','livemode',false,
    'data',jsonb_build_object('object',jsonb_build_object(
      'id','in_v77_final','customer','cus_v77','subscription','sub_v77',
      'payment_intent','pi_v77_final','currency','sgd','status','paid',
      'collection_method','charge_automatically',
      'total_excluding_tax',2000,'total',2180,'amount_due',2180,
      'amount_paid',2180,'amount_remaining',0,
      'status_transitions',jsonb_build_object('paid_at',1785068460)
    ))
  );
  perform pg_temp.as_v77_user(null,'service_role');
  perform public.ingest_stripe_billing_event_v77(
    'evt_v77_final_paid','invoice.paid','in_v77_final',
    '2026-07-26 12:21:00+00',false,v_payload,repeat('0',64)
  );
  perform public.apply_stripe_billing_event_v77('evt_v77_final_paid');
  reset role;
  if not exists(
    select 1 from public.subscriptions
     where business_id=v_business and status='canceled'
       and payment_status='paid' and last_paid_invoice_id='in_v77_final'
  ) then
    raise exception 'final paid invoice resurrected canceled subscription';
  end if;

  -- Metadata cannot re-home an already linked provider customer.
  v_payload := jsonb_build_object(
    'id','evt_v77_customer_mismatch','type','checkout.session.completed',
    'livemode',false,'data',jsonb_build_object('object',jsonb_build_object(
      'id','cs_v77_mismatch','customer','cus_v77','subscription','sub_other',
      'client_reference_id',v_foreign_business::text,
      'metadata',jsonb_build_object('business_id',v_foreign_business)
    ))
  );
  perform pg_temp.as_v77_user(null,'service_role');
  perform public.ingest_stripe_billing_event_v77(
    'evt_v77_customer_mismatch','checkout.session.completed','cs_v77_mismatch',
    '2026-07-26 12:22:00+00',false,v_payload,repeat('1',64)
  );
  v_result := public.apply_stripe_billing_event_v77('evt_v77_customer_mismatch');
  reset role;
  if v_result->>'status'<>'failed'
     or exists(
       select 1 from public.billing_provider_customers
        where business_id=v_foreign_business and provider_customer_id='cus_v77'
     ) then
    raise exception 'provider customer mismatch was not rejected';
  end if;

  -- Exact inbox replay is a no-op; a changed envelope is rejected separately.
  perform pg_temp.as_v77_user(null,'service_role');
  v_result := public.ingest_stripe_billing_event_v77(
    'evt_v77_invoice_paid','invoice.paid','in_v77',
    '2026-07-26 12:06:00+00',false,v_paid_payload,repeat('d',64)
  );
  reset role;
  if not coalesce((v_result->>'duplicate')::boolean,false)
     or (select count(*) from public.billing_provider_events
          where event_id='evt_v77_invoice_paid') <> 1 then
    raise exception 'exact event replay was not idempotent';
  end if;

  -- Refund is an immutable, GST-aware compensating record.
  v_payload := jsonb_build_object(
    'id','evt_v77_refund','type','refund.created','livemode',false,
    'data',jsonb_build_object('object',jsonb_build_object(
      'id','re_v77','payment_intent','pi_v77','amount',1090,'currency','sgd'
    ))
  );
  perform pg_temp.as_v77_user(null,'service_role');
  perform public.ingest_stripe_billing_event_v77(
    'evt_v77_refund','refund.created','re_v77',
    '2026-07-26 12:10:00+00',false,v_payload,repeat('e',64)
  );
  perform public.apply_stripe_billing_event_v77('evt_v77_refund');
  reset role;
  if not exists(
    select 1 from public.billing_adjustments
     where provider_object_id='re_v77' and adjustment_type='refund'
       and subtotal_ex_tax_cents=-1000 and tax_cents=-90 and total_cents=-1090
  ) then
    raise exception 'refund did not create separate GST-aware adjustment';
  end if;
  select id into strict v_refund
    from public.billing_adjustments where provider_object_id='re_v77';
  perform pg_temp.as_v77_user(null,'service_role');
  perform public.append_billing_adjustment_v77(
    v_business,'in_v77','reversal',1000,90,'SGD','re_v77_reversal',
    v_refund,'reverse rollback-only refund fixture',repeat('2',64),
    '2026-07-26 12:11:00+00'
  );
  reset role;
  if not exists(
    select 1 from public.billing_adjustments
     where reversal_of=v_refund and adjustment_type='reversal'
       and subtotal_ex_tax_cents=1000 and tax_cents=90 and total_cents=1090
  ) then
    raise exception 'refund reversal did not restore the exact GST-aware amount';
  end if;

  -- Command replay returns one row; changed use of the same key is rejected.
  perform pg_temp.as_v77_user(v_owner);
  v_command := public.request_billing_command_v77(
    v_business,'create_checkout','quarterly',v_key
  );
  v_result := public.request_billing_command_v77(
    v_business,'create_checkout','quarterly',v_key
  );
  reset role;
  if v_command->>'command_id' <> v_result->>'command_id'
     or (select count(*) from public.billing_commands where idempotency_key=v_key) <> 1 then
    raise exception 'billing command exact replay was not idempotent';
  end if;
  begin
    perform pg_temp.as_v77_user(v_owner);
    perform public.request_billing_command_v77(
      v_business,'create_checkout','annual',v_key
    );
    reset role;
  exception when others then
    reset role;
    v_conflict := true;
  end;
  if not v_conflict then
    raise exception 'billing command changed replay was accepted';
  end if;

  perform pg_temp.as_v77_user(null,'service_role');
  v_result := public.claim_billing_command_v77(
    (v_command->>'command_id')::uuid,v_owner
  );
  reset role;
  if v_result->>'provider_idempotency_key'
       <> 'nestly:v77:billing-command:'||(v_command->>'command_id')
     or v_result->>'provider_base_price_id' <> 'price_v77_q_base' then
    raise exception 'billing command claim did not return stable provider instructions';
  end if;

  -- Price activation is preview-confirm, retires the prior version atomically,
  -- and does not hardcode any provider IDs in the migration.
  v_effective := clock_timestamp();
  perform pg_temp.as_v77_user(v_owner);
  v_result := public.preview_billing_price_catalog_v77(
    'SGD','quarterly','price_v77_q2_base','price_v77_q2_seat',
    7200,2800,1,'exclusive',v_effective
  );
  v_result := public.confirm_billing_price_catalog_v77(
    'SGD','quarterly','price_v77_q2_base','price_v77_q2_seat',
    7200,2800,1,'exclusive',v_effective,
    v_result->>'confirmation_hash','rollback-only v77 activation'
  );
  reset role;
  if v_result->>'provider_base_price_id'<>'price_v77_q2_base'
     or (select count(*) from public.billing_price_catalog
          where currency='SGD' and cadence='quarterly'
            and active and effective_to is null)<>1
     or not exists(
       select 1 from public.audit_log
        where action='BILLING_PRICE_CATALOG_ACTIVATED_V77'
          and entity_id=(v_result->>'id')::uuid
     ) then
    raise exception 'price catalog confirmation did not activate a version';
  end if;
end
$v77_test$;

rollback;
