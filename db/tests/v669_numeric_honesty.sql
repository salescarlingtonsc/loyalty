-- Acceptance suite for nestly_v669 — numeric honesty (Phase D re-assessment, D2 + D3).
--
-- WHY. v669 (db/migrations/20260901_nestly_v669_numeric_honesty.sql) closes two
-- misleading-number defects held red in the executed corpus:
--
--   D2  app.evidence_block_v1's confidence interval on the difference of two rates used an
--       unadjusted Wald approximation, which can (and at n=10/arm, 90% vs 10%, does) produce a
--       bound outside [-100,100] — the only range a percentage-point difference between two
--       rates can legally occupy. v669 replaces the arithmetic with a Newcombe hybrid Wilson
--       score interval, bounded to [-100,100] by construction. Held red by
--       db/tests/executed/v652_corpus_statistics.sql assertion S6b.
--
--   D3  app.customer_cadence_v1 turned a customer's genuinely-unknown median visit interval
--       (zero interval observations, e.g. exactly one visit) into a fabricated 0.0 via
--       `coalesce(median_interval_days, 0)`. v669 emits a real jsonb null instead. Held red by
--       db/tests/executed/v651_corpus_cadence.sql assertion C6.
--
-- This suite is a minimal, purpose-built rehearsal for those two assertions — not a copy of the
-- full v651/v652 corpora (which carry other, unrelated truth-table checks pinned to the OLD
-- Wald numbers that v669's own header documents as a known, accepted consequence; see
-- docs referenced in the migration). D2 needs no fixture (app.evidence_block_v1 is a pure,
-- table-free computation); D3 needs a minimal business/branch/client/sale fixture, modelled on
-- db/tests/executed/v651_corpus_cadence.sql's own C6 setup.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v669$
declare
  biz       uuid := '00000000-0000-4000-8000-000000066901';
  branch    uuid := '00000000-0000-4000-8000-000000066911';
  cl_single uuid := '00000000-0000-4000-8000-000000066921';
  g         jsonb;
  v_lo      numeric;
  v_hi      numeric;
  v_err     text;
begin
  ---------------------------------------------------------------------------
  -- D2 — app.evidence_block_v1: the Newcombe hybrid Wilson interval stays inside [-100,100]
  -- for the extreme small-n case that broke the old Wald interval (treated 9/10, comparison
  -- 1/10, n=10/arm — AT the default p_min_arm floor of 10, so the floor does not intervene and
  -- the interval arithmetic is genuinely exercised).
  ---------------------------------------------------------------------------
  g := app.evidence_block_v1(
    'ZZ v669 D2 population', 'ZZ v669 D2 denominator', current_date-10, current_date,
    10, 9, 10, 1, 'ZZ v669 D2 comparison');

  if (g->'sample'->>'treated')::int <> 10 or (g->'sample'->>'comparison')::int <> 10 then
    insert into _fail values ('D2-pre',
      'fixture did not land at n=10 per arm; the floor-boundary case would be untested');
  end if;

  v_lo := (g->'difference'->'confidence_95_pp'->>0)::numeric;
  v_hi := (g->'difference'->'confidence_95_pp'->>1)::numeric;

  -- Hand-computed Newcombe bounds for 90% vs 10% at n=10/arm (worked in the migration's own
  -- header and in db/tests/executed/v652_corpus_statistics.sql S6b): [37.0, 91.6] pp, +/-0.2.
  if abs(v_lo - 37.0) > 0.2 or abs(v_hi - 91.6) > 0.2 then
    insert into _fail values ('D2-truth-table',
      format('hand-computed Newcombe CI is [37.0, 91.6] pp +/-0.2 for 90%% vs 10%% at n=10/arm, got [%s,%s]',
             v_lo, v_hi));
  end if;

  if v_lo < -100 or v_lo > 100 or v_hi < -100 or v_hi > 100 then
    insert into _fail values ('D2-defect',
      format('app.evidence_block_v1 returned a percentage-point difference bound of [%s,%s], outside '
             'the only legal range [-100,100] for a difference between two rates -- the Wald defect '
             'v669 was supposed to close is still present', v_lo, v_hi));
  end if;

  if v_hi >= 100 then
    insert into _fail values ('D2-boundary',
      format('upper bound %s is not strictly less than 100 -- even this extreme 90%% vs 10%% case '
             'must stay inside the legal range with room to spare under the Wilson/Newcombe fix', v_hi));
  end if;

  if g->'difference'->>'method' <> 'Newcombe hybrid Wilson score, 95% interval on the difference in rates' then
    insert into _fail values ('D2-method',
      format('difference.method does not match the v669 disclosure string, got %s', g->'difference'->>'method'));
  end if;

  ---------------------------------------------------------------------------
  -- D3 — app.customer_cadence_v1: a customer with exactly one visit (zero interval
  -- observations) must get a genuine jsonb null for median_interval_days, never a fabricated
  -- 0.0 ("visits every day"). Minimal fixture: one business, one branch, one client, one sale.
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules)
  values (biz, 'ZZ v669 numeric honesty fixture', 'zz-v669-numeric-honesty',
          array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active)
  values (branch, biz, 'ZZ v669 branch', true, true);

  -- Same v106 reporting-contract landmine documented in v651_corpus_cadence.sql: a fresh
  -- branch's auto-inserted contract is dated from "now", which would silently exclude a
  -- backdated sale from cadence eligibility. Backdate it the same way that fixture does.
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, branch, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore',
         upper(b.currency), true
    from public.businesses b where b.id = biz;

  insert into public.clients (id, business_id, full_name)
  values (cl_single, biz, 'ZZ v669 single visit');

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (gen_random_uuid(), biz, branch, cl_single, 'service', 1000,
          (current_date - 5)::timestamp at time zone 'Asia/Singapore',
          (current_date - 5)::timestamp at time zone 'Asia/Singapore');

  begin
    g := app.customer_cadence_v1(biz, cl_single, (current_date)::timestamp at time zone 'Asia/Singapore');

    if g->>'status' <> 'ready' then
      insert into _fail values ('D3-pre',
        format('client_single status=%s (expected ready -- one visit is not zero visits)', g->>'status'));
    end if;
    if (g->>'interval_observations')::int <> 0 then
      insert into _fail values ('D3-pre',
        format('client_single interval_observations=%s, expected 0 (one visit has no interval)',
               g->>'interval_observations'));
    end if;

    -- THE ASSERTION THAT MATTERS: zero interval observations means there is no gap to compute a
    -- median FROM. A returned numeric here would be fabricated, not measured.
    if (g->'median_interval_days') is distinct from 'null'::jsonb then
      insert into _fail values ('D3-defect',
        format('client_single (0 interval observations, 1 visit) returned median_interval_days=%s '
               'instead of a genuine null -- the coalesce-to-zero defect v669 was supposed to close '
               'is still present', g->>'median_interval_days'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('D3', format('customer_cadence_v1(client_single) raised %s', v_err));
  end;
end
$v669$;

select case when count(*)=0
            then 'PASS — v669 numeric honesty: evidence interval stays legal, single-visit median stays null'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v669: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
