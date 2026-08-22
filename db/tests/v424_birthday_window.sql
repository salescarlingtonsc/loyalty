-- Rollback-only acceptance for nestly_v424 — the birthday window a customer is promised is the
-- birthday window they get.
--   supabase db query --linked -f db/tests/v424_birthday_window.sql
-- Any row whose result starts with FAIL is a failure. Nothing is committed.
--
-- Check 07 is the P0 itself and fails on the pre-v424 definition:
-- public.customer_activate_birthday_benefit called the FOUR-argument app.c45_birthday_window and
-- never passed window_mode, so a month-mode programme — which is every live birthday programme in
-- production — was enforced as the single birthday date. A customer read "ready to activate" all
-- month and got 42501 on every day but one, and on that one day the entitlement written spanned a
-- day instead of the promised month.
--
-- Checks 01-06 pin the Asia/Singapore calendar contract at exact instants, including the boundary
-- where the UTC date and the SG date disagree and the Feb-29 rule. 07-10 prove month mode end to
-- end through the real RPCs and that the promise equals the enforcement. 11-13 prove day-window
-- mode still honours its days. 14-18 cover business_save_birthday_program_v424, the one-transaction
-- save that replaces the browser's create-draft / save / publish sequence.
--
-- Not time-travelled: customer_activate_birthday_benefit reads statement_timestamp(), so every
-- fixture birth date is derived from the CURRENT Singapore date and the exact-instant boundaries
-- are asserted against app.c45_birthday_window directly.

begin;

create temp table _r(k text, v text) on commit drop;
-- Several checks record their result while the session is still wearing the `authenticated`
-- role, which is the whole point of those checks.
grant select,insert,update,delete on _r to authenticated;

do $v424$
declare
  v_biz uuid := gen_random_uuid();
  v_slug text := 'zz-v424-'||substr(md5(random()::text),1,8);
  v_owner uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_seed uuid := gen_random_uuid();
  v_prog uuid := gen_random_uuid();
  v_key text := 'v424-month-'||substr(md5(random()::text),1,10);

  v_sg_today date; v_sg_dom integer; v_bday_dom integer;
  v_birth_month date; v_birth_recent date; v_birth_far date; v_birth_other date;
  v_month_from timestamptz; v_month_until timestamptz;

  v_saved jsonb; v_replay jsonb; v_benefit jsonb; v_activated jsonb;
  v_ent public.customer_birthday_entitlements%rowtype;
  v_year integer; v_from timestamptz; v_until timestamptz; v_rows integer;
  v_state text;

  v_c1 uuid; v_c2 uuid; v_c3 uuid; v_c4 uuid;
  v_i1 uuid; v_i2 uuid; v_i3 uuid; v_i4 uuid;
  v_u1 uuid; v_u2 uuid; v_u3 uuid; v_u4 uuid;
  v_l1 uuid; v_l2 uuid; v_l3 uuid; v_l4 uuid;
begin
  reset role;

  -- ---------------------------------------------------------------------------------------
  -- The Singapore calendar contract, at exact instants.
  -- ---------------------------------------------------------------------------------------
  select birthday_year, valid_from, valid_until into v_year, v_from, v_until
    from app.c45_birthday_window(date '1993-08-05',0,0,timestamptz '2026-08-22 12:00+08','month');
  insert into _r select '01 month mode is the whole SG month',
    case when v_year=2026 and v_from=timestamptz '2026-08-01 00:00+08'
              and v_until=timestamptz '2026-09-01 00:00+08'
      then 'PASS' else format('FAIL %s .. %s (year %s)',v_from,v_until,v_year) end;

  select count(*) into v_rows
    from app.c45_birthday_window(date '1993-08-05',0,0,timestamptz '2026-09-01 00:30+08','month');
  select count(*) into v_year
    from app.c45_birthday_window(date '1993-08-05',0,0,timestamptz '2026-08-31 23:30+08','month');
  insert into _r select '02 the month is half-open at SG midnight',
    case when v_rows=0 and v_year=1 then 'PASS'
      else format('FAIL 1 Sep 00:30 SGT matched %s rows, 31 Aug 23:30 SGT matched %s',v_rows,v_year) end;

  -- 2026-08-31 17:00Z is 2026-09-01 01:00 SGT; 2026-07-31 16:30Z is 2026-08-01 00:30 SGT.
  select count(*) into v_rows
    from app.c45_birthday_window(date '1993-08-05',0,0,timestamptz '2026-08-31 17:00+00','month');
  select valid_from into v_from
    from app.c45_birthday_window(date '1993-08-05',0,0,timestamptz '2026-07-31 16:30+00','month');
  insert into _r select '03 the window is SG, not UTC, across the date boundary',
    case when v_rows=0 and v_from=timestamptz '2026-08-01 00:00+08' then 'PASS'
      else format('FAIL after-boundary rows=%s, before-boundary from=%s',v_rows,v_from) end;

  select count(*) into v_rows
    from app.c45_birthday_window(date '1993-08-05',0,0,timestamptz '2026-08-22 12:00+08','days');
  insert into _r select '04 day mode with 0/0 is still one day',
    case when v_rows=0 then 'PASS' else 'FAIL day mode behaved like month mode' end;

  select valid_from, valid_until into v_from, v_until
    from app.c45_birthday_window(date '1993-08-20',3,3,timestamptz '2026-08-22 12:00+08','days');
  select count(*) into v_rows
    from app.c45_birthday_window(date '1993-08-20',3,3,timestamptz '2026-08-24 00:00+08','days');
  insert into _r select '05 a 3/3 day window honours both sides',
    case when v_from=timestamptz '2026-08-17 00:00+08' and v_until=timestamptz '2026-08-24 00:00+08'
              and v_rows=0
      then 'PASS' else format('FAIL %s .. %s, closing instant matched %s rows',v_from,v_until,v_rows) end;

  select valid_from, valid_until into v_from, v_until
    from app.c45_birthday_window(date '1992-02-29',0,0,timestamptz '2026-02-15 12:00+08','month');
  insert into _r select '06 a Feb-29 birthday resolves to Feb 28 in a non-leap year',
    case when app.c45_observed_birthday(date '1992-02-29',2026)=date '2026-02-28'
              and app.c45_observed_birthday(date '1992-02-29',2028)=date '2028-02-29'
              and v_from=timestamptz '2026-02-01 00:00+08'
              and v_until=timestamptz '2026-03-01 00:00+08'
      then 'PASS' else format('FAIL leap-day month %s .. %s',v_from,v_until) end;

  -- ---------------------------------------------------------------------------------------
  -- Fixture: one firm, one owner, a published loyalty configuration, four customers.
  -- ---------------------------------------------------------------------------------------
  v_sg_today := (timezone('Asia/Singapore', statement_timestamp()))::date;
  v_sg_dom := extract(day from v_sg_today)::integer;
  -- A day of the current SG month that is never today and exists in every month.
  v_bday_dom := case when v_sg_dom >= 15 then 1 else 28 end;
  v_birth_month := make_date(1993, extract(month from v_sg_today)::integer, v_bday_dom);
  v_birth_recent := make_date(1993, extract(month from (v_sg_today-2))::integer,
                                    extract(day from (v_sg_today-2))::integer);
  v_birth_far := make_date(1993, extract(month from (v_sg_today-5))::integer,
                                 extract(day from (v_sg_today-5))::integer);
  v_birth_other := make_date(1993, extract(month from (v_sg_today + interval '5 months'))::integer, 15);
  v_month_from := (date_trunc('month', v_sg_today::timestamp) at time zone 'Asia/Singapore');
  v_month_until := ((date_trunc('month', v_sg_today::timestamp) + interval '1 month') at time zone 'Asia/Singapore');

  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
    'zz-v424-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.businesses(id,name,slug,industry,is_synthetic,enabled_modules)
  values (v_biz,'ZZ v424 birthday fixture',v_slug,'test',true,array['dashboard','clients','sales','loyalty']);
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
  values (v_biz,false) on conflict (business_id) do update set workspace_paused=false;

  insert into public.firm_config_versions(id,business_id,version_no,status,source,snapshot_hash,created_by)
  values (v_seed,v_biz,1,'draft','manual',md5('v424-seed'),v_owner);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner,'role','authenticated')::text,true);
  insert into public.loyalty_program_versions(
    config_version_id,business_id,kind,loyalty_model,active,
    earn_points_per_dollar,redeem_points,reward_credit_cents,tier_basis,expiry_mode)
  values (v_seed,v_biz,'points','points_tiers',true,1,150,0,'points_earned','none');
  perform set_config('request.jwt.claims','{}',true);
  update public.firm_config_versions set status='published',published_at=clock_timestamp() where id=v_seed;
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,current_config_version_id)
  values (v_biz,'points',true,'points_tiers','published',v_seed);
  perform set_config('app.v79_system_transition','on',true);
  update public.businesses set active_config_version_id=v_seed where id=v_biz;
  perform set_config('app.v79_system_transition','',true);

  update app.platform_feature_flags set enabled=true, changed_at=statement_timestamp()
   where feature_key in ('customer_identity','customer_claims','customer_wallet','customer_birthday_benefits');

  v_u1:=gen_random_uuid(); v_i1:=gen_random_uuid(); v_c1:=gen_random_uuid(); v_l1:=gen_random_uuid();
  v_u2:=gen_random_uuid(); v_i2:=gen_random_uuid(); v_c2:=gen_random_uuid(); v_l2:=gen_random_uuid();
  v_u3:=gen_random_uuid(); v_i3:=gen_random_uuid(); v_c3:=gen_random_uuid(); v_l3:=gen_random_uuid();
  v_u4:=gen_random_uuid(); v_i4:=gen_random_uuid(); v_c4:=gen_random_uuid(); v_l4:=gen_random_uuid();
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_u1,'authenticated','authenticated','zz-v424-c1-'||substr(v_u1::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',v_u2,'authenticated','authenticated','zz-v424-c2-'||substr(v_u2::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',v_u3,'authenticated','authenticated','zz-v424-c3-'||substr(v_u3::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',v_u4,'authenticated','authenticated','zz-v424-c4-'||substr(v_u4::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.clients(id,business_id,full_name) values
    (v_c1,v_biz,'ZZ v424 month customer'),(v_c2,v_biz,'ZZ v424 recent customer'),
    (v_c3,v_biz,'ZZ v424 far customer'),(v_c4,v_biz,'ZZ v424 other-month customer');
  insert into public.customer_identities(id,auth_user_id,status,created_via) values
    (v_i1,v_u1,'active','phone_registration'),(v_i2,v_u2,'active','phone_registration'),
    (v_i3,v_u3,'active','phone_registration'),(v_i4,v_u4,'active','phone_registration');
  perform set_config('app.c42_profile_identity',v_i1::text,true);
  insert into public.customer_profiles(identity_id,auth_user_id,full_name,birth_date)
  values (v_i1,v_u1,'ZZ v424 month customer',v_birth_month);
  perform set_config('app.c42_profile_identity',v_i2::text,true);
  insert into public.customer_profiles(identity_id,auth_user_id,full_name,birth_date)
  values (v_i2,v_u2,'ZZ v424 recent customer',v_birth_recent);
  perform set_config('app.c42_profile_identity',v_i3::text,true);
  insert into public.customer_profiles(identity_id,auth_user_id,full_name,birth_date)
  values (v_i3,v_u3,'ZZ v424 far customer',v_birth_far);
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

  -- ---------------------------------------------------------------------------------------
  -- The one-transaction save publishes a month-mode programme.
  -- ---------------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner,'role','authenticated')::text,true);
  set local role authenticated;
  begin
    v_saved := public.business_save_birthday_program_v424(v_biz, jsonb_build_object(
      'program_id',v_prog,'active',true,'customer_label','Birthday treat',
      'customer_description','A free slice during your birthday month.',
      'customer_terms','One per customer per year.','fulfillment_kind','free_item',
      'manual_item','Free slice','window_mode','month','window_days_before',0,
      'window_days_after',0,'sort',0), v_key);
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate;
    v_saved := jsonb_build_object('status',v_state||' '||sqlerrm);
  end;
  reset role;
  insert into _r select '14 one call saves and publishes',
    case when v_saved->>'status'='published' and not coalesce((v_saved->>'replayed')::boolean,true)
      then 'PASS' else 'FAIL '||coalesce(v_saved::text,'null') end;
  insert into _r select '15 the firm is live on the version it returned',
    case when (select active_config_version_id from public.businesses where id=v_biz)
              = nullif(v_saved->>'version_id','')::uuid
      then 'PASS' else 'FAIL the published version is not the active one' end;

  set local role authenticated;
  begin
    v_replay := public.business_save_birthday_program_v424(v_biz, jsonb_build_object(
      'program_id',v_prog,'active',true,'customer_label','Birthday treat',
      'customer_description','A free slice during your birthday month.',
      'customer_terms','One per customer per year.','fulfillment_kind','free_item',
      'manual_item','Free slice','window_mode','month','window_days_before',0,
      'window_days_after',0,'sort',0), v_key);
  exception when others then v_replay := jsonb_build_object('status',sqlerrm);
  end;
  insert into _r select '16 the same key replays instead of publishing twice',
    case when coalesce((v_replay->>'replayed')::boolean,false)
              and v_replay->>'version_id' = v_saved->>'version_id'
      then 'PASS' else 'FAIL '||coalesce(v_replay::text,'null') end;

  v_state := 'no error';
  begin
    perform public.business_save_birthday_program_v424(v_biz, jsonb_build_object(
      'program_id',v_prog,'active',true,'customer_label','Something else',
      'customer_description','A free slice during your birthday month.',
      'customer_terms','One per customer per year.','fulfillment_kind','free_item',
      'manual_item','Free slice','window_mode','month','window_days_before',0,
      'window_days_after',0,'sort',0), v_key);
  exception when others then get stacked diagnostics v_state = returned_sqlstate;
  end;
  insert into _r select '17 a changed edit may not reuse a key',
    case when v_state='40001' then 'PASS' else 'FAIL got '||v_state end;
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub',v_u1,'role','authenticated')::text,true);
  set local role authenticated;
  v_state := 'no error';
  begin
    perform public.business_save_birthday_program_v424(v_biz, jsonb_build_object(
      'active',true,'customer_label','x','customer_description','y','customer_terms','z',
      'fulfillment_kind','free_item','manual_item','Free slice','window_mode','month',
      'window_days_before',0,'window_days_after',0,'sort',0),
      'v424-intruder-'||substr(md5(random()::text),1,10));
  exception when others then get stacked diagnostics v_state = returned_sqlstate;
  end;
  insert into _r select '18 a customer cannot publish a birthday programme',
    case when v_state='42501' then 'PASS' else 'FAIL got '||v_state end;

  -- ---------------------------------------------------------------------------------------
  -- Month mode, end to end: promise, enforcement, and the two agreeing.
  -- ---------------------------------------------------------------------------------------
  perform public.customer_set_birthday_participation(true, gen_random_uuid());
  v_benefit := public.customer_get_birthday_benefit(v_slug);
  insert into _r select '07a the card offers the benefit mid-month',
    case when v_benefit->>'status'='ready_to_activate' then 'PASS'
      else 'FAIL '||coalesce(v_benefit::text,'null') end;
  insert into _r select '07b the promise is the whole SG month',
    case when (v_benefit#>>'{validity,available_from}')::timestamptz = v_month_from
              and (v_benefit#>>'{validity,available_until}')::timestamptz = v_month_until
      then 'PASS' else format('FAIL promised %s .. %s, SG month is %s .. %s',
        v_benefit#>>'{validity,available_from}',v_benefit#>>'{validity,available_until}',
        v_month_from,v_month_until) end;

  -- THE P0. Today is not this customer's birthday. Before v424 this raised 42501.
  v_state := 'no error';
  begin
    v_activated := public.customer_activate_birthday_benefit(v_slug, gen_random_uuid());
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate;
    v_activated := null;
  end;
  insert into _r select '08 month-mode activation succeeds on a non-birthday day',
    case when v_activated->>'status'='available' then 'PASS'
      when v_state='42501' then 'FAIL 42501 — the activation path is still on the 4-argument overload'
      else 'FAIL '||v_state end;
  reset role;

  select * into v_ent from public.customer_birthday_entitlements
   where business_id=v_biz and client_id=v_c1 order by activated_at desc limit 1;
  insert into _r select '09 the entitlement written spans the whole SG month',
    case when v_ent.id is null then 'FAIL no entitlement was written'
      when v_ent.valid_from=v_month_from and v_ent.valid_until=v_month_until then 'PASS'
      else format('FAIL %s .. %s (a %s span)',v_ent.valid_from,v_ent.valid_until,
        v_ent.valid_until-v_ent.valid_from) end;
  insert into _r select '10 the promise and the enforcement are the same window',
    case when v_ent.id is not null
              and (v_benefit#>>'{validity,available_from}')::timestamptz = v_ent.valid_from
              and (v_benefit#>>'{validity,available_until}')::timestamptz = v_ent.valid_until
      then 'PASS' else 'FAIL the card and the entitlement disagree' end;

  perform set_config('request.jwt.claims',
    json_build_object('sub',v_u4,'role','authenticated')::text,true);
  set local role authenticated;
  perform public.customer_set_birthday_participation(true, gen_random_uuid());
  v_state := 'no error';
  begin
    perform public.customer_activate_birthday_benefit(v_slug, gen_random_uuid());
  exception when others then get stacked diagnostics v_state = returned_sqlstate;
  end;
  insert into _r select '11 a birthday in another month is still refused',
    case when v_state='42501' then 'PASS' else 'FAIL got '||v_state end;
  reset role;

  -- ---------------------------------------------------------------------------------------
  -- Day-window mode still honours its days.
  -- ---------------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner,'role','authenticated')::text,true);
  set local role authenticated;
  perform public.business_save_birthday_program_v424(v_biz, jsonb_build_object(
    'program_id',v_prog,'active',true,'customer_label','Birthday treat',
    'customer_description','A free slice around your birthday.',
    'customer_terms','One per customer per year.','fulfillment_kind','free_item',
    'manual_item','Free slice','window_mode','days','window_days_before',3,
    'window_days_after',3,'sort',0), 'v424-days-'||substr(md5(random()::text),1,10));
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub',v_u2,'role','authenticated')::text,true);
  set local role authenticated;
  perform public.customer_set_birthday_participation(true, gen_random_uuid());
  v_state := 'no error';
  begin
    v_activated := public.customer_activate_birthday_benefit(v_slug, gen_random_uuid());
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate; v_activated := null;
  end;
  reset role;
  select * into v_ent from public.customer_birthday_entitlements
   where business_id=v_biz and client_id=v_c2 order by activated_at desc limit 1;
  insert into _r select '12 a birthday 2 days ago is inside a 3/3 window',
    case when v_activated->>'status'='available'
              and v_ent.valid_until-v_ent.valid_from=interval '7 days'
              and v_ent.valid_from=((app.c45_observed_birthday(v_birth_recent,v_ent.birthday_year)-3)::timestamp
                                     at time zone 'Asia/Singapore')
      then 'PASS' else format('FAIL state=%s span=%s from=%s',v_state,
        v_ent.valid_until-v_ent.valid_from,v_ent.valid_from) end;

  perform set_config('request.jwt.claims',
    json_build_object('sub',v_u3,'role','authenticated')::text,true);
  set local role authenticated;
  perform public.customer_set_birthday_participation(true, gen_random_uuid());
  v_state := 'no error';
  begin
    perform public.customer_activate_birthday_benefit(v_slug, gen_random_uuid());
  exception when others then get stacked diagnostics v_state = returned_sqlstate;
  end;
  insert into _r select '13 a birthday 5 days ago is outside a 3/3 window',
    case when v_state='42501' then 'PASS' else 'FAIL got '||v_state end;
  reset role;
end
$v424$;

select k as check, v as result from _r order by k;

rollback;
