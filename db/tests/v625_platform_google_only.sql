-- Rollback-only acceptance for NESTLY v625 — platform authority requires a Google sign-in.
--
-- Proves, at the server boundary only, that the TWO roots every platform permission resolves
-- through judge the JWT the request actually carries:
--   · app.is_super_admin() is true only when super_admins holds auth.uid() AND the session was
--     minted by an OAuth flow (amr[0].method='oauth') AND the account is linked to Google
--     (app_metadata.providers contains 'google');
--   · app.v89_platform_role() returns null on any non-Google session, so a delegated grant
--     holds no authority on a password login;
--   · a JWT with NO amr claim FAILS CLOSED;
--   · the effect reaches RLS: the <t>_sa_read policies stop returning cross-tenant rows on a
--     password session.
--
-- Self-contained fixtures (gen_random_uuid) and one transaction that ends in rollback — safe
-- to run against production.
begin;

-- Raw-claims simulator: the suite needs JWT shapes the other suites never build (no amr at
-- all, and OAuth against a provider that is not Google). p_role null keeps the privileged
-- session role, because app.v89_platform_role is deliberately not executable by authenticated.
create or replace function pg_temp.as_v625_session(
  p_uid uuid,
  p_claims jsonb,
  p_role text default null
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
  perform set_config('request.jwt.claims',p_claims::text,true);
end
$fn$;
grant execute on function pg_temp.as_v625_session(uuid,jsonb,text) to public;

do $v625_main$
declare
  v_super uuid:=gen_random_uuid();
  v_admin uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_google jsonb;
  v_password jsonb;
  v_no_amr jsonb;
  v_other_oauth jsonb;
  v_role text;
  v_visible bigint;
begin
  reset role;

  -- F1 · the Google predicate is server-only; the super-admin root stays callable by RLS.
  if has_function_privilege(
       'authenticated','app.platform_session_via_google_v625()','EXECUTE')
     or has_function_privilege('anon','app.platform_session_via_google_v625()','EXECUTE')
     or not has_function_privilege('authenticated','app.is_super_admin()','EXECUTE')
     or has_function_privilege('authenticated','app.v89_platform_role()','EXECUTE') then
    raise exception 'v625 F1: platform-root ACLs are not fail-closed';
  end if;

  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) select
    '00000000-0000-0000-0000-000000000000',user_id,
    'authenticated','authenticated',email,'',now(),now(),now()
  from (values
    (v_super,'v625-super-'||substr(v_super::text,1,8)||'@example.test'),
    (v_admin,'v625-admin-'||substr(v_admin::text,1,8)||'@example.test')
  ) fixture(user_id,email);
  insert into public.super_admins(user_id,email,note)
  values(
    v_super,'v625-super-'||substr(v_super::text,1,8)||'@example.test',
    'rollback-only v625 fixture'
  );
  insert into public.platform_access_grants_v89(
    user_id,role,module_perms,created_by,updated_by
  ) values(v_admin,'admin','{"*":"r"}'::jsonb,v_super,v_super);

  insert into public.businesses(id,name,slug,industry,enabled_modules)
  values(
    v_business,'V625 platform session fixture',
    'v625-'||substr(v_business::text,1,8),'test',
    array['dashboard','clients','sales','loyalty','retention','reports']
  );

  v_google:=jsonb_build_object(
    'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth','timestamp',1756500000)),
    'app_metadata',jsonb_build_object(
      'provider','google','providers',jsonb_build_array('email','google'))
  );
  v_password:=jsonb_build_object(
    'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','password','timestamp',1756500000)),
    'app_metadata',jsonb_build_object(
      'provider','email','providers',jsonb_build_array('email','google'))
  );
  v_no_amr:=jsonb_build_object(
    'role','authenticated',
    'app_metadata',jsonb_build_object(
      'provider','google','providers',jsonb_build_array('email','google'))
  );
  v_other_oauth:=jsonb_build_object(
    'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth','timestamp',1756500000)),
    'app_metadata',jsonb_build_object(
      'provider','azure','providers',jsonb_build_array('email','azure'))
  );

  -- F2 · a password session holds no super-admin authority, even for a listed super admin
  -- whose account IS linked to Google.
  perform pg_temp.as_v625_session(v_super,v_password||jsonb_build_object('sub',v_super));
  if app.is_super_admin() then
    raise exception 'v625 F2: a password session kept super-admin authority';
  end if;
  if app.v89_platform_role() is not null then
    raise exception 'v625 F3: a password session kept a platform role';
  end if;

  -- F4 · the same identity on a Google session is the super admin.
  perform pg_temp.as_v625_session(v_super,v_google||jsonb_build_object('sub',v_super));
  if not app.is_super_admin() then
    raise exception 'v625 F4: a Google session lost super-admin authority';
  end if;
  select app.v89_platform_role() into v_role;
  if v_role is distinct from 'super_admin' then
    raise exception 'v625 F5: the Google super-admin role resolved to %',v_role;
  end if;

  -- F6 · a JWT with no amr claim at all fails closed.
  perform pg_temp.as_v625_session(v_super,v_no_amr||jsonb_build_object('sub',v_super));
  if app.is_super_admin() then
    raise exception 'v625 F6: a session with no amr claim was treated as Google';
  end if;
  if app.v89_platform_role() is not null then
    raise exception 'v625 F7: a session with no amr claim kept a platform role';
  end if;

  -- F8 · an OAuth session against an account not linked to Google is not enough.
  perform pg_temp.as_v625_session(v_super,v_other_oauth||jsonb_build_object('sub',v_super));
  if app.is_super_admin() then
    raise exception 'v625 F8: a non-Google OAuth session was accepted';
  end if;

  -- F9 · delegated operators follow the same rule in both directions.
  perform pg_temp.as_v625_session(v_admin,v_google||jsonb_build_object('sub',v_admin));
  select app.v89_platform_role() into v_role;
  if v_role is distinct from 'admin' then
    raise exception 'v625 F9: a Google delegated admin resolved to %',v_role;
  end if;
  perform pg_temp.as_v625_session(v_admin,v_password||jsonb_build_object('sub',v_admin));
  if app.v89_platform_role() is not null then
    raise exception 'v625 F10: a password-session delegated admin kept its grant';
  end if;

  -- F11 · the effect reaches RLS, not just the predicates: the sa_read policies stop
  -- returning another tenant's rows on a password session, and resume on a Google one.
  perform pg_temp.as_v625_session(
    v_super,v_password||jsonb_build_object('sub',v_super),'authenticated'
  );
  select count(*) into v_visible from public.businesses where id=v_business;
  if v_visible<>0 then
    raise exception 'v625 F11: a password session still read a tenant through sa_read (% rows)',
      v_visible;
  end if;
  perform pg_temp.as_v625_session(
    v_super,v_google||jsonb_build_object('sub',v_super),'authenticated'
  );
  select count(*) into v_visible from public.businesses where id=v_business;
  if v_visible<>1 then
    raise exception 'v625 F12: a Google super-admin session lost cross-tenant read (% rows)',
      v_visible;
  end if;

  perform pg_temp.as_v625_session(null,'{}'::jsonb);
  raise notice 'v625 platform Google-only suite: ALL PASS';
end
$v625_main$;

reset role;
rollback;
