-- nestly_v613 — a package built for one customer, and only that customer.
--
-- Owner ruling (photo, Customer packages): "some customer need customise package which is not in
-- package list" + "+ Customise Package", confirmed 2026-08-30 as "a one-off package for that
-- customer: staff pick services + number of sessions + a price, and it is sold to that one
-- customer only. It never appears in the Packages catalogue."
--
-- The shape follows from three facts about what already exists.
--
-- 1. An entitlement is public.client_packages, and client_packages.plan_id is NOT NULL and
--    references package_plans. Every reader, every snapshot, the expiry clock, the purchase
--    count that decides whether a plan may still be renamed — all of them are keyed off that
--    plan. Making plan_id nullable to express "this one had no plan" would put a null branch
--    into each of them for the sake of a row that is otherwise ordinary.
--    So a bespoke package IS a plan. It is simply a plan belonging to one client.
--
-- 2. What "never appears in the catalogue" has to mean is therefore a FILTER, and the honest
--    place for it is a column that says who the plan was made for. package_plans.bespoke_for_client
--    is NULL for every plan that has ever existed and for every catalogue plan minted from now
--    on; it is a client id for a one-off. The two catalogue readers in the browser (the Packages
--    page and the till's sellable list) both exclude non-NULL rows in the same change.
--
-- 3. Creating the plan and selling it must be ONE transaction. A plan created and not sold would
--    be an invisible orphan — invisible precisely because of (2) — that no screen could ever show
--    or clean up. sell_bespoke_package_v613 therefore mints the plan and then delegates the sale
--    to public.sell_package_v102 unchanged: the same authorization, the same branch and
--    service-availability checks, the same snapshots, the same idempotency record, the same
--    v593 expiry clock. Nothing about how a package is SOLD is re-implemented here, which is the
--    only reason this is a small migration.
--
-- Idempotency is honoured before the plan is minted, not after: a replayed key returns the first
-- call's result and mints nothing, so a double-tapped counter cannot leave a second hidden plan
-- behind. The advisory lock is the SAME key sell_package_v102 takes, so two concurrent calls with
-- one key serialize against each other rather than racing between the check and the insert.
--
-- ROLLBACK: db/tests/v613_bespoke_customer_package.sql

begin;

do $pre$
begin
  if to_regprocedure('public.sell_package_v102(uuid,uuid,uuid,uuid,uuid)') is null then
    raise exception 'v613: public.sell_package_v102 is missing — the sale this delegates to';
  end if;
  if to_regclass('public.package_plans') is null or to_regclass('public.clients') is null then
    raise exception 'v613: expected tables are absent';
  end if;
end
$pre$;

-- ---------------------------------------------------------------------------
-- 1. Who the plan was made for
-- ---------------------------------------------------------------------------
alter table public.package_plans
  add column if not exists bespoke_for_client uuid references public.clients(id);

-- Partial: catalogue plans are the overwhelming majority and carry NULL, so indexing them would
-- be indexing the whole table to answer a question about a handful of rows.
create index if not exists package_plans_bespoke_for_client_idx
  on public.package_plans(business_id, bespoke_for_client)
  where bespoke_for_client is not null;

comment on column public.package_plans.bespoke_for_client is
  'nestly_v613: the one client this plan was built for. NULL = an ordinary catalogue package. A non-NULL row is excluded from every catalogue listing and is sellable only through sell_bespoke_package_v613.';

-- ---------------------------------------------------------------------------
-- 2. sell_bespoke_package_v613 — mint the plan and sell it, once
-- ---------------------------------------------------------------------------
create or replace function public.sell_bespoke_package_v613(
  p_business uuid,
  p_client uuid,
  p_name text,
  p_price_cents integer,
  p_sessions integer,
  p_service uuid,
  p_expiry_days integer,
  p_branch uuid,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_service public.services%rowtype;
  v_existing public.sale_intent_operations%rowtype;
  v_plan public.package_plans%rowtype;
begin
  if v_actor is null or p_idempotency_key is null then
    raise exception 'authenticated staff and idempotency key required'
      using errcode='42501';
  end if;
  -- The same two gates sell_package_v102 applies. Checked here as well as there so a caller who
  -- may not sell cannot mint a plan row on the way to being refused.
  if not app.has_perm(p_business,'create_sales')
     or not (
       app.can_module_write(p_business,'till')
       or app.can_module_write(p_business,'sales')
       or app.can_module_write(p_business,'packages')
     ) then
    raise exception 'package checkout authorization required' using errcode='42501';
  end if;
  if p_client is null or not exists(
    select 1 from public.clients client
    where client.id=p_client and client.business_id=p_business
  ) then
    raise exception 'package_sale_client_invalid' using errcode='22023';
  end if;
  -- Same validation as save_package_plan_v102, stated here because that function is not the one
  -- minting this row and two writers must not disagree about what a legal package is.
  if p_name is null or length(btrim(p_name)) not between 2 and 120 then
    raise exception 'package_name_invalid' using errcode='22023';
  end if;
  if p_price_cents is null or p_price_cents < 0 then
    raise exception 'package_price_invalid' using errcode='22023';
  end if;
  if p_sessions is null or p_sessions < 1 or p_sessions > 1000 then
    raise exception 'package_sessions_invalid' using errcode='22023';
  end if;
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

  -- The lock and the replay check come BEFORE the insert, and the lock is sell_package_v102's own
  -- key, so a replay returns that call's result without minting a second hidden plan and two
  -- concurrent calls on one key cannot both pass the check.
  perform pg_advisory_xact_lock(hashtextextended(
    'v102:package-sale:'||p_business::text||':'||p_idempotency_key::text,0
  ));
  select * into v_existing
  from public.sale_intent_operations operation
  where operation.business_id=p_business
    and operation.idempotency_key=p_idempotency_key
  for share;
  if found then
    if v_existing.actor is distinct from v_actor
       or v_existing.operation_type<>'package_sale' then
      raise exception 'package sale idempotency key conflict' using errcode='23505';
    end if;
    return v_existing.result;
  end if;

  -- version_no 1 and no supersedes: a one-off is never edited into a second version, because the
  -- only customer it could affect has already bought it.
  insert into public.package_plans(
    business_id,name,price_cents,sessions,service_id,active,
    list_unit_cents_snapshot,list_value_cents_snapshot,
    version_no,supersedes_plan_id,expiry_days,bespoke_for_client
  ) values(
    p_business,btrim(p_name),p_price_cents,p_sessions,p_service,true,
    case when p_service is null then null else v_service.price_cents::bigint end,
    case when p_service is null then null
      else v_service.price_cents::bigint*p_sessions::bigint end,
    1,null,p_expiry_days,p_client
  ) returning * into v_plan;

  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values(
    p_business,v_actor,'PACKAGE_PLAN_BESPOKE_V613','package_plans',v_plan.id,
    jsonb_build_object(
      'client_id',p_client,
      'service_id',v_plan.service_id,
      'sessions',v_plan.sessions,
      'price_cents',v_plan.price_cents,
      'expiry_days',v_plan.expiry_days
    )
  );

  -- One transaction: if the sale refuses (a branch that does not offer the service, a missing
  -- staff identity), the plan minted above is rolled back with it.
  return public.sell_package_v102(p_business,p_client,v_plan.id,p_branch,p_idempotency_key);
end
$function$;

revoke all on function public.sell_bespoke_package_v613(
  uuid,uuid,text,integer,integer,uuid,integer,uuid,uuid) from public, anon;
grant execute on function public.sell_bespoke_package_v613(
  uuid,uuid,text,integer,integer,uuid,integer,uuid,uuid)
  to postgres, service_role, authenticated;

commit;
