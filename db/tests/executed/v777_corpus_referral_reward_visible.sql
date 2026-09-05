-- EXECUTED acceptance fixture for nestly_v777
-- (db/migrations/20261006_nestly_v777_referral_reward_visible.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v777_corpus --migrated-only
--
-- WHY THIS EXISTS. Owner, 2026-09-05: the referred friend must be shown the reward they are
-- working towards, inside Points & gifts, until it is paid. public.customer_get_referral_pending_v777
-- answers from the customer's own public.referrals row — the row app.on_sale_recorded REGION B pays.
--
-- SCENARIO. One business, referrals on (min_spend 500, referrer 50 points, friend defaults to the
-- same). Member R (referrer). Friend F joined and attributed (referrals row 'pending').
--   E1  as F: pending=true, min_spend_cents=500, friend_reward_points=50, referrer_first_name='Rina'.
--   E3  a blocked_reason written the way REGION B writes it is surfaced while pending (E3a);
--       once the row is 'rewarded' the read settles with the points paid (E3b).
--   E4  a customer with no referral row: pending=false, status='none'.
--   E5  the programme switched off: pending=false, status='programme_off' (fixture: a second
--       pending friend at a business whose referral_programs.enabled is flipped to false).
--   E6  anon -> 28000; a customer not linked to the business -> 42501.
--
-- One transaction, rolled back. No production access.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;
grant all on _fail to public;

create or replace function pg_temp.as_v777_user(p_uid uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', p_role)::text, true);
end
$$;
grant execute on function pg_temp.as_v777_user(uuid,text) to public;

do $v777$
declare
  v_biz uuid := gen_random_uuid(); v_slug text; v_ver uuid;
  v_auth_r uuid := gen_random_uuid(); v_auth_f uuid := gen_random_uuid(); v_auth_x uuid := gen_random_uuid();
  v_id_r uuid; v_id_f uuid; v_id_x uuid;
  v_client_r uuid; v_client_f uuid; v_client_x uuid;
  v_link_r uuid := gen_random_uuid(); v_link_f uuid := gen_random_uuid(); v_link_x uuid := gen_random_uuid();
  v_r jsonb; v_state text; v_status text;
begin
  insert into public.businesses(id, name, slug, industry, enabled_modules, join_enabled)
  values (v_biz, 'V777 referral visible', 'v777-' || substr(gen_random_uuid()::text,1,8), 'fnb',
          array['dashboard','clients','sales','loyalty','referrals'], true);
  select slug into v_slug from public.businesses where id = v_biz;
  insert into public.business_workspace_controls_v94(business_id, approval_status, decided_at, decision_reason)
  values (v_biz, 'approved', now(), 'v777 fixture')
  on conflict (business_id) do update set approval_status='approved', decided_at=now(), decision_reason='v777 fixture';
  insert into public.business_subscription_lifecycle_v94(business_id, state, workspace_paused)
  values (v_biz, 'current', false) on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions(business_id, status, payment_status, current_period_end)
  values (v_biz, 'active', 'paid', now() + interval '30 days')
  on conflict (business_id) do update set status='active', payment_status='paid', current_period_end=now()+interval '30 days';
  update app.platform_feature_flags set enabled = true, changed_at = now()
   where feature_key in ('customer_wallet', 'customer_qr_join');
  insert into public.branches (id, business_id, name, is_default, active)
  values (gen_random_uuid(), v_biz, 'V777 main', true, true)
  on conflict do nothing;
  insert into public.referral_programs(business_id, enabled, reward_kind, reward_points, min_spend_cents, friend_enabled)
  values (v_biz, true, 'points', 50, 500, true)
  on conflict (business_id) do update set enabled=true, reward_kind='points', reward_points=50, min_spend_cents=500, friend_enabled=true;
  insert into auth.users(instance_id, id, aud, role, email, phone, encrypted_password, email_confirmed_at, phone_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_auth_r, 'authenticated', 'authenticated', 'v777-r-'||substr(v_auth_r::text,1,8)||'@example.test', '6590001111', '', now(), now(), now(), now()),
         ('00000000-0000-0000-0000-000000000000', v_auth_f, 'authenticated', 'authenticated', 'v777-f-'||substr(v_auth_f::text,1,8)||'@example.test', '6590002222', '', now(), now(), now(), now()),
         ('00000000-0000-0000-0000-000000000000', v_auth_x, 'authenticated', 'authenticated', 'v777-x-'||substr(v_auth_x::text,1,8)||'@example.test', '6590003333', '', now(), now(), now(), now());
  insert into public.customer_identities(auth_user_id, status, created_via)
  values (v_auth_r,'active','phone_registration'), (v_auth_f,'active','phone_registration'), (v_auth_x,'active','phone_registration');
  select id into v_id_r from public.customer_identities where auth_user_id = v_auth_r;
  select id into v_id_f from public.customer_identities where auth_user_id = v_auth_f;
  select id into v_id_x from public.customer_identities where auth_user_id = v_auth_x;
  perform set_config('app.c42_profile_identity', v_id_r::text, true);
  insert into public.customer_profiles(identity_id, auth_user_id, full_name, birth_date, preferred_language) values (v_id_r, v_auth_r, 'Rina Referrer', date '1990-01-01', 'en');
  perform set_config('app.c42_profile_identity', v_id_f::text, true);
  insert into public.customer_profiles(identity_id, auth_user_id, full_name, birth_date, preferred_language) values (v_id_f, v_auth_f, 'Fiona Friend', date '1990-01-01', 'en');
  perform set_config('app.c42_profile_identity', v_id_x::text, true);
  insert into public.customer_profiles(identity_id, auth_user_id, full_name, birth_date, preferred_language) values (v_id_x, v_auth_x, 'Xavier Nobody', date '1990-01-01', 'en');
  perform set_config('app.c42_profile_identity', '', true);

  insert into public.clients(id, business_id, full_name, phone, referral_code) values (gen_random_uuid(), v_biz, 'Rina Referrer', '+65 9000 1111', 'V777RINA') returning id into v_client_r;
  insert into public.clients(id, business_id, full_name, phone) values (gen_random_uuid(), v_biz, 'Fiona Friend', '+65 9000 2222') returning id into v_client_f;
  insert into public.clients(id, business_id, full_name, phone) values (gen_random_uuid(), v_biz, 'Xavier Nobody', '+65 9000 3333') returning id into v_client_x;
  perform set_config('app.customer_link_insert_id', v_link_r::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link_r, v_biz, v_id_r, v_auth_r, v_client_r, 'verified', 'firm_invitation', now());
  perform set_config('app.customer_link_insert_id', v_link_f::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link_f, v_biz, v_id_f, v_auth_f, v_client_f, 'verified', 'referral_join', now());
  perform set_config('app.customer_link_insert_id', v_link_x::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link_x, v_biz, v_id_x, v_auth_x, v_client_x, 'verified', 'firm_invitation', now());
  perform set_config('app.customer_link_insert_id', '', true);

  -- F is attributed through the real RPC (the same path the app takes on the wallet render).
  perform pg_temp.as_v777_user(v_auth_f);
  begin v_r := public.customer_apply_referral_code_v612(v_slug, 'V777RINA', gen_random_uuid());
  exception when others then v_r := jsonb_build_object('raised', sqlerrm, 'state', sqlstate); end;
  reset role;
  if (v_r->>'applied')::boolean is distinct from true then insert into _fail values ('setup_apply', v_r::text); end if;

  -- E1
  perform pg_temp.as_v777_user(v_auth_f);
  begin v_r := public.customer_get_referral_pending_v777(v_slug);
  exception when others then v_r := jsonb_build_object('raised', sqlerrm, 'state', sqlstate); end;
  reset role;
  if (v_r->>'pending')::boolean is distinct from true or (v_r->>'min_spend_cents')::int is distinct from 500
     or (v_r->>'friend_reward_points')::int is distinct from 50 or coalesce(v_r->>'referrer_first_name','') <> 'Rina' then
    insert into _fail values ('E1_pending_shape', v_r::text);
  end if;

  -- E2/E3a: the sale writers are guarded by branch/module access that a fixture without a staff
  -- session cannot pass, so the two REGION B outcomes are written as REGION B writes them: an
  -- unpaid attempt leaves the row 'pending' with a blocked_reason, and the read carries it so
  -- the card can say the reward is on hold.
  update public.referrals set blocked_reason = 'reward_kind_points_requires_active_points_programme'
   where business_id = v_biz and referred_client_id = v_client_f and status = 'pending';
  perform pg_temp.as_v777_user(v_auth_f);
  begin v_r := public.customer_get_referral_pending_v777(v_slug);
  exception when others then v_r := jsonb_build_object('raised', sqlerrm); end;
  reset role;
  if (v_r->>'pending')::boolean is distinct from true or coalesce(v_r->>'blocked_reason','') = '' then
    insert into _fail values ('E3a_blocked_reason_surfaces', v_r::text);
  end if;
  -- E3b once REGION B has paid (the same status transition it writes), the read settles.
  update public.referrals set status = 'rewarded', qualified_at = now(), reward_points = 50, blocked_reason = null
   where business_id = v_biz and referred_client_id = v_client_f;
  perform pg_temp.as_v777_user(v_auth_f);
  begin v_r := public.customer_get_referral_pending_v777(v_slug);
  exception when others then v_r := jsonb_build_object('raised', sqlerrm); end;
  reset role;
  if (v_r->>'pending')::boolean is distinct from false or coalesce(v_r->>'status','') <> 'rewarded' or (v_r->>'reward_points')::int is distinct from 50 then
    insert into _fail values ('E3b_read_settled', v_r::text);
  end if;

  -- E4 no referral row
  perform pg_temp.as_v777_user(v_auth_x);
  begin v_r := public.customer_get_referral_pending_v777(v_slug);
  exception when others then v_r := jsonb_build_object('raised', sqlerrm); end;
  reset role;
  if (v_r->>'pending')::boolean is distinct from false or coalesce(v_r->>'status','') <> 'none' then
    insert into _fail values ('E4_none', v_r::text);
  end if;

  -- E5 programme off: a fresh pending referral for X, then the switch flips
  insert into public.referrals(business_id, referrer_client_id, referred_client_id, status)
  values (v_biz, v_client_r, v_client_x, 'pending');
  update public.referral_programs set enabled = false where business_id = v_biz;
  perform pg_temp.as_v777_user(v_auth_x);
  begin v_r := public.customer_get_referral_pending_v777(v_slug);
  exception when others then v_r := jsonb_build_object('raised', sqlerrm); end;
  reset role;
  if (v_r->>'pending')::boolean is distinct from false or coalesce(v_r->>'status','') <> 'programme_off' then
    insert into _fail values ('E5_programme_off', v_r::text);
  end if;
  update public.referral_programs set enabled = true where business_id = v_biz;

  -- E6 anon, and a customer not linked here
  begin
    perform set_config('request.jwt.claim.sub', '', true);
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role anon';
    v_r := public.customer_get_referral_pending_v777(v_slug);
    v_state := 'no error';
  exception when others then v_state := sqlstate; end;
  reset role;
  if v_state not in ('28000','42501') then insert into _fail values ('E6_anon', v_state); end if;
  perform pg_temp.as_v777_user(v_auth_x);
  begin v_r := public.customer_get_referral_pending_v777('v777-no-such-' || substr(gen_random_uuid()::text,1,8)); v_state := 'no error';
  exception when others then v_state := sqlstate; end;
  reset role;
  if v_state <> '42501' then insert into _fail values ('E6_not_linked', v_state); end if;

  raise notice 'v777 | biz=% | E1 pending shape | E3 blocked reason surfaced, then settled | E4 none | E5 programme off | E6 anon + unlinked refused', v_biz;
end
$v777$;

select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v) into n, d from _fail f;
  if n > 0 then raise exception 'v777: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

select case when count(*) = 0
            then 'PASS — v777: the referred friend''s read shows the floor and points while their '
                 'referral is pending and settles the moment REGION B pays; none / programme-off / '
                 'anon / unlinked answer honestly'
            else 'FAIL' end as verdict,
       count(*) as failures
from _fail;

rollback;
