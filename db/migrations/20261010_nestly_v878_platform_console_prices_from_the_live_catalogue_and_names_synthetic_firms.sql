-- nestly_v878 — the platform console prices every firm from the live catalogue, names the
--               synthetic ones, and counts a deal as won by what the pipeline catalogue says.
--
-- WHAT WAS LIVE, AND WHY IT IS WRONG.
--
--   (A) public.super_admin_list_businesses priced every firm with the retired v14 seat plan
--       (subscriptions.base_price_cents + extra seats x per_seat_price_cents — the $25 + $10
--       formula) although the live product has sold capacity tiers from
--       public.billing_capacity_tier_catalog_v664 since v664/v758. The console's overview and
--       Firms directory therefore projected SGD 185/month across 7 active subscriptions whose
--       contracted value is SGD 7,264/year — ~3.3x understated. The tenant's own Subscription
--       page (get_business_billing_v758) already prices correctly.
--
--       The same reader hid nothing about synthetic tenants: 8 of the 24 firms it lists are
--       QA or synthetic, and the console counted them as firms, seats and trials.
--       businesses.is_synthetic is the platform's own flag for that; the list now carries it so
--       every console count can exclude what it marks. (Flagging the QA tenants that are NOT yet
--       marked is a data decision for the owner; this migration flips no flags.)
--
--   (B) public.platform_get_sme_analytics_v510 counted "won" as transitions into the one hard-
--       coded stage 'closed_won'. The pipeline catalogue (public.sme_pipeline_stages.kind) says
--       two stages are wins — 'activated' (system) and 'closed_won' — so a prospect that
--       activated counted as never won: "Deals won 0" beside "Activated 21".
--
-- THE FIX.
--   (A) est_monthly_cents is the tenant-page arithmetic: the catalogue tier for the firm's
--       (cadence, customer_capacity) x (1 + billable shared branches), normalised to a month
--       (annual / 12). No terms, no price: 0, as before. A new is_synthetic column is returned;
--       the return type changes, so the function is dropped and recreated with its ACL restated.
--   (B) "won" = any stage whose catalogue kind is 'won', patched in place (extract-and-diff, the
--       fragment occurs exactly twice and both are replaced).

begin;

-- ---------------------------------------------------------------------------------------------
-- (A)
-- ---------------------------------------------------------------------------------------------
drop function if exists public.super_admin_list_businesses();

create function public.super_admin_list_businesses()
returns table(business_id uuid, name text, industry text, branch_count integer, staff_count integer,
              client_count integer, billable_seats integer, subscription_status text,
              est_monthly_cents integer, is_synthetic boolean)
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
begin
  if not app.is_super_admin() then
    raise exception 'super admin only' using errcode = '42501';
  end if;
  insert into public.audit_log(business_id, actor, action, entity, detail)
    values (null, auth.uid(), 'READ', 'businesses',
            jsonb_build_object('fn','super_admin_list_businesses'));
  return query
    select b.id, b.name, b.industry,
           (select count(*)::int from public.branches br where br.business_id = b.id),
           (select count(*)::int from public.staff    s  where s.business_id  = b.id),
           (select count(*)::int from public.clients  c  where c.business_id  = b.id and not c.is_synthetic),
           app.billable_seats(b.id),
           coalesce(sub.status, 'none'),
           -- nestly_v878: the live catalogue price, the way get_business_billing_v758 computes it,
           -- normalised to a month. The v14 seat plan is retired and priced nothing real.
           coalesce((
             select (round(tier.amount_cents::numeric
                           * (1 + (select count(*) from public.branches br2
                                    where br2.business_id = b.id
                                      and br2.billing_state in ('pending_payment','active')
                                      and br2.billing_mode = 'shared'))
                           / greatest(tier.cadence_months, 1)))::int
               from public.billing_subscription_terms_v124 t
               join public.billing_capacity_tier_catalog_v664 tier
                 on tier.currency = 'SGD' and tier.active
                and tier.cadence = t.cadence
                and tier.capacity_ceiling = t.customer_capacity
                and tier.effective_from <= now()
                and (tier.effective_to is null or tier.effective_to > now())
              where t.business_id = b.id
              order by tier.effective_from desc
              limit 1), 0)::int,
           coalesce(b.is_synthetic, false)
    from public.businesses b
    left join public.subscriptions sub on sub.business_id = b.id
    order by b.name;
end;
$function$;

-- ACL restated verbatim from prod (nestly_v878): the console (authenticated, gated inside) and
-- the service role.
revoke all on function public.super_admin_list_businesses() from public, anon;
grant execute on function public.super_admin_list_businesses() to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- (B)
-- ---------------------------------------------------------------------------------------------
do $patch$
declare
  v_sig constant regprocedure :=
    'public.platform_get_sme_analytics_v510(date,date,timestamptz,uuid,integer,text)'::regprocedure;
  v_src text := pg_get_functiondef(v_sig);
  v_old constant text := 'history.to_stage_key=''closed_won''';
  v_new constant text := 'history.to_stage_key in (select won.stage_key from public.sme_pipeline_stages won where won.kind = ''won'') /* nestly_v878 */';
  v_hits integer;
begin
  v_hits := (length(v_src) - length(replace(v_src, v_old, ''))) / length(v_old);
  if v_hits <> 2 then
    raise exception 'nestly_v878: the closed_won fragment occurs % times in platform_get_sme_analytics_v510 (expected exactly 2)', v_hits
      using errcode = 'XX001';
  end if;
  execute replace(v_src, v_old, v_new);
end
$patch$;

-- ACL restated verbatim from prod.
revoke all on function public.platform_get_sme_analytics_v510(date,date,timestamptz,uuid,integer,text) from public, anon;
grant execute on function public.platform_get_sme_analytics_v510(date,date,timestamptz,uuid,integer,text) to authenticated, service_role;

do $verify$
begin
  if not exists (select 1 from pg_proc p where p.oid = 'public.super_admin_list_businesses()'::regprocedure
                    and pg_get_function_result(p.oid) like '%is_synthetic boolean%') then
    raise exception 'nestly_v878: super_admin_list_businesses does not return is_synthetic' using errcode = 'XX001';
  end if;
  if position('billing_capacity_tier_catalog_v664' in pg_get_functiondef('public.super_admin_list_businesses()'::regprocedure)) = 0 then
    raise exception 'nestly_v878: super_admin_list_businesses still prices with the v14 seat plan' using errcode = 'XX001';
  end if;
  if position('won.kind = ''won''' in pg_get_functiondef('public.platform_get_sme_analytics_v510(date,date,timestamptz,uuid,integer,text)'::regprocedure)) = 0 then
    raise exception 'nestly_v878: sme analytics still hard-codes closed_won' using errcode = 'XX001';
  end if;
end
$verify$;

commit;
