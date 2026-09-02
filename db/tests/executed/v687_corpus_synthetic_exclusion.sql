-- EXECUTED acceptance fixture for nestly_v687 — synthetic-client exclusion in
-- public.get_revenue_truth_v106 (db/migrations/20260902_nestly_v687_revenue_truth_synthetic_
-- exclusion.sql).
--
-- Named for v687 (above the v422 baseline watermark, docs/qa/CI-CORPUS-FIXTURE-GUIDE.md):
-- reported n/a in the baseline phase, gated on the migrated run.
--
-- THE DEFECT (D7). Before v687, get_revenue_truth_v106 counted a synthetic client's sales in
-- headline known/identified revenue and completed/identified_transactions, while every other
-- v6xx Customer Intelligence reader (get_ci_daypart_v1 among them, via app.analytics_sale_
-- class_v1's is_synthetic_client column, nestly_v628/v680) already excluded them. This fixture
-- proves both halves: (1) get_revenue_truth_v106 now excludes the synthetic client's sales
-- exactly, and (2) get_ci_daypart_v1's visit count and get_revenue_truth_v106's transaction count
-- now agree on the same seed — two independently-implemented readers landing on the same number
-- because they apply the same exclusion, not because one checks the other.
--
-- TRUTH TABLE (all amounts in cents; window is the half-open date range [d+1, d+3)):
--   Identified: 3 x 5000 = 15000, on client cl_id.
--   Anonymous:  2 x 2500 = 5000, client_id null.
--   Synthetic:  4 x 1000 = 4000, on client cl_synth (clients.is_synthetic = true).
--   known_revenue_minor      = 20000  (NOT 24000 — the synthetic 4000 must not appear)
--   identified_revenue_minor = 15000  (unaffected: synthetic is a distinct client from cl_id)
--   anonymous_revenue_minor  = 5000   (unchanged: synthetic sales are never anonymous either way)
--   completed_transactions   = 5      (3 identified + 2 anonymous; NOT 9)
--   identified_transactions  = 3      (NOT 7 — the 4 synthetic sales must not inflate this either,
--                                       even though cl_synth is a real, non-null client_id)
--   get_ci_daypart_v1's weekday visit sum must equal completed_transactions (5) on this same
--   seed — both readers exclude the same 4 synthetic rows independently.
--
-- RED-BEFORE / GREEN-AFTER. Captured 2026-09-02 by moving db/migrations/20260902_nestly_v687_
-- revenue_truth_synthetic_exclusion.sql out of db/migrations/ (so the migrated-phase database is
-- built without it — public.get_revenue_truth_v106 stays at its pre-v687, nestly_v573 shape) and
-- re-running `node scripts/db-tests/run.mjs --filter=v687_corpus --migrated-only`. Exact captured
-- output (verbatim, from the RAISE at the bottom of this file):
--
--   ERROR:  v687: 5 assertion(s) failed:
--     completed_transactions: completed_transactions was 9, expected 5 (3 identified + 2
--       anonymous, not the 4 synthetic rows)
--     identified_revenue: identified_revenue_minor was 19000, expected 15000 (unaffected by the
--       synthetic client)
--     identified_transactions: identified_transactions was 7, expected 3 (NOT 7 — the synthetic
--       client has a real, non-null client_id, so this must be an explicit is_synthetic
--       exclusion, not a null check)
--     known_revenue: known_revenue_minor was 24000, expected 20000 (synthetic 4000 must be
--       excluded, not 24000)
--     reader_agreement: get_ci_daypart_v1 visits (5) and get_revenue_truth_v106
--       completed_transactions (9) disagree on the same seed -- the two readers' synthetic-client
--       exclusions no longer produce the same number
--   1 failure(s) in 18.5s
--
-- Note get_ci_daypart_v1 already reported the correct 5 in the red run — its own nestly_v628/
-- v680 exclusion was never the defect; only get_revenue_truth_v106 was wrong, which is exactly
-- what produced the reader_agreement mismatch (5 vs 9) rather than both readers agreeing on the
-- wrong number.
--
-- Restoring the migration and re-running the same filter:
--
--   ok    v687_corpus_synthetic_exclusion.sql  (970ms)
--   all executed SQL passed in 11.9s
--
-- See the verdict block at the bottom of this file for the exact PASS wording asserted.
--
-- One transaction, rolled back. No production access.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v687$
declare
  biz        uuid := '00000000-0000-4000-8000-000000068701';
  br         uuid := '00000000-0000-4000-8000-000000068711';
  u_owner    uuid := '00000000-0000-4000-8000-000000068702';
  cl_id      uuid := '00000000-0000-4000-8000-000000068703';
  cl_synth   uuid := '00000000-0000-4000-8000-000000068704';
  d          date := current_date;

  s_id1      uuid := '00000000-0000-4000-8000-000000068801';
  s_id2      uuid := '00000000-0000-4000-8000-000000068802';
  s_id3      uuid := '00000000-0000-4000-8000-000000068803';
  s_an1      uuid := '00000000-0000-4000-8000-000000068804';
  s_an2      uuid := '00000000-0000-4000-8000-000000068805';
  s_sy1      uuid := '00000000-0000-4000-8000-000000068806';
  s_sy2      uuid := '00000000-0000-4000-8000-000000068807';
  s_sy3      uuid := '00000000-0000-4000-8000-000000068808';
  s_sy4      uuid := '00000000-0000-4000-8000-000000068809';

  g          jsonb;
  g_day      jsonb;
  v_err      text;
  v_synth_count integer;
  v_visits_actual bigint;
begin
  ---------------------------------------------------------------------------
  -- actor + operational business (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md "Making a business
  -- genuinely operational" — miss any one row and every read below refuses for a billing/
  -- approval reason, not a revenue-truth reason). 'customerintel' is listed because
  -- get_revenue_truth_v106 gates on it (nestly_v573), and nestly_v668 is what makes an
  -- entitled owner's own call actually reach the function.
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (u_owner, 'zz-v687-owner@example.test')
    on conflict (id) do nothing;

  insert into public.businesses (id, name, slug, enabled_modules)
  values (biz, 'ZZ v687 synthetic exclusion', 'zz-v687-synthetic-exclusion',
          array['dashboard','clients','sales','reports','customerintel']);

  insert into public.branches (id, business_id, name, is_default, active)
  values (br, biz, 'ZZ v687 branch', true, true);

  insert into public.staff (business_id, user_id, role, full_name, active, access_state)
  values (biz, u_owner, 'owner', 'ZZ v687 owner', true, 'approved');

  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v687 synthetic-exclusion fixture')
    on conflict (business_id) do update
      set approval_status='approved', decided_at=now(),
          decision_reason='v687 synthetic-exclusion fixture';

  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;

  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  insert into public.clients (id, business_id, full_name) values
    (cl_id, biz, 'ZZ v687 Identified Client');
  insert into public.clients (id, business_id, full_name, is_synthetic) values
    (cl_synth, biz, 'ZZ v687 Synthetic Client', true);

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner, 'role','authenticated')::text, true);

  -- PRECONDITION (CI-CORPUS-FIXTURE-GUIDE "the rule that matters most"): the seeded owner must
  -- genuinely hold view_finance and customerintel, or every read below is vacuous.
  if not app.has_perm(biz, 'view_finance') then
    insert into _fail values ('PRE',
      'fixture owner lacks view_finance; every get_revenue_truth_v106 call below is vacuous');
    return;
  end if;
  if not app.can_module(biz, 'customerintel') then
    insert into _fail values ('PRE',
      'fixture owner cannot reach customerintel; nestly_v668''s fix is a precondition of this '
      'fixture, not what it is testing');
    return;
  end if;

  ---------------------------------------------------------------------------
  -- Seed: 3 identified (5000 each), 2 anonymous (2500 each), 4 synthetic (1000 each).
  -- All dated d+2, all in window [d+1, d+3).
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  values
    (s_id1, biz, br, cl_id,    'service', 5000, d+2, true, true, true, d+2, 0, d+2),
    (s_id2, biz, br, cl_id,    'service', 5000, d+2, true, true, true, d+2, 0, d+2),
    (s_id3, biz, br, cl_id,    'service', 5000, d+2, true, true, true, d+2, 0, d+2),
    (s_an1, biz, br, null,     'service', 2500, d+2, true, true, true, d+2, 0, d+2),
    (s_an2, biz, br, null,     'service', 2500, d+2, true, true, true, d+2, 0, d+2),
    (s_sy1, biz, br, cl_synth, 'service', 1000, d+2, true, true, true, d+2, 0, d+2),
    (s_sy2, biz, br, cl_synth, 'service', 1000, d+2, true, true, true, d+2, 0, d+2),
    (s_sy3, biz, br, cl_synth, 'service', 1000, d+2, true, true, true, d+2, 0, d+2),
    (s_sy4, biz, br, cl_synth, 'service', 1000, d+2, true, true, true, d+2, 0, d+2);

  -- PRECONDITION: the synthetic sales genuinely exist, so the exclusion below is earned rather
  -- than vacuously true because there was never anything to exclude.
  select count(*) into v_synth_count
    from public.sales s where s.client_id = cl_synth and s.business_id = biz;
  if v_synth_count <> 4 then
    insert into _fail values ('PRE', format(
      'expected exactly 4 synthetic-client sales to exist before asserting their exclusion, found %s',
      v_synth_count));
    return;
  end if;

  ---------------------------------------------------------------------------
  -- get_revenue_truth_v106: synthetic sales must not appear anywhere in the totals.
  ---------------------------------------------------------------------------
  begin
    g := public.get_revenue_truth_v106(biz, d+1, d+3, br);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('known_revenue', format('get_revenue_truth_v106 raised %s', v_err));
    insert into _fail values ('identified_revenue', format('get_revenue_truth_v106 raised %s', v_err));
    insert into _fail values ('anonymous_revenue', format('get_revenue_truth_v106 raised %s', v_err));
    insert into _fail values ('completed_transactions', format('get_revenue_truth_v106 raised %s', v_err));
    insert into _fail values ('identified_transactions', format('get_revenue_truth_v106 raised %s', v_err));
  end;

  if g is not null then
    if (g#>>'{totals,known_revenue_minor}')::bigint <> 20000 then
      insert into _fail values ('known_revenue', format(
        'known_revenue_minor was %s, expected 20000 (synthetic 4000 must be excluded, not 24000)',
        g#>>'{totals,known_revenue_minor}'));
    end if;
    if (g#>>'{totals,identified_revenue_minor}')::bigint <> 15000 then
      insert into _fail values ('identified_revenue', format(
        'identified_revenue_minor was %s, expected 15000 (unaffected by the synthetic client)',
        g#>>'{totals,identified_revenue_minor}'));
    end if;
    if (g#>>'{totals,anonymous_revenue_minor}')::bigint <> 5000 then
      insert into _fail values ('anonymous_revenue', format(
        'anonymous_revenue_minor was %s, expected 5000 (unchanged either way)',
        g#>>'{totals,anonymous_revenue_minor}'));
    end if;
    if (g#>>'{totals,completed_transactions}')::bigint <> 5 then
      insert into _fail values ('completed_transactions', format(
        'completed_transactions was %s, expected 5 (3 identified + 2 anonymous, not the 4 '
        'synthetic rows)', g#>>'{totals,completed_transactions}'));
    end if;
    if (g#>>'{totals,identified_transactions}')::bigint <> 3 then
      insert into _fail values ('identified_transactions', format(
        'identified_transactions was %s, expected 3 (NOT 7 — the synthetic client has a real, '
        'non-null client_id, so this must be an explicit is_synthetic exclusion, not a null check)',
        g#>>'{totals,identified_transactions}'));
    end if;
  end if;

  ---------------------------------------------------------------------------
  -- get_ci_daypart_v1: independently excludes the same synthetic client (nestly_v628/v680, via
  -- app.analytics_sale_class_v1), so its visit count must equal get_revenue_truth_v106's
  -- completed_transactions on this exact seed — two separately-implemented readers agreeing,
  -- not one checking the other.
  ---------------------------------------------------------------------------
  begin
    g_day := public.get_ci_daypart_v1(biz, d+1, d+3, br);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('reader_agreement', format('get_ci_daypart_v1 raised %s', v_err));
  end;

  if g_day is not null then
    select coalesce(sum((w->>'visits')::bigint), 0) into v_visits_actual
      from jsonb_array_elements(g_day->'weekdays') w;
    if v_visits_actual <> 5 then
      insert into _fail values ('reader_agreement', format(
        'get_ci_daypart_v1 visits were %s, expected 5 (its own is_synthetic exclusion should '
        'already drop the 4 synthetic rows independently of v687)', v_visits_actual));
    end if;
    if g is not null
       and v_visits_actual <> (g#>>'{totals,completed_transactions}')::bigint then
      insert into _fail values ('reader_agreement', format(
        'get_ci_daypart_v1 visits (%s) and get_revenue_truth_v106 completed_transactions (%s) '
        'disagree on the same seed -- the two readers'' synthetic-client exclusions no longer '
        'produce the same number', v_visits_actual, g#>>'{totals,completed_transactions}'));
    end if;
  end if;

  perform set_config('request.jwt.claims', null, true);
end
$v687$;

select case when count(*)=0
            then 'PASS — v687 revenue truth: synthetic-client sales excluded from known/'
                 'identified revenue and completed/identified transactions, and get_ci_daypart_v1 '
                 'agrees with get_revenue_truth_v106 on the same seed'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v687: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
