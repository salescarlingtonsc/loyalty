-- Rollback-only acceptance for Nestly v94 platform control and intelligence.
-- Run after the canonical chain through v94 in a disposable database.
begin;

create or replace function pg_temp.as_v94_user(
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
grant execute on function pg_temp.as_v94_user(uuid,text) to public;

do $v94_test$
declare
  v_super uuid:=gen_random_uuid();
  v_owner uuid:=gen_random_uuid();
  v_manager uuid:=gen_random_uuid();
  v_frontdesk_user uuid:=gen_random_uuid();
  v_admin uuid:=gen_random_uuid();
  v_consultant_user uuid:=gen_random_uuid();
  v_consultant_two_user uuid:=gen_random_uuid();
  v_outsider uuid:=gen_random_uuid();
  v_business uuid;
  v_branch_one uuid;
  v_branch_two uuid;
  v_staff uuid;
  v_frontdesk_staff uuid;
  v_client uuid;
  v_service uuid;
  v_product uuid;
  v_sale uuid:=gen_random_uuid();
  v_scope_sale uuid:=gen_random_uuid();
  v_consultant uuid;
  v_consultant_two uuid;
  v_appointment_one uuid:=gen_random_uuid();
  v_appointment_two uuid:=gen_random_uuid();
  v_company uuid;
  v_prospect uuid;
  v_result jsonb;
  v_checkout_lines jsonb;
  v_state text;
  v_count integer;
  v_points_count integer;
  v_credit_count integer;
  v_redemption_count integer;
  v_sqlstate text;
  v_loop integer;
  v_loop_client uuid;
  v_loop_sale uuid;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) select
    '00000000-0000-0000-0000-000000000000',user_id,
    'authenticated','authenticated',email,'',now(),now(),now()
  from (values
    (v_super,'v94-super@example.test'),
    (v_owner,'v94-owner@example.test'),
    (v_manager,'v94-manager@example.test'),
    (v_frontdesk_user,'v94-frontdesk@example.test'),
    (v_admin,'v94-admin@example.test'),
    (v_consultant_user,'v94-consultant@example.test'),
    (v_consultant_two_user,'v94-consultant-two@example.test'),
    (v_outsider,'v94-outsider@example.test')
  ) fixture(user_id,email);
  insert into public.super_admins(user_id,email,note)
  values(v_super,'v94-super@example.test','rollback-only v94 fixture');
  insert into public.platform_consultants(
    user_id,display_name,tier,employment_started_on,created_by
  ) values(
    v_consultant_user,'Nestly Test Consultant','senior',
    current_date-interval '2 years',v_super
  ) returning id into v_consultant;
  insert into public.platform_consultants(
    user_id,display_name,tier,employment_started_on,created_by
  ) values(
    v_consultant_two_user,'Nestly Reassigned Consultant','junior',
    current_date-interval '1 year',v_super
  ) returning id into v_consultant_two;
  insert into public.platform_access_grants_v89(
    user_id,role,module_perms,created_by,updated_by
  ) values(v_admin,'admin','{"*":"r"}',v_super,v_super);

  insert into public.businesses(
    name,slug,industry,enabled_modules
  ) values(
    'V94 Platform Control',
    'v94-control-'||substr(v_owner::text,1,8),
    'test',array['dashboard','clients','sales','till','services','reports',
      'inventory','appointments','bookings','loyalty']
  ) returning id into v_business;
  insert into public.staff(
    business_id,user_id,role,full_name,active
  ) values(v_business,v_owner,'owner','V94 Owner',true)
  returning id into v_staff;
  insert into public.staff(
    business_id,user_id,role,full_name,active
  ) values(v_business,v_manager,'manager','V94 Manager',true);
  insert into public.branches(business_id,name,is_default)
  values(v_business,'Primary',true) returning id into v_branch_one;
  insert into public.branches(business_id,name)
  values(v_business,'Second') returning id into v_branch_two;
  insert into public.staff(
    business_id,user_id,role,full_name,active,module_perms
  ) values(
    v_business,v_frontdesk_user,'frontdesk','V94 Front Desk',true,
    '{"sales":"rw","till":"rw","reports":"r"}'::jsonb
  ) returning id into v_frontdesk_staff;
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values(v_business,v_frontdesk_staff,v_branch_two);
  insert into public.clients(business_id,full_name,phone)
  values(v_business,'V94 Customer','+6581234567') returning id into v_client;
  insert into public.services(business_id,name,price_cents,duration_min)
  values(v_business,'V94 Service',5000,60) returning id into v_service;
  insert into public.products(
    business_id,name,sku,retail_price_cents,active
  ) values(v_business,'V94 Product','V94-SKU',2500,true)
  returning id into v_product;
  v_checkout_lines:=jsonb_build_array(jsonb_build_object(
    'catalog_kind','service','catalog_id',v_service,'qty',1
  ));

  -- Every post-v94 firm starts pending and is retained in persona discovery.
  perform pg_temp.as_v94_user(v_owner);
  if app.is_salon_member(v_business) then
    raise exception 'pending owner received workspace access';
  end if;
  v_result:=public.get_my_personas();
  if jsonb_array_length(v_result->'staff')<>1
     or v_result#>>'{staff,0,approval_status}'<>'pending'
     or (v_result#>>'{staff,0,workspace_access}')::boolean then
    raise exception 'blocked owner persona was lost or misrepresented: %',v_result;
  end if;
  reset role;
  perform pg_temp.as_v94_user(v_manager);
  v_result:=public.platform_get_business_control_v94(v_business);
  if v_result#>>'{approval,status}'<>'pending'
     or (v_result->>'workspace_access')::boolean then
    raise exception 'active non-owner staff could not preflight blocked workspace: %',
      v_result;
  end if;
  reset role;

  perform pg_temp.as_v94_user(v_super);
  v_result:=public.platform_decide_business_approval_v94(
    v_business,'approved','fixture approval',1
  );
  if v_result->>'approval_status'<>'approved'
     or not (v_result->>'workspace_access')::boolean then
    raise exception 'approval did not open workspace: %',v_result;
  end if;
  begin
    perform public.platform_decide_business_approval_v94(
      v_business,'rejected','stale write must fail',1
    );
    raise exception 'stale approval version unexpectedly succeeded';
  exception when sqlstate '40001' then null;
  end;

  -- Firm mode is inherited, branch mode wins, and Inventory is unconditionally
  -- disabled even when the legacy sector bundle contains it.
  perform public.platform_set_module_override_v94(
    v_business,null,'sales','rw','firm operational sales',null
  );
  perform public.platform_set_module_override_v94(
    v_business,v_branch_one,'till','disabled','branch till disabled',null
  );
  perform public.platform_set_module_override_v94(
    v_business,null,'inventory','rw','attempted inventory enable',null
  );
  perform public.platform_set_module_override_v94(
    v_business,null,'customerintel','rw','attempted tenant intelligence enable',
    null
  );
  perform public.platform_set_module_override_v94(
    v_business,v_branch_one,'appointments','disabled',
    'branch appointments disabled',null
  );
  perform public.platform_set_module_override_v94(
    v_business,v_branch_one,'bookings','disabled',
    'branch bookings disabled',null
  );
  perform public.platform_set_module_override_v94(
    v_business,v_branch_one,'loyalty','disabled',
    'branch loyalty disabled',null
  );
  perform public.platform_set_module_override_v94(
    v_business,v_branch_one,'reports','disabled',
    'branch reports disabled',null
  );
  v_result:=public.platform_get_effective_modules_v94(
    v_business,v_branch_one
  );
  if not exists(
    select 1 from jsonb_array_elements(v_result->'modules') module_row
    where module_row->>'module_key'='till'
      and module_row->>'mode'='disabled'
      and module_row->>'source'='branch_override'
      and (module_row->>'version')::bigint=1
  ) or not exists(
    select 1 from jsonb_array_elements(v_result->'modules') module_row
    where module_row->>'module_key'='inventory'
      and module_row->>'mode'='disabled'
      and module_row->>'source'='global_inventory_policy'
  ) or not exists(
    select 1 from jsonb_array_elements(v_result->'modules') module_row
    where module_row->>'module_key'='customerintel'
      and module_row->>'mode'='disabled'
      and module_row->>'source'='global_platform_only_policy'
  ) then
    raise exception 'effective module precedence is wrong: %',v_result;
  end if;
  reset role;

  perform pg_temp.as_v94_user(v_owner);
  if not app.can_module_write_at_v94(v_business,v_branch_two,'sales')
     or not app.can_module_read_at_v94(v_business,v_branch_two,'sales')
     or not app.can_module_read_at_v94(v_business,v_branch_one,'sales')
     or app.can_module_read_at_v94(v_business,v_branch_one,'till')
     or app.can_module_read_at_v94(v_business,null,'inventory') then
    raise exception 'tenant module modes were not enforced';
  end if;
  -- Checkout can read the active product catalogue through Sales despite the
  -- Inventory destination and every Inventory write being unavailable.
  select count(*) into v_count from public.products
  where id=v_product;
  if v_count<>1 then
    raise exception 'sales catalogue product was hidden by inventory shutdown';
  end if;
  v_result:=public.business_get_checkout_catalogue_v94(
    v_business,v_branch_two,false
  );
  if not (v_result->>'enabled')::boolean
     or jsonb_array_length(v_result->'branches')<>2
     or jsonb_array_length(v_result->'items')<>2 then
    raise exception 'checkout catalogue contract is incomplete: %',v_result;
  end if;
  reset role;
  perform pg_temp.as_v94_user(v_frontdesk_user);
  begin
    perform public.business_get_checkout_catalogue_v94(
      v_business,v_branch_one,false
    );
    raise exception 'branch-limited staff read an unassigned catalogue';
  exception when sqlstate '42501' then null;
  end;
  v_result:=public.business_get_checkout_catalogue_v94(
    v_business,v_branch_two,false
  );
  if jsonb_array_length(v_result->'branches')<>1
     or v_result#>>'{branches,0,id}'<>v_branch_two::text then
    raise exception 'catalogue disclosed an unassigned branch: %',v_result;
  end if;
  reset role;
  perform pg_temp.as_v94_user(v_owner);
  v_result:=public.business_set_checkout_catalogue_item_v94(
    v_business,'product',v_product,false,0
  );
  if (v_result->>'checkout_active')::boolean
     or (v_result->>'version')::integer<>1 then
    raise exception 'catalogue item override failed: %',v_result;
  end if;
  v_result:=public.business_get_checkout_catalogue_v94(
    v_business,v_branch_two,false
  );
  if jsonb_array_length(v_result->'items')<>1 then
    raise exception 'inactive checkout item leaked into effective catalogue: %',
      v_result;
  end if;
  v_result:=public.business_set_checkout_catalogue_enabled_v94(
    v_business,false,1
  );
  if (v_result->>'enabled')::boolean then
    raise exception 'owner checkout catalogue toggle failed: %',v_result;
  end if;
  perform public.business_set_checkout_catalogue_enabled_v94(
    v_business,true,2
  );
  perform public.business_set_checkout_catalogue_item_v94(
    v_business,'product',v_product,true,1
  );

  -- Actual operational seams reject the disabled branch before reaching
  -- business validation, while the same user can transact on another branch.
  begin
    perform public.record_quick_sale(
      v_business,1000,'cash',v_client,v_staff,v_branch_one,
      null,'v94-denied-quick-sale',true
    );
    raise exception 'disabled branch accepted quick sale';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform public.evaluate_checkout(
      v_business,v_branch_one,v_client,v_checkout_lines,gen_random_uuid()
    );
    raise exception 'disabled branch accepted checkout evaluation';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform public.record_sale_by_phone(
      v_business,'+6581234567',1000,'quick_sale',null,v_staff,
      'v94-denied-phone',v_branch_one,'cash'
    );
    raise exception 'disabled branch accepted phone sale';
  exception when sqlstate '42501' then null;
  end;
  select count(*) into v_count
  from public.sales
  where business_id=v_business and branch_id=v_branch_one;
  if v_count<>0 then
    raise exception 'Till-disabled branch persisted a sale';
  end if;
  select count(*) into v_count
  from public.checkout_evaluations
  where business_id=v_business and branch_id=v_branch_one;
  if v_count<>0 then
    raise exception 'Till-disabled branch persisted a checkout evaluation';
  end if;
  v_result:=public.record_quick_sale(
    v_business,1000,'cash',v_client,v_staff,v_branch_two,
    null,'v94-allowed-quick-sale',true
  );
  if v_result#>>'{sale,id}' is null then
    raise exception 'enabled branch rejected quick sale: %',v_result;
  end if;
  select count(*) into v_count from public.sales
  where business_id=v_business and branch_id=v_branch_two;
  if v_count<>1 then
    raise exception 'enabled-branch sale was not visible through RLS';
  end if;
  reset role;

  insert into public.appointments(
    id,business_id,client_id,staff_id,starts_at,ends_at,status,total_cents,
    branch_id
  ) values
    (v_appointment_one,v_business,v_client,v_staff,now()+interval '2 days',
      now()+interval '2 days 1 hour','booked',5000,v_branch_one),
    (v_appointment_two,v_business,v_client,v_staff,now()+interval '3 days',
      now()+interval '3 days 1 hour','booked',5000,v_branch_two);
  perform pg_temp.as_v94_user(v_owner);
  begin
    perform public.set_appointment_status_v47(
      v_business,v_appointment_one,'cancelled'
    );
    raise exception 'disabled branch accepted appointment mutation';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform public.book_appointment_smart_v47(
      v_business,v_client,v_branch_one,v_service,now()+interval '4 days',
      60,v_staff,'manual',null,'v94-denied-book'
    );
    raise exception 'disabled branch accepted appointment creation';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform public.suggest_appointment_staff_v47(
      v_business,v_branch_one,v_service,now()+interval '4 days',60,5
    );
    raise exception 'disabled branch accepted appointment suggestion';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform public.reschedule_appointment_v48(
      v_business,v_appointment_one,now()+interval '5 days',60,v_staff,
      null,gen_random_uuid()
    );
    raise exception 'disabled branch accepted appointment reschedule';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform public.staff_decide_booking_request_v73(
      v_business,gen_random_uuid(),'decline',v_branch_one
    );
    raise exception 'disabled branch accepted booking action';
  exception when sqlstate '42501' then null;
  end;
  -- The protected loyalty kernels remain byte-owned by their sanctioned
  -- migrations. v94 enforces branch disablement at their immutable economic
  -- row boundaries rather than shadowing those functions.
  if not exists(
    select 1 from pg_trigger
    where tgrelid='public.loyalty_redemptions'::regclass
      and tgname='trg_loyalty_redemptions_branch_module_v94'
      and tgenabled<>'D'
  ) or not exists(
    select 1 from pg_trigger
    where tgrelid='public.customer_birthday_redemptions'::regclass
      and tgname='trg_customer_birthday_redemptions_branch_module_v94'
      and tgenabled<>'D'
  ) or not exists(
    select 1 from pg_trigger
    where tgrelid='public.customer_redemption_intents_v89'::regclass
      and tgname='trg_redemption_completion_branch_module_v94'
      and tgenabled<>'D'
  ) then
    raise exception 'loyalty branch-boundary enforcement is incomplete';
  end if;
  reset role;
  select count(*) into v_points_count
  from public.points_ledger
  where business_id=v_business and client_id=v_client;
  select count(*) into v_credit_count
  from public.credit_ledger
  where business_id=v_business and client_id=v_client;
  select count(*) into v_redemption_count
  from public.loyalty_redemptions
  where business_id=v_business and client_id=v_client;
  if has_function_privilege(
       'authenticated',
       'public.redeem_points(uuid,uuid,text)',
       'execute'
     )
     or has_function_privilege(
       'authenticated',
       'public.redeem_reward(uuid,uuid,uuid,text)',
       'execute'
     )
     or has_function_privilege(
       'authenticated',
       'public.redeem_reward_at_context(uuid,uuid,uuid,text,uuid,uuid,uuid)',
       'execute'
     ) then
    raise exception 'authenticated retained a direct redemption writer';
  end if;
  perform pg_temp.as_v94_user(v_owner);
  begin
    perform public.redeem_points(
      v_business,v_client,'v94-direct-redeem-points'
    );
    raise exception 'direct classic redemption remained executable';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.redeem_reward(
      v_business,v_client,gen_random_uuid(),'v94-direct-reward'
    );
    raise exception 'direct reward redemption remained executable';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.redeem_reward_at_context(
      v_business,v_client,gen_random_uuid(),'v94-direct-context',
      v_branch_two,null,null
    );
    raise exception 'direct contextual redemption remained executable';
  exception when insufficient_privilege then null;
  end;
  reset role;
  if (select count(*) from public.points_ledger
      where business_id=v_business and client_id=v_client)<>v_points_count
     or (select count(*) from public.credit_ledger
      where business_id=v_business and client_id=v_client)<>v_credit_count
     or (select count(*) from public.loyalty_redemptions
      where business_id=v_business and client_id=v_client)<>v_redemption_count then
    raise exception 'denied direct redemption mutated value or history';
  end if;
  perform pg_temp.as_v94_user(v_owner);
  v_result:=public.set_appointment_status_v47(
    v_business,v_appointment_two,'cancelled'
  );
  if v_result->>'status'<>'cancelled' then
    raise exception 'enabled branch rejected appointment mutation: %',v_result;
  end if;
  select count(*) into v_count from public.appointments
  where business_id=v_business;
  if v_count<>1 or exists(
    select 1 from public.appointments where id=v_appointment_one
  ) then
    raise exception 'appointment RLS did not hide the disabled branch';
  end if;
  begin
    perform public.get_reports_summary(
      v_business,current_date-1,current_date,v_branch_one
    );
    raise exception 'disabled branch accepted report read';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform public.get_reports_summary(
      v_business,current_date-1,current_date,null
    );
    raise exception 'consolidated report included a disabled visible branch';
  exception when sqlstate '42501' then null;
  end;
  perform public.get_reports_summary(
    v_business,current_date-1,current_date,v_branch_two
  );
  reset role;
  perform pg_temp.as_v94_user(v_super);
  perform public.platform_set_module_override_v94(
    v_business,v_branch_one,'reports','rw',
    'enable reports to isolate branch visibility test',1
  );
  reset role;
  insert into public.sales(
    id,business_id,client_id,kind,amount_cents,occurred_at,
    counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,
    branch_id,staff_id,commission_rate_bps,commission_resolved_at,idem_key
  ) values(
    v_scope_sale,v_business,v_client,'quick_sale',100,now(),
    true,true,false,now(),v_branch_one,v_staff,0,now(),'v94-scope-sale'
  );
  perform pg_temp.as_v94_user(v_frontdesk_user);
  begin
    perform public.get_reports_summary(
      v_business,current_date-1,current_date,v_branch_one
    );
    raise exception 'branch-limited staff read an unassigned branch report';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform public.get_reports_summary(
      v_business,current_date-1,current_date,null
    );
    raise exception 'consolidated report disclosed an unassigned branch';
  exception when sqlstate '42501' then null;
  end;
  perform public.get_reports_summary(
    v_business,current_date-1,current_date,v_branch_two
  );
  reset role;

  -- Assignment and hotline power both scoped reporting and payment assistance.
  insert into public.sme_companies(trading_name,industry)
  values('V94 SME','test') returning id into v_company;
  insert into public.sme_prospects(
    company_id,current_stage_key,assigned_consultant_id,
    converted_business_id,converted_at,converted_by,created_by
  ) values(
    v_company,'client',v_consultant,v_business,now(),v_super,v_super
  ) returning id into v_prospect;
  insert into public.consultant_commission_attributions(
    consultant_id,prospect_id,business_id,onboarding_started_at,
    reason,attributed_by
  ) values(
    v_consultant,v_prospect,v_business,now()-interval '2 years',
    'rollback-only assignment',v_super
  );
  perform pg_temp.as_v94_user(v_super);
  perform public.platform_set_consultant_hotline_v94(
    v_consultant,'+6561234567',null
  );
  reset role;

  -- Seed one valid mixed basket without invoking unrelated loyalty/stock
  -- workflows; the test transaction restores trigger state on rollback.
  alter table public.sales disable trigger user;
  insert into public.sales(
    id,business_id,client_id,kind,amount_cents,occurred_at,
    counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,
    branch_id,staff_id,commission_rate_bps,commission_resolved_at,idem_key
  ) values(
    v_sale,v_business,v_client,'quick_sale',7500,now(),
    true,true,false,now(),v_branch_one,v_staff,0,now(),'v94-sale'
  );
  alter table public.sales enable trigger user;
  insert into public.sale_items(
    sale_id,business_id,item_type,ref_id,description,qty,
    unit_cents,line_cents,product_id,staff_id
  ) values
    (v_sale,v_business,'service',v_service,'V94 Service',1,5000,5000,null,v_staff),
    (v_sale,v_business,'retail',v_product,'V94 Product',1,2500,2500,v_product,v_staff);

  perform pg_temp.as_v94_user(v_consultant_user);
  v_result:=public.platform_get_assigned_firm_report_v94(
    v_business,null,current_date-1,current_date
  );
  if (v_result#>>'{kpis,net_revenue_cents}')::integer<>8600
     or (v_result#>>'{kpis,active_customers}')::integer<>1
     or (v_result#>>'{cohorts,counts,loyal}')::integer<>1
     or jsonb_array_length(v_result#>'{preferences,services}')<>1
     or jsonb_array_length(v_result#>'{preferences,products}')<>1 then
    raise exception 'assigned consultant report is inconsistent: %',v_result;
  end if;
  v_result:=public.platform_get_catalogue_affinity_v94(
    v_business,null,current_date-1,current_date,10
  );
  if (v_result#>>'{readiness,ready}')::boolean
     or jsonb_array_length(v_result->'pairs')<>0
     or not ((v_result#>'{readiness,suppression_reasons}')
       ?'minimum_20_transactions_required') then
    raise exception 'small-sample affinity was not suppressed: %',v_result;
  end if;
  v_result:=public.platform_get_consultative_recommendations_v94(
    v_business,null,current_date-1,current_date,10
  );
  if jsonb_array_length(v_result->'recommendations')<>0 then
    raise exception 'small-sample recommendations were not suppressed: %',
      v_result;
  end if;
  reset role;

  -- Wildcard-aware admin reads work, and consultant authority follows the
  -- current prospect assignment rather than immutable commission attribution.
  perform pg_temp.as_v94_user(v_admin);
  perform public.platform_get_assigned_firm_report_v94(
    v_business,null,current_date-1,current_date
  );
  reset role;
  perform pg_temp.as_v94_user(v_super);
  perform public.platform_set_consultant_hotline_v94(
    v_consultant_two,'+6561234568',null
  );
  reset role;
  alter table public.sme_prospects disable trigger user;
  update public.sme_prospects
  set assigned_consultant_id=v_consultant_two
  where id=v_prospect;
  alter table public.sme_prospects enable trigger user;
  perform pg_temp.as_v94_user(v_consultant_user);
  begin
    perform public.platform_get_assigned_firm_report_v94(
      v_business,null,current_date-1,current_date
    );
    raise exception 'former consultant retained report after reassignment';
  exception when sqlstate '42501' then null;
  end;
  reset role;
  perform pg_temp.as_v94_user(v_consultant_two_user);
  perform public.platform_get_assigned_firm_report_v94(
    v_business,null,current_date-1,current_date
  );
  reset role;

  -- A qualifying four-week sample crosses every readiness threshold. The
  -- emitted recommendation carries finite support, sample and confidence.
  alter table public.sales disable trigger user;
  for v_loop in 1..20 loop
    insert into public.clients(business_id,full_name,phone)
    values(
      v_business,'V94 Ready Customer '||v_loop,
      '+659'||lpad(v_loop::text,7,'0')
    ) returning id into v_loop_client;
    v_loop_sale:=gen_random_uuid();
    insert into public.sales(
      id,business_id,client_id,kind,amount_cents,occurred_at,
      counts_as_revenue,counts_as_visit,earns_points,policy_resolved_at,
      branch_id,staff_id,commission_rate_bps,commission_resolved_at,idem_key
    ) values(
      v_loop_sale,v_business,v_loop_client,'quick_sale',7500,
      now()-make_interval(days=>((v_loop-1)%4)*7),
      true,true,false,now(),v_branch_two,v_staff,0,now(),
      'v94-ready-'||v_loop
    );
    insert into public.sale_items(
      sale_id,business_id,item_type,ref_id,description,qty,
      unit_cents,line_cents,product_id,staff_id
    ) values
      (v_loop_sale,v_business,'service',v_service,'V94 Service',
        1,5000,5000,null,v_staff),
      (v_loop_sale,v_business,'retail',v_product,'V94 Product',
        1,2500,2500,v_product,v_staff);
  end loop;
  alter table public.sales enable trigger user;
  perform pg_temp.as_v94_user(v_consultant_two_user);
  v_result:=public.platform_get_catalogue_affinity_v94(
    v_business,null,current_date-30,current_date,10
  );
  if not (v_result#>>'{readiness,ready}')::boolean
     or (v_result#>>'{summary,pair_count}')::integer<>1
     or (v_result#>>'{pairs,0,support_orders}')::integer<3
     or (v_result#>>'{pairs,0,confidence_pct}')::numeric<10 then
    raise exception 'qualifying affinity evidence is wrong: %',v_result;
  end if;
  v_result:=public.platform_get_consultative_recommendations_v94(
    v_business,null,current_date-30,current_date,10
  );
  if jsonb_array_length(v_result->'recommendations')<>1
     or v_result#>>'{recommendations,0,evidence,support_orders}' is null
     or v_result#>>'{recommendations,0,evidence,sample_orders}' is null
     or v_result#>>'{recommendations,0,evidence,confidence_pct}' is null then
    raise exception 'ready recommendation lacks finite evidence: %',v_result;
  end if;
  reset role;

  perform pg_temp.as_v94_user(v_owner);
  begin
    perform public.get_customer_intelligence_v83(
      v_business,null,current_date-1,current_date,25,null,null,null
    );
    raise exception 'tenant owner retained legacy v83 customer intelligence';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.platform_get_assigned_firm_report_v94(
      v_business,null,current_date-1,current_date
    );
    raise exception 'tenant owner received platform customer intelligence';
  exception when sqlstate '42501' then null;
  end;
  reset role;
  perform pg_temp.as_v94_user(v_outsider);
  begin
    perform public.platform_get_assigned_firm_report_v94(
      v_business,null,current_date-1,current_date
    );
    raise exception 'unassigned user received platform report';
  exception when sqlstate '42501' then null;
  end;
  reset role;

  -- Daily runs emit one current notice; a catch-up jumps to the current
  -- actionable day without flooding historic notices, and replay is idempotent.
  insert into public.billing_provider_invoices(
    business_id,provider_customer_id,provider_invoice_id,currency,status,
    paid_normalized,subtotal_ex_tax_cents,tax_cents,total_cents,
    amount_due_cents,amount_paid_cents,amount_remaining_cents,
    due_at,livemode,provider_event_created_at,provider_event_rank,last_event_id
  ) values(
    v_business,'cus_v94','in_v94','SGD','open',false,
    10000,900,10900,10900,0,10900,
    '2026-07-01 00:00:00+08',false,
    '2026-07-01 00:00:00+00',10,'evt_v94_due'
  );
  perform pg_temp.as_v94_user(v_super);
  v_result:=public.run_subscription_lifecycle_v94('2026-07-01');
  if (v_result->>'notices_created')::integer<>1 then
    raise exception 'day-0 lifecycle notice is wrong: %',v_result;
  end if;
  v_result:=public.run_subscription_lifecycle_v94('2026-07-02');
  if (v_result->>'notices_created')::integer<>1 then
    raise exception 'normal daily lifecycle notice is wrong: %',v_result;
  end if;
  v_result:=public.run_subscription_lifecycle_v94('2026-07-15');
  if (v_result->>'paused')::integer<>1
     or (v_result->>'notices_created')::integer<>1 then
    raise exception 'day-14 lifecycle output is wrong: %',v_result;
  end if;
  v_result:=public.run_subscription_lifecycle_v94('2026-07-15');
  if not (v_result->>'replayed')::boolean then
    raise exception 'lifecycle rerun was not idempotent: %',v_result;
  end if;
  reset role;
  select state into v_state
  from public.business_subscription_lifecycle_v94
  where business_id=v_business;
  select count(*) into v_count
  from public.business_billing_due_notices_v94
  where business_id=v_business and hotline_phone='+6561234568';
  if v_state<>'paused' or v_count<>3 then
    raise exception 'pause or assigned-hotline notices were not persisted';
  end if;
  select count(*) into v_count from public.notifications
  where business_id=v_business and kind='subscription_payment_due'
    and ref_table='business_billing_due_notices_v94';
  if v_count<>3 then
    raise exception 'daily billing notices did not reach the in-app notification surface';
  end if;
  perform pg_temp.as_v94_user(v_owner);
  if app.is_salon_member(v_business) then
    raise exception 'paused owner retained workspace access';
  end if;
  reset role;

  -- A durable provider-paid event updates billing truth and reopens the
  -- workspace immediately. Replaying the same event remains idempotent.
  perform pg_temp.as_v94_user(null,'service_role');
  perform public.ingest_stripe_billing_event_v77(
    'evt_v94_invoice_paid','invoice.paid','in_v94',
    '2026-07-29 01:00:00+00',false,
    jsonb_build_object(
      'id','evt_v94_invoice_paid','type','invoice.paid','livemode',false,
      'data',jsonb_build_object('object',jsonb_build_object(
        'id','in_v94','customer','cus_v94','currency','sgd','status','paid',
        'collection_method','charge_automatically',
        'metadata',jsonb_build_object('business_id',v_business),
        'total_excluding_tax',10000,'tax',900,'total',10900,
        'amount_due',10900,'amount_paid',10900,'amount_remaining',0,
        'status_transitions',jsonb_build_object('paid_at',1784077200)
      ))
    ),repeat('9',64)
  );
  v_result:=public.apply_stripe_billing_event_v77('evt_v94_invoice_paid');
  if coalesce(v_result#>>'{subscription_lifecycle,outcome}','')<>'recovered' then
    raise exception 'provider-paid event did not recover workspace: %',v_result;
  end if;
  v_result:=public.apply_stripe_billing_event_v77('evt_v94_invoice_paid');
  if not coalesce(
    (v_result#>>'{subscription_lifecycle,replayed}')::boolean,false
  ) then raise exception 'provider-paid recovery replay was not idempotent: %',
    v_result;end if;
  reset role;

  perform pg_temp.as_v94_user(v_super);
  v_result:=public.platform_set_catalogue_intelligence_v94(
    v_business,false,'platform feature paused',1
  );
  if (v_result->>'catalogue_intelligence_enabled')::boolean
     or not (select quick_earn_catalogue_enabled from public.businesses
         where id=v_business) then
    raise exception 'platform intelligence incorrectly changed checkout';
  end if;
  reset role;

  if not exists(
    select 1 from public.business_workspace_control_audit_v94
    where business_id=v_business and event_type='firm_approved'
      and prior_status='pending' and new_status='approved'
  ) or not exists(
    select 1 from public.business_subscription_lifecycle_audit_v94
    where business_id=v_business and event_type='workspace_paused'
  ) or not exists(
    select 1 from public.business_subscription_lifecycle_audit_v94
    where business_id=v_business and event_type='payment_recovered'
  ) then
    raise exception 'required approval/subscription audit evidence is missing';
  end if;
end
$v94_test$;

rollback;
