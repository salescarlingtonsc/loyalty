-- NESTLY v174 — SME pipeline: Site Visit + Quotation Sent stages, and a
-- super-admin-only demo-firm flag excluded from billing/revenue rollups.
-- Local review candidate. No production application or deployment is authorized.
--
-- Feature A: the owner's real sales flow is lead -> appointment set -> site
-- visit -> quotation sent -> won/onboarded. The v76/v86 17-stage board has no
-- room for the site-visit and quotation steps that sit between "Meeting Link
-- Sent / Calendar Set" and "Pending Decision". This adds two stages:
--   site_visit       — Contact & meeting lane, after the existing meeting stages.
--   quotation_sent    — Decision lane, before Pending Decision.
--
-- Feature B: public.businesses.is_demo marks a firm as a sales/live-demo
-- tenant. Unlike is_synthetic (v66/v92, fully hidden from every enterprise
-- reader), a demo firm must remain VISIBLE in the Firms directory with a
-- badge and filter — it is a real, presentable tenant, just one that must
-- never inflate billing exceptions, the daily subscription-lifecycle scan or
-- platform revenue/aggregate rollups. Only a super admin may set it, via a
-- SECURITY DEFINER RPC (public.businesses has no owner-writable UPDATE policy
-- at all, so this is already the only write path).

begin;

-- ---------------------------------------------------------------------------
-- Feature A.1 — pipeline stage seeds.
--
-- sme_pipeline_stages.sort_order is unique and checked between 1 and 17. To
-- insert two new stages between meeting_sent(11) and pending_decision(12) we
-- widen the check first, then shift pending_decision..lost up by two slots
-- (highest sort_order first, so every UPDATE target is vacated before it is
-- claimed, so the unique constraint never sees a transient collision), then
-- insert the two new rows. Every step is idempotent: if a rerun finds the
-- rows already at their target sort_order, the UPDATE is a no-op, and the
-- INSERTs are ON CONFLICT DO NOTHING.
-- ---------------------------------------------------------------------------

alter table public.sme_pipeline_stages
  drop constraint if exists sme_pipeline_stages_sort_order_check;
alter table public.sme_pipeline_stages
  add constraint sme_pipeline_stages_sort_order_check
  check (sort_order between 1 and 19);

update public.sme_pipeline_stages set sort_order=19 where stage_key='lost' and sort_order<>19;
update public.sme_pipeline_stages set sort_order=18 where stage_key='activated' and sort_order<>18;
update public.sme_pipeline_stages set sort_order=17 where stage_key='onboarding' and sort_order<>17;
update public.sme_pipeline_stages set sort_order=16 where stage_key='account_created' and sort_order<>16;
update public.sme_pipeline_stages set sort_order=15 where stage_key='client' and sort_order<>15;
update public.sme_pipeline_stages set sort_order=14 where stage_key='pending_decision' and sort_order<>14;

insert into public.sme_pipeline_stages(stage_key,label,sort_order) values
  ('site_visit','Site Visit',12),
  ('quotation_sent','Quotation Sent',13)
on conflict (stage_key) do nothing;

-- ---------------------------------------------------------------------------
-- Feature A.2 — v86 stage-entry requirement catalogue for the two new stages.
-- site_visit: visit date/owner and outcome notes. quotation_sent: quotation
-- amount, sent date and next follow-up. Both are plain AND-required key
-- lists (no OR-alternatives), so app.validate_stage_entry_v86's generic
-- required_keys walk already enforces them; no extra elsif branch is needed
-- there (unlike meeting_sent/pending_decision/npu_*, whose requirements are
-- expressed as an OR of two keys).
-- ---------------------------------------------------------------------------

insert into public.sme_stage_entry_requirements(
  stage_key,required_keys,system_managed,terminal_confirmation,description
) values
  ('site_visit',array['visit_at','visit_owner','outcome_notes'],false,false,
    'Site visit date, responsible owner and outcome notes'),
  ('quotation_sent',array['quotation_amount_cents','sent_at','next_follow_up_at'],false,false,
    'Quotation amount, sent date and next follow-up')
on conflict (stage_key) do nothing;

-- ---------------------------------------------------------------------------
-- Feature A.3 — patch app.platform_firm_rows_v88 (the single private row
-- source behind the Firms directory and Onboarding board):
--   (a) widen the lane CASE so site_visit joins 'contacting' and
--       quotation_sent joins 'decision' alongside pending_decision;
--   (b) add an `is_demo` output column so the console can badge/filter demo
--       firms without a second reader. Adding an output column to a table
--       function is a signature change, so this drops and recreates it.
--       Every downstream consumer (app.ensure_platform_firm_snapshot_v88)
--       reads columns by name (`firm.updated_at`, `to_jsonb(firm)`, ...), so
--       the extra trailing column is additive and safe.
--   (c) demo firms are NOT filtered out here — the directory must keep
--       showing them so they can be badged/filtered in the UI, unlike
--       is_synthetic rows which v92 already hides everywhere.
-- ---------------------------------------------------------------------------

-- The is_demo column must exist before the firm-rows recreate below references
-- it (language sql bodies are parse-checked at CREATE time).
alter table public.businesses add column if not exists is_demo boolean not null default false;

drop function if exists app.platform_firm_rows_v88(timestamptz);

create function app.platform_firm_rows_v88(p_snapshot_at timestamptz)
returns table(
  row_id uuid,
  business_id uuid,
  prospect_id uuid,
  company_id uuid,
  name text,
  legal_name text,
  registration_number text,
  sector_key text,
  industry text,
  sector_assignment_version bigint,
  sector_bundle_version_id uuid,
  boss_name text,
  boss_email text,
  boss_phone text,
  source_type text,
  source_stage_key text,
  lane_key text,
  lane_label text,
  lane_sort_order smallint,
  onboarding_status text,
  onboarding_started_at timestamptz,
  activated_at timestamptz,
  last_activity_at timestamptz,
  days_unattended integer,
  attention_severity text,
  attention_due boolean,
  attention_reason text,
  next_action_at timestamptz,
  assigned_consultant_id uuid,
  updated_at timestamptz,
  branch_count integer,
  staff_count integer,
  customer_count integer,
  subscription_status text,
  is_demo boolean
)
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  with prospect_anchors as (
    select
      prospect.id as row_id,
      business.id as business_id,
      prospect.id as prospect_id,
      company.id as company_id,
      coalesce(business.name,company.trading_name,company.legal_name) as name,
      coalesce(business.legal_name,company.legal_name) as legal_name,
      coalesce(business.registration_number,company.registration_number) as registration_number,
      coalesce(company.sector_key,business.industry,company.industry,'other') as industry,
      company.email as company_email,
      company.phone as company_phone,
      prospect.current_stage_key as source_stage_key,
      prospect.next_action_at,
      prospect.assigned_consultant_id,
      prospect.created_at as anchor_created_at,
      prospect.updated_at as anchor_updated_at,
      business.onboarding_started_at,
      business.activated_at,
      coalesce(business.is_demo,false) as is_demo
    from public.sme_prospects prospect
    join public.sme_companies company on company.id=prospect.company_id
    left join lateral (
      select candidate.*
      from public.businesses candidate
      where candidate.id=prospect.converted_business_id
         or candidate.source_prospect_id=prospect.id
      order by case when candidate.id=prospect.converted_business_id then 0 else 1 end,
        candidate.created_at,candidate.id
      limit 1
    ) business on true
    where prospect.created_at <= p_snapshot_at
      and (business.id is null or business.is_synthetic = false)
  ), business_anchors as (
    select
      business.id as row_id,
      business.id as business_id,
      null::uuid as prospect_id,
      null::uuid as company_id,
      business.name,
      business.legal_name,
      business.registration_number,
      coalesce(business.industry,'other') as industry,
      null::text as company_email,
      null::text as company_phone,
      null::text as source_stage_key,
      null::timestamptz as next_action_at,
      null::uuid as assigned_consultant_id,
      business.created_at as anchor_created_at,
      business.created_at as anchor_updated_at,
      business.onboarding_started_at,
      business.activated_at,
      business.is_demo
    from public.businesses business
    where business.is_synthetic=false and business.created_at<=p_snapshot_at
      and not exists(
        select 1
        from public.sme_prospects prospect
        where prospect.converted_business_id=business.id
           or prospect.id=business.source_prospect_id
      )
  ), anchors as (
    select * from prospect_anchors
    union all
    select * from business_anchors
  ), enriched as (
    select
      anchor.*,
      coalesce(bundle.sector_key,anchor.industry,'other') as resolved_sector_key,
      assignment.version as resolved_sector_assignment_version,
      assignment.bundle_version_id as resolved_sector_bundle_version_id,
      coalesce(owner_staff.full_name,configured_owner.full_name,primary_contact.full_name) as resolved_boss_name,
      coalesce(owner_staff.account_email,configuration.owner_email,configured_owner.email,
        primary_contact.email,latest_invitation.owner_email,latest_terms.owner_email,
        anchor.company_email) as resolved_boss_email,
      coalesce(owner_staff.account_phone,configuration.owner_phone,configured_owner.phone,
        primary_contact.phone,anchor.company_phone) as resolved_boss_phone,
      coalesce(source.source_type,case when anchor.prospect_id is null then
        case when exists(
          select 1 from public.audit_log audit
          where audit.business_id=anchor.business_id and audit.action='ONBOARD'
        ) then 'website' else 'existing_business' end
        else 'manual' end) as resolved_source_type,
      case
        when anchor.business_id is not null then 'case_won'
        when anchor.source_stage_key is null or anchor.source_stage_key='new_lead' then 'inbox'
        when anchor.source_stage_key in (
          'appt_set','npu_1','npu_2','npu_3','npu_4','npu_5','npu_6',
          'call_back','reschedule','meeting_sent','site_visit'
        ) then 'contacting'
        when anchor.source_stage_key in ('quotation_sent','pending_decision') then 'decision'
        when anchor.source_stage_key in ('client','account_created','onboarding','activated')
          then 'case_won'
        when anchor.source_stage_key='lost' then 'closed'
        else 'inbox'
      end as resolved_lane_key,
      checklist.status as checklist_status,
      subscription.status as resolved_subscription_status,
      activity.last_activity_at as resolved_last_activity_at,
      least(anchor.anchor_updated_at,p_snapshot_at) as resolved_updated_at,
      (select count(*)::integer from public.branches branch
        where branch.business_id=anchor.business_id) as resolved_branch_count,
      (select count(*)::integer from public.staff staff_row
        where staff_row.business_id=anchor.business_id) as resolved_staff_count,
      (select count(*)::integer from public.clients customer
        where customer.business_id=anchor.business_id) as resolved_customer_count
    from anchors anchor
    left join public.business_sector_assignments assignment
      on assignment.business_id=anchor.business_id
    left join public.sector_bundle_versions bundle
      on bundle.id=assignment.bundle_version_id
    left join public.business_onboarding_checklists checklist
      on checklist.business_id=anchor.business_id
    left join lateral (
      select subscription_row.status
      from public.subscriptions subscription_row
      where subscription_row.business_id=anchor.business_id
      order by subscription_row.next_payment_at desc nulls last,
        subscription_row.last_paid_at desc nulls last
      limit 1
    ) subscription on true
    left join lateral (
      select staff_row.full_name,
        nullif(account.email,'') as account_email,
        nullif(account.phone,'') as account_phone
      from public.staff staff_row
      left join auth.users account on account.id=staff_row.user_id
      where staff_row.business_id=anchor.business_id and staff_row.role='owner'
      order by staff_row.active desc,(staff_row.user_id is not null) desc,
        staff_row.created_at,staff_row.id
      limit 1
    ) owner_staff on true
    left join lateral (
      select config.*
      from public.sme_conversion_configuration_versions config
      where config.prospect_id=anchor.prospect_id and config.created_at<=p_snapshot_at
      order by config.version desc limit 1
    ) configuration on true
    left join public.sme_prospect_contacts configured_owner
      on configured_owner.id=configuration.primary_owner_contact_id
    left join lateral (
      select contact.*
      from public.sme_prospect_contacts contact
      where contact.prospect_id=anchor.prospect_id and contact.active
      order by contact.is_primary desc,contact.created_at,contact.id
      limit 1
    ) primary_contact on true
    left join lateral (
      select invitation.owner_email
      from public.workspace_owner_invitations invitation
      where invitation.business_id=anchor.business_id
      order by invitation.version desc limit 1
    ) latest_invitation on true
    left join lateral (
      select terms.owner_email
      from public.sme_commercial_terms terms
      where terms.prospect_id=anchor.prospect_id
      order by terms.version desc limit 1
    ) latest_terms on true
    left join lateral (
      select lineage.source_type
      from public.sme_prospect_source_lineage lineage
      where lineage.prospect_id=anchor.prospect_id and lineage.created_at<=p_snapshot_at
      order by lineage.created_at,lineage.id limit 1
    ) source on true
    left join lateral (
      select max(moment) as last_activity_at
      from (
        select anchor.anchor_created_at as moment
        union all select anchor.anchor_updated_at
        union all select prospect_activity.occurred_at
          from public.sme_prospect_activities prospect_activity
          where prospect_activity.prospect_id=anchor.prospect_id
        union all select history.occurred_at
          from public.sme_prospect_stage_history history
          where history.prospect_id=anchor.prospect_id
        union all select onboarding_event.created_at
          from public.business_onboarding_events onboarding_event
          where onboarding_event.business_id=anchor.business_id
        union all select audit.created_at
          from public.audit_log audit
          where audit.business_id=anchor.business_id
      ) moments
      where moment<=p_snapshot_at
    ) activity on true
  ), aged as (
    select enriched.*,
      greatest(0,floor(extract(epoch from
        (p_snapshot_at-enriched.resolved_last_activity_at))/86400))::integer
        as resolved_days_unattended
    from enriched
  )
  select
    aged.row_id,
    aged.business_id,
    aged.prospect_id,
    aged.company_id,
    aged.name,
    aged.legal_name,
    aged.registration_number,
    aged.resolved_sector_key as sector_key,
    aged.industry,
    aged.resolved_sector_assignment_version as sector_assignment_version,
    aged.resolved_sector_bundle_version_id as sector_bundle_version_id,
    aged.resolved_boss_name as boss_name,
    aged.resolved_boss_email as boss_email,
    aged.resolved_boss_phone as boss_phone,
    aged.resolved_source_type as source_type,
    aged.source_stage_key,
    aged.resolved_lane_key as lane_key,
    case aged.resolved_lane_key
      when 'inbox' then 'Inbox'
      when 'contacting' then 'Contacting'
      when 'decision' then 'Decision'
      when 'case_won' then 'Case won'
      else 'Closed'
    end as lane_label,
    case aged.resolved_lane_key
      when 'inbox' then 1 when 'contacting' then 2 when 'decision' then 3
      when 'case_won' then 4 else 5
    end::smallint as lane_sort_order,
    coalesce(aged.checklist_status,
      case
        when aged.activated_at is not null then 'activated'
        when aged.onboarding_started_at is not null then 'in_progress'
        when aged.business_id is not null then 'not_started'
      end) as onboarding_status,
    aged.onboarding_started_at,
    aged.activated_at,
    aged.resolved_last_activity_at as last_activity_at,
    aged.resolved_days_unattended as days_unattended,
    case
      when aged.resolved_lane_key in ('case_won','closed') then 'none'
      when aged.next_action_at<p_snapshot_at-interval '7 days' then 'critical'
      when aged.resolved_days_unattended>=14 then 'critical'
      when aged.next_action_at<p_snapshot_at then 'warning'
      when aged.resolved_days_unattended>=7 then 'warning'
      when aged.resolved_days_unattended>=3 then 'info'
      else 'none'
    end as attention_severity,
    coalesce(aged.resolved_lane_key not in ('case_won','closed') and (
      aged.next_action_at<p_snapshot_at or aged.resolved_days_unattended>=7
    ),false) as attention_due,
    case
      when aged.resolved_lane_key in ('case_won','closed') then null
      when aged.next_action_at<p_snapshot_at and aged.resolved_days_unattended>=7
        then 'next_action_overdue_and_stale'
      when aged.next_action_at<p_snapshot_at then 'next_action_overdue'
      when aged.resolved_days_unattended>=7 then 'stale_activity'
      when aged.resolved_days_unattended>=3 then 'approaching_stale'
      else null
    end as attention_reason,
    aged.next_action_at,
    aged.assigned_consultant_id,
    aged.resolved_updated_at as updated_at,
    coalesce(aged.resolved_branch_count,0) as branch_count,
    coalesce(aged.resolved_staff_count,0) as staff_count,
    coalesce(aged.resolved_customer_count,0) as customer_count,
    coalesce(aged.resolved_subscription_status,'none') as subscription_status,
    coalesce(aged.is_demo,false) as is_demo
  from aged
$$;

revoke all on function app.platform_firm_rows_v88(timestamptz)
  from public,anon,authenticated;
comment on function app.platform_firm_rows_v88(timestamptz)
  is 'v174: real-firm-only platform onboarding source; attention_due is always boolean; site_visit/quotation_sent lanes; is_demo output column.';

-- ---------------------------------------------------------------------------
-- Feature B.1 — is_demo column. Plain boolean, no RLS write path of its own:
-- public.businesses carries no owner-writable UPDATE policy (confirmed: the
-- only prior column of this shape, is_synthetic, is likewise unwritable
-- except through a SECURITY DEFINER RPC + trigger guard). The RPC below is
-- the sole write path; a stolen owner session cannot flip its own flag.
-- ---------------------------------------------------------------------------

-- (is_demo column itself was added above, before the firm-rows recreate.)

create table if not exists public.business_demo_flag_audit_v174(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  actor uuid references auth.users(id) on delete set null,
  prior_is_demo boolean not null,
  new_is_demo boolean not null,
  reason text,
  created_at timestamptz not null default now()
);
create index if not exists business_demo_flag_audit_v174_business_idx
  on public.business_demo_flag_audit_v174(business_id,created_at desc);
alter table public.business_demo_flag_audit_v174 enable row level security;
revoke all privileges on table public.business_demo_flag_audit_v174
  from public,anon,authenticated;
create policy business_demo_flag_audit_v174_sa_read
  on public.business_demo_flag_audit_v174 for select to authenticated
  using (app.is_super_admin());

create or replace function public.set_business_demo_flag_v174(
  p_business uuid,p_is_demo boolean,p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_actor uuid:=auth.uid();v_prior boolean;
begin
  if not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode='42501';
  end if;
  if p_business is null or p_is_demo is null then
    raise exception 'business and is_demo are required' using errcode='22023';
  end if;
  select is_demo into v_prior from public.businesses where id=p_business for update;
  if not found then raise exception 'business_not_found' using errcode='22023';end if;
  if v_prior=p_is_demo then
    return jsonb_build_object('business_id',p_business,'is_demo',p_is_demo,'changed',false);
  end if;
  update public.businesses set is_demo=p_is_demo where id=p_business;
  insert into public.business_demo_flag_audit_v174(
    business_id,actor,prior_is_demo,new_is_demo,reason
  ) values(p_business,v_actor,v_prior,p_is_demo,nullif(btrim(coalesce(p_reason,'')),''));
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,v_actor,
    case when p_is_demo then 'BUSINESS_MARKED_DEMO_V174' else 'BUSINESS_UNMARKED_DEMO_V174' end,
    'businesses',p_business,jsonb_build_object('is_demo',p_is_demo,'reason',p_reason));
  return jsonb_build_object('business_id',p_business,'is_demo',p_is_demo,'changed',true);
end
$$;
revoke all on function public.set_business_demo_flag_v174(uuid,boolean,text)
  from public,anon,authenticated;
grant execute on function public.set_business_demo_flag_v174(uuid,boolean,text) to authenticated;

-- ---------------------------------------------------------------------------
-- Feature B.2 — exclude demo firms from the v94 daily subscription-lifecycle
-- scan (past-due detection, notice creation and the day-14 workspace pause).
-- A demo tenant is never really billed; it must not accumulate billing
-- notices or get its workspace paused by the automatic job. Firms directory
-- visibility (B.1/A.3) is a separate concern and is untouched here.
-- ---------------------------------------------------------------------------

create or replace function app.run_subscription_lifecycle_v94(p_as_of date)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_run public.subscription_lifecycle_runs_v94%rowtype;
  v_business record;v_day integer;v_notice_day integer;v_created integer:=0;
  v_paused integer:=0;v_recovered integer:=0;v_evaluated integer:=0;
  v_prior public.business_subscription_lifecycle_v94%rowtype;
  v_rep record;v_summary jsonb;v_notice_id uuid;
begin
  if p_as_of is null then raise exception 'run_date_required' using errcode='22023';end if;
  perform pg_advisory_xact_lock(hashtextextended('v94:subscription:'||p_as_of::text,0));
  select * into v_run from public.subscription_lifecycle_runs_v94
  where run_date=p_as_of;
  if found and v_run.status='succeeded' then
    return v_run.summary||jsonb_build_object('replayed',true);
  elsif found then
    delete from public.subscription_lifecycle_runs_v94 where run_date=p_as_of;
  end if;
  insert into public.subscription_lifecycle_runs_v94(run_date,status)
  values(p_as_of,'running');

  for v_business in
    with overdue as (
      select distinct on(invoice.business_id)
        invoice.business_id,invoice.provider_invoice_id,
        (invoice.due_at at time zone 'Asia/Singapore')::date due_date
      from public.billing_provider_invoices invoice
      where invoice.paid_normalized=false
        and invoice.status in ('open','uncollectible')
        and invoice.amount_remaining_cents>0
        and invoice.due_at is not null
        and (invoice.due_at at time zone 'Asia/Singapore')::date<=p_as_of
      order by invoice.business_id,invoice.due_at,invoice.id
    )
    select business.id business_id,overdue.provider_invoice_id,overdue.due_date
    from public.businesses business
    left join overdue on overdue.business_id=business.id
    where business.is_demo=false
    order by business.id
  loop
    v_evaluated:=v_evaluated+1;
    select * into v_prior
    from public.business_subscription_lifecycle_v94 lifecycle
    where lifecycle.business_id=v_business.business_id for update;
    if v_business.provider_invoice_id is null then
      if v_prior.state<>'current' then
        update public.business_subscription_lifecycle_v94
        set state='current',provider_invoice_id=null,due_date=null,
          overdue_day=null,workspace_paused=false,paused_at=null,
          recovered_at=now(),last_evaluated_on=p_as_of,
          version=version+1,updated_at=now()
        where business_id=v_business.business_id;
        insert into public.business_subscription_lifecycle_audit_v94(
          business_id,event_type,prior_state,new_state,actor,reason
        ) values(
          v_business.business_id,'payment_recovered',v_prior.state,'current',
          auth.uid(),'provider invoice no longer overdue'
        );
        v_recovered:=v_recovered+1;
      else
        update public.business_subscription_lifecycle_v94
        set last_evaluated_on=p_as_of,updated_at=now()
        where business_id=v_business.business_id;
      end if;
      continue;
    end if;
    v_day:=p_as_of-v_business.due_date;
    select * into v_rep from app.assigned_consultant_v94(v_business.business_id);
    -- One run creates only the currently actionable notice. A missed cron does
    -- not flood the bell with every historic day; normal daily runs still
    -- produce one notice per day, and 14 is the distinct pause notice.
    v_notice_day:=least(v_day,14);
    if v_notice_day>=0 then
      v_notice_id:=null;
      insert into public.business_billing_due_notices_v94(
        business_id,provider_invoice_id,due_date,due_day,
        notice_title,notice_body,consultant_id,representative_name,hotline_phone
      ) values(
        v_business.business_id,v_business.provider_invoice_id,
        v_business.due_date,v_notice_day,
        case when v_notice_day=0 then 'Subscription payment is due'
          when v_notice_day=14 then 'Workspace paused — payment overdue'
          else 'Subscription payment is overdue' end,
        case when v_rep.hotline_phone is null
          then case when v_notice_day=14
            then 'Your workspace is paused. Update billing to restore access.'
            else format('Payment is %s day(s) overdue. Update billing to avoid a day-14 workspace pause.',v_notice_day)
          end
          else format('Payment is %s day(s) overdue. Update billing or contact %s at %s.',v_notice_day,coalesce(v_rep.display_name,'your Nestly representative'),v_rep.hotline_phone)
        end,
        v_rep.consultant_id,v_rep.display_name,v_rep.hotline_phone
      ) on conflict(provider_invoice_id,due_day) do nothing
      returning id into v_notice_id;
      if v_notice_id is not null then
        v_created:=v_created+1;
        insert into public.notifications(
          business_id,kind,title,body,ref_table,ref_id
        ) values(
          v_business.business_id,'subscription_payment_due',
          case when v_notice_day=0 then 'Subscription payment is due'
            when v_notice_day=14 then 'Workspace paused — payment overdue'
            else 'Subscription payment is overdue' end,
          case when v_rep.hotline_phone is null
            then case when v_notice_day=14
              then 'Your workspace is paused. Update billing to restore access.'
              else format('Payment is %s day(s) overdue. Update billing to avoid a day-14 workspace pause.',v_notice_day)
            end
            else format('Payment is %s day(s) overdue. Update billing or contact %s at %s.',v_notice_day,coalesce(v_rep.display_name,'your Nestly representative'),v_rep.hotline_phone)
          end,
          'business_billing_due_notices_v94',v_notice_id
        );
      end if;
    end if;
    if v_day>=14 then
      update public.business_subscription_lifecycle_v94
      set state='paused',provider_invoice_id=v_business.provider_invoice_id,
        due_date=v_business.due_date,overdue_day=v_day,workspace_paused=true,
        paused_at=coalesce(paused_at,now()),last_evaluated_on=p_as_of,
        version=version+1,updated_at=now()
      where business_id=v_business.business_id
        and (state<>'paused' or provider_invoice_id is distinct from v_business.provider_invoice_id
          or overdue_day is distinct from v_day);
      if v_prior.state<>'paused' then
        insert into public.business_subscription_lifecycle_audit_v94(
          business_id,event_type,provider_invoice_id,prior_state,new_state,
          overdue_day,reason
        ) values(
          v_business.business_id,'workspace_paused',
          v_business.provider_invoice_id,v_prior.state,'paused',v_day,
          'automatic day-14 overdue subscription pause'
        );
        v_paused:=v_paused+1;
      end if;
    else
      update public.business_subscription_lifecycle_v94
      set state='grace',provider_invoice_id=v_business.provider_invoice_id,
        due_date=v_business.due_date,overdue_day=v_day,
        workspace_paused=false,paused_at=null,last_evaluated_on=p_as_of,
        version=case when state is distinct from 'grace'
          or provider_invoice_id is distinct from v_business.provider_invoice_id
          then version+1 else version end,
        updated_at=now()
      where business_id=v_business.business_id;
      if v_prior.state='current' then
        insert into public.business_subscription_lifecycle_audit_v94(
          business_id,event_type,provider_invoice_id,prior_state,new_state,
          overdue_day,reason
        ) values(
          v_business.business_id,'grace_started',
          v_business.provider_invoice_id,'current','grace',v_day,
          'subscription invoice reached its due date'
        );
      end if;
    end if;
  end loop;
  v_summary:=jsonb_build_object(
    'run_date',p_as_of,'businesses_evaluated',v_evaluated,
    'notices_created',v_created,'paused',v_paused,'recovered',v_recovered,
    'replayed',false
  );
  update public.subscription_lifecycle_runs_v94
  set status='succeeded',finished_at=now(),summary=v_summary
  where run_date=p_as_of;
  return v_summary;
exception when others then
  update public.subscription_lifecycle_runs_v94
  set status='failed',finished_at=now(),
    summary=jsonb_build_object('run_date',p_as_of,'error',sqlerrm)
  where run_date=p_as_of;
  raise;
end
$$;
revoke all on function app.run_subscription_lifecycle_v94(date)
  from public,anon,authenticated;

-- ---------------------------------------------------------------------------
-- Feature B.3 — exclude demo firms from platform-level revenue/aggregate
-- report RPCs used by the superadmin console: the three v82 enterprise
-- readers (already patched by v92 to exclude is_synthetic; this widens the
-- same anchor to also exclude is_demo, using the same pg_get_functiondef +
-- assert-then-replace idiom v92 established) and the v89 billing-rows
-- reader that backs get_platform_billing_v77 / platform_get_billing_v89 /
-- platform_get_billing_v125 — the exact data source for the "Billing
-- exception queue" card and the Billing/Reports revenue totals.
-- ---------------------------------------------------------------------------

do $v174_enterprise$
declare
  v_signature regprocedure;
  v_definition text;
  v_needle constant text :=
    'where business.is_synthetic=false and business.created_at<=v_snapshot_at';
  v_replacement constant text :=
    'where business.is_synthetic=false and business.is_demo=false and business.created_at<=v_snapshot_at';
  v_occurrences integer;
begin
  foreach v_signature in array array[
    'public.platform_get_enterprise_hierarchy_v82(text,uuid[],uuid,date,date,text,integer,timestamptz,timestamptz,uuid)'::regprocedure,
    'public.platform_list_enterprise_customers_v82(text,uuid[],uuid,date,date,text,integer,timestamptz,timestamptz,uuid)'::regprocedure,
    'public.platform_generate_improvement_report_v82(text,uuid[],uuid,date,date,text,timestamptz)'::regprocedure
  ] loop
    v_definition:=pg_get_functiondef(v_signature);
    v_occurrences:=(length(v_definition)-length(replace(v_definition,v_needle,'')))
      /length(v_needle);
    if v_occurrences<>1 then
      raise exception 'v174 expected one v92-patched enterprise anchor in %, found %',
        v_signature,v_occurrences using errcode='55000';
    end if;
    execute replace(v_definition,v_needle,v_replacement);
  end loop;
end
$v174_enterprise$;

do $v174_billing_rows$
declare
  v_signature regprocedure := 'app.v89_platform_billing_rows(uuid,integer)'::regprocedure;
  v_definition text := pg_get_functiondef(v_signature);
  v_needle constant text :=
    'where p_business is null or subscription.business_id=p_business';
  v_replacement constant text :=
    'where (p_business is null or subscription.business_id=p_business) and business.is_demo=false';
  v_occurrences integer;
begin
  v_occurrences:=(length(v_definition)-length(replace(v_definition,v_needle,'')))
    /length(v_needle);
  if v_occurrences<>1 then
    raise exception 'v174 expected one v89 billing-rows business anchor, found %',
      v_occurrences using errcode='55000';
  end if;
  execute replace(v_definition,v_needle,v_replacement);
end
$v174_billing_rows$;

do $v174_billing_v77$
declare
  v_signature regprocedure := 'public.get_platform_billing_v77(uuid,integer)'::regprocedure;
  v_definition text := pg_get_functiondef(v_signature);
  v_needle constant text := 'where p_business is null or s.business_id=p_business';
  v_replacement constant text :=
    'where (p_business is null or s.business_id=p_business) and b.is_demo=false';
  v_occurrences integer;
begin
  v_occurrences:=(length(v_definition)-length(replace(v_definition,v_needle,'')))
    /length(v_needle);
  if v_occurrences<>1 then
    raise exception 'v174 expected one v77 billing business anchor, found %',
      v_occurrences using errcode='55000';
  end if;
  execute replace(v_definition,v_needle,v_replacement);
end
$v174_billing_v77$;

commit;
