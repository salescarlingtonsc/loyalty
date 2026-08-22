-- Rollback-only acceptance for nestly_v454 — audit_log.detail, not audit_log.meta.
--   supabase db query --linked -f db/tests/v454_audit_log_detail_column.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- This suite exists because the two suites it replaces could not have caught the bug they were
-- written for. db/tests/v183_promotion_delete.sql and db/tests/v193_manage_unsold_package_plan.sql
-- read pg_get_functiondef and asserted the SOURCE TEXT mentioned the right content_type, guards and
-- lock. Both were green for sixteen days while the two functions raised 42703 on every call. Every
-- check below either EXECUTES an RPC or reads information_schema; none of them inspects source text
-- for its own sake.
--
--   01  the real audit_log column list, read from information_schema (the fact everything else uses)
--   02  THE GUARD: every `insert into public.audit_log(...)` in public/app must name only real
--       columns. Enumerates every distinct column list it inspected and the number of call sites
--       behind each, so it cannot pass by matching nothing. Fails before v454 is applied.
--   03  NEGATIVE CONTROL: with a deliberately re-broken body installed inside this transaction,
--       the executing assertions must FAIL. This proves checks 04-06 can detect the defect.
--   04  business_delete_promotion_v183 retires a LIVE offer and writes its audit row
--   05  business_delete_promotion_v183 deletes a DRAFT offer and writes its audit row
--   06  business_manage_package_plan_v193 renames an unsold plan and writes its audit row
--   07  the sold-plan guard still refuses, and still refuses BEFORE any audit write
--
-- Checks 03-07 build their own firm, owner, offers and package plan inside the transaction, so the
-- suite is self-contained and touches no live tenant.

begin;

create temp table _r(k text, v text) on commit drop;

-- Impersonate a browser session: the RPCs are SECURITY DEFINER but gate on auth.uid().
create or replace function pg_temp.as_v454_user(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end
$$;
grant execute on function pg_temp.as_v454_user(uuid) to public;

-- Re-point one function's audit insert at a named column. Used by the negative control to put the
-- defect back, and to take it out again, without leaving this transaction.
create or replace function pg_temp.v454_point_audit_at(p_fn text, p_column text) returns void
language plpgsql as $$
declare v_src text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = p_fn;
  if v_src is null then
    raise exception 'v454 harness: public.% is missing', p_fn;
  end if;
  -- The pattern must be PRESENT; whether the replacement changes any bytes depends on which
  -- column the deployed body already names, so identity is not an error here.
  if v_src !~ 'insert into public\.audit_log\(business_id, actor, action, entity, entity_id, [a-z_]+\)' then
    raise exception 'v454 harness: no recognisable audit insert in public.%', p_fn;
  end if;
  v_new := regexp_replace(v_src,
    '(insert into public\.audit_log\(business_id, actor, action, entity, entity_id, )[a-z_]+\)',
    '\1' || p_column || ')');
  execute v_new;
  -- Prove the installed body now names the column we asked for.
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = p_fn;
  if position('audit_log(business_id, actor, action, entity, entity_id, ' || p_column || ')'
              in v_src) = 0 then
    raise exception 'v454 harness: public.% did not take the % column', p_fn, p_column;
  end if;
end
$$;
grant execute on function pg_temp.v454_point_audit_at(text, text) to public;

-- ------------------------------------------------------------------ 1 - the schema fact
do $$
declare v_cols text;
begin
  select string_agg(column_name, ',' order by ordinal_position) into v_cols
    from information_schema.columns
   where table_schema = 'public' and table_name = 'audit_log';
  insert into _r values('01_audit_log_columns',
    case when v_cols is null then 'FAIL public.audit_log does not exist'
         when v_cols like '%detail%' and v_cols not like '%meta%'
           then 'PASS ' || v_cols
         else 'FAIL unexpected audit_log shape: ' || v_cols end);
end
$$;

-- ------------------------------- 2 - the guard that stops a fourth appearance of this token
do $$
declare
  v_real text[];
  r record;
  v_cols text[];
  v_bad text[];
  v_sites int := 0;
  v_signatures int := 0;
  v_offenders int := 0;
begin
  select array_agg(column_name order by ordinal_position) into v_real
    from information_schema.columns
   where table_schema = 'public' and table_name = 'audit_log';

  for r in
    select regexp_replace(m[1], '\s+', ' ', 'g') as collist,
           count(*)::int as sites,
           string_agg(distinct n.nspname || '.' || p.proname, ', ' order by n.nspname || '.' || p.proname) as fns
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace,
      lateral regexp_matches(pg_get_functiondef(p.oid),
        'insert\s+into\s+public\.audit_log\s*\(([^)]*)\)', 'gi') m
     where n.nspname in ('public', 'app')
       and p.prokind = 'f'   -- pg_get_functiondef refuses aggregates and window functions
     group by 1
     order by 2 desc, 1
  loop
    v_signatures := v_signatures + 1;
    v_sites := v_sites + r.sites;

    select array_agg(btrim(c)) into v_cols
      from unnest(string_to_array(r.collist, ',')) c;
    select array_agg(c) into v_bad
      from unnest(v_cols) c
     where not (c = any(v_real));

    if v_bad is null then
      insert into _r values('02_signature_' || lpad(v_signatures::text, 2, '0'),
        'PASS ' || r.sites || ' call site(s): (' || array_to_string(v_cols, ',') || ')');
    else
      v_offenders := v_offenders + 1;
      insert into _r values('02_signature_' || lpad(v_signatures::text, 2, '0'),
        'FAIL audit_log has no column(s) ' || array_to_string(v_bad, ',')
        || ' -- ' || r.sites || ' call site(s) in ' || r.fns);
    end if;
  end loop;

  -- A scan that matched nothing would report no offenders and look green. Pin the floor.
  insert into _r values('02_scan_reach',
    case when v_sites >= 100 and v_signatures >= 3
      then 'PASS inspected ' || v_sites || ' audit_log insert sites across '
           || v_signatures || ' distinct column lists'
      else 'FAIL the scan only reached ' || v_sites || ' insert sites across '
           || v_signatures || ' column lists; it cannot be trusted' end);
  insert into _r values('02_offending_signatures',
    case when v_offenders = 0 then 'PASS every audit_log insert names real columns'
         else 'FAIL ' || v_offenders || ' column list(s) name a column audit_log does not have' end);
end
$$;

-- --------------------------------------------------- 3-7 - execute the two repaired RPCs
do $$
declare
  v_owner uuid := gen_random_uuid();
  v_biz uuid := gen_random_uuid();
  v_live uuid := gen_random_uuid();
  v_draft uuid := gen_random_uuid();
  v_plan uuid := gen_random_uuid();
  v_sold_plan uuid := gen_random_uuid();
  v_client uuid := gen_random_uuid();
  v_res json;
  v_txt text;
  v_detail jsonb;
  v_n int;
begin
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password,
                         email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_owner, 'authenticated', 'authenticated',
          'v454-owner@example.test', '', now(), now(), now());
  insert into public.businesses(id, name, slug, enabled_modules)
  values (v_biz, 'V454 Firm', 'v454-' || substr(v_biz::text, 1, 8),
          array['loyalty', 'packages']);
  insert into public.staff(business_id, user_id, role, full_name, active)
  values (v_biz, v_owner, 'owner', 'V454 Owner', true);
  -- The module gate runs through app.business_workspace_open_v94: an unapproved or paused
  -- workspace answers 'disabled' for every module and both RPCs would refuse before reaching
  -- the audit insert -- which is exactly how a source-only suite stays green.
  insert into public.business_workspace_controls_v94(
    business_id, approval_status, decided_by, decided_at, decision_reason)
  values (v_biz, 'approved', v_owner, now(), 'v454 fixture')
  on conflict (business_id) do update
    set approval_status = 'approved', decided_by = excluded.decided_by,
        decided_at = excluded.decided_at, decision_reason = excluded.decision_reason;
  insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused)
  values (v_biz, false)
  on conflict (business_id) do update set workspace_paused = false;

  perform set_config('app.v104_promotion_write', 'on', true);
  insert into public.business_customer_content_v95(
    id, business_id, content_type, active, display_order, starts_at, ends_at, metadata)
  values
    (v_live,  v_biz, 'offer', true,  1, now() - interval '1 day', now() + interval '7 days',
     '{"schema":"nestly.promotion.v104"}'::jsonb),
    (v_draft, v_biz, 'offer', false, 2, null,                     now() + interval '7 days',
     '{"schema":"nestly.promotion.v104"}'::jsonb);
  perform set_config('app.v104_promotion_write', '', true);

  insert into public.package_plans(id, business_id, name, price_cents, sessions)
  values (v_plan, v_biz, 'V454 Plan', 1000, 5),
         (v_sold_plan, v_biz, 'V454 Sold Plan', 2000, 10);
  insert into public.clients(id, business_id, full_name) values (v_client, v_biz, 'V454 Customer');
  insert into public.client_packages(business_id, client_id, plan_id, remaining, status,
                                     plan_name_snapshot, plan_version_snapshot, sessions_snapshot,
                                     price_cents_snapshot)
  values (v_biz, v_client, v_sold_plan, 10, 'active', 'V454 Sold Plan', 1, 10, 2000);

  ----------------------------------------------------------------- 3 - negative control
  -- Put the defect back on purpose. If the assertions below can be satisfied by a broken
  -- function, they are worthless.
  perform pg_temp.v454_point_audit_at('business_delete_promotion_v183', 'meta');
  perform pg_temp.v454_point_audit_at('business_manage_package_plan_v193', 'meta');

  perform pg_temp.as_v454_user(v_owner);
  begin
    v_res := public.business_delete_promotion_v183(v_biz, v_live, null);
    v_txt := 'returned ' || v_res::text;
  exception when others then
    v_txt := sqlstate || ' ' || sqlerrm;
  end;
  reset role;
  insert into _r values('03_broken_promotion_rpc_raises',
    case when v_txt like '42703%' and v_txt like '%meta%'
      then 'PASS the defect is detectable: ' || v_txt
      else 'FAIL a body writing audit_log.meta did not raise 42703; got ' || v_txt end);

  select active::text into v_txt from public.business_customer_content_v95 where id = v_live;
  insert into _r values('03_broken_promotion_rpc_changes_nothing',
    case when v_txt = 'true' then 'PASS the live offer is still live after the failed call'
         else 'FAIL the failed call left state behind: active=' || coalesce(v_txt, '(row gone)') end);

  perform pg_temp.as_v454_user(v_owner);
  begin
    v_res := public.business_manage_package_plan_v193(v_biz, v_plan, 'rename', 'V454 Broken Rename');
    v_txt := 'returned ' || v_res::text;
  exception when others then
    v_txt := sqlstate || ' ' || sqlerrm;
  end;
  reset role;
  insert into _r values('03_broken_package_rpc_raises',
    case when v_txt like '42703%' and v_txt like '%meta%'
      then 'PASS the defect is detectable: ' || v_txt
      else 'FAIL a body writing audit_log.meta did not raise 42703; got ' || v_txt end);

  select name into v_txt from public.package_plans where id = v_plan;
  insert into _r values('03_broken_package_rpc_changes_nothing',
    case when v_txt = 'V454 Plan' then 'PASS the plan kept its name after the failed call'
         else 'FAIL the failed call left state behind: name=' || coalesce(v_txt, '(row gone)') end);

  -- Take the defect back out. Everything below runs against the v454 shape.
  perform pg_temp.v454_point_audit_at('business_delete_promotion_v183', 'detail');
  perform pg_temp.v454_point_audit_at('business_manage_package_plan_v193', 'detail');

  ------------------------------------------------------------- 4 - retire a live offer
  perform pg_temp.as_v454_user(v_owner);
  begin
    v_res := public.business_delete_promotion_v183(v_biz, v_live, null);
    v_txt := null;
  exception when others then
    v_txt := sqlstate || ' ' || sqlerrm;
    v_res := null;
  end;
  reset role;
  insert into _r values('04_retire_call',
    case when v_txt is not null then 'FAIL retiring a live offer raised ' || v_txt
         when v_res->>'status' = 'ok' and v_res->>'mode' = 'retired' then 'PASS ' || v_res::text
         else 'FAIL unexpected receipt ' || coalesce(v_res::text, 'null') end);

  select active::text into v_txt from public.business_customer_content_v95 where id = v_live;
  insert into _r values('04_retire_state',
    case when v_txt = 'false' then 'PASS the live offer is retired, and its row is kept'
         else 'FAIL expected active=false, got ' || coalesce(v_txt, '(row gone)') end);

  select detail into v_detail from public.audit_log
   where business_id = v_biz and entity_id = v_live and action = 'promotion.retired';
  insert into _r values('04_retire_audit',
    case when v_detail is null then 'FAIL no promotion.retired audit row with a detail payload'
         when v_detail->>'was_published' = 'true' then 'PASS detail=' || v_detail::text
         else 'FAIL wrong detail payload ' || v_detail::text end);

  ------------------------------------------------------------- 5 - delete a draft offer
  perform pg_temp.as_v454_user(v_owner);
  begin
    v_res := public.business_delete_promotion_v183(v_biz, v_draft, null);
    v_txt := null;
  exception when others then
    v_txt := sqlstate || ' ' || sqlerrm;
    v_res := null;
  end;
  reset role;
  insert into _r values('05_delete_call',
    case when v_txt is not null then 'FAIL deleting a draft raised ' || v_txt
         when v_res->>'status' = 'ok' and v_res->>'mode' = 'deleted' then 'PASS ' || v_res::text
         else 'FAIL unexpected receipt ' || coalesce(v_res::text, 'null') end);

  select count(*) into v_n from public.business_customer_content_v95 where id = v_draft;
  insert into _r values('05_delete_state',
    case when v_n = 0 then 'PASS the draft row is gone'
         else 'FAIL the draft survived the delete' end);

  select detail into v_detail from public.audit_log
   where business_id = v_biz and entity_id = v_draft and action = 'promotion.deleted';
  insert into _r values('05_delete_audit',
    case when v_detail is null then 'FAIL no promotion.deleted audit row with a detail payload'
         when v_detail->>'was_published' = 'false' then 'PASS detail=' || v_detail::text
         else 'FAIL wrong detail payload ' || v_detail::text end);

  ------------------------------------------------------ 6 - rename an unsold package plan
  perform pg_temp.as_v454_user(v_owner);
  begin
    v_res := public.business_manage_package_plan_v193(v_biz, v_plan, 'rename', 'V454 Renamed');
    v_txt := null;
  exception when others then
    v_txt := sqlstate || ' ' || sqlerrm;
    v_res := null;
  end;
  reset role;
  insert into _r values('06_rename_call',
    case when v_txt is not null then 'FAIL renaming an unsold plan raised ' || v_txt
         when v_res->>'status' = 'ok' and v_res->>'action' = 'rename' then 'PASS ' || v_res::text
         else 'FAIL unexpected receipt ' || coalesce(v_res::text, 'null') end);

  select name into v_txt from public.package_plans where id = v_plan;
  insert into _r values('06_rename_state',
    case when v_txt = 'V454 Renamed' then 'PASS the plan carries its new name'
         else 'FAIL expected the new name, got ' || coalesce(v_txt, '(row gone)') end);

  select detail into v_detail from public.audit_log
   where business_id = v_biz and entity_id = v_plan and action = 'package_plan.rename';
  insert into _r values('06_rename_audit',
    case when v_detail is null then 'FAIL no package_plan.rename audit row with a detail payload'
         when v_detail->>'was_sold' = '0' and v_detail->>'name' = 'V454 Renamed'
           then 'PASS detail=' || v_detail::text
         else 'FAIL wrong detail payload ' || v_detail::text end);

  ------------------------------------------------- 7 - the sold-plan guard is unchanged
  perform pg_temp.as_v454_user(v_owner);
  begin
    v_res := public.business_manage_package_plan_v193(v_biz, v_sold_plan, 'delete', null);
    v_txt := 'returned ' || v_res::text;
  exception when others then
    v_txt := sqlstate || ' ' || sqlerrm;
  end;
  reset role;
  insert into _r values('07_sold_plan_refused',
    case when v_txt like '42501%' and v_txt like '%create a new version instead%'
      then 'PASS ' || v_txt
      else 'FAIL a sold plan must still be refused; got ' || v_txt end);

  select count(*) into v_n from public.package_plans where id = v_sold_plan;
  insert into _r values('07_sold_plan_survives',
    case when v_n = 1 then 'PASS the sold plan is untouched'
         else 'FAIL the sold plan was deleted' end);

  select count(*) into v_n from public.audit_log
   where business_id = v_biz and entity_id = v_sold_plan;
  insert into _r values('07_sold_plan_writes_no_audit',
    case when v_n = 0 then 'PASS a refused action writes no audit row'
         else 'FAIL a refused action left ' || v_n || ' audit row(s)' end);
end
$$;

select k, v from _r order by k;

rollback;
