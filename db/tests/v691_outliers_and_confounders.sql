-- EXECUTED regression fixture for nestly_v691 -- OUTLIER ANALYSIS (check 66, USED) and
-- CONFOUNDER CHECKS (check 68) for Customer Intelligence. Above the v422 watermark: n/a in the
-- baseline phase, gated on the migrated run (taxonomy + discovery-scan tables do not exist
-- before it).
--
-- PART A -- get_ci_category_mix_v1 / get_ci_service_intelligence_v1: 'distribution' + 'skew_note'.
--   ONE business ("biz_a"), one branch, THREE level-2 categories:
--     WHALE   4 customers x $1000 (100000c... no, cents) + 1 customer x $6000 -> a single whale.
--     FLAT    5 customers x $1000, no whale at all (reseeded 2026-09-02, nestly_v717: raised
--             from 4 to 5 customers so it CLEARS v717's category-mix floor gate,
--             app.subgroup_evidence_v1's default floor of 5 on customer_count -- at n=4 this
--             category legitimately went distribution=null/skew_note=null under v717 and this
--             fixture's old n=4 numbers stopped being reachable through category_mix; see SCARCE
--             below for the below-floor case those n=4 rows used to cover).
--     SCARCE  4 customers x $1000, no whale -- the OLD flat shape, kept verbatim as its own
--             category so the below-floor path (v717) still has live coverage: distribution and
--             skew_note must be null, and a new 'evidence' block must read
--             {"n":4,"floor":5,"status":"insufficient"}.
--   HAND-COMPUTED (cents): WHALE n=5, total=10000, mean=2000.00, median=1000.00 (5-point
--   percentile_cont(0.5) lands on the 3rd sorted value), top1_share_bps=6000 (6000/10000),
--   skew_material=true (60% >= 30%, and mean/median=2.0 >= 1.5 -- both trip it),
--   mean_excl_top1=(10000-6000)/4=1000.00. FLAT n=5, total=5000, all five equal at 1000, so
--   mean=median=1000.00, top1_share_bps=2000 (1000/5000, <3000), mean/median=1.0 (<1.5) ->
--   skew_material=false, skew_note absent (null), mean_excl_top1=(5000-1000)/4=1000.00;
--   evidence={"n":5,"floor":5,"status":"ok"} (n=5 clears the floor, which is >=, not >). SCARCE
--   n=4 < floor 5 -> evidence.status='insufficient', distribution and skew_note both null; the
--   underlying counts (revenue_cents/line_count/customer_count) are unaffected by the gate.
--   Each customer buys exactly one service mapped to one category, so
--   get_ci_service_intelligence_v1's per-BUYER distribution reproduces the identical WHALE/FLAT
--   numbers (that reader has no v717 floor gate -- it is not one of the seven readers v717
--   touches -- so its FLAT numbers are unaffected by the category_mix-only gate: still
--   skew_material=false, skew_note null, at n=5 same as n=4 would have shown).
--   MUTATION CHECK: the whale's single sale is folded down to $1000 (now 5 x $1000, flat); the
--   check is re-run and skew_material must flip to false and top1_share_bps to 2000 -- proving
--   the number is recomputed, not memoised from the first call.
--
-- PART B -- get_ci_discovery_v1 confounders: A SIMPSON'S-PARADOX candidate ("biz_b", 2 branches).
--   acquisition_source 'referral' vs 'walk_in_till' (the pooled rest). Branch A is the
--   high-return branch and carries MOST of the referral population; branch B is the low-return
--   branch and carries most of the walk_in_till population -- classic composition-driven
--   reversal. category_node/age_gender/weekday are each pinned to ONE value per acquisition
--   group (referral always Monday/category R/age-band 25_30 female; walk_in_till always
--   Tuesday/category W/age-band 41_50 male), so those three dimensions can never furnish an
--   ELIGIBLE stratum (one side of the floor is always zero) -- only 'branch' can, and does.
--   TRAIN = HOLDOUT (identical counts both halves) so the candidate trivially replicates.
--
--   HAND-COMPUTED (train half, mirrored on holdout):
--     Branch A: referral n=40 returned=28 (70.0%);  walk_in_till n=10 returned=8  (80.0%)
--     Branch B: referral n=10 returned=1  (10.0%);  walk_in_till n=40 returned=8  (20.0%)
--     AGGREGATE referral:     n=50 returned=29 -> 58.0%
--     AGGREGATE walk_in_till: n=50 returned=16 -> 32.0%
--     diff_pp (aggregate) = 58.0 - 32.0 = +26.0  (referral AHEAD in aggregate)
--     Branch A stratum diff = 70.0 - 80.0 = -10.0 (referral BEHIND -- reversed vs aggregate sign)
--     Branch B stratum diff = 10.0 - 20.0 = -10.0 (referral BEHIND -- reversed vs aggregate sign)
--   Both eligible strata reverse sign (2 of 2, a full majority) -> confounders.verdict='reversed'.
--   The candidate clears materiality (26pp >= 10pp) and its Newcombe interval excludes zero, it
--   is a BH survivor (an effect this large at n=50/50 clears q=0.10 at any rank), and it
--   replicates on holdout (identical counts) -- so absent v691 it would have landed in
--   'discoveries'. With v691 it must instead land in 'confounded', NEVER 'discoveries'.
--
-- PART C -- MUTATION CHECK on the verdict itself ("biz_b2", same 2-branch shape, opposite data):
--   referral is ahead of walk_in_till WITHIN EACH branch too (no paradox) --
--     Branch A: referral n=40 returned=32 (80.0%); walk_in_till n=10 returned=7  (70.0%)
--     Branch B: referral n=10 returned=3  (30.0%); walk_in_till n=40 returned=8  (20.0%)
--     AGGREGATE referral 70.0% vs walk_in_till 30.0%, diff +40.0pp; branch A diff +10.0,
--     branch B diff +10.0 -- SAME sign as aggregate both times -> confounders.verdict='consistent'.
--   Same mechanism, same dimension, opposite outcome: proves the classifier reads the data.
--
-- PART D -- THE GENUINE (non-paradox) relationship, single-branch business ("biz_c"), reusing
--   v686's own "referral genuinely returns more" shape but confirming it AGAINST STRATIFICATION
--   this time. Single branch (no branch dimension); referral/walk_in_till each split evenly
--   across Monday and Tuesday (so weekday now DOES furnish two eligible strata) and share one
--   common category_node and one common age_gender (so those two dimensions each furnish exactly
--   one eligible stratum, identical to the aggregate by construction):
--     Monday:  referral n=50 returned=35 (70.0%); walk_in_till n=50 returned=20 (40.0%)  diff +30.0
--     Tuesday: referral n=50 returned=35 (70.0%); walk_in_till n=50 returned=20 (40.0%)  diff +30.0
--   (n=50 per sub-group, not a smaller number, because at n=20 aggregate per acquisition group
--   the Newcombe interval on a 30pp difference brushes zero and the candidate never reaches BH —
--   a real near-miss hit while building this fixture, recorded so it is not rediscovered.)
--     category_node (one shared value, whole population): referral 70.0% vs walk_in_till 40.0%,
--       diff +30.0 -- identical to the aggregate, since it covers the same population.
--     age_gender (one shared value, whole population): same, diff +30.0.
--   FOUR checked strata, ALL matching the aggregate's positive sign, ZERO reversed ->
--   confounders.verdict='consistent', landing in 'discoveries' (replicated=true, confounded=false).
--   Three public.campaign_send_records_v255 rows touch three of this cohort's referral/Monday/
--   train clients inside the window -> competing_campaigns.count must be exactly 3.

\set ON_ERROR_STOP on
begin;
create temp table _fail(k text, v text) on commit drop;

-- ===============================================================================================
-- Shared helper: build one (business, branch, acquisition, category, age/gender, weekday) group
-- of clients with an anchor sale on p_anchor and, for the first p_returned of them, a follow-up
-- sale 5 days later (comfortably inside the 30-day return window). Returns the client ids so a
-- caller can mutate a specific subset later (the outlier mutation check does not need this; the
-- confounder mutation check does not either -- PART C intentionally builds a SEPARATE business
-- rather than mutating PART B in place, so this helper needs no id-tracking beyond its own use).
-- ===============================================================================================
create or replace function pg_temp.zz_v691_group(
  p_biz uuid, p_branch uuid, p_acquisition text, p_gender text, p_birth date,
  p_service uuid, p_anchor date, p_n integer, p_returned integer)
returns uuid[] language plpgsql as $fn$
declare
  v_ids uuid[];
begin
  perform set_config('app.first_acquired_via', p_acquisition, true);
  with ins as (
    insert into public.clients (business_id, full_name, gender, birth_date)
    select p_biz, 'ZZ v691 ' || p_acquisition || ' ' || gs, p_gender, p_birth
      from generate_series(1, p_n) gs
    returning id
  )
  select array_agg(id) into v_ids from ins;

  with sale_ins as (
    insert into public.sales (business_id, branch_id, client_id, kind, amount_cents,
                               occurred_at, counts_as_revenue, counts_as_visit)
    select p_biz, p_branch, cid, 'service', 5000,
           (p_anchor::timestamp + time '10:00') at time zone 'Asia/Singapore', true, true
      from unnest(v_ids) cid
    returning id
  )
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select p_biz, si2.id, 'service', p_service, 1, 5000, 5000 from sale_ins si2;

  if p_returned > 0 then
    insert into public.sales (business_id, branch_id, client_id, kind, amount_cents,
                               occurred_at, counts_as_revenue, counts_as_visit)
    select p_biz, p_branch, cid, 'retail', 1000,
           ((p_anchor + 5)::timestamp + time '10:00') at time zone 'Asia/Singapore', true, true
      from unnest(v_ids[1:p_returned]) cid;
  end if;

  return v_ids;
end;
$fn$;

do $v691setup$
declare
  u_sa uuid := '00000000-0000-4000-8000-000000691eee';
begin
  insert into auth.users (id, email) values (u_sa, 'zz-v691-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v691-sa@example.test')
    on conflict do nothing;
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
end;
$v691setup$;

-- ===============================================================================================
-- PART A -- outlier distribution (category_mix + service_intelligence)
-- ===============================================================================================
do $v691a$
declare
  biz uuid := gen_random_uuid();
  br uuid := gen_random_uuid();
  node_whale text;
  node_flat text;
  node_scarce text;
  svc_whale uuid := gen_random_uuid();
  svc_flat uuid := gen_random_uuid();
  svc_scarce uuid := gen_random_uuid();
  d_to date := current_date;
  d_from date := current_date - 10;
  g jsonb;
  cat_whale jsonb;
  cat_flat jsonb;
  cat_scarce jsonb;
  svc_whale_row jsonb;
  svc_flat_row jsonb;
  biz2 uuid := gen_random_uuid();
  br2 uuid := gen_random_uuid();
  svc_mut uuid := gen_random_uuid();
begin
  select n.node_key into node_whale from public.taxonomy_nodes n
   where n.version_no = 1 and n.level = 2 order by n.node_key limit 1;
  select n.node_key into node_flat from public.taxonomy_nodes n
   where n.version_no = 1 and n.level = 2 and n.node_key <> node_whale order by n.node_key limit 1;
  select n.node_key into node_scarce from public.taxonomy_nodes n
   where n.version_no = 1 and n.level = 2 and n.node_key not in (node_whale, node_flat)
   order by n.node_key limit 1;
  if node_whale is null or node_flat is null or node_scarce is null then
    insert into _fail values ('A0','taxonomy v1 has fewer than three level-2 nodes; fixture cannot run');
    return;
  end if;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v691 outlier firm', 'zz-v691-outlier', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v691 outlier branch', true, true);
  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_whale, biz, 'ZZ v691 whale service', 6000, 30),
    (svc_flat,  biz, 'ZZ v691 flat service',  1000, 30),
    (svc_scarce, biz, 'ZZ v691 scarce service', 1000, 30);
  insert into public.service_canonical_map
    (business_id, service_id, node_key, version_no, method) values
    (biz, svc_whale, node_whale, 1, 'owner_chosen'),
    (biz, svc_flat,  node_flat,  1, 'owner_chosen'),
    (biz, svc_scarce, node_scarce, 1, 'owner_chosen');

  -- WHALE: 4 x 1000 + 1 x 6000.
  with wc as (
    insert into public.clients (business_id, full_name)
    select biz, 'ZZ v691 whale cust ' || gs from generate_series(1,5) gs
    returning id
  ),
  wc_ranked as (
    select id, row_number() over (order by id) as rn from wc
  ),
  wsales as (
    insert into public.sales (business_id, branch_id, client_id, kind, amount_cents,
                               occurred_at, counts_as_revenue, counts_as_visit)
    select biz, br, wr.id, 'service', case when wr.rn = 1 then 6000 else 1000 end,
           (d_from::timestamp + time '10:00') at time zone 'Asia/Singapore', true, true
      from wc_ranked wr
    returning id, amount_cents
  )
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ws.id, 'service', svc_whale, 1, ws.amount_cents, ws.amount_cents from wsales ws;

  -- FLAT: 5 x 1000, no whale (nestly_v717: raised from 4 to 5 so this category clears the
  -- category-mix floor gate; see SCARCE below for the below-floor exhibit the old n=4 covered).
  with fc as (
    insert into public.clients (business_id, full_name)
    select biz, 'ZZ v691 flat cust ' || gs from generate_series(1,5) gs
    returning id
  ),
  fsales as (
    insert into public.sales (business_id, branch_id, client_id, kind, amount_cents,
                               occurred_at, counts_as_revenue, counts_as_visit)
    select biz, br, fc.id, 'service', 1000,
           (d_from::timestamp + time '10:00') at time zone 'Asia/Singapore', true, true
      from fc
    returning id, amount_cents
  )
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, fs.id, 'service', svc_flat, 1, fs.amount_cents, fs.amount_cents from fsales fs;

  -- SCARCE: 4 x 1000, no whale -- the OLD flat shape (nestly_v717 below-floor exhibit: keeps
  -- live coverage of app.subgroup_evidence_v1's insufficient path on get_ci_category_mix_v1).
  with sc as (
    insert into public.clients (business_id, full_name)
    select biz, 'ZZ v691 scarce cust ' || gs from generate_series(1,4) gs
    returning id
  ),
  ssales as (
    insert into public.sales (business_id, branch_id, client_id, kind, amount_cents,
                               occurred_at, counts_as_revenue, counts_as_visit)
    select biz, br, sc.id, 'service', 1000,
           (d_from::timestamp + time '10:00') at time zone 'Asia/Singapore', true, true
      from sc
    returning id, amount_cents
  )
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, ss.id, 'service', svc_scarce, 1, ss.amount_cents, ss.amount_cents from ssales ss;

  -- ---------------------------------------------------------------------------
  -- A1 -- category_mix distribution, exact.
  -- ---------------------------------------------------------------------------
  g := public.get_ci_category_mix_v1(biz, d_from, d_to);
  select c into cat_whale  from jsonb_array_elements(g->'categories') c where c->>'node_key' = node_whale;
  select c into cat_flat   from jsonb_array_elements(g->'categories') c where c->>'node_key' = node_flat;
  select c into cat_scarce from jsonb_array_elements(g->'categories') c where c->>'node_key' = node_scarce;

  if cat_whale is null then
    insert into _fail values ('A1','whale category missing from categories array');
  else
    if (cat_whale->'distribution'->>'n')::int <> 5 then
      insert into _fail values ('A1-n', format('whale distribution.n = %s, expected 5', cat_whale->'distribution'->>'n'));
    end if;
    if (cat_whale->'distribution'->>'mean')::numeric <> 2000.00 then
      insert into _fail values ('A1-mean', format('whale mean = %s, expected 2000.00', cat_whale->'distribution'->>'mean'));
    end if;
    if (cat_whale->'distribution'->>'median')::numeric <> 1000.00 then
      insert into _fail values ('A1-median', format('whale median = %s, expected 1000.00', cat_whale->'distribution'->>'median'));
    end if;
    if (cat_whale->'distribution'->>'top1_share_bps')::int <> 6000 then
      insert into _fail values ('A1-top1', format('whale top1_share_bps = %s, expected 6000', cat_whale->'distribution'->>'top1_share_bps'));
    end if;
    if (cat_whale->'distribution'->>'skew_material')::boolean is distinct from true then
      insert into _fail values ('A1-skew', 'whale skew_material expected true');
    end if;
    if (cat_whale->'distribution'->>'mean_excl_top1')::numeric <> 1000.00 then
      insert into _fail values ('A1-mxt1', format('whale mean_excl_top1 = %s, expected 1000.00', cat_whale->'distribution'->>'mean_excl_top1'));
    end if;
    if cat_whale->>'skew_note' is null or position('60' in cat_whale->>'skew_note') = 0 then
      insert into _fail values ('A1-note', format('whale skew_note missing "60": %s', cat_whale->>'skew_note'));
    end if;
  end if;

  if cat_flat is null then
    insert into _fail values ('A2','flat category missing from categories array');
  else
    -- n=5 (raised from 4, nestly_v717): clears app.subgroup_evidence_v1's default floor of 5,
    -- so distribution/skew_note/evidence must all be the real, non-gated numbers.
    if (cat_flat->'distribution'->>'n')::int <> 5 then
      insert into _fail values ('A2-n', format('flat distribution.n = %s, expected 5', cat_flat->'distribution'->>'n'));
    end if;
    if (cat_flat->'distribution'->>'mean')::numeric <> 1000.00 then
      insert into _fail values ('A2-mean', format('flat mean = %s, expected 1000.00', cat_flat->'distribution'->>'mean'));
    end if;
    if (cat_flat->'distribution'->>'median')::numeric <> 1000.00 then
      insert into _fail values ('A2-median', format('flat median = %s, expected 1000.00', cat_flat->'distribution'->>'median'));
    end if;
    if (cat_flat->'distribution'->>'top1_share_bps')::int <> 2000 then
      insert into _fail values ('A2-top1', format('flat top1_share_bps = %s, expected 2000', cat_flat->'distribution'->>'top1_share_bps'));
    end if;
    if (cat_flat->'distribution'->>'skew_material')::boolean is distinct from false then
      insert into _fail values ('A2-skew', 'flat skew_material expected false');
    end if;
    if (cat_flat->'distribution'->>'mean_excl_top1')::numeric <> 1000.00 then
      insert into _fail values ('A2-mxt1', format('flat mean_excl_top1 = %s, expected 1000.00', cat_flat->'distribution'->>'mean_excl_top1'));
    end if;
    if cat_flat->>'skew_note' is not null then
      insert into _fail values ('A2-note', format('flat skew_note expected null/absent, got %s', cat_flat->>'skew_note'));
    end if;
    if cat_flat->'evidence' is distinct from '{"n":5,"floor":5,"status":"ok"}'::jsonb then
      insert into _fail values ('A2-evidence', format('flat evidence = %s, expected {"n":5,"floor":5,"status":"ok"}', cat_flat->'evidence'));
    end if;
  end if;

  -- ---------------------------------------------------------------------------
  -- A2b -- nestly_v717 below-floor exhibit: SCARCE (n=4 < floor 5) must come back with
  -- distribution and skew_note both null, and a new 'evidence' block reading insufficient.
  -- Counts (revenue_cents/line_count/customer_count) are NOT part of the gate and must survive.
  -- (-> not ->> is deliberate for the null checks below: jsonb_build_object('distribution',
  -- null, ...) stores a JSON null, not a SQL NULL, and `col -> 'key' is not null` is always true
  -- against a JSON null value; ->> correctly folds a JSON null to SQL NULL.)
  -- ---------------------------------------------------------------------------
  if cat_scarce is null then
    insert into _fail values ('A2b','scarce category missing from categories array');
  else
    if (cat_scarce->>'distribution') is not null then
      insert into _fail values ('A2b-distribution', format('expected null, got %s', cat_scarce->>'distribution'));
    end if;
    if cat_scarce->>'skew_note' is not null then
      insert into _fail values ('A2b-note', format('expected null, got %s', cat_scarce->>'skew_note'));
    end if;
    if cat_scarce->'evidence' is distinct from '{"n":4,"floor":5,"status":"insufficient"}'::jsonb then
      insert into _fail values ('A2b-evidence', format('scarce evidence = %s, expected {"n":4,"floor":5,"status":"insufficient"}', cat_scarce->'evidence'));
    end if;
    if (cat_scarce->>'revenue_cents')::bigint <> 4000 then
      insert into _fail values ('A2b-revenue', format('revenue_cents=%s, expected 4000', cat_scarce->>'revenue_cents'));
    end if;
    if (cat_scarce->>'line_count')::int <> 4 then
      insert into _fail values ('A2b-line_count', format('line_count=%s, expected 4', cat_scarce->>'line_count'));
    end if;
    if (cat_scarce->>'customer_count')::int <> 4 then
      insert into _fail values ('A2b-customer_count', format('customer_count=%s, expected 4', cat_scarce->>'customer_count'));
    end if;
  end if;

  -- ---------------------------------------------------------------------------
  -- A3 -- service_intelligence carries the identical per-buyer distribution.
  -- ---------------------------------------------------------------------------
  g := public.get_ci_service_intelligence_v1(biz, d_from, d_to);
  select s into svc_whale_row from jsonb_array_elements(g->'services') s where (s->>'service_id')::uuid = svc_whale;
  select s into svc_flat_row  from jsonb_array_elements(g->'services') s where (s->>'service_id')::uuid = svc_flat;

  if svc_whale_row is null then
    insert into _fail values ('A3','whale service missing from services array');
  else
    if (svc_whale_row->'distribution'->>'n')::int <> 5 then
      insert into _fail values ('A3-n', format('whale service distribution.n = %s, expected 5', svc_whale_row->'distribution'->>'n'));
    end if;
    if (svc_whale_row->'distribution'->>'top1_share_bps')::int <> 6000 then
      insert into _fail values ('A3-top1', format('whale service top1_share_bps = %s, expected 6000', svc_whale_row->'distribution'->>'top1_share_bps'));
    end if;
    if (svc_whale_row->'distribution'->>'skew_material')::boolean is distinct from true then
      insert into _fail values ('A3-skew', 'whale service skew_material expected true');
    end if;
    if svc_whale_row->>'skew_note' is null or position('60' in svc_whale_row->>'skew_note') = 0 then
      insert into _fail values ('A3-note', format('whale service skew_note missing "60": %s', svc_whale_row->>'skew_note'));
    end if;
  end if;
  if svc_flat_row is null then
    insert into _fail values ('A4','flat service missing from services array');
  else
    if (svc_flat_row->'distribution'->>'skew_material')::boolean is distinct from false then
      insert into _fail values ('A4-skew', 'flat service skew_material expected false');
    end if;
    if svc_flat_row->>'skew_note' is not null then
      insert into _fail values ('A4-note', format('flat service skew_note expected null, got %s', svc_flat_row->>'skew_note'));
    end if;
  end if;

  -- ---------------------------------------------------------------------------
  -- A5 -- MUTATION CHECK. public.sales is append-only (trg_sales_immutable_guard blocks both
  -- UPDATE and DELETE), so the check varies the DATA in a SEPARATE business rather than
  -- rewriting history: the SAME n=5 shape as the whale category above, but with the whale's
  -- single 6000 replaced by a 5th customer at 1000 (i.e. no whale at all). If skew_material and
  -- top1_share_bps were hardcoded to "true"/6000 rather than recomputed from the actual values,
  -- this would still show the whale numbers; it must not.
  -- ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz2, 'ZZ v691 outlier mutation firm', 'zz-v691-outlier-mut', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br2, biz2, 'ZZ v691 outlier mutation branch', true, true);
  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_mut, biz2, 'ZZ v691 mutation service', 1000, 30);
  insert into public.service_canonical_map
    (business_id, service_id, node_key, version_no, method) values
    (biz2, svc_mut, node_whale, 1, 'owner_chosen');

  with mc as (
    insert into public.clients (business_id, full_name)
    select biz2, 'ZZ v691 mutation cust ' || gs from generate_series(1,5) gs
    returning id
  ),
  msales as (
    insert into public.sales (business_id, branch_id, client_id, kind, amount_cents,
                               occurred_at, counts_as_revenue, counts_as_visit)
    select biz2, br2, mc.id, 'service', 1000,
           (d_from::timestamp + time '10:00') at time zone 'Asia/Singapore', true, true
      from mc
    returning id, amount_cents
  )
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz2, ms.id, 'service', svc_mut, 1, ms.amount_cents, ms.amount_cents from msales ms;

  g := public.get_ci_category_mix_v1(biz2, d_from, d_to);
  select c into cat_whale from jsonb_array_elements(g->'categories') c where c->>'node_key' = node_whale;
  if cat_whale is null then
    insert into _fail values ('A5','mutation-check category missing');
  else
    if (cat_whale->'distribution'->>'n')::int <> 5 then
      insert into _fail values ('A5-n', format('mutation-check distribution.n = %s, expected 5', cat_whale->'distribution'->>'n'));
    end if;
    if (cat_whale->'distribution'->>'skew_material')::boolean is distinct from false then
      insert into _fail values ('A5-skew', 'with no whale present, skew_material must be false');
    end if;
    if (cat_whale->'distribution'->>'top1_share_bps')::int <> 2000 then
      insert into _fail values ('A5-top1', format('mutation-check top1_share_bps = %s, expected 2000', cat_whale->'distribution'->>'top1_share_bps'));
    end if;
    if cat_whale->>'skew_note' is not null then
      insert into _fail values ('A5-note', format('mutation-check skew_note expected null, got %s', cat_whale->>'skew_note'));
    end if;
  end if;
end;
$v691a$;

-- ===============================================================================================
-- PART B -- Simpson's paradox: aggregate favours referral, every branch stratum reverses it.
-- ===============================================================================================
do $v691b$
declare
  biz uuid := gen_random_uuid();
  br_a uuid := gen_random_uuid();
  br_b uuid := gen_random_uuid();
  node_r text;
  node_w text;
  svc_r uuid := gen_random_uuid();
  svc_w uuid := gen_random_uuid();
  d_to date := current_date - 31;
  d_from date;
  v_train_to date;
  v_holdout_from date;
  train_mon date; train_tue date; hold_mon date; hold_tue date;
  g jsonb;
  disc jsonb;
  conf jsonb;
begin
  d_from := d_to - 119;
  v_train_to := d_from + 59;
  v_holdout_from := v_train_to + 1;
  train_mon := d_from + ((1 - extract(isodow from d_from)::int + 7) % 7);
  train_tue := d_from + ((2 - extract(isodow from d_from)::int + 7) % 7);
  hold_mon := v_holdout_from + ((1 - extract(isodow from v_holdout_from)::int + 7) % 7);
  hold_tue := v_holdout_from + ((2 - extract(isodow from v_holdout_from)::int + 7) % 7);

  select n.node_key into node_r from public.taxonomy_nodes n
   where n.version_no = 1 and n.level = 2 order by n.node_key limit 1;
  select n.node_key into node_w from public.taxonomy_nodes n
   where n.version_no = 1 and n.level = 2 and n.node_key <> node_r order by n.node_key limit 1;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v691 paradox firm', 'zz-v691-paradox', array['dashboard','clients','sales','reports']);
  -- v665: every branch after the first is born 'pending_payment' (and forced inactive) unless
  -- billing_state is explicitly 'active' -- branch B must be a genuinely paid, active branch for
  -- the confounder check to have two active branches to stratify by.
  insert into public.branches (id, business_id, name, is_default, active, billing_state) values
    (br_a, biz, 'ZZ v691 branch A', true, true, 'included'),
    (br_b, biz, 'ZZ v691 branch B', false, true, 'active');
  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_r, biz, 'ZZ v691 referral-category service', 5000, 30),
    (svc_w, biz, 'ZZ v691 walkin-category service', 5000, 30);
  insert into public.service_canonical_map
    (business_id, service_id, node_key, version_no, method) values
    (biz, svc_r, node_r, 1, 'owner_chosen'),
    (biz, svc_w, node_w, 1, 'owner_chosen');

  -- referral: always Monday, category R, age 25_30 female. walk_in_till: always Tuesday,
  -- category W, age 41_50 male. Neither weekday/category/age_gender can ever furnish an
  -- eligible confounder stratum (one side is always exactly zero).
  perform pg_temp.zz_v691_group(biz, br_a, 'referral',     'female', current_date - 27, svc_r, train_mon, 40, 28);
  perform pg_temp.zz_v691_group(biz, br_b, 'referral',     'female', current_date - 27, svc_r, train_mon, 10, 1);
  perform pg_temp.zz_v691_group(biz, br_a, 'walk_in_till', 'male',   current_date - 45, svc_w, train_tue, 10, 8);
  perform pg_temp.zz_v691_group(biz, br_b, 'walk_in_till', 'male',   current_date - 45, svc_w, train_tue, 40, 8);
  perform pg_temp.zz_v691_group(biz, br_a, 'referral',     'female', current_date - 27, svc_r, hold_mon, 40, 28);
  perform pg_temp.zz_v691_group(biz, br_b, 'referral',     'female', current_date - 27, svc_r, hold_mon, 10, 1);
  perform pg_temp.zz_v691_group(biz, br_a, 'walk_in_till', 'male',   current_date - 45, svc_w, hold_tue, 10, 8);
  perform pg_temp.zz_v691_group(biz, br_b, 'walk_in_till', 'male',   current_date - 45, svc_w, hold_tue, 40, 8);

  g := public.get_ci_discovery_v1(biz, d_from, d_to);

  if g is null then
    insert into _fail values ('B0','get_ci_discovery_v1 returned no payload');
    return;
  end if;

  -- B1 -- the referral candidate must NOT be in 'discoveries'.
  select d into disc from jsonb_array_elements(g->'discoveries') d
   where d->>'dimension' = 'acquisition_source' and d->>'group' = 'referral';
  if disc is not null then
    insert into _fail values ('B1','the Simpson''s-paradox referral candidate landed in discoveries, not confounded');
  end if;

  -- B2 -- it must be in 'confounded', replicated=true, confounders.verdict='reversed'.
  select d into disc from jsonb_array_elements(g->'confounded') d
   where d->>'dimension' = 'acquisition_source' and d->>'group' = 'referral';
  if disc is null then
    insert into _fail values ('B2','the Simpson''s-paradox referral candidate is missing from confounded');
  else
    if (disc->>'diff_pp')::numeric <> 26.0 then
      insert into _fail values ('B2-diff', format('aggregate diff_pp = %s, expected 26.0', disc->>'diff_pp'));
    end if;
    if (disc->>'replicated')::boolean is distinct from true then
      insert into _fail values ('B2-rep', 'expected replicated=true (train and holdout are mirrored)');
    end if;
    conf := disc->'confounders';
    if conf is null then
      insert into _fail values ('B2-conf','confounded entry carries no confounders block');
    else
      if (conf->>'verdict') <> 'reversed' then
        insert into _fail values ('B2-verdict', format('verdict = %s, expected reversed', conf->>'verdict'));
      end if;
      if (conf->>'strata_checked')::int <> 2 then
        insert into _fail values ('B2-checked', format('strata_checked = %s, expected 2 (branch A, branch B)', conf->>'strata_checked'));
      end if;
      if (conf->>'strata_reversed')::int <> 2 then
        insert into _fail values ('B2-reversed', format('strata_reversed = %s, expected 2', conf->>'strata_reversed'));
      end if;
      if (conf->>'strata_consistent')::int <> 0 then
        insert into _fail values ('B2-consistent', format('strata_consistent = %s, expected 0', conf->>'strata_consistent'));
      end if;
    end if;
  end if;
end;
$v691b$;

-- ===============================================================================================
-- PART C -- MUTATION CHECK on the verdict: same shape, opposite (non-paradoxical) data.
-- ===============================================================================================
do $v691c$
declare
  biz uuid := gen_random_uuid();
  br_a uuid := gen_random_uuid();
  br_b uuid := gen_random_uuid();
  node_r text;
  node_w text;
  svc_r uuid := gen_random_uuid();
  svc_w uuid := gen_random_uuid();
  d_to date := current_date - 31;
  d_from date;
  v_train_to date;
  v_holdout_from date;
  train_mon date; train_tue date; hold_mon date; hold_tue date;
  g jsonb;
  disc jsonb;
  conf jsonb;
begin
  d_from := d_to - 119;
  v_train_to := d_from + 59;
  v_holdout_from := v_train_to + 1;
  train_mon := d_from + ((1 - extract(isodow from d_from)::int + 7) % 7);
  train_tue := d_from + ((2 - extract(isodow from d_from)::int + 7) % 7);
  hold_mon := v_holdout_from + ((1 - extract(isodow from v_holdout_from)::int + 7) % 7);
  hold_tue := v_holdout_from + ((2 - extract(isodow from v_holdout_from)::int + 7) % 7);

  select n.node_key into node_r from public.taxonomy_nodes n
   where n.version_no = 1 and n.level = 2 order by n.node_key limit 1;
  select n.node_key into node_w from public.taxonomy_nodes n
   where n.version_no = 1 and n.level = 2 and n.node_key <> node_r order by n.node_key limit 1;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v691 mutation firm', 'zz-v691-mutation', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active, billing_state) values
    (br_a, biz, 'ZZ v691 mutation branch A', true, true, 'included'),
    (br_b, biz, 'ZZ v691 mutation branch B', false, true, 'active');
  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_r, biz, 'ZZ v691 mutation referral service', 5000, 30),
    (svc_w, biz, 'ZZ v691 mutation walkin service', 5000, 30);
  insert into public.service_canonical_map
    (business_id, service_id, node_key, version_no, method) values
    (biz, svc_r, node_r, 1, 'owner_chosen'),
    (biz, svc_w, node_w, 1, 'owner_chosen');

  -- SAME shape as PART B (referral=Monday/category R/age 25_30 female; walk_in_till=Tuesday/
  -- category W/age 41_50 male; branch A vs branch B) but referral is now AHEAD of walk_in_till
  -- WITHIN each branch too -- no paradox to find.
  perform pg_temp.zz_v691_group(biz, br_a, 'referral',     'female', current_date - 27, svc_r, train_mon, 40, 32);
  perform pg_temp.zz_v691_group(biz, br_b, 'referral',     'female', current_date - 27, svc_r, train_mon, 10, 3);
  perform pg_temp.zz_v691_group(biz, br_a, 'walk_in_till', 'male',   current_date - 45, svc_w, train_tue, 10, 7);
  perform pg_temp.zz_v691_group(biz, br_b, 'walk_in_till', 'male',   current_date - 45, svc_w, train_tue, 40, 8);
  perform pg_temp.zz_v691_group(biz, br_a, 'referral',     'female', current_date - 27, svc_r, hold_mon, 40, 32);
  perform pg_temp.zz_v691_group(biz, br_b, 'referral',     'female', current_date - 27, svc_r, hold_mon, 10, 3);
  perform pg_temp.zz_v691_group(biz, br_a, 'walk_in_till', 'male',   current_date - 45, svc_w, hold_tue, 10, 7);
  perform pg_temp.zz_v691_group(biz, br_b, 'walk_in_till', 'male',   current_date - 45, svc_w, hold_tue, 40, 8);

  g := public.get_ci_discovery_v1(biz, d_from, d_to);
  if g is null then
    insert into _fail values ('C0','get_ci_discovery_v1 returned no payload');
    return;
  end if;

  select d into disc from jsonb_array_elements(g->'discoveries') d
   where d->>'dimension' = 'acquisition_source' and d->>'group' = 'referral';
  if disc is null then
    insert into _fail values ('C1','the non-paradoxical referral candidate is missing from discoveries');
  else
    if (disc->>'diff_pp')::numeric <> 40.0 then
      insert into _fail values ('C1-diff', format('aggregate diff_pp = %s, expected 40.0', disc->>'diff_pp'));
    end if;
    conf := disc->'confounders';
    if conf is null then
      insert into _fail values ('C1-conf','discoveries entry carries no confounders block');
    else
      if (conf->>'verdict') <> 'consistent' then
        insert into _fail values ('C1-verdict', format('verdict = %s, expected consistent', conf->>'verdict'));
      end if;
      if (conf->>'strata_checked')::int <> 2 then
        insert into _fail values ('C1-checked', format('strata_checked = %s, expected 2', conf->>'strata_checked'));
      end if;
      if (conf->>'strata_reversed')::int <> 0 then
        insert into _fail values ('C1-reversed', format('strata_reversed = %s, expected 0', conf->>'strata_reversed'));
      end if;
    end if;
  end if;

  select d into disc from jsonb_array_elements(g->'confounded') d
   where d->>'dimension' = 'acquisition_source' and d->>'group' = 'referral';
  if disc is not null then
    insert into _fail values ('C2','the non-paradoxical referral candidate was wrongly moved to confounded');
  end if;
end;
$v691c$;

-- ===============================================================================================
-- PART D -- the genuine relationship (single branch), stratified by weekday/category/age_gender,
-- all consistent; plus the fixed competing_campaigns disclosure.
-- ===============================================================================================
do $v691d$
declare
  biz uuid := gen_random_uuid();
  br uuid := gen_random_uuid();
  node_c text;
  svc_c uuid := gen_random_uuid();
  d_to date := current_date - 31;
  d_from date;
  v_train_to date;
  v_holdout_from date;
  train_mon date; train_tue date; hold_mon date; hold_tue date;
  g jsonb;
  disc jsonb;
  conf jsonb;
  v_ids_mon uuid[];
  v_camp_count int;
begin
  d_from := d_to - 119;
  v_train_to := d_from + 59;
  v_holdout_from := v_train_to + 1;
  train_mon := d_from + ((1 - extract(isodow from d_from)::int + 7) % 7);
  train_tue := d_from + ((2 - extract(isodow from d_from)::int + 7) % 7);
  hold_mon := v_holdout_from + ((1 - extract(isodow from v_holdout_from)::int + 7) % 7);
  hold_tue := v_holdout_from + ((2 - extract(isodow from v_holdout_from)::int + 7) % 7);

  select n.node_key into node_c from public.taxonomy_nodes n
   where n.version_no = 1 and n.level = 2 order by n.node_key limit 1;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v691 genuine firm', 'zz-v691-genuine', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v691 genuine branch', true, true);
  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_c, biz, 'ZZ v691 genuine service', 5000, 30);
  insert into public.service_canonical_map
    (business_id, service_id, node_key, version_no, method) values
    (biz, svc_c, node_c, 1, 'owner_chosen');

  -- ONE shared category and ONE shared age/gender for EVERY client (both groups), so
  -- category_node and age_gender each furnish exactly one checked stratum (identical to the
  -- aggregate by construction). weekday splits both groups evenly across Monday/Tuesday.
  -- n=50 per weekday sub-group (not 10): at n=20 aggregate per acquisition group the Newcombe
  -- interval on a 30pp difference brushes zero (a real near-miss found while proving this
  -- fixture, not a hypothetical) -- n=50 per sub-group (aggregate n=100 per acquisition group)
  -- clears it with room to spare.
  v_ids_mon := pg_temp.zz_v691_group(biz, br, 'referral', 'female', current_date - 27, svc_c, train_mon, 50, 35);
  perform pg_temp.zz_v691_group(biz, br, 'referral',     'female', current_date - 27, svc_c, train_tue, 50, 35);
  perform pg_temp.zz_v691_group(biz, br, 'walk_in_till', 'female', current_date - 27, svc_c, train_mon, 50, 20);
  perform pg_temp.zz_v691_group(biz, br, 'walk_in_till', 'female', current_date - 27, svc_c, train_tue, 50, 20);
  perform pg_temp.zz_v691_group(biz, br, 'referral',     'female', current_date - 27, svc_c, hold_mon, 50, 35);
  perform pg_temp.zz_v691_group(biz, br, 'referral',     'female', current_date - 27, svc_c, hold_tue, 50, 35);
  perform pg_temp.zz_v691_group(biz, br, 'walk_in_till', 'female', current_date - 27, svc_c, hold_mon, 50, 20);
  perform pg_temp.zz_v691_group(biz, br, 'walk_in_till', 'female', current_date - 27, svc_c, hold_tue, 50, 20);

  -- Three campaign sends touching three of the train/Monday/referral cohort members, inside the
  -- requested window.
  insert into public.campaign_send_records_v255
    (business_id, campaign_kind, campaign_ref_id, send_kind, campaign_label, channel,
     client_id, occurred_at, retention_until)
  select biz, 'promotion', gen_random_uuid(), 'blast', 'ZZ v691 campaign', 'none',
         cid, (train_mon::timestamp + time '11:00') at time zone 'Asia/Singapore',
         (train_mon::timestamp + time '11:00') at time zone 'Asia/Singapore' + interval '400 days'
    from unnest(v_ids_mon[1:3]) cid;

  g := public.get_ci_discovery_v1(biz, d_from, d_to);
  if g is null then
    insert into _fail values ('D0','get_ci_discovery_v1 returned no payload');
    return;
  end if;

  select d into disc from jsonb_array_elements(g->'discoveries') d
   where d->>'dimension' = 'acquisition_source' and d->>'group' = 'referral';
  if disc is null then
    insert into _fail values ('D1','the genuine referral relationship is missing from discoveries');
  else
    if (disc->>'diff_pp')::numeric <> 30.0 then
      insert into _fail values ('D1-diff', format('aggregate diff_pp = %s, expected 30.0', disc->>'diff_pp'));
    end if;
    if (disc->>'replicated')::boolean is distinct from true then
      insert into _fail values ('D1-rep', 'expected replicated=true');
    end if;
    conf := disc->'confounders';
    if conf is null then
      insert into _fail values ('D1-conf','discoveries entry carries no confounders block');
    else
      if (conf->>'verdict') <> 'consistent' then
        insert into _fail values ('D1-verdict', format('verdict = %s, expected consistent', conf->>'verdict'));
      end if;
      if (conf->>'strata_checked')::int <> 4 then
        insert into _fail values ('D1-checked', format('strata_checked = %s, expected 4 (2 weekday + category + age_gender)', conf->>'strata_checked'));
      end if;
      if (conf->>'strata_reversed')::int <> 0 then
        insert into _fail values ('D1-reversed', format('strata_reversed = %s, expected 0', conf->>'strata_reversed'));
      end if;
      if (conf->>'strata_consistent')::int <> 4 then
        insert into _fail values ('D1-consistent', format('strata_consistent = %s, expected 4', conf->>'strata_consistent'));
      end if;
    end if;
  end if;

  select d into disc from jsonb_array_elements(g->'confounded') d
   where d->>'dimension' = 'acquisition_source' and d->>'group' = 'referral';
  if disc is not null then
    insert into _fail values ('D2','the genuine referral relationship was wrongly moved to confounded');
  end if;

  -- D3 -- competing_campaigns: exact count, fixed note.
  if g->'competing_campaigns' is null then
    insert into _fail values ('D3','competing_campaigns block is missing');
  else
    v_camp_count := coalesce((g->'competing_campaigns'->>'count')::int, -1);
    if v_camp_count <> 3 then
      insert into _fail values ('D3-count', format('competing_campaigns.count = %s, expected 3', v_camp_count));
    end if;
    if (g->'competing_campaigns'->>'note') <> 'campaign exposure is reported, not adjusted' then
      insert into _fail values ('D3-note', format('competing_campaigns.note = %s', g->'competing_campaigns'->>'note'));
    end if;
  end if;
end;
$v691d$;

select case when count(*)=0 then 'PASS — outlier distribution + confounder checks hold'
       else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v691: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
