-- v424 executed acceptance — the birthday window a customer is promised is the one they get.
--
--   psql -v ON_ERROR_STOP=1 -f db/tests/executed/v424_birthday_window.sql
--
-- Self-contained: it builds its own firm, owner, customers and programme, and RAISES on the first
-- failure. Nothing is committed — the whole file is one transaction ending in ROLLBACK.
--
-- What it proves, in the order it proves it:
--   A. The Singapore calendar contract of app.c45_birthday_window, at exact instants, including
--      the SGT boundary where the UTC date and the SGT date disagree and the Feb-29 rule.
--   B. Month mode: activation SUCCEEDS on a day that is not the birthday, and the entitlement it
--      writes spans the WHOLE Asia/Singapore birthday month. This is the P0 — before v424 the
--      activation path called the 4-argument overload and this refused with 42501.
--   C. The promise and the enforcement agree: what customer_get_birthday_benefit offers is the
--      same validity window customer_activate_birthday_benefit writes.
--   D. Day-window mode still honours window_days_before / window_days_after, in both directions.
--   E. business_save_birthday_program_v424 saves AND publishes in one transaction, is idempotent
--      on a repeated key, and refuses a different edit under a key already used.
--
-- Deliberately NOT time-travelled: public.customer_activate_birthday_benefit reads
-- statement_timestamp(), so "as of" cannot be injected. Every fixture birth date is therefore
-- derived from the CURRENT Asia/Singapore date, and the exact-instant boundaries (2026-09-01
-- 00:30+08 and friends) are asserted directly against app.c45_birthday_window in part A.

begin;

do $v424$
declare
  v_biz uuid := gen_random_uuid();
  v_slug text := 'zz-v424-'||substr(md5(random()::text),1,8);
  v_owner uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_seed uuid := gen_random_uuid();
  v_prog uuid := gen_random_uuid();

  v_sg_today date;
  v_sg_dom integer;
  v_bday_dom integer;
  v_birth_month date;          -- birthday inside this SG month, never today
  v_birth_recent date;         -- birthday 2 days ago (inside a 3/3 day window)
  v_birth_far date;            -- birthday 5 days ago (outside a 3/3 day window)
  v_birth_other date;          -- birthday in a different month entirely

  v_month_from timestamptz;
  v_month_until timestamptz;

  v_saved jsonb;
  v_replay jsonb;
  v_benefit jsonb;
  v_activated jsonb;
  v_ent public.customer_birthday_entitlements%rowtype;

  v_year integer; v_from timestamptz; v_until timestamptz; v_rows integer;
  v_c1 uuid; v_c2 uuid; v_c3 uuid; v_c4 uuid;
  v_l1 uuid; v_l2 uuid; v_l3 uuid; v_l4 uuid;
  v_i1 uuid; v_i2 uuid; v_i3 uuid; v_i4 uuid;
  v_u1 uuid; v_u2 uuid; v_u3 uuid; v_u4 uuid;
  v_state text;
begin
  reset role;

  -- ==========================================================================================
  -- A. THE SINGAPORE CALENDAR CONTRACT, AT EXACT INSTANTS
  -- ==========================================================================================
  -- Month mode covers the whole SG month of the observed birthday.
  select birthday_year, valid_from, valid_until into v_year, v_from, v_until
    from app.c45_birthday_window(date '1993-08-05', 0, 0, timestamptz '2026-08-22 12:00+08', 'month');
  if v_year is distinct from 2026
     or v_from is distinct from timestamptz '2026-08-01 00:00+08'
     or v_until is distinct from timestamptz '2026-09-01 00:00+08' then
    raise exception 'v424 A1: month window wrong: % .. % (year %)', v_from, v_until, v_year;
  end if;

  -- The half-open end: 00:30 SGT on 1 September is OUTSIDE the August month.
  select count(*) into v_rows
    from app.c45_birthday_window(date '1993-08-05', 0, 0, timestamptz '2026-09-01 00:30+08', 'month');
  if v_rows <> 0 then
    raise exception 'v424 A2: the birthday month did not close at SG midnight';
  end if;
  -- ...and 23:30 SGT on 31 August is still inside it.
  select count(*) into v_rows
    from app.c45_birthday_window(date '1993-08-05', 0, 0, timestamptz '2026-08-31 23:30+08', 'month');
  if v_rows <> 1 then
    raise exception 'v424 A3: the last evening of the birthday month was refused';
  end if;

  -- The SGT boundary where the UTC date differs from the SG date. 2026-08-31 17:00Z is
  -- 2026-09-01 01:00 SGT: a UTC-thinking implementation would still call it August.
  select count(*) into v_rows
    from app.c45_birthday_window(date '1993-08-05', 0, 0, timestamptz '2026-08-31 17:00+00', 'month');
  if v_rows <> 0 then
    raise exception 'v424 A4: the window was computed in UTC, not Asia/Singapore';
  end if;
  -- ...and the mirror: 2026-07-31 16:30Z is 2026-08-01 00:30 SGT, already inside August.
  select valid_from into v_from
    from app.c45_birthday_window(date '1993-08-05', 0, 0, timestamptz '2026-07-31 16:30+00', 'month');
  if v_from is distinct from timestamptz '2026-08-01 00:00+08' then
    raise exception 'v424 A5: SG month did not open at SG midnight, got %', v_from;
  end if;

  -- Day mode, same programme values, is a different answer: 0/0 on a non-birthday is no window.
  select count(*) into v_rows
    from app.c45_birthday_window(date '1993-08-05', 0, 0, timestamptz '2026-08-22 12:00+08', 'days');
  if v_rows <> 0 then
    raise exception 'v424 A6: day mode behaved like month mode';
  end if;
  -- Day mode with a real window honours both sides, half-open at the end.
  select valid_from, valid_until into v_from, v_until
    from app.c45_birthday_window(date '1993-08-20', 3, 3, timestamptz '2026-08-22 12:00+08', 'days');
  if v_from is distinct from timestamptz '2026-08-17 00:00+08'
     or v_until is distinct from timestamptz '2026-08-24 00:00+08' then
    raise exception 'v424 A7: 3/3 day window wrong: % .. %', v_from, v_until;
  end if;
  select count(*) into v_rows
    from app.c45_birthday_window(date '1993-08-20', 3, 3, timestamptz '2026-08-24 00:00+08', 'days');
  if v_rows <> 0 then
    raise exception 'v424 A8: the day window did not close at SG midnight';
  end if;

  -- Feb 29 maps to Feb 28 in a non-leap year, and stays Feb 29 in a leap year.
  if app.c45_observed_birthday(date '1992-02-29', 2026) <> date '2026-02-28'
     or app.c45_observed_birthday(date '1992-02-29', 2028) <> date '2028-02-29' then
    raise exception 'v424 A9: the Feb-29 observed-birthday rule changed';
  end if;
  select valid_from, valid_until into v_from, v_until
    from app.c45_birthday_window(date '1992-02-29', 0, 0, timestamptz '2026-02-15 12:00+08', 'month');
  if v_from is distinct from timestamptz '2026-02-01 00:00+08'
     or v_until is distinct from timestamptz '2026-03-01 00:00+08' then
    raise exception 'v424 A10: leap-day birthday month wrong: % .. %', v_from, v_until;
  end if;
  select valid_from, valid_until into v_from, v_until
    from app.c45_birthday_window(date '1992-02-29', 1, 1, timestamptz '2026-02-28 12:00+08', 'days');
  -- observed 2026-02-28, minus 1 day, plus 1 day, half-open: 27 Feb 00:00 SGT -> 2 Mar 00:00 SGT.
  if v_from is distinct from timestamptz '2026-02-27 00:00+08'
     or v_until is distinct from timestamptz '2026-03-02 00:00+08' then
    raise exception 'v424 A11: leap-day day-window wrong: % .. %', v_from, v_until;
  end if;

  -- ==========================================================================================
  -- FIXTURE: one firm, one owner, one published loyalty configuration
  -- ==========================================================================================
  v_sg_today := (timezone('Asia/Singapore', statement_timestamp()))::date;
  v_sg_dom := extract(day from v_sg_today)::integer;
  -- A day of the current SG month that is never today, and that exists in every month.
  v_bday_dom := case when v_sg_dom >= 15 then 1 else 28 end;
  v_birth_month := make_date(1993, extract(month from v_sg_today)::integer, v_bday_dom);
  v_birth_recent := make_date(1993, extract(month from (v_sg_today - 2))::integer,
                                    extract(day from (v_sg_today - 2))::integer);
  v_birth_far := make_date(1993, extract(month from (v_sg_today - 5))::integer,
                                 extract(day from (v_sg_today - 5))::integer);
  v_birth_other := make_date(1993, extract(month from (v_sg_today + interval '5 months'))::integer, 15);
  v_month_from := (date_trunc('month', v_sg_today::timestamp) at time zone 'Asia/Singapore');
  v_month_until := ((date_trunc('month', v_sg_today::timestamp) + interval '1 month') at time zone 'Asia/Singapore');

  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
    'zz-v424-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.businesses(id,name,slug,industry,is_synthetic,enabled_modules)
  values (v_biz,'ZZ v424 birthday fixture',v_slug,'test',true,
    array['dashboard','clients','sales','loyalty']);
  insert into public.staff(business_id,user_id,role,full_name,active)
  values (v_biz,v_owner,'owner','ZZ v424 owner',true);
  insert into public.branches(id,business_id,name,is_default,active)
  values (v_branch,v_biz,'ZZ v424 main',true,true);
  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_by=v_owner,
         decided_at=clock_timestamp(), decision_reason='v424 acceptance fixture',
         updated_at=clock_timestamp()
   where business_id=v_biz;
  insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
  values (v_biz,false)
  on conflict (business_id) do update set workspace_paused=false;
  -- v620: business_operational_v620 additionally requires a paid (or trialing) subscriptions
  -- row on top of the approved+unpaused workspace above.
  insert into public.subscriptions(business_id, status, payment_status, current_period_end)
  values (v_biz, 'active', 'paid', now() + interval '30 days')
  on conflict (business_id) do update
    set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  insert into public.firm_config_versions(id,business_id,version_no,status,source,snapshot_hash,created_by)
  values (v_seed,v_biz,1,'draft','manual',md5('v424-seed'),v_owner);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner,'role','authenticated')::text,true);
  insert into public.loyalty_program_versions(
    config_version_id,business_id,kind,loyalty_model,active,
    earn_points_per_dollar,redeem_points,reward_credit_cents,tier_basis,expiry_mode)
  values (v_seed,v_biz,'points','points_tiers',true,1,150,0,'points_earned','none');
  perform set_config('request.jwt.claims','{}',true);
  update public.firm_config_versions set status='published',published_at=clock_timestamp()
   where id=v_seed;
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,current_config_version_id)
  values (v_biz,'points',true,'points_tiers','published',v_seed);
  perform set_config('app.v79_system_transition','on',true);
  update public.businesses set active_config_version_id=v_seed where id=v_biz;
  perform set_config('app.v79_system_transition','',true);

  update app.platform_feature_flags set enabled=true, changed_at=statement_timestamp()
   where feature_key in ('customer_identity','customer_claims','customer_wallet','customer_birthday_benefits');

  -- Four customers: one for the month test, two for the day-window tests, one whose birthday is
  -- in another month. Each needs their own client, identity, profile and verified link, and the
  -- per-customer/year entitlement uniqueness is why they cannot be the same person.
  v_u1:=gen_random_uuid(); v_i1:=gen_random_uuid(); v_c1:=gen_random_uuid();
  v_u2:=gen_random_uuid(); v_i2:=gen_random_uuid(); v_c2:=gen_random_uuid();
  v_u3:=gen_random_uuid(); v_i3:=gen_random_uuid(); v_c3:=gen_random_uuid();
  v_u4:=gen_random_uuid(); v_i4:=gen_random_uuid(); v_c4:=gen_random_uuid();
  v_l1:=gen_random_uuid(); v_l2:=gen_random_uuid(); v_l3:=gen_random_uuid(); v_l4:=gen_random_uuid();
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_u1,'authenticated','authenticated','zz-v424-c1-'||substr(v_u1::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',v_u2,'authenticated','authenticated','zz-v424-c2-'||substr(v_u2::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',v_u3,'authenticated','authenticated','zz-v424-c3-'||substr(v_u3::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',v_u4,'authenticated','authenticated','zz-v424-c4-'||substr(v_u4::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.clients(id,business_id,full_name) values
    (v_c1,v_biz,'ZZ v424 month customer'),
    (v_c2,v_biz,'ZZ v424 recent-birthday customer'),
    (v_c3,v_biz,'ZZ v424 far-birthday customer'),
    (v_c4,v_biz,'ZZ v424 other-month customer');
  insert into public.customer_identities(id,auth_user_id,status,created_via) values
    (v_i1,v_u1,'active','phone_registration'),
    (v_i2,v_u2,'active','phone_registration'),
    (v_i3,v_u3,'active','phone_registration'),
    (v_i4,v_u4,'active','phone_registration');
  perform set_config('app.c42_profile_identity',v_i1::text,true);
  insert into public.customer_profiles(identity_id,auth_user_id,full_name,birth_date)
  values (v_i1,v_u1,'ZZ v424 month customer',v_birth_month);
  perform set_config('app.c42_profile_identity',v_i2::text,true);
  insert into public.customer_profiles(identity_id,auth_user_id,full_name,birth_date)
  values (v_i2,v_u2,'ZZ v424 recent-birthday customer',v_birth_recent);
  perform set_config('app.c42_profile_identity',v_i3::text,true);
  insert into public.customer_profiles(identity_id,auth_user_id,full_name,birth_date)
  values (v_i3,v_u3,'ZZ v424 far-birthday customer',v_birth_far);
  perform set_config('app.c42_profile_identity',v_i4::text,true);
  insert into public.customer_profiles(identity_id,auth_user_id,full_name,birth_date)
  values (v_i4,v_u4,'ZZ v424 other-month customer',v_birth_other);
  perform set_config('app.c42_profile_identity','',true);
  perform set_config('app.customer_link_insert_id',v_l1::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_l1,v_biz,v_i1,v_u1,v_c1,'verified','phone_claim',now());
  perform set_config('app.customer_link_insert_id',v_l2::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_l2,v_biz,v_i2,v_u2,v_c2,'verified','phone_claim',now());
  perform set_config('app.customer_link_insert_id',v_l3::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_l3,v_biz,v_i3,v_u3,v_c3,'verified','phone_claim',now());
  perform set_config('app.customer_link_insert_id',v_l4::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_l4,v_biz,v_i4,v_u4,v_c4,'verified','phone_claim',now());
  perform set_config('app.customer_link_insert_id','',true);

  -- ==========================================================================================
  -- E. ONE TRANSACTION SAVES AND PUBLISHES
  -- ==========================================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner,'role','authenticated')::text,true);
  set local role authenticated;

  v_saved := public.business_save_birthday_program_v424(v_biz, jsonb_build_object(
    'program_id',v_prog,'active',true,
    'customer_label','Birthday treat','customer_description','A free slice during your birthday month.',
    'customer_terms','One per customer per year.','fulfillment_kind','free_item',
    'manual_item','Free slice','window_mode','month','window_days_before',0,'window_days_after',0,
    'sort',0), 'v424-month-'||substr(v_biz::text,1,8));
  if v_saved->>'status' <> 'published' or (v_saved->>'replayed')::boolean then
    raise exception 'v424 E1: the atomic save did not publish: %', v_saved;
  end if;
  reset role;
  if not exists (
    select 1 from public.birthday_program_versions bpv
     join public.businesses b on b.id=bpv.business_id and b.active_config_version_id=bpv.config_version_id
    where bpv.business_id=v_biz and bpv.active and bpv.window_mode='month') then
    raise exception 'v424 E2: the published configuration is not the month-mode programme';
  end if;
  if (select active_config_version_id from public.businesses where id=v_biz)
       is distinct from (v_saved->>'version_id')::uuid then
    raise exception 'v424 E3: the firm is not live on the version the save returned';
  end if;
  set local role authenticated;

  -- The same key twice returns the stored receipt instead of publishing a second version.
  v_replay := public.business_save_birthday_program_v424(v_biz, jsonb_build_object(
    'program_id',v_prog,'active',true,
    'customer_label','Birthday treat','customer_description','A free slice during your birthday month.',
    'customer_terms','One per customer per year.','fulfillment_kind','free_item',
    'manual_item','Free slice','window_mode','month','window_days_before',0,'window_days_after',0,
    'sort',0), 'v424-month-'||substr(v_biz::text,1,8));
  if not (v_replay->>'replayed')::boolean
     or v_replay->>'version_id' is distinct from v_saved->>'version_id' then
    raise exception 'v424 E4: a repeated idempotency key did not replay: %', v_replay;
  end if;

  -- A DIFFERENT edit under a key already used is refused rather than silently discarding one.
  begin
    perform public.business_save_birthday_program_v424(v_biz, jsonb_build_object(
      'program_id',v_prog,'active',true,
      'customer_label','Something else','customer_description','A free slice during your birthday month.',
      'customer_terms','One per customer per year.','fulfillment_kind','free_item',
      'manual_item','Free slice','window_mode','month','window_days_before',0,'window_days_after',0,
      'sort',0), 'v424-month-'||substr(v_biz::text,1,8));
    raise exception 'v424 E5: a changed edit reused an idempotency key and was accepted';
  exception when serialization_failure then null;
  end;

  -- A key outside the whitelist is refused before anything is published.
  begin
    perform public.business_save_birthday_program_v424(v_biz, jsonb_build_object(
      'program_id',v_prog,'active',true,'customer_label','x','customer_description','y',
      'customer_terms','z','fulfillment_kind','free_item','manual_item','Free slice',
      'window_mode','month','sort',0,'window_days_before',0,'window_days_after',0,
      'surprise_column','boom'), 'v424-bad-'||substr(v_biz::text,1,8));
    raise exception 'v424 E6: an unsupported payload field was accepted';
  exception when invalid_parameter_value then null;
  end;
  reset role;

  -- A non-owner cannot publish a birthday programme through the new door.
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_u1,'role','authenticated')::text,true);
  set local role authenticated;
  begin
    perform public.business_save_birthday_program_v424(v_biz, jsonb_build_object(
      'program_id',v_prog,'active',true,'customer_label','x','customer_description','y',
      'customer_terms','z','fulfillment_kind','free_item','manual_item','Free slice',
      'window_mode','month','window_days_before',0,'window_days_after',0,'sort',0),
      'v424-intruder-'||substr(v_biz::text,1,8));
    raise exception 'v424 E7: a customer published a birthday programme';
  exception when insufficient_privilege then null;
  end;
  reset role;

  -- ==========================================================================================
  -- B + C. MONTH MODE: THE PROMISE AND THE ENFORCEMENT ARE THE SAME WINDOW
  -- ==========================================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_u1,'role','authenticated')::text,true);
  set local role authenticated;
  perform public.customer_set_birthday_participation(true, gen_random_uuid());

  v_benefit := public.customer_get_birthday_benefit(v_slug);
  if v_benefit->>'status' <> 'ready_to_activate' then
    raise exception 'v424 B1: the card did not offer the benefit mid-month: %', v_benefit;
  end if;
  if (v_benefit#>>'{validity,available_from}')::timestamptz is distinct from v_month_from
     or (v_benefit#>>'{validity,available_until}')::timestamptz is distinct from v_month_until then
    raise exception 'v424 B2: the promised window is not the whole SG month: %', v_benefit;
  end if;

  -- THE P0. Today is not this customer's birthday; before v424 this raised 42501.
  v_activated := public.customer_activate_birthday_benefit(v_slug, gen_random_uuid());
  if v_activated->>'status' <> 'available' then
    raise exception 'v424 B3: month-mode activation did not produce an available benefit: %', v_activated;
  end if;
  reset role;

  select * into v_ent from public.customer_birthday_entitlements
   where business_id=v_biz and client_id=v_c1 order by activated_at desc limit 1;
  if v_ent.id is null then
    raise exception 'v424 B4: no entitlement was written';
  end if;
  if v_ent.valid_from is distinct from v_month_from
     or v_ent.valid_until is distinct from v_month_until then
    raise exception 'v424 B5: the entitlement spans % .. %, expected the whole SG month % .. %',
      v_ent.valid_from, v_ent.valid_until, v_month_from, v_month_until;
  end if;
  if v_ent.valid_until - v_ent.valid_from < interval '27 days' then
    raise exception 'v424 B6: the entitlement collapsed to % — the 4-argument overload is still in the activation path',
      v_ent.valid_until - v_ent.valid_from;
  end if;
  -- C: the window the customer was promised is the window that was written.
  if (v_benefit#>>'{validity,available_from}')::timestamptz is distinct from v_ent.valid_from
     or (v_benefit#>>'{validity,available_until}')::timestamptz is distinct from v_ent.valid_until then
    raise exception 'v424 C1: promise % .. % is not enforcement % .. %',
      v_benefit#>>'{validity,available_from}', v_benefit#>>'{validity,available_until}',
      v_ent.valid_from, v_ent.valid_until;
  end if;

  -- A birthday in another month is still refused: month mode widens the window, it does not
  -- remove it.
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_u4,'role','authenticated')::text,true);
  set local role authenticated;
  perform public.customer_set_birthday_participation(true, gen_random_uuid());
  begin
    perform public.customer_activate_birthday_benefit(v_slug, gen_random_uuid());
    raise exception 'v424 B7: a customer outside their birthday month activated the benefit';
  exception when insufficient_privilege then null;
  end;
  reset role;

  -- ==========================================================================================
  -- D. DAY-WINDOW MODE STILL HONOURS ITS DAYS
  -- ==========================================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner,'role','authenticated')::text,true);
  set local role authenticated;
  perform public.business_save_birthday_program_v424(v_biz, jsonb_build_object(
    'program_id',v_prog,'active',true,
    'customer_label','Birthday treat','customer_description','A free slice around your birthday.',
    'customer_terms','One per customer per year.','fulfillment_kind','free_item',
    'manual_item','Free slice','window_mode','days','window_days_before',3,'window_days_after',3,
    'sort',0), 'v424-days-'||substr(v_biz::text,1,8));
  reset role;

  -- Two days after the birthday, inside a 3/3 window: accepted.
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_u2,'role','authenticated')::text,true);
  set local role authenticated;
  perform public.customer_set_birthday_participation(true, gen_random_uuid());
  v_activated := public.customer_activate_birthday_benefit(v_slug, gen_random_uuid());
  if v_activated->>'status' <> 'available' then
    raise exception 'v424 D1: a birthday 2 days ago was refused inside a 3/3 window: %', v_activated;
  end if;
  reset role;
  select * into v_ent from public.customer_birthday_entitlements
   where business_id=v_biz and client_id=v_c2 order by activated_at desc limit 1;
  if v_ent.valid_until - v_ent.valid_from <> interval '7 days' then
    raise exception 'v424 D2: a 3/3 window produced a % span', v_ent.valid_until - v_ent.valid_from;
  end if;
  if v_ent.valid_from is distinct from
       ((app.c45_observed_birthday(v_birth_recent, v_ent.birthday_year) - 3)::timestamp at time zone 'Asia/Singapore') then
    raise exception 'v424 D3: the 3-day head of the window is wrong: %', v_ent.valid_from;
  end if;

  -- Five days after the birthday, outside the same window: refused.
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_u3,'role','authenticated')::text,true);
  set local role authenticated;
  perform public.customer_set_birthday_participation(true, gen_random_uuid());
  begin
    perform public.customer_activate_birthday_benefit(v_slug, gen_random_uuid());
    raise exception 'v424 D4: a birthday 5 days ago was accepted by a 3/3 window';
  exception when insufficient_privilege then null;
  end;
  reset role;

  raise notice 'v424 acceptance: all checks passed (SG today %, month % .. %)',
    v_sg_today, v_month_from, v_month_until;
end
$v424$;

rollback;
