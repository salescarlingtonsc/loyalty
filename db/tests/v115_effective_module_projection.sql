-- Rollback-only acceptance for Nestly v115 effective module projection.
-- Run after the canonical chain through v115 in a disposable database.
begin;

create or replace function pg_temp.as_v115_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,
    true
  );
end
$$;
grant execute on function pg_temp.as_v115_user(uuid,text) to public;

do $v115_test$
declare
  v_super uuid:=gen_random_uuid();
  v_owner uuid:=gen_random_uuid();
  v_frontdesk uuid:=gen_random_uuid();
  v_business uuid;
  v_branch_one uuid;
  v_branch_two uuid;
  v_frontdesk_staff uuid;
  v_result jsonb;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) select
    '00000000-0000-0000-0000-000000000000',user_id,
    'authenticated','authenticated',email,'',now(),now(),now()
  from (values
    (v_super,'v115-super@example.test'),
    (v_owner,'v115-owner@example.test'),
    (v_frontdesk,'v115-frontdesk@example.test')
  ) fixture(user_id,email);

  insert into public.super_admins(user_id,email,note)
  values(v_super,'v115-super@example.test','rollback-only v115 fixture');

  insert into public.businesses(
    name,slug,industry,enabled_modules
  ) values(
    'V115 Glow Atelier',
    'v115-glow-'||substr(v_owner::text,1,8),
    'facial',
    array['dashboard','till','clients','loyalty','packages',
      'giftcards','inventory','reports']
  ) returning id into v_business;

  insert into public.branches(business_id,name,is_default)
  values(v_business,'Orchard Road',true)
  returning id into v_branch_one;
  insert into public.branches(business_id,name)
  values(v_business,'Tampines')
  returning id into v_branch_two;

  insert into public.staff(
    business_id,user_id,role,full_name,active
  ) values(v_business,v_owner,'owner','V115 Owner',true);
  insert into public.staff(
    business_id,user_id,role,full_name,active,module_perms
  ) values(
    v_business,v_frontdesk,'frontdesk','V115 Front Desk',true,
    '{"till":"rw","clients":"r","loyalty":"rw","giftcards":"rw"}'::jsonb
  ) returning id into v_frontdesk_staff;
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values(v_business,v_frontdesk_staff,v_branch_one);

  perform pg_temp.as_v115_user(v_super);
  perform public.platform_decide_business_approval_v94(
    v_business,'approved','v115 projection fixture',1
  );
  perform public.platform_set_module_overrides_v105(
    v_business,null,
    '[
      {"module":"giftcards","mode":"disabled","expected_version":null},
      {"module":"inventory","mode":"disabled","expected_version":null}
    ]'::jsonb,
    'v115 firm disabled projection'
  );
  reset role;

  perform pg_temp.as_v115_user(v_owner);
  v_result:=public.get_my_modules(v_business);
  if v_result->'modules' @> '["giftcards"]'::jsonb
     or v_result->'modules' @> '["inventory"]'::jsonb
     or v_result->'module_perms' ? 'giftcards'
     or v_result->'module_perms' ? 'inventory' then
    raise exception 'firm-disabled modules leaked into owner projection: %',
      v_result;
  end if;
  v_result:=public.get_my_personas();
  if v_result#>'{staff,0,modules}' @> '["giftcards"]'::jsonb
     or v_result#>'{staff,0,modules}' @> '["inventory"]'::jsonb then
    raise exception 'firm-disabled modules leaked into owner persona: %',
      v_result;
  end if;
  if app.can_module_read(v_business,'giftcards')
     or app.can_module_read(v_business,'inventory') then
    raise exception 'firm-disabled direct module boundary was broadened';
  end if;
  reset role;

  perform pg_temp.as_v115_user(v_frontdesk);
  v_result:=public.get_my_modules(v_business);
  if v_result->'modules' @> '["giftcards"]'::jsonb
     or v_result->'module_perms' ? 'giftcards' then
    raise exception 'firm-disabled module leaked into front-desk projection: %',
      v_result;
  end if;
  reset role;

  perform pg_temp.as_v115_user(v_super);
  perform public.platform_set_module_overrides_v105(
    v_business,null,
    '[{"module":"giftcards","mode":"rw","expected_version":1}]'::jsonb,
    'v115 firm gift cards enabled'
  );
  perform public.platform_set_module_overrides_v105(
    v_business,v_branch_one,
    '[{"module":"giftcards","mode":"disabled","expected_version":null}]'::jsonb,
    'v115 Orchard gift cards disabled'
  );
  reset role;

  perform pg_temp.as_v115_user(v_owner);
  v_result:=public.get_my_modules(v_business);
  if not v_result->'modules' @> '["giftcards"]'::jsonb
     or v_result#>>'{module_perms,giftcards}'<>'rw' then
    raise exception 'firm-effective gift card mode missing: %',v_result;
  end if;
  v_result:=public.get_my_modules_at_v115(v_business,v_branch_one);
  if v_result->'modules' @> '["giftcards"]'::jsonb
     or v_result->'module_perms' ? 'giftcards'
     or app.can_module_read_at_v94(v_business,v_branch_one,'giftcards') then
    raise exception 'branch-disabled gift card mode leaked: %',v_result;
  end if;
  v_result:=public.get_my_modules_at_v115(v_business,v_branch_two);
  if not v_result->'modules' @> '["giftcards"]'::jsonb
     or v_result#>>'{module_perms,giftcards}'<>'rw'
     or not app.can_module_write_at_v94(
       v_business,v_branch_two,'giftcards'
     ) then
    raise exception 'inherited branch gift card mode missing: %',v_result;
  end if;
  reset role;

  perform pg_temp.as_v115_user(v_frontdesk);
  v_result:=public.get_my_modules_at_v115(v_business,v_branch_one);
  if v_result->'modules' @> '["giftcards"]'::jsonb
     or v_result->'module_perms' ? 'giftcards' then
    raise exception 'front-desk branch disable leaked: %',v_result;
  end if;
  v_result:=public.get_my_modules_at_v115(v_business,v_branch_two);
  if jsonb_array_length(v_result->'modules')<>0
     or v_result->'module_perms'<>'{}'::jsonb then
    raise exception 'unassigned branch broadened front-desk access: %',
      v_result;
  end if;
  reset role;
end
$v115_test$;

rollback;
