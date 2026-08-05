-- Rollback-only v177 regression evidence: the read-only "view as firm"
-- workspace mirror (authorization, branch scoping, section validation, audit
-- trail, privacy and paused-firm visibility).
-- Run after the canonical chain through v177 in a disposable database.
--
-- Prod-compatible by construction: every assertion is scoped to
-- fixture-specific businesses, branches and audit rows, so live traffic can
-- neither satisfy nor invalidate any assertion here.
begin;

create or replace function pg_temp.as_v177_user(
  p_uid uuid,p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_v177_user(uuid,text) to public;

-- Recursive contact-key detector. The mirror must never carry a key named
-- phone or email at ANY depth, in any section.
create or replace function pg_temp.v177_has_contact_key(p_payload jsonb)
returns boolean language plpgsql immutable as $$
declare
  v_key text;
  v_value jsonb;
  v_item jsonb;
begin
  if p_payload is null then return false; end if;
  if jsonb_typeof(p_payload)='object' then
    for v_key,v_value in select * from jsonb_each(p_payload) loop
      if v_key ~* '(phone|email|mobile|contact_number)' then return true; end if;
      if pg_temp.v177_has_contact_key(v_value) then return true; end if;
    end loop;
    return false;
  end if;
  if jsonb_typeof(p_payload)='array' then
    for v_item in select * from jsonb_array_elements(p_payload) loop
      if pg_temp.v177_has_contact_key(v_item) then return true; end if;
    end loop;
    return false;
  end if;
  return false;
end
$$;
grant execute on function pg_temp.v177_has_contact_key(jsonb) to public;

do $v177$
declare
  v_sa uuid:='17700000-0000-4000-8000-000000000001';
  v_outsider uuid:='17700000-0000-4000-8000-000000000002';
  v_consultant_user uuid:='17700000-0000-4000-8000-000000000003';
  v_consultant uuid;
  v_prospect uuid;
  v_live uuid:='17700000-0000-4000-8000-000000000010';
  v_paused uuid:='17700000-0000-4000-8000-000000000011';
  v_other uuid:='17700000-0000-4000-8000-000000000012';
  v_branch uuid;
  v_other_branch uuid;
  v_client uuid:='17700000-0000-4000-8000-000000000020';
  v_staff uuid:='17700000-0000-4000-8000-000000000021';
  v_service uuid:='17700000-0000-4000-8000-000000000022';
  v_result jsonb;
  v_audit_before bigint;
  v_audit_after bigint;
  v_consultant_linked boolean:=false;
  v_section text;
begin
  ----------------------------------------------------------------------------
  -- 0. Contract surface exists with the reviewed grants.
  ----------------------------------------------------------------------------
  if to_regprocedure('public.platform_workspace_mirror_v177(uuid,uuid,text)') is null then
    raise exception 'platform_workspace_mirror_v177 is missing';
  end if;
  if has_function_privilege('anon',
       'public.platform_workspace_mirror_v177(uuid,uuid,text)','EXECUTE') then
    raise exception 'the workspace mirror is callable by anon';
  end if;
  if not has_function_privilege('authenticated',
       'public.platform_workspace_mirror_v177(uuid,uuid,text)','EXECUTE') then
    raise exception 'the workspace mirror is not callable by authenticated';
  end if;

  ----------------------------------------------------------------------------
  -- Fixtures.
  ----------------------------------------------------------------------------
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
    created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_sa,'authenticated','authenticated',
     'v177-sa@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_outsider,'authenticated','authenticated',
     'v177-outsider@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_consultant_user,'authenticated','authenticated',
     'v177-consultant@example.test','',now(),now(),now());
  insert into public.super_admins(user_id,email,note)
  values(v_sa,'v177-sa@example.test','v177 rollback fixture');

  insert into public.businesses(id,name,slug,industry,created_at,updated_at)
  values
    (v_live,'V177 Live Firm','v177-live-firm','fnb',now()-interval '400 days',now()),
    (v_paused,'V177 Paused Firm','v177-paused-firm','fnb',now()-interval '400 days',now()),
    (v_other,'V177 Other Firm','v177-other-firm','retail',now()-interval '400 days',now());

  insert into public.business_workspace_controls_v94(
    business_id,approval_status,decided_by,decided_at,decision_reason
  ) values
    (v_live,'approved',v_sa,now(),'v177 fixture approval'),
    (v_paused,'approved',v_sa,now(),'v177 fixture approval'),
    (v_other,'approved',v_sa,now(),'v177 fixture approval')
  on conflict(business_id) do update
    set approval_status='approved',decided_by=v_sa,decided_at=now(),
        decision_reason='v177 fixture approval';

  -- v11a auto-creates a default branch per business; fall back if absent.
  select id into v_branch from public.branches
  where business_id=v_live order by is_default desc, created_at limit 1;
  if v_branch is null then
    insert into public.branches(business_id,name,is_default,active)
    values(v_live,'V177 Main',true,true) returning id into v_branch;
  end if;
  select id into v_other_branch from public.branches
  where business_id=v_other order by is_default desc, created_at limit 1;
  if v_other_branch is null then
    insert into public.branches(business_id,name,is_default,active)
    values(v_other,'V177 Other Main',true,true) returning id into v_other_branch;
  end if;

  insert into public.clients(id,business_id,full_name,phone,email,created_at)
  values(v_client,v_live,'Wei Ling Tan','81770001','wei-v177@example.test',now());
  insert into public.staff(id,business_id,user_id,role,full_name,active,email,phone)
  values(v_staff,v_live,null,'staff','V177 Rota Member',true,
         'staff-v177@example.test','81770002');
  insert into public.services(id,business_id,name,price_cents,duration_min,active)
  values(v_service,v_live,'V177 Trim',4500,30,true);
  -- staff_id is deliberately null: the v120 blocked-time guard refuses an
  -- assigned appointment for a staff member with no working schedule, and the
  -- mirror's staff join is a left join anyway.
  insert into public.appointments(
    business_id,client_id,staff_id,service_id,branch_id,starts_at,ends_at,
    status,party_size
  ) values(
    v_live,v_client,null,v_service,v_branch,
    ((clock_timestamp() at time zone 'Asia/Singapore')::date + 1
      + interval '10 hours') at time zone 'Asia/Singapore',
    ((clock_timestamp() at time zone 'Asia/Singapore')::date + 1
      + interval '11 hours') at time zone 'Asia/Singapore',
    'booked',2
  );

  ----------------------------------------------------------------------------
  -- 1. Super admin gets a read-only overview envelope with the branch list.
  ----------------------------------------------------------------------------
  select count(*) into v_audit_before from public.audit_log
  where business_id=v_live and action='WORKSPACE_MIRROR_VIEWED_V177';

  perform pg_temp.as_v177_user(v_sa);
  v_result:=public.platform_workspace_mirror_v177(v_live,null,'overview');
  reset role;

  if v_result->>'contract_version'<>'v177' then
    raise exception 'the mirror did not declare contract_version v177: %',v_result;
  end if;
  if coalesce((v_result->>'read_only')::boolean,false) is not true then
    raise exception 'the mirror envelope is not marked read_only';
  end if;
  if (v_result->>'business_id')::uuid<>v_live
     or v_result->>'business_name'<>'V177 Live Firm'
     or v_result->>'industry'<>'fnb' then
    raise exception 'the envelope does not identify the firm: %',v_result;
  end if;
  if not (v_result ? 'is_demo') then
    raise exception 'the envelope does not carry the demo flag';
  end if;
  if v_result->'workspace'->>'approval_status'<>'approved' then
    raise exception 'the envelope does not carry the approval status: %',
      v_result->'workspace';
  end if;
  if not exists(
    select 1 from jsonb_array_elements(v_result->'branches') branch
    where (branch->>'id')::uuid=v_branch
      and branch ? 'name' and branch ? 'is_default' and branch ? 'active'
  ) then
    raise exception 'the branch list does not contain the fixture branch: %',
      v_result->'branches';
  end if;
  if v_result->>'branch_id' is not null then
    raise exception 'a null branch filter was not reported as null';
  end if;
  if not (v_result->'data' ? 'sales')
     or not (v_result->'data'->'sales' ? 'growth')
     or not (v_result->'data' ? 'account_opens')
     or not (v_result->'data' ? 'outstanding')
     or not (v_result->'data' ? 'counts') then
    raise exception 'the overview section is incomplete: %',v_result->'data';
  end if;

  select count(*) into v_audit_after from public.audit_log
  where business_id=v_live and action='WORKSPACE_MIRROR_VIEWED_V177';
  if v_audit_after<>v_audit_before+1 then
    raise exception 'the mirror did not write exactly one audit row (% -> %)',
      v_audit_before,v_audit_after;
  end if;
  if not exists(
    select 1 from public.audit_log entry
    where entry.business_id=v_live
      and entry.action='WORKSPACE_MIRROR_VIEWED_V177'
      and entry.entity='businesses'
      and entry.entity_id=v_live
      and entry.actor=v_sa
      and entry.detail->>'section'='overview'
  ) then
    raise exception 'the audit row does not record the viewer, entity and section';
  end if;

  ----------------------------------------------------------------------------
  -- 2. Branch scoping.
  ----------------------------------------------------------------------------
  perform pg_temp.as_v177_user(v_sa);
  v_result:=public.platform_workspace_mirror_v177(v_live,v_branch,'appointments');
  reset role;
  if (v_result->>'branch_id')::uuid<>v_branch then
    raise exception 'the resolved branch filter was not echoed back';
  end if;
  if v_result->>'branch_name' is null then
    raise exception 'the resolved branch name is missing';
  end if;
  if jsonb_array_length(v_result->'data'->'rows')<1 then
    raise exception 'the branch-scoped appointment window returned nothing';
  end if;

  -- A branch that belongs to a DIFFERENT firm is refused, not silently ignored.
  begin
    perform pg_temp.as_v177_user(v_sa);
    perform public.platform_workspace_mirror_v177(v_live,v_other_branch,'overview');
    reset role;
    raise exception 'a foreign branch was accepted as a mirror filter';
  exception when sqlstate '22023' then reset role;
  end;

  ----------------------------------------------------------------------------
  -- 3. Section validation.
  ----------------------------------------------------------------------------
  begin
    perform pg_temp.as_v177_user(v_sa);
    perform public.platform_workspace_mirror_v177(v_live,null,'billing');
    reset role;
    raise exception 'an unknown mirror section was accepted';
  exception when sqlstate '22023' then reset role;
  end;

  foreach v_section in array array['overview','appointments','customers','programmes','staff'] loop
    perform pg_temp.as_v177_user(v_sa);
    v_result:=public.platform_workspace_mirror_v177(v_live,null,v_section);
    reset role;
    if v_result->>'section'<>v_section then
      raise exception 'section % did not echo its own name',v_section;
    end if;
    if coalesce((v_result->>'read_only')::boolean,false) is not true then
      raise exception 'section % is not marked read_only',v_section;
    end if;
  end loop;

  ----------------------------------------------------------------------------
  -- 4. Privacy: no contact key anywhere in the operations sections.
  ----------------------------------------------------------------------------
  perform pg_temp.as_v177_user(v_sa);
  v_result:=public.platform_workspace_mirror_v177(v_live,null,'appointments');
  reset role;
  if pg_temp.v177_has_contact_key(v_result) then
    raise exception 'the appointments mirror leaked a contact key: %',v_result;
  end if;
  if v_result::text like '%81770001%' or v_result::text like '%wei-v177@example.test%' then
    raise exception 'the appointments mirror leaked a raw customer phone or email';
  end if;
  if not exists(
    select 1 from jsonb_array_elements(v_result->'data'->'rows') appointment
    where appointment->>'guest_label'='Wei T.'
  ) then
    raise exception 'the appointments mirror does not abbreviate the guest: %',
      v_result->'data'->'rows';
  end if;

  perform pg_temp.as_v177_user(v_sa);
  v_result:=public.platform_workspace_mirror_v177(v_live,null,'customers');
  reset role;
  if pg_temp.v177_has_contact_key(v_result) then
    raise exception 'the customers mirror leaked a contact key: %',v_result;
  end if;
  if v_result::text like '%81770001%' or v_result::text like '%wei-v177@example.test%' then
    raise exception 'the customers mirror leaked a raw customer phone or email';
  end if;
  if not exists(
    select 1 from jsonb_array_elements(v_result->'data'->'recent') customer
    where customer->>'label'='Wei T.' and customer ? 'joined_on'
      and customer ? 'visit_count'
  ) then
    raise exception 'the customers mirror does not carry the abbreviated join list: %',
      v_result->'data';
  end if;

  -- Staff full names are intentional, but staff contact columns are not.
  perform pg_temp.as_v177_user(v_sa);
  v_result:=public.platform_workspace_mirror_v177(v_live,null,'staff');
  reset role;
  if pg_temp.v177_has_contact_key(v_result) then
    raise exception 'the staff mirror leaked a contact key: %',v_result;
  end if;
  if not exists(
    select 1 from jsonb_array_elements(v_result->'data'->'rows') member
    where member->>'full_name'='V177 Rota Member' and member->>'role'='staff'
      and (member->>'active')::boolean
  ) then
    raise exception 'the staff roster is missing the fixture member: %',
      v_result->'data'->'rows';
  end if;

  ----------------------------------------------------------------------------
  -- 5. Authorization: an outsider is refused outright.
  ----------------------------------------------------------------------------
  begin
    perform pg_temp.as_v177_user(v_outsider);
    perform public.platform_workspace_mirror_v177(v_live,null,'overview');
    reset role;
    raise exception 'an outsider was able to open the workspace mirror';
  exception when insufficient_privilege or sqlstate '42501' then reset role;
  end;
  if exists(
    select 1 from public.audit_log entry
    where entry.business_id=v_live
      and entry.action='WORKSPACE_MIRROR_VIEWED_V177'
      and entry.actor=v_outsider
  ) then
    raise exception 'a refused mirror open still wrote an audit row';
  end if;

  ----------------------------------------------------------------------------
  -- 6. Assigned consultant (best effort: the prospect linkage is the v94
  --    authority and may be guarded in some environments).
  ----------------------------------------------------------------------------
  begin
    perform pg_temp.as_v177_user(v_sa);
    v_result:=public.platform_upsert_consultant_v75(
      null,v_consultant_user,'V177 Consultant','senior',current_date,true
    );
    reset role;
    v_consultant:=(v_result->'consultant'->>'id')::uuid;

    perform pg_temp.as_v177_user(v_sa);
    v_result:=public.platform_create_prospect_v76(
      '{"legal_name":"V177 Prospect Pte Ltd","trading_name":"V177 Prospect","registration_number":"V177-UEN-1","industry":"retail"}',
      '{"full_name":"V177 Owner","email":"owner-v177@example.test","phone":"81234567"}',
      'new_lead',v_consultant,'{"source_system":"manual","source_type":"manual"}',
      array['V177'],'v177-create-0001'
    );
    reset role;
    v_prospect:=(v_result->'prospect'->>'id')::uuid;
    update public.sme_prospects set converted_business_id=v_live where id=v_prospect;
    v_consultant_linked:=exists(
      select 1 from app.assigned_consultant_v94(v_live) consultant
      where consultant.user_id=v_consultant_user
    );
  exception when others then
    reset role;
    v_consultant_linked:=false;
    raise notice 'v177: consultant linkage fixture unavailable (%), skipping consultant assertions',sqlerrm;
  end;

  if v_consultant_linked then
    perform pg_temp.as_v177_user(v_consultant_user);
    v_result:=public.platform_workspace_mirror_v177(v_live,null,'overview');
    reset role;
    if (v_result->>'business_id')::uuid<>v_live then
      raise exception 'the assigned consultant did not receive their own firm';
    end if;
    if not exists(
      select 1 from public.audit_log entry
      where entry.business_id=v_live
        and entry.action='WORKSPACE_MIRROR_VIEWED_V177'
        and entry.actor=v_consultant_user
    ) then
      raise exception 'the consultant mirror open was not audited';
    end if;

    -- The same consultant has no claim on an unrelated firm.
    begin
      perform pg_temp.as_v177_user(v_consultant_user);
      perform public.platform_workspace_mirror_v177(v_other,null,'overview');
      reset role;
      raise exception 'a consultant read a firm they are not assigned to';
    exception when insufficient_privilege or sqlstate '42501' then reset role;
    end;
  end if;

  ----------------------------------------------------------------------------
  -- 7. A paused firm is still viewable - that is the point of oversight.
  ----------------------------------------------------------------------------
  insert into public.business_subscription_lifecycle_v94(
    business_id,state,provider_invoice_id,due_date,overdue_day,
    workspace_paused,paused_at,last_evaluated_on
  ) values(
    v_paused,'paused','in_v177_fixture',current_date-14,14,true,now(),current_date
  )
  on conflict(business_id) do update
    set state='paused',provider_invoice_id='in_v177_fixture',
        due_date=current_date-14,overdue_day=14,workspace_paused=true,
        paused_at=now(),last_evaluated_on=current_date;

  perform pg_temp.as_v177_user(v_sa);
  v_result:=public.platform_workspace_mirror_v177(v_paused,null,'overview');
  reset role;
  if coalesce((v_result->'workspace'->>'workspace_paused')::boolean,false) is not true then
    raise exception 'the paused firm was not reported as paused: %',
      v_result->'workspace';
  end if;
  if v_result->'workspace'->>'lifecycle_state'<>'paused' then
    raise exception 'the paused lifecycle state was not surfaced';
  end if;
  if coalesce((v_result->>'read_only')::boolean,false) is not true then
    raise exception 'the paused firm mirror is not marked read_only';
  end if;

  raise notice 'v177 workspace mirror: all assertions passed';
end
$v177$;

rollback;
