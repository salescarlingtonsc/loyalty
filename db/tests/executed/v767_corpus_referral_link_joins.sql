-- EXECUTED acceptance fixture for nestly_v767
-- (db/migrations/20261002_nestly_v767_referral_link_joins.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v767_corpus --migrated-only
--
-- WHY THIS EXISTS. Owner ruling 2026-09-05: a customer who arrives on a friend's referral link
-- must be joined to that business after sign-up without scanning the counter QR. The new writer
-- public.customer_join_business_by_referral_v767 creates the same verified link the QR path
-- creates, gated on the business accepting joins, running a referral programme, and the code
-- belonging to one of ITS customers.
--
-- SCENARIO. One business (join_enabled, referrals on) with an existing member R who holds
-- referral code 'V767FRIEND'. A second business (referrals OFF) whose member holds 'V767OFF'.
--   E1  new customer N (verified phone, profile) calls the RPC with the right slug + code
--       -> outcome 'linked', replayed=false, a verified customer_links row with
--       verification_method='referral_join', a clients row carrying N's phone, a claim attempt
--       and an audit event 'referral_join_linked'.
--   E2  the same call with the same idempotency key -> replayed=true, still one link.
--   E3  a second call with a NEW key -> outcome 'linked', replayed=true (already a member), and
--       the link count for (business, identity) stays 1.
--   E4  the wallet context now resolves for N at that business (app.v32_customer_wallet_context
--       returns a row), so customer_apply_referral_code_v612 has a member to attribute.
--   E5  refusals, each 22023: a code that belongs to no customer of that business; a business
--       whose referral programme is off; a business with join_enabled=false. No link written.
--   E6  a customer whose phone is not confirmed -> 42501, no link.
--   E7  anon (no auth.uid) -> 28000.
--
-- One transaction, rolled back. No production access.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;
grant all on _fail to public;

create or replace function pg_temp.as_v767_user(p_uid uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', p_role)::text, true);
end
$$;
grant execute on function pg_temp.as_v767_user(uuid,text) to public;

do $v767$
declare
  v_biz uuid := gen_random_uuid(); v_biz_off uuid := gen_random_uuid(); v_biz_closed uuid := gen_random_uuid();
  v_slug text; v_slug_off text; v_slug_closed text;
  v_ref_client uuid; v_off_client uuid; v_closed_client uuid;
  v_auth_n uuid := gen_random_uuid(); v_auth_u uuid := gen_random_uuid();
  v_id_n uuid; v_id_u uuid;
  v_phone_n text := '+65 8123 1' || lpad((floor(random()*1000))::int::text, 3, '0');
  v_phone_u text := '+65 9123 1' || lpad((floor(random()*1000))::int::text, 3, '0');
  v_key uuid := gen_random_uuid();
  v_r1 jsonb; v_r2 jsonb; v_r3 jsonb; v_count integer; v_state text; v_ctx integer;
begin
  insert into public.businesses(id, name, slug, industry, enabled_modules, join_enabled) values
    (v_biz, 'V767 referrals on', 'v767-on-' || substr(gen_random_uuid()::text,1,8), 'fnb', array['dashboard','clients','sales','loyalty','referrals'], true),
    (v_biz_off, 'V767 referrals off', 'v767-off-' || substr(gen_random_uuid()::text,1,8), 'fnb', array['dashboard','clients','sales','loyalty'], true),
    (v_biz_closed, 'V767 joins closed', 'v767-closed-' || substr(gen_random_uuid()::text,1,8), 'fnb', array['dashboard','clients','sales','loyalty','referrals'], false);
  select slug into v_slug from public.businesses where id = v_biz;
  select slug into v_slug_off from public.businesses where id = v_biz_off;
  select slug into v_slug_closed from public.businesses where id = v_biz_closed;
  -- The wallet context (app.v32_customer_wallet_context) answers only for an operating business:
  -- approved workspace + current subscription, the same faithful-tenant shape the v753 fixture uses.
  insert into public.business_workspace_controls_v94(business_id, approval_status, decided_at, decision_reason)
  select b.id, 'approved', now(), 'v767 fixture' from public.businesses b where b.id in (v_biz, v_biz_off, v_biz_closed)
  on conflict (business_id) do update set approval_status='approved', decided_at=now(), decision_reason='v767 fixture';
  insert into public.business_subscription_lifecycle_v94(business_id, state, workspace_paused)
  select b.id, 'current', false from public.businesses b where b.id in (v_biz, v_biz_off, v_biz_closed)
  on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions(business_id, status, payment_status, current_period_end)
  select b.id, 'active', 'paid', now() + interval '30 days' from public.businesses b where b.id in (v_biz, v_biz_off, v_biz_closed)
  on conflict (business_id) do update set status='active', payment_status='paid', current_period_end=now()+interval '30 days';
  update app.platform_feature_flags set enabled = true, changed_at = now()
   where feature_key in ('customer_wallet', 'customer_qr_join');

  insert into public.referral_programs(business_id, enabled) values (v_biz, true), (v_biz_closed, true)
  on conflict (business_id) do update set enabled = excluded.enabled;
  insert into public.referral_programs(business_id, enabled) values (v_biz_off, false)
  on conflict (business_id) do update set enabled = false;

  insert into public.clients(id, business_id, full_name, phone, referral_code) values
    (gen_random_uuid(), v_biz, 'V767 referrer', '+65 9000 0001', 'V767FRIEND') returning id into v_ref_client;
  insert into public.clients(id, business_id, full_name, phone, referral_code) values
    (gen_random_uuid(), v_biz_off, 'V767 referrer off', '+65 9000 0002', 'V767OFF') returning id into v_off_client;
  insert into public.clients(id, business_id, full_name, phone, referral_code) values
    (gen_random_uuid(), v_biz_closed, 'V767 referrer closed', '+65 9000 0003', 'V767CLOSED') returning id into v_closed_client;

  -- N: verified phone + profile. U: phone not confirmed.
  insert into auth.users(instance_id, id, aud, role, email, phone, encrypted_password, email_confirmed_at, phone_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_auth_n, 'authenticated', 'authenticated', 'v767-n-' || substr(v_auth_n::text,1,8) || '@example.test', app.norm_phone(v_phone_n), '', now(), now(), now(), now()),
         ('00000000-0000-0000-0000-000000000000', v_auth_u, 'authenticated', 'authenticated', 'v767-u-' || substr(v_auth_u::text,1,8) || '@example.test', app.norm_phone(v_phone_u), '', now(), null, now(), now());
  insert into public.customer_identities(auth_user_id, status, created_via)
  values (v_auth_n, 'active', 'phone_registration'), (v_auth_u, 'active', 'phone_registration');
  select id into v_id_n from public.customer_identities where auth_user_id = v_auth_n;
  select id into v_id_u from public.customer_identities where auth_user_id = v_auth_u;
  perform set_config('app.c42_profile_identity', v_id_n::text, true);
  insert into public.customer_profiles(identity_id, auth_user_id, full_name, birth_date, preferred_language) values (v_id_n, v_auth_n, 'V767 new customer', date '1995-05-05', 'en');
  perform set_config('app.c42_profile_identity', v_id_u::text, true);
  insert into public.customer_profiles(identity_id, auth_user_id, full_name, birth_date, preferred_language) values (v_id_u, v_auth_u, 'V767 unverified', date '1995-05-05', 'en');
  perform set_config('app.c42_profile_identity', '', true);

  -- E1
  perform pg_temp.as_v767_user(v_auth_n);
  begin
    v_r1 := public.customer_join_business_by_referral_v767(v_slug, 'v767friend', v_key);
  exception when others then
    v_r1 := jsonb_build_object('raised', sqlerrm, 'state', sqlstate);
  end;
  reset role;
  if coalesce(v_r1->>'outcome','') <> 'linked' or (v_r1->>'replayed')::boolean is distinct from false then
    insert into _fail values ('E1_linked', v_r1::text);
  end if;
  select count(*) into v_count from public.customer_links l
   where l.business_id = v_biz and l.identity_id = v_id_n and l.state = 'verified' and l.verification_method = 'referral_join';
  if v_count <> 1 then insert into _fail values ('E1_link_row', 'verified referral_join links=' || v_count::text); end if;
  select count(*) into v_count from public.clients c where c.business_id = v_biz and c.phone_norm = app.norm_phone(v_phone_n);
  if v_count <> 1 then insert into _fail values ('E1_client_row', 'clients with phone=' || v_count::text); end if;
  select count(*) into v_count from public.customer_link_claim_attempts a where a.identity_id = v_id_n and a.operation = 'referral_join';
  if v_count <> 1 then insert into _fail values ('E1_claim_attempt', 'attempts=' || v_count::text); end if;
  select count(*) into v_count from public.customer_link_audit_events e where e.identity_id = v_id_n and e.event_type = 'referral_join_linked';
  if v_count <> 1 then insert into _fail values ('E1_audit_event', 'events=' || v_count::text); end if;

  -- E2 same key
  perform pg_temp.as_v767_user(v_auth_n);
  begin v_r2 := public.customer_join_business_by_referral_v767(v_slug, 'V767FRIEND', v_key);
  exception when others then v_r2 := jsonb_build_object('raised', sqlerrm); end;
  reset role;
  if (v_r2->>'replayed')::boolean is distinct from true or coalesce(v_r2->>'outcome','') <> 'linked' then
    insert into _fail values ('E2_same_key_replayed', v_r2::text);
  end if;

  -- E3 new key, already a member
  perform pg_temp.as_v767_user(v_auth_n);
  begin v_r3 := public.customer_join_business_by_referral_v767(v_slug, 'V767FRIEND', gen_random_uuid());
  exception when others then v_r3 := jsonb_build_object('raised', sqlerrm); end;
  reset role;
  if (v_r3->>'replayed')::boolean is distinct from true or coalesce(v_r3->>'outcome','') <> 'linked' then
    insert into _fail values ('E3_member_replayed', v_r3::text);
  end if;
  select count(*) into v_count from public.customer_links l where l.business_id = v_biz and l.identity_id = v_id_n;
  if v_count <> 1 then insert into _fail values ('E3_one_link', 'links=' || v_count::text); end if;

  -- E4 wallet context resolves
  -- E4: the downstream writer the app calls next. Before v767 this raised 42501 ('verified
  -- customer link required') for a referral-link arrival; now it answers, whatever it decides.
  perform pg_temp.as_v767_user(v_auth_n);
  begin
    v_r1 := public.customer_apply_referral_code_v612(v_slug, 'V767FRIEND', gen_random_uuid());
    v_ctx := 1;
  exception when others then v_ctx := -1; v_r1 := jsonb_build_object('state', sqlstate, 'raised', sqlerrm);
  end;
  reset role;
  if v_ctx <> 1 then insert into _fail values ('E4_referral_apply_reachable', v_r1::text); end if;

  -- E5 refusals
  foreach v_state in array array['unknown_code','referrals_off','joins_closed'] loop
    perform pg_temp.as_v767_user(v_auth_n);
    begin
      v_r1 := case v_state
        when 'unknown_code' then public.customer_join_business_by_referral_v767(v_slug_off, 'V767FRIEND', gen_random_uuid())
        when 'referrals_off' then public.customer_join_business_by_referral_v767(v_slug_off, 'V767OFF', gen_random_uuid())
        else public.customer_join_business_by_referral_v767(v_slug_closed, 'V767CLOSED', gen_random_uuid()) end;
      v_r1 := jsonb_build_object('state', 'no error', 'reply', v_r1);
    exception when others then
      v_r1 := jsonb_build_object('state', sqlstate);
    end;
    reset role;
    if coalesce(v_r1->>'state','') <> '22023' then insert into _fail values ('E5_refused_' || v_state, v_r1::text); end if;
  end loop;
  select count(*) into v_count from public.customer_links l where l.identity_id = v_id_n and l.business_id in (v_biz_off, v_biz_closed);
  if v_count <> 0 then insert into _fail values ('E5_no_link_written', 'links=' || v_count::text); end if;

  -- E6 unverified phone
  perform pg_temp.as_v767_user(v_auth_u);
  begin
    v_r1 := public.customer_join_business_by_referral_v767(v_slug, 'V767FRIEND', gen_random_uuid());
    v_r1 := jsonb_build_object('state', 'no error');
  exception when others then v_r1 := jsonb_build_object('state', sqlstate); end;
  reset role;
  if coalesce(v_r1->>'state','') <> '42501' then insert into _fail values ('E6_unverified_refused', v_r1::text); end if;
  select count(*) into v_count from public.customer_links l where l.identity_id = v_id_u;
  if v_count <> 0 then insert into _fail values ('E6_no_link', 'links=' || v_count::text); end if;

  -- E7 anon
  begin
    perform set_config('request.jwt.claim.sub', '', true);
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role anon';
    v_r1 := public.customer_join_business_by_referral_v767(v_slug, 'V767FRIEND', gen_random_uuid());
    v_r1 := jsonb_build_object('state', 'no error');
  exception when others then v_r1 := jsonb_build_object('state', sqlstate); end;
  reset role;
  if coalesce(v_r1->>'state','') not in ('28000','42501') then insert into _fail values ('E7_anon_refused', v_r1::text); end if;

  raise notice 'v767 | biz=% | E1 linked | E2 same-key replay | E3 member replay | E4 wallet context | E5 three refusals | E6 unverified 42501 | E7 anon refused', v_biz;
end
$v767$;

select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v) into n, d from _fail f;
  if n > 0 then raise exception 'v767: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

select case when count(*) = 0
            then 'PASS — v767: a referral code that belongs to a customer of a business that accepts '
                 'joins and runs referrals joins a verified new customer to that business, idempotently, '
                 'and is refused for a foreign code, a business with referrals off, closed joins, an '
                 'unverified phone or no session'
            else 'FAIL' end as verdict,
       count(*) as failures
from _fail;

rollback;
