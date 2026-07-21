-- Rollback-only v30 customer identity isolation and adversarial suite.
begin;

create or replace function pg_temp.as_identity_user(p_uid uuid) returns void
language plpgsql
as $$
begin
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end;
$$;
grant execute on function pg_temp.as_identity_user(uuid) to public;

do $v30_test$
declare
  v_customer_a uuid := gen_random_uuid();
  v_customer_b uuid := gen_random_uuid();
  v_staff_user uuid;
  v_identity_a uuid;
  v_identity_b uuid;
  v_dual_identity uuid;
  v_result jsonb;
  v_first_result jsonb;
  v_before integer;
  v_after integer;
  v_acl_table text;
  v_proc oid;
begin
  reset role;
  update app.platform_feature_flags set enabled = true, changed_at = now()
   where feature_key = 'customer_identity';
  insert into auth.users(
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000', v_customer_a, 'authenticated', 'authenticated',
      'v30-customer-a@example.test', '', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', v_customer_b, 'authenticated', 'authenticated',
      'v30-customer-b@example.test', '', now(), now(), now());
  select count(*) into v_before from public.clients;

  select s.user_id into v_staff_user
    from public.staff s
    join auth.users u on u.id = s.user_id
   where s.active and s.user_id is not null and u.email_confirmed_at is not null
   order by s.created_at
   limit 1;
  if v_staff_user is null then
    raise exception 'v30 suite requires an active staff user with a confirmed email';
  end if;

  perform pg_temp.as_identity_user(v_customer_a);
  v_result := public.customer_create_identity('v30-customer-a-create');
  v_first_result := v_result;
  v_identity_a := (v_result->>'identity_id')::uuid;
  if coalesce((v_result->>'created')::boolean, false) is not true then
    raise exception 'customer identity was not created';
  end if;
  if v_result ? 'email' or v_result ? 'phone' or v_result ? 'contact_fingerprint'
     or v_result ? 'request_hash' or v_result ? 'verification_proof_id' then
    raise exception 'create RPC exposed contact or request material';
  end if;
  if public.customer_create_identity('v30-customer-a-create') is distinct from v_first_result then
    raise exception 'identity creation retry did not return the byte-equivalent response';
  end if;
  reset role;
  if (select count(*) from public.customer_identity_audit_events
       where identity_id = v_identity_a and event_type = 'identity_created') <> 1 then
    raise exception 'identity create retry wrote more than one audit event';
  end if;
  if (select count(*) from public.customer_verified_contacts
       where identity_id = v_identity_a and contact_type = 'email' and status = 'verified') <> 1 then
    raise exception 'verified email evidence was not created';
  end if;
  if not exists (
    select 1 from public.customer_contact_proofs p
     where p.identity_id = v_identity_a and p.status = 'verified'
       and p.expires_at > p.issued_at and p.expires_at > now()
  ) then
    raise exception 'customer contact proof does not expire';
  end if;

  -- A second authenticated user sees only their own empty identity state, then
  -- creates a distinct platform identity. There are still no customer links.
  perform pg_temp.as_identity_user(v_customer_b);
  if public.customer_get_identity()->>'identity' is distinct from null then
    raise exception 'uncreated customer identity did not return the empty self state';
  end if;
  v_result := public.customer_create_identity('v30-customer-b-create');
  v_identity_b := (v_result->>'identity_id')::uuid;
  if v_identity_b = v_identity_a then
    raise exception 'two auth users resolved to the same customer identity';
  end if;
  if public.customer_get_identity()->>'identity_id' is distinct from v_identity_b::text then
    raise exception 'customer B did not resolve only their own identity';
  end if;

  -- Existing staff authentication is independent. The same auth user can hold
  -- a customer identity without touching staff membership or gaining a link.
  perform pg_temp.as_identity_user(v_staff_user);
  v_dual_identity := (public.customer_create_identity('v30-dual-role-create')->>'identity_id')::uuid;
  if v_dual_identity is null then
    raise exception 'staff user could not independently create a customer identity';
  end if;
  reset role;
  if not exists (select 1 from public.staff where user_id = v_staff_user and active) then
    raise exception 'customer identity creation changed staff membership';
  end if;

  reset role;
  select count(*) into v_after from public.clients;
  if v_before <> v_after then
    raise exception 'v30 identity flow changed legacy client rows';
  end if;
  if exists (
    select 1 from public.customer_links
     where identity_id in (v_identity_a, v_identity_b, v_dual_identity)
  ) then
    raise exception 'v30 identity creation must not create customer links';
  end if;

  -- A raw-table caller cannot read, write, or discover identity/proof/audit data.
  foreach v_acl_table in array array[
    'public.customer_identities', 'public.customer_contact_proofs',
    'public.customer_verified_contacts', 'public.customer_identity_audit_events'
  ] loop
    if has_table_privilege('anon', v_acl_table, 'select')
       or has_table_privilege('authenticated', v_acl_table, 'select')
       or has_table_privilege('anon', v_acl_table, 'insert')
       or has_table_privilege('authenticated', v_acl_table, 'insert') then
      raise exception 'customer identity raw table ACL is open for %', v_acl_table;
    end if;
  end loop;
  if exists (
    select 1
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      cross join lateral aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) acl
     where n.nspname = 'public'
       and c.relname in (
         'customer_identities', 'customer_contact_proofs',
         'customer_verified_contacts', 'customer_identity_audit_events'
       )
       and acl.grantee = 0
  ) then
    raise exception 'customer identity raw table has a PUBLIC grant';
  end if;

  select p.oid into v_proc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_create_identity'
     and pg_get_function_identity_arguments(p.oid) = 'p_idempotency_key text';
  if v_proc is null
     or not has_function_privilege('authenticated', v_proc, 'execute')
     or has_function_privilege('anon', v_proc, 'execute')
     or exists (
       select 1 from aclexplode(coalesce((select proacl from pg_proc where oid = v_proc),
                                          acldefault('f', (select proowner from pg_proc where oid = v_proc)))) acl
        where acl.grantee = 0 and acl.privilege_type = 'EXECUTE'
     ) then
    raise exception 'customer_create_identity ACL is incorrect';
  end if;
  if not has_function_privilege('authenticated', 'public.customer_get_identity()', 'execute')
     or has_function_privilege('anon', 'public.customer_get_identity()', 'execute') then
    raise exception 'customer_get_identity ACL is incorrect';
  end if;

  perform pg_temp.as_identity_user(v_customer_a);
  begin
    perform 1 from public.customer_identities;
    raise exception 'authenticated raw identity read unexpectedly succeeded';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.customer_identities set auth_user_id = v_customer_b where id = v_identity_a;
    raise exception 'authenticated identity mapping update unexpectedly succeeded';
  exception when insufficient_privilege then null;
  end;

  reset role;
  begin
    update public.customer_identities set auth_user_id = v_customer_b where id = v_identity_a;
    raise exception 'identity mapping was mutable for the owner';
  exception when integrity_constraint_violation then null;
  end;
  begin
    insert into public.customer_contact_proofs(
      identity_id, auth_user_id, contact_type, proof_method, status,
      issued_at, expires_at
    ) values (
      v_identity_a, v_customer_a, 'email', 'email_otp', 'expired', now(), now()
    );
    raise exception 'non-expiring proof was accepted';
  exception when check_violation then null;
  end;
  begin
    insert into public.customer_contact_proofs(
      identity_id, auth_user_id, contact_type, proof_method, status,
      issued_at, expires_at
    ) values (
      v_identity_a, v_customer_a, 'phone', 'support_recovery', 'expired',
      now(), now() + interval '15 minutes'
    );
    raise exception 'phone proof was accepted by v30';
  exception when check_violation then null;
  end;
  begin
    update public.customer_contact_proofs set status = 'revoked' where identity_id = v_identity_a;
    raise exception 'customer contact proof evidence was mutable for the owner';
  exception when integrity_constraint_violation then null;
  end;

  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('customer_create_identity', 'customer_get_identity')
       and pg_get_functiondef(p.oid) ~* 'public\\.clients'
  ) then
    raise exception 'v30 customer RPC unexpectedly references legacy clients';
  end if;

  raise notice 'v30 customer identity suite: ALL PASS';
end;
$v30_test$;

rollback;
