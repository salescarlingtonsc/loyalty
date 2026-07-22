-- FRENLY v49 — owner-authorized billing projection for business Settings.
-- Fixes the security-invoker view/private helper ACL mismatch without exposing app internals.

begin;

create or replace function public.get_business_billing_v49(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_billable_seats integer;
  v_projection jsonb;
begin
  -- Do not rely on the historical app.is_salon_member helper here: its legacy body
  -- predates staff.active and does not enforce the owner-only Settings boundary.
  if v_actor is null or p_business is null or not exists (
    select 1
      from public.staff staff_member
     where staff_member.business_id = p_business
       and staff_member.user_id = v_actor
       and staff_member.active
       and staff_member.role = 'owner'
  ) then
    raise exception 'active business owner access is required' using errcode = '42501';
  end if;

  -- app.billable_seats remains private. This definer executes it only after the
  -- active owner/business check above and returns a finite billing allowlist.
  v_billable_seats := app.billable_seats(p_business);

  select jsonb_build_object(
    'business_id', business.id,
    'status', coalesce(subscription.status, 'trialing'),
    'currency', coalesce(subscription.currency, 'SGD'),
    'base_price_cents', coalesce(subscription.base_price_cents, 2500),
    'included_seats', coalesce(subscription.included_seats, 1),
    'per_seat_price_cents', coalesce(subscription.per_seat_price_cents, 1000),
    'billable_seats', v_billable_seats,
    'extra_seats', greatest(
      v_billable_seats - coalesce(subscription.included_seats, 1), 0
    ),
    'monthly_total_cents',
      coalesce(subscription.base_price_cents, 2500)::bigint
      + greatest(
          v_billable_seats - coalesce(subscription.included_seats, 1), 0
        )::bigint * coalesce(subscription.per_seat_price_cents, 1000)::bigint,
    'trial_ends_at', subscription.trial_ends_at,
    'current_period_start', subscription.current_period_start,
    'current_period_end', subscription.current_period_end
  )
    into v_projection
    from public.businesses business
    left join public.subscriptions subscription
      on subscription.business_id = business.id
   where business.id = p_business;

  -- Keep nonexistent and unauthorized business identifiers indistinguishable.
  if v_projection is null then
    raise exception 'active business owner access is required' using errcode = '42501';
  end if;

  return v_projection;
end
$$;

revoke all privileges on function public.get_business_billing_v49(uuid)
  from public, anon, authenticated;
grant execute on function public.get_business_billing_v49(uuid)
  to authenticated;

comment on function public.get_business_billing_v49(uuid) is
  'Finite billing projection for an authenticated active owner of the requested business. The private seat counter remains unexposed.';

commit;
