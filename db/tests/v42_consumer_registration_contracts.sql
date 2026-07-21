-- FRENLY C42 acceptance contract — run only after the pending migration chain.
-- This fixture changes no persistent data and verifies the deliberately tiny
-- pre-auth OTP capability surface remains explicitly granted and fail-closed.

begin;

do $$
declare
  v_otp_capabilities regprocedure := to_regprocedure('public.get_customer_phone_otp_capabilities()');
  v_customer_capabilities regprocedure := to_regprocedure('public.get_customer_feature_capabilities()');
begin
  if v_otp_capabilities is null then
    raise exception 'C42 public OTP capability RPC is missing';
  end if;
  if not has_function_privilege('anon', v_otp_capabilities, 'execute')
     or not has_function_privilege('authenticated', v_otp_capabilities, 'execute') then
    raise exception 'C42 OTP capability RPC must grant only the intended browser roles';
  end if;
  if exists (
    select 1
      from pg_proc p
      cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
     where p.oid = v_otp_capabilities
       and acl.grantee = 0
       and acl.privilege_type = 'EXECUTE'
  ) then
    raise exception 'C42 OTP capability RPC must not retain PUBLIC execution';
  end if;
  if v_customer_capabilities is null
     or has_function_privilege('anon', v_customer_capabilities, 'execute') then
    raise exception 'C42 authenticated customer capability RPC must remain anonymous-closed';
  end if;
end;
$$;

rollback;
