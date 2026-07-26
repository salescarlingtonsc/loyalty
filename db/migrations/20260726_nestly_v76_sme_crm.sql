-- NESTLY v76 - PLATFORM SME CRM + 17-STAGE KANBAN
-- Additive local review candidate. Do not apply until the independent release gate accepts it.

begin;

create table public.sme_pipeline_stages (
  stage_key text primary key check (stage_key ~ '^[a-z][a-z0-9_]*$'),
  label text not null unique,
  sort_order smallint not null unique check (sort_order between 1 and 17)
);
insert into public.sme_pipeline_stages(stage_key,label,sort_order) values
  ('new_lead','New Lead',1), ('appt_set','Appointment Set',2),
  ('npu_1','NPU 1',3), ('npu_2','NPU 2',4), ('npu_3','NPU 3',5),
  ('npu_4','NPU 4',6), ('npu_5','NPU 5',7), ('npu_6','NPU 6',8),
  ('call_back','Call Back',9), ('reschedule','Reschedule',10),
  ('meeting_sent','Meeting Link Sent / Calendar Set',11), ('pending_decision','Pending Decision',12),
  ('client','Client / Deal Won',13), ('account_created','Account Created',14),
  ('onboarding','Onboarding in Progress',15), ('activated','Activated',16), ('lost','Lost',17);

create table public.sme_companies (
  id uuid primary key default gen_random_uuid(),
  legal_name text,
  trading_name text,
  registration_number text,
  industry text,
  sector_key text references public.sector_profiles(sector_key) on delete restrict,
  website text,
  phone text,
  email text,
  address jsonb not null default '{}'::jsonb check (jsonb_typeof(address)='object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sme_companies_name_check check (
    length(btrim(coalesce(legal_name,''))) >= 2
    or length(btrim(coalesce(trading_name,''))) >= 2
  )
);
create unique index sme_companies_registration_uk
  on public.sme_companies(lower(btrim(registration_number)))
  where registration_number is not null and length(btrim(registration_number)) > 0;

create table public.sme_prospects (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.sme_companies(id) on delete restrict,
  current_stage_key text references public.sme_pipeline_stages(stage_key) on delete restrict,
  legacy_stage_raw text,
  assigned_consultant_id uuid references public.platform_consultants(id) on delete restrict,
  converted_business_id uuid unique references public.businesses(id) on delete restrict,
  converted_at timestamptz,
  converted_by uuid references auth.users(id) on delete set null,
  version bigint not null default 1 check (version > 0),
  priority text not null default 'normal' check (priority in ('low','normal','high','urgent')),
  region text,
  next_action_at timestamptz,
  stage_entered_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  constraint sme_prospects_conversion_shape_check check (
    (converted_business_id is null and converted_at is null and converted_by is null)
    or (converted_business_id is not null and converted_at is not null and converted_by is not null)
  ),
  constraint sme_prospects_unmapped_evidence_check check (
    current_stage_key is not null or length(btrim(coalesce(legacy_stage_raw,''))) > 0
  )
);
create index sme_prospects_stage_idx on public.sme_prospects(current_stage_key,updated_at desc);
create index sme_prospects_consultant_idx on public.sme_prospects(assigned_consultant_id,updated_at desc);

create table public.sme_prospect_contacts (
  id uuid primary key default gen_random_uuid(),
  prospect_id uuid not null references public.sme_prospects(id) on delete cascade,
  full_name text not null check (length(btrim(full_name)) between 2 and 120),
  title text,
  email text,
  phone text,
  is_primary boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sme_prospect_contacts_channel_check check (
    email is not null or phone is not null
  )
);
create unique index sme_prospect_contacts_one_primary_idx
  on public.sme_prospect_contacts(prospect_id) where is_primary and active;

create table public.sme_prospect_assignments (
  id uuid primary key default gen_random_uuid(),
  prospect_id uuid not null references public.sme_prospects(id) on delete restrict,
  consultant_id uuid references public.platform_consultants(id) on delete restrict,
  assigned_by uuid references auth.users(id) on delete set null,
  reason text,
  created_at timestamptz not null default now()
);

create table public.sme_prospect_activities (
  id uuid primary key default gen_random_uuid(),
  prospect_id uuid not null references public.sme_prospects(id) on delete restrict,
  consultant_id uuid references public.platform_consultants(id) on delete restrict,
  activity_type text not null check (activity_type in
    ('note','call','email','whatsapp','meeting','demo','task','document_sent',
     'proposal_sent','contract_sent','payment','onboarding_session','npu_attempt','system')),
  summary text not null check (length(btrim(summary)) between 2 and 240),
  detail text,
  occurred_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index sme_prospect_activities_timeline_idx
  on public.sme_prospect_activities(prospect_id,occurred_at desc,created_at desc);

create table public.sme_prospect_stage_history (
  id uuid primary key default gen_random_uuid(),
  prospect_id uuid not null references public.sme_prospects(id) on delete restrict,
  from_stage_key text references public.sme_pipeline_stages(stage_key) on delete restrict,
  to_stage_key text not null references public.sme_pipeline_stages(stage_key) on delete restrict,
  reason_code text,
  reason_detail text,
  actor uuid references auth.users(id) on delete set null,
  occurred_at timestamptz not null default now()
);
create index sme_prospect_stage_history_timeline_idx
  on public.sme_prospect_stage_history(prospect_id,occurred_at desc);

create table public.sme_prospect_tasks (
  id uuid primary key default gen_random_uuid(),
  prospect_id uuid not null references public.sme_prospects(id) on delete restrict,
  title text not null check (length(btrim(title)) between 2 and 240),
  due_at timestamptz not null,
  assigned_consultant_id uuid references public.platform_consultants(id) on delete restrict,
  status text not null default 'open' check (status in ('open','completed','cancelled')),
  outcome text,
  completed_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint sme_prospect_tasks_completion_check check (
    (status='completed' and completed_at is not null and length(btrim(coalesce(outcome,'')))>0)
    or (status<>'completed' and completed_at is null)
  )
);
create index sme_prospect_tasks_due_idx on public.sme_prospect_tasks(status,due_at);

create table public.sme_prospect_qualification_versions (
  id uuid primary key default gen_random_uuid(),
  prospect_id uuid not null references public.sme_prospects(id) on delete restrict,
  version integer not null check (version > 0),
  budget_status text check (budget_status in ('unknown','confirmed','unconfirmed','insufficient')),
  authority_status text check (authority_status in ('unknown','decision_maker','influencer','not_authorized')),
  need_status text check (need_status in ('unknown','confirmed','weak','none')),
  timeline_status text check (timeline_status in ('unknown','this_month','this_quarter','later','none')),
  score smallint check (score between 0 and 100),
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(prospect_id,version)
);

-- Accepted commercial terms are immutable snapshots used by later conversion.
create table public.sme_commercial_terms (
  id uuid primary key default gen_random_uuid(),
  prospect_id uuid not null references public.sme_prospects(id) on delete restrict,
  version integer not null check (version > 0),
  plan_code text not null check (length(btrim(plan_code)) between 1 and 80),
  product_code text not null check (length(btrim(product_code)) between 1 and 80),
  billing_cycle text not null check (billing_cycle in ('quarterly','half_yearly','annual')),
  seats integer not null check (seats > 0),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  accepted_value_cents integer not null check (accepted_value_cents >= 0),
  owner_email text not null check (position('@' in owner_email) > 1),
  onboarding_owner_consultant_id uuid references public.platform_consultants(id) on delete restrict,
  target_go_live date,
  contract_status text not null check (contract_status in
    ('draft','offered','accepted','signed','cancelled')),
  accepted_at timestamptz,
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(prospect_id,version),
  constraint sme_commercial_terms_acceptance_check check (
    (contract_status in ('accepted','signed') and accepted_at is not null)
    or (contract_status not in ('accepted','signed') and accepted_at is null)
  )
);

create table public.sme_tags (
  id uuid primary key default gen_random_uuid(),
  tag_key text not null unique check (tag_key ~ '^[a-z][a-z0-9_]{0,63}$'),
  label text not null check (length(btrim(label)) between 1 and 80),
  created_at timestamptz not null default now()
);
create table public.sme_prospect_tags (
  prospect_id uuid not null references public.sme_prospects(id) on delete cascade,
  tag_id uuid not null references public.sme_tags(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key(prospect_id,tag_id)
);

create table public.sme_prospect_source_lineage (
  id uuid primary key default gen_random_uuid(),
  prospect_id uuid not null references public.sme_prospects(id) on delete restrict,
  source_system text not null,
  source_type text not null check (source_type in
    ('manual','directory','referral','partner','event','outbound_call','website',
     'demo_request','paid_advertising','organic','social','import','other')),
  external_id text,
  detail jsonb not null default '{}'::jsonb check (jsonb_typeof(detail)='object'),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create unique index sme_prospect_source_external_uk
  on public.sme_prospect_source_lineage(source_system,external_id)
  where external_id is not null;

create table public.sme_prospect_data_quality_flags (
  id uuid primary key default gen_random_uuid(),
  prospect_id uuid not null references public.sme_prospects(id) on delete restrict,
  flag_code text not null check (flag_code ~ '^[a-z][a-z0-9_]*$'),
  severity text not null check (severity in ('info','warning','blocking')),
  detail text not null,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references auth.users(id) on delete set null,
  resolution text,
  constraint sme_quality_resolution_check check (
    (resolved_at is null and resolved_by is null and resolution is null)
    or (resolved_at is not null and resolved_by is not null and length(btrim(resolution))>0)
  )
);

create table public.sme_prospect_import_batches (
  id uuid primary key default gen_random_uuid(),
  source_system text not null,
  source_name text not null,
  status text not null default 'staged' check (status in ('staged','committed','failed')),
  total_rows integer not null check (total_rows >= 0),
  valid_rows integer not null default 0 check (valid_rows >= 0),
  unmapped_rows integer not null default 0 check (unmapped_rows >= 0),
  conflict_rows integer not null default 0 check (conflict_rows >= 0),
  invalid_rows integer not null default 0 check (invalid_rows >= 0),
  imported_rows integer not null default 0 check (imported_rows >= 0),
  skipped_rows integer not null default 0 check (skipped_rows >= 0),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  committed_at timestamptz
);
create table public.sme_prospect_import_rows (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.sme_prospect_import_batches(id) on delete restrict,
  row_number integer not null check (row_number > 0),
  raw_payload jsonb not null check (jsonb_typeof(raw_payload)='object'),
  normalized_payload jsonb not null check (jsonb_typeof(normalized_payload)='object'),
  raw_stage text,
  mapped_stage_key text references public.sme_pipeline_stages(stage_key) on delete restrict,
  row_status text not null check (row_status in ('valid','unmapped','conflict','invalid','imported')),
  errors text[] not null default '{}',
  prospect_id uuid references public.sme_prospects(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique(batch_id,row_number)
);

create table public.sme_operation_receipts (
  id uuid primary key default gen_random_uuid(),
  actor uuid not null references auth.users(id) on delete restrict,
  operation text not null,
  idempotency_key text not null check (length(btrim(idempotency_key)) between 8 and 200),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  response jsonb not null,
  created_at timestamptz not null default now(),
  unique(actor,operation,idempotency_key)
);

-- Keep every table boundary explicit so review and release tooling can prove
-- that a newly added CRM relation cannot silently miss its browser-role ACL.
alter table public.sme_pipeline_stages enable row level security;
revoke all privileges on table public.sme_pipeline_stages from public, anon, authenticated;
alter table public.sme_companies enable row level security;
revoke all privileges on table public.sme_companies from public, anon, authenticated;
alter table public.sme_prospects enable row level security;
revoke all privileges on table public.sme_prospects from public, anon, authenticated;
alter table public.sme_prospect_contacts enable row level security;
revoke all privileges on table public.sme_prospect_contacts from public, anon, authenticated;
alter table public.sme_prospect_assignments enable row level security;
revoke all privileges on table public.sme_prospect_assignments from public, anon, authenticated;
alter table public.sme_prospect_activities enable row level security;
revoke all privileges on table public.sme_prospect_activities from public, anon, authenticated;
alter table public.sme_prospect_stage_history enable row level security;
revoke all privileges on table public.sme_prospect_stage_history from public, anon, authenticated;
alter table public.sme_prospect_tasks enable row level security;
revoke all privileges on table public.sme_prospect_tasks from public, anon, authenticated;
alter table public.sme_prospect_qualification_versions enable row level security;
revoke all privileges on table public.sme_prospect_qualification_versions from public, anon, authenticated;
alter table public.sme_commercial_terms enable row level security;
revoke all privileges on table public.sme_commercial_terms from public, anon, authenticated;
alter table public.sme_tags enable row level security;
revoke all privileges on table public.sme_tags from public, anon, authenticated;
alter table public.sme_prospect_tags enable row level security;
revoke all privileges on table public.sme_prospect_tags from public, anon, authenticated;
alter table public.sme_prospect_source_lineage enable row level security;
revoke all privileges on table public.sme_prospect_source_lineage from public, anon, authenticated;
alter table public.sme_prospect_data_quality_flags enable row level security;
revoke all privileges on table public.sme_prospect_data_quality_flags from public, anon, authenticated;
alter table public.sme_prospect_import_batches enable row level security;
revoke all privileges on table public.sme_prospect_import_batches from public, anon, authenticated;
alter table public.sme_prospect_import_rows enable row level security;
revoke all privileges on table public.sme_prospect_import_rows from public, anon, authenticated;
alter table public.sme_operation_receipts enable row level security;
revoke all privileges on table public.sme_operation_receipts from public, anon, authenticated;

create trigger sme_qualification_versions_immutable_guard
  before update or delete on public.sme_prospect_qualification_versions
  for each row execute function app.v75_immutable_guard();
create trigger sme_commercial_terms_immutable_guard
  before update or delete on public.sme_commercial_terms
  for each row execute function app.v75_immutable_guard();
create trigger sme_stage_history_immutable_guard
  before update or delete on public.sme_prospect_stage_history
  for each row execute function app.v75_immutable_guard();
create trigger sme_source_lineage_immutable_guard
  before update or delete on public.sme_prospect_source_lineage
  for each row execute function app.v75_immutable_guard();
create trigger sme_operation_receipts_immutable_guard
  before update or delete on public.sme_operation_receipts
  for each row execute function app.v75_immutable_guard();

create or replace function app.v76_sha256_hex(p_value text)
returns text language sql immutable
set search_path to 'pg_catalog','extensions','pg_temp'
as $$ select encode(extensions.digest(convert_to(p_value,'UTF8'),'sha256'),'hex') $$;
revoke all on function app.v76_sha256_hex(text) from public,anon,authenticated;

create or replace function app.v76_replay(
  p_actor uuid,p_operation text,p_key text,p_hash text
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_row public.sme_operation_receipts%rowtype;
begin
  if p_key is null then return null; end if;
  select * into v_row from public.sme_operation_receipts
   where actor=p_actor and operation=p_operation and idempotency_key=p_key;
  if not found then return null; end if;
  if v_row.request_hash<>p_hash then
    raise exception 'idempotency key was reused with different input' using errcode='22023';
  end if;
  return v_row.response || jsonb_build_object('replayed',true);
end
$$;
revoke all on function app.v76_replay(uuid,text,text,text) from public,anon,authenticated;

create or replace function app.v76_store_receipt(
  p_actor uuid,p_operation text,p_key text,p_hash text,p_response jsonb
)
returns void language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if p_key is not null then
    insert into public.sme_operation_receipts(actor,operation,idempotency_key,request_hash,response)
    values(p_actor,p_operation,p_key,p_hash,p_response);
  end if;
end
$$;
revoke all on function app.v76_store_receipt(uuid,text,text,text,jsonb) from public,anon,authenticated;

create or replace function app.map_sme_stage_v76(p_raw text)
returns text language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select stage.stage_key
    from public.sme_pipeline_stages stage
   where stage.stage_key=lower(regexp_replace(btrim(coalesce(p_raw,'')),'[^a-zA-Z0-9]+','_','g'))
      or lower(stage.label)=lower(btrim(coalesce(p_raw,'')))
   order by stage.sort_order limit 1
$$;
revoke all on function app.map_sme_stage_v76(text) from public,anon,authenticated;

create or replace function app.sme_prospect_card_v76(p_prospect uuid)
returns jsonb language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select jsonb_build_object(
    'id',prospect.id,'company_id',company.id,'legal_name',company.legal_name,
    'trading_name',company.trading_name,'registration_number',company.registration_number,
    'industry',company.industry,'sector_key',company.sector_key,
    'current_stage_key',prospect.current_stage_key,'legacy_stage_raw',prospect.legacy_stage_raw,
    'assigned_consultant_id',prospect.assigned_consultant_id,
    'consultant_name',consultant.display_name,'next_action_at',prospect.next_action_at,
    'next_action_overdue',prospect.next_action_at is not null and prospect.next_action_at<now(),
    'priority',prospect.priority,'region',prospect.region,'fit_score',qualification.score,
    'primary_contact',case when contact.id is null then null else jsonb_build_object(
      'id',contact.id,'full_name',contact.full_name,'title',contact.title,
      'phone',contact.phone,'email',contact.email) end,
    'source',case when source.id is null then null else jsonb_build_object(
      'source_system',source.source_system,'source_type',source.source_type,
      'external_id',source.external_id) end,
    'tags',coalesce(tags.items,'[]'::jsonb),
    'last_activity',case when activity.id is null then null else jsonb_build_object(
      'id',activity.id,'activity_type',activity.activity_type,'summary',activity.summary,
      'detail',activity.detail,'occurred_at',activity.occurred_at) end,
    'stage_entered_at',prospect.stage_entered_at,
    'stage_age_days',greatest(0,current_date-(prospect.stage_entered_at at time zone 'Asia/Singapore')::date),
    'data_completeness_percent',
      (case when coalesce(company.legal_name,company.trading_name) is not null then 20 else 0 end)
      +(case when company.registration_number is not null then 15 else 0 end)
      +(case when coalesce(company.sector_key,company.industry) is not null then 10 else 0 end)
      +(case when contact.id is not null then 10 else 0 end)
      +(case when contact.email is not null then 10 else 0 end)
      +(case when contact.phone is not null then 10 else 0 end)
      +(case when source.id is not null then 5 else 0 end)
      +(case when prospect.assigned_consultant_id is not null then 5 else 0 end)
      +(case when qualification.score is not null then 5 else 0 end)
      +(case when prospect.next_action_at is not null then 5 else 0 end)
      +(case when prospect.current_stage_key is not null then 5 else 0 end),
    'open_data_quality_warnings',coalesce(quality.open_count,0),
    'version',prospect.version,'updated_at',prospect.updated_at,
    'converted_business_id',prospect.converted_business_id,'converted_at',prospect.converted_at
  )
  from public.sme_prospects prospect
  join public.sme_companies company on company.id=prospect.company_id
  left join public.platform_consultants consultant on consultant.id=prospect.assigned_consultant_id
  left join lateral (
    select c.* from public.sme_prospect_contacts c
     where c.prospect_id=prospect.id and c.active
     order by c.is_primary desc,c.created_at limit 1
  ) contact on true
  left join lateral (
    select s.* from public.sme_prospect_source_lineage s
     where s.prospect_id=prospect.id order by s.created_at,s.id limit 1
  ) source on true
  left join lateral (
    select q.* from public.sme_prospect_qualification_versions q
     where q.prospect_id=prospect.id order by q.version desc limit 1
  ) qualification on true
  left join lateral (
    select a.* from public.sme_prospect_activities a
     where a.prospect_id=prospect.id order by a.occurred_at desc,a.created_at desc limit 1
  ) activity on true
  left join lateral (
    select jsonb_agg(jsonb_build_object('tag_key',tag.tag_key,'label',tag.label)
      order by tag.label) items
      from public.sme_prospect_tags link join public.sme_tags tag on tag.id=link.tag_id
     where link.prospect_id=prospect.id
  ) tags on true
  left join lateral (
    select count(*)::integer open_count from public.sme_prospect_data_quality_flags flag
     where flag.prospect_id=prospect.id and flag.resolved_at is null
       and flag.severity in ('warning','blocking')
  ) quality on true
  where prospect.id=p_prospect
$$;
revoke all on function app.sme_prospect_card_v76(uuid) from public,anon,authenticated;

create or replace function app.sme_prospect_search_match_v76(p_prospect uuid,p_search text)
returns boolean language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select p_search is null or exists(
    select 1 from public.sme_prospects prospect
    join public.sme_companies company on company.id=prospect.company_id
    where prospect.id=p_prospect and (
      concat_ws(' ',company.legal_name,company.trading_name,company.registration_number,
        company.email,company.phone,company.industry,company.sector_key) ilike '%'||p_search||'%'
      or exists(select 1 from public.sme_prospect_contacts contact
        where contact.prospect_id=prospect.id and concat_ws(' ',contact.full_name,
          contact.title,contact.email,contact.phone) ilike '%'||p_search||'%')
      or exists(select 1 from public.sme_prospect_activities activity
        where activity.prospect_id=prospect.id and concat_ws(' ',activity.summary,
          activity.detail) ilike '%'||p_search||'%')
      or exists(select 1 from public.sme_prospect_qualification_versions qualification
        where qualification.prospect_id=prospect.id
          and qualification.notes ilike '%'||p_search||'%')
    )
  )
$$;
revoke all on function app.sme_prospect_search_match_v76(uuid,text) from public,anon,authenticated;

create or replace function public.platform_get_sme_board_v76(p_consultant uuid default null)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if not app.is_platform_operator_v75() then
    raise exception 'platform operator access is required' using errcode='42501';
  end if;
  return jsonb_build_object(
    'stages',(select jsonb_agg(to_jsonb(stage) order by stage.sort_order)
      from public.sme_pipeline_stages stage),
    'columns',(select jsonb_agg(jsonb_build_object(
      'stage_key',stage.stage_key,'label',stage.label,'sort_order',stage.sort_order,
      'count',(select count(*) from public.sme_prospects prospect
        where prospect.current_stage_key=stage.stage_key
          and (p_consultant is null or prospect.assigned_consultant_id=p_consultant)),
      'prospects',coalesce((select jsonb_agg(app.sme_prospect_card_v76(prospect.id)
          order by prospect.updated_at desc)
        from public.sme_prospects prospect
        where prospect.current_stage_key=stage.stage_key
          and (p_consultant is null or prospect.assigned_consultant_id=p_consultant)),'[]'::jsonb)
    ) order by stage.sort_order) from public.sme_pipeline_stages stage),
    'unmapped',jsonb_build_object(
      'count',(select count(*) from public.sme_prospects prospect
        where prospect.current_stage_key is null
          and (p_consultant is null or prospect.assigned_consultant_id=p_consultant)),
      'prospects',coalesce((select jsonb_agg(app.sme_prospect_card_v76(prospect.id)
          order by prospect.updated_at desc)
        from public.sme_prospects prospect
        where prospect.current_stage_key is null
          and (p_consultant is null or prospect.assigned_consultant_id=p_consultant)),'[]'::jsonb)
    )
  );
end
$$;

create or replace function public.platform_list_prospects_v76(
  p_stage text default null,p_consultant uuid default null,p_search text default null,
  p_limit integer default 100,p_before timestamptz default null
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_limit integer:=least(greatest(coalesce(p_limit,100),1),250);
begin
  if not app.is_platform_operator_v75() then
    raise exception 'platform operator access is required' using errcode='42501';
  end if;
  if p_stage is not null and p_stage<>'unmapped'
     and not exists(select 1 from public.sme_pipeline_stages where stage_key=p_stage) then
    raise exception 'unknown SME stage' using errcode='22023';
  end if;
  return jsonb_build_object(
    'items',coalesce((select jsonb_agg(item.card order by item.updated_at desc)
      from (select app.sme_prospect_card_v76(prospect.id) card,prospect.updated_at
        from public.sme_prospects prospect join public.sme_companies company on company.id=prospect.company_id
        where (p_stage is null or (p_stage='unmapped' and prospect.current_stage_key is null)
          or prospect.current_stage_key=p_stage)
          and (p_consultant is null or prospect.assigned_consultant_id=p_consultant)
          and (p_before is null or prospect.updated_at<p_before)
          and app.sme_prospect_search_match_v76(prospect.id,p_search)
        order by prospect.updated_at desc limit v_limit) item),'[]'::jsonb),
    'next_before',(select min(item.updated_at) from (
      select prospect.updated_at from public.sme_prospects prospect
      join public.sme_companies company on company.id=prospect.company_id
      where (p_stage is null or (p_stage='unmapped' and prospect.current_stage_key is null)
        or prospect.current_stage_key=p_stage)
        and (p_consultant is null or prospect.assigned_consultant_id=p_consultant)
        and (p_before is null or prospect.updated_at<p_before)
        and app.sme_prospect_search_match_v76(prospect.id,p_search)
      order by prospect.updated_at desc limit v_limit) item),
    'unmapped_count',(select count(*) from public.sme_prospects where current_stage_key is null)
  );
end
$$;

create or replace function public.platform_get_prospect_detail_v76(p_prospect uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_prospect public.sme_prospects%rowtype; v_company public.sme_companies%rowtype;
begin
  if not app.is_platform_operator_v75() then
    raise exception 'platform operator access is required' using errcode='42501';
  end if;
  select * into v_prospect from public.sme_prospects where id=p_prospect;
  if not found then raise exception 'prospect was not found' using errcode='22023'; end if;
  select * into strict v_company from public.sme_companies where id=v_prospect.company_id;
  return jsonb_build_object(
    'prospect',to_jsonb(v_prospect),'company',to_jsonb(v_company),
    'contacts',coalesce((select jsonb_agg(to_jsonb(contact) order by contact.is_primary desc,contact.created_at)
      from public.sme_prospect_contacts contact where contact.prospect_id=p_prospect),'[]'::jsonb),
    'assignment',case when v_prospect.assigned_consultant_id is null then null else
      (select jsonb_build_object('consultant_id',id,'display_name',display_name,'tier',tier)
       from public.platform_consultants where id=v_prospect.assigned_consultant_id) end,
    'activities',coalesce((select jsonb_agg(to_jsonb(activity) order by activity.occurred_at desc)
      from public.sme_prospect_activities activity where activity.prospect_id=p_prospect),'[]'::jsonb),
    'tasks',coalesce((select jsonb_agg(to_jsonb(task) order by task.status,task.due_at)
      from public.sme_prospect_tasks task where task.prospect_id=p_prospect),'[]'::jsonb),
    'stage_history',coalesce((select jsonb_agg(to_jsonb(history) order by history.occurred_at desc)
      from public.sme_prospect_stage_history history where history.prospect_id=p_prospect),'[]'::jsonb),
    'qualification',(select to_jsonb(q) from public.sme_prospect_qualification_versions q
      where q.prospect_id=p_prospect order by q.version desc limit 1),
    'commercial_terms',(select to_jsonb(terms) from public.sme_commercial_terms terms
      where terms.prospect_id=p_prospect order by terms.version desc limit 1),
    'sources',coalesce((select jsonb_agg(to_jsonb(source) order by source.created_at)
      from public.sme_prospect_source_lineage source where source.prospect_id=p_prospect),'[]'::jsonb),
    'tags',coalesce((select jsonb_agg(jsonb_build_object('tag_key',tag.tag_key,'label',tag.label)
      order by tag.label) from public.sme_prospect_tags link join public.sme_tags tag on tag.id=link.tag_id
      where link.prospect_id=p_prospect),'[]'::jsonb),
    'data_quality_flags',coalesce((select jsonb_agg(to_jsonb(flag) order by flag.resolved_at nulls first,flag.created_at)
      from public.sme_prospect_data_quality_flags flag where flag.prospect_id=p_prospect),'[]'::jsonb)
  );
end
$$;

create or replace function app.v76_set_tags(p_prospect uuid,p_tags text[])
returns void language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_tag text; v_key text; v_id uuid;
begin
  delete from public.sme_prospect_tags where prospect_id=p_prospect;
  foreach v_tag in array coalesce(p_tags,'{}') loop
    v_key:=trim(both '_' from lower(regexp_replace(btrim(v_tag),'[^a-zA-Z0-9]+','_','g')));
    if v_key!~'^[a-z][a-z0-9_]{0,63}$' then
      raise exception 'invalid prospect tag: %',v_tag using errcode='22023';
    end if;
    insert into public.sme_tags(tag_key,label) values(v_key,btrim(v_tag))
    on conflict(tag_key) do update set label=excluded.label returning id into v_id;
    insert into public.sme_prospect_tags(prospect_id,tag_id) values(p_prospect,v_id)
    on conflict do nothing;
  end loop;
end
$$;
revoke all on function app.v76_set_tags(uuid,text[]) from public,anon,authenticated;

create or replace function public.platform_create_prospect_v76(
  p_company jsonb,p_primary_contact jsonb,p_stage_key text default 'new_lead',
  p_consultant uuid default null,p_source jsonb default '{}'::jsonb,
  p_tags text[] default '{}',p_idempotency_key text default null
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid(); v_hash text; v_replay jsonb; v_company uuid; v_prospect uuid;
  v_response jsonb; v_source jsonb:=coalesce(p_source,'{}');
begin
  if not app.is_platform_operator_v75() then
    raise exception 'platform operator access is required' using errcode='42501';
  end if;
  if jsonb_typeof(p_company)<>'object' or jsonb_typeof(v_source)<>'object' then
    raise exception 'company and source must be objects' using errcode='22023';
  end if;
  if p_primary_contact is not null and jsonb_typeof(p_primary_contact)<>'object' then
    raise exception 'primary contact must be an object or null' using errcode='22023';
  end if;
  if not exists(select 1 from public.sme_pipeline_stages where stage_key=p_stage_key) then
    raise exception 'unknown SME stage' using errcode='22023';
  end if;
  if p_stage_key in ('account_created','onboarding','activated') then
    raise exception 'this SME stage is system-managed and requires conversion evidence'
      using errcode='42501';
  end if;
  if p_consultant is not null and not exists(
    select 1 from public.platform_consultants where id=p_consultant and active
  ) then raise exception 'active consultant was not found' using errcode='22023'; end if;
  v_hash:=app.v76_sha256_hex(jsonb_build_object('company',p_company,'contact',p_primary_contact,
    'stage',p_stage_key,'consultant',p_consultant,'source',v_source,'tags',p_tags)::text);
  v_replay:=app.v76_replay(v_actor,'create_prospect',p_idempotency_key,v_hash);
  if v_replay is not null then return v_replay; end if;
  insert into public.sme_companies(
    legal_name,trading_name,registration_number,industry,sector_key,website,phone,email,address
  ) values (
    nullif(btrim(p_company->>'legal_name'),''),nullif(btrim(p_company->>'trading_name'),''),
    nullif(btrim(p_company->>'registration_number'),''),nullif(btrim(p_company->>'industry'),''),
    nullif(btrim(p_company->>'sector_key'),''),nullif(btrim(p_company->>'website'),''),
    nullif(btrim(p_company->>'phone'),''),nullif(btrim(p_company->>'email'),''),
    coalesce(p_company->'address','{}'::jsonb)
  ) returning id into v_company;
  insert into public.sme_prospects(
    company_id,current_stage_key,assigned_consultant_id,created_by,updated_by
  ) values(v_company,p_stage_key,p_consultant,v_actor,v_actor) returning id into v_prospect;
  if p_primary_contact is not null and jsonb_typeof(p_primary_contact)='object' then
    insert into public.sme_prospect_contacts(prospect_id,full_name,title,email,phone,is_primary)
    values(v_prospect,btrim(p_primary_contact->>'full_name'),nullif(btrim(p_primary_contact->>'title'),''),
      nullif(btrim(p_primary_contact->>'email'),''),nullif(btrim(p_primary_contact->>'phone'),''),true);
  end if;
  insert into public.sme_prospect_stage_history(prospect_id,to_stage_key,actor)
  values(v_prospect,p_stage_key,v_actor);
  if p_consultant is not null then
    insert into public.sme_prospect_assignments(prospect_id,consultant_id,assigned_by,reason)
    values(v_prospect,p_consultant,v_actor,'prospect creation');
  end if;
  insert into public.sme_prospect_source_lineage(
    prospect_id,source_system,source_type,external_id,detail,created_by
  ) values(v_prospect,coalesce(nullif(v_source->>'source_system',''),'manual'),
    coalesce(nullif(v_source->>'source_type',''),'manual'),nullif(v_source->>'external_id',''),
    v_source-'source_system'-'source_type'-'external_id',v_actor);
  perform app.v76_set_tags(v_prospect,p_tags);
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'SME_PROSPECT_CREATED_V76','sme_prospects',v_prospect,
    jsonb_build_object('stage',p_stage_key,'consultant_id',p_consultant));
  v_response:=jsonb_build_object('replayed',false,'prospect',app.sme_prospect_card_v76(v_prospect));
  perform app.v76_store_receipt(v_actor,'create_prospect',p_idempotency_key,v_hash,v_response);
  return v_response;
end
$$;

create or replace function public.platform_update_prospect_v76(
  p_prospect uuid,p_expected_version bigint,p_patch jsonb,p_idempotency_key text
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid(); v_hash text; v_replay jsonb; v_row public.sme_prospects%rowtype;
  v_unknown text[]; v_qversion integer; v_response jsonb;
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501'; end if;
  if jsonb_typeof(p_patch)<>'object' then raise exception 'patch must be an object' using errcode='22023'; end if;
  select array_agg(key order by key) into v_unknown from jsonb_object_keys(p_patch) key
   where key not in ('legal_name','trading_name','registration_number','industry','sector_key',
     'website','phone','email','address','next_action_at','priority','region','qualification','tags');
  if cardinality(v_unknown)>0 then raise exception 'unsupported prospect patch fields: %',array_to_string(v_unknown,', ') using errcode='22023'; end if;
  v_hash:=app.v76_sha256_hex(jsonb_build_object('prospect',p_prospect,'version',p_expected_version,'patch',p_patch)::text);
  v_replay:=app.v76_replay(v_actor,'update_prospect',p_idempotency_key,v_hash);
  if v_replay is not null then return v_replay; end if;
  update public.sme_prospects set
    next_action_at=case when p_patch?'next_action_at' then (p_patch->>'next_action_at')::timestamptz else next_action_at end,
    priority=case when p_patch?'priority' then p_patch->>'priority' else priority end,
    region=case when p_patch?'region' then nullif(btrim(p_patch->>'region'),'') else region end,
    version=version+1,updated_by=v_actor,updated_at=now()
   where id=p_prospect and version=p_expected_version returning * into v_row;
  if not found then raise exception 'prospect version conflict' using errcode='40001'; end if;
  update public.sme_companies set
    legal_name=case when p_patch?'legal_name' then nullif(btrim(p_patch->>'legal_name'),'') else legal_name end,
    trading_name=case when p_patch?'trading_name' then nullif(btrim(p_patch->>'trading_name'),'') else trading_name end,
    registration_number=case when p_patch?'registration_number' then nullif(btrim(p_patch->>'registration_number'),'') else registration_number end,
    industry=case when p_patch?'industry' then nullif(btrim(p_patch->>'industry'),'') else industry end,
    sector_key=case when p_patch?'sector_key' then nullif(btrim(p_patch->>'sector_key'),'') else sector_key end,
    website=case when p_patch?'website' then nullif(btrim(p_patch->>'website'),'') else website end,
    phone=case when p_patch?'phone' then nullif(btrim(p_patch->>'phone'),'') else phone end,
    email=case when p_patch?'email' then nullif(btrim(p_patch->>'email'),'') else email end,
    address=case when p_patch?'address' then p_patch->'address' else address end,
    updated_at=now() where id=v_row.company_id;
  if p_patch?'qualification' then
    select coalesce(max(version),0)+1 into v_qversion from public.sme_prospect_qualification_versions where prospect_id=p_prospect;
    insert into public.sme_prospect_qualification_versions(
      prospect_id,version,budget_status,authority_status,need_status,timeline_status,score,notes,created_by
    ) values(p_prospect,v_qversion,p_patch#>>'{qualification,budget_status}',
      p_patch#>>'{qualification,authority_status}',p_patch#>>'{qualification,need_status}',
      p_patch#>>'{qualification,timeline_status}',(p_patch#>>'{qualification,score}')::smallint,
      p_patch#>>'{qualification,notes}',v_actor);
  end if;
  if p_patch?'tags' then
    perform app.v76_set_tags(p_prospect,array(select jsonb_array_elements_text(p_patch->'tags')));
  end if;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'SME_PROSPECT_UPDATED_V76','sme_prospects',p_prospect,
    jsonb_build_object('prior_version',p_expected_version,'new_version',v_row.version,'fields',
      (select jsonb_agg(key) from jsonb_object_keys(p_patch) key)));
  v_response:=jsonb_build_object('replayed',false,'prospect',app.sme_prospect_card_v76(p_prospect));
  perform app.v76_store_receipt(v_actor,'update_prospect',p_idempotency_key,v_hash,v_response);
  return v_response;
end
$$;

create or replace function public.platform_assign_prospect_v76(
  p_prospect uuid,p_consultant uuid,p_expected_version bigint,p_idempotency_key text
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_actor uuid:=auth.uid();v_hash text;v_replay jsonb;v_row public.sme_prospects%rowtype;v_response jsonb;
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501'; end if;
  if p_consultant is not null and not exists(select 1 from public.platform_consultants where id=p_consultant and active) then
    raise exception 'active consultant was not found' using errcode='22023'; end if;
  v_hash:=app.v76_sha256_hex(jsonb_build_object('prospect',p_prospect,'version',p_expected_version,'consultant',p_consultant)::text);
  v_replay:=app.v76_replay(v_actor,'assign_prospect',p_idempotency_key,v_hash);if v_replay is not null then return v_replay;end if;
  update public.sme_prospects set assigned_consultant_id=p_consultant,version=version+1,updated_by=v_actor,updated_at=now()
   where id=p_prospect and version=p_expected_version returning * into v_row;
  if not found then raise exception 'prospect version conflict' using errcode='40001';end if;
  insert into public.sme_prospect_assignments(prospect_id,consultant_id,assigned_by,reason)
  values(p_prospect,p_consultant,v_actor,'platform assignment');
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'SME_PROSPECT_ASSIGNED_V76','sme_prospects',p_prospect,
    jsonb_build_object('consultant_id',p_consultant,'new_version',v_row.version));
  v_response:=jsonb_build_object('replayed',false,'prospect',app.sme_prospect_card_v76(p_prospect));
  perform app.v76_store_receipt(v_actor,'assign_prospect',p_idempotency_key,v_hash,v_response);return v_response;
end
$$;

create or replace function public.platform_add_prospect_activity_v76(
  p_prospect uuid,p_activity_type text,p_summary text,p_detail text,
  p_occurred_at timestamptz,p_idempotency_key text
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_actor uuid:=auth.uid();v_hash text;v_replay jsonb;v_id uuid;v_response jsonb;v_consultant uuid;
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  if p_activity_type not in (
    'note','call','email','whatsapp','meeting','demo','task','document_sent',
    'proposal_sent','contract_sent','payment','onboarding_session','system'
  ) then
    raise exception 'unsupported manual activity type' using errcode='22023';end if;
  select assigned_consultant_id into v_consultant from public.sme_prospects where id=p_prospect;
  if not found then raise exception 'prospect was not found' using errcode='22023';end if;
  v_hash:=app.v76_sha256_hex(jsonb_build_object('prospect',p_prospect,'type',p_activity_type,
    'summary',p_summary,'detail',p_detail,'occurred_at',p_occurred_at)::text);
  v_replay:=app.v76_replay(v_actor,'add_activity',p_idempotency_key,v_hash);if v_replay is not null then return v_replay;end if;
  insert into public.sme_prospect_activities(prospect_id,consultant_id,activity_type,summary,detail,occurred_at,created_by)
  values(p_prospect,v_consultant,p_activity_type,btrim(p_summary),p_detail,coalesce(p_occurred_at,now()),v_actor) returning id into v_id;
  update public.sme_prospects set updated_at=now(),updated_by=v_actor where id=p_prospect;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'SME_PROSPECT_ACTIVITY_ADDED_V76','sme_prospect_activities',v_id,
    jsonb_build_object('prospect_id',p_prospect,'activity_type',p_activity_type));
  v_response:=jsonb_build_object('replayed',false,'activity',(select to_jsonb(a) from public.sme_prospect_activities a where id=v_id));
  perform app.v76_store_receipt(v_actor,'add_activity',p_idempotency_key,v_hash,v_response);return v_response;
end
$$;

create or replace function public.platform_create_prospect_task_v76(
  p_prospect uuid,p_title text,p_due_at timestamptz,p_assigned_consultant uuid,p_idempotency_key text
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_actor uuid:=auth.uid();v_hash text;v_replay jsonb;v_id uuid;v_response jsonb;
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  if not exists(select 1 from public.sme_prospects where id=p_prospect) then raise exception 'prospect was not found' using errcode='22023';end if;
  if p_assigned_consultant is not null and not exists(select 1 from public.platform_consultants where id=p_assigned_consultant and active) then
    raise exception 'active consultant was not found' using errcode='22023';end if;
  v_hash:=app.v76_sha256_hex(jsonb_build_object('prospect',p_prospect,'title',p_title,'due',p_due_at,'consultant',p_assigned_consultant)::text);
  v_replay:=app.v76_replay(v_actor,'create_task',p_idempotency_key,v_hash);if v_replay is not null then return v_replay;end if;
  insert into public.sme_prospect_tasks(prospect_id,title,due_at,assigned_consultant_id,created_by)
  values(p_prospect,btrim(p_title),p_due_at,p_assigned_consultant,v_actor) returning id into v_id;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'SME_PROSPECT_TASK_CREATED_V76','sme_prospect_tasks',v_id,
    jsonb_build_object('prospect_id',p_prospect,'due_at',p_due_at));
  v_response:=jsonb_build_object('replayed',false,'task',(select to_jsonb(t) from public.sme_prospect_tasks t where id=v_id));
  perform app.v76_store_receipt(v_actor,'create_task',p_idempotency_key,v_hash,v_response);return v_response;
end
$$;

create or replace function public.platform_complete_prospect_task_v76(
  p_task uuid,p_outcome text,p_idempotency_key text
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_actor uuid:=auth.uid();v_hash text;v_replay jsonb;v_row public.sme_prospect_tasks%rowtype;v_response jsonb;
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  v_hash:=app.v76_sha256_hex(jsonb_build_object('task',p_task,'outcome',p_outcome)::text);
  v_replay:=app.v76_replay(v_actor,'complete_task',p_idempotency_key,v_hash);if v_replay is not null then return v_replay;end if;
  update public.sme_prospect_tasks set status='completed',outcome=btrim(p_outcome),completed_at=now()
   where id=p_task and status='open' returning * into v_row;
  if not found then raise exception 'open task was not found' using errcode='22023';end if;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'SME_PROSPECT_TASK_COMPLETED_V76','sme_prospect_tasks',p_task,
    jsonb_build_object('prospect_id',v_row.prospect_id,'outcome',v_row.outcome));
  v_response:=jsonb_build_object('replayed',false,'task',to_jsonb(v_row));
  perform app.v76_store_receipt(v_actor,'complete_task',p_idempotency_key,v_hash,v_response);return v_response;
end
$$;

create or replace function public.platform_move_prospect_stage_v76(
  p_prospect uuid,p_to_stage text,p_expected_version bigint,p_reason_code text default null,
  p_reason_detail text default null,p_commercial_terms jsonb default null,
  p_idempotency_key text default null
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();v_hash text;v_replay jsonb;v_row public.sme_prospects%rowtype;
  v_from text;v_event uuid;v_activity uuid;v_terms_version integer;v_response jsonb;
  v_lost_codes constant text[]:=array[
    'no_response','not_interested','no_budget','timing','chose_competitor',
    'missing_required_feature','procurement_security_blocker','price',
    'internal_priority_changed','business_ceased','duplicate','bad_fit','other'
  ];
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  if not exists(select 1 from public.sme_pipeline_stages where stage_key=p_to_stage) then
    raise exception 'unknown SME stage' using errcode='22023';end if;
  if p_to_stage in ('account_created','onboarding','activated') then
    raise exception 'this SME stage is system-managed and requires conversion evidence'
      using errcode='42501';end if;
  if p_to_stage='lost' and (p_reason_code is null or not (p_reason_code=any(v_lost_codes))) then
    raise exception 'Lost requires a structured reason code' using errcode='22023';end if;
  if p_to_stage='lost' and p_reason_code='other' and length(btrim(coalesce(p_reason_detail,'')))<3 then
    raise exception 'Lost reason other requires detail' using errcode='22023';end if;
  if p_to_stage='client' and (
    p_commercial_terms is null or jsonb_typeof(p_commercial_terms)<>'object'
    or coalesce(p_commercial_terms->>'plan_code','')=''
    or coalesce(p_commercial_terms->>'product_code','')=''
    or coalesce(p_commercial_terms->>'billing_cycle','') not in ('quarterly','half_yearly','annual')
    or coalesce((p_commercial_terms->>'seats')::integer,0)<=0
    or coalesce(p_commercial_terms->>'currency','')!~'^[A-Z]{3}$'
    or coalesce(p_commercial_terms->>'owner_email','') not like '%@%'
    or coalesce(p_commercial_terms->>'contract_status','') not in ('accepted','signed')
  ) then raise exception 'Client requires accepted commercial fields' using errcode='22023';end if;
  v_hash:=app.v76_sha256_hex(jsonb_build_object('prospect',p_prospect,'to',p_to_stage,
    'version',p_expected_version,'reason_code',p_reason_code,'reason_detail',p_reason_detail,
    'commercial_terms',p_commercial_terms)::text);
  v_replay:=app.v76_replay(v_actor,'move_stage',p_idempotency_key,v_hash);if v_replay is not null then return v_replay;end if;
  select * into v_row from public.sme_prospects where id=p_prospect and version=p_expected_version for update;
  if not found then raise exception 'prospect version conflict' using errcode='40001';end if;
  v_from:=v_row.current_stage_key;
  update public.sme_prospects set current_stage_key=p_to_stage,legacy_stage_raw=null,
    stage_entered_at=now(),version=version+1,updated_by=v_actor,updated_at=now()
   where id=p_prospect returning * into v_row;
  insert into public.sme_prospect_stage_history(prospect_id,from_stage_key,to_stage_key,reason_code,reason_detail,actor)
  values(p_prospect,v_from,p_to_stage,p_reason_code,nullif(btrim(p_reason_detail),''),v_actor) returning id into v_event;
  if p_to_stage in ('npu_1','npu_2','npu_3','npu_4','npu_5','npu_6') then
    insert into public.sme_prospect_activities(prospect_id,consultant_id,activity_type,summary,detail,created_by)
    values(p_prospect,v_row.assigned_consultant_id,'npu_attempt',
      upper(replace(p_to_stage,'_',' ')),'Created automatically by the NPU stage transition',v_actor)
    returning id into v_activity;
  end if;
  if p_commercial_terms is not null then
    select coalesce(max(version),0)+1 into v_terms_version from public.sme_commercial_terms where prospect_id=p_prospect;
    insert into public.sme_commercial_terms(
      prospect_id,version,plan_code,product_code,billing_cycle,seats,currency,
      accepted_value_cents,owner_email,onboarding_owner_consultant_id,target_go_live,
      contract_status,accepted_at,notes,created_by
    ) values(p_prospect,v_terms_version,btrim(p_commercial_terms->>'plan_code'),
      btrim(p_commercial_terms->>'product_code'),p_commercial_terms->>'billing_cycle',
      (p_commercial_terms->>'seats')::integer,p_commercial_terms->>'currency',
      coalesce((p_commercial_terms->>'accepted_value_cents')::integer,0),
      lower(btrim(p_commercial_terms->>'owner_email')),
      nullif(p_commercial_terms->>'onboarding_owner_consultant_id','')::uuid,
      nullif(p_commercial_terms->>'target_go_live','')::date,
      p_commercial_terms->>'contract_status',
      case when p_commercial_terms->>'contract_status' in ('accepted','signed')
        then coalesce((p_commercial_terms->>'accepted_at')::timestamptz,now()) else null end,
      p_commercial_terms->>'notes',v_actor);
  end if;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'SME_PROSPECT_STAGE_MOVED_V76','sme_prospects',p_prospect,
    jsonb_build_object('from_stage',v_from,'to_stage',p_to_stage,'reason_code',p_reason_code,
      'new_version',v_row.version,'commercial_terms_version',v_terms_version));
  v_response:=jsonb_build_object('replayed',false,'prospect',app.sme_prospect_card_v76(p_prospect),
    'stage_event',(select to_jsonb(h) from public.sme_prospect_stage_history h where id=v_event),
    'activity',(select to_jsonb(a) from public.sme_prospect_activities a where id=v_activity));
  perform app.v76_store_receipt(v_actor,'move_stage',p_idempotency_key,v_hash,v_response);return v_response;
end
$$;

create or replace function public.platform_stage_prospect_import_v76(
  p_source_system text,p_source_name text,p_rows jsonb,p_idempotency_key text
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();v_hash text;v_replay jsonb;v_batch uuid;v_row jsonb;v_n integer:=0;
  v_stage text;v_status text;v_registration text;v_valid integer:=0;v_unmapped integer:=0;
  v_conflict integer:=0;v_invalid integer:=0;v_response jsonb;
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  if jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows)>1000 then raise exception 'import rows must be an array of at most 1000 objects' using errcode='22023';end if;
  v_hash:=app.v76_sha256_hex(jsonb_build_object('system',p_source_system,'name',p_source_name,'rows',p_rows)::text);
  v_replay:=app.v76_replay(v_actor,'stage_import',p_idempotency_key,v_hash);if v_replay is not null then return v_replay;end if;
  insert into public.sme_prospect_import_batches(source_system,source_name,total_rows,created_by)
  values(btrim(p_source_system),btrim(p_source_name),jsonb_array_length(p_rows),v_actor) returning id into v_batch;
  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_n:=v_n+1;v_stage:=app.map_sme_stage_v76(v_row->>'stage');
    v_registration:=nullif(lower(btrim(v_row->>'registration_number')),'');
    if jsonb_typeof(v_row)<>'object' or (coalesce(v_row->>'legal_name','')='' and coalesce(v_row->>'trading_name','')='') then
      v_status:='invalid';v_invalid:=v_invalid+1;
    elsif v_registration is not null and (
      exists(select 1 from public.sme_companies company
        where lower(btrim(company.registration_number))=v_registration)
      or exists(select 1 from public.sme_prospect_import_rows prior
        where prior.batch_id=v_batch and prior.row_number<v_n
          and lower(btrim(prior.raw_payload->>'registration_number'))=v_registration)
    ) then v_status:='conflict';v_conflict:=v_conflict+1;
    elsif v_stage is null then v_status:='unmapped';v_unmapped:=v_unmapped+1;
    else v_status:='valid';v_valid:=v_valid+1;end if;
    insert into public.sme_prospect_import_rows(
      batch_id,row_number,raw_payload,normalized_payload,raw_stage,mapped_stage_key,row_status,errors
    ) values(v_batch,v_n,v_row,v_row,v_row->>'stage',v_stage,v_status,
      case when v_status='invalid' then array['company_name_required']
           when v_status='conflict' then array['duplicate_registration_number']
           when v_status='unmapped' then array['unmapped_stage'] else '{}' end);
  end loop;
  update public.sme_prospect_import_batches set valid_rows=v_valid,unmapped_rows=v_unmapped,
    conflict_rows=v_conflict,invalid_rows=v_invalid,skipped_rows=v_conflict+v_invalid where id=v_batch;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'SME_PROSPECT_IMPORT_STAGED_V76','sme_prospect_import_batches',v_batch,
    jsonb_build_object('total_rows',v_n,'valid_rows',v_valid,
      'unmapped_rows',v_unmapped,'conflict_rows',v_conflict,'invalid_rows',v_invalid));
  v_response:=jsonb_build_object('replayed',false,'batch_id',v_batch,'status','staged',
    'total_rows',v_n,'valid_rows',v_valid,'unmapped_rows',v_unmapped,
    'conflict_rows',v_conflict,'invalid_rows',v_invalid,'skipped_rows',v_conflict+v_invalid);
  perform app.v76_store_receipt(v_actor,'stage_import',p_idempotency_key,v_hash,v_response);return v_response;
end
$$;

create or replace function public.platform_commit_prospect_import_v76(
  p_batch uuid,p_idempotency_key text
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();v_hash text;v_replay jsonb;v_batch public.sme_prospect_import_batches%rowtype;
  v_row public.sme_prospect_import_rows%rowtype;v_company uuid;v_prospect uuid;v_imported integer:=0;v_response jsonb;
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  v_hash:=app.v76_sha256_hex(jsonb_build_object('batch',p_batch)::text);
  v_replay:=app.v76_replay(v_actor,'commit_import',p_idempotency_key,v_hash);if v_replay is not null then return v_replay;end if;
  select * into v_batch from public.sme_prospect_import_batches where id=p_batch for update;
  if not found or v_batch.status<>'staged' then raise exception 'staged import batch was not found' using errcode='22023';end if;
  for v_row in select * from public.sme_prospect_import_rows
    where batch_id=p_batch and row_status in ('valid','unmapped') order by row_number for update
  loop
    insert into public.sme_companies(legal_name,trading_name,registration_number,industry,sector_key,email,phone)
    values(nullif(btrim(v_row.raw_payload->>'legal_name'),''),nullif(btrim(v_row.raw_payload->>'trading_name'),''),
      nullif(btrim(v_row.raw_payload->>'registration_number'),''),nullif(btrim(v_row.raw_payload->>'industry'),''),
      nullif(btrim(v_row.raw_payload->>'sector_key'),''),nullif(btrim(v_row.raw_payload->>'email'),''),
      nullif(btrim(v_row.raw_payload->>'phone'),'')) returning id into v_company;
    insert into public.sme_prospects(company_id,current_stage_key,legacy_stage_raw,created_by,updated_by)
    values(v_company,v_row.mapped_stage_key,case when v_row.mapped_stage_key is null then v_row.raw_stage end,v_actor,v_actor)
    returning id into v_prospect;
    if coalesce(v_row.raw_payload->>'contact_name','')<>'' and
       (coalesce(v_row.raw_payload->>'contact_email','')<>'' or coalesce(v_row.raw_payload->>'contact_phone','')<>'') then
      insert into public.sme_prospect_contacts(prospect_id,full_name,email,phone,is_primary)
      values(v_prospect,btrim(v_row.raw_payload->>'contact_name'),nullif(btrim(v_row.raw_payload->>'contact_email'),''),
        nullif(btrim(v_row.raw_payload->>'contact_phone'),''),true);
    end if;
    insert into public.sme_prospect_source_lineage(prospect_id,source_system,source_type,external_id,detail,created_by)
    values(v_prospect,v_batch.source_system,'import',nullif(v_row.raw_payload->>'external_id',''),
      jsonb_build_object('batch_id',p_batch,'row_number',v_row.row_number),v_actor);
    if v_row.mapped_stage_key is null then
      insert into public.sme_prospect_data_quality_flags(prospect_id,flag_code,severity,detail)
      values(v_prospect,'unmapped_stage','warning','Legacy stage: '||coalesce(v_row.raw_stage,'(blank)'));
    else
      insert into public.sme_prospect_stage_history(prospect_id,to_stage_key,actor)
      values(v_prospect,v_row.mapped_stage_key,v_actor);
    end if;
    update public.sme_prospect_import_rows set row_status='imported',prospect_id=v_prospect where id=v_row.id;
    v_imported:=v_imported+1;
  end loop;
  update public.sme_prospect_import_batches set status='committed',imported_rows=v_imported,committed_at=now() where id=p_batch;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'SME_PROSPECT_IMPORT_COMMITTED_V76','sme_prospect_import_batches',p_batch,
    jsonb_build_object('imported_rows',v_imported,'unmapped_rows',v_batch.unmapped_rows,
      'conflict_rows',v_batch.conflict_rows,'invalid_rows',v_batch.invalid_rows,
      'skipped_rows',v_batch.skipped_rows));
  v_response:=jsonb_build_object('replayed',false,'batch_id',p_batch,'status','committed',
    'imported_rows',v_imported,'unmapped_rows',v_batch.unmapped_rows,
    'conflict_rows',v_batch.conflict_rows,'invalid_rows',v_batch.invalid_rows,
    'skipped_rows',v_batch.skipped_rows);
  perform app.v76_store_receipt(v_actor,'commit_import',p_idempotency_key,v_hash,v_response);return v_response;
end
$$;

revoke all on function public.platform_get_sme_board_v76(uuid) from public, anon, authenticated;
revoke all on function public.platform_list_prospects_v76(text,uuid,text,integer,timestamp with time zone) from public, anon, authenticated;
revoke all on function public.platform_get_prospect_detail_v76(uuid) from public, anon, authenticated;
revoke all on function public.platform_create_prospect_v76(jsonb,jsonb,text,uuid,jsonb,text[],text) from public, anon, authenticated;
revoke all on function public.platform_update_prospect_v76(uuid,bigint,jsonb,text) from public, anon, authenticated;
revoke all on function public.platform_assign_prospect_v76(uuid,uuid,bigint,text) from public, anon, authenticated;
revoke all on function public.platform_add_prospect_activity_v76(uuid,text,text,text,timestamp with time zone,text) from public, anon, authenticated;
revoke all on function public.platform_create_prospect_task_v76(uuid,text,timestamp with time zone,uuid,text) from public, anon, authenticated;
revoke all on function public.platform_complete_prospect_task_v76(uuid,text,text) from public, anon, authenticated;
revoke all on function public.platform_move_prospect_stage_v76(uuid,text,bigint,text,text,jsonb,text) from public, anon, authenticated;
revoke all on function public.platform_stage_prospect_import_v76(text,text,jsonb,text) from public, anon, authenticated;
revoke all on function public.platform_commit_prospect_import_v76(uuid,text) from public, anon, authenticated;
grant execute on function public.platform_get_sme_board_v76(uuid) to authenticated;
grant execute on function public.platform_list_prospects_v76(text,uuid,text,integer,timestamp with time zone) to authenticated;
grant execute on function public.platform_get_prospect_detail_v76(uuid) to authenticated;
grant execute on function public.platform_create_prospect_v76(jsonb,jsonb,text,uuid,jsonb,text[],text) to authenticated;
grant execute on function public.platform_update_prospect_v76(uuid,bigint,jsonb,text) to authenticated;
grant execute on function public.platform_assign_prospect_v76(uuid,uuid,bigint,text) to authenticated;
grant execute on function public.platform_add_prospect_activity_v76(uuid,text,text,text,timestamp with time zone,text) to authenticated;
grant execute on function public.platform_create_prospect_task_v76(uuid,text,timestamp with time zone,uuid,text) to authenticated;
grant execute on function public.platform_complete_prospect_task_v76(uuid,text,text) to authenticated;
grant execute on function public.platform_move_prospect_stage_v76(uuid,text,bigint,text,text,jsonb,text) to authenticated;
grant execute on function public.platform_stage_prospect_import_v76(text,text,jsonb,text) to authenticated;
grant execute on function public.platform_commit_prospect_import_v76(uuid,text) to authenticated;

commit;
