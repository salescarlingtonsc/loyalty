-- Rolled-back acceptance contract for v511 (Work operating system + Business 360).
-- Every assertion executes real RPCs and real triggers. Nothing is committed.
begin;

-- ---------------------------------------------------------------- structure
do $$
begin
  if not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='work_items_v511' and c.relrowsecurity) then
    raise exception 'FAIL work_items_v511 must have row level security';end if;
  if exists(select 1 from information_schema.role_table_grants
    where table_schema='public' and table_name in ('work_items_v511','work_item_events_v511')
      and grantee in ('anon','authenticated','public')) then
    raise exception 'FAIL work tables must not be directly reachable from the browser';end if;
  if exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname like '%_v511'
      and not has_function_privilege('authenticated',p.oid,'execute')
      and p.proname<>'platform_reopen_due_work_v511') then
    raise exception 'FAIL every public v511 RPC except the sweep must be callable by authenticated';end if;
  if has_function_privilege('authenticated',
      'public.platform_reopen_due_work_v511(integer)','execute') then
    raise exception 'FAIL the waiting sweep must not be browser callable';end if;
end $$;

-- ---------------------------------------------------------------- behaviour
do $$
declare
  v_admin constant uuid:='50400000-0000-4000-8000-000000000001';
  v_sales constant uuid:='50400000-0000-4000-8000-000000000002';
  v_peer constant uuid:='50400000-0000-4000-8000-000000000003';
  v_consultant uuid;v_other uuid;
  v_business uuid;v_prospect uuid;v_company uuid;
  v_lead jsonb;v_item uuid;v_item2 uuid;v_task uuid;v_created jsonb;v_replay jsonb;
  v_row public.work_items_v511%rowtype;v_json jsonb;v_count integer;v_state text;
  v_checklist uuid;v_onboarding_item uuid;
  v_due constant timestamptz:=clock_timestamp()+interval '2 hours';
begin
  insert into auth.users(id,email,created_at,updated_at)
  values(v_admin,'v511-admin@example.invalid',clock_timestamp(),clock_timestamp()),
        (v_sales,'v511-sales@example.invalid',clock_timestamp(),clock_timestamp()),
        (v_peer,'v511-peer@example.invalid',clock_timestamp(),clock_timestamp());
  insert into public.super_admins(user_id,email,note)
  values(v_admin,'v511-admin@example.invalid','synthetic rolled-back v511 proof');
  insert into public.platform_access_grants_v89(user_id,role,module_perms,created_by,updated_by)
  values(v_sales,'sales_staff','{"onboarding":"rw","firms":"rw"}'::jsonb,v_admin,v_admin);
  insert into public.platform_consultants(user_id,display_name,tier,employment_started_on,created_by)
  values(v_sales,'V511 Synthetic Seller','senior',current_date,v_admin) returning id into v_consultant;
  insert into public.platform_consultants(user_id,display_name,tier,employment_started_on,created_by)
  values(v_peer,'V511 Peer Seller','junior',current_date,v_admin) returning id into v_other;

  -- v625: is_super_admin() now additionally requires a Google-SSO session (amr method 'oauth'
  -- plus app_metadata.providers containing 'google'), not merely a super_admins row. v_admin IS
  -- a genuine platform/super-admin actor in this fixture (inserted into super_admins above), so
  -- this is the same session, just carrying the claims a real platform login would present.
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_admin,'role','authenticated',
      'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
      'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text,true);

  insert into public.businesses(name,slug,legal_name,is_synthetic)
  values('V511 Work Proof','v511-work-proof','V511 Work Proof',true) returning id into v_business;

  v_lead:=public.platform_ingest_lead_v510(
    '{"legal_name":"V511 Lead Proof","registration_number":"T25V511AAA"}'::jsonb,null,
    '{"source_system":"platform_console","source_type":"manual"}'::jsonb,v_consultant,
    clock_timestamp()+interval '30 minutes','50400000-0000-4000-8000-000000000010');
  v_prospect:=(v_lead->>'prospect_id')::uuid;
  if v_prospect is null then raise exception 'FAIL could not create the lead fixture: %',v_lead;end if;

  -- 1. An open work item must name an owner or a queue, and must have a due date.
  begin
    insert into public.work_items_v511(origin_kind,origin_key,work_type,title,business_id,
      ownership_state,owner_consultant_id,queue_key,due_at)
    values('native','v511-bad-owner','support_action','no owner and no queue',v_business,
      'queued',null,null,clock_timestamp());
    raise exception 'FAIL an ownerless, queueless work item was accepted';
  exception when check_violation then null;end;
  begin
    insert into public.work_items_v511(origin_kind,origin_key,work_type,title,business_id,
      ownership_state,queue_key,due_at)
    values('native','v511-bad-due','support_action','no due date',v_business,
      'queued','operations_intake',null);
    raise exception 'FAIL a work item with no due date was accepted';
  exception when check_violation then null;end;

  -- 2. Creation is idempotent: the same operation key returns the same item.
  v_created:=public.platform_create_work_item_v511('support_action','Investigate ledger',
    'customer says points disappeared',v_business,null,v_due,
    v_consultant,null,2,'50400000-0000-4000-8000-000000000020');
  v_item:=(v_created->>'work_item_id')::uuid;
  v_replay:=public.platform_create_work_item_v511('support_action','Investigate ledger',
    'customer says points disappeared',v_business,null,v_due,
    v_consultant,null,2,'50400000-0000-4000-8000-000000000020');
  if (v_replay->>'replayed')<>'true' or (v_replay->>'work_item_id')::uuid<>v_item then
    raise exception 'FAIL replaying the create key produced a second work item';end if;
  select count(*) into v_count from public.work_items_v511
   where business_id=v_business and work_type='support_action';
  if v_count<>1 then raise exception 'FAIL expected exactly 1 work item, found %',v_count;end if;

  -- 3. The state machine refuses an illegal move and records every legal one.
  select * into v_row from public.work_items_v511 where id=v_item;
  begin
    update public.work_items_v511 set state='done',closed_at=clock_timestamp(),
      close_outcome='completed' where id=v_item;
    update public.work_items_v511 set state='in_progress' where id=v_item;
    raise exception 'FAIL a closed work item was moved straight back into progress';
  exception when check_violation then null;end;

  -- 4. A blocked item must say why; a waiting item must say when it comes back.
  select version into v_row.version from public.work_items_v511 where id=v_item;
  begin
    perform public.platform_transition_work_item_v511(v_item,v_row.version,'blocked',
      null,null,null,null,'50400000-0000-4000-8000-000000000021');
    raise exception 'FAIL a blocked work item was accepted without a reason';
  exception when check_violation then null;end;

  -- 5. Waiting work reopens by itself once its return date passes.
  select version into v_row.version from public.work_items_v511 where id=v_item;
  perform public.platform_transition_work_item_v511(v_item,v_row.version,'waiting',
    'merchant is on holiday',clock_timestamp()-interval '1 minute',null,null,
    '50400000-0000-4000-8000-000000000022');
  v_json:=public.platform_reopen_due_work_v511(100);
  select state into v_state from public.work_items_v511 where id=v_item;
  if v_state<>'open' then
    raise exception 'FAIL waiting work did not reopen by itself (state=%)',v_state;end if;
  if not exists(select 1 from public.work_item_events_v511
    where work_item_id=v_item and event_type='waiting_set') then
    raise exception 'FAIL the wait was not recorded in history';end if;

  -- 6. History is evidence: it cannot be edited or deleted.
  begin
    update public.work_item_events_v511 set detail='{}'::jsonb where work_item_id=v_item;
    raise exception 'FAIL work item history was editable';
  exception when insufficient_privilege then null;end;

  -- 7. A CRM task projects into exactly one work item, and closing the task
  --    closes the projection. The task remains the system of record.
  insert into public.sme_prospect_tasks(prospect_id,title,due_at,assigned_consultant_id,created_by)
  values(v_prospect,'Call the owner back',clock_timestamp()+interval '1 hour',v_consultant,v_admin)
  returning id into v_task;
  select count(*) into v_count from public.work_items_v511
   where origin_kind='sme_prospect_task' and origin_key=v_task::text;
  if v_count<>1 then raise exception 'FAIL a CRM task projected % work items',v_count;end if;
  select id,version into v_item2,v_row.version from public.work_items_v511
   where origin_kind='sme_prospect_task' and origin_key=v_task::text;

  -- 8. A projected item may not be closed on its own — that is how two task
  --    systems start disagreeing about whether the job is done.
  begin
    perform public.platform_transition_work_item_v511(v_item2,v_row.version,'done',
      null,null,null,'completed','50400000-0000-4000-8000-000000000023');
    raise exception 'FAIL a projected work item was closed without closing its source';
  exception when check_violation then null;end;

  update public.sme_prospect_tasks set status='completed',completed_at=clock_timestamp(),
    outcome='spoke to the owner' where id=v_task;
  select state into v_state from public.work_items_v511 where id=v_item2;
  if v_state<>'done' then
    raise exception 'FAIL closing the CRM task left the work item %',v_state;end if;

  -- 9. Blocked onboarding becomes owned, visible work.
  insert into public.business_onboarding_checklists(business_id,prospect_id,status,created_by)
  values(v_business,v_prospect,'in_progress',v_admin) returning id into v_checklist;
  insert into public.business_onboarding_items(checklist_id,business_id,item_key,label,category,
    verification_mode,mandatory,status,status_before_block,blocked_by,blocked_at,block_reason)
  values(v_checklist,v_business,'legal_identity','Legal identity','legal','manual',true,
    'blocked','pending',v_admin,clock_timestamp(),'ACRA document is unreadable')
  returning id into v_onboarding_item;
  select count(*) into v_count from public.work_items_v511
   where origin_kind='onboarding_item' and origin_key=v_onboarding_item::text and state='blocked';
  if v_count<>1 then
    raise exception 'FAIL blocked onboarding produced % work items',v_count;end if;

  -- 10. One query answers "what requires action today?" across every domain.
  --     A blocked onboarding step arrives as WORK, because projection is what
  --     stops onboarding from becoming a second queue nobody watches.
  v_json:=public.platform_command_center_v511(100);
  if jsonb_array_length(v_json->'items')=0 then
    raise exception 'FAIL the command center reported nothing to do while work was outstanding';end if;
  if not exists(select 1 from jsonb_array_elements(v_json->'items') entry
    where entry->>'domain'='work' and entry->>'reason_type'='onboarding_blocked'
      and entry->>'reason'='blocked') then
    raise exception 'FAIL the blocked onboarding step never reached the command center as work';end if;
  if not exists(select 1 from jsonb_array_elements(v_json->'items') entry
    where entry->>'domain'='lead') then
    raise exception 'FAIL the open lead never reached the command center';end if;

  -- A checklist blocked at its own level is a separate signal and must also show.
  update public.business_onboarding_checklists set status='blocked',
    blocked_reason='waiting on the owner to re-upload ACRA',blocked_at=clock_timestamp(),
    blocked_by=v_admin where id=v_checklist;
  v_json:=public.platform_command_center_v511(100);
  if not exists(select 1 from jsonb_array_elements(v_json->'items') entry
    where entry->>'domain'='onboarding' and entry->>'reason'='blocked') then
    raise exception 'FAIL a blocked onboarding checklist never reached the command center';end if;

  -- 11. Business 360 answers the operator's questions in one round trip.
  v_json:=public.platform_get_business_360_v511(v_business,20);
  if v_json->'identity'->>'business_id' is null then
    raise exception 'FAIL business 360 did not identify the business';end if;
  if (v_json->'entitlement'->>'entitled')<>'false' then
    raise exception 'FAIL an unpaid business reported as entitled';end if;
  if (v_json->'entitlement'->>'live')<>'false' then
    raise exception 'FAIL an unactivated business reported as live';end if;
  if v_json->>'blocker' is null then
    raise exception 'FAIL business 360 could not say why the business is blocked';end if;
  if (v_json->'open_work'->>'blocked')::integer<1 then
    raise exception 'FAIL business 360 undercounted blocked work';end if;
  if jsonb_array_length(v_json->'timeline')=0 then
    raise exception 'FAIL business 360 returned no timeline';end if;

  -- 12. A salesperson sees their own work, and may not claim another's.
  -- v625: app.v89_platform_role() returns null on a non-Google session. v_sales is a genuine
  -- platform_access_grants_v89 sales_staff actor (inserted above), so add the same claims a
  -- real platform login would present.
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_sales,'role','authenticated',
      'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
      'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text,true);
  v_json:=public.platform_list_work_v511('mine',null,50);
  if jsonb_array_length(v_json->'items')=0 then
    raise exception 'FAIL the salesperson could not see their own work';end if;
  if exists(select 1 from jsonb_array_elements(v_json->'items') entry
    where entry->>'origin_kind' is null) then
    raise exception 'FAIL the work list hides which items are projections';end if;
  begin
    v_json:=public.platform_list_work_v511('team',null,50);
    raise exception 'FAIL a salesperson read the whole team queue';
  exception when insufficient_privilege then null;end;
  select id,version into v_item2,v_row.version from public.work_items_v511
   where origin_kind='onboarding_item' and origin_key=v_onboarding_item::text;
  begin
    perform public.platform_assign_work_item_v511(v_item2,v_row.version,v_other,null,
      '50400000-0000-4000-8000-000000000024');
    raise exception 'FAIL a salesperson assigned work to somebody else';
  exception when insufficient_privilege then null;end;
end $$;

select 'PASS v511 work invariants, projection, reopen, command center and business 360' result;
rollback;
