-- EXECUTED acceptance fixture for nestly_v764
-- (db/migrations/20260930_nestly_v764_birthday_rejoin_guard_and_tombstone_ban.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v764_corpus --migrated-only
--
-- WHY THIS EXISTS. Owner, 2026-09-05: a customer who redeems the welcome and birthday rewards,
-- deletes the account and signs up again must not receive them again. v751 left a hashed-phone
-- mark behind every deletion and made the welcome offer and the referral bonus consult it. The
-- birthday auto-grant (v753) never did: its uniqueness is (business, client, birthday_year) and
-- a re-registration is a new client row, so the same number was granted a second birthday gift.
--
-- The deletion RPC itself is not called here: the local harness snapshot has no auth.sessions /
-- auth.mfa_factors / auth.webauthn_credentials tables for it to clear. The mark it would leave
-- is written directly in the exact shape v751 writes it (business_id + SHA-256 of the client's
-- phone_norm); the production rollback suite (db/tests/v764_*.sql) runs the real RPC.
--
-- SCENARIO. One business, live birthday programme, days mode +/-182 (any today is in-window).
--   E1  (positive control) customer K, phone P1, DOB in window, verified link -> granted.
--   E2  the deletion mark for (business, hash(P1)) is written; customer R re-registers with the
--       SAME number: new auth user, identity, profile (same DOB), client (phone P1), link.
--       No entitlement is written for R's client.
--   E3  read as R: public.customer_get_birthday_benefit does NOT answer 'ready_to_activate'
--       (no invitation the server would refuse).
--   E4  as R: public.customer_activate_birthday_benefit raises 42501 — the tap is refused.
--   E5  control customer C, a DIFFERENT number, same DOB, joins -> granted (the mark is
--       per-number, not per-business-wide), and their read answers 'available'.
--   E6  the mark is older than 365 days -> a customer with that number IS granted (the window
--       is the same one v751 chose).
--   E7  the three birthday readers all name app.phone_recently_deleted_v751, and the deletion
--       writer no longer bans with 'infinity': app.v764_tombstone_ban_until() is finite and the
--       RPC body references it.
--
-- One transaction, rolled back. No production access.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

create or replace function pg_temp.as_v764_user(p_uid uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', p_role)::text, true);
end
$$;
grant execute on function pg_temp.as_v764_user(uuid,text) to public;

do $v764$
declare
  v_biz uuid := gen_random_uuid();
  v_ver uuid;
  v_prog uuid := gen_random_uuid();
  v_slug text;
  v_today date := (clock_timestamp() at time zone 'Asia/Singapore')::date;
  v_anchor date := v_today - 5;
  v_dob date := make_date(2000, extract(month from v_anchor)::int, extract(day from v_anchor)::int);
  v_phone1 text := '+65 8123 0' || lpad((floor(random()*1000))::int::text, 3, '0');
  v_phone2 text := '+65 9123 0' || lpad((floor(random()*1000))::int::text, 3, '0');
  v_phone3 text := '+65 9345 0' || lpad((floor(random()*1000))::int::text, 3, '0');
  v_auth_k uuid := gen_random_uuid(); v_auth_r uuid := gen_random_uuid();
  v_auth_c uuid := gen_random_uuid(); v_auth_o uuid := gen_random_uuid();
  v_id_k uuid; v_id_r uuid; v_id_c uuid; v_id_o uuid;
  v_client_k uuid; v_client_r uuid; v_client_c uuid; v_client_o uuid;
  v_link_k uuid := gen_random_uuid(); v_link_r uuid := gen_random_uuid();
  v_link_c uuid := gen_random_uuid(); v_link_o uuid := gen_random_uuid();
  v_count integer; v_read jsonb; v_src text; v_raised text;
begin
  -- Business, approved + subscribed, loyalty on, one published birthday programme.
  insert into public.businesses(id, name, slug, industry, enabled_modules)
  values (v_biz, 'V764 rejoin guard', 'v764-' || substr(gen_random_uuid()::text,1,8), 'fnb',
          array['dashboard','clients','sales','loyalty']);
  select slug into v_slug from public.businesses where id = v_biz;
  insert into public.business_workspace_controls_v94(business_id, approval_status, decided_at, decision_reason)
  values (v_biz, 'approved', now(), 'v764 fixture')
  on conflict (business_id) do update set approval_status='approved', decided_at=now(), decision_reason='v764 fixture';
  insert into public.business_subscription_lifecycle_v94(business_id, state, workspace_paused)
  values (v_biz, 'current', false)
  on conflict (business_id) do update set state='current', workspace_paused=false;
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
  insert into public.birthday_program_versions(
    config_version_id, business_id, program_id, active, sort,
    customer_label, customer_description, customer_terms, fulfillment_kind, discount_percent,
    window_mode, window_days_before, window_days_after)
  values (v_ver, v_biz, v_prog, true, 0, 'Birthday treat', 'fixture', 'terms', 'discount_pct', 20, 'days', 182, 182);
  update public.firm_config_versions set status='published', published_at=now() where id = v_ver;

  -- Four logins / identities / profiles. K = first life of number P1; R = its second life;
  -- C = a different number; O = a number whose mark is older than the window.
  insert into auth.users(instance_id, id, aud, role, email, phone, encrypted_password, email_confirmed_at, created_at, updated_at)
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'v764-' || substr(u.id::text,1,8) || '@example.test', null, '', now(), now(), now()
    from (values (v_auth_k),(v_auth_r),(v_auth_c),(v_auth_o)) as u(id);
  insert into public.customer_identities(auth_user_id, status, created_via)
  select v_auth_k, 'active', 'phone_registration' union all
  select v_auth_r, 'active', 'phone_registration' union all
  select v_auth_c, 'active', 'phone_registration' union all
  select v_auth_o, 'active', 'phone_registration';
  select id into v_id_k from public.customer_identities where auth_user_id = v_auth_k;
  select id into v_id_r from public.customer_identities where auth_user_id = v_auth_r;
  select id into v_id_c from public.customer_identities where auth_user_id = v_auth_c;
  select id into v_id_o from public.customer_identities where auth_user_id = v_auth_o;

  perform set_config('app.c42_profile_identity', v_id_k::text, true);
  insert into public.customer_profiles(identity_id, auth_user_id, full_name, birth_date, preferred_language)
  values (v_id_k, v_auth_k, 'V764 K first life', v_dob, 'en');
  perform set_config('app.c42_profile_identity', v_id_r::text, true);
  insert into public.customer_profiles(identity_id, auth_user_id, full_name, birth_date, preferred_language)
  values (v_id_r, v_auth_r, 'V764 R second life', v_dob, 'en');
  perform set_config('app.c42_profile_identity', v_id_c::text, true);
  insert into public.customer_profiles(identity_id, auth_user_id, full_name, birth_date, preferred_language)
  values (v_id_c, v_auth_c, 'V764 C control', v_dob, 'en');
  perform set_config('app.c42_profile_identity', v_id_o::text, true);
  insert into public.customer_profiles(identity_id, auth_user_id, full_name, birth_date, preferred_language)
  values (v_id_o, v_auth_o, 'V764 O old mark', v_dob, 'en');
  perform set_config('app.c42_profile_identity', '', true);

  -- E1 — first life: K joins with number P1 and is granted (the gate must not touch a customer
  -- with no mark).
  insert into public.clients(id, business_id, full_name, phone) values
    (gen_random_uuid(), v_biz, 'V764 K client', v_phone1) returning id into v_client_k;
  perform set_config('app.customer_link_insert_id', v_link_k::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link_k, v_biz, v_id_k, v_auth_k, v_client_k, 'verified', 'firm_invitation', now());
  perform set_config('app.customer_link_insert_id', '', true);
  select count(*) into v_count from public.customer_birthday_entitlements
   where business_id = v_biz and client_id = v_client_k;
  if v_count <> 1 then
    insert into _fail values ('E1_first_life_granted', format('expected 1 entitlement for K, found %s', v_count));
  end if;

  -- The deletion leaves its mark (exactly what public.customer_delete_account_v749 writes, v751).
  -- K's client row is anonymised the same way so the second life cannot match it by phone.
  insert into public.customer_deletion_marks_v751(business_id, phone_hash)
  select v_biz, app.v89_sha256(c.phone_norm) from public.clients c where c.id = v_client_k;
  update public.clients set phone = null, full_name = 'Erased customer' where id = v_client_k;

  -- E2 — second life: R registers the SAME number, new client, new link. Nothing granted.
  insert into public.clients(id, business_id, full_name, phone) values
    (gen_random_uuid(), v_biz, 'V764 R client', v_phone1) returning id into v_client_r;
  perform set_config('app.customer_link_insert_id', v_link_r::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link_r, v_biz, v_id_r, v_auth_r, v_client_r, 'verified', 'firm_invitation', now());
  perform set_config('app.customer_link_insert_id', '', true);
  select count(*) into v_count from public.customer_birthday_entitlements
   where business_id = v_biz and client_id = v_client_r;
  if v_count <> 0 then
    insert into _fail values ('E2_rejoin_not_granted', format('the re-registered number was granted %s entitlement(s)', v_count));
  end if;
  if not app.phone_recently_deleted_v751(v_biz, v_client_r) then
    insert into _fail values ('E2_mark_recognised', 'phone_recently_deleted_v751 is false for the re-registered number');
  end if;

  -- E3 — the customer read offers no invitation the activate RPC would refuse.
  perform pg_temp.as_v764_user(v_auth_r);
  begin
    v_read := public.customer_get_birthday_benefit(v_slug);
  exception when others then
    v_read := jsonb_build_object('raised', sqlerrm);
  end;
  reset role;
  if coalesce(v_read->>'status','') in ('ready_to_activate','available') then
    insert into _fail values ('E3_no_invitation_on_rejoin', format('customer read answered %s', v_read));
  end if;

  -- E4 — the explicit tap is refused with the same code as "no programme".
  v_raised := null;
  perform pg_temp.as_v764_user(v_auth_r);
  begin
    v_read := public.customer_activate_birthday_benefit(v_slug, gen_random_uuid());
  exception when others then
    v_raised := sqlstate;
  end;
  reset role;
  if v_raised is distinct from '42501' then
    insert into _fail values ('E4_activate_refused', format('expected sqlstate 42501, got %s (read=%s)', coalesce(v_raised,'no error'), v_read));
  end if;
  select count(*) into v_count from public.customer_birthday_entitlements
   where business_id = v_biz and client_id = v_client_r;
  if v_count <> 0 then
    insert into _fail values ('E4_activate_wrote_nothing', format('%s entitlement(s) after the refused tap', v_count));
  end if;

  -- E5 — control: a different number with the same DOB is granted and reads 'available'.
  insert into public.clients(id, business_id, full_name, phone) values
    (gen_random_uuid(), v_biz, 'V764 C client', v_phone2) returning id into v_client_c;
  perform set_config('app.customer_link_insert_id', v_link_c::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link_c, v_biz, v_id_c, v_auth_c, v_client_c, 'verified', 'firm_invitation', now());
  perform set_config('app.customer_link_insert_id', '', true);
  select count(*) into v_count from public.customer_birthday_entitlements
   where business_id = v_biz and client_id = v_client_c;
  if v_count <> 1 then
    insert into _fail values ('E5_control_granted', format('expected 1 entitlement for the control customer, found %s', v_count));
  end if;
  perform pg_temp.as_v764_user(v_auth_c);
  begin
    v_read := public.customer_get_birthday_benefit(v_slug);
  exception when others then
    v_read := jsonb_build_object('raised', sqlerrm);
  end;
  reset role;
  if coalesce(v_read->>'status','') <> 'available' then
    insert into _fail values ('E5_control_reads_available', format('customer read answered %s', v_read));
  end if;

  -- E6 — a mark older than 365 days no longer counts.
  insert into public.clients(id, business_id, full_name, phone) values
    (gen_random_uuid(), v_biz, 'V764 O client', v_phone3) returning id into v_client_o;
  insert into public.customer_deletion_marks_v751(business_id, phone_hash, deleted_at)
  select v_biz, app.v89_sha256(c.phone_norm), now() - interval '366 days' from public.clients c where c.id = v_client_o;
  perform set_config('app.customer_link_insert_id', v_link_o::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link_o, v_biz, v_id_o, v_auth_o, v_client_o, 'verified', 'firm_invitation', now());
  perform set_config('app.customer_link_insert_id', '', true);
  select count(*) into v_count from public.customer_birthday_entitlements
   where business_id = v_biz and client_id = v_client_o;
  if v_count <> 1 then
    insert into _fail values ('E6_old_mark_expired', format('expected 1 entitlement for a mark older than the window, found %s', v_count));
  end if;

  -- E7 — the readers agree, and the tombstone ban is finite.
  for v_src in
    select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname, p.proname) in (('app','v753_birthday_evaluate_and_grant'),
                                      ('public','customer_activate_birthday_benefit'),
                                      ('app','c45_customer_birthday_benefit_for_context'))
  loop
    if v_src not like '%phone_recently_deleted_v751%' then
      insert into _fail values ('E7_reader_missing_gate', left(v_src, 120));
    end if;
  end loop;
  select pg_get_functiondef(p.oid) into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_delete_account_v749';
  if v_src like '%''infinity''::timestamptz%' or v_src not like '%v764_tombstone_ban_until%' then
    insert into _fail values ('E7_delete_ban_finite', 'customer_delete_account_v749 still bans with infinity');
  end if;
  if app.v764_tombstone_ban_until() = 'infinity'::timestamptz or app.v764_tombstone_ban_until() < now() + interval '100 years' then
    insert into _fail values ('E7_ban_until_value', app.v764_tombstone_ban_until()::text);
  end if;

  raise notice 'v764 | biz=% | E1 first life granted | E2 rejoin not granted | E3 no invitation | E4 tap refused 42501 | E5 control granted+available | E6 old mark expired | E7 readers gated, ban finite', v_biz;
end
$v764$;

select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v764: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

select case when count(*) = 0
            then 'PASS — v764: a number that deleted its account at a business in the last 365 days '
                 'is not auto-granted the birthday gift on rejoin, is shown no invitation, and is '
                 'refused at the activate tap; other numbers and expired marks are unaffected; the '
                 'deletion tombstone bans until a finite instant'
            else 'FAIL' end as verdict,
       count(*) as failures
from _fail;

rollback;
