-- EXECUTED acceptance fixture for nestly_v756
-- (db/migrations/20260926_nestly_v756_self_serve_payment_evidence.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v756_corpus --migrated-only
--
-- WHY THIS EXISTS. app.v510_verified_initial_payment derived a tenant's obligation only from
-- public.sme_commercial_terms through an INNER join on subscriptions.commercial_terms_id. A
-- self-serve tenant has no such row, so no provider invoice could ever be evidence, and
-- app.v510_sync_payment_readiness — which fires from triggers on billing_provider_invoices and
-- subscriptions — kept overwriting payment_status back to 'not_collected' right after a real
-- Razorpay charge settled (production: business 709387ff…, invoice inv_TXttE3oaLvaEdZ).
--
-- Every assertion below drives the REAL trigger path: the fixture inserts a mirrored invoice and
-- lets v510's own projector run, rather than calling the evidence function in isolation.
--
-- ASSERTIONS:
--   B1  a self-serve tenant with a matching paid provider invoice reaches payment_status 'paid',
--       last_paid_at set, initial_payment_source 'provider_invoice_self_serve'.
--   B2  the same tenant shape with a MISMATCHED amount stays 'not_collected' — the new branch is
--       an exact-amount match, not "any paid invoice".
--   B3  the same tenant shape with a refund recorded against the invoice stays 'not_collected' —
--       the refund/chargeback exclusion applies to the new branch too.
--   B4  an assisted-sale tenant (commercial_terms_id NOT null) still requires the strict contract
--       match: an invoice with the right money but the wrong service period is NOT evidence, and
--       the same invoice with the contract period IS.
--   B5  the migration's re-projection block is idempotent: running it twice leaves exactly one
--       audit_log row per business (column `detail`, not `meta`).
begin;

do $v756_test$
declare
  v_now timestamptz := now();
  v_b1 uuid; v_b2 uuid; v_b3 uuid; v_b4 uuid;
  v_amount integer := 168800;
  v_tenant public.subscriptions%rowtype;
  v_company uuid; v_prospect uuid; v_terms uuid;
  v_invoice uuid;
  v_business uuid;
  v_pass integer;
  v_count integer;
  v_evidence jsonb;
begin
  -- -------------------------------------------------------------------------------------------
  -- Fixture helper shapes. Four businesses, one subscription each. The scratch harness starts
  -- with zero tenants; everything here is discarded by the enclosing rollback.
  -- -------------------------------------------------------------------------------------------
  insert into public.businesses(name,slug,industry,enabled_modules) values
    ('V756 self-serve paid','v756-b1-'||substr(gen_random_uuid()::text,1,8),'test',array['dashboard']),
    ('V756 self-serve mismatch','v756-b2-'||substr(gen_random_uuid()::text,1,8),'test',array['dashboard']),
    ('V756 self-serve refunded','v756-b3-'||substr(gen_random_uuid()::text,1,8),'test',array['dashboard']),
    ('V756 assisted sale','v756-b4-'||substr(gen_random_uuid()::text,1,8),'test',array['dashboard']);
  select id into v_b1 from public.businesses where name='V756 self-serve paid';
  select id into v_b2 from public.businesses where name='V756 self-serve mismatch';
  select id into v_b3 from public.businesses where name='V756 self-serve refunded';
  select id into v_b4 from public.businesses where name='V756 assisted sale';

  insert into public.subscriptions(business_id) values (v_b1),(v_b2),(v_b3),(v_b4)
    on conflict (business_id) do nothing;

  -- Three self-serve tenants: provider-collected, SGD, no commercial terms at all.
  update public.subscriptions
     set billing_provider='razorpay', billing_cadence='annual', cadence_months=12, currency='SGD',
         commercial_terms_id=null,
         provider_subscription_id='sub_v756_'||left(business_id::text,8),
         period_subtotal_cents=v_amount, period_tax_cents=0, period_total_cents=v_amount
   where business_id in (v_b1,v_b2,v_b3);

  -- -------------------------------------------------------------------------------------------
  -- B1 — a matching paid provider invoice IS evidence for a self-serve tenant.
  -- -------------------------------------------------------------------------------------------
  insert into public.billing_provider_invoices(
    business_id,provider_customer_id,provider_subscription_id,provider_invoice_id,currency,status,
    paid_normalized,subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,amount_paid_cents,
    amount_remaining_cents,period_start,period_end,paid_at,livemode,provider_event_created_at,
    provider_event_rank,last_event_id)
  values (
    v_b1,'cust_v756_b1','sub_v756_'||left(v_b1::text,8),'inv_v756_b1','SGD','paid',
    true,v_amount,0,v_amount,v_amount,v_amount,
    0,v_now,v_now+interval '365 days',v_now,false,v_now,
    10,'evt_v756_b1');

  select * into v_tenant from public.subscriptions where business_id=v_b1;
  if v_tenant.payment_status <> 'paid' then
    raise exception 'B1: self-serve payment_status is % instead of paid', v_tenant.payment_status;
  end if;
  if v_tenant.last_paid_at is null then
    raise exception 'B1: last_paid_at was not set by the self-serve evidence branch';
  end if;
  if v_tenant.initial_payment_source <> 'provider_invoice_self_serve' then
    raise exception 'B1: initial_payment_source is % instead of provider_invoice_self_serve',
      coalesce(v_tenant.initial_payment_source,'<null>');
  end if;
  if v_tenant.initial_payment_verified_at is null or v_tenant.initial_payment_evidence_id is null then
    raise exception 'B1: the evidence shape check left initial_payment_* incomplete';
  end if;

  -- -------------------------------------------------------------------------------------------
  -- B2 — a paid invoice for the WRONG amount is not evidence.
  -- -------------------------------------------------------------------------------------------
  insert into public.billing_provider_invoices(
    business_id,provider_customer_id,provider_subscription_id,provider_invoice_id,currency,status,
    paid_normalized,subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,amount_paid_cents,
    amount_remaining_cents,period_start,period_end,paid_at,livemode,provider_event_created_at,
    provider_event_rank,last_event_id)
  values (
    v_b2,'cust_v756_b2','sub_v756_'||left(v_b2::text,8),'inv_v756_b2','SGD','paid',
    true,v_amount-1,0,v_amount-1,v_amount-1,v_amount-1,
    0,v_now,v_now+interval '365 days',v_now,false,v_now,
    10,'evt_v756_b2');

  select * into v_tenant from public.subscriptions where business_id=v_b2;
  if v_tenant.payment_status <> 'not_collected' then
    raise exception 'B2: a mismatched amount was accepted (payment_status %)', v_tenant.payment_status;
  end if;
  if v_tenant.initial_payment_source is not null then
    raise exception 'B2: a mismatched amount produced evidence source %', v_tenant.initial_payment_source;
  end if;

  -- -------------------------------------------------------------------------------------------
  -- B3 — a refunded invoice is not evidence.
  -- -------------------------------------------------------------------------------------------
  insert into public.billing_provider_invoices(
    business_id,provider_customer_id,provider_subscription_id,provider_invoice_id,currency,status,
    paid_normalized,subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,amount_paid_cents,
    amount_remaining_cents,period_start,period_end,paid_at,livemode,provider_event_created_at,
    provider_event_rank,last_event_id)
  values (
    v_b3,'cust_v756_b3','sub_v756_'||left(v_b3::text,8),'inv_v756_b3','SGD','paid',
    true,v_amount,0,v_amount,v_amount,v_amount,
    0,v_now,v_now+interval '365 days',v_now,false,v_now,
    10,'evt_v756_b3');
  -- Before the refund it must be evidence, otherwise B3 would pass for the wrong reason.
  select * into v_tenant from public.subscriptions where business_id=v_b3;
  if v_tenant.payment_status <> 'paid' then
    raise exception 'B3 precondition: the un-refunded invoice was not evidence (%)',
      v_tenant.payment_status;
  end if;

  insert into public.billing_adjustments(
    business_id,provider_invoice_id,adjustment_type,subtotal_ex_tax_cents,tax_cents,total_cents,
    currency,reason,evidence_sha256,occurred_at)
  values (v_b3,'inv_v756_b3','refund',-v_amount,0,-v_amount,'SGD','v756 rollback fixture',
    repeat('b',64),v_now);
  perform app.v510_sync_payment_readiness(v_b3,null);

  select * into v_tenant from public.subscriptions where business_id=v_b3;
  if v_tenant.payment_status <> 'not_collected' then
    raise exception 'B3: a refunded invoice remained evidence (payment_status %)',
      v_tenant.payment_status;
  end if;
  if v_tenant.initial_payment_source is not null then
    raise exception 'B3: a refunded invoice left source %', v_tenant.initial_payment_source;
  end if;

  -- -------------------------------------------------------------------------------------------
  -- B4 — the assisted-sale contract match is unchanged.
  -- -------------------------------------------------------------------------------------------
  insert into public.sme_companies(legal_name) values ('V756 Assisted Tenant Pte Ltd')
    returning id into v_company;
  insert into public.sme_prospects(company_id, ownership_state, legacy_stage_raw, priority)
  values (v_company,'closed','v756 rollback fixture','normal') returning id into v_prospect;
  insert into public.sme_commercial_terms(prospect_id, version, plan_code, product_code,
    billing_cycle, seats, currency, accepted_value_cents, owner_email, contract_status, accepted_at)
  values (v_prospect,1,'v756-fixture','peekaa-core','annual',1,'SGD',v_amount,
    'v756.fixture@example.com','accepted',v_now - interval '1 hour') returning id into v_terms;

  update public.subscriptions
     set billing_provider='razorpay', billing_cadence='annual', cadence_months=12, currency='SGD',
         commercial_terms_id=v_terms,
         provider_subscription_id='sub_v756_'||left(v_b4::text,8),
         period_subtotal_cents=v_amount, period_tax_cents=0, period_total_cents=v_amount,
         obligation_period_start=app.sg_day(v_now),
         obligation_period_end=app.sg_day(v_now + interval '365 days')
   where business_id=v_b4;

  -- Right money, WRONG service period: the contract arm must refuse it, and the new self-serve
  -- arm must not rescue it, because this tenant HAS commercial terms.
  insert into public.billing_provider_invoices(
    business_id,provider_customer_id,provider_subscription_id,provider_invoice_id,currency,status,
    paid_normalized,subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,amount_paid_cents,
    amount_remaining_cents,period_start,period_end,paid_at,livemode,provider_event_created_at,
    provider_event_rank,last_event_id)
  values (
    v_b4,'cust_v756_b4','sub_v756_'||left(v_b4::text,8),'inv_v756_b4','SGD','paid',
    true,v_amount,0,v_amount,v_amount,v_amount,
    0,v_now - interval '90 days',v_now + interval '275 days',v_now,false,v_now,
    10,'evt_v756_b4') returning id into v_invoice;

  select * into v_tenant from public.subscriptions where business_id=v_b4;
  if v_tenant.payment_status <> 'not_collected' then
    raise exception 'B4: an out-of-period invoice satisfied an assisted-sale contract (%)',
      v_tenant.payment_status;
  end if;

  update public.billing_provider_invoices
     set period_start=v_now, period_end=v_now + interval '365 days'
   where id=v_invoice;
  select * into v_tenant from public.subscriptions where business_id=v_b4;
  if v_tenant.initial_payment_source <> 'stripe_invoice' then
    raise exception 'B4: the in-period contract invoice produced source %',
      coalesce(v_tenant.initial_payment_source,'<null>');
  end if;

  -- -------------------------------------------------------------------------------------------
  -- B5 — the migration's re-projection block, run twice, writes one audit row per business.
  --      This is a verbatim copy of the DO block in the migration, executed as two passes.
  -- -------------------------------------------------------------------------------------------
  for v_pass in 1..2 loop
    for v_business in
      select distinct subscription.business_id
        from public.subscriptions subscription
        join public.billing_provider_invoices invoice
          on invoice.business_id = subscription.business_id
         and invoice.provider_subscription_id = subscription.provider_subscription_id
       where subscription.commercial_terms_id is null
         and subscription.billing_provider in ('stripe','razorpay')
         and subscription.provider_subscription_id is not null
         and subscription.period_total_cents > 0
         and invoice.paid_normalized
         and invoice.status = 'paid'
         and invoice.currency = subscription.currency
         and invoice.amount_paid_cents = subscription.period_total_cents
         and invoice.amount_remaining_cents = 0
         and invoice.total_cents = subscription.period_total_cents
         and not exists (
           select 1 from public.billing_adjustments adjustment
            where adjustment.provider_invoice_id = invoice.provider_invoice_id
              and adjustment.adjustment_type in ('refund','chargeback'))
         and not exists (
           select 1 from public.audit_log entry
            where entry.business_id = subscription.business_id
              and entry.action = 'SELF_SERVE_PAYMENT_EVIDENCE_REPROJECTED_V756')
       order by 1
    loop
      perform app.v510_sync_payment_readiness(v_business, null);
      v_evidence := app.v510_verified_initial_payment(v_business);
      insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
      values (
        v_business, null, 'SELF_SERVE_PAYMENT_EVIDENCE_REPROJECTED_V756', 'subscriptions', v_business,
        jsonb_build_object(
          'source', v_evidence->>'source',
          'evidence_id', v_evidence->>'evidence_id',
          'verified_at', v_evidence->>'verified_at',
          'reason', 'v756 self-serve provider invoices became verified initial-payment evidence'
        )
      );
    end loop;
  end loop;

  -- Only B1 qualifies: B2's amount does not match, B3 is refunded, B4 has commercial terms.
  select count(*)::integer into v_count from public.audit_log
   where action='SELF_SERVE_PAYMENT_EVIDENCE_REPROJECTED_V756';
  if v_count <> 1 then
    raise exception 'B5: expected exactly one re-projection audit row after two passes, found %',
      v_count;
  end if;
  select count(*)::integer into v_count from public.audit_log
   where action='SELF_SERVE_PAYMENT_EVIDENCE_REPROJECTED_V756'
     and business_id=v_b1
     and detail->>'source'='provider_invoice_self_serve';
  if v_count <> 1 then
    raise exception 'B5: the audit row did not name the self-serve source in `detail` (% rows)',
      v_count;
  end if;

  raise notice 'v756_corpus: B1-B5 passed';
end
$v756_test$;

rollback;
