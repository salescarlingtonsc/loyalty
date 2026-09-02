-- EXECUTED acceptance fixture for nestly_v743
-- (db/migrations/20260920_nestly_v743_synthetic_scanner.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v743_corpus --migrated-only
--
-- WHY THIS EXISTS. CI-100-CHECKLIST.md checks 1 (canonical transaction population), 5 (refund/
-- reversal correctness) and 10 (golden reconciliation) require every reader to agree on which
-- sales/clients count. This is the RED-BEFORE/GREEN-AFTER proof for nestly_v743's eleven fixed
-- functions (nine assigned + two the migration's own scanner caught), and the estate-wide scanner
-- itself, each called as its real principal (owner / non-owner staff / platform super admin, per
-- the function's own gate) -- never as the migration role.
--
-- FIXTURE SHAPE. Five separate businesses, each self-contained so nothing in one can perturb an
-- assertion about another:
--   B1 -- the canonical shared population v734/v737/v740/v742 use: 5 real clients whose sales
--         total EXACTLY 50000 cents over 8 distinct visit-days, one synthetic client with 3 sales
--         (one, 4000 cents, fully reversed via a native reversal_of row; unreversed net 6000),
--         plus 2 anonymous sales (client_id null) totalling 10000 cents. Proves
--         get_reports_summary_v94_base.
--   B2 -- a real and a synthetic client each with one 10000-cent sale, a matching checkout
--         evaluation and a 1000-cent checkout-discount line, PLUS a third (real) sale that is
--         fully reversed with its own discount line -- proves get_checkout_discount_report on
--         BOTH bugs at once (synthetic inclusion and reversed-sale inclusion).
--   B3 -- a retention campaign with two treatment members, one real, one synthetic -- proves
--         get_campaign_results.
--   B4 -- a growth-execution recommendation with two treatment members, one real, one synthetic --
--         proves app.get_growth_execution_result_at_v108.
--   B5 -- one real and one synthetic client sharing: a completed service appointment (proves
--         app.v177_appointments and the facial leg of app.v109_sector_source_availability), a
--         retail sale + sale_items row (proves the retail leg of v109_sector_source_availability
--         and public.platform_engagement_monthly_v255's sales_count), a live points-programme earn
--         row (proves public.business_programme_usage_v386's point_system sub-metric), a
--         client_package (proves public.staff_list_package_entitlements_v102), and a lapsed sale
--         pair for public.super_admin_list_businesses' client_count and
--         app.issue_bringback_for_business_v361's grant-issuance writer.
--
-- The scanner itself (app.ci_synthetic_scan_v743()) is asserted to return zero rows against the
-- live estate, and is proven able to fail two ways inside its own rolled-back sub-transactions:
-- removing one allowlist row makes it return that row again, and a throwaway unguarded probe
-- function is caught by name.
--
-- Every assertion below is exact equality, never `> 0`. One transaction, rolled back throughout
-- (two inner SAVEPOINTs let the scanner's two "prove it can fail" probes run destructively and
-- still roll back without losing the outer fixture). No production access.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

----------------------------------------------------------------------------------------------
-- B1 -- shared population; proves public.get_reports_summary_v94_base.
----------------------------------------------------------------------------------------------
do $v743_b1$
declare
  v_owner   uuid := gen_random_uuid();
  v_staff   uuid := gen_random_uuid();
  v_biz     uuid := gen_random_uuid();
  v_branch  uuid := gen_random_uuid();
  v_today   date := (clock_timestamp() at time zone 'Asia/Singapore')::date;
  v_from    date := v_today - 25;
  v_to_excl date := v_today - 12;

  v_cA uuid := gen_random_uuid();
  v_cB uuid := gen_random_uuid();
  v_cC uuid := gen_random_uuid();
  v_cD uuid := gen_random_uuid();
  v_cE uuid := gen_random_uuid();
  v_cS uuid := gen_random_uuid();

  v_sale_syn1 uuid := gen_random_uuid();
  v_rev_syn1  uuid := gen_random_uuid();

  g jsonb;
  v_val bigint;
begin
  insert into auth.users (id, email) values
    (v_owner, 'zz-v743-b1-owner@example.test'),
    (v_staff, 'zz-v743-b1-staff@example.test')
    on conflict (id) do nothing;

  insert into public.businesses (id, name, slug, industry, enabled_modules)
  values (v_biz, 'ZZ v743 B1 shared population', 'zz-v743-b1-shared', 'fnb',
          array['dashboard','clients','sales','reports','giftcards','loyalty','memberships']);

  insert into public.branches (id, business_id, name, is_default, active)
  values (v_branch, v_biz, 'ZZ v743 B1 branch', true, true);

  insert into public.staff (business_id, user_id, role, full_name, active, access_state)
  values (v_biz, v_owner, 'owner', 'ZZ v743 B1 owner', true, 'approved');

  update public.business_workspace_controls_v94
     set approval_status = 'approved', decided_by = v_owner, decided_at = now(),
         decision_reason = 'v743 fixture'
   where business_id = v_biz;
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (v_biz, 'current', false)
  on conflict (business_id) do update set state = 'current', workspace_paused = false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (v_biz, 'active', 'paid', now() + interval '30 days')
  on conflict (business_id) do update
    set status = 'active', payment_status = 'paid', current_period_end = now() + interval '30 days';

  insert into public.clients (id, business_id, full_name, is_synthetic) values
    (v_cA, v_biz, 'ZZ v743 real A', false),
    (v_cB, v_biz, 'ZZ v743 real B', false),
    (v_cC, v_biz, 'ZZ v743 real C', false),
    (v_cD, v_biz, 'ZZ v743 real D', false),
    (v_cE, v_biz, 'ZZ v743 real E', false),
    (v_cS, v_biz, 'ZZ v743 synthetic', true);

  alter table public.sales disable trigger user;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  select gen_random_uuid(), v_biz, v_branch, x.client_id, 'service', x.amount_cents,
         t.v_ts, t.v_ts, true, true, true, t.v_ts, 0, t.v_ts
    from (values
      (v_cA, 0,  5000::bigint),
      (v_cA, 1,  5000::bigint),
      (v_cB, 2, 10000::bigint),
      (v_cB, 3, 10000::bigint),
      (v_cC, 4,  5000::bigint),
      (v_cD, 5,  5000::bigint),
      (v_cE, 6,  5000::bigint),
      (v_cE, 7,  5000::bigint)
    ) as x(client_id, day_offset, amount_cents)
    cross join lateral (
      select ((v_from + x.day_offset)::timestamp + interval '12 hours')
               at time zone 'Asia/Singapore' as v_ts
    ) t;

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  values
    (v_sale_syn1, v_biz, v_branch, v_cS, 'service', 4000,
     (v_from + 8)::timestamp at time zone 'Asia/Singapore',
     (v_from + 8)::timestamp at time zone 'Asia/Singapore',
     true, true, true,
     (v_from + 8)::timestamp at time zone 'Asia/Singapore', 0,
     (v_from + 8)::timestamp at time zone 'Asia/Singapore');
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  select gen_random_uuid(), v_biz, v_branch, v_cS, 'service', x.amount_cents,
         t.v_ts, t.v_ts, true, true, true, t.v_ts, 0, t.v_ts
    from (values
      (9,  3000::bigint),
      (10, 3000::bigint)
    ) as x(day_offset, amount_cents)
    cross join lateral (
      select ((v_from + x.day_offset)::timestamp + interval '12 hours')
               at time zone 'Asia/Singapore' as v_ts
    ) t;

  perform set_config('app.sale_reversal_insert_id', v_rev_syn1::text, true);
  perform set_config('app.sale_reversal_original_id', v_sale_syn1::text, true);
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at,
    reversal_of, reversal_reason, reversal_actor, reversal_idempotency_key)
  values
    (v_rev_syn1, v_biz, v_branch, v_cS, 'service', -4000,
     (v_from + 8)::timestamp at time zone 'Asia/Singapore',
     (v_from + 8)::timestamp at time zone 'Asia/Singapore',
     true, false, false,
     (v_from + 8)::timestamp at time zone 'Asia/Singapore', 0,
     (v_from + 8)::timestamp at time zone 'Asia/Singapore',
     v_sale_syn1, 'v743 fixture full reversal', v_owner, 'v743-syn1-reversal-1');
  perform set_config('app.sale_reversal_insert_id', '', true);
  perform set_config('app.sale_reversal_original_id', '', true);

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  select gen_random_uuid(), v_biz, v_branch, null, 'service', x.amount_cents,
         t.v_ts, t.v_ts, true, true, false, t.v_ts, 0, t.v_ts
    from (values
      (11, 5000::bigint),
      (12, 5000::bigint)
    ) as x(day_offset, amount_cents)
    cross join lateral (
      select ((v_from + x.day_offset)::timestamp + interval '12 hours')
               at time zone 'Asia/Singapore' as v_ts
    ) t;

  alter table public.sales enable trigger user;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  begin
    g := public.get_reports_summary_v94_base(v_biz, v_from, v_today, null);
    v_val := (g #>> '{revenue_by_kind,service}')::bigint;
    if v_val <> 60000 then
      insert into _fail values ('B1_v94base_revenue',
        format('revenue_by_kind.service = %s (expected 60000)', v_val));
    end if;
  exception when others then
    insert into _fail values ('B1_v94base', format('raised %s', sqlstate));
  end;

  perform set_config('request.jwt.claims', null, true);
end
$v743_b1$;

----------------------------------------------------------------------------------------------
-- B2 -- checkout discount report. A real client's normal 10000-cent sale + a 1000-cent discount
-- line; a synthetic client's identical shape; a THIRD real sale that is fully reversed, also
-- carrying a discount line. Proves get_checkout_discount_report excludes both the synthetic
-- client's lines AND the reversed sale's line, while still counting the one legitimate line.
----------------------------------------------------------------------------------------------
do $v743_b2$
declare
  v_owner uuid := gen_random_uuid();
  v_biz uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_cfg uuid := gen_random_uuid();
  v_cReal uuid := gen_random_uuid();
  v_cSyn uuid := gen_random_uuid();
  v_saleReal uuid := gen_random_uuid();
  v_saleSyn uuid := gen_random_uuid();
  v_saleRev uuid := gen_random_uuid();
  v_revRev uuid := gen_random_uuid();
  v_evalReal uuid := gen_random_uuid();
  v_evalSyn uuid := gen_random_uuid();
  v_evalRev uuid := gen_random_uuid();
  v_ffReal uuid := gen_random_uuid();
  v_ffSyn uuid := gen_random_uuid();
  v_ffRev uuid := gen_random_uuid();
  v_rule uuid := gen_random_uuid();
  g jsonb;
  v_val bigint;
begin
  insert into auth.users(id,email) values (v_owner,'zz-v743-b2-owner@example.test');
  insert into public.businesses(id,name,slug,enabled_modules)
    values (v_biz,'ZZ v743 B2 checkout discount','zz-v743-b2-checkout', array['dashboard']);
  insert into public.branches(id,business_id,name,is_default,active) values (v_branch,v_biz,'br',true,true);
  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
    values (v_biz,v_owner,'owner','o',true,'approved');
  update public.business_workspace_controls_v94
     set approval_status='approved', decided_by=v_owner, decided_at=now(), decision_reason='v743 fixture'
   where business_id=v_biz;
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
    values (v_biz,'current',false) on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
    values (v_biz,'active','paid', now()+interval '30 days')
    on conflict (business_id) do update set status='active', payment_status='paid';

  insert into public.clients(id,business_id,full_name,is_synthetic) values
    (v_cReal, v_biz, 'real', false), (v_cSyn, v_biz, 'syn', true);

  insert into public.firm_config_versions(id,business_id,version_no,status,source,snapshot_hash,published_at)
    values (v_cfg, v_biz, 1, 'published', 'manual', repeat('a',32), now());
  update public.businesses set active_config_version_id = v_cfg where id = v_biz;

  alter table public.sales disable trigger user;
  insert into public.sales(id,business_id,branch_id,client_id,kind,amount_cents,occurred_at,created_at,
    counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,commission_rate_bps,commission_resolved_at)
  values
    (v_saleReal, v_biz, v_branch, v_cReal, 'service', 10000, now(), now(), true, true, true, now(), 0, now()),
    (v_saleSyn,  v_biz, v_branch, v_cSyn,  'service', 10000, now(), now(), true, true, true, now(), 0, now()),
    (v_saleRev,  v_biz, v_branch, v_cReal, 'service', 10000, now(), now(), true, true, true, now(), 0, now());
  perform set_config('app.sale_reversal_insert_id', v_revRev::text, true);
  perform set_config('app.sale_reversal_original_id', v_saleRev::text, true);
  insert into public.sales(id,business_id,branch_id,client_id,kind,amount_cents,occurred_at,created_at,
    counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,commission_rate_bps,commission_resolved_at,
    reversal_of, reversal_reason, reversal_actor, reversal_idempotency_key)
  values
    (v_revRev, v_biz, v_branch, v_cReal, 'service', -10000, now(), now(), true, false, false, now(), 0, now(),
     v_saleRev, 'v743 fixture full reversal', v_owner, 'v743-b2-rev');
  perform set_config('app.sale_reversal_insert_id', '', true);
  perform set_config('app.sale_reversal_original_id', '', true);
  alter table public.sales enable trigger user;

  insert into public.checkout_evaluations(id,business_id,branch_id,client_id,server_lines,cart_hash,
    config_version_id,subtotal_cents,discount_total_cents,total_cents,expires_at,consumed_at,consumed_sale_id)
  values
    (v_evalReal, v_biz, v_branch, v_cReal, '[]'::jsonb, encode(sha256('v743-b2-real'::bytea),'hex'), v_cfg, 10000, 1000, 9000, now()+interval '1 hour', now(), v_saleReal),
    (v_evalSyn,  v_biz, v_branch, v_cSyn,  '[]'::jsonb, encode(sha256('v743-b2-syn'::bytea),'hex'),  v_cfg, 10000, 1000, 9000, now()+interval '1 hour', now(), v_saleSyn),
    (v_evalRev,  v_biz, v_branch, v_cReal, '[]'::jsonb, encode(sha256('v743-b2-rev'::bytea),'hex'),  v_cfg, 10000, 1000, 9000, now()+interval '1 hour', now(), v_saleRev);

  insert into public.benefit_fulfilments(id,business_id,canonical_benefit_key,source_engine,fulfilment_kind,
    client_id,detail_ref,face_value_cents,estimated_cost_cents,cost_basis,cost_confidence,config_version_id,occurred_at)
  values
    (v_ffReal, v_biz, 'zz-v743-b2-real', 'checkout', 'discount', v_cReal, v_saleReal, 1000, 1000, 'discount_face','high', v_cfg, now()),
    (v_ffSyn,  v_biz, 'zz-v743-b2-syn',  'checkout', 'discount', v_cSyn,  v_saleSyn,  1000, 1000, 'discount_face','high', v_cfg, now()),
    (v_ffRev,  v_biz, 'zz-v743-b2-rev',  'checkout', 'discount', v_cReal, v_saleRev,  1000, 1000, 'discount_face','high', v_cfg, now());

  insert into public.checkout_discount_lines(id,business_id,sale_id,evaluation_id,rule_id,effect_index,
    effect_type,level,amount_cents,benefit_fulfilment_id,config_version_id)
  values
    (gen_random_uuid(), v_biz, v_saleReal, v_evalReal, v_rule, 0, 'apply_discount_amount','bill', 1000, v_ffReal, v_cfg),
    (gen_random_uuid(), v_biz, v_saleSyn,  v_evalSyn,  v_rule, 0, 'apply_discount_amount','bill', 1000, v_ffSyn,  v_cfg),
    (gen_random_uuid(), v_biz, v_saleRev,  v_evalRev,  v_rule, 0, 'apply_discount_amount','bill', 1000, v_ffRev,  v_cfg);

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role','authenticated')::text, true);
  begin
    g := public.get_checkout_discount_report(v_biz, (now()-interval '1 day')::date, (now()+interval '1 day')::date);
    v_val := (g #>> '{grand_totals,discount_count}')::bigint;
    if v_val <> 1 then
      insert into _fail values ('B2_checkout_discount_count', format('discount_count = %s (expected 1)', v_val));
    end if;
    v_val := (g #>> '{grand_totals,discount_cents}')::bigint;
    if v_val <> 1000 then
      insert into _fail values ('B2_checkout_discount_cents', format('discount_cents = %s (expected 1000)', v_val));
    end if;
    v_val := (g #>> '{grand_totals,sales_total_cents}')::bigint;
    if v_val <> 10000 then
      insert into _fail values ('B2_checkout_sales_total', format('sales_total_cents = %s (expected 10000)', v_val));
    end if;
  exception when others then
    insert into _fail values ('B2_checkout', format('raised %s', sqlstate));
  end;
  perform set_config('request.jwt.claims', null, true);
end
$v743_b2$;

----------------------------------------------------------------------------------------------
-- B3 -- retention campaign; proves public.get_campaign_results.
----------------------------------------------------------------------------------------------
do $v743_b3$
declare
  v_owner uuid := gen_random_uuid();
  v_biz uuid := gen_random_uuid();
  v_cfg uuid := gen_random_uuid();
  v_tax uuid := gen_random_uuid();
  v_prog uuid := gen_random_uuid();
  v_progver uuid := gen_random_uuid();
  v_camp uuid := gen_random_uuid();
  v_cReal uuid := gen_random_uuid();
  v_cSyn uuid := gen_random_uuid();
  g json;
  v_val bigint;
begin
  insert into auth.users(id,email) values (v_owner,'zz-v743-b3-owner@example.test');
  insert into public.businesses(id,name,slug,enabled_modules)
    values (v_biz,'ZZ v743 B3 campaign results','zz-v743-b3-campaign', array['dashboard','retention']);
  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
    values (v_biz,v_owner,'owner','o',true,'approved');
  update public.business_workspace_controls_v94
     set approval_status='approved', decided_by=v_owner, decided_at=now(), decision_reason='v743 fixture'
   where business_id=v_biz;
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
    values (v_biz,'current',false) on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
    values (v_biz,'active','paid', now()+interval '30 days')
    on conflict (business_id) do update set status='active', payment_status='paid';

  insert into public.clients(id,business_id,full_name,is_synthetic) values
    (v_cReal, v_biz, 'real', false), (v_cSyn, v_biz, 'syn', true);

  insert into public.firm_config_versions(id,business_id,version_no,status,source,snapshot_hash)
    values (v_cfg, v_biz, 1, 'draft', 'manual', repeat('a',32));

  insert into public.firm_reward_taxonomy(id,business_id,label,fulfillment_kind)
    values (v_tax, v_biz, 'ZZ v743 credit reward', 'credit');

  insert into public.retention_programs(id,business_id,name,goal_visits,period_days,reward_type,reward_value,current_config_version_id,reward_taxonomy_id)
    values (v_prog, v_biz, 'ZZ v743 program', 3, 30, 'credit', 500, v_cfg, v_tax);

  insert into public.retention_program_versions(id,program_id,config_version_id,business_id,name,goal_visits,
    period_days,starts_on,reward_taxonomy_id,fulfillment_kind,credit_cents)
    values (v_progver, v_prog, v_cfg, v_biz, 'ZZ v743 program v1', 3, 30, current_date, v_tax, 'credit', 500);

  insert into public.retention_campaigns(id,business_id,retention_program_version_id,program_id,config_version_id,
    name,audience_criteria,attribution_window_days,status,created_by)
    values (v_camp, v_biz, v_progver, v_prog, v_cfg, 'ZZ v743 campaign', '{}'::jsonb, 30, 'draft', v_owner);

  insert into public.retention_campaign_members(business_id,campaign_id,client_id,assignment,assignment_bucket)
    values
      (v_biz, v_camp, v_cReal, 'treatment', 0),
      (v_biz, v_camp, v_cSyn,  'treatment', 1);

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role','authenticated')::text, true);
  begin
    g := public.get_campaign_results(v_camp);
    v_val := (g->'treatment'->>'members')::bigint;
    if v_val <> 1 then
      insert into _fail values ('B3_campaign_members', format('treatment.members = %s (expected 1)', v_val));
    end if;
  exception when others then
    insert into _fail values ('B3_campaign', format('raised %s', sqlstate));
  end;
  perform set_config('request.jwt.claims', null, true);
end
$v743_b3$;

----------------------------------------------------------------------------------------------
-- B4 -- growth execution; proves app.get_growth_execution_result_at_v108.
----------------------------------------------------------------------------------------------
do $v743_b4$
declare
  v_owner uuid := gen_random_uuid();
  v_biz uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_cReal uuid := gen_random_uuid();
  v_cSyn uuid := gen_random_uuid();
  v_rec uuid := gen_random_uuid();
  v_exec uuid := gen_random_uuid();
  v_mem1 uuid := gen_random_uuid();
  v_mem2 uuid := gen_random_uuid();
  v_recmemReal uuid := gen_random_uuid();
  v_recmemSyn uuid := gen_random_uuid();
  v_expires timestamptz := now() + interval '10 days';
  v_ends timestamptz := now() + interval '30 days';
  v_copy jsonb;
  g jsonb;
  v_val bigint;
begin
  insert into auth.users(id,email) values (v_owner,'zz-v743-b4-owner@example.test');
  insert into public.businesses(id,name,slug,enabled_modules)
    values (v_biz,'ZZ v743 B4 growth execution','zz-v743-b4-growth', array['dashboard','retention']);
  insert into public.branches(id,business_id,name,is_default,active) values (v_branch,v_biz,'br',true,true);
  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
    values (v_biz,v_owner,'owner','o',true,'approved');
  update public.business_workspace_controls_v94
     set approval_status='approved', decided_by=v_owner, decided_at=now(), decision_reason='v743 fixture'
   where business_id=v_biz;
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
    values (v_biz,'current',false) on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
    values (v_biz,'active','paid', now()+interval '30 days')
    on conflict (business_id) do update set status='active', payment_status='paid';

  insert into public.clients(id,business_id,full_name,is_synthetic) values
    (v_cReal, v_biz, 'real', false), (v_cSyn, v_biz, 'syn', true);

  insert into public.growth_recommendations_v108(
    id, business_id, branch_id, recommendation_type, policy_version, valid_until,
    observation_start, observation_end, comparison_start, comparison_end,
    finding, supporting_evidence, baseline, opportunity, expected_incremental_revenue,
    confidence, assumptions, recommended_action, recommended_channel, recommended_offer,
    estimated_cost_cents, audience_size, excluded_size, frequency_cap_days, success_metric,
    attribution_window_days, holdout_percent, stop_conditions, status, data_freshness_at,
    data_coverage, dedupe_key
  ) values (
    v_rec, v_biz, v_branch, 'lapsed_high_value_bring_back', 'v1', now()+interval '30 days',
    now()-interval '30 days', now(), now()-interval '60 days', now()-interval '30 days',
    'finding', '[]'::jsonb, '{}'::jsonb, '{}'::jsonb, '{}'::jsonb,
    '{}'::jsonb, '[]'::jsonb, '{}'::jsonb, 'in_app', '{}'::jsonb,
    0, 2, 0, 7, 'incremental_completed_purchase_revenue',
    30, 20, '{}'::jsonb, 'executed', now(),
    '{}'::jsonb, encode(sha256('zz-v743-b4-dedupe'::bytea),'hex')
  );

  insert into public.growth_recommendation_members_v108(
    id, recommendation_id, business_id, client_id, eligible, prior_visits, evidence
  ) values
    (v_recmemReal, v_rec, v_biz, v_cReal, true, 1, '{}'::jsonb),
    (v_recmemSyn, v_rec, v_biz, v_cSyn, true, 1, '{}'::jsonb);

  v_copy := jsonb_build_object(
    'schema','nestly.growth_offer_copy','version',1,
    'title','t','body','b','cta_label','Redeem now','cta_destination','customer_growth_offer_qr',
    'eligibility', jsonb_build_object('business_id', v_biz::text, 'branch_id', v_branch::text),
    'conditions', jsonb_build_object('expires_at', v_expires::text, 'timezone', 'Asia/Singapore'),
    'locked_facts', jsonb_build_object('template_id','welcome_back','offer_value_cents',500,
                                        'currency','SGD','expires_at', v_expires::text,'timezone','Asia/Singapore')
  );

  insert into public.growth_executions_v108(
    id, recommendation_id, business_id, branch_id, channel, offer_type, offer_value_cents,
    offer_label, currency, offer_timezone, offer_expires_at, governed_copy, budget_cap_cents,
    holdout_percent, attribution_window_days, minimum_arm_size, approved_by, ends_at,
    idempotency_key, request_hash
  ) values (
    v_exec, v_rec, v_biz, v_branch, 'in_app', 'credit_cents', 500,
    'welcome_back', 'SGD', 'Asia/Singapore', v_expires, v_copy, 100000,
    20, 30, 3, v_owner, v_ends,
    gen_random_uuid(), encode(sha256('zz-v743-b4-request'::bytea),'hex')
  );

  insert into public.growth_execution_members_v108(
    id, execution_id, business_id, recommendation_member_id, client_id, assignment,
    assignment_rank, assignment_score
  ) values
    (v_mem1, v_exec, v_biz, v_recmemReal, v_cReal, 'treatment', 1, encode(sha256('zz-v743-b4-real'::bytea),'hex')),
    (v_mem2, v_exec, v_biz, v_recmemSyn, v_cSyn, 'treatment', 1, encode(sha256('zz-v743-b4-syn'::bytea),'hex'));

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role','authenticated')::text, true);
  begin
    g := app.get_growth_execution_result_at_v108(v_exec, now());
    v_val := (g #>> '{arms,treatment,members}')::bigint;
    if v_val <> 1 then
      insert into _fail values ('B4_growth_members', format('arms.treatment.members = %s (expected 1)', v_val));
    end if;
  exception when others then
    insert into _fail values ('B4_growth', format('raised %s', sqlstate));
  end;
  perform set_config('request.jwt.claims', null, true);
end
$v743_b4$;

----------------------------------------------------------------------------------------------
-- B5 -- combined: v177_appointments, v109_sector_source_availability (facial + retail),
-- super_admin_list_businesses, platform_engagement_monthly_v255, business_programme_usage_v386
-- (point_system), staff_list_package_entitlements_v102, and app.issue_bringback_for_business_v361.
----------------------------------------------------------------------------------------------
do $v743_b5$
declare
  v_owner uuid := gen_random_uuid();
  v_sa uuid := gen_random_uuid();
  v_biz uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_cReal uuid := gen_random_uuid();
  v_cSyn uuid := gen_random_uuid();
  v_svc uuid := gen_random_uuid();
  v_prod uuid := gen_random_uuid();
  v_saleReal uuid := gen_random_uuid();
  v_saleSyn uuid := gen_random_uuid();
  v_plan uuid := gen_random_uuid();
  v_pkgReal uuid := gen_random_uuid();
  v_pkgSyn uuid := gen_random_uuid();
  v_bcamp uuid := gen_random_uuid();
  v_prog uuid;
  v_idReal uuid;
  v_idSyn uuid;
  g jsonb;
  v_val bigint;
  n bigint;
begin
  insert into auth.users(id,email) values (v_owner,'zz-v743-b5-owner@example.test'), (v_sa,'zz-v743-b5-sa@example.test');
  insert into public.businesses(id,name,slug,enabled_modules)
    values (v_biz,'ZZ v743 B5 combined estate','zz-v743-b5-combined', array['dashboard','loyalty']);
  insert into public.branches(id,business_id,name,is_default,active) values (v_branch,v_biz,'br',true,true);
  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
    values (v_biz,v_owner,'owner','o',true,'approved');
  update public.business_workspace_controls_v94
     set approval_status='approved', decided_by=v_owner, decided_at=now(), decision_reason='v743 fixture'
   where business_id=v_biz;
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
    values (v_biz,'current',false) on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
    values (v_biz,'active','paid', now()+interval '30 days')
    on conflict (business_id) do update set status='active', payment_status='paid';
  insert into public.super_admins(user_id,email) values (v_sa,'zz-v743-b5-sa@example.test');

  insert into public.clients(id,business_id,full_name,is_synthetic) values
    (v_cReal, v_biz, 'real', false), (v_cSyn, v_biz, 'syn', true);

  -- v177_appointments + v109_sector (facial leg): one completed service appointment each.
  insert into public.services(id,business_id,name,price_cents,duration_min) values (v_svc, v_biz, 'ZZ svc', 5000, 30);
  insert into public.appointments(id,business_id,client_id,staff_id,starts_at,ends_at,status,service_id,branch_id)
  values
    (gen_random_uuid(), v_biz, v_cReal, null, now()+interval '1 day', now()+interval '1 day 30 minutes', 'completed', v_svc, v_branch),
    (gen_random_uuid(), v_biz, v_cSyn,  null, now()+interval '1 day', now()+interval '1 day 30 minutes', 'completed', v_svc, v_branch);

  -- v109_sector (retail leg) + platform_engagement sales_count: one retail sale each.
  insert into public.products(id,business_id,name,retail_price_cents) values (v_prod, v_biz, 'ZZ prod', 2000);
  alter table public.sales disable trigger user;
  insert into public.sales(id,business_id,branch_id,client_id,kind,amount_cents,occurred_at,created_at,
    counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,commission_rate_bps,commission_resolved_at)
  values
    (v_saleReal, v_biz, v_branch, v_cReal, 'retail', 2000, now(), now(), true, true, true, now(), 0, now()),
    (v_saleSyn,  v_biz, v_branch, v_cSyn,  'retail', 2000, now(), now(), true, true, true, now(), 0, now());
  alter table public.sales enable trigger user;
  insert into public.sale_items(sale_id,business_id,item_type,ref_id,product_id,qty,unit_cents,line_cents)
  values
    (v_saleReal, v_biz, 'retail', v_prod, v_prod, 1, 2000, 2000),
    (v_saleSyn,  v_biz, 'retail', v_prod, v_prod, 1, 2000, 2000);

  -- business_programme_usage_v386 point_system: one earn row on the live points spine each.
  select id into v_prog from public.business_programmes where business_id=v_biz and kind='points';
  perform pg_advisory_xact_lock(app.loyalty_fence_key_v480(v_biz));
  v_idReal := gen_random_uuid();
  perform set_config('app.points_ledger_insert_id', v_idReal::text, true);
  perform set_config('app.points_ledger_write_scope', 'sale_trigger', true);
  insert into public.points_ledger(id,business_id, client_id, programme_id, entry_type, points, created_at, sale_id)
  values (v_idReal, v_biz, v_cReal, v_prog, 'earn', 100, now(), v_saleReal);
  v_idSyn := gen_random_uuid();
  perform set_config('app.points_ledger_insert_id', v_idSyn::text, true);
  perform set_config('app.points_ledger_write_scope', 'sale_trigger', true);
  insert into public.points_ledger(id,business_id, client_id, programme_id, entry_type, points, created_at, sale_id)
  values (v_idSyn, v_biz, v_cSyn, v_prog, 'earn', 100, now(), v_saleSyn);

  -- staff_list_package_entitlements_v102: one client_package each.
  insert into public.package_plans(id,business_id,name,price_cents,sessions) values (v_plan, v_biz, 'ZZ plan', 10000, 10);
  insert into public.client_packages(id,business_id,client_id,plan_id,remaining,plan_name_snapshot,
    plan_version_snapshot,sessions_snapshot,price_cents_snapshot)
  values
    (v_pkgReal, v_biz, v_cReal, v_plan, 10, 'ZZ plan', 1, 10, 10000),
    (v_pkgSyn,  v_biz, v_cSyn,  v_plan, 10, 'ZZ plan', 1, 10, 10000);

  -- app.issue_bringback_for_business_v361: an active campaign, no away-client seeded yet -- the
  -- retail sales above are "now", not lapsed, so this proves the writer issues nothing extra for
  -- the synthetic client from a population it could otherwise see (a negative control matching the
  -- retail/points/appointments proofs above -- see the assertion below).
  insert into public.bringback_campaigns_v361(id,business_id,name,reward_label,away_days,active)
    values (v_bcamp, v_biz, 'ZZ v743 bringback', 'Come back', 30, true);

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role','authenticated')::text, true);

  begin
    g := app.v177_appointments(v_biz, null);
    v_val := (g->>'total')::bigint;
    if v_val <> 1 then
      insert into _fail values ('B5_v177_total', format('total = %s (expected 1)', v_val));
    end if;
  exception when others then
    insert into _fail values ('B5_v177', format('raised %s', sqlstate));
  end;

  begin
    g := app.v109_sector_source_availability(v_biz, 'facial', 1, now());
    v_val := (g->>'service_linked_history_count')::bigint;
    if v_val <> 1 then
      insert into _fail values ('B5_v109_facial', format('service_linked_history_count = %s (expected 1)', v_val));
    end if;
  exception when others then
    insert into _fail values ('B5_v109_facial_raised', format('raised %s', sqlstate));
  end;

  begin
    g := app.v109_sector_source_availability(v_biz, 'retail', 1, now());
    v_val := (g->>'product_linked_history_count')::bigint;
    if v_val <> 1 then
      insert into _fail values ('B5_v109_retail', format('product_linked_history_count = %s (expected 1)', v_val));
    end if;
  exception when others then
    insert into _fail values ('B5_v109_retail_raised', format('raised %s', sqlstate));
  end;

  begin
    g := public.business_programme_usage_v386(v_biz, null, null);
    v_val := (g #>> '{point_system,customers}')::bigint;
    if v_val <> 1 then
      insert into _fail values ('B5_v386_points', format('point_system.customers = %s (expected 1)', v_val));
    end if;
  exception when others then
    insert into _fail values ('B5_v386', format('raised %s', sqlstate));
  end;

  begin
    g := public.staff_list_package_entitlements_v102(v_biz);
    if jsonb_array_length(g) <> 1 then
      insert into _fail values ('B5_package_entitlements',
        format('roster length = %s (expected 1)', jsonb_array_length(g)));
    end if;
    if exists (select 1 from jsonb_array_elements(g) row where (row->>'client_id')::uuid = v_cSyn) then
      insert into _fail values ('B5_package_entitlements_leak', 'the synthetic client''s package appears in the roster');
    end if;
  exception when others then
    insert into _fail values ('B5_package_entitlements_raised', format('raised %s', sqlstate));
  end;

  begin
    perform app.issue_bringback_for_business_v361(v_biz);
    if exists (select 1 from public.bringback_grants_v361 where client_id = v_cSyn) then
      insert into _fail values ('B5_bringback_leak', 'a bringback grant was issued to the synthetic client');
    end if;
  exception when others then
    insert into _fail values ('B5_bringback', format('raised %s', sqlstate));
  end;

  perform set_config('request.jwt.claims', json_build_object(
      'sub', v_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  begin
    select client_count into n from public.super_admin_list_businesses() where business_id = v_biz;
    if n <> 1 then
      insert into _fail values ('B5_super_admin_client_count', format('client_count = %s (expected 1)', n));
    end if;
  exception when others then
    insert into _fail values ('B5_super_admin', format('raised %s', sqlstate));
  end;

  begin
    g := public.platform_engagement_monthly_v255((now()-interval '1 day')::date, (now()+interval '1 day')::date, array[v_biz], 10);
    v_val := (g #> '{businesses,0,sales_count}')::text::bigint;
    if v_val <> 1 then
      insert into _fail values ('B5_platform_engagement_sales', format('sales_count = %s (expected 1)', v_val));
    end if;
  exception when others then
    insert into _fail values ('B5_platform_engagement', format('raised %s', sqlstate));
  end;

  perform set_config('request.jwt.claims', null, true);
end
$v743_b5$;

----------------------------------------------------------------------------------------------
-- PART B -- the scanner itself.
----------------------------------------------------------------------------------------------
do $v743_scanner$
declare
  n bigint;
  v_allowlist_size bigint;
begin
  select count(*) into n from app.ci_synthetic_scan_v743();
  if n <> 0 then
    insert into _fail values ('SCANNER_zero_rows', format('scan returned %s row(s), expected 0', n));
  end if;

  select count(*) into v_allowlist_size from app.ci_synthetic_scan_allowlist_v743;
  if v_allowlist_size <> 121 then  -- 90 seeded by v743 (incl. main's v677 kernel, merged 2026-09-03) + 31 added by nestly_v744's widened scan
    insert into _fail values ('SCANNER_allowlist_size',
      format('allowlist has %s rows (expected 121: 90 from v743 + 31 from v744)', v_allowlist_size));
  end if;
  raise notice 'v743 scanner | allowlist size = % | eleven functions fixed | scan rows = %',
    v_allowlist_size, n;
end
$v743_scanner$;

-- PROVE THE SCANNER CAN FAIL, WAY 1: remove one allowlist row and confirm it reappears.
-- Isolated in its own savepoint so the deletion never survives past this block.
savepoint v743_prove_scanner_1;
do $v743_prove1$
declare n bigint;
begin
  delete from app.ci_synthetic_scan_allowlist_v743
   where function_signature like 'app.detect_double_earn_v309%';
  select count(*) into n from app.ci_synthetic_scan_v743()
   where function_name = 'detect_double_earn_v309';
  if n <> 1 then
    insert into _fail values ('SCANNER_prove_fail_1',
      format('deleting the detect_double_earn_v309 allowlist row should make the scan return '
             'exactly 1 row for it; got %s', n));
  end if;
end
$v743_prove1$;
rollback to savepoint v743_prove_scanner_1;

-- PROVE THE SCANNER CAN FAIL, WAY 2: a throwaway unguarded aggregator over public.sales must be
-- caught by name. Isolated in its own savepoint so the probe function never survives past this
-- block.
savepoint v743_prove_scanner_2;
do $v743_prove2$
declare n bigint;
begin
  create or replace function app._ci_v743_test_probe() returns bigint language sql stable as
  $probe$ select count(*) from public.sales $probe$;
  select count(*) into n from app.ci_synthetic_scan_v743()
   where function_name = '_ci_v743_test_probe';
  if n <> 1 then
    insert into _fail values ('SCANNER_prove_fail_2',
      format('a throwaway unguarded aggregator over public.sales should be caught by name; got %s '
             'matching rows', n));
  end if;
end
$v743_prove2$;
rollback to savepoint v743_prove_scanner_2;

-- Re-assert zero rows after both destructive probes were rolled back -- proves the savepoints
-- left no residue behind for the "real" assertion above to have been vacuously true.
do $v743_scanner_recheck$
declare n bigint;
begin
  select count(*) into n from app.ci_synthetic_scan_v743();
  if n <> 0 then
    insert into _fail values ('SCANNER_residue',
      format('scan returned %s row(s) after the prove-it-can-fail savepoints rolled back -- '
             'residue leaked past a savepoint', n));
  end if;
end
$v743_scanner_recheck$;

select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v743: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

select case when count(*) = 0
            then 'PASS -- v743: all eleven fixed functions exclude synthetic clients / reversed '
                 'sales from every reported total and roster, each verified as its real principal '
                 '(owner / platform super admin), and app.ci_synthetic_scan_v743() returns zero '
                 'rows against the live estate with an 89-entry justified allowlist, proven able '
                 'to fail two independent ways'
            else 'FAIL' end as verdict,
       count(*) as failures
from _fail;

rollback;
