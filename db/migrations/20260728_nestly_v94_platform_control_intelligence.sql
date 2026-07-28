-- NESTLY v94 — platform approval, workspace controls, subscription enforcement,
-- assigned-consultant reporting and catalogue affinity intelligence.
--
-- Forward-only review candidate. No production action is authorized by this file.

begin;

-- ---------------------------------------------------------------------------
-- 1. Firm approval and workspace control.
-- ---------------------------------------------------------------------------

create table public.business_workspace_controls_v94(
  business_id uuid primary key references public.businesses(id) on delete cascade,
  approval_status text not null
    check(approval_status in ('pending','approved','rejected')),
  version bigint not null default 1 check(version>0),
  decided_by uuid references auth.users(id) on delete set null,
  decided_at timestamptz,
  decision_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint business_workspace_controls_v94_decision_shape check(
    (approval_status='pending' and decided_by is null and decided_at is null
      and decision_reason is null)
    or
    (approval_status in ('approved','rejected') and decided_at is not null
      and length(btrim(decision_reason)) between 3 and 1000)
  )
);

create table public.business_workspace_control_audit_v94(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  actor uuid references auth.users(id) on delete set null,
  event_type text not null
    check(event_type in ('existing_firm_approved','firm_created_pending',
      'firm_approved','firm_rejected')),
  prior_status text,
  new_status text not null,
  reason text not null check(length(btrim(reason)) between 3 and 1000),
  control_version bigint not null check(control_version>0),
  created_at timestamptz not null default now()
);

create index business_workspace_control_audit_v94_business_idx
  on public.business_workspace_control_audit_v94(business_id,created_at desc,id);

alter table public.business_workspace_controls_v94 enable row level security;
alter table public.business_workspace_control_audit_v94 enable row level security;
revoke all privileges on table public.business_workspace_controls_v94
  from public,anon,authenticated;
revoke all privileges on table public.business_workspace_control_audit_v94
  from public,anon,authenticated;

create trigger trg_business_workspace_control_audit_v94_append_only
before update or delete on public.business_workspace_control_audit_v94
for each row execute function app.forbid_mutation();

-- Every firm that exists before v94 is explicitly preserved as approved.
insert into public.business_workspace_controls_v94(
  business_id,approval_status,version,decided_at,decision_reason
)
select id,'approved',1,now(),'v94 existing-firm preservation'
from public.businesses;

insert into public.business_workspace_control_audit_v94(
  business_id,event_type,new_status,reason,control_version
)
select id,'existing_firm_approved','approved',
  'v94 existing-firm preservation',1
from public.businesses;

create or replace function app.seed_business_workspace_control_v94()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  insert into public.business_workspace_controls_v94(
    business_id,approval_status,version
  ) values(new.id,'pending',1);
  insert into public.business_workspace_control_audit_v94(
    business_id,event_type,new_status,reason,control_version
  ) values(
    new.id,'firm_created_pending','pending',
    'new firms require super-admin approval',1
  );
  return new;
end
$$;
revoke all on function app.seed_business_workspace_control_v94()
  from public,anon,authenticated;

create trigger trg_business_workspace_control_v94
after insert on public.businesses
for each row execute function app.seed_business_workspace_control_v94();

-- ---------------------------------------------------------------------------
-- 2. Subscription lifecycle and representative hotline.
-- ---------------------------------------------------------------------------

create table public.platform_consultant_hotlines_v94(
  consultant_id uuid primary key
    references public.platform_consultants(id) on delete cascade,
  hotline_phone text not null
    check(hotline_phone ~ '^\+[1-9][0-9]{7,14}$'),
  version bigint not null default 1 check(version>0),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

create table public.business_subscription_lifecycle_v94(
  business_id uuid primary key references public.businesses(id) on delete cascade,
  state text not null default 'current'
    check(state in ('current','grace','paused')),
  provider_invoice_id text,
  due_date date,
  overdue_day integer check(overdue_day is null or overdue_day>=0),
  workspace_paused boolean not null default false,
  paused_at timestamptz,
  recovered_at timestamptz,
  last_evaluated_on date,
  version bigint not null default 1 check(version>0),
  updated_at timestamptz not null default now(),
  constraint business_subscription_lifecycle_v94_shape check(
    (state='current' and workspace_paused=false and overdue_day is null)
    or
    (state='grace' and workspace_paused=false and overdue_day between 0 and 13
      and provider_invoice_id is not null and due_date is not null)
    or
    (state='paused' and workspace_paused=true and overdue_day>=14
      and provider_invoice_id is not null and due_date is not null
      and paused_at is not null)
  )
);

create table public.business_billing_due_notices_v94(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  provider_invoice_id text not null,
  due_date date not null,
  due_day smallint not null check(due_day between 0 and 14),
  notice_title text not null,
  notice_body text not null,
  consultant_id uuid references public.platform_consultants(id) on delete set null,
  representative_name text,
  hotline_phone text,
  created_at timestamptz not null default now(),
  unique(provider_invoice_id,due_day)
);

create table public.business_subscription_lifecycle_audit_v94(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  event_type text not null
    check(event_type in ('grace_started','workspace_paused','payment_recovered')),
  provider_invoice_id text,
  prior_state text not null,
  new_state text not null,
  overdue_day integer,
  actor uuid references auth.users(id) on delete set null,
  reason text not null check(length(btrim(reason)) between 3 and 1000),
  idempotency_key text,
  created_at timestamptz not null default now(),
  unique(business_id,idempotency_key)
);

create table public.subscription_lifecycle_runs_v94(
  run_date date primary key,
  status text not null check(status in ('running','succeeded','failed')),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  summary jsonb,
  constraint subscription_lifecycle_runs_v94_finish check(
    (status='running' and finished_at is null and summary is null)
    or (status in ('succeeded','failed') and finished_at is not null
      and jsonb_typeof(summary)='object')
  )
);

-- Reuse the business notification bell/realtime surface for billing reminders.
-- The private v94 notice ledger remains the durable delivery/idempotency source.
alter table public.notifications
  drop constraint notifications_kind_check;
alter table public.notifications
  add constraint notifications_kind_check check(kind in(
    'booking_new','booking_waitlisted','change_request','booking_expired',
    'waitlist_ready','subscription_payment_due'
  ));

create index business_billing_due_notices_v94_business_idx
  on public.business_billing_due_notices_v94(business_id,created_at desc,id);
create index business_subscription_lifecycle_audit_v94_business_idx
  on public.business_subscription_lifecycle_audit_v94(
    business_id,created_at desc,id
  );

alter table public.platform_consultant_hotlines_v94 enable row level security;
alter table public.business_subscription_lifecycle_v94 enable row level security;
alter table public.business_billing_due_notices_v94 enable row level security;
alter table public.business_subscription_lifecycle_audit_v94 enable row level security;
alter table public.subscription_lifecycle_runs_v94 enable row level security;
revoke all privileges on table public.platform_consultant_hotlines_v94
  from public,anon,authenticated;
revoke all privileges on table public.business_subscription_lifecycle_v94
  from public,anon,authenticated;
revoke all privileges on table public.business_billing_due_notices_v94
  from public,anon,authenticated;
revoke all privileges on table public.business_subscription_lifecycle_audit_v94
  from public,anon,authenticated;
revoke all privileges on table public.subscription_lifecycle_runs_v94
  from public,anon,authenticated;

create trigger trg_business_billing_due_notices_v94_append_only
before update or delete on public.business_billing_due_notices_v94
for each row execute function app.forbid_mutation();
create trigger trg_business_subscription_lifecycle_audit_v94_append_only
before update or delete on public.business_subscription_lifecycle_audit_v94
for each row execute function app.forbid_mutation();

insert into public.business_subscription_lifecycle_v94(business_id)
select id from public.businesses;

create or replace function app.seed_business_subscription_lifecycle_v94()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  insert into public.business_subscription_lifecycle_v94(business_id)
  values(new.id);
  return new;
end
$$;
revoke all on function app.seed_business_subscription_lifecycle_v94()
  from public,anon,authenticated;

create trigger trg_business_subscription_lifecycle_v94
after insert on public.businesses
for each row execute function app.seed_business_subscription_lifecycle_v94();

create or replace function app.assigned_consultant_v94(p_business uuid)
returns table(
  consultant_id uuid,
  user_id uuid,
  display_name text,
  hotline_phone text
)
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select consultant.id,consultant.user_id,consultant.display_name,
    hotline.hotline_phone
  from public.platform_consultants consultant
  left join public.platform_consultant_hotlines_v94 hotline
    on hotline.consultant_id=consultant.id
  where consultant.active
    and exists(
      select 1
      from public.sme_prospects prospect
      where prospect.converted_business_id=p_business
        and prospect.assigned_consultant_id=consultant.id
    )
  order by consultant.created_at,consultant.id
  limit 1
$$;
revoke all on function app.assigned_consultant_v94(uuid)
  from public,anon,authenticated;

-- ---------------------------------------------------------------------------
-- 3. Platform module overrides and catalogue-intelligence toggle.
-- ---------------------------------------------------------------------------

create table public.platform_module_overrides_v94(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  branch_scope uuid,
  module_key text not null check(module_key ~ '^[a-z][a-z0-9_]*$'),
  mode text not null check(mode in ('inherit','disabled','r','rw')),
  version bigint not null default 1 check(version>0),
  reason text not null check(length(btrim(reason)) between 3 and 1000),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  constraint platform_module_overrides_v94_branch_fk
    foreign key(branch_scope,business_id)
    references public.branches(id,business_id) on delete cascade
);

create unique index platform_module_overrides_v94_branch_uk
  on public.platform_module_overrides_v94(
    business_id,branch_scope,module_key
  ) where branch_scope is not null;
create unique index platform_module_overrides_v94_firm_uk
  on public.platform_module_overrides_v94(business_id,module_key)
  where branch_scope is null;

create table public.platform_module_override_audit_v94(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  branch_scope uuid,
  module_key text not null,
  prior_mode text,
  new_mode text not null,
  prior_version bigint,
  new_version bigint not null,
  reason text not null,
  actor uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table public.business_platform_intelligence_settings_v94(
  business_id uuid primary key references public.businesses(id) on delete cascade,
  catalogue_intelligence_enabled boolean not null default true,
  version bigint not null default 1 check(version>0),
  reason text not null default 'v94 default enabled',
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

create table public.business_checkout_catalogue_settings_v94(
  business_id uuid primary key references public.businesses(id) on delete cascade,
  platform_allowed boolean not null default true,
  owner_enabled boolean not null default true,
  version bigint not null default 1 check(version>0),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

create table public.business_checkout_catalogue_items_v94(
  business_id uuid not null references public.businesses(id) on delete cascade,
  item_type text not null check(item_type in ('service','product')),
  item_id uuid not null,
  checkout_active boolean not null,
  version bigint not null default 1 check(version>0),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key(business_id,item_type,item_id)
);

-- Effective owner checkout state. It is deliberately independent from the
-- platform-only catalogue-intelligence recommendation feature.
alter table public.businesses
  add column quick_earn_catalogue_enabled boolean not null default true;

alter table public.platform_module_overrides_v94 enable row level security;
alter table public.platform_module_override_audit_v94 enable row level security;
alter table public.business_platform_intelligence_settings_v94
  enable row level security;
alter table public.business_checkout_catalogue_settings_v94
  enable row level security;
alter table public.business_checkout_catalogue_items_v94
  enable row level security;
revoke all privileges on table public.platform_module_overrides_v94
  from public,anon,authenticated;
revoke all privileges on table public.platform_module_override_audit_v94
  from public,anon,authenticated;
revoke all privileges on table public.business_platform_intelligence_settings_v94
  from public,anon,authenticated;
revoke all privileges on table public.business_checkout_catalogue_settings_v94
  from public,anon,authenticated;
revoke all privileges on table public.business_checkout_catalogue_items_v94
  from public,anon,authenticated;

create trigger trg_platform_module_override_audit_v94_append_only
before update or delete on public.platform_module_override_audit_v94
for each row execute function app.forbid_mutation();

insert into public.business_platform_intelligence_settings_v94(business_id)
select id from public.businesses;
insert into public.business_checkout_catalogue_settings_v94(business_id)
select id from public.businesses;

create or replace function app.seed_business_platform_intelligence_v94()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  insert into public.business_platform_intelligence_settings_v94(business_id)
  values(new.id);
  insert into public.business_checkout_catalogue_settings_v94(business_id)
  values(new.id);
  return new;
end
$$;
revoke all on function app.seed_business_platform_intelligence_v94()
  from public,anon,authenticated;

create trigger trg_business_platform_intelligence_v94
after insert on public.businesses
for each row execute function app.seed_business_platform_intelligence_v94();

create or replace function app.business_workspace_open_v94(p_business uuid)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select coalesce((
    select control.approval_status='approved'
      and not lifecycle.workspace_paused
    from public.business_workspace_controls_v94 control
    join public.business_subscription_lifecycle_v94 lifecycle
      on lifecycle.business_id=control.business_id
    where control.business_id=p_business
  ),false)
$$;
revoke all on function app.business_workspace_open_v94(uuid)
  from public,anon,authenticated;

create or replace function app.effective_platform_module_mode_v94(
  p_business uuid,p_branch uuid,p_module text
)
returns table(mode text,source text,version bigint)
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_row public.platform_module_overrides_v94%rowtype;
  v_inherit_version bigint;
begin
  if p_module='inventory' then
    return query select 'disabled'::text,'global_inventory_policy'::text,null::bigint;
    return;
  elsif p_module='customerintel' then
    return query select 'disabled'::text,'global_platform_only_policy'::text,null::bigint;
    return;
  end if;
  if p_branch is not null then
    select * into v_row
    from public.platform_module_overrides_v94 override_row
    where override_row.business_id=p_business
      and override_row.branch_scope=p_branch
      and override_row.module_key=p_module;
    if found and v_row.mode<>'inherit' then
      return query select v_row.mode,'branch_override'::text,v_row.version;
      return;
    elsif found then
      v_inherit_version:=v_row.version;
    end if;
  end if;
  select * into v_row
  from public.platform_module_overrides_v94 override_row
  where override_row.business_id=p_business
    and override_row.branch_scope is null
    and override_row.module_key=p_module;
  if found and v_row.mode<>'inherit' then
    return query select v_row.mode,'firm_override'::text,v_row.version;
    return;
  elsif found then
    v_inherit_version:=greatest(
      coalesce(v_inherit_version,0),v_row.version
    );
  end if;
  return query
  select case when p_module=any(business.enabled_modules)
      then 'rw' else 'disabled' end,
    'sector_entitlement'::text,
    v_inherit_version
  from public.businesses business
  where business.id=p_business;
end
$$;
revoke all on function app.effective_platform_module_mode_v94(uuid,uuid,text)
  from public,anon,authenticated;

create or replace function app.staff_module_mode_v94(
  p_business uuid,p_branch uuid,p_module text
)
returns text
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_staff public.staff%rowtype;v_platform text;v_staff_mode text;
begin
  if not app.business_workspace_open_v94(p_business) or p_module='inventory' then
    return 'disabled';
  end if;
  select * into v_staff
  from public.staff staff_row
  where staff_row.business_id=p_business
    and staff_row.user_id=auth.uid()
    and staff_row.active
  order by case when staff_row.role='owner' then 0 else 1 end,
    staff_row.created_at,staff_row.id
  limit 1;
  if not found then return 'disabled';end if;
  if p_branch is not null
     and not app.can_see_branch(p_business,p_branch) then
    return 'disabled';
  end if;
  select resolved.mode into v_platform
  from app.effective_platform_module_mode_v94(
    p_business,p_branch,p_module
  ) resolved;
  if coalesce(v_platform,'disabled')='disabled' then return 'disabled';end if;
  if v_staff.role='owner' then
    return v_platform;
  elsif v_staff.module_perms is not null then
    v_staff_mode:=coalesce(v_staff.module_perms->>p_module,'disabled');
  elsif v_staff.modules is null or p_module=any(v_staff.modules) then
    v_staff_mode:='rw';
  else
    v_staff_mode:='disabled';
  end if;
  if v_staff_mode='disabled' then return 'disabled';end if;
  if v_platform='r' or v_staff_mode='r' then return 'r';end if;
  return 'rw';
end
$$;
revoke all on function app.staff_module_mode_v94(uuid,uuid,text)
  from public,anon,authenticated;

create or replace function app.can_module_read_at_v94(
  p_business uuid,p_branch uuid,p_module text
)
returns boolean language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select app.staff_module_mode_v94(p_business,p_branch,p_module) in ('r','rw')
$$;
create or replace function app.can_module_write_at_v94(
  p_business uuid,p_branch uuid,p_module text
)
returns boolean language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select app.staff_module_mode_v94(p_business,p_branch,p_module)='rw'
$$;
revoke all on function app.can_module_read_at_v94(uuid,uuid,text)
  from public,anon,authenticated;
revoke all on function app.can_module_write_at_v94(uuid,uuid,text)
  from public,anon,authenticated;
grant execute on function app.can_module_read_at_v94(uuid,uuid,text)
  to authenticated;
grant execute on function app.can_module_write_at_v94(uuid,uuid,text)
  to authenticated;

-- Inventory management is intentionally unavailable to firm roles, but an
-- active product remains a valid checkout catalogue item. Keep the existing
-- inventory policy (and all product writes) closed, and add only this narrow
-- sale-catalogue SELECT path for approved staff who can operate Sales or Till.
drop policy if exists products_checkout_catalogue_read_v94 on public.products;
create policy products_checkout_catalogue_read_v94 on public.products
for select to authenticated
using(
  active
  and (
    app.can_module_read_at_v94(business_id,null,'sales')
    or app.can_module_read_at_v94(business_id,null,'till')
  )
);

-- Existing tenant helpers now fail closed when approval or billing closes the
-- workspace. Whole-firm platform overrides are enforced by legacy call sites;
-- branch-aware RPCs can use the v94 *_at helpers.
create or replace function app.is_salon_member(p_salon uuid)
returns boolean language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select app.business_workspace_open_v94(p_salon) and exists(
    select 1 from public.staff staff_row
    where staff_row.business_id=p_salon
      and staff_row.user_id=auth.uid() and staff_row.active
  )
$$;
create or replace function app.is_salon_owner(p_salon uuid)
returns boolean language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select app.business_workspace_open_v94(p_salon) and exists(
    select 1 from public.staff staff_row
    where staff_row.business_id=p_salon
      and staff_row.user_id=auth.uid() and staff_row.active
      and staff_row.role='owner'
  )
$$;
create or replace function app.has_perm(p_business uuid,p_perm text)
returns boolean language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select app.business_workspace_open_v94(p_business) and exists(
    select 1 from public.staff staff_row
    where staff_row.business_id=p_business
      and staff_row.user_id=auth.uid() and staff_row.active
      and p_perm=any(app.role_perms(staff_row.role))
  )
$$;
create or replace function app.can_see_branch(p_business uuid,p_branch uuid)
returns boolean language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select case
    when auth.uid() is null then false
    when app.is_super_admin() then true
    when not app.business_workspace_open_v94(p_business) then false
    else exists(
      select 1 from public.staff staff_row
      where staff_row.business_id=p_business
        and staff_row.user_id=auth.uid() and staff_row.active
        and (
          app.role_class(staff_row.role) in ('owner','admin')
          or (p_branch is not null and exists(
            select 1 from public.staff_branches assignment
            where assignment.business_id=p_business
              and assignment.staff_id=staff_row.id
              and assignment.branch_id=p_branch
          ))
        )
    )
  end
$$;
create or replace function app.staff_can_see_branch(
  p_business uuid,p_branch uuid
)
returns boolean language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$select app.can_see_branch(p_business,p_branch)$$;
create or replace function app.can_module(p_business uuid,p_module text)
returns boolean language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$select app.can_module_read_at_v94(p_business,null,p_module)$$;
create or replace function app.can_module_read(p_business uuid,p_module text)
returns boolean language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$select app.can_module_read_at_v94(p_business,null,p_module)$$;
create or replace function app.can_module_write(p_business uuid,p_module text)
returns boolean language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$select app.can_module_write_at_v94(p_business,null,p_module)$$;

revoke all on function app.is_salon_member(uuid) from public,anon;
revoke all on function app.is_salon_owner(uuid) from public,anon;
revoke all on function app.has_perm(uuid,text) from public,anon;
revoke all on function app.can_see_branch(uuid,uuid) from public,anon;
revoke all on function app.staff_can_see_branch(uuid,uuid) from public,anon;
revoke all on function app.can_module(uuid,text) from public,anon;
revoke all on function app.can_module_read(uuid,text) from public,anon;
revoke all on function app.can_module_write(uuid,text) from public,anon;
grant execute on function app.is_salon_member(uuid) to authenticated;
grant execute on function app.is_salon_owner(uuid) to authenticated;
grant execute on function app.has_perm(uuid,text) to authenticated;
grant execute on function app.can_see_branch(uuid,uuid) to authenticated;
grant execute on function app.staff_can_see_branch(uuid,uuid) to authenticated;
grant execute on function app.can_module(uuid,text) to authenticated;
grant execute on function app.can_module_read(uuid,text) to authenticated;
grant execute on function app.can_module_write(uuid,text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Approval, module and settings RPCs.
-- ---------------------------------------------------------------------------

create or replace function public.platform_decide_business_approval_v94(
  p_business uuid,p_decision text,p_reason text,p_expected_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_actor uuid:=auth.uid();v_control public.business_workspace_controls_v94%rowtype;
  v_prior_status text;
begin
  if not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode='42501';
  end if;
  if p_decision not in ('approved','rejected')
     or length(btrim(coalesce(p_reason,''))) not between 3 and 1000 then
    raise exception 'valid approval decision and reason are required'
      using errcode='22023';
  end if;
  select * into v_control
  from public.business_workspace_controls_v94 control
  where control.business_id=p_business for update;
  if not found then raise exception 'business_control_not_found' using errcode='22023';end if;
  if p_expected_version is null or p_expected_version<>v_control.version then
    raise exception 'business_control_version_conflict' using errcode='40001';
  end if;
  v_prior_status:=v_control.approval_status;
  update public.business_workspace_controls_v94
  set approval_status=p_decision,version=version+1,decided_by=v_actor,
    decided_at=now(),decision_reason=btrim(p_reason),updated_at=now()
  where business_id=p_business returning * into v_control;
  insert into public.business_workspace_control_audit_v94(
    business_id,actor,event_type,prior_status,new_status,reason,control_version
  ) values(
    p_business,v_actor,
    case p_decision when 'approved' then 'firm_approved' else 'firm_rejected' end,
    v_prior_status,p_decision,btrim(p_reason),v_control.version
  );
  return jsonb_build_object(
    'business_id',p_business,'approval_status',v_control.approval_status,
    'workspace_access',app.business_workspace_open_v94(p_business),
    'version',v_control.version,'decided_at',v_control.decided_at,
    'decided_by',v_control.decided_by
  );
end
$$;

create or replace function public.platform_set_module_override_v94(
  p_business uuid,p_branch uuid,p_module text,p_mode text,p_reason text,
  p_expected_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_actor uuid:=auth.uid();v_prior public.platform_module_overrides_v94%rowtype;
  v_row public.platform_module_overrides_v94%rowtype;v_effective record;
begin
  if not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode='42501';
  end if;
  if p_module is null or p_module!~'^[a-z][a-z0-9_]*$'
     or p_mode not in ('inherit','disabled','r','rw')
     or length(btrim(coalesce(p_reason,''))) not between 3 and 1000 then
    raise exception 'valid module override is required' using errcode='22023';
  end if;
  if p_branch is not null and not exists(
    select 1 from public.branches branch
    where branch.id=p_branch and branch.business_id=p_business
  ) then raise exception 'branch_not_in_business' using errcode='22023';end if;
  select * into v_prior from public.platform_module_overrides_v94 override_row
  where override_row.business_id=p_business
    and override_row.branch_scope is not distinct from p_branch
    and override_row.module_key=p_module for update;
  if found then
    if p_expected_version is null or p_expected_version<>v_prior.version then
      raise exception 'module_override_version_conflict' using errcode='40001';
    end if;
    update public.platform_module_overrides_v94
    set mode=p_mode,version=version+1,reason=btrim(p_reason),
      updated_by=v_actor,updated_at=now()
    where business_id=p_business
      and branch_scope is not distinct from p_branch
      and module_key=p_module returning * into v_row;
  else
    if p_expected_version is not null then
      raise exception 'module_override_version_conflict' using errcode='40001';
    end if;
    insert into public.platform_module_overrides_v94(
      business_id,branch_scope,module_key,mode,reason,updated_by
    ) values(p_business,p_branch,p_module,p_mode,btrim(p_reason),v_actor)
    returning * into v_row;
  end if;
  insert into public.platform_module_override_audit_v94(
    business_id,branch_scope,module_key,prior_mode,new_mode,prior_version,
    new_version,reason,actor
  ) values(
    p_business,p_branch,p_module,v_prior.mode,p_mode,v_prior.version,
    v_row.version,btrim(p_reason),v_actor
  );
  select * into v_effective
  from app.effective_platform_module_mode_v94(p_business,p_branch,p_module);
  return jsonb_build_object(
    'business_id',p_business,'branch_id',p_branch,'module_key',p_module,
    'mode',p_mode,'version',v_row.version,
    'effective_mode',v_effective.mode,'source',v_effective.source
  );
end
$$;

create or replace function public.platform_get_effective_modules_v94(
  p_business uuid,p_branch uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_modules jsonb;
begin
  if not app.v89_platform_can('sectors','r') then
    raise exception 'platform_module_access_required' using errcode='42501';
  end if;
  if p_branch is not null and not exists(
    select 1 from public.branches branch
    where branch.id=p_branch and branch.business_id=p_business
  ) then raise exception 'branch_not_in_business' using errcode='22023';end if;
  with module_keys as (
    select unnest(business.enabled_modules) module_key
    from public.businesses business where business.id=p_business
    union select module_key from public.platform_module_overrides_v94
      where business_id=p_business
    union select 'inventory'
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'module_key',module_key,'mode',resolved.mode,'source',resolved.source,
    'version',resolved.version
  ) order by module_key),'[]'::jsonb)
  into v_modules
  from module_keys
  cross join lateral app.effective_platform_module_mode_v94(
    p_business,p_branch,module_keys.module_key
  ) resolved;
  return jsonb_build_object(
    'business_id',p_business,'branch_id',p_branch,
    'workspace_access',app.business_workspace_open_v94(p_business),
    'inventory_global_disabled',true,'modules',v_modules
  );
end
$$;

create or replace function public.platform_set_catalogue_intelligence_v94(
  p_business uuid,p_enabled boolean,p_reason text,p_expected_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_row public.business_platform_intelligence_settings_v94%rowtype;
begin
  if not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode='42501';
  end if;
  if p_enabled is null or length(btrim(coalesce(p_reason,''))) not between 3 and 1000 then
    raise exception 'valid catalogue setting and reason are required' using errcode='22023';
  end if;
  select * into v_row from public.business_platform_intelligence_settings_v94
  where business_id=p_business for update;
  if not found then raise exception 'business_not_found' using errcode='22023';end if;
  if p_expected_version is null or p_expected_version<>v_row.version then
    raise exception 'catalogue_setting_version_conflict' using errcode='40001';
  end if;
  update public.business_platform_intelligence_settings_v94
  set catalogue_intelligence_enabled=p_enabled,version=version+1,
    reason=btrim(p_reason),updated_by=auth.uid(),updated_at=now()
  where business_id=p_business returning * into v_row;
  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values(
    p_business,auth.uid(),'CATALOGUE_INTELLIGENCE_SET_V94',
    'businesses',p_business,jsonb_build_object(
      'enabled',p_enabled,'version',v_row.version,'reason',btrim(p_reason)
    )
  );
  return jsonb_build_object(
    'business_id',p_business,
    'catalogue_intelligence_enabled',v_row.catalogue_intelligence_enabled,
    'version',v_row.version,'updated_at',v_row.updated_at
  );
end
$$;

create or replace function public.business_get_checkout_catalogue_v94(
  p_business uuid,p_branch uuid,p_include_inactive boolean
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_branch uuid:=p_branch;
  v_setting public.business_checkout_catalogue_settings_v94%rowtype;
  v_branches jsonb;
  v_items jsonb;
begin
  if p_include_inactive is null then
    raise exception 'include_inactive_required' using errcode='22023';
  end if;
  if v_branch is null then
    select branch.id into v_branch
    from public.branches branch
    where branch.business_id=p_business and branch.active
    order by branch.is_default desc,branch.created_at,branch.id
    limit 1;
  end if;
  if v_branch is null or not exists(
    select 1 from public.branches branch
    where branch.id=v_branch and branch.business_id=p_business and branch.active
  ) then
    raise exception 'active_branch_required' using errcode='22023';
  end if;
  if not (
    app.is_super_admin()
    or app.can_module_read_at_v94(p_business,v_branch,'sales')
    or app.can_module_read_at_v94(p_business,v_branch,'till')
  ) then
    raise exception 'checkout_catalogue_access_required' using errcode='42501';
  end if;
  if p_include_inactive and not (
    app.is_super_admin() or app.is_salon_owner(p_business)
  ) then
    raise exception 'owner_required_for_inactive_catalogue' using errcode='42501';
  end if;
  select * into v_setting
  from public.business_checkout_catalogue_settings_v94
  where business_id=p_business;
  if not found then
    raise exception 'business_not_found' using errcode='22023';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',branch.id,'name',branch.name,'is_default',branch.is_default
  ) order by branch.is_default desc,branch.name,branch.id),'[]'::jsonb)
  into v_branches
  from public.branches branch
  where branch.business_id=p_business and branch.active
    and (
      app.is_super_admin()
      or app.can_see_branch(p_business,branch.id)
    );
  with catalogue as (
    select
      'service'::text item_type,service.id item_id,service.name,
      service.price_cents unit_cents,service.active source_active,
      coalesce(item.checkout_active,true) checkout_active,
      (
        not exists(
          select 1 from public.service_branches configured
          where configured.business_id=p_business
            and configured.service_id=service.id
        )
        or exists(
          select 1 from public.service_branches available
          where available.business_id=p_business
            and available.service_id=service.id
            and available.branch_id=v_branch
        )
      ) branch_available,
      coalesce(item.version,0) version
    from public.services service
    left join public.business_checkout_catalogue_items_v94 item
      on item.business_id=p_business and item.item_type='service'
      and item.item_id=service.id
    where service.business_id=p_business
    union all
    select
      'product'::text,product.id,product.name,
      product.retail_price_cents,product.active,
      coalesce(item.checkout_active,true),true,
      coalesce(item.version,0)
    from public.products product
    left join public.business_checkout_catalogue_items_v94 item
      on item.business_id=p_business and item.item_type='product'
      and item.item_id=product.id
    where product.business_id=p_business
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'item_type',item_type,'item_id',item_id,'name',name,
    'unit_cents',unit_cents,'checkout_active',checkout_active,
    'branch_available',branch_available,'version',version
  ) order by item_type,name,item_id),'[]'::jsonb)
  into v_items
  from catalogue
  where p_include_inactive
     or (source_active and checkout_active and branch_available);
  return jsonb_build_object(
    'platform_allowed',v_setting.platform_allowed,
    'enabled',v_setting.platform_allowed and v_setting.owner_enabled,
    'settings_version',v_setting.version,
    'selected_branch_id',v_branch,
    'branches',v_branches,
    'items',v_items
  );
end
$$;

create or replace function public.business_set_checkout_catalogue_enabled_v94(
  p_business uuid,p_enabled boolean,p_expected_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_setting public.business_checkout_catalogue_settings_v94%rowtype;
begin
  if not app.is_salon_owner(p_business) and not app.is_super_admin() then
    raise exception 'owner_required' using errcode='42501';
  end if;
  if p_enabled is null or p_expected_version is null then
    raise exception 'enabled_and_expected_version_required' using errcode='22023';
  end if;
  select * into v_setting
  from public.business_checkout_catalogue_settings_v94
  where business_id=p_business for update;
  if not found then raise exception 'business_not_found' using errcode='22023';end if;
  if v_setting.version<>p_expected_version then
    raise exception 'checkout_catalogue_version_conflict' using errcode='40001';
  end if;
  update public.business_checkout_catalogue_settings_v94
  set owner_enabled=p_enabled,version=version+1,
    updated_by=auth.uid(),updated_at=now()
  where business_id=p_business returning * into v_setting;
  update public.businesses
  set quick_earn_catalogue_enabled=(
    v_setting.platform_allowed and v_setting.owner_enabled
  ) where id=p_business;
  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values(
    p_business,auth.uid(),'CHECKOUT_CATALOGUE_ENABLED_SET_V94',
    'businesses',p_business,jsonb_build_object(
      'owner_enabled',v_setting.owner_enabled,
      'platform_allowed',v_setting.platform_allowed,
      'effective_enabled',
        v_setting.platform_allowed and v_setting.owner_enabled,
      'version',v_setting.version
    )
  );
  return jsonb_build_object(
    'business_id',p_business,
    'platform_allowed',v_setting.platform_allowed,
    'enabled',v_setting.platform_allowed and v_setting.owner_enabled,
    'settings_version',v_setting.version
  );
end
$$;

create or replace function public.business_set_checkout_catalogue_item_v94(
  p_business uuid,p_item_type text,p_item uuid,p_active boolean,
  p_expected_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_item public.business_checkout_catalogue_items_v94%rowtype;
begin
  if not app.is_salon_owner(p_business) and not app.is_super_admin() then
    raise exception 'owner_required' using errcode='42501';
  end if;
  if p_item_type not in ('service','product') or p_item is null
     or p_active is null or p_expected_version is null
  then
    raise exception 'valid_item_type_item_active_and_version_required'
      using errcode='22023';
  end if;
  if (
    p_item_type='service' and not exists(
      select 1 from public.services service
      where service.id=p_item and service.business_id=p_business
    )
  ) or (
    p_item_type='product' and not exists(
      select 1 from public.products product
      where product.id=p_item and product.business_id=p_business
    )
  ) then
    raise exception 'catalogue_item_not_in_business' using errcode='22023';
  end if;
  select * into v_item
  from public.business_checkout_catalogue_items_v94 item
  where item.business_id=p_business and item.item_type=p_item_type
    and item.item_id=p_item
  for update;
  if found then
    if v_item.version<>p_expected_version then
      raise exception 'checkout_catalogue_item_version_conflict'
        using errcode='40001';
    end if;
    update public.business_checkout_catalogue_items_v94
    set checkout_active=p_active,version=version+1,
      updated_by=auth.uid(),updated_at=now()
    where business_id=p_business and item_type=p_item_type and item_id=p_item
    returning * into v_item;
  else
    if p_expected_version<>0 then
      raise exception 'checkout_catalogue_item_version_conflict'
        using errcode='40001';
    end if;
    insert into public.business_checkout_catalogue_items_v94(
      business_id,item_type,item_id,checkout_active,updated_by
    ) values(p_business,p_item_type,p_item,p_active,auth.uid())
    returning * into v_item;
  end if;
  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values(
    p_business,auth.uid(),'CHECKOUT_CATALOGUE_ITEM_SET_V94',
    p_item_type,p_item,jsonb_build_object(
      'checkout_active',v_item.checkout_active,'version',v_item.version
    )
  );
  return jsonb_build_object(
    'business_id',p_business,'item_type',v_item.item_type,
    'item_id',v_item.item_id,'checkout_active',v_item.checkout_active,
    'version',v_item.version
  );
end
$$;

create or replace function public.platform_set_consultant_hotline_v94(
  p_consultant uuid,p_phone text,p_expected_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_row public.platform_consultant_hotlines_v94%rowtype;v_name text;
begin
  if not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode='42501';
  end if;
  if p_phone is null or p_phone!~'^\+[1-9][0-9]{7,14}$' then
    raise exception 'hotline_must_be_e164' using errcode='22023';
  end if;
  select display_name into v_name from public.platform_consultants
  where id=p_consultant and active;
  if not found then raise exception 'active_consultant_not_found' using errcode='22023';end if;
  select * into v_row from public.platform_consultant_hotlines_v94
  where consultant_id=p_consultant for update;
  if found then
    if p_expected_version is null or p_expected_version<>v_row.version then
      raise exception 'hotline_version_conflict' using errcode='40001';
    end if;
    update public.platform_consultant_hotlines_v94
    set hotline_phone=p_phone,version=version+1,updated_by=auth.uid(),updated_at=now()
    where consultant_id=p_consultant returning * into v_row;
  else
    if p_expected_version is not null then
      raise exception 'hotline_version_conflict' using errcode='40001';
    end if;
    insert into public.platform_consultant_hotlines_v94(
      consultant_id,hotline_phone,updated_by
    ) values(p_consultant,p_phone,auth.uid()) returning * into v_row;
  end if;
  return jsonb_build_object(
    'consultant_id',p_consultant,'display_name',v_name,
    'hotline_phone',v_row.hotline_phone,'version',v_row.version
  );
end
$$;

-- ---------------------------------------------------------------------------
-- 5. Billing lifecycle runner/readers.
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

create or replace function public.run_subscription_lifecycle_v94(
  p_as_of date default ((now() at time zone 'Asia/Singapore')::date)
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if not app.is_super_admin()
     and coalesce(auth.jwt()->>'role','')<>'service_role' then
    raise exception 'subscription_lifecycle_runner_required' using errcode='42501';
  end if;
  return app.run_subscription_lifecycle_v94(p_as_of);
end
$$;

create or replace function app.reconcile_subscription_payment_v94(
  p_business uuid,p_idempotency_key text,p_reason text,p_actor uuid,
  p_fail_if_unpaid boolean
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_prior public.business_subscription_lifecycle_v94%rowtype;v_result jsonb;
begin
  if length(btrim(coalesce(p_idempotency_key,'')))<8
     or length(btrim(coalesce(p_reason,''))) not between 3 and 1000 then
    raise exception 'valid recovery idempotency and reason are required'
      using errcode='22023';
  end if;
  select * into v_prior from public.business_subscription_lifecycle_v94
  where business_id=p_business for update;
  if not found then raise exception 'business_not_found' using errcode='22023';end if;
  select jsonb_build_object(
    'business_id',p_business,'outcome','replayed','replayed',true,
    'state',audit.new_state,'workspace_paused',audit.new_state='paused',
    'recovered_at',audit.created_at
  ) into v_result
  from public.business_subscription_lifecycle_audit_v94 audit
  where audit.business_id=p_business
    and audit.idempotency_key=btrim(p_idempotency_key);
  if v_result is not null then return v_result;end if;
  if exists(
    select 1 from public.billing_provider_invoices invoice
    where invoice.business_id=p_business and invoice.paid_normalized=false
      and invoice.status in ('open','uncollectible')
      and invoice.amount_remaining_cents>0 and invoice.due_at is not null
      and invoice.due_at<=now()
  ) then
    if p_fail_if_unpaid then
      raise exception 'provider_invoice_still_unpaid' using errcode='23514';
    end if;
    return jsonb_build_object(
      'business_id',p_business,'outcome','still_overdue','replayed',false,
      'state',v_prior.state,'workspace_paused',v_prior.workspace_paused
    );
  end if;
  if v_prior.state='current' then
    return jsonb_build_object(
      'business_id',p_business,'outcome','already_current','replayed',false,
      'state','current','workspace_paused',false,'recovered_at',v_prior.recovered_at
    );
  end if;
  update public.business_subscription_lifecycle_v94
  set state='current',provider_invoice_id=null,due_date=null,overdue_day=null,
    workspace_paused=false,paused_at=null,recovered_at=now(),
    version=version+1,updated_at=now()
  where business_id=p_business;
  insert into public.business_subscription_lifecycle_audit_v94(
    business_id,event_type,provider_invoice_id,prior_state,new_state,
    actor,reason,idempotency_key
  ) values(
    p_business,'payment_recovered',v_prior.provider_invoice_id,
    v_prior.state,'current',p_actor,btrim(p_reason),btrim(p_idempotency_key)
  );
  return jsonb_build_object(
    'business_id',p_business,'outcome','recovered','replayed',false,
    'state','current','workspace_paused',false,'recovered_at',now()
  );
end
$$;
revoke all on function app.reconcile_subscription_payment_v94(
  uuid,text,text,uuid,boolean
) from public,anon,authenticated;

create or replace function public.platform_reconcile_subscription_payment_v94(
  p_business uuid,p_idempotency_key text,p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode='42501';
  end if;
  return app.reconcile_subscription_payment_v94(
    p_business,p_idempotency_key,p_reason,auth.uid(),true
  );
end
$$;

-- Stripe is the source of truth for a successful provider payment. Preserve
-- v77's durable inbox/idempotency semantics, then reconcile the workspace in
-- the same server-side command so recovery does not wait for the next cron.
alter function public.apply_stripe_billing_event_v77(text)
  rename to apply_stripe_billing_event_v94_base;

create or replace function public.apply_stripe_billing_event_v77(p_event_id text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_result jsonb;
  v_event public.billing_provider_events%rowtype;
  v_recovery jsonb;
begin
  v_result:=public.apply_stripe_billing_event_v94_base(p_event_id);
  select * into v_event
  from public.billing_provider_events event_row
  where event_row.provider='stripe' and event_row.event_id=p_event_id;
  if v_event.event_type='invoice.paid'
     and coalesce(v_result->>'status','')='processed'
     and v_event.business_id is not null
  then
    v_recovery:=app.reconcile_subscription_payment_v94(
      v_event.business_id,
      'stripe-paid:'||p_event_id,
      'Stripe invoice.paid recovered the subscription workspace',
      null,false
    );
    v_result:=v_result||jsonb_build_object(
      'subscription_lifecycle',v_recovery
    );
  elsif v_event.event_type='invoice.paid'
        and coalesce(v_result->>'duplicate','false')='true'
        and v_event.business_id is not null
  then
    v_recovery:=app.reconcile_subscription_payment_v94(
      v_event.business_id,
      'stripe-paid:'||p_event_id,
      'Stripe invoice.paid recovered the subscription workspace',
      null,false
    );
    v_result:=v_result||jsonb_build_object(
      'subscription_lifecycle',v_recovery
    );
  end if;
  return v_result;
end
$$;
revoke all on function public.apply_stripe_billing_event_v94_base(text)
  from public,anon,authenticated,service_role;
revoke all on function public.apply_stripe_billing_event_v77(text)
  from public,anon,authenticated;
grant execute on function public.apply_stripe_billing_event_v77(text)
  to service_role;

-- ---------------------------------------------------------------------------
-- 6. Assigned-consultant platform intelligence.
-- ---------------------------------------------------------------------------

create or replace function app.platform_firm_report_access_v94(p_business uuid)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select app.v89_platform_can('reports','r')
    or exists(
      select 1 from app.assigned_consultant_v94(p_business) consultant
      where consultant.user_id=auth.uid()
    )
$$;
revoke all on function app.platform_firm_report_access_v94(uuid)
  from public,anon,authenticated;

create or replace function public.platform_get_business_control_v94(
  p_business uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_result jsonb;
begin
  if not app.is_super_admin()
     and not app.platform_firm_report_access_v94(p_business)
     and not exists(
       select 1 from public.staff active_staff
       where active_staff.business_id=p_business
         and active_staff.user_id=auth.uid()
         and active_staff.active
     ) then
    raise exception 'business_control_access_required' using errcode='42501';
  end if;
  select jsonb_build_object(
    'business_id',business.id,
    'approval',jsonb_build_object(
      'status',control.approval_status,'version',control.version,
      'decided_at',control.decided_at,'decided_by',control.decided_by,
      'reason',control.decision_reason
    ),
    'subscription',jsonb_build_object(
      'state',lifecycle.state,'due_date',lifecycle.due_date,
      'overdue_day',lifecycle.overdue_day,
      'workspace_paused',lifecycle.workspace_paused,
      'paused_at',lifecycle.paused_at,'recovered_at',lifecycle.recovered_at,
      'version',lifecycle.version
    ),
    'workspace_access',app.business_workspace_open_v94(business.id),
    'representative',case when representative.consultant_id is null then null
      else jsonb_build_object(
        'consultant_id',representative.consultant_id,
        'display_name',representative.display_name,
        'hotline_phone',representative.hotline_phone
      ) end,
    'catalogue_intelligence',jsonb_build_object(
      'enabled',setting.catalogue_intelligence_enabled,
      'version',setting.version,'updated_at',setting.updated_at
    ),
    'quick_earn_catalogue_enabled',
      checkout_setting.platform_allowed and checkout_setting.owner_enabled,
    'checkout_catalogue',jsonb_build_object(
      'platform_allowed',checkout_setting.platform_allowed,
      'owner_enabled',checkout_setting.owner_enabled,
      'enabled',
        checkout_setting.platform_allowed and checkout_setting.owner_enabled,
      'version',checkout_setting.version,
      'updated_at',checkout_setting.updated_at
    )
  ) into v_result
  from public.businesses business
  join public.business_workspace_controls_v94 control
    on control.business_id=business.id
  join public.business_subscription_lifecycle_v94 lifecycle
    on lifecycle.business_id=business.id
  join public.business_platform_intelligence_settings_v94 setting
    on setting.business_id=business.id
  join public.business_checkout_catalogue_settings_v94 checkout_setting
    on checkout_setting.business_id=business.id
  left join lateral app.assigned_consultant_v94(business.id) representative
    on true
  where business.id=p_business;
  if v_result is null then raise exception 'business_not_found' using errcode='22023';end if;
  return v_result;
end
$$;

create or replace function public.get_business_subscription_lifecycle_v94(
  p_business uuid
)
returns jsonb language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select public.platform_get_business_control_v94(p_business)->'subscription'
    || jsonb_build_object(
      'business_id',p_business,
      'representative',
        public.platform_get_business_control_v94(p_business)->'representative'
    )
$$;

-- Persona discovery must retain blocked firms. Otherwise a pending or
-- payment-paused owner can be misrouted into onboarding and create a duplicate
-- business. This is discovery metadata only; every workspace data path remains
-- protected by app.business_workspace_open_v94().
create or replace function public.get_my_personas()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_staff jsonb:='[]'::jsonb;
  v_customer jsonb:='[]'::jsonb;
  v_default_route text:='#/';
begin
  if v_actor is null then
    raise exception 'authenticated session required' using errcode='28000';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'business_id',business.id,
    'business_slug',business.slug,
    'business_name',business.name,
    'role',staff_row.role,
    'modules',app.staff_modules(staff_row.business_id),
    'workspace_access',app.business_workspace_open_v94(business.id),
    'approval_status',control.approval_status,
    'subscription_state',lifecycle.state,
    'workspace_paused',lifecycle.workspace_paused,
    'representative_name',representative.display_name,
    'representative_hotline',representative.hotline_phone
  ) order by business.name,business.slug),'[]'::jsonb)
  into v_staff
  from public.staff staff_row
  join public.businesses business on business.id=staff_row.business_id
  join public.business_workspace_controls_v94 control
    on control.business_id=business.id
  join public.business_subscription_lifecycle_v94 lifecycle
    on lifecycle.business_id=business.id
  left join lateral app.assigned_consultant_v94(business.id) representative
    on true
  where staff_row.user_id=v_actor and staff_row.active;
  if app.platform_feature_enabled('customer_identity')
     and app.platform_feature_enabled('customer_claims')
     and app.platform_feature_enabled('customer_wallet') then
    select coalesce(jsonb_agg(jsonb_build_object(
      'business_slug',business.slug,
      'business_name',business.name
    ) order by business.name,business.slug),'[]'::jsonb)
    into v_customer
    from public.customer_identities identity_row
    join public.customer_links link
      on link.identity_id=identity_row.id
      and link.auth_user_id=v_actor and link.state='verified'
    join public.businesses business on business.id=link.business_id
    where identity_row.auth_user_id=v_actor
      and identity_row.status='active';
  end if;
  if jsonb_array_length(v_staff)>0 then
    v_default_route:='#/workspace/'||(v_staff->0->>'business_slug')||'/dashboard';
  elsif jsonb_array_length(v_customer)>0 then
    v_default_route:='#/wallet';
  elsif app.platform_feature_enabled('customer_identity') then
    v_default_route:='#/claim';
  end if;
  return jsonb_build_object(
    'staff',v_staff,'customer',v_customer,'default_route',v_default_route
  );
end
$$;
revoke all privileges on function public.get_my_personas()
  from public,anon,authenticated;
grant execute on function public.get_my_personas() to authenticated;

create or replace function public.platform_get_assigned_firm_report_v94(
  p_business uuid,p_branch uuid,p_from date,p_to date
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_result jsonb;v_from timestamptz;v_to timestamptz;
begin
  if not app.platform_firm_report_access_v94(p_business) then
    raise exception 'assigned_platform_report_access_required' using errcode='42501';
  end if;
  if p_from is null or p_to is null or p_from>p_to or p_to-p_from>1826 then
    raise exception 'invalid_report_window' using errcode='22023';
  end if;
  if p_branch is not null and not exists(
    select 1 from public.branches branch
    where branch.id=p_branch and branch.business_id=p_business
  ) then raise exception 'branch_not_in_business' using errcode='22023';end if;
  v_from:=p_from::timestamp at time zone 'Asia/Singapore';
  v_to:=(p_to+1)::timestamp at time zone 'Asia/Singapore';
  with valid_sales as (
    select sale.*
    from public.sales sale
    where sale.business_id=p_business and sale.reversal_of is null
      and sale.occurred_at>=v_from and sale.occurred_at<v_to
      and (p_branch is null or sale.branch_id=p_branch)
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id=sale.business_id
          and reversal.reversal_of=sale.id
      )
  ), customer_metrics as (
    select client.id,count(valid_sales.id) purchases,
      coalesce(sum(valid_sales.amount_cents),0) revenue_cents,
      max(valid_sales.occurred_at) last_purchase_at
    from public.clients client
    left join valid_sales on valid_sales.client_id=client.id
    where client.business_id=p_business and client.is_synthetic=false
    group by client.id
  )
  select jsonb_build_object(
    'scope',jsonb_build_object(
      'business_id',business.id,'business_name',business.name,
      'branch_id',p_branch,'from',p_from,'to',p_to
    ),
    'kpis',jsonb_build_object(
      'net_revenue_cents',coalesce((select sum(amount_cents)
        from valid_sales where counts_as_revenue),0),
      'visits',(select count(*) from valid_sales where counts_as_visit),
      'active_customers',(select count(*) from customer_metrics where purchases>0),
      'returning_customers',(select count(*) from customer_metrics where purchases>=2),
      'average_order_cents',coalesce((select round(avg(amount_cents))::bigint
        from valid_sales where counts_as_revenue),0)
    ),
    'customer_intelligence',jsonb_build_object(
      'total_customers',(select count(*) from customer_metrics),
      'customers_with_purchase',(select count(*) from customer_metrics where purchases>0),
      'customers_over_90_days_inactive',(select count(*) from customer_metrics
        where last_purchase_at<now()-interval '90 days'),
      'top_customer_revenue_cents',coalesce((select max(revenue_cents)
        from customer_metrics),0)
    ),
    'data_quality',jsonb_build_object(
      'synthetic_excluded',true,'reversed_sales_excluded',true,
      'timezone','Asia/Singapore'
    )
  ) into v_result
  from public.businesses business where business.id=p_business;
  return v_result;
end
$$;

create or replace function public.platform_get_catalogue_affinity_v94(
  p_business uuid,p_branch uuid,p_from date,p_to date,p_limit integer default 25
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_pairs jsonb;v_enabled boolean;v_from timestamptz;v_to timestamptz;
begin
  if not app.platform_firm_report_access_v94(p_business) then
    raise exception 'assigned_platform_report_access_required' using errcode='42501';
  end if;
  if p_limit not between 1 and 100 or p_from is null or p_to is null
     or p_from>p_to or p_to-p_from>1826 then
    raise exception 'invalid_affinity_request' using errcode='22023';
  end if;
  if p_branch is not null and not exists(
    select 1 from public.branches branch
    where branch.id=p_branch and branch.business_id=p_business
  ) then raise exception 'branch_not_in_business' using errcode='22023';end if;
  select catalogue_intelligence_enabled into v_enabled
  from public.business_platform_intelligence_settings_v94
  where business_id=p_business;
  if not coalesce(v_enabled,false) then
    return jsonb_build_object(
      'scope',jsonb_build_object('business_id',p_business,'branch_id',p_branch,
        'from',p_from,'to',p_to),
      'enabled',false,'summary',jsonb_build_object('pair_count',0),
      'pairs','[]'::jsonb
    );
  end if;
  v_from:=p_from::timestamp at time zone 'Asia/Singapore';
  v_to:=(p_to+1)::timestamp at time zone 'Asia/Singapore';
  with valid_sales as (
    select sale.id
    from public.sales sale
    where sale.business_id=p_business and sale.reversal_of is null
      and sale.occurred_at>=v_from and sale.occurred_at<v_to
      and (p_branch is null or sale.branch_id=p_branch)
      and not exists(select 1 from public.sales reversal
        where reversal.business_id=sale.business_id
          and reversal.reversal_of=sale.id)
  ), service_orders as (
    select item.ref_id service_id,count(distinct item.sale_id) orders
    from public.sale_items item join valid_sales sale on sale.id=item.sale_id
    where item.business_id=p_business and item.item_type='service'
      and item.ref_id is not null group by item.ref_id
  ), pairs as (
    select service_item.ref_id service_id,service.name service_name,
      product_item.ref_id product_id,product.name product_name,
      count(distinct service_item.sale_id) orders_together,
      max(service_orders.orders) service_orders,
      sum(product_item.qty) product_units,
      sum(product_item.line_cents) paired_revenue_cents
    from public.sale_items service_item
    join public.sale_items product_item
      on product_item.business_id=service_item.business_id
      and product_item.sale_id=service_item.sale_id
      and product_item.item_type='retail'
    join valid_sales sale on sale.id=service_item.sale_id
    join public.services service
      on service.id=service_item.ref_id and service.business_id=p_business
    join public.products product
      on product.id=product_item.ref_id and product.business_id=p_business
    join service_orders on service_orders.service_id=service_item.ref_id
    where service_item.business_id=p_business
      and service_item.item_type='service'
    group by service_item.ref_id,service.name,product_item.ref_id,product.name
    order by orders_together desc,service_item.ref_id,product_item.ref_id
    limit p_limit
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'service_id',service_id,'service_name',service_name,
    'product_id',product_id,'product_name',product_name,
    'orders_together',orders_together,'service_orders',service_orders,
    'attach_rate_pct',round(orders_together::numeric*100/nullif(service_orders,0),2),
    'product_units',product_units,'paired_revenue_cents',paired_revenue_cents
  ) order by orders_together desc,service_id,product_id),'[]'::jsonb)
  into v_pairs from pairs;
  return jsonb_build_object(
    'scope',jsonb_build_object('business_id',p_business,'branch_id',p_branch,
      'from',p_from,'to',p_to),
    'enabled',true,
    'summary',jsonb_build_object('pair_count',jsonb_array_length(v_pairs)),
    'pairs',v_pairs
  );
end
$$;

create or replace function public.platform_get_consultative_recommendations_v94(
  p_business uuid,p_branch uuid,p_from date,p_to date,p_limit integer default 25
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_affinity jsonb;v_report jsonb;v_recommendations jsonb:='[]'::jsonb;
  v_pair jsonb;v_active_products integer;v_product_sales integer;
begin
  v_report:=public.platform_get_assigned_firm_report_v94(
    p_business,p_branch,p_from,p_to
  );
  v_affinity:=public.platform_get_catalogue_affinity_v94(
    p_business,p_branch,p_from,p_to,p_limit
  );
  if not (v_affinity->>'enabled')::boolean then
    return jsonb_build_object(
      'scope',v_affinity->'scope','generated_at',now(),
      'recommendations','[]'::jsonb,'disabled_reason','catalogue_intelligence_disabled'
    );
  end if;
  select count(*) into v_active_products from public.products
  where business_id=p_business and active;
  select coalesce(sum((pair->>'product_units')::integer),0)
  into v_product_sales from jsonb_array_elements(v_affinity->'pairs') pair;
  select value into v_pair from jsonb_array_elements(v_affinity->'pairs')
  order by (value->>'orders_together')::integer desc limit 1;
  if v_pair is not null then
    v_recommendations:=v_recommendations||jsonb_build_array(jsonb_build_object(
      'priority','high','category','cross_sell',
      'title','Bundle the strongest service and product pair',
      'evidence',v_pair,
      'recommended_action','Offer the product during booking, checkout and follow-up for this service.'
    ));
  end if;
  if v_active_products>0 and v_product_sales=0 then
    v_recommendations:=v_recommendations||jsonb_build_array(jsonb_build_object(
      'priority','high','category','catalogue_activation',
      'title','Active products are not attaching to service sales',
      'evidence',jsonb_build_object('active_products',v_active_products,'paired_units',0),
      'recommended_action','Select one relevant product per top service and add a staff checkout prompt.'
    ));
  end if;
  if coalesce((v_report#>>'{kpis,returning_customers}')::integer,0)=0
     and coalesce((v_report#>>'{kpis,active_customers}')::integer,0)>0 then
    v_recommendations:=v_recommendations||jsonb_build_array(jsonb_build_object(
      'priority','medium','category','retention',
      'title','Turn first visits into a second purchase',
      'evidence',jsonb_build_object(
        'active_customers',v_report#>'{kpis,active_customers}',
        'returning_customers',v_report#>'{kpis,returning_customers}'
      ),
      'recommended_action','Create a time-bound follow-up offer tied to the purchased service.'
    ));
  end if;
  return jsonb_build_object(
    'scope',v_affinity->'scope','generated_at',now(),
    'recommendations',v_recommendations
  );
end
$$;

-- Final deterministic reporting contract. Cohort boundaries are tied to the
-- requested report end date, never wall-clock time, so reruns are reproducible.
create or replace function public.platform_get_assigned_firm_report_v94(
  p_business uuid,p_branch uuid,p_from date,p_to date
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_result jsonb;v_from timestamptz;v_to timestamptz;
begin
  if not app.platform_firm_report_access_v94(p_business) then
    raise exception 'assigned_platform_report_access_required' using errcode='42501';
  end if;
  if p_from is null or p_to is null or p_from>p_to or p_to-p_from>1826 then
    raise exception 'invalid_report_window' using errcode='22023';
  end if;
  if p_branch is not null and not exists(
    select 1 from public.branches branch
    where branch.id=p_branch and branch.business_id=p_business
  ) then raise exception 'branch_not_in_business' using errcode='22023';end if;
  v_from:=p_from::timestamp at time zone 'Asia/Singapore';
  v_to:=(p_to+1)::timestamp at time zone 'Asia/Singapore';
  with valid_sales as (
    select sale.*
    from public.sales sale
    where sale.business_id=p_business and sale.reversal_of is null
      and sale.occurred_at>=v_from and sale.occurred_at<v_to
      and (p_branch is null or sale.branch_id=p_branch)
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id=sale.business_id
          and reversal.reversal_of=sale.id
      )
  ), customer_metrics as (
    select client.id,count(valid_sales.id) purchases,
      coalesce(sum(valid_sales.amount_cents),0) revenue_cents,
      min(valid_sales.occurred_at) first_purchase_at,
      max(valid_sales.occurred_at) last_purchase_at
    from public.clients client
    left join valid_sales on valid_sales.client_id=client.id
    where client.business_id=p_business and client.is_synthetic=false
    group by client.id
  ), classified as (
    select customer_metrics.*,
      case
        when purchases=1
          and first_purchase_at>=(p_to-29)::timestamp at time zone 'Asia/Singapore'
          then 'new'
        when purchases>=5
          and last_purchase_at>=(p_to-29)::timestamp at time zone 'Asia/Singapore'
          then 'champions'
        when purchases>=2
          and last_purchase_at>=(p_to-59)::timestamp at time zone 'Asia/Singapore'
          then 'loyal'
        when purchases>=2
          and last_purchase_at>=(p_to-89)::timestamp at time zone 'Asia/Singapore'
          then 'at_risk'
        when last_purchase_at<(p_to-89)::timestamp at time zone 'Asia/Singapore'
          then 'lapsed'
        else 'other'
      end cohort
    from customer_metrics
  ), preference_rows as (
    select item.item_type,item.ref_id,
      coalesce(
        max(case when item.item_type='service' then service.name
                 when item.item_type='retail' then product.name end),
        max(item.description),'Unlabelled item'
      ) item_name,
      count(distinct item.sale_id) orders,sum(item.qty) units,
      sum(item.line_cents) revenue_cents
    from public.sale_items item
    join valid_sales sale on sale.id=item.sale_id
    left join public.services service
      on item.item_type='service' and service.id=item.ref_id
        and service.business_id=p_business
    left join public.products product
      on item.item_type='retail' and product.id=item.ref_id
        and product.business_id=p_business
    where item.business_id=p_business
      and item.item_type in ('service','retail')
    group by item.item_type,item.ref_id
  ), ranked_preferences as (
    select preference_rows.*,
      row_number() over(
        partition by item_type
        order by orders desc,revenue_cents desc,ref_id nulls last,item_name
      ) preference_rank
    from preference_rows
  ), preferences as (
    select
      coalesce(jsonb_agg(jsonb_build_object(
        'item_id',ref_id,'name',item_name,'orders',orders,'units',units,
        'revenue_cents',revenue_cents
      ) order by preference_rank) filter(
        where item_type='service' and preference_rank<=5
      ),'[]'::jsonb) services,
      coalesce(jsonb_agg(jsonb_build_object(
        'item_id',ref_id,'name',item_name,'orders',orders,'units',units,
        'revenue_cents',revenue_cents
      ) order by preference_rank) filter(
        where item_type='retail' and preference_rank<=5
      ),'[]'::jsonb) products
    from ranked_preferences
  )
  select jsonb_build_object(
    'scope',jsonb_build_object(
      'business_id',business.id,'business_name',business.name,
      'branch_id',p_branch,'from',p_from,'to',p_to
    ),
    'kpis',jsonb_build_object(
      'net_revenue_cents',coalesce((select sum(amount_cents)
        from valid_sales where counts_as_revenue),0),
      'visits',(select count(*) from valid_sales where counts_as_visit),
      'active_customers',(select count(*) from customer_metrics where purchases>0),
      'returning_customers',(select count(*) from customer_metrics where purchases>=2),
      'average_order_cents',coalesce((select round(avg(amount_cents))::bigint
        from valid_sales where counts_as_revenue),0)
    ),
    'cohorts',jsonb_build_object(
      'definitions',jsonb_build_object(
        'champions','5+ purchases; last purchase in final 30 days',
        'loyal','2-4 purchases; last purchase in final 60 days',
        'at_risk','2+ purchases; last purchase 61-90 days before report end',
        'new','exactly 1 purchase; first purchase in final 30 days',
        'lapsed','last purchase more than 90 days before report end',
        'other','does not meet a named cohort'
      ),
      'counts',jsonb_build_object(
        'champions',(select count(*) from classified where cohort='champions'),
        'loyal',(select count(*) from classified where cohort='loyal'),
        'at_risk',(select count(*) from classified where cohort='at_risk'),
        'new',(select count(*) from classified where cohort='new'),
        'lapsed',(select count(*) from classified where cohort='lapsed'),
        'other',(select count(*) from classified where cohort='other')
      )
    ),
    'preferences',jsonb_build_object(
      'services',preferences.services,'products',preferences.products
    ),
    'customer_intelligence',jsonb_build_object(
      'total_customers',(select count(*) from customer_metrics),
      'customers_with_purchase',(select count(*) from customer_metrics where purchases>0),
      'customers_over_90_days_inactive',(select count(*) from classified
        where cohort='lapsed'),
      'top_customer_revenue_cents',coalesce((select max(revenue_cents)
        from customer_metrics),0)
    ),
    'data_quality',jsonb_build_object(
      'synthetic_excluded',true,'reversed_sales_excluded',true,
      'timezone','Asia/Singapore','cohort_anchor',p_to
    )
  ) into v_result
  from public.businesses business cross join preferences
  where business.id=p_business;
  return v_result;
end
$$;

create or replace function public.platform_get_catalogue_affinity_v94(
  p_business uuid,p_branch uuid,p_from date,p_to date,p_limit integer default 25
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_pairs jsonb:='[]'::jsonb;v_enabled boolean;v_from timestamptz;v_to timestamptz;
  v_transactions integer;v_customers integer;v_weeks integer;
  v_reasons jsonb:='[]'::jsonb;v_ready boolean;
begin
  if not app.platform_firm_report_access_v94(p_business) then
    raise exception 'assigned_platform_report_access_required' using errcode='42501';
  end if;
  if p_limit not between 1 and 100 or p_from is null or p_to is null
     or p_from>p_to or p_to-p_from>1826 then
    raise exception 'invalid_affinity_request' using errcode='22023';
  end if;
  if p_branch is not null and not exists(
    select 1 from public.branches branch
    where branch.id=p_branch and branch.business_id=p_business
  ) then raise exception 'branch_not_in_business' using errcode='22023';end if;
  select catalogue_intelligence_enabled into v_enabled
  from public.business_platform_intelligence_settings_v94
  where business_id=p_business;
  v_from:=p_from::timestamp at time zone 'Asia/Singapore';
  v_to:=(p_to+1)::timestamp at time zone 'Asia/Singapore';
  with valid_sales as (
    select sale.id,sale.client_id,sale.occurred_at
    from public.sales sale
    where sale.business_id=p_business and sale.reversal_of is null
      and sale.occurred_at>=v_from and sale.occurred_at<v_to
      and (p_branch is null or sale.branch_id=p_branch)
      and not exists(select 1 from public.sales reversal
        where reversal.business_id=sale.business_id
          and reversal.reversal_of=sale.id)
  )
  select count(*),count(distinct client_id),
    count(distinct date_trunc('week',occurred_at at time zone 'Asia/Singapore'))
  into v_transactions,v_customers,v_weeks from valid_sales;
  if not coalesce(v_enabled,false) then
    v_reasons:=v_reasons||jsonb_build_array('catalogue_intelligence_disabled');
  end if;
  if v_transactions<20 then
    v_reasons:=v_reasons||jsonb_build_array('minimum_20_transactions_required');
  end if;
  if v_customers<10 then
    v_reasons:=v_reasons||jsonb_build_array('minimum_10_customers_required');
  end if;
  if v_weeks<4 then
    v_reasons:=v_reasons||jsonb_build_array('minimum_4_active_weeks_required');
  end if;
  v_ready:=jsonb_array_length(v_reasons)=0;
  if v_ready then
    with valid_sales as (
      select sale.id
      from public.sales sale
      where sale.business_id=p_business and sale.reversal_of is null
        and sale.occurred_at>=v_from and sale.occurred_at<v_to
        and (p_branch is null or sale.branch_id=p_branch)
        and not exists(select 1 from public.sales reversal
          where reversal.business_id=sale.business_id
            and reversal.reversal_of=sale.id)
    ), service_orders as (
      select item.ref_id service_id,count(distinct item.sale_id) orders
      from public.sale_items item join valid_sales sale on sale.id=item.sale_id
      where item.business_id=p_business and item.item_type='service'
        and item.ref_id is not null group by item.ref_id
    ), pairs as (
      select service_item.ref_id service_id,service.name service_name,
        product_item.ref_id product_id,product.name product_name,
        count(distinct service_item.sale_id) support_orders,
        max(service_orders.orders) sample_orders,
        sum(product_item.qty) product_units,
        sum(product_item.line_cents) paired_revenue_cents
      from public.sale_items service_item
      join public.sale_items product_item
        on product_item.business_id=service_item.business_id
        and product_item.sale_id=service_item.sale_id
        and product_item.item_type='retail'
      join valid_sales sale on sale.id=service_item.sale_id
      join public.services service
        on service.id=service_item.ref_id and service.business_id=p_business
      join public.products product
        on product.id=product_item.ref_id and product.business_id=p_business
      join service_orders on service_orders.service_id=service_item.ref_id
      where service_item.business_id=p_business
        and service_item.item_type='service'
      group by service_item.ref_id,service.name,product_item.ref_id,product.name
      having count(distinct service_item.sale_id)>=3
        and count(distinct service_item.sale_id)::numeric
          /nullif(max(service_orders.orders),0)>=0.10
      order by support_orders desc,service_item.ref_id,product_item.ref_id
      limit p_limit
    )
    select coalesce(jsonb_agg(jsonb_build_object(
      'service_id',service_id,'service_name',service_name,
      'product_id',product_id,'product_name',product_name,
      'support_orders',support_orders,'sample_orders',sample_orders,
      'confidence_pct',
        round(support_orders::numeric*100/nullif(sample_orders,0),2),
      'product_units',product_units,
      'paired_revenue_cents',paired_revenue_cents
    ) order by support_orders desc,service_id,product_id),'[]'::jsonb)
    into v_pairs from pairs;
  end if;
  return jsonb_build_object(
    'scope',jsonb_build_object('business_id',p_business,'branch_id',p_branch,
      'from',p_from,'to',p_to),
    'enabled',coalesce(v_enabled,false),
    'readiness',jsonb_build_object(
      'ready',v_ready,
      'thresholds',jsonb_build_object(
        'transactions',20,'customers',10,'active_weeks',4,
        'pair_support_orders',3,'pair_confidence_pct',10
      ),
      'observed',jsonb_build_object(
        'transactions',v_transactions,'customers',v_customers,
        'active_weeks',v_weeks
      ),
      'suppression_reasons',v_reasons
    ),
    'summary',jsonb_build_object('pair_count',jsonb_array_length(v_pairs)),
    'pairs',v_pairs
  );
end
$$;

create or replace function public.platform_get_consultative_recommendations_v94(
  p_business uuid,p_branch uuid,p_from date,p_to date,p_limit integer default 25
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_affinity jsonb;v_recommendations jsonb:='[]'::jsonb;
  v_pair jsonb;v_reasons jsonb;
begin
  v_affinity:=public.platform_get_catalogue_affinity_v94(
    p_business,p_branch,p_from,p_to,p_limit
  );
  v_reasons:=v_affinity#>'{readiness,suppression_reasons}';
  if not coalesce((v_affinity#>>'{readiness,ready}')::boolean,false) then
    return jsonb_build_object(
      'scope',v_affinity->'scope','generated_at',now(),
      'readiness',v_affinity->'readiness',
      'suppression_reasons',v_reasons,
      'recommendations','[]'::jsonb
    );
  end if;
  select value into v_pair
  from jsonb_array_elements(v_affinity->'pairs')
  order by (value->>'support_orders')::integer desc,
    (value->>'confidence_pct')::numeric desc
  limit 1;
  if v_pair is null then
    v_reasons:=jsonb_build_array('no_pair_meets_evidence_threshold');
  else
    v_recommendations:=jsonb_build_array(jsonb_build_object(
      'priority','high','category','cross_sell',
      'title','Bundle the strongest service and product pair',
      'evidence',jsonb_build_object(
        'service_id',v_pair->'service_id',
        'product_id',v_pair->'product_id',
        'support_orders',v_pair->'support_orders',
        'sample_orders',v_pair->'sample_orders',
        'confidence_pct',v_pair->'confidence_pct'
      ),
      'recommended_action',
        'Offer the product during booking, checkout and follow-up for this service.'
    ));
  end if;
  return jsonb_build_object(
    'scope',v_affinity->'scope','generated_at',now(),
    'readiness',v_affinity->'readiness',
    'suppression_reasons',v_reasons,
    'recommendations',v_recommendations
  );
end
$$;

-- ---------------------------------------------------------------------------
-- 7. Branch-aware enforcement at the real operational entry points.
-- ---------------------------------------------------------------------------

create or replace function app.require_branch_module_v94(
  p_business uuid,p_branch uuid,p_module text,p_mode text
)
returns uuid
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_branch uuid:=p_branch;
begin
  if v_branch is null then
    select branch.id into v_branch
    from public.branches branch
    where branch.business_id=p_business and branch.active
    order by branch.is_default desc,branch.created_at,branch.id
    limit 1;
  end if;
  if v_branch is null or not exists(
    select 1 from public.branches branch
    where branch.id=v_branch and branch.business_id=p_business and branch.active
  ) then
    raise exception 'active_branch_required' using errcode='22023';
  end if;
  if not app.is_super_admin() and (
    (p_mode='r' and not app.can_module_read_at_v94(
      p_business,v_branch,p_module
    ))
    or
    (p_mode='rw' and not app.can_module_write_at_v94(
      p_business,v_branch,p_module
    ))
  ) then
    raise exception 'branch_module_access_required:%:%',p_module,p_mode
      using errcode='42501';
  end if;
  return v_branch;
end
$$;
revoke all on function app.require_branch_module_v94(uuid,uuid,text,text)
  from public,anon,authenticated;

alter function public.book_appointment_smart_v47(
  uuid,uuid,uuid,uuid,timestamptz,integer,uuid,text,text,text
) rename to book_appointment_smart_v47_v94_base;
alter function public.suggest_appointment_staff_v47(
  uuid,uuid,uuid,timestamptz,integer,integer
) rename to suggest_appointment_staff_v47_v94_base;
alter function public.reschedule_appointment_v48(
  uuid,uuid,timestamptz,integer,uuid,text,uuid
) rename to reschedule_appointment_v48_v94_base;
alter function public.set_appointment_status_v47(uuid,uuid,text)
  rename to set_appointment_status_v47_v94_base;
alter function public.staff_decide_booking_request_v73(
  uuid,uuid,text,uuid
) rename to staff_decide_booking_request_v73_v94_base;
alter function public.get_reports_summary(uuid,date,date,uuid)
  rename to get_reports_summary_v94_base;

create or replace function public.book_appointment_smart_v47(
  p_business uuid,p_client uuid,p_branch uuid,p_service uuid,
  p_starts timestamptz,p_duration_minutes integer,p_requested_staff uuid,
  p_assignment_mode text,p_note text,p_idempotency_key text
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  perform app.require_branch_module_v94(
    p_business,p_branch,'appointments','rw'
  );
  return public.book_appointment_smart_v47_v94_base(
    p_business,p_client,p_branch,p_service,p_starts,p_duration_minutes,
    p_requested_staff,p_assignment_mode,p_note,p_idempotency_key
  );
end
$$;

create or replace function public.suggest_appointment_staff_v47(
  p_business uuid,p_branch uuid,p_service uuid,p_starts timestamptz,
  p_duration_minutes integer,p_limit integer default 5
) returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  perform app.require_branch_module_v94(
    p_business,p_branch,'appointments','r'
  );
  return public.suggest_appointment_staff_v47_v94_base(
    p_business,p_branch,p_service,p_starts,p_duration_minutes,p_limit
  );
end
$$;

create or replace function public.reschedule_appointment_v48(
  p_business uuid,p_appointment uuid,p_starts timestamptz,
  p_duration_minutes integer,p_staff uuid,p_note text,
  p_idempotency_key uuid
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_branch uuid;
begin
  select branch_id into v_branch from public.appointments
  where id=p_appointment and business_id=p_business;
  perform app.require_branch_module_v94(
    p_business,v_branch,'appointments','rw'
  );
  return public.reschedule_appointment_v48_v94_base(
    p_business,p_appointment,p_starts,p_duration_minutes,p_staff,p_note,
    p_idempotency_key
  );
end
$$;

create or replace function public.set_appointment_status_v47(
  p_business uuid,p_appointment uuid,p_status text
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_branch uuid;
begin
  select branch_id into v_branch from public.appointments
  where id=p_appointment and business_id=p_business;
  perform app.require_branch_module_v94(
    p_business,v_branch,'appointments','rw'
  );
  return public.set_appointment_status_v47_v94_base(
    p_business,p_appointment,p_status
  );
end
$$;

create or replace function public.staff_decide_booking_request_v73(
  p_business uuid,p_request uuid,p_decision text,p_branch uuid default null
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_branch uuid;
begin
  v_branch:=app.require_branch_module_v94(
    p_business,p_branch,'bookings','rw'
  );
  if p_decision='confirm' then
    perform app.require_branch_module_v94(
      p_business,v_branch,'appointments','rw'
    );
  end if;
  return public.staff_decide_booking_request_v73_v94_base(
    p_business,p_request,p_decision,v_branch
  );
end
$$;

create or replace function public.get_reports_summary(
  p_business uuid,p_from date,p_to date,p_branch uuid default null
) returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_branch uuid:=p_branch;
begin
  if v_branch is not null then
    perform app.require_branch_module_v94(
      p_business,v_branch,'reports','r'
    );
  elsif not app.is_super_admin() then
    if not app.can_module_read_at_v94(p_business,null,'reports') then
      raise exception 'branch_module_access_required:reports:r'
        using errcode='42501';
    end if;
    if exists(
      select 1
      from public.branches branch
      where branch.business_id=p_business
        and branch.active
        and (
          not app.can_see_branch(p_business,branch.id)
          or not app.can_module_read_at_v94(
            p_business,branch.id,'reports'
          )
        )
    ) then
      raise exception 'explicit_branch_required_for_partial_report_scope'
        using errcode='42501';
    end if;
  end if;
  return public.get_reports_summary_v94_base(
    p_business,p_from,p_to,p_branch
  );
end
$$;

revoke all on function public.book_appointment_smart_v47(
  uuid,uuid,uuid,uuid,timestamptz,integer,uuid,text,text,text
) from public,anon,authenticated;
revoke all on function public.suggest_appointment_staff_v47(
  uuid,uuid,uuid,timestamptz,integer,integer
) from public,anon,authenticated;
revoke all on function public.reschedule_appointment_v48(
  uuid,uuid,timestamptz,integer,uuid,text,uuid
) from public,anon,authenticated;
revoke all on function public.set_appointment_status_v47(uuid,uuid,text)
  from public,anon,authenticated;
revoke all on function public.staff_decide_booking_request_v73(
  uuid,uuid,text,uuid
) from public,anon,authenticated;
revoke all on function public.get_reports_summary(uuid,date,date,uuid)
  from public,anon,authenticated;

grant execute on function public.book_appointment_smart_v47(
  uuid,uuid,uuid,uuid,timestamptz,integer,uuid,text,text,text
) to authenticated;
grant execute on function public.suggest_appointment_staff_v47(
  uuid,uuid,uuid,timestamptz,integer,integer
) to authenticated;
grant execute on function public.reschedule_appointment_v48(
  uuid,uuid,timestamptz,integer,uuid,text,uuid
) to authenticated;
grant execute on function public.set_appointment_status_v47(uuid,uuid,text)
  to authenticated;
grant execute on function public.staff_decide_booking_request_v73(
  uuid,uuid,text,uuid
) to authenticated;
grant execute on function public.get_reports_summary(uuid,date,date,uuid)
  to authenticated;

revoke all on function public.book_appointment_smart_v47_v94_base(
  uuid,uuid,uuid,uuid,timestamptz,integer,uuid,text,text,text
) from public,anon,authenticated,service_role;
revoke all on function public.suggest_appointment_staff_v47_v94_base(
  uuid,uuid,uuid,timestamptz,integer,integer
) from public,anon,authenticated,service_role;
revoke all on function public.reschedule_appointment_v48_v94_base(
  uuid,uuid,timestamptz,integer,uuid,text,uuid
) from public,anon,authenticated,service_role;
revoke all on function public.set_appointment_status_v47_v94_base(
  uuid,uuid,text
) from public,anon,authenticated,service_role;
revoke all on function public.staff_decide_booking_request_v73_v94_base(
  uuid,uuid,text,uuid
) from public,anon,authenticated,service_role;
revoke all on function public.get_reports_summary_v94_base(
  uuid,date,date,uuid
) from public,anon,authenticated,service_role;

-- Financial and loyalty writers remain byte-owned by their sanctioned kernel
-- migrations. Branch module enforcement is applied at their immutable row
-- boundaries so v94 cannot fork or shadow the checkout/redemption algorithms.
-- The two legacy redemption entry points carry no branch and therefore cannot
-- satisfy a branch override. Browser execution is retired; v93's explicit
-- branch-scoped merchant scanner remains the supported path and can still call
-- these functions internally under its definer authority.
revoke execute on function public.redeem_points(uuid,uuid,text)
  from authenticated;
revoke execute on function public.redeem_reward(uuid,uuid,uuid,text)
  from authenticated;
revoke execute on function public.redeem_reward_at_context(
  uuid,uuid,uuid,text,uuid,uuid,uuid
) from authenticated;

create or replace function app.enforce_branch_module_row_v94()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if auth.uid() is null or app.is_super_admin() then
    return new;
  end if;
  perform app.require_branch_module_v94(
    new.business_id,new.branch_id,tg_argv[0],tg_argv[1]
  );
  if tg_nargs>=4 and (
    tg_nargs=4
    or to_jsonb(new)->>'kind'=tg_argv[4]
  ) then
    perform app.require_branch_module_v94(
      new.business_id,new.branch_id,tg_argv[2],tg_argv[3]
    );
  end if;
  return new;
end
$$;
revoke all on function app.enforce_branch_module_row_v94()
  from public,anon,authenticated;

create trigger trg_sales_branch_module_v94
before insert or update on public.sales
for each row execute function app.enforce_branch_module_row_v94(
  'sales','rw','till','rw','quick_sale'
);
create trigger trg_checkout_evaluations_branch_module_v94
before insert or update on public.checkout_evaluations
for each row execute function app.enforce_branch_module_row_v94(
  'sales','rw','till','rw'
);
create trigger trg_customer_birthday_redemptions_branch_module_v94
before insert or update on public.customer_birthday_redemptions
for each row execute function app.enforce_branch_module_row_v94('loyalty','rw');

create or replace function app.enforce_loyalty_redemption_branch_v94()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_branch uuid;
begin
  if auth.uid() is null or app.is_super_admin() then
    return new;
  end if;
  v_branch:=nullif(
    new.eligibility_snapshot#>>'{selected,branch_id}',''
  )::uuid;
  if v_branch is null then
    raise exception 'active_branch_required' using errcode='42501';
  end if;
  perform app.require_branch_module_v94(
    new.business_id,v_branch,'loyalty','rw'
  );
  return new;
end
$$;
revoke all on function app.enforce_loyalty_redemption_branch_v94()
  from public,anon,authenticated;
create trigger trg_loyalty_redemptions_branch_module_v94
before insert on public.loyalty_redemptions
for each row execute function app.enforce_loyalty_redemption_branch_v94();

create or replace function app.enforce_redemption_completion_branch_v94()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_branch uuid;
begin
  if auth.uid() is null or app.is_super_admin()
     or old.status<>'pending' or new.status<>'completed' then
    return new;
  end if;
  v_branch:=nullif(new.completion_result->>'branch_id','')::uuid;
  perform app.require_branch_module_v94(
    new.business_id,v_branch,'loyalty','rw'
  );
  return new;
end
$$;
revoke all on function app.enforce_redemption_completion_branch_v94()
  from public,anon,authenticated;
create trigger trg_redemption_completion_branch_module_v94
before update on public.customer_redemption_intents_v89
for each row execute function app.enforce_redemption_completion_branch_v94();

drop policy if exists sales_v94_branch_module_select on public.sales;
create policy sales_v94_branch_module_select on public.sales
as restrictive for select to authenticated
using(
  app.is_super_admin()
  or app.can_module_read_at_v94(business_id,branch_id,'sales')
);
drop policy if exists appointments_v94_branch_module_select
  on public.appointments;
create policy appointments_v94_branch_module_select on public.appointments
as restrictive for select to authenticated
using(
  app.is_super_admin()
  or app.can_module_read_at_v94(business_id,branch_id,'appointments')
);

-- v83 tenant customer-intelligence readers are retired from browser roles.
-- Platform reporting uses the assignment-scoped, aggregate v94 contracts.
revoke all on function public.get_customer_intelligence_v83(
  uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid
) from public,anon,authenticated;
revoke all on function public.create_customer_intelligence_export_v83(
  uuid,uuid,date,date
) from public,anon,authenticated;
revoke all on function public.get_customer_intelligence_export_page_v83(
  uuid,integer,integer
) from public,anon,authenticated;
grant execute on function public.get_customer_intelligence_v83(
  uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid
) to service_role;
grant execute on function public.create_customer_intelligence_export_v83(
  uuid,uuid,date,date
) to service_role;
grant execute on function public.get_customer_intelligence_export_page_v83(
  uuid,integer,integer
) to service_role;

-- Keep literal finite ACL declarations visible to the migration preflight.
revoke all on function public.platform_decide_business_approval_v94(
  uuid,text,text,bigint
) from public,anon,authenticated;
revoke all on function public.platform_set_module_override_v94(
  uuid,uuid,text,text,text,bigint
) from public,anon,authenticated;
revoke all on function public.platform_get_effective_modules_v94(
  uuid,uuid
) from public,anon,authenticated;
revoke all on function public.platform_set_catalogue_intelligence_v94(
  uuid,boolean,text,bigint
) from public,anon,authenticated;
revoke all on function public.business_get_checkout_catalogue_v94(
  uuid,uuid,boolean
) from public,anon,authenticated;
revoke all on function public.business_set_checkout_catalogue_enabled_v94(
  uuid,boolean,bigint
) from public,anon,authenticated;
revoke all on function public.business_set_checkout_catalogue_item_v94(
  uuid,text,uuid,boolean,bigint
) from public,anon,authenticated;
revoke all on function public.platform_set_consultant_hotline_v94(
  uuid,text,bigint
) from public,anon,authenticated;
revoke all on function public.run_subscription_lifecycle_v94(date)
  from public,anon,authenticated;
revoke all on function public.platform_reconcile_subscription_payment_v94(
  uuid,text,text
) from public,anon,authenticated;
revoke all on function public.platform_get_business_control_v94(uuid)
  from public,anon,authenticated;
revoke all on function public.get_business_subscription_lifecycle_v94(uuid)
  from public,anon,authenticated;
revoke all on function public.platform_get_assigned_firm_report_v94(
  uuid,uuid,date,date
) from public,anon,authenticated;
revoke all on function public.platform_get_catalogue_affinity_v94(
  uuid,uuid,date,date,integer
) from public,anon,authenticated;
revoke all on function public.platform_get_consultative_recommendations_v94(
  uuid,uuid,date,date,integer
) from public,anon,authenticated;
grant execute on function public.platform_decide_business_approval_v94(
  uuid,text,text,bigint
) to authenticated;
grant execute on function public.platform_set_module_override_v94(
  uuid,uuid,text,text,text,bigint
) to authenticated;
grant execute on function public.platform_get_effective_modules_v94(
  uuid,uuid
) to authenticated;
grant execute on function public.platform_set_catalogue_intelligence_v94(
  uuid,boolean,text,bigint
) to authenticated;
grant execute on function public.business_get_checkout_catalogue_v94(
  uuid,uuid,boolean
) to authenticated;
grant execute on function public.business_set_checkout_catalogue_enabled_v94(
  uuid,boolean,bigint
) to authenticated;
grant execute on function public.business_set_checkout_catalogue_item_v94(
  uuid,text,uuid,boolean,bigint
) to authenticated;
grant execute on function public.platform_set_consultant_hotline_v94(
  uuid,text,bigint
) to authenticated;
grant execute on function public.run_subscription_lifecycle_v94(date)
  to authenticated;
grant execute on function public.platform_reconcile_subscription_payment_v94(
  uuid,text,text
) to authenticated;
grant execute on function public.platform_get_business_control_v94(uuid)
  to authenticated;
grant execute on function public.get_business_subscription_lifecycle_v94(uuid)
  to authenticated;
grant execute on function public.platform_get_assigned_firm_report_v94(
  uuid,uuid,date,date
) to authenticated;
grant execute on function public.platform_get_catalogue_affinity_v94(
  uuid,uuid,date,date,integer
) to authenticated;
grant execute on function public.platform_get_consultative_recommendations_v94(
  uuid,uuid,date,date,integer
) to authenticated;

-- Browser-facing ACL: finite RPC surface only.
do $acl$
declare v_signature regprocedure;
begin
  foreach v_signature in array array[
    'public.platform_decide_business_approval_v94(uuid,text,text,bigint)'::regprocedure,
    'public.platform_set_module_override_v94(uuid,uuid,text,text,text,bigint)'::regprocedure,
    'public.platform_get_effective_modules_v94(uuid,uuid)'::regprocedure,
    'public.platform_set_catalogue_intelligence_v94(uuid,boolean,text,bigint)'::regprocedure,
    'public.business_get_checkout_catalogue_v94(uuid,uuid,boolean)'::regprocedure,
    'public.business_set_checkout_catalogue_enabled_v94(uuid,boolean,bigint)'::regprocedure,
    'public.business_set_checkout_catalogue_item_v94(uuid,text,uuid,boolean,bigint)'::regprocedure,
    'public.platform_set_consultant_hotline_v94(uuid,text,bigint)'::regprocedure,
    'public.run_subscription_lifecycle_v94(date)'::regprocedure,
    'public.platform_reconcile_subscription_payment_v94(uuid,text,text)'::regprocedure,
    'public.platform_get_business_control_v94(uuid)'::regprocedure,
    'public.get_business_subscription_lifecycle_v94(uuid)'::regprocedure,
    'public.platform_get_assigned_firm_report_v94(uuid,uuid,date,date)'::regprocedure,
    'public.platform_get_catalogue_affinity_v94(uuid,uuid,date,date,integer)'::regprocedure,
    'public.platform_get_consultative_recommendations_v94(uuid,uuid,date,date,integer)'::regprocedure
  ] loop
    execute format('revoke all on function %s from public,anon,authenticated',
      v_signature);
    execute format('grant execute on function %s to authenticated',v_signature);
  end loop;
end
$acl$;

grant execute on function public.run_subscription_lifecycle_v94(date)
  to service_role;

-- Cron invokes the private core directly. Schedule only when pg_cron is present;
-- this keeps local/rehearsal chains extension-optional.
do $cron$
begin
  if to_regnamespace('cron') is not null
     and to_regprocedure('cron.schedule(text,text,text)') is not null then
    if exists(
      select 1 from cron.job
      where jobname='nestly-v94-subscription-lifecycle-daily'
    ) then
      perform cron.unschedule('nestly-v94-subscription-lifecycle-daily');
    end if;
    perform cron.schedule(
      'nestly-v94-subscription-lifecycle-daily',
      '15 0 * * *',
      $command$select app.run_subscription_lifecycle_v94(
        (now() at time zone 'Asia/Singapore')::date
      )$command$
    );
  end if;
end
$cron$;

comment on function public.platform_get_assigned_firm_report_v94(
  uuid,uuid,date,date
) is 'Platform-only, assignment-scoped aggregate customer intelligence; no tenant-role access and no customer PII.';
comment on function public.platform_get_catalogue_affinity_v94(
  uuid,uuid,date,date,integer
) is 'Platform-only service/product co-purchase affinity for assigned consultants and platform report readers.';

commit;
