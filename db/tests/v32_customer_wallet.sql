-- Rollback-only v32 customer wallet adversarial suite.
-- It proves self-derived identity/link scope, per-firm cards, allowlisted output,
-- direct-table denial, staff-only denial, unlink revocation, and function ACLs.
-- Sessions are fixed through auth.uid() claims. The tested scope is business A,
-- business B, a wrong business, verified customer_links, enabled_modules, the
-- SECURITY DEFINER search_path, and raw table grants.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_wallet_customer(p_uid uuid) returns void
language plpgsql as $$
begin
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text,
    true
  );
end;
$$;
grant execute on function pg_temp.as_wallet_customer(uuid) to public;

do $v32_test$
declare
  v_business_a uuid;
  v_business_b uuid;
  v_owner uuid;
  v_customer_a uuid := gen_random_uuid();
  v_customer_b uuid := gen_random_uuid();
  v_staff_only uuid := gen_random_uuid();
  v_identity_a uuid := gen_random_uuid();
  v_identity_b uuid := gen_random_uuid();
  v_client_a_a uuid := gen_random_uuid();
  v_client_a_b uuid := gen_random_uuid();
  v_client_b_b uuid := gen_random_uuid();
  v_link_a_a uuid := gen_random_uuid();
  v_link_a_b uuid := gen_random_uuid();
  v_link_b_b uuid := gen_random_uuid();
  v_slug_a text;
  v_slug_b text;
  v_wallet jsonb;
  v_summary jsonb;
  v_appointments jsonb;
  v_capabilities jsonb;
  v_disabled_card jsonb;
  v_function text;
begin
  reset role;
  select b.id, b.slug into v_business_a, v_slug_a
    from public.businesses b order by b.created_at, b.id limit 1;
  select b.id, b.slug into v_business_b, v_slug_b
    from public.businesses b where b.id <> v_business_a order by b.created_at, b.id limit 1;
  select s.user_id into v_owner
    from public.staff s
   where s.business_id = v_business_a
     and s.role = 'owner'
     and s.active
     and s.user_id is not null
   order by s.created_at, s.id
   limit 1;
  if v_business_a is null or v_business_b is null or v_owner is null then
    raise exception 'v32 suite requires two businesses and an active owner';
  end if;
  update public.businesses
     set enabled_modules = array['loyalty','appointments','bookings','packages','memberships']
   where id in (v_business_a, v_business_b);

  insert into auth.users(
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000', v_customer_a, 'authenticated', 'authenticated',
      'v32-customer-a@example.test', '', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', v_customer_b, 'authenticated', 'authenticated',
      'v32-customer-b@example.test', '', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', v_staff_only, 'authenticated', 'authenticated',
      'v32-staff-only@example.test', '', now(), now(), now());
  insert into public.staff(business_id, user_id, role, full_name, active)
  values (v_business_a, v_staff_only, 'frontdesk', 'V32 staff only', true);

  insert into public.customer_identities(id, auth_user_id, status, created_via)
  values
    (v_identity_a, v_customer_a, 'active', 'wallet_start'),
    (v_identity_b, v_customer_b, 'active', 'wallet_start');
  insert into public.clients(id, business_id, full_name)
  values
    (v_client_a_a, v_business_a, 'Wallet A in business A'),
    (v_client_a_b, v_business_b, 'Wallet A in business B'),
    (v_client_b_b, v_business_b, 'Wallet B in business B');

  perform set_config('app.customer_link_insert_id', v_link_a_a::text, true);
  insert into public.customer_links(
    id, business_id, identity_id, auth_user_id, client_id, state,
    verification_method, verified_at
  ) values (
    v_link_a_a, v_business_a, v_identity_a, v_customer_a, v_client_a_a,
    'verified', 'firm_invitation', now()
  );
  perform set_config('app.customer_link_insert_id', v_link_a_b::text, true);
  insert into public.customer_links(
    id, business_id, identity_id, auth_user_id, client_id, state,
    verification_method, verified_at
  ) values (
    v_link_a_b, v_business_b, v_identity_a, v_customer_a, v_client_a_b,
    'verified', 'firm_invitation', now()
  );
  perform set_config('app.customer_link_insert_id', v_link_b_b::text, true);
  insert into public.customer_links(
    id, business_id, identity_id, auth_user_id, client_id, state,
    verification_method, verified_at
  ) values (
    v_link_b_b, v_business_b, v_identity_b, v_customer_b, v_client_b_b,
    'verified', 'firm_invitation', now()
  );

  insert into public.appointments(
    business_id, client_id, starts_at, ends_at, status, total_cents, source
  ) values
    (v_business_a, v_client_a_a, now() + interval '1 day', now() + interval '1 day 30 minutes',
      'booked', 0, 'admin'),
    (v_business_b, v_client_a_b, now() + interval '2 days', now() + interval '2 days 30 minutes',
      'booked', 0, 'admin'),
    (v_business_b, v_client_b_b, now() + interval '3 days', now() + interval '3 days 30 minutes',
      'booked', 0, 'admin');

  -- A frontend flag is not the launch boundary. The private database gate starts
  -- closed and only an operator-controlled write can open the customer read API.
  perform pg_temp.as_wallet_customer(v_customer_a);
  begin
    perform public.customer_get_wallet();
    raise exception 'customer wallet RPC ignored the closed platform feature gate';
  exception when feature_not_supported then null;
  end;
  reset role;
  update app.platform_feature_flags set enabled=true,changed_at=now()
   where feature_key in ('customer_wallet','customer_claims');

  -- Customer A has two independent firms. The wallet must be an array, not one
  -- cross-firm total, and a business B appointment must not include customer B.
  perform pg_temp.as_wallet_customer(v_customer_a);
  v_wallet := public.customer_get_wallet();
  if jsonb_typeof(v_wallet) <> 'array' or jsonb_array_length(v_wallet) <> 2 then
    raise exception 'customer A wallet is not an array of two independent firm cards';
  end if;
  if exists (
    select 1 from jsonb_array_elements(v_wallet) card
     where not (card ? 'business') or card ? 'total' or card ? 'aggregate'
  ) then
    raise exception 'wallet exposed a cross-firm aggregate instead of firm cards';
  end if;
  v_summary := public.customer_get_business_summary(v_slug_b);
  if v_summary #>> '{business,slug}' is distinct from v_slug_b then
    raise exception 'customer A could not resolve only its verified business B summary';
  end if;
  v_appointments := public.customer_get_appointments(v_slug_b);
  if jsonb_typeof(v_appointments) <> 'array' or jsonb_array_length(v_appointments) <> 1 then
    raise exception 'customer A saw another customer or wrong-firm appointments';
  end if;
  v_capabilities := public.customer_portal_capabilities(v_slug_b);
  if v_capabilities ? 'email' or v_capabilities ? 'phone' or v_capabilities ? 'notes'
     or v_capabilities ? 'internal' then
    raise exception 'capabilities output exposed PII or internal keys';
  end if;

  if v_wallet::text ~* '"(email|phone|notes|internal|auth_user_id|contact_fingerprint)"' then
    raise exception 'wallet output contains a prohibited PII or internal key';
  end if;
  if v_summary::text ~* '"(email|phone|notes|internal|auth_user_id|contact_fingerprint)"'
     or v_appointments::text ~* '"(email|phone|notes|internal|auth_user_id|contact_fingerprint)"' then
    raise exception 'summary or appointments output contains a prohibited PII or internal key';
  end if;

  -- Disabled modules remove both the data and the direct appointments reader.
  reset role;
  update public.businesses set enabled_modules = array['dashboard'] where id = v_business_b;
  perform pg_temp.as_wallet_customer(v_customer_a);
  v_wallet := public.customer_get_wallet();
  select card into v_disabled_card
    from jsonb_array_elements(v_wallet) card
   where card #>> '{business,slug}' = v_slug_b;
  if v_disabled_card is null
     or v_disabled_card #>> '{loyalty,enabled}' is distinct from 'false'
     or v_disabled_card #>> '{loyalty,balance}' is distinct from '0'
     or v_disabled_card #>> '{loyalty,credit_balance_cents}' is distinct from '0'
     or v_disabled_card #>> '{packages,enabled}' is distinct from 'false'
     or v_disabled_card #>> '{packages,active_count}' is distinct from '0'
     or v_disabled_card #>> '{packages,sessions_remaining}' is distinct from '0'
     or v_disabled_card #>> '{membership,enabled}' is distinct from 'false'
     or v_disabled_card #>> '{membership,active}' is distinct from 'false'
     or v_disabled_card #>> '{upcoming_appointments,enabled}' is distinct from 'false'
     or v_disabled_card #>> '{upcoming_appointments,count}' is distinct from '0' then
    raise exception 'wallet disclosed disabled-module data';
  end if;
  v_summary := public.customer_get_business_summary(v_slug_b);
  if v_summary #>> '{loyalty,enabled}' is distinct from 'false'
     or v_summary #>> '{loyalty,balance}' is distinct from '0'
     or v_summary #>> '{loyalty,credit_balance_cents}' is distinct from '0'
     or v_summary #>> '{packages,enabled}' is distinct from 'false'
     or v_summary #>> '{packages,active_count}' is distinct from '0'
     or v_summary #>> '{packages,sessions_remaining}' is distinct from '0'
     or v_summary #>> '{membership,enabled}' is distinct from 'false'
     or v_summary #>> '{membership,active}' is distinct from 'false'
     or v_summary #>> '{upcoming_appointments,enabled}' is distinct from 'false'
     or v_summary #>> '{upcoming_appointments,count}' is distinct from '0' then
    raise exception 'business summary disclosed disabled-module data';
  end if;
  begin
    perform public.customer_get_appointments(v_slug_b);
    raise exception 'appointments reader ignored disabled appointments module';
  exception when insufficient_privilege then null;
  end;
  v_capabilities := public.customer_portal_capabilities(v_slug_b);
  if coalesce((v_capabilities->>'wallet')::boolean, true)
     or coalesce((v_capabilities->>'appointments')::boolean, true)
     or coalesce((v_capabilities->>'packages')::boolean, true)
     or coalesce((v_capabilities->>'membership')::boolean, true) then
    raise exception 'capabilities exposed a disabled module';
  end if;

  -- Customer B is linked only to business B, so business A is indistinguishable
  -- from any other unavailable firm and must not reveal its data.
  perform pg_temp.as_wallet_customer(v_customer_b);
  begin
    perform public.customer_get_business_summary(v_slug_a);
    raise exception 'customer B read customer A business summary';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.customer_get_appointments(v_slug_a);
    raise exception 'customer B read customer A appointments';
  exception when insufficient_privilege then null;
  end;

  -- A staff login is not a customer identity. Holding a staff role alone cannot
  -- call the customer wallet boundary.
  perform pg_temp.as_wallet_customer(v_staff_only);
  begin
    perform public.customer_get_wallet();
    raise exception 'staff-only user accessed customer wallet';
  exception when insufficient_privilege then null;
  end;

  -- A self-unlink removes every customer-facing read for that firm immediately.
  perform pg_temp.as_wallet_customer(v_customer_a);
  if public.customer_unlink_business_link(v_slug_b, 'v32-unlink-customer-a')->>'outcome'
       is distinct from 'unlinked' then
    raise exception 'v32 unlink fixture did not complete';
  end if;
  if jsonb_array_length(public.customer_get_wallet()) <> 1 then
    raise exception 'unlinked firm remained visible in wallet';
  end if;
  begin
    perform public.customer_portal_capabilities(v_slug_b);
    raise exception 'unlinked customer retained business capabilities';
  exception when insufficient_privilege then null;
  end;

  reset role;
  foreach v_function in array array[
    'public.customer_get_wallet()',
    'public.customer_get_business_summary(text)',
    'public.customer_get_appointments(text)',
    'public.customer_portal_capabilities(text)'
  ] loop
    if not has_function_privilege('authenticated', v_function, 'execute')
       or has_function_privilege('anon', v_function, 'execute')
       or exists (
         select 1
           from pg_proc p
           cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
          where p.oid = to_regprocedure(v_function)
            and acl.grantee = 0
            and acl.privilege_type = 'EXECUTE'
       ) then
      raise exception 'wallet RPC ACL is incorrect for %', v_function;
    end if;
  end loop;
  if has_table_privilege('authenticated', 'public.customer_links', 'select')
     or has_table_privilege('anon', 'public.customer_links', 'select')
     or has_table_privilege('authenticated', 'public.customer_identities', 'select')
     or has_table_privilege('anon', 'public.customer_identities', 'select') then
    raise exception 'raw customer link or identity table grant is open';
  end if;

  perform pg_temp.as_wallet_customer(v_customer_a);
  begin
    perform 1 from public.customer_links;
    raise exception 'authenticated customer directly read raw customer links table';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from public.customer_identities;
    raise exception 'authenticated customer directly read raw customer identities table';
  exception when insufficient_privilege then null;
  end;

  raise notice 'v32 customer wallet suite: ALL PASS';
end;
$v32_test$;

rollback;
