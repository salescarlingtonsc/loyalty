-- Rollback-only acceptance for OPSUX-004 appointment completion truth.
-- Run after the canonical chain through v121 in a disposable local database.
--
-- The synthetic SPA-GLOW fixture proves:
--   * Complete & checkout creates one appointment-linked sale and one earn row;
--   * a same-call retry replays without duplicating either economic record;
--   * all three customer-safe projections read the same persistent balance;
--   * a front-desk user cannot complete an appointment outside branch scope;
--   * disabling effective Loyalty prevents a new earn while preserving checkout.
--
-- This file intentionally asserts the desired disabled-Loyalty boundary. It
-- fails on the v120 predecessor and passes after the forward-only v121 fix.
begin;

create or replace function pg_temp.as_v120_completion_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,
    true
  );
end
$$;
grant execute on function pg_temp.as_v120_completion_user(uuid,text) to public;

do $v120_completion$
declare
  v_super uuid:=gen_random_uuid();
  v_owner uuid:=gen_random_uuid();
  v_frontdesk uuid:=gen_random_uuid();
  v_customer uuid:=gen_random_uuid();
  v_identity uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_orchard uuid:=gen_random_uuid();
  v_tampines uuid:=gen_random_uuid();
  v_client uuid:=gen_random_uuid();
  v_owner_staff uuid;
  v_frontdesk_staff uuid;
  v_service uuid:=gen_random_uuid();
  v_config uuid:=gen_random_uuid();
  v_enabled_appointment uuid:=gen_random_uuid();
  v_denied_appointment uuid:=gen_random_uuid();
  v_firm_disabled_appointment uuid:=gen_random_uuid();
  v_branch_disabled_appointment uuid:=gen_random_uuid();
  v_branch_readonly_appointment uuid:=gen_random_uuid();
  v_slug text;
  v_result jsonb;
  v_replay jsonb;
  v_wallet jsonb;
  v_summary jsonb;
  v_details jsonb;
  v_denied boolean;
  v_sale uuid;
  v_sales_before integer;
  v_points_before integer;
  v_disabled_points integer;
  v_override_version bigint;
begin
  if to_regprocedure(
       'public.set_appointment_status_v47(uuid,uuid,text)'
     ) is null
     or to_regprocedure('public.customer_get_wallet()') is null
     or to_regprocedure(
       'public.customer_get_business_summary(text)'
     ) is null
     or to_regprocedure(
       'public.customer_get_loyalty_details(text,jsonb)'
     ) is null then
    raise exception 'OPSUX-004 final-chain contracts are not installed';
  end if;

  insert into auth.users(
    instance_id,id,aud,role,email,phone,encrypted_password,
    email_confirmed_at,phone_confirmed_at,created_at,updated_at
  ) values
    (
      '00000000-0000-0000-0000-000000000000',v_super,
      'authenticated','authenticated','v120-completion-super@example.test',
      null,'',now(),null,now(),now()
    ),
    (
      '00000000-0000-0000-0000-000000000000',v_owner,
      'authenticated','authenticated','v120-completion-owner@example.test',
      null,'',now(),null,now(),now()
    ),
    (
      '00000000-0000-0000-0000-000000000000',v_frontdesk,
      'authenticated','authenticated','v120-completion-frontdesk@example.test',
      null,'',now(),null,now(),now()
    ),
    (
      '00000000-0000-0000-0000-000000000000',v_customer,
      'authenticated','authenticated','v120-completion-customer@example.test',
      '+6580004567','',now(),now(),now(),now()
    );

  insert into public.super_admins(user_id,email,note)
  values(
    v_super,'v120-completion-super@example.test',
    'rollback-only OPSUX-004 completion acceptance'
  );

  update app.platform_feature_flags
  set enabled=true
  where feature_key='customer_wallet';

  v_slug:='v120-spa-glow-'||substr(v_business::text,1,8);
  insert into public.businesses(
    id,name,slug,industry,currency,is_synthetic,enabled_modules
  ) values(
    v_business,'Glow Atelier',v_slug,'facial','SGD',true,
    array[
      'dashboard','branches','clients','services','appointments',
      'sales','loyalty'
    ]
  );
  insert into public.branches(
    id,business_id,name,timezone,is_default,active
  ) values
    (
      v_orchard,v_business,'Orchard','Asia/Singapore',true,true
    ),
    (
      v_tampines,v_business,'Tampines','Asia/Singapore',false,true
    );
  insert into public.staff(
    business_id,user_id,role,full_name,active
  ) values(
    v_business,v_owner,'owner','Olivia Tan',true
  ) returning id into v_owner_staff;
  insert into public.staff(
    business_id,user_id,role,full_name,active,modules,module_perms
  ) values(
    v_business,v_frontdesk,'frontdesk','Farah Noor',true,
    array['appointments','sales'],
    '{"appointments":"rw","sales":"rw"}'::jsonb
  ) returning id into v_frontdesk_staff;
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values
    (v_business,v_owner_staff,v_orchard),
    (v_business,v_owner_staff,v_tampines),
    (v_business,v_frontdesk_staff,v_orchard);
  insert into public.branch_hours(
    business_id,branch_id,weekday,opens_at,closes_at
  ) values
    (v_business,v_orchard,4,'09:00','19:00'),
    (v_business,v_tampines,4,'09:00','19:00');
  insert into public.staff_hours(
    business_id,staff_id,weekday,starts_at,ends_at
  ) values(
    v_business,v_owner_staff,4,'09:00','19:00'
  );

  insert into public.services(
    id,business_id,name,price_cents,duration_min,active,
    buffer_before_min,buffer_after_min
  ) values(
    v_service,v_business,'Spa ritual 60',6000,60,true,0,0
  );
  insert into public.staff_services(
    business_id,staff_id,service_id
  ) values(
    v_business,v_owner_staff,v_service
  );
  insert into public.clients(
    id,business_id,full_name,phone
  ) values(
    v_client,v_business,'Mei Lin','+6580004567'
  );

  perform pg_temp.as_v120_completion_user(v_super);
  v_result:=public.platform_decide_business_approval_v94(
    v_business,'approved','OPSUX-004 rollback fixture',1
  );
  reset role;
  if v_result->>'approval_status'<>'approved'
     or not (v_result->>'workspace_access')::boolean then
    raise exception 'SPA-GLOW workspace approval failed: %',v_result;
  end if;

  insert into public.customer_identities(
    id,auth_user_id,status,created_via
  ) values(
    v_identity,v_customer,'active','phone_registration'
  );
  perform set_config(
    'app.customer_link_insert_id',
    gen_random_uuid()::text,
    true
  );
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,
    verification_method,verified_at
  ) values(
    current_setting('app.customer_link_insert_id')::uuid,
    v_business,v_identity,v_customer,v_client,'verified',
    'firm_invitation',now()
  );
  perform set_config('app.customer_link_insert_id','',true);

  insert into public.firm_config_versions(
    id,business_id,version_no,status,source,snapshot_hash,created_by
  ) values(
    v_config,v_business,1,'draft','manual',
    md5('v120-spa-glow-classic-points'),v_owner
  );
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',v_owner,'role','authenticated')::text,
    true
  );
  insert into public.loyalty_program_versions(
    config_version_id,business_id,kind,loyalty_model,active,
    earn_points_per_dollar,redeem_points,reward_credit_cents,
    tier_basis,expiry_mode
  ) values(
    v_config,v_business,'points','classic',true,
    10,1000,1000,'points_earned','none'
  );
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  update public.firm_config_versions
  set status='published',published_at=now()
  where id=v_config;
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,
    current_config_version_id,earn_points_per_dollar,redeem_points,
    reward_credit_cents,tier_basis,expiry_mode
  ) values(
    v_business,'points',true,'classic','published',v_config,
    10,1000,1000,'points_earned','none'
  );
  perform set_config('app.v79_system_transition','on',true);
  update public.businesses
  set active_config_version_id=v_config
  where id=v_business;
  perform set_config('app.v79_system_transition','',true);

  -- Three booked SGD 60 appointments: enabled happy path, wrong-branch denial,
  -- and completion after effective Loyalty is disabled.
  insert into public.appointments(
    id,business_id,client_id,branch_id,service_id,staff_id,
    starts_at,ends_at,status,total_cents,note,created_at
  ) values
    (
      v_enabled_appointment,v_business,v_client,v_orchard,v_service,
      v_owner_staff,'2026-07-30 10:00+08','2026-07-30 11:00+08',
      'booked',6000,'OPSUX-004 enabled completion',
      '2026-07-30 09:00+08'
    ),
    (
      v_denied_appointment,v_business,v_client,v_tampines,v_service,
      v_owner_staff,'2026-07-30 12:00+08','2026-07-30 13:00+08',
      'booked',6000,'OPSUX-004 wrong-branch denial',
      '2026-07-30 09:00+08'
    ),
    (
      v_firm_disabled_appointment,v_business,v_client,v_orchard,v_service,
      v_owner_staff,'2026-07-30 14:00+08','2026-07-30 15:00+08',
      'booked',6000,'OPSUX-004 firm-disabled Loyalty completion',
      '2026-07-30 09:00+08'
    ),
    (
      v_branch_disabled_appointment,v_business,v_client,v_orchard,v_service,
      v_owner_staff,'2026-07-30 16:00+08','2026-07-30 17:00+08',
      'booked',6000,'OPSUX-004 branch-disabled Loyalty completion',
      '2026-07-30 09:00+08'
    ),
    (
      v_branch_readonly_appointment,v_business,v_client,v_orchard,v_service,
      v_owner_staff,'2026-07-30 17:00+08','2026-07-30 18:00+08',
      'booked',6000,'OPSUX-004 branch-read-only Loyalty completion',
      '2026-07-30 09:00+08'
    );

  -- Branch mismatch: Farah is assigned only to Orchard and cannot complete
  -- the otherwise valid Tampines appointment.
  select count(*) into v_sales_before
  from public.sales
  where business_id=v_business;
  select coalesce(sum(points),0)::integer into v_points_before
  from public.points_ledger
  where business_id=v_business and client_id=v_client;
  v_denied:=false;
  begin
    perform pg_temp.as_v120_completion_user(v_frontdesk);
    perform public.set_appointment_status_v47(
      v_business,v_denied_appointment,'completed'
    );
    reset role;
  exception when insufficient_privilege then
    reset role;
    v_denied:=true;
  end;
  if not v_denied
     or (select status from public.appointments
         where id=v_denied_appointment)<>'booked'
     or (select count(*) from public.sales
         where business_id=v_business)<>v_sales_before
     or (select coalesce(sum(points),0)::integer
         from public.points_ledger
         where business_id=v_business and client_id=v_client)
        <>v_points_before then
    raise exception 'wrong-branch completion mutated persistent state';
  end if;

  -- Enabled Loyalty: one completion produces exactly one sale and one 600
  -- point earn. Repeating the same completion must only replay.
  perform pg_temp.as_v120_completion_user(v_owner);
  v_result:=public.set_appointment_status_v47(
    v_business,v_enabled_appointment,'completed'
  );
  v_replay:=public.set_appointment_status_v47(
    v_business,v_enabled_appointment,'completed'
  );
  reset role;
  select sale.id into v_sale
  from public.sales sale
  where sale.business_id=v_business
    and sale.appointment_id=v_enabled_appointment;
  if coalesce((v_result->>'replayed')::boolean,true)
     or not coalesce((v_replay->>'replayed')::boolean,false)
     or (select status from public.appointments
         where id=v_enabled_appointment)<>'completed'
     or (select count(*) from public.sales
         where business_id=v_business
           and appointment_id=v_enabled_appointment)<>1
     or (select count(*) from public.points_ledger
         where business_id=v_business and sale_id=v_sale
           and entry_type='earn')<>1
     or (select coalesce(sum(points),0)::integer
         from public.points_ledger
         where business_id=v_business and sale_id=v_sale)<>600
     or (select amount_cents from public.sales where id=v_sale)<>6000
     or (select branch_id from public.sales where id=v_sale)<>v_orchard
     or (select staff_id from public.sales where id=v_sale)<>v_owner_staff
     or (select client_id from public.sales where id=v_sale)<>v_client then
    raise exception
      'enabled completion was not one authoritative sale/earn: % / %',
      v_result,v_replay;
  end if;

  -- A refreshed linked customer reads the same 600 persistent points through
  -- the wallet list, verified business summary, and bounded ledger history.
  perform pg_temp.as_v120_completion_user(v_customer);
  v_wallet:=public.customer_get_wallet();
  v_summary:=public.customer_get_business_summary(v_slug);
  v_details:=public.customer_get_loyalty_details(v_slug,'{"limit":20}'::jsonb);
  reset role;
  if jsonb_array_length(v_wallet)<>1
     or not coalesce(
       (v_wallet#>>'{0,loyalty,enabled}')::boolean,
       false
     )
     or (v_wallet#>>'{0,loyalty,balance}')::integer<>600
     or v_summary#>>'{business,id}'<>v_business::text
     or not coalesce(
       (v_summary#>>'{loyalty,enabled}')::boolean,
       false
     )
     or (v_summary#>>'{loyalty,balance}')::integer<>600
     or (v_details->>'balance')::integer<>600
     or jsonb_array_length(v_details->'items')<>1
     or v_details#>>'{items,0,event_type}'<>'earn'
     or (v_details#>>'{items,0,points_delta}')::integer<>600 then
    raise exception
      'customer-safe projections disagreed with the 600-point ledger: % / % / %',
      v_wallet,v_summary,v_details;
  end if;

  -- Effective Loyalty is now disabled firm-wide. Customer-safe projections
  -- must hide the balance/history, and a subsequent appointment checkout must
  -- preserve its sale but must not mint a new Loyalty earn.
  perform pg_temp.as_v120_completion_user(v_super);
  perform public.platform_set_module_overrides_v105(
    v_business,null,
    '[{"module":"loyalty","mode":"disabled","expected_version":null}]'::jsonb,
    'OPSUX-004 disabled Loyalty completion boundary'
  );
  reset role;

  perform pg_temp.as_v120_completion_user(v_customer);
  v_wallet:=public.customer_get_wallet();
  v_summary:=public.customer_get_business_summary(v_slug);
  v_denied:=false;
  begin
    perform public.customer_get_loyalty_details(
      v_slug,'{"limit":20}'::jsonb
    );
  exception when insufficient_privilege then
    v_denied:=true;
  end;
  reset role;
  if coalesce((v_wallet#>>'{0,loyalty,enabled}')::boolean,false)
     or (v_wallet#>>'{0,loyalty,balance}')::integer<>0
     or coalesce((v_summary#>>'{loyalty,enabled}')::boolean,false)
     or (v_summary#>>'{loyalty,balance}')::integer<>0
     or not v_denied then
    raise exception
      'disabled Loyalty remained customer-visible: % / %',
      v_wallet,v_summary;
  end if;

  perform pg_temp.as_v120_completion_user(v_owner);
  v_result:=public.set_appointment_status_v47(
    v_business,v_firm_disabled_appointment,'completed'
  );
  v_replay:=public.set_appointment_status_v47(
    v_business,v_firm_disabled_appointment,'completed'
  );
  reset role;
  select sale.id into v_sale
  from public.sales sale
  where sale.business_id=v_business
    and sale.appointment_id=v_firm_disabled_appointment;
  select coalesce(sum(points),0)::integer into v_disabled_points
  from public.points_ledger
  where business_id=v_business and sale_id=v_sale;
  if coalesce((v_result->>'replayed')::boolean,true)
     or not coalesce((v_replay->>'replayed')::boolean,false)
     or (select count(*) from public.sales
         where business_id=v_business
           and appointment_id=v_firm_disabled_appointment)<>1
     or v_disabled_points<>0 then
    raise exception
      'DEFECT OPSUX-004: firm-disabled Loyalty completion created % point(s); '
      'checkout result=% replay=%',
      v_disabled_points,v_result,v_replay;
  end if;

  -- Restore firm Loyalty, then prove exact-branch disabled and read-only modes
  -- also preserve checkout while suppressing only the new earn.
  select version into v_override_version
  from public.platform_module_overrides_v94
  where business_id=v_business
    and branch_scope is null
    and module_key='loyalty';
  perform pg_temp.as_v120_completion_user(v_super);
  perform public.platform_set_module_overrides_v105(
    v_business,null,
    jsonb_build_array(jsonb_build_object(
      'module','loyalty','mode','rw',
      'expected_version',v_override_version
    )),
    'OPSUX-004 restore firm Loyalty for branch boundaries'
  );
  perform public.platform_set_module_overrides_v105(
    v_business,v_orchard,
    '[{"module":"loyalty","mode":"disabled","expected_version":null}]'::jsonb,
    'OPSUX-004 branch-disabled Loyalty completion boundary'
  );
  reset role;

  perform pg_temp.as_v120_completion_user(v_owner);
  v_result:=public.set_appointment_status_v47(
    v_business,v_branch_disabled_appointment,'completed'
  );
  v_replay:=public.set_appointment_status_v47(
    v_business,v_branch_disabled_appointment,'completed'
  );
  reset role;
  select sale.id into v_sale
  from public.sales sale
  where sale.business_id=v_business
    and sale.appointment_id=v_branch_disabled_appointment;
  select coalesce(sum(points),0)::integer into v_disabled_points
  from public.points_ledger
  where business_id=v_business and sale_id=v_sale;
  if coalesce((v_result->>'replayed')::boolean,true)
     or not coalesce((v_replay->>'replayed')::boolean,false)
     or (select count(*) from public.sales
         where business_id=v_business
           and appointment_id=v_branch_disabled_appointment)<>1
     or v_disabled_points<>0 then
    raise exception
      'DEFECT OPSUX-004: branch-disabled Loyalty completion created % point(s)',
      v_disabled_points;
  end if;

  select version into v_override_version
  from public.platform_module_overrides_v94
  where business_id=v_business
    and branch_scope=v_orchard
    and module_key='loyalty';
  perform pg_temp.as_v120_completion_user(v_super);
  perform public.platform_set_module_overrides_v105(
    v_business,v_orchard,
    jsonb_build_array(jsonb_build_object(
      'module','loyalty','mode','r',
      'expected_version',v_override_version
    )),
    'OPSUX-004 branch-read-only Loyalty completion boundary'
  );
  reset role;

  perform pg_temp.as_v120_completion_user(v_owner);
  v_result:=public.set_appointment_status_v47(
    v_business,v_branch_readonly_appointment,'completed'
  );
  v_replay:=public.set_appointment_status_v47(
    v_business,v_branch_readonly_appointment,'completed'
  );
  reset role;
  select sale.id into v_sale
  from public.sales sale
  where sale.business_id=v_business
    and sale.appointment_id=v_branch_readonly_appointment;
  select coalesce(sum(points),0)::integer into v_disabled_points
  from public.points_ledger
  where business_id=v_business and sale_id=v_sale;
  if coalesce((v_result->>'replayed')::boolean,true)
     or not coalesce((v_replay->>'replayed')::boolean,false)
     or (select count(*) from public.sales
         where business_id=v_business
           and appointment_id=v_branch_readonly_appointment)<>1
     or v_disabled_points<>0 then
    raise exception
      'DEFECT OPSUX-004: branch-read-only Loyalty completion created % point(s)',
      v_disabled_points;
  end if;

  -- A readable effective branch still exposes the unchanged prior balance.
  perform pg_temp.as_v120_completion_user(v_customer);
  v_wallet:=public.customer_get_wallet();
  v_summary:=public.customer_get_business_summary(v_slug);
  v_details:=public.customer_get_loyalty_details(v_slug,'{"limit":20}'::jsonb);
  reset role;
  if (v_wallet#>>'{0,loyalty,balance}')::integer<>600
     or (v_summary#>>'{loyalty,balance}')::integer<>600
     or (v_details->>'balance')::integer<>600
     or jsonb_array_length(v_details->'items')<>1
     or (select count(*) from public.sales
         where business_id=v_business)<>4
     or (select count(*) from public.points_ledger
         where business_id=v_business and client_id=v_client
           and entry_type='earn')<>1 then
    raise exception
      'disabled/read-only completion changed the prior customer value: % / % / %',
      v_wallet,v_summary,v_details;
  end if;

  raise notice
    'V121 OPSUX-004 appointment completion customer projection: PASS';
end
$v120_completion$;

rollback;
