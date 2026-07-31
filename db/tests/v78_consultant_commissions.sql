-- Rollback-only acceptance for Nestly v78 consultant commissions.
-- Run after the canonical chain through 20260726130000 in a disposable database.
begin;

create or replace function pg_temp.as_v78_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,true
  );
end
$$;
grant execute on function pg_temp.as_v78_user(uuid,text) to public;

do $v78_test$
declare
  v_admin uuid:=gen_random_uuid();
  v_consultant_user uuid:=gen_random_uuid();
  v_consultant uuid;
  v_business uuid;
  v_company uuid;
  v_prospect uuid;
  v_anchor timestamptz:=date_trunc('day',now())-interval '18 months';
  v_first_invoice uuid;
  v_renewal_invoice uuid;
  v_future_invoice uuid;
  v_first_accrual uuid;
  v_bonus_accrual uuid;
  v_renewal_accrual uuid;
  v_refund_adjustment uuid;
  v_refund_commission_adjustment uuid;
  v_batch uuid;
  v_line uuid;
  v_result jsonb;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_admin,
     'authenticated','authenticated','v78-admin@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_consultant_user,
     'authenticated','authenticated','v78-consultant@example.test','',now(),now(),now());
  insert into public.super_admins(user_id,email,note)
  values(v_admin,'v78-admin@example.test','rollback-only v78 fixture');

  perform pg_temp.as_v78_user(v_admin);
  v_result:=public.platform_upsert_consultant_v75(
    null,v_consultant_user,'V78 Senior Consultant','senior',
    (v_anchor-interval '1 month')::date,true
  );
  reset role;
  v_consultant:=(v_result#>>'{consultant,id}')::uuid;

  insert into public.businesses(name,slug,industry,enabled_modules)
  values(
    'V78 converted firm','v78-firm-'||substr(v_admin::text,1,8),
    'test',array['dashboard']
  ) returning id into v_business;
  insert into public.subscriptions(business_id,status,currency)
  values(v_business,'active','SGD');
  insert into public.sme_companies(trading_name)
  values('V78 prospect company') returning id into v_company;
  insert into public.sme_prospects(
    company_id,current_stage_key,assigned_consultant_id,
    converted_business_id,converted_at,converted_by,created_by
  ) values (
    v_company,'client',v_consultant,v_business,v_anchor,v_admin,v_admin
  ) returning id into v_prospect;
  perform pg_temp.as_v78_user(v_admin);
  perform public.attribute_consultant_v78(
    v_consultant,v_prospect,v_business,v_anchor,
    'rollback-only converted firm attribution'
  );
  reset role;

  -- A first-year paid invoice includes the entire net cash ex GST (including
  -- any setup fee represented in that Stripe invoice). Senior cash splits into
  -- 30% base plus a separately visible 10% retained-service bonus.
  insert into public.billing_provider_invoices(
    business_id,provider_customer_id,provider_subscription_id,
    provider_invoice_id,currency,collection_method,status,paid_normalized,
    subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,
    amount_paid_cents,amount_remaining_cents,net_cash_ex_tax_cents,
    paid_at,livemode,provider_event_created_at,provider_event_rank,last_event_id
  ) values (
    v_business,'cus_v78','sub_v78','in_v78_first','SGD',
    'charge_automatically','paid',true,10000,900,10900,10900,10900,0,10000,
    v_anchor+interval '1 month',false,v_anchor+interval '1 month',100,
    'evt_v78_first'
  ) returning id into v_first_invoice;
  select id into strict v_first_accrual
    from public.consultant_commission_accruals
   where invoice_id=v_first_invoice and commission_phase='first_year_base';
  select id into strict v_bonus_accrual
    from public.consultant_commission_accruals
   where invoice_id=v_first_invoice and commission_phase='anniversary_bonus';
  if not exists(
    select 1 from public.consultant_commission_accruals
     where id=v_first_accrual and commission_phase='first_year_base'
       and basis_cents=10000 and rate_bps=3000 and commission_cents=3000
       and eligible_at=invoice_paid_at
       and status='accrued'
  ) then
    raise exception using
      message = 'first-year senior base accrual was not 30% of net cash ex GST';
  end if;
  if not exists(
    select 1 from public.consultant_commission_accruals
     where id=v_bonus_accrual and commission_phase='anniversary_bonus'
       and basis_cents=10000 and rate_bps=1000 and commission_cents=1000
       and eligible_at=onboarding_started_at+interval '12 months'
       and status='accrued'
  ) then
    raise exception using
      message = 'senior anniversary accrual was not deferred 10%';
  end if;
  perform app.accrue_consultant_invoice_v78(v_first_invoice);
  if (select count(*) from public.consultant_commission_accruals
       where invoice_id=v_first_invoice)<>2 then
    raise exception 'duplicate paid invoice changed the two-component accrual';
  end if;

  -- Exactly at the 12-month anniversary is renewal, not first-year.
  insert into public.billing_provider_invoices(
    business_id,provider_customer_id,provider_subscription_id,
    provider_invoice_id,currency,collection_method,status,paid_normalized,
    subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,
    amount_paid_cents,amount_remaining_cents,net_cash_ex_tax_cents,
    paid_at,livemode,provider_event_created_at,provider_event_rank,last_event_id
  ) values (
    v_business,'cus_v78','sub_v78','in_v78_renewal','SGD',
    'charge_automatically','paid',true,10000,900,10900,10900,10900,0,10000,
    v_anchor+interval '12 months',false,v_anchor+interval '12 months',100,
    'evt_v78_renewal'
  ) returning id into v_renewal_invoice;
  select id into strict v_renewal_accrual
    from public.consultant_commission_accruals where invoice_id=v_renewal_invoice;
  if not exists(
    select 1 from public.consultant_commission_accruals
     where id=v_renewal_accrual and commission_phase='renewal'
       and rate_bps=1500 and commission_cents=1500
  ) then
    raise exception using
      message = '12-month anniversary did not use the 15% renewal rate';
  end if;

  -- Refund then chargeback append negative compensation and cap at original.
  insert into public.billing_adjustments(
    business_id,provider_invoice_id,adjustment_type,subtotal_ex_tax_cents,
    tax_cents,total_cents,currency,source_event_id,provider_object_id,
    reason,evidence_sha256,occurred_at
  ) values (
    v_business,'in_v78_first','refund',-1000,-90,-1090,'SGD',
    'evt_v78_refund','re_v78','rollback refund',repeat('a',64),now()
  ) returning id into v_refund_adjustment;
  select id into strict v_refund_commission_adjustment
    from public.consultant_commission_adjustments
   where billing_adjustment_id=v_refund_adjustment
     and accrual_id=v_first_accrual;
  if not exists(
    select 1 from public.consultant_commission_adjustments
     where accrual_id=v_first_accrual and adjustment_type='refund'
       and basis_adjustment_cents=-1000 and commission_adjustment_cents=-300
  ) then
    raise exception 'refund did not reduce the first-year base component';
  end if;
  if not exists(
    select 1 from public.consultant_commission_adjustments
     where accrual_id=v_bonus_accrual and adjustment_type='refund'
       and basis_adjustment_cents=-1000 and commission_adjustment_cents=-100
  ) then
    raise exception 'refund did not reduce the deferred anniversary component';
  end if;
  insert into public.billing_adjustments(
    business_id,provider_invoice_id,adjustment_type,subtotal_ex_tax_cents,
    tax_cents,total_cents,currency,source_event_id,provider_object_id,
    reversal_of,reason,evidence_sha256,occurred_at
  ) values (
    v_business,'in_v78_first','reversal',1000,90,1090,'SGD',
    'evt_v78_refund_reversed','rv_v78',v_refund_adjustment,
    'rollback refund reversal',repeat('c',64),now()
  );
  if not exists(
    select 1 from public.consultant_commission_adjustments
     where accrual_id=v_first_accrual and adjustment_type='reversal'
       and reversal_of=v_refund_commission_adjustment
       and basis_adjustment_cents=1000 and commission_adjustment_cents=300
  ) then
    raise exception 'refund reversal did not append exact positive commission compensation';
  end if;
  insert into public.billing_adjustments(
    business_id,provider_invoice_id,adjustment_type,subtotal_ex_tax_cents,
    tax_cents,total_cents,currency,source_event_id,provider_object_id,
    reason,evidence_sha256,occurred_at
  ) values (
    v_business,'in_v78_first','chargeback',-10000,-900,-10900,'SGD',
    'evt_v78_chargeback','dp_v78','rollback chargeback',repeat('b',64),now()
  );
  if (select sum(commission_adjustment_cents)
       from public.consultant_commission_adjustments
       where accrual_id=v_first_accrual)<>-3000
     or (select sum(commission_adjustment_cents)
           from public.consultant_commission_adjustments
          where accrual_id=v_bonus_accrual)<>-1000 then
    raise exception 'chargeback did not cap both commission components';
  end if;

  -- Approval, allocation and two partial payments finish at the bounded total.
  perform pg_temp.as_v78_user(v_admin);
  perform public.approve_consultant_accrual_v78(
    v_renewal_accrual,'rollback payout approval'
  );
  v_batch:=public.create_consultant_payout_batch_v78('SGD','rollback partial payout');
  v_line:=public.add_consultant_payout_line_v78(v_batch,v_renewal_accrual,1500);
  perform public.approve_consultant_payout_batch_v78(v_batch);
  perform public.record_consultant_payout_v78(
    v_line,500,'V78-PARTIAL-1',now()
  );
  v_result:=public.get_consultant_commission_dashboard_v78(v_consultant,100);
  if not exists(
    select 1
      from jsonb_array_elements(v_result->'payout_lines') line
     where (line->>'line_id')::uuid=v_line
       and (line->>'paid_amount_cents')::integer=500
       and (line->>'remaining_cents')::integer=1000
       and (line->>'recordable')::boolean
  ) then
    raise exception 'dashboard omitted recordable partial payout line';
  end if;
  perform public.record_consultant_payout_v78(
    v_line,1000,'V78-PARTIAL-2',now()
  );
  reset role;
  if (select sum(amount_cents) from public.consultant_payout_payments
       where line_id=v_line)<>1500
     or not exists(
       select 1 from public.consultant_payout_batches
        where id=v_batch and status='paid'
     )
     or not exists(
       select 1 from public.consultant_commission_accruals
        where id=v_renewal_accrual and status='paid'
     ) then
    raise exception 'partial payout exceeded or skipped bounded lifecycle';
  end if;

  -- Existing v75 directory deactivation must invoke v78 forfeiture atomically.
  perform pg_temp.as_v78_user(v_admin);
  perform public.platform_upsert_consultant_v75(
    v_consultant,v_consultant_user,'V78 Senior Consultant','senior',
    (v_anchor-interval '1 month')::date,false
  );
  reset role;
  if not exists(
    select 1 from public.platform_consultants
     where id=v_consultant and not active and departed_at is not null
  ) or not exists(
    select 1 from public.consultant_commission_accruals
     where id=v_first_accrual and status='forfeited'
  ) or not exists(
    select 1 from public.consultant_commission_accruals
     where id=v_bonus_accrual and status='forfeited'
  ) then
    raise exception 'v75 deactivation bypassed consultant forfeiture';
  end if;
  if not exists(
    select 1 from public.consultant_commission_accruals
     where id=v_renewal_accrual and status='paid'
  ) then
    raise exception 'previously paid consultant commission was not final';
  end if;

  -- Paid invoices after departure retain a snapshot but forfeit to Nestly.
  insert into public.billing_provider_invoices(
    business_id,provider_customer_id,provider_subscription_id,
    provider_invoice_id,currency,collection_method,status,paid_normalized,
    subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,
    amount_paid_cents,amount_remaining_cents,net_cash_ex_tax_cents,
    paid_at,livemode,provider_event_created_at,provider_event_rank,last_event_id
  ) values (
    v_business,'cus_v78','sub_v78','in_v78_future','SGD',
    'charge_automatically','paid',true,10000,900,10900,10900,10900,0,10000,
    now(),false,now(),100,'evt_v78_future'
  ) returning id into v_future_invoice;
  if not exists(
    select 1 from public.consultant_commission_accruals
     where invoice_id=v_future_invoice and status='forfeited'
       and forfeiture_reason like '%forfeited to Nestly%'
  ) then
    raise exception 'future paid invoice was not forfeited to Nestly';
  end if;
end
$v78_test$;

rollback;
