-- nestly_v764 rollback suite — a deleted-and-re-registered number gets no second birthday gift,
-- and a deleted login is tombstoned with a ban the auth server can read.
--
-- Runs inside ONE transaction ending in ROLLBACK, so it is safe against production.
--
-- WHAT IT PROVES
--   01  the three birthday readers (auto-grant, activate RPC, preview) all consult
--       app.phone_recently_deleted_v751.
--   02  app.v764_tombstone_ban_until() exists, is revoked from anon/authenticated, and answers a
--       finite instant more than 100 years out; customer_delete_account_v749 uses it and no
--       longer writes 'infinity'.
--   03  no v749 tombstone in auth.users still carries banned_until = 'infinity' (the repair ran).
--   04  end to end, on synthetic rows: a customer with an in-window birthday joins a business
--       with a live programme and is granted; they delete their account through the REAL
--       public.customer_delete_account_v749 (role-switched); their auth row is banned until the
--       finite instant; the same number re-registers (new login, identity, client, link) and is
--       NOT granted, reads no 'ready_to_activate', and is refused 42501 at the activate tap.
--   05  a control customer with a different number is granted normally.

begin;

create temp table _v764(id int generated always as identity, check_name text, ok boolean, detail text) on commit drop;
grant all on _v764 to public;

create or replace function pg_temp.as_v764_user(p_uid uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', p_role)::text, true);
end
$$;
grant execute on function pg_temp.as_v764_user(uuid,text) to public;

do $$
declare
  v_src text; v_n integer;
  v_biz uuid := gen_random_uuid(); v_ver uuid; v_prog uuid := gen_random_uuid(); v_slug text;
  v_today date := (clock_timestamp() at time zone 'Asia/Singapore')::date;
  v_anchor date := v_today - 5;
  v_dob date := make_date(2000, extract(month from v_anchor)::int, extract(day from v_anchor)::int);
  v_phone1 text := '+65 8123 0' || lpad((floor(random()*1000))::int::text, 3, '0');
  v_phone2 text := '+65 9123 0' || lpad((floor(random()*1000))::int::text, 3, '0');
  v_auth_k uuid := gen_random_uuid(); v_auth_r uuid := gen_random_uuid(); v_auth_c uuid := gen_random_uuid();
  v_id_k uuid; v_id_r uuid; v_id_c uuid;
  v_client_k uuid; v_client_r uuid; v_client_c uuid;
  v_link_k uuid := gen_random_uuid(); v_link_r uuid := gen_random_uuid(); v_link_c uuid := gen_random_uuid();
  v_count integer; v_read jsonb; v_raised text; v_result jsonb; v_ban timestamptz;
begin
  -- 01
  for v_src in
    select n.nspname || '.' || p.proname || '=' || (pg_get_functiondef(p.oid) like '%phone_recently_deleted_v751%')::text
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname, p.proname) in (('app','v753_birthday_evaluate_and_grant'),
                                      ('public','customer_activate_birthday_benefit'),
                                      ('app','c45_customer_birthday_benefit_for_context'))
  loop
    insert into _v764(check_name, ok, detail)
    values ('01 birthday reader consults phone_recently_deleted_v751: ' || split_part(v_src,'=',1),
            split_part(v_src,'=',2) = 'true', v_src);
  end loop;

  -- 02
  select pg_get_functiondef(p.oid) into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='customer_delete_account_v749';
  insert into _v764(check_name, ok, detail) values
    ('02a customer_delete_account_v749 bans via v764_tombstone_ban_until, never infinity',
     v_src like '%v764_tombstone_ban_until%' and v_src not like '%''infinity''::timestamptz%', '');
  insert into _v764(check_name, ok, detail)
  select '02b app.v764_tombstone_ban_until finite, >100y out, revoked from anon/authenticated',
         app.v764_tombstone_ban_until() <> 'infinity'::timestamptz
           and app.v764_tombstone_ban_until() > now() + interval '100 years'
           and not has_function_privilege('anon', p.oid, 'EXECUTE')
           and not has_function_privilege('authenticated', p.oid, 'EXECUTE'),
         app.v764_tombstone_ban_until()::text
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='app' and p.proname='v764_tombstone_ban_until';

  -- 03
  select count(*) into v_n from auth.users u
   where u.raw_user_meta_data @> '{"deleted_v749": true}'::jsonb and u.banned_until = 'infinity'::timestamptz;
  insert into _v764(check_name, ok, detail) values
    ('03 no v749 tombstone still banned until infinity', v_n = 0, 'remaining=' || v_n::text);

  -- 04/05 fixture
  insert into public.businesses(id, name, slug, industry, enabled_modules)
  values (v_biz, 'V764 suite', 'v764-' || substr(gen_random_uuid()::text,1,8), 'fnb', array['dashboard','clients','sales','loyalty']);
  select slug into v_slug from public.businesses where id = v_biz;
  insert into public.business_workspace_controls_v94(business_id, approval_status, decided_at, decision_reason)
  values (v_biz, 'approved', now(), 'v764 suite')
  -- businesses' own insert trigger seeds a 'pending' control row first, so this is the conflict path.
  on conflict (business_id) do update set approval_status='approved', decided_at=now(), decision_reason='v764 suite';
  insert into public.business_subscription_lifecycle_v94(business_id, state, workspace_paused)
  values (v_biz, 'current', false) on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions(business_id, status, payment_status, current_period_end)
  values (v_biz, 'active', 'paid', now() + interval '30 days')
  on conflict (business_id) do update set status='active', payment_status='paid', current_period_end=now()+interval '30 days';
  update app.platform_feature_flags set enabled = true, changed_at = now()
   where feature_key in ('customer_wallet', 'customer_birthday_benefits');
  insert into public.firm_config_versions(id, business_id, version_no, status, snapshot_hash)
  values (gen_random_uuid(), v_biz, 1, 'draft', md5('v764'));
  select id into v_ver from public.firm_config_versions where business_id = v_biz;
  update public.businesses set active_config_version_id = v_ver where id = v_biz;
  insert into public.birthday_programs(id, business_id) values (v_prog, v_biz);
  insert into public.birthday_program_versions(config_version_id, business_id, program_id, active, sort,
    customer_label, customer_description, customer_terms, fulfillment_kind, discount_percent,
    window_mode, window_days_before, window_days_after)
  values (v_ver, v_biz, v_prog, true, 0, 'Birthday treat', 'suite', 'terms', 'discount_pct', 20, 'days', 182, 182);
  update public.firm_config_versions set status='published', published_at=now() where id = v_ver;

  insert into auth.users(instance_id, id, aud, role, email, phone, encrypted_password, email_confirmed_at, phone_confirmed_at, created_at, updated_at, raw_user_meta_data)
  values ('00000000-0000-0000-0000-000000000000', v_auth_k, 'authenticated', 'authenticated', null, app.norm_phone(v_phone1) , '', null, now(), now(), now(), '{}'::jsonb),
         ('00000000-0000-0000-0000-000000000000', v_auth_r, 'authenticated', 'authenticated', null, null, '', null, null, now(), now(), '{}'::jsonb),
         ('00000000-0000-0000-0000-000000000000', v_auth_c, 'authenticated', 'authenticated', null, null, '', null, null, now(), now(), '{}'::jsonb);
  insert into public.customer_identities(auth_user_id, status, created_via)
  values (v_auth_k,'active','phone_registration'), (v_auth_r,'active','phone_registration'), (v_auth_c,'active','phone_registration');
  select id into v_id_k from public.customer_identities where auth_user_id = v_auth_k;
  select id into v_id_r from public.customer_identities where auth_user_id = v_auth_r;
  select id into v_id_c from public.customer_identities where auth_user_id = v_auth_c;
  perform set_config('app.c42_profile_identity', v_id_k::text, true);
  insert into public.customer_profiles(identity_id, auth_user_id, full_name, birth_date, preferred_language) values (v_id_k, v_auth_k, 'V764 K', v_dob, 'en');
  perform set_config('app.c42_profile_identity', v_id_r::text, true);
  insert into public.customer_profiles(identity_id, auth_user_id, full_name, birth_date, preferred_language) values (v_id_r, v_auth_r, 'V764 R', v_dob, 'en');
  perform set_config('app.c42_profile_identity', v_id_c::text, true);
  insert into public.customer_profiles(identity_id, auth_user_id, full_name, birth_date, preferred_language) values (v_id_c, v_auth_c, 'V764 C', v_dob, 'en');
  perform set_config('app.c42_profile_identity', '', true);

  insert into public.clients(id, business_id, full_name, phone) values (gen_random_uuid(), v_biz, 'V764 K client', v_phone1) returning id into v_client_k;
  perform set_config('app.customer_link_insert_id', v_link_k::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link_k, v_biz, v_id_k, v_auth_k, v_client_k, 'verified', 'firm_invitation', now());
  perform set_config('app.customer_link_insert_id', '', true);
  select count(*) into v_count from public.customer_birthday_entitlements where business_id = v_biz and client_id = v_client_k;
  insert into _v764(check_name, ok, detail) values ('04a first life is granted on join', v_count = 1, 'rows=' || v_count::text);

  -- The real deletion, as the customer.
  perform pg_temp.as_v764_user(v_auth_k);
  begin
    v_result := public.customer_delete_account_v749('DELETE', 'v764-suite-' || v_auth_k::text);
  exception when others then
    v_result := jsonb_build_object('status','raised','error',sqlerrm);
  end;
  reset role;
  insert into _v764(check_name, ok, detail) values ('04b customer_delete_account_v749 deleted', v_result->>'status' = 'deleted', v_result::text);
  select banned_until into v_ban from auth.users where id = v_auth_k;
  insert into _v764(check_name, ok, detail) values ('04c tombstone banned until the finite instant',
    v_ban = app.v764_tombstone_ban_until(), coalesce(v_ban::text,'null'));
  select count(*) into v_count from public.customer_deletion_marks_v751 m
   where m.business_id = v_biz and m.phone_hash = app.v89_sha256(app.norm_phone(v_phone1));
  insert into _v764(check_name, ok, detail) values ('04d per-business mark written', v_count = 1, 'marks=' || v_count::text);

  -- Second life of the same number.
  insert into public.clients(id, business_id, full_name, phone) values (gen_random_uuid(), v_biz, 'V764 R client', v_phone1) returning id into v_client_r;
  perform set_config('app.customer_link_insert_id', v_link_r::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link_r, v_biz, v_id_r, v_auth_r, v_client_r, 'verified', 'firm_invitation', now());
  perform set_config('app.customer_link_insert_id', '', true);
  select count(*) into v_count from public.customer_birthday_entitlements where business_id = v_biz and client_id = v_client_r;
  insert into _v764(check_name, ok, detail) values ('04e rejoin is NOT granted', v_count = 0, 'rows=' || v_count::text);

  perform pg_temp.as_v764_user(v_auth_r);
  begin v_read := public.customer_get_birthday_benefit(v_slug); exception when others then v_read := jsonb_build_object('raised', sqlerrm); end;
  reset role;
  insert into _v764(check_name, ok, detail) values ('04f rejoin sees no invitation',
    coalesce(v_read->>'status','') not in ('ready_to_activate','available'), coalesce(v_read::text,'null'));

  v_raised := null;
  perform pg_temp.as_v764_user(v_auth_r);
  begin v_read := public.customer_activate_birthday_benefit(v_slug, gen_random_uuid()); exception when others then v_raised := sqlstate; end;
  reset role;
  insert into _v764(check_name, ok, detail) values ('04g rejoin activate tap refused 42501', v_raised = '42501', coalesce(v_raised,'no error'));

  -- 05 control
  insert into public.clients(id, business_id, full_name, phone) values (gen_random_uuid(), v_biz, 'V764 C client', v_phone2) returning id into v_client_c;
  perform set_config('app.customer_link_insert_id', v_link_c::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link_c, v_biz, v_id_c, v_auth_c, v_client_c, 'verified', 'firm_invitation', now());
  perform set_config('app.customer_link_insert_id', '', true);
  select count(*) into v_count from public.customer_birthday_entitlements where business_id = v_biz and client_id = v_client_c;
  insert into _v764(check_name, ok, detail) values ('05 a different number is granted normally', v_count = 1, 'rows=' || v_count::text);
end $$;

select id, check_name, ok, detail from _v764 order by id;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed,
       case when count(*) filter (where not ok) = 0 then 'PASS' else 'FAIL' end as verdict
  from _v764;

rollback;
