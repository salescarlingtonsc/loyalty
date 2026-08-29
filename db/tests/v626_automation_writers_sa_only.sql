-- Rollback-only acceptance for NESTLY v626 — the two automation control-plane writers are
-- super-admin only, matching the authority the console already claims for them.
--
-- Proves, at the server boundary only:
--   · a delegated platform admin holding automation:rw — proven to hold it, so the refusal
--     cannot be blamed on a missing grant — is refused by BOTH writers with 42501;
--   · a super admin on a Google session passes the gate (the call fails, if at all, on
--     fixture shape, never on 42501);
--   · neither writer is anon-callable.
--
-- Self-contained fixtures (gen_random_uuid) and one transaction that ends in rollback — the
-- super-admin probes deliberately use unknown keys so nothing is written anywhere.
begin;

create or replace function pg_temp.as_v626_session(
  p_uid uuid,
  p_method text default 'oauth',
  p_role text default 'authenticated'
) returns void language plpgsql as $fn$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  if p_uid is null then
    return;
  end if;
  if p_role is not null then
    execute format('set local role %I',p_role);
  end if;
  perform set_config('request.jwt.claim.sub',p_uid::text,true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub',p_uid,
      'role',coalesce(p_role,'authenticated'),
      'amr',jsonb_build_array(
        jsonb_build_object('method',p_method,'timestamp',1756500000)
      ),
      'app_metadata',case when p_method='oauth'
        then jsonb_build_object(
          'provider','google','providers',jsonb_build_array('email','google'))
        else jsonb_build_object(
          'provider','email','providers',jsonb_build_array('email')) end
    )::text,
    true
  );
end
$fn$;
grant execute on function pg_temp.as_v626_session(uuid,text,text) to public;

do $v626_main$
declare
  v_super uuid:=gen_random_uuid();
  v_admin uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_unknown_capability text:='v626_probe_'||substr(gen_random_uuid()::text,1,8);
  v_sqlstate text;
begin
  reset role;

  -- G1 · neither automation writer is anon-callable, and both stay reachable by a signed-in
  -- session (the gate is inside the function, not the ACL).
  if has_function_privilege(
       'anon',
       'public.platform_set_capability_grant_v518(uuid,text,boolean,integer,text,text,bigint,boolean)',
       'EXECUTE')
     or has_function_privilege(
       'anon',
       'public.platform_set_retention_hold_v574(uuid,uuid,boolean,text,bigint)','EXECUTE')
     or not has_function_privilege(
       'authenticated',
       'public.platform_set_capability_grant_v518(uuid,text,boolean,integer,text,text,bigint,boolean)',
       'EXECUTE') then
    raise exception 'v626 G1: automation writer ACLs are not fail-closed';
  end if;

  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) select
    '00000000-0000-0000-0000-000000000000',user_id,
    'authenticated','authenticated',email,'',now(),now(),now()
  from (values
    (v_super,'v626-super-'||substr(v_super::text,1,8)||'@example.test'),
    (v_admin,'v626-admin-'||substr(v_admin::text,1,8)||'@example.test')
  ) fixture(user_id,email);
  insert into public.super_admins(user_id,email,note)
  values(
    v_super,'v626-super-'||substr(v_super::text,1,8)||'@example.test',
    'rollback-only v626 fixture'
  );
  insert into public.platform_access_grants_v89(
    user_id,role,module_perms,created_by,updated_by
  ) values(v_admin,'admin','{"automation":"rw"}'::jsonb,v_super,v_super);

  insert into public.businesses(id,name,slug,industry,enabled_modules)
  values(
    v_business,'V626 automation writer fixture',
    'v626-'||substr(v_business::text,1,8),'test',
    array['dashboard','clients','sales','loyalty','retention','reports']
  );

  -- G2 · the delegated admin really does hold automation:rw on this Google session, so the
  -- refusals below are the new gate rather than an unconfigured fixture.
  perform pg_temp.as_v626_session(v_admin,'oauth',null);
  if not app.v89_platform_can('automation','rw') then
    raise exception 'v626 G2: the fixture admin does not hold automation:rw';
  end if;

  -- G3 · WhatsApp capability grants are super-admin only now.
  perform pg_temp.as_v626_session(v_admin,'oauth');
  begin
    perform public.platform_set_capability_grant_v518(
      p_business=>v_business,p_capability=>v_unknown_capability,p_enabled=>true,
      p_limit_count=>null,p_limit_period=>null,p_note=>'v626 delegated attempt',
      p_expected_version=>0
    );
    raise exception 'v626 G3: automation:rw still set a capability grant';
  exception when sqlstate '42501' then null;
  end;

  -- G4 · retention sending holds are super-admin only now.
  begin
    perform public.platform_set_retention_hold_v574(
      p_business=>v_business,p_campaign=>null,p_held=>true,
      p_reason=>'v626 delegated attempt',p_expected_version=>0
    );
    raise exception 'v626 G4: automation:rw still placed a retention hold';
  exception when sqlstate '42501' then null;
  end;

  -- G5 · a Google super admin passes the gate: whatever happens next, it is not 42501.
  perform pg_temp.as_v626_session(v_super,'oauth');
  v_sqlstate:=null;
  begin
    perform public.platform_set_capability_grant_v518(
      p_business=>v_business,p_capability=>v_unknown_capability,p_enabled=>true,
      p_limit_count=>null,p_limit_period=>null,p_note=>'v626 super-admin probe',
      p_expected_version=>0
    );
  exception when others then
    v_sqlstate:=sqlstate;
  end;
  if v_sqlstate='42501' then
    raise exception 'v626 G5: the super admin was refused by the capability writer';
  end if;
  if v_sqlstate is distinct from '22023' then
    raise exception 'v626 G6: the capability probe failed unexpectedly [%]',
      coalesce(v_sqlstate,'no error - an unknown capability was accepted');
  end if;

  -- G7 · the same for the retention hold writer.
  v_sqlstate:=null;
  begin
    perform public.platform_set_retention_hold_v574(
      p_business=>gen_random_uuid(),p_campaign=>null,p_held=>true,
      p_reason=>'v626 super-admin probe',p_expected_version=>0
    );
  exception when others then
    v_sqlstate:=sqlstate;
  end;
  if v_sqlstate='42501' then
    raise exception 'v626 G7: the super admin was refused by the retention hold writer';
  end if;
  if v_sqlstate is distinct from '22023' then
    raise exception 'v626 G8: the retention hold probe failed unexpectedly [%]',
      coalesce(v_sqlstate,'no error - an unknown business was accepted');
  end if;

  -- G9 · and a password session holds nothing here either (v625 folded in).
  perform pg_temp.as_v626_session(v_super,'password');
  begin
    perform public.platform_set_retention_hold_v574(
      p_business=>v_business,p_campaign=>null,p_held=>true,
      p_reason=>'v626 password session attempt',p_expected_version=>0
    );
    raise exception 'v626 G9: a password-session super admin placed a retention hold';
  exception when sqlstate '42501' then null;
  end;

  perform pg_temp.as_v626_session(null);
  raise notice 'v626 automation writer suite: ALL PASS';
end
$v626_main$;

reset role;
rollback;
