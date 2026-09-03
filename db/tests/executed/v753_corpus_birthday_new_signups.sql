-- EXECUTED acceptance fixture for nestly_v753
-- (db/migrations/20260924_nestly_v753_birthday_reaches_new_signups.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v753_corpus --migrated-only
--
-- WHY THIS EXISTS. Owner ruling, 2026-09-04 (photo 3, the Birthday gift editor's window
-- fields "Days before 182 / Days after 182"): "When a window period for the birthday gift...
-- is allocated, NEW sign-ups whose birthday falls within the reward period must receive the
-- birthday reward as well ... once the account is registered." Before this migration, the
-- entitlement row (public.customer_birthday_entitlements) was written only by the customer's
-- own explicit tap (public.customer_activate_birthday_benefit) -- a signup landing inside the
-- window got nothing until they found the button. v753 adds two AFTER triggers that call the
-- same primitives (app.c45_birthday_window, app.c45_benefit_snapshot) the instant a customer
-- becomes a member of a business, or their date of birth becomes known.
--
-- SCENARIO. Five businesses, each isolated so one programme shape cannot leak into another
-- assertion:
--   biz_wide   -- days mode, +/-182, live.        (E1, E5 idempotency, E6 fail-soft)
--   biz_narrow -- days mode, +/-3, live.           (E2)
--   biz_month  -- month mode, live.                (E3, two customers: in-month / out-of-month)
--   biz_off    -- days mode, +/-182, PROGRAMME OFF (birthday_program_versions.active = false).
--                                                   (E4)
-- Every customer opts into birthday participation (customer_birthday_participation.opted_in)
-- BEFORE their link is created, matching the identical consent gate the pre-existing read path
-- and activate RPC already enforce -- this migration adds no new consent path.
--
-- ASSERTIONS:
--   E1  biz_wide, a customer whose birthday was 5 days ago (SG calendar) registers (their
--       customer_links row goes straight to state='verified' -- the only insert shape
--       app.v31_link_immutable_guard allows). An entitlement row appears immediately, no
--       "activate" tap needed, and the SAME RPC the customer app calls
--       (public.customer_get_birthday_benefit, read as the customer via role switch) reports
--       status 'available' -- not 'ready_to_activate'.
--   E2  biz_narrow (+/-3 days), a customer whose birthday is 40 days away registers. No
--       entitlement is written -- 40 days is outside a 3-day window.
--   E3  biz_month: a customer born in the current SG month registers and IS granted; a second
--       customer born six months off registers and is NOT granted -- proves month mode is
--       evaluated, not defaulted to a fixed day count.
--   E4  biz_off (programme explicitly inactive): a customer whose birthday sits inside what
--       would otherwise be a live window registers. Nothing is granted, AND the link itself
--       still succeeds (business logic staying off never blocks a signup).
--   E5  Idempotency: (a) calling the shared primitive
--       (app.v753_birthday_evaluate_and_grant) a second time with byte-identical arguments for
--       the E1 customer creates no second row; (b) the E1 customer's link is unlinked and a
--       FRESH verified link is inserted for the same business/client/identity (a genuine second
--       "becomes a member" event, replayed through app.v31_link_immutable_guard's own
--       unlink/relink path) -- the entitlement count for that customer/business/year stays at
--       exactly 1 throughout.
--   E6  Fail-soft: app.v753_birthday_evaluate_and_grant is temporarily replaced (inside this
--       same rolled-back transaction only, restored via pg_get_functiondef before the verdict)
--       with a stub that unconditionally raises. A brand-new customer_links insert for a
--       fresh customer on biz_wide still SUCCEEDS -- the birthday evaluation failing never
--       blocks the membership it rode in on -- and, since the evaluator never reached its own
--       INSERT, no entitlement row is written for that customer.
--
--   E7  AMENDMENT (owner ruling 2026-09-04, "giving a DOB at signup = participating"): the
--       E1 customer had NO prior customer_birthday_participation row before their DOB was
--       written. A row now exists, opted_in=true, with a matching replay-safe receipt in
--       customer_birthday_participation_operations (actor = the customer).
--   E8  AMENDMENT: a customer who EXPLICITLY set opted_in=false BEFORE their DOB was ever
--       written (biz_wide, birthday inside the window) stays false, and nothing is granted --
--       the auto opt-in's ON CONFLICT (identity_id) DO NOTHING never touches an existing choice.
--   E9  AMENDMENT: that same customer then calls the REAL public.customer_set_birthday_
--       participation(true, ...) RPC (role-switched, as the customer app does). The in-window
--       reward appears immediately -- no wallet visit, no sweep, no second action.
--
-- MUTATION CHECK (documented, not re-run here; performed once by hand against a throwaway
-- Postgres before this suite was finalised): commenting out the `if not found then return; end
-- if;` guard immediately after the app.c45_birthday_window call -- so a customer outside their
-- window falls through to the INSERT -- turns E2 red (a grant appears 40 days out). Swapping
-- `v_program.window_mode` for the literal 'days' in that same call turns E3 red (the
-- in-month customer stops being granted because month mode is never evaluated). Both were
-- confirmed to fail before being reverted.
--
-- One transaction, rolled back. No production access.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

create or replace function pg_temp.as_v753_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub', p_uid, 'role', p_role
  )::text, true);
end
$$;
grant execute on function pg_temp.as_v753_user(uuid,text) to public;

do $v753$
declare
  v_biz_wide   uuid := gen_random_uuid();
  v_biz_narrow uuid := gen_random_uuid();
  v_biz_month  uuid := gen_random_uuid();
  v_biz_off    uuid := gen_random_uuid();

  v_ver_wide   uuid;
  v_ver_narrow uuid;
  v_ver_month  uuid;
  v_ver_off    uuid;

  v_prog_wide   uuid := gen_random_uuid();
  v_prog_narrow uuid := gen_random_uuid();
  v_prog_month  uuid := gen_random_uuid();
  v_prog_off    uuid := gen_random_uuid();

  v_today       date := (clock_timestamp() at time zone 'Asia/Singapore')::date;

  -- E1: birthday 5 days ago, built in a leap year (2000) so a February 29 edge case never
  -- breaks the fixture regardless of which real calendar day this suite happens to run on.
  v_e1_anchor   date := v_today - 5;
  v_e1_dob      date := make_date(2000, extract(month from v_e1_anchor)::int, extract(day from v_e1_anchor)::int);

  -- E2: birthday 40 days away, outside a +/-3 day window.
  v_e2_anchor   date := v_today + 40;
  v_e2_dob      date := make_date(2000, extract(month from v_e2_anchor)::int, extract(day from v_e2_anchor)::int);

  -- E3: one customer born in the current SG month (day 10, always valid), one six months off.
  v_e3a_dob     date := make_date(2000, extract(month from v_today)::int, 10);
  v_e3b_month   int  := ((extract(month from v_today)::int + 5) % 12) + 1; -- + 6 months, wrapped
  v_e3b_dob     date := make_date(2000, v_e3b_month, 10);

  -- E4: same shape as E1 (would grant if the programme were live).
  v_e4_dob      date := v_e1_dob;

  v_auth_e1     uuid := gen_random_uuid();
  v_auth_e2     uuid := gen_random_uuid();
  v_auth_e3a    uuid := gen_random_uuid();
  v_auth_e3b    uuid := gen_random_uuid();
  v_auth_e4     uuid := gen_random_uuid();
  v_auth_e6     uuid := gen_random_uuid();

  v_id_e1       uuid; v_id_e2 uuid; v_id_e3a uuid; v_id_e3b uuid; v_id_e4 uuid; v_id_e6 uuid;
  v_client_e1   uuid; v_client_e2 uuid; v_client_e3a uuid; v_client_e3b uuid; v_client_e4 uuid; v_client_e6 uuid;
  v_link_e1     uuid := gen_random_uuid();
  v_link_e2     uuid := gen_random_uuid();
  v_link_e3a    uuid := gen_random_uuid();
  v_link_e3b    uuid := gen_random_uuid();
  v_link_e4     uuid := gen_random_uuid();
  v_link_e6     uuid := gen_random_uuid();
  v_link_e5b    uuid := gen_random_uuid();

  v_slug_wide   text;
  v_count       integer;
  v_read        jsonb;
  v_orig_fn     text;

  -- E8/E9: same in-window shape as E1/E4, on biz_wide. E8's participation row is created
  -- EXPLICITLY opted_in=false BEFORE its customer_profiles row exists, so the auto-opt-in
  -- ON CONFLICT DO NOTHING must find it already present and leave it alone. E9 reuses this same
  -- customer and later flips it on through the REAL public.customer_set_birthday_participation
  -- RPC (role-switched, exactly as the customer app calls it).
  v_auth_e89    uuid := gen_random_uuid();
  v_id_e89      uuid;
  v_client_e89  uuid;
  v_link_e89    uuid := gen_random_uuid();
  v_e89_dob     date := v_e1_dob;
  v_set_result  jsonb;
begin
  -----------------------------------------------------------------------------------------------
  -- Four businesses. Each gets an approved workspace + active subscription (the same faithful-
  -- tenant shape v748/v741 use), the loyalty module, and its own published birthday programme.
  -----------------------------------------------------------------------------------------------
  insert into public.businesses(id, name, slug, industry, enabled_modules)
  values
    (v_biz_wide,   'V753 wide window',   'v753-wide-'   || substr(gen_random_uuid()::text,1,8), 'fnb', array['dashboard','clients','sales','loyalty']),
    (v_biz_narrow, 'V753 narrow window', 'v753-narrow-' || substr(gen_random_uuid()::text,1,8), 'fnb', array['dashboard','clients','sales','loyalty']),
    (v_biz_month,  'V753 month mode',    'v753-month-'  || substr(gen_random_uuid()::text,1,8), 'fnb', array['dashboard','clients','sales','loyalty']),
    (v_biz_off,    'V753 programme off', 'v753-off-'    || substr(gen_random_uuid()::text,1,8), 'fnb', array['dashboard','clients','sales','loyalty']);

  select slug into v_slug_wide from public.businesses where id = v_biz_wide;

  insert into public.business_workspace_controls_v94(business_id, approval_status, decided_at, decision_reason)
  select b.id, 'approved', now(), 'v753 fixture' from public.businesses b
   where b.id in (v_biz_wide, v_biz_narrow, v_biz_month, v_biz_off)
  on conflict (business_id) do update set approval_status='approved', decided_at=now(), decision_reason='v753 fixture';

  insert into public.business_subscription_lifecycle_v94(business_id, state, workspace_paused)
  select b.id, 'current', false from public.businesses b
   where b.id in (v_biz_wide, v_biz_narrow, v_biz_month, v_biz_off)
  on conflict (business_id) do update set state='current', workspace_paused=false;

  insert into public.subscriptions(business_id, status, payment_status, current_period_end)
  select b.id, 'active', 'paid', now() + interval '30 days' from public.businesses b
   where b.id in (v_biz_wide, v_biz_narrow, v_biz_month, v_biz_off)
  on conflict (business_id) do update
    set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  update app.platform_feature_flags set enabled = true, changed_at = now()
   where feature_key in ('customer_wallet', 'customer_birthday_benefits');

  -- One published config version + one birthday programme per business, following the same
  -- publish order the v560 fixture uses: version rows are immutable once published, so the
  -- config is promoted to 'published' only AFTER its birthday_program_versions row exists.
  insert into public.firm_config_versions(id, business_id, version_no, status, snapshot_hash)
  values
    (gen_random_uuid(), v_biz_wide,   1, 'draft', md5('v753-wide')),
    (gen_random_uuid(), v_biz_narrow, 1, 'draft', md5('v753-narrow')),
    (gen_random_uuid(), v_biz_month,  1, 'draft', md5('v753-month')),
    (gen_random_uuid(), v_biz_off,    1, 'draft', md5('v753-off'));

  select id into v_ver_wide   from public.firm_config_versions where business_id = v_biz_wide;
  select id into v_ver_narrow from public.firm_config_versions where business_id = v_biz_narrow;
  select id into v_ver_month  from public.firm_config_versions where business_id = v_biz_month;
  select id into v_ver_off    from public.firm_config_versions where business_id = v_biz_off;

  update public.businesses set active_config_version_id = v_ver_wide   where id = v_biz_wide;
  update public.businesses set active_config_version_id = v_ver_narrow where id = v_biz_narrow;
  update public.businesses set active_config_version_id = v_ver_month  where id = v_biz_month;
  update public.businesses set active_config_version_id = v_ver_off    where id = v_biz_off;

  insert into public.birthday_programs(id, business_id) values
    (v_prog_wide, v_biz_wide), (v_prog_narrow, v_biz_narrow),
    (v_prog_month, v_biz_month), (v_prog_off, v_biz_off);

  insert into public.birthday_program_versions(
    config_version_id, business_id, program_id, active, sort,
    customer_label, customer_description, customer_terms, fulfillment_kind, discount_percent,
    window_mode, window_days_before, window_days_after
  ) values
    (v_ver_wide,   v_biz_wide,   v_prog_wide,   true,  0, 'Birthday treat', 'fixture', 'terms', 'discount_pct', 20, 'days',  182, 182),
    (v_ver_narrow, v_biz_narrow, v_prog_narrow, true,  0, 'Birthday treat', 'fixture', 'terms', 'discount_pct', 20, 'days',  3,   3),
    (v_ver_month,  v_biz_month,  v_prog_month,  true,  0, 'Birthday treat', 'fixture', 'terms', 'discount_pct', 20, 'month', 0,   0),
    -- E4: programme OFF -- active=false is the only thing distinguishing this row.
    (v_ver_off,    v_biz_off,    v_prog_off,    false, 0, 'Birthday treat', 'fixture', 'terms', 'discount_pct', 20, 'days',  182, 182);

  update public.firm_config_versions set status='published', published_at=now()
   where id in (v_ver_wide, v_ver_narrow, v_ver_month, v_ver_off);

  -----------------------------------------------------------------------------------------------
  -- Six auth users, six identities, one profile each (birth_date set once at "registration",
  -- exactly as public.customer_register_verified_phone does it), opted into birthday
  -- participation BEFORE any link exists -- the same consent gate the pre-existing read path
  -- and activate RPC already require.
  -----------------------------------------------------------------------------------------------
  insert into auth.users(
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  )
  select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
         'v753-' || substr(u.id::text,1,8) || '@example.test', '', now(), now(), now()
    from (values (v_auth_e1),(v_auth_e2),(v_auth_e3a),(v_auth_e3b),(v_auth_e4),(v_auth_e6),(v_auth_e89)) as u(id);

  insert into public.customer_identities(auth_user_id, status, created_via)
  select v_auth_e1,  'active', 'phone_registration' union all
  select v_auth_e2,  'active', 'phone_registration' union all
  select v_auth_e3a, 'active', 'phone_registration' union all
  select v_auth_e3b, 'active', 'phone_registration' union all
  select v_auth_e4,  'active', 'phone_registration' union all
  select v_auth_e6,  'active', 'phone_registration' union all
  select v_auth_e89, 'active', 'phone_registration';

  select id into v_id_e1  from public.customer_identities where auth_user_id = v_auth_e1;
  select id into v_id_e2  from public.customer_identities where auth_user_id = v_auth_e2;
  select id into v_id_e3a from public.customer_identities where auth_user_id = v_auth_e3a;
  select id into v_id_e3b from public.customer_identities where auth_user_id = v_auth_e3b;
  select id into v_id_e4  from public.customer_identities where auth_user_id = v_auth_e4;
  select id into v_id_e6  from public.customer_identities where auth_user_id = v_auth_e6;
  select id into v_id_e89 from public.customer_identities where auth_user_id = v_auth_e89;

  -- app.c42_profile_guard refuses any write whose row identity_id does not match the
  -- transaction-local app.c42_profile_identity setting (customer_register_verified_phone's own
  -- guard rail) -- one row per SET, exactly as that RPC does it.
  perform set_config('app.c42_profile_identity', v_id_e1::text, true);
  insert into public.customer_profiles(identity_id, auth_user_id, full_name, birth_date, preferred_language)
  values (v_id_e1, v_auth_e1, 'V753 E1 customer', v_e1_dob, 'en');
  perform set_config('app.c42_profile_identity', v_id_e2::text, true);
  insert into public.customer_profiles(identity_id, auth_user_id, full_name, birth_date, preferred_language)
  values (v_id_e2, v_auth_e2, 'V753 E2 customer', v_e2_dob, 'en');
  perform set_config('app.c42_profile_identity', v_id_e3a::text, true);
  insert into public.customer_profiles(identity_id, auth_user_id, full_name, birth_date, preferred_language)
  values (v_id_e3a, v_auth_e3a, 'V753 E3a customer', v_e3a_dob, 'en');
  perform set_config('app.c42_profile_identity', v_id_e3b::text, true);
  insert into public.customer_profiles(identity_id, auth_user_id, full_name, birth_date, preferred_language)
  values (v_id_e3b, v_auth_e3b, 'V753 E3b customer', v_e3b_dob, 'en');
  perform set_config('app.c42_profile_identity', v_id_e4::text, true);
  insert into public.customer_profiles(identity_id, auth_user_id, full_name, birth_date, preferred_language)
  values (v_id_e4, v_auth_e4, 'V753 E4 customer', v_e4_dob, 'en');
  perform set_config('app.c42_profile_identity', v_id_e6::text, true);
  insert into public.customer_profiles(identity_id, auth_user_id, full_name, birth_date, preferred_language)
  values (v_id_e6, v_auth_e6, 'V753 E6 customer', v_e1_dob, 'en');
  perform set_config('app.c42_profile_identity', '', true);

  -- AMENDMENT (owner ruling 2026-09-04, "giving a date of birth at signup = participating"):
  -- no explicit customer_birthday_participation row is inserted for E1/E2/E3a/E3b/E4/E6 here --
  -- each customer_profiles insert above already fired trg_v753_birthday_grant_on_profile_dob_set,
  -- which auto-created opted_in=true for every one of them (none had a prior row). This is
  -- exercised, not stubbed: E1's later assertions (and E7 below) prove the auto-opt-in actually
  -- happened, rather than assuming it.

  -----------------------------------------------------------------------------------------------
  -- E8/E9 setup. The order is the whole point: the participation row is created EXPLICITLY,
  -- opted_in=FALSE, BEFORE this identity's customer_profiles row exists -- an explicit prior
  -- choice, not the auto-opt-in path. When the DOB is then written, trg_v753_birthday_grant_on_
  -- profile_dob_set's own auto-insert hits ON CONFLICT (identity_id) DO NOTHING and must leave
  -- the false row untouched.
  -----------------------------------------------------------------------------------------------
  insert into public.customer_birthday_participation(identity_id, auth_user_id, opted_in)
  values (v_id_e89, v_auth_e89, false);

  perform set_config('app.c42_profile_identity', v_id_e89::text, true);
  insert into public.customer_profiles(identity_id, auth_user_id, full_name, birth_date, preferred_language)
  values (v_id_e89, v_auth_e89, 'V753 E8/E9 customer', v_e89_dob, 'en');
  perform set_config('app.c42_profile_identity', '', true);

  -----------------------------------------------------------------------------------------------
  -- Clients + verified links. Every insert goes through the SAME shape the app's own writers
  -- use: app.customer_link_insert_id set to the row's own id, state='verified' from the first
  -- instant -- app.v31_link_immutable_guard refuses anything else. This IS "a customer becomes
  -- a member of a business" -- the event under test.
  -----------------------------------------------------------------------------------------------
  insert into public.clients(id, business_id, full_name) values
    (gen_random_uuid(), v_biz_wide,   'V753 E1 client')  returning id into v_client_e1;
  insert into public.clients(id, business_id, full_name) values
    (gen_random_uuid(), v_biz_narrow, 'V753 E2 client')  returning id into v_client_e2;
  insert into public.clients(id, business_id, full_name) values
    (gen_random_uuid(), v_biz_month,  'V753 E3a client') returning id into v_client_e3a;
  insert into public.clients(id, business_id, full_name) values
    (gen_random_uuid(), v_biz_month,  'V753 E3b client') returning id into v_client_e3b;
  insert into public.clients(id, business_id, full_name) values
    (gen_random_uuid(), v_biz_off,    'V753 E4 client')  returning id into v_client_e4;
  insert into public.clients(id, business_id, full_name) values
    (gen_random_uuid(), v_biz_wide,   'V753 E6 client')  returning id into v_client_e6;
  insert into public.clients(id, business_id, full_name) values
    (gen_random_uuid(), v_biz_wide,   'V753 E8/E9 client') returning id into v_client_e89;

  perform set_config('app.customer_link_insert_id', v_link_e1::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link_e1, v_biz_wide, v_id_e1, v_auth_e1, v_client_e1, 'verified', 'firm_invitation', now());
  perform set_config('app.customer_link_insert_id', '', true);

  perform set_config('app.customer_link_insert_id', v_link_e2::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link_e2, v_biz_narrow, v_id_e2, v_auth_e2, v_client_e2, 'verified', 'firm_invitation', now());
  perform set_config('app.customer_link_insert_id', '', true);

  perform set_config('app.customer_link_insert_id', v_link_e3a::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link_e3a, v_biz_month, v_id_e3a, v_auth_e3a, v_client_e3a, 'verified', 'firm_invitation', now());
  perform set_config('app.customer_link_insert_id', '', true);

  perform set_config('app.customer_link_insert_id', v_link_e3b::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link_e3b, v_biz_month, v_id_e3b, v_auth_e3b, v_client_e3b, 'verified', 'firm_invitation', now());
  perform set_config('app.customer_link_insert_id', '', true);

  perform set_config('app.customer_link_insert_id', v_link_e4::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link_e4, v_biz_off, v_id_e4, v_auth_e4, v_client_e4, 'verified', 'firm_invitation', now());
  perform set_config('app.customer_link_insert_id', '', true);

  perform set_config('app.customer_link_insert_id', v_link_e89::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link_e89, v_biz_wide, v_id_e89, v_auth_e89, v_client_e89, 'verified', 'firm_invitation', now());
  perform set_config('app.customer_link_insert_id', '', true);

  -----------------------------------------------------------------------------------------------
  -- E1 -- the link above already fired the trigger. An entitlement must exist immediately, and
  -- the customer's own RPC (the exact read the customer app calls) must report 'available'.
  -----------------------------------------------------------------------------------------------
  select count(*) into v_count from public.customer_birthday_entitlements
   where business_id = v_biz_wide and client_id = v_client_e1;
  if v_count <> 1 then
    insert into _fail values ('E1_entitlement_row',
      format('expected exactly 1 entitlement row for the E1 customer immediately after their link, found %s', v_count));
  end if;

  perform pg_temp.as_v753_user(v_auth_e1);
  begin
    v_read := public.customer_get_birthday_benefit(v_slug_wide);
  exception when others then
    insert into _fail values ('E1_customer_read_raised', sqlerrm);
  end;
  reset role;
  if v_read is null or v_read->>'status' <> 'available' then
    insert into _fail values ('E1_customer_read_status',
      format('customer_get_birthday_benefit returned %s, expected status=available with no activate tap', coalesce(v_read::text,'NULL')));
  end if;

  -----------------------------------------------------------------------------------------------
  -- E7 -- AMENDMENT: the E1 customer signed up with a DOB inside the window and NO prior
  -- participation row. Proves the auto-opt-in itself, distinct from E1's entitlement/read
  -- checks above: a customer_birthday_participation row must exist, opted_in=true, with a
  -- matching replay-safe receipt in customer_birthday_participation_operations (actor = the
  -- customer's own auth id, opted_in=true) -- the same shape an explicit
  -- customer_set_birthday_participation(true, ...) call would have written.
  -----------------------------------------------------------------------------------------------
  if not exists (
    select 1 from public.customer_birthday_participation
     where identity_id = v_id_e1 and auth_user_id = v_auth_e1 and opted_in = true
  ) then
    insert into _fail values ('E7_participation_auto_created',
      'no opted_in=true customer_birthday_participation row exists for the E1 customer after their DOB was written with no prior row');
  end if;
  if not exists (
    select 1 from public.customer_birthday_participation_operations
     where identity_id = v_id_e1 and actor_auth_user_id = v_auth_e1 and opted_in = true
  ) then
    insert into _fail values ('E7_participation_receipt',
      'no matching customer_birthday_participation_operations receipt was written for the E1 customer''s auto opt-in');
  end if;

  -----------------------------------------------------------------------------------------------
  -- E8 -- AMENDMENT: a customer who EXPLICITLY set opted_in=false before their DOB was ever
  -- written stays false, and nothing is granted, even though their birthday sits inside
  -- biz_wide's live window and they are now a verified member of it.
  -----------------------------------------------------------------------------------------------
  if not exists (
    select 1 from public.customer_birthday_participation
     where identity_id = v_id_e89 and opted_in = false
  ) then
    insert into _fail values ('E8_participation_stays_false',
      'the E8/E9 customer''s explicit opted_in=false row was flipped by the DOB write / link -- it must never be');
  end if;
  select count(*) into v_count from public.customer_birthday_entitlements
   where business_id = v_biz_wide and client_id = v_client_e89;
  if v_count <> 0 then
    insert into _fail values ('E8_no_grant',
      format('a customer who explicitly opted out was still granted a birthday benefit (found %s row(s))', v_count));
  end if;

  -----------------------------------------------------------------------------------------------
  -- E9 -- AMENDMENT: the SAME E8 customer now turns birthday participation ON through the REAL
  -- public.customer_set_birthday_participation RPC (role-switched, exactly as the customer app
  -- calls it). The in-window reward must appear immediately -- no separate wallet visit, no
  -- sweep, no second action.
  -----------------------------------------------------------------------------------------------
  perform pg_temp.as_v753_user(v_auth_e89);
  begin
    v_set_result := public.customer_set_birthday_participation(true, gen_random_uuid());
  exception when others then
    insert into _fail values ('E9_set_participation_raised', sqlerrm);
  end;
  reset role;
  if v_set_result is null or (v_set_result->>'opted_in')::boolean is not true then
    insert into _fail values ('E9_set_participation_result',
      format('customer_set_birthday_participation returned %s, expected opted_in=true', coalesce(v_set_result::text,'NULL')));
  end if;
  select count(*) into v_count from public.customer_birthday_entitlements
   where business_id = v_biz_wide and client_id = v_client_e89;
  if v_count <> 1 then
    insert into _fail values ('E9_grant_on_opt_in',
      format('turning birthday participation ON produced %s entitlement row(s) for the now-opted-in customer, expected exactly 1', v_count));
  end if;

  -----------------------------------------------------------------------------------------------
  -- E2 -- 40 days away, +/-3 day window: nothing granted.
  -----------------------------------------------------------------------------------------------
  select count(*) into v_count from public.customer_birthday_entitlements
   where business_id = v_biz_narrow and client_id = v_client_e2;
  if v_count <> 0 then
    insert into _fail values ('E2_no_grant',
      format('a birthday 40 days away was granted under a +/-3 day window (%s row(s))', v_count));
  end if;

  -- A SECOND, UNWRAPPED direct call to the primitive itself -- not through a trigger's
  -- fail-soft wrapper. If a defect (e.g. the window guard removed) made the underlying
  -- function raise on a null birthday_year, the trigger path above would silently swallow
  -- that exception and RAISE WARNING, leaving the entitlement count at 0 by ACCIDENT rather
  -- than by correct evaluation -- indistinguishable from this suite's own PASS. Calling the
  -- function directly here, with nothing catching the exception, turns that failure mode into
  -- a hard error for this whole suite instead of a silently-passing assertion.
  perform app.v753_birthday_evaluate_and_grant(v_biz_narrow, v_client_e2, v_id_e2, v_e2_dob, statement_timestamp());
  select count(*) into v_count from public.customer_birthday_entitlements
   where business_id = v_biz_narrow and client_id = v_client_e2;
  if v_count <> 0 then
    insert into _fail values ('E2_direct_call_no_grant',
      format('a direct call for a birthday 40 days away still granted under a +/-3 day window (%s row(s))', v_count));
  end if;

  -----------------------------------------------------------------------------------------------
  -- E3 -- month mode: in-month customer granted, six-months-off customer not.
  -----------------------------------------------------------------------------------------------
  select count(*) into v_count from public.customer_birthday_entitlements
   where business_id = v_biz_month and client_id = v_client_e3a;
  if v_count <> 1 then
    insert into _fail values ('E3a_in_month_granted',
      format('month-mode programme did not grant an in-month birthday (found %s row(s))', v_count));
  end if;

  select count(*) into v_count from public.customer_birthday_entitlements
   where business_id = v_biz_month and client_id = v_client_e3b;
  if v_count <> 0 then
    insert into _fail values ('E3b_out_of_month_not_granted',
      format('month-mode programme granted a birthday six months off (found %s row(s))', v_count));
  end if;

  -- Same reinforcement as E2 above: direct, unwrapped calls so a window_mode mutation
  -- (e.g. hardcoding 'days' in place of v_program.window_mode) surfaces as a hard failure
  -- here rather than being masked by the trigger's fail-soft exception handling.
  perform app.v753_birthday_evaluate_and_grant(v_biz_month, v_client_e3a, v_id_e3a, v_e3a_dob, statement_timestamp());
  perform app.v753_birthday_evaluate_and_grant(v_biz_month, v_client_e3b, v_id_e3b, v_e3b_dob, statement_timestamp());
  select count(*) into v_count from public.customer_birthday_entitlements
   where business_id = v_biz_month and client_id = v_client_e3a;
  if v_count <> 1 then
    insert into _fail values ('E3a_direct_call_granted',
      format('a direct call for an in-month birthday produced %s row(s), expected exactly 1', v_count));
  end if;
  select count(*) into v_count from public.customer_birthday_entitlements
   where business_id = v_biz_month and client_id = v_client_e3b;
  if v_count <> 0 then
    insert into _fail values ('E3b_direct_call_no_grant',
      format('a direct call for a birthday six months off produced %s row(s), expected 0', v_count));
  end if;

  -----------------------------------------------------------------------------------------------
  -- E4 -- programme OFF: nothing granted, and the link itself still succeeded (it is already
  -- sitting in customer_links with state='verified' -- if it hadn't, the inserts above would
  -- have raised and this whole DO block would already have failed).
  -----------------------------------------------------------------------------------------------
  select count(*) into v_count from public.customer_birthday_entitlements
   where business_id = v_biz_off and client_id = v_client_e4;
  if v_count <> 0 then
    insert into _fail values ('E4_no_grant_programme_off',
      format('a programme with active=false still granted a birthday benefit (found %s row(s))', v_count));
  end if;
  if not exists (select 1 from public.customer_links
                  where id = v_link_e4 and state = 'verified') then
    insert into _fail values ('E4_link_still_succeeded',
      'the E4 link is missing or not verified -- the programme being off must never block a signup');
  end if;

  -----------------------------------------------------------------------------------------------
  -- E5a -- calling the shared primitive a second time with identical arguments creates no
  -- second row (the constraint + ON CONFLICT both new triggers rely on).
  -----------------------------------------------------------------------------------------------
  perform app.v753_birthday_evaluate_and_grant(v_biz_wide, v_client_e1, v_id_e1, v_e1_dob, statement_timestamp());
  select count(*) into v_count from public.customer_birthday_entitlements
   where business_id = v_biz_wide and client_id = v_client_e1;
  if v_count <> 1 then
    insert into _fail values ('E5a_direct_replay_idempotent',
      format('a second direct call to the evaluator produced %s row(s), expected exactly 1', v_count));
  end if;

  -----------------------------------------------------------------------------------------------
  -- E5b -- a genuine second "becomes a member" event: unlink the E1 customer (the same
  -- unlink shape nestly_v473's erasure path uses -- app.customer_link_transition_id set to the
  -- row's own id), then insert a FRESH verified link for the same business/client/identity.
  -- The AFTER INSERT trigger fires again; the entitlement count must still be exactly 1.
  -----------------------------------------------------------------------------------------------
  perform set_config('app.customer_link_transition_id', v_link_e1::text, true);
  update public.customer_links
     set state = 'unlinked', unlinked_at = now(), unlinked_by_auth_user_id = v_auth_e1, updated_at = now()
   where id = v_link_e1;
  perform set_config('app.customer_link_transition_id', '', true);

  perform set_config('app.customer_link_insert_id', v_link_e5b::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link_e5b, v_biz_wide, v_id_e1, v_auth_e1, v_client_e1, 'verified', 'firm_invitation', now());
  perform set_config('app.customer_link_insert_id', '', true);

  select count(*) into v_count from public.customer_birthday_entitlements
   where business_id = v_biz_wide and client_id = v_client_e1;
  if v_count <> 1 then
    insert into _fail values ('E5b_relink_idempotent',
      format('a second real link-verified event produced %s entitlement row(s) for the same customer/business/year, expected exactly 1', v_count));
  end if;

  -----------------------------------------------------------------------------------------------
  -- E6 -- fail-soft: the evaluator is temporarily replaced with a stub that always raises. A
  -- brand-new link insert on biz_wide must still succeed, and must write no entitlement.
  -----------------------------------------------------------------------------------------------
  v_orig_fn := pg_get_functiondef('app.v753_birthday_evaluate_and_grant(uuid,uuid,uuid,date,timestamptz)'::regprocedure);

  create or replace function app.v753_birthday_evaluate_and_grant(
    p_business_id uuid, p_client_id uuid, p_identity_id uuid, p_birth_date date, p_as_of timestamptz
  )
  returns void language plpgsql as $stub$
  begin
    raise exception 'v753 E6 simulated evaluation failure (intentional, test-only, restored before this suite ends)';
  end
  $stub$;

  begin
    perform set_config('app.customer_link_insert_id', v_link_e6::text, true);
    insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
    values (v_link_e6, v_biz_wide, v_id_e6, v_auth_e6, v_client_e6, 'verified', 'firm_invitation', now());
    perform set_config('app.customer_link_insert_id', '', true);
  exception when others then
    insert into _fail values ('E6_link_insert_must_not_fail',
      format('a birthday-evaluation failure propagated out of the link insert: %s', sqlerrm));
  end;

  -- Restore the real function before any further assertion runs.
  execute v_orig_fn;

  if not exists (select 1 from public.customer_links where id = v_link_e6 and state = 'verified') then
    insert into _fail values ('E6_link_verified',
      'the E6 link did not end up verified despite the evaluator being stubbed to fail');
  end if;
  select count(*) into v_count from public.customer_birthday_entitlements
   where business_id = v_biz_wide and client_id = v_client_e6;
  if v_count <> 0 then
    insert into _fail values ('E6_no_grant_while_stubbed',
      format('the stubbed evaluator still wrote %s entitlement row(s) -- it should have raised before reaching its own INSERT', v_count));
  end if;

  -- Prove the restore actually worked: a direct call now succeeds and grants normally on a
  -- fresh (business, client) pair reusing the E6 customer's own in-window DOB.
  perform app.v753_birthday_evaluate_and_grant(v_biz_wide, v_client_e6, v_id_e6, v_e1_dob, statement_timestamp());
  select count(*) into v_count from public.customer_birthday_entitlements
   where business_id = v_biz_wide and client_id = v_client_e6;
  if v_count <> 1 then
    insert into _fail values ('E6_restore_verified',
      format('after restoring the real function, a direct call produced %s row(s), expected exactly 1', v_count));
  end if;

  raise notice 'v753 | wide=% narrow=% month=% off=% | E1 entitlement+customer-RPC available | E7 auto-opt-in participation+receipt | E8 explicit opt-out stays false, no grant | E9 real opt-in RPC grants immediately | E2 no grant (40d/+-3) | E3 month mode in/out | E4 programme-off no grant, link still verified | E5 direct-replay + real relink both idempotent | E6 stubbed evaluator failed closed, link still succeeded, restore verified',
    v_biz_wide, v_biz_narrow, v_biz_month, v_biz_off;
end
$v753$;

select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v753: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

select case when count(*) = 0
            then 'PASS — v753: a customer whose link verifies (or whose date of birth becomes '
                 'known) while inside a live birthday programme''s window is granted the '
                 'benefit immediately, with the same one-per-window/year rule and the same '
                 'programme-off/module-off silence as the existing read and activate paths, and '
                 'never at the cost of the signup or link itself. Giving a DOB with no prior '
                 'choice auto-opts a customer in (with a real receipt); an explicit opt-out is '
                 'never flipped back on; turning participation on later grants immediately'
            else 'FAIL' end as verdict,
       count(*) as failures
from _fail;

rollback;
