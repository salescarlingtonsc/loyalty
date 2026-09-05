-- nestly_v791 rollback suite — Stripe is the platform billing provider again, and it knows branches.
--
-- Runs inside ONE transaction ending in ROLLBACK, so it is safe against production. Drives the real
-- Stripe pipeline (ingest_stripe_billing_event_v77 -> apply_stripe_billing_event_v77) with
-- synthesised Stripe envelopes carrying metadata.branch_id, exactly as the executor writes them.
--
-- WHAT IT PROVES
--   D1  the flat tiers price from Stripe price ids; the larger tiers carry none; nothing is razorpay.
--   D2  the nightly reconcile call posts to stripe-billing-reconcile.
--   D3  a customer.subscription.created + invoice.paid pair naming a branch writes the branch's own
--       row, mirrors and invoice (detail.branch_id), switches the branch ON, and leaves the
--       company's subscriptions row untouched.
--   D4  customer.subscription.updated with cancel_at_period_end and a future period end reads as
--       'canceling' with the date; customer.subscription.deleted switches the branch off.
--   D5  an event WITHOUT a branch still goes through the base applier (company path unchanged).
--   D6  ACLs: the two new app.* functions are server-only.
begin;

create or replace function pg_temp.push_stripe_v791(p_event_id text, p_type text, p_object jsonb, p_at timestamptz)
returns jsonb language plpgsql as $$
declare v_payload jsonb; v_apply jsonb;
begin
  v_payload := jsonb_build_object('id',p_event_id,'object','event','type',p_type,'livemode',false,
    'created',extract(epoch from p_at)::bigint,'data',jsonb_build_object('object',p_object));
  perform public.ingest_stripe_billing_event_v77(p_event_id, p_type, p_object->>'id', p_at, false, v_payload,
    encode(extensions.digest(convert_to(v_payload::text,'utf8'),'sha256'),'hex'));
  v_apply := public.apply_stripe_billing_event_v77(p_event_id);
  if v_apply->>'status' <> 'processed' then
    raise exception 'v791 push %: apply answered %', p_event_id, v_apply;
  end if;
  return v_apply;
end
$$;
grant execute on function pg_temp.push_stripe_v791(text,text,jsonb,timestamptz) to public;

do $v791_main$
declare
  v_owner uuid := gen_random_uuid();
  v_business uuid := gen_random_uuid();
  v_main uuid; v_branch uuid;
  v_sub text := 'sub_v791'||substr(replace(gen_random_uuid()::text,'-',''),1,14);
  v_inv text := 'in_v791'||substr(replace(gen_random_uuid()::text,'-',''),1,14);
  v_cust text := 'cus_v791'||substr(replace(gen_random_uuid()::text,'-',''),1,12);
  v_price text;
  v_now timestamptz := now();
  v_end timestamptz := now() + interval '30 days';
  v_subobj jsonb;
  v_row public.branch_subscriptions_v786%rowtype;
  v_br public.branches%rowtype;
  v_company_before jsonb; v_company_after jsonb;
  v_n integer;
begin
  reset role;

  -- D1
  select count(*) into v_n from public.billing_capacity_tier_catalog_v664 where active and provider <> 'stripe';
  if v_n > 0 then raise exception 'v791 D1: % active tier(s) are not stripe', v_n; end if;
  select provider_base_price_id into v_price from public.billing_capacity_tier_catalog_v664
   where active and cadence='monthly' and capacity_ceiling=10000;
  if v_price is null or v_price not like 'price_%' then raise exception 'v791 D1: monthly flat tier has no Stripe price'; end if;
  select count(*) into v_n from public.billing_capacity_tier_catalog_v664 where active and capacity_ceiling > 10000 and provider_base_price_id is not null;
  if v_n > 0 then raise exception 'v791 D1: a larger tier still carries a price id'; end if;

  -- D2
  if position('stripe-billing-reconcile' in pg_get_functiondef('app.run_billing_reconcile_call_v624()'::regprocedure)) = 0 then
    raise exception 'v791 D2: the reconcile call does not post to stripe-billing-reconcile';
  end if;

  -- D6
  if has_function_privilege('authenticated','app.stripe_branch_v791(jsonb)','EXECUTE')
     or has_function_privilege('authenticated','app.apply_stripe_branch_event_v791(text,uuid,uuid,smallint)','EXECUTE') then
    raise exception 'v791 D6: branch applier ACLs are not server-only';
  end if;

  -- fixture business with a main branch and an own-billed branch
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated','v791-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.businesses(id,name,slug,industry,enabled_modules)
  values (v_business,'V791 fixture','v791-'||substr(v_business::text,1,8),'test',array['dashboard','clients','sales']);
  insert into public.staff(business_id,user_id,role,full_name,active) values (v_business,v_owner,'owner','V791 Owner',true);
  insert into public.branches(business_id,name,is_default,active) values (v_business,'Main',true,true) returning id into v_main;
  insert into public.branches(business_id,name,is_default,active,billing_state,billing_mode)
  values (v_business,'Own branch',false,false,'pending_payment','own') returning id into v_branch;
  insert into public.subscriptions(business_id,status,payment_status,current_period_start,current_period_end,billing_provider,billing_cadence)
  values (v_business,'active','paid',now()-interval '10 days',now()+interval '355 days','manual','annual');
  select to_jsonb(s) - 'updated_at' into v_company_before from public.subscriptions s where s.business_id=v_business;

  -- D3
  v_subobj := jsonb_build_object('id',v_sub,'object','subscription','customer',v_cust,'status','active','currency','sgd',
    'created',extract(epoch from v_now)::bigint,'current_period_start',extract(epoch from v_now)::bigint,
    'current_period_end',extract(epoch from v_end)::bigint,'cancel_at_period_end',false,
    'metadata',jsonb_build_object('business_id',v_business::text,'branch_id',v_branch::text,'cadence','monthly'),
    'items',jsonb_build_object('data',jsonb_build_array(jsonb_build_object('id','si_v791a','quantity',1,
      'current_period_start',extract(epoch from v_now)::bigint,'current_period_end',extract(epoch from v_end)::bigint,
      'price',jsonb_build_object('id',v_price,'unit_amount',14800,'currency','sgd','recurring',jsonb_build_object('interval','month','interval_count',1))))));
  perform pg_temp.push_stripe_v791('evt_v791_sub_created','customer.subscription.created',v_subobj,v_now);
  perform pg_temp.push_stripe_v791('evt_v791_inv_paid','invoice.paid',jsonb_build_object(
    'id',v_inv,'object','invoice','customer',v_cust,'subscription',v_sub,'status','paid','currency','sgd',
    'total',14800,'subtotal',14800,'amount_due',14800,'amount_paid',14800,'amount_remaining',0,
    'period_start',extract(epoch from v_now)::bigint,'period_end',extract(epoch from v_end)::bigint,
    'payment_intent','pi_v791','collection_method','charge_automatically',
    'status_transitions',jsonb_build_object('paid_at',extract(epoch from v_now)::bigint),
    'subscription_details',jsonb_build_object('metadata',jsonb_build_object('business_id',v_business::text,'branch_id',v_branch::text))),
    v_now + interval '1 second');
  select * into v_row from public.branch_subscriptions_v786 where branch_id=v_branch;
  select * into v_br from public.branches where id=v_branch;
  if v_row.provider_subscription_id <> v_sub or v_row.provider <> 'stripe' or v_row.payment_status <> 'paid'
     or v_row.cadence <> 'monthly' or v_row.unit_amount_cents <> 14800 then
    raise exception 'v791 D3: branch subscription row is wrong: %', to_jsonb(v_row);
  end if;
  if v_br.billing_state <> 'active' or not v_br.active then
    raise exception 'v791 D3: the branch did not switch on (state=% active=%)', v_br.billing_state, v_br.active;
  end if;
  if not exists (select 1 from public.billing_provider_invoices i where i.provider_invoice_id=v_inv and (i.detail->>'branch_id')::uuid=v_branch and i.status='paid') then
    raise exception 'v791 D3: invoice was not mirrored with the branch';
  end if;
  select to_jsonb(s) - 'updated_at' into v_company_after from public.subscriptions s where s.business_id=v_business;
  if v_company_after <> v_company_before then
    raise exception 'v791 D3: a branch event rewrote the company subscription: %', v_company_after;
  end if;

  -- D4
  perform pg_temp.push_stripe_v791('evt_v791_sub_cancel_sched','customer.subscription.updated',
    v_subobj || jsonb_build_object('cancel_at_period_end',true), v_now + interval '2 days');
  select * into v_br from public.branches where id=v_branch;
  if v_br.billing_state <> 'canceling' or v_br.billing_cancel_at is null or not v_br.active then
    raise exception 'v791 D4: scheduled cancel did not read as canceling (state=%)', v_br.billing_state;
  end if;
  perform pg_temp.push_stripe_v791('evt_v791_sub_deleted','customer.subscription.deleted',
    v_subobj || jsonb_build_object('status','canceled','ended_at',extract(epoch from v_end)::bigint), v_now + interval '31 days');
  select * into v_br from public.branches where id=v_branch;
  if v_br.billing_state <> 'unsubscribed' or v_br.active then
    raise exception 'v791 D4: deleted did not switch the branch off (state=%)', v_br.billing_state;
  end if;

  -- D5 · a company-level event (no branch) reaches the base applier
  perform pg_temp.push_stripe_v791('evt_v791_company_sub','customer.subscription.created',
    jsonb_build_object('id','sub_v791company','object','subscription','customer',v_cust,'status','active','currency','sgd',
      'created',extract(epoch from v_now)::bigint,'current_period_start',extract(epoch from v_now)::bigint,
      'current_period_end',extract(epoch from v_end)::bigint,'cancel_at_period_end',false,
      'metadata',jsonb_build_object('business_id',v_business::text),
      'items',jsonb_build_object('data',jsonb_build_array(jsonb_build_object('id','si_v791c','quantity',1,
        'price',jsonb_build_object('id',v_price,'unit_amount',14800,'currency','sgd','recurring',jsonb_build_object('interval','month','interval_count',1)))))),
    v_now + interval '3 days');
  if not exists (select 1 from public.subscriptions s where s.business_id=v_business and s.provider_subscription_id='sub_v791company' and s.billing_provider='stripe') then
    raise exception 'v791 D5: the company path did not write the company subscription';
  end if;

  raise notice 'v791 acceptance: D1–D6 passed';
end
$v791_main$;

rollback;
