/* nestly_v655 — three owner marks from the 2026-08-31 review.

   (1) A CUSTOMER CAN CANCEL A CONFIRMED BOOKING (owner photo 1: "where's the cancel appointment
       button. i need it there. X"). The Bookings screen offered Reschedule and nothing else. A
       cancel path did exist — customer_request_appointment_action(p_action=>'cancel') from v33 —
       but it FILES A REQUEST for the business to approve, and nothing on this screen ever called
       it. Owner ruling when asked: "cancel it outright". So this is a new, deliberately narrow
       function rather than a reuse: it cancels, it does not ask.
       Its guards are v508's verbatim (the reschedule the same button sits beside), because the
       two acts have identical authority requirements — the appointment must be this customer's,
       at this business, still 'booked'. Cancelling is idempotent in the only way that matters: a
       second call finds a non-booked row and answers already_actioned rather than doing anything.

   (2) EDITING AN UNSOLD PACKAGE EDITS IT (owner ruling: "edit should not create new > it should
       just edit that existing package"). v102's clone-on-edit exists to protect people who have
       ALREADY PAID: mutating a sold package in place would rewrite the price and the session count
       on receipts and wallets customers already hold. That reason does not apply to a package
       nobody has bought — and cloning one produced exactly what the owner photographed, two rows
       in the catalogue for one package, the older one dead and undeletable. So: no purchases,
       edit in place; one purchase or more, the clone-on-edit contract is untouched.

   (3) DELETING A SUPERSEDED PACKAGE WORKS (owner photo 1: "not able to delete package", with the
       generic "That change couldn't be saved" toast). Root cause, reproduced against production as
       the owner's own role: package_plans.supersedes_plan_id is ON DELETE RESTRICT, so the newer
       version pointed at the older one and the delete raised 23503. Every package that had ever
       been edited left an undeletable row behind. The delete now releases that pointer first —
       the only thing lost is the "this replaced that" provenance of a row being removed anyway —
       and the audit entry records that it did.

   Rollback suite: db/tests/v655_cancel_and_package_edit.sql */
begin;

-- ---------------------------------------------------------------------------------------------
-- (1) customer_cancel_appointment_v655
-- ---------------------------------------------------------------------------------------------
create or replace function public.customer_cancel_appointment_v655(
  p_business_slug text,
  p_appointment uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_slug text := lower(btrim(coalesce(p_business_slug, '')));
  v_business_id uuid;
  v_client_id uuid;
  v_enabled_modules text[];
  v_appt public.appointments%rowtype;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;

  -- One cancel of one appointment at a time, per customer.
  perform pg_advisory_xact_lock(hashtextextended(
    'v655:cancel:' || v_actor::text || ':' || coalesce(p_appointment::text, ''), 0));

  -- Identical to v508: business, client and identity all derive from auth.uid(); the slug only
  -- narrows the verified relationship. A customer can never reach another customer's row.
  select l.business_id, l.client_id, coalesce(b.enabled_modules, '{}'::text[])
    into v_business_id, v_client_id, v_enabled_modules
    from public.customer_identities ci
    join public.customer_links l
      on l.identity_id = ci.id
     and l.auth_user_id = v_actor
     and l.state = 'verified'
    join public.businesses b on b.id = l.business_id
   where ci.auth_user_id = v_actor
     and ci.status = 'active'
     and b.slug = v_slug
   limit 1;
  if not found or not ('appointments' = any(v_enabled_modules)) then
    raise exception 'verified customer link and appointment required' using errcode = '42501';
  end if;

  select * into v_appt
    from public.appointments a
   where a.id = p_appointment
     and a.business_id = v_business_id
     and a.client_id = v_client_id
   for update;
  if not found then
    raise exception 'verified customer link and appointment required' using errcode = '42501';
  end if;
  if v_appt.status = 'cancelled' then
    -- Replay of a successful cancel is a success, not an error: the customer asked for a state
    -- and the row is in it.
    return jsonb_build_object('status', 'ok', 'appointment_id', v_appt.id, 'replayed', true);
  end if;
  if v_appt.status <> 'booked' then
    raise exception 'already_actioned' using errcode = '22023';
  end if;

  update public.appointments
     set status = 'cancelled'
   where id = v_appt.id and business_id = v_business_id;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (v_business_id, v_actor, 'appointment.cancelled_by_customer', 'appointments', v_appt.id,
          jsonb_build_object('client_id', v_client_id, 'starts_at', v_appt.starts_at,
                             'service_id', v_appt.service_id, 'source', 'v655'));

  return jsonb_build_object('status', 'ok', 'appointment_id', v_appt.id, 'replayed', false);
end
$function$;

revoke all on function public.customer_cancel_appointment_v655(text, uuid) from public, anon;
grant execute on function public.customer_cancel_appointment_v655(text, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- (2) save_package_plan_v102 — edit in place when nobody has bought it.
--     Restated in full because CREATE OR REPLACE takes the whole body; the ONLY change is the
--     v_sold branch below. Everything else is v102/v593/v627 verbatim.
-- ---------------------------------------------------------------------------------------------
create or replace function public.save_package_plan_v102(p_business uuid, p_plan uuid, p_name text, p_price_cents integer, p_sessions integer, p_service uuid, p_active boolean, p_expiry_days integer)
 returns package_plans
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_service public.services%rowtype;
  v_plan public.package_plans%rowtype;
  v_previous public.package_plans%rowtype;
  v_sold integer;
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

    select count(*) into v_sold
      from public.client_packages cp
     where cp.business_id=p_business and cp.plan_id=v_previous.id;

    if v_sold = 0 then
      -- nestly_v655 (owner ruling: "edit should not create new > it should just edit that
      -- existing package"). Nobody has bought this plan, so there is no receipt, no wallet row
      -- and no snapshot anywhere that a change could rewrite under somebody. Cloning it here is
      -- what produced two catalogue rows for one package, the older of them dead and (until this
      -- migration) undeletable. The version number is left where it is: this is the same version
      -- of the same package, corrected, not a new one.
      update public.package_plans
         set name=btrim(p_name),
             price_cents=p_price_cents,
             sessions=p_sessions,
             service_id=p_service,
             active=p_active,
             expiry_days=p_expiry_days,
             list_unit_cents_snapshot=case when p_service is null then null
               else v_service.price_cents::bigint end,
             list_value_cents_snapshot=case when p_service is null then null
               else v_service.price_cents::bigint*p_sessions::bigint end
       where id=v_previous.id and business_id=p_business
      returning * into v_plan;
    else
      if exists(
        select 1 from public.package_plans child
        where child.business_id=p_business
          and child.supersedes_plan_id=v_previous.id
      ) then
        raise exception 'package_plan_version_superseded' using errcode='40001';
      end if;

      -- Clone-on-edit, for a SOLD plan only. Existing purchases keep their original plan FK and
      -- the snapshots taken at checkout. Only the new version becomes sellable.
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
      'edited_in_place',(p_plan is not null and coalesce(v_sold,0)=0),
      'active',v_plan.active
    )
  );
  return v_plan;
end
$function$;

-- Restate the live ACL verbatim.
revoke all on function public.save_package_plan_v102(uuid, uuid, text, integer, integer, uuid, boolean, integer) from public, anon;
grant execute on function public.save_package_plan_v102(uuid, uuid, text, integer, integer, uuid, boolean, integer) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- (3) business_manage_package_plan_v193 — a superseded plan can be deleted.
-- ---------------------------------------------------------------------------------------------
create or replace function public.business_manage_package_plan_v193(p_business uuid, p_plan uuid, p_action text, p_name text default null::text)
 returns json
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_plan public.package_plans%rowtype;
  v_sold integer;
  v_name text;
  v_retired boolean := false;
  v_released integer := 0;
begin
  if p_action not in ('rename','delete') then
    raise exception 'unsupported package action' using errcode='22023';
  end if;
  if not app.can_module_write(p_business,'packages') then
    raise exception 'packages write access is required' using errcode='42501';
  end if;

  select * into v_plan from public.package_plans
   where id=p_plan and business_id=p_business for update;
  if not found then
    raise exception 'package not found in this business' using errcode='42704';
  end if;

  select count(*) into v_sold from public.client_packages
   where business_id=p_business and plan_id=p_plan;

  if p_action='rename' then
    -- Renaming a sold package would rename it on the receipts and wallets of everybody who
    -- bought it, so this half keeps its original refusal exactly.
    if v_sold > 0 then
      raise exception 'this package has been sold to % customer(s); create a new version instead', v_sold
        using errcode='42501';
    end if;
    v_name := btrim(coalesce(p_name,''));
    if length(v_name) < 2 then
      raise exception 'give the package a name' using errcode='22023';
    end if;
    update public.package_plans set name=v_name where id=p_plan and business_id=p_business;
  elsif v_sold > 0 then
    -- nestly_v601 (owner ruling). Sold: taken off sale, never removed. The rows customers hold in
    -- client_packages are untouched, so their remaining sessions still redeem at the counter.
    -- active=false is what actually shuts the selling door (sell_package_v102 refuses an inactive
    -- plan); retired_at records that this was a decision and not a pause.
    if v_plan.retired_at is not null then
      raise exception 'this package is already off sale' using errcode='22023';
    end if;
    update public.package_plans
       set retired_at=now(), active=false
     where id=p_plan and business_id=p_business;
    v_retired := true;
  else
    -- nestly_v655 (owner photo 1: "not able to delete package"). package_plans.supersedes_plan_id
    -- is ON DELETE RESTRICT, so a plan that had ever been edited was pointed at by its own newer
    -- version and every delete raised 23503 behind a generic toast. Release the pointer first.
    -- Nothing a customer can see depends on it: it is provenance for a row being removed, and the
    -- newer version keeps its own identity, price, sessions and purchases.
    update public.package_plans
       set supersedes_plan_id=null
     where business_id=p_business and supersedes_plan_id=p_plan;
    get diagnostics v_released = row_count;
    delete from public.package_plans where id=p_plan and business_id=p_business;
  end if;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, auth.uid(),
          'package_plan.'||case when v_retired then 'retire' else p_action end,
          'package_plans', p_plan,
          jsonb_build_object('was_sold', v_sold, 'name', coalesce(v_name, v_plan.name),
                             'retired', v_retired, 'versions_unlinked', v_released));

  return json_build_object('status','ok',
    'action', case when v_retired then 'retire' else p_action end,
    'plan_id', p_plan, 'sold_to', v_sold, 'versions_unlinked', v_released);
end
$function$;

-- Restate the live ACL verbatim.
revoke all on function public.business_manage_package_plan_v193(uuid, uuid, text, text) from public, anon;
grant execute on function public.business_manage_package_plan_v193(uuid, uuid, text, text) to authenticated, service_role;

commit;
