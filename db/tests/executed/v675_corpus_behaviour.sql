-- EXECUTED regression fixture for nestly_v675 -- daypart (honest denominators), service
-- intelligence, package intelligence.
--
-- Closes checklist items 35 (daypart naming/exposure), 36 (busiest vs most-valuable must be
-- distinguishable) and 60 (service + package intelligence). Three independently-scoped parts,
-- each its own business, sharing one platform (super admin) reading session. Above the v422
-- watermark: n/a in the baseline phase, gated on the migrated run.
--
-- PREDETERMINED TRUTH TABLES (asserted exactly, never with `> 0`). REVISED from the first draft:
-- the original truth table used an explicit floor of 2 (daypart/package), which is precisely the
-- floor a fixture would choose to make its OWN small seed data clear the bar -- rejected on
-- review. Every evidence check below now uses app.subgroup_evidence_v1's real default floor (5),
-- and the fixture seeds MORE data to get real evidence-ok verdicts instead of a smaller floor.
--
--   PART A -- daypart. 14-day window ending today, so every ISO weekday occurs exactly twice.
--     Monday:    3 sales @2000 on Monday-1, 3 sales @2000 on Monday-2
--                -> visits=6, revenue_cents=12000, revenue_per_visit_cents=2000, evidence 'ok'
--                   (n=6 >= floor 5), weekday_occurrences=2, visits_per_occurrence=6/2.
--     Saturday:  3 sales @9000 on Saturday-1, 2 sales @9000 on Saturday-2
--                -> visits=5, revenue_cents=45000, revenue_per_visit_cents=9000, evidence 'ok'
--                   (n=5 >= floor 5, exactly at the floor).
--     Wednesday: 1 sale @50000 on each of the 2 Wednesdays (BELOW-floor cell, kept deliberately)
--                -> visits=2, revenue_cents=100000 -- counts stay visible -- but evidence
--                   'insufficient' (n=2 < floor 5), so revenue_per_visit_cents (which would be a
--                   table-topping 50000, five times Saturday's) and visits_per_occurrence.pct
--                   MUST be null.
--     busiest_weekday = Monday (6 visits, a raw count, evidence-independent).
--     most_valuable_weekday = Saturday (9000/visit) -- THE POINT OF THIS REVISION: Wednesday's
--     raw per-visit value (50000) is more than five times Saturday's, but Wednesday is NOT
--     evidence-ok, so it is INELIGIBLE for the most_valuable_weekday verdict no matter how large
--     its number looks. The fixture asserts this exclusion explicitly (DP-V2), not just that
--     Saturday happens to win. A synthetic client's 999999-cent Monday sale, and a 7000/-7000
--     original+reversal pair also dated Monday, must both net to zero.
--
--   PART B -- service intelligence (unchanged from the first draft -- it already used the
--     default floor of 5, never overridden). Service A: 6 buyers (a1..a6), 3 repeat (a1,a2,a3
--     buy twice), 4 gateway (a1,a2,a4,a5 -- service A really was their first-ever purchase; a3
--     and a6 each have an earlier, unrelated retail sale, so it wasn't). -> buyers=6, orders=9,
--     revenue_cents=36000, repeat_buyers=3 (rate 50.0%), gateway_count=4, evidence 'ok' (n=6 >=
--     floor 5). Service B: 2 buyers, single purchase each -> buyers=2, revenue_cents=6000,
--     evidence 'insufficient' (n=2 < floor 5) -- repeat_rate.pct and median_days_to_next_purchase
--     must be null while the raw counts (buyers/orders/revenue/repeat_buyers) stay visible. A
--     synthetic client's 999999-cent service-A purchase must not move service A's numbers.
--
--   PART C -- package intelligence, via the REAL sell_package_v102 / use_package_session_v102
--     RPCs (some session-use rows are necessarily hand-seeded with backdated timestamps -- now()
--     is fixed for the whole transaction, so the RPC itself cannot produce two differently-timed
--     historical rows in one transaction; see the migration header, judgement call 2).
--     Plan A: 2 sold in window (holder1, holder2) -> BELOW the floor of 5, evidence
--     'insufficient'. sold_count=2, sessions_included=10, sessions_used=3 (holder1 uses 3 of 5,
--     gaps 7 and 7 days; holder2 uses 0) all stay visible as raw counts, but utilisation.pct and
--     median_days_between_sessions must both be null. Holder1 also holds an OLDER, already
--     used-up plan-A package from before the window -> repurchase_count=1 (a raw count, stays
--     visible). Holder1 spends an extra 3000 cents outside the package, inside the window ->
--     outside_spend_cents=3000 (also stays visible).
--     Plan B: 1 holder, seeded already expired with 3 of 5 sessions unused -- evidence
--     'insufficient' (n=1 < floor 5) -- utilisation/median null, expired_or_lapsed_with_unused=1
--     stays visible.
--     Plan C (NEW -- the evidence-ok case the revision asked for): 5 holders sold in window.
--     Holder c1 uses 3 of 5 sessions (gaps 7 and 7 days, same technique as plan A's holder1);
--     c2..c5 use 0. -> sold_count=5 (AT the floor), evidence 'ok', sessions_included=25,
--     sessions_used=3, utilisation = 3/25 = 12.0% (a REAL computed rate), median_days_between_
--     sessions = 7.0 days (a REAL computed median, from >=3 pooled session-use events -- the
--     "enough events" half of judgement call 2's assertion; plan A/B above are the "too few"
--     half, both null).
--     A branch filter must be REFUSED (22023): client_packages carries no branch column at all.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

-- One platform session (Google-SSO-shaped super admin claims, per the fixture guide) shared by
-- all three parts below -- entitlement for a per-business drill-down doesn't depend on the
-- target business being "operational" (app.v176_can_read_firm_report short-circuits true for a
-- super admin), so this one row is all the reading side needs.
insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-000000675eee', 'zz-v675-sa@example.test')
  on conflict (id) do nothing;
insert into public.super_admins (user_id, email) values
  ('00000000-0000-4000-8000-000000675eee', 'zz-v675-sa@example.test')
  on conflict do nothing;

-- Scratch helper for part B: one (sale, sale_item) pair for a service purchase. pg_temp so it
-- never touches a shared schema, and CREATE FUNCTION is transactional DDL anyway -- this whole
-- file rolls back at the end regardless.
create function pg_temp.zz_v675_svc_sale(
  p_biz uuid, p_br uuid, p_client uuid, p_service uuid, p_amount integer, p_at timestamptz
) returns void language plpgsql as $$
declare v_sale uuid := gen_random_uuid();
begin
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at)
  values (v_sale, p_biz, p_br, p_client, 'service', p_amount, p_at);
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  values (p_biz, v_sale, 'service', p_service, 1, p_amount, p_amount);
end;
$$;

-- =================================================================================================
-- PART A -- get_ci_daypart_v1
-- =================================================================================================
do $v675a$
declare
  biz uuid := gen_random_uuid();
  br uuid := gen_random_uuid();
  u_sa uuid := '00000000-0000-4000-8000-000000675eee';
  cl_reg uuid := gen_random_uuid();
  cl_synth uuid := gen_random_uuid();
  d_to date := current_date;
  d_from date := current_date - 13;
  v_mondays date[];
  v_saturdays date[];
  v_wednesdays date[];
  v_orig uuid := gen_random_uuid();
  v_rev uuid := gen_random_uuid();
  g jsonb;
  v_mon jsonb;
  v_sat jsonb;
  v_wed jsonb;
  v_busiest jsonb;
  v_valuable jsonb;
  v_total_visits int;
  v_total_rev bigint;
  v_err text;
begin
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v675 daypart firm', 'zz-v675-daypart', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v675 daypart branch', true, true);
  insert into public.clients (id, business_id, full_name, is_synthetic) values
    (cl_reg, biz, 'ZZ v675 regular customer', false),
    (cl_synth, biz, 'ZZ v675 synthetic customer', true);

  select array_agg(gs::date order by gs) into v_mondays
    from generate_series(d_from, d_to, interval '1 day') gs
   where extract(isodow from gs) = 1;
  select array_agg(gs::date order by gs) into v_saturdays
    from generate_series(d_from, d_to, interval '1 day') gs
   where extract(isodow from gs) = 6;
  select array_agg(gs::date order by gs) into v_wednesdays
    from generate_series(d_from, d_to, interval '1 day') gs
   where extract(isodow from gs) = 3;

  if coalesce(array_length(v_mondays,1),0) <> 2 or coalesce(array_length(v_saturdays,1),0) <> 2
     or coalesce(array_length(v_wednesdays,1),0) <> 2 then
    insert into _fail values ('DP0',
      format('fixture window %s..%s does not contain exactly 2 Mondays, 2 Saturdays and 2 Wednesdays',
             d_from, d_to));
    return;
  end if;

  -- Monday: 6 visits (evidence-ok, n=6 >= floor 5).
  insert into public.sales (business_id, branch_id, client_id, kind, amount_cents, occurred_at)
  select biz, br, cl_reg, 'service', 2000,
         (v_mondays[1]::timestamp + time '10:00') at time zone 'Asia/Singapore'
    from generate_series(1,3);
  insert into public.sales (business_id, branch_id, client_id, kind, amount_cents, occurred_at)
  select biz, br, cl_reg, 'service', 2000,
         (v_mondays[2]::timestamp + time '11:00') at time zone 'Asia/Singapore'
    from generate_series(1,3);

  -- Saturday: 5 visits (evidence-ok, n=5 >= floor 5, exactly at the floor).
  insert into public.sales (business_id, branch_id, client_id, kind, amount_cents, occurred_at)
  select biz, br, cl_reg, 'service', 9000,
         (v_saturdays[1]::timestamp + time '14:00') at time zone 'Asia/Singapore'
    from generate_series(1,3);
  insert into public.sales (business_id, branch_id, client_id, kind, amount_cents, occurred_at)
  select biz, br, cl_reg, 'service', 9000,
         (v_saturdays[2]::timestamp + time '14:00') at time zone 'Asia/Singapore'
    from generate_series(1,2);

  -- Wednesday: only 2 visits (BELOW floor 5), deliberately at a huge per-visit price (50000) that
  -- would top the whole table if the floor were not enforced -- this is what DP-V2 below proves
  -- does NOT happen.
  insert into public.sales (business_id, branch_id, client_id, kind, amount_cents, occurred_at)
  values
    (biz, br, cl_reg, 'service', 50000,
       (v_wednesdays[1]::timestamp + time '15:00') at time zone 'Asia/Singapore'),
    (biz, br, cl_reg, 'service', 50000,
       (v_wednesdays[2]::timestamp + time '15:00') at time zone 'Asia/Singapore');

  -- EXCLUSION 1: a synthetic client's sale, same Monday as the real traffic.
  insert into public.sales (business_id, branch_id, client_id, kind, amount_cents, occurred_at)
  values (biz, br, cl_synth, 'service', 999999,
          (v_mondays[1]::timestamp + time '12:00') at time zone 'Asia/Singapore');

  -- EXCLUSION 2: an original sale plus its reversal, both dated Monday-1. Both must be entirely
  -- invisible to the reader (not just netted to a signed sum) -- app.analytics_sale_class_v1
  -- excludes the original because a reversal exists against it, and excludes the reversal
  -- because it is itself reversal_of-not-null.
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at)
  values (v_orig, biz, br, cl_reg, 'service', 7000,
          (v_mondays[1]::timestamp + time '16:00') at time zone 'Asia/Singapore');
  perform set_config('app.sale_reversal_insert_id', v_rev::text, true);
  perform set_config('app.sale_reversal_original_id', v_orig::text, true);
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at,
                             reversal_of, reversal_reason, reversal_actor, reversal_idempotency_key)
  values (v_rev, biz, br, cl_reg, 'service', -7000,
          (v_mondays[1]::timestamp + time '16:05') at time zone 'Asia/Singapore',
          v_orig, 'v675 fixture: reversal must net out of daypart revenue', u_sa, 'v675-daypart-rev-001');
  perform set_config('app.sale_reversal_insert_id', '', true);
  perform set_config('app.sale_reversal_original_id', '', true);

  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  begin
    g := public.get_ci_daypart_v1(biz, d_from, d_to);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('DP1', format('get_ci_daypart_v1 raised %s: %s', v_err, sqlerrm));
  end;

  if g is null then
    insert into _fail values ('DP1', 'get_ci_daypart_v1 returned no payload');
  else
    if g->>'time_basis' <> 'sale_occurred_at' then
      insert into _fail values ('DP2', format('time_basis was %s, expected sale_occurred_at', g->>'time_basis'));
    end if;
    if coalesce(g->>'basis_note','') !~* 'arrival' then
      insert into _fail values ('DP2', 'basis_note does not plainly say arrival time is not captured');
    end if;

    select w into v_mon from jsonb_array_elements(g->'weekdays') w where (w->>'dow')::int = 1;
    select w into v_sat from jsonb_array_elements(g->'weekdays') w where (w->>'dow')::int = 6;
    select w into v_wed from jsonb_array_elements(g->'weekdays') w where (w->>'dow')::int = 3;

    if v_mon is null then
      insert into _fail values ('DP-MON0', 'Monday bucket missing');
    else
      if coalesce((v_mon->>'visits')::int,-1) <> 6 then
        insert into _fail values ('DP-MON1', format('Monday visits were %s, expected 6', v_mon->>'visits'));
      end if;
      if coalesce((v_mon->>'revenue_cents')::bigint,-1) <> 12000 then
        insert into _fail values ('DP-MON2', format('Monday revenue_cents was %s, expected 12000', v_mon->>'revenue_cents'));
      end if;
      if coalesce((v_mon->>'revenue_per_visit_cents')::numeric,-1) <> 2000 then
        insert into _fail values ('DP-MON3', format('Monday revenue_per_visit_cents was %s, expected 2000', v_mon->>'revenue_per_visit_cents'));
      end if;
      if coalesce((v_mon->>'weekday_occurrences')::int,-1) <> 2 then
        insert into _fail values ('DP-MON4', format('Monday weekday_occurrences was %s, expected 2', v_mon->>'weekday_occurrences'));
      end if;
      if coalesce((v_mon->'visits_per_occurrence'->>'numerator')::int,-1) <> 6
         or coalesce((v_mon->'visits_per_occurrence'->>'denominator')::int,-1) <> 2
         or coalesce((v_mon->'visits_per_occurrence'->>'pct')::numeric,-1) <> 300.0 then
        insert into _fail values ('DP-MON5',
          format('Monday visits_per_occurrence was %s, expected 6/2 (pct 300.0)', v_mon->'visits_per_occurrence'));
      end if;
      if coalesce(v_mon->'evidence'->>'status','') <> 'ok' then
        insert into _fail values ('DP-MON6', 'Monday evidence should be ok at n=6 (floor=5)');
      end if;
    end if;

    if v_sat is null then
      insert into _fail values ('DP-SAT0', 'Saturday bucket missing');
    else
      if coalesce((v_sat->>'visits')::int,-1) <> 5 then
        insert into _fail values ('DP-SAT1', format('Saturday visits were %s, expected 5', v_sat->>'visits'));
      end if;
      if coalesce((v_sat->>'revenue_cents')::bigint,-1) <> 45000 then
        insert into _fail values ('DP-SAT2', format('Saturday revenue_cents was %s, expected 45000', v_sat->>'revenue_cents'));
      end if;
      if coalesce((v_sat->>'revenue_per_visit_cents')::numeric,-1) <> 9000 then
        insert into _fail values ('DP-SAT3', format('Saturday revenue_per_visit_cents was %s, expected 9000', v_sat->>'revenue_per_visit_cents'));
      end if;
      if coalesce(v_sat->'evidence'->>'status','') <> 'ok' then
        insert into _fail values ('DP-SAT4', 'Saturday evidence should be ok at n=5 (exactly the floor)');
      end if;
    end if;

    -- THE BELOW-FLOOR CELL. Wednesday has real, large revenue (100000 cents over 2 visits, i.e.
    -- a raw 50000/visit -- more than five times Saturday's 9000/visit) but only 2 visits, below
    -- the floor of 5. Its counts must stay visible; its rate-like fields must not.
    if v_wed is null then
      insert into _fail values ('DP-WED0', 'Wednesday bucket missing');
    else
      if coalesce((v_wed->>'visits')::int,-1) <> 2 then
        insert into _fail values ('DP-WED1', format('Wednesday visits were %s, expected 2 (counts are never suppressed)', v_wed->>'visits'));
      end if;
      if coalesce((v_wed->>'revenue_cents')::bigint,-1) <> 100000 then
        insert into _fail values ('DP-WED2', format('Wednesday revenue_cents was %s, expected 100000 (counts are never suppressed)', v_wed->>'revenue_cents'));
      end if;
      if v_wed->>'revenue_per_visit_cents' is not null then
        insert into _fail values ('DP-WED3',
          format('Wednesday revenue_per_visit_cents was %s, expected null below the evidence floor (n=2 < 5)',
                 v_wed->>'revenue_per_visit_cents'));
      end if;
      if v_wed->'visits_per_occurrence'->>'pct' is not null then
        insert into _fail values ('DP-WED4',
          'Wednesday visits_per_occurrence.pct should be null below the evidence floor');
      end if;
      if coalesce(v_wed->'evidence'->>'status','') <> 'insufficient' then
        insert into _fail values ('DP-WED5', 'Wednesday evidence should be insufficient at n=2 (floor=5)');
      end if;
    end if;

    v_busiest := g->'busiest_weekday';
    v_valuable := g->'most_valuable_weekday';
    if coalesce((v_busiest->>'dow')::int,-1) <> 1 or coalesce((v_busiest->>'visits')::int,-1) <> 6 then
      insert into _fail values ('DP-B1', format('busiest_weekday was %s, expected Monday/6', v_busiest));
    end if;
    if coalesce((v_valuable->>'dow')::int,-1) <> 6
       or coalesce((v_valuable->>'revenue_per_visit_cents')::numeric,-1) <> 9000 then
      insert into _fail values ('DP-V1', format('most_valuable_weekday was %s, expected Saturday/9000', v_valuable));
    end if;
    -- THE POINT OF THIS REVISION, asserted explicitly rather than left implicit in DP-V1 above:
    -- Wednesday's raw per-visit value (50000) is the highest in the whole table -- a floor-less
    -- reader would crown IT most valuable. It must be excluded from the verdict purely because
    -- its evidence is insufficient, not because its number is small.
    if (v_valuable->>'dow')::int = 3 then
      insert into _fail values ('DP-V2',
        'most_valuable_weekday picked Wednesday (raw 50000/visit, n=2) over Saturday (9000/visit, '
        'n=5) -- a below-floor cell must never win the verdict no matter how large its raw '
        'per-visit value is; this is the failure mode the floor-5 revision exists to close');
    end if;
    if (v_busiest->>'dow') = (v_valuable->>'dow') then
      insert into _fail values ('DP-B-V',
        'busiest_weekday and most_valuable_weekday must be distinguishable (check 36) but matched');
    end if;

    select coalesce(sum((w->>'visits')::int),0), coalesce(sum((w->>'revenue_cents')::bigint),0)
      into v_total_visits, v_total_rev
      from jsonb_array_elements(g->'weekdays') w;
    if v_total_visits <> 13 then
      insert into _fail values ('DP-TOT1',
        format('total visits across all weekdays were %s, expected 13 (6 Monday + 5 Saturday + 2 '
               'Wednesday) -- synthetic or reversed rows may have leaked into another bucket', v_total_visits));
    end if;
    if v_total_rev <> 157000 then
      insert into _fail values ('DP-TOT2', format('total revenue across all weekdays was %s, expected 157000', v_total_rev));
    end if;
  end if;

  perform set_config('request.jwt.claims', null, true);
end
$v675a$;

-- =================================================================================================
-- PART B -- get_ci_service_intelligence_v1
-- =================================================================================================
do $v675b$
declare
  biz uuid := gen_random_uuid();
  br uuid := gen_random_uuid();
  u_sa uuid := '00000000-0000-4000-8000-000000675eee';
  svc_a uuid := gen_random_uuid();
  svc_b uuid := gen_random_uuid();
  cl_a1 uuid := gen_random_uuid();
  cl_a2 uuid := gen_random_uuid();
  cl_a3 uuid := gen_random_uuid();
  cl_a4 uuid := gen_random_uuid();
  cl_a5 uuid := gen_random_uuid();
  cl_a6 uuid := gen_random_uuid();
  cl_b1 uuid := gen_random_uuid();
  cl_b2 uuid := gen_random_uuid();
  cl_synth uuid := gen_random_uuid();
  d_to date := current_date;
  d_from date := current_date - 29;
  v_day0 date := current_date - 24;
  v_day1 date := current_date - 19;
  v_blocker date := current_date - 25;
  g jsonb;
  svc_a_row jsonb;
  svc_b_row jsonb;
  v_err text;
begin
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v675 service firm', 'zz-v675-service', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v675 service branch', true, true);
  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_a, biz, 'ZZ v675 service A', 4000, 30),
    (svc_b, biz, 'ZZ v675 service B', 3000, 30);
  insert into public.clients (id, business_id, full_name, is_synthetic) values
    (cl_a1, biz, 'ZZ v675 A buyer 1', false),
    (cl_a2, biz, 'ZZ v675 A buyer 2', false),
    (cl_a3, biz, 'ZZ v675 A buyer 3', false),
    (cl_a4, biz, 'ZZ v675 A buyer 4', false),
    (cl_a5, biz, 'ZZ v675 A buyer 5', false),
    (cl_a6, biz, 'ZZ v675 A buyer 6', false),
    (cl_b1, biz, 'ZZ v675 B buyer 1', false),
    (cl_b2, biz, 'ZZ v675 B buyer 2', false),
    (cl_synth, biz, 'ZZ v675 synthetic buyer', true);

  -- a3 and a6's TRUE first-ever purchase: an unrelated retail sale before their service-A
  -- purchase, so service A is not their gateway even though a3 goes on to buy it twice (repeat
  -- and gateway are independent dimensions).
  insert into public.sales (business_id, branch_id, client_id, kind, amount_cents, occurred_at)
  values
    (biz, br, cl_a3, 'retail', 1000, (v_blocker::timestamp + time '09:00') at time zone 'Asia/Singapore'),
    (biz, br, cl_a6, 'retail', 1000, (v_blocker::timestamp + time '09:00') at time zone 'Asia/Singapore');

  -- Service A: 6 buyers. a1/a2/a3 repeat (2 purchases each); a1/a2/a4/a5 are gateway.
  perform pg_temp.zz_v675_svc_sale(biz, br, cl_a1, svc_a, 4000, (v_day0::timestamp + time '10:00') at time zone 'Asia/Singapore');
  perform pg_temp.zz_v675_svc_sale(biz, br, cl_a1, svc_a, 4000, (v_day1::timestamp + time '10:00') at time zone 'Asia/Singapore');
  perform pg_temp.zz_v675_svc_sale(biz, br, cl_a2, svc_a, 4000, (v_day0::timestamp + time '10:00') at time zone 'Asia/Singapore');
  perform pg_temp.zz_v675_svc_sale(biz, br, cl_a2, svc_a, 4000, (v_day1::timestamp + time '10:00') at time zone 'Asia/Singapore');
  perform pg_temp.zz_v675_svc_sale(biz, br, cl_a3, svc_a, 4000, (v_day0::timestamp + time '10:00') at time zone 'Asia/Singapore');
  perform pg_temp.zz_v675_svc_sale(biz, br, cl_a3, svc_a, 4000, (v_day1::timestamp + time '10:00') at time zone 'Asia/Singapore');
  perform pg_temp.zz_v675_svc_sale(biz, br, cl_a4, svc_a, 4000, (v_day0::timestamp + time '10:00') at time zone 'Asia/Singapore');
  perform pg_temp.zz_v675_svc_sale(biz, br, cl_a5, svc_a, 4000, (v_day0::timestamp + time '10:00') at time zone 'Asia/Singapore');
  perform pg_temp.zz_v675_svc_sale(biz, br, cl_a6, svc_a, 4000, (v_day0::timestamp + time '10:00') at time zone 'Asia/Singapore');

  -- Service B: 2 buyers, single purchase each -- below the k=5 identity floor.
  perform pg_temp.zz_v675_svc_sale(biz, br, cl_b1, svc_b, 3000, (v_day0::timestamp + time '10:00') at time zone 'Asia/Singapore');
  perform pg_temp.zz_v675_svc_sale(biz, br, cl_b2, svc_b, 3000, (v_day0::timestamp + time '10:00') at time zone 'Asia/Singapore');

  -- EXCLUSION: a synthetic client's service-A purchase must not move service A's numbers.
  perform pg_temp.zz_v675_svc_sale(biz, br, cl_synth, svc_a, 999999, (v_day0::timestamp + time '10:00') at time zone 'Asia/Singapore');

  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  begin
    g := public.get_ci_service_intelligence_v1(biz, d_from, d_to);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('SVC1', format('get_ci_service_intelligence_v1 raised %s: %s', v_err, sqlerrm));
  end;

  if g is null then
    insert into _fail values ('SVC1', 'get_ci_service_intelligence_v1 returned no payload');
  else
    select s into svc_a_row from jsonb_array_elements(g->'services') s where (s->>'service_id')::uuid = svc_a;
    select s into svc_b_row from jsonb_array_elements(g->'services') s where (s->>'service_id')::uuid = svc_b;

    if svc_a_row is null then
      insert into _fail values ('SVC-A0', 'service A missing from services array');
    else
      if coalesce((svc_a_row->>'buyers')::int,-1) <> 6 then
        insert into _fail values ('SVC-A1', format('service A buyers was %s, expected 6', svc_a_row->>'buyers'));
      end if;
      if coalesce((svc_a_row->>'orders')::int,-1) <> 9 then
        insert into _fail values ('SVC-A2', format('service A orders was %s, expected 9', svc_a_row->>'orders'));
      end if;
      if coalesce((svc_a_row->>'revenue_cents')::bigint,-1) <> 36000 then
        insert into _fail values ('SVC-A3', format('service A revenue_cents was %s, expected 36000', svc_a_row->>'revenue_cents'));
      end if;
      if coalesce((svc_a_row->>'repeat_buyers')::int,-1) <> 3 then
        insert into _fail values ('SVC-A4', format('service A repeat_buyers was %s, expected 3', svc_a_row->>'repeat_buyers'));
      end if;
      if coalesce((svc_a_row->'repeat_rate'->>'pct')::numeric,-1) <> 50.0 then
        insert into _fail values ('SVC-A5', format('service A repeat_rate pct was %s, expected 50.0', svc_a_row->'repeat_rate'->>'pct'));
      end if;
      if coalesce((svc_a_row->>'gateway_count')::int,-1) <> 4 then
        insert into _fail values ('SVC-A6', format('service A gateway_count was %s, expected 4', svc_a_row->>'gateway_count'));
      end if;
      if coalesce(svc_a_row->'evidence'->>'status','') <> 'ok' then
        insert into _fail values ('SVC-A7', 'service A evidence should be ok at n=6 (floor=5)');
      end if;
    end if;

    if svc_b_row is null then
      insert into _fail values ('SVC-B0', 'service B missing from services array');
    else
      if coalesce((svc_b_row->>'buyers')::int,-1) <> 2 then
        insert into _fail values ('SVC-B1', format('service B buyers was %s, expected 2', svc_b_row->>'buyers'));
      end if;
      if coalesce((svc_b_row->>'orders')::int,-1) <> 2 then
        insert into _fail values ('SVC-B2', format('service B orders was %s, expected 2', svc_b_row->>'orders'));
      end if;
      if coalesce((svc_b_row->>'revenue_cents')::bigint,-1) <> 6000 then
        insert into _fail values ('SVC-B3', format('service B revenue_cents was %s, expected 6000', svc_b_row->>'revenue_cents'));
      end if;
      if coalesce(svc_b_row->'evidence'->>'status','') <> 'insufficient' then
        insert into _fail values ('SVC-B4', 'service B evidence should be insufficient at n=2 (floor=5)');
      end if;
      if svc_b_row->'repeat_rate'->>'pct' is not null then
        insert into _fail values ('SVC-B5', 'service B repeat_rate.pct should be suppressed to null below the floor');
      end if;
      if svc_b_row->>'median_days_to_next_purchase' is not null then
        insert into _fail values ('SVC-B6', 'service B median_days_to_next_purchase should be null below the floor');
      end if;
    end if;

    if coalesce((g->>'truncated')::boolean, true) is distinct from false then
      insert into _fail values ('SVC-T', 'truncated should be false with only 2 services total');
    end if;
  end if;

  perform set_config('request.jwt.claims', null, true);
end
$v675b$;

-- =================================================================================================
-- PART C -- get_ci_package_intelligence_v1
-- =================================================================================================
do $v675c$
declare
  biz uuid := gen_random_uuid();
  br uuid := gen_random_uuid();
  u_owner uuid := gen_random_uuid();
  u_sa uuid := '00000000-0000-4000-8000-000000675eee';
  cl_h1 uuid := gen_random_uuid();
  cl_h2 uuid := gen_random_uuid();
  cl_h3 uuid := gen_random_uuid();
  -- plan C's 5 holders -- the evidence-ok case the revision asked for (sold_count must clear the
  -- real floor of 5, not a fixture-friendly floor of 2).
  cl_c1 uuid := gen_random_uuid();
  cl_c2 uuid := gen_random_uuid();
  cl_c3 uuid := gen_random_uuid();
  cl_c4 uuid := gen_random_uuid();
  cl_c5 uuid := gen_random_uuid();
  plan_a uuid := gen_random_uuid();
  plan_b uuid := gen_random_uuid();
  plan_c uuid := gen_random_uuid();
  -- SGT "today", not the session's own current_date: the real RPCs below stamp purchased_at/
  -- occurred_at from raw now(), and the reader buckets by (occurred_at at time zone
  -- 'Asia/Singapore')::date -- if the session's default timezone is UTC and the suite happens to
  -- run late enough in the UTC day, SGT "today" is already one calendar day ahead of the
  -- session's current_date, and every window-purchased row would silently fall one day outside
  -- [d_from,d_to]. Anchoring the window itself to SGT closes that gap.
  d_to date := (now() at time zone 'Asia/Singapore')::date;
  d_from date := d_to - 29;
  v_t0 timestamptz := now();
  v_sell1 jsonb;
  v_sell2 jsonb;
  v_sellc1 jsonb;
  v_sellc2 jsonb;
  v_sellc3 jsonb;
  v_sellc4 jsonb;
  v_sellc5 jsonb;
  v_cp1 uuid;
  v_cp2 uuid;
  v_cpc1 uuid;
  v_use jsonb;
  v_usec jsonb;
  v_old_cp uuid := gen_random_uuid();
  v_use2_id uuid := gen_random_uuid();
  v_use2_sale uuid := gen_random_uuid();
  v_use3_id uuid := gen_random_uuid();
  v_use3_sale uuid := gen_random_uuid();
  v_usec2_id uuid := gen_random_uuid();
  v_usec2_sale uuid := gen_random_uuid();
  v_usec3_id uuid := gen_random_uuid();
  v_usec3_sale uuid := gen_random_uuid();
  g jsonb;
  pa jsonb;
  pb jsonb;
  pc jsonb;
  v_payload jsonb;
  v_hash text;
  v_err text;
begin
  insert into auth.users (id, email) values (u_owner, 'zz-v675-owner@example.test')
    on conflict (id) do nothing;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v675 package firm', 'zz-v675-pkg',
     array['dashboard','clients','sales','reports','till','packages']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v675 package branch', true, true);
  insert into public.staff (business_id, user_id, role, full_name, active, access_state) values
    (biz, u_owner, 'owner', 'ZZ v675 package owner', true, 'approved');

  -- Operational-workspace recipe (fixture guide): the real sell/use RPCs gate on
  -- app.business_workspace_open_v94 (via has_perm / can_module_write / can_see_branch), which
  -- resolves through all three of these rows.
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v675 fixture')
    on conflict (business_id) do update set approval_status='approved', decided_at=now();
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  insert into public.clients (id, business_id, full_name) values
    (cl_h1, biz, 'ZZ v675 holder 1'),
    (cl_h2, biz, 'ZZ v675 holder 2'),
    (cl_h3, biz, 'ZZ v675 holder 3'),
    (cl_c1, biz, 'ZZ v675 plan C holder 1'),
    (cl_c2, biz, 'ZZ v675 plan C holder 2'),
    (cl_c3, biz, 'ZZ v675 plan C holder 3'),
    (cl_c4, biz, 'ZZ v675 plan C holder 4'),
    (cl_c5, biz, 'ZZ v675 plan C holder 5');

  insert into public.package_plans (id, business_id, name, price_cents, sessions, service_id, active)
  values (plan_a, biz, 'ZZ v675 plan A', 10000, 5, null, true);
  insert into public.package_plans
    (id, business_id, name, price_cents, sessions, service_id, active, expiry_days)
  values (plan_b, biz, 'ZZ v675 plan B (expiry case)', 5000, 5, null, true, 1);
  insert into public.package_plans (id, business_id, name, price_cents, sessions, service_id, active)
  values (plan_c, biz, 'ZZ v675 plan C (evidence-ok)', 10000, 5, null, true);

  -- Holder1's OLDER, already-exhausted plan-A package, purchased well before the window: this is
  -- what makes holder1's window purchase below a REPURCHASE.
  insert into public.client_packages
    (id, business_id, client_id, plan_id, remaining, status, purchased_at,
     plan_name_snapshot, plan_version_snapshot, sessions_snapshot, price_cents_snapshot)
  values
    (v_old_cp, biz, cl_h1, plan_a, 0, 'used_up',
     (d_from - 20)::timestamp at time zone 'Asia/Singapore', 'ZZ v675 plan A', 1, 5, 10000);

  -- Plan B's already-expired-with-unused-sessions holder. expires_at must be in the past, which
  -- purchased_at + expiry_days (both effectively "now" through the real RPC, in one transaction)
  -- cannot produce, so this one row is seeded directly rather than sold.
  insert into public.client_packages
    (id, business_id, client_id, plan_id, remaining, status, purchased_at,
     plan_name_snapshot, plan_version_snapshot, sessions_snapshot, price_cents_snapshot,
     expiry_days_snapshot, expires_at)
  values
    (gen_random_uuid(), biz, cl_h3, plan_b, 3, 'active',
     (d_from + 2)::timestamp at time zone 'Asia/Singapore',
     'ZZ v675 plan B (expiry case)', 1, 5, 5000, 1,
     (d_from + 3)::timestamp at time zone 'Asia/Singapore');

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner, 'role','authenticated')::text, true);

  if not app.has_perm(biz, 'create_sales') then
    insert into _fail values ('PKG0-pre',
      'fixture owner lacks create_sales; the package RPCs would refuse for the wrong reason');
  end if;

  begin
    v_sell1 := public.sell_package_v102(biz, cl_h1, plan_a, br, gen_random_uuid());
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('PKG1', format('sell_package_v102 (holder1) raised %s: %s', v_err, sqlerrm));
  end;
  begin
    v_sell2 := public.sell_package_v102(biz, cl_h2, plan_a, br, gen_random_uuid());
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('PKG1', format('sell_package_v102 (holder2) raised %s: %s', v_err, sqlerrm));
  end;

  if v_sell1 is null or v_sell2 is null then
    insert into _fail values ('PKG1', 'package sale(s) returned no result; cannot continue part C');
  else
    v_cp1 := (v_sell1->>'client_package_id')::uuid;
    v_cp2 := (v_sell2->>'client_package_id')::uuid;

    -- Two of holder1's three session-uses are hand-seeded, backdated 14 and 7 days before "now"
    -- (now() is fixed for the whole transaction, so the real RPC cannot itself produce two
    -- differently-timed historical rows here). The THIRD, most recent use goes through the real
    -- RPC untouched, so the live path is still proven end to end.
    insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at, note, branch_id)
    values (v_use2_sale, biz, cl_h1, 'service', 0, v_t0 - interval '14 days',
            'package session used: ZZ v675 plan A', br);
    v_payload := jsonb_build_object('branch_id', br, 'business_id', biz, 'client_package_id', v_cp1);
    v_hash := md5(v_payload::text);
    insert into public.package_session_consumptions
      (id, business_id, client_package_id, client_id, sale_id, actor, idempotency_key,
       request_payload, request_hash, remaining_before, remaining_after, created_at, result)
    values
      (v_use2_id, biz, v_cp1, cl_h1, v_use2_sale, u_owner, 'v675-manual-session-002',
       v_payload, v_hash, 5, 4, v_t0 - interval '14 days',
       jsonb_build_object('status','completed','replayed',false));
    update public.client_packages set remaining = 4, status = 'active' where id = v_cp1;

    insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at, note, branch_id)
    values (v_use3_sale, biz, cl_h1, 'service', 0, v_t0 - interval '7 days',
            'package session used: ZZ v675 plan A', br);
    v_payload := jsonb_build_object('branch_id', br, 'business_id', biz, 'client_package_id', v_cp1);
    v_hash := md5(v_payload::text);
    insert into public.package_session_consumptions
      (id, business_id, client_package_id, client_id, sale_id, actor, idempotency_key,
       request_payload, request_hash, remaining_before, remaining_after, created_at, result)
    values
      (v_use3_id, biz, v_cp1, cl_h1, v_use3_sale, u_owner, 'v675-manual-session-003',
       v_payload, v_hash, 4, 3, v_t0 - interval '7 days',
       jsonb_build_object('status','completed','replayed',false));
    update public.client_packages set remaining = 3, status = 'active' where id = v_cp1;

    begin
      v_use := public.use_package_session_v102(biz, v_cp1, br, 'v675-session-001');
    exception when others then
      get stacked diagnostics v_err = returned_sqlstate;
      insert into _fail values ('PKG2', format('use_package_session_v102 raised %s: %s', v_err, sqlerrm));
    end;

    if v_use is not null and coalesce((v_use->>'remaining_after')::int, -1) <> 2 then
      insert into _fail values ('PKG2-pre',
        format('holder1 remaining_after was %s, expected 2 (5 sold, 3 used)', v_use->>'remaining_after'));
    end if;

    -- Holder1's extra, non-package spend inside the window.
    insert into public.sales (business_id, client_id, kind, amount_cents, occurred_at, branch_id)
    values (biz, cl_h1, 'service', 3000, v_t0, br);
  end if;

  -- PLAN C: 5 holders sold in window -- clears the real evidence floor (5), so its utilisation
  -- and median must come back as real computed values, not suppressed.
  begin
    v_sellc1 := public.sell_package_v102(biz, cl_c1, plan_c, br, gen_random_uuid());
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('PKG-C1', format('sell_package_v102 (plan C holder 1) raised %s: %s', v_err, sqlerrm));
  end;
  begin
    v_sellc2 := public.sell_package_v102(biz, cl_c2, plan_c, br, gen_random_uuid());
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('PKG-C1', format('sell_package_v102 (plan C holder 2) raised %s: %s', v_err, sqlerrm));
  end;
  begin
    v_sellc3 := public.sell_package_v102(biz, cl_c3, plan_c, br, gen_random_uuid());
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('PKG-C1', format('sell_package_v102 (plan C holder 3) raised %s: %s', v_err, sqlerrm));
  end;
  begin
    v_sellc4 := public.sell_package_v102(biz, cl_c4, plan_c, br, gen_random_uuid());
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('PKG-C1', format('sell_package_v102 (plan C holder 4) raised %s: %s', v_err, sqlerrm));
  end;
  begin
    v_sellc5 := public.sell_package_v102(biz, cl_c5, plan_c, br, gen_random_uuid());
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('PKG-C1', format('sell_package_v102 (plan C holder 5) raised %s: %s', v_err, sqlerrm));
  end;

  if v_sellc1 is null or v_sellc2 is null or v_sellc3 is null or v_sellc4 is null or v_sellc5 is null then
    insert into _fail values ('PKG-C0', 'plan C sale(s) returned no result; cannot continue the evidence-ok portion');
  else
    v_cpc1 := (v_sellc1->>'client_package_id')::uuid;

    -- Same technique as holder1 above: two of holder c1's three session-uses are hand-seeded,
    -- backdated 14 and 7 days before "now"; the third goes through the real RPC. c2..c5 use 0
    -- sessions each, so plan C's sessions_used comes ENTIRELY from c1 (5-2=3), same as plan A's
    -- holder1 -- the only thing that changed is the number of holders, which is what moves plan C
    -- across the evidence floor while plan A stays below it.
    insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at, note, branch_id)
    values (v_usec2_sale, biz, cl_c1, 'service', 0, v_t0 - interval '14 days',
            'package session used: ZZ v675 plan C', br);
    v_payload := jsonb_build_object('branch_id', br, 'business_id', biz, 'client_package_id', v_cpc1);
    v_hash := md5(v_payload::text);
    insert into public.package_session_consumptions
      (id, business_id, client_package_id, client_id, sale_id, actor, idempotency_key,
       request_payload, request_hash, remaining_before, remaining_after, created_at, result)
    values
      (v_usec2_id, biz, v_cpc1, cl_c1, v_usec2_sale, u_owner, 'v675-manual-planc-session-002',
       v_payload, v_hash, 5, 4, v_t0 - interval '14 days',
       jsonb_build_object('status','completed','replayed',false));
    update public.client_packages set remaining = 4, status = 'active' where id = v_cpc1;

    insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at, note, branch_id)
    values (v_usec3_sale, biz, cl_c1, 'service', 0, v_t0 - interval '7 days',
            'package session used: ZZ v675 plan C', br);
    v_payload := jsonb_build_object('branch_id', br, 'business_id', biz, 'client_package_id', v_cpc1);
    v_hash := md5(v_payload::text);
    insert into public.package_session_consumptions
      (id, business_id, client_package_id, client_id, sale_id, actor, idempotency_key,
       request_payload, request_hash, remaining_before, remaining_after, created_at, result)
    values
      (v_usec3_id, biz, v_cpc1, cl_c1, v_usec3_sale, u_owner, 'v675-manual-planc-session-003',
       v_payload, v_hash, 4, 3, v_t0 - interval '7 days',
       jsonb_build_object('status','completed','replayed',false));
    update public.client_packages set remaining = 3, status = 'active' where id = v_cpc1;

    begin
      v_usec := public.use_package_session_v102(biz, v_cpc1, br, 'v675-planc-session-001');
    exception when others then
      get stacked diagnostics v_err = returned_sqlstate;
      insert into _fail values ('PKG-C2', format('use_package_session_v102 (plan C) raised %s: %s', v_err, sqlerrm));
    end;

    if v_usec is not null and coalesce((v_usec->>'remaining_after')::int, -1) <> 2 then
      insert into _fail values ('PKG-C2-pre',
        format('plan C holder c1 remaining_after was %s, expected 2 (5 sold, 3 used)', v_usec->>'remaining_after'));
    end if;
  end if;

  perform set_config('request.jwt.claims', null, true);

  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  begin
    g := public.get_ci_package_intelligence_v1(biz, d_from, d_to);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('PKG3', format('get_ci_package_intelligence_v1 raised %s: %s', v_err, sqlerrm));
  end;

  if g is not null then
    select p into pa from jsonb_array_elements(g->'plans') p where (p->>'plan_id')::uuid = plan_a;
    select p into pb from jsonb_array_elements(g->'plans') p where (p->>'plan_id')::uuid = plan_b;
    select p into pc from jsonb_array_elements(g->'plans') p where (p->>'plan_id')::uuid = plan_c;

    -- PLAN A: below the real floor (sold_count=2 < 5). Raw counts stay visible; utilisation.pct
    -- and median_days_between_sessions must both be null even though sessions_used=3 and the
    -- underlying gaps (7, 7) would otherwise support a real median -- the evidence gate applies
    -- to the whole rate, not just to whether a number happens to be computable.
    if pa is null then
      insert into _fail values ('PKG-A0', 'plan A did not appear in the plans array');
    else
      if coalesce((pa->>'sold_count')::int,-1) <> 2 then
        insert into _fail values ('PKG-A1', format('plan A sold_count was %s, expected 2', pa->>'sold_count'));
      end if;
      if coalesce((pa->>'sessions_included')::int,-1) <> 10 then
        insert into _fail values ('PKG-A2', format('plan A sessions_included was %s, expected 10', pa->>'sessions_included'));
      end if;
      if coalesce((pa->>'sessions_used')::int,-1) <> 3 then
        insert into _fail values ('PKG-A3', format('plan A sessions_used was %s, expected 3', pa->>'sessions_used'));
      end if;
      if coalesce(pa->'evidence'->>'status','') <> 'insufficient' then
        insert into _fail values ('PKG-A-EV', 'plan A evidence should be insufficient at n=2 (floor=5)');
      end if;
      if pa->'utilisation'->>'pct' is not null then
        insert into _fail values ('PKG-A4',
          format('plan A utilisation.pct was %s, expected null below the evidence floor (n=2 < 5)',
                 pa->'utilisation'->>'pct'));
      end if;
      if pa->>'median_days_between_sessions' is not null then
        insert into _fail values ('PKG-A5',
          format('plan A median_days_between_sessions was %s, expected null below the evidence '
                 'floor even though real gaps (7, 7) exist underneath', pa->>'median_days_between_sessions'));
      end if;
      if coalesce((pa->>'repurchase_count')::int,-1) <> 1 then
        insert into _fail values ('PKG-A6', format('plan A repurchase_count was %s, expected 1', pa->>'repurchase_count'));
      end if;
      if coalesce((pa->>'outside_spend_cents')::int,-1) <> 3000 then
        insert into _fail values ('PKG-A7', format('plan A outside_spend_cents was %s, expected 3000', pa->>'outside_spend_cents'));
      end if;
      if coalesce((pa->>'expired_or_lapsed_with_unused')::int,-1) <> 0 then
        insert into _fail values ('PKG-A8', format('plan A expired_or_lapsed_with_unused was %s, expected 0', pa->>'expired_or_lapsed_with_unused'));
      end if;
    end if;

    -- PLAN B: also below the floor (sold_count=1 < 5), same suppression pattern as plan A.
    if pb is null then
      insert into _fail values ('PKG-B0', 'plan B did not appear in the plans array');
    else
      if coalesce((pb->>'sold_count')::int,-1) <> 1 then
        insert into _fail values ('PKG-B1', format('plan B sold_count was %s, expected 1', pb->>'sold_count'));
      end if;
      if coalesce(pb->'evidence'->>'status','') <> 'insufficient' then
        insert into _fail values ('PKG-B2', 'plan B evidence should be insufficient at n=1 (floor=5)');
      end if;
      if pb->'utilisation'->>'pct' is not null then
        insert into _fail values ('PKG-B3', 'plan B utilisation.pct should be suppressed to null below the floor');
      end if;
      if pb->>'median_days_between_sessions' is not null then
        insert into _fail values ('PKG-B4', 'plan B median_days_between_sessions should be null below the floor');
      end if;
      if coalesce((pb->>'expired_or_lapsed_with_unused')::int,-1) <> 1 then
        insert into _fail values ('PKG-B5', format('plan B expired_or_lapsed_with_unused was %s, expected 1', pb->>'expired_or_lapsed_with_unused'));
      end if;
    end if;

    -- PLAN C: AT the real floor (sold_count=5), evidence-ok -- utilisation and median must come
    -- back as real, exact computed values. This is the "computed median (enough events)" half of
    -- judgement call 2's assertion; plan A/B above are the "too few" half.
    if pc is null then
      insert into _fail values ('PKG-C0-verify', 'plan C did not appear in the plans array');
    else
      if coalesce((pc->>'sold_count')::int,-1) <> 5 then
        insert into _fail values ('PKG-C3', format('plan C sold_count was %s, expected 5', pc->>'sold_count'));
      end if;
      if coalesce((pc->>'sessions_included')::int,-1) <> 25 then
        insert into _fail values ('PKG-C4', format('plan C sessions_included was %s, expected 25', pc->>'sessions_included'));
      end if;
      if coalesce((pc->>'sessions_used')::int,-1) <> 3 then
        insert into _fail values ('PKG-C5', format('plan C sessions_used was %s, expected 3', pc->>'sessions_used'));
      end if;
      if coalesce(pc->'evidence'->>'status','') <> 'ok' then
        insert into _fail values ('PKG-C6', 'plan C evidence should be ok at n=5 (exactly the floor)');
      end if;
      if coalesce((pc->'utilisation'->>'pct')::numeric,-1) <> 12.0 then
        insert into _fail values ('PKG-C7', format('plan C utilisation pct was %s, expected 12.0 (3/25)', pc->'utilisation'->>'pct'));
      end if;
      if coalesce((pc->>'median_days_between_sessions')::numeric,-1) <> 7 then
        insert into _fail values ('PKG-C8', format('plan C median_days_between_sessions was %s, expected 7', pc->>'median_days_between_sessions'));
      end if;
      if coalesce((pc->>'repurchase_count')::int,-1) <> 0 then
        insert into _fail values ('PKG-C9', format('plan C repurchase_count was %s, expected 0', pc->>'repurchase_count'));
      end if;
      if coalesce((pc->>'outside_spend_cents')::int,-1) <> 0 then
        insert into _fail values ('PKG-C10', format('plan C outside_spend_cents was %s, expected 0', pc->>'outside_spend_cents'));
      end if;
    end if;
  end if;

  -- A branch filter must be REFUSED (client_packages carries no branch column at all).
  begin
    g := public.get_ci_package_intelligence_v1(biz, d_from, d_to, br);
    insert into _fail values ('PKG4',
      'a branch filter was silently accepted; package intelligence has no branch dimension and should refuse it');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '22023' then
      insert into _fail values ('PKG4', format('branch filter refused with %s, expected 22023', v_err));
    end if;
  end;

  perform set_config('request.jwt.claims', null, true);
end
$v675c$;

select case when count(*)=0
            then 'PASS -- daypart exposure, service intelligence, package intelligence all hold'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v675: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
