-- Rollback-only nestly_v687 acceptance: a non-owner staff member can save their OWN display
-- name, and can still change nothing else about their staff row.
--
-- WHAT THE BUG WAS (audit finding F131). The account menu's "Your display name" form is rendered
-- for every signed-in staff member. It mirrored the new name into public.staff.full_name with a
-- bare `sb.from('staff').update(...)` whose result was never assigned, and policy staff_update is
-- `using (app.is_salon_owner(business_id))` with no self-row predicate. For every non-owner role
-- the statement matched zero rows, PostgREST reported a zero-row UPDATE as success, and the UI
-- printed "Name saved." while the name every colleague reads never changed.
--
-- WHAT THIS SUITE PROVES, against a tenant it builds itself:
--   1. The RAW UPDATE a non-owner used to make still matches zero rows — the defect is real and
--      this migration did NOT paper over it by widening the policy.
--   2. The same non-owner CAN rename themselves through staff_update_my_profile_v687, and
--      public.staff.full_name actually changes.
--   3. That call left role, modules, access_state and active exactly as they were.
--   4. The non-owner still cannot rename a COLLEAGUE: the raw UPDATE is zero rows, and the RPC
--      has no route to another person's row (the colleague's name is unchanged afterwards).
--   5. A member of business A is refused (42501) for business B — the RPC cannot cross tenants.
--   6. A one-character name is refused (22023) and nothing is written.
--   7. The owner can still rename themselves through the same RPC (a positive control that the
--      refusals above are about the caller, not about the function being broken).
--   8. The write is recorded in audit_log as staff.rename_self.
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v687_staff_self_profile.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole
-- suite. Any row whose outcome starts with FAIL is a failure.

begin;

create temp table v687_out(seq integer, step text, outcome text) on commit drop;
grant insert, select on v687_out to public;

create or replace function pg_temp.as_v687_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v687_system() to public;

create or replace function pg_temp.as_v687_user(p_uid uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_v687_user(uuid,text) to public;

-- A minimal operational tenant: approved workspace, unpaused subscription, one owner and one
-- non-owner staff member. modules is left NULL because that is what an invited teammate gets by
-- default, and it is the exact configuration whose display name could never be saved.
create or replace function pg_temp.v687_tenant(
  p_business uuid, p_owner uuid, p_staff_user uuid, p_label text
) returns void language plpgsql as $$
declare v_owner_staff uuid; v_staff uuid; v_branch uuid;
begin
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',p_owner,'authenticated','authenticated',
          'v687-owner-'||substr(p_owner::text,1,8)||'@example.test','',now(),now(),now())
  on conflict (id) do nothing;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',p_staff_user,'authenticated','authenticated',
          'v687-staff-'||substr(p_staff_user::text,1,8)||'@example.test','',now(),now(),now())
  on conflict (id) do nothing;

  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules)
  values (p_business,'V687 '||p_label,'v687-'||substr(p_business::text,1,8),
          'retail','SGD',array['dashboard','clients','sales','services']);
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved', decided_by=p_owner, decided_at=now(),
         decision_reason='v687 rollback fixture'
   where business_id = p_business;
  insert into public.business_subscription_lifecycle_v94(business_id)
  values (p_business) on conflict (business_id) do nothing;
  update public.business_subscription_lifecycle_v94
     set workspace_paused=false where business_id = p_business;
  insert into public.subscriptions(business_id) values (p_business) on conflict do nothing;

  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values (p_business,p_owner,'owner','V687 Owner '||p_label,true,'approved')
  returning id into v_owner_staff;
  insert into public.staff(business_id,user_id,role,full_name,active,access_state,modules)
  values (p_business,p_staff_user,'frontdesk','V687 Frontdesk '||p_label,true,'approved',null)
  returning id into v_staff;

  insert into public.branches(business_id,name,active,is_default)
  values (p_business,'V687 Main '||p_label,true,true)
  returning id into v_branch;
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values (p_business,v_owner_staff,v_branch),(p_business,v_staff,v_branch);
end
$$;
grant execute on function pg_temp.v687_tenant(uuid,uuid,uuid,text) to public;

do $v687_test$
declare
  bA uuid := gen_random_uuid();  oA uuid := gen_random_uuid();  uA uuid := gen_random_uuid();
  bB uuid := gen_random_uuid();  oB uuid := gen_random_uuid();  uB uuid := gen_random_uuid();
  v_rows integer;
  v_res jsonb;
  v_err text;
  v_before public.staff%rowtype;
  v_after  public.staff%rowtype;
  v_owner_name text;
begin
  perform pg_temp.as_v687_system();
  perform pg_temp.v687_tenant(bA,oA,uA,'Alpha');
  perform pg_temp.v687_tenant(bB,oB,uB,'Beta');

  select * into v_before from public.staff where business_id=bA and user_id=uA;

  -- ------------------------------------------------------------------ 1. the raw UPDATE is still refused
  -- This is the statement app/app.js used to send. It must STILL match zero rows: v687 adds a
  -- route, it does not widen policy staff_update.
  perform pg_temp.as_v687_user(uA);
  with upd as (
    update public.staff set full_name='V687 RAW ATTEMPT'
     where business_id=bA and user_id=uA returning id)
  select count(*) into v_rows from upd;
  perform pg_temp.as_v687_system();
  select * into v_after from public.staff where business_id=bA and user_id=uA;
  if v_rows = 0 and v_after.full_name = v_before.full_name then
    insert into v687_out values (1,'the raw staff UPDATE a non-owner used to send still matches ZERO rows','PASS');
  else
    insert into v687_out values (1,'the raw staff UPDATE a non-owner used to send still matches ZERO rows',
      format('FAIL - rows=%s name=%s',v_rows,v_after.full_name));
  end if;

  -- ------------------------------------------------------------------ 2. the RPC saves the caller's own name
  perform pg_temp.as_v687_user(uA);
  v_err := null;
  begin
    select public.staff_update_my_profile_v687(bA,'Siti Rahayu') into v_res;
  exception when others then v_err := sqlstate; v_res := null;
  end;
  perform pg_temp.as_v687_system();
  select * into v_after from public.staff where business_id=bA and user_id=uA;
  if v_err is null and (v_res->>'status')='ok' and v_after.full_name = 'Siti Rahayu' then
    insert into v687_out values (2,'a non-owner CAN save their own display name through staff_update_my_profile_v687','PASS');
  else
    insert into v687_out values (2,'a non-owner CAN save their own display name through staff_update_my_profile_v687',
      format('FAIL - sqlstate=%s result=%s name=%s',
             coalesce(v_err,'<none>'),coalesce(v_res::text,'<null>'),coalesce(v_after.full_name,'<null>')));
  end if;

  -- ------------------------------------------------------------------ 3. nothing else moved
  if v_after.role = v_before.role
     and v_after.access_state = v_before.access_state
     and v_after.active = v_before.active
     and v_after.modules is not distinct from v_before.modules
     and v_after.user_id = v_before.user_id
     and v_after.business_id = v_before.business_id then
    insert into v687_out values (3,'the rename changed full_name ONLY — role, modules, access_state and active are untouched','PASS');
  else
    insert into v687_out values (3,'the rename changed full_name ONLY — role, modules, access_state and active are untouched',
      format('FAIL - role %s->%s access_state %s->%s active %s->%s modules %s->%s',
             v_before.role,v_after.role,v_before.access_state,v_after.access_state,
             v_before.active,v_after.active,
             coalesce(v_before.modules::text,'<null>'),coalesce(v_after.modules::text,'<null>')));
  end if;

  -- ------------------------------------------------------------------ 4. a colleague is still out of reach
  select full_name into v_owner_name from public.staff where business_id=bA and user_id=oA;
  perform pg_temp.as_v687_user(uA);
  with upd as (
    update public.staff set full_name='V687 COLLEAGUE HIJACK'
     where business_id=bA and user_id=oA returning id)
  select count(*) into v_rows from upd;
  perform pg_temp.as_v687_system();
  if v_rows = 0
     and (select full_name from public.staff where business_id=bA and user_id=oA) = v_owner_name then
    insert into v687_out values (4,'a non-owner still cannot rename a COLLEAGUE — zero rows, name unchanged','PASS');
  else
    insert into v687_out values (4,'a non-owner still cannot rename a COLLEAGUE — zero rows, name unchanged',
      format('FAIL - rows=%s name=%s',v_rows,
             (select full_name from public.staff where business_id=bA and user_id=oA)));
  end if;

  -- ------------------------------------------------------------------ 5. the RPC cannot cross tenants
  perform pg_temp.as_v687_user(uA);
  v_err := null;
  begin
    perform public.staff_update_my_profile_v687(bB,'V687 CROSS TENANT');
  exception when others then v_err := sqlstate;
  end;
  perform pg_temp.as_v687_system();
  if v_err = '42501'
     and (select full_name from public.staff where business_id=bB and user_id=uB) = 'V687 Frontdesk Beta' then
    insert into v687_out values (5,'a member of business A is REFUSED (42501) for business B','PASS');
  else
    insert into v687_out values (5,'a member of business A is REFUSED (42501) for business B',
      format('FAIL - sqlstate=%s betaname=%s',coalesce(v_err,'<none>'),
             (select full_name from public.staff where business_id=bB and user_id=uB)));
  end if;

  -- ------------------------------------------------------------------ 6. a one-character name is refused
  perform pg_temp.as_v687_user(uA);
  v_err := null;
  begin
    perform public.staff_update_my_profile_v687(bA,'  S  ');
  exception when others then v_err := sqlstate;
  end;
  perform pg_temp.as_v687_system();
  if v_err = '22023'
     and (select full_name from public.staff where business_id=bA and user_id=uA) = 'Siti Rahayu' then
    insert into v687_out values (6,'a one-character display name is REFUSED (22023) and nothing is written','PASS');
  else
    insert into v687_out values (6,'a one-character display name is REFUSED (22023) and nothing is written',
      format('FAIL - sqlstate=%s name=%s',coalesce(v_err,'<none>'),
             (select full_name from public.staff where business_id=bA and user_id=uA)));
  end if;

  -- ------------------------------------------------------------------ 7. positive control: the owner too
  perform pg_temp.as_v687_user(oA);
  v_err := null;
  begin
    select public.staff_update_my_profile_v687(bA,'Chuan Seng') into v_res;
  exception when others then v_err := sqlstate; v_res := null;
  end;
  perform pg_temp.as_v687_system();
  if v_err is null
     and (select full_name from public.staff where business_id=bA and user_id=oA) = 'Chuan Seng' then
    insert into v687_out values (7,'the OWNER can rename themselves through the same RPC (positive control)','PASS');
  else
    insert into v687_out values (7,'the OWNER can rename themselves through the same RPC (positive control)',
      format('FAIL - sqlstate=%s name=%s',coalesce(v_err,'<none>'),
             (select full_name from public.staff where business_id=bA and user_id=oA)));
  end if;

  -- ------------------------------------------------------------------ 8. the write is audited
  if exists (select 1 from public.audit_log
              where business_id = bA and actor = uA and action = 'staff.rename_self'
                and detail->>'full_name' = 'Siti Rahayu') then
    insert into v687_out values (8,'the rename is recorded in audit_log as staff.rename_self','PASS');
  else
    insert into v687_out values (8,'the rename is recorded in audit_log as staff.rename_self',
      'FAIL - no staff.rename_self audit row for the non-owner');
  end if;
end
$v687_test$;

select seq, step, outcome from v687_out order by seq;

/* The report above is printed first so a human sees WHICH assertion failed; this block then
   makes the failure fatal. It matters because scripts/db-tests/run.mjs judges a file purely by
   psql's exit code — a suite that only records FAIL rows is reported green. */
do $v687_gate$
declare v_bad integer; v_all integer;
begin
  select count(*) filter (where outcome not like 'PASS%'), count(*) into v_bad, v_all from v687_out;
  if v_all <> 8 then
    raise exception 'nestly_v687: % of 8 assertions ran — the suite aborted early', v_all;
  end if;
  if v_bad > 0 then
    raise exception 'nestly_v687: % assertion(s) FAILED — see the report above', v_bad;
  end if;
end
$v687_gate$;

rollback;
