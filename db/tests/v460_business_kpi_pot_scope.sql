-- Rollback-only acceptance for nestly_v460 — business KPIs count one pot, in one unit.
--   supabase db query --linked -f db/tests/v460_business_kpi_pot_scope.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- Every check CALLS public.get_dashboard_summary_v155 / public.get_reports_summary as a real
-- authenticated owner. No check reads a function's source text.
--
--   01  fixture shape: a tenant with a LIVE points pot and a RETIRED stamps pot, both carrying
--       ledger rows -- the shape that produced the defect
--   02  NEGATIVE CONTROL: against the pre-v460 bodies -- re-installed inside this transaction
--       when the migration IS applied, or simply the deployed bodies when it is not -- both
--       readers must report the WRONG combined figure of 170. Proves 03-08 can detect the defect.
--       Run this suite against an unpatched database and 02 passes while 03-08 fail: that is the
--       defect reproducing itself, and it is the intended pre-apply result.
--   03  the dashboard counts only the live pot
--   04  the retired pot contributes nothing, to any entry type
--   05  stamps never land in a points total, and the unit is named
--   06  a STAMPS tenant reports its stamps, labelled 'stamps' -- not silently added to points
--   07  a tenant with NO accruing programme reports 0, not "everything ever earned"
--   08  the scoping reuses app.live_balance_programme_v381 rather than a second definition
--
-- The fixture numbers deliberately mirror production qa-kopi-lab at the time the defect was
-- found: 159 points on the live pot, 11 stamps on the retired one, 170 when wrongly added.

begin;

create temp table _r(k text, v text) on commit drop;

create or replace function pg_temp.as_v460_user(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end
$$;
grant execute on function pg_temp.as_v460_user(uuid) to public;

-- Un-point / re-point the two readers, so the negative control can put the defect back inside
-- this transaction and take it out again. Restoring re-executes the EXACT definition that was
-- snapshotted before stripping, so the harness cannot drift the functions it is testing.
create temp table _v460_snapshot(proname text primary key, def text) on commit drop;

create or replace function pg_temp.v460_set_scope(p_on boolean) returns void language plpgsql as $$
declare
  v_scope constant text :=
    '        and pl.programme_id = app.live_balance_programme_v381(p_business)' || E'\n';
  v_name text;
  v_src text;
  v_new text;
begin
  foreach v_name in array array['get_dashboard_summary_v155', 'get_reports_summary'] loop
    if p_on then
      select def into v_src from _v460_snapshot where proname = v_name;
      if v_src is null then
        raise exception 'v460 harness: no snapshot to restore for public.%', v_name;
      end if;
      execute v_src;
    else
      select pg_get_functiondef(p.oid) into v_src
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = v_name;
      if v_src is null then
        raise exception 'v460 harness: public.% is missing', v_name;
      end if;
      -- Snapshot first, always: restoring re-executes exactly what was deployed.
      insert into _v460_snapshot(proname, def) values (v_name, v_src)
        on conflict (proname) do update set def = excluded.def;
      -- Before nestly_v460 is applied the deployed body IS the pre-fix body, so there is nothing
      -- to strip. Running this suite against an unpatched database therefore reports the defect
      -- (check 02 sees 170) and then fails checks 03-08 -- which is the negative control, live.
      if position(v_scope in v_src) > 0 then
        v_new := replace(v_src, v_scope, '');
        execute v_new;
      end if;
    end if;
  end loop;
end
$$;
grant execute on function pg_temp.v460_set_scope(boolean) to public;

-- public.points_ledger is guarded: app.loyalty_ledger_write_guard refuses any append that does
-- not name its own row id and one of the eight sanctioned write scopes. The fixture goes through
-- the same door rather than around it.
create or replace function pg_temp.v460_ledger(
  p_biz uuid, p_client uuid, p_programme uuid, p_type text, p_points integer,
  p_sale uuid, p_scope text) returns void language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  perform set_config('app.points_ledger_insert_id', v_id::text, true);
  perform set_config('app.points_ledger_write_scope', p_scope, true);
  insert into public.points_ledger(id, business_id, client_id, programme_id,
                                   entry_type, points, sale_id)
  values (v_id, p_biz, p_client, p_programme, p_type, p_points, p_sale);
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);
end
$$;
grant execute on function pg_temp.v460_ledger(uuid, uuid, uuid, text, integer, uuid, text) to public;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_biz uuid := gen_random_uuid();          -- live points pot + retired stamps pot
  v_stamp_biz uuid := gen_random_uuid();    -- live stamps pot + retired points pot
  v_dark_biz uuid := gen_random_uuid();     -- no accruing programme at all
  v_branch uuid;
  v_stamp_branch uuid;
  v_dark_branch uuid;
  v_client uuid := gen_random_uuid();
  v_stamp_client uuid := gen_random_uuid();
  v_dark_client uuid := gen_random_uuid();
  v_live_pot uuid;
  v_dead_pot uuid;
  v_stamp_live uuid;
  v_stamp_dead uuid;
  v_dash jsonb;
  v_rep jsonb;
  v_txt text;
  v_today date := (now() at time zone 'Asia/Singapore')::date;
  v_sale uuid := gen_random_uuid();
  v_stamp_sale uuid := gen_random_uuid();
  v_dark_sale uuid := gen_random_uuid();

begin
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password,
                         email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_owner, 'authenticated', 'authenticated',
          'v460-owner@example.test', '', now(), now(), now());

  insert into public.businesses(id, name, slug, enabled_modules) values
    (v_biz,       'V460 Points Firm', 'v460p-' || substr(v_biz::text, 1, 8),
     array['till','sales','clients','loyalty','reports','dashboard']),
    (v_stamp_biz, 'V460 Stamps Firm', 'v460s-' || substr(v_stamp_biz::text, 1, 8),
     array['till','sales','clients','loyalty','reports','dashboard']),
    (v_dark_biz,  'V460 No Programme', 'v460n-' || substr(v_dark_biz::text, 1, 8),
     array['till','sales','clients','loyalty','reports','dashboard']);

  insert into public.staff(business_id, user_id, role, full_name, active) values
    (v_biz, v_owner, 'owner', 'V460 Owner', true),
    (v_stamp_biz, v_owner, 'owner', 'V460 Owner', true),
    (v_dark_biz, v_owner, 'owner', 'V460 Owner', true);

  insert into public.business_workspace_controls_v94(
    business_id, approval_status, decided_by, decided_at, decision_reason)
  values (v_biz, 'approved', v_owner, now(), 'v460 fixture'),
         (v_stamp_biz, 'approved', v_owner, now(), 'v460 fixture'),
         (v_dark_biz, 'approved', v_owner, now(), 'v460 fixture')
  on conflict (business_id) do update
    set approval_status = 'approved', decided_by = excluded.decided_by,
        decided_at = excluded.decided_at, decision_reason = excluded.decision_reason;
  insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused)
  values (v_biz, false), (v_stamp_biz, false), (v_dark_biz, false)
  on conflict (business_id) do update set workspace_paused = false;

  -- A plain businesses INSERT seeds the programme spine but no branch, so the reporting scope
  -- needs one explicitly; without it get_dashboard_summary_v155 raises
  -- operational_branch_required_for_current_scope and every assertion below would be untested.
  v_branch := gen_random_uuid(); v_stamp_branch := gen_random_uuid(); v_dark_branch := gen_random_uuid();
  insert into public.branches(id, business_id, name) values
    (v_branch, v_biz, 'V460 Main'),
    (v_stamp_branch, v_stamp_biz, 'V460 Stamp Main'),
    (v_dark_branch, v_dark_biz, 'V460 Dark Main');

  insert into public.clients(id, business_id, full_name) values
    (v_client, v_biz, 'V460 Customer'),
    (v_stamp_client, v_stamp_biz, 'V460 Stamp Customer'),
    (v_dark_client, v_dark_biz, 'V460 Dark Customer');

  -- Spine: exactly the qa-kopi-lab shape. business_programmes rows are seeded by trigger on the
  -- businesses insert, so these are UPDATEs of the seeded rows rather than fresh inserts.
  update public.business_programmes set active = true  where business_id = v_biz and kind = 'points';
  update public.business_programmes set active = false where business_id = v_biz and kind = 'stamps';
  update public.business_programmes set active = true  where business_id = v_stamp_biz and kind = 'stamps';
  update public.business_programmes set active = false where business_id = v_stamp_biz and kind = 'points';
  update public.business_programmes set active = false where business_id = v_dark_biz and kind in ('points','stamps');

  select id into v_live_pot  from public.business_programmes where business_id = v_biz and kind = 'points';
  select id into v_dead_pot  from public.business_programmes where business_id = v_biz and kind = 'stamps';
  select id into v_stamp_live from public.business_programmes where business_id = v_stamp_biz and kind = 'stamps';
  select id into v_stamp_dead from public.business_programmes where business_id = v_stamp_biz and kind = 'points';

  ---------------------------------------------------------------------- 1 - fixture shape
  insert into _r values('01_fixture_two_pots',
    case when v_live_pot is not null and v_dead_pot is not null and v_live_pot <> v_dead_pot
      then 'PASS live points pot and retired stamps pot both exist'
      else 'FAIL the fixture does not have two distinct pots' end);
  insert into _r values('01_helper_picks_the_live_pot',
    case when app.live_balance_programme_v381(v_biz) = v_live_pot
      then 'PASS app.live_balance_programme_v381 returns the live points pot'
      else 'FAIL the helper returned '
           || coalesce(app.live_balance_programme_v381(v_biz)::text, 'null') end);
  insert into _r values('01_helper_picks_stamps_when_stamps_run',
    case when app.live_balance_programme_v381(v_stamp_biz) = v_stamp_live
      then 'PASS the helper returns the stamps pot for a stamps tenant'
      else 'FAIL the helper returned '
           || coalesce(app.live_balance_programme_v381(v_stamp_biz)::text, 'null') end);
  insert into _r values('01_helper_is_null_without_a_programme',
    case when app.live_balance_programme_v381(v_dark_biz) is null
      then 'PASS the helper returns NULL when no accruing programme runs'
      else 'FAIL the helper invented a pot for a firm with none' end);

  -- Ledger rows. The dashboard joins points_ledger to sales on sale_id and requires the sale's
  -- branch to be in scope, so every earn row needs a real sale behind it.
  insert into public.sales(id, business_id, client_id, branch_id, kind, amount_cents, occurred_at)
  values (v_sale, v_biz, v_client, v_branch, 'quick_sale', 100, now()),
         (v_stamp_sale, v_stamp_biz, v_stamp_client, v_stamp_branch, 'quick_sale', 100, now()),
         (v_dark_sale, v_dark_biz, v_dark_client, v_dark_branch, 'quick_sale', 100, now());

  -- Tenant A: 159 on the LIVE points pot, 11 on the RETIRED stamps pot. 170 if wrongly added.
  perform pg_temp.v460_ledger(v_biz, v_client, v_live_pot, 'earn',   159, v_sale, 'sale_trigger');
  perform pg_temp.v460_ledger(v_biz, v_client, v_dead_pot, 'earn',    11, v_sale, 'sale_trigger');
  -- non-earn rows on both pots, so the reports breakdown is exercised too
  perform pg_temp.v460_ledger(v_biz, v_client, v_live_pot, 'expire', -15, null, 'points_expiry');
  perform pg_temp.v460_ledger(v_biz, v_client, v_live_pot, 'adjust', -28, null, 'programme_pot_transfer');
  perform pg_temp.v460_ledger(v_biz, v_client, v_dead_pot, 'adjust',   4, null, 'programme_pot_transfer');

  -- Tenant B: the Cubbly shape. 16 on the LIVE stamps pot, 78,292 on the RETIRED points pot.
  perform pg_temp.v460_ledger(v_stamp_biz, v_stamp_client, v_stamp_live, 'earn',    16, v_stamp_sale, 'sale_trigger');
  perform pg_temp.v460_ledger(v_stamp_biz, v_stamp_client, v_stamp_dead, 'earn', 78292, v_stamp_sale, 'sale_trigger');

  -- Tenant C: no accruing programme at all, but a switched-off pot still holding 4,242.
  perform pg_temp.v460_ledger(v_dark_biz, v_dark_client,
    (select bp.id from public.business_programmes bp
      where bp.business_id = v_dark_biz and bp.kind = 'points'),
    'earn', 4242, v_dark_sale, 'sale_trigger');

  ------------------------------------------------------------------ 2 - negative control
  perform pg_temp.v460_set_scope(false);
  perform pg_temp.as_v460_user(v_owner);
  v_dash := to_jsonb(public.get_dashboard_summary_v155(v_biz, v_today, v_today, 'all', null, v_branch));
  v_rep  := to_jsonb(public.get_reports_summary(v_biz, v_today, v_today, null));
  reset role;
  insert into _r values('02_unscoped_dashboard_is_wrong',
    case when (v_dash->>'points_issued')::int = 170
      then 'PASS the pre-v460 body reproduces the defect: points_issued=170 (159 points + 11 stamps)'
      else 'FAIL expected the unscoped body to report 170, got '
           || coalesce(v_dash->>'points_issued', 'null') end);
  insert into _r values('02_unscoped_reports_is_wrong',
    case when (v_rep#>>'{points_by_type,earn}')::int = 170
      then 'PASS the pre-v460 body reproduces the defect: earn=170'
      else 'FAIL expected the unscoped body to report earn=170, got '
           || coalesce(v_rep#>>'{points_by_type,earn}', 'null') end);
  perform pg_temp.v460_set_scope(true);

  ------------------------------------------------- 3 - the dashboard counts one pot only
  perform pg_temp.as_v460_user(v_owner);
  begin
    v_dash := to_jsonb(public.get_dashboard_summary_v155(v_biz, v_today, v_today, 'all', null, v_branch));
    v_txt := null;
  exception when others then
    v_txt := sqlstate || ' ' || sqlerrm; v_dash := null;
  end;
  reset role;
  insert into _r values('03_dashboard_call',
    case when v_txt is not null then 'FAIL the dashboard raised ' || v_txt else 'PASS' end);
  insert into _r values('03_dashboard_counts_live_pot_only',
    case when (v_dash->>'points_issued')::int = 159
      then 'PASS points_issued=159 (the live pot), not 170'
      when (v_dash->>'points_issued')::int = 170
      then 'FAIL points_issued=170; the retired stamps pot is still being added in'
      else 'FAIL points_issued=' || coalesce(v_dash->>'points_issued', 'null') || ', expected 159' end);

  ------------------------------------------------- 4 - the retired pot contributes nothing
  perform pg_temp.as_v460_user(v_owner);
  v_rep := to_jsonb(public.get_reports_summary(v_biz, v_today, v_today, null));
  reset role;
  insert into _r values('04_reports_earn_scoped',
    case when (v_rep#>>'{points_by_type,earn}')::int = 159
      then 'PASS earn=159' else 'FAIL earn=' || coalesce(v_rep#>>'{points_by_type,earn}', 'null') end);
  insert into _r values('04_reports_adjust_scoped',
    case when (v_rep#>>'{points_by_type,adjust}')::int = -28
      then 'PASS adjust=-28 (the retired pot''s +4 is excluded)'
      when (v_rep#>>'{points_by_type,adjust}')::int = -24
      then 'FAIL adjust=-24; the retired pot is still being added in'
      else 'FAIL adjust=' || coalesce(v_rep#>>'{points_by_type,adjust}', 'null') end);
  insert into _r values('04_reports_expire_scoped',
    case when (v_rep#>>'{points_by_type,expire}')::int = -15
      then 'PASS expire=-15' else 'FAIL expire=' || coalesce(v_rep#>>'{points_by_type,expire}', 'null') end);

  ---------------------------------------- 5 - stamps never land in a points total, and the
  --                                            payload says which unit the figure is in
  insert into _r values('05_no_stamps_in_a_points_total',
    case when (v_dash->>'points_issued')::int + 11 = 170
              and (v_dash->>'points_issued')::int <> 170
      then 'PASS the 11 stamps on the retired pot are excluded from the points figure'
      else 'FAIL the arithmetic does not separate the two units' end);
  insert into _r values('05_dashboard_names_its_unit',
    case when v_dash->>'loyalty_unit' = 'points'
      then 'PASS dashboard loyalty_unit=points'
      else 'FAIL dashboard loyalty_unit=' || coalesce(v_dash->>'loyalty_unit', 'null') end);
  insert into _r values('05_reports_names_its_unit',
    case when v_rep->>'loyalty_unit' = 'points'
      then 'PASS reports loyalty_unit=points'
      else 'FAIL reports loyalty_unit=' || coalesce(v_rep->>'loyalty_unit', 'null') end);

  ------------------------------------------------------------------ 6 - a stamps tenant
  perform pg_temp.as_v460_user(v_owner);
  v_dash := to_jsonb(public.get_dashboard_summary_v155(v_stamp_biz, v_today, v_today, 'all', null, v_stamp_branch));
  v_rep  := to_jsonb(public.get_reports_summary(v_stamp_biz, v_today, v_today, null));
  reset role;
  insert into _r values('06_stamps_tenant_reports_its_stamps',
    case when (v_dash->>'points_issued')::int = 16
      then 'PASS the stamps tenant reports 16, its live stamp pot'
      when (v_dash->>'points_issued')::int = 78308
      then 'FAIL 78308; the retired points pot is still being added to the stamp count'
      else 'FAIL got ' || coalesce(v_dash->>'points_issued', 'null') || ', expected 16' end);
  insert into _r values('06_stamps_tenant_is_labelled_stamps',
    case when v_dash->>'loyalty_unit' = 'stamps' and v_rep->>'loyalty_unit' = 'stamps'
      then 'PASS both payloads report loyalty_unit=stamps, so the figure can be labelled correctly'
      else 'FAIL dashboard=' || coalesce(v_dash->>'loyalty_unit', 'null')
           || ' reports=' || coalesce(v_rep->>'loyalty_unit', 'null') end);
  insert into _r values('06_stamps_tenant_reports_breakdown',
    case when (v_rep#>>'{points_by_type,earn}')::int = 16
      then 'PASS the reports breakdown is 16 too'
      else 'FAIL earn=' || coalesce(v_rep#>>'{points_by_type,earn}', 'null') end);

  ------------------------------------------------- 7 - a tenant with no accruing programme
  perform pg_temp.as_v460_user(v_owner);
  v_dash := to_jsonb(public.get_dashboard_summary_v155(v_dark_biz, v_today, v_today, 'all', null, v_dark_branch));
  v_rep  := to_jsonb(public.get_reports_summary(v_dark_biz, v_today, v_today, null));
  reset role;
  insert into _r values('07_no_programme_reports_zero',
    case when (v_dash->>'points_issued')::int = 0
      then 'PASS 0, not the 4242 sitting on the switched-off pot'
      when (v_dash->>'points_issued')::int = 4242
      then 'FAIL 4242; a firm with no running programme is still being shown a retired pot'
      else 'FAIL got ' || coalesce(v_dash->>'points_issued', 'null') || ', expected 0' end);
  insert into _r values('07_no_programme_has_no_unit',
    case when v_dash->>'loyalty_unit' is null
      then 'PASS loyalty_unit is null when nothing is running'
      else 'FAIL loyalty_unit=' || (v_dash->>'loyalty_unit') end);
  insert into _r values('07_no_programme_reports_empty_breakdown',
    case when coalesce(v_rep#>>'{points_by_type,earn}', '0')::int = 0
      then 'PASS the reports breakdown is empty'
      else 'FAIL earn=' || (v_rep#>>'{points_by_type,earn}') end);
end
$$;

-- 8 - one definition of "which pot counts", not two.
do $$
declare v_dash_uses boolean; v_rep_uses boolean; v_callers int;
begin
  select position('app.live_balance_programme_v381' in pg_get_functiondef(p.oid)) > 0
    into v_dash_uses
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_dashboard_summary_v155';
  select position('app.live_balance_programme_v381' in pg_get_functiondef(p.oid)) > 0
    into v_rep_uses
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_reports_summary';
  select count(*) into v_callers
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app','public') and p.prokind = 'f'
     and p.proname <> 'live_balance_programme_v381'
     and pg_get_functiondef(p.oid) like '%live_balance_programme_v381%';

  insert into _r values('08_both_readers_use_the_shared_helper',
    case when v_dash_uses and v_rep_uses
      then 'PASS both readers call app.live_balance_programme_v381'
      else 'FAIL dashboard=' || v_dash_uses || ' reports=' || v_rep_uses end);
  insert into _r values('08_helper_is_the_single_definition',
    case when v_callers >= 6
      then 'PASS ' || v_callers || ' readers now share the one pot definition'
      else 'FAIL only ' || v_callers || ' callers; the two new ones did not join the others' end);
end
$$;

select k, v from _r order by k;

rollback;
