-- NESTLY v79 - TRANSACTIONAL PROSPECT CONVERSION + EVIDENCE-BACKED ONBOARDING
-- Local review candidate. No production migration or deployment is authorized.

begin;

alter table public.businesses
  add column if not exists legal_name text,
  add column if not exists registration_number text,
  add column if not exists onboarding_started_at timestamptz,
  add column if not exists activated_at timestamptz,
  add column if not exists source_prospect_id uuid
    references public.sme_prospects(id) on delete restrict;
create unique index businesses_source_prospect_uk
  on public.businesses(source_prospect_id) where source_prospect_id is not null;
create unique index businesses_registration_number_uk
  on public.businesses(lower(btrim(registration_number)))
  where registration_number is not null and length(btrim(registration_number))>0;

alter table public.subscriptions
  add column if not exists plan_code text,
  add column if not exists product_code text,
  add column if not exists commercial_terms_id uuid
    references public.sme_commercial_terms(id) on delete restrict,
  add column if not exists seat_limit integer check (seat_limit is null or seat_limit>0);
create unique index subscriptions_commercial_terms_uk
  on public.subscriptions(commercial_terms_id) where commercial_terms_id is not null;

create table public.workspace_owner_invitations(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  prospect_id uuid not null references public.sme_prospects(id) on delete restrict,
  version integer not null check(version>0),
  owner_email text not null check(position('@' in owner_email)>1),
  token_hash text not null unique check(token_hash~'^[0-9a-f]{64}$'),
  token_last_four text not null check(length(token_last_four)=4),
  status text not null default 'pending' check(status in ('pending','accepted','revoked','expired')),
  expires_at timestamptz not null,
  issued_by uuid references auth.users(id) on delete set null,
  accepted_by uuid references auth.users(id) on delete restrict,
  accepted_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  unique(business_id,version),
  constraint workspace_owner_invitation_status_shape check(
    (status='pending' and accepted_by is null and accepted_at is null and revoked_at is null)
    or (status='accepted' and accepted_by is not null and accepted_at is not null and revoked_at is null)
    or (status in ('revoked','expired') and accepted_by is null and accepted_at is null and revoked_at is not null)
  )
);
create unique index workspace_owner_invitations_one_pending_uk
  on public.workspace_owner_invitations(business_id) where status='pending';

create table public.business_onboarding_checklists(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null unique references public.businesses(id) on delete restrict,
  prospect_id uuid not null unique references public.sme_prospects(id) on delete restrict,
  status text not null default 'not_started'
    check(status in ('not_started','in_progress','blocked','ready','activated')),
  version bigint not null default 1 check(version>0),
  blocked_reason text,
  blocked_by uuid references auth.users(id) on delete set null,
  blocked_at timestamptz,
  started_at timestamptz,
  activated_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint business_onboarding_checklist_block_shape check(
    (blocked_at is null and blocked_reason is null and blocked_by is null)
    or (blocked_at is not null and length(btrim(coalesce(blocked_reason,'')))>=3)
  )
);

create table public.business_onboarding_items(
  id uuid primary key default gen_random_uuid(),
  checklist_id uuid not null references public.business_onboarding_checklists(id) on delete restrict,
  business_id uuid not null references public.businesses(id) on delete restrict,
  item_key text not null check(item_key~'^[a-z][a-z0-9_]*$'),
  label text not null,
  category text not null check(category in ('legal','owner','billing','workspace','users','first_value','training','go_live','import','integration','security')),
  verification_mode text not null check(verification_mode in ('derived','manual','sa_approval')),
  mandatory boolean not null default true,
  waivable boolean not null default false,
  status text not null default 'pending' check(status in ('pending','satisfied','waived','blocked')),
  status_before_block text check(status_before_block in ('pending','satisfied','waived')),
  evidence jsonb not null default '{}'::jsonb check(jsonb_typeof(evidence)='object'),
  satisfied_by uuid references auth.users(id) on delete set null,
  satisfied_at timestamptz,
  waived_by uuid references auth.users(id) on delete set null,
  waived_at timestamptz,
  waiver_reason text,
  blocked_by uuid references auth.users(id) on delete set null,
  blocked_at timestamptz,
  block_reason text,
  updated_at timestamptz not null default now(),
  unique(checklist_id,item_key),
  unique(id,business_id),
  constraint business_onboarding_item_waiver_check check(
    status<>'waived' or (waivable and waived_by is not null and waived_at is not null
      and length(btrim(coalesce(waiver_reason,'')))>=3)
  ),
  constraint business_onboarding_item_block_check check(
    status<>'blocked' or (blocked_by is not null and blocked_at is not null
      and length(btrim(coalesce(block_reason,'')))>=3 and status_before_block is not null)
  )
);
create index business_onboarding_items_status_idx
  on public.business_onboarding_items(business_id,status,item_key);

create table public.business_onboarding_events(
  id uuid primary key default gen_random_uuid(),
  checklist_id uuid not null references public.business_onboarding_checklists(id) on delete restrict,
  business_id uuid not null references public.businesses(id) on delete restrict,
  item_id uuid,
  event_type text not null check(event_type in
    ('created','started','refreshed','evidence_recorded','item_waived','blocked',
     'unblocked','owner_invite_accepted','activated')),
  from_status text,
  to_status text,
  evidence jsonb not null default '{}'::jsonb check(jsonb_typeof(evidence)='object'),
  actor uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint business_onboarding_events_item_fk foreign key(item_id,business_id)
    references public.business_onboarding_items(id,business_id) on delete restrict
);
create index business_onboarding_events_timeline_idx
  on public.business_onboarding_events(business_id,created_at,id);

alter table public.workspace_owner_invitations enable row level security;
revoke all privileges on table public.workspace_owner_invitations from public, anon, authenticated;
alter table public.business_onboarding_checklists enable row level security;
revoke all privileges on table public.business_onboarding_checklists from public, anon, authenticated;
alter table public.business_onboarding_items enable row level security;
revoke all privileges on table public.business_onboarding_items from public, anon, authenticated;
alter table public.business_onboarding_events enable row level security;
revoke all privileges on table public.business_onboarding_events from public, anon, authenticated;

create trigger business_onboarding_events_immutable_guard
  before update or delete on public.business_onboarding_events
  for each row execute function app.v75_immutable_guard();

create or replace function app.normalized_business_identity_v79(p_value text)
returns text language sql immutable
set search_path to 'pg_catalog','pg_temp'
as $$ select nullif(regexp_replace(lower(btrim(coalesce(p_value,''))),'[^a-z0-9]','','g'),'') $$;
revoke all on function app.normalized_business_identity_v79(text) from public,anon,authenticated;

drop index if exists public.businesses_registration_number_uk;
create unique index businesses_registration_number_uk
  on public.businesses(app.normalized_business_identity_v79(registration_number))
  where app.normalized_business_identity_v79(registration_number) is not null;

create or replace function app.require_idempotency_key_v79(p_key text)
returns void language plpgsql immutable
set search_path to 'pg_catalog','pg_temp'
as $$
begin
  if length(btrim(coalesce(p_key,''))) not between 8 and 200 then
    raise exception 'idempotency key must contain 8 to 200 characters' using errcode='22023';
  end if;
end
$$;
revoke all on function app.require_idempotency_key_v79(text) from public,anon,authenticated;

create or replace function app.guard_converted_prospect_v79()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if old.converted_business_id is not null and (
    new.current_stage_key is distinct from old.current_stage_key
    or new.assigned_consultant_id is distinct from old.assigned_consultant_id
    or new.company_id is distinct from old.company_id
  ) and coalesce(current_setting('app.v79_system_transition',true),'')<>'on' then
    raise exception 'converted prospect lifecycle is controlled by v79 onboarding' using errcode='42501';
  end if;
  return new;
end
$$;
revoke all on function app.guard_converted_prospect_v79() from public,anon,authenticated;
create trigger sme_prospects_v79_lifecycle_guard
  before update on public.sme_prospects
  for each row execute function app.guard_converted_prospect_v79();

create or replace function app.guard_converted_commercial_terms_v79()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if exists(
    select 1 from public.sme_prospects
    where id=new.prospect_id and converted_business_id is not null
  ) then
    raise exception 'commercial terms are frozen after prospect conversion' using errcode='42501';
  end if;
  return new;
end
$$;
revoke all on function app.guard_converted_commercial_terms_v79() from public,anon,authenticated;
create trigger sme_commercial_terms_v79_conversion_guard
  before insert on public.sme_commercial_terms
  for each row execute function app.guard_converted_commercial_terms_v79();

create or replace function app.guard_converted_workspace_activation_v79()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if coalesce(current_setting('app.v79_system_transition',true),'')='on' then return new;end if;
  if tg_table_name='businesses' and old.source_prospect_id is not null and (
    new.source_prospect_id is distinct from old.source_prospect_id
    or new.onboarding_started_at is distinct from old.onboarding_started_at
    or new.activated_at is distinct from old.activated_at
    or new.legal_name is distinct from old.legal_name
    or new.registration_number is distinct from old.registration_number
  ) then
    raise exception 'converted workspace identity and activation are controlled by v79' using errcode='42501';
  elsif tg_table_name='branches'
    and old.active=false and new.active=true
    and exists(select 1 from public.businesses where id=new.business_id and source_prospect_id is not null)
  then
    raise exception 'converted workspace branch activation is controlled by v79' using errcode='42501';
  end if;
  return new;
end
$$;
revoke all on function app.guard_converted_workspace_activation_v79() from public,anon,authenticated;
create trigger businesses_v79_conversion_guard
  before update on public.businesses
  for each row execute function app.guard_converted_workspace_activation_v79();
create trigger branches_v79_activation_guard
  before update on public.branches
  for each row execute function app.guard_converted_workspace_activation_v79();

create or replace function app.issue_workspace_owner_invite_core_v79(
  p_business uuid,p_prospect uuid,p_email text,p_actor uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_token text;v_hash text;v_version integer;v_row public.workspace_owner_invitations%rowtype;
begin
  if p_business is null or p_prospect is null or position('@' in coalesce(p_email,''))<=1 then
    raise exception 'complete workspace owner invitation input is required' using errcode='22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_business::text,79));
  update public.workspace_owner_invitations set status='revoked',revoked_at=now()
   where business_id=p_business and status='pending';
  select coalesce(max(version),0)+1 into v_version
    from public.workspace_owner_invitations where business_id=p_business;
  v_token:=encode(extensions.gen_random_bytes(32),'hex');
  v_hash:=app.v76_sha256_hex(v_token);
  insert into public.workspace_owner_invitations(
    business_id,prospect_id,version,owner_email,token_hash,token_last_four,
    expires_at,issued_by
  ) values(p_business,p_prospect,v_version,lower(btrim(p_email)),v_hash,right(v_token,4),
    now()+interval '14 days',p_actor) returning * into v_row;
  return jsonb_build_object('id',v_row.id,'business_id',p_business,'version',v_version,
    'owner_email',v_row.owner_email,'status',v_row.status,'expires_at',v_row.expires_at,
    'token_last_four',v_row.token_last_four,'raw_token',v_token);
end
$$;
revoke all on function app.issue_workspace_owner_invite_core_v79(uuid,uuid,text,uuid)
  from public,anon,authenticated;

create or replace function app.create_onboarding_checklist_core_v79(
  p_business uuid,p_prospect uuid,p_actor uuid
)
returns uuid language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_checklist uuid;
begin
  insert into public.business_onboarding_checklists(business_id,prospect_id,created_by)
  values(p_business,p_prospect,p_actor) returning id into v_checklist;
  insert into public.business_onboarding_items(
    checklist_id,business_id,item_key,label,category,verification_mode,mandatory,waivable
  ) values
    (v_checklist,p_business,'legal_identity','Legal identity recorded','legal','derived',true,false),
    (v_checklist,p_business,'owner_access','Workspace owner accepted access','owner','derived',true,false),
    (v_checklist,p_business,'billing_terms','Accepted commercial and billing terms linked','billing','derived',true,false),
    (v_checklist,p_business,'core_workspace','Sector, branch and core workspace created','workspace','derived',true,false),
    (v_checklist,p_business,'users_ready','At least one owner and users within seat limit','users','derived',true,false),
    (v_checklist,p_business,'first_value_configured','A live service, product or loyalty programme exists','first_value','derived',true,false),
    (v_checklist,p_business,'training_completed','Owner training completed','training','manual',true,true),
    (v_checklist,p_business,'go_live_readiness','Go-live runbook completed','go_live','manual',true,true),
    (v_checklist,p_business,'data_import_readiness','Data import reviewed or declared unnecessary','import','manual',true,true),
    (v_checklist,p_business,'integration_readiness','Integration readiness reviewed','integration','manual',true,true),
    (v_checklist,p_business,'security_readiness','Operational security review completed','security','manual',true,true),
    (v_checklist,p_business,'go_live_approved','Go-live approved by super admin','go_live','sa_approval',true,false);
  insert into public.business_onboarding_events(checklist_id,business_id,event_type,to_status,evidence,actor)
  values(v_checklist,p_business,'created','not_started',
    jsonb_build_object('mandatory_items',12),p_actor);
  return v_checklist;
end
$$;
revoke all on function app.create_onboarding_checklist_core_v79(uuid,uuid,uuid)
  from public,anon,authenticated;

create or replace function app.recompute_onboarding_status_v79(p_business uuid,p_actor uuid)
returns text language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_row public.business_onboarding_checklists%rowtype;v_status text;
begin
  select * into v_row from public.business_onboarding_checklists
   where business_id=p_business for update;
  if not found then raise exception 'onboarding checklist was not found' using errcode='22023';end if;
  if v_row.status='activated' then return 'activated';end if;
  if v_row.blocked_at is not null or exists(
    select 1 from public.business_onboarding_items where business_id=p_business and status='blocked'
  ) then v_status:='blocked';
  elsif v_row.started_at is not null and not exists(
    select 1 from public.business_onboarding_items
     where business_id=p_business and mandatory and status not in ('satisfied','waived')
  ) then v_status:='ready';
  elsif v_row.started_at is not null then v_status:='in_progress';
  else v_status:='not_started';end if;
  update public.business_onboarding_checklists set status=v_status,version=version+1,
    updated_at=now() where id=v_row.id;
  return v_status;
end
$$;
revoke all on function app.recompute_onboarding_status_v79(uuid,uuid)
  from public,anon,authenticated;

create or replace function app.refresh_onboarding_core_v79(p_business uuid,p_actor uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_item record;v_ok boolean;v_evidence jsonb;v_status text;
begin
  for v_item in select item_key from public.business_onboarding_items
    where business_id=p_business and verification_mode='derived' and status not in ('blocked','waived')
  loop
    case v_item.item_key
      when 'legal_identity' then
        select app.normalized_business_identity_v79(legal_name) is not null
          and app.normalized_business_identity_v79(registration_number) is not null,
          jsonb_build_object('legal_name',legal_name,'registration_number',registration_number)
          into v_ok,v_evidence from public.businesses where id=p_business;
      when 'owner_access' then
        select exists(select 1 from public.workspace_owner_invitations invitation
          join public.staff staff on staff.business_id=invitation.business_id
            and staff.user_id=invitation.accepted_by and staff.role='owner' and staff.active
          where invitation.business_id=p_business and invitation.status='accepted'),
          jsonb_build_object('accepted_owner_count',(select count(*) from public.staff
            where business_id=p_business and role='owner' and active and user_id is not null))
          into v_ok,v_evidence;
      when 'billing_terms' then
        select subscription.commercial_terms_id=terms.id
          and subscription.plan_code=terms.plan_code
          and subscription.product_code=terms.product_code
          and subscription.billing_cadence=terms.billing_cycle
          and subscription.seat_limit=terms.seats
          and terms.contract_status in ('accepted','signed'),
          jsonb_build_object('commercial_terms_id',subscription.commercial_terms_id,
            'plan_code',subscription.plan_code,'product_code',subscription.product_code,
            'billing_cadence',subscription.billing_cadence,'seat_limit',subscription.seat_limit)
          into v_ok,v_evidence
          from public.subscriptions subscription
          join public.sme_commercial_terms terms on terms.id=subscription.commercial_terms_id
          where subscription.business_id=p_business;
      when 'core_workspace' then
        select exists(select 1 from public.business_sector_assignments where business_id=p_business)
          and exists(select 1 from public.branches where business_id=p_business and is_default and not active)
          and exists(select 1 from public.loyalty_programs where business_id=p_business
            and configuration_status='draft' and not active),
          jsonb_build_object('sector_assigned',exists(select 1 from public.business_sector_assignments where business_id=p_business),
            'inactive_default_branch',exists(select 1 from public.branches where business_id=p_business and is_default and not active),
            'draft_loyalty',exists(select 1 from public.loyalty_programs where business_id=p_business
              and configuration_status='draft' and not active))
          into v_ok,v_evidence;
      when 'users_ready' then
        select exists(select 1 from public.staff where business_id=p_business and role='owner' and active and user_id is not null)
          and app.billable_seats(p_business)<=coalesce((select seat_limit from public.subscriptions where business_id=p_business),0),
          jsonb_build_object('billable_seats',app.billable_seats(p_business),
            'seat_limit',(select seat_limit from public.subscriptions where business_id=p_business))
          into v_ok,v_evidence;
      when 'first_value_configured' then
        select exists(select 1 from public.loyalty_programs where business_id=p_business and active and configuration_status='published')
          or exists(select 1 from public.services where business_id=p_business and active)
          or exists(select 1 from public.products where business_id=p_business and active),
          jsonb_build_object(
            'published_loyalty',exists(select 1 from public.loyalty_programs where business_id=p_business and active and configuration_status='published'),
            'active_services',(select count(*) from public.services where business_id=p_business and active),
            'active_products',(select count(*) from public.products where business_id=p_business and active))
          into v_ok,v_evidence;
      else v_ok:=false;v_evidence:='{}';end case;
    update public.business_onboarding_items set status=case when v_ok then 'satisfied' else 'pending' end,
      evidence=v_evidence,satisfied_by=case when v_ok then p_actor end,
      satisfied_at=case when v_ok then coalesce(satisfied_at,now()) end,updated_at=now()
     where business_id=p_business and item_key=v_item.item_key;
  end loop;
  v_status:=app.recompute_onboarding_status_v79(p_business,p_actor);
  return jsonb_build_object('business_id',p_business,'status',v_status);
end
$$;
revoke all on function app.refresh_onboarding_core_v79(uuid,uuid)
  from public,anon,authenticated;

create or replace function public.convert_sme_prospect_v79(
  p_prospect uuid,p_expected_version bigint,p_idempotency_key text
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();v_hash text;v_replay jsonb;v_prospect public.sme_prospects%rowtype;
  v_company public.sme_companies%rowtype;v_terms public.sme_commercial_terms%rowtype;
  v_bundle public.sector_bundle_versions%rowtype;v_business public.businesses%rowtype;
  v_duplicate public.businesses%rowtype;v_branch uuid;v_checklist uuid;v_invite jsonb;
  v_response jsonb;v_sector text;v_slug text;v_months integer;
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  perform app.require_idempotency_key_v79(p_idempotency_key);
  v_hash:=app.v76_sha256_hex(jsonb_build_object('prospect',p_prospect,'version',p_expected_version)::text);
  v_replay:=app.v76_replay(v_actor,'convert_prospect_v79',p_idempotency_key,v_hash);
  if v_replay is not null then return v_replay;end if;
  select * into v_prospect from public.sme_prospects where id=p_prospect for update;
  if not found then raise exception 'prospect was not found' using errcode='22023';end if;
  if v_prospect.converted_business_id is not null then
    return jsonb_build_object('replayed',false,'outcome','already_converted',
      'prospect_id',p_prospect,'business_id',v_prospect.converted_business_id,
      'prospect_version',v_prospect.version);
  end if;
  if v_prospect.version<>p_expected_version then raise exception 'prospect version conflict' using errcode='40001';end if;
  if v_prospect.current_stage_key<>'client' then raise exception 'only a Client / Deal Won prospect can convert' using errcode='22023';end if;
  select * into v_company from public.sme_companies where id=v_prospect.company_id;
  select * into v_terms from public.sme_commercial_terms
   where prospect_id=p_prospect and contract_status in ('accepted','signed')
   order by version desc limit 1;
  if not found then raise exception 'latest accepted or signed commercial terms are required' using errcode='22023';end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    coalesce(app.normalized_business_identity_v79(v_company.registration_number),'registration:none'),79));
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    coalesce(app.normalized_business_identity_v79(coalesce(v_company.legal_name,v_company.trading_name)),'name:none'),79));
  select * into v_duplicate from public.businesses business
   where (v_company.registration_number is not null
      and app.normalized_business_identity_v79(business.registration_number)
        =app.normalized_business_identity_v79(v_company.registration_number))
      or app.normalized_business_identity_v79(coalesce(business.legal_name,business.name))
         =app.normalized_business_identity_v79(coalesce(v_company.legal_name,v_company.trading_name))
   order by business.created_at limit 1;
  if found then
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
  insert into public.businesses(
    name,slug,industry,enabled_modules,legal_name,registration_number,source_prospect_id
  ) values(coalesce(v_company.trading_name,v_company.legal_name),v_slug,v_sector,v_bundle.modules,
    coalesce(v_company.legal_name,v_company.trading_name),v_company.registration_number,p_prospect)
  returning * into v_business;
  insert into public.branches(business_id,name,is_default,active)
  values(v_business.id,coalesce(v_company.trading_name,v_company.legal_name),true,false)
  returning id into v_branch;
  insert into public.loyalty_programs(
    business_id,kind,earn_points_per_dollar,redeem_points,reward_credit_cents,
    active,loyalty_model,configuration_status,recommendation_source
  ) values(v_business.id,'points',1,800,2000,false,'classic','draft','prospect_conversion_v79');
  v_months:=case v_terms.billing_cycle when 'quarterly' then 3 when 'half_yearly' then 6 else 12 end;
  insert into public.subscriptions(
    business_id,status,currency,billing_provider,billing_cadence,cadence_months,
    plan_code,product_code,commercial_terms_id,seat_limit
  ) values(v_business.id,'trialing',v_terms.currency,'manual',v_terms.billing_cycle,v_months,
    v_terms.plan_code,v_terms.product_code,v_terms.id,v_terms.seats);
  insert into public.business_sector_assignments(
    business_id,bundle_version_id,version,assigned_by
  ) values(v_business.id,v_bundle.id,1,v_actor);
  v_invite:=app.issue_workspace_owner_invite_core_v79(
    v_business.id,p_prospect,v_terms.owner_email,v_actor);
  v_checklist:=app.create_onboarding_checklist_core_v79(v_business.id,p_prospect,v_actor);
  update public.sme_prospects set converted_business_id=v_business.id,converted_at=now(),
    converted_by=v_actor,current_stage_key='account_created',stage_entered_at=now(),
    version=version+1,updated_by=v_actor,updated_at=now() where id=p_prospect
    returning * into v_prospect;
  insert into public.sme_prospect_stage_history(prospect_id,from_stage_key,to_stage_key,reason_code,reason_detail,actor)
  values(p_prospect,'client','account_created','conversion_completed','Workspace and owner invitation created',v_actor);
  insert into public.sme_prospect_activities(prospect_id,consultant_id,activity_type,summary,detail,created_by)
  values(p_prospect,v_prospect.assigned_consultant_id,'system','Account created',
    'v79 transactional workspace conversion completed',v_actor);
  perform app.refresh_onboarding_core_v79(v_business.id,v_actor);
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(v_business.id,v_actor,'SME_PROSPECT_CONVERTED_V79','businesses',v_business.id,
    jsonb_build_object('prospect_id',p_prospect,'commercial_terms_id',v_terms.id,
      'sector_bundle_version_id',v_bundle.id,'branch_id',v_branch,'checklist_id',v_checklist));
  v_response:=jsonb_build_object('replayed',false,'outcome','converted','prospect_id',p_prospect,
    'prospect_version',v_prospect.version,'business_id',v_business.id,'branch_id',v_branch,
    'checklist_id',v_checklist,'owner_invitation',v_invite);
  perform app.v76_store_receipt(v_actor,'convert_prospect_v79',p_idempotency_key,v_hash,
    v_response#-'{owner_invitation,raw_token}');
  return v_response;
end
$$;

create or replace function public.accept_workspace_owner_invite_v79(
  p_token text,p_idempotency_key text
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();v_email text;v_hash text;v_request_hash text;v_replay jsonb;
  v_invite public.workspace_owner_invitations%rowtype;v_staff uuid;v_branch uuid;v_response jsonb;
  v_checklist uuid;
begin
  if v_actor is null then raise exception 'authenticated owner access is required' using errcode='42501';end if;
  perform app.require_idempotency_key_v79(p_idempotency_key);
  select lower(btrim(email)) into v_email from auth.users
   where id=v_actor and email_confirmed_at is not null;
  if v_email is null then raise exception 'authenticated email is required' using errcode='42501';end if;
  v_hash:=app.v76_sha256_hex(coalesce(p_token,''));
  v_request_hash:=app.v76_sha256_hex(jsonb_build_object('token_hash',v_hash)::text);
  v_replay:=app.v76_replay(v_actor,'accept_owner_invite_v79',p_idempotency_key,v_request_hash);
  if v_replay is not null then return v_replay;end if;
  select * into v_invite from public.workspace_owner_invitations
   where token_hash=v_hash for update;
  if not found then raise exception 'workspace owner invitation is invalid' using errcode='22023';end if;
  if v_invite.status='accepted' and v_invite.accepted_by=v_actor then
    return jsonb_build_object('replayed',false,'outcome','already_accepted',
      'business_id',v_invite.business_id,'invitation_id',v_invite.id);
  end if;
  if v_invite.status<>'pending' then raise exception 'workspace owner invitation is no longer active' using errcode='22023';end if;
  if v_invite.expires_at<=now() then
    update public.workspace_owner_invitations set status='expired',revoked_at=now() where id=v_invite.id;
    v_response:=jsonb_build_object('replayed',false,'outcome','expired',
      'business_id',v_invite.business_id,'invitation_id',v_invite.id);
    perform app.v76_store_receipt(v_actor,'accept_owner_invite_v79',p_idempotency_key,
      v_request_hash,v_response);
    return v_response;
  end if;
  if lower(btrim(v_invite.owner_email))<>v_email then
    raise exception 'workspace owner invitation email does not match the authenticated user'
      using errcode='42501';
  end if;
  if exists(
    select 1 from public.staff
    where business_id=v_invite.business_id and user_id=v_actor and role<>'owner'
  ) then
    raise exception 'existing non-owner membership requires an explicit platform role decision'
      using errcode='42501';
  end if;
  insert into public.staff(business_id,user_id,role,full_name,active)
  values(v_invite.business_id,v_actor,'owner',coalesce((select raw_user_meta_data->>'full_name'
    from auth.users where id=v_actor),split_part(v_email,'@',1)),true)
  on conflict(business_id,user_id) do update set role='owner',active=true
  returning id into v_staff;
  select id into v_branch from public.branches
   where business_id=v_invite.business_id and is_default limit 1;
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values(v_invite.business_id,v_staff,v_branch) on conflict do nothing;
  update public.workspace_owner_invitations set status='accepted',accepted_by=v_actor,
    accepted_at=now() where id=v_invite.id;
  select id into v_checklist from public.business_onboarding_checklists
   where business_id=v_invite.business_id;
  insert into public.business_onboarding_events(
    checklist_id,business_id,event_type,to_status,evidence,actor
  ) values(v_checklist,v_invite.business_id,'owner_invite_accepted','satisfied',
    jsonb_build_object('invitation_id',v_invite.id,'staff_id',v_staff),v_actor);
  perform app.refresh_onboarding_core_v79(v_invite.business_id,v_actor);
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(v_invite.business_id,v_actor,'WORKSPACE_OWNER_INVITE_ACCEPTED_V79',
    'workspace_owner_invitations',v_invite.id,jsonb_build_object('staff_id',v_staff));
  v_response:=jsonb_build_object('replayed',false,'outcome','accepted',
    'business_id',v_invite.business_id,'invitation_id',v_invite.id,'staff_id',v_staff);
  perform app.v76_store_receipt(v_actor,'accept_owner_invite_v79',p_idempotency_key,
    v_request_hash,v_response);
  return v_response;
end
$$;

create or replace function public.reissue_workspace_owner_invite_v79(
  p_business uuid,p_owner_email text,p_idempotency_key text
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();v_hash text;v_replay jsonb;v_prospect uuid;v_email text;
  v_invite jsonb;v_response jsonb;
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  perform app.require_idempotency_key_v79(p_idempotency_key);
  v_hash:=app.v76_sha256_hex(jsonb_build_object('business',p_business,'email',lower(btrim(coalesce(p_owner_email,''))))::text);
  v_replay:=app.v76_replay(v_actor,'reissue_owner_invite_v79',p_idempotency_key,v_hash);
  if v_replay is not null then return v_replay;end if;
  select source_prospect_id into v_prospect from public.businesses where id=p_business;
  if v_prospect is null then raise exception 'converted business was not found' using errcode='22023';end if;
  select coalesce(nullif(lower(btrim(p_owner_email)),''),
    (select lower(btrim(owner_email)) from public.sme_commercial_terms
      where prospect_id=v_prospect and contract_status in ('accepted','signed')
      order by version desc limit 1)) into v_email;
  v_invite:=app.issue_workspace_owner_invite_core_v79(p_business,v_prospect,v_email,v_actor);
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,v_actor,'WORKSPACE_OWNER_INVITE_REISSUED_V79','workspace_owner_invitations',
    (v_invite->>'id')::uuid,jsonb_build_object('owner_email',v_email,'version',v_invite->>'version'));
  v_response:=jsonb_build_object('replayed',false,'outcome','reissued',
    'business_id',p_business,'owner_invitation',v_invite);
  perform app.v76_store_receipt(v_actor,'reissue_owner_invite_v79',p_idempotency_key,
    v_hash,v_response#-'{owner_invitation,raw_token}');
  return v_response;
end
$$;

create or replace function app.get_onboarding_core_v79(p_business uuid)
returns jsonb language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select jsonb_build_object(
    'checklist',to_jsonb(checklist),
    'business',(select jsonb_build_object('id',business.id,'name',business.name,
      'legal_name',business.legal_name,'registration_number',business.registration_number,
      'industry',business.industry,'onboarding_started_at',business.onboarding_started_at,
      'activated_at',business.activated_at,'source_prospect_id',business.source_prospect_id)
      from public.businesses business where business.id=p_business),
    'subscription',(select jsonb_build_object('status',subscription.status,
      'plan_code',subscription.plan_code,'product_code',subscription.product_code,
      'billing_cadence',subscription.billing_cadence,'seat_limit',subscription.seat_limit,
      'commercial_terms_id',subscription.commercial_terms_id)
      from public.subscriptions subscription where subscription.business_id=p_business),
    'items',coalesce((select jsonb_agg(to_jsonb(item) order by item.category,item.item_key)
      from public.business_onboarding_items item where item.business_id=p_business),'[]'::jsonb),
    'events',coalesce((select jsonb_agg(to_jsonb(event) order by event.created_at,event.id)
      from public.business_onboarding_events event where event.business_id=p_business),'[]'::jsonb),
    'owner_invitations',coalesce((select jsonb_agg(jsonb_build_object(
      'id',invitation.id,'version',invitation.version,'owner_email',invitation.owner_email,
      'status',invitation.status,'expires_at',invitation.expires_at,
      'token_last_four',invitation.token_last_four,'accepted_at',invitation.accepted_at)
      order by invitation.version desc) from public.workspace_owner_invitations invitation
      where invitation.business_id=p_business),'[]'::jsonb)
  ) from public.business_onboarding_checklists checklist where checklist.business_id=p_business
$$;
revoke all on function app.get_onboarding_core_v79(uuid) from public,anon,authenticated;

create or replace function public.get_business_onboarding_v79(p_business uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if not app.is_platform_operator_v75() and not exists(
    select 1 from public.staff where business_id=p_business and user_id=auth.uid()
      and role='owner' and active
  ) then raise exception 'platform operator or active workspace owner access is required' using errcode='42501';end if;
  if not exists(select 1 from public.business_onboarding_checklists where business_id=p_business) then
    raise exception 'onboarding checklist was not found' using errcode='22023';end if;
  return app.get_onboarding_core_v79(p_business);
end
$$;

create or replace function public.start_business_onboarding_v79(
  p_business uuid,p_expected_version bigint,p_idempotency_key text
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();v_hash text;v_replay jsonb;
  v_check public.business_onboarding_checklists%rowtype;
  v_prospect public.sme_prospects%rowtype;v_response jsonb;
  v_onboarding_started_at timestamptz;
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  perform app.require_idempotency_key_v79(p_idempotency_key);
  v_hash:=app.v76_sha256_hex(jsonb_build_object('business',p_business,'version',p_expected_version)::text);
  v_replay:=app.v76_replay(v_actor,'start_onboarding_v79',p_idempotency_key,v_hash);if v_replay is not null then return v_replay;end if;
  select * into v_check from public.business_onboarding_checklists where business_id=p_business for update;
  if not found or v_check.version<>p_expected_version then raise exception 'onboarding version conflict' using errcode='40001';end if;
  if v_check.status='in_progress' then
    v_response:=jsonb_build_object('replayed',false,'onboarding',app.get_onboarding_core_v79(p_business));
    perform app.v76_store_receipt(v_actor,'start_onboarding_v79',p_idempotency_key,v_hash,v_response);
    return v_response;
  end if;
  if v_check.status<>'not_started' then raise exception 'onboarding cannot start from its current status' using errcode='22023';end if;
  if not exists(
    select 1 from public.business_onboarding_items
    where checklist_id=v_check.id and item_key='owner_access' and status='satisfied'
  ) then raise exception 'workspace owner must accept access before onboarding starts' using errcode='22023';end if;
  update public.business_onboarding_checklists set status='in_progress',
    started_at=coalesce(started_at,now()),version=version+1,updated_at=now() where id=v_check.id;
  select * into v_prospect from public.sme_prospects where id=v_check.prospect_id for update;
  perform set_config('app.v79_system_transition','on',true);
  update public.businesses
    set onboarding_started_at=coalesce(onboarding_started_at,now()),updated_at=now()
    where id=p_business
    returning onboarding_started_at into v_onboarding_started_at;
  if v_prospect.current_stage_key='account_created' then
    update public.sme_prospects set current_stage_key='onboarding',stage_entered_at=now(),
      version=version+1,updated_by=v_actor,updated_at=now() where id=v_prospect.id;
    insert into public.sme_prospect_stage_history(prospect_id,from_stage_key,to_stage_key,reason_code,actor)
    values(v_prospect.id,'account_created','onboarding','onboarding_started',v_actor);
  end if;
  if v_prospect.assigned_consultant_id is not null and exists(
    select 1 from public.platform_consultants consultant
    where consultant.id=v_prospect.assigned_consultant_id
      and consultant.active and consultant.departed_at is null
  ) then
    perform app.attribute_consultant_core_v78(
      v_prospect.assigned_consultant_id,v_prospect.id,p_business,
      v_onboarding_started_at,'v79 active assigned consultant at onboarding start',v_actor
    );
  end if;
  insert into public.business_onboarding_events(checklist_id,business_id,event_type,from_status,to_status,evidence,actor)
  values(v_check.id,p_business,'started',v_check.status,'in_progress','{}',v_actor);
  perform app.refresh_onboarding_core_v79(p_business,v_actor);
  v_response:=jsonb_build_object('replayed',false,'onboarding',app.get_onboarding_core_v79(p_business));
  perform app.v76_store_receipt(v_actor,'start_onboarding_v79',p_idempotency_key,v_hash,v_response);
  return v_response;
end
$$;

create or replace function public.refresh_business_onboarding_v79(
  p_business uuid,p_expected_version bigint,p_idempotency_key text
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_actor uuid:=auth.uid();v_hash text;v_replay jsonb;v_check uuid;v_response jsonb;
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  perform app.require_idempotency_key_v79(p_idempotency_key);
  v_hash:=app.v76_sha256_hex(jsonb_build_object('business',p_business,'version',p_expected_version)::text);
  v_replay:=app.v76_replay(v_actor,'refresh_onboarding_v79',p_idempotency_key,v_hash);if v_replay is not null then return v_replay;end if;
  select id into v_check from public.business_onboarding_checklists
   where business_id=p_business and version=p_expected_version for update;
  if not found then raise exception 'onboarding version conflict' using errcode='40001';end if;
  perform app.refresh_onboarding_core_v79(p_business,v_actor);
  insert into public.business_onboarding_events(checklist_id,business_id,event_type,evidence,actor)
  values(v_check,p_business,'refreshed',jsonb_build_object('derived_rules','v79'),v_actor);
  v_response:=jsonb_build_object('replayed',false,'onboarding',app.get_onboarding_core_v79(p_business));
  perform app.v76_store_receipt(v_actor,'refresh_onboarding_v79',p_idempotency_key,v_hash,v_response);return v_response;
end
$$;

create or replace function public.record_onboarding_manual_evidence_v79(
  p_business uuid,p_item_key text,p_evidence jsonb,p_expected_version bigint,p_idempotency_key text
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_actor uuid:=auth.uid();v_hash text;v_replay jsonb;v_check public.business_onboarding_checklists%rowtype;v_item public.business_onboarding_items%rowtype;v_response jsonb;
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  perform app.require_idempotency_key_v79(p_idempotency_key);
  if jsonb_typeof(p_evidence)<>'object' or p_evidence='{}'::jsonb then raise exception 'manual evidence must be a non-empty object' using errcode='22023';end if;
  v_hash:=app.v76_sha256_hex(jsonb_build_object('business',p_business,'item',p_item_key,'evidence',p_evidence,'version',p_expected_version)::text);
  v_replay:=app.v76_replay(v_actor,'manual_onboarding_evidence_v79',p_idempotency_key,v_hash);if v_replay is not null then return v_replay;end if;
  select * into v_check from public.business_onboarding_checklists where business_id=p_business and version=p_expected_version for update;
  if not found then raise exception 'onboarding version conflict' using errcode='40001';end if;
  select * into v_item from public.business_onboarding_items where business_id=p_business and item_key=p_item_key for update;
  if not found or v_item.verification_mode not in ('manual','sa_approval') then raise exception 'manual onboarding item was not found' using errcode='22023';end if;
  if v_item.verification_mode='sa_approval' and not app.is_super_admin() then
    raise exception 'go-live approval requires a super admin' using errcode='42501';end if;
  if v_item.status='blocked' then raise exception 'blocked onboarding evidence cannot be satisfied' using errcode='22023';end if;
  update public.business_onboarding_items set status='satisfied',evidence=p_evidence,
    satisfied_by=v_actor,satisfied_at=now(),waived_by=null,waived_at=null,waiver_reason=null,
    updated_at=now() where id=v_item.id;
  insert into public.business_onboarding_events(checklist_id,business_id,item_id,event_type,from_status,to_status,evidence,actor)
  values(v_check.id,p_business,v_item.id,'evidence_recorded',v_item.status,'satisfied',p_evidence,v_actor);
  perform app.recompute_onboarding_status_v79(p_business,v_actor);
  v_response:=jsonb_build_object('replayed',false,'onboarding',app.get_onboarding_core_v79(p_business));
  perform app.v76_store_receipt(v_actor,'manual_onboarding_evidence_v79',p_idempotency_key,v_hash,v_response);return v_response;
end
$$;

create or replace function public.waive_onboarding_item_v79(
  p_business uuid,p_item_key text,p_reason text,p_expected_version bigint,p_idempotency_key text
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_actor uuid:=auth.uid();v_hash text;v_replay jsonb;v_check public.business_onboarding_checklists%rowtype;v_item public.business_onboarding_items%rowtype;v_response jsonb;
begin
  if not app.is_super_admin() then raise exception 'super admin access is required' using errcode='42501';end if;
  perform app.require_idempotency_key_v79(p_idempotency_key);
  if length(btrim(coalesce(p_reason,'')))<3 then raise exception 'waiver reason is required' using errcode='22023';end if;
  v_hash:=app.v76_sha256_hex(jsonb_build_object('business',p_business,'item',p_item_key,'reason',p_reason,'version',p_expected_version)::text);
  v_replay:=app.v76_replay(v_actor,'waive_onboarding_item_v79',p_idempotency_key,v_hash);if v_replay is not null then return v_replay;end if;
  select * into v_check from public.business_onboarding_checklists where business_id=p_business and version=p_expected_version for update;
  if not found then raise exception 'onboarding version conflict' using errcode='40001';end if;
  select * into v_item from public.business_onboarding_items where business_id=p_business and item_key=p_item_key for update;
  if not found or not v_item.waivable or v_item.item_key='go_live_approved' then
    raise exception 'this onboarding item is nonwaivable' using errcode='22023';end if;
  update public.business_onboarding_items set status='waived',waived_by=v_actor,waived_at=now(),
    waiver_reason=btrim(p_reason),satisfied_by=null,satisfied_at=null,updated_at=now() where id=v_item.id;
  insert into public.business_onboarding_events(checklist_id,business_id,item_id,event_type,from_status,to_status,evidence,actor)
  values(v_check.id,p_business,v_item.id,'item_waived',v_item.status,'waived',jsonb_build_object('reason',btrim(p_reason)),v_actor);
  perform app.recompute_onboarding_status_v79(p_business,v_actor);
  v_response:=jsonb_build_object('replayed',false,'onboarding',app.get_onboarding_core_v79(p_business));
  perform app.v76_store_receipt(v_actor,'waive_onboarding_item_v79',p_idempotency_key,v_hash,v_response);return v_response;
end
$$;

create or replace function public.block_business_onboarding_v79(
  p_business uuid,
  p_item_key text,
  p_reason text,
  p_expected_version bigint,
  p_idempotency_key text
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_checklist public.business_onboarding_checklists%rowtype;
  v_item public.business_onboarding_items%rowtype;
  v_request jsonb;
  v_replay jsonb;
  v_response jsonb;
begin
  if not app.is_super_admin() then
    raise exception 'super_admin_required';
  end if;
  perform app.require_idempotency_key_v79(p_idempotency_key);
  if length(btrim(coalesce(p_reason,'')))<3 then
    raise exception 'block_reason_required';
  end if;
  if nullif(btrim(p_idempotency_key), '') is null then
    raise exception 'idempotency_key_required';
  end if;

  v_request := jsonb_build_object(
    'business_id', p_business,
    'item_key', p_item_key,
    'reason', btrim(p_reason),
    'expected_version', p_expected_version
  );
  v_replay := app.v76_replay(
    v_actor, 'block_business_onboarding_v79', p_idempotency_key,
    app.v76_sha256_hex(v_request::text)
  );
  if v_replay is not null then return v_replay; end if;

  select * into v_checklist
  from public.business_onboarding_checklists
  where business_id = p_business
  for update;
  if not found then raise exception 'onboarding_checklist_not_found'; end if;
  if v_checklist.version <> p_expected_version then raise exception 'version_conflict'; end if;
  if v_checklist.status = 'activated' then raise exception 'business_already_activated'; end if;

  if nullif(btrim(p_item_key), '') is null then
    update public.business_onboarding_checklists
    set status = 'blocked',
        blocked_reason = btrim(p_reason),
        blocked_by = v_actor,
        blocked_at = now(),
        version = version + 1,
        updated_at = now()
    where id = v_checklist.id;
  else
    select * into v_item
    from public.business_onboarding_items
    where checklist_id = v_checklist.id
      and item_key = btrim(p_item_key)
    for update;
    if not found then raise exception 'onboarding_item_not_found'; end if;

    update public.business_onboarding_items
    set status_before_block = case when status = 'blocked' then status_before_block else status end,
        status = 'blocked',
        block_reason = btrim(p_reason),
        blocked_by = v_actor,
        blocked_at = now(),
        updated_at = now()
    where id = v_item.id;
    perform app.recompute_onboarding_status_v79(p_business, v_actor);
  end if;

  insert into public.business_onboarding_events(
    checklist_id, business_id, item_id, event_type, actor, evidence
  ) values (
    v_checklist.id, p_business, v_item.id, 'blocked', v_actor,
    jsonb_build_object('item_key', nullif(btrim(p_item_key), ''), 'reason', btrim(p_reason))
  );

  v_response := jsonb_build_object(
    'replayed',false,'onboarding',app.get_onboarding_core_v79(p_business)
  );
  perform app.v76_store_receipt(
    v_actor, 'block_business_onboarding_v79', p_idempotency_key,
    app.v76_sha256_hex(v_request::text), v_response
  );
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,v_actor,'BUSINESS_ONBOARDING_BLOCKED_V79','businesses',p_business,
    jsonb_build_object('item_key',nullif(btrim(p_item_key),''),'reason',btrim(p_reason)));
  return v_response;
end
$$;

create or replace function public.unblock_business_onboarding_v79(
  p_business uuid,
  p_item_key text,
  p_expected_version bigint,
  p_idempotency_key text
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_checklist public.business_onboarding_checklists%rowtype;
  v_item public.business_onboarding_items%rowtype;
  v_request jsonb;
  v_replay jsonb;
  v_response jsonb;
begin
  if not app.is_super_admin() then
    raise exception 'super_admin_required';
  end if;
  perform app.require_idempotency_key_v79(p_idempotency_key);
  if nullif(btrim(p_idempotency_key), '') is null then
    raise exception 'idempotency_key_required';
  end if;

  v_request := jsonb_build_object(
    'business_id', p_business,
    'item_key', p_item_key,
    'expected_version', p_expected_version
  );
  v_replay := app.v76_replay(
    v_actor, 'unblock_business_onboarding_v79', p_idempotency_key,
    app.v76_sha256_hex(v_request::text)
  );
  if v_replay is not null then return v_replay; end if;

  select * into v_checklist
  from public.business_onboarding_checklists
  where business_id = p_business
  for update;
  if not found then raise exception 'onboarding_checklist_not_found'; end if;
  if v_checklist.version <> p_expected_version then raise exception 'version_conflict'; end if;
  if v_checklist.status = 'activated' then raise exception 'business_already_activated'; end if;

  if nullif(btrim(p_item_key), '') is null then
    if v_checklist.blocked_at is null then raise exception 'onboarding_not_globally_blocked'; end if;
    update public.business_onboarding_checklists
    set blocked_reason = null,
        blocked_by = null,
        blocked_at = null,
        updated_at = now()
    where id = v_checklist.id;
  else
    select * into v_item
    from public.business_onboarding_items
    where checklist_id = v_checklist.id
      and item_key = btrim(p_item_key)
    for update;
    if not found then raise exception 'onboarding_item_not_found'; end if;
    if v_item.status <> 'blocked' then raise exception 'onboarding_item_not_blocked'; end if;

    update public.business_onboarding_items
    set status = coalesce(status_before_block, 'pending'),
        status_before_block = null,
        block_reason = null,
        blocked_by = null,
        blocked_at = null,
        updated_at = now()
    where id = v_item.id;
  end if;

  perform app.recompute_onboarding_status_v79(p_business, v_actor);
  insert into public.business_onboarding_events(
    checklist_id, business_id, item_id, event_type, actor, evidence
  ) values (
    v_checklist.id, p_business, v_item.id, 'unblocked', v_actor,
    jsonb_build_object('item_key', nullif(btrim(p_item_key), ''))
  );

  v_response := jsonb_build_object(
    'replayed',false,'onboarding',app.get_onboarding_core_v79(p_business)
  );
  perform app.v76_store_receipt(
    v_actor, 'unblock_business_onboarding_v79', p_idempotency_key,
    app.v76_sha256_hex(v_request::text), v_response
  );
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,v_actor,'BUSINESS_ONBOARDING_UNBLOCKED_V79','businesses',p_business,
    jsonb_build_object('item_key',nullif(btrim(p_item_key),'')));
  return v_response;
end
$$;

create or replace function public.activate_business_v79(
  p_business uuid,
  p_expected_version bigint,
  p_idempotency_key text
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_checklist public.business_onboarding_checklists%rowtype;
  v_prospect public.sme_prospects%rowtype;
  v_request jsonb;
  v_replay jsonb;
  v_response jsonb;
  v_now timestamptz := now();
begin
  if not app.is_super_admin() then
    raise exception 'super_admin_required';
  end if;
  perform app.require_idempotency_key_v79(p_idempotency_key);
  if nullif(btrim(p_idempotency_key), '') is null then
    raise exception 'idempotency_key_required';
  end if;

  v_request := jsonb_build_object(
    'business_id', p_business,
    'expected_version', p_expected_version
  );
  v_replay := app.v76_replay(
    v_actor, 'activate_business_v79', p_idempotency_key,
    app.v76_sha256_hex(v_request::text)
  );
  if v_replay is not null then return v_replay; end if;

  select * into v_checklist
  from public.business_onboarding_checklists
  where business_id = p_business
  for update;
  if not found then raise exception 'onboarding_checklist_not_found'; end if;
  if v_checklist.version <> p_expected_version then raise exception 'version_conflict'; end if;
  if v_checklist.status = 'activated' then raise exception 'business_already_activated'; end if;
  if v_checklist.blocked_at is not null
     or exists (
       select 1 from public.business_onboarding_items
       where checklist_id = v_checklist.id and status = 'blocked'
     ) then
    raise exception 'onboarding_blocked';
  end if;

  perform app.refresh_onboarding_core_v79(p_business, v_actor);
  select * into v_checklist
  from public.business_onboarding_checklists
  where business_id = p_business
  for update;

  if v_checklist.status <> 'ready'
     or exists (
       select 1 from public.business_onboarding_items
       where checklist_id = v_checklist.id
         and mandatory
         and status not in ('satisfied', 'waived')
     ) then
    raise exception 'mandatory_onboarding_items_incomplete';
  end if;
  if not exists (
    select 1 from public.business_onboarding_items
    where checklist_id = v_checklist.id
      and item_key = 'go_live_approved'
      and status = 'satisfied'
      and verification_mode = 'sa_approval'
      and not waivable
  ) then
    raise exception 'go_live_approval_required';
  end if;

  select * into v_prospect
  from public.sme_prospects
  where id = v_checklist.prospect_id
  for update;
  if not found or v_prospect.converted_business_id is distinct from p_business then
    raise exception 'prospect_business_link_invalid';
  end if;
  if v_prospect.current_stage_key <> 'onboarding' then
    raise exception 'prospect_must_be_in_onboarding';
  end if;

  perform set_config('app.v79_system_transition','on',true);
  update public.businesses
  set activated_at = coalesce(activated_at, v_now),
      updated_at = v_now
  where id = p_business;

  update public.branches
  set active = true,
      updated_at = v_now
  where business_id = p_business
    and is_default;

  update public.business_onboarding_checklists
  set status = 'activated',
      activated_at = v_now,
      version = version + 1,
      updated_at = v_now
  where id = v_checklist.id;

  update public.sme_prospects
  set current_stage_key = 'activated',
      version = version + 1,
      stage_entered_at = v_now,
      updated_by = v_actor,
      updated_at = v_now
  where id = v_prospect.id;

  insert into public.sme_prospect_stage_history(
    prospect_id, from_stage_key, to_stage_key, reason_code, reason_detail, actor
  ) values (
    v_prospect.id, 'onboarding', 'activated', 'activation_completed',
    'v79 activation gate satisfied', v_actor
  );
  insert into public.sme_prospect_activities(
    prospect_id, consultant_id, activity_type, summary, detail, created_by
  ) values (
    v_prospect.id, v_prospect.assigned_consultant_id, 'system',
    'Business activated', 'v79 onboarding gates satisfied', v_actor
  );
  insert into public.business_onboarding_events(
    checklist_id, business_id, event_type, actor, evidence
  ) values (
    v_checklist.id, p_business, 'activated', v_actor,
    jsonb_build_object('activated_at', v_now)
  );

  v_response := jsonb_build_object(
    'replayed',false,
    'onboarding',app.get_onboarding_core_v79(p_business),
    'activated_at',v_now
  );
  perform app.v76_store_receipt(
    v_actor, 'activate_business_v79', p_idempotency_key,
    app.v76_sha256_hex(v_request::text), v_response
  );
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,v_actor,'BUSINESS_ACTIVATED_V79','businesses',p_business,
    jsonb_build_object('prospect_id',v_prospect.id,'checklist_id',v_checklist.id));
  return v_response;
end
$$;

revoke all on function public.convert_sme_prospect_v79(uuid, bigint, text) from public, anon, authenticated;
revoke all on function public.accept_workspace_owner_invite_v79(text, text) from public, anon, authenticated;
revoke all on function public.reissue_workspace_owner_invite_v79(uuid, text, text) from public, anon, authenticated;
revoke all on function public.get_business_onboarding_v79(uuid) from public, anon, authenticated;
revoke all on function public.start_business_onboarding_v79(uuid, bigint, text) from public, anon, authenticated;
revoke all on function public.refresh_business_onboarding_v79(uuid, bigint, text) from public, anon, authenticated;
revoke all on function public.record_onboarding_manual_evidence_v79(uuid, text, jsonb, bigint, text) from public, anon, authenticated;
revoke all on function public.waive_onboarding_item_v79(uuid, text, text, bigint, text) from public, anon, authenticated;
revoke all on function public.block_business_onboarding_v79(uuid, text, text, bigint, text) from public, anon, authenticated;
revoke all on function public.unblock_business_onboarding_v79(uuid, text, bigint, text) from public, anon, authenticated;
revoke all on function public.activate_business_v79(uuid, bigint, text) from public, anon, authenticated;

grant execute on function public.convert_sme_prospect_v79(uuid, bigint, text) to authenticated;
grant execute on function public.accept_workspace_owner_invite_v79(text, text) to authenticated;
grant execute on function public.reissue_workspace_owner_invite_v79(uuid, text, text) to authenticated;
grant execute on function public.get_business_onboarding_v79(uuid) to authenticated;
grant execute on function public.start_business_onboarding_v79(uuid, bigint, text) to authenticated;
grant execute on function public.refresh_business_onboarding_v79(uuid, bigint, text) to authenticated;
grant execute on function public.record_onboarding_manual_evidence_v79(uuid, text, jsonb, bigint, text) to authenticated;
grant execute on function public.waive_onboarding_item_v79(uuid, text, text, bigint, text) to authenticated;
grant execute on function public.block_business_onboarding_v79(uuid, text, text, bigint, text) to authenticated;
grant execute on function public.unblock_business_onboarding_v79(uuid, text, bigint, text) to authenticated;
grant execute on function public.activate_business_v79(uuid, bigint, text) to authenticated;

comment on function public.convert_sme_prospect_v79(uuid, bigint, text) is
  'Transactional v79 client conversion. Raw invitation token is returned once and omitted from idempotency receipts.';
comment on function public.activate_business_v79(uuid, bigint, text) is
  'Super-admin-only activation after refreshed derived evidence and every mandatory onboarding gate is fulfilled.';

commit;
