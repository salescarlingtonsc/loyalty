-- EXECUTED acceptance fixture for nestly_v711 — check 4 refutation: public.
-- refresh_growth_recommendation_v108's metrics CTE now collapses same-day sales (a split bill)
-- into one visit before counting prior_visits and lagging cadence_days, matching the same
-- visit-day authority (app.ci_visit_day_v699, nestly_v699) nestly_v709 already applied to
-- app.customer_cadence_batch_v1 and app.tier_resolve_v426.
--
-- Named v711 (above the v422 baseline watermark): n/a in the baseline phase, gated on the
-- migrated run (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md).
--
-- AUTH CONTEXT. public.refresh_growth_recommendation_v108 requires auth.uid() plus either
-- app.is_super_admin() or (has_perm(view_finance) AND can_module_read(retention)). This fixture
-- uses a super admin, which ALSO requires the Google-SSO session claims app.is_super_admin() now
-- checks via app.platform_session_via_google_v625() (fixture guide, "Impersonation") — a bare
-- sub/role claim is not enough post-nestly_v625, and would make every assertion below fail for a
-- fixture reason, not the thing under test.
--
-- ============================================================================================
-- TRUTH TABLE (hand-computed BEFORE running anything; asserted as exact equality, never `> 0`)
-- ============================================================================================
-- All sales at 09:00 Asia/Singapore unless noted, so day-to-day gaps are exact whole days.
--
-- R (cl_refuter) — the check-4 refutation shape: 3 same-day sales + 1 next-day + 1 later.
--   Day -40: 3 sales (09:00, 13:00, 18:00).  Day -39: 1 sale.  Day -24: 1 sale.
--   OLD (buggy) behaviour, raw sale rows, for contrast only (NOT what this fixture asserts as
--   correct — see the mutation check below): prior_visits=5; gaps between the 5 chronological
--   rows (in days) = 0.1667, 0.2083, 0.625, 15.0 -> median (percentile_cont(0.5) over 4 values,
--   interpolated rank2..rank3) = 0.2083 + 0.5*(0.625-0.2083) = 0.41665 =~ 0.42 -- the same
--   corruption-toward-zero shape the nestly_v711 migration header describes.
--   NEW (fixed) behaviour: visit-days are {-40, -39, -24} -> prior_visits=3. Gaps: (-40)->(-39)=1
--   day, (-39)->(-24)=15 days. cadence_days = percentile_cont(0.5) over {1,15} = (1+15)/2 = 8.00.
--   last_visit_at: day -24 has only one sale, so the anchor-at-first-sale choice is a no-op here
--   -- last_visit_at is BYTE-IDENTICAL to the pre-nestly_v711 (raw max(occurred_at)) answer: the
--   day -24, 09:00 SGT sale.
--   minimum_prior_visits for a fresh 'other'-sector business is 4 (sector_policy_versions_v109,
--   sector_key='other'): 3 < 4 -> exclusion_reason='insufficient_history', eligible=false.
--
-- C (cl_control) — distinct-day control: 3 sales, one per day, at -50/-40/-25. No day has more
--   than one sale, so the visit-day collapse is a no-op for every one of its inputs: prior_visits
--   and cadence_days must be IDENTICAL under old and new counting.
--   prior_visits=3. Gaps: (-50)->(-40)=10 days, (-40)->(-25)=15 days. cadence_days =
--   percentile_cont(0.5) over {10,15} = 12.50. 3 < 4 -> insufficient_history, eligible=false.
--
-- L (cl_lastday) — the anchor-rule proof: 1 sale at day -30 (09:00), then TWO sales on the
--   customer's LAST visit day, -10, at 09:00 and 15:00 -- a collision on the last day specifically.
--   Visit-days = {-30, -10} -> prior_visits=2. One gap: (-30)->(-10)=20 days -> cadence_days=20.00
--   (percentile_cont(0.5) over a single value is that value). last_visit_at is the documented,
--   accepted consequence of the anchor rule: the day's FIRST qualifying sale (day -10, 09:00 SGT),
--   NOT the day's last sale (day -10, 15:00) that raw max(occurred_at) over ungrouped rows would
--   have reported. 2 < 4 -> insufficient_history, eligible=false.
-- ============================================================================================

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v711$
declare
  v_sa        uuid := '00000000-0000-4000-8000-0000000711a1';
  biz         uuid := '00000000-0000-4000-8000-0000000711b1';
  cl_refuter  uuid := '00000000-0000-4000-8000-0000000711c1';
  cl_control  uuid := '00000000-0000-4000-8000-0000000711c2';
  cl_lastday  uuid := '00000000-0000-4000-8000-0000000711c3';
  v_refresh   jsonb;
  v_rec       uuid;
  v_err       text;
  v_def       text;
  v_reg       jsonb;
  r           record;
  v_seen      int := 0;
  v_indep_r   numeric;
  v_indep_c   numeric;
begin
  ---------------------------------------------------------------------------
  -- Preconditions: independently recompute the two truth-table medians (pure arithmetic, no
  -- table reads) before trusting either the function or this fixture's own hand-arithmetic.
  ---------------------------------------------------------------------------
  select percentile_cont(0.5) within group (order by g) into v_indep_r
    from unnest(array[1, 15]::numeric[]) g;
  if v_indep_r <> 8.0 then
    insert into _fail values ('pre-arith',
      format('independent percentile_cont over {1,15} gave %s, expected 8.0 — the truth table''s '
             'own arithmetic is wrong, not the function', v_indep_r));
  end if;
  select percentile_cont(0.5) within group (order by g) into v_indep_c
    from unnest(array[10, 15]::numeric[]) g;
  if v_indep_c <> 12.5 then
    insert into _fail values ('pre-arith',
      format('independent percentile_cont over {10,15} gave %s, expected 12.5 — the truth '
             'table''s own arithmetic is wrong, not the function', v_indep_c));
  end if;

  ---------------------------------------------------------------------------
  -- Fixture setup: a super admin session (Google SSO claims — see AUTH CONTEXT above), one
  -- fresh 'other'-sector business, and three clients shaped per the truth table.
  ---------------------------------------------------------------------------
  insert into auth.users(
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000', v_sa, 'authenticated', 'authenticated',
    'v711-sa-' || v_sa || '@example.test', '', now(), now(), now()
  );
  insert into public.super_admins(user_id, email, note)
  values (v_sa, 'v711-sa-' || v_sa || '@example.test', 'v711 corpus fixture');

  insert into public.businesses(id, name, slug, currency, is_synthetic)
  values (biz, 'ZZ v711 bringback visit days', 'zz-v711-' || biz, 'SGD', true);

  update app.platform_feature_flags set enabled = true
   where feature_key = 'growth_closed_loop_v108';

  insert into public.clients (id, business_id, full_name) values
    (cl_refuter, biz, 'ZZ v711 refuter split-bill'),
    (cl_control, biz, 'ZZ v711 distinct-day control'),
    (cl_lastday, biz, 'ZZ v711 last-day collision');

  -- R: 3 same-day sales (day -40) + 1 next-day (-39) + 1 later (-24).
  insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, cl_refuter, 'service', 1000,
         (current_date - d.day_offset)::timestamp at time zone 'Asia/Singapore' + d.tod,
         (current_date - d.day_offset)::timestamp at time zone 'Asia/Singapore' + d.tod
    from (values (40, interval '9 hours'), (40, interval '13 hours'), (40, interval '18 hours'),
                 (39, interval '9 hours'), (24, interval '9 hours')) as d(day_offset, tod);

  -- C: 3 distinct-day sales, -50/-40/-25.
  insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, cl_control, 'service', 1000,
         (current_date - o)::timestamp at time zone 'Asia/Singapore' + interval '9 hours',
         (current_date - o)::timestamp at time zone 'Asia/Singapore' + interval '9 hours'
    from unnest(array[50, 40, 25]) as o;

  -- L: -30 (single sale), then a collision on the LAST day (-10: 09:00 and 15:00).
  insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, cl_lastday, 'service', 1000,
         (current_date - d.day_offset)::timestamp at time zone 'Asia/Singapore' + d.tod,
         (current_date - d.day_offset)::timestamp at time zone 'Asia/Singapore' + d.tod
    from (values (30, interval '9 hours'), (10, interval '9 hours'), (10, interval '15 hours'))
      as d(day_offset, tod);

  perform set_config('request.jwt.claim.sub', v_sa::text, true);
  perform set_config('request.jwt.claims', json_build_object(
      'sub', v_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method', 'oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  ---------------------------------------------------------------------------
  -- Preconditions: the impersonated session genuinely holds the access the function requires,
  -- before trusting anything the call below returns (fixture guide, "the rule that matters most").
  ---------------------------------------------------------------------------
  if not app.is_super_admin() then
    insert into _fail values ('pre-auth',
      'fixture session is not recognised as super admin (missing Google SSO claims?) — every '
      'assertion below proves nothing');
  end if;

  begin
    v_refresh := public.refresh_growth_recommendation_v108(biz, null);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('call', format('refresh_growth_recommendation_v108 raised %s', v_err));
  end;

  if v_refresh is null then
    insert into _fail values ('call-pre', 'refresh_growth_recommendation_v108 returned no result');
  else
    v_rec := (v_refresh->>'recommendation_id')::uuid;

    for r in
      select client_id, prior_visits, cadence_days, last_visit_at, exclusion_reason, eligible
        from public.growth_recommendation_members_v108
       where recommendation_id = v_rec
    loop
      v_seen := v_seen + 1;

      if r.client_id = cl_refuter then
        if r.prior_visits <> 3 then
          insert into _fail values ('R-prior_visits',
            format('got %s, expected 3 (three same-day sales collapse to one visit-day)', r.prior_visits));
        end if;
        if r.cadence_days <> 8.00 then
          insert into _fail values ('R-cadence_days',
            format('got %s, expected 8.00 (median of gaps {1,15})', r.cadence_days));
        end if;
        if r.last_visit_at <> (current_date - 24)::timestamp at time zone 'Asia/Singapore' + interval '9 hours' then
          insert into _fail values ('R-last_visit_at',
            format('got %s, expected day -24 09:00 SGT (no collision on the last day, so '
                   'unchanged from raw max(occurred_at))', r.last_visit_at));
        end if;
        if r.exclusion_reason <> 'insufficient_history' or r.eligible then
          insert into _fail values ('R-eligibility',
            format('exclusion_reason=%s eligible=%s, expected insufficient_history/false '
                   '(prior_visits 3 < minimum_prior_visits 4 for a fresh ''other''-sector business)',
                   r.exclusion_reason, r.eligible));
        end if;
        -- Mutation check: the OLD (buggy) raw-row count for this client is 5, not 3. A mutation
        -- that reverts to counting sale rows must be caught here, not just by a `<> 3` miss.
        if r.prior_visits = 5 then
          insert into _fail values ('R-mutation',
            'prior_visits=5 — the metrics CTE is still counting raw sale rows, not visit-days');
        end if;

      elsif r.client_id = cl_control then
        if r.prior_visits <> 3 then
          insert into _fail values ('C-prior_visits', format('got %s, expected 3', r.prior_visits));
        end if;
        if r.cadence_days <> 12.50 then
          insert into _fail values ('C-cadence_days',
            format('got %s, expected 12.50 (median of gaps {10,15}) — a client whose sales are '
                   'already on distinct days must be unaffected by the visit-day collapse',
                   r.cadence_days));
        end if;
        if r.last_visit_at <> (current_date - 25)::timestamp at time zone 'Asia/Singapore' + interval '9 hours' then
          insert into _fail values ('C-last_visit_at',
            format('got %s, expected day -25 09:00 SGT', r.last_visit_at));
        end if;
        if r.exclusion_reason <> 'insufficient_history' or r.eligible then
          insert into _fail values ('C-eligibility',
            format('exclusion_reason=%s eligible=%s, expected insufficient_history/false',
                   r.exclusion_reason, r.eligible));
        end if;

      elsif r.client_id = cl_lastday then
        if r.prior_visits <> 2 then
          insert into _fail values ('L-prior_visits', format('got %s, expected 2', r.prior_visits));
        end if;
        if r.cadence_days <> 20.00 then
          insert into _fail values ('L-cadence_days',
            format('got %s, expected 20.00 (single gap of 20 days)', r.cadence_days));
        end if;
        -- The anchor-rule proof: last_visit_at must be the LAST day's FIRST sale (09:00), not its
        -- later sale (15:00) that raw max(occurred_at) over ungrouped rows would report.
        if r.last_visit_at <> (current_date - 10)::timestamp at time zone 'Asia/Singapore' + interval '9 hours' then
          insert into _fail values ('L-last_visit_at-anchor',
            format('got %s, expected day -10 09:00 SGT (the day''s FIRST qualifying sale)',
                   r.last_visit_at));
        end if;
        if r.last_visit_at = (current_date - 10)::timestamp at time zone 'Asia/Singapore' + interval '15 hours' then
          insert into _fail values ('L-last_visit_at-mutation',
            'last_visit_at is the LAST-day''s LAST sale (15:00) — the anchor rule (first sale of '
            'the day) did not land, this is the pre-nestly_v711 raw max(occurred_at) answer');
        end if;
        if r.exclusion_reason <> 'insufficient_history' or r.eligible then
          insert into _fail values ('L-eligibility',
            format('exclusion_reason=%s eligible=%s, expected insufficient_history/false',
                   r.exclusion_reason, r.eligible));
        end if;
      else
        insert into _fail values ('unexpected-member', format('unexpected client_id %s', r.client_id));
      end if;
    end loop;

    if v_seen <> 3 then
      insert into _fail values ('member-count',
        format('growth_recommendation_members_v108 has %s rows for this recommendation, expected 3',
               v_seen));
    end if;
  end if;

  ---------------------------------------------------------------------------
  -- Structural proof: the live function body now calls the visit-day authority.
  ---------------------------------------------------------------------------
  select pg_get_functiondef(to_regprocedure('public.refresh_growth_recommendation_v108(uuid,uuid)'))
    into v_def;
  if v_def is null then
    insert into _fail values ('struct-pre', 'refresh_growth_recommendation_v108 not found');
  elsif position('app.ci_visit_day_v699' in v_def) = 0 then
    insert into _fail values ('struct',
      'refresh_growth_recommendation_v108 does not call app.ci_visit_day_v699 — the visit-day '
      'authority did not land');
  end if;

  ---------------------------------------------------------------------------
  -- Registry proof: app.ci_visit_registry_v699() names this reader and claims uses_authority.
  ---------------------------------------------------------------------------
  begin
    v_reg := app.ci_visit_registry_v699();
    if (v_reg #>> '{readers,refresh_growth_recommendation_v108,uses_authority}') is distinct from 'true' then
      insert into _fail values ('registry',
        format('registry entry for refresh_growth_recommendation_v108 is %s, expected uses_authority=true',
               v_reg #> '{readers,refresh_growth_recommendation_v108}'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('registry', format('ci_visit_registry_v699 raised %s', v_err));
  end;
end
$v711$;

select case when count(*) = 0
            then 'PASS — refresh_growth_recommendation_v108 counts distinct visit-days (check 4); '
                 'split-bill refuter, distinct-day control, and last-day anchor-rule proof all hold'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v711: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
