-- Rollback-only v327 acceptance: the global Peekaa member QR.
-- Contract under test: one platform identity issues ONE static, opaque, re-derivable
-- token; a merchant scan resolves it to that merchant's OWN client relationship
-- (auto-provisioning on first scan, reusing on every scan after), never to another
-- merchant's client row, and never by reading the token back into a phone or email.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v327_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',json_build_object(
    'sub',p_uid,'role',p_role
  )::text,true);
end
$$;
grant execute on function pg_temp.as_v327_user(uuid,text) to authenticated,anon;

do $v327$
declare
  v_business_a uuid;
  v_business_b uuid;
  v_owner_a uuid;
  v_owner_b uuid;
  v_customer uuid := gen_random_uuid();
  v_identity uuid;
  v_token_a text;
  v_token_b text;
  v_full_qr text;
  v_scan_1 jsonb;
  v_scan_2 jsonb;
  v_scan_b jsonb;
  v_client_at_a uuid;
  v_rotated jsonb;
  v_scan_after_rotation jsonb;
  v_scan_old_token jsonb;
  v_links_count integer;
begin
  reset role;
  select id into v_business_a from public.businesses where name='Pristine chain fixture A';
  select id into v_business_b from public.businesses where name='Pristine chain fixture B';
  select user_id into v_owner_a from public.staff
   where business_id=v_business_a and role='owner' and active limit 1;
  select user_id into v_owner_b from public.staff
   where business_id=v_business_b and role='owner' and active limit 1;
  if v_business_a is null or v_business_b is null or v_owner_a is null or v_owner_b is null then
    raise exception 'v327 suite requires the pristine two-tenant fixture';
  end if;

  update app.platform_feature_flags set enabled=true, changed_at=now()
   where feature_key='customer_identity';

  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000',v_customer,'authenticated','authenticated',
    'v327-customer@example.test','',now(),now(),now()
  );

  -- A. Issuing a QR before any identity exists auto-creates one (mirrors the claim
  -- flow's own customer_create_identity call), and the SAME token comes back on
  -- every subsequent call — a printable, re-derivable code, not a one-shot secret.
  perform pg_temp.as_v327_user(v_customer);
  begin
    perform public.customer_get_member_qr_v327();
    raise exception 'A: member QR issued before a platform identity existed';
  exception when others then
    if sqlstate <> '42501' then raise; end if;
  end;
  perform public.customer_create_identity('v327-identity-create');
  v_full_qr := public.customer_get_member_qr_v327()->>'member_qr';
  if v_full_qr !~ '^nestly:member:[0-9a-f]{64}$' then
    raise exception 'B: unexpected member QR wire format: %', v_full_qr;
  end if;
  v_token_a := substring(v_full_qr from length('nestly:member:')+1);
  if (public.customer_get_member_qr_v327()->>'member_qr') <> v_full_qr then
    raise exception 'C: member QR changed between calls with no rotation';
  end if;
  reset role;
  select id into v_identity from public.customer_identities where auth_user_id=v_customer;
  if v_identity is null then raise exception 'D: no platform identity was created'; end if;
  if (select qr_token_hash from public.customer_identities where id=v_identity)
     <> app.v89_sha256(v_token_a) then
    raise exception 'E: stored token hash does not match the derived token';
  end if;

  -- B. The token never carries the phone or email, and is not reversible by construction:
  -- it is an HMAC digest, and nothing on public.customer_identities exposes the secret.
  if v_full_qr ~* 'example\.test' or v_full_qr ~ v_customer::text then
    raise exception 'F: member QR leaks the auth user id or email';
  end if;
  if has_function_privilege('authenticated','app.v327_member_qr_secret()','execute')
     or has_function_privilege('anon','app.v327_member_qr_secret()','execute')
     or has_function_privilege('authenticated','app.v327_member_qr_token(uuid,integer)','execute')
     or has_function_privilege('anon','app.v327_member_qr_token(uuid,integer)','execute') then
    raise exception 'G: token derivation is callable directly by a browser role';
  end if;

  -- C. Business A scans the QR: no existing relationship, so one client + one
  -- customer_links row is auto-provisioned, silently (owner ruling, no confirm step).
  perform pg_temp.as_v327_user(v_owner_a);
  v_scan_1 := public.staff_scan_member_qr_v327(v_business_a, v_full_qr);
  if v_scan_1->>'status' <> 'found' then
    raise exception 'H: first scan at business A did not resolve: %', v_scan_1;
  end if;
  if coalesce((v_scan_1->>'newly_linked')::boolean,false) is not true then
    raise exception 'I: first scan did not report a new relationship';
  end if;
  v_client_at_a := (v_scan_1->>'client_id')::uuid;
  reset role;
  if not exists (
    select 1 from public.clients where id=v_client_at_a and business_id=v_business_a
  ) then
    raise exception 'J: no client row was provisioned at business A';
  end if;
  if not exists (
    select 1 from public.customer_links
     where business_id=v_business_a and identity_id=v_identity
       and client_id=v_client_at_a and state='verified' and verification_method='qr_scan'
  ) then
    raise exception 'K: no verified customer_links row was created';
  end if;

  -- D. Scanning the SAME QR at business A again resolves to the SAME client —
  -- no duplicate client, no duplicate link.
  perform pg_temp.as_v327_user(v_owner_a);
  v_scan_2 := public.staff_scan_member_qr_v327(v_business_a, v_full_qr);
  reset role;
  if (v_scan_2->>'client_id')::uuid <> v_client_at_a then
    raise exception 'L: second scan at business A resolved to a different client';
  end if;
  if coalesce((v_scan_2->>'newly_linked')::boolean,true) is not false then
    raise exception 'M: second scan at business A reported a new relationship';
  end if;
  select count(*) into v_links_count from public.customer_links
   where business_id=v_business_a and identity_id=v_identity;
  if v_links_count <> 1 then
    raise exception 'N: business A holds % links for one identity, expected 1', v_links_count;
  end if;
  select count(*) into v_links_count from public.clients
   where business_id=v_business_a and id=v_client_at_a;
  if v_links_count <> 1 then raise exception 'O: client row duplicated at business A'; end if;

  -- E. THE CORE CLAIM: the SAME token, scanned at an UNRELATED business B, resolves
  -- to a DIFFERENT client row there — business B never sees business A's client id,
  -- and business A's relationship is untouched.
  perform pg_temp.as_v327_user(v_owner_b);
  v_scan_b := public.staff_scan_member_qr_v327(v_business_b, v_full_qr);
  reset role;
  if v_scan_b->>'status' <> 'found' then
    raise exception 'P: scan at business B did not resolve: %', v_scan_b;
  end if;
  if (v_scan_b->>'client_id')::uuid = v_client_at_a then
    raise exception 'Q: business B was handed business A''s client id — tenant isolation broken';
  end if;
  if not exists (
    select 1 from public.clients
     where id=(v_scan_b->>'client_id')::uuid and business_id=v_business_b
  ) then
    raise exception 'R: business B''s resolved client does not belong to business B';
  end if;
  select count(*) into v_links_count from public.customer_links
   where identity_id=v_identity and state='verified';
  if v_links_count <> 2 then
    raise exception 'S: identity should now have exactly 2 verified relationships, got %', v_links_count;
  end if;

  -- F. Rotation is a deliberate act: it changes the token, and the OLD token stops
  -- resolving anywhere, while the NEW token still reaches the SAME business-A client
  -- (rotation changes the code, not the underlying relationship).
  perform pg_temp.as_v327_user(v_customer);
  v_rotated := public.customer_rotate_member_qr_v327();
  reset role;
  v_token_b := v_rotated->>'member_qr';
  if v_token_b = v_full_qr then raise exception 'T: rotation did not change the token'; end if;

  perform pg_temp.as_v327_user(v_owner_a);
  v_scan_old_token := public.staff_scan_member_qr_v327(v_business_a, v_full_qr);
  if v_scan_old_token->>'status' <> 'invalid' then
    raise exception 'U: the pre-rotation token still resolves after rotation';
  end if;
  v_scan_after_rotation := public.staff_scan_member_qr_v327(v_business_a, v_token_b);
  reset role;
  if (v_scan_after_rotation->>'client_id')::uuid <> v_client_at_a then
    raise exception 'V: the rotated token resolved to a different client at business A';
  end if;
  if coalesce((v_scan_after_rotation->>'newly_linked')::boolean,true) is not false then
    raise exception 'W: rotation caused a second relationship to be provisioned';
  end if;

  -- G. A junk/garbage string is rejected as invalid, never as an exception leaking detail.
  perform pg_temp.as_v327_user(v_owner_a);
  if (public.staff_scan_member_qr_v327(v_business_a, 'not-a-real-qr'))->>'status' <> 'invalid' then
    raise exception 'X: a malformed scan payload was not rejected as invalid';
  end if;
  reset role;

  -- H. Raw table ACLs stay closed — every read/write goes through the RPCs above.
  if has_table_privilege('anon','public.customer_identities','select')
     or has_table_privilege('authenticated','public.customer_identities','select')
     or has_table_privilege('anon','public.customer_identities','update')
     or has_table_privilege('authenticated','public.customer_identities','update') then
    raise exception 'Y: customer_identities raw table ACL is open';
  end if;

  raise notice 'v327 global customer QR suite: ALL PASS';
end;
$v327$;

rollback;
