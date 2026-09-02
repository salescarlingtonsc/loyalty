-- EXECUTED regression fixture for nestly_v686 -- the Customer Intelligence DISCOVERY engine.
-- Closes checklist items 26 (holdout validation), 27 (predetermined dimensions x metrics,
-- disclosed), 28 (deterioration), 67 (seasonality disclosure), 69 (false discovery control),
-- 70 (missingness sensitivity). Above the v422 watermark: n/a in the baseline phase, gated on
-- the migrated run (the taxonomy tables this reader depends on, v647+, do not exist before it).
--
-- ONE operational business ("biz"), read by a super-admin (Google-SSO-shaped) session --
-- entitlement for a per-business drill-down does not depend on the target business being
-- "operational" (app.v176_can_read_firm_report short-circuits true for a super admin), so no
-- workspace/subscription recipe is needed for a READ-only fixture (contrast v675 Part C, which
-- calls real write RPCs and does need it).
--
-- A 120-day window, ending 31 days before "today" so every anchor purchase in it is already
-- MATURE (current_date - anchor >= 30) with margin to spare -- no flakiness from running the
-- suite on different days. TRAIN = first 60 days, HOLDOUT = last 60 days (integer-day split,
-- even here because 119 is odd and floor(119/2)=59 gives TRAIN 60 days, HOLDOUT the remaining
-- 60 -- see the migration's own SPLIT note).
--
-- FIVE COHORTS, each a distinct (acquisition_source, category_node, age_gender, weekday)
-- combination chosen so every assertion below is independently traceable to one cohort. Every
-- cohort's weekday is "the half's first Monday" EXCEPT the Saturday-fluke cohort, so the
-- weekday dimension only ever sees two groups (Monday, Saturday) -- controlled precisely enough
-- to hand-compute comparisons.examined.
--
--   REFERRAL             acquisition=referral,      category=nails,  age_gender=25_30_female
--   WALKIN (baseline)     acquisition=walk_in_till,  category=nails,  age_gender=25_30_female
--   SATURDAY-FLUKE        acquisition=qr_join,       category=nails,  age_gender=25_30_female,
--                         weekday=Saturday (not Monday)
--   FACIAL (deteriorating) acquisition=staff_created, category=facial, age_gender=25_30_female
--   OUTLIER (n=3, train only) acquisition=csv_import, category=nails,  age_gender=41_50_other
--
-- PREDETERMINED TRAIN / HOLDOUT COUNTS (n, returned-within-30-days):
--   REFERRAL:  train 20/16 (80.0%)   holdout 20/16 (80.0%)   -- same both halves: replicates.
--   WALKIN:    train 40/12 (30.0%)   holdout 40/12 (30.0%)   -- same both halves: replicates.
--   SATURDAY:  train 10/9  (90.0%)   holdout 10/3  (30.0%)   -- collapses: must NOT replicate.
--   FACIAL:    train 20/14 (70.0%)   holdout 20/7  (35.0%)   -- collapses: deteriorating.
--   OUTLIER:   train 3/2 (n<5, excluded from every comparison by the floor; holdout has none).
--
-- HAND-COMPUTED comparisons.examined (train, (dimension,group) cells clearing the n>=5 floor):
--   weekday:             Monday (20+40+20+3=83) + Saturday (10)                      = 2
--   acquisition_source:  referral(20) + walk_in_till(40) + qr_join(10) + staff_created(20)
--                        (csv_import n=3 excluded)                                    = 4
--   category_node:       nails (20+40+10+3=73) + facial (20)                          = 2
--   age_gender:          25_30_female (20+40+10+20=90) (41_50_other n=3 excluded)      = 1
--   TOTAL                                                                             = 9
--
-- HAND-COMPUTED two-proportion p-value for the REFERRAL candidate (train, referral vs the
-- pooled rest of the acquisition_source dimension = walk_in_till+qr_join+staff_created+
-- csv_import = n 73, returned 37):
--   p1 = 16/20 = 0.8,  p2 = 37/73 = 0.506849...,  pooled = 53/93 = 0.569892...
--   se = sqrt(0.569892*0.430108*(1/20+1/73)) = sqrt(0.245115*0.063699) = 0.124955
--   z  = (0.8-0.506849)/0.124955 = 2.34597
--   p  = 2*(1-Phi(2.34597)) ~= 0.0190
-- BH THRESHOLD, worst case: q=0.10, and at the LARGEST possible rank (rank=m, i.e. referral
-- ranked dead last among however many candidates the run actually finds), the BH cutoff is
-- (m/m)*q = q = 0.10 -- the loosest threshold BH can ever apply to any candidate. 0.0190 clears
-- even that loosest bar, so referral survives BH regardless of exactly how many other candidates
-- the live run turns up (Saturday/Monday and walk_in_till are expected too, all with even smaller
-- p-values than referral's, by hand-inspection of their much larger effect sizes -- see the
-- migration header). The fixture asserts the *outcome* (referral present in 'discoveries',
-- replicated=true) rather than re-deriving the exact rank/m the live run assigns, which is the
-- honest way to prove survival without brittle-coupling the test to floating-point tie-breaks.
--
-- MISSINGNESS (exact): headline (train+holdout pooled) n=93+90=183, returned=53+38=91.
-- 8 anonymous qualifying sales are seeded in the window.
--   metric_if_anonymous_all_returned = (91+8)/(183+8) = 99/191 = 51.8%
--   metric_if_anonymous_none_returned = 91/(183+8)     = 91/191 = 47.6%
--
-- SEASONALITY: the business is created inside this transaction (effectively "now"), so no data
-- exists one year before the window -- available must be false.
--
-- MUTATION-CHECK (a), a second minimal business ("biz2"): the SAME referral (train 20/16) vs
-- walk_in_till (train 40/12) pair, but HOLDOUT's referral count is mutated to 20/4 (20%, down
-- from the unmutated 80%) while walk_in_till holds at 40/12 (30%). Train diff was +50pp
-- (referral above rest); holdout diff is -10pp (referral now below rest) -- the sign flips, so
-- the engine must move referral to 'not_replicated', never 'discoveries', proving the holdout
-- check actually discriminates rather than rubber-stamping every candidate.

\set ON_ERROR_STOP on
begin;

create temp table _fail(k text, v text) on commit drop;

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-000000686eee', 'zz-v686-sa@example.test')
  on conflict (id) do nothing;
insert into public.super_admins (user_id, email) values
  ('00000000-0000-4000-8000-000000686eee', 'zz-v686-sa@example.test')
  on conflict do nothing;

-- One reusable cohort builder: p_n clients (given acquisition/age/gender), each with an anchor
-- service sale on p_anchor_date, and a qualifying return sale (anchor+7 days) for the first
-- p_n_returned of them. Shared by both parts of this fixture.
create function pg_temp.zz_v686_cohort(
  p_biz uuid, p_br uuid, p_svc uuid, p_anchor_date date, p_acq text,
  p_age_years integer, p_gender text, p_n integer, p_n_returned integer, p_price integer
) returns void language plpgsql as $$
declare
  v_ids uuid[];
begin
  perform set_config('app.first_acquired_via', p_acq, true);
  select array_agg(gen_random_uuid()) into v_ids from generate_series(1, p_n);

  insert into public.clients (id, business_id, full_name, birth_date, gender, is_synthetic)
  select v_ids[g], p_biz, 'ZZ v686 ' || p_acq || ' client ' || g,
         (current_date - make_interval(years => p_age_years))::date, p_gender, false
    from generate_series(1, p_n) g;

  with s as (
    insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at)
    select gen_random_uuid(), p_biz, p_br, v_ids[g], 'service', p_price,
           (p_anchor_date::timestamp + time '10:00') at time zone 'Asia/Singapore'
      from generate_series(1, p_n) g
    returning id, client_id
  )
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select p_biz, s.id, 'service', p_svc, 1, p_price, p_price from s;

  if p_n_returned > 0 then
    insert into public.sales (business_id, branch_id, client_id, kind, amount_cents, occurred_at)
    select p_biz, p_br, v_ids[g], 'service', p_price,
           ((p_anchor_date + 7)::timestamp + time '10:00') at time zone 'Asia/Singapore'
      from generate_series(1, p_n_returned) g;
  end if;

  perform set_config('app.first_acquired_via', '', true);
end;
$$;

-- =================================================================================================
-- PART A -- the full discovery scan
-- =================================================================================================
do $v686a$
declare
  biz uuid := gen_random_uuid();
  br uuid := gen_random_uuid();
  svc_nails uuid := gen_random_uuid();
  svc_facial uuid := gen_random_uuid();
  u_sa uuid := '00000000-0000-4000-8000-000000686eee';
  d_to date := current_date - 31;
  d_from date := (current_date - 31) - 119;
  v_train_to date := d_from + 59;
  v_holdout_from date := d_from + 60;
  v_train_mon date;
  v_train_sat date;
  v_hold_mon date;
  v_hold_sat date;
  g jsonb;
  disc jsonb;
  notrep jsonb;
  det jsonb;
  fdc jsonb;
  ref_row jsonb;
  sat_row jsonb;
  facial_row jsonb;
  outlier_seen boolean := false;
  rec jsonb;
  v_err text;
begin
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v686 discovery firm', 'zz-v686-discovery',
     array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v686 branch', true, true);
  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_nails, biz, 'ZZ v686 nails service', 3000, 30),
    (svc_facial, biz, 'ZZ v686 facial service', 4000, 45);
  insert into public.service_canonical_map (business_id, service_id, node_key, version_no, method)
  values
    (biz, svc_nails, 'nails', 1, 'owner_chosen'),
    (biz, svc_facial, 'facial', 1, 'owner_chosen');

  select min(gs::date) into v_train_mon from generate_series(d_from, v_train_to, interval '1 day') gs
   where extract(isodow from gs) = 1;
  select min(gs::date) into v_train_sat from generate_series(d_from, v_train_to, interval '1 day') gs
   where extract(isodow from gs) = 6;
  select min(gs::date) into v_hold_mon from generate_series(v_holdout_from, d_to, interval '1 day') gs
   where extract(isodow from gs) = 1;
  select min(gs::date) into v_hold_sat from generate_series(v_holdout_from, d_to, interval '1 day') gs
   where extract(isodow from gs) = 6;

  if v_train_mon is null or v_train_sat is null or v_hold_mon is null or v_hold_sat is null
     or v_train_mon + 7 > v_train_to or v_hold_mon + 7 > d_to then
    insert into _fail values ('DISC0',
      format('fixture window %s..%s does not yield usable Monday/Saturday anchors in both halves',
             d_from, d_to));
  else
    -- ---------------------------------------------------------------------------------------
    -- TRAIN cohorts
    -- ---------------------------------------------------------------------------------------
    perform pg_temp.zz_v686_cohort(biz, br, svc_nails, v_train_mon, 'referral', 27, 'female', 20, 16, 3000);
    perform pg_temp.zz_v686_cohort(biz, br, svc_nails, v_train_mon, 'walk_in_till', 27, 'female', 40, 12, 3000);
    perform pg_temp.zz_v686_cohort(biz, br, svc_nails, v_train_sat, 'qr_join', 27, 'female', 10, 9, 3000);
    perform pg_temp.zz_v686_cohort(biz, br, svc_facial, v_train_mon, 'staff_created', 27, 'female', 20, 14, 4000);
    perform pg_temp.zz_v686_cohort(biz, br, svc_nails, v_train_mon, 'csv_import', 45, 'other', 3, 2, 3000);

    -- ---------------------------------------------------------------------------------------
    -- HOLDOUT cohorts (no outlier group in holdout)
    -- ---------------------------------------------------------------------------------------
    perform pg_temp.zz_v686_cohort(biz, br, svc_nails, v_hold_mon, 'referral', 27, 'female', 20, 16, 3000);
    perform pg_temp.zz_v686_cohort(biz, br, svc_nails, v_hold_mon, 'walk_in_till', 27, 'female', 40, 12, 3000);
    perform pg_temp.zz_v686_cohort(biz, br, svc_nails, v_hold_sat, 'qr_join', 27, 'female', 10, 3, 3000);
    perform pg_temp.zz_v686_cohort(biz, br, svc_facial, v_hold_mon, 'staff_created', 27, 'female', 20, 7, 4000);

    -- 8 anonymous qualifying sales, scattered across the whole window.
    insert into public.sales (business_id, branch_id, client_id, kind, amount_cents, occurred_at)
    select biz, br, null, 'service', 2000,
           ((d_from + (gs * 13))::timestamp + time '09:00') at time zone 'Asia/Singapore'
      from generate_series(0, 7) gs;

    perform set_config('request.jwt.claims', json_build_object(
        'sub', u_sa, 'role','authenticated',
        'amr', json_build_array(json_build_object('method','oauth')),
        'app_metadata', json_build_object('providers', json_build_array('google'))
      )::text, true);

    begin
      g := public.get_ci_discovery_v1(biz, d_from, d_to);
    exception when others then
      get stacked diagnostics v_err = returned_sqlstate;
      insert into _fail values ('DISC1', format('get_ci_discovery_v1 raised %s: %s', v_err, sqlerrm));
    end;

    if g is null then
      insert into _fail values ('DISC1', 'get_ci_discovery_v1 returned no payload');
    else
      disc := g->'discoveries';
      notrep := g->'not_replicated';
      det := g->'deteriorating';
      fdc := g->'false_discovery_control';

      -- comparisons.examined (predetermined = 9)
      if coalesce((fdc->>'hypotheses_examined')::int, -1) <> 9 then
        insert into _fail values ('DISC-EX1',
          format('false_discovery_control.hypotheses_examined was %s, expected 9', fdc->>'hypotheses_examined'));
      end if;
      if coalesce((g->'comparisons'->>'subgroups_examined')::int, -1) <> 9 then
        insert into _fail values ('DISC-EX2',
          format('comparisons.subgroups_examined was %s, expected 9', g->'comparisons'->>'subgroups_examined'));
      end if;

      -- BH bookkeeping keys exist, survivors <= candidates.
      if fdc->'candidates_pre_bh' is null or fdc->'survivors_post_bh' is null or fdc->'q' is null then
        insert into _fail values ('DISC-BH0', 'false_discovery_control is missing candidates_pre_bh/survivors_post_bh/q');
      elsif (fdc->>'survivors_post_bh')::int > (fdc->>'candidates_pre_bh')::int then
        insert into _fail values ('DISC-BH1',
          format('survivors_post_bh (%s) exceeded candidates_pre_bh (%s)',
                 fdc->>'survivors_post_bh', fdc->>'candidates_pre_bh'));
      end if;
      if coalesce((fdc->>'q')::numeric, -1) <> 0.10 then
        insert into _fail values ('DISC-BH2', format('q was %s, expected 0.10', fdc->>'q'));
      end if;

      -- REFERRAL must be a replicated discovery, exact counts, hand-computed p-value.
      select r into ref_row from jsonb_array_elements(disc) r
       where r->>'dimension' = 'acquisition_source' and r->>'group' = 'referral';
      if ref_row is null then
        insert into _fail values ('DISC-REF0', 'referral did not appear in discoveries');
      else
        if coalesce((ref_row->'train'->>'n')::int,-1) <> 20
           or coalesce((ref_row->'train'->>'rate')::numeric,-1) <> 80.0 then
          insert into _fail values ('DISC-REF1',
            format('referral train was %s, expected n=20 rate=80.0', ref_row->'train'));
        end if;
        if coalesce((ref_row->'holdout'->>'n')::int,-1) <> 20
           or coalesce((ref_row->'holdout'->>'rate')::numeric,-1) <> 80.0 then
          insert into _fail values ('DISC-REF2',
            format('referral holdout was %s, expected n=20 rate=80.0', ref_row->'holdout'));
        end if;
        if (ref_row->>'replicated')::boolean is distinct from true then
          insert into _fail values ('DISC-REF3', 'referral replicated should be true');
        end if;
        if ref_row->>'evidence_class' <> 'ASSOCIATION' then
          insert into _fail values ('DISC-REF4', 'referral evidence_class should be ASSOCIATION');
        end if;
        if abs(coalesce((ref_row->>'p_value')::numeric, -1) - 0.0190) > 0.01 then
          insert into _fail values ('DISC-REF5',
            format('referral p_value was %s, expected ~0.019 (hand-computed two-proportion z-test)',
                   ref_row->>'p_value'));
        end if;
        if ref_row->>'bh_rank' is null then
          insert into _fail values ('DISC-REF6', 'referral bh_rank should not be null (it survived BH)');
        end if;
      end if;

      -- SATURDAY-FLUKE (via its acquisition_source twin qr_join, same cohort) must NOT replicate.
      select r into sat_row from jsonb_array_elements(notrep) r
       where r->>'dimension' = 'acquisition_source' and r->>'group' = 'qr_join';
      if sat_row is null then
        insert into _fail values ('DISC-SAT0', 'qr_join (Saturday-fluke) did not appear in not_replicated');
      else
        if coalesce((sat_row->'holdout'->>'n')::int,-1) <> 10
           or coalesce((sat_row->'holdout'->>'rate')::numeric,-1) <> 30.0 then
          insert into _fail values ('DISC-SAT1',
            format('qr_join holdout was %s, expected n=10 rate=30.0', sat_row->'holdout'));
        end if;
        if (sat_row->>'replicated')::boolean is distinct from false then
          insert into _fail values ('DISC-SAT2', 'qr_join replicated should be false');
        end if;
        -- must not ALSO have been reported as a replicated discovery.
        if exists (select 1 from jsonb_array_elements(disc) r2
                    where r2->>'dimension' = 'acquisition_source' and r2->>'group' = 'qr_join') then
          insert into _fail values ('DISC-SAT3', 'qr_join appeared in BOTH discoveries and not_replicated');
        end if;
      end if;

      -- FACIAL (deteriorating): exact 70.0% train -> 35.0% holdout.
      select r into facial_row from jsonb_array_elements(det) r
       where r->>'group' = 'facial';
      if facial_row is null then
        insert into _fail values ('DISC-FAC0', 'facial did not appear in deteriorating');
      else
        if coalesce((facial_row->'train'->>'n')::int,-1) <> 20
           or coalesce((facial_row->'train'->>'rate')::numeric,-1) <> 70.0 then
          insert into _fail values ('DISC-FAC1',
            format('facial train was %s, expected n=20 rate=70.0', facial_row->'train'));
        end if;
        if coalesce((facial_row->'holdout'->>'n')::int,-1) <> 20
           or coalesce((facial_row->'holdout'->>'rate')::numeric,-1) <> 35.0 then
          insert into _fail values ('DISC-FAC2',
            format('facial holdout was %s, expected n=20 rate=35.0', facial_row->'holdout'));
        end if;
        if coalesce((facial_row->>'diff_pp')::numeric,-1) <> 35.0 then
          insert into _fail values ('DISC-FAC3',
            format('facial diff_pp was %s, expected 35.0', facial_row->>'diff_pp'));
        end if;
      end if;

      -- The n=3 outlier group must NEVER appear as a candidate anywhere (below the floor).
      outlier_seen := false;
      for rec in select * from jsonb_array_elements(disc) loop
        if rec->>'group' = '41_50_other' then outlier_seen := true; end if;
      end loop;
      for rec in select * from jsonb_array_elements(notrep) loop
        if rec->>'group' = '41_50_other' then outlier_seen := true; end if;
      end loop;
      for rec in select * from jsonb_array_elements(det) loop
        if rec->>'group' = '41_50_other' then outlier_seen := true; end if;
      end loop;
      for rec in select * from jsonb_array_elements(disc) loop
        if rec->>'group' = 'csv_import' then outlier_seen := true; end if;
      end loop;
      for rec in select * from jsonb_array_elements(notrep) loop
        if rec->>'group' = 'csv_import' then outlier_seen := true; end if;
      end loop;
      if outlier_seen then
        insert into _fail values ('DISC-OUT0',
          'the n=3 outlier group (41_50_other / csv_import) appeared as a candidate somewhere -- the floor should have excluded it entirely');
      end if;

      -- Seasonality: no prior-year data exists (business created inside this transaction).
      if (g->'seasonality'->>'available')::boolean is distinct from false then
        insert into _fail values ('DISC-SEASON', 'seasonality.available should be false (no prior-year data)');
      end if;

      -- Missingness: exact bounds, hand-computed above.
      if coalesce((g->'missingness'->>'anonymous_sales')::int,-1) <> 8 then
        insert into _fail values ('DISC-MISS0',
          format('missingness.anonymous_sales was %s, expected 8', g->'missingness'->>'anonymous_sales'));
      end if;
      if coalesce((g->'missingness'->'bounds'->>'metric_if_anonymous_all_returned')::numeric,-1) <> 51.8 then
        insert into _fail values ('DISC-MISS1',
          format('metric_if_anonymous_all_returned was %s, expected 51.8',
                 g->'missingness'->'bounds'->>'metric_if_anonymous_all_returned'));
      end if;
      if coalesce((g->'missingness'->'bounds'->>'metric_if_anonymous_none_returned')::numeric,-1) <> 47.6 then
        insert into _fail values ('DISC-MISS2',
          format('metric_if_anonymous_none_returned was %s, expected 47.6',
                 g->'missingness'->'bounds'->>'metric_if_anonymous_none_returned'));
      end if;
    end if;

    perform set_config('request.jwt.claims', null, true);
  end if;
end
$v686a$;

-- =================================================================================================
-- PART B -- mutation-check (a): a flipped holdout sign must demote referral to not_replicated
-- =================================================================================================
do $v686b$
declare
  biz2 uuid := gen_random_uuid();
  br2 uuid := gen_random_uuid();
  svc2 uuid := gen_random_uuid();
  u_sa uuid := '00000000-0000-4000-8000-000000686eee';
  d_to date := current_date - 31;
  d_from date := (current_date - 31) - 119;
  v_train_to date := d_from + 59;
  v_holdout_from date := d_from + 60;
  v_train_mon date;
  v_hold_mon date;
  g jsonb;
  ref_row jsonb;
  v_err text;
begin
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz2, 'ZZ v686 mutation firm', 'zz-v686-mutation',
     array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br2, biz2, 'ZZ v686 mutation branch', true, true);
  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc2, biz2, 'ZZ v686 mutation service', 3000, 30);
  insert into public.service_canonical_map (business_id, service_id, node_key, version_no, method)
  values (biz2, svc2, 'nails', 1, 'owner_chosen');

  select min(gs::date) into v_train_mon from generate_series(d_from, v_train_to, interval '1 day') gs
   where extract(isodow from gs) = 1;
  select min(gs::date) into v_hold_mon from generate_series(v_holdout_from, d_to, interval '1 day') gs
   where extract(isodow from gs) = 1;

  if v_train_mon is null or v_hold_mon is null then
    insert into _fail values ('MUT0', 'mutation-check fixture window did not yield a usable Monday anchor');
  else
    -- TRAIN: identical shape to Part A's clean referral-vs-walkin pair (80% vs 30%).
    perform pg_temp.zz_v686_cohort(biz2, br2, svc2, v_train_mon, 'referral', 27, 'female', 20, 16, 3000);
    perform pg_temp.zz_v686_cohort(biz2, br2, svc2, v_train_mon, 'walk_in_till', 27, 'female', 40, 12, 3000);

    -- HOLDOUT: walk_in_till unchanged (30%); referral MUTATED from the would-be-replicating
    -- 16/20 (80%) down to 4/20 (20%) -- now BELOW the rest, flipping the train's positive sign.
    perform pg_temp.zz_v686_cohort(biz2, br2, svc2, v_hold_mon, 'referral', 27, 'female', 20, 4, 3000);
    perform pg_temp.zz_v686_cohort(biz2, br2, svc2, v_hold_mon, 'walk_in_till', 27, 'female', 40, 12, 3000);

    perform set_config('request.jwt.claims', json_build_object(
        'sub', u_sa, 'role','authenticated',
        'amr', json_build_array(json_build_object('method','oauth')),
        'app_metadata', json_build_object('providers', json_build_array('google'))
      )::text, true);

    begin
      g := public.get_ci_discovery_v1(biz2, d_from, d_to);
    exception when others then
      get stacked diagnostics v_err = returned_sqlstate;
      insert into _fail values ('MUT1', format('get_ci_discovery_v1 (mutation) raised %s: %s', v_err, sqlerrm));
    end;

    if g is null then
      insert into _fail values ('MUT1', 'get_ci_discovery_v1 (mutation) returned no payload');
    else
      if exists (select 1 from jsonb_array_elements(g->'discoveries') r
                  where r->>'dimension' = 'acquisition_source' and r->>'group' = 'referral') then
        insert into _fail values ('MUT2',
          'mutated referral (holdout 4/20=20%, sign flipped from train) was reported as a REPLICATED discovery -- the holdout check failed to catch a train-only pattern that did not hold up');
      end if;

      select r into ref_row from jsonb_array_elements(g->'not_replicated') r
       where r->>'dimension' = 'acquisition_source' and r->>'group' = 'referral';
      if ref_row is null then
        insert into _fail values ('MUT3', 'mutated referral did not appear in not_replicated at all');
      else
        if coalesce((ref_row->'holdout'->>'n')::int,-1) <> 20
           or coalesce((ref_row->'holdout'->>'rate')::numeric,-1) <> 20.0 then
          insert into _fail values ('MUT4',
            format('mutated referral holdout was %s, expected n=20 rate=20.0', ref_row->'holdout'));
        end if;
        if (ref_row->>'replicated')::boolean is distinct from false then
          insert into _fail values ('MUT5', 'mutated referral replicated should be false');
        end if;
      end if;
    end if;

    perform set_config('request.jwt.claims', null, true);
  end if;
end
$v686b$;

select case when count(*)=0
            then 'PASS -- discovery scan: candidates, BH, holdout replication, deterioration, seasonality, missingness all hold'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v686: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
