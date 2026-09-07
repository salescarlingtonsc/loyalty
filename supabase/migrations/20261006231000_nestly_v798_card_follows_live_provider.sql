-- nestly_v798 — only the provider billing TODAY may name the card, and the business can see it.
--
-- OWNER, 2026-09-06, looking at two firm records side by side: "why some there's card number but
-- some dont have? this card number is correct." and "make sure the business view also able to see
-- which card they are using."
--
-- The difference was not cards. It was PROVIDERS.
--
--   Cafe 111 / Cafe 312 / cs cafe on / Cafe Only / Jess Salon / Cafe2U carry
--   billing_provider_customers rows written by the RAZORPAY path, which did return a brand and a
--   last4 in its webhooks, so "MasterCard ending 9037" was stored. Those subscriptions are
--   Razorpay SANDBOX artifacts: no money ever moved, and Razorpay is retired, so nothing will ever
--   charge that card. The firm on Stripe shows no digits because it was paid through Link, whose
--   payment method carries neither brand nor last4 (v796).
--
--   So the console was displaying, with full confidence, a real card number attached to a
--   subscription that cannot renew — beside an "Auto deduction - On" pill. The one firm that
--   genuinely does auto-renew was the one that looked less trustworthy.
--
-- v792 already established the rule for this exact situation: a subscription on a retired provider
-- is not a live plan. The payment method escaped that rule in BOTH readers. This applies the same
-- gate to both, so a card is shown only when the provider that stored it is the provider billing
-- today. The six sandbox firms stop naming a card; nothing else changes.
--
-- Read-only. STABLE. No DML. Nothing here changes what is charged, when, or to whom.
-- Rollback suite: db/tests/v798_card_follows_live_provider.sql

begin;

do $v798_assert$
begin
  if position('platform_billing_provider_v792'
       in pg_get_functiondef('public.get_business_billing_v758(uuid)'::regprocedure)) > 0 then
    raise exception 'v798: get_business_billing_v758 already gates the card on the provider';
  end if;
end
$v798_assert$;

-- =============================================================================================
-- 1 - The BUSINESS's own reader.
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.get_business_billing_v758(p_business uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  /* Delegating is the tenant guard: v125 -> v124 -> v77 all raise 42501 unless the caller is the
     active billing owner or a super admin, and v125 asserts the payload carries no GST claim. */
  v_payload jsonb := public.get_business_billing_v125(p_business);
  v_terms jsonb := v_payload->'terms';
  v_cadence text;
  v_capacity integer;
  v_unit_amount_cents integer;
  v_total integer := 0;
  v_included integer := 0;
  v_billable integer := 0;
  v_stopping integer := 0;
  v_lapsed integer := 0;
  v_unsubscribed integer := 0;
  v_branches_total integer := 0;
  v_units integer := 1;
  v_state text;
  v_trial_ends_at timestamptz;
  v_cancel_at_period_end boolean := coalesce((v_payload->>'cancel_at_period_end')::boolean,false);
  v_status text := v_payload->>'status';
  v_payment_status text := v_payload->>'payment_status';
  v_plan_label text;
  v_payment_method jsonb;
  /* v765 */
  v_subscription public.subscriptions%rowtype;
  v_renewal_cancel_final_after timestamptz;
  v_scheduled_change jsonb;
begin
  if jsonb_typeof(v_terms) = 'object' then
    v_cadence := nullif(v_terms->>'cadence','');
    v_capacity := nullif(v_terms->>'customer_capacity','')::integer;
  end if;
  v_plan_label := case v_cadence when 'annual' then 'Annual'
                                 when 'monthly' then 'Monthly' else null end;

  select * into v_subscription from public.subscriptions s where s.business_id = p_business;
  v_trial_ends_at := v_subscription.trial_ends_at;

  /* The same counts the browser was doing by hand. `included` is its own state, so the first
     branch is never in the billable set — units is 1 (the included one) plus every branch the
     tenant is actually being charged for. */
  select count(*)::integer,
         count(*) filter (where branch.billing_state = 'included')::integer,
         count(*) filter (where branch.billing_state in ('pending_payment','active') and branch.billing_mode = 'shared')::integer,
         count(*) filter (where branch.billing_state = 'canceling')::integer,
         count(*) filter (where branch.billing_state = 'suspended')::integer,
         count(*) filter (where branch.billing_state = 'unsubscribed')::integer
    into v_branches_total, v_included, v_billable, v_stopping, v_lapsed, v_unsubscribed
    from public.branches branch
   where branch.business_id = p_business;
  v_units := 1 + v_billable;

  if v_cadence is not null and v_capacity is not null then
    select tier.amount_cents into v_unit_amount_cents
      from public.billing_capacity_tier_catalog_v664 tier
     where tier.currency = 'SGD' and tier.active
       and tier.cadence = v_cadence
       and tier.capacity_ceiling = v_capacity
       and tier.effective_from <= now()
       and (tier.effective_to is null or tier.effective_to > now())
     order by tier.effective_from desc
     limit 1;
  end if;
  v_total := coalesce(v_unit_amount_cents,0) * v_units;

  if v_terms is null or jsonb_typeof(v_terms) <> 'object' then
    v_state := case when v_trial_ends_at is not null and v_trial_ends_at > now()
                    then 'trial' else 'none' end;
  else
    v_state := case
      when v_status = 'canceled' then 'canceled'
      when v_status = 'unpaid' then 'unpaid'
      /* v765: a renewal the owner has asked to stop reads 'canceling' from the moment they ask,
         not from the moment the provider is told. The intent is what the tenant experiences. */
      when v_subscription.renewal_cancel_requested_at is not null then 'canceling'
      when v_cancel_at_period_end then 'canceling'
      when v_payment_status = 'failed' then 'past_due'
      when v_status = 'trialing' then 'trial'
      when v_status = 'active' then 'active'
      else 'none' end;
  end if;

  /* Resume is offered right up to the moment the reconciler transmits the cancel, which is
     inside the last 48 hours of the period. Saying the date is the whole point of ruling 4. */
  if v_subscription.renewal_cancel_requested_at is not null
     and v_subscription.current_period_end is not null then
    v_renewal_cancel_final_after := v_subscription.current_period_end - interval '48 hours';
  end if;

  if v_subscription.scheduled_cadence is not null
     or v_subscription.scheduled_effective_at is not null then
    v_scheduled_change := jsonb_build_object(
      'kind','cadence',
      'cadence', v_subscription.scheduled_cadence,
      'plan_label', case v_subscription.scheduled_cadence
                      when 'annual' then 'Annual'
                      when 'monthly' then 'Monthly' else null end,
      'plan_id', v_subscription.scheduled_plan_id,
      'effective_at', v_subscription.scheduled_effective_at,
      'amount_cents', v_subscription.scheduled_amount_cents
    );
  end if;

  select jsonb_build_object(
           'kind', customer.payment_method_kind,
           'brand', customer.payment_method_brand,
           'last4', customer.payment_method_last4,
           'updated_at', customer.payment_method_updated_at
         )
    into v_payment_method
    from public.billing_provider_customers customer
   where customer.business_id = p_business
     and customer.payment_method_kind is not null
     /* v798: a card belonging to a RETIRED provider is not the card that will be charged.
        v792 already refuses to present a subscription on a retired provider as a live plan; the
        payment method escaped that rule, so six firms whose Razorpay-era card was stored still
        read "MasterCard ending 9037 - Auto deduction On" against a subscription that can never
        renew. Same gate, same reason: only the provider billing TODAY can name the card. */
     and customer.provider = app.platform_billing_provider_v792();

  return v_payload || jsonb_build_object(
    'payment_method', v_payment_method,
    'summary', jsonb_build_object(
      'plan_label', v_plan_label,
      'capacity', v_capacity,
      'branches_total', v_branches_total,
      'branches_included', v_included,
      'branches_billable', v_billable,
      'branches_stopping', v_stopping,
      'branches_lapsed', v_lapsed,
      'branches_unsubscribed', v_unsubscribed,
      'unit_amount_cents', v_unit_amount_cents,
      'units', v_units,
      'total_cents', v_total,
      'renews_at', coalesce(v_payload->>'next_payment_at', v_payload->>'current_period_end'),
      'state', v_state,
      'trial_ends_at', v_trial_ends_at,
      'cancel_at_period_end', v_cancel_at_period_end,
      /* v765 */
      'renewal_cancel_requested_at', v_subscription.renewal_cancel_requested_at,
      'renewal_cancel_sent_at', v_subscription.renewal_cancel_sent_at,
      'renewal_cancel_final_after', v_renewal_cancel_final_after,
      'renewal_cancel_is_final', v_subscription.renewal_cancel_sent_at is not null,
      'scheduled_change', v_scheduled_change
    )
  );
end
$function$
;

revoke all on function public.get_business_billing_v758(uuid) from public, anon;
grant execute on function public.get_business_billing_v758(uuid) to authenticated;

-- =============================================================================================
-- 2 - The PLATFORM console's reader (company level and per branch).
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.platform_get_business_payments_v779(p_business uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_business public.businesses%rowtype;
begin
  if p_business is null then
    raise exception 'business is required' using errcode='22023';
  end if;
  -- A super admin reads every tenant (CLAUDE.md ruling); a consultant reads the firms assigned
  -- to them, through the same guard the firm record itself uses. Anyone else is refused.
  if not (app.is_super_admin() or app.platform_firm_report_access_v94(p_business)) then
    raise exception 'assigned_platform_report_access_required' using errcode='42501';
  end if;
  select * into v_business from public.businesses where id=p_business;
  if not found then
    raise exception 'business not found' using errcode='P0002';
  end if;

  return jsonb_build_object(
    'as_of', clock_timestamp(),
    'business', jsonb_build_object(
      'business_id', v_business.id, 'name', v_business.name, 'slug', v_business.slug),
    'subscription', (
      select jsonb_build_object(
        'provider_subscription_id', s.provider_subscription_id,
        'status', s.status, 'cadence', s.cadence,
        'current_period_start', s.current_period_start,
        'current_period_end', s.current_period_end,
        'cancel_at_period_end', s.cancel_at_period_end,
        'customer_capacity', (select t.customer_capacity
          from public.billing_subscription_terms_v124 t where t.business_id=p_business limit 1))
      from public.billing_provider_subscriptions s
      where s.business_id=p_business
      order by s.updated_at desc nulls last limit 1),
    /* v797: the card each branch is actually charged on. The console could tell an operator that
       a firm auto-deducts but never WHICH card, so a failed renewal could not be chased ("your
       Visa ending 7820 was declined") without opening Stripe. An own-billed branch pays on its own
       card (v786); every other branch is on the company card. */
    'payment_method', (
      select jsonb_build_object('kind', c.payment_method_kind, 'brand', c.payment_method_brand,
                                'last4', c.payment_method_last4,
                                'updated_at', c.payment_method_updated_at)
        from public.billing_provider_customers c
       where c.business_id=p_business and c.payment_method_kind is not null
         /* v798: only the provider billing TODAY can name the card (see v792). */
         and c.provider = app.platform_billing_provider_v792()),
    'branches', coalesce((
      select jsonb_agg(jsonb_build_object(
        'branch_id', b.id, 'name', b.name, 'is_default', b.is_default, 'active', b.active,
        'billing_state', b.billing_state, 'billing_cancel_at', b.billing_cancel_at,
        'created_at', b.created_at,
        'payment_method', case
          when b.billing_mode = 'own' then (
            select jsonb_build_object('kind', s.payment_method_kind, 'brand', s.payment_method_brand,
                                      'last4', s.payment_method_last4,
                                      'updated_at', s.payment_method_updated_at)
              from public.branch_subscriptions_v786 s
             where s.branch_id = b.id and s.payment_method_kind is not null
               and s.provider = app.platform_billing_provider_v792())
          else (
            select jsonb_build_object('kind', c.payment_method_kind, 'brand', c.payment_method_brand,
                                      'last4', c.payment_method_last4,
                                      'updated_at', c.payment_method_updated_at)
              from public.billing_provider_customers c
             where c.business_id=p_business and c.payment_method_kind is not null
               and c.provider = app.platform_billing_provider_v792())
          end)
        order by b.is_default desc, b.created_at, b.name)
      from public.branches b where b.business_id=p_business), '[]'::jsonb),
    'invoices', coalesce((
      select jsonb_agg(to_jsonb(rows) order by rows.sort_at desc)
      from (
        select i.provider_invoice_id, i.number, i.status, i.paid_normalized, i.currency,
          i.total_cents, i.amount_paid_cents, i.amount_remaining_cents, i.collection_method,
          i.period_start, i.period_end, i.paid_at, i.created_at,
          i.reason, i.detail, i.provider_receipt_url, i.hosted_invoice_url, i.livemode,
          coalesce(i.paid_at, i.created_at) sort_at
        from public.billing_provider_invoices i
        where i.business_id=p_business
        order by coalesce(i.paid_at, i.created_at) desc
        limit 100
      ) rows), '[]'::jsonb)
  );
end
$function$
;

revoke all on function public.platform_get_business_payments_v779(uuid) from public, anon;
grant execute on function public.platform_get_business_payments_v779(uuid) to authenticated;

commit;
