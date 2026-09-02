-- EXECUTED regression fixture for nestly_v708 -- check 68 refutation fix #3 (exact-tie strata,
-- stratum_sign = 0, no longer count as silent agreement inside get_ci_discovery_v1's confounder
-- verdict). Above the v422 watermark: n/a in the baseline phase (discovery-scan tables/functions
-- do not exist before it), gated on the migrated run.
--
-- PART T -- 'tied' verdict (2 of 3 checked strata are EXACT TIES, 1 agrees). Single-branch
--   business ("biz_tied"). Candidate dimension acquisition_source, group 'referral' vs
--   'walk_in_till'. age_gender/category_node are made structurally unclassifiable for every
--   client (no gender/birth_date set, and the group's service carries no service_canonical_map
--   row), so the ONLY other dimension that can ever furnish a checked stratum is weekday, split
--   across three weekdays:
--     Monday:    referral n=50 returned=40 (80.0%); walk_in_till n=50 returned=20 (40.0%)  diff +40.0 (CONSISTENT)
--     Tuesday:   referral n=50 returned=25 (50.0%); walk_in_till n=50 returned=25 (50.0%)  diff   0.0 (EXACT TIE)
--     Wednesday: referral n=50 returned=25 (50.0%); walk_in_till n=50 returned=25 (50.0%)  diff   0.0 (EXACT TIE)
--   AGGREGATE (train, mirrored on holdout): referral n=150 returned=90 -> 60.0%;
--   walk_in_till n=150 returned=70 -> 46.7%; diff_pp = 13.3 (>=10, comfortably clears BH/CI).
--   3 checked strata (each clears the floor of 5 on both sides): 1 consistent (Monday),
--   0 reversed, 2 exact ties (Tuesday, Wednesday). Pre-v708, strata_reversed = 0 alone promoted
--   this to 'consistent' ("sign holds across all 3 checked strata" -- false: it held in exactly
--   1 of those 3). Post-v708, 'consistent' requires strata_consistent = strata_checked, which
--   1 = 3 fails -> verdict = 'tied'. MUST NOT appear in 'discoveries' or 'confounded', MUST land
--   in 'unverified' with the exact disclosure note and strata_tied = 2.
--
-- PART S -- 'consistent' verdict, 3 checked strata, ALL consistent, ZERO ties (regression check:
--   a genuine no-tie finding still promotes after this migration). Single-branch business
--   ("biz_3consistent"), one shared category for every client (category_node furnishes exactly
--   one checked stratum, identical to the aggregate by construction, same as v691/v702's
--   established pattern) with age_gender left unclassifiable (no gender/birth_date), plus weekday
--   split Monday/Tuesday (two more checked strata):
--     Monday:  referral n=50 returned=35 (70.0%); walk_in_till n=50 returned=20 (40.0%) diff +30.0
--     Tuesday: referral n=50 returned=35 (70.0%); walk_in_till n=50 returned=20 (40.0%) diff +30.0
--     category_node (whole population, one shared value): diff +30.0 (matches aggregate exactly)
--   THREE checked strata, all matching sign, ZERO reversed, ZERO ties -> verdict='consistent'.
--   MUST land in 'discoveries' (replicated=true) with strata_consistent = strata_checked = 3 and
--   the exact "sign holds in 3 of 3 checked strata (no ties)" note, MUST NOT appear in
--   'confounded' or 'unverified'.
--
-- MUTATION CHECK (documented, not executed as code -- public.sales/functions are the artifact
-- under test, not a second copy of this migration to mutate in place):
--   (a) Reverting confound_final's verdict CASE to its pre-v708 shape (dropping the
--       `strata_consistent = strata_checked` requirement, i.e. `when strata_reversed = 0 then
--       'consistent'`) would move PART T's finding from 'tied'/'unverified' back into
--       'consistent'/'discoveries', turning T1 (must not be in discoveries) and T4 (verdict) red.
--   (b) Reverting the 'unverified' list membership test back to `confound_verdict = 'unchecked'`
--       only (dropping 'tied' from the `in (...)` list) while keeping fix (a) would make PART T's
--       finding vanish from every list (correctly excluded from 'discoveries'/'confounded', but
--       silently absent from 'unverified' too) -- turning T3 (must be in unverified) red on its
--       own, independent of (a).
--   (c) Reverting the 'note' case's 'consistent' branch to the pre-v708 wording
--       ('sign holds across all %s checked strata', strata_checked) would turn S2-note red (exact
--       text match) without affecting membership -- catches a wording-only regression fix (a)/(b)
--       would not.
--   One flip in any of (a)/(b)/(c) is sufficient to turn this fixture red.
--
-- Reuses v702's own `pg_temp.zz_v702_group` fixture-building convention (a shared helper of the
-- same shape, redeclared here as zz_v708_group with the identical parameters for nullable
-- gender/birth_date, since PART T/S deliberately need age_gender and category_node to be
-- unclassifiable-by-default so weekday is the only free-running confounder dimension).

\set ON_ERROR_STOP on
begin;
create temp table _fail(k text, v text) on commit drop;

-- ===============================================================================================
-- Shared helper: build one (business, branch, acquisition, weekday) group of clients with an
-- anchor sale on p_anchor and, for the first p_returned of them, a follow-up sale 5 days later.
-- gender/birth_date are left NULL by every caller in this fixture (age_gender must never
-- classify), and the service passed in (p_service) deliberately carries NO
-- service_canonical_map row anywhere in this fixture unless the caller adds one separately
-- (category_node must never classify either, except in PART S where it is added deliberately).
-- ===============================================================================================
create or replace function pg_temp.zz_v708_group(
  p_biz uuid, p_branch uuid, p_acquisition text, p_service uuid, p_anchor date,
  p_n integer, p_returned integer)
returns uuid[] language plpgsql as $fn$
declare
  v_ids uuid[];
begin
  perform set_config('app.first_acquired_via', p_acquisition, true);
  with ins as (
    insert into public.clients (business_id, full_name)
    select p_biz, 'ZZ v708 ' || p_acquisition || ' ' || p_anchor::text || ' ' || gs
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

do $v708setup$
declare
  u_sa uuid := '00000000-0000-4000-8000-000000708eee';
begin
  insert into auth.users (id, email) values (u_sa, 'zz-v708-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v708-sa@example.test')
    on conflict do nothing;
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
end;
$v708setup$;

-- ===============================================================================================
-- PART T -- 'tied' verdict: 1 of 3 checked strata (weekday) consistent, 2 are exact ties.
-- ===============================================================================================
do $v708t$
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
    (biz, 'ZZ v708 tied firm', 'zz-v708-tied', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v708 tied branch', true, true);
  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc, biz, 'ZZ v708 tied service', 5000, 30);
  -- deliberately NO service_canonical_map row -- category_node never classifies.

  -- Monday: referral 50/40 (80%), walk 50/20 (40%) -- diff +40 (consistent with aggregate sign).
  perform pg_temp.zz_v708_group(biz, br, 'referral',     svc, train_mon, 50, 40);
  perform pg_temp.zz_v708_group(biz, br, 'walk_in_till', svc, train_mon, 50, 20);
  perform pg_temp.zz_v708_group(biz, br, 'referral',     svc, hold_mon,  50, 40);
  perform pg_temp.zz_v708_group(biz, br, 'walk_in_till', svc, hold_mon,  50, 20);
  -- Tuesday: referral 50/25 (50%), walk 50/25 (50%) -- EXACT TIE (diff 0.0).
  perform pg_temp.zz_v708_group(biz, br, 'referral',     svc, train_tue, 50, 25);
  perform pg_temp.zz_v708_group(biz, br, 'walk_in_till', svc, train_tue, 50, 25);
  perform pg_temp.zz_v708_group(biz, br, 'referral',     svc, hold_tue,  50, 25);
  perform pg_temp.zz_v708_group(biz, br, 'walk_in_till', svc, hold_tue,  50, 25);
  -- Wednesday: same tie shape as Tuesday.
  perform pg_temp.zz_v708_group(biz, br, 'referral',     svc, train_wed, 50, 25);
  perform pg_temp.zz_v708_group(biz, br, 'walk_in_till', svc, train_wed, 50, 25);
  perform pg_temp.zz_v708_group(biz, br, 'referral',     svc, hold_wed,  50, 25);
  perform pg_temp.zz_v708_group(biz, br, 'walk_in_till', svc, hold_wed,  50, 25);

  g := public.get_ci_discovery_v1(biz, d_from, d_to);
  if g is null then
    insert into _fail values ('T0','get_ci_discovery_v1 returned no payload');
    return;
  end if;

  -- T1 -- must NOT be in discoveries.
  select d into disc from jsonb_array_elements(g->'discoveries') d
   where d->>'dimension' = 'acquisition_source' and d->>'group' = 'referral';
  if disc is not null then
    insert into _fail values ('T1','the tied-verdict referral candidate wrongly landed in discoveries');
  end if;

  -- T2 -- must NOT be in confounded.
  select d into disc from jsonb_array_elements(g->'confounded') d
   where d->>'dimension' = 'acquisition_source' and d->>'group' = 'referral';
  if disc is not null then
    insert into _fail values ('T2','the tied-verdict referral candidate wrongly landed in confounded');
  end if;

  -- T3/T4 -- must be in unverified, verdict='tied', 3 checked / 1 consistent / 0 reversed / 2 tied.
  select d into disc from jsonb_array_elements(g->'unverified') d
   where d->>'dimension' = 'acquisition_source' and d->>'group' = 'referral';
  if disc is null then
    insert into _fail values ('T3','the tied-verdict referral candidate is missing from unverified');
  else
    if round((disc->>'diff_pp')::numeric, 1) <> 13.3 then
      insert into _fail values ('T3-diff', format('aggregate diff_pp = %s, expected 13.3', disc->>'diff_pp'));
    end if;
    if (disc->>'replicated')::boolean is distinct from true then
      insert into _fail values ('T3-rep', 'expected replicated=true (train mirrored on holdout)');
    end if;
    conf := disc->'confounders';
    if conf is null then
      insert into _fail values ('T4','unverified entry carries no confounders block');
    else
      if (conf->>'verdict') <> 'tied' then
        insert into _fail values ('T4-verdict', format('verdict = %s, expected tied', conf->>'verdict'));
      end if;
      if (conf->>'strata_checked')::int <> 3 then
        insert into _fail values ('T4-checked', format('strata_checked = %s, expected 3', conf->>'strata_checked'));
      end if;
      if (conf->>'strata_consistent')::int <> 1 then
        insert into _fail values ('T4-consistent', format('strata_consistent = %s, expected 1', conf->>'strata_consistent'));
      end if;
      if (conf->>'strata_reversed')::int <> 0 then
        insert into _fail values ('T4-reversed', format('strata_reversed = %s, expected 0', conf->>'strata_reversed'));
      end if;
      if (conf->>'strata_tied')::int <> 2 then
        insert into _fail values ('T4-tied', format('strata_tied = %s, expected 2', conf->>'strata_tied'));
      end if;
      if (conf->>'note') <> '2 of 3 checked strata showed no difference; not promoted' then
        insert into _fail values ('T4-note', format('note = %s', conf->>'note'));
      end if;
    end if;
  end if;
end;
$v708t$;

-- ===============================================================================================
-- PART S -- 'consistent' verdict: 3 checked strata, all consistent, zero ties (regression).
-- ===============================================================================================
do $v708s$
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
    insert into _fail values ('S0','taxonomy v1 has no level-2 node; fixture cannot run');
    return;
  end if;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v708 3-consistent firm', 'zz-v708-3consistent', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v708 3-consistent branch', true, true);
  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc, biz, 'ZZ v708 3-consistent service', 5000, 30);
  insert into public.service_canonical_map
    (business_id, service_id, node_key, version_no, method) values
    (biz, svc, node_c, 1, 'owner_chosen');

  -- ONE shared category (svc's own mapping) equals the aggregate by construction (v691/v702's
  -- established pattern); age_gender is left unclassifiable (no gender/birth_date). weekday
  -- splits both groups evenly Monday/Tuesday -- three checked strata total, none tied.
  perform pg_temp.zz_v708_group(biz, br, 'referral',     svc, train_mon, 50, 35);
  perform pg_temp.zz_v708_group(biz, br, 'referral',     svc, train_tue, 50, 35);
  perform pg_temp.zz_v708_group(biz, br, 'walk_in_till', svc, train_mon, 50, 20);
  perform pg_temp.zz_v708_group(biz, br, 'walk_in_till', svc, train_tue, 50, 20);
  perform pg_temp.zz_v708_group(biz, br, 'referral',     svc, hold_mon,  50, 35);
  perform pg_temp.zz_v708_group(biz, br, 'referral',     svc, hold_tue,  50, 35);
  perform pg_temp.zz_v708_group(biz, br, 'walk_in_till', svc, hold_mon,  50, 20);
  perform pg_temp.zz_v708_group(biz, br, 'walk_in_till', svc, hold_tue,  50, 20);

  g := public.get_ci_discovery_v1(biz, d_from, d_to);
  if g is null then
    insert into _fail values ('S1','get_ci_discovery_v1 returned no payload');
    return;
  end if;

  select d into disc from jsonb_array_elements(g->'discoveries') d
   where d->>'dimension' = 'acquisition_source' and d->>'group' = 'referral';
  if disc is null then
    insert into _fail values ('S2','the genuine 3-stratum-consistent finding is missing from discoveries');
  else
    if round((disc->>'diff_pp')::numeric, 1) <> 30.0 then
      insert into _fail values ('S2-diff', format('aggregate diff_pp = %s, expected 30.0', disc->>'diff_pp'));
    end if;
    conf := disc->'confounders';
    if conf is null then
      insert into _fail values ('S2-conf','discoveries entry carries no confounders block');
    else
      if (conf->>'verdict') <> 'consistent' then
        insert into _fail values ('S2-verdict', format('verdict = %s, expected consistent', conf->>'verdict'));
      end if;
      if (conf->>'strata_checked')::int <> 3 then
        insert into _fail values ('S2-checked', format('strata_checked = %s, expected 3', conf->>'strata_checked'));
      end if;
      if (conf->>'strata_consistent')::int <> 3 then
        insert into _fail values ('S2-consistent', format('strata_consistent = %s, expected 3', conf->>'strata_consistent'));
      end if;
      if (conf->>'strata_reversed')::int <> 0 then
        insert into _fail values ('S2-reversed', format('strata_reversed = %s, expected 0', conf->>'strata_reversed'));
      end if;
      if (conf->>'strata_tied')::int <> 0 then
        insert into _fail values ('S2-tied', format('strata_tied = %s, expected 0', conf->>'strata_tied'));
      end if;
      if (conf->>'note') <> 'sign holds in 3 of 3 checked strata (no ties)' then
        insert into _fail values ('S2-note', format('note = %s', conf->>'note'));
      end if;
    end if;
  end if;

  select d into disc from jsonb_array_elements(g->'confounded') d
   where d->>'dimension' = 'acquisition_source' and d->>'group' = 'referral';
  if disc is not null then
    insert into _fail values ('S3','the genuine finding was wrongly moved to confounded');
  end if;

  select d into disc from jsonb_array_elements(g->'unverified') d
   where d->>'dimension' = 'acquisition_source' and d->>'group' = 'referral';
  if disc is not null then
    insert into _fail values ('S4','the genuine finding was wrongly moved to unverified');
  end if;
end;
$v708s$;

select case when count(*)=0 then 'PASS — discovery tie-strata verdict (tied vs 3-consistent)'
       else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v708: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
