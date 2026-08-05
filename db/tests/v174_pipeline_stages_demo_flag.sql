-- Rollback-only v174 regression evidence: Site Visit / Quotation Sent
-- pipeline stages, and the super-admin-only is_demo flag.
-- Run after the canonical chain through v174 in a disposable database.
begin;

create or replace function pg_temp.as_v174_user(
  p_uid uuid,p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_v174_user(uuid,text) to public;

do $v174$
declare
  v_sa uuid:='17400000-0000-4000-8000-000000000001';
  v_outsider uuid:='17400000-0000-4000-8000-000000000002';
  v_consultant_user uuid:='17400000-0000-4000-8000-000000000003';
  v_consultant uuid;
  v_prospect uuid;
  v_version bigint;
  v_result jsonb;
  v_business_demo uuid:='17400000-0000-4000-8000-000000000010';
  v_business_control uuid:='17400000-0000-4000-8000-000000000011';
  v_lifecycle_demo record;
  v_lifecycle_control record;
  v_notice_count_demo integer;
begin
  ----------------------------------------------------------------------------
  -- 1. Stage catalogue: the two new stages exist with the intended sort
  --    order, sitting between meeting_sent(11) and the renumbered
  --    pending_decision(14), and the existing later stages shifted cleanly.
  ----------------------------------------------------------------------------
  if not exists(
    select 1 from public.sme_pipeline_stages
    where stage_key='site_visit' and label='Site Visit' and sort_order=12
  ) then raise exception 'site_visit stage missing or misordered'; end if;
  if not exists(
    select 1 from public.sme_pipeline_stages
    where stage_key='quotation_sent' and label='Quotation Sent' and sort_order=13
  ) then raise exception 'quotation_sent stage missing or misordered'; end if;
  if not exists(
    select 1 from public.sme_pipeline_stages where stage_key='meeting_sent' and sort_order=11
  ) then raise exception 'meeting_sent sort_order was disturbed'; end if;
  if not exists(
    select 1 from public.sme_pipeline_stages where stage_key='pending_decision' and sort_order=14
  ) then raise exception 'pending_decision was not renumbered to 14'; end if;
  if not exists(
    select 1 from public.sme_pipeline_stages where stage_key='lost' and sort_order=19
  ) then raise exception 'lost was not renumbered to 19'; end if;
  if (select count(distinct sort_order) from public.sme_pipeline_stages)
     <>(select count(*) from public.sme_pipeline_stages) then
    raise exception 'sort_order is no longer unique across sme_pipeline_stages';
  end if;

  if not exists(
    select 1 from public.sme_stage_entry_requirements
    where stage_key='site_visit'
      and required_keys=array['visit_at','visit_owner','outcome_notes']
      and system_managed=false
  ) then raise exception 'site_visit stage-entry requirement missing/incorrect'; end if;
  if not exists(
    select 1 from public.sme_stage_entry_requirements
    where stage_key='quotation_sent'
      and required_keys=array['quotation_amount_cents','sent_at','next_follow_up_at']
      and system_managed=false
  ) then raise exception 'quotation_sent stage-entry requirement missing/incorrect'; end if;

  ----------------------------------------------------------------------------
  -- Fixtures shared by the remaining sections.
  ----------------------------------------------------------------------------
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_sa,'authenticated','authenticated',
     'v174-sa@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_outsider,'authenticated','authenticated',
     'v174-outsider@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_consultant_user,'authenticated','authenticated',
     'v174-consultant@example.test','',now(),now(),now());
  insert into public.super_admins(user_id,email,note)
  values(v_sa,'v174-sa@example.test','v174 rollback fixture');

  perform pg_temp.as_v174_user(v_sa);
  v_result:=public.platform_upsert_consultant_v75(
    null,v_consultant_user,'V174 Consultant','senior',current_date,true
  );
  reset role;
  v_consultant:=(v_result->'consultant'->>'id')::uuid;

  ----------------------------------------------------------------------------
  -- 2. A prospect can transition into and out of both new stages.
  ----------------------------------------------------------------------------
  perform pg_temp.as_v174_user(v_sa);
  v_result:=public.platform_create_prospect_v76(
    '{"legal_name":"V174 Prospect Pte Ltd","trading_name":"V174 Prospect","registration_number":"V174-UEN-1","industry":"retail"}',
    '{"full_name":"V174 Owner","email":"owner-v174@example.test","phone":"81234567"}',
    'new_lead',v_consultant,'{"source_system":"manual","source_type":"manual"}',
    array['V174'],'v174-create-0001'
  );
  reset role;
  v_prospect:=(v_result->'prospect'->>'id')::uuid;
  select version into v_version from public.sme_prospects where id=v_prospect;

  -- new_lead -> appt_set (appt_set's own validator requires an active contact
  -- with a channel; the create-prospect RPC already created one).
  perform pg_temp.as_v174_user(v_sa);
  perform public.platform_move_prospect_stage_v86(
    v_prospect,'appt_set',v_version,
    jsonb_build_object('appointment_at','2026-08-01T02:00:00Z',
      'appointment_owner',v_consultant,'next_action_at','2026-08-01T02:00:00Z'),
    null,'v174-stage-appt_set'
  );
  reset role;
  select version into v_version from public.sme_prospects where id=v_prospect;

  -- appt_set -> site_visit
  perform pg_temp.as_v174_user(v_sa);
  perform public.platform_move_prospect_stage_v86(
    v_prospect,'site_visit',v_version,
    jsonb_build_object('visit_at','2026-08-02T03:00:00Z',
      'visit_owner',v_consultant,'outcome_notes','Site suits a two-terminal rollout.'),
    null,'v174-stage-site_visit'
  );
  reset role;
  if not exists(
    select 1 from public.sme_prospects
    where id=v_prospect and current_stage_key='site_visit'
  ) then raise exception 'prospect did not enter site_visit'; end if;
  if not exists(
    select 1 from public.sme_stage_entry_evidence
    where prospect_id=v_prospect and stage_key='site_visit'
  ) then raise exception 'site_visit entry evidence was not recorded'; end if;
  if not exists(
    select 1 from public.sme_prospect_stage_history
    where prospect_id=v_prospect and to_stage_key='site_visit'
  ) then raise exception 'site_visit stage history was not recorded'; end if;
  select version into v_version from public.sme_prospects where id=v_prospect;

  -- site_visit -> quotation_sent (out of site_visit, into quotation_sent)
  perform pg_temp.as_v174_user(v_sa);
  perform public.platform_move_prospect_stage_v86(
    v_prospect,'quotation_sent',v_version,
    jsonb_build_object('quotation_amount_cents',480000,
      'sent_at','2026-08-03T04:00:00Z','next_follow_up_at','2026-08-06T04:00:00Z'),
    null,'v174-stage-quotation_sent'
  );
  reset role;
  if not exists(
    select 1 from public.sme_prospects
    where id=v_prospect and current_stage_key='quotation_sent'
  ) then raise exception 'prospect did not enter quotation_sent'; end if;
  if not exists(
    select 1 from public.sme_prospect_stage_history
    where prospect_id=v_prospect and from_stage_key='site_visit' and to_stage_key='quotation_sent'
  ) then raise exception 'transition out of site_visit into quotation_sent was not recorded'; end if;
  select version into v_version from public.sme_prospects where id=v_prospect;

  -- quotation_sent -> pending_decision (out of quotation_sent)
  perform pg_temp.as_v174_user(v_sa);
  perform public.platform_move_prospect_stage_v86(
    v_prospect,'pending_decision',v_version,
    jsonb_build_object('qualification_summary','Ready to decide','decision_maker','V174 Owner',
      'key_objection','Price','proposed_plan','Standard','proposed_value_cents',480000,
      'next_action_at','2026-08-07T04:00:00Z','decision_at','2026-08-10'),
    null,'v174-stage-pending_decision'
  );
  reset role;
  if not exists(
    select 1 from public.sme_prospects
    where id=v_prospect and current_stage_key='pending_decision'
  ) then raise exception 'prospect did not leave quotation_sent for pending_decision'; end if;

  -- Reject an unknown-stage move to confirm the FK/lookup guard still fails
  -- closed (defends against a typo reintroducing an unmapped stage_key).
  begin
    select version into v_version from public.sme_prospects where id=v_prospect;
    perform pg_temp.as_v174_user(v_sa);
    perform public.platform_move_prospect_stage_v86(
      v_prospect,'not_a_real_stage',v_version,'{}'::jsonb,null,'v174-stage-invalid'
    );
    reset role;
    raise exception 'unknown stage_key was accepted';
  exception when invalid_text_representation or sqlstate '22023' then reset role;
  end;

  ----------------------------------------------------------------------------
  -- 3. is_demo defaults to false, and only a super admin may change it.
  ----------------------------------------------------------------------------
  insert into public.businesses(id,name,slug,industry,created_at,updated_at)
  values(v_business_demo,'V174 Demo Firm','v174-demo-firm','fnb',now()-interval '30 days',now());
  insert into public.businesses(id,name,slug,industry,created_at,updated_at)
  values(v_business_control,'V174 Control Firm','v174-control-firm','fnb',now()-interval '30 days',now());

  if not exists(
    select 1 from public.businesses where id in (v_business_demo,v_business_control) and is_demo=false
  ) or exists(
    select 1 from public.businesses where id in (v_business_demo,v_business_control) and is_demo<>false
  ) then raise exception 'is_demo did not default to false'; end if;

  begin
    perform pg_temp.as_v174_user(v_outsider);
    perform public.set_business_demo_flag_v174(v_business_demo,true,'attempted by non-SA');
    reset role;
    raise exception 'non-super-admin was able to set is_demo';
  exception when insufficient_privilege or sqlstate '42501' then reset role;
  end;
  if exists(select 1 from public.businesses where id=v_business_demo and is_demo=true) then
    raise exception 'is_demo changed despite the RPC being rejected';
  end if;

  perform pg_temp.as_v174_user(v_sa);
  v_result:=public.set_business_demo_flag_v174(v_business_demo,true,'v174 fixture: mark demo');
  reset role;
  if coalesce((v_result->>'changed')::boolean,false)<>true
     or coalesce((v_result->>'is_demo')::boolean,false)<>true then
    raise exception 'set_business_demo_flag_v174 did not report the change: %',v_result;
  end if;
  if not exists(select 1 from public.businesses where id=v_business_demo and is_demo=true) then
    raise exception 'is_demo was not persisted for the demo firm';
  end if;
  if not exists(
    select 1 from public.business_demo_flag_audit_v174
    where business_id=v_business_demo and prior_is_demo=false and new_is_demo=true
  ) then raise exception 'demo flag audit row was not recorded'; end if;
  if not exists(
    select 1 from public.audit_log
    where business_id=v_business_demo and action='BUSINESS_MARKED_DEMO_V174'
  ) then raise exception 'platform audit_log row was not recorded for the demo flag'; end if;

  ----------------------------------------------------------------------------
  -- 4. The v94 daily subscription-lifecycle scan skips demo firms: an
  --    identically-overdue invoice pauses the control firm's workspace on
  --    day 20 but leaves the demo firm's lifecycle state untouched and
  --    creates no billing-due notice for it.
  ----------------------------------------------------------------------------
  insert into public.billing_provider_invoices(
    business_id,provider_customer_id,provider_invoice_id,currency,status,livemode,
    subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,amount_paid_cents,
    amount_remaining_cents,due_at,provider_event_created_at,provider_event_rank,last_event_id
  ) values
    (v_business_demo,'cus_v174_demo','in_v174_demo','SGD','open',false,
      14800,0,14800,14800,0,14800,now()-interval '20 days',now()-interval '20 days',1,'evt_v174_demo'),
    (v_business_control,'cus_v174_control','in_v174_control','SGD','open',false,
      14800,0,14800,14800,0,14800,now()-interval '20 days',now()-interval '20 days',1,'evt_v174_control');

  -- current_date+1: in a live database today's cron run may already be
  -- recorded as succeeded, which would make a current_date call replay the
  -- stored summary instead of evaluating the fixtures.
  perform app.run_subscription_lifecycle_v94(current_date+1);

  select * into v_lifecycle_demo from public.business_subscription_lifecycle_v94
  where business_id=v_business_demo;
  select * into v_lifecycle_control from public.business_subscription_lifecycle_v94
  where business_id=v_business_control;

  if v_lifecycle_demo.state<>'current' or v_lifecycle_demo.workspace_paused<>false then
    raise exception 'demo firm was evaluated by the subscription lifecycle scan: %',
      row_to_json(v_lifecycle_demo);
  end if;
  if v_lifecycle_control.state<>'paused' or v_lifecycle_control.workspace_paused<>true then
    raise exception 'control firm was not paused by the day-20 overdue scan: %',
      row_to_json(v_lifecycle_control);
  end if;

  select count(*) into v_notice_count_demo
  from public.business_billing_due_notices_v94 where business_id=v_business_demo;
  if v_notice_count_demo<>0 then
    raise exception 'a billing-due notice was created for a demo firm';
  end if;
  if not exists(
    select 1 from public.business_billing_due_notices_v94 where business_id=v_business_control
  ) then raise exception 'no billing-due notice was created for the control firm'; end if;

  raise notice 'v174 pipeline stages + demo flag: all assertions passed';
end
$v174$;

rollback;
