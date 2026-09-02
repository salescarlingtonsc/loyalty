-- NESTLY v702 — check 68 REFUTATION FIX (Customer Intelligence discovery confounder verdicts)
-- and check 16 completion (get_ci_discovery_v1 never wrapped in the shared envelope).
--
-- Reads: docs/qa/CI-CORPUS-FIXTURE-GUIDE.md, docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md (v672,
-- frozen), db/migrations/20260920_nestly_v691_outliers_and_confounders.sql (the LIVE body this
-- migration extract-and-diffs from — grepped: no migration after v691 touches
-- public.get_ci_discovery_v1), db/migrations/20260920_nestly_v693_exclusions_and_typed_verdicts.sql
-- (app.ci_envelope_v680 / app.ci_exclusion_counts_v680's current five-key shape, and
-- get_ci_daypart_v1's envelope call as the shape this migration copies), db/migrations/
-- 20260920_nestly_v680_ci_envelope.sql (the envelope's own contract). Proven by
-- db/tests/executed/v702_corpus_discovery_rigor.sql.
--
-- THREE REFUTATIONS, from the check-68 re-audit against the owner's checklist wording ("68.
-- Confounder checks. Service, staff, branch, customer mix, prior behaviour and competing
-- campaigns are tested where relevant."):
--
-- (1) A survivor with a MINORITY of reversed strata got verdict 'mixed' — a real, disclosed
--     warning sign — but v691's own list-membership test was `sr.replicated and not sr.confounded`,
--     and 'confounded' was only ever true for verdict='reversed'. So a 'mixed' survivor sailed
--     into 'discoveries' anyway, carrying a confounders.verdict the caller was never told to
--     check before treating the row as clean. A caller reading only 'discoveries' (the entire
--     point of the list — "here are the clean findings") had no way to know one in three
--     supporting strata pointed the other way.
--
-- (2) When strata_checked = 0 (no OTHER dimension had a stratum clearing the sample floor on
--     BOTH sides — the check genuinely never ran), the verdict was hardcoded 'consistent'. That
--     is indistinguishable, in the payload, from "we checked N strata and every one agreed" —
--     the single strongest form of confounder evidence a caller can get — when it actually means
--     "we have no idea, nothing was checkable." A caller has no way to tell "confirmed clean" from
--     "never examined" without re-deriving strata_checked itself, which is exactly the kind of
--     silent conflation this program's typed-verdict discipline (CI-STAT-AUTHORITY-CONTRACT.md,
--     the same discipline behind v693's DIRECT_FACT/ASSOCIATION split) exists to prevent.
--
-- (3) public.get_ci_discovery_v1 has never called app.ci_envelope_v680 at all — every sibling CI
--     reader in this program (get_ci_category_mix_v1, get_ci_service_intelligence_v1,
--     get_ci_funnel_conversion_v1, get_ci_retention_windows_v1, get_ci_daypart_v1,
--     get_ci_demographic_cohort_v1, get_ci_demographics_v1 …) wraps its payload in the envelope so
--     'exclusions', 'trace_id' and a normalised 'period' always travel with the answer (check 16:
--     "Reversals, synthetic customers, anonymous transactions, missing demographic fields,
--     overlapping campaigns and other exclusions are countable and visible."). get_ci_discovery_v1
--     ends `return v_result;` and always has — its own 'reversed_sales'/'synthetic_clients'/etc.
--     counts have literally never been computable from its own output, on any version, ever.
--
-- THE FIX. confound_final's verdict CASE gains a fourth outcome, 'unchecked', used exactly when
-- strata_checked = 0 (previously silently folded into 'consistent'); the CASE's remaining branches
-- (>50% reversed -> 'reversed'; zero reversed with at least one checked -> 'consistent'; anything
-- else -> 'mixed') are unchanged. Promotion to 'discoveries' now requires
-- confounders.verdict = 'consistent' — an EXPLICIT match, not "not flagged reversed" — so 'mixed'
-- moves to 'confounded' alongside 'reversed' (both are "at least one stratum disagreed"; the
-- existing 'confounded':true tag and the full strata detail travel with both, so the false-alarm
-- Simpson's-paradox headline and the "some evidence disagrees, look closer" headline are both
-- still fully visible — never silently dropped, per v691's own founding rule). 'unchecked' gets its
-- own new top-level list, 'unverified', with the note "no other dimension cleared the floor on
-- both sides; not promoted" — literally true (it is why nothing could be compared), rather than
-- the misleading blanket sentence 'consistent' used to attach to this case (which read as "sign
-- holds across strata," implying strata existed to check). 'not_replicated' keeps its existing
-- meaning untouched (whether a survivor cleared holdout, independent of its confounders verdict —
-- v691's original design and still correct: replication and confounding are different questions).
-- comparisons_note_v1's 'promoted' count is redefined to count 'consistent'-verdict discoveries
-- only, matching what 'discoveries' now actually contains (previously it counted every replicated
-- survivor regardless of confound verdict, which over-counted "promoted" the same way the
-- discoveries list itself did).
--
-- The whole payload is now returned via `app.ci_envelope_v680('ci_discovery_v1', ...)`, the same
-- call shape get_ci_daypart_v1 uses (v693) — 'generated_at'/'as_of'/'period'/'exclusions'/
-- 'trace_id' now travel on every call, with the five exclusion keys app.ci_exclusion_counts_v680
-- already computes (reversed_sales, synthetic_clients, anonymous_sales, missing_demographics,
-- overlapping_campaigns — the last two only because v693 already taught the shared envelope to
-- forward them; nothing in v702 touches that function). This requires a trailing
-- `p_as_of timestamptz default clock_timestamp()` parameter (ci_envelope_v680's own signature
-- demands one) — added via `drop function if exists` on the exact pre-v702 signature first,
-- exactly as v680 itself did when it added p_branch/p_as_of to every other CI reader, so the
-- existing 4-arg call site (public.get_ci_opportunities_v1, v688: `public.get_ci_discovery_v1(
-- p_business, p_from, p_to, p_branch)`) keeps working unchanged — a new trailing default
-- parameter never breaks a shorter positional call.
--
-- DISCLOSED, DELIBERATE NON-CHANGE: unlike every OTHER re-emitted CI reader (v680's own "AS_OF
-- GATE" section), get_ci_discovery_v1's internal population queries are NOT retrofitted to gate
-- on `s.created_at <= p_as_of` here — that immutable-snapshot gate is check 9's concern, not check
-- 16 or check 68's, and this migration's mandate is the confounder-verdict vocabulary and the
-- envelope wrap only. p_as_of is threaded through solely so app.ci_envelope_v680 has the parameter
-- its own signature requires (echoed back as 'as_of', and fed into app.ci_exclusion_counts_v680,
-- which DOES gate its own counts on it). A caller pinning an old p_as_of on this reader today gets
-- an envelope that correctly reports that snapshot's exclusion counts, but a discovery pipeline
-- that is not itself re-anchored on that snapshot — a real, narrower version of the same gap v680's
-- own header already disclosed for get_ci_package_intelligence_v1's cohort. Recorded here rather
-- than silently left implicit, and left for a future migration whose mandate actually covers check
-- 9 for this reader.
--
-- Every other key, condition and computation in get_ci_discovery_v1 is unchanged from the v691
-- body — proven mechanically below (extract-and-diff, pattern v668/v690/v695): the live body is
-- captured via pg_get_functiondef BEFORE this migration's DROP FUNCTION, and after the replacement
-- the new body must equal the old body with ONLY the named substrings swapped, or the migration
-- raises and rolls back.

begin;

-- ---------------------------------------------------------------------------------------------
-- 1 · Capture the live body and refuse to run against a shape we do not recognise. A silent
--     no-op here would look exactly like a successful fix.
-- ---------------------------------------------------------------------------------------------
create temp table _v702_before(def text) on commit drop;

do $pre$
declare
  v_n integer;
  v_def text;
begin
  insert into _v702_before(def)
  select pg_get_functiondef(p.oid)
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname = 'get_ci_discovery_v1';

  select count(*) into v_n from _v702_before;
  if v_n <> 1 then
    raise exception 'v702: expected exactly one public.get_ci_discovery_v1 before this migration, found %', v_n;
  end if;

  select def into v_def from _v702_before;

  if position('when strata_checked = 0 then ''consistent''' in v_def) = 0 then
    raise exception
      'v702: the strata_checked=0 -> ''consistent'' shape is already absent — stop and re-read before shipping';
  end if;
  if position('confound_verdict' in v_def) > 0 then
    raise exception 'v702: confound_verdict already present in the live body — this migration already applied';
  end if;
  if position('return v_result;' in v_def) = 0 then
    raise exception 'v702: expected an un-enveloped ''return v_result;'' in the live body; shape has drifted';
  end if;
end
$pre$;

-- ---------------------------------------------------------------------------------------------
-- 2 · The re-emitted function. p_as_of is a new trailing parameter (default clock_timestamp()),
--     so the pre-v702 4-arg signature is dropped first — the existing 4-arg call site
--     (public.get_ci_opportunities_v1, v688) keeps working against the new 5-arg signature
--     unchanged, since a shorter positional call still resolves against trailing defaults.
-- ---------------------------------------------------------------------------------------------
drop function if exists public.get_ci_discovery_v1(uuid,date,date,uuid);

create or replace function public.get_ci_discovery_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null,
  p_as_of timestamptz default clock_timestamp())
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_result jsonb;
  v_train_to date;
  v_holdout_from date;
  v_floor constant integer := 5;   -- app.subgroup_evidence_v1's own default; never overridden.
  v_q constant numeric := 0.10;
  v_use_branch boolean;
  v_prior_from date;
  v_prior_to date;
  v_prior_available boolean;
  v_prior_pct numeric;
  v_current_pct numeric;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'invalid date range' using errcode = '22023';
  end if;

  v_train_to := p_from + ((p_to - p_from) / 2);
  v_holdout_from := v_train_to + 1;
  if v_holdout_from > p_to then
    raise exception 'window too short to split into train and holdout halves'
      using errcode = '22023';
  end if;

  select count(*) > 1 into v_use_branch
    from public.branches br where br.business_id = p_business and br.active;
  v_use_branch := coalesce(v_use_branch, false) and p_branch is null;

  v_prior_from := (p_from - interval '1 year')::date;
  v_prior_to := (p_to - interval '1 year')::date;

  with

  -- ---------------------------------------------------------------------------------------
  -- Per-half anchor population: one row per (half, client) with everything a dimension needs.
  -- ---------------------------------------------------------------------------------------
  halves as (
    select 'train'::text as half, p_from as h_from, v_train_to as h_to
    union all
    select 'holdout', v_holdout_from, p_to
  ),
  anchors as (
    select h.half, s.client_id,
           min((s.occurred_at at time zone 'Asia/Singapore')::date) as anchor_date
      from halves h
      join public.sales s on s.business_id = p_business
      cross join lateral app.analytics_sale_class_v1(s) sc
     where (p_branch is null or s.branch_id = p_branch)
       and sc.include_visit
       and not sc.is_synthetic_client
       and s.client_id is not null
       and (s.occurred_at at time zone 'Asia/Singapore')::date between h.h_from and h.h_to
     group by h.half, s.client_id
  ),
  anchor_sale as (
    -- the specific sale row for that anchor date (min id breaks a same-day tie deterministically).
    select a.half, a.client_id, a.anchor_date,
           (select s.id from public.sales s
              cross join lateral app.analytics_sale_class_v1(s) sc
             where s.business_id = p_business and s.client_id = a.client_id
               and (p_branch is null or s.branch_id = p_branch)
               and sc.include_visit and not sc.is_synthetic_client
               and (s.occurred_at at time zone 'Asia/Singapore')::date = a.anchor_date
             order by s.id asc limit 1) as anchor_sale_id
      from anchors a
  ),
  population as (
    select ans.half, ans.client_id, ans.anchor_date, s.branch_id,
           extract(isodow from ans.anchor_date)::int as dow,
           c.first_acquired_via as acquisition,
           dem->>'age_band' as age_band,
           dem->>'gender' as gender,
           coalesce(tn.parent_key, tn.node_key) as l2_key,
           ((app.sg_today() - ans.anchor_date) >= 30) as mature,
           exists (
             select 1 from public.sales s2
             cross join lateral app.analytics_sale_class_v1(s2) sc2
            where s2.business_id = p_business and s2.client_id = ans.client_id
              and (p_branch is null or s2.branch_id = p_branch)
              and sc2.include_visit and not sc2.is_synthetic_client
              and (s2.occurred_at at time zone 'Asia/Singapore')::date > ans.anchor_date
              and (s2.occurred_at at time zone 'Asia/Singapore')::date <= ans.anchor_date + 30
           ) as returned
      from anchor_sale ans
      join public.sales s on s.id = ans.anchor_sale_id
      join public.clients c on c.id = ans.client_id
      cross join lateral (select app.customer_demographics_core_v674(p_business, ans.client_id) as dem) d
      left join lateral (
        select en.node_key
          from public.sale_items si
          cross join lateral app.ci_effective_node_v650(si) en
         where si.sale_id = ans.anchor_sale_id
         order by si.line_cents desc limit 1
      ) cat on true
      left join public.taxonomy_nodes tn on tn.version_no = 1 and tn.node_key = cat.node_key
  ),

  -- ---------------------------------------------------------------------------------------
  -- Fan each population row out to every dimension it classifies into.
  -- ---------------------------------------------------------------------------------------
  dim_rows as (
    select half, 'weekday'::text as dimension,
           case dow when 1 then 'Monday' when 2 then 'Tuesday' when 3 then 'Wednesday'
                    when 4 then 'Thursday' when 5 then 'Friday' when 6 then 'Saturday'
                    else 'Sunday' end as group_key,
           mature, returned
      from population
    union all
    select half, 'age_gender', age_band || '_' || gender, mature, returned
      from population where age_band is not null and gender is not null
    union all
    select half, 'category_node', l2_key, mature, returned
      from population where l2_key is not null
    union all
    select half, 'acquisition_source', acquisition, mature, returned
      from population where acquisition is not null
    union all
    select half, 'branch', branch_id::text, mature, returned
      from population where v_use_branch and branch_id is not null
  ),
  cells as (
    select half, dimension, group_key,
           count(*) filter (where mature) as n,
           count(*) filter (where mature and returned) as numer
      from dim_rows
     group by half, dimension, group_key
  ),
  train_cells as (select * from cells where half = 'train'),
  holdout_cells as (select * from cells where half = 'holdout'),
  train_totals as (
    select dimension, sum(n) as total_n, sum(numer) as total_numer
      from train_cells group by dimension
  ),
  holdout_totals as (
    select dimension, sum(n) as total_n, sum(numer) as total_numer
      from holdout_cells group by dimension
  ),

  -- ---------------------------------------------------------------------------------------
  -- Step 3-4: examined hypotheses, candidates, BH.
  -- ---------------------------------------------------------------------------------------
  examined as (
    select tc.dimension, tc.group_key, tc.n, tc.numer,
           (tt.total_n - tc.n)::bigint as rest_n, (tt.total_numer - tc.numer)::bigint as rest_numer
      from train_cells tc
      join train_totals tt on tt.dimension = tc.dimension
     where tc.n >= v_floor
       and (tt.total_n - tc.n) > 0
  ),
  evid as (
    select e.*,
           app.evidence_block_v1(
             'discovery_group', 'discovery_rest', p_from, v_train_to,
             e.n::integer, e.numer::integer, e.rest_n::integer, e.rest_numer::integer,
             'group vs all other groups in the same dimension (train half)',
             'strong_pattern', array[]::text[], null, 1) as block,
           app.two_prop_p_value_v686(e.numer, e.n, e.rest_numer, e.rest_n) as p_value
      from examined e
  ),
  scored as (
    select *,
           (block->'difference'->>'absolute_pp')::numeric as diff_pp,
           (block->'difference'->'confidence_95_pp'->>0)::numeric as ci_lo,
           (block->'difference'->'confidence_95_pp'->>1)::numeric as ci_hi
      from evid
  ),
  candidates as (
    select * from scored
     where abs(diff_pp) >= 10
       and not (ci_lo <= 0 and ci_hi >= 0)
  ),
  ranked as (
    select *, row_number() over (order by p_value asc, dimension, group_key) as p_rank,
           count(*) over () as m
      from candidates
  ),
  bh as (
    select *, (p_value <= (p_rank::numeric / m) * v_q) as clears_own_rank
      from ranked
  ),
  bh_cutoff as (
    select coalesce(max(p_rank) filter (where clears_own_rank), 0) as k from bh
  ),
  survivors as (
    select bh.* from bh, bh_cutoff where bh.p_rank <= bh_cutoff.k
  ),

  -- ---------------------------------------------------------------------------------------
  -- v691 (check 68): STRATIFIED CONFOUNDER CHECK. For every BH survivor (dimension D, group G),
  -- recompute G-vs-rest-of-D separately within every stratum of every OTHER predetermined
  -- dimension, using the TRAIN half's own population (the same half candidacy was judged on).
  -- ---------------------------------------------------------------------------------------
  train_pop_raw as (
    select client_id, mature, returned, dow, age_band, gender, l2_key, acquisition, branch_id
      from population where half = 'train'
  ),
  confound_strata as (
    select sv.dimension as focus_dim, sv.group_key as focus_group, sv.diff_pp as focus_diff_pp,
           o.dim_name as other_dim,
           app.discovery_dim_label_v691(
             o.dim_name, t.dow, t.age_band, t.gender, t.l2_key, t.acquisition, t.branch_id
           ) as stratum_value,
           count(*) filter (
             where t.mature and app.discovery_dim_label_v691(
                     sv.dimension, t.dow, t.age_band, t.gender, t.l2_key, t.acquisition, t.branch_id
                   ) = sv.group_key
           ) as g_n,
           count(*) filter (
             where t.mature and t.returned and app.discovery_dim_label_v691(
                     sv.dimension, t.dow, t.age_band, t.gender, t.l2_key, t.acquisition, t.branch_id
                   ) = sv.group_key
           ) as g_numer,
           count(*) filter (
             where t.mature and app.discovery_dim_label_v691(
                     sv.dimension, t.dow, t.age_band, t.gender, t.l2_key, t.acquisition, t.branch_id
                   ) is not null
               and app.discovery_dim_label_v691(
                     sv.dimension, t.dow, t.age_band, t.gender, t.l2_key, t.acquisition, t.branch_id
                   ) <> sv.group_key
           ) as rest_n,
           count(*) filter (
             where t.mature and t.returned and app.discovery_dim_label_v691(
                     sv.dimension, t.dow, t.age_band, t.gender, t.l2_key, t.acquisition, t.branch_id
                   ) is not null
               and app.discovery_dim_label_v691(
                     sv.dimension, t.dow, t.age_band, t.gender, t.l2_key, t.acquisition, t.branch_id
                   ) <> sv.group_key
           ) as rest_numer
      from survivors sv
      cross join lateral unnest(
        array['weekday','age_gender','category_node','acquisition_source']
        || case when v_use_branch then array['branch'] else array[]::text[] end
      ) as o(dim_name)
      cross join train_pop_raw t
     where o.dim_name <> sv.dimension
       and app.discovery_dim_label_v691(
             o.dim_name, t.dow, t.age_band, t.gender, t.l2_key, t.acquisition, t.branch_id
           ) is not null
     group by sv.dimension, sv.group_key, sv.diff_pp, o.dim_name,
              app.discovery_dim_label_v691(
                o.dim_name, t.dow, t.age_band, t.gender, t.l2_key, t.acquisition, t.branch_id
              )
  ),
  confound_eligible as (
    select *,
           (g_n >= v_floor and rest_n >= v_floor) as eligible,
           case when g_n > 0 then g_numer::numeric / g_n else null end as g_rate,
           case when rest_n > 0 then rest_numer::numeric / rest_n else null end as rest_rate
      from confound_strata
  ),
  confound_signs as (
    select *,
           (g_rate - rest_rate) as stratum_diff,
           sign(g_rate - rest_rate) as stratum_sign,
           sign(focus_diff_pp) as focus_sign
      from confound_eligible where eligible
  ),
  confound_agg as (
    select focus_dim, focus_group,
           count(*) as strata_checked,
           count(*) filter (where stratum_sign = focus_sign and stratum_sign <> 0) as strata_consistent,
           count(*) filter (where stratum_sign <> focus_sign and stratum_sign <> 0) as strata_reversed,
           coalesce(jsonb_agg(jsonb_build_object(
             'dimension', other_dim, 'stratum', stratum_value,
             'group_rate_pct', round(g_rate * 100, 1), 'rest_rate_pct', round(rest_rate * 100, 1),
             'diff_pp', round(stratum_diff * 100, 1))
             order by other_dim, stratum_value), '[]'::jsonb) as strata_detail
      from confound_signs
     group by focus_dim, focus_group
  ),
  survivors_with_confound as (
    select sv.*,
           coalesce(ca.strata_checked, 0) as strata_checked,
           coalesce(ca.strata_consistent, 0) as strata_consistent,
           coalesce(ca.strata_reversed, 0) as strata_reversed,
           coalesce(ca.strata_detail, '[]'::jsonb) as strata_detail
      from survivors sv
      left join confound_agg ca on ca.focus_dim = sv.dimension and ca.focus_group = sv.group_key
  ),
  confound_final as (
    select *,
           -- v702 (check 68 refutation 2): strata_checked = 0 used to fall into the SAME
           -- 'consistent' bucket as "every checked stratum agreed" -- indistinguishable from a
           -- confirmed-clean result when it actually means the confounder check never ran at
           -- all. It now gets its own verdict, 'unchecked', so 'consistent' means only what it
           -- says: at least one stratum was checked, and none reversed.
           case when strata_checked = 0 then 'unchecked'
                when strata_reversed::numeric / strata_checked > 0.5 then 'reversed'
                when strata_reversed = 0 then 'consistent'
                else 'mixed' end as verdict
      from survivors_with_confound
  ),
  confound_block as (
    select dimension, group_key, verdict,
           jsonb_build_object(
             'strata_checked', strata_checked,
             'strata_consistent', strata_consistent,
             'strata_reversed', strata_reversed,
             'verdict', verdict,
             'note', case verdict
               when 'reversed' then format(
                 'sign reverses in %s of %s checked strata (a majority); the aggregate direction '
                 'may be driven by an uneven mix of %s across strata rather than a genuine '
                 'within-stratum effect', strata_reversed, strata_checked, group_key)
               when 'mixed' then format(
                 '%s of %s checked strata reverse sign; interpret the aggregate direction with caution',
                 strata_reversed, strata_checked)
               when 'unchecked' then
                 'no other dimension cleared the floor on both sides; not promoted'
               else format('sign holds across all %s checked strata', strata_checked)
             end,
             'detail', strata_detail
           ) as confounders
      from confound_final
  ),

  -- ---------------------------------------------------------------------------------------
  -- Step 5: holdout replication for each BH survivor.
  -- ---------------------------------------------------------------------------------------
  survivor_eval as (
    select sv.*,
           hc.n as h_n, hc.numer as h_numer,
           ht.total_n as h_total_n, ht.total_numer as h_total_numer
      from survivors sv
      left join holdout_cells hc on hc.dimension = sv.dimension and hc.group_key = sv.group_key
      left join holdout_totals ht on ht.dimension = sv.dimension
  ),
  survivor_final as (
    select *,
           (h_total_n - coalesce(h_n, 0)) as h_rest_n,
           (h_total_numer - coalesce(h_numer, 0)) as h_rest_numer
      from survivor_eval
  ),
  survivor_verdict as (
    select *,
           case when h_n is not null and h_n >= v_floor and h_rest_n > 0
                then round(100.0 * h_numer / h_n - 100.0 * h_rest_numer / h_rest_n, 1)
                else null end as h_diff_pp
      from survivor_final
  ),
  survivor_replicated as (
    select sv.*, cb.confounders, cb.verdict as confound_verdict,
           (h_diff_pp is not null and sign(h_diff_pp) = sign(sv.diff_pp) and sign(sv.diff_pp) <> 0)
             as replicated
      from survivor_verdict sv
      left join confound_block cb on cb.dimension = sv.dimension and cb.group_key = sv.group_key
  ),

  -- ---------------------------------------------------------------------------------------
  -- Step 6: deterioration -- independent of the candidate/BH pipeline (see header).
  -- ---------------------------------------------------------------------------------------
  both_floor as (
    select tc.dimension, tc.group_key,
           tc.n as train_n, tc.numer as train_numer,
           hcell.n as holdout_n, hcell.numer as holdout_numer
      from train_cells tc
      join holdout_cells hcell on hcell.dimension = tc.dimension and hcell.group_key = tc.group_key
     where tc.n >= v_floor and hcell.n >= v_floor
  ),
  det_evid as (
    select bf.*,
           app.evidence_block_v1(
             'discovery_group_train', 'discovery_group_holdout', p_from, p_to,
             bf.train_n::integer, bf.train_numer::integer,
             bf.holdout_n::integer, bf.holdout_numer::integer,
             'same group, train half vs holdout half', 'strong_pattern', array[]::text[], null, 1
           ) as block
      from both_floor bf
  ),
  det_scored as (
    select *,
           round(100.0 * train_numer / train_n, 1) as train_pct,
           round(100.0 * holdout_numer / holdout_n, 1) as holdout_pct,
           (block->'difference'->'confidence_95_pp'->>0)::numeric as ci_lo,
           (block->'difference'->'confidence_95_pp'->>1)::numeric as ci_hi
      from det_evid
  ),
  deteriorating_rows as (
    select * from det_scored
     where (train_pct - holdout_pct) >= 10
       and not (ci_lo <= 0 and ci_hi >= 0)
  ),

  -- ---------------------------------------------------------------------------------------
  -- Missingness (headline = whole period, not split by half) and prior-year seasonality.
  -- ---------------------------------------------------------------------------------------
  headline as (
    select count(*) filter (where mature) as n, count(*) filter (where mature and returned) as numer
      from population
  ),
  cohort_clients as (
    select distinct client_id from population
  ),
  anon_sales as (
    select count(*) as n
      from public.sales s
      cross join lateral app.analytics_sale_class_v1(s) sc
     where s.business_id = p_business
       and (p_branch is null or s.branch_id = p_branch)
       and sc.include_visit and not sc.is_synthetic_client
       and s.client_id is null
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
  ),
  ident_sales as (
    select count(*) as n
      from public.sales s
      cross join lateral app.analytics_sale_class_v1(s) sc
     where s.business_id = p_business
       and (p_branch is null or s.branch_id = p_branch)
       and sc.include_visit and not sc.is_synthetic_client
       and s.client_id is not null
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
  ),
  prior_anchors as (
    select s.client_id, min((s.occurred_at at time zone 'Asia/Singapore')::date) as anchor_date
      from public.sales s
      cross join lateral app.analytics_sale_class_v1(s) sc
     where s.business_id = p_business
       and (p_branch is null or s.branch_id = p_branch)
       and sc.include_visit and not sc.is_synthetic_client
       and s.client_id is not null
       and (s.occurred_at at time zone 'Asia/Singapore')::date between v_prior_from and v_prior_to
     group by s.client_id
  ),
  prior_pop as (
    select pa.client_id, pa.anchor_date,
           ((app.sg_today() - pa.anchor_date) >= 30) as mature,
           exists (
             select 1 from public.sales s2
             cross join lateral app.analytics_sale_class_v1(s2) sc2
            where s2.business_id = p_business and s2.client_id = pa.client_id
              and (p_branch is null or s2.branch_id = p_branch)
              and sc2.include_visit and not sc2.is_synthetic_client
              and (s2.occurred_at at time zone 'Asia/Singapore')::date > pa.anchor_date
              and (s2.occurred_at at time zone 'Asia/Singapore')::date <= pa.anchor_date + 30
           ) as returned
      from prior_anchors pa
  ),
  prior_agg as (
    select count(*) filter (where mature) as n, count(*) filter (where mature and returned) as numer
      from prior_pop
  )

  select
    jsonb_build_object(
      'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                   'from', p_from, 'to', p_to),
      'period', jsonb_build_object('from', p_from, 'to', p_to),
      'train', jsonb_build_object('from', p_from, 'to', v_train_to),
      'holdout', jsonb_build_object('from', v_holdout_from, 'to', p_to),
      'metric', 'return_within_30_days_rate_per_first_purchase_in_window',
      'segment_dimensions',
        (select jsonb_agg(d) from unnest(
           array['weekday','age_gender','category_node','acquisition_source']
           || case when v_use_branch then array['branch'] else array[]::text[] end) d),

      'discoveries', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'dimension', sr.dimension, 'group', sr.group_key,
                 'train', jsonb_build_object('n', sr.n, 'rate', round(100.0*sr.numer/sr.n,1)),
                 'holdout', jsonb_build_object('n', sr.h_n, 'rate',
                              case when sr.h_n > 0 then round(100.0*sr.h_numer/sr.h_n,1) else null end),
                 'diff_pp', sr.diff_pp, 'interval', sr.block->'difference'->'confidence_95_pp',
                 'p_value', sr.p_value, 'bh_rank', sr.p_rank, 'replicated', true,
                 'evidence_class', 'ASSOCIATION',
                 'confounders', sr.confounders)
               order by sr.dimension, sr.group_key)
          -- v702 (check 68 refutation 1): promotion now requires an EXPLICIT
          -- confound_verdict = 'consistent' match, not merely "not flagged reversed" -- a
          -- 'mixed' survivor (a minority of strata disagree) no longer sails into the one list a
          -- caller is meant to be able to trust without reading confounders itself.
          from survivor_replicated sr where sr.replicated and sr.confound_verdict = 'consistent'), '[]'::jsonb),

      -- v691: a BH survivor that replicates on holdout but whose train-half sign is a Simpson's-
      -- paradox artifact (majority of checked strata reverse) is disclosed here instead of
      -- 'discoveries' — never silently dropped. v702: 'mixed' (a minority reversed) joins
      -- 'reversed' here too -- both mean "at least one stratum disagreed with the aggregate," and
      -- both keep the same 'confounded':true tag and full strata detail.
      'confounded', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'dimension', sr.dimension, 'group', sr.group_key,
                 'train', jsonb_build_object('n', sr.n, 'rate', round(100.0*sr.numer/sr.n,1)),
                 'holdout', jsonb_build_object('n', sr.h_n, 'rate',
                              case when sr.h_n > 0 then round(100.0*sr.h_numer/sr.h_n,1) else null end),
                 'diff_pp', sr.diff_pp, 'interval', sr.block->'difference'->'confidence_95_pp',
                 'p_value', sr.p_value, 'bh_rank', sr.p_rank, 'replicated', true,
                 'evidence_class', 'ASSOCIATION',
                 'confounded', true,
                 'confounders', sr.confounders)
               order by sr.dimension, sr.group_key)
          from survivor_replicated sr where sr.replicated and sr.confound_verdict in ('mixed','reversed')), '[]'::jsonb),

      -- v702 (check 68 refutation 2): a survivor whose confounder check never ran (no OTHER
      -- dimension cleared the floor on both sides) is disclosed here, separately from a
      -- confirmed-clean 'consistent' verdict, instead of silently defaulting to 'consistent'.
      'unverified', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'dimension', sr.dimension, 'group', sr.group_key,
                 'train', jsonb_build_object('n', sr.n, 'rate', round(100.0*sr.numer/sr.n,1)),
                 'holdout', jsonb_build_object('n', sr.h_n, 'rate',
                              case when sr.h_n > 0 then round(100.0*sr.h_numer/sr.h_n,1) else null end),
                 'diff_pp', sr.diff_pp, 'interval', sr.block->'difference'->'confidence_95_pp',
                 'p_value', sr.p_value, 'bh_rank', sr.p_rank, 'replicated', true,
                 'evidence_class', 'ASSOCIATION',
                 'confounders', sr.confounders)
               order by sr.dimension, sr.group_key)
          from survivor_replicated sr where sr.replicated and sr.confound_verdict = 'unchecked'), '[]'::jsonb),

      'not_replicated', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'dimension', sr.dimension, 'group', sr.group_key,
                 'train', jsonb_build_object('n', sr.n, 'rate', round(100.0*sr.numer/sr.n,1)),
                 'holdout', jsonb_build_object('n', sr.h_n, 'rate',
                              case when coalesce(sr.h_n,0) > 0 then round(100.0*sr.h_numer/sr.h_n,1) else null end),
                 'diff_pp', sr.diff_pp, 'interval', sr.block->'difference'->'confidence_95_pp',
                 'p_value', sr.p_value, 'bh_rank', sr.p_rank, 'replicated', false,
                 'evidence_class', 'ASSOCIATION',
                 'confounders', sr.confounders)
               order by sr.dimension, sr.group_key)
          from survivor_replicated sr where not sr.replicated), '[]'::jsonb),

      'deteriorating', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'dimension', dr.dimension, 'group', dr.group_key,
                 'train', jsonb_build_object('n', dr.train_n, 'rate', dr.train_pct),
                 'holdout', jsonb_build_object('n', dr.holdout_n, 'rate', dr.holdout_pct),
                 'diff_pp', round(dr.train_pct - dr.holdout_pct, 1),
                 'interval', dr.block->'difference'->'confidence_95_pp')
               order by dr.dimension, dr.group_key)
          from deteriorating_rows dr), '[]'::jsonb),

      'false_discovery_control', jsonb_build_object(
        'hypotheses_examined', (select count(*) from examined),
        'candidates_pre_bh', (select count(*) from candidates),
        'survivors_post_bh', (select count(*) from survivors),
        'q', v_q,
        'method', 'two-proportion z-test p-value per candidate (group vs rest, train half); '
          'Benjamini-Hochberg step-up at q=0.10 over the candidate p-values only'),
      -- v702: 'promoted' now counts 'consistent'-verdict discoveries only, matching what
      -- 'discoveries' itself actually contains post-fix (previously every replicated survivor
      -- regardless of confound verdict, which over-counted "promoted" the same way the list did).
      'comparisons', app.comparisons_note_v1(
        (select count(*) from examined)::integer,
        (select count(*) from survivor_replicated
           where replicated and confound_verdict = 'consistent')::integer),

      -- v691 (68): fixed disclosure of marketing exposure touching this call's cohort. Reported,
      -- not adjusted -- the pipeline above makes no attempt to net campaign contact out of the
      -- return-rate calculation.
      'competing_campaigns', jsonb_build_object(
        'count', coalesce((
          select count(*) from public.campaign_send_records_v255 csr
           where csr.business_id = p_business
             and csr.client_id in (select client_id from cohort_clients)
             and (csr.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
        ), 0),
        'note', 'campaign exposure is reported, not adjusted'),

      'seasonality', jsonb_build_object(
        'method', 'same_period_prior_year',
        'available',
          (select (app.metric_observed_since_v1('ci_discovery', p_business) <= v_prior_from::timestamptz)
                  and coalesce((select n from prior_agg), 0) > 0),
        'prior_period', jsonb_build_object('from', v_prior_from, 'to', v_prior_to),
        'current_pct', (select case when h.n > 0 then round(100.0*h.numer/h.n,1) else null end from headline h),
        'prior_year_pct', (
          select case
            when (app.metric_observed_since_v1('ci_discovery', p_business) <= v_prior_from::timestamptz)
                 and coalesce(pa.n,0) > 0 and pa.n > 0
            then round(100.0*pa.numer/pa.n, 1) else null end
          from prior_agg pa),
        'note', 'Compares the same metric for the identical calendar window one year earlier; '
          'unavailable when the metric was not yet observed that far back or no qualifying '
          'customers exist in that prior window.'),

      'missingness', jsonb_build_object(
        'anonymous_sales', (select n from anon_sales),
        'identified_sales', (select n from ident_sales),
        'headline', jsonb_build_object(
          'numerator', (select numer from headline), 'denominator', (select n from headline)),
        'bounds', jsonb_build_object(
          'metric_if_anonymous_all_returned',
            (select case when (h.n + a.n) > 0
                          then round(100.0*(h.numer + a.n)/(h.n + a.n), 1) else null end
               from headline h, anon_sales a),
          'metric_if_anonymous_none_returned',
            (select case when (h.n + a.n) > 0
                          then round(100.0*h.numer/(h.n + a.n), 1) else null end
               from headline h, anon_sales a)),
        'note', 'Anonymous (no client_id) qualifying sales cannot be scored as returned or not; '
          'the bracket shows the headline rate under the two extreme assumptions about them.'),

      'time_basis', 'sale_occurred_at',
      'limitation', 'segments are predefined dimensions; discoveries are associations validated '
        'on later data, not causes',
      'observed_since', app.metric_observed_since_v1('ci_discovery', p_business)
    )
  into v_result;

  return app.ci_envelope_v680('ci_discovery_v1', p_business, p_branch, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
end;
$function$;
revoke all on function public.get_ci_discovery_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_discovery_v1(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 3 · Prove the body diff is exactly the diff that was intended, and nothing else drifted. The
--     header/signature line is deliberately NOT included in this byte-diff (pg_get_functiondef
--     regenerates the parameter-list text in its own canonical form, independent of source
--     formatting, so a literal replace() against it would be fragile) -- only the body content
--     between the function's dollar-quote delimiters is compared, which Postgres stores and
--     echoes back verbatim.
-- ---------------------------------------------------------------------------------------------
do $post$
declare
  v_before      text;
  v_after       text;
  v_body_before text;
  v_body_after  text;
  v_expected    text;

  v_a_old constant text := $tag_a_old$           case when strata_checked = 0 then 'consistent'
                when strata_reversed::numeric / strata_checked > 0.5 then 'reversed'$tag_a_old$;
  v_a_new constant text := $tag_a_new$           -- v702 (check 68 refutation 2): strata_checked = 0 used to fall into the SAME
           -- 'consistent' bucket as "every checked stratum agreed" -- indistinguishable from a
           -- confirmed-clean result when it actually means the confounder check never ran at
           -- all. It now gets its own verdict, 'unchecked', so 'consistent' means only what it
           -- says: at least one stratum was checked, and none reversed.
           case when strata_checked = 0 then 'unchecked'
                when strata_reversed::numeric / strata_checked > 0.5 then 'reversed'$tag_a_new$;

  v_b_old constant text := $tag_b_old$  confound_block as (
    select dimension, group_key,
           jsonb_build_object(
             'strata_checked', strata_checked,
             'strata_consistent', strata_consistent,
             'strata_reversed', strata_reversed,
             'verdict', verdict,
             'note', case verdict
               when 'reversed' then format(
                 'sign reverses in %s of %s checked strata (a majority); the aggregate direction '
                 'may be driven by an uneven mix of %s across strata rather than a genuine '
                 'within-stratum effect', strata_reversed, strata_checked, group_key)
               when 'mixed' then format(
                 '%s of %s checked strata reverse sign; interpret the aggregate direction with caution',
                 strata_reversed, strata_checked)
               else case when strata_checked = 0
                 then 'no other dimension had at least the sample floor of customers on both sides to check for confounding'
                 else format('sign holds across all %s checked strata', strata_checked) end
             end,
             'detail', strata_detail
           ) as confounders,
           (verdict = 'reversed') as confounded
      from confound_final
  ),$tag_b_old$;
  v_b_new constant text := $tag_b_new$  confound_block as (
    select dimension, group_key, verdict,
           jsonb_build_object(
             'strata_checked', strata_checked,
             'strata_consistent', strata_consistent,
             'strata_reversed', strata_reversed,
             'verdict', verdict,
             'note', case verdict
               when 'reversed' then format(
                 'sign reverses in %s of %s checked strata (a majority); the aggregate direction '
                 'may be driven by an uneven mix of %s across strata rather than a genuine '
                 'within-stratum effect', strata_reversed, strata_checked, group_key)
               when 'mixed' then format(
                 '%s of %s checked strata reverse sign; interpret the aggregate direction with caution',
                 strata_reversed, strata_checked)
               when 'unchecked' then
                 'no other dimension cleared the floor on both sides; not promoted'
               else format('sign holds across all %s checked strata', strata_checked)
             end,
             'detail', strata_detail
           ) as confounders
      from confound_final
  ),$tag_b_new$;

  v_c_old constant text := $tag_c_old$  survivor_replicated as (
    select sv.*, cb.confounders, coalesce(cb.confounded, false) as confounded,
           (h_diff_pp is not null and sign(h_diff_pp) = sign(sv.diff_pp) and sign(sv.diff_pp) <> 0)
             as replicated
      from survivor_verdict sv
      left join confound_block cb on cb.dimension = sv.dimension and cb.group_key = sv.group_key
  ),$tag_c_old$;
  v_c_new constant text := $tag_c_new$  survivor_replicated as (
    select sv.*, cb.confounders, cb.verdict as confound_verdict,
           (h_diff_pp is not null and sign(h_diff_pp) = sign(sv.diff_pp) and sign(sv.diff_pp) <> 0)
             as replicated
      from survivor_verdict sv
      left join confound_block cb on cb.dimension = sv.dimension and cb.group_key = sv.group_key
  ),$tag_c_new$;

  v_d_old constant text := $tag_d_old$          from survivor_replicated sr where sr.replicated and not sr.confounded), '[]'::jsonb),$tag_d_old$;
  v_d_new constant text := $tag_d_new$          -- v702 (check 68 refutation 1): promotion now requires an EXPLICIT
          -- confound_verdict = 'consistent' match, not merely "not flagged reversed" -- a
          -- 'mixed' survivor (a minority of strata disagree) no longer sails into the one list a
          -- caller is meant to be able to trust without reading confounders itself.
          from survivor_replicated sr where sr.replicated and sr.confound_verdict = 'consistent'), '[]'::jsonb),$tag_d_new$;

  v_h_old constant text := $tag_h_old$      -- v691: a BH survivor that replicates on holdout but whose train-half sign is a Simpson's-
      -- paradox artifact (majority of checked strata reverse) is disclosed here instead of
      -- 'discoveries' — never silently dropped.
      'confounded', coalesce(($tag_h_old$;
  v_h_new constant text := $tag_h_new$      -- v691: a BH survivor that replicates on holdout but whose train-half sign is a Simpson's-
      -- paradox artifact (majority of checked strata reverse) is disclosed here instead of
      -- 'discoveries' — never silently dropped. v702: 'mixed' (a minority reversed) joins
      -- 'reversed' here too -- both mean "at least one stratum disagreed with the aggregate," and
      -- both keep the same 'confounded':true tag and full strata detail.
      'confounded', coalesce(($tag_h_new$;

  v_e_old constant text := $tag_e_old$                 'confounders', sr.confounders)
               order by sr.dimension, sr.group_key)
          from survivor_replicated sr where sr.replicated and sr.confounded), '[]'::jsonb),

      'not_replicated', coalesce(($tag_e_old$;
  v_e_new constant text := $tag_e_new$                 'confounders', sr.confounders)
               order by sr.dimension, sr.group_key)
          from survivor_replicated sr where sr.replicated and sr.confound_verdict in ('mixed','reversed')), '[]'::jsonb),

      -- v702 (check 68 refutation 2): a survivor whose confounder check never ran (no OTHER
      -- dimension cleared the floor on both sides) is disclosed here, separately from a
      -- confirmed-clean 'consistent' verdict, instead of silently defaulting to 'consistent'.
      'unverified', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'dimension', sr.dimension, 'group', sr.group_key,
                 'train', jsonb_build_object('n', sr.n, 'rate', round(100.0*sr.numer/sr.n,1)),
                 'holdout', jsonb_build_object('n', sr.h_n, 'rate',
                              case when sr.h_n > 0 then round(100.0*sr.h_numer/sr.h_n,1) else null end),
                 'diff_pp', sr.diff_pp, 'interval', sr.block->'difference'->'confidence_95_pp',
                 'p_value', sr.p_value, 'bh_rank', sr.p_rank, 'replicated', true,
                 'evidence_class', 'ASSOCIATION',
                 'confounders', sr.confounders)
               order by sr.dimension, sr.group_key)
          from survivor_replicated sr where sr.replicated and sr.confound_verdict = 'unchecked'), '[]'::jsonb),

      'not_replicated', coalesce(($tag_e_new$;

  v_f_old constant text := $tag_f_old$      'comparisons', app.comparisons_note_v1(
        (select count(*) from examined)::integer,
        (select count(*) from survivor_replicated where replicated)::integer),$tag_f_old$;
  v_f_new constant text := $tag_f_new$      -- v702: 'promoted' now counts 'consistent'-verdict discoveries only, matching what
      -- 'discoveries' itself actually contains post-fix (previously every replicated survivor
      -- regardless of confound verdict, which over-counted "promoted" the same way the list did).
      'comparisons', app.comparisons_note_v1(
        (select count(*) from examined)::integer,
        (select count(*) from survivor_replicated
           where replicated and confound_verdict = 'consistent')::integer),$tag_f_new$;

  v_g_old constant text := $tag_g_old$  into v_result;

  return v_result;
end;$tag_g_old$;
  v_g_new constant text := $tag_g_new$  into v_result;

  return app.ci_envelope_v680('ci_discovery_v1', p_business, p_branch, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
end;$tag_g_new$;

begin
  select def into v_before from _v702_before;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname = 'get_ci_discovery_v1';

  if v_after is null then
    raise exception 'v702: public.get_ci_discovery_v1 not found after replacement';
  end if;

  v_body_before := split_part(v_before, '$function$', 2);
  v_body_after  := split_part(v_after,  '$function$', 2);

  if v_body_before = '' or v_body_after = '' then
    raise exception 'v702: could not isolate function body via the $function$ dollar-quote tag -- extract with pg_get_functiondef and re-diff rather than guessing';
  end if;

  if position(v_a_old in v_body_before) = 0 then
    raise exception 'v702: chunk A (confound_final verdict case) not found in the live body in the expected shape';
  end if;
  if position(v_b_old in v_body_before) = 0 then
    raise exception 'v702: chunk B (confound_block) not found in the live body in the expected shape';
  end if;
  if position(v_c_old in v_body_before) = 0 then
    raise exception 'v702: chunk C (survivor_replicated) not found in the live body in the expected shape';
  end if;
  if position(v_d_old in v_body_before) = 0 then
    raise exception 'v702: chunk D (discoveries where-clause) not found in the live body in the expected shape';
  end if;
  if position(v_e_old in v_body_before) = 0 then
    raise exception 'v702: chunk E (confounded where-clause + not_replicated transition) not found in the live body in the expected shape';
  end if;
  if position(v_f_old in v_body_before) = 0 then
    raise exception 'v702: chunk F (comparisons_note promoted count) not found in the live body in the expected shape';
  end if;
  if position(v_h_old in v_body_before) = 0 then
    raise exception 'v702: chunk H (confounded preamble comment) not found in the live body in the expected shape';
  end if;
  if position(v_g_old in v_body_before) = 0 then
    raise exception 'v702: chunk G (return statement) not found in the live body in the expected shape';
  end if;

  v_expected := v_body_before;
  v_expected := replace(v_expected, v_a_old, v_a_new);
  v_expected := replace(v_expected, v_b_old, v_b_new);
  v_expected := replace(v_expected, v_c_old, v_c_new);
  v_expected := replace(v_expected, v_d_old, v_d_new);
  v_expected := replace(v_expected, v_h_old, v_h_new);
  v_expected := replace(v_expected, v_e_old, v_e_new);
  v_expected := replace(v_expected, v_f_old, v_f_new);
  v_expected := replace(v_expected, v_g_old, v_g_new);

  if v_body_after <> v_expected then
    raise exception
      'v702: the new body differs from the old one by more than the named chunks -- '
      'something else drifted. expected_len=% actual_len=%', length(v_expected), length(v_body_after);
  end if;

  -- The removed shapes must be genuinely gone from the executable body.
  if position('sr.confounded' in v_body_after) > 0 or position('cb.confounded' in v_body_after) > 0 then
    raise exception 'v702: a reference to the removed confounded boolean column survives';
  end if;
  if position('when strata_checked = 0 then ''consistent''' in v_body_after) > 0 then
    raise exception 'v702: the strata_checked=0 -> consistent conflation survives';
  end if;
  if position('return v_result;' in v_body_after) > 0 then
    raise exception 'v702: the un-enveloped return survives';
  end if;

  -- The signature gained p_as_of (checked separately from the body diff -- see the header note
  -- on why the parameter-list line itself is not byte-diffed).
  if position('p_as_of' in v_after) = 0 then
    raise exception 'v702: p_as_of parameter not found on the new signature';
  end if;
end
$post$;

commit;
