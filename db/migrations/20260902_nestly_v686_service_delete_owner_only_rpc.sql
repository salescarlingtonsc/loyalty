/* nestly_v686 — hard-deleting a service is owner-only at the RPC too, and "unused" now
   includes the two references that were being ignored.

   Audit finding F068 (P2, confirmed against production read-only on 2026-09-02:
   pg_get_functiondef on public.business_manage_catalogue_item_v660 matches the repo byte for
   byte, and policy services_delete_v636 is live on public.services).

   THE DEFECT — a SECURITY DEFINER route around a one-day-old ruling.
     nestly_v636 (20260830) deliberately narrowed raw DELETE on public.services to staff with
     role='owner', for a reason it states itself: "sale_items.ref_id has no FK, so deletion
     orphans every historical line and the Phase C taxonomy mapping target." Soft retire stayed
     open to everyone with services write; the permanent act became the owner's alone.

     One day later nestly_v660 gave the Services page a Delete button backed by
     public.business_manage_catalogue_item_v660. That function is SECURITY DEFINER, so RLS —
     and therefore services_delete_v636 — never applies to the DELETE it runs. Its only
     authorisation check is app.can_module_write(p_business,'services'), which every staff
     member holds by default (staff.modules NULL = full access, staff_module_mode_v94). So any
     invited, approved teammate of any role could permanently destroy a service, which is
     exactly what v636 had been written to prevent. The client never gated it either: the row's
     Delete button was rendered on canWrite, not on ownership.

     The blast radius was widened by an incomplete definition of "used". The retire-vs-delete
     decision is made by counting live references, and the count omitted:
       · public.service_canonical_map — the Phase C taxonomy mapping v636's own comment names.
         Its service_id has NO foreign key, so a delete leaves a mapping pointing at nothing and
         every future stamping read resolves a service that is gone.
       · public.service_products — the consumption recipe (v8). Its FK is ON DELETE CASCADE, so
         a delete silently takes the recipe with it, which is precisely the class of quiet
         collateral ("a bundle that quietly loses a member still charges the bundle price") that
         v660's own header says the count exists to prevent.
     A service that was mapped to a canonical node but had never been sold therefore counted as
     zero-referenced and was hard-deleted rather than retired.

   THE FIX — two changes, both inside the one function, nothing else moved.
     1. The hard-delete branch for a SERVICE now requires app.is_salon_owner(p_business), the
        canonical owner predicate (approved + active owner staff in an open workspace). That is
        the same authority services_delete_v636 asserts, restated where SECURITY DEFINER made
        the policy unreachable. Everything else is untouched: the retire branch (active=false,
        retired_at=now()) stays open to any staff with module write, matching the RLS UPDATE
        policy and the everyday workflow, and the module-write gate still runs first for every
        action so a non-services staff member is still refused before anything is read.
     2. service_canonical_map and service_products join the service reference count. The effect
        is not a new refusal — it is that a mapped-but-unsold service is now RETIRED and kept,
        with the decision recorded in retired_at and audit_log, instead of being destroyed.

   NOT CHANGED, deliberately:
     · Products. v636 was a ruling about services only, and there is no owner-only DELETE policy
       on public.products (its live policy set has no DELETE-specific owner gate). Extending an
       owner requirement to product deletion would be a new product decision, not the repair of
       a bypass, so the product branch keeps exactly the behaviour it shipped with.
     · The error code. A refused delete raises 42501, the same code the module gate raises, so
       the client's existing failure handling needs no new case.
     · The audit row, the return shape, the 22023/42704 errors and the `for update` lock: all
       identical, so every existing caller and the v660 rollback suite still read the same JSON.

   Client: app/app.js servicesPage now renders Delete only for S.myRole==='owner' (the same
   test canUploadCatalogueMedia already uses on that page), so a non-owner sees Edit alone
   rather than a button the server will refuse.

   Rollback suite: db/tests/v686_service_delete_owner_only_rpc.sql */
begin;

create or replace function public.business_manage_catalogue_item_v660(
  p_business uuid, p_kind text, p_item uuid, p_action text)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_kind text := lower(btrim(coalesce(p_kind, '')));
  v_used integer := 0;
  v_name text;
  v_active boolean;
  v_retired timestamptz;
  v_retiring boolean := false;
begin
  if p_action <> 'delete' then
    raise exception 'unsupported catalogue action' using errcode = '22023';
  end if;
  if v_kind not in ('service','product') then
    raise exception 'catalogue item must be a service or a product' using errcode = '22023';
  end if;
  -- Each catalogue lives behind its own module, exactly as its page does.
  if not app.can_module_write(p_business, case when v_kind = 'service' then 'services' else 'inventory' end) then
    raise exception 'catalogue write access is required' using errcode = '42501';
  end if;

  if v_kind = 'service' then
    select name, active, retired_at into v_name, v_active, v_retired
      from public.services where id = p_item and business_id = p_business for update;
    if not found then raise exception 'service not found in this business' using errcode = '42704'; end if;
    select
      (select count(*) from public.appointment_services x where x.service_id = p_item)
    + (select count(*) from public.appointments x where x.service_id = p_item)
    + (select count(*) from public.booking_requests x where x.service_id = p_item)
    + (select count(*) from public.waitlist x where x.service_id = p_item)
    + (select count(*) from public.package_plans x where x.service_id = p_item)
    + (select count(*) from public.loyalty_reward_services x where x.service_id = p_item)
    + (select count(*) from public.bundle_items x where x.service_id = p_item)
    + (select count(*) from public.tier_benefit_scope_v656 x where x.service_id = p_item)
    + (select count(*) from public.sale_items x where x.business_id = p_business and x.ref_id = p_item)
    /* nestly_v686. service_canonical_map.service_id has no FK, so a delete strands the Phase C
       mapping v636's own comment names; service_products cascades, so a delete silently takes
       the consumption recipe with it. Both make a service "used": it is retired, not removed. */
    + (select count(*) from public.service_canonical_map x
        where x.business_id = p_business and x.service_id = p_item)
    + (select count(*) from public.service_products x where x.service_id = p_item)
      into v_used;
  else
    select name, active, retired_at into v_name, v_active, v_retired
      from public.products where id = p_item and business_id = p_business for update;
    if not found then raise exception 'product not found in this business' using errcode = '42704'; end if;
    select
      (select count(*) from public.sale_items x where x.product_id = p_item)
    + (select count(*) from public.sales x where x.product_id = p_item)
    + (select count(*) from public.stock_batches x where x.product_id = p_item)
    + (select count(*) from public.bar_bottles x where x.product_id = p_item)
    + (select count(*) from public.loyalty_reward_products x where x.product_id = p_item)
    + (select count(*) from public.bundle_items x where x.product_id = p_item)
    + (select count(*) from public.tier_benefit_scope_v656 x where x.product_id = p_item)
    + (select count(*) from public.tier_benefits_v365 x where x.product_id = p_item)
    + (select count(*) from public.service_products x where x.product_id = p_item)
      into v_used;
  end if;

  if v_used > 0 then
    if v_retired is not null then
      raise exception 'this item is already off sale' using errcode = '22023';
    end if;
    v_retiring := true;
    if v_kind = 'service' then
      update public.services set active = false, retired_at = now()
       where id = p_item and business_id = p_business;
    else
      update public.products set active = false, retired_at = now()
       where id = p_item and business_id = p_business;
    end if;
  else
    /* nestly_v686. This is the permanent act, and for a service it is the owner's alone —
       policy services_delete_v636 says so, and SECURITY DEFINER is why the policy could not say
       it here. Retiring above stays open to anyone with services write, matching the RLS UPDATE
       policy; only destroying the row is narrowed. */
    if v_kind = 'service' and not app.is_salon_owner(p_business) then
      raise exception 'only the owner can permanently delete a service' using errcode = '42501';
    end if;
    if v_kind = 'service' then
      delete from public.services where id = p_item and business_id = p_business;
    else
      delete from public.products where id = p_item and business_id = p_business;
    end if;
  end if;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values(p_business, auth.uid(),
         v_kind || '.' || case when v_retiring then 'retire' else 'delete' end,
         case when v_kind = 'service' then 'services' else 'products' end, p_item,
         jsonb_build_object('name', v_name, 'used_by', v_used, 'retired', v_retiring));

  return json_build_object('status','ok','kind',v_kind,
    'action', case when v_retiring then 'retire' else 'delete' end,
    'item_id', p_item, 'used_by', v_used);
end
$function$;

/* The live grant, restated verbatim (production today: EXECUTE to authenticated and
   service_role, and to nobody else). */
revoke all on function public.business_manage_catalogue_item_v660(uuid, text, uuid, text) from public, anon;
grant execute on function public.business_manage_catalogue_item_v660(uuid, text, uuid, text) to authenticated, service_role;

-- =============================================================================================
-- Prove the code change took, in the same transaction that made it.
-- =============================================================================================
do $verify$
declare
  v_def text := pg_get_functiondef(
    'public.business_manage_catalogue_item_v660(uuid,text,uuid,text)'::regprocedure);
begin
  if position('is_salon_owner' in v_def) = 0 then
    raise exception 'nestly_v686: the catalogue RPC still hard-deletes a service without an owner check'
      using errcode = 'XX001';
  end if;
  if position('service_canonical_map' in v_def) = 0 then
    raise exception 'nestly_v686: the service reference count still ignores the canonical mapping'
      using errcode = 'XX001';
  end if;
  /* service_products must be counted from BOTH sides now: once by product_id (v660) and once by
     service_id (v682). Two occurrences, not one. */
  if (length(v_def) - length(replace(v_def, 'public.service_products', '')))
     / length('public.service_products') <> 2 then
    raise exception 'nestly_v686: the service reference count still ignores the consumption recipe'
      using errcode = 'XX001';
  end if;
  if exists (select 1 from information_schema.routine_privileges
              where routine_schema = 'public'
                and routine_name = 'business_manage_catalogue_item_v660'
                and grantee in ('anon','PUBLIC')) then
    raise exception 'nestly_v686: the catalogue RPC is reachable anonymously' using errcode = 'XX001';
  end if;
end
$verify$;

commit;
