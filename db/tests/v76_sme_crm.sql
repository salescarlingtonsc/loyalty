-- Rollback-only v76 SME CRM acceptance evidence.
-- Run after the canonical chain through v76 in a disposable database.
begin;

create or replace function pg_temp.as_v76_user(p_uid uuid,p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',json_build_object('sub',p_uid,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_v76_user(uuid,text) to public;

do $v76_test$
declare
  v_sa uuid:=gen_random_uuid();
  v_outsider uuid:=gen_random_uuid();
  v_consultant_user uuid:=gen_random_uuid();
  v_consultant uuid;
  v_prospect uuid;
  v_task uuid;
  v_batch uuid;
  v_version bigint;
  v_result jsonb;
  v_first jsonb;
  v_before integer;
  v_after integer;
  v_conflict integer;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_sa,'authenticated','authenticated',
     'v76-sa-'||substr(v_sa::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_outsider,'authenticated','authenticated',
     'v76-out-'||substr(v_outsider::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_consultant_user,'authenticated','authenticated',
     'v76-consultant-'||substr(v_consultant_user::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.super_admins(user_id,email,note)
  values(v_sa,'v76-sa-'||substr(v_sa::text,1,8)||'@example.test','v76 rollback fixture');

  perform pg_temp.as_v76_user(v_sa);
  v_result:=public.platform_upsert_consultant_v75(
    null,v_consultant_user,'V76 Junior','junior',current_date-30,true
  );
  reset role;
  v_consultant:=(v_result->'consultant'->>'id')::uuid;

  perform pg_temp.as_v76_user(v_sa);
  v_first:=public.platform_create_prospect_v76(
    '{"legal_name":"V76 Prospect Pte Ltd","trading_name":"V76 Prospect","registration_number":"V76-UEN-1","industry":"retail","sector_key":"retail"}',
    '{"full_name":"V76 Owner","email":"owner-v76@example.test"}',
    'new_lead',v_consultant,'{"source_system":"manual","source_type":"manual"}',
    array['Priority Lead','Priority Lead'],'v76-create-0001'
  );
  v_result:=public.platform_create_prospect_v76(
    '{"legal_name":"V76 Prospect Pte Ltd","trading_name":"V76 Prospect","registration_number":"V76-UEN-1","industry":"retail","sector_key":"retail"}',
    '{"full_name":"V76 Owner","email":"owner-v76@example.test"}',
    'new_lead',v_consultant,'{"source_system":"manual","source_type":"manual"}',
    array['Priority Lead','Priority Lead'],'v76-create-0001'
  );
  reset role;
  v_prospect:=(v_first->'prospect'->>'id')::uuid;
  if (v_result->'prospect'->>'id')::uuid<>v_prospect
     or coalesce((v_result->>'replayed')::boolean,false)<>true
     or (select count(*) from public.sme_prospects where id=v_prospect)<>1 then
    raise exception 'prospect create replay was not idempotent';
  end if;

  select version into v_version from public.sme_prospects where id=v_prospect;
  perform pg_temp.as_v76_user(v_sa);
  v_result:=public.platform_update_prospect_v76(
    v_prospect,v_version,
    '{"next_action_at":"2026-08-01T02:00:00Z","qualification":{"budget_status":"confirmed","authority_status":"decision_maker","need_status":"confirmed","timeline_status":"this_month","score":90},"tags":["Qualified"]}',
    'v76-update-0001'
  );
  reset role;
  begin
    perform pg_temp.as_v76_user(v_sa);
    perform public.platform_update_prospect_v76(
      v_prospect,v_version,'{"trading_name":"STALE"}','v76-update-stale'
    );
    reset role;
    raise exception 'stale prospect update did not conflict';
  exception when serialization_failure then reset role;
  end;

  select version into v_version from public.sme_prospects where id=v_prospect;
  perform pg_temp.as_v76_user(v_sa);
  perform public.platform_assign_prospect_v76(v_prospect,v_consultant,v_version,'v76-assign-0001');
  v_result:=public.platform_add_prospect_activity_v76(
    v_prospect,'whatsapp','Discovery follow-up sent','Decision maker acknowledged',now(),'v76-activity-0001'
  );
  v_result:=public.platform_create_prospect_task_v76(
    v_prospect,'Send proposal',now()+interval '1 day',v_consultant,'v76-task-0001'
  );
  reset role;
  v_task:=(v_result->'task'->>'id')::uuid;
  perform pg_temp.as_v76_user(v_sa);
  perform public.platform_complete_prospect_task_v76(v_task,'Proposal sent','v76-taskdone-0001');
  reset role;

  select version into v_version from public.sme_prospects where id=v_prospect;
  select count(*) into v_before from public.sme_prospect_activities
   where prospect_id=v_prospect and activity_type='npu_attempt';
  perform pg_temp.as_v76_user(v_sa);
  perform public.platform_move_prospect_stage_v76(
    v_prospect,'npu_1',v_version,null,null,null,'v76-stage-npu1'
  );
  reset role;
  select count(*) into v_after from public.sme_prospect_activities
   where prospect_id=v_prospect and activity_type='npu_attempt';
  if v_after<>v_before+1 then raise exception 'NPU transition did not create one activity';end if;

  select version into v_version from public.sme_prospects where id=v_prospect;
  begin
    perform pg_temp.as_v76_user(v_sa);
    perform public.platform_move_prospect_stage_v76(
      v_prospect,'lost',v_version,null,null,null,'v76-stage-lost-invalid'
    );
    reset role;
    raise exception 'Lost accepted no structured reason';
  exception when invalid_parameter_value then reset role;
  end;
  begin
    perform pg_temp.as_v76_user(v_sa);
    perform public.platform_move_prospect_stage_v76(
      v_prospect,'activated',v_version,null,null,null,'v76-stage-system-invalid'
    );
    reset role;
    raise exception 'user moved a prospect into a system-managed stage';
  exception when insufficient_privilege then reset role;
  end;
  begin
    perform pg_temp.as_v76_user(v_sa);
    perform public.platform_move_prospect_stage_v76(
      v_prospect,'client',v_version,null,null,null,'v76-stage-client-invalid'
    );
    reset role;
    raise exception 'Client accepted no commercial fields';
  exception when invalid_parameter_value then reset role;
  end;

  perform pg_temp.as_v76_user(v_sa);
  perform public.platform_move_prospect_stage_v76(
    v_prospect,'client',v_version,null,null,
    jsonb_build_object(
      'plan_code','growth','product_code','nestly_sme','billing_cycle','quarterly',
      'seats',3,'currency','SGD','accepted_value_cents',5500,
      'owner_email','owner-v76@example.test','onboarding_owner_consultant_id',v_consultant,
      'target_go_live','2026-08-15','contract_status','accepted'
    ),'v76-stage-client-valid'
  );
  reset role;
  if not exists(
    select 1 from public.sme_commercial_terms
     where prospect_id=v_prospect and plan_code='growth' and product_code='nestly_sme'
       and billing_cycle='quarterly' and seats=3 and currency='SGD'
       and accepted_value_cents=5500 and contract_status='accepted' and accepted_at is not null
  ) then raise exception 'accepted commercial snapshot was not preserved';end if;

  perform pg_temp.as_v76_user(v_sa);
  v_result:=public.platform_stage_prospect_import_v76(
    'legacy_crm','v76-import',
    '[{"trading_name":"Mapped Co","registration_number":"V76-IMPORT-DUP","stage":"Appointment Set","email":"mapped@example.test"},
      {"trading_name":"Conflict Co","registration_number":"V76-IMPORT-DUP","stage":"New Lead","email":"conflict@example.test"},
      {"trading_name":"Unknown Co","stage":"Someday Maybe","email":"unknown@example.test"},
      {"stage":"New Lead"}]'::jsonb,
    'v76-import-stage-0001'
  );
  reset role;
  v_batch:=(v_result->>'batch_id')::uuid;
  v_conflict:=coalesce((v_result->>'conflict_rows')::integer,0);
  if v_conflict<>1 or not exists(
    select 1 from public.sme_prospect_import_rows
     where batch_id=v_batch and row_status='conflict'
       and 'duplicate_registration_number'=any(errors)
  ) then raise exception 'duplicate registration import was not isolated as conflict';end if;
  perform pg_temp.as_v76_user(v_sa);
  perform public.platform_commit_prospect_import_v76(v_batch,'v76-import-commit-0001');
  v_result:=public.platform_get_sme_board_v76(null);
  reset role;
  if coalesce((v_result#>>'{unmapped,count}')::integer,0)<1
     or not exists(
       select 1 from public.sme_prospects
        where current_stage_key is null and legacy_stage_raw='Someday Maybe'
     ) then raise exception 'unknown imported stage was hidden instead of Unmapped';end if;

  begin
    perform pg_temp.as_v76_user(v_outsider);
    perform public.platform_get_sme_board_v76(null);
    reset role;
    raise exception 'non-platform user opened the SME board';
  exception when insufficient_privilege then reset role;
  end;
end
$v76_test$;

rollback;
