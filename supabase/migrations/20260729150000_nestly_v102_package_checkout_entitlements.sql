-- Nestly v102 — package checkout, service variations and merchant media repair.
-- Local migration only until independent review + owner release approval.

begin;

-- The v95 storage policies execute this helper as the authenticated caller.
-- v95 revoked EXECUTE from authenticated as well as PUBLIC/anon, so every
-- otherwise-authorized upload failed before the ownership predicate could run.
revoke all on function app.v95_storage_path_owned(text) from public, anon;
grant execute on function app.v95_storage_path_owned(text) to authenticated;

alter table public.services
  add column if not exists variant_label text;
alter table public.services
  drop constraint if exists services_variant_label_check;
alter table public.services
  add constraint services_variant_label_check
  check (
    variant_label is null
    or length(btrim(variant_label)) between 1 and 80
  );

alter table public.package_plans
  add column if not exists list_unit_cents_snapshot bigint,
  add column if not exists list_value_cents_snapshot bigint,
  add column if not exists version_no integer not null default 1,
  add column if not exists supersedes_plan_id uuid references public.package_plans(id) on delete restrict;
alter table public.package_plans
  alter column list_unit_cents_snapshot type bigint
    using list_unit_cents_snapshot::bigint,
  alter column list_value_cents_snapshot type bigint
    using list_value_cents_snapshot::bigint;
alter table public.package_plans
  drop constraint if exists package_plans_list_unit_snapshot_check;
alter table public.package_plans
  add constraint package_plans_list_unit_snapshot_check
  check (list_unit_cents_snapshot is null or list_unit_cents_snapshot >= 0);
alter table public.package_plans
  drop constraint if exists package_plans_list_value_snapshot_check;
alter table public.package_plans
  add constraint package_plans_list_value_snapshot_check
  check (list_value_cents_snapshot is null or list_value_cents_snapshot >= 0);

update public.package_plans plan
set list_unit_cents_snapshot=service.price_cents::bigint,
    list_value_cents_snapshot=service.price_cents::bigint*plan.sessions::bigint
from public.services service
where plan.service_id=service.id
  and plan.business_id=service.business_id
  and (plan.list_unit_cents_snapshot is null or plan.list_value_cents_snapshot is null);

drop policy if exists pkgplans_all on public.package_plans;
drop policy if exists package_plans_read_v102 on public.package_plans;
drop policy if exists package_plans_write_v102 on public.package_plans;
create policy package_plans_read_v102 on public.package_plans
for select to authenticated using(
  app.is_super_admin()
  or app.can_module_read(business_id,'packages')
  or app.can_module_read(business_id,'till')
  or app.can_module_read(business_id,'sales')
);

-- A sold package is a financial/history record. Browser roles may read plans,
-- but every plan mutation must pass through save_package_plan_v102 so editing
-- creates a new immutable version instead of rewriting what a customer bought.
revoke insert,update,delete,truncate on table public.package_plans
  from public,anon,authenticated;

alter table public.client_packages
  add column if not exists plan_name_snapshot text,
  add column if not exists plan_version_snapshot integer,
  add column if not exists sessions_snapshot integer,
  add column if not exists price_cents_snapshot bigint,
  add column if not exists service_id_snapshot uuid,
  add column if not exists service_name_snapshot text,
  add column if not exists service_variant_snapshot text,
  add column if not exists service_duration_min_snapshot integer,
  add column if not exists list_unit_cents_snapshot bigint,
  add column if not exists list_value_cents_snapshot bigint;

update public.client_packages customer_package
set plan_name_snapshot=plan.name,
    plan_version_snapshot=plan.version_no,
    sessions_snapshot=plan.sessions,
    price_cents_snapshot=plan.price_cents::bigint,
    service_id_snapshot=plan.service_id,
    service_name_snapshot=service.name,
    service_variant_snapshot=service.variant_label,
    service_duration_min_snapshot=service.duration_min,
    list_unit_cents_snapshot=plan.list_unit_cents_snapshot,
    list_value_cents_snapshot=plan.list_value_cents_snapshot
from public.package_plans plan
left join public.services service
  on service.id=plan.service_id and service.business_id=plan.business_id
where customer_package.plan_id=plan.id
  and customer_package.business_id=plan.business_id
  and (
    customer_package.plan_name_snapshot is null
    or customer_package.plan_version_snapshot is null
    or customer_package.sessions_snapshot is null
    or customer_package.price_cents_snapshot is null
  );

alter table public.client_packages
  alter column plan_name_snapshot set not null,
  alter column plan_version_snapshot set not null,
  alter column sessions_snapshot set not null,
  alter column price_cents_snapshot set not null;
alter table public.client_packages
  drop constraint if exists client_packages_plan_version_snapshot_check,
  add constraint client_packages_plan_version_snapshot_check
    check (plan_version_snapshot > 0),
  drop constraint if exists client_packages_sessions_snapshot_check,
  add constraint client_packages_sessions_snapshot_check
    check (sessions_snapshot > 0),
  drop constraint if exists client_packages_price_snapshot_check,
  add constraint client_packages_price_snapshot_check
    check (price_cents_snapshot >= 0),
  drop constraint if exists client_packages_list_unit_snapshot_check,
  add constraint client_packages_list_unit_snapshot_check
    check (list_unit_cents_snapshot is null or list_unit_cents_snapshot >= 0),
  drop constraint if exists client_packages_list_value_snapshot_check,
  add constraint client_packages_list_value_snapshot_check
    check (list_value_cents_snapshot is null or list_value_cents_snapshot >= 0);

-- New v102 session rows persist the exact response so a lost-response retry
-- cannot drift when the customer's points balance later changes.
alter table public.package_session_consumptions
  add column if not exists result jsonb;
alter table public.package_session_consumptions
  drop constraint if exists package_session_consumptions_result_check,
  add constraint package_session_consumptions_result_check
    check (result is null or jsonb_typeof(result)='object');

alter table public.businesses
  add column if not exists gift_card_sales_enabled boolean not null default false;

-- Policy choices change money. Staff may read the resolved setting, but only
-- owners (or the platform) may mutate a raw override.
drop policy if exists sale_policies_all on public.sale_policies;
drop policy if exists sale_policies_read_v102 on public.sale_policies;
drop policy if exists sale_policies_owner_insert_v102 on public.sale_policies;
drop policy if exists sale_policies_owner_update_v102 on public.sale_policies;
drop policy if exists sale_policies_owner_delete_v102 on public.sale_policies;
create policy sale_policies_read_v102 on public.sale_policies
for select to authenticated using(
  app.is_super_admin() or app.is_salon_member(business_id)
);
create policy sale_policies_owner_insert_v102 on public.sale_policies
for insert to authenticated with check(
  app.is_super_admin() or app.is_salon_owner(business_id)
);
create policy sale_policies_owner_update_v102 on public.sale_policies
for update to authenticated
using(app.is_super_admin() or app.is_salon_owner(business_id))
with check(app.is_super_admin() or app.is_salon_owner(business_id));
create policy sale_policies_owner_delete_v102 on public.sale_policies
for delete to authenticated
using(app.is_super_admin() or app.is_salon_owner(business_id));

-- Preserve firms that already sold cards; new firms must deliberately enable.
update public.businesses business
set gift_card_sales_enabled=true
where exists(
  select 1 from public.gift_cards card
  where card.business_id=business.id
);

create or replace function public.business_get_checkout_preferences_v102(
  p_business uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_gift boolean;
  v_package_points boolean;
begin
  if not (
    app.is_super_admin()
    or app.can_module_read(p_business,'till')
    or app.can_module_read(p_business,'sales')
    or app.can_module_read(p_business,'packages')
    or app.can_module_read(p_business,'giftcards')
  ) then
    raise exception 'checkout_preferences_access_required' using errcode='42501';
  end if;
  select business.gift_card_sales_enabled
  into v_gift
  from public.businesses business
  where business.id=p_business;
  if not found then
    raise exception 'business_not_found' using errcode='22023';
  end if;
  select policy.earns_points into v_package_points
  from app.sale_policy(p_business,'package') policy;
  return jsonb_build_object(
    'status','available',
    'gift_card_sales_enabled',coalesce(v_gift,false),
    'package_earns_points',coalesce(v_package_points,true)
  );
end
$$;

create or replace function public.staff_get_customer_entitlements_v102(
  p_business uuid,p_client uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_packages jsonb;
  v_vouchers jsonb;
begin
  if not (
    app.is_super_admin()
    or app.can_module_read(p_business,'till')
    or app.can_module_read(p_business,'sales')
    or app.can_module_read(p_business,'packages')
  ) then
    raise exception 'customer_entitlements_access_required' using errcode='42501';
  end if;
  if not exists(
    select 1 from public.clients client
    where client.id=p_client and client.business_id=p_business
  ) then
    raise exception 'customer_not_found' using errcode='22023';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'client_package_id',customer_package.id,
    'remaining',customer_package.remaining,
    'status',customer_package.status,
    'plan_id',customer_package.plan_id,
    'plan_version',customer_package.plan_version_snapshot,
    'plan_name',customer_package.plan_name_snapshot,
    'sessions',customer_package.sessions_snapshot,
    'price_cents',customer_package.price_cents_snapshot,
    'service_id',customer_package.service_id_snapshot,
    'service_name',customer_package.service_name_snapshot,
    'variant_label',customer_package.service_variant_snapshot,
    'list_unit_cents',customer_package.list_unit_cents_snapshot,
    'list_value_cents',customer_package.list_value_cents_snapshot,
    'duration_min',customer_package.service_duration_min_snapshot
  ) order by customer_package.purchased_at,customer_package.id),'[]'::jsonb)
  into v_packages
  from public.client_packages customer_package
  where customer_package.business_id=p_business
    and customer_package.client_id=p_client
    and customer_package.status='active'
    and customer_package.remaining>0;

  select coalesce(jsonb_agg(jsonb_build_object(
    'intent_id',intent.id,
    'redemption_kind',intent.redemption_kind,
    'reward_name',coalesce(reward.name,'Points reward'),
    'points_spent',intent.quoted_points_spent,
    'credit_cents',intent.quoted_credit_cents,
    'expires_at',intent.expires_at
  ) order by intent.expires_at,intent.id),'[]'::jsonb)
  into v_vouchers
  from public.customer_redemption_intents_v89 intent
  left join public.loyalty_rewards reward on reward.id=intent.reward_id
    and reward.business_id=intent.business_id
  where intent.business_id=p_business
    and intent.client_id=p_client
    and intent.status='pending'
    and intent.expires_at>now();

  return jsonb_build_object('packages',v_packages,'vouchers',v_vouchers);
end
$$;

create or replace function public.staff_list_package_entitlements_v102(
  p_business uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if not (
    app.is_super_admin()
    or app.can_module_read(p_business,'till')
    or app.can_module_read(p_business,'sales')
    or app.can_module_read(p_business,'packages')
  ) then
    raise exception 'package_entitlements_access_required' using errcode='42501';
  end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'client_package_id',customer_package.id,
      'client_id',customer_package.client_id,
      'client_name',client.full_name,
      'client_phone',client.phone,
      'plan_id',customer_package.plan_id,
      'plan_version',customer_package.plan_version_snapshot,
      'plan_name',customer_package.plan_name_snapshot,
      'sessions',customer_package.sessions_snapshot,
      'price_cents',customer_package.price_cents_snapshot,
      'remaining',customer_package.remaining,
      'status',customer_package.status,
      'service_id',customer_package.service_id_snapshot,
      'service_name',customer_package.service_name_snapshot,
      'variant_label',customer_package.service_variant_snapshot,
      'duration_min',customer_package.service_duration_min_snapshot,
      'list_unit_cents',customer_package.list_unit_cents_snapshot,
      'list_value_cents',customer_package.list_value_cents_snapshot,
      'purchased_at',customer_package.purchased_at
    ) order by customer_package.purchased_at desc,customer_package.id),'[]'::jsonb)
    from public.client_packages customer_package
    join public.clients client
      on client.id=customer_package.client_id
     and client.business_id=customer_package.business_id
    where customer_package.business_id=p_business
  );
end
$$;

create or replace function public.set_gift_card_sales_enabled_v102(
  p_business uuid,p_enabled boolean
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if p_enabled is null then
    raise exception 'enabled_required' using errcode='22023';
  end if;
  if not (app.is_super_admin() or app.is_salon_owner(p_business)) then
    raise exception 'owner_required' using errcode='42501';
  end if;
  update public.businesses
  set gift_card_sales_enabled=p_enabled
  where id=p_business;
  if not found then
    raise exception 'business_not_found' using errcode='22023';
  end if;
  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values(
    p_business,auth.uid(),'GIFT_CARD_SALES_SET_V102','businesses',p_business,
    jsonb_build_object('enabled',p_enabled)
  );
  return jsonb_build_object('gift_card_sales_enabled',p_enabled);
end
$$;

create or replace function public.set_package_points_policy_v102(
  p_business uuid,p_earns_points boolean
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if p_earns_points is null then
    raise exception 'earns_points_required' using errcode='22023';
  end if;
  if not (app.is_super_admin() or app.is_salon_owner(p_business)) then
    raise exception 'owner_required' using errcode='42501';
  end if;
  insert into public.sale_policies(
    business_id,kind,earns_points,note
  ) values(
    p_business,'package',p_earns_points,
    'Owner package-purchase points setting (Nestly v102)'
  )
  on conflict (business_id,kind) do update
  set earns_points=excluded.earns_points,
      note=excluded.note,
      updated_at=now();
  return jsonb_build_object('package_earns_points',p_earns_points);
end
$$;

create or replace function public.save_package_plan_v102(
  p_business uuid,
  p_plan uuid,
  p_name text,
  p_price_cents integer,
  p_sessions integer,
  p_service uuid,
  p_active boolean
)
returns public.package_plans
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_service public.services%rowtype;
  v_plan public.package_plans%rowtype;
  v_previous public.package_plans%rowtype;
begin
  if not (
    app.is_super_admin()
    or app.can_module_write(p_business,'packages')
  ) then
    raise exception 'packages_write_required' using errcode='42501';
  end if;
  if p_name is null or length(btrim(p_name)) not between 2 and 120 then
    raise exception 'package_name_invalid' using errcode='22023';
  end if;
  if p_price_cents is null or p_price_cents < 0 then
    raise exception 'package_price_invalid' using errcode='22023';
  end if;
  if p_sessions is null or p_sessions < 1 or p_sessions > 1000 then
    raise exception 'package_sessions_invalid' using errcode='22023';
  end if;
  if p_active is null then
    raise exception 'package_active_required' using errcode='22023';
  end if;
  if p_service is not null then
    select * into v_service
    from public.services service
    where service.id=p_service and service.business_id=p_business;
    if not found then
      raise exception 'package_service_not_found' using errcode='22023';
    end if;
  end if;
  if p_plan is null then
    insert into public.package_plans(
      business_id,name,price_cents,sessions,service_id,active,
      list_unit_cents_snapshot,list_value_cents_snapshot,
      version_no,supersedes_plan_id
    ) values(
      p_business,btrim(p_name),p_price_cents,p_sessions,p_service,p_active,
      case when p_service is null then null else v_service.price_cents::bigint end,
      case when p_service is null then null
        else v_service.price_cents::bigint*p_sessions::bigint end,
      1,null
    ) returning * into v_plan;
  else
    select * into v_previous
    from public.package_plans plan
    where plan.id=p_plan and plan.business_id=p_business
    for update;
    if not found then
      raise exception 'package_plan_not_found' using errcode='22023';
    end if;
    if exists(
      select 1 from public.package_plans child
      where child.business_id=p_business
        and child.supersedes_plan_id=v_previous.id
    ) then
      raise exception 'package_plan_version_superseded' using errcode='40001';
    end if;

    -- Clone-on-edit: existing purchases keep their original plan FK and the
    -- snapshots taken at checkout. Only the new version becomes sellable.
    insert into public.package_plans(
      business_id,name,price_cents,sessions,service_id,active,
      list_unit_cents_snapshot,list_value_cents_snapshot,
      version_no,supersedes_plan_id
    ) values(
      p_business,btrim(p_name),p_price_cents,p_sessions,p_service,p_active,
      case when p_service is null then null else v_service.price_cents::bigint end,
      case when p_service is null then null
        else v_service.price_cents::bigint*p_sessions::bigint end,
      v_previous.version_no+1,v_previous.id
    ) returning * into v_plan;

    update public.package_plans
    set active=false
    where id=v_previous.id and business_id=p_business;
  end if;
  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values(
    p_business,auth.uid(),'PACKAGE_PLAN_SAVED_V102','package_plans',v_plan.id,
    jsonb_build_object(
      'service_id',v_plan.service_id,
      'version_no',v_plan.version_no,
      'supersedes_plan_id',v_plan.supersedes_plan_id,
      'sessions',v_plan.sessions,
      'price_cents',v_plan.price_cents,
      'list_value_cents_snapshot',v_plan.list_value_cents_snapshot,
      'active',v_plan.active
    )
  );
  return v_plan;
end
$$;

-- Exact, branch-bound package purchase. The operation ledger stores the full
-- completed result; a retry after a lost response returns the same identifiers,
-- price/session snapshots and ledger-derived points values.
create or replace function public.sell_package_v102(
  p_business uuid,
  p_client uuid,
  p_plan uuid,
  p_branch uuid,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_plan public.package_plans%rowtype;
  v_service public.services%rowtype;
  v_existing public.sale_intent_operations%rowtype;
  v_client_package_id uuid := gen_random_uuid();
  v_sale_id uuid := gen_random_uuid();
  v_payload jsonb;
  v_hash text;
  v_points_earned bigint;
  v_points_total bigint;
  v_result jsonb;
begin
  if v_actor is null or p_idempotency_key is null then
    raise exception 'authenticated staff and idempotency key required'
      using errcode='42501';
  end if;
  if not app.has_perm(p_business,'create_sales')
     or not (
       app.can_module_write(p_business,'till')
       or app.can_module_write(p_business,'sales')
       or app.can_module_write(p_business,'packages')
     ) then
    raise exception 'package checkout authorization required' using errcode='42501';
  end if;
  select staff_row.id into v_staff
  from public.staff staff_row
  where staff_row.business_id=p_business
    and staff_row.user_id=v_actor
    and staff_row.active
    and 'create_sales'=any(app.role_perms(staff_row.role))
  order by case staff_row.role when 'owner' then 0 when 'manager' then 1 else 2 end,
           staff_row.created_at,staff_row.id
  limit 1
  for update;
  if not found then
    raise exception 'active staff authorization required' using errcode='42501';
  end if;
  if p_client is null or not exists(
    select 1 from public.clients client
    where client.id=p_client and client.business_id=p_business
  ) then
    raise exception 'package_sale_client_invalid' using errcode='22023';
  end if;

  v_payload:=jsonb_build_object(
    'branch_id',p_branch,
    'business_id',p_business,
    'client_id',p_client,
    'plan_id',p_plan
  );
  v_hash:=app.v41_request_hash(v_payload::text);
  perform pg_advisory_xact_lock(hashtextextended(
    'v102:package-sale:'||p_business::text||':'||p_idempotency_key::text,0
  ));

  select * into v_existing
  from public.sale_intent_operations operation
  where operation.business_id=p_business
    and operation.idempotency_key=p_idempotency_key
  for update;
  if found then
    if v_existing.actor is distinct from v_actor
       or v_existing.operation_type<>'package_sale'
       or v_existing.request_hash<>v_hash then
      raise exception 'package sale idempotency key conflict' using errcode='23505';
    end if;
    return v_existing.result;
  end if;

  select * into v_plan
  from public.package_plans plan
  where plan.id=p_plan and plan.business_id=p_business and plan.active
  for share;
  if not found then
    raise exception 'package_plan_not_found_or_inactive' using errcode='22023';
  end if;
  if v_plan.service_id is not null then
    select * into v_service
    from public.services service
    where service.id=v_plan.service_id and service.business_id=p_business;
    if not found then
      raise exception 'package_service_not_found' using errcode='22023';
    end if;
  end if;
  perform 1
  from public.branches branch
  where branch.id=p_branch and branch.business_id=p_business and branch.active
    and app.can_see_branch(p_business,branch.id)
    and (
      v_plan.service_id is null
      or not exists(
        select 1 from public.service_branches any_branch
        where any_branch.business_id=p_business
          and any_branch.service_id=v_plan.service_id
      )
      or exists(
        select 1 from public.service_branches allowed
        where allowed.business_id=p_business
          and allowed.service_id=v_plan.service_id
          and allowed.branch_id=branch.id
      )
    )
  for share;
  if not found then
    raise exception 'package_branch_not_permitted' using errcode='42501';
  end if;

  insert into public.client_packages(
    id,business_id,client_id,plan_id,remaining,
    plan_name_snapshot,plan_version_snapshot,sessions_snapshot,
    price_cents_snapshot,service_id_snapshot,service_name_snapshot,
    service_variant_snapshot,service_duration_min_snapshot,
    list_unit_cents_snapshot,list_value_cents_snapshot
  ) values(
    v_client_package_id,p_business,p_client,v_plan.id,v_plan.sessions,
    v_plan.name,v_plan.version_no,v_plan.sessions,v_plan.price_cents::bigint,
    v_plan.service_id,case when v_plan.service_id is null then null else v_service.name end,
    case when v_plan.service_id is null then null else v_service.variant_label end,
    case when v_plan.service_id is null then null else v_service.duration_min end,
    v_plan.list_unit_cents_snapshot,v_plan.list_value_cents_snapshot
  );
  insert into public.sales(
    id,business_id,client_id,kind,amount_cents,note,branch_id,staff_id
  ) values(
    v_sale_id,p_business,p_client,'package',v_plan.price_cents,
    'package sold: '||v_plan.name,p_branch,v_staff
  );

  select coalesce(sum(ledger.points),0)::bigint into v_points_earned
  from public.points_ledger ledger
  where ledger.business_id=p_business
    and ledger.client_id=p_client
    and ledger.sale_id=v_sale_id;
  select coalesce(sum(ledger.points),0)::bigint into v_points_total
  from public.points_ledger ledger
  where ledger.business_id=p_business and ledger.client_id=p_client;

  v_result:=jsonb_build_object(
    'status','completed',
    'replayed',false,
    'client_package_id',v_client_package_id,
    'sale_id',v_sale_id,
    'plan_id',v_plan.id,
    'plan_version',v_plan.version_no,
    'branch_id',p_branch,
    'price_cents',v_plan.price_cents::bigint,
    'sessions',v_plan.sessions,
    'remaining',v_plan.sessions,
    'points_earned',v_points_earned,
    'points_total',v_points_total
  );
  insert into public.sale_intent_operations(
    business_id,actor,operation_type,idempotency_key,request_hash,
    status,client_id,result
  ) values(
    p_business,v_actor,'package_sale',p_idempotency_key,v_hash,
    'completed',p_client,v_result
  );
  return v_result;
end
$$;

-- Explicit branch is part of the request identity. The exact completed JSON is
-- stored beside the immutable consumption evidence for deterministic replay.
create or replace function public.use_package_session_v102(
  p_business uuid,
  p_client_package uuid,
  p_branch uuid,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_staff uuid;
  v_package public.client_packages%rowtype;
  v_existing public.package_session_consumptions%rowtype;
  v_consumption_id uuid:=gen_random_uuid();
  v_sale_id uuid:=gen_random_uuid();
  v_payload jsonb;
  v_hash text;
  v_points_total bigint;
  v_result jsonb;
begin
  p_idempotency_key:=btrim(p_idempotency_key);
  if v_actor is null or p_idempotency_key is null
     or length(p_idempotency_key)<8 then
    raise exception 'authenticated staff and valid idempotency key required'
      using errcode='22023';
  end if;
  if not app.has_perm(p_business,'create_sales')
     or not (
       app.can_module_write(p_business,'till')
       or app.can_module_write(p_business,'sales')
       or app.can_module_write(p_business,'packages')
     ) then
    raise exception 'package session authorization required' using errcode='42501';
  end if;
  select staff_row.id into v_staff
  from public.staff staff_row
  where staff_row.business_id=p_business
    and staff_row.user_id=v_actor
    and staff_row.active
    and 'create_sales'=any(app.role_perms(staff_row.role))
  order by case staff_row.role when 'owner' then 0 when 'manager' then 1 else 2 end,
           staff_row.created_at,staff_row.id
  limit 1
  for update;
  if not found then
    raise exception 'active staff authorization required' using errcode='42501';
  end if;

  v_payload:=jsonb_build_object(
    'branch_id',p_branch,
    'business_id',p_business,
    'client_package_id',p_client_package
  );
  v_hash:=md5(v_payload::text);
  perform pg_advisory_xact_lock(hashtextextended(
    'v102:package-session:'||p_business::text||':'||p_idempotency_key,0
  ));
  select * into v_existing
  from public.package_session_consumptions consumption
  where consumption.business_id=p_business
    and consumption.idempotency_key=p_idempotency_key;
  if found then
    if v_existing.actor is distinct from v_actor
       or v_existing.request_hash<>v_hash
       or v_existing.result is null then
      raise exception 'package session idempotency key conflict' using errcode='23505';
    end if;
    return v_existing.result;
  end if;

  select * into v_package
  from public.client_packages customer_package
  where customer_package.id=p_client_package
    and customer_package.business_id=p_business
  for update;
  if not found then
    raise exception 'client_package_not_found' using errcode='22023';
  end if;
  if v_package.status<>'active' or v_package.remaining<=0 then
    raise exception 'package_has_no_sessions' using errcode='22023';
  end if;
  perform 1
  from public.branches branch
  where branch.id=p_branch and branch.business_id=p_business and branch.active
    and app.can_see_branch(p_business,branch.id)
    and (
      v_package.service_id_snapshot is null
      or not exists(
        select 1 from public.service_branches any_branch
        where any_branch.business_id=p_business
          and any_branch.service_id=v_package.service_id_snapshot
      )
      or exists(
        select 1 from public.service_branches allowed
        where allowed.business_id=p_business
          and allowed.service_id=v_package.service_id_snapshot
          and allowed.branch_id=branch.id
      )
    )
  for share;
  if not found then
    raise exception 'package_branch_not_permitted' using errcode='42501';
  end if;

  update public.client_packages
  set remaining=remaining-1,
      status=case when remaining-1=0 then 'used_up' else 'active' end
  where id=v_package.id and business_id=p_business and remaining>0;
  if not found then
    raise exception 'package_session_concurrent_use' using errcode='40001';
  end if;
  insert into public.sales(
    id,business_id,client_id,kind,amount_cents,note,branch_id,staff_id
  ) values(
    v_sale_id,p_business,v_package.client_id,'service',0,
    'package session used: '||v_package.plan_name_snapshot,p_branch,v_staff
  );
  select coalesce(sum(ledger.points),0)::bigint into v_points_total
  from public.points_ledger ledger
  where ledger.business_id=p_business and ledger.client_id=v_package.client_id;
  v_result:=jsonb_build_object(
    'status','completed',
    'replayed',false,
    'consumption_id',v_consumption_id,
    'sale_id',v_sale_id,
    'client_package_id',v_package.id,
    'client_id',v_package.client_id,
    'branch_id',p_branch,
    'remaining_before',v_package.remaining,
    'remaining_after',v_package.remaining-1,
    'points_earned',0,
    'points_total',v_points_total
  );
  insert into public.package_session_consumptions(
    id,business_id,client_package_id,client_id,sale_id,actor,
    idempotency_key,request_payload,request_hash,
    remaining_before,remaining_after,result
  ) values(
    v_consumption_id,p_business,v_package.id,v_package.client_id,v_sale_id,v_actor,
    p_idempotency_key,v_payload,v_hash,
    v_package.remaining,v_package.remaining-1,v_result
  );
  return v_result;
end
$$;

-- v102 gift-card issue switch. Completed operations replay above this guard;
-- only genuinely new issuance is refused. Existing cards remain redeemable.
create or replace function public.issue_gift_card(
  p_business uuid,
  p_amount integer,
  p_purchaser uuid,
  p_recipient_email text,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_staff uuid;
  v_email text:=nullif(lower(btrim(p_recipient_email)),'');
  v_payload jsonb;
  v_hash text;
  v_existing public.gift_card_issue_operations%rowtype;
  v_code text;
  v_card public.gift_cards%rowtype;
  v_sale public.sales%rowtype;
  v_result jsonb;
begin
  if v_actor is null
     or not app.can_module_write(p_business,'giftcards')
     or not app.has_perm(p_business,'create_sales') then
    raise exception 'active giftcards-module and create-sales authorization is required'
      using errcode='42501';
  end if;
  select staff_row.id into v_staff
  from public.staff staff_row
  where staff_row.business_id=p_business
    and staff_row.user_id=v_actor and staff_row.active
    and 'create_sales'=any(app.role_perms(staff_row.role))
  order by case when staff_row.role='owner' then 0 else 1 end,
           staff_row.created_at
  limit 1 for update;
  if not found then
    raise exception 'active staff authorization is required' using errcode='42501';
  end if;
  if p_idempotency_key is null or p_amount is null or p_amount<=0
     or p_amount>100000000
     or (v_email is not null and char_length(v_email)>320) then
    raise exception 'invalid gift-card issuance request' using errcode='22023';
  end if;
  if p_purchaser is not null and not exists(
    select 1 from public.clients client
    where client.id=p_purchaser and client.business_id=p_business
  ) then
    raise exception 'purchaser does not belong to this business' using errcode='22023';
  end if;
  v_payload:=jsonb_build_object(
    'amount_cents',p_amount,
    'business_id',p_business,
    'purchaser_client_id',p_purchaser,
    'recipient_email',v_email
  );
  v_hash:=app.v41_request_hash(v_payload::text);
  perform pg_advisory_xact_lock(hashtextextended(
    'v41:gift-card:'||p_business::text||':'||p_idempotency_key::text,0
  ));
  select * into v_existing
  from public.gift_card_issue_operations operation
  where operation.business_id=p_business
    and operation.idempotency_key=p_idempotency_key
  for update;
  if found then
    if v_existing.actor is distinct from v_actor
       or v_existing.request_hash<>v_hash then
      raise exception 'idempotency key conflicts with another gift-card request'
        using errcode='23505';
    end if;
    select * into v_card
    from public.gift_cards card
    where card.id=v_existing.gift_card_id
      and card.business_id=p_business
    for share;
    return jsonb_build_object(
      'status','completed',
      'gift_card_id',v_existing.gift_card_id,
      'sale_id',v_existing.sale_id,
      'code',v_card.code,
      'initial_cents',v_existing.amount_cents,
      'balance_cents',v_existing.amount_cents
    );
  end if;

  if not coalesce((
    select business.gift_card_sales_enabled
    from public.businesses business where business.id=p_business
  ),false) then
    raise exception 'gift_card_sales_disabled' using errcode='55000';
  end if;
  perform app.sv_legacy_issue_guard(p_business,'gift_card');
  if p_purchaser is not null then
    perform 1 from public.clients client
    where client.id=p_purchaser and client.business_id=p_business
    for share;
    if not found then
      raise exception 'purchaser does not belong to this business' using errcode='22023';
    end if;
  end if;
  loop
    v_code:='GC-'||upper(substr(md5(
      gen_random_uuid()::text||clock_timestamp()::text
    ),1,12));
    exit when not exists(
      select 1 from public.gift_cards card where card.code=v_code
    );
  end loop;
  insert into public.gift_cards(
    business_id,code,initial_cents,balance_cents,
    purchaser_client_id,recipient_email
  ) values(
    p_business,v_code,p_amount,p_amount,p_purchaser,v_email
  ) returning * into v_card;
  insert into public.sales(
    business_id,client_id,kind,amount_cents,note,staff_id
  ) values(
    p_business,p_purchaser,'gift_card',p_amount,
    'gift card liability issued',v_staff
  ) returning * into v_sale;
  v_result:=jsonb_build_object(
    'status','completed',
    'gift_card_id',v_card.id,
    'sale_id',v_sale.id,
    'code',v_card.code,
    'initial_cents',v_card.initial_cents,
    'balance_cents',v_card.balance_cents
  );
  insert into public.gift_card_issue_operations(
    business_id,actor,idempotency_key,request_hash,status,
    amount_cents,gift_card_id,sale_id
  ) values(
    p_business,v_actor,p_idempotency_key,v_hash,'completed',
    p_amount,v_card.id,v_sale.id
  );
  return v_result;
end
$$;

revoke all on function public.business_get_checkout_preferences_v102(uuid)
  from public,anon,authenticated;
revoke all on function public.staff_get_customer_entitlements_v102(uuid,uuid)
  from public,anon,authenticated;
revoke all on function public.staff_list_package_entitlements_v102(uuid)
  from public,anon,authenticated;
revoke all on function public.set_gift_card_sales_enabled_v102(uuid,boolean)
  from public,anon,authenticated;
revoke all on function public.set_package_points_policy_v102(uuid,boolean)
  from public,anon,authenticated;
revoke all on function public.save_package_plan_v102(
  uuid,uuid,text,integer,integer,uuid,boolean
) from public,anon,authenticated;
revoke all on function public.sell_package_v102(uuid,uuid,uuid,uuid,uuid)
  from public,anon,authenticated;
revoke all on function public.use_package_session_v102(uuid,uuid,uuid,text)
  from public,anon,authenticated;
-- The old 3-arg core is intentionally retained only as a definer-owner/internal
-- implementation artifact for historical database routines. No Data API role
-- may execute it: it has no branch or idempotency key and would bypass v102.
revoke all on function public.sell_package(uuid,uuid,uuid)
  from public,anon,authenticated;
revoke all on function public.sell_package(uuid,uuid,uuid,uuid)
  from public,anon,authenticated;
revoke all on function public.use_package_session(uuid,uuid,text)
  from public,anon,authenticated;
revoke all on function public.issue_gift_card(uuid,integer,uuid,text,uuid)
  from public,anon,authenticated;
grant execute on function public.business_get_checkout_preferences_v102(uuid)
  to authenticated;
grant execute on function public.staff_get_customer_entitlements_v102(uuid,uuid)
  to authenticated;
grant execute on function public.staff_list_package_entitlements_v102(uuid)
  to authenticated;
grant execute on function public.set_gift_card_sales_enabled_v102(uuid,boolean)
  to authenticated;
grant execute on function public.set_package_points_policy_v102(uuid,boolean)
  to authenticated;
grant execute on function public.save_package_plan_v102(
  uuid,uuid,text,integer,integer,uuid,boolean
) to authenticated;
grant execute on function public.sell_package_v102(uuid,uuid,uuid,uuid,uuid)
  to authenticated;
grant execute on function public.use_package_session_v102(uuid,uuid,uuid,text)
  to authenticated;
grant execute on function public.issue_gift_card(uuid,integer,uuid,text,uuid)
  to authenticated;

commit;
