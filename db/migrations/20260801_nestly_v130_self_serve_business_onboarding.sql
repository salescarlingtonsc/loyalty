-- NESTLY v130 - SELF-SERVICE BUSINESS OWNER ONBOARDING
--
-- A confirmed owner account may stage exactly one locked workspace, choose a
-- server-priced subscription and enter hosted Stripe Checkout. Access opens
-- only after the signed provider event pipeline records a matching paid
-- invoice and V124 fixes the immutable 30-day money-back window.

begin;

alter table public.business_workspace_control_audit_v94
  drop constraint business_workspace_control_audit_v94_event_type_check;
alter table public.business_workspace_control_audit_v94
  add constraint business_workspace_control_audit_v94_event_type_check
  check(event_type in (
    'existing_firm_approved','firm_created_pending','firm_approved',
    'firm_rejected','application_activated','self_service_started',
    'self_service_payment_confirmed'
  ));

create table public.self_serve_business_onboarding_v130(
  business_id uuid primary key
    references public.businesses(id) on delete cascade,
  owner_user_id uuid not null unique
    references auth.users(id) on delete restrict,
  owner_staff_id uuid not null unique
    references public.staff(id) on delete restrict,
  default_branch_id uuid not null unique
    references public.branches(id) on delete restrict,
  bundle_version_id uuid not null
    references public.sector_bundle_versions(id) on delete restrict,
  setup_idempotency_key uuid not null unique,
  request_hash text not null check(request_hash~'^[0-9a-f]{64}$'),
  owner_name text not null check(length(btrim(owner_name)) between 2 and 120),
  owner_email text not null check(owner_email=lower(owner_email)),
  business_name text not null check(length(btrim(business_name)) between 2 and 160),
  business_slug text not null unique
    check(business_slug~'^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  sector_key text not null references public.sector_profiles(sector_key),
  registration_number text,
  preferred_locale text not null default 'en'
    check(preferred_locale in ('en','zh-CN','ms')),
  selected_cadence text not null check(selected_cadence in ('monthly','annual')),
  selected_customer_capacity integer not null check(
    selected_customer_capacity>=1000 and selected_customer_capacity%1000=0
  ),
  billing_catalog_id_v124 uuid not null
    references public.billing_plan_catalog_v124(id) on delete restrict,
  checkout_command_id uuid unique
    references public.billing_commands(id) on delete restrict,
  legal_document_version text not null default '2026-08-01',
  legal_accepted_at timestamptz not null,
  status text not null default 'payment_pending'
    check(status in ('payment_pending','active')),
  activation_invoice_id text,
  activated_at timestamptz,
  version bigint not null default 1 check(version>0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint self_serve_business_onboarding_v130_activation_shape check(
    (status='payment_pending' and activation_invoice_id is null and activated_at is null)
    or
    (status='active' and activation_invoice_id is not null and activated_at is not null)
  ),
  constraint self_serve_business_onboarding_v130_registration_shape check(
    registration_number is null
    or length(btrim(registration_number)) between 3 and 80
  )
);

create index self_serve_business_onboarding_v130_status_idx
  on public.self_serve_business_onboarding_v130(status,created_at);
alter table public.self_serve_business_onboarding_v130 enable row level security;
revoke all privileges on table public.self_serve_business_onboarding_v130
  from public,anon,authenticated;

-- A self-service workspace is payment-managed. No legacy/manual approval path
-- may change its decision while the provider-paid transition is pending.
create or replace function app.guard_self_serve_manual_decision_v130()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if new.approval_status is distinct from old.approval_status
     and exists(
       select 1 from public.self_serve_business_onboarding_v130 onboarding
        where onboarding.business_id=old.business_id
          and onboarding.status='payment_pending'
     ) then
    raise exception 'self-service approval is controlled by provider-confirmed payment'
      using errcode='42501';
  end if;
  return new;
end
$$;
revoke all on function app.guard_self_serve_manual_decision_v130()
  from public,anon,authenticated;

create trigger business_control_self_serve_payment_guard_v130
  before update of approval_status
  on public.business_workspace_controls_v94
  for each row execute function app.guard_self_serve_manual_decision_v130();

create or replace function app.self_serve_plan_total_v130(
  p_catalog public.billing_plan_catalog_v124,
  p_customer_capacity integer
)
returns integer
language sql
immutable
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select (p_catalog).base_amount_cents
    + greatest(p_customer_capacity/(p_catalog).capacity_block_size-1,0)
      * (p_catalog).capacity_block_amount_cents
$$;
revoke all on function app.self_serve_plan_total_v130(
  public.billing_plan_catalog_v124,integer
) from public,anon,authenticated;

create or replace function public.get_self_serve_checkout_v130(
  p_business uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_email text;
  v_is_super_admin boolean:=app.is_super_admin();
  v_onboarding public.self_serve_business_onboarding_v130%rowtype;
begin
  if v_actor is null then
    raise exception 'authenticated session required' using errcode='28000';
  end if;
  select lower(email) into v_email from auth.users
   where id=v_actor and coalesce(email_confirmed_at,confirmed_at) is not null;
  if v_email is null then
    raise exception 'confirmed owner email required' using errcode='42501';
  end if;
  select onboarding.* into v_onboarding
    from public.self_serve_business_onboarding_v130 onboarding
   where (onboarding.owner_user_id=v_actor
          or (v_is_super_admin and p_business is not null))
     and (p_business is null or onboarding.business_id=p_business);
  if p_business is not null and not found and not v_is_super_admin then
    raise exception 'self-service onboarding access required' using errcode='42501';
  end if;
  return jsonb_build_object(
    'onboarding',case when v_onboarding.business_id is null then null else
      jsonb_build_object(
        'business_id',v_onboarding.business_id,
        'business_slug',v_onboarding.business_slug,
        'business_name',v_onboarding.business_name,
        'owner_name',v_onboarding.owner_name,
        'sector_key',v_onboarding.sector_key,
        'cadence',v_onboarding.selected_cadence,
        'customer_capacity',v_onboarding.selected_customer_capacity,
        'status',v_onboarding.status,
        'checkout_command_id',v_onboarding.checkout_command_id,
        'activated_at',v_onboarding.activated_at,
        'legal_document_version',v_onboarding.legal_document_version,
        'total_cents',app.self_serve_plan_total_v130(
          (select catalog from public.billing_plan_catalog_v124 catalog
            where catalog.id=v_onboarding.billing_catalog_id_v124),
          v_onboarding.selected_customer_capacity
        )
      ) end,
    'plans',coalesce((
      select jsonb_agg(jsonb_build_object(
        'cadence',catalog.cadence,
        'cadence_months',catalog.cadence_months,
        'base_amount_cents',catalog.base_amount_cents,
        'included_customer_capacity',catalog.included_customer_capacity,
        'capacity_block_size',catalog.capacity_block_size,
        'capacity_block_amount_cents',catalog.capacity_block_amount_cents,
        'compare_at_monthly_cents',catalog.compare_at_monthly_cents,
        'tax_behavior',catalog.tax_behavior
      ) order by case catalog.cadence when 'annual' then 0 else 1 end)
      from public.billing_plan_catalog_v124 catalog
      where catalog.currency='SGD' and catalog.active
        and catalog.effective_from<=now()
        and (catalog.effective_to is null or catalog.effective_to>now())
    ),'[]'::jsonb),
    'sectors',coalesce((
      select jsonb_agg(jsonb_build_object(
        'sector_key',profile.sector_key,'label',profile.label
      ) order by profile.label)
      from public.sector_profiles profile
      where profile.active and exists(
        select 1 from public.sector_bundle_versions bundle
         where bundle.sector_key=profile.sector_key and bundle.status='published'
      )
    ),'[]'::jsonb),
    'gst_registered',false,
    'money_back_days',30,
    'included_modules',jsonb_build_array(
      'Customer CRM and QR signup','Loyalty points, stamps and rewards',
      'Birthday benefits and referrals','Appointments, team schedule and waitlist',
      'Record Sale and sales history','Packages, memberships and gift cards',
      'Customer wallet, history and redemption','Promotions and AI-assisted promotion copy',
      'Feedback and Google review handoff','Configured notifications',
      'Profitability and operational reports','Branches, roles and permissions',
      'English, Simplified Chinese and Malay business UI'
    )
  );
end
$$;
revoke all on function public.get_self_serve_checkout_v130(uuid)
  from public,anon,authenticated;
grant execute on function public.get_self_serve_checkout_v130(uuid)
  to authenticated;

create or replace function public.start_self_serve_business_v130(
  p_owner_name text,p_business_name text,p_business_slug text,
  p_sector_key text,p_registration_number text,p_locale text,
  p_cadence text,p_customer_capacity integer,p_legal_accepted boolean,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_email text;
  v_owner_name text:=btrim(coalesce(p_owner_name,''));
  v_business_name text:=btrim(coalesce(p_business_name,''));
  v_business_slug text:=lower(btrim(coalesce(p_business_slug,'')));
  v_registration text:=nullif(btrim(coalesce(p_registration_number,'')),'');
  v_locale text:=coalesce(p_locale,'en');
  v_hash text;
  v_existing public.self_serve_business_onboarding_v130%rowtype;
  v_catalog public.billing_plan_catalog_v124%rowtype;
  v_bundle public.sector_bundle_versions%rowtype;
  v_business public.businesses%rowtype;
  v_staff uuid;
  v_branch uuid;
begin
  if v_actor is null or p_idempotency_key is null then
    raise exception 'authenticated idempotent setup required' using errcode='28000';
  end if;
  select lower(email) into v_email from auth.users
   where id=v_actor and coalesce(email_confirmed_at,confirmed_at) is not null;
  if v_email is null then
    raise exception 'confirmed owner email required' using errcode='42501';
  end if;
  if length(v_owner_name) not between 2 and 120
     or length(v_business_name) not between 2 and 160
     or v_business_slug!~'^[a-z0-9]+(?:-[a-z0-9]+)*$'
     or length(v_business_slug) not between 3 and 80
     or coalesce(p_sector_key,'')!~'^[a-z][a-z0-9_]*$'
     or (v_registration is not null and length(v_registration) not between 3 and 80)
     or v_locale not in ('en','zh-CN','ms')
     or p_cadence not in ('monthly','annual')
     or p_customer_capacity<1000 or p_customer_capacity%1000<>0
     or p_legal_accepted is distinct from true then
    raise exception 'valid owner, business, plan and legal acceptance are required'
      using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_actor::text,130));
  v_hash:=app.v95_sha256(
    v_actor::text||E'\n'||v_owner_name||E'\n'||v_business_name||E'\n'
    ||v_business_slug||E'\n'||p_sector_key||E'\n'||coalesce(v_registration,'')
    ||E'\n'||v_locale||E'\n'||p_cadence||E'\n'||p_customer_capacity::text
    ||E'\n2026-08-01'
  );
  select * into v_existing
    from public.self_serve_business_onboarding_v130 onboarding
   where onboarding.owner_user_id=v_actor for update;
  if found then
    if v_existing.request_hash<>v_hash then
      raise exception 'self-service setup is locked to the existing selection'
        using errcode='22023';
    end if;
    return jsonb_build_object(
      'business_id',v_existing.business_id,
      'business_slug',v_existing.business_slug,
      'owner_staff_id',v_existing.owner_staff_id,
      'default_branch_id',v_existing.default_branch_id,
      'status',v_existing.status,'workspace_access',v_existing.status='active',
      'replayed',true
    );
  end if;
  if exists(select 1 from public.staff where user_id=v_actor) then
    raise exception 'this account is already assigned to a business workspace'
      using errcode='42501';
  end if;
  select * into v_catalog
    from public.billing_plan_catalog_v124 catalog
   where catalog.currency='SGD' and catalog.cadence=p_cadence
     and catalog.active and catalog.effective_from<=now()
     and (catalog.effective_to is null or catalog.effective_to>now())
   order by catalog.effective_from desc limit 1;
  if not found or v_catalog.tax_behavior<>'exclusive' then
    raise exception 'selected Stripe plan is not available' using errcode='22023';
  end if;
  select * into v_bundle from public.sector_bundle_versions bundle
   where bundle.sector_key=p_sector_key and bundle.status='published';
  if not found then
    raise exception 'published sector is required' using errcode='23514';
  end if;
  insert into public.businesses(name,slug,industry,enabled_modules)
  values(v_business_name,v_business_slug,p_sector_key,v_bundle.modules)
  returning * into v_business;
  insert into public.staff(business_id,user_id,role,full_name,email,active)
  values(v_business.id,v_actor,'owner',v_owner_name,v_email,true)
  returning id into v_staff;
  insert into public.branches(business_id,name,is_default,active)
  values(v_business.id,v_business_name,true,true)
  returning id into v_branch;
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values(v_business.id,v_staff,v_branch);
  insert into public.subscriptions(business_id,status,billing_provider)
  values(v_business.id,'incomplete','stripe')
  on conflict(business_id) do nothing;
  insert into public.self_serve_business_onboarding_v130(
    business_id,owner_user_id,owner_staff_id,default_branch_id,
    bundle_version_id,setup_idempotency_key,request_hash,owner_name,
    owner_email,business_name,business_slug,sector_key,registration_number,
    preferred_locale,selected_cadence,selected_customer_capacity,
    billing_catalog_id_v124,legal_accepted_at
  ) values(
    v_business.id,v_actor,v_staff,v_branch,v_bundle.id,p_idempotency_key,
    v_hash,v_owner_name,v_email,v_business_name,v_business_slug,p_sector_key,
    v_registration,v_locale,p_cadence,p_customer_capacity,v_catalog.id,now()
  );
  insert into public.business_workspace_control_audit_v94(
    business_id,actor,event_type,prior_status,new_status,reason,control_version
  ) values(
    v_business.id,v_actor,'self_service_started','pending','pending',
    'self-service owner workspace locked pending provider-confirmed payment',1
  );
  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values(
    v_business.id,v_actor,'SELF_SERVICE_STARTED',
    'self_serve_business_onboarding_v130',v_business.id,
    jsonb_build_object(
      'cadence',p_cadence,'customer_capacity',p_customer_capacity,
      'sector_key',p_sector_key,'legal_document_version','2026-08-01'
    )
  );
  return jsonb_build_object(
    'business_id',v_business.id,'business_slug',v_business.slug,
    'owner_staff_id',v_staff,'default_branch_id',v_branch,
    'status','payment_pending','workspace_access',false,'replayed',false,
    'cadence',p_cadence,'customer_capacity',p_customer_capacity,
    'total_cents',app.self_serve_plan_total_v130(v_catalog,p_customer_capacity)
  );
exception when unique_violation then
  raise exception 'business address or setup identity is already in use'
    using errcode='23505';
end
$$;
revoke all on function public.start_self_serve_business_v130(
  text,text,text,text,text,text,text,integer,boolean,uuid
) from public,anon,authenticated;
grant execute on function public.start_self_serve_business_v130(
  text,text,text,text,text,text,text,integer,boolean,uuid
) to authenticated;

create or replace function public.request_self_serve_checkout_v130(
  p_business uuid,p_cadence text,p_customer_capacity integer,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_onboarding public.self_serve_business_onboarding_v130%rowtype;
  v_catalog public.billing_plan_catalog_v124%rowtype;
  v_command public.billing_commands%rowtype;
  v_command_key uuid;
  v_fingerprint text;
begin
  if v_actor is null or p_idempotency_key is null then
    raise exception 'authenticated idempotent checkout required' using errcode='28000';
  end if;
  select * into v_onboarding
    from public.self_serve_business_onboarding_v130 onboarding
   where onboarding.business_id=p_business
     and onboarding.owner_user_id=v_actor for update;
  if not found or v_onboarding.status<>'payment_pending' then
    raise exception 'payment-pending self-service owner access required'
      using errcode='42501';
  end if;
  if p_cadence is distinct from v_onboarding.selected_cadence
     or p_customer_capacity is distinct from v_onboarding.selected_customer_capacity then
    raise exception 'checkout must use the locked onboarding selection'
      using errcode='22023';
  end if;
  if v_onboarding.checkout_command_id is not null then
    select * into strict v_command from public.billing_commands
     where id=v_onboarding.checkout_command_id;
    -- Reuse uncertain work and a conservatively still-live Checkout URL.
    -- Stripe's default maximum is 24 hours, so rotate completed sessions at
    -- 23 hours rather than ever returning an already expired redirect.
    if v_command.status in ('pending','processing','uncertain')
       or (v_command.status='completed'
           and v_command.requested_at>now()-interval '23 hours') then
      return jsonb_build_object(
        'command_id',v_command.id,'status',v_command.status,
        'cadence',v_command.requested_cadence,
        'requested_customer_capacity',v_command.requested_customer_capacity,
        'redirect_url',v_command.redirect_url,'replayed',true
      );
    end if;
  end if;
  select * into v_catalog from public.billing_plan_catalog_v124 catalog
   where catalog.id=v_onboarding.billing_catalog_id_v124
     and catalog.currency='SGD' and catalog.cadence=p_cadence
     and catalog.active and catalog.effective_from<=now()
     and (catalog.effective_to is null or catalog.effective_to>now());
  if not found then
    raise exception 'snapshotted Stripe plan is no longer available'
      using errcode='22023';
  end if;
  v_fingerprint:=app.v95_sha256(
    p_business::text||E'\ncreate_checkout\n'||p_cadence||E'\n'
    ||p_customer_capacity::text||E'\nv124_customer_capacity'
  );
  v_command_key:=case
    when v_onboarding.checkout_command_id is null then p_idempotency_key
    else gen_random_uuid()
  end;
  insert into public.billing_commands(
    business_id,command_type,requested_cadence,pricing_model,
    requested_customer_capacity,billing_catalog_id_v124,
    idempotency_key,request_fingerprint,requested_by
  ) values(
    p_business,'create_checkout',p_cadence,'v124_customer_capacity',
    p_customer_capacity,v_catalog.id,v_command_key,v_fingerprint,v_actor
  ) returning * into v_command;
  update public.self_serve_business_onboarding_v130
     set checkout_command_id=v_command.id,version=version+1,updated_at=now()
   where business_id=p_business;
  return jsonb_build_object(
    'command_id',v_command.id,'status',v_command.status,
    'cadence',v_command.requested_cadence,
    'requested_customer_capacity',v_command.requested_customer_capacity,
    'redirect_url',v_command.redirect_url,'replayed',false
  );
end
$$;
revoke all on function public.request_self_serve_checkout_v130(
  uuid,text,integer,uuid
) from public,anon,authenticated;
grant execute on function public.request_self_serve_checkout_v130(
  uuid,text,integer,uuid
) to authenticated;

create or replace function public.claim_billing_command_v130(
  p_command uuid,p_actor uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_claim jsonb;
  v_self_service boolean;
begin
  v_claim:=public.claim_billing_command_v124(p_command,p_actor);
  select exists(
    select 1 from public.billing_commands command
    join public.self_serve_business_onboarding_v130 onboarding
      on onboarding.business_id=command.business_id
     and onboarding.checkout_command_id=command.id
   where command.id=p_command and command.requested_by=p_actor
  ) into v_self_service;
  return v_claim||jsonb_build_object(
    'self_service_onboarding',v_self_service
  );
end
$$;
revoke all on function public.claim_billing_command_v130(uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.claim_billing_command_v130(uuid,uuid)
  to service_role;

create or replace function app.activate_self_serve_paid_v130()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_onboarding public.self_serve_business_onboarding_v130%rowtype;
  v_control public.business_workspace_controls_v94%rowtype;
begin
  select * into v_onboarding
    from public.self_serve_business_onboarding_v130 onboarding
   where onboarding.business_id=new.business_id
     and onboarding.status='payment_pending' for update;
  if not found then return new;end if;
  if not exists(
    select 1 from public.billing_provider_invoices invoice
    join public.billing_subscription_terms_v124 terms
      on terms.business_id=invoice.business_id
     and terms.provider_subscription_id=invoice.provider_subscription_id
    join public.billing_plan_catalog_v124 catalog
      on catalog.id=v_onboarding.billing_catalog_id_v124
   where invoice.business_id=new.business_id
     and invoice.provider_invoice_id=new.first_paid_invoice_id
     and invoice.status='paid' and invoice.paid_normalized
     and invoice.paid_at is not null
     and invoice.paid_at=new.first_paid_at
     and invoice.currency='SGD'
     and invoice.tax_cents=0
     and invoice.subtotal_ex_tax_cents=app.self_serve_plan_total_v130(
       catalog,v_onboarding.selected_customer_capacity
     )
     and invoice.total_cents=app.self_serve_plan_total_v130(
       catalog,v_onboarding.selected_customer_capacity
     )
     and invoice.amount_due_cents=app.self_serve_plan_total_v130(
       catalog,v_onboarding.selected_customer_capacity
     )
     and invoice.amount_paid_cents=app.self_serve_plan_total_v130(
       catalog,v_onboarding.selected_customer_capacity
     )
     and invoice.amount_remaining_cents=0
     and catalog.currency='SGD'
     and catalog.tax_behavior='exclusive'
     and catalog.cadence=v_onboarding.selected_cadence
     and terms.pricing_model='v124_customer_capacity'
     and terms.cadence=v_onboarding.selected_cadence
     and terms.customer_capacity=v_onboarding.selected_customer_capacity
     and terms.capacity_blocks=v_onboarding.selected_customer_capacity/1000
     and terms.provider_base_price_id=catalog.provider_base_price_id
     and (
       (v_onboarding.selected_customer_capacity=1000
        and terms.provider_capacity_item_id is null
        and terms.provider_capacity_price_id is null)
       or
       (v_onboarding.selected_customer_capacity>1000
        and terms.provider_capacity_item_id is not null
        and terms.provider_capacity_price_id=catalog.provider_capacity_price_id)
     )
  ) then
    return new;
  end if;
  -- Change the staging state first so the control-table guard can distinguish
  -- this verified, atomic activation from every manual decision route.
  update public.self_serve_business_onboarding_v130
     set status='active',activation_invoice_id=new.first_paid_invoice_id,
         activated_at=new.first_paid_at,version=version+1,updated_at=now()
   where business_id=new.business_id and status='payment_pending';
  if not found then return new;end if;
  select * into strict v_control
    from public.business_workspace_controls_v94 control
   where control.business_id=new.business_id for update;
  if v_control.approval_status<>'pending' then return new;end if;
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,decided_by=null,
         decided_at=new.first_paid_at,
         decision_reason='provider-confirmed self-service subscription payment',
         updated_at=now()
   where business_id=new.business_id and approval_status='pending';
  insert into public.business_workspace_control_audit_v94(
    business_id,actor,event_type,prior_status,new_status,reason,control_version
  ) values(
    new.business_id,null,'self_service_payment_confirmed','pending','approved',
    'provider-confirmed self-service subscription payment',v_control.version+1
  );
  insert into public.business_sector_assignments(
    business_id,bundle_version_id,version,assigned_by
  ) values(new.business_id,v_onboarding.bundle_version_id,1,null)
  on conflict(business_id) do nothing;
  insert into public.loyalty_programs(
    business_id,kind,earn_points_per_dollar,redeem_points,
    reward_credit_cents,active,loyalty_model,configuration_status,
    recommendation_source
  ) values(
    new.business_id,'points',1,800,2000,false,'classic','draft',
    'self_service_onboarding_preset'
  ) on conflict(business_id) do nothing;
  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values(
    new.business_id,null,'SELF_SERVICE_PAYMENT_CONFIRMED',
    'self_serve_business_onboarding_v130',new.business_id,
    jsonb_build_object(
      'provider_invoice_id',new.first_paid_invoice_id,
      'paid_at',new.first_paid_at,'workspace_access',true
    )
  );
  return new;
end
$$;
revoke all on function app.activate_self_serve_paid_v130()
  from public,anon,authenticated;

create trigger billing_money_back_self_serve_activate_v130
  after insert or update of first_paid_at
  on public.billing_money_back_windows_v124
  for each row execute function app.activate_self_serve_paid_v130();

comment on table public.self_serve_business_onboarding_v130 is
  'Browser-closed staging record. Signed Stripe paid-invoice evidence alone opens the workspace.';
comment on function public.start_self_serve_business_v130(
  text,text,text,text,text,text,text,integer,boolean,uuid
) is 'Creates exactly one locked owner workspace using published sector and Stripe plan truth.';
comment on function public.request_self_serve_checkout_v130(
  uuid,text,integer,uuid
) is 'Creates or reuses the single server-priced Stripe Checkout command for pending onboarding.';

commit;
