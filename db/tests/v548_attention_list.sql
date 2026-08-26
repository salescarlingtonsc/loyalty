-- Rollback-only acceptance for nestly_v548 — the attention list judges each customer by their own rhythm.
--   supabase db query --linked -f db/tests/v548_attention_list.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- Every check EXECUTES public.get_attention_list_v548. The fixture is production tenant
-- qa-kaya-toast; every client and sale this suite inserts is rolled back, and summary
-- assertions are DELTAS against a baseline call made before the fixtures exist, so the
-- suite keeps meaning something as that tenant's real data changes.
--
-- Fixture clients (visits are `service` sales of $20.00, offsets from now()):
--   A  "V548 Rhythm Regular"  visits -165,-135,-105,-75,-45  cadence 30, lapse 45  -> overdue  (45 = ceil(30*1.5)); monthly 2000
--   B  "V548 Just Due"        visits -95,-64,-33             cadence 31, lapse 33  -> due      (33 >= 31, < 47);    monthly 1935
--   C  "V548 Fast Fader"      visits -94,-87,-80             cadence 7,  lapse 80  -> slipping (80 >= ceil(17.5)); monthly 8571
--   D  "V548 One Timer"       one visit -60                                        -> one_time_count only, never a row
--   E  "V548 Still Fresh"     visits -70,-40,-10             cadence 30, lapse 10  -> no status (10 < 30); considered only
--   F  "V548 Synthetic Ghost" same shape as A but is_synthetic = true              -> appears NOWHERE (rows, counts, one_time)
--   G  "V548 Reversed Away"   visits -105,-75,-45 with the -45 sale REVERSED       -> 2 valid visits, insufficient history, absent
--
--   01  baseline call succeeds as the owner (shape sanity: summary + rows keys)
--   02  A is overdue with cadence 30.0, lapse 45, monthly 2000
--   03  B is due; C is slipping with monthly 8571 (the 7-day floor did not eat the fast cadence)
--   04  summary deltas: due +1, overdue +1, slipping +1, considered +4, at-risk +10571, one_time +1
--   05  D, E, F, G are not rows; F contributed to NO count; G proves reversal discounting
--   06  ordering: slipping/overdue before due; within them, monthly value decides (C before A before B)
--   07  the row cap is honest: p_limit=1 returns 1 row and unchanged summary counts
--   08  branch scoping: a random branch uuid sees none of the fixture clients
--   09  an authenticated stranger gets 42501, and anon holds no EXECUTE at all

begin;

create temp table _r(k text, v text) on commit drop;
create temp table _fx(label text primary key, client_id uuid) on commit drop;
create temp table _base(payload jsonb) on commit drop;

create or replace function pg_temp.as_v548_user(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end
$$;
grant execute on function pg_temp.as_v548_user(uuid) to public;

create or replace function pg_temp.v548_owner() returns uuid language sql as $$
  select st.user_id from public.staff st
  where st.business_id = '38b30e6d-de73-4c2b-a2ca-19b08950896c'
    and st.role = 'owner' and st.user_id is not null
  order by st.created_at limit 1
$$;

create or replace function pg_temp.v548_row(p jsonb, p_label text) returns jsonb language sql as $$
  select r from jsonb_array_elements(p->'rows') r
  join _fx f on f.label = p_label
  where (r->>'client_id')::uuid = f.client_id
$$;

-- ---------------------------------------------------------------------------------------------
-- 01  baseline as the owner, BEFORE any fixture exists
-- ---------------------------------------------------------------------------------------------
do $$
declare b uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c'; p jsonb;
begin
  perform pg_temp.as_v548_user(pg_temp.v548_owner());
  p := public.get_attention_list_v548(b, null, 50);
  execute 'reset role';
  insert into _base values (p);
  insert into _r values ('01_baseline',
    case when p ? 'summary' and p ? 'rows'
           and (p->'summary') ?& array['due','overdue','slipping','considered','monthly_at_risk_cents','one_time_count']
      then 'PASS baseline summary=' || (p->'summary')::text
      else 'FAIL shape: ' || coalesce(p::text, 'null') end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- fixtures (as postgres; policy triggers fill the sale policy columns as in v494)
-- ---------------------------------------------------------------------------------------------
do $$
declare
  b uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  v_id uuid; v_sale uuid; v_off integer;
begin
  execute 'reset role';

  insert into public.clients(business_id, full_name, phone, is_synthetic)
    values (b, 'V548 Rhythm Regular', '90004801', false) returning id into v_id;
  insert into _fx values ('A', v_id);
  foreach v_off in array array[165,135,105,75,45] loop
    insert into public.sales(business_id, client_id, kind, amount_cents, counts_as_visit, earns_points, occurred_at)
      values (b, v_id, 'service', 2000, true, false, now() - make_interval(days => v_off));
  end loop;

  insert into public.clients(business_id, full_name, phone, is_synthetic)
    values (b, 'V548 Just Due', '90004802', false) returning id into v_id;
  insert into _fx values ('B', v_id);
  foreach v_off in array array[95,64,33] loop
    insert into public.sales(business_id, client_id, kind, amount_cents, counts_as_visit, earns_points, occurred_at)
      values (b, v_id, 'service', 2000, true, false, now() - make_interval(days => v_off));
  end loop;

  insert into public.clients(business_id, full_name, phone, is_synthetic)
    values (b, 'V548 Fast Fader', '90004803', false) returning id into v_id;
  insert into _fx values ('C', v_id);
  foreach v_off in array array[94,87,80] loop
    insert into public.sales(business_id, client_id, kind, amount_cents, counts_as_visit, earns_points, occurred_at)
      values (b, v_id, 'service', 2000, true, false, now() - make_interval(days => v_off));
  end loop;

  insert into public.clients(business_id, full_name, phone, is_synthetic)
    values (b, 'V548 One Timer', '90004804', false) returning id into v_id;
  insert into _fx values ('D', v_id);
  insert into public.sales(business_id, client_id, kind, amount_cents, counts_as_visit, earns_points, occurred_at)
    values (b, v_id, 'service', 2000, true, false, now() - make_interval(days => 60));

  insert into public.clients(business_id, full_name, phone, is_synthetic)
    values (b, 'V548 Still Fresh', '90004805', false) returning id into v_id;
  insert into _fx values ('E', v_id);
  foreach v_off in array array[70,40,10] loop
    insert into public.sales(business_id, client_id, kind, amount_cents, counts_as_visit, earns_points, occurred_at)
      values (b, v_id, 'service', 2000, true, false, now() - make_interval(days => v_off));
  end loop;

  insert into public.clients(business_id, full_name, phone, is_synthetic)
    values (b, 'V548 Synthetic Ghost', '90004806', true) returning id into v_id;
  insert into _fx values ('F', v_id);
  foreach v_off in array array[165,135,105,75,45] loop
    insert into public.sales(business_id, client_id, kind, amount_cents, counts_as_visit, earns_points, occurred_at)
      values (b, v_id, 'service', 2000, true, false, now() - make_interval(days => v_off));
  end loop;

  insert into public.clients(business_id, full_name, phone, is_synthetic)
    values (b, 'V548 Reversed Away', '90004807', false) returning id into v_id;
  insert into _fx values ('G', v_id);
  foreach v_off in array array[105,75] loop
    insert into public.sales(business_id, client_id, kind, amount_cents, counts_as_visit, earns_points, occurred_at)
      values (b, v_id, 'service', 2000, true, false, now() - make_interval(days => v_off));
  end loop;
  insert into public.sales(business_id, client_id, kind, amount_cents, counts_as_visit, earns_points, occurred_at)
    values (b, v_id, 'service', 2000, true, false, now() - make_interval(days => 45))
    returning id into v_sale;
  -- Reversals may only be created through the sanctioned path (sales_reversal_insert_guard),
  -- so the discount case uses the real RPC as the tenant owner — exactly what production does.
  perform pg_temp.as_v548_user(pg_temp.v548_owner());
  perform public.reverse_sale(b, v_sale, 'v548 suite reversal', 'v548-suite-' || v_sale::text, null, 'none');
  execute 'reset role';
end $$;

-- ---------------------------------------------------------------------------------------------
-- 02..06  one post-fixture call as the owner, then the row/summary/order assertions
-- ---------------------------------------------------------------------------------------------
do $$
declare
  b uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  p jsonb; base jsonb; ra jsonb; rb jsonb; rc jsonb;
  d_due int; d_over int; d_slip int; d_cons int; d_risk bigint; d_once int;
  pos_a int; pos_b int; pos_c int; i int := 0; r jsonb;
  ghost int;
begin
  perform pg_temp.as_v548_user(pg_temp.v548_owner());
  p := public.get_attention_list_v548(b, null, 50);
  execute 'reset role';
  select payload into base from _base;

  ra := pg_temp.v548_row(p, 'A'); rb := pg_temp.v548_row(p, 'B'); rc := pg_temp.v548_row(p, 'C');

  insert into _r values ('02_overdue_by_own_rhythm',
    case when ra->>'status' = 'overdue'
           and (ra->>'cadence_days')::numeric = 30.0
           and (ra->>'last_visit_days')::int = 45
           and (ra->>'monthly_value_cents')::bigint = 2000
           and ra->>'full_name' = 'V548 Rhythm Regular'
      then 'PASS A overdue, cadence 30, lapse 45, monthly 2000'
      else 'FAIL A=' || coalesce(ra::text, 'ABSENT') end);

  insert into _r values ('03_due_and_slipping',
    case when rb->>'status' = 'due' and (rb->>'monthly_value_cents')::bigint = 1935
           and rc->>'status' = 'slipping' and (rc->>'monthly_value_cents')::bigint = 8571
           and (rc->>'cadence_days')::numeric = 7.0
      then 'PASS B due (1935), C slipping (8571, cadence 7)'
      else 'FAIL B=' || coalesce(rb::text, 'ABSENT') || ' C=' || coalesce(rc::text, 'ABSENT') end);

  d_due  := (p#>>'{summary,due}')::int      - (base#>>'{summary,due}')::int;
  d_over := (p#>>'{summary,overdue}')::int  - (base#>>'{summary,overdue}')::int;
  d_slip := (p#>>'{summary,slipping}')::int - (base#>>'{summary,slipping}')::int;
  d_cons := (p#>>'{summary,considered}')::int - (base#>>'{summary,considered}')::int;
  d_risk := (p#>>'{summary,monthly_at_risk_cents}')::bigint - (base#>>'{summary,monthly_at_risk_cents}')::bigint;
  d_once := (p#>>'{summary,one_time_count}')::int - (base#>>'{summary,one_time_count}')::int;
  insert into _r values ('04_summary_deltas',
    case when d_due = 1 and d_over = 1 and d_slip = 1 and d_cons = 4 and d_risk = 10571 and d_once = 1
      then 'PASS due+1 overdue+1 slipping+1 considered+4 risk+10571 one_time+1'
      else 'FAIL due+' || d_due || ' overdue+' || d_over || ' slipping+' || d_slip
           || ' considered+' || d_cons || ' risk+' || d_risk || ' one_time+' || d_once end);

  select count(*) into ghost
  from jsonb_array_elements(p->'rows') el
  join _fx f on (el->>'client_id')::uuid = f.client_id
  where f.label in ('D','E','F','G');
  insert into _r values ('05_absentees',
    case when ghost = 0
      then 'PASS D/E/F/G are not rows (one-timer, fresh, synthetic, reversal-discounted)'
      else 'FAIL ' || ghost || ' absentee fixture(s) appeared as rows' end);

  pos_a := null; pos_b := null; pos_c := null;
  for r in select * from jsonb_array_elements(p->'rows') loop
    i := i + 1;
    if (r->>'client_id')::uuid = (select client_id from _fx where label = 'A') then pos_a := i; end if;
    if (r->>'client_id')::uuid = (select client_id from _fx where label = 'B') then pos_b := i; end if;
    if (r->>'client_id')::uuid = (select client_id from _fx where label = 'C') then pos_c := i; end if;
  end loop;
  insert into _r values ('06_ordering',
    case when pos_c < pos_a and pos_a < pos_b
      then 'PASS C(' || pos_c || ') before A(' || pos_a || ') before B(' || pos_b || ')'
      else 'FAIL positions C=' || coalesce(pos_c::text,'?') || ' A=' || coalesce(pos_a::text,'?')
           || ' B=' || coalesce(pos_b::text,'?') end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 07  the cap trims rows, never the summary
-- ---------------------------------------------------------------------------------------------
do $$
declare
  b uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  p1 jsonb; p50 jsonb;
begin
  perform pg_temp.as_v548_user(pg_temp.v548_owner());
  p1  := public.get_attention_list_v548(b, null, 1);
  p50 := public.get_attention_list_v548(b, null, 50);
  execute 'reset role';
  insert into _r values ('07_honest_cap',
    case when jsonb_array_length(p1->'rows') = 1
           and (p1->'summary') = (p50->'summary')
      then 'PASS limit 1 -> 1 row, identical summary'
      else 'FAIL rows=' || jsonb_array_length(p1->'rows')
           || ' summaries_equal=' || ((p1->'summary') = (p50->'summary')) end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 08  branch scoping — the home branch sees the fixtures; a fresh empty branch sees none.
--     (A NONEXISTENT branch uuid is a 42501 from the scope gate, not an empty filter, so the
--     negative case uses a real, empty branch row inserted and rolled back with the rest.)
-- ---------------------------------------------------------------------------------------------
do $$
declare
  b uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  v_home uuid; v_empty uuid; p_home jsonb; p_empty jsonb; hits_home int; hits_empty int;
begin
  execute 'reset role';
  select id into v_home from public.branches where business_id = b order by created_at limit 1;
  insert into public.branches(business_id, name, active)
    values (b, 'V548 Empty Branch', true) returning id into v_empty;
  perform pg_temp.as_v548_user(pg_temp.v548_owner());
  p_home  := public.get_attention_list_v548(b, v_home, 50);
  p_empty := public.get_attention_list_v548(b, v_empty, 50);
  execute 'reset role';
  select count(*) into hits_home
  from jsonb_array_elements(p_home->'rows') el
  join _fx f on (el->>'client_id')::uuid = f.client_id
  where f.label in ('A','B','C');
  select count(*) into hits_empty
  from jsonb_array_elements(p_empty->'rows') el
  join _fx f on (el->>'client_id')::uuid = f.client_id;
  insert into _r values ('08_branch_scope',
    case when hits_home = 3 and hits_empty = 0
      then 'PASS home branch shows A/B/C, empty branch shows none'
      else 'FAIL home=' || hits_home || ' empty=' || hits_empty end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 09  authorization: stranger 42501, anon has no EXECUTE
-- ---------------------------------------------------------------------------------------------
do $$
declare
  b uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  v_state text := 'no error';
  v_anon boolean;
begin
  begin
    perform pg_temp.as_v548_user(gen_random_uuid());
    perform public.get_attention_list_v548(b, null, 8);
  exception when others then
    v_state := SQLSTATE;
  end;
  execute 'reset role';
  v_anon := has_function_privilege('anon', 'public.get_attention_list_v548(uuid,uuid,integer)', 'execute');
  insert into _r values ('09_authorization',
    case when v_state = '42501' and not v_anon
      then 'PASS stranger 42501, anon unprivileged'
      else 'FAIL stranger=' || v_state || ' anon_execute=' || v_anon end);
end $$;

select k, v from _r order by k;

rollback;
