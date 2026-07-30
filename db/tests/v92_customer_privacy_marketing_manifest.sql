-- Rollback-only v92 customer Privacy Notice manifest acceptance suite.
-- Run after the canonical chain through v92 in a disposable rehearsal database.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.v92_as_customer(p_uid uuid) returns void
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
grant execute on function pg_temp.v92_as_customer(uuid) to public;

do $v92_test$
begin
  if (
    select count(*)
      from app.customer_legal_documents d
     where d.document_key = 'privacy'
       and d.document_version = '2026-07-28'
       and d.document_sha256 = '994400cadc703134d9c8bd3868fe054f94e37153c47c2d2e688064bdc75138c9'
       and d.published_at = timestamptz '2026-07-28 00:00:00+08:00'
       and d.active
  ) <> 1 then
    raise exception 'v92 approved Nestly privacy manifest is not exact';
  end if;

  if has_table_privilege('anon', 'app.customer_legal_documents', 'select')
     or has_table_privilege('authenticated', 'app.customer_legal_documents', 'select')
     or has_table_privilege('anon', 'app.customer_legal_documents', 'insert')
     or has_table_privilege('authenticated', 'app.customer_legal_documents', 'insert')
     or has_table_privilege('anon', 'app.customer_legal_documents', 'update')
     or has_table_privilege('authenticated', 'app.customer_legal_documents', 'update')
     or has_table_privilege('anon', 'app.customer_legal_documents', 'delete')
     or has_table_privilege('authenticated', 'app.customer_legal_documents', 'delete') then
    raise exception 'v92 widened browser access to the private legal manifest';
  end if;

  if has_table_privilege('anon', 'public.customer_platform_marketing_consent_events', 'select')
     or has_table_privilege('authenticated', 'public.customer_platform_marketing_consent_events', 'select')
     or has_table_privilege('anon', 'public.customer_platform_marketing_consent_events', 'insert')
     or has_table_privilege('authenticated', 'public.customer_platform_marketing_consent_events', 'insert')
     or has_table_privilege('anon', 'public.customer_platform_marketing_consent_events', 'update')
     or has_table_privilege('authenticated', 'public.customer_platform_marketing_consent_events', 'update')
     or has_table_privilege('anon', 'public.customer_platform_marketing_consent_events', 'delete')
     or has_table_privilege('authenticated', 'public.customer_platform_marketing_consent_events', 'delete') then
    raise exception 'v92 exposed private marketing consent evidence';
  end if;

  if has_function_privilege('anon', 'public.customer_get_platform_marketing_preference()', 'execute')
     or has_function_privilege('anon', 'public.customer_set_platform_marketing_preference(boolean,text)', 'execute')
     or not has_function_privilege('authenticated', 'public.customer_get_platform_marketing_preference()', 'execute')
     or not has_function_privilege('authenticated', 'public.customer_set_platform_marketing_preference(boolean,text)', 'execute') then
    raise exception 'v92 marketing preference RPC ACLs are not exact';
  end if;

  raise notice 'v92 Nestly privacy marketing manifest suite: ALL PASS';
end
$v92_test$;

do $v92_idempotency_test$
declare
  v_user uuid := gen_random_uuid();
  v_identity uuid := gen_random_uuid();
  v_key text := 'v92-noop-' || gen_random_uuid()::text;
  v_result jsonb;
begin
  reset role;
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000', v_user,
    'authenticated', 'authenticated',
    'v92-' || v_user::text || '@example.test', '', now(), now(), now()
  );
  insert into public.customer_identities (
    id, auth_user_id, status, created_via
  ) values (
    v_identity, v_user, 'active', 'wallet_start'
  );
  insert into public.customer_registration_preferences (
    identity_id, auth_user_id, platform_marketing_opted_in
  ) values (
    v_identity, v_user, false
  );

  perform pg_temp.v92_as_customer(v_user);
  v_result := public.customer_set_platform_marketing_preference(false, v_key);
  if v_result <> jsonb_build_object('outcome', 'updated', 'opted_in', false) then
    raise exception 'v92 unchanged preference did not return the canonical response';
  end if;
  v_result := public.customer_set_platform_marketing_preference(false, v_key);
  if v_result <> jsonb_build_object('outcome', 'updated', 'opted_in', false) then
    raise exception 'v92 exact unchanged-preference replay was not stable';
  end if;

  begin
    perform public.customer_set_platform_marketing_preference(true, v_key);
    raise exception 'v92 changed-payload idempotency-key reuse was accepted';
  exception
    when unique_violation then null;
  end;

  reset role;
  if (
    select count(*)
      from public.customer_platform_marketing_consent_events e
     where e.identity_id = v_identity
       and e.idempotency_key = v_key
       and not e.opted_in
  ) <> 1 then
    raise exception 'v92 unchanged preference did not reserve exactly one immutable operation';
  end if;
  if (
    select p.platform_marketing_opted_in
      from public.customer_registration_preferences p
     where p.identity_id = v_identity
  ) then
    raise exception 'v92 changed-payload replay mutated the preference';
  end if;
end
$v92_idempotency_test$;

rollback;
