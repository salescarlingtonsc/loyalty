-- nestly_v593 — a prepaid package can be given a life.
--
-- Owner ruling (photo 5, the Packages page): "for each designed package - i need to have an
-- expiry date upon purchase. - how many days of expiry after purchase. - current model has no
-- expiry."
--
-- Three facts decide the shape of this migration.
--
-- 1. The clock starts AT PURCHASE, not at design time. Two customers who buy the same plan a
--    month apart get two different deadlines, so the number lives on package_plans and the DATE
--    lives on client_packages. Nothing about an existing sale changes when the plan is later
--    edited — the same freeze that already protects price, sessions and the service snapshot.
-- 2. A package_plan version is IMMUTABLE once sold (save_package_plan_v102 clones on edit), so
--    expiry_days joins the cloned column list and is carried into every new version.
-- 3. NULL means never expires, and every one of the packages already sold is NULL. This is
--    additive: no existing entitlement gains a deadline it was not sold with.
--
-- The deadline is the LAST INSTANT of the last valid Singapore day: buy on the 1st with 30 days
-- and the package is usable through all of the 31st. V266 established that a Singapore calendar
-- day is a half-open instant range and that clipping to 23:59 silently loses the last minute of
-- it, so the value is the start of the day AFTER the last valid one, less one microsecond.
--
-- Expiry is DERIVED at read time, never swept. There is no cron row and no status backfill: a
-- package whose expires_at has passed reads as 'expired' everywhere it is listed and is refused
-- at use time. A sweep would be a second source of truth for a question a comparison answers.

begin;

-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------
alter table public.package_plans
  add column if not exists expiry_days integer;

alter table public.package_plans
  drop constraint if exists package_plans_expiry_days_ck;
alter table public.package_plans
  add constraint package_plans_expiry_days_ck
  check (expiry_days is null or (expiry_days >= 1 and expiry_days <= 3650));

-- The snapshot is what the customer BOUGHT, kept beside the price and sessions snapshots for the
-- same reason: the plan row may be superseded, and a receipt must still be able to say what the
-- terms were on the day.
alter table public.client_packages
  add column if not exists expiry_days_snapshot integer;
alter table public.client_packages
  add column if not exists expires_at timestamptz;

comment on column public.package_plans.expiry_days is
  'nestly_v593: days a customer has to use this package after purchase. NULL = never expires.';
comment on column public.client_packages.expires_at is
  'nestly_v593: last instant this entitlement may be used, SGT end-of-day. NULL = never expires.';

-- ---------------------------------------------------------------------------
-- 2. app.package_expires_at_v593 — one definition of the deadline
-- ---------------------------------------------------------------------------
-- Written once and called from the sale, so the rule cannot drift between where it is set and
-- where it would otherwise be re-derived.
create or replace function app.package_expires_at_v593(
  p_purchased_at timestamptz,
  p_expiry_days integer
) returns timestamptz
language sql
immutable
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select case
    when p_expiry_days is null then null
    else ((
      (p_purchased_at at time zone 'Asia/Singapore')::date + (p_expiry_days + 1)
    )::timestamp at time zone 'Asia/Singapore') - interval '1 microsecond'
  end
$$;

revoke all on function app.package_expires_at_v593(timestamptz,integer) from public, anon;
grant execute on function app.package_expires_at_v593(timestamptz,integer)
  to postgres, service_role, authenticated;

-- ---------------------------------------------------------------------------
-- 3. save_package_plan_v102 — the owner sets the number
-- ---------------------------------------------------------------------------
-- Replaced by SIGNATURE rather than overloaded. Two functions differing only by a trailing
-- parameter is the PGRST203 shape that took the promotion editor down in v410: PostgREST resolves
-- by argument name, and a defaulted eighth parameter would make every existing seven-argument
-- call ambiguous. One function, one signature, every caller updated in the same change.
drop function if exists public.save_package_plan_v102(uuid,uuid,text,integer,integer,uuid,boolean);

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
  -- must be a usable one — zero days would sell a package that is dead on purchase.
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
-- 4. sell_package_v102 — the deadline is stamped at purchase
-- ---------------------------------------------------------------------------
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

  -- nestly_v593: purchased_at and expires_at are computed from ONE instant, not two calls to
  -- now() a few statements apart, so the deadline is always exactly N Singapore days after the
  -- purchase date this row records.
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

-- ---------------------------------------------------------------------------
-- 5. use_package_session_v102 — an expired package pays out nothing
-- ---------------------------------------------------------------------------
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
-- 6. staff_list_package_entitlements_v102 — the Packages page reads the deadline
-- ---------------------------------------------------------------------------
create or replace function public.staff_list_package_entitlements_v102(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
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
      -- nestly_v593: 'expired' is DERIVED, never stored. The stored status still says what
      -- happened to the sessions; this says whether the window is still open, and the window
      -- closing is what a member of staff needs to read before promising anything.
      'status',case
        when customer_package.status='active'
         and customer_package.expires_at is not null
         and customer_package.expires_at < now() then 'expired'
        else customer_package.status end,
      'expiry_days',customer_package.expiry_days_snapshot,
      'expires_at',customer_package.expires_at,
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
$function$;

revoke all on function public.staff_list_package_entitlements_v102(uuid) from public, anon;
grant execute on function public.staff_list_package_entitlements_v102(uuid)
  to postgres, service_role, authenticated;

-- ---------------------------------------------------------------------------
-- 7. staff_get_customer_entitlements_v102 — the till stops offering a dead package
-- ---------------------------------------------------------------------------
-- v215 set the rule this follows: an expired grant is withheld here rather than offered and then
-- refused at redeem time. An expired package now behaves the same way, so the till never shows a
-- session it is about to reject.
create or replace function public.staff_get_customer_entitlements_v102(p_business uuid, p_client uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_bringback jsonb;
  v_referral jsonb;
  v_welcome jsonb;
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
    'expires_at',customer_package.expires_at,
    'duration_min',customer_package.service_duration_min_snapshot
  ) order by customer_package.purchased_at,customer_package.id),'[]'::jsonb)
  into v_packages
  from public.client_packages customer_package
  where customer_package.business_id=p_business
    and customer_package.client_id=p_client
    and customer_package.status='active'
    and customer_package.remaining>0
    and (customer_package.expires_at is null or customer_package.expires_at >= now());

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

  -- v215: the welcome offer belongs next to packages and vouchers because this
  -- is the one payload the till reads for a looked-up customer. An expired
  -- grant is withheld here rather than offered and then refused at redeem time.
  select jsonb_build_object(
    'grant_id',grant_row.id,
    'reward_label',grant_row.reward_label,
    'reward_catalog_kind',grant_row.reward_catalog_kind,
    'reward_catalog_id',grant_row.reward_catalog_id,
    'min_spend_cents',grant_row.min_spend_cents,
    'expires_at',grant_row.expires_at)
  into v_welcome
  from public.welcome_offer_grants_v215 grant_row
  where grant_row.business_id=p_business
    and grant_row.client_id=p_client
    and grant_row.status='granted'
    and (grant_row.expires_at is null or grant_row.expires_at>now());

  select jsonb_build_object('grant_id',bb.id,'reward_label',bb.reward_label,'away_days',bb.away_days,'expires_at',bb.expires_at) into v_bringback from public.bringback_grants_v361 bb where bb.business_id=p_business and bb.client_id=p_client and bb.status='granted' and (bb.expires_at is null or bb.expires_at>now()) order by bb.granted_at limit 1; select jsonb_build_object('grant_id',rg.id,'reward_label',rg.reward_label,'expires_at',rg.expires_at)
    into v_referral
    from public.referral_grants_v420 rg
   where rg.business_id=p_business and rg.client_id=p_client and rg.status='granted'
     and (rg.expires_at is null or rg.expires_at>now())
   order by rg.granted_at limit 1;
  -- nestly_v420: the referral gift joins the one payload the till reads for a looked-up customer,
  -- beside the welcome offer and the bring-back voucher it is shaped after. An expired grant is
  -- withheld here rather than offered and then refused at redeem time (v215's rule).
  return jsonb_build_object('packages',v_packages,'vouchers',v_vouchers,'welcome_offer',v_welcome,'bringback_offer',v_bringback,'referral_offer',v_referral);
end
$function$;

revoke all on function public.staff_get_customer_entitlements_v102(uuid,uuid) from public, anon;
grant execute on function public.staff_get_customer_entitlements_v102(uuid,uuid)
  to postgres, service_role, authenticated;

commit;
