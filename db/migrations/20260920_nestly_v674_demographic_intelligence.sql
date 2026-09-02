-- NESTLY v674 — Phase CI-A: demographic revenue/frequency/ATV + the flagship cohort question.
--
-- Closes checks 31-34 of the rescoped Customer Intelligence program
-- (docs/qa/CI-ACCEPTANCE-VERDICT-2026-09-02.md, phase CI-A). Two readers, both gated by
-- app.ci_access_gate_v667 and embedding the frozen v672 statistical authority
-- (docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md) rather than inventing a fourth sample floor.
-- Proven by db/tests/executed/v674_corpus_demographics.sql — a predetermined truth table,
-- exact assertions, no `> 0`.
--
--   public.get_ci_demographics_v1        the (age_band x gender) revenue/frequency/ATV grid,
--                                         plus an 'unclassified' bucket and two coverage rates.
--   public.get_ci_demographic_cohort_v1  THE FLAGSHIP: "women aged 25-30 who bought a facial-
--                                         category service — do they return?" All eleven
--                                         required fields, plus two small honest companions
--                                         (see "ELEVEN FIELDS" below).
--
-- ---------------------------------------------------------------------------------------------
-- DESIGN DECISIONS (read before touching either function)
-- ---------------------------------------------------------------------------------------------
--
-- 1. ATV DEFINITION. atv_cents = revenue_cents / count of REVENUE-qualifying sales in the cell
--    (i.e. sales with counts_as_revenue, not counts_as_visit). A $0 or non-revenue visit moves
--    footfall but has no "transaction value" to average, so it is excluded from the ATV
--    denominator even though it is included in `visits`. Below the k=5 evidence floor
--    (app.subgroup_evidence_v1, same convention as v667's category-customers small-cell rule)
--    the cell is KEPT with its real customers/revenue_cents/visits and atv_cents is nulled —
--    never dropped, never a fabricated average from four people.
--
-- 2. "IDENTIFIED" POPULATION for get_ci_demographics_v1 = clients with a linked client_id on a
--    qualifying sale (counts_as_revenue or counts_as_visit) in the window — i.e. every non-
--    anonymous sale, not a category- or node-scoped subset. Reversal rules match the rest of
--    the CI surface (v650/v667): a reversed sale and its reversal row are both excluded.
--
-- 3. CLASSIFICATION reuses v638's computation VERBATIM, called per distinct client via LATERAL
--    — the header's own instruction ("consistency with v638's precedence beats set-based
--    speed; SME row counts are small"). get_ci_demographics_v1 needs only today's age band, so
--    the real authority is called directly, not reimplemented — specifically the gate-free core
--    app.customer_demographics_core_v674 (see design decision 8), not the public
--    app.customer_demographics_v1 wrapper, so this reader's own app.ci_access_gate_v667 remains
--    the single authority a caller is judged against.
--
-- 4. THE FLAGSHIP'S AGE PROBLEM. get_ci_demographic_cohort_v1 takes literal p_age_from/
--    p_age_to integers, not a v638 band label — "aged 25-30" is a number range a caller
--    chooses, not one of v638's six fixed buckets. app.customer_demographics_v1 cannot answer
--    that (it returns a band string, classified as of TODAY, and never exposes the raw birth
--    date, deliberately — v638's own header: "merchants consume a derived AGE BAND, never the
--    raw wallet birth date"). Two sub-decisions follow:
--
--    4a. AGE BASIS = 'purchase_date', not "as of today" (the task's own recommendation,
--        adopted). A customer's age at the moment of a purchase from three months — or three
--        years — ago is a fact about that purchase, not about today. The payload carries
--        'age_basis': 'purchase_date' so a caller never has to guess which convention applies.
--
--    4b. PRECEDENCE IS MIRRORED, NOT DIVERGED. Computing age-at-purchase needs a raw birth
--        date, which v638 will not hand back. The alternative — inventing a new "whose value
--        wins" rule — is exactly the divergence the CI-CORPUS-FIXTURE-GUIDE and this task
--        warn against. Instead, the `demog` CTE below reproduces v638's wallet-vs-staff
--        precedence and prefer_not_to_say masking VERBATIM (same COALESCE shape, same
--        branching on "did a verified wallet value exist at all"), just evaluated at the
--        purchase's anchor date instead of at NOW(). If v638's precedence rule ever changes,
--        this block must change with it — that coupling is recorded here for discoverability,
--        not hidden. The raw birth date itself never leaves this function: the payload only
--        ever carries the derived cohort membership and the 'age_basis' label, preserving
--        v638's privacy intent even though the raw column is read internally.
--
-- 5. "ANOTHER QUALIFYING VISIT" (the numerator) means ANY counts_as_visit sale after the
--    anchor purchase, in ANY category — not a second node-A purchase specifically. The
--    business question is "do they return", a general retention question, not "do they
--    re-buy this category". Documented so a future reader does not silently narrow it.
--
-- 6. COVERAGE (field 10) is scoped to the MATURE population (cohort members whose maturity
--    window has fully elapsed), not the full incl.-immature membership. Coverage exists to
--    say how much of the RETURN-RATE comparison is demographically explained; an immature
--    member contributes no rate outcome yet, so folding them into the coverage denominator
--    would answer a different question than the one attached to this field. baseline's own
--    denominator (field 7) is exactly the RESOLVED subset of this same mature population, so
--    coverage.numerator == baseline.denominator by construction — not a coincidence, the two
--    fields describe the same population from two angles.
--
-- 7. ELEVEN FIELDS + two honest companions. The task specifies eleven named blocks (cohort,
--    window, numerator, denominator, customers, observations, baseline, difference, period,
--    coverage, confidence). Field 11 (confidence) implies two more concrete values that must
--    exist to be nulled/explained on insufficiency: 'pct' (the cohort's own return rate, the
--    number 'difference' is computed from) and 'withheld_reason' (a human sentence when
--    confidence is 'insufficient'). Both ship as top-level companions to field 11, plus
--    'observed_since' per the v672 contract's point 5 ("where a watermark exists" — the
--    lookup gracefully falls back to the business's own created_at when no watermark row is
--    registered for the key, so passing a fresh metric key here is safe).
--
-- 8. FIXED (was: "known limitation, recorded not fixed" — reopened on review). The original
--    draft of this migration left get_ci_demographics_v1 calling the PUBLIC
--    app.customer_demographics_v1 (v638), which carries its OWN internal gate
--    (`is_salon_member OR is_super_admin`) — narrower than, and layered underneath,
--    app.ci_access_gate_v667 (which deliberately also admits the assigned consultant;
--    PRODUCT-TRUTH.md:443, and the whole point of v667's P0-1 fix). That double-gate meant an
--    assigned consultant — reading THIS reader's data is exactly what Customer Intelligence
--    exists for them to do — passed the outer gate and then 42501'd on the very first LATERAL
--    call inside. A reader that inherits a closure v667 was built to open is a new instance of
--    the same defect, not a documented edge case.
--
--    THE FIX splits v638's classification into a gate-free core plus a byte-equivalent public
--    wrapper (section 0 below), extract-and-diff style:
--      app.customer_demographics_core_v674(business, client)  — v638's computation, gate
--        removed, nothing else changed. SECURITY DEFINER, revoked from public/anon/
--        authenticated, granted to service_role only — it is an internal building block, never
--        a directly callable entitlement surface, so nothing outside a security-definer chain
--        this repo already owns can reach it.
--      app.customer_demographics_v1(business, client)         — re-CREATE OR REPLACEd as the
--        ORIGINAL gate followed by `return app.customer_demographics_core_v674(...)`. Same
--        signature, same gate text and errcode, same ACL (revoke/grant restated verbatim
--        below) — every existing caller sees byte-identical behaviour. Confirmed by
--        `grep -rn customer_demographics_v1` across the repo (excluding node_modules): the
--        defining migrations (db/migrations/20260830_nestly_v638…, its mirrored
--        supabase/migrations/20260830200000_nestly_v638… copy — untouched here, out of this
--        task's two-file scope, and not read by the db-tests harness either way), this
--        migration's own new wrapper body, get_ci_demographics_v1 (repointed below to call the
--        core instead), the executed fixture db/tests/executed/v629_corpus_acquisition_
--        demographics.sql (calls it as a super admin — unaffected), and one UNEXECUTED rollback
--        suite db/tests/v638_demographics_authority.sql — no `executed/` in its path, so per
--        the harness's own docstring ("Only files in db/tests/executed/ are ever run") it is
--        read by nobody and cannot be disturbed by this change either. No app/*.js file calls
--        it. Every real caller is therefore proven unaffected by execution, not by reading.
--    get_ci_demographics_v1 is repointed at the CORE: its own app.ci_access_gate_v667 call is
--    already the correct authority for this surface (firm entitlement OR platform read), so
--    double-gating through v638's narrower merchant-only check was the bug, not a safety net.
--    Proven by db/tests/executed/v674_corpus_demographics.sql's 'DC' block: an assigned
--    consultant with no staff row on the fixture business gets the SAME (25_30,female) cell the
--    super admin gets (served, not refused), while an unrelated firm's owner is still refused
--    (the underlying tenant boundary is unweakened — v667's own boundary, unchanged here).
--
--    get_ci_demographic_cohort_v1 (section 2) never called app.customer_demographics_v1 at all
--    — its `demog` CTE always computed age/gender inline (design decision 4b), because it needs
--    a raw birth date and an as-of-PURCHASE-DATE age that neither v638's public function nor
--    the new core exposes (the core is a byte-faithful extraction of v638's TODAY-only
--    computation, not a generalisation). It is therefore unaffected by this defect and by this
--    fix; already reads app.ci_access_gate_v667 as its sole authority.
begin;

-- ---------------------------------------------------------------------------------------------
-- 0 · app.customer_demographics_v1 (v638) split: gate-free core + byte-equivalent public wrapper
-- ---------------------------------------------------------------------------------------------
-- CORE. v638's computation, verbatim, with the `if auth.uid() is null or not (...)` gate block
-- removed and nothing else touched: same declarations, same wallet-vs-staff precedence, same
-- prefer_not_to_say masking, same age-band boundaries, same return shape.
create or replace function app.customer_demographics_core_v674(p_business uuid, p_client uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_client public.clients%rowtype;
  v_wallet_birth date;
  v_wallet_gender text;
  v_birth date;
  v_gender text;
  v_source text;
  v_conflict boolean := false;
  v_age integer;
  v_band text;
begin
  select * into v_client from public.clients
   where id = p_client and business_id = p_business;
  if not found then
    raise exception 'client not found' using errcode = '22023';
  end if;

  select cp.birth_date, cp.gender
    into v_wallet_birth, v_wallet_gender
    from public.customer_links cl
    join public.customer_profiles cp on cp.identity_id = cl.identity_id
   where cl.business_id = p_business
     and cl.client_id = p_client
     and cl.state = 'verified'
   limit 1;

  if v_wallet_birth is not null or v_wallet_gender is not null then
    v_birth := coalesce(v_wallet_birth, v_client.birth_date);
    v_gender := coalesce(v_wallet_gender, v_client.gender);
    v_source := 'customer_attested';
    v_conflict :=
      (v_wallet_birth is not null and v_client.birth_date is not null
        and v_wallet_birth <> v_client.birth_date)
      or (v_wallet_gender is not null and v_client.gender is not null
        and v_wallet_gender <> v_client.gender);
  else
    v_birth := v_client.birth_date;
    v_gender := v_client.gender;
    v_source := case when v_birth is null and v_gender is null
                     then 'none' else 'staff_entered' end;
  end if;

  if v_birth is not null then
    -- nestly_v685 (main, Singapore-day authority) patched the v638 body to age against the
    -- Singapore day; the core keeps that semantics rather than the pre-v685 UTC day.
    v_age := date_part('year', age(app.sg_today(), v_birth))::integer;
    v_band := case
      when v_age < 20 then 'under_20'
      when v_age <= 24 then '20_24'
      when v_age <= 30 then '25_30'
      when v_age <= 40 then '31_40'
      when v_age <= 50 then '41_50'
      else '51_plus' end;
  end if;

  return jsonb_build_object(
    'age_band', v_band,
    'gender', case when v_gender = 'prefer_not_to_say' then null else v_gender end,
    'gender_declared', v_gender is not null,
    'source', v_source,
    'conflict', v_conflict
  );
end;
$$;
revoke all on function app.customer_demographics_core_v674(uuid,uuid) from public, anon, authenticated;
grant execute on function app.customer_demographics_core_v674(uuid,uuid) to service_role;

-- WRAPPER. Byte-equivalent to v638 for every existing caller: identical gate (same predicate,
-- same message, same errcode), then delegates to the core. Signature and ACL restated verbatim.
create or replace function app.customer_demographics_v1(p_business uuid, p_client uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if auth.uid() is null
     or not (app.is_salon_member(p_business) or app.is_super_admin()) then
    raise exception 'business membership is required' using errcode = '42501';
  end if;
  return app.customer_demographics_core_v674(p_business, p_client);
end;
$$;
revoke all on function app.customer_demographics_v1(uuid,uuid) from public, anon;
grant execute on function app.customer_demographics_v1(uuid,uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 1 · get_ci_demographics_v1 — (age_band x gender) revenue/frequency/ATV, coverage, unclassified
-- ---------------------------------------------------------------------------------------------
create or replace function public.get_ci_demographics_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_result jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);

  with qualifying as (
    select s.client_id, s.amount_cents,
           coalesce(s.counts_as_revenue, false) as is_revenue,
           coalesce(s.counts_as_visit, false) as is_visit
      from public.sales s
      join public.clients c on c.id = s.client_id
     where s.business_id = p_business
       and s.client_id is not null
       and not coalesce(c.is_synthetic, false)
       and (p_branch is null or s.branch_id = p_branch)
       and s.reversal_of is null
       and not exists (select 1 from public.sales r where r.reversal_of = s.id)
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
       and (coalesce(s.counts_as_revenue, false) or coalesce(s.counts_as_visit, false))
  ),
  client_agg as (
    select q.client_id,
           coalesce(sum(q.amount_cents) filter (where q.is_revenue), 0) as revenue_cents,
           count(*) filter (where q.is_revenue) as revenue_txns,
           count(*) filter (where q.is_visit) as visits
      from qualifying q
     group by q.client_id
  ),
  classified as (
    -- CORE, not the public wrapper: app.ci_access_gate_v667 (called above) is already the
    -- correct authority for this reader — it admits the firm OR the platform (super admin /
    -- assigned consultant). Routing per-client classification back through v638's narrower
    -- merchant-only gate would double-gate and wrongly 42501 an entitled consultant (see
    -- design decision 8).
    select ca.client_id, ca.revenue_cents, ca.revenue_txns, ca.visits,
           d.dem->>'age_band' as age_band,
           d.dem->>'gender' as gender
      from client_agg ca
      cross join lateral (
        select app.customer_demographics_core_v674(p_business, ca.client_id) as dem
      ) d
  ),
  cells as (
    select age_band, gender,
           count(*) as customers,
           sum(revenue_cents)::bigint as revenue_cents,
           sum(visits)::bigint as visits,
           sum(revenue_txns)::bigint as revenue_txns
      from classified
     where age_band is not null and gender is not null
     group by age_band, gender
  ),
  unclass as (
    select count(*) as customers, coalesce(sum(revenue_cents), 0)::bigint as revenue_cents
      from classified
     where age_band is null or gender is null
  ),
  totals as (
    select count(*) as active_customers,
           coalesce(sum(revenue_cents), 0)::bigint as active_revenue_cents,
           count(*) filter (where age_band is not null and gender is not null) as resolved_customers,
           coalesce(sum(revenue_cents) filter (where age_band is not null and gender is not null), 0)::bigint
             as resolved_revenue_cents
      from classified
  )
  select jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                 'from', p_from, 'to', p_to),
    'cells', coalesce((
      select jsonb_agg(jsonb_build_object(
               'age_band', cl.age_band,
               'gender', cl.gender,
               'customers', cl.customers,
               'revenue_cents', cl.revenue_cents,
               'visits', cl.visits,
               'atv_cents', case
                 when app.subgroup_evidence_v1(cl.customers::int)->>'status' = 'ok'
                      and cl.revenue_txns > 0
                 then round(cl.revenue_cents::numeric / cl.revenue_txns)::bigint
                 else null end,
               'evidence', app.subgroup_evidence_v1(cl.customers::int))
             order by cl.age_band, cl.gender)
        from cells cl), '[]'::jsonb),
    'unclassified', jsonb_build_object('customers', u.customers, 'revenue_cents', u.revenue_cents),
    'coverage', jsonb_build_object(
      'demographics', app.rate_block_v1(t.resolved_customers, t.active_customers),
      'revenue', app.rate_block_v1(t.resolved_revenue_cents, t.active_revenue_cents)),
    'time_basis', 'sale_occurred_at',
    'observed_since', app.metric_observed_since_v1('ci_demographics', p_business))
    into v_result
    from unclass u, totals t;

  return v_result;
end;
$$;
revoke all on function public.get_ci_demographics_v1(uuid,date,date,uuid) from public, anon;
grant execute on function public.get_ci_demographics_v1(uuid,date,date,uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 2 · get_ci_demographic_cohort_v1 — the flagship "do they return?" cohort-vs-baseline reader
-- ---------------------------------------------------------------------------------------------
create or replace function public.get_ci_demographic_cohort_v1(
  p_business uuid, p_gender text, p_age_from integer, p_age_to integer,
  p_node_key text, p_from date, p_to date,
  p_return_window_days integer default 60, p_branch uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_result jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);

  if p_gender is null or p_gender not in ('female', 'male', 'other') then
    raise exception 'p_gender must be one of female, male, other (got %)', coalesce(p_gender, '<null>')
      using errcode = '22023';
  end if;
  if p_age_from is null or p_age_to is null or p_age_from < 0 or p_age_to < p_age_from then
    raise exception 'invalid age range % to %', p_age_from, p_age_to using errcode = '22023';
  end if;
  if p_return_window_days is null or p_return_window_days < 1 then
    raise exception 'p_return_window_days must be a positive integer' using errcode = '22023';
  end if;
  if not exists (select 1 from public.taxonomy_nodes n
                  where n.version_no = 1 and n.node_key = p_node_key) then
    raise exception 'unknown taxonomy node %', p_node_key using errcode = '22023';
  end if;

  with qualifying_purchases as (
    -- One row per client: their EARLIEST qualifying category (node_key or a descendant)
    -- purchase within [p_from, p_to] — the anchor event this whole reader hangs off.
    select s.client_id, min((s.occurred_at at time zone 'Asia/Singapore')::date) as anchor_date
      from public.sale_items si
      join public.sales s on s.id = si.sale_id
      join public.clients c on c.id = s.client_id
      cross join lateral app.ci_effective_node_v650(si) en
     where si.business_id = p_business
       and si.item_type in ('service', 'retail')
       and (p_branch is null or s.branch_id = p_branch)
       and s.client_id is not null
       and not coalesce(c.is_synthetic, false)
       and s.reversal_of is null
       and not exists (select 1 from public.sales r where r.reversal_of = s.id)
       and coalesce(s.counts_as_visit, false)
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
       and (en.node_key = p_node_key or en.node_key like p_node_key || '.%')
     group by s.client_id
  ),
  demog as (
    -- Mirrors app.customer_demographics_v1 (v638) verbatim — see design decision 4b above.
    select qp.client_id, qp.anchor_date,
           case when wl.wbirth is not null or wl.wgender is not null
                then coalesce(wl.wbirth, c.birth_date) else c.birth_date end as eff_birth,
           case when wl.wbirth is not null or wl.wgender is not null
                then nullif(coalesce(wl.wgender, c.gender), 'prefer_not_to_say')
                else nullif(c.gender, 'prefer_not_to_say') end as eff_gender
      from qualifying_purchases qp
      join public.clients c on c.id = qp.client_id
      left join lateral (
        select cp.birth_date as wbirth, cp.gender as wgender
          from public.customer_links cl
          join public.customer_profiles cp on cp.identity_id = cl.identity_id
         where cl.business_id = p_business and cl.client_id = qp.client_id and cl.state = 'verified'
         limit 1
      ) wl on true
  ),
  classified as (
    select d.client_id, d.anchor_date, d.eff_gender,
           (d.eff_birth is not null and d.eff_gender is not null) as resolved,
           case when d.eff_birth is not null
                then extract(year from age(d.anchor_date, d.eff_birth))::int end as age_at_anchor,
           ((current_date - d.anchor_date) >= p_return_window_days) as mature
      from demog d
  ),
  cohort as (
    select cl2.client_id, cl2.anchor_date, cl2.mature
      from classified cl2
     where cl2.eff_gender = p_gender
       and cl2.age_at_anchor is not null
       and cl2.age_at_anchor between p_age_from and p_age_to
  ),
  cohort_eval as (
    select co.client_id, co.mature,
           exists (
             select 1 from public.sales s2
              where s2.business_id = p_business
                and s2.client_id = co.client_id
                and (p_branch is null or s2.branch_id = p_branch)
                and coalesce(s2.counts_as_visit, false)
                and s2.reversal_of is null
                and not exists (select 1 from public.sales r2 where r2.reversal_of = s2.id)
                and (s2.occurred_at at time zone 'Asia/Singapore')::date > co.anchor_date
                and (s2.occurred_at at time zone 'Asia/Singapore')::date
                      <= co.anchor_date + p_return_window_days
           ) as returned
      from cohort co
  ),
  cohort_agg as (
    select count(*) as customers,
           count(*) filter (where mature) as denom,
           count(*) filter (where mature and returned) as numer
      from cohort_eval
  ),
  cohort_observations as (
    -- All qualifying category purchase EVENTS by cohort members in the period (not just the
    -- first): a member who bought twice contributes two observations to one "customers" slot.
    select count(*) as obs
      from public.sale_items si
      join public.sales s on s.id = si.sale_id
      cross join lateral app.ci_effective_node_v650(si) en
     where si.business_id = p_business
       and si.item_type in ('service', 'retail')
       and (p_branch is null or s.branch_id = p_branch)
       and s.client_id in (select client_id from cohort)
       and s.reversal_of is null
       and not exists (select 1 from public.sales r where r.reversal_of = s.id)
       and coalesce(s.counts_as_visit, false)
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
       and (en.node_key = p_node_key or en.node_key like p_node_key || '.%')
  ),
  baseline_pop as (
    -- The SAME return computation for ALL resolved, mature category purchasers, any age/gender.
    select cl3.client_id, cl3.anchor_date
      from classified cl3
     where cl3.resolved and cl3.mature
  ),
  baseline_eval as (
    select bp.client_id,
           exists (
             select 1 from public.sales s3
              where s3.business_id = p_business
                and s3.client_id = bp.client_id
                and (p_branch is null or s3.branch_id = p_branch)
                and coalesce(s3.counts_as_visit, false)
                and s3.reversal_of is null
                and not exists (select 1 from public.sales r3 where r3.reversal_of = s3.id)
                and (s3.occurred_at at time zone 'Asia/Singapore')::date > bp.anchor_date
                and (s3.occurred_at at time zone 'Asia/Singapore')::date
                      <= bp.anchor_date + p_return_window_days
           ) as returned
      from baseline_pop bp
  ),
  baseline_agg as (
    select count(*) as denom, count(*) filter (where returned) as numer
      from baseline_eval
  ),
  coverage_pop as (
    -- Same mature population baseline_pop is drawn from, before the resolved filter — see
    -- design decision 6 (coverage.numerator == baseline.denominator by construction).
    select count(*) as mature_identified,
           count(*) filter (where resolved) as mature_resolved
      from classified
     where mature
  ),
  final as (
    select ca.customers, ca.denom, ca.numer, co.obs,
           ba.denom as b_denom, ba.numer as b_numer,
           cp.mature_identified, cp.mature_resolved,
           app.subgroup_evidence_v1(ca.denom::int) as confidence
      from cohort_agg ca, cohort_observations co, baseline_agg ba, coverage_pop cp
  )
  select jsonb_build_object(
    'cohort', jsonb_build_object(
      'gender', p_gender, 'age_from', p_age_from, 'age_to', p_age_to,
      'node_key', p_node_key, 'business_id', p_business, 'branch_id', p_branch,
      'sentence', format('%s customers aged %s-%s who made a qualifying purchase in category %s.',
                          initcap(p_gender), p_age_from, p_age_to, p_node_key)),
    'window', jsonb_build_object(
      'return_window_days', p_return_window_days,
      'maturity_rule', 'a cohort member is mature once return_window_days have fully elapsed since their qualifying category purchase: (current_date - purchase_date) >= return_window_days'),
    'numerator', f.numer,
    'denominator', f.denom,
    'customers', f.customers,
    'observations', f.obs,
    'baseline', app.rate_block_v1(f.b_numer, f.b_denom),
    'pct', case when f.confidence->>'status' = 'ok' and f.denom > 0
                then round(100.0 * f.numer / f.denom, 1) else null end,
    'difference', case when f.confidence->>'status' = 'ok' and f.denom > 0 and f.b_denom > 0
                  then round(100.0 * f.numer / f.denom - 100.0 * f.b_numer / f.b_denom, 1)
                  else null end,
    'period', jsonb_build_object('from', p_from, 'to', p_to, 'time_basis', 'sale_occurred_at'),
    'coverage', app.rate_block_v1(f.mature_resolved, f.mature_identified),
    'age_basis', 'purchase_date',
    'confidence', f.confidence,
    'withheld_reason', case when f.confidence->>'status' <> 'ok'
      then format('cohort denominator (%s mature member(s)) is below the sample floor of %s; the return rate and its comparison to baseline are withheld to avoid a false-precision figure for a very small group.', f.denom, f.confidence->>'floor')
      else null end,
    'observed_since', app.metric_observed_since_v1('ci_demographic_cohort', p_business))
    into v_result
    from final f;

  return v_result;
end;
$$;
revoke all on function public.get_ci_demographic_cohort_v1(uuid,text,integer,integer,text,date,date,integer,uuid)
  from public, anon;
grant execute on function public.get_ci_demographic_cohort_v1(uuid,text,integer,integer,text,date,date,integer,uuid)
  to authenticated, service_role;

commit;
