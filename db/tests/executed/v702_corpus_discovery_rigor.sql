-- EXECUTED regression fixture for nestly_v702 -- check 68 refutation fix (typed confounder
-- verdicts: consistent | mixed | reversed | unchecked; only 'consistent' promotes to
-- 'discoveries') and check 16 completion (get_ci_discovery_v1 wrapped in app.ci_envelope_v680).
-- Above the v422 watermark: n/a in the baseline phase (discovery-scan tables/functions do not
-- exist before it), gated on the migrated run.
--
-- PART M -- 'mixed' verdict (1 of 3 checked strata reversed). Single-branch business
--   ("biz_mixed"). Candidate dimension acquisition_source, group 'referral' vs 'walk_in_till'.
--   age_gender/category_node are made structurally unclassifiable for every client (no gender/
--   birth_date set, and the group's service carries no service_canonical_map row), so the ONLY
--   other dimension that can ever furnish a checked stratum is weekday. Three weekdays used:
--     Monday:    referral n=50 returned=40 (80.0%); walk_in_till n=50 returned=20 (40.0%)  diff +40.0
--     Tuesday:   referral n=50 returned=40 (80.0%); walk_in_till n=50 returned=20 (40.0%)  diff +40.0
--     Wednesday: referral n=6  returned=1  (16.7%); walk_in_till n=6  returned=5  (83.3%)  diff -66.7 (REVERSED)
--   AGGREGATE (train, mirrored on holdout): referral n=106 returned=81 -> 76.4%;
--   walk_in_till n=106 returned=45 -> 42.5%; diff_pp = +34.0 (>=10, comfortably clears BH/CI).
--   3 checked strata (Monday, Tuesday, Wednesday -- each clears the floor of 5 on both sides),
--   1 reversed (Wednesday) -> 1/3 = 0.333, not a majority -> confounders.verdict='mixed'.
--   MUST land in 'confounded' (replicated=true, confound_verdict in the note), MUST NOT appear in
--   'discoveries' or 'unverified'.
--
-- PART U -- 'unchecked' verdict (every other dimension fails to clear the floor on both sides).
--   Single-branch business ("biz_unchecked"), same acquisition_source candidate. Every client is
--   anchored on the SAME single weekday (Monday) both halves, so weekday's one possible stratum
--   equals the whole population; age_gender/category_node are again unclassifiable (no gender/
--   birth_date, no service_canonical_map row). referral n=50 returned=40 (80.0%); walk_in_till
--   n=4 returned=0 (0.0%) -- diff_pp=+80.0, comfortably clears materiality/BH/CI at this size.
--   Weekday IS a row in the confounder check (dow is never null) but is INELIGIBLE: the group
--   side (referral, n=50) clears the floor of 5, but the rest side (walk_in_till, n=4) does not
--   (4 < 5) -- and since every client shares the one weekday, that rest_n is identically the
--   candidate's own total rest_n, which only needed to be > 0 (not >= floor) to be examined as a
--   candidate in the first place. age_gender/category_node contribute zero rows (unclassifiable).
--   strata_checked = 0 -> confounders.verdict='unchecked'. MUST land in 'unverified'
--   (with the exact disclosure note), MUST NOT appear in 'discoveries' or 'confounded'.
--
-- PART C -- the v691 4-stratum 'consistent' finding still promotes to 'discoveries' after this
--   migration (regression check on the untouched-by-v702 happy path). Single-branch business
--   ("biz_consistent"), one shared category + one shared age_gender for every client (so those
--   two dimensions each furnish exactly one checked stratum, identical to the aggregate by
--   construction), weekday split evenly Monday/Tuesday (two more checked strata):
--     Monday:  referral n=50 returned=35 (70.0%); walk_in_till n=50 returned=20 (40.0%) diff +30.0
--     Tuesday: referral n=50 returned=35 (70.0%); walk_in_till n=50 returned=20 (40.0%) diff +30.0
--     category_node (whole population, one shared value): diff +30.0 (matches aggregate exactly)
--     age_gender (whole population, one shared value): diff +30.0 (matches aggregate exactly)
--   FOUR checked strata, ALL matching sign, ZERO reversed -> verdict='consistent'.
--   MUST land in 'discoveries' (replicated=true), MUST NOT appear in 'confounded' or 'unverified'.
--
-- MUTATION CHECK (documented, not executed as code -- public.sales/functions are the artifact
-- under test, not a second copy of this migration to mutate in place): reverting the check-68
-- refutation-1 fix -- i.e. restoring `sr.replicated and not sr.confounded` as the 'discoveries'
-- membership test where 'confounded' is only true for verdict='reversed' -- would move PART M's
-- mixed-verdict finding (2 of these assertions: M1 and M4) from 'confounded' back into
-- 'discoveries', turning M1 and M4 red. Reverting refutation-2 (folding strata_checked=0 back into
-- 'consistent') would turn U1/U2/U3 red (the unchecked finding would show verdict='consistent'
-- and land in 'discoveries' instead of 'unverified'). Reverting the envelope wrap (`return
-- v_result;` instead of the app.ci_envelope_v680 call) would turn E1-E5 red (no 'exclusions' key
-- at all). One flip in any of these three fixes is sufficient to turn this fixture red.
--
-- Reuses v691's own `pg_temp.zz_v691_group` fixture-building convention (a shared helper of the
-- same shape, redeclared here as zz_v702_group with parameters for nullable gender/birth_date and
-- an optional service-category mapping toggle, since PART M/U deliberately need age_gender and
-- category_node to be unclassifiable for every client).

\set ON_ERROR_STOP on
begin;
create temp table _fail(k text, v text) on commit drop;

-- ===============================================================================================
-- Shared helper: build one (business, branch, acquisition, weekday) group of clients with an
-- anchor sale on p_anchor and, for the first p_returned of them, a follow-up sale 5 days later.
-- gender/birth_date are left NULL by every caller in this fixture (age_gender must never
-- classify), and the service passed in (p_service) deliberately carries NO
-- service_canonical_map row anywhere in this fixture (category_node must never classify either)
-- -- so the only dimension besides acquisition_source that can ever furnish a checked stratum is
-- weekday, which each PART engineers deliberately (three distinct weekdays for PART M, one single
-- shared weekday for PART U).
-- ===============================================================================================
create or replace function pg_temp.zz_v702_group(
  p_biz uuid, p_branch uuid, p_acquisition text, p_service uuid, p_anchor date,
  p_n integer, p_returned integer)
returns uuid[] language plpgsql as $fn$
declare
  v_ids uuid[];
begin
  perform set_config('app.first_acquired_via', p_acquisition, true);
  with ins as (
    insert into public.clients (business_id, full_name)
    select p_biz, 'ZZ v702 ' || p_acquisition || ' ' || p_anchor::text || ' ' || gs
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

do $v702setup$
declare
  u_sa uuid := '00000000-0000-4000-8000-000000702eee';
begin
  insert into auth.users (id, email) values (u_sa, 'zz-v702-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v702-sa@example.test')
    on conflict do nothing;
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
end;
$v702setup$;

-- ===============================================================================================
-- PART M -- 'mixed' verdict: 1 of 3 checked strata (weekday) reverses.
-- ===============================================================================================
do $v702m$
declare
  biz uuid := gen_random_uuid();
  br uuid := gen_random_uuid();
  svc uuid := gen_random_uuid();
  d_to date := current_date - 31;
  d_from date;
  v_train_to date;
  v_holdout_from date;
  train_mon date; train_tue date; train_wed date;
  hold_mon date; hold_tue date; hold_wed date;
  g jsonb;
  disc jsonb;
  conf jsonb;
begin
  d_from := d_to - 119;
  v_train_to := d_from + 59;
  v_holdout_from := v_train_to + 1;
  train_mon := d_from + ((1 - extract(isodow from d_from)::int + 7) % 7);
  train_tue := d_from + ((2 - extract(isodow from d_from)::int + 7) % 7);
  train_wed := d_from + ((3 - extract(isodow from d_from)::int + 7) % 7);
  hold_mon := v_holdout_from + ((1 - extract(isodow from v_holdout_from)::int + 7) % 7);
  hold_tue := v_holdout_from + ((2 - extract(isodow from v_holdout_from)::int + 7) % 7);
  hold_wed := v_holdout_from + ((3 - extract(isodow from v_holdout_from)::int + 7) % 7);

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v702 mixed firm', 'zz-v702-mixed', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v702 mixed branch', true, true);
  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc, biz, 'ZZ v702 mixed service', 5000, 30);
  -- deliberately NO service_canonical_map row -- category_node never classifies.

  -- Monday: referral 50/40 (80%), walk 50/20 (40%) -- diff +40 (consistent with aggregate sign).
  perform pg_temp.zz_v702_group(biz, br, 'referral',     svc, train_mon, 50, 40);
  perform pg_temp.zz_v702_group(biz, br, 'walk_in_till', svc, train_mon, 50, 20);
  perform pg_temp.zz_v702_group(biz, br, 'referral',     svc, hold_mon,  50, 40);
  perform pg_temp.zz_v702_group(biz, br, 'walk_in_till', svc, hold_mon,  50, 20);
  -- Tuesday: same shape as Monday.
  perform pg_temp.zz_v702_group(biz, br, 'referral',     svc, train_tue, 50, 40);
  perform pg_temp.zz_v702_group(biz, br, 'walk_in_till', svc, train_tue, 50, 20);
  perform pg_temp.zz_v702_group(biz, br, 'referral',     svc, hold_tue,  50, 40);
  perform pg_temp.zz_v702_group(biz, br, 'walk_in_till', svc, hold_tue,  50, 20);
  -- Wednesday: referral 6/1 (16.7%), walk 6/5 (83.3%) -- diff -66.7 (REVERSED vs aggregate sign).
  perform pg_temp.zz_v702_group(biz, br, 'referral',     svc, train_wed, 6, 1);
  perform pg_temp.zz_v702_group(biz, br, 'walk_in_till', svc, train_wed, 6, 5);
  perform pg_temp.zz_v702_group(biz, br, 'referral',     svc, hold_wed,  6, 1);
  perform pg_temp.zz_v702_group(biz, br, 'walk_in_till', svc, hold_wed,  6, 5);

  g := public.get_ci_discovery_v1(biz, d_from, d_to);
  if g is null then
    insert into _fail values ('M0','get_ci_discovery_v1 returned no payload');
    return;
  end if;

  -- M1 -- must NOT be in discoveries.
  select d into disc from jsonb_array_elements(g->'discoveries') d
   where d->>'dimension' = 'acquisition_source' and d->>'group' = 'referral';
  if disc is not null then
    insert into _fail values ('M1','the mixed-verdict referral candidate wrongly landed in discoveries');
  end if;

  -- M2 -- must NOT be in unverified.
  select d into disc from jsonb_array_elements(g->'unverified') d
   where d->>'dimension' = 'acquisition_source' and d->>'group' = 'referral';
  if disc is not null then
    insert into _fail values ('M2','the mixed-verdict referral candidate wrongly landed in unverified');
  end if;

  -- M3/M4 -- must be in confounded, verdict='mixed', 3 checked / 1 reversed / 2 consistent.
  select d into disc from jsonb_array_elements(g->'confounded') d
   where d->>'dimension' = 'acquisition_source' and d->>'group' = 'referral';
  if disc is null then
    insert into _fail values ('M3','the mixed-verdict referral candidate is missing from confounded');
  else
    if round((disc->>'diff_pp')::numeric, 1) <> 34.0 then
      insert into _fail values ('M3-diff', format('aggregate diff_pp = %s, expected 34.0', disc->>'diff_pp'));
    end if;
    if (disc->>'replicated')::boolean is distinct from true then
      insert into _fail values ('M3-rep', 'expected replicated=true (train mirrored on holdout)');
    end if;
    conf := disc->'confounders';
    if conf is null then
      insert into _fail values ('M4','confounded entry carries no confounders block');
    else
      if (conf->>'verdict') <> 'mixed' then
        insert into _fail values ('M4-verdict', format('verdict = %s, expected mixed', conf->>'verdict'));
      end if;
      if (conf->>'strata_checked')::int <> 3 then
        insert into _fail values ('M4-checked', format('strata_checked = %s, expected 3', conf->>'strata_checked'));
      end if;
      if (conf->>'strata_reversed')::int <> 1 then
        insert into _fail values ('M4-reversed', format('strata_reversed = %s, expected 1', conf->>'strata_reversed'));
      end if;
      if (conf->>'strata_consistent')::int <> 2 then
        insert into _fail values ('M4-consistent', format('strata_consistent = %s, expected 2', conf->>'strata_consistent'));
      end if;
    end if;
  end if;
end;
$v702m$;

-- ===============================================================================================
-- PART U -- 'unchecked' verdict: every other dimension fails to clear the floor on both sides.
-- ===============================================================================================
do $v702u$
declare
  biz uuid := gen_random_uuid();
  br uuid := gen_random_uuid();
  svc uuid := gen_random_uuid();
  d_to date := current_date - 31;
  d_from date;
  v_train_to date;
  v_holdout_from date;
  train_mon date; hold_mon date;
  g jsonb;
  disc jsonb;
  conf jsonb;
begin
  d_from := d_to - 119;
  v_train_to := d_from + 59;
  v_holdout_from := v_train_to + 1;
  train_mon := d_from + ((1 - extract(isodow from d_from)::int + 7) % 7);
  hold_mon := v_holdout_from + ((1 - extract(isodow from v_holdout_from)::int + 7) % 7);

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v702 unchecked firm', 'zz-v702-unchecked', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v702 unchecked branch', true, true);
  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc, biz, 'ZZ v702 unchecked service', 5000, 30);
  -- deliberately NO service_canonical_map row -- category_node never classifies.

  -- Every client (both groups, both halves) anchored on the SAME single weekday (Monday), so
  -- weekday's one possible stratum is identical to the whole population -- it will always be a
  -- row in the confounder check (dow is never null), but it is INELIGIBLE here because the rest
  -- side (walk_in_till) never clears the floor of 5.
  perform pg_temp.zz_v702_group(biz, br, 'referral',     svc, train_mon, 50, 40);
  perform pg_temp.zz_v702_group(biz, br, 'walk_in_till', svc, train_mon, 4,  0);
  perform pg_temp.zz_v702_group(biz, br, 'referral',     svc, hold_mon,  50, 40);
  perform pg_temp.zz_v702_group(biz, br, 'walk_in_till', svc, hold_mon,  4,  0);

  g := public.get_ci_discovery_v1(biz, d_from, d_to);
  if g is null then
    insert into _fail values ('U0','get_ci_discovery_v1 returned no payload');
    return;
  end if;

  -- U1 -- must NOT be in discoveries.
  select d into disc from jsonb_array_elements(g->'discoveries') d
   where d->>'dimension' = 'acquisition_source' and d->>'group' = 'referral';
  if disc is not null then
    insert into _fail values ('U1','the unchecked referral candidate wrongly landed in discoveries');
  end if;

  -- U2 -- must NOT be in confounded.
  select d into disc from jsonb_array_elements(g->'confounded') d
   where d->>'dimension' = 'acquisition_source' and d->>'group' = 'referral';
  if disc is not null then
    insert into _fail values ('U2','the unchecked referral candidate wrongly landed in confounded');
  end if;

  -- U3 -- must be in unverified, verdict='unchecked', 0 checked, exact disclosure note.
  select d into disc from jsonb_array_elements(g->'unverified') d
   where d->>'dimension' = 'acquisition_source' and d->>'group' = 'referral';
  if disc is null then
    insert into _fail values ('U3','the unchecked referral candidate is missing from unverified');
  else
    if (disc->>'replicated')::boolean is distinct from true then
      insert into _fail values ('U3-rep', 'expected replicated=true (train mirrored on holdout)');
    end if;
    conf := disc->'confounders';
    if conf is null then
      insert into _fail values ('U3-conf','unverified entry carries no confounders block');
    else
      if (conf->>'verdict') <> 'unchecked' then
        insert into _fail values ('U3-verdict', format('verdict = %s, expected unchecked', conf->>'verdict'));
      end if;
      if (conf->>'strata_checked')::int <> 0 then
        insert into _fail values ('U3-checked', format('strata_checked = %s, expected 0', conf->>'strata_checked'));
      end if;
      if (conf->>'note') <> 'no other dimension cleared the floor on both sides; not promoted' then
        insert into _fail values ('U3-note', format('note = %s', conf->>'note'));
      end if;
    end if;
  end if;
end;
$v702u$;

-- ===============================================================================================
-- PART C -- the v691 4-stratum 'consistent' finding still promotes to discoveries (regression).
-- ===============================================================================================
do $v702c$
declare
  biz uuid := gen_random_uuid();
  br uuid := gen_random_uuid();
  node_c text;
  svc uuid := gen_random_uuid();
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

  select n.node_key into node_c from public.taxonomy_nodes n
   where n.version_no = 1 and n.level = 2 order by n.node_key limit 1;
  if node_c is null then
    insert into _fail values ('C0','taxonomy v1 has no level-2 node; fixture cannot run');
    return;
  end if;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v702 consistent firm', 'zz-v702-consistent', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v702 consistent branch', true, true);
  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc, biz, 'ZZ v702 consistent service', 5000, 30);
  insert into public.service_canonical_map
    (business_id, service_id, node_key, version_no, method) values
    (biz, svc, node_c, 1, 'owner_chosen');

  -- ONE shared category (svc's own mapping) and every client given the SAME gender/birth so
  -- age_gender is a single shared value too -- both dimensions equal the aggregate by
  -- construction, per v691's PART D. weekday splits both groups evenly Monday/Tuesday.
  perform pg_temp.zz_v702_group(biz, br, 'referral',     svc, train_mon, 50, 35);
  perform pg_temp.zz_v702_group(biz, br, 'referral',     svc, train_tue, 50, 35);
  perform pg_temp.zz_v702_group(biz, br, 'walk_in_till', svc, train_mon, 50, 20);
  perform pg_temp.zz_v702_group(biz, br, 'walk_in_till', svc, train_tue, 50, 20);
  perform pg_temp.zz_v702_group(biz, br, 'referral',     svc, hold_mon,  50, 35);
  perform pg_temp.zz_v702_group(biz, br, 'referral',     svc, hold_tue,  50, 35);
  perform pg_temp.zz_v702_group(biz, br, 'walk_in_till', svc, hold_mon,  50, 20);
  perform pg_temp.zz_v702_group(biz, br, 'walk_in_till', svc, hold_tue,  50, 20);

  update public.clients set gender = 'female', birth_date = current_date - interval '27 years'
   where business_id = biz;

  g := public.get_ci_discovery_v1(biz, d_from, d_to);
  if g is null then
    insert into _fail values ('C1','get_ci_discovery_v1 returned no payload');
    return;
  end if;

  select d into disc from jsonb_array_elements(g->'discoveries') d
   where d->>'dimension' = 'acquisition_source' and d->>'group' = 'referral';
  if disc is null then
    insert into _fail values ('C2','the genuine 4-stratum-consistent finding is missing from discoveries');
  else
    if round((disc->>'diff_pp')::numeric, 1) <> 30.0 then
      insert into _fail values ('C2-diff', format('aggregate diff_pp = %s, expected 30.0', disc->>'diff_pp'));
    end if;
    conf := disc->'confounders';
    if conf is null then
      insert into _fail values ('C2-conf','discoveries entry carries no confounders block');
    else
      if (conf->>'verdict') <> 'consistent' then
        insert into _fail values ('C2-verdict', format('verdict = %s, expected consistent', conf->>'verdict'));
      end if;
      if (conf->>'strata_checked')::int <> 4 then
        insert into _fail values ('C2-checked', format('strata_checked = %s, expected 4', conf->>'strata_checked'));
      end if;
      if (conf->>'strata_reversed')::int <> 0 then
        insert into _fail values ('C2-reversed', format('strata_reversed = %s, expected 0', conf->>'strata_reversed'));
      end if;
    end if;
  end if;

  select d into disc from jsonb_array_elements(g->'confounded') d
   where d->>'dimension' = 'acquisition_source' and d->>'group' = 'referral';
  if disc is not null then
    insert into _fail values ('C3','the genuine finding was wrongly moved to confounded');
  end if;

  select d into disc from jsonb_array_elements(g->'unverified') d
   where d->>'dimension' = 'acquisition_source' and d->>'group' = 'referral';
  if disc is not null then
    insert into _fail values ('C4','the genuine finding was wrongly moved to unverified');
  end if;

  -- E1-E5 -- the envelope: exclusions must always be present with the five frozen keys, and
  -- 'CAUSAL' must never appear anywhere in the payload (typed-verdict vocabulary is DIRECT_FACT |
  -- ASSOCIATION only, everywhere in this program).
  if g->'exclusions' is null then
    insert into _fail values ('E1','exclusions key is absent from the envelope');
  else
    if not (g->'exclusions' ? 'reversed_sales') then
      insert into _fail values ('E1-a','exclusions.reversed_sales missing');
    end if;
    if not (g->'exclusions' ? 'synthetic_clients') then
      insert into _fail values ('E2','exclusions.synthetic_clients missing');
    end if;
    if not (g->'exclusions' ? 'anonymous_sales') then
      insert into _fail values ('E3','exclusions.anonymous_sales missing');
    end if;
    if not (g->'exclusions' ? 'missing_demographics') then
      insert into _fail values ('E4','exclusions.missing_demographics missing');
    end if;
    if not (g->'exclusions' ? 'overlapping_campaigns') then
      insert into _fail values ('E5','exclusions.overlapping_campaigns missing');
    end if;
  end if;
  if g->>'trace_id' is null then
    insert into _fail values ('E6','trace_id is absent from the envelope');
  end if;
  if g->'period' is null or g->'period'->>'timezone' <> 'Asia/Singapore' then
    insert into _fail values ('E7','period.timezone missing or wrong');
  end if;
  if g::text ilike '%CAUSAL%' then
    insert into _fail values ('E8','the forbidden vocabulary word CAUSAL appears somewhere in the payload');
  end if;
end;
$v702c$;

select case when count(*)=0 then 'PASS — discovery verdict rigor (mixed/unchecked/consistent) + envelope hold'
       else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v702: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
