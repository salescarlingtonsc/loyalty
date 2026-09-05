-- nestly_v777 rollback suite — the referred friend can see the reward they are working towards.
--
-- Runs inside ONE transaction ending in ROLLBACK, so it is safe against production.
--
-- WHAT IT PROVES
--   01  public.customer_get_referral_pending_v777(text) exists, STABLE, granted to authenticated
--       and service_role, not to anon.
--   02  on synthetic rows: a pending referral reads pending=true with the programme's floor and
--       the friend's points and the referrer's first name; a customer with no referral reads
--       status 'none'; an unlinked slug is refused 42501.

begin;

create temp table _v777(id int generated always as identity, check_name text, ok boolean, detail text) on commit drop;
grant all on _v777 to public;

create or replace function pg_temp.as_v777_user(p_uid uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', p_role)::text, true);
end
$$;
grant execute on function pg_temp.as_v777_user(uuid,text) to public;

do $$
declare
  v_biz uuid := gen_random_uuid(); v_slug text;
  v_auth_r uuid := gen_random_uuid(); v_auth_f uuid := gen_random_uuid(); v_auth_x uuid := gen_random_uuid();
  v_id_r uuid; v_id_f uuid; v_id_x uuid;
  v_client_r uuid; v_client_f uuid; v_client_x uuid;
  v_link_r uuid := gen_random_uuid(); v_link_f uuid := gen_random_uuid(); v_link_x uuid := gen_random_uuid();
  v_r jsonb; v_state text;
begin
  insert into _v777(check_name, ok, detail)
  select '01 customer_get_referral_pending_v777 exists, stable, authenticated+service_role only',
         p.provolatile = 's'
           and has_function_privilege('authenticated', p.oid, 'EXECUTE')
           and has_function_privilege('service_role', p.oid, 'EXECUTE')
           and not has_function_privilege('anon', p.oid, 'EXECUTE'),
         coalesce(p.proacl::text, '(default)')
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_get_referral_pending_v777';
  if not found then
    insert into _v777(check_name, ok, detail) values ('01 customer_get_referral_pending_v777 exists', false, 'function not found');
  end if;

  insert into public.businesses(id, name, slug, industry, enabled_modules, join_enabled)
  values (v_biz, 'V777 suite', 'v777-' || substr(gen_random_uuid()::text,1,8), 'fnb', array['dashboard','clients','sales','loyalty','referrals'], true);
  select slug into v_slug from public.businesses where id = v_biz;
  insert into public.business_workspace_controls_v94(business_id, approval_status, decided_at, decision_reason)
  values (v_biz, 'approved', now(), 'v777 suite')
  on conflict (business_id) do update set approval_status='approved', decided_at=now(), decision_reason='v777 suite';
  insert into public.business_subscription_lifecycle_v94(business_id, state, workspace_paused)
  values (v_biz, 'current', false) on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions(business_id, status, payment_status, current_period_end)
  values (v_biz, 'active', 'paid', now() + interval '30 days')
  on conflict (business_id) do update set status='active', payment_status='paid', current_period_end=now()+interval '30 days';
  update app.platform_feature_flags set enabled = true, changed_at = now() where feature_key in ('customer_wallet');
  insert into public.referral_programs(business_id, enabled, reward_kind, reward_points, min_spend_cents, friend_enabled)
  values (v_biz, true, 'points', 50, 500, true)
  on conflict (business_id) do update set enabled=true, reward_kind='points', reward_points=50, min_spend_cents=500, friend_enabled=true;

  insert into auth.users(instance_id, id, aud, role, email, phone, encrypted_password, email_confirmed_at, phone_confirmed_at, created_at, updated_at, raw_user_meta_data)
  values ('00000000-0000-0000-0000-000000000000', v_auth_r, 'authenticated', 'authenticated', null, '6590001111', '', null, now(), now(), now(), '{}'::jsonb),
         ('00000000-0000-0000-0000-000000000000', v_auth_f, 'authenticated', 'authenticated', null, '6590002222', '', null, now(), now(), now(), '{}'::jsonb),
         ('00000000-0000-0000-0000-000000000000', v_auth_x, 'authenticated', 'authenticated', null, '6590003333', '', null, now(), now(), now(), '{}'::jsonb);
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
  insert into public.referrals(business_id, referrer_client_id, referred_client_id, status)
  values (v_biz, v_client_r, v_client_f, 'pending');

  perform pg_temp.as_v777_user(v_auth_f);
  begin v_r := public.customer_get_referral_pending_v777(v_slug);
  exception when others then v_r := jsonb_build_object('raised', sqlerrm, 'state', sqlstate); end;
  reset role;
  insert into _v777(check_name, ok, detail) values ('02a pending referral reads floor, points and referrer',
    (v_r->>'pending')::boolean is not distinct from true and (v_r->>'min_spend_cents')::int = 500
      and (v_r->>'friend_reward_points')::int = 50 and coalesce(v_r->>'referrer_first_name','') = 'Rina', v_r::text);

  perform pg_temp.as_v777_user(v_auth_x);
  begin v_r := public.customer_get_referral_pending_v777(v_slug);
  exception when others then v_r := jsonb_build_object('raised', sqlerrm, 'state', sqlstate); end;
  reset role;
  insert into _v777(check_name, ok, detail) values ('02b no referral reads status none',
    (v_r->>'pending')::boolean is not distinct from false and coalesce(v_r->>'status','') = 'none', v_r::text);

  perform pg_temp.as_v777_user(v_auth_x);
  begin v_r := public.customer_get_referral_pending_v777('v777-no-such-' || substr(gen_random_uuid()::text,1,8)); v_state := 'no error';
  exception when others then v_state := sqlstate; end;
  reset role;
  insert into _v777(check_name, ok, detail) values ('02c unlinked slug refused 42501', v_state = '42501', v_state);
end $$;

select id, check_name, ok, detail from _v777 order by id;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed,
       case when count(*) filter (where not ok) = 0 then 'PASS' else 'FAIL' end as verdict
  from _v777;

rollback;
