-- Nestly V132: close the V130 provider-paid activation rehearsal gap without
-- weakening the C45 owner/module loyalty writer boundary.

begin;

-- This launch plan always includes Loyalty. Refuse deployment over any staged
-- V130 row that could already have paid for a bundle which cannot accept the
-- governed draft preset.
do $v132_preflight$
begin
  if exists(
    select 1
      from public.self_serve_business_onboarding_v130 onboarding
      join public.sector_bundle_versions bundle
        on bundle.id=onboarding.bundle_version_id
     where onboarding.status='payment_pending'
       and not ('loyalty'=any(bundle.modules))
  ) then
    raise exception 'V132 preflight: payment-pending self-service bundle lacks Loyalty'
      using errcode='23514';
  end if;
end
$v132_preflight$;

create or replace function app.enforce_self_serve_loyalty_bundle_v132()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if not exists(
    select 1 from public.sector_bundle_versions bundle
     where bundle.id=new.bundle_version_id
       and bundle.sector_key=new.sector_key
       and bundle.status='published'
       and 'loyalty'=any(bundle.modules)
  ) then
    raise exception 'self-service launch requires a published Loyalty-capable sector'
      using errcode='23514';
  end if;
  return new;
end
$$;

revoke all on function app.enforce_self_serve_loyalty_bundle_v132()
  from public,anon,authenticated;

create trigger self_serve_loyalty_bundle_guard_v132
  before insert or update of bundle_version_id,sector_key
  on public.self_serve_business_onboarding_v130
  for each row execute function app.enforce_self_serve_loyalty_bundle_v132();

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
         where bundle.sector_key=profile.sector_key
           and bundle.status='published'
           and 'loyalty'=any(bundle.modules)
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

create or replace function app.activate_self_serve_paid_v130()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_onboarding public.self_serve_business_onboarding_v130%rowtype;
  v_control public.business_workspace_controls_v94%rowtype;
  v_prior_sub text:=current_setting('request.jwt.claim.sub',true);
  v_prior_claims text:=current_setting('request.jwt.claims',true);
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
  -- The only identity used for the governed draft seed is the active owner
  -- locked into this payment-pending onboarding record.
  if not exists(
    select 1 from public.staff staff
     where staff.business_id=new.business_id
       and staff.user_id=v_onboarding.owner_user_id
       and staff.role='owner' and staff.active
  ) then
    return new;
  end if;
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

  -- C45 intentionally requires the real owner identity for draft writes. The
  -- provider trigger temporarily supplies the locked owner claims, performs
  -- one idempotent preset insert, then restores the caller claims. No grant,
  -- RLS policy, or C45 predicate is changed.
  perform set_config(
    'request.jwt.claim.sub',v_onboarding.owner_user_id::text,true
  );
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub',v_onboarding.owner_user_id,
      'role','authenticated',
      'aud','authenticated'
    )::text,
    true
  );
  insert into public.loyalty_programs(
    business_id,kind,earn_points_per_dollar,redeem_points,
    reward_credit_cents,active,loyalty_model,configuration_status,
    recommendation_source
  ) values(
    new.business_id,'points',1,800,2000,false,'classic','draft',
    'self_service_onboarding_preset'
  ) on conflict(business_id) do nothing;
  perform set_config('request.jwt.claim.sub',coalesce(v_prior_sub,''),true);
  perform set_config('request.jwt.claims',coalesce(v_prior_claims,''),true);

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

comment on function app.activate_self_serve_paid_v130() is
  'V132 provider-paid self-service activation. Seeds one owner-governed draft using the locked active owner identity without relaxing C45 or browser grants.';

commit;
