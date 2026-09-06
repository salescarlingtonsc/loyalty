-- nestly_v797 — the platform console can see WHICH card a firm is charged on.
--
-- OWNER, 2026-09-06: "please ensure my www.peekaa.asia/admin has it reflected as well".
--
-- The Branches tab of a firm already answered "is this auto-deducting?" — it could not answer
-- "on what?". Nothing in platform-console.js referenced a payment method at all, and this reader
-- returned none, so an operator chasing a failed renewal could not say "your Visa ending 7820 was
-- declined" without leaving Peekaa and opening Stripe. The business itself has been able to see
-- its own card since v758; the people doing the chasing could not.
--
-- Adds `payment_method` twice, deliberately: once at the top level (the company card) and once per
-- branch, resolved the way v786 bills — an own-billed branch pays on ITS OWN card, every other
-- branch on the company's. Resolving it here rather than in the console keeps the two apps from
-- disagreeing about who pays for what.
--
-- Read-only. STABLE. No DML. Nothing here changes what is charged, when, or to whom.
-- Rollback suite: db/tests/v797_console_payment_method.sql

begin;

do $v797_assert$
begin
  if position('payment_method'
       in pg_get_functiondef('public.platform_get_business_payments_v779(uuid)'::regprocedure)) > 0 then
    raise exception 'v797: platform_get_business_payments_v779 already returns a payment method';
  end if;
end
$v797_assert$;

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
       where c.business_id=p_business and c.payment_method_kind is not null),
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
             where s.branch_id = b.id and s.payment_method_kind is not null)
          else (
            select jsonb_build_object('kind', c.payment_method_kind, 'brand', c.payment_method_brand,
                                      'last4', c.payment_method_last4,
                                      'updated_at', c.payment_method_updated_at)
              from public.billing_provider_customers c
             where c.business_id=p_business and c.payment_method_kind is not null)
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
