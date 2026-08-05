-- Rollback-only acceptance for Nestly v105 task-first platform administration.
-- Run after the canonical chain through v105 in a disposable database.
begin;

create or replace function pg_temp.as_v105_user(
  p_uid uuid,p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,true
  );
end
$$;
grant execute on function pg_temp.as_v105_user(uuid,text) to public;

do $v105_test$
declare
  v_super uuid:=gen_random_uuid();
  v_outsider uuid:=gen_random_uuid();
  v_sales uuid:=gen_random_uuid();
  v_owner uuid:=gen_random_uuid();
  v_business uuid;
  v_other_business uuid;
  v_company uuid:=gen_random_uuid();
  v_other_company uuid:=gen_random_uuid();
  v_prospect uuid:=gen_random_uuid();
  v_other_prospect uuid:=gen_random_uuid();
  v_consultant uuid:=gen_random_uuid();
  v_other_consultant uuid:=gen_random_uuid();
  v_branch uuid;
  v_other_branch uuid;
  v_application uuid:=gen_random_uuid();
  v_attempt uuid:=gen_random_uuid();
  v_result jsonb;
  v_page_one jsonb;
  v_page_two_before jsonb;
  v_page_two_after jsonb;
  v_snapshot timestamptz;
  v_cursor_updated_at timestamptz;
  v_cursor_id uuid;
  v_count integer;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
    created_at,updated_at
  ) values
  ('00000000-0000-0000-0000-000000000000',v_super,
    'authenticated','authenticated','v105-super@example.test','',now(),now(),now()),
  ('00000000-0000-0000-0000-000000000000',v_outsider,
    'authenticated','authenticated','v105-outsider@example.test','',now(),now(),now()),
  ('00000000-0000-0000-0000-000000000000',v_sales,
    'authenticated','authenticated','v105-sales@example.test','',now(),now(),now()),
  ('00000000-0000-0000-0000-000000000000',v_owner,
    'authenticated','authenticated','v105-owner@example.test','',now(),now(),now());
  insert into public.super_admins(user_id,email,note)
  values(v_super,'v105-super@example.test','rollback-only v105 fixture');
  insert into public.platform_consultants(
    id,user_id,display_name,tier,employment_started_on,created_by
  ) values
    (v_consultant,v_sales,'V105 Sales','senior',current_date-500,v_super),
    (v_other_consultant,v_outsider,'V105 Other Sales','junior',
      current_date-100,v_super);
  insert into public.platform_access_grants_v89(
    user_id,role,module_perms,created_by,updated_by
  ) values(
    v_sales,'sales_staff',
    '{"onboarding":"rw","firms":"r","reports":"r"}',
    v_super,v_super
  );

  insert into public.businesses(name,slug,industry,enabled_modules)
  values(
    'V105 Task Closure','v105-task-'||substr(v_super::text,1,8),'test',
    array['dashboard','clients','sales','reports']
  ) returning id into v_business;
  insert into public.businesses(name,slug,industry,enabled_modules)
  values(
    'V105 Other Firm','v105-other-'||substr(v_outsider::text,1,8),'test',
    array['dashboard']
  ) returning id into v_other_business;
  insert into public.branches(business_id,name,is_default)
  values(v_business,'V105 Primary',true) returning id into v_branch;
  insert into public.branches(business_id,name,is_default)
  values(v_other_business,'V105 Other',true) returning id into v_other_branch;
  update public.businesses set created_at=clock_timestamp()-interval '3 days'
  where id=v_business;
  update public.businesses set created_at=clock_timestamp()-interval '1 day'
  where id=v_other_business;

  insert into public.sme_companies(
    id,legal_name,trading_name,registration_number,industry,email,phone,
    created_at,updated_at
  ) values
    (v_company,'V105 Task Closure Pte Ltd','V105 Task Closure',
      'V105-UEN-A','test','v105-a@example.test','81110001',
      clock_timestamp()-interval '2 days',
      clock_timestamp()-interval '2 days'),
    (v_other_company,'V105 Other Firm Pte Ltd','V105 Other Firm',
      'V105-UEN-B','test','v105-b@example.test','81110002',
      clock_timestamp()-interval '1 day',
      clock_timestamp()-interval '1 day');
  insert into public.sme_prospects(
    id,company_id,current_stage_key,assigned_consultant_id,next_action_at,
    stage_entered_at,created_at,updated_at
  ) values
    (v_prospect,v_company,'new_lead',v_consultant,
      clock_timestamp()+interval '2 days',clock_timestamp()-interval '2 days',
      clock_timestamp()-interval '2 days',clock_timestamp()-interval '2 days'),
    (v_other_prospect,v_other_company,'new_lead',v_consultant,
      clock_timestamp()+interval '2 days',clock_timestamp()-interval '1 day',
      clock_timestamp()-interval '1 day',clock_timestamp()-interval '1 day');
  insert into public.sme_prospect_contacts(
    prospect_id,full_name,email,phone,is_primary
  ) values
    (v_prospect,'V105 Boss A','v105-boss-a@example.test','82220001',true),
    (v_other_prospect,'V105 Boss B','v105-boss-b@example.test','82220002',true);
  update public.businesses set source_prospect_id=v_prospect
  where id=v_business;
  update public.businesses set source_prospect_id=v_other_prospect
  where id=v_other_business;
  update public.sme_prospects set
    converted_business_id=case id
      when v_prospect then v_business else v_other_business end,
    converted_at=clock_timestamp()-interval '12 hours',
    converted_by=v_super
  where id in(v_prospect,v_other_prospect);
  insert into public.subscriptions(business_id,status,currency)
  values(v_business,'active','SGD'),(v_other_business,'active','SGD')
  on conflict(business_id) do update set status='active',currency='SGD';

  -- Browser writers remain super-admin only.
  perform pg_temp.as_v105_user(v_outsider);
  begin
    perform public.platform_set_module_overrides_v105(
      v_business,null,
      '[{"module":"reports","mode":"disabled","expected_version":null}]',
      'outsider must fail'
    );
    raise exception 'non-superadmin changed firm modules';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform public.platform_decide_business_application_v105(
      v_application,'approved','outsider must fail',1,v_attempt
    );
    raise exception 'non-superadmin decided an application';
  exception when sqlstate '42501' then null;
  end;
  reset role;

  perform pg_temp.as_v105_user(v_super);
  begin
    perform public.platform_get_effective_modules_v105(
      v_business,v_other_branch
    );
    raise exception 'cross-firm branch was accepted';
  exception when sqlstate '22023' then null;
  end;

  -- One request updates the exact firm scope atomically.
  v_result:=public.platform_set_module_overrides_v105(
    v_business,null,
    jsonb_build_array(
      jsonb_build_object(
        'module','reports','mode','disabled','expected_version',null
      ),
      jsonb_build_object(
        'module','sales','mode','r','expected_version',null
      )
    ),
    'v105 exact-scope batch'
  );
  if (v_result->>'updated_count')::integer<>2 then
    raise exception 'batch writer did not update both modules: %',v_result;
  end if;
  v_result:=public.platform_get_effective_modules_v105(v_business,null);
  if not exists(
    select 1 from jsonb_array_elements(v_result->'modules') item
    where item->>'module_key'='reports'
      and item->>'override_mode'='disabled'
      and (item->>'override_version')::bigint=1
  ) or not exists(
    select 1 from jsonb_array_elements(v_result->'modules') item
    where item->>'module_key'='sales'
      and item->>'override_mode'='r'
      and (item->>'override_version')::bigint=1
  ) then
    raise exception 'exact-scope projection is incomplete: %',v_result;
  end if;

  -- A stale member aborts the whole batch; the valid member must not change.
  begin
    perform public.platform_set_module_overrides_v105(
      v_business,null,
      jsonb_build_array(
        jsonb_build_object(
          'module','reports','mode','rw','expected_version',1
        ),
        jsonb_build_object(
          'module','sales','mode','rw','expected_version',99
        )
      ),
      'stale batch must be atomic'
    );
    raise exception 'stale batch unexpectedly succeeded';
  exception when sqlstate '40001' then null;
  end;
  reset role;
  if exists(
    select 1 from public.platform_module_overrides_v94
    where business_id=v_business and branch_scope is null
      and (
        (module_key='reports' and (mode<>'disabled' or version<>1))
        or (module_key='sales' and (mode<>'r' or version<>1))
      )
  ) then
    raise exception 'stale batch partially changed a module';
  end if;
  perform pg_temp.as_v105_user(v_super);

  v_result:=public.platform_set_module_overrides_v105(
    v_business,null,
    '[{"module":"reports","mode":"inherit","expected_version":1}]',
    'reset reports to sector default'
  );
  v_result:=public.platform_get_effective_modules_v105(v_business,null);
  if not exists(
    select 1 from jsonb_array_elements(v_result->'modules') item
    where item->>'module_key'='reports'
      and item->>'override_mode'='inherit'
      and (item->>'override_version')::bigint=2
  ) then
    raise exception 'inherit reset was not projected exactly: %',v_result;
  end if;

  -- The delegated directory freezes role scope, membership, order, search
  -- projection and payload bytes for the complete cursor walk.
  perform pg_temp.as_v105_user(v_sales);
  v_page_one:=public.platform_list_my_firms_v105('V105',1,null,null,null);
  if v_page_one->>'snapshot_at' is null
     or v_page_one->>'snapshot_expires_at' is null
     or v_page_one->>'scope'<>'own_created_or_assigned'
     or jsonb_typeof(v_page_one->'items')<>'array'
     or (v_page_one->>'total_count')::integer<>2
     or v_page_one->'next_cursor' is null then
    raise exception 'fixed-snapshot firm directory contract is incomplete: %',
      v_page_one;
  end if;
  v_snapshot:=(v_page_one->>'snapshot_at')::timestamptz;
  v_cursor_updated_at:=(v_page_one#>>'{next_cursor,updated_at}')::timestamptz;
  v_cursor_id:=(v_page_one#>>'{next_cursor,id}')::uuid;
  v_page_two_before:=public.platform_list_my_firms_v105(
    'V105',1,v_snapshot,v_cursor_updated_at,v_cursor_id
  );
  if v_page_two_before#>>'{items,0,prospect_id}'<>v_prospect::text then
    raise exception 'deterministic second-page fixture was not selected: %',
      v_page_two_before;
  end if;

  reset role;
  perform set_config('app.v79_system_transition','on',true);
  update public.sme_prospects set
    assigned_consultant_id=v_other_consultant,
    current_stage_key='pending_decision',
    next_action_at=clock_timestamp()-interval '1 day',
    updated_at=clock_timestamp()
  where id=v_prospect;
  update public.sme_prospect_contacts set
    full_name='V105 Mutated Boss',email='mutated-v105@example.test',
    phone='89999999',updated_at=clock_timestamp()
  where prospect_id=v_prospect and is_primary;
  update public.subscriptions set status='past_due'
  where business_id=v_business;
  update public.businesses set name='V105 Mutated Firm'
  where id=v_business;
  perform set_config('app.v79_system_transition','off',true);

  perform pg_temp.as_v105_user(v_sales);
  v_page_two_after:=public.platform_list_my_firms_v105(
    'V105',1,v_snapshot,v_cursor_updated_at,v_cursor_id
  );
  if v_page_two_after->'items' is distinct from v_page_two_before->'items'
     or v_page_two_after->'next_cursor'
        is distinct from v_page_two_before->'next_cursor'
     or v_page_two_after->'total_count'
        is distinct from v_page_two_before->'total_count' then
    raise exception
      'snapshot page changed after reassignment/CRM/billing/contact mutations: before %, after %',
      v_page_two_before,v_page_two_after;
  end if;
  if v_page_two_after#>>'{items,0,boss_name}'='V105 Mutated Boss'
     or v_page_two_after#>>'{items,0,subscription_status}'='past_due'
     or v_page_two_after#>>'{items,0,assigned_consultant_id}'
        =v_other_consultant::text then
    raise exception 'mutable content leaked into frozen page two: %',
      v_page_two_after;
  end if;
  reset role;
  perform pg_temp.as_v105_user(v_super);

  -- Exact decision replays return the direct activation without duplicating
  -- workspace, staff, branch, subscription, decision, or audit evidence.
  reset role;
  insert into public.business_applications_v95(
    id,idempotency_key,request_hash,contact_name,contact_email,contact_phone,
    business_name,sector_key,preferred_locale
  ) values(
    v_application,gen_random_uuid(),repeat('a',64),'V105 Owner',
    'v105-owner@example.test','+6581234567','V105 Applied Firm','test','en'
  );
  perform pg_temp.as_v105_user(v_super);
  v_result:=public.platform_decide_business_application_v105(
    v_application,'approved','approve v105 fixture',1,v_attempt
  );
  if (v_result->>'workspace_created')::boolean is not true
     or (v_result->>'replayed')::boolean
     or v_result->>'status'<>'consumed' then
    raise exception 'first direct approval activation failed: %',v_result;
  end if;
  v_result:=public.platform_decide_business_application_v105(
    v_application,'approved','approve v105 fixture',1,v_attempt
  );
  if (v_result->>'workspace_created')::boolean is not true
     or not (v_result->>'replayed')::boolean
     or (v_result->>'response_version')::integer<>1 then
    raise exception 'exact replay did not return existing activation: %',v_result;
  end if;
  reset role;
  select count(*) into v_count
  from public.business_application_audit_v95
  where application_id=v_application and event_type='approved';
  if v_count<>1 then
    raise exception 'retry duplicated the application decision audit';
  end if;
  select count(*) into v_count
  from public.staff
  where user_id=v_owner and role='owner';
  if v_count<>1 then
    raise exception 'retry did not retain exactly one owner staff row';
  end if;
  select count(*) into v_count
  from public.business_application_invitations_v95
  where application_id=v_application
    and revoked_at is null and consumed_at is null;
  if v_count<>0 then
    raise exception 'direct approval retained an active invitation';
  end if;
  perform pg_temp.as_v105_user(v_super);
  begin
    perform public.platform_decide_business_application_v105(
      v_application,'approved','changed retry payload',1,v_attempt
    );
    raise exception 'altered idempotency replay unexpectedly succeeded';
  exception when sqlstate '22023' then null;
  end;
  reset role;
end
$v105_test$;

rollback;
