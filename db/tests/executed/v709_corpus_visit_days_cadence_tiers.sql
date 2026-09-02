-- EXECUTED acceptance fixture for nestly_v709 — check 4 refutation, closed for the two visits-
-- shaped surfaces nestly_v699's sweep missed: app.customer_cadence_batch_v1 and
-- app.tier_resolve_v426.
--
-- Named v709 (above the v422 baseline watermark): n/a in the baseline phase, gated on the
-- migrated run (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md).
--
-- ============================================================================================
-- TRUTH TABLE (all offsets are whole days before v_as_of = midnight SGT, current_date; every
-- occurred_at is midnight-SGT on a (current_date - N) date, so every gap is an exact integer
-- number of days)
-- ============================================================================================
-- cl_split   5 sales at offsets [15,15,15,14,7] days ago -- a split bill (3 tickets, one
--            afternoon) 15 days ago, then one visit the next day (14 days ago), then one visit
--            "a week later" (7 days ago).
--
--            Pre-v709 (raw sale rows):  paid_visits=5, interval_observations=4, gaps between
--              consecutive SALE rows include two near-zero (same-instant) gaps from the
--              same-day trio -- a corrupted median (the exact defect nestly_v709 fixes).
--
--            Post-v709 (distinct visit-days, one row per calendar day):
--              visit days, oldest first: day(-15) [the 3-way tie], day(-14), day(-7).
--              gaps: day(-14)-day(-15) = 1 day; day(-7)-day(-14) = 7 days.
--              paid_visits = 3 (not 5).
--              interval_observations = 2 (not 4).
--              median_interval_days = percentile_cont(0.5) of {1,7} = 1 + 0.5*(7-1) = 4.0
--                (hand-computed: linear interpolation of a 2-element sorted array at rank 0.5).
--              last_visit_at = day(-7)'s (only) sale -- unaffected by the split-bill collision,
--                which sits on the FIRST visit day, not the last.
--              tier_resolve_v426(tier_basis='visits') metric = 3 (not 5).
--
-- cl_control 5 sales at offsets [40,33,25,16,6] days ago -- v651's own C1 fixture, reused
--            verbatim to prove NO regression: every sale lands on its own distinct calendar day,
--            so the visit-day collapse this migration adds is a no-op.
--              gaps, oldest first: 40-33=7, 33-25=8, 25-16=9, 16-6=10.
--              paid_visits = 5 (unchanged). interval_observations = 4 (unchanged).
--              median_interval_days = percentile_cont(0.5) of {7,8,9,10} = 8.5 (unchanged;
--                interpolated between the 2nd and 3rd order stats: (8+9)/2).
--              tier_resolve_v426(tier_basis='visits') metric = 5 (unchanged: count(distinct day)
--                equals count(*) when every sale is already on its own day).
-- ============================================================================================

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v709$
declare
  biz         uuid := '00000000-0000-4000-8000-000000709001';
  branch      uuid := '00000000-0000-4000-8000-000000709011';
  cl_split    uuid := '00000000-0000-4000-8000-000000709101';
  cl_control  uuid := '00000000-0000-4000-8000-000000709102';
  v_as_of     timestamptz := (current_date)::timestamp at time zone 'Asia/Singapore';
  v_before    date := (current_date + 1);
  v_row       record;
  v_tier      jsonb;
  v_registry  jsonb;
  v_n         integer;
  v_err       text;
begin
  ---------------------------------------------------------------------------
  -- fixture business + branch
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules)
  values (biz, 'ZZ v709 visit-days fixture', 'zz-v709-visit-days',
          array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active)
  values (branch, biz, 'ZZ v709 branch', true, true);

  -- v106 LANDMINE (documented in v651's own fixture): a brand-new branch's reporting contract
  -- otherwise starts "now", which would inner-join out every backdated sale below. Backdate an
  -- explicit contract version the same way v106 itself backdates pre-existing branches.
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, branch, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore',
         upper(b.currency), true
    from public.businesses b where b.id = biz;

  insert into public.clients (id, business_id, full_name) values
    (cl_split,   biz, 'ZZ v709 split-bill (3+1+1)'),
    (cl_control, biz, 'ZZ v709 control (v651 C1, 5 distinct days)');

  -- cl_split: 3 sales tied at the SAME instant 15 days ago (a split bill), then one sale 14
  -- days ago, then one sale 7 days ago ("a week later" than the 14-days-ago visit).
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, branch, cl_split, 'service', 1000,
         (current_date - o)::timestamp at time zone 'Asia/Singapore',
         (current_date - o)::timestamp at time zone 'Asia/Singapore'
    from unnest(array[15,15,15,14,7]) as o;

  -- cl_control: v651's C1 truth table, reused verbatim as the no-regression control.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, branch, cl_control, 'service', 1000,
         (current_date - o)::timestamp at time zone 'Asia/Singapore',
         (current_date - o)::timestamp at time zone 'Asia/Singapore'
    from unnest(array[40,33,25,16,6]) as o;

  -- a minimal loyalty_programs row so app.tier_resolve_v426 has a tier_basis to read.
  insert into public.loyalty_programs
    (business_id, kind, active, tier_basis, loyalty_model,
     earn_points_per_dollar, redeem_points, expiry_mode, configuration_status)
  values (biz, 'points', true, 'visits', 'classic', 1, 800, 'none', 'published');

  ---------------------------------------------------------------------------
  -- PRECONDITIONS. If the raw sale-row counts are not what the truth table assumes, every
  -- assertion below would pass or fail for a fixture reason, not a product one.
  ---------------------------------------------------------------------------
  select count(*) into v_n from public.sales where business_id = biz and client_id = cl_split;
  if v_n <> 5 then
    insert into _fail values ('PRE-split', format('cl_split has %s raw sales, expected 5', v_n));
  end if;
  select count(*) into v_n from public.sales where business_id = biz and client_id = cl_split
   and counts_as_visit;
  if v_n <> 5 then
    insert into _fail values ('PRE-split-policy',
      format('cl_split has %s counts_as_visit sales, expected 5 -- the sale-policy trigger did '
             'not resolve kind=service to counts_as_visit=true as documented', v_n));
  end if;
  select count(distinct occurred_at) into v_n from public.sales
   where business_id = biz and client_id = cl_split and (current_date - occurred_at::date) = 15;
  if v_n <> 1 then
    insert into _fail values ('PRE-split-tie',
      format('the 3 same-day sales landed on %s distinct instants, expected 1 (an exact tie) -- '
             'the split-bill collision this fixture depends on was not constructed', v_n));
  end if;

  ---------------------------------------------------------------------------
  -- A — app.customer_cadence_batch_v1: the split-bill client collapses to 3 visit-days.
  ---------------------------------------------------------------------------
  begin
    select b.* into v_row
      from app.customer_cadence_batch_v1(biz, v_before, v_before, v_as_of, null, true) b
     where b.client_id = cl_split;

    if not found then
      insert into _fail values ('A-pre', 'cl_split produced no row from customer_cadence_batch_v1');
    else
      if v_row.paid_visits <> 3 then
        insert into _fail values ('A-paid_visits',
          format('cl_split paid_visits=%s, expected 3 (5 sales collapse to 3 visit-days)',
                 v_row.paid_visits));
      end if;
      if v_row.interval_observations <> 2 then
        insert into _fail values ('A-interval_observations',
          format('cl_split interval_observations=%s, expected 2 (2 gaps between 3 visit-days, '
                 'not 4 between 5 sale rows)', v_row.interval_observations));
      end if;
      if v_row.median_interval_days <> 4.0 then
        insert into _fail values ('A-median',
          format('cl_split median_interval_days=%s, expected 4.0 (percentile_cont(0.5) of the '
                 'two day-gaps {1,7})', v_row.median_interval_days));
      end if;
      if v_row.last_visit_at <> ((current_date - 7)::timestamp at time zone 'Asia/Singapore') then
        insert into _fail values ('A-last_visit_at',
          format('cl_split last_visit_at=%s, expected the day(-7) sale timestamp -- the '
                 'split-bill collision sits on the FIRST visit day, not the last, so '
                 'last_visit_at must be untouched', v_row.last_visit_at));
      end if;
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('A', format('customer_cadence_batch_v1(cl_split) raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- B — app.customer_cadence_batch_v1: the control client is BYTE-IDENTICAL to v651's own C1
  --     truth table (paid_visits=5, interval_observations=4, median=8.5) -- no regression.
  ---------------------------------------------------------------------------
  begin
    select b.* into v_row
      from app.customer_cadence_batch_v1(biz, v_before, v_before, v_as_of, null, true) b
     where b.client_id = cl_control;

    if not found then
      insert into _fail values ('B-pre', 'cl_control produced no row from customer_cadence_batch_v1');
    else
      if v_row.paid_visits <> 5 then
        insert into _fail values ('B-paid_visits',
          format('cl_control paid_visits=%s, expected 5 (unchanged: 5 sales, 5 distinct days)',
                 v_row.paid_visits));
      end if;
      if v_row.interval_observations <> 4 then
        insert into _fail values ('B-interval_observations',
          format('cl_control interval_observations=%s, expected 4 (unchanged)',
                 v_row.interval_observations));
      end if;
      if v_row.median_interval_days <> 8.5 then
        insert into _fail values ('B-median',
          format('cl_control median_interval_days=%s, expected 8.5 (unchanged: median of '
                 '{7,8,9,10})', v_row.median_interval_days));
      end if;
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('B', format('customer_cadence_batch_v1(cl_control) raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- C — app.tier_resolve_v426, tier_basis='visits': the same authority, the same numbers.
  ---------------------------------------------------------------------------
  begin
    v_tier := app.tier_resolve_v426(biz, cl_split, v_as_of);
    if v_tier->>'basis' <> 'visits' then
      insert into _fail values ('C-pre',
        format('cl_split tier_resolve_v426 basis=%s, expected visits', v_tier->>'basis'));
    end if;
    if (v_tier->>'metric')::numeric <> 3 then
      insert into _fail values ('C-split-metric',
        format('cl_split tier_resolve_v426 metric=%s, expected 3 (distinct visit-days, not 5 '
               'raw sales)', v_tier->>'metric'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('C', format('tier_resolve_v426(cl_split) raised %s', v_err));
  end;

  begin
    v_tier := app.tier_resolve_v426(biz, cl_control, v_as_of);
    if (v_tier->>'metric')::numeric <> 5 then
      insert into _fail values ('C-control-metric',
        format('cl_control tier_resolve_v426 metric=%s, expected 5 (unchanged: 5 sales already '
               'on 5 distinct days)', v_tier->>'metric'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('C', format('tier_resolve_v426(cl_control) raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- D — app.ci_visit_registry_v699 names both fixed readers as using the authority. Proven
  --     against reality above (A/B/C), not merely trusted here.
  ---------------------------------------------------------------------------
  begin
    v_registry := app.ci_visit_registry_v699();
    if (v_registry#>'{readers,app.customer_cadence_batch_v1,uses_authority}') is distinct from 'true'::jsonb then
      insert into _fail values ('D-registry-batch',
        format('registry says app.customer_cadence_batch_v1 uses_authority=%s, expected true',
               v_registry#>>'{readers,app.customer_cadence_batch_v1,uses_authority}'));
    end if;
    if (v_registry#>'{readers,app.tier_resolve_v426,uses_authority}') is distinct from 'true'::jsonb then
      insert into _fail values ('D-registry-tier',
        format('registry says app.tier_resolve_v426 uses_authority=%s, expected true',
               v_registry#>>'{readers,app.tier_resolve_v426,uses_authority}'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('D', format('ci_visit_registry_v699() raised %s', v_err));
  end;
end
$v709$;

select case when count(*)=0 then 'PASS — visit-day collapse reaches cadence batch and tier resolution alike'
       else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v709: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
