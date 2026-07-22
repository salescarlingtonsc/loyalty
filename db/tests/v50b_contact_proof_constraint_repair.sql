-- Rollback-only v50b suite: contact-proof constraint repair.
-- Run after the canonical chain through v50b in a disposable rehearsal DB. Proves the
-- stale email-only proof_method check is gone, phone registration now succeeds end to
-- end, and email proofs remain correctly constrained. Every fixture row rolls back.
begin;

create or replace function pg_temp.as_v50b(p_uid uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', p_role)::text, true);
  execute format('set local role %I', p_role);
end $$;
grant execute on function pg_temp.as_v50b(uuid, text) to public;

do $v50b_test$
declare
  v_method_type text;
  v_dupes integer;
  v_sgt_today date := (timezone('Asia/Singapore', statement_timestamp()))::date;
  v_cust uuid := gen_random_uuid();
  v_cust_email uuid := gen_random_uuid();
  v_id_email uuid := gen_random_uuid();
  v_identity uuid;
  v_response jsonb;
begin
  reset role;

  -- ---------------------------------------------------------------------------
  -- (a) Catalog: stale constraint gone; method_type_check intact; no family dupes.
  -- ---------------------------------------------------------------------------
  if exists (
    select 1 from pg_constraint
     where conrelid = 'public.customer_contact_proofs'::regclass
       and conname = 'customer_contact_proofs_proof_method_check'
  ) then
    raise exception 'the stale customer_contact_proofs_proof_method_check still exists';
  end if;

  select pg_get_constraintdef(c.oid) into v_method_type
    from pg_constraint c
   where c.conrelid = 'public.customer_contact_proofs'::regclass
     and c.conname = 'customer_contact_proofs_method_type_check' and c.contype = 'c';
  if v_method_type is null
     or position('contact_type' in v_method_type) = 0
     or position('proof_method' in v_method_type) = 0
     or position('auth_phone_otp' in v_method_type) = 0
     or position('auth_email_confirmation' in v_method_type) = 0
     or position('email_otp' in v_method_type) = 0
     or position('firm_invitation' in v_method_type) = 0
     or position('support_recovery' in v_method_type) = 0 then
    raise exception 'method_type_check is missing or not the expected c42 combined definition: %', v_method_type;
  end if;

  -- Sweep 1: no check on this table references proof_method without admitting the phone method.
  if exists (
    select 1 from pg_constraint c
     where c.conrelid = 'public.customer_contact_proofs'::regclass and c.contype = 'c'
       and position('proof_method' in pg_get_constraintdef(c.oid)) > 0
       and position('auth_phone_otp' in pg_get_constraintdef(c.oid)) = 0
  ) then
    raise exception 'a proof_method check without the phone method survives on customer_contact_proofs';
  end if;

  -- Sweep 2: no c42-family table carries two single-column check constraints on one column
  -- (the exact v30-inline + named duplication shape this repair addresses).
  select count(*) into v_dupes from (
    select conrelid, conkey from pg_constraint
     where contype = 'c' and array_length(conkey, 1) = 1
       and conrelid in (
         'public.customer_contact_proofs'::regclass, 'public.customer_identities'::regclass,
         'public.customer_verified_contacts'::regclass, 'public.customer_links'::regclass)
     group by conrelid, conkey having count(*) > 1
  ) d;
  if v_dupes <> 0 then
    raise exception 'a c42-family table still has duplicate single-column check constraints';
  end if;

  -- ---------------------------------------------------------------------------
  -- (b) Behavioral: the full phone-registration happy path now succeeds and the
  --     phone contact proof row exists (impossible while the stale check survives).
  -- ---------------------------------------------------------------------------
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_cust, 'authenticated', 'authenticated',
          'v50b-acc-'||substr(v_cust::text,1,8)||'@example.test', '', now(), now(), now());
  update auth.users set phone = '+6581' || substr(v_cust::text, 1, 6), phone_confirmed_at = now()
   where id = v_cust;
  update app.platform_feature_flags set enabled = true, changed_at = statement_timestamp()
   where feature_key in ('customer_phone_registration', 'customer_phone_otp');
  insert into app.customer_legal_documents(document_key, document_version, document_sha256, published_at, active)
  values ('terms', 'v50b-1', md5('v50b-terms')||md5('terms-v50b'), now(), true),
         ('privacy', 'v50b-1', md5('v50b-privacy')||md5('privacy-v50b'), now(), true)
  on conflict (document_key) do update set
    document_version = excluded.document_version, document_sha256 = excluded.document_sha256,
    published_at = excluded.published_at, active = true;

  perform pg_temp.as_v50b(v_cust, 'authenticated');
  v_response := public.customer_register_verified_phone(
    'V50b Accept', v_sgt_today, 'en', true, true, false, 'v50b-accept-key-01');
  if v_response->>'outcome' <> 'registered' then
    raise exception 'phone registration did not succeed after the constraint repair: %', v_response;
  end if;

  reset role;
  select id into v_identity from public.customer_identities where auth_user_id = v_cust;
  if not exists (
    select 1 from public.customer_contact_proofs
     where identity_id = v_identity and contact_type = 'phone'
       and proof_method = 'auth_phone_otp' and status = 'verified'
  ) then
    raise exception 'the phone contact proof row was not created by registration';
  end if;

  -- ---------------------------------------------------------------------------
  -- (c) Email proofs remain constrained: email + auth_phone_otp violates method_type_check.
  -- ---------------------------------------------------------------------------
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_cust_email, 'authenticated', 'authenticated',
          'v50b-eml-'||substr(v_cust_email::text,1,8)||'@example.test', '', now(), now(), now());
  insert into public.customer_identities(id, auth_user_id, status, created_via)
  values (v_id_email, v_cust_email, 'active', 'phone_registration');
  begin
    insert into public.customer_contact_proofs(
      identity_id, auth_user_id, contact_type, proof_method, status, issued_at, expires_at, verified_at)
    values (v_id_email, v_cust_email, 'email', 'auth_phone_otp', 'verified', now(), now() + interval '15 minutes', now());
    raise exception 'an email proof with proof_method auth_phone_otp was wrongly accepted';
  exception when check_violation then null;  -- 23514, from method_type_check
  end;

  reset role;
  raise notice 'v50b contact-proof constraint repair suite: ALL PASS';
end $v50b_test$;

reset role;
rollback;
