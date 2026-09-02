-- NESTLY v682 — the golden reconciliation corpus seeder.
--
-- Closes checklist item 10: a suite of >=100 populated synthetic businesses across every
-- supported sector, whose headline metrics reconcile EXACTLY to independently calculated
-- expected values. Proven by db/tests/executed/v682_golden_reconciliation.sql.
--
-- ---------------------------------------------------------------------------------------------
-- THE ORACLE, AND WHY IT NEVER QUERIES public.sales.
-- ---------------------------------------------------------------------------------------------
-- app.seed_golden_business_v682(p_index, p_sector, p_owner) provisions ONE fully-operational
-- business (businesses + branches + staff + business_workspace_controls_v94 +
-- business_subscription_lifecycle_v94 + subscriptions + a -infinity reporting_contract_versions_v106
-- row per docs/qa/CI-CORPUS-FIXTURE-GUIDE.md "Making a business genuinely operational" /
-- "FIXTURE-TIMING TRAP") plus a DETERMINISTIC customer/sales population keyed only on
-- (p_index, p_sector) -- no randomness anywhere. It returns the expected headline values computed
-- by INDEPENDENT plpgsql arithmetic on those same two inputs, BEFORE any row it just inserted is
-- read back. The independence is the point: db/tests/executed/v682_golden_reconciliation.sql
-- calls three product RPCs (get_revenue_truth_v106, get_ci_daypart_v1, get_customer_lifecycle_v107)
-- against the rows this function wrote, and compares their output to this function's returned
-- 'expected' block -- two separately-derived numbers that must land on the same integer, not one
-- number checking itself.
--
-- ---------------------------------------------------------------------------------------------
-- THE POPULATION SHAPE, and why every piece of it maps to a closed-form sum.
-- ---------------------------------------------------------------------------------------------
--   n = 8 + (p_index mod 7)                              -- 8..14 identified customers
--   customer c (1..n): visits_c  = 1 + ((p_index + c) mod 5)     -- 1..5 visits
--                       ticket_c = sector_base_price * (1 + (c mod 3))  -- 3 distinct price points
--   identified_revenue       = sum_c ticket_c * visits_c
--   identified_transactions  = sum_c visits_c
--   repeat_customers         = count of c where visits_c >= 2
--   customer_count           = n                          -- every visits_c >= 1 by construction
--   anonymous sales: (p_index mod 2) rows, client_id null, each priced sector_base_price*4
--     anonymous_revenue = (p_index mod 2) * sector_base_price*4
--   reversed pairs: (p_index mod 3) FULL reversals on a dedicated client who has no other sale.
--     Each pair (original + its exact-amount reversal, both dated inside the window) nets to
--     zero revenue AND zero visits -- app.v106_sale_residual_minor zeroes the original's residual
--     for get_revenue_truth_v106 / get_customer_lifecycle_v107, and app.analytics_sale_class_v1
--     (v628) marks a reversed original's own include_visit false for get_ci_daypart_v1 -- so this
--     client contributes exactly 0 to every metric below. Its purpose is solely to prove the
--     exclusion holds at scale, the way v106_corpus_revenue_truth.sql's R2 proves it for one pair.
--   1 synthetic client (is_synthetic=true) with 2 real sales at the sector base price
--     (counts_as_revenue=true, counts_as_visit=false -- see the insert's own comment for why visit
--     is left false). UPDATED by nestly_v687 (HARDEN): this client used to carry ZERO sales,
--     specifically to sidestep a divergence where get_revenue_truth_v106 predated the
--     is_synthetic exclusion entirely while get_ci_daypart_v1 already enforced it via v628 --
--     giving it no sales sidestepped the disagreement rather than fixing it. nestly_v687 closed
--     that gap (get_revenue_truth_v106 now excludes is_synthetic-client sales via
--     app.analytics_sale_class_v1, same as get_ci_daypart_v1), so this corpus now gives the
--     synthetic client real revenue-bearing sales specifically to prove the exclusion holds: with
--     v687 applied, known/identified revenue and completed/identified_transactions below are
--     unmoved by these 2 rows; with v687 rolled back, they are not (see
--     db/tests/executed/v687_corpus_synthetic_exclusion.sql and this file's own red/green proof).
--   known_revenue          = identified_revenue + anonymous_revenue
--   completed_transactions = identified_transactions + (p_index mod 2)
--   visits                 = identified_transactions + (p_index mod 2)   -- same qualifying set as
--                             completed_transactions in this design (every counted sale is both
--                             counts_as_revenue and counts_as_visit, no $0 rows, no packages) --
--                             asserted against get_revenue_truth_v106 and get_ci_daypart_v1
--                             respectively, so an equal expected value still tests two independent
--                             code paths, not one number checking itself twice.
--
-- ---------------------------------------------------------------------------------------------
-- SECTOR COVERAGE. Read from public.sector_profiles (seeded by nestly_v75, extended by nestly_v275
-- for 'bar') rather than guessed: the eight canonical sector_key values live there today --
-- fnb, salon, facial, massage, fitness, retail, other, bar. p_sector is validated against this
-- fixed list (hardcoded here, not looked up live, so the seeder's own behaviour cannot silently
-- drift if sector_profiles gains or loses a row later without this file being revisited).
--
-- ---------------------------------------------------------------------------------------------
-- MODULE ENTITLEMENT, read and chosen honestly. get_revenue_truth_v106 and get_customer_lifecycle_
-- v107 gate on `app.is_super_admin() or app.has_perm(p_business,'view_finance')`, AND (since
-- nestly_v573, fixed by nestly_v668 two migrations before this one) get_revenue_truth_v106 also
-- requires app.can_module(p_business,'customerintel'). get_ci_daypart_v1 gates through
-- app.ci_access_gate_v667, whose merchant arm is `is_salon_member and can_module(business,'reports')`
-- -- no customerintel requirement there. Rather than wire up the full sector_bundle_versions /
-- business_sector_assignments entitlement machinery (irrelevant to what this corpus measures),
-- every seeded business lists ['dashboard','clients','sales','reports','customerintel'] in
-- enabled_modules directly -- the same simplification db/tests/executed/v106_corpus_revenue_truth
-- .sql uses, and legitimate because a real firm entitled to 'reports' genuinely carries
-- 'customerintel' too (nestly_v171 appended it to every published bundle containing 'reports').
-- All three readers below are therefore called as the business OWNER, never a super admin --
-- the only caller for which "reconciles to Dashboard/P&L truth" is a coherent claim.
--
-- ---------------------------------------------------------------------------------------------
-- BULK INSERT, TRIGGERS OFF. Mirrors db/tests/executed/v422_customer_intelligence_scale.sql:
-- `alter table public.sales disable trigger user` for the whole per-business population (a few
-- dozen rows, not v422's 24,000, but still no per-row RPCs, per the task's runtime budget), then
-- re-enabled before the function returns. Disabling user triggers also disables the v20 reversal-
-- insert guard, so the reversal pair below needs no app.sale_reversal_insert_id /
-- app.sale_reversal_original_id GUC pair -- there is nothing left armed to check them while this
-- block runs.
--
-- One transaction, whole harness run rolls back (db/tests/executed/v682_golden_reconciliation.sql
-- runs the whole corpus inside `begin; ... rollback;`). No production access.

begin;

create or replace function app.seed_golden_business_v682(
  p_index int,
  p_sector text,
  p_owner uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_biz               uuid := gen_random_uuid();
  v_branch            uuid := gen_random_uuid();
  v_base_price_cents  bigint;
  v_n                 int;
  v_num_anon          int;
  v_num_rev           int;
  v_today             date := (clock_timestamp() at time zone 'Asia/Singapore')::date;
  v_window_from       date := v_today - 120;
  v_window_to         date := v_today + 1;
  v_identified_revenue       bigint := 0;
  v_identified_transactions  bigint := 0;
  v_repeat_customers         int := 0;
  v_anon_revenue             bigint := 0;
  v_rev_client        uuid;
  v_synth_client       uuid;
  v_c                  int;
  v_visits_c           int;
  v_ticket_c           bigint;
  v_r                  int;
  v_rev_ticket         bigint;
  v_anon_ticket        bigint;
begin
  if p_owner is null then
    raise exception 'app.seed_golden_business_v682: p_owner is required' using errcode = '22023';
  end if;

  -- Canonical sector list (public.sector_profiles as of nestly_v75 + nestly_v275's 'bar' row).
  v_base_price_cents := case p_sector
    when 'fnb'     then 1200
    when 'salon'   then 6800
    when 'facial'  then 8800
    when 'massage' then 7500
    when 'fitness' then 5500
    when 'retail'  then 2500
    when 'other'   then 2000
    when 'bar'     then 1800
    else null
  end;
  if v_base_price_cents is null then
    raise exception 'app.seed_golden_business_v682: unsupported sector % -- must be one of '
      'fnb/salon/facial/massage/fitness/retail/other/bar', p_sector using errcode = '22023';
  end if;

  v_n        := 8 + (p_index % 7);
  v_num_anon := p_index % 2;
  v_num_rev  := p_index % 3;
  v_anon_ticket := v_base_price_cents * 4;
  v_rev_ticket  := v_base_price_cents;

  ------------------------------------------------------------------------------------------
  -- control rows: business, branch, staff, workspace/subscription, reporting contract.
  ------------------------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, industry, enabled_modules)
  values (v_biz, 'ZZ golden '||p_sector||' #'||p_index,
          'zz-golden-'||p_sector||'-'||p_index, p_sector,
          array['dashboard','clients','sales','reports','customerintel']);

  insert into public.branches (id, business_id, name, is_default, active)
  values (v_branch, v_biz, 'ZZ golden branch', true, true);

  insert into public.staff (business_id, user_id, role, full_name, active, access_state)
  values (v_biz, p_owner, 'owner', 'ZZ golden owner', true, 'approved');

  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (v_biz, 'approved', now(), 'v682 golden corpus')
  on conflict (business_id) do update
    set approval_status = 'approved', decided_at = now(), decision_reason = 'v682 golden corpus';

  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (v_biz, 'current', false)
  on conflict (business_id) do update set state = 'current', workspace_paused = false;

  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (v_biz, 'active', 'paid', now() + interval '30 days')
  on conflict (business_id) do update
    set status = 'active', payment_status = 'paid', current_period_end = now() + interval '30 days';

  -- Reach back to -infinity so every backdated sale below (up to 120 days in the past) resolves
  -- a contract -- the auto-created version (effective_from = transaction start) only covers
  -- future-dated rows. See docs/qa/CI-CORPUS-FIXTURE-GUIDE.md's FIXTURE-TIMING TRAP.
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  values (v_biz, null,     2, '-infinity', 'Asia/Singapore', 'SGD', true),
         (v_biz, v_branch, 2, '-infinity', 'Asia/Singapore', 'SGD', true)
  on conflict do nothing;

  ------------------------------------------------------------------------------------------
  -- customers + sales, bulk, triggers off (see header).
  ------------------------------------------------------------------------------------------
  alter table public.sales disable trigger user;

  for v_c in 1..v_n loop
    declare
      v_cl uuid := gen_random_uuid();
    begin
      v_visits_c := 1 + ((p_index + v_c) % 5);
      v_ticket_c := v_base_price_cents * (1 + (v_c % 3));

      insert into public.clients (id, business_id, full_name)
      values (v_cl, v_biz, 'ZZ golden customer '||v_c);

      insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
        occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
        policy_resolved_at, commission_rate_bps, commission_resolved_at)
      select gen_random_uuid(), v_biz, v_branch, v_cl, 'service', v_ticket_c,
             v_ts, v_ts, true, true, true, v_ts, 0, v_ts
        from generate_series(1, v_visits_c) as g,
        lateral (select (v_window_from + ((v_c*7 + g*3 + p_index) % 120))::timestamp
                          at time zone 'Asia/Singapore' as v_ts) t;

      v_identified_revenue := v_identified_revenue + v_ticket_c * v_visits_c;
      v_identified_transactions := v_identified_transactions + v_visits_c;
      if v_visits_c >= 2 then
        v_repeat_customers := v_repeat_customers + 1;
      end if;
    end;
  end loop;

  -- Anonymous sales: client_id null, counted as revenue+visit, never identified.
  if v_num_anon > 0 then
    insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
      occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
      policy_resolved_at, commission_rate_bps, commission_resolved_at)
    select gen_random_uuid(), v_biz, v_branch, null, 'service', v_anon_ticket,
           v_ts, v_ts, true, true, true, v_ts, 0, v_ts
      from generate_series(1, v_num_anon) as g,
      lateral (select (v_window_from + ((g*11 + p_index) % 120))::timestamp
                        at time zone 'Asia/Singapore' as v_ts) t;
    v_anon_revenue := v_num_anon * v_anon_ticket;
  end if;

  -- Reversed pairs: a dedicated client with no other sale, so the pair's net-zero contribution
  -- is provably 0 rather than merely offsetting some other real visit of theirs.
  if v_num_rev > 0 then
    v_rev_client := gen_random_uuid();
    insert into public.clients (id, business_id, full_name)
    values (v_rev_client, v_biz, 'ZZ golden reversal client');

    for v_r in 1..v_num_rev loop
      declare
        v_orig   uuid := gen_random_uuid();
        v_rvsl   uuid := gen_random_uuid();
        v_offset int := (v_r*17 + p_index) % 110;
        v_ts1    timestamptz := (v_window_from + v_offset)::timestamp
                                   at time zone 'Asia/Singapore';
        v_ts2    timestamptz := (v_window_from + v_offset + 1)::timestamp
                                   at time zone 'Asia/Singapore';
      begin
        insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
          occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
          policy_resolved_at, commission_rate_bps, commission_resolved_at)
        values (v_orig, v_biz, v_branch, v_rev_client, 'service', v_rev_ticket,
                v_ts1, v_ts1, true, true, true, v_ts1, 0, v_ts1);

        insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
          occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
          policy_resolved_at, commission_rate_bps, commission_resolved_at,
          reversal_of, reversal_reason, reversal_actor, reversal_idempotency_key)
        values (v_rvsl, v_biz, v_branch, v_rev_client, 'service', -v_rev_ticket,
                v_ts2, v_ts2, true, false, false, v_ts2, 0, v_ts2,
                v_orig, 'v682 golden corpus reversal', p_owner,
                'v682-rev-'||v_biz::text||'-'||v_r);
      end;
    end loop;
  end if;

  -- 1 synthetic client, WITH 2 real sales at the sector base price (v687 hardening: this used
  -- to be zero sales specifically to sidestep the get_revenue_truth_v106/get_ci_daypart_v1
  -- divergence -- see the header's "1 synthetic client" note and nestly_v687's header for the
  -- fix that closed it). counts_as_revenue=true so a get_revenue_truth_v106 that forgot the
  -- exclusion would inflate known/identified revenue and completed/identified_transactions by
  -- exactly these 2 rows -- the divergence this corpus now exists to catch.
  -- counts_as_visit=false is deliberate and NOT part of what v687 tests: get_customer_lifecycle_
  -- v107 (nestly_v107, untouched by v687, out of this task's scope) has its own eligibility gate
  -- requiring counts_as_visit=true and carries no is_synthetic exclusion of its own, so a
  -- counts_as_visit=true row here would leak into transacting_identified_customers /
  -- repeat_purchasers_in_period and move 'customer_count'/'repeat_customers' out from under the
  -- unchanged expected block below, for a reason unrelated to D7. get_ci_daypart_v1 already
  -- excludes this client either way, via app.analytics_sale_class_v1's is_synthetic_client column
  -- (nestly_v628/v680) -- unaffected by this migration.
  v_synth_client := gen_random_uuid();
  insert into public.clients (id, business_id, full_name, is_synthetic)
  values (v_synth_client, v_biz, 'ZZ golden synthetic (excluded from every reader)', true);

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  select gen_random_uuid(), v_biz, v_branch, v_synth_client, 'service', v_base_price_cents,
         v_ts, v_ts, true, false, false, v_ts, 0, v_ts
    from generate_series(1, 2) as g,
    lateral (select (v_window_from + ((g*23 + p_index) % 120))::timestamp
                      at time zone 'Asia/Singapore' as v_ts) t;

  alter table public.sales enable trigger user;

  return jsonb_build_object(
    'business_id', v_biz,
    'branch_id', v_branch,
    'sector', p_sector,
    'window_from', v_window_from,
    'window_to', v_window_to,
    'expected', jsonb_build_object(
      'known_revenue', v_identified_revenue + v_anon_revenue,
      'identified_revenue', v_identified_revenue,
      'anonymous_revenue', v_anon_revenue,
      'completed_transactions', v_identified_transactions + v_num_anon,
      'identified_transactions', v_identified_transactions,
      'visits', v_identified_transactions + v_num_anon,
      'customer_count', v_n,
      'repeat_customers', v_repeat_customers
    )
  );
end;
$fn$;

-- Service-role / definer-only, exactly as the task requires: a golden-corpus seeder that can
-- fabricate an arbitrary "operational business" plus history must never be reachable by an
-- ordinary authenticated session or anon.
revoke all on function app.seed_golden_business_v682(int, text, uuid) from public, anon, authenticated;

commit;
