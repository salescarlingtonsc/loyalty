-- nestly_v756 — a self-serve tenant's paid provider invoice IS verified initial payment (2026-09-04).
--
-- THE BUG, observed in production today. app.v510_verified_initial_payment derives a tenant's
-- obligation ONLY from public.sme_commercial_terms, joined through subscriptions.commercial_terms_id.
-- That join is an INNER join, so a self-serve tenant — one that signed up and paid through the
-- provider's own checkout, with no assisted-sale paperwork — has no obligation row at all, and
-- therefore no evidence can ever match. app.v510_sync_payment_readiness fires from triggers on
-- billing_provider_invoices and subscriptions, reads that NULL, and overwrites payment_status back
-- to 'not_collected', nulling last_paid_at and the three initial_payment_* columns, moments after a
-- real Razorpay charge settled.
--
-- Live example (business 709387ff-5768-4767-9dad-abd665c2bb07): subscriptions.billing_provider
-- 'razorpay', commercial_terms_id NULL, period_total_cents 168800 SGD; billing_provider_invoices
-- inv_TXttE3oaLvaEdZ paid, amount_paid 168800, amount_remaining 0, against provider_subscription_id
-- sub_TXttD4l7HV8vQb. Result: status 'active' but payment_status 'not_collected'.
--
-- OWNER RULING (2026-09-04). When subscriptions.commercial_terms_id is null and billing_provider is
-- one the provider collects automatically ('stripe','razorpay'), a paid provider invoice raised
-- against that tenant's own provider_subscription_id, in the subscription's currency, for exactly
-- the subscription's period_total_cents, fully paid, nothing outstanding, and not refunded or
-- charged back, IS verified initial-payment evidence. Its source is 'provider_invoice_self_serve'.
--
-- Assisted-sale tenants (commercial_terms_id NOT null) are untouched: they keep the strict contract
-- match, including the Singapore service-day window, exactly as before. The new arm is a THIRD union
-- branch over a disjoint population — a subscription cannot be both self-serve and contracted — so
-- no tenant can satisfy two arms of the union with the same paperwork.
--
-- The body below is the LIVE definition read from production with pg_get_functiondef (it carries
-- v755's provider relaxation and the app.sg_day() service-day normalisation, neither of which is in
-- the v510 source file) plus the new branch. Grants are restated verbatim from the live proacl,
-- which is `{postgres=X/postgres}` — the function is not callable by public, anon or authenticated.
--
-- Rollback suite: db/tests/v756_self_serve_payment_evidence.sql
--                 db/tests/executed/v756_corpus_self_serve_payment_evidence.sql
--   LC_ALL=C node scripts/db-tests/run.mjs --filter=v756_corpus --migrated-only

begin;

-- =============================================================================================
-- 0 · The evidence-source vocabulary admits the new source.
-- =============================================================================================
-- subscriptions_initial_payment_source_check enumerates the sources v510 could produce
-- ('stripe_invoice','manual_payment'). Without this the new branch's very first projection
-- raises 23514 inside app.v510_sync_payment_readiness, which runs from a trigger — so the
-- invoice insert itself would fail. Widened, never loosened to "anything".
alter table public.subscriptions
  drop constraint if exists subscriptions_initial_payment_source_check;
alter table public.subscriptions
  add constraint subscriptions_initial_payment_source_check
  check (initial_payment_source is null
    or initial_payment_source in ('stripe_invoice','manual_payment','provider_invoice_self_serve'));

-- =============================================================================================
-- 1 · A self-serve provider payment is evidence.
-- =============================================================================================
create or replace function app.v510_verified_initial_payment(p_business uuid)
returns jsonb language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
  with obligation as (
    select subscription.* from public.subscriptions subscription
    join public.sme_commercial_terms terms on terms.id=subscription.commercial_terms_id
    where subscription.business_id=p_business and terms.contract_status in ('accepted','signed')
      and terms.accepted_value_cents>0
  ), self_serve as (
    -- No commercial terms exist for this tenant, so there is no contract period to match against.
    -- The subscription row itself is the obligation: its currency and its period total.
    select subscription.* from public.subscriptions subscription
    where subscription.business_id=p_business
      and subscription.commercial_terms_id is null
      and subscription.billing_provider in ('stripe','razorpay')
      and subscription.period_total_cents>0
      and subscription.provider_subscription_id is not null
  ), evidence as (
    select 'stripe_invoice' source,invoice.id evidence_id,invoice.paid_at verified_at
    from obligation join public.billing_provider_invoices invoice
      on invoice.business_id=obligation.business_id
      and invoice.provider_subscription_id=obligation.provider_subscription_id
    where obligation.billing_provider in ('stripe','razorpay') and invoice.paid_normalized and invoice.status='paid'
      and invoice.currency=obligation.currency
      and invoice.amount_paid_cents=obligation.period_total_cents
      and invoice.amount_remaining_cents=0 and invoice.total_cents=obligation.period_total_cents
      and app.sg_day(invoice.period_start)=obligation.obligation_period_start
      and (app.sg_day(invoice.period_end)=obligation.obligation_period_end
        or app.sg_day(invoice.period_end)=obligation.obligation_period_end+1)
      and not exists(select 1 from public.billing_adjustments adjustment
        where adjustment.provider_invoice_id=invoice.provider_invoice_id
          and adjustment.adjustment_type in ('refund','chargeback'))
    union all
    select 'provider_invoice_self_serve',invoice.id,invoice.paid_at
    from self_serve join public.billing_provider_invoices invoice
      on invoice.business_id=self_serve.business_id
      and invoice.provider_subscription_id=self_serve.provider_subscription_id
    where invoice.paid_normalized and invoice.status='paid'
      and invoice.currency=self_serve.currency
      and invoice.amount_paid_cents=self_serve.period_total_cents
      and invoice.amount_remaining_cents=0
      and invoice.total_cents=self_serve.period_total_cents
      and not exists(select 1 from public.billing_adjustments adjustment
        where adjustment.provider_invoice_id=invoice.provider_invoice_id
          and adjustment.adjustment_type in ('refund','chargeback'))
    union all
    select 'manual_payment',payment.id,payment.verified_at
    from obligation join public.platform_subscription_documents_v156 document
      on document.business_id=obligation.business_id and document.document_type='invoice'
    join public.platform_manual_payments_v156 payment
      on payment.invoice_document_id=document.id and payment.status='verified'
    where obligation.billing_provider='manual' and document.provider_invoice_id is null
      and document.currency=obligation.currency
      and document.total_cents=obligation.period_total_cents
      and payment.amount_cents=obligation.period_total_cents
      and document.service_period_start=obligation.obligation_period_start
      and document.service_period_end=obligation.obligation_period_end
  ) select jsonb_build_object('source',source,'evidence_id',evidence_id,'verified_at',verified_at)
    from evidence order by verified_at limit 1
$$;
revoke all on function app.v510_verified_initial_payment(uuid) from public,anon,authenticated;

-- =============================================================================================
-- 2 · Re-project every tenant this changes.
-- =============================================================================================
-- The readiness projection is only recomputed by triggers on billing_provider_invoices and
-- subscriptions, so a tenant whose invoice settled BEFORE this migration keeps the wrong
-- payment_status until something writes to one of those tables again. Re-project them here.
-- Bounded to the population the new branch can possibly change (self-serve, provider-collected,
-- with a paid matching invoice), and audited one row per business so the change is attributable.
-- Guarded by `not exists` over its own audit action, so re-running the block is a no-op.
do $v756_reproject$
declare
  v_business uuid;
  v_count integer := 0;
  v_evidence jsonb;
begin
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
    v_count := v_count + 1;
  end loop;
  raise notice 'v756 re-projected payment readiness for % self-serve tenant(s)', v_count;
end
$v756_reproject$;

commit;
