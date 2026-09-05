-- nestly_v779 — the platform console can read a firm's payments, branch by branch.
--
-- OWNER, 2026-09-05 (three photos): clicking a Case-won card in the onboarding kanban should
-- open the company and show its transactions "broken down to each branch like how businesses
-- see it", with a way straight into the firm record; the firm record itself should carry the
-- same payment history ("Cubbly SPA paid on 5 Sep 2026 · renews on 5 Sep 2027").
--
-- The business's own page reads get_business_billing_v146 — a member-scoped reader that does not
-- carry the v764/v775 invoice reason or the branch each charge paid for. This is the platform
-- side of the same facts: one read, open to a super admin (app.is_super_admin) or to the
-- consultant assigned to the firm (app.platform_firm_report_access_v94, the firm record's own guard),
-- returning the branches, the live subscription and every mirrored provider invoice with the
-- reason and detail the applier wrote (branch_added → branch_id/branch_name, capacity_increase →
-- sizes, initial/renewal → the plan). The grouping into "per branch" is a presentation concern
-- and stays in the console; the RPC hands over facts, never a layout.
--
-- Read-only. STABLE. No DML. Nothing here changes what is charged or when.

begin;

create or replace function public.platform_get_business_payments_v779(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
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
    'branches', coalesce((
      select jsonb_agg(jsonb_build_object(
        'branch_id', b.id, 'name', b.name, 'is_default', b.is_default, 'active', b.active,
        'billing_state', b.billing_state, 'billing_cancel_at', b.billing_cancel_at,
        'created_at', b.created_at)
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
$function$;

comment on function public.platform_get_business_payments_v779(uuid) is
  'nestly_v779: platform read of one firm''s branches, subscription and mirrored provider invoices (with reason/detail) for the per-branch payment history. Scope = app.platform_firm_report_access_v94.';

revoke all on function public.platform_get_business_payments_v779(uuid) from public, anon;
grant execute on function public.platform_get_business_payments_v779(uuid) to authenticated, service_role;

commit;
