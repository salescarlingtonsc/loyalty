-- Rollback-only v50a suite: SGT-correct birth-date validation.
-- Run after the canonical chain through v50a in a disposable rehearsal DB.
-- Regression-proof at any time of day: it asserts the catalog is SGT-corrected and
-- behaviourally exercises SGT-today (accept) and SGT-tomorrow (reject) on both the
-- customer_profiles guard and the registration RPC. Every fixture row rolls back.
begin;

create or replace function pg_temp.as_v50a(p_uid uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', p_role)::text, true);
  execute format('set local role %I', p_role);
end $$;
grant execute on function pg_temp.as_v50a(uuid, text) to public;

create or replace function pg_temp.expect_v50a(p_sql text, p_label text, p_sqlstate text default '22023')
returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception '% unexpectedly succeeded', p_label;
exception when others then
  if sqlstate <> p_sqlstate then
    raise exception '% failed with %, expected %: %', p_label, sqlstate, p_sqlstate, sqlerrm;
  end if;
end $$;
grant execute on function pg_temp.expect_v50a(text, text, text) to public;

do $v50a_test$
declare
  v_src_guard text;
  v_src_register text;
  v_sgt_today date := (timezone('Asia/Singapore', statement_timestamp()))::date;
  v_sgt_tomorrow date := (timezone('Asia/Singapore', statement_timestamp()))::date + 1;
  v_cust_a uuid := gen_random_uuid();
  v_cust_b uuid := gen_random_uuid();
  v_id_a uuid := gen_random_uuid();
  v_id_b uuid := gen_random_uuid();
  v_cust_accept uuid := gen_random_uuid();
  v_cust_reject uuid := gen_random_uuid();
  v_response jsonb;
begin
  reset role;

  -- (d) Catalog assertion: both validators are SGT-corrected, no bare current_date.
  select p.prosrc into v_src_guard from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'c42_profile_guard';
  select p.prosrc into v_src_register from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_register_verified_phone';
  if v_src_guard is null or v_src_register is null then
    raise exception 'v50a could not resolve the two c42 birth-date validators';
  end if;
  if position('birth_date > current_date' in v_src_guard) <> 0
     or position('birth_date > current_date' in v_src_register) <> 0 then
    raise exception 'a bare "> current_date" birth-date check survives';
  end if;
  if position('(timezone(''Asia/Singapore'', now()))::date' in v_src_guard) = 0
     or position('(timezone(''Asia/Singapore'', now()))::date' in v_src_register) = 0 then
    raise exception 'the SGT-corrected birth-date comparison is not present';
  end if;

  -- Common auth fixtures.
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values
    ('00000000-0000-0000-0000-000000000000', v_cust_a, 'authenticated', 'authenticated', 'v50a-a-'||substr(v_cust_a::text,1,8)||'@example.test', '', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', v_cust_b, 'authenticated', 'authenticated', 'v50a-b-'||substr(v_cust_b::text,1,8)||'@example.test', '', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', v_cust_accept, 'authenticated', 'authenticated', 'v50a-acc-'||substr(v_cust_accept::text,1,8)||'@example.test', '', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', v_cust_reject, 'authenticated', 'authenticated', 'v50a-rej-'||substr(v_cust_reject::text,1,8)||'@example.test', '', now(), now(), now());

  -- ---------------------------------------------------------------------------
  -- (a)/(b) The customer_profiles write guard, exactly as v45 inserts profiles.
  -- ---------------------------------------------------------------------------
  insert into public.customer_identities(id, auth_user_id, status, created_via)
  values (v_id_a, v_cust_a, 'active', 'phone_registration'),
         (v_id_b, v_cust_b, 'active', 'phone_registration');

  -- (a) SGT-today succeeds through the guarded path.
  perform set_config('app.c42_profile_identity', v_id_a::text, true);
  insert into public.customer_profiles(identity_id, auth_user_id, full_name, birth_date)
  values (v_id_a, v_cust_a, 'V50a today', v_sgt_today);
  if not exists (select 1 from public.customer_profiles where identity_id = v_id_a and birth_date = v_sgt_today) then
    raise exception 'SGT-today birth date was not accepted by the guard';
  end if;
  perform set_config('app.c42_profile_identity', '', true);

  -- (b) SGT-tomorrow is rejected with 22023.
  perform set_config('app.c42_profile_identity', v_id_b::text, true);
  begin
    insert into public.customer_profiles(identity_id, auth_user_id, full_name, birth_date)
    values (v_id_b, v_cust_b, 'V50a tomorrow', v_sgt_tomorrow);
    raise exception 'SGT-tomorrow birth date was accepted by the guard';
  exception when invalid_parameter_value then null;  -- 22023
  end;
  perform set_config('app.c42_profile_identity', '', true);

  -- ---------------------------------------------------------------------------
  -- (c) The registration RPC. Enable the gated features and publish legal docs.
  -- ---------------------------------------------------------------------------
  update app.platform_feature_flags set enabled = true, changed_at = statement_timestamp()
   where feature_key in ('customer_phone_registration', 'customer_phone_otp');
  insert into app.customer_legal_documents(document_key, document_version, document_sha256, published_at, active)
  values ('terms', 'v50a-1', md5('v50a-terms')||md5('terms-v50a'), now(), true),
         ('privacy', 'v50a-1', md5('v50a-privacy')||md5('privacy-v50a'), now(), true)
  on conflict (document_key) do update set
    document_version = excluded.document_version, document_sha256 = excluded.document_sha256,
    published_at = excluded.published_at, active = true;
  -- The accept customer needs a verified phone; the reject fails validation first.
  update auth.users set phone = '+6581' || substr(v_cust_accept::text, 1, 6), phone_confirmed_at = now()
   where id = v_cust_accept;

  -- (c) accept: SGT-today registers cleanly (also exercises the guard via the RPC).
  perform pg_temp.as_v50a(v_cust_accept, 'authenticated');
  v_response := public.customer_register_verified_phone(
    'V50a Accept', v_sgt_today, 'en', true, true, false, 'v50a-accept-key-01');
  if v_response->>'outcome' <> 'registered' then
    raise exception 'SGT-today registration did not succeed: %', v_response;
  end if;

  -- (c) reject: SGT-tomorrow fails input validation with 22023.
  perform pg_temp.as_v50a(v_cust_reject, 'authenticated');
  perform pg_temp.expect_v50a(
    format('select public.customer_register_verified_phone(%L,%L,%L,true,true,false,%L)',
           'V50a Reject', v_sgt_tomorrow, 'en', 'v50a-reject-key-01'),
    'SGT-tomorrow registration');

  reset role;
  raise notice 'v50a SGT birth-date guard suite: ALL PASS';
end $v50a_test$;

reset role;
rollback;
