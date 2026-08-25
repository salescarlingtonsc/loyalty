-- Rolled-back acceptance contract for v513 (onboarding knows whose move it is).
-- Every assertion executes the real triggers, the real v79 evaluator and the real
-- v511 work core. Nothing is committed.
begin;

-- ---------------------------------------------------------------- structure
do $$
begin
  if not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='onboarding_interventions_v513' and c.relrowsecurity) then
    raise exception 'FAIL onboarding_interventions_v513 must have row level security';end if;
  if exists(select 1 from information_schema.role_table_grants
    where table_schema='public' and table_name='onboarding_interventions_v513'
      and grantee in ('anon','authenticated','public')) then
    raise exception 'FAIL the intervention record must not be reachable from the browser';end if;
  if not has_function_privilege('authenticated',
      'public.onboarding_submit_for_review_v513(uuid,uuid)','execute') then
    raise exception 'FAIL a workspace owner must be able to submit for review';end if;
  if not has_function_privilege('authenticated',
      'public.platform_get_onboarding_review_v513(uuid)','execute') then
    raise exception 'FAIL the review reader must be callable by authenticated';end if;
  if not has_function_privilege('authenticated',
      'public.platform_get_onboarding_metrics_v513(integer)','execute') then
    raise exception 'FAIL the metrics reader must be callable by authenticated';end if;
  if has_function_privilege('authenticated',
      'public.platform_sweep_stalled_onboarding_v513(integer)','execute') then
    raise exception 'FAIL the stall sweep must not be browser callable';end if;
  if not exists(select 1 from pg_attribute
    where attrelid='public.business_onboarding_checklists'::regclass
      and attname in ('next_actor','submitted_for_review_at','last_evaluated_at','template_version')
      and not attisdropped
    group by attrelid having count(*)=4) then
    raise exception 'FAIL the checklist must carry the turn, the submission and the template version';end if;
end $$;

-- ---------------------------------------------------------------- behaviour
do $$
declare
  v_admin constant uuid:='51300000-0000-4000-8000-000000000001';
  v_ops constant uuid:='51300000-0000-4000-8000-000000000002';
  v_owner constant uuid:='51300000-0000-4000-8000-000000000003';
  v_stranger constant uuid:='51300000-0000-4000-8000-000000000004';
  v_consultant uuid;
  v_business uuid;v_business2 uuid;v_prospect uuid;v_prospect2 uuid;
  v_checklist uuid;v_checklist2 uuid;
  v_lead jsonb;v_json jsonb;v_submit jsonb;v_replay jsonb;
  v_actor_text text;v_count integer;v_before integer;v_status text;v_day text:=current_date::text;
begin
  insert into auth.users(id,email,created_at,updated_at)
  values(v_admin,'v513-admin@example.invalid',clock_timestamp(),clock_timestamp()),
        (v_ops,'v513-ops@example.invalid',clock_timestamp(),clock_timestamp()),
        (v_owner,'v513-owner@example.invalid',clock_timestamp(),clock_timestamp()),
        (v_stranger,'v513-stranger@example.invalid',clock_timestamp(),clock_timestamp());
  insert into public.super_admins(user_id,email,note)
  values(v_admin,'v513-admin@example.invalid','synthetic rolled-back v513 proof');
  -- v90 keeps sales_staff inside onboarding|firms|reports; '*' is refused outright.
  insert into public.platform_access_grants_v89(user_id,role,module_perms,created_by,updated_by)
  values(v_ops,'sales_staff','{"onboarding":"rw","firms":"r"}'::jsonb,v_admin,v_admin);
  insert into public.platform_consultants(user_id,display_name,tier,employment_started_on,created_by)
  values(v_ops,'V513 Synthetic Operator','senior',current_date,v_admin) returning id into v_consultant;

  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_admin,'role','authenticated')::text,true);

  -- The business is deliberately NOT converted (source_prospect_id stays null) so
  -- the v510 inactive-shell rails do not demand a verified payment for the fixture
  -- owner login. The checklist still needs a real prospect for its FK.
  insert into public.businesses(name,slug,legal_name,is_synthetic)
  values('V513 Turn Proof','v513-turn-proof','V513 Turn Proof',true) returning id into v_business;
  insert into public.businesses(name,slug,legal_name,is_synthetic)
  values('V513 Quiet Merchant','v513-quiet-merchant','V513 Quiet Merchant',true)
  returning id into v_business2;

  v_lead:=public.platform_ingest_lead_v510(
    '{"legal_name":"V513 Lead Proof","registration_number":"T25V513AAA"}'::jsonb,null,
    '{"source_system":"platform_console","source_type":"manual"}'::jsonb,v_consultant,
    clock_timestamp()+interval '30 minutes','51300000-0000-4000-8000-000000000010');
  v_prospect:=(v_lead->>'prospect_id')::uuid;
  v_lead:=public.platform_ingest_lead_v510(
    '{"legal_name":"V513 Quiet Lead","registration_number":"T25V513BBB"}'::jsonb,null,
    '{"source_system":"platform_console","source_type":"manual"}'::jsonb,v_consultant,
    clock_timestamp()+interval '30 minutes','51300000-0000-4000-8000-000000000011');
  v_prospect2:=(v_lead->>'prospect_id')::uuid;
  if v_prospect is null or v_prospect2 is null then
    raise exception 'FAIL could not create the lead fixtures';end if;

  insert into public.business_onboarding_checklists(
    business_id,prospect_id,status,started_at,created_by)
  values(v_business,v_prospect,'in_progress',clock_timestamp(),v_admin)
  returning id into v_checklist;
  insert into public.business_onboarding_checklists(
    business_id,prospect_id,status,started_at,created_by)
  values(v_business2,v_prospect2,'in_progress',clock_timestamp(),v_admin)
  returning id into v_checklist2;

  insert into public.business_onboarding_items(checklist_id,business_id,item_key,label,category,
    verification_mode,mandatory,waivable)
  values(v_checklist,v_business,'first_value_configured',
    'A live service, product or loyalty programme exists','first_value','derived',true,false),
       (v_checklist,v_business,'training_completed','Owner training completed',
    'training','manual',true,true);

  insert into public.staff(business_id,user_id,role,full_name,active)
  values(v_business,v_owner,'owner','V513 Owner',true);

  -- 1. The turn is derived from the status v79 already computes — every status,
  --    not just the convenient ones.
  select next_actor into v_actor_text from public.business_onboarding_checklists where id=v_checklist;
  if v_actor_text<>'merchant' then
    raise exception 'FAIL an unsubmitted in_progress onboarding is the merchant''s move, not %',v_actor_text;end if;

  update public.business_onboarding_checklists set status='blocked',
    blocked_reason='ACRA document is unreadable',blocked_at=clock_timestamp(),blocked_by=v_admin
   where id=v_checklist;
  select next_actor into v_actor_text from public.business_onboarding_checklists where id=v_checklist;
  if v_actor_text<>'peekaa' then
    raise exception 'FAIL blocked onboarding must be Peekaa''s move, not %',v_actor_text;end if;

  update public.business_onboarding_checklists set status='ready',
    blocked_reason=null,blocked_at=null,blocked_by=null where id=v_checklist;
  select next_actor into v_actor_text from public.business_onboarding_checklists where id=v_checklist;
  if v_actor_text<>'peekaa' then
    raise exception 'FAIL a ready checklist waits on a Peekaa decision, not on %',v_actor_text;end if;

  update public.business_onboarding_checklists set status='activated',
    activated_at=clock_timestamp() where id=v_checklist;
  select next_actor into v_actor_text from public.business_onboarding_checklists where id=v_checklist;
  if v_actor_text<>'system' then
    raise exception 'FAIL an activated workspace has no human turn left, found %',v_actor_text;end if;

  update public.business_onboarding_checklists set status='not_started',activated_at=null
   where id=v_checklist;
  select next_actor into v_actor_text from public.business_onboarding_checklists where id=v_checklist;
  if v_actor_text<>'merchant' then
    raise exception 'FAIL a not_started checklist is the merchant''s move, not %',v_actor_text;end if;

  update public.business_onboarding_checklists set status='in_progress' where id=v_checklist;

  -- 2. Only an active owner of THAT business, or the platform, may hand the turn over.
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_stranger,'role','authenticated')::text,true);
  begin
    v_json:=public.onboarding_submit_for_review_v513(v_business,
      '51300000-0000-4000-8000-000000000020');
    raise exception 'FAIL an unrelated authenticated user submitted somebody else''s onboarding';
  exception when insufficient_privilege then null;end;

  -- 3. Submitting re-runs the REAL v79 evaluator: a tenant row that appeared
  --    since the last look must flip its derived item.
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_owner,'role','authenticated')::text,true);
  insert into public.services(business_id,name,price_cents,duration_min,active)
  values(v_business,'V513 Signature Wash',4500,30,true);
  select status into v_status from public.business_onboarding_items
   where checklist_id=v_checklist and item_key='first_value_configured';
  if v_status<>'pending' then
    raise exception 'FAIL the derived item was already % before any evaluation',v_status;end if;

  v_submit:=public.onboarding_submit_for_review_v513(v_business,
    '51300000-0000-4000-8000-000000000021');
  select status into v_status from public.business_onboarding_items
   where checklist_id=v_checklist and item_key='first_value_configured';
  if v_status<>'satisfied' then
    raise exception 'FAIL submitting did not re-evaluate the derived item (still %)',v_status;end if;

  select next_actor into v_actor_text from public.business_onboarding_checklists where id=v_checklist;
  if v_actor_text<>'peekaa' then
    raise exception 'FAIL a submitted onboarding must be Peekaa''s move, found %',v_actor_text;end if;
  if not exists(select 1 from public.business_onboarding_checklists
    where id=v_checklist and submitted_for_review_at is not null and last_evaluated_at is not null) then
    raise exception 'FAIL the submission was not stamped with its own moment';end if;
  if (v_submit->>'next_actor')<>'peekaa' or (v_submit->>'review_round')<>'1' then
    raise exception 'FAIL the submit response did not report the turn and the round: %',v_submit;end if;

  -- 4. One submission is one work item, and asking twice does not make two.
  select count(*) into v_count from public.work_items_v511
   where origin_kind='onboarding_review' and business_id=v_business;
  if v_count<>1 then
    raise exception 'FAIL a submission produced % review work items',v_count;end if;

  v_replay:=public.onboarding_submit_for_review_v513(v_business,
    '51300000-0000-4000-8000-000000000021');
  if (v_replay->>'replayed')<>'true'
     or (v_replay->>'work_item_id')<>(v_submit->>'work_item_id') then
    raise exception 'FAIL replaying the submission key did not replay: %',v_replay;end if;

  -- A second, genuinely new submission while the round is still open must land on
  -- the same round and therefore the same single work item.
  v_json:=public.onboarding_submit_for_review_v513(v_business,
    '51300000-0000-4000-8000-000000000022');
  if (v_json->>'review_round')<>'1' then
    raise exception 'FAIL an unanswered round advanced anyway: %',v_json;end if;
  select count(*) into v_count from public.work_items_v511
   where origin_kind='onboarding_review' and business_id=v_business;
  if v_count<>1 then
    raise exception 'FAIL re-submitting spawned a second review work item (%)',v_count;end if;

  -- 5. A turn nobody takes surfaces by itself, and twice a day is still once.
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_admin,'role','authenticated')::text,true);
  update public.business_onboarding_checklists
     set updated_at=clock_timestamp()-interval '48 hours' where id=v_checklist;
  update public.business_onboarding_checklists
     set updated_at=clock_timestamp()-interval '6 days' where id=v_checklist2;

  v_json:=public.platform_sweep_stalled_onboarding_v513(200);
  if not exists(select 1 from public.work_items_v511
    where origin_kind='system_sweep'
      and origin_key='onboarding-stall:'||v_checklist::text||':'||v_day
      and priority=3 and queue_key='operations_intake') then
    raise exception 'FAIL a 48h-old Peekaa turn did not become a stall work item: %',v_json;end if;
  if not exists(select 1 from public.work_items_v511
    where origin_kind='system_sweep'
      and origin_key='onboarding-nudge:'||v_checklist2::text||':'||v_day
      and priority=1 and title like 'Nudge merchant%') then
    raise exception 'FAIL a 6-day-silent merchant did not become a nudge work item: %',v_json;end if;

  select count(*) into v_before from public.work_items_v511 where origin_kind='system_sweep';
  v_json:=public.platform_sweep_stalled_onboarding_v513(200);
  select count(*) into v_count from public.work_items_v511 where origin_kind='system_sweep';
  if v_count<>v_before then
    raise exception 'FAIL a second sweep in the same day created % extra work items',v_count-v_before;end if;

  -- 6. Every touch is recorded, and whose touch it was is decided from real grants.
  if not exists(select 1 from public.onboarding_interventions_v513
    where checklist_id=v_checklist and actor=v_owner and actor_kind='merchant') then
    raise exception 'FAIL the merchant''s own submission was not recorded as a merchant touch';end if;

  update public.business_onboarding_items set status='satisfied',
    evidence=jsonb_build_object('note','training call completed'),
    satisfied_by=v_admin,satisfied_at=clock_timestamp(),updated_at=clock_timestamp()
   where checklist_id=v_checklist and item_key='training_completed';
  if not exists(select 1 from public.onboarding_interventions_v513
    where checklist_id=v_checklist and actor=v_admin and actor_kind='platform'
      and action='onboarding_item_satisfied') then
    raise exception 'FAIL a platform operator''s edit was not recorded as a platform touch';end if;

  -- 7. Measurement is evidence: it cannot be edited or deleted.
  begin
    update public.onboarding_interventions_v513 set detail='{}'::jsonb
     where checklist_id=v_checklist;
    raise exception 'FAIL intervention history was editable';
  exception when insufficient_privilege then null;end;
  begin
    delete from public.onboarding_interventions_v513 where checklist_id=v_checklist;
    raise exception 'FAIL intervention history was deletable';
  exception when insufficient_privilege then null;end;

  -- 8. The review reader answers the operator's question, and refuses everyone else.
  v_json:=public.platform_get_onboarding_review_v513(v_business);
  if v_json->'checklist'->>'next_actor'<>'peekaa' then
    raise exception 'FAIL the review reader lost the turn: %',v_json->'checklist';end if;
  if v_json->'checklist'->>'submitted_for_review_at' is null
     or v_json->'checklist'->>'last_evaluated_at' is null
     or (v_json->'checklist'->>'template_version')<>'1' then
    raise exception 'FAIL the review reader dropped a documented checklist field: %',v_json->'checklist';end if;
  if jsonb_array_length(v_json->'items')=0 then
    raise exception 'FAIL the review reader returned no items';end if;
  if not exists(select 1 from jsonb_array_elements(v_json->'items') entry
    where entry->>'item_key'='first_value_configured' and entry->>'status'='satisfied'
      and entry->'evidence' is not null) then
    raise exception 'FAIL the review reader dropped the evidence behind a satisfied item';end if;
  if v_json->>'ready' is null or (v_json->>'ready')<>'false' then
    raise exception 'FAIL an onboarding with an unpaid mandatory item reported ready: %',v_json->>'ready';end if;
  if (v_json->'interventions'->>'platform_touches')::integer<1
     or (v_json->'interventions'->>'merchant_touches')::integer<1
     or v_json->'interventions'->>'first_touch_at' is null then
    raise exception 'FAIL the review reader could not say what our own time cost: %',
      v_json->'interventions';end if;
  if (v_json->'entitlement'->>'entitled')<>'false' or (v_json->'entitlement'->>'live')<>'false' then
    raise exception 'FAIL an unpaid, unactivated business reported entitled or live';end if;

  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_stranger,'role','authenticated')::text,true);
  begin
    v_json:=public.platform_get_onboarding_review_v513(v_business);
    raise exception 'FAIL a non-platform caller read an onboarding review';
  exception when insufficient_privilege then null;end;

  -- 9. Metrics are super-admin only, and are raw explainable numbers.
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_ops,'role','authenticated')::text,true);
  begin
    v_json:=public.platform_get_onboarding_metrics_v513(100);
    raise exception 'FAIL a sales operator read the platform onboarding metrics';
  exception when insufficient_privilege then null;end;

  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_admin,'role','authenticated')::text,true);
  v_json:=public.platform_get_onboarding_metrics_v513(100);
  if not exists(select 1 from jsonb_array_elements(v_json->'businesses') entry
    where (entry->>'business_id')::uuid=v_business
      and (entry->>'platform_touches')::integer>=1
      and (entry->>'merchant_touches')::integer>=1
      and entry->>'days_to_live' is null
      and entry->>'submitted_for_review_at' is not null) then
    raise exception 'FAIL the metrics reader did not report this onboarding honestly: %',
      v_json->'businesses';end if;

  -- 10. Widening v511's origin list added one member and loosened nothing.
  begin
    insert into public.work_items_v511(origin_kind,origin_key,work_type,title,business_id,
      ownership_state,queue_key,due_at)
    values('not_a_real_origin','v513-bogus','onboarding_step','unknown origin',v_business,
      'queued','operations_intake',clock_timestamp());
    raise exception 'FAIL v511 accepted an unknown work origin';
  exception when check_violation then null;end;
end $$;

select 'PASS v513 onboarding turn, submission, stall sweep, interventions and review readers' result;
rollback;
