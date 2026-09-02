-- Rollback-only v673 acceptance suite: staff_insert is owner-only.
--   T1  An authenticated OUTSIDER (no staff row anywhere) cannot insert itself into a
--       business that already has an owner — the exact F132 shape — 42501.
--   T2  The same outsider cannot insert itself into a business with ZERO staff rows either
--       (the retired bootstrap arm) — 42501.
--   T3  The business OWNER can still add a teammate row (the policy's only remaining arm).
-- Run after the complete canonical chain through v673 in a disposable database.
begin;

do $suite$
declare
  v_owner uuid := gen_random_uuid();
  v_outsider uuid := gen_random_uuid();
  v_business uuid := gen_random_uuid();
  v_empty_business uuid := gen_random_uuid();
  v_state text;
begin
  reset role;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
          'v673-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',v_outsider,'authenticated','authenticated',
          'v673-outsider-'||substr(v_outsider::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.businesses(id,name,slug,industry,join_enabled,enabled_modules)
  values (v_business,'v673 fixture','v673-'||substr(v_business::text,1,8),'test',true,
          array['dashboard','clients','sales','till','loyalty']),
         (v_empty_business,'v673 empty fixture','v673e-'||substr(v_empty_business::text,1,8),'test',true,
          array['dashboard','clients','sales','till','loyalty']);
  insert into public.staff(business_id,user_id,role,full_name,active)
  values (v_business,v_owner,'owner','v673 Owner',true);
  insert into public.subscriptions(business_id) values (v_business),(v_empty_business) on conflict do nothing;
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,decided_at=now(),updated_at=now()
   where business_id in (v_business,v_empty_business);

  -- T1: outsider vs a business that has an owner
  perform set_config('request.jwt.claim.sub',v_outsider::text,true);
  set local role authenticated;
  begin
    insert into public.staff(business_id,user_id,role,full_name,active)
    values (v_business,v_outsider,'manager','Intruder',true);
    raise exception 'T1 FAIL: outsider inserted itself into a business with an owner';
  exception when insufficient_privilege then
    raise notice 'T1 OK: outsider refused (42501)';
  end;

  -- T2: outsider vs a business with zero staff rows (the retired bootstrap arm)
  begin
    insert into public.staff(business_id,user_id,role,full_name,active)
    values (v_empty_business,v_outsider,'owner','Intruder',true);
    raise exception 'T2 FAIL: outsider bootstrapped itself as owner of an empty business';
  exception when insufficient_privilege then
    raise notice 'T2 OK: bootstrap arm is gone (42501)';
  end;

  -- T3: the real owner can still add a teammate
  reset role;
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  set local role authenticated;
  insert into public.staff(business_id,user_id,role,full_name,active)
  values (v_business,null,'staff','v673 Teammate',true);
  get diagnostics v_state = row_count;
  if v_state::int <> 1 then raise exception 'T3 FAIL: owner could not add a teammate'; end if;
  raise notice 'T3 OK: owner insert allowed';
  reset role;
end $suite$;

rollback;
