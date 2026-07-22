-- Rollback-only v31 customer links, claims, invitation, and unlink adversarial suite.
-- Covers raw email, raw phone, and raw token non-persistence; token_hash only;
-- generic ambiguous exactly one matching; name and phone non-authority; customer A
-- and customer B across business A and business B; same business and cross-business
-- isolation; expired single-use replay and
-- idempotent unlink deletion denial, plus PUBLIC and anon ACL denial.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_customer(p_uid uuid) returns void
language plpgsql as $$
begin
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end;
$$;
grant execute on function pg_temp.as_customer(uuid) to public;

do $v31_test$
declare
  v_business uuid;
  v_other_business uuid;
  v_business_slug text;
  v_other_business_slug text;
  v_owner uuid;
  v_owner_email text;
  v_customer_a uuid := gen_random_uuid();
  v_customer_b uuid := gen_random_uuid();
  v_customer_b_email text := 'v31-b-' || gen_random_uuid()::text || '@example.test';
  v_staff_only uuid := gen_random_uuid();
  v_dual_role uuid;
  v_client_exact uuid;
  v_client_duplicate uuid;
  v_client_invited uuid;
  v_client_changed uuid;
  v_client_other_business uuid;
  v_identity_a uuid;
  v_identity_b uuid;
  v_dual_identity uuid;
  v_invite jsonb;
  v_claim jsonb;
  v_token text;
  v_expired_token text := repeat('e', 64);
  v_link uuid;
  v_acl_table text;
  v_i integer;
begin
  reset role;
  update app.platform_feature_flags set enabled = true, changed_at = now()
   where feature_key in ('customer_identity', 'customer_claims');
  select b.id, b.slug into v_business, v_business_slug
    from public.businesses b order by b.created_at limit 1;
  select b.id, b.slug into v_other_business, v_other_business_slug
    from public.businesses b where b.id <> v_business order by b.created_at limit 1;
  select s.user_id into v_owner from public.staff s
   where s.business_id = v_business and s.role = 'owner' and s.active and s.user_id is not null limit 1;
  if v_business is null or v_other_business is null or v_owner is null then
    raise exception 'v31 suite requires two businesses and an active owner';
  end if;
  v_dual_role := v_owner;

  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values
    ('00000000-0000-0000-0000-000000000000', v_customer_a, 'authenticated', 'authenticated', 'same@example.test', '', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', v_customer_b, 'authenticated', 'authenticated', v_customer_b_email, '', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', v_staff_only, 'authenticated', 'authenticated', 'staff-only@example.test', '', now(), now(), now());
  insert into public.staff(business_id,user_id,role,full_name,active)
  values (v_business, v_staff_only, 'frontdesk', 'V31 staff only', true);
  insert into public.clients(business_id,full_name,email)
  values (v_business, 'Duplicate Name', 'same@example.test')
  returning id into v_client_exact;
  insert into public.clients(business_id,full_name,email)
  values
    (v_business, 'Another Duplicate Name', ' SAME@example.test '),
    (v_business, 'Invitation Target', 'unrelated@example.test'),
    (v_other_business, 'Cross Business', 'same@example.test');
  select c.id into v_client_duplicate from public.clients c where c.business_id = v_business and c.full_name = 'Another Duplicate Name';
  select c.id into v_client_invited from public.clients c where c.business_id = v_business and c.full_name = 'Invitation Target';
  select c.id into v_client_other_business from public.clients c where c.business_id = v_other_business and c.full_name = 'Cross Business';

  -- A staff session without an independently created customer identity cannot claim.
  perform pg_temp.as_customer(v_staff_only);
  begin
    perform public.customer_claim_link_by_email(v_business_slug, 'v31-staff-only');
    raise exception 'staff-only auth user could claim without a customer identity';
  exception when insufficient_privilege then null;
  end;

  perform pg_temp.as_customer(v_customer_a);
  v_identity_a := (public.customer_create_identity('v31-identity-a')->>'identity_id')::uuid;
  if public.customer_claim_link_by_email(v_business_slug, 'v31-duplicate-email')->>'outcome'
       is distinct from 'no_link_created' then
    raise exception 'duplicate normalized email candidates were linked or enumerated';
  end if;
  reset role;
  if exists (select 1 from public.customer_links where identity_id = v_identity_a) then
    raise exception 'duplicate normalized email candidates created a link';
  end if;
  perform pg_temp.as_customer(v_customer_a);
  if public.customer_claim_link_by_email(v_business_slug, 'v31-duplicate-email')->>'outcome'
       is distinct from 'no_link_created' then
    raise exception 'email claim replay did not return the stored generic outcome';
  end if;

  -- Make a one-candidate email relationship and prove it cannot cross business.
  reset role;
  update public.clients set email = v_customer_b_email where id = v_client_duplicate;
  update public.clients set email = 'different@example.test' where id = v_client_exact;
  if (select count(*) from public.clients
       where business_id = v_business and lower(btrim(email)) = lower(v_customer_b_email)) <> 1 then
    raise exception 'v31 exact-email fixture is not unique';
  end if;
  perform pg_temp.as_customer(v_customer_b);
  v_identity_b := (public.customer_create_identity('v31-identity-b')->>'identity_id')::uuid;
  reset role;
  if not exists (
    select 1 from auth.users
     where id = v_customer_b and lower(btrim(email)) = lower(v_customer_b_email)
       and email_confirmed_at is not null
  ) then
    raise exception 'v31 exact-email auth fixture is not verified';
  end if;
  if not exists (
    select 1 from public.customer_identities
     where id = v_identity_b and auth_user_id = v_customer_b
  ) then
    raise exception 'v31 customer identity was not bound to the expected auth user';
  end if;
  perform pg_temp.as_customer(v_customer_b);
  if auth.uid() is distinct from v_customer_b then
    raise exception 'v31 customer session did not switch to the expected auth user';
  end if;
  v_claim := public.customer_claim_link_by_email(
    v_business_slug, 'v31-single-match');
  if v_claim->>'outcome' is distinct from 'linked' then
    raise exception 'exact unique verified email did not link: %', v_claim;
  end if;
  reset role;
  select id into v_link from public.customer_links where identity_id = v_identity_b and business_id = v_business and state = 'verified';
  if v_link is null then raise exception 'email claim did not create a verified link'; end if;
  perform pg_temp.as_customer(v_customer_b);
  if public.customer_claim_link_by_email(v_other_business_slug, 'v31-cross-business')->>'outcome'
       is distinct from 'no_link_created' then
    raise exception 'email claim crossed the business boundary';
  end if;

  -- Owner-issued invitation returns a secret once, stores only a SHA-256 hash, and does not replay it.
  reset role;
  select lower(btrim(email)) into v_owner_email from auth.users where id = v_owner;
  update public.clients
     set email = v_owner_email
   where id = v_client_invited;
  perform pg_temp.as_customer(v_owner);
  v_invite := public.customer_issue_link_invitation(v_business, v_client_invited, 'v31-issue-invite', 60);
  v_token := v_invite->>'token';
  if v_invite->>'outcome' <> 'invitation_issued' or v_token is null or length(v_token) <> 64 then
    raise exception 'owner invitation did not return one high-entropy raw token';
  end if;
  reset role;
  if exists (select 1 from public.customer_link_invitations where token_hash = v_token) then
    raise exception 'raw invitation token was stored';
  end if;
  perform pg_temp.as_customer(v_owner);
  if public.customer_issue_link_invitation(v_business, v_client_invited, 'v31-issue-invite', 60)->>'token' is not null then
    raise exception 'invitation issue replay returned the secret again';
  end if;
  begin
    perform public.customer_issue_link_invitation(v_other_business, v_client_invited, 'v31-cross-business-invite', 60);
    raise exception 'owner issued invitation for a client outside their business';
  exception when insufficient_privilege then null;
  end;

  -- Possession of an unconsumed token is insufficient: the signed-in account
  -- must also have the confirmed email that the owner targeted.
  perform pg_temp.as_customer(v_customer_a);
  if public.customer_claim_link_invitation(v_token, 'v31-preconsume-theft')->>'outcome' <> 'no_link_created' then
    raise exception 'pre-consumption invitation theft linked the wrong confirmed email';
  end if;
  reset role;
  if not exists (
    select 1 from public.customer_link_invitations
     where token_hash = app.v31_sha256_hex(v_token) and state = 'issued'
  ) then
    raise exception 'wrong-email invitation attempt consumed the intended recipient token';
  end if;

  -- A staff user becomes a customer only by the separate v30 identity flow; that
  -- dual role may redeem its own invitation but gains no cross-client relationship.
  perform pg_temp.as_customer(v_dual_role);
  v_dual_identity := (public.customer_create_identity('v31-dual-role-identity')->>'identity_id')::uuid;
  if public.customer_claim_link_invitation(v_token, 'v31-claim-invite')->>'outcome' <> 'linked' then
    raise exception 'independent dual-role identity could not claim its own invitation';
  end if;
  if public.customer_claim_link_invitation(v_token, 'v31-replay-token')->>'outcome' <> 'linked' then
    raise exception 'same identity invitation replay was not retry-safe';
  end if;
  reset role;
  if exists (select 1 from public.customer_links where identity_id = v_dual_identity and client_id <> v_client_invited and state = 'verified') then
    raise exception 'dual-role invitation claim gained another client relationship';
  end if;
  perform pg_temp.as_customer(v_customer_b);
  if public.customer_claim_link_invitation(v_token, 'v31-other-replay-token')->>'outcome' <> 'no_link_created' then
    raise exception 'invitation replay by another identity leaked or reused the link';
  end if;

  -- Claims use the current confirmed Auth email, not stale identity evidence.
  reset role;
  insert into public.clients(business_id, full_name, email)
  values (v_business, 'Changed Auth Contact', 'changed-contact@example.test')
  returning id into v_client_changed;
  update auth.users set email = 'changed-contact@example.test', email_confirmed_at = now()
   where id = v_customer_a;
  perform pg_temp.as_customer(v_customer_a);
  if public.customer_claim_link_by_email(
       v_business_slug, 'v31-changed-auth-contact'
     )->>'outcome' <> 'linked' then
    raise exception 'changed confirmed Auth contact did not become the current email authority';
  end if;
  reset role;
  if not exists (
    select 1 from public.customer_links
     where identity_id = v_identity_a and client_id = v_client_changed and state = 'verified'
  ) then
    raise exception 'changed Auth contact linked a stale email candidate';
  end if;

  -- Expired invitations cannot create a link.
  perform pg_temp.as_customer(v_owner);
  reset role;
  insert into public.customer_link_invitations(
    business_id, client_id, issued_by_auth_user_id, token_hash, recipient_email_hash,
    expires_at, created_at
  ) values (
    v_business, v_client_exact, v_owner, app.v31_sha256_hex(v_expired_token),
    app.v31_sha256_hex('v31.invitation-email:changed-contact@example.test'),
    now() - interval '1 hour', now() - interval '2 hours'
  );
  -- The fixture inserts an already-expired evidence row; production callers have
  -- no direct table grant and cannot bypass the invitation transition guard.
  perform pg_temp.as_customer(v_customer_a);
  if public.customer_claim_link_invitation(v_expired_token, 'v31-claim-expired')->>'outcome' <> 'no_link_created' then
    raise exception 'expired invitation created a link';
  end if;

  -- Unlink is a customer-self-service, audited state transition, never deletion.
  perform pg_temp.as_customer(v_customer_b);
  if public.customer_unlink_business_link(v_business_slug, 'v31-unlink')->>'outcome' <> 'unlinked' then
    raise exception 'self unlink did not transition the caller link';
  end if;
  reset role;
  if not exists (select 1 from public.customer_links where id = v_link and state = 'unlinked' and unlinked_by_auth_user_id = v_customer_b) then
    raise exception 'unlink deleted or failed to audit the relationship';
  end if;
  perform pg_temp.as_customer(v_customer_b);
  if public.customer_unlink_business_link(v_business_slug, 'v31-unlink')->>'outcome' <> 'unlinked' then
    raise exception 'unlink replay was not idempotent';
  end if;
  for v_i in 1..9 loop
    perform public.customer_unlink_business_link(
      v_business_slug,
      'v31-unlink-rate-' || v_i::text
    );
  end loop;
  begin
    perform public.customer_unlink_business_link(
      v_business_slug, 'v31-unlink-rate-blocked'
    );
    raise exception 'fresh unlink keys bypassed the bounded abuse control';
  exception when sqlstate '54000' then null;
  end;

  reset role;
  foreach v_acl_table in array array[
    'public.customer_links', 'public.customer_link_claim_attempts', 'public.customer_link_invitations',
    'public.customer_link_invitation_issues', 'public.customer_link_audit_events', 'public.customer_link_unlink_events'
  ] loop
    if has_table_privilege('anon', v_acl_table, 'select') or has_table_privilege('authenticated', v_acl_table, 'select')
       or has_table_privilege('anon', v_acl_table, 'insert') or has_table_privilege('authenticated', v_acl_table, 'insert') then
      raise exception 'v31 raw table ACL is open for %', v_acl_table;
    end if;
  end loop;
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname in (
       'customer_claim_link_by_email', 'customer_issue_link_invitation',
       'customer_claim_link_invitation', 'customer_unlink_business_link'
     ) and (not p.prosecdef or has_function_privilege('anon', p.oid, 'execute')
       or exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0 and a.privilege_type = 'EXECUTE'))
  ) then
    raise exception 'v31 customer RPC security-definer or ACL contract is incorrect';
  end if;
  raise notice 'v31 customer links/claims suite: ALL PASS';
end;
$v31_test$;

rollback;
