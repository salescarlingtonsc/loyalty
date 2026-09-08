-- EXECUTED acceptance fixture for nestly_v764
-- (db/migrations/20260930_nestly_v764_birthday_rejoin_guard_and_tombstone_ban.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v764_corpus --migrated-only
--
-- SUPERSEDED BY nestly_v831 (2026-09-09). Read this before changing it back.
--
-- v764 certified the rule "a deleted-and-re-registered number gets no second birthday gift",
-- keyed on app.phone_recently_deleted_v751 — a hashed-phone mark left by the ACCOUNT DELETION,
-- honoured for 365 days. The owner overturned exactly that rule on 2026-09-09: "if customer used
-- welcome rewards / birthday rewards / referral from company A and did not use for company B ...
-- will not enjoy the same benefit anymore for company A, while company B will still get to enjoy
-- all benefits as yet to use up. for birthday ... not able to enjoy this year's birthday,
-- subsequent years still able." Deleting is no longer the trigger; CONSUMING is, and the birthday
-- gift is scoped to the YEAR that was consumed.
--
-- So E2/E3/E4 now assert the OPPOSITE of what v764 asserted, on purpose, and E6 asserts that a
-- deletion mark decides nothing at all. Do NOT "repair" them back — that would re-impose a rule
-- the owner removed, and the old behaviour had a hard bug: the 365 days ran from the deletion
-- date, and the next birthday anniversary is always inside 365 days, so every deletion always
-- cost one future birthday, used or not. E8 is the assertion that still protects the business.
--
-- SCENARIO. One business, live birthday programme, days mode +/-182 (any today is in-window).
--   E1  (positive control) customer K, phone P1, DOB in window, verified link -> granted.
--   E2  K deletes (mark written, client anonymised); customer R re-registers with the SAME
--       number having NEVER USED the gift -> IS granted, and carries no consumption mark.
--   E3  read as R: the customer IS offered the benefit.
--   E4  as R: the activate tap is NOT refused, and the entitlement stands.
--   E5  control customer C, a DIFFERENT number, same DOB, joins -> granted, reads 'available'.
--   E6  a deletion mark, however recent, no longer withholds anything.
--   E8  R USES this year's gift (entitlement -> 'redeemed', which writes the consumption mark),
--       deletes, and customer T re-registers with the SAME number: nothing is granted, the read
--       offers no invitation, and the tap is refused 42501 — while NEXT year's period key is
--       still clean, so T's birthday returns next year.
--   E7  the three birthday readers all name app.benefit_consumed_v831, and the deletion writer
--       still bans with a finite instant (app.v764_tombstone_ban_until(), unchanged by v831).
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
  v_auth_t uuid := gen_random_uuid();   -- nestly_v831: third life, AFTER the gift was used
  v_id_k uuid; v_id_r uuid; v_id_c uuid; v_id_o uuid; v_id_t uuid;
  v_client_k uuid; v_client_r uuid; v_client_c uuid; v_client_o uuid; v_client_t uuid;
  v_link_k uuid := gen_random_uuid(); v_link_r uuid := gen_random_uuid();
  v_link_c uuid := gen_random_uuid(); v_link_o uuid := gen_random_uuid();
  v_link_t uuid := gen_random_uuid();
  v_count integer; v_read jsonb; v_src text; v_raised text;
  v_ent uuid; v_year integer;
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
    from (values (v_auth_k),(v_auth_r),(v_auth_c),(v_auth_o),(v_auth_t)) as u(id);
  insert into public.customer_identities(auth_user_id, status, created_via)
  select v_auth_k, 'active', 'phone_registration' union all
  select v_auth_r, 'active', 'phone_registration' union all
  select v_auth_c, 'active', 'phone_registration' union all
  select v_auth_o, 'active', 'phone_registration' union all
  select v_auth_t, 'active', 'phone_registration';
  select id into v_id_k from public.customer_identities where auth_user_id = v_auth_k;
  select id into v_id_r from public.customer_identities where auth_user_id = v_auth_r;
  select id into v_id_c from public.customer_identities where auth_user_id = v_auth_c;
  select id into v_id_o from public.customer_identities where auth_user_id = v_auth_o;
  select id into v_id_t from public.customer_identities where auth_user_id = v_auth_t;

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
  perform set_config('app.c42_profile_identity', v_id_t::text, true);
  insert into public.customer_profiles(identity_id, auth_user_id, full_name, birth_date, preferred_language)
  values (v_id_t, v_auth_t, 'V831 T third life', v_dob, 'en');
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
  select birthday_year into v_year from public.customer_birthday_entitlements
   where business_id = v_biz and client_id = v_client_k limit 1;

  -- The deletion leaves its mark (exactly what public.customer_delete_account_v749 writes, v751).
  -- K's client row is anonymised the same way so the second life cannot match it by phone.
  insert into public.customer_deletion_marks_v751(business_id, phone_hash)
  select v_biz, app.v89_sha256(c.phone_norm) from public.clients c where c.id = v_client_k;
  update public.clients set phone = null, full_name = 'Erased customer' where id = v_client_k;

  -- E2 — second life: R registers the SAME number having never USED the gift. nestly_v831: the
  -- deletion mark above decides nothing, so R IS granted.
  insert into public.clients(id, business_id, full_name, phone) values
    (gen_random_uuid(), v_biz, 'V764 R client', v_phone1) returning id into v_client_r;
  perform set_config('app.customer_link_insert_id', v_link_r::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link_r, v_biz, v_id_r, v_auth_r, v_client_r, 'verified', 'firm_invitation', now());
  perform set_config('app.customer_link_insert_id', '', true);
  select count(*) into v_count from public.customer_birthday_entitlements
   where business_id = v_biz and client_id = v_client_r;
  if v_count <> 1 then
    insert into _fail values ('E2_rejoin_granted_when_unused', format('an unused gift was withheld after a rejoin: %s entitlement(s)', v_count));
  end if;
  if app.benefit_consumed_v831(v_biz, v_client_r, 'birthday', v_year::text) then
    insert into _fail values ('E2_no_consumption_yet', 'the number is marked as having consumed a birthday gift it never used');
  end if;

  -- E3 — nestly_v831: the read DOES offer it; nothing was consumed.
  perform pg_temp.as_v764_user(v_auth_r);
  begin
    v_read := public.customer_get_birthday_benefit(v_slug);
  exception when others then
    v_read := jsonb_build_object('raised', sqlerrm);
  end;
  reset role;
  if coalesce(v_read->>'status','') not in ('ready_to_activate','available') then
    insert into _fail values ('E3_invitation_on_unused_rejoin', format('customer read answered %s', v_read));
  end if;

  -- E4 — nestly_v831: the explicit tap is NOT refused, and the entitlement stands.
  v_raised := null;
  perform pg_temp.as_v764_user(v_auth_r);
  begin
    v_read := public.customer_activate_birthday_benefit(v_slug, gen_random_uuid());
  exception when others then
    v_raised := sqlstate;
  end;
  reset role;
  if v_raised is not null then
    insert into _fail values ('E4_activate_allowed', format('an unused rejoin was refused with sqlstate %s', v_raised));
  end if;
  select count(*) into v_count from public.customer_birthday_entitlements
   where business_id = v_biz and client_id = v_client_r;
  if v_count <> 1 then
    insert into _fail values ('E4_entitlement_stands', format('%s entitlement(s) after the tap', v_count));
  end if;


  -- E8 — nestly_v831, the assertion that still protects the business. R USES this year's gift,
  -- deletes, and T re-registers the SAME number: refused for THIS year, clean for the next.
  select id into v_ent from public.customer_birthday_entitlements
   where business_id = v_biz and client_id = v_client_r limit 1;
  perform set_config('app.c45_entitlement_id', v_ent::text, true);
  update public.customer_birthday_entitlements set status = 'redeemed' where id = v_ent;
  perform set_config('app.c45_entitlement_id', '', true);
  if not app.benefit_consumed_v831(v_biz, v_client_r, 'birthday', v_year::text) then
    insert into _fail values ('E8_consumption_recorded', 'redeeming this year''s birthday gift wrote no consumption mark');
  end if;
  if app.benefit_consumed_v831(v_biz, v_client_r, 'birthday', (v_year + 1)::text) then
    insert into _fail values ('E8_next_year_clean', 'using this year''s birthday also burned next year''s');
  end if;

  update public.clients set phone = null, full_name = 'Erased customer' where id = v_client_r;
  insert into public.clients(id, business_id, full_name, phone) values
    (gen_random_uuid(), v_biz, 'V831 T client', v_phone1) returning id into v_client_t;
  perform set_config('app.customer_link_insert_id', v_link_t::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link_t, v_biz, v_id_t, v_auth_t, v_client_t, 'verified', 'firm_invitation', now());
  perform set_config('app.customer_link_insert_id', '', true);
  select count(*) into v_count from public.customer_birthday_entitlements
   where business_id = v_biz and client_id = v_client_t;
  if v_count <> 0 then
    insert into _fail values ('E8_used_rejoin_not_granted', format('a number that used this year''s gift was granted %s entitlement(s) again', v_count));
  end if;

  perform pg_temp.as_v764_user(v_auth_t);
  begin
    v_read := public.customer_get_birthday_benefit(v_slug);
  exception when others then
    v_read := jsonb_build_object('raised', sqlerrm);
  end;
  reset role;
  if coalesce(v_read->>'status','') in ('ready_to_activate','available') then
    insert into _fail values ('E8_no_invitation', format('customer read answered %s', v_read));
  end if;

  v_raised := null;
  perform pg_temp.as_v764_user(v_auth_t);
  begin
    v_read := public.customer_activate_birthday_benefit(v_slug, gen_random_uuid());
  exception when others then
    v_raised := sqlstate;
  end;
  reset role;
  if v_raised is distinct from '42501' then
    insert into _fail values ('E8_activate_refused', format('expected sqlstate 42501, got %s', coalesce(v_raised,'no error')));
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

  -- E6 — nestly_v831: a deletion mark decides nothing at all, at any age.
  insert into public.clients(id, business_id, full_name, phone) values
    (gen_random_uuid(), v_biz, 'V764 O client', v_phone3) returning id into v_client_o;
  insert into public.customer_deletion_marks_v751(business_id, phone_hash, deleted_at)
  select v_biz, app.v89_sha256(c.phone_norm), now() from public.clients c where c.id = v_client_o;
  perform set_config('app.customer_link_insert_id', v_link_o::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link_o, v_biz, v_id_o, v_auth_o, v_client_o, 'verified', 'firm_invitation', now());
  perform set_config('app.customer_link_insert_id', '', true);
  select count(*) into v_count from public.customer_birthday_entitlements
   where business_id = v_biz and client_id = v_client_o;
  if v_count <> 1 then
    insert into _fail values ('E6_deletion_mark_irrelevant', format('a fresh deletion mark still withheld the gift: found %s entitlement(s)', v_count));
  end if;

  -- E7 — the readers agree, and the tombstone ban is finite.
  for v_src in
    select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname, p.proname) in (('app','v753_birthday_evaluate_and_grant'),
                                      ('public','customer_activate_birthday_benefit'),
                                      ('app','c45_customer_birthday_benefit_for_context'))
  loop
    if v_src not like '%benefit_consumed_v831%' then
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

  raise notice 'v764/v831 | biz=% | E1 first life granted | E2 unused rejoin granted | E3 invited | E4 tap allowed | E5 control granted+available | E6 deletion mark irrelevant | E8 used-then-rejoined refused, next year clean | E7 readers gated, ban finite', v_biz;
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
