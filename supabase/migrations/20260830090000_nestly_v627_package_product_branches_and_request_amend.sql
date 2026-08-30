-- nestly_v627 — a package and a product can be limited to branches, and a pending booking
-- request can be amended instead of only withdrawn.
--
-- Owner rulings (2026-08-30 photo batch):
--   photo 3: "when designing customised or normal package - needs to indicate if able to use at
--            all branches or only selected branches - so when frontdesk open up record sale the
--            packages will show up accordingly to the selection (same as services)"
--   item 5:  "products should also allow owner to decide if the product is only for selected
--            branches or all branches (same as services)"
--   photo 4: an Edit button on a booking card — confirmed as PENDING REQUESTS ONLY.
--
-- "Same as services" is meant literally, and that decides almost everything here. Services have
-- carried public.service_branches since v11a with one convention: NO ROWS AT ALL means offered
-- everywhere, and any rows mean only those. That convention is why a branch added tomorrow
-- inherits every universal service instead of silently being excluded from it, and it is why this
-- migration is additive for every package and product already sold — none of them has a row, so
-- none of them changes. The owner confirmed it explicitly for these two.
--
-- Enforcement goes where the READ already is, never in a new place:
--   • products: business_get_checkout_catalogue_v94 already computes `branch_available` per item
--     and already applies the service rule to services. Products hardcoded `true`. They now run
--     the same pair of clauses, so the till list, which already honours that flag, needs no
--     change to obey this.
--   • packages: the till lists them by reading package_plans straight from the browser, which
--     cannot express "no rows OR this row" in one PostgREST filter. business_list_branch_packages_v627
--     answers that question server-side for the one caller that asks it.
--   • the two writers that can actually spend a package — sell_package_v102 and
--     use_package_session_v102 — both already have a branch check keyed on the package's SERVICE
--     and both already raise package_branch_not_permitted. The package's own rule joins that same
--     check rather than becoming a second refusal with a different name.
--
-- A package version is immutable once sold, and save_package_plan_v102 clones on edit. Branch
-- rows are cloned with it: a new version inheriting "Orchard only" from the version it replaces
-- is the same rule v593 applied to expiry_days, and the alternative — a new version silently
-- offered everywhere — would widen availability as a side effect of a price change.
--
-- customer_amend_booking_request_v627 resolves ownership through exactly the chain
-- customer_withdraw_booking_request_v290 uses (identity -> verified link -> request -> management
-- token), refuses the same states with the same already_actioned error, and touches only the two
-- fields the customer typed. It cannot approve, move or convert anything.
--
-- ROLLBACK: db/tests/v627_package_product_branches_and_request_amend.sql

begin;

do $pre$
declare
  v_missing text;
begin
  select string_agg(t, ', ') into v_missing
  from unnest(array['package_plans','products','branches','service_branches',
                    'booking_requests','client_packages']) t
  where to_regclass('public.'||t) is null;
  if v_missing is not null then
    raise exception 'v627: expected tables are absent: %', v_missing;
  end if;
  if to_regprocedure('public.business_get_checkout_catalogue_v94(uuid,uuid,boolean)') is null then
    raise exception 'v627: business_get_checkout_catalogue_v94 is missing — the read this hangs product availability on';
  end if;
  if to_regclass('app.booking_management_tokens') is null then
    raise exception 'v627: app.booking_management_tokens is missing — the ownership chain the amend reuses';
  end if;
end
$pre$;

-- ---------------------------------------------------------------------------
-- 1. The two tables, shaped exactly like service_branches
-- ---------------------------------------------------------------------------
create table if not exists public.package_branches(
  business_id uuid not null references public.businesses(id) on delete cascade,
  plan_id uuid not null references public.package_plans(id) on delete cascade,
  branch_id uuid not null references public.branches(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (business_id, plan_id, branch_id)
);

create table if not exists public.product_branches(
  business_id uuid not null references public.businesses(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  branch_id uuid not null references public.branches(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (business_id, product_id, branch_id)
);

comment on table public.package_branches is
  'nestly_v627: which branches offer a package plan. NO ROWS for a plan = offered at every branch, including branches added later. Same convention as service_branches.';
comment on table public.product_branches is
  'nestly_v627: which branches sell a product. NO ROWS for a product = sold at every branch, including branches added later. Same convention as service_branches.';

create index if not exists package_branches_branch_idx on public.package_branches(business_id, branch_id);
create index if not exists product_branches_branch_idx on public.product_branches(business_id, branch_id);

alter table public.package_branches enable row level security;
alter table public.product_branches enable row level security;

-- v572 found the hole this avoids: service_branches once had an owner WITH CHECK but a member
-- USING, and DELETE is governed by USING alone, so any member could delete a service's branches.
-- All four commands are owner-only here from the start; reading is member-wide because the till
-- and the editor both need it.
drop policy if exists package_branches_select on public.package_branches;
drop policy if exists package_branches_sa_read on public.package_branches;
drop policy if exists package_branches_insert_v627 on public.package_branches;
drop policy if exists package_branches_update_v627 on public.package_branches;
drop policy if exists package_branches_delete_v627 on public.package_branches;
create policy package_branches_select on public.package_branches
  for select using (app.is_salon_member(business_id));
create policy package_branches_sa_read on public.package_branches
  for select using (app.is_super_admin());
create policy package_branches_insert_v627 on public.package_branches
  for insert with check (app.is_salon_owner(business_id));
create policy package_branches_update_v627 on public.package_branches
  for update using (app.is_salon_owner(business_id)) with check (app.is_salon_owner(business_id));
create policy package_branches_delete_v627 on public.package_branches
  for delete using (app.is_salon_owner(business_id));

drop policy if exists product_branches_select on public.product_branches;
drop policy if exists product_branches_sa_read on public.product_branches;
drop policy if exists product_branches_insert_v627 on public.product_branches;
drop policy if exists product_branches_update_v627 on public.product_branches;
drop policy if exists product_branches_delete_v627 on public.product_branches;
create policy product_branches_select on public.product_branches
  for select using (app.is_salon_member(business_id));
create policy product_branches_sa_read on public.product_branches
  for select using (app.is_super_admin());
create policy product_branches_insert_v627 on public.product_branches
  for insert with check (app.is_salon_owner(business_id));
create policy product_branches_update_v627 on public.product_branches
  for update using (app.is_salon_owner(business_id)) with check (app.is_salon_owner(business_id));
create policy product_branches_delete_v627 on public.product_branches
  for delete using (app.is_salon_owner(business_id));

grant select, insert, update, delete on public.package_branches to authenticated;
grant select, insert, update, delete on public.product_branches to authenticated;

-- ---------------------------------------------------------------------------
-- 2. One definition of "is this offered here"
-- ---------------------------------------------------------------------------
-- Written once and called from all four places, so the convention cannot drift between the list
-- that offers an item and the writer that refuses it.
create or replace function app.branch_offers_package_v627(
  p_business uuid, p_plan uuid, p_branch uuid
) returns boolean
language sql
stable
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select p_plan is null
      or not exists(
        select 1 from public.package_branches configured
        where configured.business_id=p_business and configured.plan_id=p_plan)
      or exists(
        select 1 from public.package_branches allowed
        where allowed.business_id=p_business and allowed.plan_id=p_plan
          and allowed.branch_id=p_branch)
$$;

create or replace function app.branch_offers_product_v627(
  p_business uuid, p_product uuid, p_branch uuid
) returns boolean
language sql
stable
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select p_product is null
      or not exists(
        select 1 from public.product_branches configured
        where configured.business_id=p_business and configured.product_id=p_product)
      or exists(
        select 1 from public.product_branches allowed
        where allowed.business_id=p_business and allowed.product_id=p_product
          and allowed.branch_id=p_branch)
$$;

revoke all on function app.branch_offers_package_v627(uuid,uuid,uuid) from public, anon;
revoke all on function app.branch_offers_product_v627(uuid,uuid,uuid) from public, anon;
grant execute on function app.branch_offers_package_v627(uuid,uuid,uuid)
  to postgres, service_role, authenticated;
grant execute on function app.branch_offers_product_v627(uuid,uuid,uuid)
  to postgres, service_role, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Products obey it in the read the till already uses
-- ---------------------------------------------------------------------------
-- Only the product arm changes: its branch_available was the literal `true`. Services keep the
-- clauses they have always had, written out rather than routed through the new helper, because
-- rewriting a working rule is how a working rule breaks.
create or replace function public.business_get_checkout_catalogue_v94(
  p_business uuid, p_branch uuid, p_include_inactive boolean
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
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
      coalesce(item.version,0) version,
      app.v95_public_media_url(service_asset.object_path) image_url
    from public.services service
    left join public.business_checkout_catalogue_items_v94 item
      on item.business_id=p_business and item.item_type='service'
      and item.item_id=service.id
    left join public.business_media_assets_v95 service_asset
      on service_asset.business_id=p_business
      and service_asset.asset_kind='service'
      and service_asset.entity_id=service.id
      and service_asset.branch_id is null
      and service_asset.customer_visible
    where service.business_id=p_business
    union all
    select
      'product'::text,product.id,product.name,
      product.retail_price_cents,product.active,
      coalesce(item.checkout_active,true),
      -- nestly_v627: was the literal `true`. A product with no product_branches row is still
      -- available everywhere, so nothing already on sale changes.
      app.branch_offers_product_v627(p_business,product.id,v_branch),
      coalesce(item.version,0),
      app.v95_public_media_url(product_asset.object_path)
    from public.products product
    left join public.business_checkout_catalogue_items_v94 item
      on item.business_id=p_business and item.item_type='product'
      and item.item_id=product.id
    left join public.business_media_assets_v95 product_asset
      on product_asset.business_id=p_business
      and product_asset.asset_kind='product'
      and product_asset.entity_id=product.id
      and product_asset.branch_id is null
      and product_asset.customer_visible
    where product.business_id=p_business
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'item_type',item_type,'item_id',item_id,'name',name,
    'unit_cents',unit_cents,'checkout_active',checkout_active,
    'branch_available',branch_available,'version',version,
    'image_url',image_url
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
$function$;

revoke all on function public.business_get_checkout_catalogue_v94(uuid,uuid,boolean) from public, anon;
grant execute on function public.business_get_checkout_catalogue_v94(uuid,uuid,boolean)
  to postgres, service_role, authenticated;

-- ---------------------------------------------------------------------------
-- 4. The till's package list, answered where the rule lives
-- ---------------------------------------------------------------------------
-- The browser used to read package_plans directly with .eq('active',true). "No rows OR a row for
-- this branch" is not expressible as one PostgREST filter, and a client-side approximation of it
-- would be the browser re-deriving a server rule — the thing v145 forbids. One RPC, one caller.
-- A bespoke plan stays excluded here exactly as it is in the direct read it replaces.
create or replace function public.business_list_branch_packages_v627(
  p_business uuid, p_branch uuid
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_branch uuid:=p_branch;
  v_items jsonb;
begin
  -- The branch is resolved BEFORE it is used to authorise: can_module_read_at_v94 takes a branch,
  -- and asking it about NULL would be asking a question with no answer.
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
    or app.can_module_read_at_v94(p_business,v_branch,'packages')
    or app.can_module_read_at_v94(p_business,v_branch,'till')
  ) then
    raise exception 'package_catalogue_access_required' using errcode='42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',plan.id,'name',plan.name,'price_cents',plan.price_cents,'active',plan.active
  ) order by plan.name,plan.id),'[]'::jsonb)
  into v_items
  from public.package_plans plan
  where plan.business_id=p_business
    and plan.active
    and plan.bespoke_for_client is null
    and plan.retired_at is null
    and app.branch_offers_package_v627(p_business,plan.id,v_branch);

  return jsonb_build_object('branch_id',v_branch,'items',v_items);
end
$function$;

revoke all on function public.business_list_branch_packages_v627(uuid,uuid) from public, anon;
grant execute on function public.business_list_branch_packages_v627(uuid,uuid)
  to postgres, service_role, authenticated;

-- ---------------------------------------------------------------------------
-- 5. The two writers refuse a branch the package is not offered at
-- ---------------------------------------------------------------------------
-- Both already had a branch check keyed on the package's SERVICE, and both already raised
-- package_branch_not_permitted. The package's own rule is ANDed into that same check so there is
-- one refusal with one name, not two that a receptionist would have to tell apart.
create or replace function public.sell_package_v102(
  p_business uuid, p_client uuid, p_plan uuid, p_branch uuid, p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_plan public.package_plans%rowtype;
  v_service public.services%rowtype;
  v_existing public.sale_intent_operations%rowtype;
  v_client_package_id uuid := gen_random_uuid();
  v_sale_id uuid := gen_random_uuid();
  v_purchased_at timestamptz := now();
  v_expires_at timestamptz;
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
    -- nestly_v627: the package's own branch rule, beside the service rule it has always applied.
    and app.branch_offers_package_v627(p_business,v_plan.id,branch.id)
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

  v_expires_at := app.package_expires_at_v593(v_purchased_at, v_plan.expiry_days);

  insert into public.client_packages(
    id,business_id,client_id,plan_id,remaining,purchased_at,
    plan_name_snapshot,plan_version_snapshot,sessions_snapshot,
    price_cents_snapshot,service_id_snapshot,service_name_snapshot,
    service_variant_snapshot,service_duration_min_snapshot,
    list_unit_cents_snapshot,list_value_cents_snapshot,
    expiry_days_snapshot,expires_at
  ) values(
    v_client_package_id,p_business,p_client,v_plan.id,v_plan.sessions,v_purchased_at,
    v_plan.name,v_plan.version_no,v_plan.sessions,v_plan.price_cents::bigint,
    v_plan.service_id,case when v_plan.service_id is null then null else v_service.name end,
    case when v_plan.service_id is null then null else v_service.variant_label end,
    case when v_plan.service_id is null then null else v_service.duration_min end,
    v_plan.list_unit_cents_snapshot,v_plan.list_value_cents_snapshot,
    v_plan.expiry_days,v_expires_at
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
  v_points_total := app.client_points_balance_v409(p_business, p_client)::bigint;

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
    'expiry_days',v_plan.expiry_days,
    'expires_at',v_expires_at,
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
$function$;

revoke all on function public.sell_package_v102(uuid,uuid,uuid,uuid,uuid) from public, anon;
grant execute on function public.sell_package_v102(uuid,uuid,uuid,uuid,uuid)
  to postgres, service_role, authenticated;

-- use_package_session_v102: same addition, keyed on the plan the entitlement came from. The
-- entitlement's own service snapshot rule is untouched.
create or replace function public.use_package_session_v102(
  p_business uuid, p_client_package uuid, p_branch uuid, p_idempotency_key text
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
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
    -- A replay returns the ORIGINAL result and never re-tests expiry: the session it describes
    -- was already consumed, inside the window, and a double-tap must not turn a completed sale
    -- into an error just because the deadline passed in between.
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
  -- nestly_v593. Its own error, not package_has_no_sessions: the sessions ARE there, the time is
  -- not, and a receptionist reading the refusal has to be able to tell a customer which it was.
  if v_package.expires_at is not null and v_package.expires_at < now() then
    raise exception 'package_expired' using errcode='22023';
  end if;
  perform 1
  from public.branches branch
  where branch.id=p_branch and branch.business_id=p_business and branch.active
    and app.can_see_branch(p_business,branch.id)
    -- nestly_v627: where the package itself may be used, beside where its service may be given.
    and app.branch_offers_package_v627(p_business,v_package.plan_id,branch.id)
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
  v_points_total := app.client_points_balance_v409(p_business, v_package.client_id)::bigint;
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
$function$;

revoke all on function public.use_package_session_v102(uuid,uuid,uuid,text) from public, anon;
grant execute on function public.use_package_session_v102(uuid,uuid,uuid,text)
  to postgres, service_role, authenticated;

-- ---------------------------------------------------------------------------
-- 6. A new package version inherits the branches of the version it replaces
-- ---------------------------------------------------------------------------
-- The alternative is that repricing a package silently offers it everywhere, which is a widening
-- of availability nobody asked for. Same reasoning v593 used for expiry_days.
create or replace function public.save_package_plan_v102(
  p_business uuid,
  p_plan uuid,
  p_name text,
  p_price_cents integer,
  p_sessions integer,
  p_service uuid,
  p_active boolean,
  p_expiry_days integer
) returns public.package_plans
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
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
  -- nestly_v593: blank is a real answer ("no expiry"), so NULL passes. A number that is present
  -- must be usable — zero days would sell a package that is dead on purchase.
  if p_expiry_days is not null and (p_expiry_days < 1 or p_expiry_days > 3650) then
    raise exception 'package_expiry_days_invalid' using errcode='22023';
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
      version_no,supersedes_plan_id,expiry_days
    ) values(
      p_business,btrim(p_name),p_price_cents,p_sessions,p_service,p_active,
      case when p_service is null then null else v_service.price_cents::bigint end,
      case when p_service is null then null
        else v_service.price_cents::bigint*p_sessions::bigint end,
      1,null,p_expiry_days
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
    -- nestly_v593: expiry_days is cloned with the rest, so a customer who bought v1 keeps the
    -- deadline v1 sold them even after v2 changes it.
    insert into public.package_plans(
      business_id,name,price_cents,sessions,service_id,active,
      list_unit_cents_snapshot,list_value_cents_snapshot,
      version_no,supersedes_plan_id,expiry_days
    ) values(
      p_business,btrim(p_name),p_price_cents,p_sessions,p_service,p_active,
      case when p_service is null then null else v_service.price_cents::bigint end,
      case when p_service is null then null
        else v_service.price_cents::bigint*p_sessions::bigint end,
      v_previous.version_no+1,v_previous.id,p_expiry_days
    ) returning * into v_plan;

    -- nestly_v627: the branch restriction travels with the version.
    insert into public.package_branches(business_id,plan_id,branch_id)
    select p_business, v_plan.id, previous_branch.branch_id
    from public.package_branches previous_branch
    where previous_branch.business_id=p_business
      and previous_branch.plan_id=v_previous.id
    on conflict do nothing;

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
      'expiry_days',v_plan.expiry_days,
      'active',v_plan.active
    )
  );
  return v_plan;
end
$function$;

revoke all on function public.save_package_plan_v102(
  uuid,uuid,text,integer,integer,uuid,boolean,integer) from public, anon;
grant execute on function public.save_package_plan_v102(
  uuid,uuid,text,integer,integer,uuid,boolean,integer)
  to postgres, service_role, authenticated;

-- ---------------------------------------------------------------------------
-- 7. A pending booking request can be amended
-- ---------------------------------------------------------------------------
-- Owner ruling: Edit is for PENDING REQUESTS ONLY. An approved appointment keeps the v508
-- reschedule-replace flow, which is a different act — it releases a slot the business has already
-- committed to, and has to go back for approval.
--
-- Ownership is resolved through the same four-table chain customer_withdraw_booking_request_v290
-- walks, so this can only ever amend a request that customer was already allowed to withdraw. The
-- refusal states are identical, and it writes only preferred_at and notes: not status, not
-- appointment_id, not the branch or the staff member the business may have assigned.
create or replace function public.customer_amend_booking_request_v627(
  p_request uuid,
  p_preferred_at timestamptz,
  p_notes text
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_request public.booking_requests%rowtype;
  v_notes text := nullif(btrim(coalesce(p_notes,'')),'');
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if p_request is null then
    raise exception 'invalid booking request' using errcode = '22023';
  end if;
  if p_preferred_at is null then
    raise exception 'booking_request_time_required' using errcode = '22023';
  end if;
  -- A request the business cannot act on is not an amendment, it is a dead row. The customer is
  -- told so rather than being allowed to save a time that has already gone.
  if p_preferred_at <= now() then
    raise exception 'booking_request_time_past' using errcode = '22023';
  end if;
  if v_notes is not null and length(v_notes) > 750 then
    raise exception 'booking_request_note_too_long' using errcode = '22023';
  end if;

  select request.* into v_request
    from public.customer_identities identity
    join public.customer_links link
      on link.identity_id = identity.id
     and link.auth_user_id = identity.auth_user_id
     and link.state = 'verified'
    join public.booking_requests request
      on request.business_id = link.business_id
     and request.customer_client_id = link.client_id
    join app.booking_management_tokens token
      on token.business_id = request.business_id
     and token.booking_request_id = request.id
     and token.customer_client_id = request.customer_client_id
     and token.authenticated_user_id = v_actor
   where identity.auth_user_id = v_actor
     and identity.status = 'active'
     and request.id = p_request
   for update of request;
  if not found then
    raise exception 'booking request not found' using errcode = '42501';
  end if;

  -- The same gate withdrawal uses. Once the business has approved it there is an appointment,
  -- and moving that is the v508 reschedule act, not this one.
  if v_request.appointment_id is not null
     or v_request.status not in ('new','pending','waitlisted') then
    raise exception 'already_actioned' using errcode = '22023';
  end if;

  update public.booking_requests
     set preferred_at = p_preferred_at,
         notes = v_notes
   where id = v_request.id and business_id = v_request.business_id;

  return jsonb_build_object(
    'status','amended',
    'request_id',v_request.id,
    'preferred_at',p_preferred_at
  );
end
$function$;

revoke all on function public.customer_amend_booking_request_v627(uuid,timestamptz,text) from public, anon;
grant execute on function public.customer_amend_booking_request_v627(uuid,timestamptz,text)
  to postgres, service_role, authenticated;

commit;
