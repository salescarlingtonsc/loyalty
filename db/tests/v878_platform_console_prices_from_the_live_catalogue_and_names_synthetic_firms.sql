-- nestly_v878 rollback suite — the platform console prices from the live catalogue, names
-- synthetic firms, and counts wins by the pipeline catalogue.
--
-- Run inside a transaction against production and ROLLED BACK. Impersonates a real super admin
-- (public.super_admins); the console readers write an audit row the rollback discards.

\set ON_ERROR_STOP on

begin;

do $suite$
declare
  sa uuid; r record; expected integer; won_catalogue bigint; won_closed_only bigint; analytics jsonb; n integer := 0;
begin
  select user_id into sa from public.super_admins limit 1;
  if sa is null then raise exception 'J0 failed: no super admin to impersonate'; end if;
  -- app.is_super_admin() also demands a Google-OAuth-shaped session (nestly_v625): amr[0].method
  -- = 'oauth' and app_metadata.providers containing 'google'. Same claims the v625 suite mints.
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', sa, 'role', 'authenticated',
    'amr', jsonb_build_array(jsonb_build_object('method', 'oauth')),
    'app_metadata', jsonb_build_object('providers', jsonb_build_array('google')))::text, true);
  perform set_config('request.jwt.claim.sub', sa::text, true);

  -- J1: the list carries is_synthetic
  n := n + 1;
  if pg_get_function_result('public.super_admin_list_businesses()'::regprocedure) not like '%is_synthetic boolean%' then
    raise exception 'J% failed: is_synthetic is not returned', n;
  end if;

  -- J2: every priced firm equals the tenant-page arithmetic normalised to a month
  for r in select * from public.super_admin_list_businesses() loop
    select coalesce((
      select (round(tier.amount_cents::numeric
                    * (1 + (select count(*) from public.branches br2 where br2.business_id = r.business_id
                             and br2.billing_state in ('pending_payment','active') and br2.billing_mode = 'shared'))
                    / greatest(tier.cadence_months, 1)))::int
        from public.billing_subscription_terms_v124 t
        join public.billing_capacity_tier_catalog_v664 tier
          on tier.currency = 'SGD' and tier.active and tier.cadence = t.cadence
         and tier.capacity_ceiling = t.customer_capacity
         and tier.effective_from <= now() and (tier.effective_to is null or tier.effective_to > now())
       where t.business_id = r.business_id
       order by tier.effective_from desc limit 1), 0) into expected;
    if r.est_monthly_cents <> expected then
      raise exception 'J2 failed: % priced % but the catalogue says %', r.name, r.est_monthly_cents, expected;
    end if;
    if r.is_synthetic <> coalesce((select b.is_synthetic from public.businesses b where b.id = r.business_id), false) then
      raise exception 'J2 failed: % is_synthetic mismatch', r.name;
    end if;
  end loop;
  n := n + 1;

  -- J3: no firm with live terms is priced with the retired seat formula (0 or $25 + $10/seat)
  n := n + 1;
  if exists (select 1 from public.super_admin_list_businesses() l
              join public.billing_subscription_terms_v124 t on t.business_id = l.business_id
              join public.billing_capacity_tier_catalog_v664 tier on tier.cadence = t.cadence and tier.capacity_ceiling = t.customer_capacity and tier.active
             where l.est_monthly_cents = 0) then
    raise exception 'J% failed: a firm with catalogue terms is priced at 0', n;
  end if;

  -- J4: "won" includes every catalogue win, never only closed_won
  select count(*) into won_catalogue from public.sme_prospect_stage_history h
   where h.to_stage_key in (select stage_key from public.sme_pipeline_stages where kind = 'won')
     and h.occurred_at >= now() - interval '365 days';
  select count(*) into won_closed_only from public.sme_prospect_stage_history h
   where h.to_stage_key = 'closed_won' and h.occurred_at >= now() - interval '365 days';
  analytics := public.platform_get_sme_analytics_v510((app.sg_today() - 365), app.sg_today(), null, null, 50, null);
  n := n + 1;
  if (analytics #>> '{summary,won}')::bigint <> won_catalogue then
    raise exception 'J% failed: won % <> catalogue wins %', n, analytics #>> '{summary,won}', won_catalogue;
  end if;
  n := n + 1;
  if won_catalogue < won_closed_only then raise exception 'J% failed: catalogue wins cannot be fewer than closed_won alone', n; end if;

  raise notice 'nestly_v878 suite: % assertions passed (won % vs closed_won-only %)', n, won_catalogue, won_closed_only;
end
$suite$;

rollback;
