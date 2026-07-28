-- NESTLY v95 — approval-first business activation, bilingual customer copy,
-- and owner-controlled customer-visible programme media.
--
-- Forward-only review candidate. No production action is authorized by this file.

begin;

-- ---------------------------------------------------------------------------
-- 1. Approval-first, pre-auth business applications.
-- ---------------------------------------------------------------------------

create table public.business_applications_v95(
  id uuid primary key default gen_random_uuid(),
  public_reference uuid not null default gen_random_uuid() unique,
  idempotency_key uuid not null unique,
  request_hash text not null check(request_hash~'^[0-9a-f]{64}$'),
  contact_name text not null check(length(btrim(contact_name)) between 2 and 120),
  contact_email text not null check(
    contact_email=lower(btrim(contact_email))
    and contact_email~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  ),
  contact_phone text not null check(contact_phone~'^\+[1-9][0-9]{7,14}$'),
  business_name text not null check(length(btrim(business_name)) between 2 and 160),
  sector_key text not null check(sector_key~'^[a-z][a-z0-9_]*$'),
  registration_number text check(
    registration_number is null
    or length(btrim(registration_number)) between 3 and 40
  ),
  preferred_locale text not null default 'en' check(preferred_locale in ('en','zh-CN')),
  status text not null default 'submitted'
    check(status in ('submitted','approved','rejected','expired','consumed')),
  version bigint not null default 1 check(version>0),
  decided_by uuid references auth.users(id) on delete set null,
  decided_at timestamptz,
  decision_reason text,
  consumed_business_id uuid references public.businesses(id) on delete restrict,
  consumed_by uuid references auth.users(id) on delete set null,
  consumed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint business_applications_v95_decision_shape check(
    (status='submitted' and decided_by is null and decided_at is null
      and decision_reason is null and consumed_at is null)
    or
    (status in ('approved','rejected','expired') and decided_at is not null
      and length(btrim(decision_reason)) between 3 and 1000
      and consumed_at is null)
    or
    (status='consumed' and decided_at is not null
      and length(btrim(decision_reason)) between 3 and 1000
      and consumed_business_id is not null and consumed_by is not null
      and consumed_at is not null)
  )
);
create unique index business_applications_v95_open_email_uk
  on public.business_applications_v95(contact_email)
  where status in ('submitted','approved');
create index business_applications_v95_status_created_idx
  on public.business_applications_v95(status,created_at,id);

create table public.business_application_invitations_v95(
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.business_applications_v95(id)
    on delete restrict,
  token_hash text not null unique check(token_hash~'^[0-9a-f]{64}$'),
  expires_at timestamptz not null,
  issued_by uuid not null references auth.users(id) on delete restrict,
  issued_at timestamptz not null default now(),
  revoked_at timestamptz,
  consumed_at timestamptz,
  consumed_by uuid references auth.users(id) on delete set null,
  business_id uuid references public.businesses(id) on delete restrict,
  idempotency_key uuid,
  response jsonb,
  constraint business_application_invitations_v95_expiry_check
    check(expires_at>issued_at),
  constraint business_application_invitations_v95_consumption_shape check(
    (consumed_at is null and consumed_by is null and business_id is null
      and idempotency_key is null and response is null)
    or
    (consumed_at is not null and consumed_by is not null
      and business_id is not null and idempotency_key is not null
      and jsonb_typeof(response)='object')
  )
);
create unique index business_application_invitations_v95_active_uk
  on public.business_application_invitations_v95(application_id)
  where revoked_at is null and consumed_at is null;

create table public.business_application_audit_v95(
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.business_applications_v95(id)
    on delete restrict,
  event_type text not null check(event_type in (
    'submitted','approved','rejected','invitation_expired',
    'activation_refused','invitation_consumed'
  )),
  actor uuid references auth.users(id) on delete set null,
  prior_status text,
  new_status text not null,
  reason text not null check(length(btrim(reason)) between 3 and 1000),
  detail jsonb not null default '{}'::jsonb check(jsonb_typeof(detail)='object'),
  created_at timestamptz not null default now()
);
create index business_application_audit_v95_timeline_idx
  on public.business_application_audit_v95(application_id,created_at,id);

alter table public.business_applications_v95 enable row level security;
alter table public.business_application_invitations_v95 enable row level security;
alter table public.business_application_audit_v95 enable row level security;
revoke all privileges on table public.business_applications_v95
  from public,anon,authenticated;
revoke all privileges on table public.business_application_invitations_v95
  from public,anon,authenticated;
revoke all privileges on table public.business_application_audit_v95
  from public,anon,authenticated;
create trigger trg_business_application_audit_v95_append_only
before update or delete on public.business_application_audit_v95
for each row execute function app.forbid_mutation();

create or replace function app.v95_sha256(p_value text)
returns text language sql immutable strict
set search_path to 'pg_catalog','extensions','pg_temp'
as $$
  select encode(extensions.digest(convert_to(p_value,'UTF8'),'sha256'),'hex')
$$;
revoke all on function app.v95_sha256(text)
  from public,anon,authenticated;

create or replace function public.internal_submit_business_application_v95(
  p_contact_name text,p_contact_email text,p_contact_phone text,
  p_business_name text,p_sector_key text,p_registration_number text,
  p_locale text,p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_email text:=lower(btrim(coalesce(p_contact_email,'')));
  v_hash text;
  v_application public.business_applications_v95%rowtype;
begin
  if p_idempotency_key is null
     or length(btrim(coalesce(p_contact_name,''))) not between 2 and 120
     or v_email!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
     or coalesce(p_contact_phone,'')!~'^\+[1-9][0-9]{7,14}$'
     or length(btrim(coalesce(p_business_name,''))) not between 2 and 160
     or coalesce(p_locale,'') not in ('en','zh-CN')
  then raise exception 'valid business application fields are required'
    using errcode='22023';end if;
  if not exists(
    select 1 from public.sector_bundle_versions bundle
    where bundle.sector_key=p_sector_key and bundle.status='published'
  ) then raise exception 'published_sector_required' using errcode='22023';end if;
  v_hash:=app.v95_sha256(concat_ws('|',
    btrim(p_contact_name),v_email,p_contact_phone,btrim(p_business_name),
    p_sector_key,btrim(coalesce(p_registration_number,'')),p_locale
  ));
  select * into v_application from public.business_applications_v95
  where idempotency_key=p_idempotency_key;
  if found then
    if v_application.request_hash<>v_hash then
      raise exception 'application_idempotency_conflict' using errcode='22023';
    end if;
    return jsonb_build_object(
      'application_id',v_application.id,
      'public_reference',v_application.public_reference,
      'status',v_application.status,'version',v_application.version,
      'replayed',true
    );
  end if;
  if exists(
    select 1 from public.business_applications_v95 application
    where application.contact_email=v_email
      and application.status in ('submitted','approved')
  ) then
    raise exception 'open_application_already_exists' using errcode='23505';
  end if;
  insert into public.business_applications_v95(
    idempotency_key,request_hash,contact_name,contact_email,contact_phone,
    business_name,sector_key,registration_number,preferred_locale
  ) values(
    p_idempotency_key,v_hash,btrim(p_contact_name),v_email,p_contact_phone,
    btrim(p_business_name),p_sector_key,
    nullif(btrim(coalesce(p_registration_number,'')),''),
    p_locale
  ) returning * into v_application;
  insert into public.business_application_audit_v95(
    application_id,event_type,new_status,reason,detail
  ) values(
    v_application.id,'submitted','submitted',
    'public pre-auth business application submitted',
    jsonb_build_object('sector_key',p_sector_key,'preferred_locale',p_locale)
  );
  return jsonb_build_object(
    'application_id',v_application.id,
    'public_reference',v_application.public_reference,
    'status','submitted','version',1,'replayed',false
  );
end
$$;

create or replace function public.platform_decide_business_application_v95(
  p_application uuid,p_decision text,p_reason text,p_expected_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_application public.business_applications_v95%rowtype;
  v_raw_token text;
  v_invitation public.business_application_invitations_v95%rowtype;
begin
  if not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode='42501';
  end if;
  if p_decision not in ('approved','rejected')
     or length(btrim(coalesce(p_reason,''))) not between 3 and 1000
     or p_expected_version is null
  then raise exception 'valid decision reason and version are required'
    using errcode='22023';end if;
  select * into v_application from public.business_applications_v95
  where id=p_application for update;
  if not found then raise exception 'application_not_found' using errcode='22023';end if;
  if v_application.status<>'submitted' then
    raise exception 'application_is_not_pending' using errcode='23514';
  end if;
  if v_application.version<>p_expected_version then
    raise exception 'application_version_conflict' using errcode='40001';
  end if;
  update public.business_applications_v95
  set status=p_decision,version=version+1,decided_by=auth.uid(),
    decided_at=now(),decision_reason=btrim(p_reason),updated_at=now()
  where id=p_application returning * into v_application;
  insert into public.business_application_audit_v95(
    application_id,event_type,actor,prior_status,new_status,reason
  ) values(
    p_application,p_decision,auth.uid(),'submitted',p_decision,btrim(p_reason)
  );
  if p_decision='approved' then
    v_raw_token:=encode(extensions.gen_random_bytes(32),'hex');
    insert into public.business_application_invitations_v95(
      application_id,token_hash,expires_at,issued_by
    ) values(
      p_application,app.v95_sha256(v_raw_token),now()+interval '72 hours',
      auth.uid()
    ) returning * into v_invitation;
  end if;
  return jsonb_build_object(
    'application_id',p_application,'status',p_decision,
    'version',v_application.version,
    'approved_email',case when p_decision='approved'
      then v_application.contact_email else null end,
    'invitation_token',v_raw_token,
    'invitation_expires_at',v_invitation.expires_at
  );
end
$$;

create or replace function public.get_business_application_status_v95(
  p_public_reference uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_application public.business_applications_v95%rowtype;
begin
  select * into v_application from public.business_applications_v95
  where public_reference=p_public_reference;
  if not found then
    return jsonb_build_object('found',false);
  end if;
  return jsonb_build_object(
    'found',true,'public_reference',v_application.public_reference,
    'status',v_application.status,'version',v_application.version,
    'submitted_at',v_application.created_at,
    'decided_at',v_application.decided_at
  );
end
$$;

create or replace function public.platform_get_business_application_v95(
  p_application uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_result jsonb;
begin
  if not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode='42501';
  end if;
  select jsonb_build_object(
    'application',jsonb_build_object(
      'id',application.id,'public_reference',application.public_reference,
      'contact_name',application.contact_name,
      'contact_email',application.contact_email,
      'contact_phone',application.contact_phone,
      'business_name',application.business_name,
      'sector_key',application.sector_key,
      'registration_number',application.registration_number,
      'preferred_locale',application.preferred_locale,
      'status',application.status,'version',application.version,
      'decision_reason',application.decision_reason,
      'submitted_at',application.created_at,
      'decided_at',application.decided_at,
      'consumed_business_id',application.consumed_business_id,
      'consumed_at',application.consumed_at
    ),
    'invitation',case when invitation.id is null then null
      else jsonb_build_object(
        'id',invitation.id,'issued_at',invitation.issued_at,
        'expires_at',invitation.expires_at,
        'revoked_at',invitation.revoked_at,
        'consumed_at',invitation.consumed_at,
        'business_id',invitation.business_id
      ) end,
    'audit',coalesce((
      select jsonb_agg(jsonb_build_object(
        'event_type',audit.event_type,'prior_status',audit.prior_status,
        'new_status',audit.new_status,'reason',audit.reason,
        'created_at',audit.created_at
      ) order by audit.created_at,audit.id)
      from public.business_application_audit_v95 audit
      where audit.application_id=application.id
    ),'[]'::jsonb)
  ) into v_result
  from public.business_applications_v95 application
  left join lateral(
    select invitation_row.*
    from public.business_application_invitations_v95 invitation_row
    where invitation_row.application_id=application.id
    order by invitation_row.issued_at desc,invitation_row.id desc
    limit 1
  ) invitation on true
  where application.id=p_application;
  if v_result is null then raise exception 'application_not_found'
    using errcode='22023';end if;
  return v_result;
end
$$;

create or replace function public.platform_list_business_applications_v95(
  p_status text default null,p_search text default null,
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_rows jsonb;v_search text:=lower(btrim(coalesce(p_search,'')));
begin
  if not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode='42501';
  end if;
  if p_status is not null and p_status not in (
      'submitted','approved','rejected','expired','consumed'
    ) or p_limit not between 1 and 250
  then raise exception 'valid application queue filters are required'
    using errcode='22023';end if;
  with matched as (
    select application.*,invitation.expires_at invitation_expires_at,
      invitation.consumed_at invitation_consumed_at
    from public.business_applications_v95 application
    left join lateral(
      select invitation_row.expires_at,invitation_row.consumed_at
      from public.business_application_invitations_v95 invitation_row
      where invitation_row.application_id=application.id
      order by invitation_row.issued_at desc,invitation_row.id desc limit 1
    ) invitation on true
    where (p_status is null or application.status=p_status)
      and (v_search='' or lower(concat_ws(' ',
        application.business_name,application.contact_name,
        application.contact_email,application.contact_phone,
        application.registration_number,application.sector_key
      )) like '%'||v_search||'%')
    order by application.created_at desc,application.id desc
    limit p_limit+1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'public_reference',public_reference,
    'business_name',business_name,'sector_key',sector_key,
    'registration_number',registration_number,
    'contact_name',contact_name,'contact_email',contact_email,
    'contact_phone',contact_phone,'preferred_locale',preferred_locale,
    'status',status,'version',version,'submitted_at',created_at,
    'decided_at',decided_at,'decision_reason',decision_reason,
    'invitation_expires_at',invitation_expires_at,
    'invitation_consumed_at',invitation_consumed_at,
    'consumed_business_id',consumed_business_id
  ) order by created_at desc,id desc) filter(
    where ordinal<=p_limit
  ),'[]'::jsonb)
  into v_rows
  from (
    select matched.*,row_number() over(order by created_at desc,id desc) ordinal
    from matched
  ) ordered;
  return jsonb_build_object(
    'applications',v_rows,
    'truncated',(
      select count(*)>p_limit from (
        select 1 from public.business_applications_v95 application
        where (p_status is null or application.status=p_status)
          and (v_search='' or lower(concat_ws(' ',
            application.business_name,application.contact_name,
            application.contact_email,application.contact_phone,
            application.registration_number,application.sector_key
          )) like '%'||v_search||'%')
        limit p_limit+1
      ) count_rows
    )
  );
end
$$;

create or replace function public.internal_get_approved_business_invitation_v95(
  p_invitation_token text
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_invitation public.business_application_invitations_v95%rowtype;
  v_application public.business_applications_v95%rowtype;
begin
  if coalesce(p_invitation_token,'')!~'^[0-9a-f]{64}$' then
    return jsonb_build_object('valid',false,'status','invalid');
  end if;
  select * into v_invitation
  from public.business_application_invitations_v95
  where token_hash=app.v95_sha256(p_invitation_token);
  if not found then
    return jsonb_build_object('valid',false,'status','invalid');
  end if;
  select * into v_application from public.business_applications_v95
  where id=v_invitation.application_id;
  if v_invitation.consumed_at is not null then
    return jsonb_build_object('valid',false,'status','consumed');
  elsif v_invitation.revoked_at is not null
        or v_application.status<>'approved' then
    return jsonb_build_object('valid',false,'status','inactive');
  elsif v_invitation.expires_at<=now() then
    return jsonb_build_object(
      'valid',false,'status','expired','expires_at',v_invitation.expires_at
    );
  end if;
  return jsonb_build_object(
    'valid',true,'status','approved',
    'application_id',v_application.id,
    'business_name',v_application.business_name,
    'approved_email',v_application.contact_email,
    'preferred_locale',v_application.preferred_locale,
    'expires_at',v_invitation.expires_at
  );
end
$$;

-- The legacy self-service workspace creator is deliberately retired. Customer
-- Auth accounts remain valid, but no authenticated browser can promote itself
-- into an owner or create a workspace without consuming an approved invite.
create or replace function public.create_business(
  p_name text,p_slug text,p_industry text,p_modules text[]
)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  raise exception 'approved_business_invitation_required' using errcode='42501';
end
$$;

alter table public.business_workspace_control_audit_v94
  drop constraint business_workspace_control_audit_v94_event_type_check;
alter table public.business_workspace_control_audit_v94
  add constraint business_workspace_control_audit_v94_event_type_check
  check(event_type in (
    'existing_firm_approved','firm_created_pending','firm_approved',
    'firm_rejected','application_activated'
  ));

create or replace function public.activate_approved_business_application_v95(
  p_invitation_token text,p_business_slug text,p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_email text;
  v_invitation public.business_application_invitations_v95%rowtype;
  v_application public.business_applications_v95%rowtype;
  v_bundle public.sector_bundle_versions%rowtype;
  v_business public.businesses%rowtype;
  v_staff uuid;v_branch uuid;v_response jsonb;
begin
  if v_actor is null or p_idempotency_key is null
     or coalesce(p_invitation_token,'')!~'^[0-9a-f]{64}$'
     or coalesce(p_business_slug,'')!~'^[a-z0-9]+(?:-[a-z0-9]+)*$'
     or length(p_business_slug) not between 3 and 80
  then raise exception 'valid authenticated activation is required'
    using errcode='22023';end if;
  select lower(email) into v_email from auth.users
  where id=v_actor and coalesce(email_confirmed_at,confirmed_at) is not null;
  if v_email is null then
    raise exception 'confirmed_invited_email_required' using errcode='42501';
  end if;
  select * into v_invitation
  from public.business_application_invitations_v95 invitation
  where invitation.token_hash=app.v95_sha256(p_invitation_token)
  for update;
  if not found then raise exception 'approved_invitation_not_found'
    using errcode='42501';end if;
  if v_invitation.consumed_at is not null then
    if v_invitation.consumed_by=v_actor
       and v_invitation.idempotency_key=p_idempotency_key then
      return v_invitation.response||jsonb_build_object('replayed',true);
    end if;
    raise exception 'approved_invitation_already_consumed' using errcode='42501';
  end if;
  select * into v_application from public.business_applications_v95
  where id=v_invitation.application_id for update;
  if v_invitation.revoked_at is not null or v_application.status<>'approved' then
    raise exception 'approved_invitation_inactive' using errcode='42501';
  end if;
  if v_invitation.expires_at<=now() then
    update public.business_applications_v95
    set status='expired',version=version+1,updated_at=now(),
      decision_reason=decision_reason||'; approved invitation expired'
    where id=v_application.id;
    insert into public.business_application_audit_v95(
      application_id,event_type,actor,prior_status,new_status,reason
    ) values(
      v_application.id,'invitation_expired',v_actor,'approved','expired',
      'approved owner invitation expired before consumption'
    );
    return jsonb_build_object(
      'application_id',v_application.id,'status','expired',
      'workspace_created',false,'replayed',false
    );
  end if;
  if v_email<>v_application.contact_email then
    insert into public.business_application_audit_v95(
      application_id,event_type,actor,prior_status,new_status,reason,detail
    ) values(
      v_application.id,'activation_refused',v_actor,'approved','approved',
      'authenticated email did not match approved application',
      jsonb_build_object('email_match',false)
    );
    return jsonb_build_object(
      'application_id',v_application.id,'status','refused',
      'reason','approved_invitation_email_mismatch',
      'workspace_created',false,'replayed',false
    );
  end if;
  select * into v_bundle from public.sector_bundle_versions
  where sector_key=v_application.sector_key and status='published';
  if not found then raise exception 'published_sector_required'
    using errcode='23514';end if;
  insert into public.businesses(name,slug,industry,enabled_modules)
  values(
    v_application.business_name,p_business_slug,
    v_application.sector_key,v_bundle.modules
  ) returning * into v_business;
  insert into public.staff(business_id,user_id,role,full_name,active)
  values(v_business.id,v_actor,'owner',v_application.contact_name,true)
  returning id into v_staff;
  insert into public.branches(business_id,name,is_default,active)
  values(v_business.id,v_application.business_name,true,true)
  returning id into v_branch;
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values(v_business.id,v_staff,v_branch);
  -- v94 seeds every direct business insert as pending. This workspace was
  -- already approved at the application boundary, so open it before owner-
  -- guarded configuration triggers (loyalty/config versioning) execute.
  update public.business_workspace_controls_v94
  set approval_status='approved',version=version+1,
    decided_by=v_application.decided_by,
    decided_at=v_application.decided_at,
    decision_reason='approved business application '||v_application.id,
    updated_at=now()
  where business_id=v_business.id;
  insert into public.business_workspace_control_audit_v94(
    business_id,actor,event_type,prior_status,new_status,reason,control_version
  ) values(
    v_business.id,v_application.decided_by,'application_activated',
    'pending','approved','approved pre-auth application consumed',2
  );
  insert into public.loyalty_programs(
    business_id,kind,earn_points_per_dollar,redeem_points,
    reward_credit_cents,active,loyalty_model,configuration_status,
    recommendation_source
  ) values(
    v_business.id,'points',1,800,2000,false,'classic','draft',
    'onboarding_preset'
  );
  insert into public.subscriptions(business_id) values(v_business.id)
  on conflict(business_id) do nothing;
  insert into public.business_sector_assignments(
    business_id,bundle_version_id,version,assigned_by
  ) values(v_business.id,v_bundle.id,1,v_actor);
  update public.business_applications_v95
  set status='consumed',version=version+1,consumed_business_id=v_business.id,
    consumed_by=v_actor,consumed_at=now(),updated_at=now()
  where id=v_application.id;
  v_response:=jsonb_build_object(
    'application_id',v_application.id,'status','consumed',
    'business_id',v_business.id,'business_slug',v_business.slug,
    'owner_staff_id',v_staff,'default_branch_id',v_branch,
    'workspace_created',true,'workspace_access',true,'replayed',false
  );
  update public.business_application_invitations_v95
  set consumed_at=now(),consumed_by=v_actor,business_id=v_business.id,
    idempotency_key=p_idempotency_key,response=v_response
  where id=v_invitation.id;
  insert into public.business_application_audit_v95(
    application_id,event_type,actor,prior_status,new_status,reason,detail
  ) values(
    v_application.id,'invitation_consumed',v_actor,'approved','consumed',
    'approved invitation consumed once',
    jsonb_build_object('business_id',v_business.id)
  );
  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values(
    v_business.id,v_actor,'APPROVED_APPLICATION_ACTIVATED_V95',
    'businesses',v_business.id,jsonb_build_object(
      'application_id',v_application.id,'sector_bundle_version_id',v_bundle.id
    )
  );
  return v_response;
end
$$;

-- ---------------------------------------------------------------------------
-- 2. Locale, localized customer copy, media metadata and content.
-- ---------------------------------------------------------------------------

create table public.customer_locale_preferences_v95(
  auth_user_id uuid primary key references auth.users(id) on delete cascade,
  locale text not null check(locale in ('en','zh-CN')),
  version bigint not null default 1 check(version>0),
  updated_at timestamptz not null default now()
);

create table public.business_customer_content_v95(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  content_type text not null check(content_type in ('benefit','offer')),
  branch_id uuid,
  active boolean not null default true,
  display_order integer not null default 0 check(display_order between 0 and 10000),
  starts_at timestamptz,
  ends_at timestamptz,
  metadata jsonb not null default '{}'::jsonb check(jsonb_typeof(metadata)='object'),
  version bigint not null default 1 check(version>0),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  unique(id,business_id),
  constraint business_customer_content_v95_branch_fk
    foreign key(branch_id,business_id)
    references public.branches(id,business_id) on delete cascade,
  constraint business_customer_content_v95_window_check
    check(ends_at is null or starts_at is null or ends_at>starts_at)
);
create index business_customer_content_v95_visible_idx
  on public.business_customer_content_v95(
    business_id,content_type,branch_id,active,display_order
  );

create table public.business_localized_copy_v95(
  business_id uuid not null references public.businesses(id) on delete cascade,
  entity_type text not null check(entity_type in (
    'programme','reward','product','service','benefit','offer','tier'
  )),
  entity_id uuid not null,
  locale text not null check(locale in ('en','zh-CN')),
  name text not null check(length(btrim(name)) between 1 and 160),
  tagline text check(tagline is null or length(btrim(tagline)) between 1 and 240),
  description text check(
    description is null or length(btrim(description)) between 1 and 2000
  ),
  terms text check(terms is null or length(btrim(terms)) between 1 and 4000),
  version bigint not null default 1 check(version>0),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key(business_id,entity_type,entity_id,locale)
);

insert into storage.buckets as bucket(
  id,name,public,file_size_limit,allowed_mime_types
) values(
  'business-public','business-public',true,10485760,
  array['image/png','image/jpeg','image/webp','image/gif']::text[]
)
on conflict(id) do update set
  name=excluded.name,public=true,file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

create table public.business_media_assets_v95(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  asset_kind text not null check(asset_kind in (
    'logo','hero','programme','reward','product','service','benefit','offer'
  )),
  entity_id uuid,
  branch_id uuid,
  bucket_id text not null default 'business-public'
    check(bucket_id='business-public'),
  object_path text not null unique check(
    object_path~(
      '^'||business_id::text||'/'||asset_kind||
      '/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(png|jpg|jpeg|webp|gif)$'
    )
  ),
  mime_type text not null check(
    mime_type in ('image/png','image/jpeg','image/webp','image/gif')
  ),
  width_px integer check(width_px between 1 and 10000),
  height_px integer check(height_px between 1 and 10000),
  alt_en text not null check(length(btrim(alt_en)) between 1 and 240),
  alt_zh_cn text check(
    alt_zh_cn is null or length(btrim(alt_zh_cn)) between 1 and 240
  ),
  customer_visible boolean not null default true,
  version bigint not null default 1 check(version>0),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  unique(id,business_id),
  constraint business_media_assets_v95_branch_fk
    foreign key(branch_id,business_id)
    references public.branches(id,business_id) on delete cascade
);
create unique index business_media_assets_v95_scope_uk
  on public.business_media_assets_v95(
    business_id,asset_kind,coalesce(entity_id,'00000000-0000-0000-0000-000000000000'),
    coalesce(branch_id,'00000000-0000-0000-0000-000000000000')
  );

create table public.business_media_cleanup_queue_v95(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  bucket_id text not null default 'business-public'
    check(bucket_id='business-public'),
  object_path text not null,
  reason text not null check(length(btrim(reason)) between 1 and 240),
  status text not null default 'pending'
    check(status in ('pending','completed')),
  attempts integer not null default 0 check(attempts between 0 and 10000),
  last_error text check(
    last_error is null or length(btrim(last_error)) between 1 and 1000
  ),
  requested_by uuid references auth.users(id) on delete set null,
  requested_at timestamptz not null default now(),
  last_attempt_at timestamptz,
  completed_at timestamptz,
  updated_at timestamptz not null default now(),
  unique(business_id,object_path),
  check(
    object_path~(
      '^'||business_id::text||
      '/(logo|hero|programme|reward|product|service|benefit|offer)'||
      '/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(png|jpg|jpeg|webp|gif)$'
    )
  )
);
create index business_media_cleanup_queue_v95_pending_idx
  on public.business_media_cleanup_queue_v95(
    business_id,status,requested_at,id
  ) where status='pending';

create table public.business_brand_presentation_v95(
  business_id uuid primary key references public.businesses(id) on delete cascade,
  logo_asset_id uuid,
  hero_asset_id uuid,
  hero_color text not null default '#C43D32'
    check(hero_color~'^#[0-9A-Fa-f]{6}$'),
  version bigint not null default 1 check(version>0),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  constraint business_brand_presentation_v95_logo_fk
    foreign key(logo_asset_id,business_id)
    references public.business_media_assets_v95(id,business_id) on delete restrict,
  constraint business_brand_presentation_v95_hero_fk
    foreign key(hero_asset_id,business_id)
    references public.business_media_assets_v95(id,business_id) on delete restrict
);
insert into public.business_brand_presentation_v95(business_id)
select id from public.businesses;

alter table public.customer_locale_preferences_v95 enable row level security;
alter table public.business_customer_content_v95 enable row level security;
alter table public.business_localized_copy_v95 enable row level security;
alter table public.business_media_assets_v95 enable row level security;
alter table public.business_media_cleanup_queue_v95 enable row level security;
alter table public.business_brand_presentation_v95 enable row level security;
revoke all privileges on table public.customer_locale_preferences_v95
  from public,anon,authenticated;
revoke all privileges on table public.business_customer_content_v95
  from public,anon,authenticated;
revoke all privileges on table public.business_localized_copy_v95
  from public,anon,authenticated;
revoke all privileges on table public.business_media_assets_v95
  from public,anon,authenticated;
revoke all privileges on table public.business_media_cleanup_queue_v95
  from public,anon,authenticated;
revoke all privileges on table public.business_brand_presentation_v95
  from public,anon,authenticated;

create or replace function app.seed_business_presentation_v95()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  insert into public.business_brand_presentation_v95(business_id)
  values(new.id);
  return new;
end
$$;
revoke all on function app.seed_business_presentation_v95()
  from public,anon,authenticated;
create trigger trg_seed_business_presentation_v95
after insert on public.businesses for each row
execute function app.seed_business_presentation_v95();

create or replace function app.v95_entity_in_business(
  p_business uuid,p_entity_type text,p_entity uuid
)
returns boolean language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select case p_entity_type
    when 'programme' then exists(select 1 from public.loyalty_programs
      where id=p_entity and business_id=p_business)
    when 'reward' then exists(select 1 from public.loyalty_rewards
      where id=p_entity and business_id=p_business)
    when 'product' then exists(select 1 from public.products
      where id=p_entity and business_id=p_business)
    when 'service' then exists(select 1 from public.services
      where id=p_entity and business_id=p_business)
    when 'tier' then exists(select 1 from public.loyalty_tiers
      where id=p_entity and business_id=p_business)
    when 'benefit' then exists(select 1 from public.business_customer_content_v95
      where id=p_entity and business_id=p_business and content_type='benefit')
    when 'offer' then exists(select 1 from public.business_customer_content_v95
      where id=p_entity and business_id=p_business and content_type='offer')
    else false end
$$;
revoke all on function app.v95_entity_in_business(uuid,text,uuid)
  from public,anon,authenticated;

create or replace function app.v95_public_media_url(p_object_path text)
returns text language sql immutable
set search_path to 'pg_catalog','pg_temp'
as $$
  select case when p_object_path is null then null
    else '/storage/v1/object/public/business-public/'||p_object_path end
$$;
revoke all on function app.v95_public_media_url(text)
  from public,anon,authenticated;

create or replace function app.v95_storage_object_is_publishable(
  p_business uuid,p_asset_kind text,p_object_path text,p_mime_type text
)
returns boolean language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select
    p_asset_kind in (
      'logo','hero','programme','reward','product','service','benefit','offer'
    )
    and p_mime_type in ('image/png','image/jpeg','image/webp','image/gif')
    and p_object_path~(
      '^'||p_business::text||'/'||p_asset_kind||
      '/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(png|jpg|jpeg|webp|gif)$'
    )
    and case p_mime_type
      when 'image/png' then p_object_path~'\.png$'
      when 'image/jpeg' then p_object_path~'\.(jpg|jpeg)$'
      when 'image/webp' then p_object_path~'\.webp$'
      when 'image/gif' then p_object_path~'\.gif$'
      else false
    end
    and exists(
      select 1 from storage.objects object
      where object.bucket_id='business-public'
        and object.name=p_object_path
        and lower(coalesce(object.metadata->>'mimetype',''))=p_mime_type
        and coalesce(object.metadata->>'size','')~'^[0-9]+$'
        and (object.metadata->>'size')::bigint between 1 and 10485760
    )
$$;
revoke all on function app.v95_storage_object_is_publishable(
  uuid,text,text,text
) from public,anon,authenticated;

create or replace function public.customer_get_locale_preference_v95()
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_actor uuid:=auth.uid();v_row public.customer_locale_preferences_v95%rowtype;
begin
  if v_actor is null then raise exception 'authenticated_session_required'
    using errcode='28000';end if;
  select * into v_row from public.customer_locale_preferences_v95
  where auth_user_id=v_actor;
  return jsonb_build_object(
    'locale',coalesce(v_row.locale,'en'),'version',coalesce(v_row.version,0)
  );
end
$$;

create or replace function public.customer_set_locale_preference_v95(
  p_locale text,p_expected_version bigint
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_actor uuid:=auth.uid();v_row public.customer_locale_preferences_v95%rowtype;
begin
  if v_actor is null then raise exception 'authenticated_session_required'
    using errcode='28000';end if;
  if p_locale not in ('en','zh-CN') or p_expected_version is null then
    raise exception 'supported_locale_and_version_required' using errcode='22023';
  end if;
  select * into v_row from public.customer_locale_preferences_v95
  where auth_user_id=v_actor for update;
  if found then
    if v_row.version<>p_expected_version then
      raise exception 'locale_version_conflict' using errcode='40001';
    end if;
    update public.customer_locale_preferences_v95
    set locale=p_locale,version=version+1,updated_at=now()
    where auth_user_id=v_actor returning * into v_row;
  else
    if p_expected_version<>0 then
      raise exception 'locale_version_conflict' using errcode='40001';
    end if;
    insert into public.customer_locale_preferences_v95(auth_user_id,locale)
    values(v_actor,p_locale) returning * into v_row;
  end if;
  return jsonb_build_object('locale',v_row.locale,'version',v_row.version);
end
$$;

create or replace function public.business_upsert_customer_content_v95(
  p_business uuid,p_content_type text,p_content_id uuid,p_branch uuid,
  p_active boolean,p_display_order integer,p_starts_at timestamptz,
  p_ends_at timestamptz,p_metadata jsonb,p_expected_version bigint
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_row public.business_customer_content_v95%rowtype;
begin
  if not app.is_salon_owner(p_business) and not app.is_super_admin() then
    raise exception 'owner_required' using errcode='42501';end if;
  if p_content_type not in ('benefit','offer') or p_active is null
     or p_display_order not between 0 and 10000
     or jsonb_typeof(coalesce(p_metadata,'null'::jsonb))<>'object'
     or p_expected_version is null
     or (p_branch is not null and not exists(
       select 1 from public.branches where id=p_branch and business_id=p_business
     ))
  then raise exception 'valid customer content fields are required'
    using errcode='22023';end if;
  if p_content_id is null then
    if p_expected_version<>0 then raise exception 'content_version_conflict'
      using errcode='40001';end if;
    insert into public.business_customer_content_v95(
      business_id,content_type,branch_id,active,display_order,starts_at,
      ends_at,metadata,updated_by
    ) values(
      p_business,p_content_type,p_branch,p_active,p_display_order,p_starts_at,
      p_ends_at,p_metadata,auth.uid()
    ) returning * into v_row;
  else
    select * into v_row from public.business_customer_content_v95
    where id=p_content_id and business_id=p_business for update;
    if not found then raise exception 'content_not_found' using errcode='22023';end if;
    if v_row.version<>p_expected_version then raise exception 'content_version_conflict'
      using errcode='40001';end if;
    update public.business_customer_content_v95
    set content_type=p_content_type,branch_id=p_branch,active=p_active,
      display_order=p_display_order,starts_at=p_starts_at,ends_at=p_ends_at,
      metadata=p_metadata,version=version+1,updated_by=auth.uid(),updated_at=now()
    where id=p_content_id returning * into v_row;
  end if;
  return jsonb_build_object(
    'id',v_row.id,'business_id',v_row.business_id,
    'content_type',v_row.content_type,'branch_id',v_row.branch_id,
    'active',v_row.active,'display_order',v_row.display_order,
    'starts_at',v_row.starts_at,'ends_at',v_row.ends_at,
    'metadata',v_row.metadata,'version',v_row.version
  );
end
$$;

create or replace function public.business_upsert_localized_copy_v95(
  p_business uuid,p_entity_type text,p_entity_id uuid,p_locale text,
  p_name text,p_tagline text,p_description text,p_terms text,
  p_expected_version bigint
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_row public.business_localized_copy_v95%rowtype;
begin
  if not app.is_salon_owner(p_business) and not app.is_super_admin() then
    raise exception 'owner_required' using errcode='42501';end if;
  if p_locale not in ('en','zh-CN')
     or not app.v95_entity_in_business(p_business,p_entity_type,p_entity_id)
     or length(btrim(coalesce(p_name,''))) not between 1 and 160
     or p_expected_version is null
  then raise exception 'valid localized entity copy is required'
    using errcode='22023';end if;
  select * into v_row from public.business_localized_copy_v95
  where business_id=p_business and entity_type=p_entity_type
    and entity_id=p_entity_id and locale=p_locale for update;
  if found then
    if v_row.version<>p_expected_version then raise exception 'copy_version_conflict'
      using errcode='40001';end if;
    update public.business_localized_copy_v95
    set name=btrim(p_name),tagline=nullif(btrim(coalesce(p_tagline,'')),''),
      description=nullif(btrim(coalesce(p_description,'')),''),
      terms=nullif(btrim(coalesce(p_terms,'')),''),
      version=version+1,updated_by=auth.uid(),updated_at=now()
    where business_id=p_business and entity_type=p_entity_type
      and entity_id=p_entity_id and locale=p_locale returning * into v_row;
  else
    if p_expected_version<>0 then raise exception 'copy_version_conflict'
      using errcode='40001';end if;
    insert into public.business_localized_copy_v95(
      business_id,entity_type,entity_id,locale,name,tagline,description,
      terms,updated_by
    ) values(
      p_business,p_entity_type,p_entity_id,p_locale,btrim(p_name),
      nullif(btrim(coalesce(p_tagline,'')),''),
      nullif(btrim(coalesce(p_description,'')),''),
      nullif(btrim(coalesce(p_terms,'')),''),auth.uid()
    ) returning * into v_row;
  end if;
  return to_jsonb(v_row)-'updated_by';
end
$$;

create or replace function public.business_upsert_media_asset_v95(
  p_business uuid,p_asset_kind text,p_entity_id uuid,p_branch uuid,
  p_object_path text,p_mime_type text,p_width_px integer,p_height_px integer,
  p_alt_en text,p_alt_zh_cn text,p_visible boolean,p_expected_version bigint
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_row public.business_media_assets_v95%rowtype;
begin
  if not app.is_salon_owner(p_business) and not app.is_super_admin() then
    raise exception 'owner_required' using errcode='42501';end if;
  if p_asset_kind not in (
      'logo','hero','programme','reward','product','service','benefit','offer'
    ) or p_visible is distinct from false
     or not app.v95_storage_object_is_publishable(
       p_business,p_asset_kind,p_object_path,p_mime_type
     )
     or p_mime_type not in ('image/png','image/jpeg','image/webp','image/gif')
     or length(btrim(coalesce(p_alt_en,''))) not between 1 and 240
     or p_visible is null or p_expected_version is null
     or (p_asset_kind not in ('logo','hero') and (
       p_entity_id is null or not app.v95_entity_in_business(
         p_business,p_asset_kind,p_entity_id
       )
     ))
     or (p_asset_kind in ('logo','hero') and p_entity_id is not null)
     or (p_asset_kind in ('logo','hero') and p_branch is not null)
     or (p_branch is not null and not exists(
       select 1 from public.branches where id=p_branch and business_id=p_business
     ))
  then raise exception 'valid scoped media asset is required' using errcode='22023';end if;
  select * into v_row from public.business_media_assets_v95 asset
  where asset.business_id=p_business and asset.asset_kind=p_asset_kind
    and asset.entity_id is not distinct from p_entity_id
    and asset.branch_id is not distinct from p_branch for update;
  if found then
    if v_row.version<>p_expected_version then raise exception 'media_version_conflict'
      using errcode='40001';end if;
    update public.business_media_assets_v95
    set object_path=p_object_path,mime_type=p_mime_type,width_px=p_width_px,
      height_px=p_height_px,alt_en=btrim(p_alt_en),
      alt_zh_cn=nullif(btrim(coalesce(p_alt_zh_cn,'')),''),
      customer_visible=p_visible,version=version+1,updated_by=auth.uid(),
      updated_at=now()
    where id=v_row.id returning * into v_row;
  else
    if p_expected_version<>0 then raise exception 'media_version_conflict'
      using errcode='40001';end if;
    insert into public.business_media_assets_v95(
      business_id,asset_kind,entity_id,branch_id,object_path,mime_type,
      width_px,height_px,alt_en,alt_zh_cn,customer_visible,updated_by
    ) values(
      p_business,p_asset_kind,p_entity_id,p_branch,p_object_path,p_mime_type,
      p_width_px,p_height_px,btrim(p_alt_en),
      nullif(btrim(coalesce(p_alt_zh_cn,'')),''),p_visible,auth.uid()
    ) returning * into v_row;
  end if;
  return jsonb_build_object(
    'id',v_row.id,'asset_kind',v_row.asset_kind,'entity_id',v_row.entity_id,
    'branch_id',v_row.branch_id,'object_path',v_row.object_path,
    'url',app.v95_public_media_url(v_row.object_path),
    'mime_type',v_row.mime_type,'width_px',v_row.width_px,
    'height_px',v_row.height_px,'alt_en',v_row.alt_en,
    'alt_zh_cn',v_row.alt_zh_cn,'customer_visible',v_row.customer_visible,
    'version',v_row.version
  );
end
$$;

create or replace function public.business_publish_media_replacement_v95(
  p_business uuid,p_asset_kind text,p_entity_id uuid,p_branch uuid,
  p_object_path text,p_mime_type text,p_width_px integer,p_height_px integer,
  p_alt_en text,p_alt_zh_cn text,p_hero_color text,
  p_expected_asset_version bigint,
  p_expected_brand_version bigint
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_existing public.business_media_assets_v95%rowtype;
  v_asset public.business_media_assets_v95%rowtype;
  v_brand public.business_brand_presentation_v95%rowtype;
  v_previous_object_path text;
begin
  if not app.is_salon_owner(p_business) and not app.is_super_admin() then
    raise exception 'owner_required' using errcode='42501';
  end if;
  if p_expected_asset_version is null
     or not app.v95_storage_object_is_publishable(
       p_business,p_asset_kind,p_object_path,p_mime_type
     ) then
    raise exception 'verified_storage_object_required' using errcode='22023';
  end if;
  if p_asset_kind in ('logo','hero') then
    if p_expected_brand_version is null or p_entity_id is not null
       or p_branch is not null
       or coalesce(p_hero_color,'')!~'^#[0-9A-Fa-f]{6}$' then
      raise exception 'brand_version_required' using errcode='22023';
    end if;
    select * into v_brand from public.business_brand_presentation_v95
    where business_id=p_business for update;
    if not found or v_brand.version<>p_expected_brand_version then
      raise exception 'brand_version_conflict' using errcode='40001';
    end if;
  elsif p_expected_brand_version is not null or p_hero_color is not null then
    raise exception 'brand_version_not_applicable' using errcode='22023';
  end if;

  select * into v_existing from public.business_media_assets_v95 asset
  where asset.business_id=p_business and asset.asset_kind=p_asset_kind
    and asset.entity_id is not distinct from p_entity_id
    and asset.branch_id is not distinct from p_branch
  for update;
  if found then v_previous_object_path:=v_existing.object_path;end if;

  perform public.business_upsert_media_asset_v95(
    p_business,p_asset_kind,p_entity_id,p_branch,p_object_path,p_mime_type,
    p_width_px,p_height_px,p_alt_en,p_alt_zh_cn,false,
    p_expected_asset_version
  );
  update public.business_media_assets_v95 asset
  set customer_visible=true
  where asset.business_id=p_business and asset.asset_kind=p_asset_kind
    and asset.entity_id is not distinct from p_entity_id
    and asset.branch_id is not distinct from p_branch
  returning * into v_asset;

  if p_asset_kind in ('logo','hero') then
    update public.business_brand_presentation_v95
    set logo_asset_id=case
          when p_asset_kind='logo' then v_asset.id else logo_asset_id end,
        hero_asset_id=case
          when p_asset_kind='hero' then v_asset.id else hero_asset_id end,
        hero_color=upper(p_hero_color),
        version=version+1,updated_by=auth.uid(),updated_at=now()
    where business_id=p_business returning * into v_brand;
  end if;

  return jsonb_build_object(
    'id',v_asset.id,'asset_kind',v_asset.asset_kind,
    'entity_id',v_asset.entity_id,'branch_id',v_asset.branch_id,
    'object_path',v_asset.object_path,
    'url',app.v95_public_media_url(v_asset.object_path),
    'mime_type',v_asset.mime_type,'width_px',v_asset.width_px,
    'height_px',v_asset.height_px,'alt_en',v_asset.alt_en,
    'alt_zh_cn',v_asset.alt_zh_cn,'customer_visible',true,
    'version',v_asset.version,
    'brand_version',case when p_asset_kind in ('logo','hero')
      then v_brand.version else null end,
    'previous_object_path',case
      when v_previous_object_path is distinct from v_asset.object_path
      then v_previous_object_path else null end
  );
end
$$;

create or replace function public.business_queue_media_cleanup_v95(
  p_business uuid,p_object_path text,p_reason text
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_row public.business_media_cleanup_queue_v95%rowtype;
begin
  if not app.is_salon_owner(p_business) and not app.is_super_admin() then
    raise exception 'owner_required' using errcode='42501';
  end if;
  if coalesce(p_object_path,'')!~(
       '^'||p_business::text||
       '/(logo|hero|programme|reward|product|service|benefit|offer)'||
       '/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(png|jpg|jpeg|webp|gif)$'
     )
     or length(btrim(coalesce(p_reason,''))) not between 1 and 240 then
    raise exception 'valid cleanup target required' using errcode='22023';
  end if;
  if exists(
    select 1 from public.business_media_assets_v95
    where business_id=p_business and object_path=p_object_path
  ) then
    raise exception 'published_media_cannot_be_queued' using errcode='23514';
  end if;
  insert into public.business_media_cleanup_queue_v95(
    business_id,object_path,reason,status,requested_by,completed_at
  ) values(
    p_business,p_object_path,btrim(p_reason),
    case when exists(
      select 1 from storage.objects
      where bucket_id='business-public' and name=p_object_path
    ) then 'pending' else 'completed' end,
    auth.uid(),
    case when exists(
      select 1 from storage.objects
      where bucket_id='business-public' and name=p_object_path
    ) then null else now() end
  )
  on conflict(business_id,object_path) do update set
    reason=excluded.reason,status=excluded.status,
    requested_by=excluded.requested_by,requested_at=now(),
    completed_at=excluded.completed_at,updated_at=now()
  returning * into v_row;
  return to_jsonb(v_row)-'requested_by';
end
$$;

create or replace function public.business_list_media_cleanup_queue_v95(
  p_business uuid,p_limit integer default 20
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if not app.is_salon_owner(p_business) and not app.is_super_admin() then
    raise exception 'owner_required' using errcode='42501';
  end if;
  if p_limit not between 1 and 100 then
    raise exception 'cleanup_limit_out_of_range' using errcode='22023';
  end if;
  return jsonb_build_object(
    'pending',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',queue.id,'object_path',queue.object_path,
          'reason',queue.reason,'attempts',queue.attempts,
          'last_error',queue.last_error,'requested_at',queue.requested_at,
          'last_attempt_at',queue.last_attempt_at
        ) order by queue.requested_at,queue.id
      )
      from (
        select * from public.business_media_cleanup_queue_v95
        where business_id=p_business and status='pending'
        order by requested_at,id limit p_limit
      ) queue
    ),'[]'::jsonb)
  );
end
$$;

create or replace function public.business_mark_media_cleanup_result_v95(
  p_business uuid,p_cleanup uuid,p_succeeded boolean,p_error text
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_row public.business_media_cleanup_queue_v95%rowtype;
begin
  if not app.is_salon_owner(p_business) and not app.is_super_admin() then
    raise exception 'owner_required' using errcode='42501';
  end if;
  select * into v_row from public.business_media_cleanup_queue_v95
  where id=p_cleanup and business_id=p_business for update;
  if not found then raise exception 'cleanup_item_not_found'
    using errcode='22023';end if;
  if p_succeeded is null
     or (not p_succeeded and length(btrim(coalesce(p_error,'')))
       not between 1 and 1000)
     or (p_succeeded and exists(
       select 1 from storage.objects
       where bucket_id='business-public' and name=v_row.object_path
     )) then
    raise exception 'truthful_cleanup_result_required' using errcode='22023';
  end if;
  update public.business_media_cleanup_queue_v95
  set status=case when p_succeeded then 'completed' else 'pending' end,
    attempts=attempts+1,last_attempt_at=now(),
    last_error=case when p_succeeded then null else btrim(p_error) end,
    completed_at=case when p_succeeded then now() else null end,
    updated_at=now()
  where id=p_cleanup returning * into v_row;
  return to_jsonb(v_row)-'requested_by';
end
$$;

create or replace function public.business_set_brand_presentation_v95(
  p_business uuid,p_logo_asset uuid,p_hero_asset uuid,p_hero_color text,
  p_expected_version bigint
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_row public.business_brand_presentation_v95%rowtype;
begin
  if not app.is_salon_owner(p_business) and not app.is_super_admin() then
    raise exception 'owner_required' using errcode='42501';end if;
  if coalesce(p_hero_color,'')!~'^#[0-9A-Fa-f]{6}$'
     or p_expected_version is null
     or (p_logo_asset is not null and not exists(
       select 1 from public.business_media_assets_v95
       where id=p_logo_asset and business_id=p_business
         and asset_kind='logo' and customer_visible
     ))
     or (p_hero_asset is not null and not exists(
       select 1 from public.business_media_assets_v95
       where id=p_hero_asset and business_id=p_business
         and asset_kind='hero' and customer_visible
     ))
  then raise exception 'valid visible brand assets and version are required'
    using errcode='22023';end if;
  select * into v_row from public.business_brand_presentation_v95
  where business_id=p_business for update;
  if v_row.version<>p_expected_version then raise exception 'brand_version_conflict'
    using errcode='40001';end if;
  update public.business_brand_presentation_v95
  set logo_asset_id=p_logo_asset,hero_asset_id=p_hero_asset,
    hero_color=upper(p_hero_color),version=version+1,
    updated_by=auth.uid(),updated_at=now()
  where business_id=p_business returning * into v_row;
  return jsonb_build_object(
    'business_id',p_business,'logo_asset_id',v_row.logo_asset_id,
    'hero_asset_id',v_row.hero_asset_id,'hero_color',v_row.hero_color,
    'version',v_row.version
  );
end
$$;

create or replace function public.business_get_presentation_editor_v95(
  p_business uuid
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_result jsonb;
begin
  if not app.is_salon_owner(p_business) and not app.is_super_admin() then
    raise exception 'owner_required' using errcode='42501';
  end if;
  if not exists(select 1 from public.businesses where id=p_business) then
    raise exception 'business_not_found' using errcode='22023';
  end if;

  select jsonb_build_object(
    'business_id',p_business,
    'available_locales',jsonb_build_array('en','zh-CN'),
    'brand',jsonb_build_object(
      'version',brand.version,
      'hero_color',brand.hero_color,
      'logo_asset',case when logo.id is null then null else
        (to_jsonb(logo)-'business_id'-'updated_by')
        ||jsonb_build_object('url',app.v95_public_media_url(logo.object_path))
      end,
      'hero_asset',case when hero.id is null then null else
        (to_jsonb(hero)-'business_id'-'updated_by')
        ||jsonb_build_object('url',app.v95_public_media_url(hero.object_path))
      end
    ),
    'programmes',coalesce((
      select jsonb_agg(
        (to_jsonb(programme)-'business_id')
        ||jsonb_build_object(
          'copies',coalesce((
            select jsonb_agg(
              to_jsonb(copy)-'business_id'-'entity_type'-'entity_id'
                -'updated_by'
              order by copy.locale
            )
            from public.business_localized_copy_v95 copy
            where copy.business_id=p_business
              and copy.entity_type='programme'
              and copy.entity_id=programme.id
          ),'[]'::jsonb),
          'media',coalesce((
            select jsonb_agg(
              (to_jsonb(asset)-'business_id'-'updated_by')
                ||jsonb_build_object(
                  'url',app.v95_public_media_url(asset.object_path)
                )
              order by asset.branch_id nulls first,asset.id
            )
            from public.business_media_assets_v95 asset
            where asset.business_id=p_business
              and asset.asset_kind='programme'
              and asset.entity_id=programme.id
          ),'[]'::jsonb)
        )
        order by programme.id
      )
      from public.loyalty_programs programme
      where programme.business_id=p_business
    ),'[]'::jsonb),
    'rewards',coalesce((
      select jsonb_agg(
        (to_jsonb(reward)-'business_id')
        ||jsonb_build_object(
          'copies',coalesce((
            select jsonb_agg(
              to_jsonb(copy)-'business_id'-'entity_type'-'entity_id'
                -'updated_by'
              order by copy.locale
            )
            from public.business_localized_copy_v95 copy
            where copy.business_id=p_business
              and copy.entity_type='reward'
              and copy.entity_id=reward.id
          ),'[]'::jsonb),
          'media',coalesce((
            select jsonb_agg(
              (to_jsonb(asset)-'business_id'-'updated_by')
                ||jsonb_build_object(
                  'url',app.v95_public_media_url(asset.object_path)
                )
              order by asset.branch_id nulls first,asset.id
            )
            from public.business_media_assets_v95 asset
            where asset.business_id=p_business
              and asset.asset_kind='reward'
              and asset.entity_id=reward.id
          ),'[]'::jsonb)
        )
        order by reward.sort,reward.id
      )
      from public.loyalty_rewards reward
      where reward.business_id=p_business
    ),'[]'::jsonb),
    'products',coalesce((
      select jsonb_agg(
        (to_jsonb(product)-'business_id')
        ||jsonb_build_object(
          'copies',coalesce((
            select jsonb_agg(
              to_jsonb(copy)-'business_id'-'entity_type'-'entity_id'
                -'updated_by'
              order by copy.locale
            )
            from public.business_localized_copy_v95 copy
            where copy.business_id=p_business
              and copy.entity_type='product'
              and copy.entity_id=product.id
          ),'[]'::jsonb),
          'media',coalesce((
            select jsonb_agg(
              (to_jsonb(asset)-'business_id'-'updated_by')
                ||jsonb_build_object(
                  'url',app.v95_public_media_url(asset.object_path)
                )
              order by asset.branch_id nulls first,asset.id
            )
            from public.business_media_assets_v95 asset
            where asset.business_id=p_business
              and asset.asset_kind='product'
              and asset.entity_id=product.id
          ),'[]'::jsonb)
        )
        order by product.name,product.id
      )
      from public.products product
      where product.business_id=p_business
    ),'[]'::jsonb),
    'services',coalesce((
      select jsonb_agg(
        (to_jsonb(service)-'business_id')
        ||jsonb_build_object(
          'copies',coalesce((
            select jsonb_agg(
              to_jsonb(copy)-'business_id'-'entity_type'-'entity_id'
                -'updated_by'
              order by copy.locale
            )
            from public.business_localized_copy_v95 copy
            where copy.business_id=p_business
              and copy.entity_type='service'
              and copy.entity_id=service.id
          ),'[]'::jsonb),
          'media',coalesce((
            select jsonb_agg(
              (to_jsonb(asset)-'business_id'-'updated_by')
                ||jsonb_build_object(
                  'url',app.v95_public_media_url(asset.object_path)
                )
              order by asset.branch_id nulls first,asset.id
            )
            from public.business_media_assets_v95 asset
            where asset.business_id=p_business
              and asset.asset_kind='service'
              and asset.entity_id=service.id
          ),'[]'::jsonb)
        )
        order by service.name,service.id
      )
      from public.services service
      where service.business_id=p_business
    ),'[]'::jsonb)
  ) into v_result
  from public.business_brand_presentation_v95 brand
  left join public.business_media_assets_v95 logo
    on logo.id=brand.logo_asset_id and logo.business_id=brand.business_id
  left join public.business_media_assets_v95 hero
    on hero.id=brand.hero_asset_id and hero.business_id=brand.business_id
  where brand.business_id=p_business;
  return v_result;
end
$$;

-- Storage folders are `<business uuid>/<kind>/<asset uuid>.<ext>`. Policies
-- are installed only where Supabase's platform-owned storage.objects exists;
-- the local rehearsal intentionally stubs bucket metadata only.
create or replace function app.v95_storage_path_owned(p_name text)
returns boolean language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if coalesce(p_name,'')!~(
    '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}'||
    '/(logo|hero|programme|reward|product|service|benefit|offer)'||
    '/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(png|jpg|jpeg|webp|gif)$'
  )
  then return false;end if;
  return app.is_salon_owner(split_part(p_name,'/',1)::uuid);
end
$$;
revoke all on function app.v95_storage_path_owned(text)
  from public,anon,authenticated;

do $storage_policies$
begin
  if to_regclass('storage.objects') is not null then
    execute 'drop policy if exists business_public_owner_insert_v95 on storage.objects';
    execute 'drop policy if exists business_public_owner_select_v95 on storage.objects';
    execute 'drop policy if exists business_public_owner_update_v95 on storage.objects';
    execute 'drop policy if exists business_public_owner_delete_v95 on storage.objects';
    execute $policy$create policy business_public_owner_insert_v95
      on storage.objects for insert to authenticated
      with check(bucket_id='business-public' and app.v95_storage_path_owned(name))$policy$;
    execute $policy$create policy business_public_owner_select_v95
      on storage.objects for select to authenticated
      using(bucket_id='business-public' and app.v95_storage_path_owned(name))$policy$;
    execute $policy$create policy business_public_owner_update_v95
      on storage.objects for update to authenticated
      using(bucket_id='business-public' and app.v95_storage_path_owned(name))
      with check(bucket_id='business-public' and app.v95_storage_path_owned(name))$policy$;
    execute $policy$create policy business_public_owner_delete_v95
      on storage.objects for delete to authenticated
      using(bucket_id='business-public' and app.v95_storage_path_owned(name))$policy$;
  end if;
end
$storage_policies$;

-- ---------------------------------------------------------------------------
-- 3. One verified-customer presentation reader with deterministic fallback.
-- ---------------------------------------------------------------------------

create or replace function public.customer_get_business_presentation_v95(
  p_business uuid,p_branch uuid default null,p_locale text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();v_identity uuid;v_client uuid;v_branch uuid:=p_branch;
  v_locale text;v_programme uuid;v_balance integer:=0;v_unit text:='points';
  v_metric numeric:=0;v_basis text;v_current public.loyalty_tiers%rowtype;
  v_next public.loyalty_tiers%rowtype;v_progress numeric:=0;v_result jsonb;
begin
  if v_actor is null then raise exception 'authenticated_session_required'
    using errcode='28000';end if;
  if p_locale is not null and p_locale not in ('en','zh-CN') then
    raise exception 'unsupported_locale' using errcode='22023';end if;
  v_identity:=app.v31_current_identity();
  select link.client_id into v_client from public.customer_links link
  where link.identity_id=v_identity and link.auth_user_id=v_actor
    and link.business_id=p_business and link.state='verified';
  if not found then raise exception 'verified_customer_link_required'
    using errcode='42501';end if;
  v_locale:=coalesce(
    p_locale,(select locale from public.customer_locale_preferences_v95
      where auth_user_id=v_actor),'en'
  );
  if v_branch is null then
    select id into v_branch from public.branches
    where business_id=p_business and active
    order by is_default desc,created_at,id limit 1;
  end if;
  if v_branch is null or not exists(
    select 1 from public.branches
    where id=v_branch and business_id=p_business and active
  ) then raise exception 'active_branch_required' using errcode='22023';end if;
  select id,case when loyalty_model='stamps' then 'stamps' else 'points' end,
    coalesce(tier_basis,'visits')
  into v_programme,v_unit,v_basis
  from public.loyalty_programs
  where business_id=p_business and active
  order by (current_config_version_id is not null) desc,id limit 1;
  select coalesce(sum(points),0)::integer into v_balance
  from public.points_ledger
  where business_id=p_business and client_id=v_client;
  if v_basis='spend' then
    select coalesce(sum(amount_cents),0)/100.0 into v_metric from public.sales
    where business_id=p_business and client_id=v_client and counts_as_revenue;
  elsif v_basis='points_earned' then
    select coalesce(sum(points),0) into v_metric from public.points_ledger
    where business_id=p_business and client_id=v_client and entry_type='earn';
  else
    select count(*) into v_metric from public.sales
    where business_id=p_business and client_id=v_client and counts_as_visit;
  end if;
  select * into v_current from public.loyalty_tiers
  where business_id=p_business and threshold<=v_metric
  order by threshold desc,sort desc,id limit 1;
  select * into v_next from public.loyalty_tiers
  where business_id=p_business and threshold>coalesce(v_current.threshold,-1)
  order by threshold,sort,id limit 1;
  if v_next.id is not null then
    v_progress:=greatest(0,least(100,round(
      (v_metric-coalesce(v_current.threshold,0))*100
      /nullif(v_next.threshold-coalesce(v_current.threshold,0),0),2
    )));
  elsif v_current.id is not null then v_progress:=100;end if;

  with programme_copy as (
    select copy.* from public.business_localized_copy_v95 copy
    where copy.business_id=p_business and copy.entity_type='programme'
      and copy.entity_id=v_programme and copy.locale=v_locale
    limit 1
  ), programme_english as (
    select copy.* from public.business_localized_copy_v95 copy
    where copy.business_id=p_business and copy.entity_type='programme'
      and copy.entity_id=v_programme and copy.locale='en'
    limit 1
  ), visible_media as (
    select distinct on(asset.asset_kind,asset.entity_id)
      asset.asset_kind,asset.entity_id,
      app.v95_public_media_url(asset.object_path) url
    from public.business_media_assets_v95 asset
    where asset.business_id=p_business and asset.customer_visible
      and (asset.branch_id is null or asset.branch_id=v_branch)
    order by asset.asset_kind,asset.entity_id,
      (asset.branch_id=v_branch) desc,asset.updated_at desc,asset.id
  ), benefits as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',content.id,
      'name',coalesce(copy.name,english.name,'Benefit'),
      'tagline',coalesce(copy.tagline,english.tagline),
      'description',coalesce(copy.description,english.description),
      'image_url',media.url,'metadata',content.metadata
    ) order by content.display_order,content.id),'[]'::jsonb) value
    from public.business_customer_content_v95 content
    left join public.business_localized_copy_v95 copy
      on copy.business_id=p_business and copy.entity_type='benefit'
      and copy.entity_id=content.id and copy.locale=v_locale
    left join public.business_localized_copy_v95 english
      on english.business_id=p_business and english.entity_type='benefit'
      and english.entity_id=content.id and english.locale='en'
    left join visible_media media
      on media.asset_kind='benefit' and media.entity_id=content.id
    where content.business_id=p_business and content.content_type='benefit'
      and content.active and (content.branch_id is null or content.branch_id=v_branch)
      and (content.starts_at is null or content.starts_at<=now())
      and (content.ends_at is null or content.ends_at>now())
  ), offers as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',content.id,
      'name',coalesce(copy.name,english.name,'Offer'),
      'tagline',coalesce(copy.tagline,english.tagline),
      'description',coalesce(copy.description,english.description),
      'terms',coalesce(copy.terms,english.terms),
      'image_url',media.url,'starts_at',content.starts_at,
      'ends_at',content.ends_at,'metadata',content.metadata
    ) order by content.display_order,content.id),'[]'::jsonb) value
    from public.business_customer_content_v95 content
    left join public.business_localized_copy_v95 copy
      on copy.business_id=p_business and copy.entity_type='offer'
      and copy.entity_id=content.id and copy.locale=v_locale
    left join public.business_localized_copy_v95 english
      on english.business_id=p_business and english.entity_type='offer'
      and english.entity_id=content.id and english.locale='en'
    left join visible_media media
      on media.asset_kind='offer' and media.entity_id=content.id
    where content.business_id=p_business and content.content_type='offer'
      and content.active and (content.branch_id is null or content.branch_id=v_branch)
      and (content.starts_at is null or content.starts_at<=now())
      and (content.ends_at is null or content.ends_at>now())
  ), services_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',service.id,'name',coalesce(copy.name,english.name,service.name),
      'description',coalesce(copy.description,english.description),
      'image_url',media.url,'price_cents',service.price_cents,
      'duration_min',service.duration_min
    ) order by service.name,service.id),'[]'::jsonb) value
    from public.services service
    left join public.business_localized_copy_v95 copy
      on copy.business_id=p_business and copy.entity_type='service'
      and copy.entity_id=service.id and copy.locale=v_locale
    left join public.business_localized_copy_v95 english
      on english.business_id=p_business and english.entity_type='service'
      and english.entity_id=service.id and english.locale='en'
    left join visible_media media
      on media.asset_kind='service' and media.entity_id=service.id
    where service.business_id=p_business and service.active
      and service.show_on_booking_page
      and (not exists(select 1 from public.service_branches configured
        where configured.business_id=p_business and configured.service_id=service.id)
        or exists(select 1 from public.service_branches available
          where available.business_id=p_business and available.service_id=service.id
            and available.branch_id=v_branch))
  ), products_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',product.id,'name',coalesce(copy.name,english.name,product.name),
      'description',coalesce(copy.description,english.description),
      'image_url',media.url,'price_cents',product.retail_price_cents
    ) order by product.name,product.id),'[]'::jsonb) value
    from public.products product
    left join public.business_localized_copy_v95 copy
      on copy.business_id=p_business and copy.entity_type='product'
      and copy.entity_id=product.id and copy.locale=v_locale
    left join public.business_localized_copy_v95 english
      on english.business_id=p_business and english.entity_type='product'
      and english.entity_id=product.id and english.locale='en'
    left join visible_media media
      on media.asset_kind='product' and media.entity_id=product.id
    where product.business_id=p_business and product.active
  ), rewards_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',reward.id,'name',coalesce(copy.name,english.name,reward.name),
      'description',coalesce(copy.description,english.description),
      'terms',coalesce(copy.terms,english.terms),
      'image_url',media.url,
      'metadata',jsonb_build_object(
        'cost_points',reward.cost_points,'credit_cents',reward.credit_cents
      )
    ) order by reward.sort,reward.id),'[]'::jsonb) value
    from public.loyalty_rewards reward
    left join public.business_localized_copy_v95 copy
      on copy.business_id=p_business and copy.entity_type='reward'
      and copy.entity_id=reward.id and copy.locale=v_locale
    left join public.business_localized_copy_v95 english
      on english.business_id=p_business and english.entity_type='reward'
      and english.entity_id=reward.id and english.locale='en'
    left join visible_media media
      on media.asset_kind='reward' and media.entity_id=reward.id
    where reward.business_id=p_business and reward.active
  )
  select jsonb_build_object(
    'business_id',business.id,'branch_id',v_branch,'locale',v_locale,
    'available_locales',jsonb_build_array('en','zh-CN'),
    'brand',jsonb_build_object(
      'logo_url',app.v95_public_media_url(logo.object_path),
      'hero_image_url',app.v95_public_media_url(hero.object_path),
      'hero_color',brand.hero_color
    ),
    'programme',jsonb_build_object(
      'id',v_programme,
      'name',coalesce(programme_copy.name,programme_english.name,
        business.name||' Loyalty'),
      'tagline',coalesce(programme_copy.tagline,programme_english.tagline),
      'description',coalesce(
        programme_copy.description,programme_english.description
      ),
      'balance',v_balance,'unit',v_unit,
      'tier',jsonb_build_object(
        'label',coalesce(tier_copy.name,tier_english.name,v_current.name),
        'current',case when v_current.id is null then null else jsonb_build_object(
          'id',v_current.id,'threshold',v_current.threshold,'metric',v_metric
        ) end,
        'next',case when v_next.id is null then null else jsonb_build_object(
          'id',v_next.id,'label',coalesce(next_copy.name,next_english.name,v_next.name),
          'threshold',v_next.threshold
        ) end,
        'progress_percent',v_progress
      ),
      'benefits',benefits.value,'offers',offers.value
    ),
    'catalogue',jsonb_build_object(
      'services',services_json.value,'products',products_json.value,
      'rewards',rewards_json.value
    ),
    'capabilities',jsonb_build_object(
      'booking_enabled',coalesce(capability.booking_enabled,false)
        and app.v89_business_module_enabled(p_business,'bookings')
        and jsonb_array_length(services_json.value)>0,
      'redemption_enabled',coalesce(capability.redemption_enabled,false)
        and app.v89_business_module_enabled(p_business,'loyalty')
        and v_programme is not null,
      'appointment_changes_enabled',
        coalesce(capability.appointment_changes_enabled,false)
        and app.v89_business_module_enabled(p_business,'appointments')
    )
  ) into v_result
  from public.businesses business
  join public.business_brand_presentation_v95 brand
    on brand.business_id=business.id
  left join public.business_media_assets_v95 logo
    on logo.id=brand.logo_asset_id and logo.customer_visible
    and (logo.branch_id is null or logo.branch_id=v_branch)
  left join public.business_media_assets_v95 hero
    on hero.id=brand.hero_asset_id and hero.customer_visible
    and (hero.branch_id is null or hero.branch_id=v_branch)
  left join public.business_customer_capabilities_v89 capability
    on capability.business_id=business.id
  left join programme_copy on true
  left join programme_english on true
  left join public.business_localized_copy_v95 tier_copy
    on tier_copy.business_id=p_business and tier_copy.entity_type='tier'
    and tier_copy.entity_id=v_current.id and tier_copy.locale=v_locale
  left join public.business_localized_copy_v95 tier_english
    on tier_english.business_id=p_business and tier_english.entity_type='tier'
    and tier_english.entity_id=v_current.id and tier_english.locale='en'
  left join public.business_localized_copy_v95 next_copy
    on next_copy.business_id=p_business and next_copy.entity_type='tier'
    and next_copy.entity_id=v_next.id and next_copy.locale=v_locale
  left join public.business_localized_copy_v95 next_english
    on next_english.business_id=p_business and next_english.entity_type='tier'
    and next_english.entity_id=v_next.id and next_english.locale='en'
  cross join benefits cross join offers cross join services_json
  cross join products_json cross join rewards_json
  where business.id=p_business;
  return v_result;
end
$$;

-- Finite browser ACL.
revoke all on function public.internal_submit_business_application_v95(
  text,text,text,text,text,text,text,uuid
) from public,anon,authenticated;
grant execute on function public.internal_submit_business_application_v95(
  text,text,text,text,text,text,text,uuid
) to service_role;
revoke all on function public.internal_get_approved_business_invitation_v95(text)
  from public,anon,authenticated;
grant execute on function public.internal_get_approved_business_invitation_v95(text)
  to service_role;
revoke all on function public.platform_decide_business_application_v95(
  uuid,text,text,bigint
) from public,anon,authenticated;
grant execute on function public.platform_decide_business_application_v95(
  uuid,text,text,bigint
) to authenticated;
revoke all on function public.get_business_application_status_v95(uuid)
  from public,anon,authenticated;
grant execute on function public.get_business_application_status_v95(uuid)
  to anon,authenticated;
grant execute on function public.get_business_application_status_v95(uuid)
  to service_role;
revoke all on function public.platform_get_business_application_v95(uuid)
  from public,anon,authenticated;
grant execute on function public.platform_get_business_application_v95(uuid)
  to authenticated;
revoke all on function public.platform_list_business_applications_v95(
  text,text,integer
) from public,anon,authenticated;
grant execute on function public.platform_list_business_applications_v95(
  text,text,integer
) to authenticated;
revoke all on function public.create_business(text,text,text,text[])
  from public,anon,authenticated;
grant execute on function public.create_business(text,text,text,text[])
  to authenticated;
revoke all on function public.activate_approved_business_application_v95(
  text,text,uuid
) from public,anon,authenticated;
grant execute on function public.activate_approved_business_application_v95(
  text,text,uuid
) to authenticated;
revoke all on function public.customer_get_locale_preference_v95()
  from public,anon,authenticated;
grant execute on function public.customer_get_locale_preference_v95()
  to authenticated;
revoke all on function public.customer_set_locale_preference_v95(text,bigint)
  from public,anon,authenticated;
grant execute on function public.customer_set_locale_preference_v95(text,bigint)
  to authenticated;
revoke all on function public.business_upsert_customer_content_v95(
  uuid,text,uuid,uuid,boolean,integer,timestamptz,timestamptz,jsonb,bigint
) from public,anon,authenticated;
grant execute on function public.business_upsert_customer_content_v95(
  uuid,text,uuid,uuid,boolean,integer,timestamptz,timestamptz,jsonb,bigint
) to authenticated;
revoke all on function public.business_upsert_localized_copy_v95(
  uuid,text,uuid,text,text,text,text,text,bigint
) from public,anon,authenticated;
grant execute on function public.business_upsert_localized_copy_v95(
  uuid,text,uuid,text,text,text,text,text,bigint
) to authenticated;
revoke all on function public.business_upsert_media_asset_v95(
  uuid,text,uuid,uuid,text,text,integer,integer,text,text,boolean,bigint
) from public,anon,authenticated;
revoke all on function public.business_publish_media_replacement_v95(
  uuid,text,uuid,uuid,text,text,integer,integer,text,text,text,bigint,bigint
) from public,anon,authenticated;
grant execute on function public.business_publish_media_replacement_v95(
  uuid,text,uuid,uuid,text,text,integer,integer,text,text,text,bigint,bigint
) to authenticated;
revoke all on function public.business_queue_media_cleanup_v95(uuid,text,text)
  from public,anon,authenticated;
grant execute on function public.business_queue_media_cleanup_v95(
  uuid,text,text
) to authenticated;
revoke all on function public.business_list_media_cleanup_queue_v95(
  uuid,integer
) from public,anon,authenticated;
grant execute on function public.business_list_media_cleanup_queue_v95(
  uuid,integer
) to authenticated;
revoke all on function public.business_mark_media_cleanup_result_v95(
  uuid,uuid,boolean,text
) from public,anon,authenticated;
grant execute on function public.business_mark_media_cleanup_result_v95(
  uuid,uuid,boolean,text
) to authenticated;
revoke all on function public.business_set_brand_presentation_v95(
  uuid,uuid,uuid,text,bigint
) from public,anon,authenticated;
grant execute on function public.business_set_brand_presentation_v95(
  uuid,uuid,uuid,text,bigint
) to authenticated;
revoke all on function public.business_get_presentation_editor_v95(uuid)
  from public,anon,authenticated;
grant execute on function public.business_get_presentation_editor_v95(uuid)
  to authenticated;
revoke all on function public.customer_get_business_presentation_v95(
  uuid,uuid,text
) from public,anon,authenticated;
grant execute on function public.customer_get_business_presentation_v95(
  uuid,uuid,text
) to authenticated;

commit;
