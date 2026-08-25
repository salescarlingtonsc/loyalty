-- NESTLY v510 — Peekaa Operating System P0/P1: canonical company + CRM foundation.
--
-- This migration deliberately reuses the existing Company (sme_companies) and
-- commercial case (sme_prospects) instead of adding Account/Merchant duplicates.
-- It adds the missing operating contracts: normalized identity, one intake
-- path, explicit ownership, guarded human transitions, exception visibility,
-- and one server-side lead timeline. It also repairs the approved CLOSED_WON
-- handoff so conversion creates only an inactive shell and entitlement derives
-- from exact, independently verified Stripe or manual-payment evidence.

begin;

-- ---------------------------------------------------------------- identity

create table public.sme_company_identity_keys_v510 (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.sme_companies(id) on delete restrict,
  key_type text not null check(key_type in
    ('uen','google_place_id','domain','phone','email','name_postal')),
  key_namespace text not null check(key_namespace ~ '^[a-z][a-z0-9_]{1,63}$'),
  normalized_value text not null check(length(normalized_value) between 2 and 320),
  confidence text not null check(confidence in ('strong','supporting')),
  source_system text not null check(length(btrim(source_system)) between 1 and 80),
  verified_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default clock_timestamp(),
  constraint sme_company_identity_provenance_v510_uk
    unique(company_id,key_type,key_namespace,normalized_value,source_system)
);

create index sme_company_identity_supporting_v510_idx
  on public.sme_company_identity_keys_v510(key_type,key_namespace,normalized_value,company_id)
  where confidence='supporting';

create table public.sme_lead_intakes_v510 (
  id uuid primary key default gen_random_uuid(),
  operation_key uuid not null unique,
  request_hash text not null check(request_hash ~ '^[0-9a-f]{64}$'),
  source_system text not null check(length(btrim(source_system)) between 1 and 80),
  source_type text not null check(source_type in
    ('manual','directory','referral','partner','event','outbound_call','website',
     'demo_request','paid_advertising','organic','social','import','other')),
  external_id text,
  source_payload jsonb not null default '{}'::jsonb check(jsonb_typeof(source_payload)='object'),
  company_payload jsonb not null check(jsonb_typeof(company_payload)='object'),
  contact_payload jsonb check(contact_payload is null or jsonb_typeof(contact_payload)='object'),
  requested_consultant_id uuid references public.platform_consultants(id) on delete set null,
  requested_next_action_at timestamptz,
  status text not null check(status in
    ('received','duplicate_review','committed','existing_merchant','rejected')),
  disposition text,
  company_id uuid references public.sme_companies(id) on delete restrict,
  prospect_id uuid references public.sme_prospects(id) on delete restrict,
  submitted_by uuid not null references auth.users(id) on delete restrict,
  decided_by uuid references auth.users(id) on delete restrict,
  decided_at timestamptz,
  result jsonb not null default '{}'::jsonb check(jsonb_typeof(result)='object'),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);
create index sme_lead_intakes_company_v510_idx
  on public.sme_lead_intakes_v510(company_id,created_at desc) where company_id is not null;
create index sme_lead_intakes_prospect_v510_idx
  on public.sme_lead_intakes_v510(prospect_id,created_at desc) where prospect_id is not null;

create table public.sme_company_identity_match_candidates_v510 (
  id uuid primary key default gen_random_uuid(),
  intake_id uuid not null references public.sme_lead_intakes_v510(id) on delete restrict,
  candidate_company_id uuid not null references public.sme_companies(id) on delete restrict,
  match_basis text not null check(match_basis in
    ('uen','google_place_id','domain','phone','email','name_postal','conflicting_strong_keys')),
  confidence text not null check(confidence in ('strong','supporting','conflict')),
  evidence jsonb not null default '{}'::jsonb check(jsonb_typeof(evidence)='object'),
  status text not null default 'pending' check(status in ('pending','confirmed','rejected')),
  decided_by uuid references auth.users(id) on delete restrict,
  decided_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  unique(intake_id,candidate_company_id,match_basis)
);
create index sme_identity_candidates_company_v510_idx
  on public.sme_company_identity_match_candidates_v510(candidate_company_id,status,created_at desc);

alter table public.sme_company_identity_keys_v510 enable row level security;
alter table public.sme_lead_intakes_v510 enable row level security;
alter table public.sme_company_identity_match_candidates_v510 enable row level security;
revoke all privileges on table public.sme_company_identity_keys_v510 from public,anon,authenticated;
revoke all privileges on table public.sme_lead_intakes_v510 from public,anon,authenticated;
revoke all privileges on table public.sme_company_identity_match_candidates_v510 from public,anon,authenticated;

create or replace function app.v510_normalize_identity(p_type text,p_value text)
returns text language plpgsql immutable
set search_path to 'pg_catalog','pg_temp' as $$
declare v text:=nullif(btrim(coalesce(p_value,'')),'');
begin
  if v is null then return null;end if;
  case p_type
    when 'uen' then return upper(regexp_replace(v,'[^A-Za-z0-9]','','g'));
    when 'google_place_id' then return v;
    when 'domain' then
      v:=lower(regexp_replace(v,'^https?://','','i'));
      v:=regexp_replace(v,'^www\.','','i');
      return nullif(split_part(split_part(v,'/',1),':',1),'');
    when 'phone' then
      v:=regexp_replace(v,'[^0-9]','','g');
      if length(v)=8 then v:='65'||v;end if;
      return case when length(v) between 8 and 15 then '+'||v else null end;
    when 'email' then return lower(v);
    when 'name_postal' then return lower(regexp_replace(v,'[^a-zA-Z0-9]','','g'));
    else raise exception 'unsupported company identity key' using errcode='22023';
  end case;
end $$;

-- Seed identity keys from the two existing strong sources and the useful
-- supporting fields. Existing unique constraints on UEN and Google source ID
-- make the strong-key backfill deterministic; any unexpected conflict fails
-- this migration rather than silently choosing a company.
insert into public.sme_company_identity_keys_v510(
  company_id,key_type,key_namespace,normalized_value,confidence,source_system,verified_at
)
select company.id,'uen','sg',app.v510_normalize_identity('uen',company.registration_number),
  'strong','sme_companies',null
from public.sme_companies company
where app.v510_normalize_identity('uen',company.registration_number) is not null
on conflict on constraint sme_company_identity_provenance_v510_uk do nothing;

insert into public.sme_company_identity_keys_v510(
  company_id,key_type,key_namespace,normalized_value,confidence,source_system
)
select prospect.company_id,key.key_type,key.key_namespace,key.normalized_value,
  'supporting','prospect_contacts'
from public.sme_prospect_contacts contact
join public.sme_prospects prospect on prospect.id=contact.prospect_id
cross join lateral(values
  ('phone','e164',app.v510_normalize_identity('phone',contact.phone)),
  ('email','rfc5321',app.v510_normalize_identity('email',contact.email))
) key(key_type,key_namespace,normalized_value)
where contact.active and key.normalized_value is not null
on conflict on constraint sme_company_identity_provenance_v510_uk do nothing;

insert into public.sme_company_identity_keys_v510(
  company_id,key_type,key_namespace,normalized_value,confidence,source_system,verified_at
)
select source.company_id,'google_place_id','google_places',
  app.v510_normalize_identity('google_place_id',source.source_id),
  'strong','google_places',source.last_synced_at
from public.sme_company_sources source
where source.source='google_places'
  and app.v510_normalize_identity('google_place_id',source.source_id) is not null
on conflict on constraint sme_company_identity_provenance_v510_uk do nothing;

-- V76's UEN uniqueness used only case/outer-whitespace normalization. V510's
-- punctuation-insensitive identity is stronger, so deployment must stop and
-- expose every pre-existing collision instead of silently choosing a Company.
do $$
declare v_conflicts jsonb;
begin
  select jsonb_agg(jsonb_build_object('type',key_type,'namespace',key_namespace,
    'value',normalized_value,'companies',companies) order by key_type,key_namespace,normalized_value)
  into v_conflicts
  from (select key_type,key_namespace,normalized_value,
      array_agg(distinct company_id order by company_id) companies
    from public.sme_company_identity_keys_v510
    where confidence='strong' and key_type in ('uen','google_place_id')
    group by key_type,key_namespace,normalized_value
    having count(distinct company_id)>1) collision;
  if v_conflicts is not null then
    raise exception 'normalized Company identity conflicts require review before v510: %',v_conflicts
      using errcode='23505';
  end if;
  if exists(select 1 from public.sme_company_identity_keys_v510
    where confidence='strong' and key_type='uen'
    group by company_id,key_namespace having count(distinct normalized_value)>1) then
    raise exception 'a Company has contradictory current UEN identities; review is required before v510'
      using errcode='23505';
  end if;
end $$;

create unique index sme_company_identity_strong_v510_uk
  on public.sme_company_identity_keys_v510(key_type,key_namespace,normalized_value)
  where confidence='strong' and key_type in ('uen','google_place_id');
create unique index sme_company_one_current_uen_v510_uk
  on public.sme_company_identity_keys_v510(company_id,key_namespace)
  where confidence='strong' and key_type='uen';

insert into public.sme_company_identity_keys_v510(
  company_id,key_type,key_namespace,normalized_value,confidence,source_system
)
select company.id,key.key_type,key.key_namespace,key.normalized_value,'supporting','sme_companies'
from public.sme_companies company
cross join lateral (values
  ('domain','dns',app.v510_normalize_identity('domain',company.website)),
  ('phone','e164',app.v510_normalize_identity('phone',company.phone)),
  ('email','rfc5321',app.v510_normalize_identity('email',company.email)),
  ('name_postal','sg',app.v510_normalize_identity('name_postal',
    coalesce(company.legal_name,company.trading_name,'')||coalesce(company.address->>'postal_code','')))
) key(key_type,key_namespace,normalized_value)
where key.normalized_value is not null
on conflict on constraint sme_company_identity_provenance_v510_uk do nothing;

create or replace function app.v510_sync_company_identity()
returns trigger language plpgsql
set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin
  if app.v510_normalize_identity('uen',new.registration_number) is not null then
    perform pg_advisory_xact_lock(hashtextextended('v510:uen:sg:'||
      app.v510_normalize_identity('uen',new.registration_number),0));
  end if;
  if app.v510_normalize_identity('domain',new.website) is not null then
    perform pg_advisory_xact_lock(hashtextextended('v510:domain:dns:'||app.v510_normalize_identity('domain',new.website),0));end if;
  if app.v510_normalize_identity('phone',new.phone) is not null then
    perform pg_advisory_xact_lock(hashtextextended('v510:phone:e164:'||app.v510_normalize_identity('phone',new.phone),0));end if;
  if app.v510_normalize_identity('email',new.email) is not null then
    perform pg_advisory_xact_lock(hashtextextended('v510:email:rfc5321:'||app.v510_normalize_identity('email',new.email),0));end if;
  if app.v510_normalize_identity('name_postal',coalesce(new.legal_name,new.trading_name,'')||
      coalesce(new.address->>'postal_code','')) is not null then
    perform pg_advisory_xact_lock(hashtextextended('v510:name_postal:sg:'||
      app.v510_normalize_identity('name_postal',coalesce(new.legal_name,new.trading_name,'')||
        coalesce(new.address->>'postal_code','')),0));end if;
  delete from public.sme_company_identity_keys_v510
  where company_id=new.id and source_system='sme_companies';
  insert into public.sme_company_identity_keys_v510(
    company_id,key_type,key_namespace,normalized_value,confidence,source_system,verified_at
  ) select new.id,key.key_type,key.key_namespace,key.normalized_value,key.confidence,
      'sme_companies',null
    from (values
      ('uen','sg',app.v510_normalize_identity('uen',new.registration_number),'strong'),
      ('domain','dns',app.v510_normalize_identity('domain',new.website),'supporting'),
      ('phone','e164',app.v510_normalize_identity('phone',new.phone),'supporting'),
      ('email','rfc5321',app.v510_normalize_identity('email',new.email),'supporting'),
      ('name_postal','sg',app.v510_normalize_identity('name_postal',
        coalesce(new.legal_name,new.trading_name,'')||coalesce(new.address->>'postal_code','')),'supporting')
    ) key(key_type,key_namespace,normalized_value,confidence)
    where key.normalized_value is not null
    on conflict on constraint sme_company_identity_provenance_v510_uk do nothing;
  return new;
end $$;
drop trigger if exists sme_companies_v510_identity_sync on public.sme_companies;
create trigger sme_companies_v510_identity_sync after insert or update of registration_number,
  website,phone,email,legal_name,trading_name,address on public.sme_companies
  for each row execute function app.v510_sync_company_identity();

create or replace function app.v510_sync_company_source_identity()
returns trigger language plpgsql
set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('v510:place:'||lower(new.source)||':'||
    app.v510_normalize_identity('google_place_id',new.source_id),0));
  if tg_op='UPDATE' then
    delete from public.sme_company_identity_keys_v510 where company_id=old.company_id
      and key_type='google_place_id' and key_namespace=old.source
      and normalized_value=app.v510_normalize_identity('google_place_id',old.source_id);
  end if;
  insert into public.sme_company_identity_keys_v510(company_id,key_type,key_namespace,
    normalized_value,confidence,source_system,verified_at)
  values(new.company_id,'google_place_id',lower(new.source),
    app.v510_normalize_identity('google_place_id',new.source_id),'strong',new.source,clock_timestamp())
  on conflict on constraint sme_company_identity_provenance_v510_uk do nothing;
  return new;
end $$;
drop trigger if exists sme_company_sources_v510_identity_sync on public.sme_company_sources;
create trigger sme_company_sources_v510_identity_sync after insert or update of company_id,source,source_id
  on public.sme_company_sources for each row execute function app.v510_sync_company_source_identity();

create or replace function app.v510_sync_contact_identity()
returns trigger language plpgsql
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_company uuid;v_prospect uuid;
begin
  v_prospect:=case when tg_op='DELETE' then old.prospect_id else new.prospect_id end;
  if tg_op<>'DELETE' and app.v510_normalize_identity('phone',new.phone) is not null then
    perform pg_advisory_xact_lock(hashtextextended('v510:phone:e164:'||app.v510_normalize_identity('phone',new.phone),0));end if;
  if tg_op<>'DELETE' and app.v510_normalize_identity('email',new.email) is not null then
    perform pg_advisory_xact_lock(hashtextextended('v510:email:rfc5321:'||app.v510_normalize_identity('email',new.email),0));end if;
  select prospect.company_id into v_company from public.sme_prospects prospect
  where prospect.id=v_prospect;
  delete from public.sme_company_identity_keys_v510
  where company_id=v_company and source_system='prospect_contacts';
  insert into public.sme_company_identity_keys_v510(company_id,key_type,key_namespace,
    normalized_value,confidence,source_system)
  select v_company,key.key_type,key.key_namespace,key.normalized_value,'supporting','prospect_contacts'
  from public.sme_prospect_contacts contact
  join public.sme_prospects prospect on prospect.id=contact.prospect_id
  cross join lateral(values
    ('phone','e164',app.v510_normalize_identity('phone',contact.phone)),
    ('email','rfc5321',app.v510_normalize_identity('email',contact.email))
  ) key(key_type,key_namespace,normalized_value)
  where prospect.company_id=v_company and contact.active
    and key.normalized_value is not null
  on conflict on constraint sme_company_identity_provenance_v510_uk do nothing;
  if tg_op='DELETE' then return old;else return new;end if;
end $$;
drop trigger if exists sme_prospect_contacts_v510_identity_sync on public.sme_prospect_contacts;
create trigger sme_prospect_contacts_v510_identity_sync after insert or update of email,phone,active or delete
  on public.sme_prospect_contacts for each row execute function app.v510_sync_contact_identity();

create or replace function app.v510_freeze_converted_company_identity()
returns trigger language plpgsql
set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin
  if current_setting('app.v510_identity_change',true) is distinct from 'on'
     and (new.legal_name,new.trading_name,new.registration_number,new.website,new.phone,new.email,new.address)
       is distinct from
       (old.legal_name,old.trading_name,old.registration_number,old.website,old.phone,old.email,old.address)
     and (old.peekaa_business_id is not null or exists(select 1 from public.sme_prospects prospect
       where prospect.company_id=old.id and prospect.converted_business_id is not null)) then
    raise exception 'converted Company identity requires the audited identity-change workflow' using errcode='23514';
  end if;
  return new;
end $$;
drop trigger if exists aa_sme_companies_v510_converted_identity on public.sme_companies;
create trigger aa_sme_companies_v510_converted_identity before update of
  legal_name,trading_name,registration_number,website,phone,email,address on public.sme_companies
  for each row execute function app.v510_freeze_converted_company_identity();

-- ---------------------------------------------------------- lead contracts

alter table public.sme_prospects
  add column if not exists opportunity_kind text not null default 'core_acquisition'
    check(opportunity_kind ~ '^[a-z][a-z0-9_]{1,63}$'),
  add column if not exists ownership_state text not null default 'queued'
    check(ownership_state in ('queued','owned','closed')),
  add column if not exists queue_key text default 'sales_intake'
    check(queue_key is null or queue_key ~ '^[a-z][a-z0-9_]{1,63}$'),
  add column if not exists owner_assigned_at timestamptz,
  add column if not exists next_action_type text not null default 'triage'
    check(next_action_type ~ '^[a-z][a-z0-9_]{1,63}$'),
  add column if not exists last_contact_at timestamptz,
  add column if not exists next_action_task_id uuid references public.sme_prospect_tasks(id) on delete set null;

update public.sme_prospects prospect set next_action_task_id=(
  select candidate.id from public.sme_prospect_tasks candidate
  where candidate.prospect_id=prospect.id and candidate.status='open'
  order by abs(extract(epoch from(candidate.due_at-coalesce(prospect.next_action_at,candidate.due_at)))),
    candidate.created_at desc limit 1)
where prospect.next_action_task_id is null and exists(
  select 1 from public.sme_prospect_tasks candidate
  where candidate.prospect_id=prospect.id and candidate.status='open');

update public.sme_prospects prospect
set ownership_state=case
      when prospect.archived_at is not null or stage.kind in ('closed','won') then 'closed'
      when prospect.assigned_consultant_id is not null then 'owned'
      else 'queued' end,
    queue_key=case when prospect.assigned_consultant_id is null then 'sales_intake' else null end,
    owner_assigned_at=case when prospect.assigned_consultant_id is not null
      then coalesce(prospect.owner_assigned_at,prospect.updated_at,prospect.created_at) end,
    next_action_at=case
      when prospect.archived_at is null and prospect.converted_business_id is null
        and stage.kind not in ('closed','won')
      then coalesce((select task.due_at from public.sme_prospect_tasks task
        where task.id=prospect.next_action_task_id),prospect.next_action_at,clock_timestamp())
      else prospect.next_action_at end,
    next_action_type=case when prospect.next_action_task_id is not null then 'task'
      when prospect.next_action_at is null then 'triage' else prospect.next_action_type end
from public.sme_pipeline_stages stage
where stage.stage_key=prospect.current_stage_key;

update public.sme_prospects prospect set last_contact_at=activity.last_contact_at
from (select prospect_id,max(occurred_at) last_contact_at from public.sme_prospect_activities
  where activity_type in ('call','email','whatsapp','meeting','demo') group by prospect_id) activity
where prospect.id=activity.prospect_id;
update public.sme_prospects prospect set last_contact_at=greatest(
  coalesce(prospect.last_contact_at,outreach.last_contact_at),outreach.last_contact_at)
from (select prospect_id,max(contacted_at) last_contact_at from public.sme_outreach_records group by prospect_id) outreach
where prospect.id=outreach.prospect_id;

alter table public.sme_prospects
  add constraint sme_prospects_v510_ownership_shape check(
    (ownership_state='owned' and assigned_consultant_id is not null and queue_key is null)
    or (ownership_state='queued' and assigned_consultant_id is null and queue_key is not null)
    or ownership_state='closed'
  );

-- One open core-acquisition case per Company; historical closed cases and
-- future non-core opportunity kinds remain possible.
with ranked as (
  select prospect.id,row_number() over(partition by prospect.company_id order by prospect.created_at,prospect.id) ordinal
  from public.sme_prospects prospect
  where prospect.archived_at is null and prospect.converted_business_id is null
    and prospect.current_stage_key not in
      ('not_interested','no_response','invalid_contact','closed_business','do_not_contact','lost')
)
update public.sme_prospects prospect set opportunity_kind='legacy_duplicate'
from ranked where ranked.id=prospect.id and ranked.ordinal>1;

create unique index sme_prospects_one_open_core_v510_uk
  on public.sme_prospects(company_id)
  where opportunity_kind='core_acquisition'
    and archived_at is null
    and converted_business_id is null
    and current_stage_key not in
      ('not_interested','no_response','invalid_contact','closed_business','do_not_contact','lost');

create index sme_prospects_operating_queue_v510_idx
  on public.sme_prospects(ownership_state,queue_key,next_action_at,id)
  where archived_at is null and converted_business_id is null;

insert into public.sme_pipeline_stages(stage_key,label,sort_order,kind,is_system)
values
  ('proposal','Proposal',10,'active',false),
  ('closed_won','Closed won',11,'won',false),
  ('nurture','Nurture',12,'active',false)
on conflict(stage_key) do update set
  label=excluded.label,sort_order=excluded.sort_order,
  kind=excluded.kind,is_system=excluded.is_system;

alter table public.sme_pipeline_stages
  add column if not exists operating_sla interval check(operating_sla is null or operating_sla>interval '0');
update public.sme_pipeline_stages set operating_sla=case stage_key
  when 'new_lead' then interval '1 hour' when 'assigned' then interval '1 day'
  when 'contacted' then interval '2 days' when 'interested' then interval '2 days'
  when 'appointment' then interval '2 days' when 'proposal' then interval '1 day'
  when 'closed_won' then interval '1 day' when 'nurture' then interval '30 days'
  else operating_sla end;

update public.sme_prospects set
  ownership_state=case when assigned_consultant_id is null then 'queued' else 'owned' end,
  queue_key=case when assigned_consultant_id is null then 'sales_intake' else null end,
  owner_assigned_at=case when assigned_consultant_id is not null
    then coalesce(owner_assigned_at,updated_at,created_at) else null end,
  next_action_at=coalesce(next_action_at,clock_timestamp()),
  next_action_type=coalesce(nullif(next_action_type,''),'payment_follow_up')
where current_stage_key='closed_won' and archived_at is null and converted_business_id is null;

-- Dirty legacy rows converge before the guard is installed: the chosen task
-- owns both type and due date, and every over-SLA action becomes actionable
-- now instead of remaining invisible for months.
update public.sme_prospect_tasks task set due_at=least(task.due_at,clock_timestamp()+stage.operating_sla)
from public.sme_prospects prospect join public.sme_pipeline_stages stage
  on stage.stage_key=prospect.current_stage_key
where task.id=prospect.next_action_task_id and task.status='open' and stage.operating_sla is not null;
update public.sme_prospects prospect set next_action_type='task',next_action_at=task.due_at
from public.sme_pipeline_stages stage,public.sme_prospect_tasks task
where stage.stage_key=prospect.current_stage_key and task.id=prospect.next_action_task_id
  and stage.operating_sla is not null and prospect.archived_at is null
  and prospect.converted_business_id is null;
update public.sme_prospects prospect set next_action_type='sla_review',next_action_at=clock_timestamp()
from public.sme_pipeline_stages stage
where stage.stage_key=prospect.current_stage_key and stage.operating_sla is not null
  and prospect.next_action_task_id is null and prospect.next_action_at>clock_timestamp()+stage.operating_sla
  and prospect.archived_at is null and prospect.converted_business_id is null;

do $$
begin
  if exists(select 1 from public.sme_prospects prospect
    join public.sme_pipeline_stages stage on stage.stage_key=prospect.current_stage_key
    left join public.sme_prospect_tasks task on task.id=prospect.next_action_task_id
    where prospect.archived_at is null and prospect.converted_business_id is null
      and (stage.kind='active' or prospect.current_stage_key='closed_won') and (
        prospect.next_action_at is null or nullif(btrim(prospect.next_action_type),'') is null
        or prospect.next_action_at>clock_timestamp()+stage.operating_sla+interval '1 minute'
        or (prospect.next_action_task_id is not null and
          (task.status is distinct from 'open' or task.prospect_id<>prospect.id
            or prospect.next_action_type<>'task' or prospect.next_action_at<>task.due_at)))) then
    raise exception 'v510 lead backfill did not converge canonical ownership/action state';end if;
end $$;

insert into public.sme_stage_entry_requirements(
  stage_key,description,required_keys,system_managed,terminal_confirmation,evidence_schema_version
) values
  ('assigned','A named consultant accepted ownership',array['assigned_consultant','context'],false,false,2),
  ('contacted','A real contact attempt and outcome were recorded',array['contacted_at','channel','context'],false,false,2),
  ('interested','Interest and the next follow-up were recorded',array['context','next_follow_up_at'],false,false,2),
  ('appointment','A dated meeting with an owner and channel/location was recorded',
    array['appointment_at','appointment_owner','channel'],false,false,2),
  ('proposal','A versioned proposal has been issued',array['proposal_issued','context'],false,false,2),
  ('closed_won','Commercial agreement accepted; payment and entitlement remain separate',
    array['explicit_confirmation'],false,true,1),
  ('nurture','The company may be contacted again on a recorded date',
    array['recontact_permission','recontact_at'],false,false,1)
on conflict(stage_key) do update set
  description=excluded.description,required_keys=excluded.required_keys,
  system_managed=excluded.system_managed,
  terminal_confirmation=excluded.terminal_confirmation;

create table public.sme_pipeline_transition_rules_v510 (
  from_stage_key text not null references public.sme_pipeline_stages(stage_key) on delete restrict,
  to_stage_key text not null references public.sme_pipeline_stages(stage_key) on delete restrict,
  requires_owner boolean not null default true,
  requires_next_action boolean not null default true,
  requires_commercial_terms boolean not null default false,
  default_sla interval not null check(default_sla>interval '0'),
  active boolean not null default true,
  primary key(from_stage_key,to_stage_key),
  check(from_stage_key<>to_stage_key)
);
alter table public.sme_pipeline_transition_rules_v510 enable row level security;
revoke all privileges on table public.sme_pipeline_transition_rules_v510 from public,anon,authenticated;

insert into public.sme_pipeline_transition_rules_v510(
  from_stage_key,to_stage_key,requires_owner,requires_next_action,
  requires_commercial_terms,default_sla
) values
  ('new_lead','assigned',true,true,false,interval '1 hour'),
  ('new_lead','contacted',true,true,false,interval '1 day'),
  ('new_lead','nurture',true,true,false,interval '30 days'),
  ('new_lead','lost',false,false,false,interval '1 day'),
  ('assigned','contacted',true,true,false,interval '1 day'),
  ('assigned','nurture',true,true,false,interval '30 days'),
  ('assigned','lost',false,false,false,interval '1 day'),
  ('contacted','interested',true,true,false,interval '2 days'),
  ('contacted','appointment',true,true,false,interval '2 days'),
  ('contacted','nurture',true,true,false,interval '30 days'),
  ('contacted','lost',false,false,false,interval '1 day'),
  ('interested','appointment',true,true,false,interval '2 days'),
  ('interested','proposal',true,true,false,interval '3 days'),
  ('interested','nurture',true,true,false,interval '30 days'),
  ('interested','lost',false,false,false,interval '1 day'),
  ('appointment','interested',true,true,false,interval '2 days'),
  ('appointment','proposal',true,true,false,interval '3 days'),
  ('appointment','nurture',true,true,false,interval '30 days'),
  ('appointment','lost',false,false,false,interval '1 day'),
  ('proposal','interested',true,true,false,interval '2 days'),
  ('proposal','closed_won',true,true,true,interval '1 day'),
  ('proposal','nurture',true,true,false,interval '30 days'),
  ('proposal','lost',false,false,false,interval '1 day'),
  ('nurture','contacted',true,true,false,interval '1 day'),
  ('nurture','lost',false,false,false,interval '1 day'),
  ('lost','nurture',true,true,false,interval '30 days'),
  ('lost','contacted',true,true,false,interval '1 day');

create or replace function app.v510_prospect_operating_guard()
returns trigger language plpgsql
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_kind text;v_system boolean;v_sla interval;
begin
  select kind,is_system,operating_sla into v_kind,v_system,v_sla
  from public.sme_pipeline_stages where stage_key=new.current_stage_key;
  if new.archived_at is null and new.converted_business_id is null
     and (v_kind='active' or new.current_stage_key='closed_won') then
    if not (
      (new.ownership_state='owned' and new.assigned_consultant_id is not null and new.queue_key is null)
      or (new.ownership_state='queued' and new.assigned_consultant_id is null and new.queue_key is not null)
    ) then raise exception 'active lead requires an owner or explicit queue' using errcode='23514';end if;
    if new.next_action_at is null or nullif(btrim(new.next_action_type),'') is null then
      raise exception 'active lead requires a next action and deadline' using errcode='23514';
    end if;
    if v_sla is null or new.next_action_at>clock_timestamp()+v_sla+interval '1 minute' then
      raise exception 'next action exceeds the canonical stage SLA' using errcode='23514';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists sme_prospects_v510_operating_guard on public.sme_prospects;
create trigger sme_prospects_v510_operating_guard
  before insert or update of current_stage_key,archived_at,converted_business_id,
    assigned_consultant_id,ownership_state,queue_key,next_action_at,next_action_type
  on public.sme_prospects for each row execute function app.v510_prospect_operating_guard();

-- Any legacy writer that changes the canonical next action must participate in
-- optimistic concurrency. This prevents a stale stage form from overwriting a
-- follow-up that was scheduled in another tab.
create or replace function app.v510_version_next_action_change()
returns trigger language plpgsql
set search_path to 'pg_catalog','pg_temp' as $$
begin
  if (new.next_action_at,new.next_action_type) is distinct from
     (old.next_action_at,old.next_action_type) and new.version=old.version then
    new.version:=old.version+1;
  end if;
  return new;
end $$;
drop trigger if exists aa_sme_prospects_v510_next_action_version on public.sme_prospects;
create trigger aa_sme_prospects_v510_next_action_version
  before update of next_action_at,next_action_type on public.sme_prospects
  for each row execute function app.v510_version_next_action_change();

create or replace function app.v510_project_canonical_task()
returns trigger language plpgsql
set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin
  if tg_op='INSERT' and new.status='open' then
    perform 1 from public.sme_prospects where id=new.prospect_id for update;
    update public.sme_prospects set next_action_task_id=new.id,next_action_type='task',
      next_action_at=new.due_at,updated_at=clock_timestamp() where id=new.prospect_id;
  elsif tg_op='UPDATE' and old.status='open' and new.status in ('completed','cancelled') then
    update public.sme_prospects set next_action_task_id=null,next_action_type='review_next_action',
      next_action_at=clock_timestamp(),updated_at=clock_timestamp()
    where id=new.prospect_id and next_action_task_id=new.id;
  end if;
  return new;
end $$;
drop trigger if exists sme_prospect_tasks_v510_canonical_projection on public.sme_prospect_tasks;
create trigger sme_prospect_tasks_v510_canonical_projection
  after insert or update of status on public.sme_prospect_tasks
  for each row execute function app.v510_project_canonical_task();

create or replace function app.v510_reject_activity_shadow_action()
returns trigger language plpgsql
set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin
  if new.next_action is not null or new.next_action_owner is not null or new.next_action_due_at is not null then
    raise exception 'activity follow-up must be recorded as the canonical lead task/action' using errcode='23514';end if;
  return new;
end $$;
drop trigger if exists sme_activity_details_v510_no_shadow_action on public.sme_activity_detail_versions;
create trigger sme_activity_details_v510_no_shadow_action
  before insert or update of next_action,next_action_owner,next_action_due_at
  on public.sme_activity_detail_versions for each row execute function app.v510_reject_activity_shadow_action();

-- A commercial win must be able to create the inactive payment/onboarding
-- shell before either Stripe or a manual invoice can collect money.  V79
-- previously required the post-payment `client` stage, while both billing
-- rails required the Business created by this function: an impossible cycle.
-- Keep the proven transactional conversion, but admit canonical CLOSED_WON
-- and scope salespeople to leads they own.
create or replace function public.convert_sme_prospect_v79(
  p_prospect uuid,p_expected_version bigint,p_idempotency_key text
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare
  v_actor uuid:=auth.uid();v_hash text;v_replay jsonb;v_prospect public.sme_prospects%rowtype;
  v_company public.sme_companies%rowtype;v_terms public.sme_commercial_terms%rowtype;
  v_bundle public.sector_bundle_versions%rowtype;v_business public.businesses%rowtype;
  v_duplicate public.businesses%rowtype;v_branch uuid;v_checklist uuid;v_invite jsonb;
  v_response jsonb;v_sector text;v_slug text;v_months integer;v_previous_stage text;
begin
  perform app.require_idempotency_key_v79(p_idempotency_key);
  v_hash:=app.v76_sha256_hex(jsonb_build_object('prospect',p_prospect,'version',p_expected_version)::text);
  perform pg_advisory_xact_lock(hashtextextended('v510:operation:'||v_actor||':convert:'||p_idempotency_key,0));
  v_replay:=app.v76_replay(v_actor,'convert_prospect_v79',p_idempotency_key,v_hash);
  if v_replay is not null then return v_replay;end if;
  select * into v_prospect from public.sme_prospects where id=p_prospect for update;
  if not found then raise exception 'prospect was not found' using errcode='22023';end if;
  if not app.is_platform_operator_v75() and not (
    app.v89_platform_role()='sales_staff' and exists(select 1 from public.platform_consultants consultant
      where consultant.id=v_prospect.assigned_consultant_id and consultant.user_id=v_actor and consultant.active)
  ) then raise exception 'platform operator or owning salesperson access is required' using errcode='42501';end if;
  if v_prospect.converted_business_id is not null then
    return jsonb_build_object('replayed',false,'outcome','already_converted',
      'prospect_id',p_prospect,'business_id',v_prospect.converted_business_id,
      'prospect_version',v_prospect.version);
  end if;
  if v_prospect.version<>p_expected_version then raise exception 'prospect version conflict' using errcode='40001';end if;
  if v_prospect.current_stage_key not in ('closed_won','client') then
    raise exception 'only a CLOSED_WON commercial agreement can create a payment-ready account' using errcode='22023';end if;
  v_previous_stage:=v_prospect.current_stage_key;
  select * into v_company from public.sme_companies where id=v_prospect.company_id;
  select * into v_terms from public.sme_commercial_terms
   where prospect_id=p_prospect and contract_status in ('accepted','signed')
   order by version desc limit 1;
  if not found then raise exception 'latest accepted or signed commercial terms are required' using errcode='22023';end if;
  perform pg_advisory_xact_lock(hashtextextended(
    coalesce(app.normalized_business_identity_v79(v_company.registration_number),'registration:none'),79));
  perform pg_advisory_xact_lock(hashtextextended(
    coalesce(app.normalized_business_identity_v79(coalesce(v_company.legal_name,v_company.trading_name)),'name:none'),79));
  if v_company.peekaa_business_id is not null then
    v_response:=jsonb_build_object('replayed',false,'outcome','duplicate_workspace',
      'prospect_id',p_prospect,'matched_business_id',v_company.peekaa_business_id,
      'match_basis','reviewed_merchant_link');
    perform app.v76_store_receipt(v_actor,'convert_prospect_v79',p_idempotency_key,v_hash,v_response);
    return v_response;
  end if;
  select * into v_duplicate from public.businesses business
   where (v_company.registration_number is not null
      and app.normalized_business_identity_v79(business.registration_number)
        =app.normalized_business_identity_v79(v_company.registration_number))
      or ((v_company.registration_number is null or business.registration_number is null)
        and app.normalized_business_identity_v79(coalesce(business.legal_name,business.name))
         =app.normalized_business_identity_v79(coalesce(v_company.legal_name,v_company.trading_name))
        and not exists(select 1 from public.sme_merchant_match_candidates decision
          where decision.company_id=v_company.id and decision.business_id=business.id
            and decision.match_basis='name_only' and decision.status='rejected'))
   order by business.created_at limit 1;
  if found then
    if v_company.registration_number is null or v_duplicate.registration_number is null then
      insert into public.sme_merchant_match_candidates(company_id,business_id,match_basis)
      values(v_company.id,v_duplicate.id,'name_only') on conflict do nothing;
    end if;
    v_response:=jsonb_build_object('replayed',false,'outcome','duplicate_workspace',
      'prospect_id',p_prospect,'matched_business_id',v_duplicate.id,
      'match_basis',case when v_company.registration_number is not null
        and lower(btrim(v_duplicate.registration_number))=lower(btrim(v_company.registration_number))
        then 'registration_number' else 'normalized_name' end);
    perform app.v76_store_receipt(v_actor,'convert_prospect_v79',p_idempotency_key,v_hash,v_response);
    return v_response;
  end if;
  v_sector:=case when exists(select 1 from public.sector_profiles where sector_key=v_company.sector_key and active)
    then v_company.sector_key when exists(select 1 from public.sector_profiles where sector_key=v_company.industry and active)
    then v_company.industry else 'other' end;
  select * into v_bundle from public.sector_bundle_versions where sector_key=v_sector and status='published';
  if not found then raise exception 'current published sector bundle is required' using errcode='22023';end if;
  v_slug:=trim(both '-' from regexp_replace(lower(coalesce(v_company.trading_name,v_company.legal_name,'business')),'[^a-z0-9]+','-','g'))
    ||'-'||left(replace(p_prospect::text,'-',''),8);
  insert into public.businesses(name,slug,industry,enabled_modules,legal_name,registration_number,source_prospect_id,join_enabled)
  values(coalesce(v_company.trading_name,v_company.legal_name),v_slug,v_sector,v_bundle.modules,
    coalesce(v_company.legal_name,v_company.trading_name),v_company.registration_number,p_prospect,false)
  returning * into v_business;
  insert into public.branches(business_id,name,is_default,active)
  values(v_business.id,coalesce(v_company.trading_name,v_company.legal_name),true,false) returning id into v_branch;
  -- Do not seed tenant loyalty as the platform operator.  The loyalty spine is
  -- deliberately owner-authorised, and the owner does not exist until the
  -- invitation is accepted.  Its mandatory onboarding item remains pending
  -- and the merchant creates the first draft through the normal owner path.
  v_months:=case v_terms.billing_cycle when 'quarterly' then 3 when 'half_yearly' then 6 else 12 end;
  insert into public.subscriptions(business_id,status,currency,billing_provider,billing_cadence,cadence_months,
    plan_code,product_code,commercial_terms_id,seat_limit,base_price_cents,included_seats,
    period_subtotal_cents,period_tax_cents,period_total_cents,payment_status,
    trial_ends_at,current_period_start,current_period_end,note,
    obligation_period_start,obligation_period_end)
  values(v_business.id,'incomplete',v_terms.currency,'manual',v_terms.billing_cycle,v_months,
    v_terms.plan_code,v_terms.product_code,v_terms.id,v_terms.seats,v_terms.accepted_value_cents,
    v_terms.seats,v_terms.accepted_value_cents,0,v_terms.accepted_value_cents,'not_collected',
    v_terms.accepted_at,v_terms.accepted_at,v_terms.accepted_at+make_interval(months=>v_months),
    'Assisted-sale obligation from immutable commercial terms v'||v_terms.version,
    v_terms.accepted_at::date,(v_terms.accepted_at+make_interval(months=>v_months)-interval '1 day')::date);
  insert into public.business_sector_assignments(business_id,bundle_version_id,version,assigned_by)
  values(v_business.id,v_bundle.id,1,v_actor);
  v_invite:=app.issue_workspace_owner_invite_core_v79(v_business.id,p_prospect,v_terms.owner_email,v_actor);
  v_checklist:=app.create_onboarding_checklist_core_v79(v_business.id,p_prospect,v_actor);
  update public.sme_prospects set converted_business_id=v_business.id,converted_at=clock_timestamp(),
    converted_by=v_actor,current_stage_key='account_created',stage_entered_at=clock_timestamp(),
    version=version+1,updated_by=v_actor,updated_at=clock_timestamp() where id=p_prospect returning * into v_prospect;
  insert into public.sme_prospect_stage_history(prospect_id,from_stage_key,to_stage_key,reason_code,reason_detail,actor)
  values(p_prospect,v_previous_stage,'account_created','payment_account_created',
    'Inactive workspace, subscription shell and owner invitation created before payment',v_actor);
  insert into public.sme_prospect_activities(prospect_id,consultant_id,activity_type,summary,detail,created_by)
  values(p_prospect,v_prospect.assigned_consultant_id,'system','Payment-ready account created',
    'v510 CLOSED_WON handoff created an inactive v79 workspace',v_actor);
  perform app.refresh_onboarding_core_v79(v_business.id,v_actor);
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(v_business.id,v_actor,'SME_PROSPECT_CONVERTED_V510','businesses',v_business.id,
    jsonb_build_object('prospect_id',p_prospect,'from_stage',v_previous_stage,'commercial_terms_id',v_terms.id,
      'sector_bundle_version_id',v_bundle.id,'branch_id',v_branch,'checklist_id',v_checklist,'payment_verified',false));
  v_response:=jsonb_build_object('replayed',false,'outcome','converted','prospect_id',p_prospect,
    'prospect_version',v_prospect.version,'business_id',v_business.id,'branch_id',v_branch,
    'checklist_id',v_checklist,'payment_state','pending','owner_invitation',v_invite);
  perform app.v76_store_receipt(v_actor,'convert_prospect_v79',p_idempotency_key,v_hash,
    v_response#-'{owner_invitation,raw_token}');
  return v_response;
end $$;
revoke all on function public.convert_sme_prospect_v79(uuid,bigint,text) from public,anon,authenticated;
grant execute on function public.convert_sme_prospect_v79(uuid,bigint,text) to authenticated;

alter table public.subscriptions
  add column if not exists initial_payment_source text
    check(initial_payment_source is null or initial_payment_source in ('stripe_invoice','manual_payment')),
  add column if not exists initial_payment_evidence_id uuid,
  add column if not exists initial_payment_verified_at timestamptz,
  add column if not exists obligation_period_start date,
  add column if not exists obligation_period_end date,
  add constraint subscriptions_v510_initial_payment_shape check(
    (initial_payment_source is null and initial_payment_evidence_id is null and initial_payment_verified_at is null)
    or (initial_payment_source is not null and initial_payment_evidence_id is not null and initial_payment_verified_at is not null));

-- V156's evidence uploader emits `<uuid>.pdf`, but its recorder was deployed
-- with two regex backslashes under standard_conforming_strings.  PostgreSQL
-- therefore expected a literal backslash before any character and rejected
-- every path the paired uploader generated.  Repair only that exact fragment
-- in the deployed function and fail the migration if its source has drifted.
do $$
declare
  v_definition text;v_bad text;v_good text;
begin
  select pg_get_functiondef(
    'public.platform_record_manual_payment_v156(uuid,bigint,text,date,text,text,uuid)'::regprocedure
  ) into v_definition;
  v_bad:='/[0-9a-f-]+'||chr(92)||chr(92)||'.(pdf|jpg|png)$';
  v_good:='/[0-9a-f-]+'||chr(92)||'.(pdf|jpg|png)$';
  if strpos(v_definition,v_bad)=0 then
    if strpos(v_definition,v_good)=0 then
      raise exception 'manual evidence path validator has an unknown shape';
    end if;
  else
    if length(v_definition)-length(replace(v_definition,v_bad,''))<>length(v_bad) then
      raise exception 'manual evidence path validator occurs an unexpected number of times';
    end if;
    execute replace(v_definition,v_bad,v_good);
  end if;
end $$;

create or replace function app.v510_verified_initial_payment(p_business uuid)
returns jsonb language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
  with obligation as (
    select subscription.* from public.subscriptions subscription
    join public.sme_commercial_terms terms on terms.id=subscription.commercial_terms_id
    where subscription.business_id=p_business and terms.contract_status in ('accepted','signed')
      and terms.accepted_value_cents>0
  ), evidence as (
    select 'stripe_invoice' source,invoice.id evidence_id,invoice.paid_at verified_at
    from obligation join public.billing_provider_invoices invoice
      on invoice.business_id=obligation.business_id
      and invoice.provider_subscription_id=obligation.provider_subscription_id
    where obligation.billing_provider='stripe' and invoice.paid_normalized and invoice.status='paid'
      and invoice.currency=obligation.currency
      and invoice.amount_paid_cents=obligation.period_total_cents
      and invoice.amount_remaining_cents=0 and invoice.total_cents=obligation.period_total_cents
      and invoice.period_start::date=obligation.obligation_period_start
      and (invoice.period_end::date=obligation.obligation_period_end
        or invoice.period_end::date=obligation.obligation_period_end+1)
      and not exists(select 1 from public.billing_adjustments adjustment
        where adjustment.provider_invoice_id=invoice.provider_invoice_id
          and adjustment.adjustment_type in ('refund','chargeback'))
    union all
    select 'manual_payment',payment.id,payment.verified_at
    from obligation join public.platform_subscription_documents_v156 document
      on document.business_id=obligation.business_id and document.document_type='invoice'
    join public.platform_manual_payments_v156 payment
      on payment.invoice_document_id=document.id and payment.status='verified'
    where obligation.billing_provider='manual' and document.provider_invoice_id is null
      and document.currency=obligation.currency
      and document.total_cents=obligation.period_total_cents
      and payment.amount_cents=obligation.period_total_cents
      and document.service_period_start=obligation.obligation_period_start
      and document.service_period_end=obligation.obligation_period_end
  ) select jsonb_build_object('source',source,'evidence_id',evidence_id,'verified_at',verified_at)
    from evidence order by verified_at limit 1
$$;
revoke all on function app.v510_verified_initial_payment(uuid) from public,anon,authenticated;

create or replace function app.v510_has_verified_initial_payment(p_business uuid)
returns boolean language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select app.v510_verified_initial_payment(p_business) is not null
$$;
revoke all on function app.v510_has_verified_initial_payment(uuid) from public,anon,authenticated;

create or replace function app.v510_guard_payment_onboarding_item()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_paid boolean;
begin
  if new.item_key='payment_verified' then
    v_paid:=app.v510_has_verified_initial_payment(new.business_id);
    new.status:=case when v_paid then 'satisfied' else 'pending' end;
    new.evidence:=jsonb_build_object('verified_backend_payment',v_paid);
    new.satisfied_at:=case when v_paid then coalesce(new.satisfied_at,clock_timestamp()) else null end;
    new.satisfied_by:=case when v_paid then coalesce(new.satisfied_by,auth.uid()) else null end;
    new.waived_at:=null;new.waived_by:=null;new.waiver_reason:=null;
  end if;
  return new;
end $$;
drop trigger if exists aa_business_onboarding_payment_v510 on public.business_onboarding_items;
create trigger aa_business_onboarding_payment_v510
  before insert or update on public.business_onboarding_items
  for each row execute function app.v510_guard_payment_onboarding_item();

create or replace function app.v510_add_payment_onboarding_item()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin
  insert into public.business_onboarding_items(checklist_id,business_id,item_key,label,category,
    verification_mode,mandatory,waivable)
  values(new.id,new.business_id,'payment_verified','Initial subscription payment verified',
    'billing','derived',true,false) on conflict(checklist_id,item_key) do nothing;
  return new;
end $$;
drop trigger if exists business_onboarding_checklist_payment_v510 on public.business_onboarding_checklists;
create trigger business_onboarding_checklist_payment_v510
  after insert on public.business_onboarding_checklists
  for each row execute function app.v510_add_payment_onboarding_item();

insert into public.business_onboarding_items(checklist_id,business_id,item_key,label,category,
  verification_mode,mandatory,waivable)
select checklist.id,checklist.business_id,'payment_verified','Initial subscription payment verified',
  'billing','derived',true,false
from public.business_onboarding_checklists checklist
where checklist.status<>'activated'
on conflict(checklist_id,item_key) do nothing;

create or replace function app.v510_sync_payment_readiness(p_business uuid,p_actor uuid)
returns void language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_evidence jsonb:=app.v510_verified_initial_payment(p_business);v_activated boolean;
begin
  select activated_at is not null into v_activated from public.businesses where id=p_business for update;
  update public.subscriptions set
    status=case when v_evidence is not null then 'active' when v_activated then 'past_due' else 'incomplete' end,
    payment_status=case when v_evidence is not null then 'paid' when v_activated then 'action_required' else 'not_collected' end,
    last_paid_at=case when v_evidence is not null then (v_evidence->>'verified_at')::timestamptz else null end,
    last_paid_invoice_id=case when v_evidence is not null then v_evidence->>'evidence_id' else null end,
    initial_payment_source=case when v_evidence is not null then v_evidence->>'source' else null end,
    initial_payment_evidence_id=case when v_evidence is not null then (v_evidence->>'evidence_id')::uuid else null end,
    initial_payment_verified_at=case when v_evidence is not null then (v_evidence->>'verified_at')::timestamptz else null end,
    updated_at=clock_timestamp()
  where business_id=p_business;
  if v_evidence is null and v_activated then
    update public.businesses set join_enabled=false,updated_at=clock_timestamp() where id=p_business;
    update public.branches set active=false,updated_at=clock_timestamp() where business_id=p_business and active;
  end if;
  update public.business_onboarding_items set updated_at=clock_timestamp(),
    satisfied_by=coalesce(p_actor,satisfied_by)
  where business_id=p_business and item_key='payment_verified';
  if found then perform app.recompute_onboarding_status_v79(p_business,p_actor);end if;
end $$;
revoke all on function app.v510_sync_payment_readiness(uuid,uuid) from public,anon,authenticated;

create or replace function app.v510_project_stripe_payment_readiness()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin
  perform app.v510_sync_payment_readiness(new.business_id,null);
  return new;
end $$;
drop trigger if exists billing_provider_invoices_payment_v510 on public.billing_provider_invoices;
create trigger billing_provider_invoices_payment_v510
  after insert or update of paid_normalized,status,amount_paid_cents,amount_remaining_cents on public.billing_provider_invoices
  for each row execute function app.v510_project_stripe_payment_readiness();

create or replace function app.v510_project_subscription_payment_readiness()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin
  perform app.v510_sync_payment_readiness(new.business_id,null);
  return new;
end $$;
drop trigger if exists subscriptions_payment_link_v510 on public.subscriptions;
create trigger subscriptions_payment_link_v510
  after update of billing_provider,provider_subscription_id,commercial_terms_id,
    currency,period_total_cents,obligation_period_start,obligation_period_end
  on public.subscriptions for each row
  when ((old.billing_provider,old.provider_subscription_id,old.commercial_terms_id,
    old.currency,old.period_total_cents,old.obligation_period_start,old.obligation_period_end)
    is distinct from
    (new.billing_provider,new.provider_subscription_id,new.commercial_terms_id,
    new.currency,new.period_total_cents,new.obligation_period_start,new.obligation_period_end))
  execute function app.v510_project_subscription_payment_readiness();

create or replace function app.v510_project_adjustment_payment_readiness()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin perform app.v510_sync_payment_readiness(new.business_id,null);return new;end $$;
drop trigger if exists billing_adjustments_payment_v510 on public.billing_adjustments;
create trigger billing_adjustments_payment_v510 after insert on public.billing_adjustments
  for each row when(new.adjustment_type in ('refund','chargeback'))
  execute function app.v510_project_adjustment_payment_readiness();

create or replace function app.v510_guard_business_activation()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin
  if new.activated_at is not null and old.activated_at is null
     and not app.v510_has_verified_initial_payment(new.id) then
    raise exception 'business activation requires verified initial payment' using errcode='23514';
  end if;
  if new.activated_at is not null and old.activated_at is null then new.join_enabled:=true;end if;
  return new;
end $$;
drop trigger if exists aa_businesses_payment_activation_v510 on public.businesses;
create trigger aa_businesses_payment_activation_v510
  before update of activated_at on public.businesses
  for each row execute function app.v510_guard_business_activation();

create or replace function app.v510_guard_inactive_shell_rails()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_business uuid;v_activated boolean;v_assisted boolean;v_row jsonb:=to_jsonb(new);
begin
  v_business:=(v_row->>'business_id')::uuid;
  select business.activated_at is not null,business.source_prospect_id is not null
    into v_activated,v_assisted from public.businesses business where business.id=v_business;
  if tg_table_name='staff' and coalesce((v_row->>'active')::boolean,false)
     and v_row->>'role'='owner' and v_assisted
     and not app.v510_has_verified_initial_payment(v_business) then
    raise exception 'workspace owner access requires verified initial payment' using errcode='23514';end if;
  if tg_table_name='branches' and coalesce((v_row->>'active')::boolean,false)
     and v_assisted and not v_activated then
    raise exception 'active branch requires activated Business' using errcode='23514';end if;
  if tg_table_name='business_customer_join_qr_v89' and v_row->>'status'='active'
     and v_assisted and not v_activated then
    raise exception 'customer join QR requires activated Business' using errcode='23514';end if;
  return new;
end $$;
drop trigger if exists aa_staff_inactive_shell_v510 on public.staff;
create trigger aa_staff_inactive_shell_v510 before insert or update of active,role on public.staff
  for each row execute function app.v510_guard_inactive_shell_rails();
drop trigger if exists aa_branches_inactive_shell_v510 on public.branches;
create trigger aa_branches_inactive_shell_v510 before insert or update of active on public.branches
  for each row execute function app.v510_guard_inactive_shell_rails();
drop trigger if exists aa_join_qr_inactive_shell_v510 on public.business_customer_join_qr_v89;
create trigger aa_join_qr_inactive_shell_v510 before insert or update of status on public.business_customer_join_qr_v89
  for each row execute function app.v510_guard_inactive_shell_rails();

update public.businesses set join_enabled=false,updated_at=clock_timestamp()
where source_prospect_id is not null and activated_at is null;
update public.branches branch set active=false,updated_at=clock_timestamp()
from public.businesses business where business.id=branch.business_id
  and business.source_prospect_id is not null and business.activated_at is null and branch.active;
update public.business_customer_join_qr_v89 qr set status='revoked',revoked_at=clock_timestamp()
from public.businesses business where business.id=qr.business_id
  and business.source_prospect_id is not null and business.activated_at is null and qr.status='active';

-- Legacy billing code may project verified payment into the historical
-- `client` handoff stage. It may never manufacture the commercial agreement:
-- CLOSED_WON must already exist and payment evidence must be backend truth.
create or replace function app.v510_guard_paid_handoff()
returns trigger language plpgsql
set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin
  if new.current_stage_key='client' and old.current_stage_key is distinct from 'client' then
    if old.current_stage_key<>'closed_won' then
      raise exception 'verified payment cannot replace CLOSED_WON commercial agreement' using errcode='23514';end if;
    if new.converted_business_id is null
       or not app.v510_has_verified_initial_payment(new.converted_business_id) then
      raise exception 'client handoff requires verified backend payment evidence' using errcode='23514';end if;
    new.next_action_type:='create_account';
    new.next_action_at:=clock_timestamp()+interval '1 day';
  end if;
  return new;
end $$;
drop trigger if exists ab_sme_prospects_v510_paid_handoff on public.sme_prospects;
create trigger ab_sme_prospects_v510_paid_handoff
  before update of current_stage_key on public.sme_prospects
  for each row execute function app.v510_guard_paid_handoff();

create or replace function app.v510_project_verified_manual_payment()
returns trigger language plpgsql
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_prospect uuid;v_business uuid;v_previous text;
begin
  if new.status='verified' and old.status is distinct from 'verified' then
    select document.prospect_id,document.business_id into v_prospect,v_business
    from public.platform_subscription_documents_v156 document
    where document.id=new.invoice_document_id;
    if v_business is not null then perform app.v510_sync_payment_readiness(v_business,new.verified_by);end if;
    if v_prospect is not null and v_business is not null
       and app.v510_has_verified_initial_payment(v_business) then
      select current_stage_key into v_previous from public.sme_prospects where id=v_prospect for update;
      if v_previous='closed_won' then
        update public.sme_prospects set current_stage_key='client',stage_entered_at=clock_timestamp(),
          next_action_type='create_account',next_action_at=clock_timestamp()+interval '1 day',
          version=version+1,updated_at=clock_timestamp() where id=v_prospect;
        insert into public.sme_prospect_stage_history(prospect_id,from_stage_key,to_stage_key,
          reason_code,reason_detail,occurred_at)
        values(v_prospect,'closed_won','client','verified_payment','Verified manual payment '||new.id,new.verified_at);
      end if;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists platform_manual_payments_v510_crm_handoff on public.platform_manual_payments_v156;
create trigger platform_manual_payments_v510_crm_handoff
  after update of status on public.platform_manual_payments_v156
  for each row execute function app.v510_project_verified_manual_payment();

-- V156 conservatively labels every manual receipt as requiring a human
-- entitlement review. Preserve that exception for mismatched payments, but
-- exact independently verified payment must produce one canonical truth and
-- no open task asking a person to decide entitlement again.
create or replace function app.v510_normalize_manual_entitlement_event()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin
  if new.source_type='manual_payment' and new.lifecycle_status='payment_received'
     and new.business_id is not null and app.v510_has_verified_initial_payment(new.business_id) then
    new.snapshot:=jsonb_set(coalesce(new.snapshot,'{}'::jsonb),'{entitlement_status}',
      '"verified_exact_payment"'::jsonb,true);
  end if;
  return new;
end $$;
drop trigger if exists aa_manual_entitlement_event_v510 on public.platform_subscription_lifecycle_events_v156;
create trigger aa_manual_entitlement_event_v510 before insert
  on public.platform_subscription_lifecycle_events_v156 for each row
  execute function app.v510_normalize_manual_entitlement_event();

create or replace function app.v510_close_obsolete_manual_entitlement_task()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin
  if new.task_key like 'onboarding:manual:%'
     and new.title='Review manual-payment entitlement and schedule onboarding'
     and new.business_id is not null and app.v510_has_verified_initial_payment(new.business_id) then
    new.status:='cancelled';
    new.resolution:='Exact accepted payment verified automatically by v510';
    new.completed_at:=null;
  end if;
  return new;
end $$;
drop trigger if exists aa_manual_entitlement_task_v510 on public.platform_subscription_tasks_v156;
create trigger aa_manual_entitlement_task_v510 before insert or update
  on public.platform_subscription_tasks_v156 for each row
  execute function app.v510_close_obsolete_manual_entitlement_task();

create or replace function app.v510_project_contact_activity()
returns trigger language plpgsql
set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin
  if tg_table_name='sme_prospect_activities' then
    if new.activity_type in ('call','email','whatsapp','meeting','demo') then
      update public.sme_prospects set last_contact_at=greatest(coalesce(last_contact_at,new.occurred_at),new.occurred_at)
      where id=new.prospect_id;
    end if;
  else
    update public.sme_prospects set
      last_contact_at=greatest(coalesce(last_contact_at,coalesce(new.contacted_at,new.created_at)),
        coalesce(new.contacted_at,new.created_at)),
      next_action_type=case when new.next_follow_up_at is not null then 'follow_up' else next_action_type end,
      next_action_at=coalesce(new.next_follow_up_at,next_action_at)
    where id=new.prospect_id;
  end if;
  return new;
end $$;
drop trigger if exists sme_prospect_activities_v510_projection on public.sme_prospect_activities;
create trigger sme_prospect_activities_v510_projection after insert on public.sme_prospect_activities
  for each row execute function app.v510_project_contact_activity();
drop trigger if exists sme_outreach_records_v510_projection on public.sme_outreach_records;
create trigger sme_outreach_records_v510_projection after insert on public.sme_outreach_records
  for each row execute function app.v510_project_contact_activity();

-- --------------------------------------------------------------- ingestion

create or replace function public.platform_ingest_lead_v510(
  p_company jsonb,
  p_primary_contact jsonb default null,
  p_source jsonb default '{}'::jsonb,
  p_consultant uuid default null,
  p_next_action_at timestamptz default null,
  p_operation_key uuid default null
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare
  v_actor uuid:=auth.uid();v_role text:=app.v89_platform_role();v_self uuid;
  v_hash text;v_replay jsonb;v_intake uuid;v_company uuid;v_prospect uuid;
  v_source_system text;v_source_type text;v_external_id text;v_owner uuid;
  v_uen_namespace text;v_place_namespace text;
  v_uen text;v_place text;v_domain text;v_phone text;v_email text;v_name_postal text;
  v_strong uuid[];v_support uuid[];v_all uuid[];v_merchant_matches uuid[];v_result jsonb;
  v_is_merchant boolean:=false;v_prospect_created boolean:=false;v_strong_conflict boolean:=false;
begin
  perform app.v297_assert_prospecting('rw');
  if p_operation_key is null then raise exception 'operation key is required' using errcode='22023';end if;
  if jsonb_typeof(p_company)<>'object'
     or (p_primary_contact is not null and jsonb_typeof(p_primary_contact)<>'object')
     or jsonb_typeof(coalesce(p_source,'{}'::jsonb))<>'object' then
    raise exception 'company, contact and source payloads are invalid' using errcode='22023';
  end if;
  if length(btrim(coalesce(p_company->>'legal_name',p_company->>'trading_name',''))) < 2 then
    raise exception 'company name is required' using errcode='22023';
  end if;
  if p_next_action_at is not null and p_next_action_at>clock_timestamp()+interval '1 hour 1 minute' then
    raise exception 'new lead next action exceeds the one-hour intake SLA' using errcode='22023';end if;
  v_source_system:=coalesce(nullif(btrim(p_source->>'source_system'),''),'platform_console');
  v_source_type:=coalesce(nullif(btrim(p_source->>'source_type'),''),'manual');
  if v_source_type not in ('manual','directory','referral','partner','event','outbound_call',
    'website','demo_request','paid_advertising','organic','social','import','other') then
    raise exception 'unsupported lead source type' using errcode='22023';end if;
  v_external_id:=nullif(btrim(p_source->>'external_id'),'');
  v_uen_namespace:=lower(coalesce(nullif(btrim(p_company->>'registration_jurisdiction'),''),'sg'));
  v_place_namespace:=lower(coalesce(nullif(btrim(p_company->>'place_provider'),''),v_source_system));
  v_hash:=app.v76_sha256_hex(jsonb_build_object('company',p_company,'contact',p_primary_contact,
    'source',p_source,'consultant',p_consultant,'next_action_at',p_next_action_at)::text);
  perform pg_advisory_xact_lock(hashtextextended('v510:operation:'||v_actor||':ingest:'||p_operation_key,0));
  v_replay:=app.v76_replay(v_actor,'ingest_lead_v510',p_operation_key::text,v_hash);
  if v_replay is not null then return v_replay;end if;

  if v_role='sales_staff' then
    v_self:=app.v226_self_consultant();
    if v_self is null then raise exception 'salesperson is not linked to an active consultant' using errcode='42501';end if;
    if p_consultant is not null and p_consultant<>v_self then
      raise exception 'salesperson may create only an owned lead' using errcode='42501';end if;
    v_owner:=v_self;
  elsif p_consultant is not null then
    if not app.is_super_admin() then raise exception 'only super admin may assign another consultant' using errcode='42501';end if;
    if not exists(select 1 from public.platform_consultants where id=p_consultant and active) then
      raise exception 'active consultant was not found' using errcode='22023';end if;
    v_owner:=p_consultant;
  end if;

  v_uen:=app.v510_normalize_identity('uen',p_company->>'registration_number');
  v_place:=app.v510_normalize_identity('google_place_id',coalesce(p_company->>'place_id',
    case when v_source_system='google_places' then v_external_id end));
  v_domain:=app.v510_normalize_identity('domain',p_company->>'website');
  v_phone:=app.v510_normalize_identity('phone',coalesce(p_company->>'phone',p_primary_contact->>'phone'));
  v_email:=app.v510_normalize_identity('email',coalesce(p_company->>'email',p_primary_contact->>'email'));
  v_name_postal:=app.v510_normalize_identity('name_postal',
    coalesce(p_company->>'legal_name',p_company->>'trading_name','')||
    coalesce(p_company->>'postal_code',p_company#>>'{address,postal_code}',''));
  if (v_uen is not null and v_uen_namespace!~'^[a-z][a-z0-9_]{1,63}$')
     or (v_place is not null and v_place_namespace!~'^[a-z][a-z0-9_]{1,63}$') then
    raise exception 'identity namespace is invalid' using errcode='22023';end if;

  if v_uen is not null then perform pg_advisory_xact_lock(hashtextextended('v510:uen:'||v_uen_namespace||':'||v_uen,0));end if;
  if v_place is not null then perform pg_advisory_xact_lock(hashtextextended('v510:place:'||v_place_namespace||':'||v_place,0));end if;
  if v_domain is not null then perform pg_advisory_xact_lock(hashtextextended('v510:domain:dns:'||v_domain,0));end if;
  if v_phone is not null then perform pg_advisory_xact_lock(hashtextextended('v510:phone:e164:'||v_phone,0));end if;
  if v_email is not null then perform pg_advisory_xact_lock(hashtextextended('v510:email:rfc5321:'||v_email,0));end if;
  if v_name_postal is not null then perform pg_advisory_xact_lock(hashtextextended('v510:name_postal:sg:'||v_name_postal,0));end if;

  insert into public.sme_lead_intakes_v510(
    operation_key,request_hash,source_system,source_type,external_id,
    source_payload,company_payload,contact_payload,requested_consultant_id,requested_next_action_at,status,submitted_by
  ) values(p_operation_key,v_hash,v_source_system,v_source_type,v_external_id,
    coalesce(p_source,'{}'::jsonb),p_company,p_primary_contact,v_owner,p_next_action_at,'received',v_actor) returning id into v_intake;

  select coalesce(array_agg(distinct key.company_id),'{}'::uuid[]) into v_strong
  from public.sme_company_identity_keys_v510 key
  where key.confidence='strong' and (
    (key.key_type='uen' and key.key_namespace=v_uen_namespace and key.normalized_value=v_uen)
    or (key.key_type='google_place_id' and key.key_namespace=v_place_namespace and key.normalized_value=v_place));
  select coalesce(array_agg(distinct key.company_id),'{}'::uuid[]) into v_support
  from public.sme_company_identity_keys_v510 key
  where key.confidence='supporting' and (
    (key.key_type='domain' and key.key_namespace='dns' and key.normalized_value=v_domain)
    or (key.key_type='phone' and key.key_namespace='e164' and key.normalized_value=v_phone)
    or (key.key_type='email' and key.key_namespace='rfc5321' and key.normalized_value=v_email)
    or (key.key_type='name_postal' and key.key_namespace='sg' and key.normalized_value=v_name_postal));
  select coalesce(array_agg(distinct value),'{}'::uuid[]) into v_all
  from unnest(coalesce(v_strong,'{}'::uuid[])||coalesce(v_support,'{}'::uuid[])) value;
  if cardinality(v_strong)=1 and v_uen is not null then
    select exists(select 1 from public.sme_company_identity_keys_v510 key
      where key.company_id=v_strong[1] and key.key_type='uen' and key.key_namespace=v_uen_namespace
        and key.confidence='strong' and key.normalized_value<>v_uen) into v_strong_conflict;
  end if;

  if v_strong_conflict or cardinality(v_strong)>1 or (cardinality(v_strong)=1 and exists(
    select 1 from unnest(v_support) candidate where candidate<>v_strong[1]
  )) or (cardinality(v_strong)=0 and cardinality(v_support)>0) then
    insert into public.sme_company_identity_match_candidates_v510(
      intake_id,candidate_company_id,match_basis,confidence,evidence
    ) select v_intake,candidate,
      case when v_strong_conflict or cardinality(v_strong)>1 then 'conflicting_strong_keys'
        when candidate=any(v_strong) then coalesce(case when v_uen is not null then 'uen' else 'google_place_id' end,'conflicting_strong_keys')
        when v_domain is not null then 'domain' when v_phone is not null then 'phone'
        when v_email is not null then 'email' else 'name_postal' end,
      case when v_strong_conflict or cardinality(v_strong)>1 then 'conflict'
        when candidate=any(v_strong) then 'strong' else 'supporting' end,
      jsonb_build_object('uen',v_uen,'place_id',v_place,'domain',v_domain,
        'phone',v_phone,'email',v_email,'name_postal',v_name_postal)
    from unnest(v_all) candidate on conflict do nothing;
    v_result:=jsonb_build_object('disposition','duplicate_review','intake_id',v_intake,
      'candidate_company_ids',to_jsonb(v_all));
    update public.sme_lead_intakes_v510 set status='duplicate_review',
      disposition='duplicate_review',result=v_result,updated_at=clock_timestamp() where id=v_intake;
    perform app.v76_store_receipt(v_actor,'ingest_lead_v510',p_operation_key::text,v_hash,v_result);
    return v_result;
  end if;

  -- Compare the incoming identity directly with live merchants before a
  -- prospect can be materialised.  A differing pair of strong UENs always
  -- defeats the weaker name+postal agreement.
  select coalesce(array_agg(match.id order by match.rank,match.id),'{}'::uuid[])
    into v_merchant_matches
  from (select business.id,case
      when v_uen is not null and app.v510_normalize_identity('uen',business.registration_number)=v_uen then 1
      when v_place is not null and app.v510_normalize_identity('google_place_id',business.place_id)=v_place then 2
      else 3 end rank
    from public.businesses business
    where (v_uen is not null and app.v510_normalize_identity('uen',business.registration_number)=v_uen)
      or (v_place is not null and app.v510_normalize_identity('google_place_id',business.place_id)=v_place)
      or (v_name_postal is not null and business.postal_code is not null
        and app.v510_normalize_identity('name_postal',coalesce(business.legal_name,business.name)||business.postal_code)=v_name_postal
        and not (v_uen is not null and business.registration_number is not null
          and app.v510_normalize_identity('uen',business.registration_number)<>v_uen))) match;
  if cardinality(v_merchant_matches)=1 then
    select company.id into v_company from public.sme_companies company
      where company.peekaa_business_id=v_merchant_matches[1] order by company.created_at limit 1;
  end if;

  if v_company is not null then null;
  elsif cardinality(v_strong)=1 then v_company:=v_strong[1];else
    insert into public.sme_companies(
      legal_name,trading_name,registration_number,industry,sector_key,website,phone,email,address
    ) values(
      nullif(btrim(p_company->>'legal_name'),''),nullif(btrim(p_company->>'trading_name'),''),
      nullif(btrim(p_company->>'registration_number'),''),nullif(btrim(p_company->>'industry'),''),
      nullif(btrim(p_company->>'sector_key'),''),nullif(btrim(p_company->>'website'),''),
      nullif(btrim(p_company->>'phone'),''),nullif(btrim(p_company->>'email'),''),
      coalesce(p_company->'address','{}'::jsonb)
    ) returning id into v_company;
  end if;

  if cardinality(v_merchant_matches)=1 then
    update public.sme_companies set peekaa_business_id=v_merchant_matches[1],
      merchant_linked_at=clock_timestamp(),merchant_link_basis=case
        when v_uen is not null then 'registration_number'
        when v_place is not null then 'place_id' else 'name_postal' end
    where id=v_company;
  elsif cardinality(v_merchant_matches)>1 then
    insert into public.sme_merchant_match_candidates(company_id,business_id,match_basis)
      select v_company,id,'name_postal' from unnest(v_merchant_matches) id on conflict do nothing;
    v_result:=jsonb_build_object('disposition','existing_merchant','intake_id',v_intake,
      'company_id',v_company,'candidate_business_ids',to_jsonb(v_merchant_matches),'review_required',true);
    update public.sme_lead_intakes_v510 set status='existing_merchant',disposition='existing_merchant',
      company_id=v_company,result=v_result,updated_at=clock_timestamp() where id=v_intake;
    perform app.v76_store_receipt(v_actor,'ingest_lead_v510',p_operation_key::text,v_hash,v_result);
    return v_result;
  end if;

  update public.sme_companies set registration_number=p_company->>'registration_number',
    updated_at=clock_timestamp()
  where id=v_company and v_uen is not null and nullif(btrim(registration_number),'') is null;

  insert into public.sme_company_identity_keys_v510(
    company_id,key_type,key_namespace,normalized_value,confidence,source_system,verified_at,created_by
  ) select v_company,key.key_type,key.key_namespace,key.normalized_value,key.confidence,v_source_system,
      case when key.key_type='google_place_id' and v_source_system in ('google_places','google_business_profile')
        then clock_timestamp() end,v_actor
    from (values
      ('uen',v_uen_namespace,v_uen,'strong'),('google_place_id',v_place_namespace,v_place,'strong'),
      ('domain','dns',v_domain,'supporting'),
      ('phone','e164',app.v510_normalize_identity('phone',p_company->>'phone'),'supporting'),
      ('email','rfc5321',app.v510_normalize_identity('email',p_company->>'email'),'supporting'),
      ('name_postal','sg',v_name_postal,'supporting')
    ) key(key_type,key_namespace,normalized_value,confidence)
    where key.normalized_value is not null and not (key.confidence='strong' and exists(
      select 1 from public.sme_company_identity_keys_v510 existing
      where existing.company_id=v_company and existing.key_type=key.key_type
        and existing.key_namespace=key.key_namespace and existing.normalized_value=key.normalized_value
        and existing.confidence='strong'))
    on conflict on constraint sme_company_identity_provenance_v510_uk do nothing;

  select company.peekaa_business_id is not null or exists(
    select 1 from public.sme_prospects converted
    where converted.company_id=company.id and converted.converted_business_id is not null
  ) into v_is_merchant
  from public.sme_companies company where company.id=v_company;
  if v_is_merchant then
    v_result:=jsonb_build_object('disposition','existing_merchant','intake_id',v_intake,
      'company_id',v_company,'business_id',coalesce(
        (select peekaa_business_id from public.sme_companies where id=v_company),
        (select converted_business_id from public.sme_prospects where company_id=v_company
          and converted_business_id is not null order by converted_at desc nulls last limit 1)));
    update public.sme_lead_intakes_v510 set status='existing_merchant',disposition='existing_merchant',
      company_id=v_company,result=v_result,updated_at=clock_timestamp() where id=v_intake;
    perform app.v76_store_receipt(v_actor,'ingest_lead_v510',p_operation_key::text,v_hash,v_result);
    return v_result;
  end if;

  select prospect.id into v_prospect from public.sme_prospects prospect
  where prospect.company_id=v_company and prospect.opportunity_kind='core_acquisition'
    and prospect.archived_at is null and prospect.converted_business_id is null
    and prospect.current_stage_key not in
      ('not_interested','no_response','invalid_contact','closed_business','do_not_contact','lost')
  order by prospect.created_at limit 1 for update;
  if not found then
    insert into public.sme_prospects(
      company_id,current_stage_key,assigned_consultant_id,opportunity_kind,
      ownership_state,queue_key,owner_assigned_at,next_action_type,next_action_at,
      created_by,updated_by
    ) values(v_company,case when v_owner is null then 'new_lead' else 'assigned' end,v_owner,
      'core_acquisition',case when v_owner is null then 'queued' else 'owned' end,
      case when v_owner is null then 'sales_intake' end,
      case when v_owner is not null then clock_timestamp() end,
      case when v_owner is null then 'assign_owner' else 'first_contact' end,
      coalesce(p_next_action_at,clock_timestamp()+interval '1 hour'),v_actor,v_actor)
    returning id into v_prospect;
    v_prospect_created:=true;
    insert into public.sme_prospect_stage_history(prospect_id,to_stage_key,reason_code,reason_detail,actor)
    values(v_prospect,case when v_owner is null then 'new_lead' else 'assigned' end,
      'lead_ingested','Canonical v510 lead intake',v_actor);
    if v_owner is not null then
      insert into public.sme_prospect_assignments(prospect_id,consultant_id,assigned_by,reason)
      values(v_prospect,v_owner,v_actor,'Lead intake ownership');
    end if;
  end if;

  if p_primary_contact is not null
     and (nullif(btrim(p_primary_contact->>'email'),'') is not null
       or nullif(btrim(p_primary_contact->>'phone'),'') is not null)
     and not exists(select 1 from public.sme_prospect_contacts contact
       where contact.prospect_id=v_prospect and contact.active
         and (lower(contact.email)=lower(p_primary_contact->>'email')
           or app.v510_normalize_identity('phone',contact.phone)=v_phone)) then
    insert into public.sme_prospect_contacts(
      prospect_id,full_name,title,email,phone,is_primary
    ) values(v_prospect,coalesce(nullif(btrim(p_primary_contact->>'full_name'),''),'Business contact'),
      nullif(btrim(p_primary_contact->>'title'),''),nullif(btrim(p_primary_contact->>'email'),''),
      nullif(btrim(p_primary_contact->>'phone'),''),
      not exists(select 1 from public.sme_prospect_contacts where prospect_id=v_prospect and active and is_primary));
  end if;

  if v_external_id is null or not exists(select 1 from public.sme_prospect_source_lineage
    where source_system=v_source_system and external_id=v_external_id) then
    insert into public.sme_prospect_source_lineage(
      prospect_id,source_system,source_type,external_id,detail,created_by
    ) values(v_prospect,v_source_system,v_source_type,v_external_id,
      coalesce(p_source,'{}'::jsonb)-'source_system'-'source_type'-'external_id',v_actor);
  end if;

  v_result:=jsonb_build_object('disposition',case when v_prospect_created then 'created' else 'reused' end,
    'intake_id',v_intake,'company_id',v_company,'prospect_id',v_prospect);
  update public.sme_lead_intakes_v510 set status='committed',disposition=v_result->>'disposition',
    company_id=v_company,prospect_id=v_prospect,result=v_result,updated_at=clock_timestamp()
    where id=v_intake;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'LEAD_INGESTED_V510','sme_prospects',v_prospect,v_result);
  perform app.v76_store_receipt(v_actor,'ingest_lead_v510',p_operation_key::text,v_hash,v_result);
  return v_result;
end $$;

-- Discovery keeps provider facts in their existing retention-controlled tables,
-- while Company/Lead creation is delegated to the canonical intake above.
create or replace function public.platform_crm_ingest_discovered_v297(
  p_places jsonb,p_request jsonb default '{}'::jsonb,p_commit boolean default false,
  p_search_calls integer default 0,p_detail_calls integer default 0
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare
  v_place jsonb;v_run uuid;v_company uuid;v_category uuid;v_result jsonb;v_operation uuid;
  v_actor uuid:=auth.uid();v_wrapper_operation uuid;v_hash text;v_replay jsonb;
  v_found integer:=0;v_new integer:=0;v_existing integer:=0;v_review integer:=0;
  v_source text;v_source_id text;v_name text;v_geo_source text;
begin
  perform app.v297_assert_prospecting('rw');
  if not (app.is_super_admin() or app.v89_platform_role()='admin') then
    raise exception 'business_import_requires_admin' using errcode='42501';end if;
  if jsonb_typeof(coalesce(p_places,'null'::jsonb))<>'array' then
    raise exception 'places_payload_must_be_an_array' using errcode='22023';end if;
  v_hash:=app.v76_sha256_hex(jsonb_build_object('places',p_places,'request',p_request,
    'commit',p_commit,'search_calls',p_search_calls,'detail_calls',p_detail_calls)::text);
  v_wrapper_operation:=(md5(v_actor::text||':'||v_hash))::uuid;
  perform pg_advisory_xact_lock(hashtextextended('v510:operation:'||v_actor||':discovery:'||v_wrapper_operation,0));
  v_replay:=app.v76_replay(v_actor,'discovery_ingest_v510',v_wrapper_operation::text,v_hash);
  if v_replay is not null then return v_replay;end if;
  insert into public.sme_discovery_runs(provider,request,status,search_calls,detail_calls,created_by)
  values(coalesce(p_request->>'provider','google_places'),coalesce(p_request,'{}'::jsonb),
    case when p_commit then 'importing' else 'preview' end,greatest(coalesce(p_search_calls,0),0),
    greatest(coalesce(p_detail_calls,0),0),auth.uid()) returning id into v_run;
  for v_place in select * from jsonb_array_elements(p_places) loop
    v_found:=v_found+1;v_source:=coalesce(nullif(btrim(v_place->>'source'),''),'google_places');
    v_source_id:=nullif(btrim(v_place->>'source_id'),'');v_name:=nullif(btrim(v_place->>'name'),'');
    v_geo_source:=case when coalesce(v_place->>'geo_source','')='onemap' then 'onemap' else 'google_places' end;
    if v_source_id is null or v_name is null then continue;end if;
    if not p_commit then
      if exists(select 1 from public.sme_company_sources where source=v_source and source_id=v_source_id)
      then v_existing:=v_existing+1;else v_new:=v_new+1;end if;
      continue;
    end if;
    v_operation:=(substr(md5(v_run::text||':'||v_found),1,8)||'-'||
      substr(md5(v_run::text||':'||v_found),9,4)||'-'||substr(md5(v_run::text||':'||v_found),13,4)||'-'||
      substr(md5(v_run::text||':'||v_found),17,4)||'-'||substr(md5(v_run::text||':'||v_found),21,12))::uuid;
    v_result:=public.platform_ingest_lead_v510(
      jsonb_build_object('legal_name',v_name,'trading_name',v_name,'place_id',v_source_id,
        'phone',v_place->>'phone','website',v_place->>'website',
        'address',jsonb_build_object('registered_address',v_place->>'address','postal_code',v_place->>'postal_code')),
      null,jsonb_build_object('source_system',v_source,'source_type','directory',
        'external_id',v_source_id,'discovery_run_id',v_run,'provider_payload',v_place),
      null,clock_timestamp()+interval '1 hour',v_operation);
    if v_result->>'disposition'='duplicate_review' then v_review:=v_review+1;continue;end if;
    v_company:=(v_result->>'company_id')::uuid;
    if v_result->>'disposition'='created' then v_new:=v_new+1;else v_existing:=v_existing+1;end if;
    insert into public.sme_company_sources(company_id,source,source_id,source_url,detail_fetched_at,last_synced_at)
    values(v_company,v_source,v_source_id,nullif(v_place->>'source_url',''),
      case when v_place?'rating' then clock_timestamp() end,clock_timestamp())
    on conflict(source,source_id) do update set last_synced_at=excluded.last_synced_at,
      detail_fetched_at=coalesce(excluded.detail_fetched_at,public.sme_company_sources.detail_fetched_at);
    insert into public.sme_company_locations(company_id,country,planning_area,district,address,postal_code,
      latitude,longitude,is_primary,geo_source,geo_synced_at)
    values(v_company,coalesce(nullif(v_place->>'country',''),'SG'),nullif(v_place->>'planning_area',''),
      nullif(v_place->>'district',''),nullif(v_place->>'address',''),nullif(v_place->>'postal_code',''),
      nullif(v_place->>'latitude','')::double precision,nullif(v_place->>'longitude','')::double precision,
      true,v_geo_source,clock_timestamp())
    on conflict(company_id) where is_primary do update set
      latitude=case when public.sme_company_locations.geo_source='manual' then public.sme_company_locations.latitude else coalesce(excluded.latitude,public.sme_company_locations.latitude) end,
      longitude=case when public.sme_company_locations.geo_source='manual' then public.sme_company_locations.longitude else coalesce(excluded.longitude,public.sme_company_locations.longitude) end,
      address=case when public.sme_company_locations.geo_source='manual' then public.sme_company_locations.address else coalesce(excluded.address,public.sme_company_locations.address) end,
      postal_code=case when public.sme_company_locations.geo_source='manual' then public.sme_company_locations.postal_code else coalesce(excluded.postal_code,public.sme_company_locations.postal_code) end,
      geo_source=case when public.sme_company_locations.geo_source='manual' then 'manual'
        when excluded.latitude is null and excluded.longitude is null then public.sme_company_locations.geo_source else excluded.geo_source end,
      geo_synced_at=case when public.sme_company_locations.geo_source='manual' then public.sme_company_locations.geo_synced_at else excluded.geo_synced_at end,
      updated_at=clock_timestamp();
    insert into public.sme_company_market_facts(company_id,business_status,rating,review_count,price_level,
      provider_phone,provider_website,last_synced_at,updated_at)
    values(v_company,v_place->>'business_status',nullif(v_place->>'rating','')::numeric,
      nullif(v_place->>'review_count','')::integer,nullif(v_place->>'price_level','')::smallint,
      v_place->>'phone',v_place->>'website',clock_timestamp(),clock_timestamp())
    on conflict(company_id) do update set
      business_status=coalesce(excluded.business_status,public.sme_company_market_facts.business_status),
      rating=coalesce(excluded.rating,public.sme_company_market_facts.rating),
      review_count=coalesce(excluded.review_count,public.sme_company_market_facts.review_count),
      price_level=coalesce(excluded.price_level,public.sme_company_market_facts.price_level),
      provider_phone=coalesce(excluded.provider_phone,public.sme_company_market_facts.provider_phone),
      provider_website=coalesce(excluded.provider_website,public.sme_company_market_facts.provider_website),
      last_synced_at=excluded.last_synced_at,updated_at=excluded.updated_at;
    if nullif(v_place->>'category_key','') is not null then
      select id into v_category from public.sme_categories where category_key=v_place->>'category_key';
      if v_category is not null then insert into public.sme_company_categories(company_id,category_id,is_primary)
        values(v_company,v_category,true) on conflict do nothing;end if;
    end if;
  end loop;
  update public.sme_discovery_runs set found_count=v_found,new_count=v_new,existing_count=v_existing,
    status=case when p_commit then 'completed' else 'preview' end,completed_at=clock_timestamp() where id=v_run;
  v_result:=jsonb_build_object('run_id',v_run,'committed',p_commit,'found',v_found,'new',v_new,
    'existing',v_existing,'duplicates',v_review,'canonical_intake',true);
  perform app.v76_store_receipt(v_actor,'discovery_ingest_v510',v_wrapper_operation::text,v_hash,v_result);
  return v_result;
end $$;

-- CSV rows keep the existing preview/decision UI, but every committed insert
-- now passes through the same identity and intake contract as manual leads.
create or replace function public.platform_commit_prospect_import_v86(p_batch uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare
  v_actor uuid:=auth.uid();v_batch public.sme_prospect_import_batches%rowtype;v_row record;
  v_result jsonb;v_company uuid;v_prospect uuid;v_source uuid;
  v_inserted integer:=0;v_merged integer:=0;v_skipped integer:=0;v_review integer:=0;v_hash text;
begin
  perform app.v297_assert_prospecting('rw');
  select * into v_batch from public.sme_prospect_import_batches where id=p_batch for update;
  if not found then raise exception 'import batch was not found' using errcode='22023';end if;
  if v_batch.status='committed' then
    return jsonb_build_object('batch_id',p_batch,'inserted_rows',v_batch.imported_rows,
      'merged_rows',0,'skipped_rows',v_batch.skipped_rows,'review_rows',v_batch.conflict_rows,
      'canonical_intake',true,'replayed',true);
  end if;
  if v_batch.status<>'staged' then raise exception 'staged import batch was not found' using errcode='22023';end if;
  if exists(select 1 from public.sme_prospect_import_rows import_row
    left join lateral(select decision.* from public.sme_import_row_decision_versions decision
      where decision.import_row_id=import_row.id order by decision.version desc limit 1) latest on true
    where import_row.batch_id=p_batch and (latest.id is null or latest.decision='review')) then
    raise exception 'all import rows require a final insert, merge or skip decision' using errcode='22023';end if;
  for v_row in select import_row.*,latest.decision,latest.candidate_prospect_id
    from public.sme_prospect_import_rows import_row
    join lateral(select decision.* from public.sme_import_row_decision_versions decision
      where decision.import_row_id=import_row.id order by decision.version desc limit 1) latest on true
    where import_row.batch_id=p_batch order by import_row.row_number for update of import_row
  loop
    if v_row.decision='skip' then v_skipped:=v_skipped+1;continue;end if;
    if v_row.decision='merge' then
      select prospect.company_id into v_company from public.sme_prospects prospect
      where prospect.id=v_row.candidate_prospect_id for update;
      if not found then raise exception 'reviewed merge target no longer exists' using errcode='40001';end if;
      v_prospect:=v_row.candidate_prospect_id;
      if nullif(v_row.normalized_payload->>'registration_number','') is not null and exists(
        select 1 from public.sme_companies where id=v_company and registration_number is not null
          and app.v510_normalize_identity('uen',registration_number)<>
            app.v510_normalize_identity('uen',v_row.normalized_payload->>'registration_number')) then
        raise exception 'reviewed merge conflicts with the Company UEN' using errcode='23505';end if;
      update public.sme_companies set
        registration_number=coalesce(registration_number,nullif(v_row.normalized_payload->>'registration_number','')),
        website=coalesce(website,nullif(v_row.normalized_payload->>'website_domain','')),
        phone=coalesce(phone,nullif(v_row.normalized_payload->>'phone_e164','')),
        email=coalesce(email,nullif(v_row.normalized_payload->>'email','')),
        address=case when address='{}'::jsonb then jsonb_strip_nulls(jsonb_build_object(
          'registered_address',nullif(v_row.normalized_payload->>'address',''),
          'postal_code',nullif(v_row.normalized_payload->>'postal_code',''))) else address end,
        updated_at=clock_timestamp() where id=v_company;
      if nullif(v_row.normalized_payload->>'email','') is not null
         or nullif(v_row.normalized_payload->>'phone_e164','') is not null then
        insert into public.sme_prospect_contacts(prospect_id,full_name,title,email,phone,is_primary)
        select v_prospect,coalesce(nullif(v_row.normalized_payload->>'contact_name',''),'Business contact'),
          nullif(v_row.normalized_payload->>'job_title',''),nullif(v_row.normalized_payload->>'email',''),
          nullif(v_row.normalized_payload->>'phone_e164',''),
          not exists(select 1 from public.sme_prospect_contacts where prospect_id=v_prospect and active and is_primary)
        where not exists(select 1 from public.sme_prospect_contacts contact
          where contact.prospect_id=v_prospect and contact.active and
            (lower(contact.email)=lower(v_row.normalized_payload->>'email')
             or app.v510_normalize_identity('phone',contact.phone)=
                app.v510_normalize_identity('phone',v_row.normalized_payload->>'phone_e164')));
      end if;
      v_hash:=app.v76_sha256_hex(jsonb_build_object('batch',p_batch,'row',v_row.id,
        'decision','merge','prospect',v_prospect)::text);
      insert into public.sme_lead_intakes_v510(operation_key,request_hash,source_system,source_type,
        external_id,company_payload,contact_payload,status,disposition,company_id,prospect_id,
        submitted_by,decided_by,decided_at,result)
      values(v_row.id,v_hash,v_batch.source_system,'import',p_batch::text||':'||v_row.row_number,
        v_row.normalized_payload,jsonb_build_object('full_name',v_row.normalized_payload->>'contact_name',
          'email',v_row.normalized_payload->>'email','phone',v_row.normalized_payload->>'phone_e164'),
        'committed','reused',v_company,v_prospect,v_actor,v_actor,clock_timestamp(),
        jsonb_build_object('disposition','reused','reviewed_merge',true,'company_id',v_company,'prospect_id',v_prospect));
      insert into public.sme_prospect_source_lineage(prospect_id,source_system,source_type,external_id,detail,created_by)
      values(v_prospect,v_batch.source_system,'import',p_batch::text||':'||v_row.row_number,
        jsonb_build_object('batch_id',p_batch,'row_number',v_row.row_number,'reviewed_merge',true,
          'raw_payload',v_row.raw_payload),v_actor) returning id into v_source;
      v_merged:=v_merged+1;
    else
      v_result:=public.platform_ingest_lead_v510(
        jsonb_build_object('legal_name',v_row.normalized_payload->>'company_name',
          'trading_name',v_row.normalized_payload->>'company_name',
          'registration_number',v_row.normalized_payload->>'registration_number',
          'industry',v_row.normalized_payload->>'industry','website',v_row.normalized_payload->>'website_domain',
          'phone',v_row.normalized_payload->>'phone_e164','email',v_row.normalized_payload->>'email',
          'address',jsonb_build_object('registered_address',v_row.normalized_payload->>'address',
            'postal_code',v_row.normalized_payload->>'postal_code')),
        jsonb_build_object('full_name',coalesce(nullif(v_row.normalized_payload->>'contact_name',''),'Business contact'),
          'title',v_row.normalized_payload->>'job_title','email',v_row.normalized_payload->>'email',
          'phone',v_row.normalized_payload->>'phone_e164'),
        jsonb_build_object('source_system',v_batch.source_system,'source_type','import',
          'external_id',p_batch::text||':'||v_row.row_number,'batch_id',p_batch,'row_number',v_row.row_number),
        null,clock_timestamp()+interval '1 hour',v_row.id);
      if v_result->>'disposition' in ('duplicate_review','existing_merchant') then
        update public.sme_prospect_import_rows set row_status='conflict',
          errors=array_append(errors,'canonical_identity_'||(v_result->>'disposition'))
        where id=v_row.id;
        v_review:=v_review+1;
        continue;
      end if;
      v_company:=(v_result->>'company_id')::uuid;v_prospect:=(v_result->>'prospect_id')::uuid;
      select lineage.id into v_source from public.sme_prospect_source_lineage lineage
      where lineage.prospect_id=v_prospect and lineage.source_system=v_batch.source_system
        and lineage.external_id=p_batch::text||':'||v_row.row_number order by lineage.created_at desc limit 1;
      if nullif(v_row.raw_stage,'') is not null and v_row.mapped_stage_key is distinct from 'new_lead' then
        insert into public.sme_prospect_data_quality_flags(prospect_id,flag_code,severity,detail)
        values(v_prospect,'imported_stage_requires_evidence','warning',
          'Source stage retained but not applied: '||v_row.raw_stage);
      end if;
      v_inserted:=v_inserted+1;
    end if;
    insert into public.sme_import_commit_ledger(batch_id,import_row_id,decision,prospect_id,
      company_id,source_lineage_id,prospect_version_at_commit,committed_by)
    select p_batch,v_row.id,v_row.decision,prospect.id,prospect.company_id,v_source,prospect.version,v_actor
    from public.sme_prospects prospect where prospect.id=v_prospect;
    update public.sme_prospect_import_rows set row_status='imported',prospect_id=v_prospect where id=v_row.id;
  end loop;
  update public.sme_prospect_import_batches set status='committed',imported_rows=v_inserted+v_merged,
    skipped_rows=v_skipped,conflict_rows=conflict_rows+v_review,committed_at=clock_timestamp() where id=p_batch;
  v_result:=jsonb_build_object('batch_id',p_batch,'inserted_rows',v_inserted,
    'merged_rows',v_merged,'skipped_rows',v_skipped,'review_rows',v_review,'canonical_intake',true);
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'SME_PROSPECT_IMPORT_COMMITTED_V510','sme_prospect_import_batches',p_batch,v_result);
  return v_result;
end $$;

-- ------------------------------------------------------ ownership / stages

create or replace function public.platform_bulk_transfer_leads_v510(
  p_prospects uuid[],p_consultant uuid,p_reason text,p_operation_key uuid
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_ids uuid[];v_new_ids uuid[];v_hash text;v_replay jsonb;v_result jsonb;
begin
  perform app.v297_assert_prospecting('rw');
  if not app.is_super_admin() then raise exception 'super admin is required' using errcode='42501';end if;
  if p_operation_key is null or p_prospects is null or cardinality(p_prospects) not between 1 and 500
     or length(btrim(coalesce(p_reason,'')))<3 then
    raise exception '1 to 500 leads, reason and operation key are required' using errcode='22023';end if;
  if cardinality(p_prospects)<>(select count(distinct id) from unnest(p_prospects) id) then
    raise exception 'duplicate lead IDs are not allowed' using errcode='22023';end if;
  if not exists(select 1 from public.platform_consultants where id=p_consultant and active) then
    raise exception 'active consultant was not found' using errcode='22023';end if;
  v_hash:=app.v76_sha256_hex(jsonb_build_object('prospects',to_jsonb(p_prospects),
    'consultant',p_consultant,'reason',p_reason)::text);
  perform pg_advisory_xact_lock(hashtextextended('v510:operation:'||v_actor||':bulk_transfer:'||p_operation_key,0));
  v_replay:=app.v76_replay(v_actor,'bulk_transfer_leads_v510',p_operation_key::text,v_hash);
  if v_replay is not null then return v_replay;end if;
  select coalesce(array_agg(locked.id order by locked.id),'{}'::uuid[]),
    coalesce(array_agg(locked.id order by locked.id) filter(where locked.current_stage_key='new_lead'),'{}'::uuid[])
  into v_ids,v_new_ids from (select prospect.id,prospect.current_stage_key
    from public.sme_prospects prospect join public.sme_companies company on company.id=prospect.company_id
    where prospect.id=any(p_prospects) and prospect.archived_at is null
      and prospect.converted_business_id is null and company.peekaa_business_id is null
    order by prospect.id for update of prospect) locked;
  update public.sme_prospects set assigned_consultant_id=p_consultant,ownership_state='owned',queue_key=null,
    owner_assigned_at=clock_timestamp(),
    current_stage_key=case when current_stage_key='new_lead' then 'assigned' else current_stage_key end,
    stage_entered_at=case when current_stage_key='new_lead' then clock_timestamp() else stage_entered_at end,
    next_action_type=case when current_stage_key='new_lead'
      then 'first_contact' else next_action_type end,
    next_action_at=case when current_stage_key='new_lead'
      then clock_timestamp()+interval '1 hour' else next_action_at end,
    version=version+1,updated_by=v_actor,updated_at=clock_timestamp()
  where id=any(v_ids);
  insert into public.sme_prospect_assignments(prospect_id,consultant_id,assigned_by,reason)
  select id,p_consultant,v_actor,btrim(p_reason) from unnest(v_ids) id;
  insert into public.sme_prospect_stage_history(prospect_id,from_stage_key,to_stage_key,
    reason_code,reason_detail,actor)
  select id,'new_lead','assigned','bulk_owner_assigned',btrim(p_reason),v_actor from unnest(v_new_ids) id;
  v_result:=jsonb_build_object('assigned',cardinality(v_ids),
    'skipped',cardinality(p_prospects)-cardinality(v_ids),'requested',cardinality(p_prospects));
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'LEADS_BULK_TRANSFERRED_V510','sme_prospects',null,v_result||
    jsonb_build_object('consultant',p_consultant,'reason',btrim(p_reason)));
  perform app.v76_store_receipt(v_actor,'bulk_transfer_leads_v510',p_operation_key::text,v_hash,v_result);
  return v_result;
end $$;

create or replace function public.platform_claim_lead_v510(
  p_prospect uuid,p_expected_version bigint,p_operation_key uuid
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_self uuid;v_row public.sme_prospects%rowtype;v_hash text;v_replay jsonb;v_result jsonb;v_previous text;
begin
  perform app.v297_assert_prospecting('rw');
  v_self:=app.v226_self_consultant();
  if v_self is null then raise exception 'active consultant link is required' using errcode='42501';end if;
  if p_operation_key is null then raise exception 'operation key is required' using errcode='22023';end if;
  v_hash:=app.v76_sha256_hex(jsonb_build_object('prospect',p_prospect,'version',p_expected_version,'consultant',v_self)::text);
  perform pg_advisory_xact_lock(hashtextextended('v510:operation:'||v_actor||':claim:'||p_operation_key,0));
  v_replay:=app.v76_replay(v_actor,'claim_lead_v510',p_operation_key::text,v_hash);
  if v_replay is not null then return v_replay;end if;
  select * into v_row from public.sme_prospects where id=p_prospect for update;
  if not found then raise exception 'lead was not found' using errcode='22023';end if;
  if v_row.version<>p_expected_version then raise exception 'lead version conflict' using errcode='40001';end if;
  if v_row.ownership_state<>'queued' or v_row.assigned_consultant_id is not null then
    raise exception 'lead is not available to claim' using errcode='40001';end if;
  v_previous:=v_row.current_stage_key;
  update public.sme_prospects set assigned_consultant_id=v_self,ownership_state='owned',
    queue_key=null,owner_assigned_at=clock_timestamp(),current_stage_key=case when current_stage_key='new_lead' then 'assigned' else current_stage_key end,
    next_action_type=case when current_stage_key='new_lead' then 'first_contact' else next_action_type end,
    next_action_at=case when current_stage_key='new_lead' then least(next_action_at,clock_timestamp()+interval '1 hour') else next_action_at end,
    stage_entered_at=case when current_stage_key='new_lead' then clock_timestamp() else stage_entered_at end,
    version=version+1,updated_by=v_actor,updated_at=clock_timestamp() where id=p_prospect returning * into v_row;
  insert into public.sme_prospect_assignments(prospect_id,consultant_id,assigned_by,reason)
  values(p_prospect,v_self,v_actor,'Salesperson claimed queued lead');
  if v_previous='new_lead' then
    insert into public.sme_prospect_stage_history(
      prospect_id,from_stage_key,to_stage_key,reason_code,reason_detail,actor)
    values(p_prospect,'new_lead','assigned','lead_claimed',
      'Queued lead claimed by its owner',v_actor);
  end if;
  v_result:=jsonb_build_object('prospect_id',p_prospect,'owner',v_self,'version',v_row.version,'status','claimed');
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'LEAD_CLAIMED_V510','sme_prospects',p_prospect,v_result);
  perform app.v76_store_receipt(v_actor,'claim_lead_v510',p_operation_key::text,v_hash,v_result);
  return v_result;
end $$;

create or replace function public.platform_transfer_lead_v510(
  p_prospect uuid,p_consultant uuid,p_expected_version bigint,p_reason text,p_operation_key uuid
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_row public.sme_prospects%rowtype;v_hash text;v_replay jsonb;v_result jsonb;v_previous text;
begin
  if not app.is_super_admin() then raise exception 'super admin is required' using errcode='42501';end if;
  if p_operation_key is null or length(btrim(coalesce(p_reason,'')))<3 then
    raise exception 'operation key and transfer reason are required' using errcode='22023';end if;
  if not exists(select 1 from public.platform_consultants where id=p_consultant and active) then
    raise exception 'active consultant was not found' using errcode='22023';end if;
  v_hash:=app.v76_sha256_hex(jsonb_build_object('prospect',p_prospect,'consultant',p_consultant,
    'version',p_expected_version,'reason',p_reason)::text);
  perform pg_advisory_xact_lock(hashtextextended('v510:operation:'||v_actor||':transfer:'||p_operation_key,0));
  v_replay:=app.v76_replay(v_actor,'transfer_lead_v510',p_operation_key::text,v_hash);
  if v_replay is not null then return v_replay;end if;
  select * into v_row from public.sme_prospects where id=p_prospect for update;
  if not found or v_row.version<>p_expected_version then
    raise exception 'lead version conflict' using errcode='40001';end if;
  v_previous:=v_row.current_stage_key;
  update public.sme_prospects set assigned_consultant_id=p_consultant,ownership_state='owned',
    queue_key=null,owner_assigned_at=clock_timestamp(),
    current_stage_key=case when current_stage_key='new_lead' then 'assigned' else current_stage_key end,
    stage_entered_at=case when current_stage_key='new_lead' then clock_timestamp() else stage_entered_at end,
    next_action_type=case when current_stage_key='new_lead'
      then 'first_contact' else next_action_type end,
    next_action_at=case when current_stage_key='new_lead'
      then clock_timestamp()+interval '1 hour' else next_action_at end,version=version+1,
    updated_by=v_actor,updated_at=clock_timestamp()
  where id=p_prospect returning * into v_row;
  insert into public.sme_prospect_assignments(prospect_id,consultant_id,assigned_by,reason)
  values(p_prospect,p_consultant,v_actor,btrim(p_reason));
  if v_previous='new_lead' then
    insert into public.sme_prospect_stage_history(
      prospect_id,from_stage_key,to_stage_key,reason_code,reason_detail,actor)
    values(p_prospect,'new_lead','assigned','owner_assigned',btrim(p_reason),v_actor);
  end if;
  v_result:=jsonb_build_object('prospect_id',p_prospect,'owner',p_consultant,'version',v_row.version,'status','transferred');
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'LEAD_TRANSFERRED_V510','sme_prospects',p_prospect,v_result||jsonb_build_object('reason',p_reason));
  perform app.v76_store_receipt(v_actor,'transfer_lead_v510',p_operation_key::text,v_hash,v_result);
  return v_result;
end $$;

create or replace function public.platform_queue_lead_v510(
  p_prospect uuid,p_queue_key text,p_expected_version bigint,p_reason text,p_operation_key uuid
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_row public.sme_prospects%rowtype;v_hash text;v_replay jsonb;v_result jsonb;
begin
  perform app.v297_assert_prospecting('rw');
  if not app.is_super_admin() then raise exception 'super admin is required' using errcode='42501';end if;
  if p_operation_key is null or coalesce(p_queue_key,'')!~'^[a-z][a-z0-9_]{1,63}$'
     or length(btrim(coalesce(p_reason,'')))<3 then
    raise exception 'queue, reason and operation key are required' using errcode='22023';end if;
  v_hash:=app.v76_sha256_hex(jsonb_build_object('prospect',p_prospect,'queue',p_queue_key,
    'version',p_expected_version,'reason',p_reason)::text);
  perform pg_advisory_xact_lock(hashtextextended('v510:operation:'||v_actor||':queue:'||p_operation_key,0));
  v_replay:=app.v76_replay(v_actor,'queue_lead_v510',p_operation_key::text,v_hash);
  if v_replay is not null then return v_replay;end if;
  update public.sme_prospects set assigned_consultant_id=null,ownership_state='queued',
    queue_key=p_queue_key,owner_assigned_at=null,version=version+1,
    updated_by=v_actor,updated_at=clock_timestamp()
  where id=p_prospect and version=p_expected_version returning * into v_row;
  if not found then raise exception 'lead version conflict' using errcode='40001';end if;
  insert into public.sme_prospect_assignments(prospect_id,consultant_id,assigned_by,reason)
  values(p_prospect,null,v_actor,btrim(p_reason));
  v_result:=jsonb_build_object('prospect_id',p_prospect,'queue_key',p_queue_key,
    'version',v_row.version,'status','queued');
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'LEAD_QUEUED_V510','sme_prospects',p_prospect,v_result||jsonb_build_object('reason',p_reason));
  perform app.v76_store_receipt(v_actor,'queue_lead_v510',p_operation_key::text,v_hash,v_result);
  return v_result;
end $$;

create or replace function public.platform_reassign_consultant_portfolio_v510(
  p_from_consultant uuid,p_to_consultant uuid,p_expected_count integer,
  p_reason text,p_operation_key uuid
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare
  v_actor uuid:=auth.uid();v_hash text;v_replay jsonb;v_actual integer;v_result jsonb;
  v_ids uuid[];
begin
  perform app.v297_assert_prospecting('rw');
  if not app.is_super_admin() then raise exception 'super admin is required' using errcode='42501';end if;
  if p_operation_key is null or p_from_consultant=p_to_consultant
     or p_expected_count is null or p_expected_count<0 or length(btrim(coalesce(p_reason,'')))<3 then
    raise exception 'valid consultants, expected count, reason and operation key are required' using errcode='22023';end if;
  if not exists(select 1 from public.platform_consultants where id=p_to_consultant and active) then
    raise exception 'active destination consultant was not found' using errcode='22023';end if;
  v_hash:=app.v76_sha256_hex(jsonb_build_object('from',p_from_consultant,'to',p_to_consultant,
    'expected_count',p_expected_count,'reason',p_reason)::text);
  perform pg_advisory_xact_lock(hashtextextended('v510:operation:'||v_actor||':portfolio:'||p_operation_key,0));
  v_replay:=app.v76_replay(v_actor,'reassign_portfolio_v510',p_operation_key::text,v_hash);
  if v_replay is not null then return v_replay;end if;
  select coalesce(array_agg(locked.id order by locked.id),'{}'::uuid[]) into v_ids
  from (select prospect.id from public.sme_prospects prospect
    join public.sme_pipeline_stages stage on stage.stage_key=prospect.current_stage_key
    where prospect.assigned_consultant_id=p_from_consultant
      and prospect.archived_at is null and prospect.converted_business_id is null
      and (stage.kind='active' or prospect.current_stage_key='closed_won')
    order by prospect.id for update of prospect) locked;
  v_actual:=cardinality(v_ids);
  if v_actual<>p_expected_count then
    raise exception 'portfolio changed: expected %, found %',p_expected_count,v_actual using errcode='40001';end if;
  update public.sme_prospects set assigned_consultant_id=p_to_consultant,
    ownership_state='owned',queue_key=null,owner_assigned_at=clock_timestamp(),
    version=version+1,updated_by=v_actor,updated_at=clock_timestamp()
  where id=any(v_ids);
  insert into public.sme_prospect_assignments(prospect_id,consultant_id,assigned_by,reason)
  select prospect_id,p_to_consultant,v_actor,btrim(p_reason) from unnest(v_ids) prospect_id;
  v_result:=jsonb_build_object('from_consultant',p_from_consultant,
    'to_consultant',p_to_consultant,'reassigned_count',v_actual,'prospect_ids',to_jsonb(v_ids));
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'LEAD_PORTFOLIO_REASSIGNED_V510','platform_consultants',p_from_consultant,v_result);
  perform app.v76_store_receipt(v_actor,'reassign_portfolio_v510',p_operation_key::text,v_hash,v_result);
  return v_result;
end $$;

create or replace function public.platform_transition_lead_v510(
  p_prospect uuid,p_to_stage text,p_expected_version bigint,
  p_next_action_type text,p_next_action_at timestamptz,
  p_reason_code text default null,p_reason_detail text default null,
  p_entry_evidence jsonb default '{}'::jsonb,
  p_commercial_terms jsonb default null,p_operation_key uuid default null
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare
  v_actor uuid:=auth.uid();v_role text:=app.v89_platform_role();v_self uuid;
  v_row public.sme_prospects%rowtype;v_rule public.sme_pipeline_transition_rules_v510%rowtype;
  v_hash text;v_replay jsonb;v_terms_version integer;v_result jsonb;
  v_entry_rule public.sme_stage_entry_requirements%rowtype;v_missing text[];
begin
  perform app.v297_assert_prospecting('rw');
  if p_operation_key is null then raise exception 'operation key is required' using errcode='22023';end if;
  if jsonb_typeof(coalesce(p_entry_evidence,'{}'::jsonb))<>'object' then
    raise exception 'stage entry evidence must be an object' using errcode='22023';end if;
  v_hash:=app.v76_sha256_hex(jsonb_build_object('prospect',p_prospect,
    'to',p_to_stage,'version',p_expected_version,'next_action_type',p_next_action_type,
    'next_action_at',p_next_action_at,'reason_code',p_reason_code,'reason_detail',p_reason_detail,
    'entry_evidence',p_entry_evidence,'commercial_terms',p_commercial_terms)::text);
  perform pg_advisory_xact_lock(hashtextextended('v510:operation:'||v_actor||':transition:'||p_operation_key,0));
  v_replay:=app.v76_replay(v_actor,'transition_lead_v510',p_operation_key::text,v_hash);
  if v_replay is not null then return v_replay;end if;
  select * into v_row from public.sme_prospects where id=p_prospect for update;
  if not found then raise exception 'lead was not found' using errcode='22023';end if;
  if v_row.version<>p_expected_version then raise exception 'lead version conflict' using errcode='40001';end if;
  if v_role='sales_staff' then
    v_self:=app.v226_self_consultant();
    if v_self is null or v_row.assigned_consultant_id is distinct from v_self then
      raise exception 'salesperson may update only an owned lead' using errcode='42501';end if;
  end if;
  select * into v_rule from public.sme_pipeline_transition_rules_v510
  where from_stage_key=v_row.current_stage_key and to_stage_key=p_to_stage and active;
  if not found then raise exception 'lead transition is not allowed' using errcode='22023';end if;
  if v_rule.requires_owner and v_row.assigned_consultant_id is null then
    raise exception 'lead transition requires an owner' using errcode='22023';end if;
  if v_rule.requires_next_action and (p_next_action_at is null
     or nullif(btrim(coalesce(p_next_action_type,'')),'') is null) then
    raise exception 'lead transition requires a next action and deadline' using errcode='22023';end if;
  if p_next_action_at is not null and p_next_action_at<clock_timestamp()-interval '5 minutes' then
    raise exception 'next action cannot be in the past' using errcode='22023';end if;
  select * into v_entry_rule from public.sme_stage_entry_requirements where stage_key=p_to_stage;
  if not found or v_entry_rule.system_managed then
    raise exception 'target stage is not human-managed' using errcode='42501';end if;
  select array_agg(required_key order by required_key) into v_missing
  from unnest(v_entry_rule.required_keys) required_key
  where not (p_entry_evidence?required_key)
     or nullif(btrim(p_entry_evidence->>required_key),'') is null;
  if cardinality(v_missing)>0 then
    raise exception 'stage % is missing evidence: %',p_to_stage,array_to_string(v_missing,', ')
      using errcode='22023';end if;
  if v_entry_rule.terminal_confirmation
     and p_entry_evidence?'explicit_confirmation'
     and coalesce((p_entry_evidence->>'explicit_confirmation')::boolean,false) is not true then
    raise exception 'terminal confirmation must be true' using errcode='22023';end if;
  if p_to_stage='contacted' and (
    coalesce(p_entry_evidence->>'channel','') not in ('phone','sms','whatsapp','email','video','in_person')
    or (p_entry_evidence->>'contacted_at')::timestamptz>clock_timestamp()+interval '5 minutes') then
    raise exception 'contacted evidence is invalid' using errcode='22023';end if;
  if p_to_stage='assigned' and (
    (p_entry_evidence->>'assigned_consultant')::uuid is distinct from v_row.assigned_consultant_id
    or length(btrim(p_entry_evidence->>'context'))<3) then
    raise exception 'assignment evidence must name the current owner and context' using errcode='22023';end if;
  if p_to_stage='interested' and (
    (p_entry_evidence->>'next_follow_up_at')::timestamptz<clock_timestamp()-interval '5 minutes'
    or abs(extract(epoch from ((p_entry_evidence->>'next_follow_up_at')::timestamptz-p_next_action_at)))>60
    or length(btrim(p_entry_evidence->>'context'))<3) then
    raise exception 'interest evidence must match the canonical follow-up' using errcode='22023';end if;
  if p_to_stage='appointment' and (
    (p_entry_evidence->>'appointment_at')::timestamptz<clock_timestamp()-interval '5 minutes'
    or (nullif(btrim(p_entry_evidence->>'meeting_url'),'') is null
      and nullif(btrim(p_entry_evidence->>'physical_location'),'') is null)) then
    raise exception 'appointment requires a future time and meeting URL or location' using errcode='22023';end if;
  if p_to_stage='proposal' and (
    (p_entry_evidence->>'proposal_issued')::timestamptz>clock_timestamp()+interval '5 minutes'
    or (p_entry_evidence->>'proposal_issued')::timestamptz<clock_timestamp()-interval '1 year'
    or length(btrim(p_entry_evidence->>'context'))<3) then
    raise exception 'proposal evidence requires a real issued timestamp and context' using errcode='22023';end if;
  if p_to_stage='nurture' and (
    coalesce((p_entry_evidence->>'recontact_permission')::boolean,false) is not true
    or (p_entry_evidence->>'recontact_at')::timestamptz<=clock_timestamp()
    or abs(extract(epoch from ((p_entry_evidence->>'recontact_at')::timestamptz-p_next_action_at)))>60) then
    raise exception 'nurture evidence must permit and match the canonical recontact date' using errcode='22023';end if;
  if v_rule.requires_next_action and p_next_action_at is not null
     and p_next_action_at>clock_timestamp()+v_rule.default_sla then
    raise exception 'next action exceeds the canonical stage SLA' using errcode='22023';end if;
  if p_to_stage='lost' and (
    coalesce(p_entry_evidence->>'reason_code','') not in
      ('no_response','not_interested','no_budget','timing','chose_competitor',
       'missing_required_feature','procurement_security_blocker','price',
       'internal_priority_changed','business_ceased','duplicate','bad_fit','other')
    or (coalesce((p_entry_evidence->>'recontact_permission')::boolean,false)
      and not p_entry_evidence?'recontact_at')
  ) then raise exception 'lost requires a valid reason and conditional recontact date' using errcode='22023';end if;
  if v_rule.requires_commercial_terms and (
    p_commercial_terms is null or jsonb_typeof(p_commercial_terms)<>'object'
    or coalesce(p_commercial_terms->>'contract_status','') not in ('accepted','signed')
    or coalesce(p_commercial_terms->>'owner_email','') not like '%@%'
    or coalesce(p_commercial_terms->>'plan_code','')=''
    or coalesce(p_commercial_terms->>'product_code','')=''
    or coalesce(p_commercial_terms->>'billing_cycle','') not in ('quarterly','half_yearly','annual')
    or coalesce((p_commercial_terms->>'seats')::integer,0)<=0
    or coalesce((p_commercial_terms->>'accepted_value_cents')::integer,0)<=0
    or coalesce(p_commercial_terms->>'currency','')!~'^[A-Z]{3}$'
    or nullif(p_commercial_terms->>'onboarding_owner_consultant_id','') is null
    or nullif(p_commercial_terms->>'target_go_live','') is null
  ) then raise exception 'closed won requires accepted commercial terms' using errcode='22023';end if;
  if p_commercial_terms is not null then
    select coalesce(max(version),0)+1 into v_terms_version from public.sme_commercial_terms where prospect_id=p_prospect;
    insert into public.sme_commercial_terms(
      prospect_id,version,plan_code,product_code,billing_cycle,seats,currency,
      accepted_value_cents,owner_email,onboarding_owner_consultant_id,target_go_live,
      contract_status,accepted_at,notes,created_by
    ) values(p_prospect,v_terms_version,btrim(p_commercial_terms->>'plan_code'),
      btrim(p_commercial_terms->>'product_code'),p_commercial_terms->>'billing_cycle',
      greatest(coalesce((p_commercial_terms->>'seats')::integer,1),1),
      coalesce(p_commercial_terms->>'currency','SGD'),
      greatest(coalesce((p_commercial_terms->>'accepted_value_cents')::integer,0),0),
      lower(btrim(p_commercial_terms->>'owner_email')),
      nullif(p_commercial_terms->>'onboarding_owner_consultant_id','')::uuid,
      nullif(p_commercial_terms->>'target_go_live','')::date,
      p_commercial_terms->>'contract_status',clock_timestamp(),p_commercial_terms->>'notes',v_actor);
  end if;
  update public.sme_prospects set current_stage_key=p_to_stage,stage_entered_at=clock_timestamp(),
    next_action_type=coalesce(nullif(btrim(p_next_action_type),''),next_action_type),
    next_action_at=case when v_rule.requires_next_action then p_next_action_at else next_action_at end,
    ownership_state=case when p_to_stage='lost' then 'closed'
      when v_rule.from_stage_key='lost' then 'owned' else ownership_state end,
    version=version+1,updated_by=v_actor,updated_at=clock_timestamp()
  where id=p_prospect returning * into v_row;
  insert into public.sme_prospect_stage_history(
    prospect_id,from_stage_key,to_stage_key,reason_code,reason_detail,actor
  ) values(p_prospect,v_rule.from_stage_key,p_to_stage,p_reason_code,
    nullif(btrim(p_reason_detail),''),v_actor);
  insert into public.sme_stage_entry_evidence(
    prospect_id,stage_key,prospect_version,schema_version,evidence,actor
  ) values(p_prospect,p_to_stage,p_expected_version,v_entry_rule.evidence_schema_version,
    p_entry_evidence,v_actor);
  v_result:=jsonb_build_object('prospect_id',p_prospect,'from_stage',v_rule.from_stage_key,
    'to_stage',p_to_stage,'version',v_row.version,'next_action_at',v_row.next_action_at,
    'commercial_terms_version',v_terms_version);
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'LEAD_TRANSITIONED_V510','sme_prospects',p_prospect,v_result);
  perform app.v76_store_receipt(v_actor,'transition_lead_v510',p_operation_key::text,v_hash,v_result);
  return v_result;
end $$;

-- ------------------------------------------------------------ read models

create or replace function public.platform_list_identity_reviews_v510(p_limit integer default 100)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_limit integer:=least(greatest(coalesce(p_limit,100),1),250);
begin
  perform app.v297_assert_prospecting('r');
  if not (app.is_super_admin() or app.v89_platform_role()='admin') then
    raise exception 'duplicate review requires admin access' using errcode='42501';end if;
  return jsonb_build_object('items',coalesce((
    select jsonb_agg(to_jsonb(review) order by review.created_at,review.intake_id)
    from (select intake.id intake_id,intake.updated_at,intake.created_at,intake.source_system,
      intake.source_type,intake.external_id,intake.company_payload,intake.contact_payload,
      coalesce(jsonb_agg(jsonb_build_object('candidate_id',candidate.id,
        'company_id',candidate.candidate_company_id,'company_name',
          coalesce(company.trading_name,company.legal_name),
        'registration_number',company.registration_number,'match_basis',candidate.match_basis,
        'confidence',candidate.confidence,'evidence',candidate.evidence)
        order by candidate.confidence desc,company.legal_name)
        filter(where candidate.id is not null),'[]'::jsonb) candidates
      from public.sme_lead_intakes_v510 intake
      left join public.sme_company_identity_match_candidates_v510 candidate
        on candidate.intake_id=intake.id and candidate.status='pending'
      left join public.sme_companies company on company.id=candidate.candidate_company_id
      where intake.status='duplicate_review'
      group by intake.id order by intake.created_at limit v_limit) review
  ),'[]'::jsonb));
end $$;

create or replace function public.platform_resolve_identity_review_v510(
  p_intake uuid,p_decision text,p_candidate_company uuid,p_expected_updated_at timestamptz,
  p_operation_key uuid
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare
  v_actor uuid:=auth.uid();v_intake public.sme_lead_intakes_v510%rowtype;
  v_company uuid;v_prospect uuid;v_business uuid;v_result jsonb;v_hash text;v_replay jsonb;
  v_owner uuid;v_phone text;v_source_id uuid;
  v_source_system text;v_uen_namespace text;v_place_namespace text;
  v_uen text;v_place text;v_domain text;v_email text;v_name_postal text;v_provider jsonb;
  v_batch uuid;v_import_row uuid;
begin
  perform app.v297_assert_prospecting('rw');
  if not app.is_super_admin() then raise exception 'super admin duplicate resolution is required' using errcode='42501';end if;
  if p_decision not in ('confirm','create_distinct','reject') or p_operation_key is null then
    raise exception 'valid decision and operation key are required' using errcode='22023';end if;
  v_hash:=app.v76_sha256_hex(jsonb_build_object('intake',p_intake,'decision',p_decision,
    'candidate_company',p_candidate_company,'expected_updated_at',p_expected_updated_at)::text);
  perform pg_advisory_xact_lock(hashtextextended('v510:operation:'||v_actor||':identity_review:'||p_operation_key,0));
  v_replay:=app.v76_replay(v_actor,'resolve_identity_review_v510',p_operation_key::text,v_hash);
  if v_replay is not null then return v_replay;end if;
  select * into v_intake from public.sme_lead_intakes_v510 where id=p_intake for update;
  if not found or v_intake.status<>'duplicate_review' or
     v_intake.updated_at is distinct from p_expected_updated_at then
    raise exception 'duplicate review changed; refresh before deciding' using errcode='40001';end if;
  v_source_system:=coalesce(nullif(btrim(v_intake.source_system),''),'platform_console');
  v_uen_namespace:=lower(coalesce(nullif(btrim(v_intake.company_payload->>'registration_jurisdiction'),''),'sg'));
  v_place_namespace:=lower(coalesce(nullif(btrim(v_intake.company_payload->>'place_provider'),''),v_source_system));
  v_uen:=app.v510_normalize_identity('uen',v_intake.company_payload->>'registration_number');
  v_place:=app.v510_normalize_identity('google_place_id',coalesce(v_intake.company_payload->>'place_id',
    case when v_source_system='google_places' then v_intake.external_id end));
  v_domain:=app.v510_normalize_identity('domain',v_intake.company_payload->>'website');
  v_phone:=app.v510_normalize_identity('phone',coalesce(v_intake.company_payload->>'phone',v_intake.contact_payload->>'phone'));
  v_email:=app.v510_normalize_identity('email',coalesce(v_intake.company_payload->>'email',v_intake.contact_payload->>'email'));
  v_name_postal:=app.v510_normalize_identity('name_postal',
    coalesce(v_intake.company_payload->>'legal_name',v_intake.company_payload->>'trading_name','')||
    coalesce(v_intake.company_payload->>'postal_code',v_intake.company_payload#>>'{address,postal_code}',''));
  if v_uen is not null then
    perform pg_advisory_xact_lock(hashtextextended('v510:uen:'||v_uen_namespace||':'||v_uen,0));
  end if;
  if v_place is not null then
    perform pg_advisory_xact_lock(hashtextextended('v510:place:'||v_place_namespace||':'||v_place,0));
  end if;
  if v_domain is not null then perform pg_advisory_xact_lock(hashtextextended('v510:domain:dns:'||v_domain,0));end if;
  if v_phone is not null then perform pg_advisory_xact_lock(hashtextextended('v510:phone:e164:'||v_phone,0));end if;
  if v_email is not null then perform pg_advisory_xact_lock(hashtextextended('v510:email:rfc5321:'||v_email,0));end if;
  if v_name_postal is not null then perform pg_advisory_xact_lock(hashtextextended('v510:name_postal:sg:'||v_name_postal,0));end if;
  if p_decision='reject' then
    update public.sme_company_identity_match_candidates_v510 set status='rejected',
      decided_by=v_actor,decided_at=clock_timestamp()
    where intake_id=p_intake and status='pending';
    v_result:=jsonb_build_object('disposition','rejected','intake_id',p_intake);
    update public.sme_lead_intakes_v510 set status='rejected',disposition='rejected',
      decided_by=v_actor,decided_at=clock_timestamp(),result=v_result,updated_at=clock_timestamp()
    where id=p_intake;
  else
    if p_decision='confirm' then
      if p_candidate_company is null or not exists(select 1
        from public.sme_company_identity_match_candidates_v510 candidate
        where candidate.intake_id=p_intake and candidate.candidate_company_id=p_candidate_company
          and candidate.status='pending') then
        raise exception 'pending candidate was not found' using errcode='22023';end if;
      v_company:=p_candidate_company;
    else
      if exists(select 1 from public.sme_company_identity_match_candidates_v510 candidate
        where candidate.intake_id=p_intake and candidate.status='pending'
          and candidate.confidence in ('strong','conflict')) then
        raise exception 'strong identity conflicts cannot create a distinct Company' using errcode='23505';end if;
      insert into public.sme_companies(legal_name,trading_name,registration_number,industry,
        sector_key,website,phone,email,address)
      values(nullif(btrim(v_intake.company_payload->>'legal_name'),''),
        nullif(btrim(v_intake.company_payload->>'trading_name'),''),
        nullif(btrim(v_intake.company_payload->>'registration_number'),''),
        nullif(btrim(v_intake.company_payload->>'industry'),''),
        nullif(btrim(v_intake.company_payload->>'sector_key'),''),
        nullif(btrim(v_intake.company_payload->>'website'),''),
        nullif(btrim(v_intake.company_payload->>'phone'),''),
        nullif(btrim(v_intake.company_payload->>'email'),''),
        coalesce(v_intake.company_payload->'address','{}'::jsonb)) returning id into v_company;
    end if;
    update public.sme_companies set registration_number=v_intake.company_payload->>'registration_number',
      updated_at=clock_timestamp()
    where id=v_company and v_uen is not null and nullif(btrim(registration_number),'') is null;
    -- Commit the reviewed evidence to the chosen Company. Strong-key uniqueness
    -- revalidates the decision under the same advisory locks used by ingestion.
    insert into public.sme_company_identity_keys_v510(
      company_id,key_type,key_namespace,normalized_value,confidence,source_system,verified_at,created_by
    ) select v_company,key.key_type,key.key_namespace,key.normalized_value,key.confidence,v_source_system,
        case when key.key_type='google_place_id' and v_source_system in ('google_places','google_business_profile')
          then clock_timestamp() end,v_actor
      from (values
        ('uen',v_uen_namespace,v_uen,'strong'),('google_place_id',v_place_namespace,v_place,'strong'),
        ('domain','dns',v_domain,'supporting'),('phone','e164',v_phone,'supporting'),
        ('email','rfc5321',v_email,'supporting'),('name_postal','sg',v_name_postal,'supporting')
      ) key(key_type,key_namespace,normalized_value,confidence)
      where key.normalized_value is not null and not (key.confidence='strong' and exists(
        select 1 from public.sme_company_identity_keys_v510 existing
        where existing.company_id=v_company and existing.key_type=key.key_type
          and existing.key_namespace=key.key_namespace and existing.normalized_value=key.normalized_value
          and existing.confidence='strong'))
      on conflict on constraint sme_company_identity_provenance_v510_uk do nothing;
    select coalesce(company.peekaa_business_id,(select converted_business_id
      from public.sme_prospects where company_id=v_company and converted_business_id is not null
      order by converted_at desc nulls last limit 1)) into v_business
    from public.sme_companies company where company.id=v_company;
    if v_business is not null then
      select id into v_prospect from public.sme_prospects
      where converted_business_id=v_business order by converted_at desc nulls last limit 1;
    end if;
    if v_business is null then
      select id into v_prospect from public.sme_prospects
      where company_id=v_company and opportunity_kind='core_acquisition' and archived_at is null
        and converted_business_id is null and current_stage_key not in
          ('not_interested','no_response','invalid_contact','closed_business','do_not_contact','lost')
      order by created_at limit 1 for update;
      if not found then
        select id into v_owner from public.platform_consultants
          where id=v_intake.requested_consultant_id and active;
        insert into public.sme_prospects(company_id,current_stage_key,assigned_consultant_id,opportunity_kind,
          ownership_state,queue_key,owner_assigned_at,next_action_type,next_action_at,created_by,updated_by)
        values(v_company,case when v_owner is null then 'new_lead' else 'assigned' end,v_owner,'core_acquisition',
          case when v_owner is null then 'queued' else 'owned' end,
          case when v_owner is null then 'sales_intake' end,
          case when v_owner is not null then clock_timestamp() end,
          case when v_owner is null then 'assign_owner' else 'first_contact' end,
          coalesce(v_intake.requested_next_action_at,clock_timestamp()+interval '1 hour'),v_actor,v_actor)
        returning id into v_prospect;
        insert into public.sme_prospect_stage_history(prospect_id,to_stage_key,reason_code,reason_detail,actor)
        values(v_prospect,case when v_owner is null then 'new_lead' else 'assigned' end,
          'duplicate_review_resolved','Canonical identity review completed',v_actor);
        if v_owner is not null then
          insert into public.sme_prospect_assignments(prospect_id,consultant_id,assigned_by,reason)
          values(v_prospect,v_owner,v_actor,'Ownership restored from reviewed intake');
        end if;
      end if;
      select id into v_owner from public.platform_consultants
        where id=v_intake.requested_consultant_id and active;
      if v_owner is not null and exists(select 1 from public.sme_prospects
        where id=v_prospect and ownership_state='queued') then
        insert into public.sme_prospect_stage_history(prospect_id,from_stage_key,to_stage_key,
          reason_code,reason_detail,actor)
        select id,'new_lead','assigned','reviewed_intake_owner_restored',
          'Ownership restored from reviewed intake',v_actor
        from public.sme_prospects where id=v_prospect and current_stage_key='new_lead';
        update public.sme_prospects set assigned_consultant_id=v_owner,ownership_state='owned',queue_key=null,
          owner_assigned_at=clock_timestamp(),
          current_stage_key=case when current_stage_key='new_lead' then 'assigned' else current_stage_key end,
          next_action_type=case when current_stage_key='new_lead' then 'first_contact' else next_action_type end,
          next_action_at=case when current_stage_key='new_lead' then
            coalesce(v_intake.requested_next_action_at,clock_timestamp()+interval '1 hour') else next_action_at end,
          version=version+1,updated_by=v_actor,updated_at=clock_timestamp() where id=v_prospect;
        insert into public.sme_prospect_assignments(prospect_id,consultant_id,assigned_by,reason)
        values(v_prospect,v_owner,v_actor,'Ownership restored from reviewed intake');
      end if;
      if v_intake.contact_payload is not null and
         (nullif(btrim(v_intake.contact_payload->>'email'),'') is not null or
          nullif(btrim(v_intake.contact_payload->>'phone'),'') is not null) then
        v_phone:=app.v510_normalize_identity('phone',v_intake.contact_payload->>'phone');
        if not exists(select 1 from public.sme_prospect_contacts contact where contact.prospect_id=v_prospect
          and contact.active and (lower(contact.email)=lower(v_intake.contact_payload->>'email')
            or app.v510_normalize_identity('phone',contact.phone)=v_phone)) then
          insert into public.sme_prospect_contacts(prospect_id,full_name,title,email,phone,is_primary)
          values(v_prospect,coalesce(nullif(btrim(v_intake.contact_payload->>'full_name'),''),'Business contact'),
            nullif(btrim(v_intake.contact_payload->>'title'),''),nullif(btrim(v_intake.contact_payload->>'email'),''),
            nullif(btrim(v_intake.contact_payload->>'phone'),''),
            not exists(select 1 from public.sme_prospect_contacts where prospect_id=v_prospect and active and is_primary));
        end if;
      end if;
      if v_intake.external_id is null or not exists(select 1 from public.sme_prospect_source_lineage
        where source_system=v_intake.source_system and external_id=v_intake.external_id) then
        insert into public.sme_prospect_source_lineage(prospect_id,source_system,source_type,
          external_id,detail,created_by)
        values(v_prospect,v_intake.source_system,v_intake.source_type,v_intake.external_id,
          (v_intake.source_payload-'source_system'-'source_type'-'external_id')||
            jsonb_build_object('resolved_intake_id',p_intake),v_actor) returning id into v_source_id;
      end if;
    end if;
    if v_prospect is not null and (v_intake.external_id is null or not exists(select 1
      from public.sme_prospect_source_lineage where source_system=v_intake.source_system
        and external_id=v_intake.external_id)) then
      insert into public.sme_prospect_source_lineage(prospect_id,source_system,source_type,
        external_id,detail,created_by)
      values(v_prospect,v_intake.source_system,v_intake.source_type,v_intake.external_id,
        (v_intake.source_payload-'source_system'-'source_type'-'external_id')||
          jsonb_build_object('resolved_intake_id',p_intake),v_actor) returning id into v_source_id;
    elsif v_prospect is not null then
      select id into v_source_id from public.sme_prospect_source_lineage
      where source_system=v_intake.source_system and external_id=v_intake.external_id
      order by created_at desc limit 1;
    end if;

    v_provider:=v_intake.source_payload->'provider_payload';
    if v_source_system in ('google_places','google_business_profile')
       and jsonb_typeof(v_provider)='object' then
      insert into public.sme_company_sources(company_id,source,source_id,source_url,detail_fetched_at,last_synced_at)
      values(v_company,v_source_system,v_intake.external_id,nullif(v_provider->>'source_url',''),
        case when v_provider?'rating' then clock_timestamp() end,clock_timestamp())
      on conflict(source,source_id) do update set last_synced_at=excluded.last_synced_at,
        detail_fetched_at=coalesce(excluded.detail_fetched_at,public.sme_company_sources.detail_fetched_at);
      insert into public.sme_company_locations(company_id,country,planning_area,district,address,postal_code,
        latitude,longitude,is_primary,geo_source,geo_synced_at)
      values(v_company,coalesce(nullif(v_provider->>'country',''),'SG'),nullif(v_provider->>'planning_area',''),
        nullif(v_provider->>'district',''),nullif(v_provider->>'address',''),nullif(v_provider->>'postal_code',''),
        nullif(v_provider->>'latitude','')::double precision,nullif(v_provider->>'longitude','')::double precision,
        true,case when v_provider->>'geo_source'='onemap' then 'onemap' else 'google_places' end,clock_timestamp())
      on conflict(company_id) where is_primary do update set
        latitude=case when public.sme_company_locations.geo_source='manual' then public.sme_company_locations.latitude else coalesce(excluded.latitude,public.sme_company_locations.latitude) end,
        longitude=case when public.sme_company_locations.geo_source='manual' then public.sme_company_locations.longitude else coalesce(excluded.longitude,public.sme_company_locations.longitude) end,
        address=case when public.sme_company_locations.geo_source='manual' then public.sme_company_locations.address else coalesce(excluded.address,public.sme_company_locations.address) end,
        postal_code=case when public.sme_company_locations.geo_source='manual' then public.sme_company_locations.postal_code else coalesce(excluded.postal_code,public.sme_company_locations.postal_code) end,
        geo_source=case when public.sme_company_locations.geo_source='manual' then 'manual' else excluded.geo_source end,
        geo_synced_at=case when public.sme_company_locations.geo_source='manual' then public.sme_company_locations.geo_synced_at else excluded.geo_synced_at end,
        updated_at=clock_timestamp();
      insert into public.sme_company_market_facts(company_id,business_status,rating,review_count,price_level,
        provider_phone,provider_website,last_synced_at,updated_at)
      values(v_company,v_provider->>'business_status',nullif(v_provider->>'rating','')::numeric,
        nullif(v_provider->>'review_count','')::integer,nullif(v_provider->>'price_level','')::smallint,
        v_provider->>'phone',v_provider->>'website',clock_timestamp(),clock_timestamp())
      on conflict(company_id) do update set
        business_status=coalesce(excluded.business_status,public.sme_company_market_facts.business_status),
        rating=coalesce(excluded.rating,public.sme_company_market_facts.rating),
        review_count=coalesce(excluded.review_count,public.sme_company_market_facts.review_count),
        price_level=coalesce(excluded.price_level,public.sme_company_market_facts.price_level),
        provider_phone=coalesce(excluded.provider_phone,public.sme_company_market_facts.provider_phone),
        provider_website=coalesce(excluded.provider_website,public.sme_company_market_facts.provider_website),
        last_synced_at=excluded.last_synced_at,updated_at=excluded.updated_at;
    end if;

    if v_intake.source_type='import' and nullif(v_intake.source_payload->>'batch_id','') is not null
       and v_prospect is not null then
      v_batch:=(v_intake.source_payload->>'batch_id')::uuid;v_import_row:=v_intake.operation_key;
      insert into public.sme_import_commit_ledger(batch_id,import_row_id,decision,prospect_id,
        company_id,source_lineage_id,prospect_version_at_commit,committed_by)
      select v_batch,v_import_row,'insert',v_prospect,v_company,v_source_id,prospect.version,v_actor
      from public.sme_prospects prospect where prospect.id=v_prospect
      on conflict(import_row_id) do nothing;
      update public.sme_prospect_import_rows set row_status='imported',prospect_id=v_prospect,
        errors=array_remove(errors,'canonical_identity_duplicate_review') where id=v_import_row and batch_id=v_batch;
      update public.sme_prospect_import_batches batch set
        imported_rows=(select count(*) from public.sme_import_commit_ledger ledger where ledger.batch_id=v_batch),
        conflict_rows=(select count(*) from public.sme_prospect_import_rows import_row
          where import_row.batch_id=v_batch and import_row.row_status='conflict')
      where batch.id=v_batch;
    end if;
    update public.sme_company_identity_match_candidates_v510 set
      status=case when candidate_company_id=v_company then 'confirmed' else 'rejected' end,
      decided_by=v_actor,decided_at=clock_timestamp()
    where intake_id=p_intake and status='pending';
    v_result:=jsonb_build_object('disposition',case when v_business is null then 'reused' else 'existing_merchant' end,
      'intake_id',p_intake,'company_id',v_company,'prospect_id',v_prospect,'business_id',v_business);
    update public.sme_lead_intakes_v510 set status=case when v_business is null then 'committed' else 'existing_merchant' end,
      disposition=v_result->>'disposition',company_id=v_company,prospect_id=v_prospect,
      decided_by=v_actor,decided_at=clock_timestamp(),result=v_result,updated_at=clock_timestamp()
    where id=p_intake;
  end if;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(v_business,v_actor,'COMPANY_IDENTITY_REVIEW_RESOLVED_V510','sme_lead_intakes_v510',p_intake,v_result);
  perform app.v76_store_receipt(v_actor,'resolve_identity_review_v510',p_operation_key::text,v_hash,v_result);
  return v_result;
end $$;

-- Outreach is one transactional command: the contact record, canonical task,
-- audit event and replay receipt either all commit once or none do.  The
-- actor/key advisory lock closes the race left by the legacy two-minute
-- similarity check, while the request hash rejects key reuse with new input.
create or replace function public.platform_crm_log_outreach_v297(
  p_prospect uuid,p_channel text,p_outcome text,
  p_notes text default null,p_contact uuid default null,
  p_next_follow_up_at timestamptz default null,
  p_idempotency_key text default null
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare
  v_actor uuid:=auth.uid();v_self uuid;v_assigned uuid;v_stage text;v_sla interval;
  v_hash text;v_replay jsonb;v_outreach uuid;v_task uuid;v_response jsonb;
  v_notes text:=nullif(btrim(coalesce(p_notes,'')),'');
begin
  perform app.v297_assert_prospecting('rw');
  perform app.require_idempotency_key_v79(p_idempotency_key);
  if v_actor is null then raise exception 'authenticated actor is required' using errcode='42501';end if;
  v_hash:=app.v76_sha256_hex(jsonb_build_object(
    'prospect',p_prospect,'channel',p_channel,'outcome',p_outcome,'notes',v_notes,
    'contact',p_contact,'next_follow_up_at',p_next_follow_up_at)::text);
  perform pg_advisory_xact_lock(hashtextextended(
    'v510:operation:'||v_actor||':outreach:'||p_idempotency_key,0));
  v_replay:=app.v76_replay(v_actor,'log_outreach_v510',p_idempotency_key,v_hash);
  if v_replay is not null then return v_replay;end if;

  v_self:=app.v226_self_consultant();
  select prospect.assigned_consultant_id,prospect.current_stage_key,stage.operating_sla
    into v_assigned,v_stage,v_sla
  from public.sme_prospects prospect
  join public.sme_pipeline_stages stage on stage.stage_key=prospect.current_stage_key
  where prospect.id=p_prospect and prospect.archived_at is null
    and prospect.converted_business_id is null for update of prospect;
  if not found then raise exception 'active prospect was not found' using errcode='22023';end if;
  if app.v89_platform_role()='sales_staff' and not app.is_super_admin()
     and v_assigned is distinct from v_self then
    raise exception 'prospect is outside your book' using errcode='42501';end if;
  if p_contact is not null and not exists(select 1 from public.sme_prospect_contacts
      where id=p_contact and prospect_id=p_prospect and active) then
    raise exception 'contact does not belong to the prospect' using errcode='22023';end if;
  if p_outcome='follow_up' and p_next_follow_up_at is null then
    raise exception 'follow-up outcome requires a date' using errcode='22023';end if;
  if p_next_follow_up_at is not null and p_next_follow_up_at<clock_timestamp()-interval '5 minutes' then
    raise exception 'follow-up cannot be in the past' using errcode='22023';end if;
  if p_next_follow_up_at is not null and
     (v_sla is null or p_next_follow_up_at>clock_timestamp()+v_sla+interval '1 minute') then
    raise exception 'follow-up exceeds the canonical stage SLA' using errcode='22023';end if;

  insert into public.sme_outreach_records(
    prospect_id,contact_id,consultant_id,channel,outcome,notes,
    next_follow_up_at,created_by)
  values(p_prospect,p_contact,coalesce(v_self,v_assigned),p_channel,p_outcome,v_notes,
    p_next_follow_up_at,v_actor) returning id into v_outreach;
  if p_next_follow_up_at is not null then
    insert into public.sme_prospect_tasks(
      prospect_id,title,due_at,assigned_consultant_id,status,created_by)
    values(p_prospect,'Follow up: '||p_outcome,p_next_follow_up_at,
      coalesce(v_self,v_assigned),'open',v_actor) returning id into v_task;
  end if;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'CRM_OUTREACH_LOGGED_V510','sme_prospects',p_prospect,
    jsonb_build_object('outreach_id',v_outreach,'task_id',v_task,'channel',p_channel,
      'outcome',p_outcome,'follow_up',p_next_follow_up_at,'stage',v_stage));
  v_response:=jsonb_build_object('outreach_id',v_outreach,'task_id',v_task,'replayed',false);
  perform app.v76_store_receipt(v_actor,'log_outreach_v510',p_idempotency_key,v_hash,v_response);
  return v_response;
end $$;

create or replace function public.platform_list_lead_exceptions_v510(
  p_owner uuid default null,p_limit integer default 100
) returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_role text:=app.v89_platform_role();v_self uuid;v_limit integer:=least(greatest(coalesce(p_limit,100),1),250);
begin
  perform app.v297_assert_prospecting('r');
  if v_role='sales_staff' then
    v_self:=app.v226_self_consultant();
    if p_owner is not null and p_owner is distinct from v_self then
      raise exception 'salesperson may read only their own exceptions' using errcode='42501';end if;
  end if;
  return jsonb_build_object('as_of',clock_timestamp(),'items',coalesce((
    select jsonb_agg(to_jsonb(item) order by item.due_at,item.priority desc,item.prospect_id)
    from (select prospect.id prospect_id,prospect.company_id,prospect.version,
      coalesce(company.trading_name,company.legal_name) company_name,
      prospect.current_stage_key,prospect.assigned_consultant_id,consultant.display_name owner_name,prospect.ownership_state,
      prospect.queue_key,prospect.next_action_type,prospect.next_action_at due_at,prospect.priority,
      case
        when prospect.ownership_state='queued' then 'unassigned'
        when consultant.id is null or not consultant.active then 'inactive_owner'
        when prospect.next_action_at is null then 'missing_next_action'
        when prospect.next_action_at<clock_timestamp() then 'overdue'
        else 'due_today' end exception_reason
      from public.sme_prospects prospect
      join public.sme_companies company on company.id=prospect.company_id
      left join public.platform_consultants consultant on consultant.id=prospect.assigned_consultant_id
      join public.sme_pipeline_stages stage on stage.stage_key=prospect.current_stage_key
      where prospect.archived_at is null and prospect.converted_business_id is null
        and (stage.kind='active' or prospect.current_stage_key='closed_won')
        and (case when v_role='sales_staff' then
          prospect.assigned_consultant_id=v_self or prospect.ownership_state='queued'
          else p_owner is null or prospect.assigned_consultant_id=p_owner end)
        and (prospect.ownership_state='queued' or consultant.id is null or not consultant.active
          or prospect.next_action_at is null
          or prospect.next_action_at<(date_trunc('day',clock_timestamp() at time zone 'Asia/Singapore')
             +interval '1 day') at time zone 'Asia/Singapore')
      order by prospect.next_action_at nulls first limit v_limit) item
  ),'[]'::jsonb));
end $$;

create or replace function public.platform_get_sme_analytics_v510(
  p_from date,p_to date,p_snapshot_at timestamptz default null,
  p_consultant uuid default null,p_limit integer default 100,p_after_source text default null
) returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_base jsonb;v_snapshot timestamptz:=coalesce(p_snapshot_at,clock_timestamp());
  v_from timestamptz;v_to timestamptz;v_effective uuid:=p_consultant;v_won bigint;v_sources jsonb;
begin
  v_base:=public.platform_get_sme_analytics_v86(p_from,p_to,v_snapshot,p_consultant,p_limit,p_after_source);
  if not app.is_super_admin() then
    select id into v_effective from public.platform_consultants where user_id=auth.uid() and active;
  end if;
  v_from:=p_from::timestamp at time zone 'Asia/Singapore';
  v_to:=(p_to+1)::timestamp at time zone 'Asia/Singapore';
  select count(*) into v_won from public.sme_prospect_stage_history history
  join public.sme_prospects prospect on prospect.id=history.prospect_id
  where history.to_stage_key='closed_won' and history.occurred_at>=v_from
    and history.occurred_at<v_to and history.occurred_at<=v_snapshot
    and (v_effective is null or prospect.assigned_consultant_id=v_effective);
  select coalesce(jsonb_agg(jsonb_set(source.value,'{converted}',to_jsonb(metric.converted),true)),'[]'::jsonb)
  into v_sources from jsonb_array_elements(coalesce(v_base->'source_page','[]'::jsonb)) source(value)
  cross join lateral(select count(distinct lineage.prospect_id) converted
    from public.sme_prospect_source_lineage lineage
    join public.sme_prospect_stage_history history on history.prospect_id=lineage.prospect_id
      and history.to_stage_key='closed_won' and history.occurred_at>=v_from
      and history.occurred_at<v_to and history.occurred_at<=v_snapshot
    join public.sme_prospects prospect on prospect.id=lineage.prospect_id
    where lineage.source_type=source.value->>'source_type'
      and (v_effective is null or prospect.assigned_consultant_id=v_effective)) metric;
  return jsonb_set(jsonb_set(v_base,'{summary,won}',to_jsonb(v_won),true),'{source_page}',v_sources,true);
end $$;

create or replace function public.platform_get_lead_timeline_v510(
  p_prospect uuid,p_limit integer default 100
) returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_role text:=app.v89_platform_role();v_self uuid;v_limit integer:=least(greatest(coalesce(p_limit,100),1),250);
begin
  perform app.v297_assert_prospecting('r');
  if v_role='sales_staff' then
    v_self:=app.v226_self_consultant();
    if not exists(select 1 from public.sme_prospects where id=p_prospect and assigned_consultant_id=v_self) then
      raise exception 'lead is outside your book' using errcode='42501';end if;
  end if;
  if not exists(select 1 from public.sme_prospects where id=p_prospect) then
    raise exception 'lead was not found' using errcode='22023';end if;
  return jsonb_build_object('prospect_id',p_prospect,'items',coalesce((
    select jsonb_agg(to_jsonb(timeline)-'sort_id' order by occurred_at desc,sort_id desc)
    from (select * from (
      select history.id sort_id,history.occurred_at,'stage_changed' event_type,history.actor,
        coalesce(history.from_stage_key,'created')||' → '||history.to_stage_key summary,
        jsonb_build_object('from',history.from_stage_key,'to',history.to_stage_key,
          'reason_code',history.reason_code,'reason_detail',history.reason_detail) detail
      from public.sme_prospect_stage_history history where history.prospect_id=p_prospect
      union all
      select assignment.id,assignment.created_at,'ownership_changed',assignment.assigned_by,
        coalesce(consultant.display_name,'Unassigned'),
        jsonb_build_object('consultant_id',assignment.consultant_id,'reason',assignment.reason)
      from public.sme_prospect_assignments assignment
      left join public.platform_consultants consultant on consultant.id=assignment.consultant_id
      where assignment.prospect_id=p_prospect
      union all
      select activity.id,activity.occurred_at,'activity',activity.created_by,activity.summary,
        jsonb_build_object('activity_type',activity.activity_type,'detail',activity.detail)
      from public.sme_prospect_activities activity where activity.prospect_id=p_prospect
      union all
      select outreach.id,outreach.contacted_at,'outreach',outreach.created_by,
        outreach.channel||' / '||outreach.outcome,
        jsonb_build_object('channel',outreach.channel,'outcome',outreach.outcome,
          'notes',outreach.notes,'next_follow_up_at',outreach.next_follow_up_at)
      from public.sme_outreach_records outreach where outreach.prospect_id=p_prospect
      union all
      select source.id,source.created_at,'source_added',source.created_by,
        source.source_system||' / '||source.source_type,
        jsonb_build_object('external_id',source.external_id,'detail',source.detail)
      from public.sme_prospect_source_lineage source where source.prospect_id=p_prospect
      union all
      select task.id,coalesce(task.completed_at,task.created_at),'task',task.created_by,task.title,
        jsonb_build_object('due_at',task.due_at,'status',task.status,'outcome',task.outcome)
      from public.sme_prospect_tasks task where task.prospect_id=p_prospect
    ) events order by occurred_at desc,sort_id desc limit v_limit) timeline
  ),'[]'::jsonb));
end $$;

revoke all on function app.v510_normalize_identity(text,text) from public,anon,authenticated;
revoke all on function app.v510_sync_company_identity() from public,anon,authenticated;
revoke all on function app.v510_sync_company_source_identity() from public,anon,authenticated;
revoke all on function app.v510_sync_contact_identity() from public,anon,authenticated;
revoke all on function app.v510_freeze_converted_company_identity() from public,anon,authenticated;
revoke all on function app.v510_prospect_operating_guard() from public,anon,authenticated;
revoke all on function app.v510_project_contact_activity() from public,anon,authenticated;
revoke all on function app.v510_version_next_action_change() from public,anon,authenticated;
revoke all on function app.v510_project_canonical_task() from public,anon,authenticated;
revoke all on function app.v510_reject_activity_shadow_action() from public,anon,authenticated;
revoke all on function app.v510_guard_payment_onboarding_item() from public,anon,authenticated;
revoke all on function app.v510_add_payment_onboarding_item() from public,anon,authenticated;
revoke all on function app.v510_sync_payment_readiness(uuid,uuid) from public,anon,authenticated;
revoke all on function app.v510_project_stripe_payment_readiness() from public,anon,authenticated;
revoke all on function app.v510_project_subscription_payment_readiness() from public,anon,authenticated;
revoke all on function app.v510_project_adjustment_payment_readiness() from public,anon,authenticated;
revoke all on function app.v510_guard_business_activation() from public,anon,authenticated;
revoke all on function app.v510_guard_inactive_shell_rails() from public,anon,authenticated;
revoke all on function app.v510_guard_paid_handoff() from public,anon,authenticated;
revoke all on function app.v510_project_verified_manual_payment() from public,anon,authenticated;
revoke all on function app.v510_normalize_manual_entitlement_event() from public,anon,authenticated;
revoke all on function app.v510_close_obsolete_manual_entitlement_task() from public,anon,authenticated;
revoke all on function public.platform_ingest_lead_v510(jsonb,jsonb,jsonb,uuid,timestamptz,uuid) from public,anon,authenticated;
revoke all on function public.platform_bulk_transfer_leads_v510(uuid[],uuid,text,uuid) from public,anon,authenticated;
revoke all on function public.platform_claim_lead_v510(uuid,bigint,uuid) from public,anon,authenticated;
revoke all on function public.platform_transfer_lead_v510(uuid,uuid,bigint,text,uuid) from public,anon,authenticated;
revoke all on function public.platform_queue_lead_v510(uuid,text,bigint,text,uuid) from public,anon,authenticated;
revoke all on function public.platform_reassign_consultant_portfolio_v510(uuid,uuid,integer,text,uuid) from public,anon,authenticated;
revoke all on function public.platform_transition_lead_v510(uuid,text,bigint,text,timestamptz,text,text,jsonb,jsonb,uuid) from public,anon,authenticated;
revoke all on function public.platform_list_identity_reviews_v510(integer) from public,anon,authenticated;
revoke all on function public.platform_resolve_identity_review_v510(uuid,text,uuid,timestamptz,uuid) from public,anon,authenticated;
revoke all on function public.platform_list_lead_exceptions_v510(uuid,integer) from public,anon,authenticated;
revoke all on function public.platform_get_sme_analytics_v510(date,date,timestamptz,uuid,integer,text) from public,anon,authenticated;
revoke all on function public.platform_get_lead_timeline_v510(uuid,integer) from public,anon,authenticated;
revoke all on function public.platform_crm_log_outreach_v297(uuid,text,text,text,uuid,timestamptz,text) from public,anon,authenticated;
revoke all on function public.platform_crm_ingest_discovered_v297(jsonb,jsonb,boolean,integer,integer) from public,anon,authenticated;
revoke all on function public.platform_commit_prospect_import_v86(uuid) from public,anon,authenticated;

-- Remove callable bypasses after every current UI/source adapter has been cut
-- over above. Historical functions remain for migration dependency integrity.
revoke execute on function public.platform_create_prospect_v76(jsonb,jsonb,text,uuid,jsonb,text[],text)
  from public,anon,authenticated;
revoke execute on function public.platform_create_my_prospect_v89(text,text,text,text,text)
  from public,anon,authenticated;
revoke execute on function public.platform_assign_prospect_v89(uuid,uuid,text)
  from public,anon,authenticated;
revoke execute on function public.platform_move_prospect_stage_v76(uuid,text,bigint,text,text,jsonb,text)
  from public,anon,authenticated;
revoke execute on function public.platform_move_prospect_stage_v86(uuid,text,bigint,jsonb,jsonb,text)
  from public,anon,authenticated;
revoke execute on function public.platform_move_my_prospect_stage_v89(uuid,text,bigint,text)
  from public,anon,authenticated;
revoke execute on function public.platform_commit_prospect_import_v76(uuid,text)
  from public,anon,authenticated;
revoke execute on function public.platform_explorer_bulk_assign_v312(uuid[],uuid,text)
  from public,anon,authenticated;
revoke execute on function public.platform_merge_prospects_v184(uuid,uuid,text)
  from public,anon,authenticated;

grant execute on function public.platform_ingest_lead_v510(jsonb,jsonb,jsonb,uuid,timestamptz,uuid) to authenticated;
grant execute on function public.platform_bulk_transfer_leads_v510(uuid[],uuid,text,uuid) to authenticated;
grant execute on function public.platform_claim_lead_v510(uuid,bigint,uuid) to authenticated;
grant execute on function public.platform_transfer_lead_v510(uuid,uuid,bigint,text,uuid) to authenticated;
grant execute on function public.platform_queue_lead_v510(uuid,text,bigint,text,uuid) to authenticated;
grant execute on function public.platform_reassign_consultant_portfolio_v510(uuid,uuid,integer,text,uuid) to authenticated;
grant execute on function public.platform_transition_lead_v510(uuid,text,bigint,text,timestamptz,text,text,jsonb,jsonb,uuid) to authenticated;
grant execute on function public.platform_list_identity_reviews_v510(integer) to authenticated;
grant execute on function public.platform_resolve_identity_review_v510(uuid,text,uuid,timestamptz,uuid) to authenticated;
grant execute on function public.platform_list_lead_exceptions_v510(uuid,integer) to authenticated;
grant execute on function public.platform_get_sme_analytics_v510(date,date,timestamptz,uuid,integer,text) to authenticated;
grant execute on function public.platform_get_lead_timeline_v510(uuid,integer) to authenticated;
grant execute on function public.platform_crm_log_outreach_v297(uuid,text,text,text,uuid,timestamptz,text) to authenticated;
grant execute on function public.platform_crm_ingest_discovered_v297(jsonb,jsonb,boolean,integer,integer) to authenticated;
grant execute on function public.platform_commit_prospect_import_v86(uuid) to authenticated;

commit;
