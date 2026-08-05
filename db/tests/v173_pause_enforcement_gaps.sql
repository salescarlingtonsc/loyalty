-- Rollback-only v173 acceptance suite: day-14 pause enforcement gap closure.
-- Run after the canonical chain through v173 in a disposable database.
-- Verifies that a billing-paused firm's owner/manager can no longer
-- adjust_points, sell top-ups, or administer staff — and that an open firm
-- still can (no regression).
begin;

do $v173$
declare
  v_owner uuid:=gen_random_uuid();
  v_manager uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_staff_member uuid;
  v_client uuid:=gen_random_uuid();
  v_result integer;
  v_caught boolean;
begin
  reset role;
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
     'v173-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_manager,'authenticated','authenticated',
     'v173-manager-'||substr(v_manager::text,1,8)||'@example.test','',now(),now(),now());

  insert into public.businesses(id,name,slug,industry,join_enabled,enabled_modules)
  values (v_business,'V173 pause fixture',
    'v173-pause-'||substr(v_business::text,1,8),'test',true,
    array['dashboard','clients','sales','till','loyalty','reports']);

  insert into public.staff(business_id,user_id,role,full_name,active) values
    (v_business,v_owner,'owner','V173 Owner',true),
    (v_business,v_manager,'manager','V173 Manager',true);
  select id into v_staff_member from public.staff
   where business_id=v_business and user_id=v_manager;

  insert into public.clients(id,business_id,full_name,phone)
  values (v_client,v_business,'V173 Client','91730000');

  -- Firm approved and open.
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,updated_at=now(),
         decided_by=v_owner,decided_at=now(),
         decision_reason='v173 fixture approval'
   where business_id=v_business;

  -- ---- Baseline: open workspace, everything works -------------------------
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner,'role','authenticated')::text,true);

  v_result:=public.adjust_points(v_business,v_client,50,'v173 baseline earn');
  if v_result<>50 then
    raise exception 'v173 FAIL: baseline adjust_points expected 50, got %',v_result;
  end if;
  if not app.can_sell_topups(v_business) then
    raise exception 'v173 FAIL: open-workspace owner should be able to sell top-ups';
  end if;
  perform public.set_staff_role_v74(v_staff_member,'staff');
  perform public.set_staff_role_v74(v_staff_member,'manager');

  perform set_config('request.jwt.claim.sub',v_manager::text,true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_manager,'role','authenticated')::text,true);
  if not app.can_sell_topups(v_business) then
    raise exception 'v173 FAIL: open-workspace manager should be able to sell top-ups';
  end if;

  -- ---- Pause the workspace (day-14 state) ---------------------------------
  reset role;
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  update public.business_subscription_lifecycle_v94
     set state='paused',workspace_paused=true,overdue_day=14,
         provider_invoice_id='in_v173_fixture',
         paused_at=now(),due_date=current_date-14,last_evaluated_on=current_date
   where business_id=v_business;
  if app.business_workspace_open_v94(v_business) then
    raise exception 'v173 FAIL: fixture pause did not close the workspace';
  end if;

  -- ---- Paused: owner cannot adjust points ---------------------------------
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner,'role','authenticated')::text,true);

  v_caught:=false;
  begin
    perform public.adjust_points(v_business,v_client,10,'v173 paused earn');
  exception when insufficient_privilege then
    v_caught:=true;
  end;
  if not v_caught then
    raise exception 'v173 FAIL: paused-firm owner could still adjust_points';
  end if;

  -- ---- Paused: owner cannot sell top-ups or administer staff --------------
  if app.can_sell_topups(v_business) then
    raise exception 'v173 FAIL: paused-firm owner can_sell_topups should be false';
  end if;

  v_caught:=false;
  begin
    perform public.set_staff_role_v74(v_staff_member,'staff');
  exception when insufficient_privilege then
    v_caught:=true;
  end;
  if not v_caught then
    raise exception 'v173 FAIL: paused-firm owner could still set staff roles';
  end if;

  v_caught:=false;
  begin
    perform public.set_staff_module_permissions_v74(
      v_staff_member,'{"clients":"r"}'::jsonb);
  exception when insufficient_privilege then
    v_caught:=true;
  end;
  if not v_caught then
    raise exception 'v173 FAIL: paused-firm owner could still set module permissions';
  end if;

  -- ---- Paused: manager branch of can_sell_topups is gated too -------------
  perform set_config('request.jwt.claim.sub',v_manager::text,true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_manager,'role','authenticated')::text,true);
  if app.can_sell_topups(v_business) then
    raise exception 'v173 FAIL: paused-firm manager can_sell_topups should be false';
  end if;

  -- ---- Recovery: reopening restores access (no sticky state) --------------
  reset role;
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  update public.business_subscription_lifecycle_v94
     set state='current',workspace_paused=false,overdue_day=null,
         paused_at=null,last_evaluated_on=current_date
   where business_id=v_business;

  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner,'role','authenticated')::text,true);
  v_result:=public.adjust_points(v_business,v_client,-20,'v173 recovery redeem');
  if v_result<>30 then
    raise exception 'v173 FAIL: post-recovery adjust_points expected 30, got %',v_result;
  end if;
  perform public.set_staff_role_v74(v_staff_member,'staff');

  reset role;
  raise notice 'v173 PASS: all pause-enforcement assertions held';
end
$v173$;

rollback;
