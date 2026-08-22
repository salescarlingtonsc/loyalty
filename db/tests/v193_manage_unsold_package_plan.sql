-- Rollback-only acceptance for V193: only an UNSOLD package version may be renamed or deleted.
--   supabase db query --linked -f db/tests/v193_manage_unsold_package_plan.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- REWRITTEN BY nestly_v454. The previous version read pg_get_functiondef and asserted the source
-- mentioned client_packages, plan_id=p_plan, the "create a new version instead" wording,
-- can_module_write and `for update`. All five were true of a function that raised 42703 on every
-- call (it wrote audit_log.meta, a column that does not exist), so rename and delete were inert on
-- #/packages for every merchant while this suite stayed green. Only the RLS check at the end was
-- ever a real fact, and it is kept. Everything else now calls the RPC.
--
--   01  an unsold plan RENAMES, and the audit row lands in audit_log.detail
--   02  an unsold plan DELETES, and the audit row lands in audit_log.detail
--   03  a SOLD plan is refused on both actions, keeps its name, and writes no audit row
--       (the guard keys on client_packages.plan_id, not on a name or version snapshot that two
--        versions of the same plan would share)
--   04  a blank rename is refused; an unsupported action is refused
--   05  permission is enforced, and another firm's plan is not reachable
--   06  package_plans stays write-closed to the browser: this RPC is the only way in

begin;

create temp table _r(k text, v text) on commit drop;

create or replace function pg_temp.as_v193_user(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end
$$;
grant execute on function pg_temp.as_v193_user(uuid) to public;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_outsider uuid := gen_random_uuid();
  v_biz uuid := gen_random_uuid();
  v_other_biz uuid := gen_random_uuid();
  v_client uuid := gen_random_uuid();
  v_unsold uuid := gen_random_uuid();
  v_doomed uuid := gen_random_uuid();
  v_sold_v1 uuid := gen_random_uuid();
  v_sold_v2 uuid := gen_random_uuid();
  v_foreign uuid := gen_random_uuid();
  v_res json;
  v_txt text;
  v_n int;
begin
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password,
                         email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_owner, 'authenticated', 'authenticated',
          'v193-owner@example.test', '', now(), now(), now()),
         ('00000000-0000-0000-0000-000000000000', v_outsider, 'authenticated', 'authenticated',
          'v193-outsider@example.test', '', now(), now(), now());

  insert into public.businesses(id, name, slug, enabled_modules)
  values (v_biz, 'V193 Firm', 'v193-' || substr(v_biz::text, 1, 8), array['packages']),
         (v_other_biz, 'V193 Other Firm', 'v193o-' || substr(v_other_biz::text, 1, 8),
          array['packages']);
  insert into public.staff(business_id, user_id, role, full_name, active)
  values (v_biz, v_owner, 'owner', 'V193 Owner', true);

  -- An unapproved or paused workspace makes every module 'disabled', so the RPC refuses before it
  -- does any work. A refusal is indistinguishable from success to a source-text assertion.
  insert into public.business_workspace_controls_v94(
    business_id, approval_status, decided_by, decided_at, decision_reason)
  values (v_biz, 'approved', v_owner, now(), 'v193 fixture'),
         (v_other_biz, 'approved', v_owner, now(), 'v193 fixture')
  on conflict (business_id) do update
    set approval_status = 'approved', decided_by = excluded.decided_by,
        decided_at = excluded.decided_at, decision_reason = excluded.decision_reason;
  insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused)
  values (v_biz, false), (v_other_biz, false)
  on conflict (business_id) do update set workspace_paused = false;

  insert into public.clients(id, business_id, full_name) values (v_client, v_biz, 'V193 Customer');

  -- v1 and v2 of the SAME plan name: only v1 was ever sold. A guard keyed on the name or on the
  -- version snapshot would wrongly refuse v2 (or wrongly allow v1).
  insert into public.package_plans(id, business_id, name, price_cents, sessions, version_no)
  values (v_unsold,  v_biz, 'V193 Unsold Plan', 1000, 5,  1),
         (v_doomed,  v_biz, 'V193 Doomed Plan', 1500, 3,  1),
         (v_sold_v1, v_biz, 'V193 Shared Name', 2000, 10, 1),
         (v_sold_v2, v_biz, 'V193 Shared Name', 2500, 10, 2);
  insert into public.package_plans(id, business_id, name, price_cents, sessions)
  values (v_foreign, v_other_biz, 'V193 Foreign Plan', 3000, 4);

  insert into public.client_packages(business_id, client_id, plan_id, remaining, status,
                                     plan_name_snapshot, plan_version_snapshot,
                                     sessions_snapshot, price_cents_snapshot)
  values (v_biz, v_client, v_sold_v1, 10, 'active', 'V193 Shared Name', 1, 10, 2000);

  ------------------------------------------------------------------- 1 - rename an unsold plan
  perform pg_temp.as_v193_user(v_owner);
  begin
    v_res := public.business_manage_package_plan_v193(v_biz, v_unsold, 'rename', 'V193 Renamed');
    v_txt := null;
  exception when others then
    v_txt := sqlstate || ' ' || sqlerrm; v_res := null;
  end;
  reset role;
  insert into _r values('01_rename_receipt',
    case when v_txt is not null then 'FAIL renaming an unsold plan raised ' || v_txt
         when v_res->>'status' = 'ok' and v_res->>'action' = 'rename' then 'PASS ' || v_res::text
         else 'FAIL unexpected receipt ' || coalesce(v_res::text, 'null') end);

  select name into v_txt from public.package_plans where id = v_unsold;
  insert into _r values('01_rename_state',
    case when v_txt = 'V193 Renamed' then 'PASS the plan carries its new name'
         else 'FAIL expected the new name, got ' || coalesce(v_txt, '(row gone)') end);

  select detail into v_txt from public.audit_log
   where business_id = v_biz and entity_id = v_unsold and action = 'package_plan.rename';
  insert into _r values('01_rename_audit',
    case when v_txt is null then 'FAIL no package_plan.rename row in audit_log.detail'
         when v_txt like '%"was_sold": 0%' then 'PASS detail=' || v_txt
         else 'FAIL wrong detail payload ' || v_txt end);

  ------------------------------------------------------------------- 2 - delete an unsold plan
  perform pg_temp.as_v193_user(v_owner);
  begin
    v_res := public.business_manage_package_plan_v193(v_biz, v_doomed, 'delete', null);
    v_txt := null;
  exception when others then
    v_txt := sqlstate || ' ' || sqlerrm; v_res := null;
  end;
  reset role;
  insert into _r values('02_delete_receipt',
    case when v_txt is not null then 'FAIL deleting an unsold plan raised ' || v_txt
         when v_res->>'status' = 'ok' and v_res->>'action' = 'delete' then 'PASS ' || v_res::text
         else 'FAIL unexpected receipt ' || coalesce(v_res::text, 'null') end);

  select count(*) into v_n from public.package_plans where id = v_doomed;
  insert into _r values('02_delete_state',
    case when v_n = 0 then 'PASS the plan row is gone'
         else 'FAIL the plan survived the delete' end);

  select detail into v_txt from public.audit_log
   where business_id = v_biz and entity_id = v_doomed and action = 'package_plan.delete';
  insert into _r values('02_delete_audit',
    case when v_txt is null then 'FAIL no package_plan.delete row in audit_log.detail'
         else 'PASS detail=' || v_txt end);

  ------------------------------------------------------- 3 - the sold guard keys on plan_id
  perform pg_temp.as_v193_user(v_owner);
  begin
    v_res := public.business_manage_package_plan_v193(v_biz, v_sold_v1, 'rename', 'V193 Nope');
    v_txt := 'returned ' || v_res::text;
  exception when others then
    v_txt := sqlstate || ' ' || sqlerrm;
  end;
  reset role;
  insert into _r values('03_sold_rename_refused',
    case when v_txt like '42501%' and v_txt like '%create a new version instead%'
      then 'PASS ' || v_txt
      else 'FAIL a sold plan must be refused with the version route; got ' || v_txt end);

  perform pg_temp.as_v193_user(v_owner);
  begin
    v_res := public.business_manage_package_plan_v193(v_biz, v_sold_v1, 'delete', null);
    v_txt := 'returned ' || v_res::text;
  exception when others then
    v_txt := sqlstate || ' ' || sqlerrm;
  end;
  reset role;
  insert into _r values('03_sold_delete_refused',
    case when v_txt like '42501%' then 'PASS ' || v_txt
         else 'FAIL a sold plan must not be deletable; got ' || v_txt end);

  select name into v_txt from public.package_plans where id = v_sold_v1;
  insert into _r values('03_sold_plan_untouched',
    case when v_txt = 'V193 Shared Name' then 'PASS the sold plan kept its name and its row'
         else 'FAIL the sold plan changed: ' || coalesce(v_txt, '(row gone)') end);

  select count(*) into v_n from public.audit_log where business_id = v_biz and entity_id = v_sold_v1;
  insert into _r values('03_sold_plan_writes_no_audit',
    case when v_n = 0 then 'PASS a refused action writes no audit row'
         else 'FAIL a refused action left ' || v_n || ' audit row(s)' end);

  -- v2 shares the sold plan's NAME but has never been sold, so it must still be manageable.
  perform pg_temp.as_v193_user(v_owner);
  begin
    v_res := public.business_manage_package_plan_v193(v_biz, v_sold_v2, 'rename', 'V193 Shared v2');
    v_txt := null;
  exception when others then
    v_txt := sqlstate || ' ' || sqlerrm; v_res := null;
  end;
  reset role;
  insert into _r values('03_unsold_sibling_version_allowed',
    case when v_txt is not null
           then 'FAIL an unsold version sharing a sold version''s name was refused: ' || v_txt
         when v_res->>'status' = 'ok' then 'PASS ' || v_res::text
         else 'FAIL unexpected receipt ' || coalesce(v_res::text, 'null') end);

  --------------------------------------------------------------------- 4 - input validation
  perform pg_temp.as_v193_user(v_owner);
  begin
    v_res := public.business_manage_package_plan_v193(v_biz, v_unsold, 'rename', ' ');
    v_txt := 'returned ' || v_res::text;
  exception when others then
    v_txt := sqlstate || ' ' || sqlerrm;
  end;
  reset role;
  insert into _r values('04_blank_name_refused',
    case when v_txt like '22023%' then 'PASS ' || v_txt
         else 'FAIL a blank rename must be refused; got ' || v_txt end);

  perform pg_temp.as_v193_user(v_owner);
  begin
    v_res := public.business_manage_package_plan_v193(v_biz, v_unsold, 'archive', null);
    v_txt := 'returned ' || v_res::text;
  exception when others then
    v_txt := sqlstate || ' ' || sqlerrm;
  end;
  reset role;
  insert into _r values('04_unknown_action_refused',
    case when v_txt like '22023%' then 'PASS ' || v_txt
         else 'FAIL an unsupported action must be refused; got ' || v_txt end);

  ------------------------------------------------------- 5 - permission and tenant isolation
  perform pg_temp.as_v193_user(v_outsider);
  begin
    v_res := public.business_manage_package_plan_v193(v_biz, v_unsold, 'delete', null);
    v_txt := 'returned ' || v_res::text;
  exception when others then
    v_txt := sqlstate || ' ' || sqlerrm;
  end;
  reset role;
  insert into _r values('05_outsider_refused',
    case when v_txt like '42501%' then 'PASS ' || v_txt
         else 'FAIL a user with no staff row must be refused; got ' || v_txt end);

  perform pg_temp.as_v193_user(v_owner);
  begin
    v_res := public.business_manage_package_plan_v193(v_biz, v_foreign, 'delete', null);
    v_txt := 'returned ' || v_res::text;
  exception when others then
    v_txt := sqlstate || ' ' || sqlerrm;
  end;
  reset role;
  insert into _r values('05_foreign_plan_not_found',
    case when v_txt like '42704%' then 'PASS ' || v_txt
         else 'FAIL another firm''s plan must not be reachable; got ' || v_txt end);

  select count(*) into v_n from public.package_plans where id in (v_unsold, v_foreign);
  insert into _r values('05_refused_calls_change_nothing',
    case when v_n = 2 then 'PASS both plans survived the refused calls'
         else 'FAIL a refused call removed a plan' end);
end
$$;

-- 6 - package_plans must stay write-closed to the browser: this RPC is the only way in.
do $$
begin
  if exists (select 1 from pg_policy p join pg_class c on c.oid = p.polrelid
              where c.relname = 'package_plans' and p.polcmd in ('w', 'd', 'a')) then
    insert into _r values('06_no_direct_write_policy',
      'FAIL package_plans gained a direct write policy; the RPC is no longer the only path');
  else
    insert into _r values('06_no_direct_write_policy',
      'PASS package_plans has no INSERT/UPDATE/DELETE policy');
  end if;
end
$$;

select k, v from _r order by k;

rollback;
