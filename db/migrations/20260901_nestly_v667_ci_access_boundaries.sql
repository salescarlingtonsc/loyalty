-- NESTLY v667 — Customer Intelligence access boundaries.
--
-- Closes three of the four P0 defects recorded in docs/qa/CI-PROOF-BASELINE-2026-09-01.md.
-- Proven by db/tests/executed/v667_ci_access_boundaries.sql, which fails against v650 and
-- passes against this migration. The fourth defect is a browser payload mismatch and is fixed
-- in app/platform-console.js.
--
-- 1. ENTITLEMENT — the gate was wrong in BOTH directions.
--
--    v650 gated on `app.is_salon_member(b) and app.can_module(b,'reports')`. Executed against a
--    real engine, that gate REFUSED the assigned consultant AND the super admin: neither holds a
--    `staff` row for the firm, and `can_module` reads `public.staff`. So the capability was
--    unusable by exactly the two populations PRODUCT-TRUTH.md:443 names as entitled to generate
--    it for assigned firms.
--
--    An earlier reading of this file claimed the gate was ALSO too broad for admitting a firm
--    owner, on the strength of PRODUCT-TRUTH.md:228. That was wrong, and the correction is worth
--    recording because it is the kind of mistake that reverses an owner: PRODUCT-TRUTH.md:228 was
--    written 2026-08-02, and nestly_v523 records an owner ruling of 2026-08-26 — twenty-four days
--    later — that the module follows entitlement again. The merchant arm of the gate is therefore
--    KEPT, byte-equivalent to v650, and the platform arm is added beside it.
--
--    The platform arm reuses the authority that already guards the sibling surface rather than
--    inventing a second one: app.v176_can_read_firm_report = super admin OR assigned consultant,
--    the same predicate behind the ai_firm_reports_v176 RLS policy, so the AI report and the CI
--    readers can no longer disagree about who may read a firm.
--
-- 2. BRANCH — v650 took no branch argument at all, so branch scope was not weakly enforced, it
--    was absent. p_branch is added to all six readers and validated to belong to the business,
--    which is what blocks a foreign branch id from being injected. Where the metric genuinely
--    has no branch dimension (acquisition is per-client, the funnel is identity-free, consent
--    is firm-level, engagement rollups are firm-level) the reader RAISES rather than silently
--    ignoring the argument — a filter that quietly does nothing returns firm-wide figures to a
--    caller who asked for one branch, which is the misleading-output failure mode.
--
-- 3. SMALL CELL — get_ci_category_customers_v1 returned raw full_name for any cohort size, so a
--    category with one customer identified that person by name. A k=5 floor now suppresses the
--    rows and says so. The count still travels, because coverage honesty needs it; only the
--    identities are withheld.
--
-- Signatures change, so the old ones are dropped rather than left as overloads: PostgREST
-- resolves twin overloads to PGRST203 and would break every caller (see the v410 promotion
-- finalize incident). Dropping and recreating with a defaulted p_branch keeps existing 3-arg
-- callers working.

begin;

-- ---------------------------------------------------------------------------
-- 1 · One authority for "may this caller read this firm's intelligence?"
-- ---------------------------------------------------------------------------
create or replace function app.ci_access_gate_v667(p_business uuid, p_branch uuid default null)
returns void
language plpgsql stable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  /* A UNION, deliberately, because two authorities are both live and they disagree:
       - docs/product/PRODUCT-TRUTH.md:228 (written 2026-08-02) calls Customer Intelligence a
         platform/consulting capability and not a self-service owner module;
       - nestly_v523 (2026-08-26, TWENTY-FOUR DAYS LATER) records an owner ruling that the
         module "follows entitlement again" and removed the hand-placed override so it would
         "resolve exactly like every other one".
     The later ruling should win, but PRODUCT-TRUTH has not been updated to match and the
     v523 ruling is NOT actually in force (see the note below). Picking either side alone
     would silently overrule an owner; admitting both regresses nobody and leaves the
     decision where it belongs. The merchant arm is byte-equivalent to the v650 gate, so no
     caller that worked before this migration stops working.

     WHAT THIS MIGRATION DOES NOT FIX, on purpose: v523 removed the override from
     app.staff_module_perms_at_v115 but NOT from app.effective_platform_module_mode_v94,
     which still answers 'disabled' / 'global_platform_only_policy' for 'customerintel'.
     v537 then re-pointed the capability gate at that resolver. Net effect today:
     app.can_module(b,'customerintel') is false for EVERY caller including an entitled
     owner, so the owner's 2026-08-26 ruling never took effect, and v573's gating of
     public.get_revenue_truth_v106 on that module makes revenue truth unreachable for every
     merchant role. Completing v523 changes what merchants can see and is an owner decision,
     not a defect fix to fold into an access-boundary migration. Recorded, not fixed. */
  if auth.uid() is null
     or not (
          app.v176_can_read_firm_report(p_business)                    -- platform: SA or assigned consultant
          or (app.is_salon_member(p_business)                          -- merchant: exactly the v650 path
              and app.can_module(p_business, 'reports'))
        ) then
    raise exception 'customer intelligence access is required'
      using errcode = '42501';
  end if;
  -- A branch that is not this firm's is refused, never ignored.
  if p_branch is not null
     and not exists (select 1 from public.branches br
                      where br.id = p_branch and br.business_id = p_business) then
    raise exception 'branch does not belong to this business'
      using errcode = '42501';
  end if;
end;
$$;
revoke all on function app.ci_access_gate_v667(uuid,uuid) from public, anon, authenticated;

-- Refuse a branch filter on a metric that has no branch dimension, rather than ignore it.
create or replace function app.ci_no_branch_dimension_v667(p_branch uuid, p_metric text)
returns void
language plpgsql immutable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if p_branch is not null then
    raise exception '% has no branch dimension; ask for the firm or pick a branch-scoped metric', p_metric
      using errcode = '22023';
  end if;
end;
$$;
revoke all on function app.ci_no_branch_dimension_v667(uuid,text) from public, anon, authenticated;

-- The v650 name stays valid and now delegates, so there is exactly one decision.
create or replace function app.ci_reports_gate_v650(p_business uuid)
returns void
language plpgsql stable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  perform app.ci_access_gate_v667(p_business, null);
end;
$$;

-- ---------------------------------------------------------------------------
-- 2 · Category mix — branch-scoped
-- ---------------------------------------------------------------------------
drop function if exists public.get_ci_category_mix_v1(uuid,date,date);
create or replace function public.get_ci_category_mix_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_result jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  with lines as (
    select si.line_cents, s.client_id, en.node_key as eff_node, en.classification,
           coalesce(n.parent_key, n.node_key) as l2_key,
           case when n.level = 3 then n.node_key end as l3_key
      from public.sale_items si
      join public.sales s on s.id = si.sale_id
      cross join lateral app.ci_effective_node_v650(si) en
      left join public.taxonomy_nodes n on n.version_no = 1 and n.node_key = en.node_key
     where si.business_id = p_business
       and (p_branch is null or s.branch_id = p_branch)
       and s.reversal_of is null
       and not exists (select 1 from public.sales r where r.reversal_of = s.id)
       and coalesce(s.counts_as_revenue, false)
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
       and si.item_type in ('service','retail')
       and si.line_cents > 0
       and not coalesce((select c.is_synthetic from public.clients c where c.id = s.client_id), false)
  ),
  totals as (
    select coalesce(sum(line_cents),0) as total_rev,
           coalesce(sum(line_cents) filter (where eff_node is not null),0) as classified_rev,
           coalesce(sum(line_cents) filter (where eff_node is not null and classification='projected'),0) as projected_rev
      from lines
  ),
  l3 as (
    select l2_key, l3_key, sum(line_cents) as rev
      from lines where l3_key is not null group by l2_key, l3_key
  ),
  l2 as (
    select l.l2_key,
           max(n2.label) as label,
           sum(l.line_cents) as rev,
           count(*) as line_count,
           count(distinct l.client_id) as customer_count,
           case when sum(l.line_cents) > 0
             then (10000.0 * coalesce(sum(l.line_cents) filter (where l.classification='projected'),0) / sum(l.line_cents))::int
             else 0 end as projected_share_bps
      from lines l
      left join public.taxonomy_nodes n2 on n2.version_no = 1 and n2.node_key = l.l2_key
     where l.l2_key is not null
     group by l.l2_key
  )
  select jsonb_build_object(
    'status', case when t.total_rev = 0 then 'empty' else 'ready' end,
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                'from', p_from, 'to', p_to),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object(
        'node_key', l2.l2_key, 'label', l2.label,
        'revenue_cents', l2.rev, 'line_count', l2.line_count,
        'customer_count', l2.customer_count,
        'projected_share_bps', l2.projected_share_bps,
        'children', coalesce((select jsonb_agg(jsonb_build_object(
                       'node_key', l3.l3_key, 'revenue_cents', l3.rev) order by l3.rev desc)
                       from l3 where l3.l2_key = l2.l2_key), '[]'::jsonb))
        order by l2.rev desc)
        from l2), '[]'::jsonb),
    'coverage', jsonb_build_object(
      'stampable_revenue_cents', t.total_rev,
      'classified_pct_bps', case when t.total_rev > 0
        then (10000.0 * t.classified_rev / t.total_rev)::int else null end,
      'projected_share_bps', case when t.classified_rev > 0
        then (10000.0 * t.projected_rev / t.classified_rev)::int else null end),
    'observed_since', app.metric_observed_since_v1('category_snapshots', p_business))
    into v_result
    from totals t;
  return v_result;
end;
$$;
revoke all on function public.get_ci_category_mix_v1(uuid,date,date,uuid) from public, anon;
grant execute on function public.get_ci_category_mix_v1(uuid,date,date,uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3 · Category customers — branch-scoped AND small-cell suppressed
-- ---------------------------------------------------------------------------
drop function if exists public.get_ci_category_customers_v1(uuid,text,date,date,integer);
create or replace function public.get_ci_category_customers_v1(
  p_business uuid, p_node_key text, p_from date, p_to date,
  p_limit integer default 100, p_branch uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_rows jsonb;
  v_count integer;
  -- k=5: the conventional small-cell floor. Below it, naming the members of a filtered
  -- cohort re-identifies them, which is the disclosure this migration exists to stop.
  v_floor constant integer := 5;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  if not exists (select 1 from public.taxonomy_nodes n
                  where n.version_no = 1 and n.node_key = p_node_key) then
    raise exception 'unknown taxonomy node %', p_node_key using errcode = '22023';
  end if;
  select coalesce(jsonb_agg(rec order by (rec->>'revenue_cents')::bigint desc), '[]'::jsonb)
    into v_rows
    from (
      select jsonb_build_object(
        'client_id', s.client_id,
        'full_name', max(c.full_name),
        'visits', count(distinct s.id),
        'revenue_cents', sum(si.line_cents),
        'last_visit', max((s.occurred_at at time zone 'Asia/Singapore')::date)
      ) as rec
      from public.sale_items si
      join public.sales s on s.id = si.sale_id
      join public.clients c on c.id = s.client_id
      cross join lateral app.ci_effective_node_v650(si) en
     where si.business_id = p_business
       and (p_branch is null or s.branch_id = p_branch)
       and s.client_id is not null
       and not coalesce(c.is_synthetic, false)
       and s.reversal_of is null
       and not exists (select 1 from public.sales r where r.reversal_of = s.id)
       and coalesce(s.counts_as_visit, false)
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
       and (en.node_key = p_node_key or en.node_key like p_node_key || '.%')
     group by s.client_id
     limit greatest(1, least(coalesce(p_limit, 100), 500))
    ) t;

  v_count := jsonb_array_length(v_rows);

  /* Below the floor the identities are withheld, not the fact. The cohort size still travels
     so a reader can tell "too few to name" apart from "nobody", which coverage honesty needs. */
  if v_count > 0 and v_count < v_floor then
    return jsonb_build_object(
      'node_key', p_node_key,
      'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                  'from', p_from, 'to', p_to),
      'customers', '[]'::jsonb,
      'suppressed', jsonb_build_object(
        'reason', 'below_small_cell_floor',
        'floor', v_floor,
        'cohort_size', v_count,
        'note', 'Naming a cohort this small would identify its members.'),
      'observed_since', app.metric_observed_since_v1('category_snapshots', p_business));
  end if;

  return jsonb_build_object(
    'node_key', p_node_key,
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                'from', p_from, 'to', p_to),
    'customers', v_rows,
    'suppressed', null,
    'observed_since', app.metric_observed_since_v1('category_snapshots', p_business));
end;
$$;
revoke all on function public.get_ci_category_customers_v1(uuid,text,date,date,integer,uuid) from public, anon;
grant execute on function public.get_ci_category_customers_v1(uuid,text,date,date,integer,uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4 · The four firm-level readers: same gate, and an honest refusal of p_branch
-- ---------------------------------------------------------------------------
drop function if exists public.get_ci_acquisition_v1(uuid,date,date);
create or replace function public.get_ci_acquisition_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_rows jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_no_branch_dimension_v667(p_branch, 'acquisition');
  select coalesce(jsonb_agg(rec order by (rec->>'customers')::int desc), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
        'via', c.first_acquired_via,
        'evidence', c.first_acquired_evidence,
        'customers', count(*),
        'new_in_period', count(*) filter (
          where (c.created_at at time zone 'Asia/Singapore')::date between p_from and p_to),
        'repeat_customers', count(*) filter (where (
          select count(*) from public.sales s
           where s.business_id = p_business and s.client_id = c.id
             and coalesce(s.counts_as_visit, false) and s.reversal_of is null) >= 2)
      ) as rec
      from public.clients c
     where c.business_id = p_business and not coalesce(c.is_synthetic, false)
     group by c.first_acquired_via, c.first_acquired_evidence
    ) t;
  return jsonb_build_object('sources', v_rows,
    'observed_since', app.metric_observed_since_v1('first_acquisition', p_business));
end;
$$;
revoke all on function public.get_ci_acquisition_v1(uuid,date,date,uuid) from public, anon;
grant execute on function public.get_ci_acquisition_v1(uuid,date,date,uuid) to authenticated, service_role;

drop function if exists public.get_ci_funnel_v1(uuid,date,date);
create or replace function public.get_ci_funnel_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_rows jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_no_branch_dimension_v667(p_branch, 'the public funnel');
  select coalesce(jsonb_object_agg(surface, steps), '{}'::jsonb) into v_rows
    from (
      select f.surface, jsonb_object_agg(f.step, f.hits) as steps
        from (select surface, step, sum(hits) as hits
                from public.public_funnel_counters
               where business_id = p_business and day between p_from and p_to
               group by surface, step) f
       group by f.surface
    ) t;
  return jsonb_build_object('funnel', v_rows,
    'observed_since', app.metric_observed_since_v1('public_funnel_counters', p_business));
end;
$$;
revoke all on function public.get_ci_funnel_v1(uuid,date,date,uuid) from public, anon;
grant execute on function public.get_ci_funnel_v1(uuid,date,date,uuid) to authenticated, service_role;

drop function if exists public.get_ci_contactability_v1(uuid);
create or replace function public.get_ci_contactability_v1(
  p_business uuid, p_branch uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_no_branch_dimension_v667(p_branch, 'contactability');
  return jsonb_build_object(
    'business_offers', app.contactable_counts_v1(p_business, 'business_offers'),
    'rewards_and_points', app.contactable_counts_v1(p_business, 'rewards_and_points'),
    'note', 'A customer counts only with an affirmative recorded consent for the channel; nobody is grandfathered.');
end;
$$;
revoke all on function public.get_ci_contactability_v1(uuid,uuid) from public, anon;
grant execute on function public.get_ci_contactability_v1(uuid,uuid) to authenticated, service_role;

drop function if exists public.get_ci_engagement_v1(uuid,integer);
create or replace function public.get_ci_engagement_v1(
  p_business uuid, p_months integer default 12, p_branch uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_hist jsonb; v_current jsonb;
  v_this_month date := date_trunc('month', now() at time zone 'Asia/Singapore')::date;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_no_branch_dimension_v667(p_branch, 'engagement');
  select coalesce(jsonb_agg(jsonb_build_object(
           'month', r.month, 'event_name', r.event_name,
           'events', r.event_count, 'people', r.distinct_actor_count)
           order by r.month, r.event_name), '[]'::jsonb) into v_hist
    from public.engagement_monthly_rollup_v1 r
   where r.business_id = p_business and r.actor_scope = 'customer'
     and r.month >= (v_this_month - make_interval(months => greatest(1, least(coalesce(p_months,12), 36))));
  select coalesce(jsonb_agg(jsonb_build_object(
           'event_name', e.event_name, 'events', e.n, 'people', e.actors)), '[]'::jsonb) into v_current
    from (select event_name, count(*) n, count(distinct actor_user_id) actors
            from public.product_adoption_events_v100
           where business_id = p_business and actor_scope = 'customer'
             and (occurred_at at time zone 'Asia/Singapore')::date >= v_this_month
           group by event_name) e;
  return jsonb_build_object('months', v_hist, 'current_month', v_current,
    'observed_since', app.metric_observed_since_v1('engagement_rollups', p_business));
end;
$$;
revoke all on function public.get_ci_engagement_v1(uuid,integer,uuid) from public, anon;
grant execute on function public.get_ci_engagement_v1(uuid,integer,uuid) to authenticated, service_role;

commit;
