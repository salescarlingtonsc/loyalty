-- NESTLY v88 — unified platform firm onboarding directory and stale-attention reader.
-- Local review candidate only. No production application or deployment is authorized.

begin;

create index if not exists sme_prospects_v88_updated_cursor_idx
  on public.sme_prospects(updated_at desc,id desc);
create index if not exists businesses_v88_created_cursor_idx
  on public.businesses(created_at desc,id desc);
create index if not exists staff_v88_owner_lookup_idx
  on public.staff(business_id,role,active desc,created_at,id);

-- Private row source. It unifies the prospect pipeline with self-service/legacy
-- businesses, and excludes the business half whenever either v79 conversion link
-- points at the same prospect.
create or replace function app.platform_firm_rows_v88(p_snapshot_at timestamptz)
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
  subscription_status text
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
      business.activated_at
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
    where prospect.created_at<=p_snapshot_at
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
      business.activated_at
    from public.businesses business
    where business.created_at<=p_snapshot_at
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
          'call_back','reschedule','meeting_sent'
        ) then 'contacting'
        when anchor.source_stage_key='pending_decision' then 'decision'
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
    aged.resolved_lane_key not in ('case_won','closed') and (
      aged.next_action_at<p_snapshot_at or aged.resolved_days_unattended>=7
    ) as attention_due,
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
    coalesce(aged.resolved_subscription_status,'none') as subscription_status
  from aged
$$;

revoke all on function app.platform_firm_rows_v88(timestamptz)
  from public,anon,authenticated;

-- A timestamp alone is not a database snapshot token: all of the CRM, billing,
-- contact and onboarding projections above are mutable. Capture the complete
-- row projection on the first page and serve every later page from those frozen
-- bytes. Expired tokens fail closed instead of silently rebuilding against new
-- data and changing membership/order/content midway through pagination.
create table app.platform_firm_snapshots_v88(
  actor_id uuid not null references auth.users(id) on delete cascade,
  snapshot_at timestamptz not null,
  captured_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null default clock_timestamp()+interval '24 hours',
  primary key(actor_id,snapshot_at),
  check(expires_at>captured_at)
);

create table app.platform_firm_snapshot_rows_v88(
  actor_id uuid not null,
  snapshot_at timestamptz not null,
  row_id uuid not null,
  updated_at timestamptz not null,
  days_unattended integer not null,
  attention_due boolean not null,
  attention_severity text not null,
  lane_key text not null,
  sector_key text,
  industry text,
  onboarding_status text,
  subscription_status text not null,
  search_text text not null,
  payload jsonb not null check(jsonb_typeof(payload)='object'),
  primary key(actor_id,snapshot_at,row_id),
  foreign key(actor_id,snapshot_at)
    references app.platform_firm_snapshots_v88(actor_id,snapshot_at) on delete cascade
);
create index platform_firm_snapshot_rows_v88_cursor_idx
  on app.platform_firm_snapshot_rows_v88(
    actor_id,snapshot_at,updated_at desc,row_id desc
  );
create index platform_firm_snapshot_rows_v88_attention_idx
  on app.platform_firm_snapshot_rows_v88(
    actor_id,snapshot_at,days_unattended desc,row_id desc
  ) where attention_due;

revoke all privileges on table app.platform_firm_snapshots_v88
  from public,anon,authenticated;
revoke all privileges on table app.platform_firm_snapshot_rows_v88
  from public,anon,authenticated;

create or replace function app.ensure_platform_firm_snapshot_v88(
  p_actor uuid,
  p_snapshot_at timestamptz,
  p_allow_create boolean
)
returns timestamptz
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_expires_at timestamptz;
  v_created boolean:=false;
begin
  if p_actor is null or p_snapshot_at is null then
    raise exception 'actor and snapshot token are required' using errcode='22023';
  end if;

  select snapshot.expires_at into v_expires_at
  from app.platform_firm_snapshots_v88 snapshot
  where snapshot.actor_id=p_actor and snapshot.snapshot_at=p_snapshot_at;
  if found then
    if v_expires_at<=clock_timestamp() then
      raise exception 'firm snapshot token has expired' using errcode='22023';
    end if;
    return v_expires_at;
  end if;
  if not p_allow_create then
    raise exception 'firm snapshot token was not found' using errcode='22023';
  end if;

  delete from app.platform_firm_snapshots_v88 snapshot
  where snapshot.actor_id=p_actor and snapshot.expires_at<=clock_timestamp();

  insert into app.platform_firm_snapshots_v88(actor_id,snapshot_at)
  values(p_actor,p_snapshot_at)
  on conflict(actor_id,snapshot_at) do nothing
  returning expires_at into v_expires_at;
  v_created:=found;

  if v_created then
    insert into app.platform_firm_snapshot_rows_v88(
      actor_id,snapshot_at,row_id,updated_at,days_unattended,
      attention_due,attention_severity,lane_key,sector_key,industry,
      onboarding_status,subscription_status,search_text,payload
    )
    select
      p_actor,p_snapshot_at,firm.row_id,firm.updated_at,firm.days_unattended,
      firm.attention_due,firm.attention_severity,firm.lane_key,firm.sector_key,
      firm.industry,firm.onboarding_status,firm.subscription_status,
      lower(concat_ws(' ',firm.name,firm.legal_name,firm.registration_number,
        firm.sector_key,firm.industry,firm.boss_name,firm.boss_email,firm.boss_phone)),
      to_jsonb(firm)
    from app.platform_firm_rows_v88(p_snapshot_at) firm;
  else
    select snapshot.expires_at into v_expires_at
    from app.platform_firm_snapshots_v88 snapshot
    where snapshot.actor_id=p_actor and snapshot.snapshot_at=p_snapshot_at;
  end if;

  if v_expires_at is null or v_expires_at<=clock_timestamp() then
    raise exception 'firm snapshot token is unavailable' using errcode='22023';
  end if;
  return v_expires_at;
end
$$;

revoke all on function app.ensure_platform_firm_snapshot_v88(uuid,timestamptz,boolean)
  from public,anon,authenticated;

create or replace function public.platform_list_firm_onboarding_v88(
  p_filters jsonb default '{}'::jsonb,
  p_snapshot_at timestamptz default null,
  p_limit integer default 100,
  p_after_updated_at timestamptz default null,
  p_after_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_snapshot timestamptz:=coalesce(p_snapshot_at,clock_timestamp());
  v_snapshot_expires_at timestamptz;
  v_limit integer:=least(greatest(coalesce(p_limit,100),1),250);
  v_filters jsonb:=coalesce(p_filters,'{}'::jsonb);
  v_result jsonb;
begin
  if not app.is_super_admin() then
    raise exception 'super admin access is required' using errcode='42501';
  end if;
  perform app.v86_assert_object_keys(v_filters,array[
    'search','lane','sector','onboarding_status','subscription_status',
    'attention_severity','attention_due'
  ],'firm onboarding filters');
  if (p_after_updated_at is null)<>(p_after_id is null) then
    raise exception 'complete firm cursor is required' using errcode='22023';
  end if;
  if p_snapshot_at is null and p_after_updated_at is not null then
    raise exception 'snapshot token is required after the first page' using errcode='22023';
  end if;
  if v_filters?'attention_due'
     and v_filters->>'attention_due' not in ('true','false') then
    raise exception 'attention_due must be a boolean' using errcode='22023';
  end if;
  v_snapshot_expires_at:=app.ensure_platform_firm_snapshot_v88(
    v_actor,v_snapshot,p_snapshot_at is null
  );

  with filtered as materialized (
    select firm.*
    from app.platform_firm_snapshot_rows_v88 firm
    where firm.actor_id=v_actor and firm.snapshot_at=v_snapshot
      and (nullif(v_filters->>'lane','') is null or firm.lane_key=v_filters->>'lane')
      and (nullif(v_filters->>'sector','') is null
        or firm.sector_key=v_filters->>'sector' or firm.industry=v_filters->>'sector')
      and (nullif(v_filters->>'onboarding_status','') is null
        or firm.onboarding_status=v_filters->>'onboarding_status')
      and (nullif(v_filters->>'subscription_status','') is null
        or firm.subscription_status=v_filters->>'subscription_status')
      and (nullif(v_filters->>'attention_severity','') is null
        or firm.attention_severity=v_filters->>'attention_severity')
      and (not (v_filters?'attention_due')
        or firm.attention_due=(v_filters->>'attention_due')::boolean)
      and (nullif(btrim(v_filters->>'search'),'') is null
        or firm.search_text like '%'||lower(btrim(v_filters->>'search'))||'%')
  ), page as materialized (
    select firm.*
    from filtered firm
    where p_after_updated_at is null
       or (firm.updated_at,firm.row_id)<(p_after_updated_at,p_after_id)
    order by firm.updated_at desc,firm.row_id desc
    limit v_limit
  )
  select jsonb_build_object(
    'snapshot_at',v_snapshot,
    'snapshot_expires_at',v_snapshot_expires_at,
    'items',coalesce((select jsonb_agg(
      item.payload||jsonb_build_object('id',item.row_id,'total_count',(select count(*) from filtered))
      order by item.updated_at desc,item.row_id desc
    ) from page item),'[]'::jsonb),
    'next_cursor',(select jsonb_build_object('updated_at',item.updated_at,'id',item.row_id)
      from page item order by item.updated_at,item.row_id limit 1),
    'total_count',(select count(*) from filtered),
    'attention_summary',jsonb_build_object(
      'due',(select count(*) from filtered where attention_due),
      'critical',(select count(*) from filtered where attention_severity='critical'),
      'warning',(select count(*) from filtered where attention_severity='warning'),
      'info',(select count(*) from filtered where attention_severity='info')
    )
  ) into v_result;

  insert into public.audit_log(business_id,actor,action,entity,detail)
  values(null,auth.uid(),'PLATFORM_FIRM_ONBOARDING_READ_V88','businesses',
    jsonb_build_object('snapshot_at',v_snapshot,'filters',v_filters,
      'limit',v_limit,'result_count',jsonb_array_length(v_result->'items'),
      'total_count',v_result->'total_count'));
  return v_result;
end
$$;

create or replace function public.platform_list_firm_attention_v88(
  p_snapshot_at timestamptz default null,
  p_limit integer default 100,
  p_after_days_unattended integer default null,
  p_after_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_snapshot timestamptz:=coalesce(p_snapshot_at,clock_timestamp());
  v_snapshot_expires_at timestamptz;
  v_limit integer:=least(greatest(coalesce(p_limit,100),1),250);
  v_result jsonb;
begin
  if not app.is_super_admin() then
    raise exception 'super admin access is required' using errcode='42501';
  end if;
  if (p_after_days_unattended is null)<>(p_after_id is null) then
    raise exception 'complete attention cursor is required' using errcode='22023';
  end if;
  if p_snapshot_at is null and p_after_days_unattended is not null then
    raise exception 'snapshot token is required after the first page' using errcode='22023';
  end if;
  if p_after_days_unattended is not null and p_after_days_unattended<0 then
    raise exception 'attention cursor days must not be negative' using errcode='22023';
  end if;
  v_snapshot_expires_at:=app.ensure_platform_firm_snapshot_v88(
    v_actor,v_snapshot,p_snapshot_at is null
  );

  with due as materialized (
    select firm.* from app.platform_firm_snapshot_rows_v88 firm
    where firm.actor_id=v_actor and firm.snapshot_at=v_snapshot and firm.attention_due
  ), page as materialized (
    select firm.* from due firm
    where p_after_days_unattended is null
       or (firm.days_unattended,firm.row_id)<(p_after_days_unattended,p_after_id)
    order by firm.days_unattended desc,firm.row_id desc
    limit v_limit
  )
  select jsonb_build_object(
    'snapshot_at',v_snapshot,
    'snapshot_expires_at',v_snapshot_expires_at,
    'items',coalesce((select jsonb_agg(
      item.payload||jsonb_build_object('id',item.row_id,'total_count',(select count(*) from due))
      order by item.days_unattended desc,item.row_id desc
    ) from page item),'[]'::jsonb),
    'next_cursor',(select jsonb_build_object(
      'days_unattended',item.days_unattended,'id',item.row_id
    ) from page item order by item.days_unattended,item.row_id limit 1),
    'total_count',(select count(*) from due),
    'summary',jsonb_build_object(
      'critical',(select count(*) from due where attention_severity='critical'),
      'warning',(select count(*) from due where attention_severity='warning')
    )
  ) into v_result;

  insert into public.audit_log(business_id,actor,action,entity,detail)
  values(null,auth.uid(),'PLATFORM_FIRM_ATTENTION_READ_V88','businesses',
    jsonb_build_object('snapshot_at',v_snapshot,'limit',v_limit,
      'result_count',jsonb_array_length(v_result->'items'),
      'total_count',v_result->'total_count'));
  return v_result;
end
$$;

comment on function public.platform_list_firm_onboarding_v88(jsonb,timestamptz,integer,timestamptz,uuid)
  is 'v88 SA-only unified prospect/business onboarding directory. Keyset-paginated, searchable and de-duplicated; exposes owner contact only through this guarded reader.';
comment on function public.platform_list_firm_attention_v88(timestamptz,integer,integer,uuid)
  is 'v88 deterministic SA-only stale-attention queue. No external delivery or mutable notification state.';

revoke all on function public.platform_list_firm_onboarding_v88(jsonb,timestamptz,integer,timestamptz,uuid)
  from public,anon,authenticated;
revoke all on function public.platform_list_firm_attention_v88(timestamptz,integer,integer,uuid)
  from public,anon,authenticated;
grant execute on function public.platform_list_firm_onboarding_v88(jsonb,timestamptz,integer,timestamptz,uuid)
  to authenticated;
grant execute on function public.platform_list_firm_attention_v88(timestamptz,integer,integer,uuid)
  to authenticated;

commit;
