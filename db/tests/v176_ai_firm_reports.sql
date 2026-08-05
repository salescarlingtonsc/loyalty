-- Rollback-only v176 regression evidence: scheduled AI narrative reports per
-- firm (storage, authorization, enqueue, queue claim, completion, listing).
-- Run after the canonical chain through v176 in a disposable database.
--
-- Prod-compatible by construction: every assertion uses fixture-specific
-- businesses and fixture-specific closed periods, so a real cron run for the
-- same calendar period cannot satisfy or invalidate any assertion here.
begin;

create or replace function pg_temp.as_v176_user(
  p_uid uuid,p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_v176_user(uuid,text) to public;

do $v176$
declare
  v_sa uuid:='17600000-0000-4000-8000-000000000001';
  v_outsider uuid:='17600000-0000-4000-8000-000000000002';
  v_consultant_user uuid:='17600000-0000-4000-8000-000000000003';
  v_consultant uuid;
  v_prospect uuid;
  v_live uuid:='17600000-0000-4000-8000-000000000010';
  v_demo uuid:='17600000-0000-4000-8000-000000000011';
  v_pending uuid:='17600000-0000-4000-8000-000000000012';
  v_period_start date:='2026-01-01';
  v_second_period date:='2026-02-01';
  v_result jsonb;
  v_claim jsonb;
  v_claim_again jsonb;
  v_report uuid;
  v_second_report uuid;
  v_row public.ai_firm_reports_v176%rowtype;
  v_policy_count integer;
  v_write_policies integer;
  v_queued integer;
  v_consultant_linked boolean:=false;
  v_narrative text:=E'## Summary\nSales grew this month.\n\n## What went well\n- 12 new customers joined.';
begin
  ----------------------------------------------------------------------------
  -- 1. Table and RLS shape: read-only to the API, no write policy at all.
  ----------------------------------------------------------------------------
  if to_regclass('public.ai_firm_reports_v176') is null then
    raise exception 'ai_firm_reports_v176 is missing';
  end if;
  if not exists(
    select 1 from pg_class
    where oid='public.ai_firm_reports_v176'::regclass and relrowsecurity
  ) then raise exception 'row level security is not enabled on ai_firm_reports_v176'; end if;

  select count(*) filter(where polcmd='r'),
         count(*) filter(where polcmd<>'r')
  into v_policy_count,v_write_policies
  from pg_policy where polrelid='public.ai_firm_reports_v176'::regclass;
  if v_policy_count<1 then
    raise exception 'no SELECT policy exists on ai_firm_reports_v176';
  end if;
  if v_write_policies<>0 then
    raise exception 'ai_firm_reports_v176 must have no write policy (found %)',
      v_write_policies;
  end if;
  if has_table_privilege('authenticated','public.ai_firm_reports_v176','INSERT')
     or has_table_privilege('authenticated','public.ai_firm_reports_v176','UPDATE')
     or has_table_privilege('authenticated','public.ai_firm_reports_v176','DELETE')
     or has_table_privilege('anon','public.ai_firm_reports_v176','SELECT') then
    raise exception 'ai_firm_reports_v176 grants are too wide';
  end if;
  if not exists(
    select 1 from pg_index
    where indrelid='public.ai_firm_reports_v176'::regclass
      and indisunique
      and pg_get_indexdef(indexrelid) like
        '%(business_id, period_kind, period_start)%'
  ) then
    raise exception 'unique (business_id, period_kind, period_start) is missing';
  end if;

  ----------------------------------------------------------------------------
  -- Fixtures.
  ----------------------------------------------------------------------------
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
    created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_sa,'authenticated','authenticated',
     'v176-sa@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_outsider,'authenticated','authenticated',
     'v176-outsider@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_consultant_user,'authenticated','authenticated',
     'v176-consultant@example.test','',now(),now(),now());
  insert into public.super_admins(user_id,email,note)
  values(v_sa,'v176-sa@example.test','v176 rollback fixture');

  insert into public.businesses(id,name,slug,industry,created_at,updated_at)
  values
    (v_live,'V176 Live Firm','v176-live-firm','fnb',now()-interval '400 days',now()),
    (v_demo,'V176 Demo Firm','v176-demo-firm','fnb',now()-interval '400 days',now()),
    (v_pending,'V176 Pending Firm','v176-pending-firm','fnb',now()-interval '400 days',now());

  insert into public.business_workspace_controls_v94(
    business_id,approval_status,decided_by,decided_at,decision_reason
  ) values
    (v_live,'approved',v_sa,now(),'v176 fixture approval'),
    (v_demo,'approved',v_sa,now(),'v176 fixture approval')
  on conflict(business_id) do update
    set approval_status='approved',decided_by=v_sa,decided_at=now(),
        decision_reason='v176 fixture approval';
  insert into public.business_workspace_controls_v94(
    business_id,approval_status
  ) values(v_pending,'pending')
  on conflict(business_id) do update
    set approval_status='pending',decided_by=null,decided_at=null,
        decision_reason=null;

  update public.businesses set is_demo=true where id=v_demo;
  if not exists(select 1 from public.businesses where id=v_demo and is_demo) then
    raise exception 'demo fixture firm was not marked as demo';
  end if;

  ----------------------------------------------------------------------------
  -- 2. Request RPC authorization.
  ----------------------------------------------------------------------------
  -- 2a. An outsider with no platform grant is refused.
  begin
    perform pg_temp.as_v176_user(v_outsider);
    perform public.platform_request_ai_firm_report_v176(
      v_live,'monthly',v_period_start
    );
    reset role;
    raise exception 'an outsider was able to request an AI firm report';
  exception when insufficient_privilege or sqlstate '42501' then reset role;
  end;
  if exists(select 1 from public.ai_firm_reports_v176 where business_id=v_live) then
    raise exception 'a report row was created despite the request being refused';
  end if;

  -- 2b. A demo firm is rejected even for a super admin.
  begin
    perform pg_temp.as_v176_user(v_sa);
    perform public.platform_request_ai_firm_report_v176(
      v_demo,'monthly',v_period_start
    );
    reset role;
    raise exception 'a demo firm was accepted for AI report generation';
  exception when sqlstate '22023' then reset role;
  end;

  -- 2c. A period that has not closed is rejected.
  begin
    perform pg_temp.as_v176_user(v_sa);
    perform public.platform_request_ai_firm_report_v176(
      v_live,'monthly',
      date_trunc('month',(clock_timestamp() at time zone 'Asia/Singapore')::date)::date
    );
    reset role;
    raise exception 'an open (unfinished) period was accepted';
  exception when sqlstate '22023' then reset role;
  end;

  -- 2d. A misaligned period_start is rejected.
  begin
    perform pg_temp.as_v176_user(v_sa);
    perform public.platform_request_ai_firm_report_v176(
      v_live,'monthly',v_period_start+5
    );
    reset role;
    raise exception 'a misaligned period_start was accepted';
  exception when sqlstate '22023' then reset role;
  end;

  -- 2e. The super admin succeeds, and a repeat request refreshes the SAME row
  --     with an incremented generation counter rather than duplicating it.
  perform pg_temp.as_v176_user(v_sa);
  v_result:=public.platform_request_ai_firm_report_v176(
    v_live,'monthly',v_period_start
  );
  reset role;
  v_report:=(v_result->>'id')::uuid;
  if v_result->>'status'<>'pending' then
    raise exception 'requested report is not pending: %',v_result;
  end if;
  if v_result->>'model'<>'claude-sonnet-5' then
    raise exception 'monthly report was not routed to claude-sonnet-5: %',v_result;
  end if;
  if (v_result->>'period_end')::date<>'2026-01-31'::date then
    raise exception 'monthly period_end was not derived correctly: %',v_result;
  end if;
  if (v_result->>'generation')::integer<>1 then
    raise exception 'first generation counter is not 1: %',v_result;
  end if;

  perform pg_temp.as_v176_user(v_sa);
  v_result:=public.platform_request_ai_firm_report_v176(
    v_live,'monthly',v_period_start
  );
  reset role;
  if (v_result->>'id')::uuid<>v_report then
    raise exception 'regeneration created a second row instead of refreshing';
  end if;
  if (v_result->>'generation')::integer<>2 then
    raise exception 'regeneration did not increment the generation counter: %',v_result;
  end if;
  if (select count(*) from public.ai_firm_reports_v176
      where business_id=v_live and period_kind='monthly'
        and period_start=v_period_start)<>1 then
    raise exception 'the (business, kind, period) uniqueness was not enforced';
  end if;

  -- 2f. Quarterly and yearly route to the deeper model.
  perform pg_temp.as_v176_user(v_sa);
  v_result:=public.platform_request_ai_firm_report_v176(
    v_live,'quarterly','2026-01-01'
  );
  reset role;
  if v_result->>'model'<>'claude-opus-4-8' then
    raise exception 'quarterly report was not routed to claude-opus-4-8: %',v_result;
  end if;
  delete from public.ai_firm_reports_v176
  where business_id=v_live and period_kind='quarterly';

  ----------------------------------------------------------------------------
  -- 3. Assigned-consultant access (best effort: the prospect linkage is the
  --    v94 authority and may be guarded in some environments).
  ----------------------------------------------------------------------------
  begin
    perform pg_temp.as_v176_user(v_sa);
    v_result:=public.platform_upsert_consultant_v75(
      null,v_consultant_user,'V176 Consultant','senior',current_date,true
    );
    reset role;
    v_consultant:=(v_result->'consultant'->>'id')::uuid;

    perform pg_temp.as_v176_user(v_sa);
    v_result:=public.platform_create_prospect_v76(
      '{"legal_name":"V176 Prospect Pte Ltd","trading_name":"V176 Prospect","registration_number":"V176-UEN-1","industry":"retail"}',
      '{"full_name":"V176 Owner","email":"owner-v176@example.test","phone":"81234567"}',
      'new_lead',v_consultant,'{"source_system":"manual","source_type":"manual"}',
      array['V176'],'v176-create-0001'
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
    raise notice 'v176: consultant linkage fixture unavailable (%), skipping consultant assertions',sqlerrm;
  end;

  if v_consultant_linked then
    perform pg_temp.as_v176_user(v_consultant_user);
    if not app.v176_can_read_firm_report(v_live) then
      reset role;
      raise exception 'the assigned consultant cannot read this firm''s reports';
    end if;
    if not app.v176_is_assigned_consultant(v_live) then
      reset role;
      raise exception 'assigned-consultant detection failed for the linked firm';
    end if;
    v_result:=public.platform_list_ai_firm_reports_v176(v_live,12);
    reset role;
    if jsonb_array_length(v_result->'reports')<1 then
      raise exception 'the assigned consultant sees no reports for their own firm';
    end if;

    perform pg_temp.as_v176_user(v_outsider);
    if app.v176_is_assigned_consultant(v_live) then
      reset role;
      raise exception 'an outsider was treated as the assigned consultant';
    end if;
    reset role;
  end if;

  ----------------------------------------------------------------------------
  -- 4. Scheduled enqueue: approved, non-demo firms only.
  ----------------------------------------------------------------------------
  -- `reset role` does not clear request GUCs. Clear them so the remaining
  -- sections run in the same identity-less context as pg_cron / service role.
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
  if auth.uid() is not null then
    raise exception 'the internal sections are not running without an auth identity';
  end if;

  v_queued:=app.v176_enqueue_ai_firm_reports('monthly',v_second_period);
  if v_queued<1 then
    raise exception 'the enqueue helper queued nothing at all';
  end if;
  if not exists(
    select 1 from public.ai_firm_reports_v176
    where business_id=v_live and period_kind='monthly'
      and period_start=v_second_period and status='pending'
  ) then raise exception 'the approved live firm was not enqueued'; end if;
  if exists(
    select 1 from public.ai_firm_reports_v176 where business_id=v_demo
  ) then raise exception 'a demo firm was enqueued for an AI report'; end if;
  if exists(
    select 1 from public.ai_firm_reports_v176 where business_id=v_pending
  ) then raise exception 'a firm awaiting approval was enqueued'; end if;

  -- Re-running the same enqueue is idempotent (no duplicate, no reset).
  if app.v176_enqueue_ai_firm_reports('monthly',v_second_period)<>0 then
    raise exception 'a repeated enqueue for the same period created new rows';
  end if;

  ----------------------------------------------------------------------------
  -- 5. Queue claim: pending -> generating with the evidence pack stored, and
  --    the same row is never handed out twice (SKIP LOCKED semantics).
  ----------------------------------------------------------------------------
  -- Make the fixture row unambiguously the oldest pending row so the assertion
  -- holds in a database that already carries real queued reports.
  update public.ai_firm_reports_v176
  set created_at=now()-interval '10 years'
  where id=v_report;

  v_claim:=public.internal_claim_ai_firm_report_v176();
  if not coalesce((v_claim->>'claimed')::boolean,false) then
    raise exception 'the queue claim returned nothing while a pending row existed';
  end if;
  if (v_claim->'report'->>'id')::uuid<>v_report then
    raise exception 'the oldest pending report was not the one claimed';
  end if;
  if v_claim->'report'->>'status'<>'generating' then
    raise exception 'a claimed report was not moved to generating: %',v_claim;
  end if;
  if v_claim->'report'->'evidence' is null
     or v_claim->'report'->'evidence'='null'::jsonb then
    raise exception 'the claim did not store an evidence pack';
  end if;
  if not (v_claim->'report'->'evidence' ? 'sales')
     or not (v_claim->'report'->'evidence' ? 'account_opens')
     or not (v_claim->'report'->'evidence' ? 'scope') then
    raise exception 'the evidence pack is missing required sections: %',
      v_claim->'report'->'evidence';
  end if;
  if not (v_claim->'report'->'evidence'->'sales'->'current' ? 'new_customers') then
    raise exception 'the evidence pack does not carry the new-customer count';
  end if;
  if not (v_claim->'report'->'evidence'->'sales' ? 'growth') then
    raise exception 'the evidence pack does not carry period-over-period growth';
  end if;

  v_claim_again:=public.internal_claim_ai_firm_report_v176();
  if coalesce((v_claim_again->>'claimed')::boolean,false)
     and (v_claim_again->'report'->>'id')::uuid=v_report then
    raise exception 'the same report was claimed twice';
  end if;

  ----------------------------------------------------------------------------
  -- 6. Completion stores the narrative and flips the status.
  ----------------------------------------------------------------------------
  -- A succeeded completion with no narrative must be refused.
  begin
    perform public.internal_complete_ai_firm_report_v176(
      v_report,'succeeded',null,null,'claude-sonnet-5'
    );
    raise exception 'a succeeded completion was accepted without a narrative';
  exception when sqlstate '22023' then null;
  end;

  v_result:=public.internal_complete_ai_firm_report_v176(
    v_report,'succeeded',v_narrative,null,'claude-sonnet-5'
  );
  if v_result->>'status'<>'succeeded' then
    raise exception 'completion did not flip the status: %',v_result;
  end if;
  select * into v_row from public.ai_firm_reports_v176 where id=v_report;
  if v_row.narrative_md<>v_narrative then
    raise exception 'the stored narrative does not match what was submitted';
  end if;
  if v_row.completed_at is null or v_row.error is not null then
    raise exception 'completion did not record completed_at / clear the error';
  end if;

  -- A completed report can no longer be completed again.
  begin
    perform public.internal_complete_ai_firm_report_v176(
      v_report,'failed',null,'late failure','claude-sonnet-5'
    );
    raise exception 'a completed report was completed a second time';
  exception when sqlstate '22023' then null;
  end;

  -- A failure path stores the reason and leaves no narrative behind. The
  -- second fixture row may already have been claimed by the SKIP LOCKED
  -- assertion above, so move it to `generating` only if it is still pending.
  select id into v_second_report
  from public.ai_firm_reports_v176
  where business_id=v_live and period_kind='monthly'
    and period_start=v_second_period;
  if v_second_report is null then
    raise exception 'the enqueued second fixture report disappeared';
  end if;
  update public.ai_firm_reports_v176
  set status='generating',claimed_at=now()
  where id=v_second_report and status='pending';
  v_result:=public.internal_complete_ai_firm_report_v176(
    v_second_report,'failed',null,'anthropic_529: overloaded',null
  );
  if v_result->>'status'<>'failed'
     or v_result->>'error'<>'anthropic_529: overloaded'
     or v_result->>'narrative_md' is not null then
    raise exception 'the failure path did not store cleanly: %',v_result;
  end if;

  ----------------------------------------------------------------------------
  -- 7. List RPC.
  ----------------------------------------------------------------------------
  perform pg_temp.as_v176_user(v_sa);
  v_result:=public.platform_list_ai_firm_reports_v176(v_live,12);
  reset role;
  if jsonb_array_length(v_result->'reports')<2 then
    raise exception 'the super admin does not see both fixture reports: %',v_result;
  end if;
  if exists(
    select 1 from jsonb_array_elements(v_result->'reports') report
    where report ? 'evidence'
  ) then raise exception 'the list RPC leaked the evidence pack to the browser'; end if;

  begin
    perform pg_temp.as_v176_user(v_outsider);
    perform public.platform_list_ai_firm_reports_v176(v_live,12);
    reset role;
    raise exception 'an outsider was able to list AI firm reports';
  exception when insufficient_privilege or sqlstate '42501' then reset role;
  end;

  begin
    perform pg_temp.as_v176_user(v_sa);
    perform public.platform_list_ai_firm_reports_v176(v_live,0);
    reset role;
    raise exception 'an out-of-range list limit was accepted';
  exception when sqlstate '22023' then reset role;
  end;

  raise notice 'v176 AI firm reports: all assertions passed';
end
$v176$;

rollback;
