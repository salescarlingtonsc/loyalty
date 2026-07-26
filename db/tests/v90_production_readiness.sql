-- Rollback-only v90 production-readiness evidence.
-- Run after the canonical chain through v90 in a disposable database.

begin;

create or replace function pg_temp.as_v90_user(
  p_uid uuid,p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_v90_user(uuid,text) to public;

create or replace function pg_temp.v90_platform_can(
  p_module text,p_mode text
) returns boolean language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$select app.v89_platform_can(p_module,p_mode)$$;
grant execute on function pg_temp.v90_platform_can(text,text) to public;

-- A similarly named pg_temp function must not be mistaken for a trusted
-- legacy caller by the PG_CONTEXT compatibility adapter.
create or replace function pg_temp.platform_get_sme_board_v76_probe()
returns boolean language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$select app.is_platform_operator_v75()$$;
grant execute on function pg_temp.platform_get_sme_board_v76_probe() to public;

do $v90$
declare
  v_sa uuid:=gen_random_uuid();
  v_admin uuid:=gen_random_uuid();
  v_sales uuid:=gen_random_uuid();
  v_owner uuid:=gen_random_uuid();
  v_customer uuid:=gen_random_uuid();
  v_consultant uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_nullable text;
  v_default text;
  v_result jsonb;
  v_first_token text;
  v_rotated_token text;
begin
  select column_info.is_nullable,column_info.column_default
    into v_nullable,v_default
  from information_schema.columns column_info
  where column_info.table_schema='public'
    and column_info.table_name='businesses'
    and column_info.column_name='updated_at';

  if v_nullable is distinct from 'NO' or v_default not ilike '%now()%' then
    raise exception 'businesses.updated_at is not a required lifecycle timestamp';
  end if;
  if exists(select 1 from public.businesses where updated_at is null) then
    raise exception 'v90 left businesses without lifecycle timestamps';
  end if;

  if to_regprocedure('public.start_business_onboarding_v79(uuid,bigint,text)') is null
     or to_regprocedure('public.activate_business_v79(uuid,bigint,text)') is null
     or to_regprocedure(
       'public.business_rotate_customer_join_qr_v90(uuid,timestamptz)'
     ) is null
     or to_regprocedure(
       'public.business_revoke_customer_join_qrs_v90(uuid)'
     ) is null then
    raise exception 'v90 production-readiness contracts are incomplete';
  end if;

  if has_function_privilege(
       'anon','public.customer_join_business_from_qr_v89(text,uuid)','EXECUTE'
     )
     or has_function_privilege(
       'service_role',
       'public.customer_join_business_from_qr_v89_base_v90(text,uuid)',
       'EXECUTE'
     )
     or has_function_privilege(
       'authenticated',
       'public.business_create_customer_join_qr_v89(uuid,timestamptz)',
       'EXECUTE'
     )
     or not has_function_privilege(
       'authenticated',
       'public.business_rotate_customer_join_qr_v90(uuid,timestamptz)',
       'EXECUTE'
     ) then
    raise exception 'v90 QR RPC privileges are not fail-closed';
  end if;

  insert into auth.users(
    instance_id,id,aud,role,email,phone,encrypted_password,email_confirmed_at,
    phone_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_sa,'authenticated',
      'authenticated','v90-sa@example.test',null,'',now(),null,now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_admin,'authenticated',
      'authenticated','v90-admin@example.test',null,'',now(),null,now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_sales,'authenticated',
      'authenticated','v90-sales@example.test',null,'',now(),null,now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated',
      'authenticated','v90-owner@example.test',null,'',now(),null,now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_customer,'authenticated',
      'authenticated','v90-customer@example.test','+6581230090','',
      now(),now(),now(),now());
  insert into public.super_admins(user_id,email,note)
  values(v_sa,'v90-sa@example.test','v90 rollback fixture');
  insert into public.platform_consultants(
    id,user_id,display_name,tier,employment_started_on,created_by
  ) values(
    v_consultant,v_sales,'V90 Sales','senior',current_date-400,v_sa
  );
  insert into public.businesses(id,name,slug,join_enabled,enabled_modules)
  values(
    v_business,'V90 QR Kill Switch',
    'v90-qr-'||substr(v_business::text,1,8),true,
    array['dashboard','clients','loyalty']
  );
  insert into public.staff(business_id,user_id,role,full_name)
  values(v_business,v_owner,'owner','V90 Owner');

  perform pg_temp.as_v90_user(v_sa);
  perform public.platform_upsert_access_grant_v89(
    v_admin,'admin','{"onboarding":"r"}',true
  );
  reset role;

  -- Read-only admins retain legacy readers but every legacy writer is denied
  -- before lookup, validation, idempotency, or mutation.
  perform pg_temp.as_v90_user(v_admin);
  v_result:=public.platform_get_sme_board_v76(null);
  reset role;
  if jsonb_typeof(v_result)<>'object' then
    raise exception 'read-only admin lost the legacy onboarding reader';
  end if;

  begin
    perform pg_temp.as_v90_user(v_admin);
    perform public.convert_sme_prospect_v79(
      gen_random_uuid(),0,'v90-readonly-convert'
    );
    reset role;
    raise exception 'read-only admin reached prospect conversion';
  exception when insufficient_privilege then reset role;
  end;
  begin
    perform pg_temp.as_v90_user(v_admin);
    perform public.reissue_workspace_owner_invite_v79(
      gen_random_uuid(),'owner@example.test','v90-readonly-reissue'
    );
    reset role;
    raise exception 'read-only admin reached invite reissue';
  exception when insufficient_privilege then reset role;
  end;
  begin
    perform pg_temp.as_v90_user(v_admin);
    perform public.start_business_onboarding_v79(
      gen_random_uuid(),0,'v90-readonly-start'
    );
    reset role;
    raise exception 'read-only admin reached onboarding start';
  exception when insufficient_privilege then reset role;
  end;
  begin
    perform pg_temp.as_v90_user(v_admin);
    perform public.platform_analyse_prospect_import_v86(
      gen_random_uuid(),'{}'::jsonb
    );
    reset role;
    raise exception 'read-only admin reached import analysis';
  exception when insufficient_privilege then reset role;
  end;

  perform pg_temp.as_v90_user(v_admin);
  if pg_temp.platform_get_sme_board_v76_probe() then
    reset role;
    raise exception 'a pg_temp caller spoofed the trusted legacy allowlist';
  end if;
  reset role;

  -- A sales grant cannot smuggle wildcard or unrelated enterprise modules.
  begin
    perform pg_temp.as_v90_user(v_sa);
    perform public.platform_upsert_access_grant_v89(
      v_sales,'sales_staff',
      '{"*":"rw","onboarding":"rw","reports":"r"}',true
    );
    reset role;
    raise exception 'sales wildcard grant bypassed the v90 constraint';
  exception when check_violation then reset role;
  end;

  perform pg_temp.as_v90_user(v_sa);
  perform public.platform_upsert_access_grant_v89(
    v_sales,'sales_staff',
    '{"onboarding":"rw","firms":"r","reports":"r"}',true
  );
  reset role;
  perform pg_temp.as_v90_user(v_sales);
  if not pg_temp.v90_platform_can('onboarding','rw')
     or pg_temp.v90_platform_can('billing','r')
     or pg_temp.v90_platform_can('*','r') then
    reset role;
    raise exception 'sales access escaped its own CRM/reporting scope';
  end if;
  reset role;

  -- Rotation invalidates every prior printed QR; explicit revocation is also
  -- available. The business pause switch is rechecked at authenticated claim.
  perform pg_temp.as_v90_user(v_owner);
  v_result:=public.business_rotate_customer_join_qr_v90(
    v_business,now()+interval '7 days'
  );
  v_first_token:=v_result->>'join_token';
  v_result:=public.business_rotate_customer_join_qr_v90(
    v_business,now()+interval '7 days'
  );
  v_rotated_token:=v_result->>'join_token';
  reset role;
  if v_first_token is null or v_rotated_token is null
     or v_first_token=v_rotated_token
     or (v_result->>'replaced_count')::integer<>1 then
    raise exception 'business QR rotation did not replace exactly one token';
  end if;

  perform set_config('app.v75_sector_assignment','on',true);
  update public.businesses set join_enabled=false where id=v_business;
  begin
    perform pg_temp.as_v90_user(v_customer);
    perform public.customer_join_business_from_qr_v89(
      v_rotated_token,gen_random_uuid()
    );
    reset role;
    raise exception 'paused business accepted an authenticated QR claim';
  exception when invalid_parameter_value then reset role;
  end;

  perform pg_temp.as_v90_user(v_owner);
  v_result:=public.business_revoke_customer_join_qrs_v90(v_business);
  reset role;
  if (v_result->>'revoked_count')::integer<>1
     or exists(
       select 1 from public.business_customer_join_qr_v89
       where business_id=v_business and status='active'
     ) then
    raise exception 'explicit QR revocation left an active token';
  end if;
end
$v90$;

rollback;
