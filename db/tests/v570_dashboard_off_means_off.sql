-- Rollback-only acceptance for nestly_v570 — "Dashboard: Off" actually turns the dashboard off.
-- Run: supabase db query --linked -f db/tests/v570_dashboard_off_means_off.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
--   01  shape: the dashboard reader asks the module authority as well as the role permission.
--   02  SAFETY (the property that matters more than the fix): no OWNER and no INHERIT staff row
--       (no modules allowlist, no module_perms map) loses the dashboard. Accounts whose owner
--       explicitly denied it are supposed to lose it — those are listed, never failed.
--   03  end to end, rolled back: three teammates in one fixture business — an owner, an inherit
--       staff row, and a staff row denied the dashboard module — all carrying the role permission
--       view_sales. The first two get the dashboard; the third is refused 42501.
--
-- ROLLBACK: reverting v570 means dropping the app.can_module gate, which re-opens the recorded
-- case: an owner sets a teammate's Dashboard to Off and the teammate still reads the firm's
-- revenue, because every 'staff' role carries view_sales by definition.

begin;

create temp table _r(check_id text, value text) on commit drop;

do $shape$
declare v_def text;
begin
  v_def := pg_get_functiondef('public.get_dashboard_summary_v155(uuid,date,date,text,uuid[],uuid)'::regprocedure);
  insert into _r values ('01 the dashboard reader asks the module authority',
    case when position('app.can_module(p_business,''dashboard'')' in v_def) = 0
      then 'FAIL: the module permission is still unenforced at the reader'
      when position('app.has_perm(p_business,''view_sales'')' in v_def) = 0
      then 'FAIL: the role permission gate was lost'
      else 'OK' end);
end
$shape$;

do $safety$
declare r record; v_wrong text := ''; v_denied text := '';
begin
  for r in select s.user_id, s.full_name, s.business_id, s.role, s.modules, s.module_perms
             from public.staff s
            where s.active and s.user_id is not null and s.access_state='approved'
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub',r.user_id,'role','authenticated','aud','authenticated')::text,true);
    if app.has_perm(r.business_id,'view_sales') and not app.can_module(r.business_id,'dashboard') then
      if r.role='owner' or (r.modules is null and r.module_perms is null) then
        v_wrong := v_wrong||' ['||coalesce(r.full_name,'?')||' role='||r.role||']';
      else
        v_denied := v_denied||' ['||coalesce(r.full_name,'?')||']';
      end if;
    end if;
  end loop;
  perform set_config('request.jwt.claims','',true);
  insert into _r values ('02 no owner or inherit account loses the dashboard',
    case when v_wrong = '' then 'OK (explicitly denied, as intended:'
                                ||coalesce(nullif(v_denied,''),' none')||')'
         else 'FAIL:'||v_wrong end);
end
$safety$;

do $endtoend$
declare
  v_biz uuid := 'cafe0570-0000-4000-8000-000000000001';
  v_owner uuid := 'cafe0570-0000-4000-8000-0000000000a1';
  v_inherit uuid := 'cafe0570-0000-4000-8000-0000000000a2';
  v_denied uuid := 'cafe0570-0000-4000-8000-0000000000a3';
  v_branch uuid; v_owner_ok boolean := false; v_inherit_ok boolean := false; v_denied_ok boolean := true;
  v_owner_err text := ''; v_inherit_err text := '';
begin
  insert into public.businesses(id, name, slug, industry)
  values (v_biz, 'v570 fixture', 'v570-fixture-rolled-back', 'fnb');
  -- a bare businesses INSERT seeds workspace controls and lifecycle but NOT a branch: the real
  -- creation RPCs make the default branch themselves, so the fixture does too.
  select id into v_branch from public.branches where business_id=v_biz and active limit 1;
  if v_branch is null then
    insert into public.branches(business_id, name, active)
    values (v_biz, 'v570 fixture branch', true) returning id into v_branch;
  end if;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  select '00000000-0000-0000-0000-000000000000', u, 'authenticated','authenticated',
         'v570-'||u||'@example.test','',now(),now(),now()
    from unnest(array[v_owner,v_inherit,v_denied]) u;
  update public.business_workspace_controls_v94
     set approval_status='approved', decided_at=now(), decided_by=v_owner,
         decision_reason='v570 acceptance fixture (rolled back)'
   where business_id=v_biz;
  insert into public.staff(business_id,user_id,role,full_name,active,access_state,modules)
  values (v_biz,v_owner,'owner','v570 owner',true,'approved',null),
         -- inherits: no allowlist, no map — must keep the dashboard
         (v_biz,v_inherit,'staff','v570 inherit',true,'approved',null),
         -- explicitly denied: an allowlist that omits 'dashboard'
         (v_biz,v_denied,'staff','v570 denied',true,'approved',array['till','clients']);
  -- Branch VISIBILITY is a separate rule from module permission: reporting scope refuses a staff
  -- member who is not assigned to the branch (unauthorised_branch_scope). Assign both non-owner
  -- fixtures so this test measures the module gate and nothing else. Owners see every branch.
  insert into public.staff_branches(business_id, staff_id, branch_id)
  select v_biz, s.id, v_branch from public.staff s
   where s.business_id=v_biz and s.user_id in (v_inherit, v_denied);

  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner,'role','authenticated','aud','authenticated')::text,true);
  begin
    perform public.get_dashboard_summary_v155(v_biz,current_date-30,current_date,'current',array[]::uuid[],v_branch);
    v_owner_ok := true;
  exception when others then v_owner_ok := false; v_owner_err := sqlerrm;
  end;
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_inherit,'role','authenticated','aud','authenticated')::text,true);
  begin
    perform public.get_dashboard_summary_v155(v_biz,current_date-30,current_date,'current',array[]::uuid[],v_branch);
    v_inherit_ok := true;
  exception when others then v_inherit_ok := false; v_inherit_err := sqlerrm;
  end;
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_denied,'role','authenticated','aud','authenticated')::text,true);
  begin
    perform public.get_dashboard_summary_v155(v_biz,current_date-30,current_date,'current',array[]::uuid[],v_branch);
    v_denied_ok := true;
  exception when sqlstate '42501' then v_denied_ok := false;
  end;
  perform set_config('request.jwt.claims','',true);

  insert into _r values ('03 owner and inherit keep it; an explicit Off is refused',
    case when not v_owner_ok then 'FAIL: the owner lost the dashboard — '||v_owner_err
         when not v_inherit_ok then 'FAIL: an inheriting teammate lost the dashboard — '||v_inherit_err
         when v_denied_ok then 'FAIL: the denied teammate still read the dashboard'
         else 'OK' end);
exception when others then
  insert into _r values ('03 owner and inherit keep it; an explicit Off is refused','FAIL: '||sqlerrm);
end
$endtoend$;

select * from _r order by check_id;

rollback;
