-- nestly_v767 rollback suite — a friend's referral link joins the business by itself.
--
-- Runs inside ONE transaction ending in ROLLBACK, so it is safe against production.
--
-- WHAT IT PROVES
--   01  public.customer_join_business_by_referral_v767(text,text,uuid) exists, is granted to
--       authenticated and service_role, and not to anon.
--   02  the three CHECK constraints admit the new values (referral_join / referral_join_linked /
--       referral_join_replayed) and still admit qr_join.
--   03  end to end on synthetic rows: a business that accepts joins and runs referrals, a member
--       holding a referral code, a new verified customer — the RPC links them (verification_method
--       'referral_join'), replays idempotently, and the customer's wallet context resolves.
--   04  refusals: a code from another business, referrals off, joins closed -> 22023, no link.

begin;

create temp table _v767(id int generated always as identity, check_name text, ok boolean, detail text) on commit drop;
grant all on _v767 to public;

create or replace function pg_temp.as_v767_user(p_uid uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', p_role)::text, true);
end
$$;
grant execute on function pg_temp.as_v767_user(uuid,text) to public;

do $$
declare
  v_def text;
  v_biz uuid := gen_random_uuid(); v_biz_off uuid := gen_random_uuid(); v_biz_closed uuid := gen_random_uuid();
  v_slug text; v_slug_off text; v_slug_closed text;
  v_auth_n uuid := gen_random_uuid(); v_id_n uuid;
  v_phone_n text := '+65 8123 1' || lpad((floor(random()*1000))::int::text, 3, '0');
  v_key uuid := gen_random_uuid();
  v_r jsonb; v_count integer; v_state text; v_ctx integer;
begin
  -- 01
  insert into _v767(check_name, ok, detail)
  select '01 customer_join_business_by_referral_v767 exists, authenticated+service_role only',
         has_function_privilege('authenticated', p.oid, 'EXECUTE')
           and has_function_privilege('service_role', p.oid, 'EXECUTE')
           and not has_function_privilege('anon', p.oid, 'EXECUTE'),
         coalesce(p.proacl::text, '(default)')
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_join_business_by_referral_v767';
  if not found then
    insert into _v767(check_name, ok, detail) values ('01 customer_join_business_by_referral_v767 exists', false, 'function not found');
  end if;

  -- 02
  for v_def in
    select conname || '=' || pg_get_constraintdef(oid) from pg_constraint
     where conname in ('customer_links_verification_method_check','customer_link_claim_attempts_operation_check','customer_link_audit_events_event_type_check')
  loop
    insert into _v767(check_name, ok, detail)
    values ('02 constraint admits referral_join values: ' || split_part(v_def,'=',1),
            v_def like '%referral_join%' and v_def like '%qr_join%', left(v_def, 160));
  end loop;

  -- 03 fixture
  insert into public.businesses(id, name, slug, industry, enabled_modules, join_enabled) values
    (v_biz, 'V767 suite on', 'v767-on-' || substr(gen_random_uuid()::text,1,8), 'fnb', array['dashboard','clients','sales','loyalty','referrals'], true),
    (v_biz_off, 'V767 suite off', 'v767-off-' || substr(gen_random_uuid()::text,1,8), 'fnb', array['dashboard','clients','sales','loyalty'], true),
    (v_biz_closed, 'V767 suite closed', 'v767-closed-' || substr(gen_random_uuid()::text,1,8), 'fnb', array['dashboard','clients','sales','loyalty','referrals'], false);
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
  update app.platform_feature_flags set enabled = true, changed_at = now() where feature_key in ('customer_wallet','customer_qr_join');
  insert into public.referral_programs(business_id, enabled) values (v_biz, true), (v_biz_closed, true)
  on conflict (business_id) do update set enabled = excluded.enabled;
  insert into public.referral_programs(business_id, enabled) values (v_biz_off, false)
  on conflict (business_id) do update set enabled = false;
  insert into public.clients(business_id, full_name, phone, referral_code) values
    (v_biz, 'V767 referrer', '+65 9000 0001', 'V767FRIEND'),
    (v_biz_off, 'V767 referrer off', '+65 9000 0002', 'V767OFF'),
    (v_biz_closed, 'V767 referrer closed', '+65 9000 0003', 'V767CLOSED');
  insert into auth.users(instance_id, id, aud, role, email, phone, encrypted_password, email_confirmed_at, phone_confirmed_at, created_at, updated_at, raw_user_meta_data)
  values ('00000000-0000-0000-0000-000000000000', v_auth_n, 'authenticated', 'authenticated', null, app.norm_phone(v_phone_n), '', null, now(), now(), now(), '{}'::jsonb);
  insert into public.customer_identities(auth_user_id, status, created_via) values (v_auth_n, 'active', 'phone_registration');
  select id into v_id_n from public.customer_identities where auth_user_id = v_auth_n;
  perform set_config('app.c42_profile_identity', v_id_n::text, true);
  insert into public.customer_profiles(identity_id, auth_user_id, full_name, birth_date, preferred_language) values (v_id_n, v_auth_n, 'V767 new', date '1995-05-05', 'en');
  perform set_config('app.c42_profile_identity', '', true);

  perform pg_temp.as_v767_user(v_auth_n);
  begin v_r := public.customer_join_business_by_referral_v767(v_slug, 'v767friend', v_key);
  exception when others then v_r := jsonb_build_object('raised', sqlerrm, 'state', sqlstate); end;
  reset role;
  insert into _v767(check_name, ok, detail) values ('03a referral join links a new verified customer',
    coalesce(v_r->>'outcome','') = 'linked' and (v_r->>'replayed')::boolean is not distinct from false, v_r::text);
  select count(*) into v_count from public.customer_links l
   where l.business_id = v_biz and l.identity_id = v_id_n and l.state = 'verified' and l.verification_method = 'referral_join';
  insert into _v767(check_name, ok, detail) values ('03b one verified referral_join link', v_count = 1, 'links=' || v_count::text);

  perform pg_temp.as_v767_user(v_auth_n);
  begin v_r := public.customer_join_business_by_referral_v767(v_slug, 'V767FRIEND', gen_random_uuid());
  exception when others then v_r := jsonb_build_object('raised', sqlerrm); end;
  reset role;
  insert into _v767(check_name, ok, detail) values ('03c a member replays, no second link',
    coalesce(v_r->>'outcome','') = 'linked' and (v_r->>'replayed')::boolean is not distinct from true, v_r::text);

  perform pg_temp.as_v767_user(v_auth_n);
  begin v_r := public.customer_apply_referral_code_v612(v_slug, 'V767FRIEND', gen_random_uuid()); v_ctx := 1;
  exception when others then v_ctx := -1; v_r := jsonb_build_object('state', sqlstate, 'raised', sqlerrm); end;
  reset role;
  insert into _v767(check_name, ok, detail) values ('03d customer_apply_referral_code_v612 answers for the joined customer (no 42501)', v_ctx = 1, v_r::text);

  -- 04
  foreach v_state in array array['unknown_code','referrals_off','joins_closed'] loop
    perform pg_temp.as_v767_user(v_auth_n);
    begin
      v_r := case v_state
        when 'unknown_code' then public.customer_join_business_by_referral_v767(v_slug_off, 'V767FRIEND', gen_random_uuid())
        when 'referrals_off' then public.customer_join_business_by_referral_v767(v_slug_off, 'V767OFF', gen_random_uuid())
        else public.customer_join_business_by_referral_v767(v_slug_closed, 'V767CLOSED', gen_random_uuid()) end;
      v_r := jsonb_build_object('state', 'no error');
    exception when others then v_r := jsonb_build_object('state', sqlstate); end;
    reset role;
    insert into _v767(check_name, ok, detail) values ('04 refused 22023: ' || v_state, coalesce(v_r->>'state','') = '22023', v_r::text);
  end loop;
  select count(*) into v_count from public.customer_links l where l.identity_id = v_id_n and l.business_id in (v_biz_off, v_biz_closed);
  insert into _v767(check_name, ok, detail) values ('04 no link written by a refusal', v_count = 0, 'links=' || v_count::text);
end $$;

select id, check_name, ok, detail from _v767 order by id;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed,
       case when count(*) filter (where not ok) = 0 then 'PASS' else 'FAIL' end as verdict
  from _v767;

rollback;
