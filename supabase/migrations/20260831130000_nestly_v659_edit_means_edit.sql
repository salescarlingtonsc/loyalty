/* nestly_v659 — EDITING A PACKAGE EDITS IT, AND A BUYER SEES ONLY WHAT THEY BOUGHT.
   Owner ruling, 2026-08-31, given twice:
     "edit should not create new > it should just edit that existing package"
     "editing or deleting any packages should not affect packages that are sold, the business
      should honour what is already sold, nothing change for customers who bought the package"

   Those two read as a contradiction only while one reader is wrong, and one was.
   public.client_packages captures the name, version, sessions, price, service, list value and
   expiry AT THE MOMENT OF SALE. Every staff-facing reader already uses those snapshots — the
   Customer packages page (staff_list_package_entitlements_v102), the till
   (staff_get_customer_entitlements_v102), the session history (staff_package_session_history_v603)
   and the receipt line written by v634. The single exception was the BUYER'S OWN wallet card:
   customer_get_packages joined package_plans and read pp.name and pp.sessions live.

   So (1) that reader is pointed at the snapshot, which also fixes a bug older than this batch —
   `remaining` is stored on the purchase while the denominator was live, so raising a plan from 5
   sessions to 10 made a fully-used package read "0 of 10 left" on the customer's card — and
   (2) save_package_plan_v102 stops cloning altogether. v102 cloned on every edit and v655
   narrowed it to sold plans; with nothing a buyer can see coming from the plan row, cloning
   protects nobody and leaves a dead second catalogue row the owner cannot use, which is exactly
   what they photographed.

   NOT changed, deliberately: package_branches is keyed on the live plan id, so changing WHERE a
   package may be redeemed still reaches existing buyers. That is a different writer, and a
   business closing a branch legitimately affects redemption there.

   Rollback suite: db/tests/v659_edit_means_edit.sql */
begin;

CREATE OR REPLACE FUNCTION public.save_package_plan_v102(p_business uuid, p_plan uuid, p_name text, p_price_cents integer, p_sessions integer, p_service uuid, p_active boolean, p_expiry_days integer)
 RETURNS package_plans
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
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

    /* nestly_v659 — EDIT MEANS EDIT (owner ruling, twice: "edit should not create new > it should
       just edit that existing package", then "editing or deleting any packages should not affect
       packages that are sold ... nothing change for customers who bought the package").
       v102 cloned on every edit and v655 narrowed that to SOLD plans only, both out of a fear that
       a sold plan's edit would rewrite what a buyer already holds. Tracing every reader of
       client_packages showed exactly one place where it could: customer_get_packages took the
       plan's NAME and SESSION COUNT from the live row. This migration points that reader at the
       purchase snapshot, like the Customer packages page, the till, the session history and the
       receipt line already do.
       With that closed, nothing a buyer can see comes from this row — their name, sessions, price,
       service, list value and expiry were all captured on client_packages at the moment of sale —
       so cloning protects nobody, and it cost the owner a second, permanently dead catalogue row
       for every edit. Clone-on-edit is retired, not weakened; the buyer's protection is the
       snapshot, and it is unchanged.
       ONE thing genuinely does still reach an existing buyer and is deliberately left alone:
       package_branches is keyed on the live plan id, so changing WHERE a package may be redeemed
       changes it for people who already bought. That is a different writer
       (saveCatalogueBranchesV627), and a business closing a branch legitimately affects redemption
       there. */
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
      'edited_in_place',(p_plan is not null),
      'sold_to',coalesce(v_sold,0),
      'active',v_plan.active
    )
  );
  return v_plan;
end
$function$
;

-- Restate the live ACL verbatim.
revoke all on function public.save_package_plan_v102(uuid, uuid, text, integer, integer, uuid, boolean, integer) from public, anon;
grant execute on function public.save_package_plan_v102(uuid, uuid, text, integer, integer, uuid, boolean, integer) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.customer_get_packages(p_business_slug text, p_cursor jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_context record;
  v_cursor jsonb := coalesce(p_cursor, '{}'::jsonb);
  v_limit integer := 20;
  v_before_at timestamptz;
  v_before_id uuid;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if jsonb_typeof(v_cursor) <> 'object' then
    raise exception 'invalid packages cursor' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_object_keys(v_cursor) as keys(key) where key not in ('limit','before_at','before_id')) then
    raise exception 'invalid packages cursor' using errcode = '22023';
  end if;
  begin
    v_limit := least(greatest(coalesce((v_cursor->>'limit')::integer, 20), 1), 50);
    v_before_at := nullif(v_cursor->>'before_at', '')::timestamptz;
    v_before_id := nullif(v_cursor->>'before_id', '')::uuid;
  exception when others then
    raise exception 'invalid packages cursor' using errcode = '22023';
  end;
  if (v_before_at is null) <> (v_before_id is null) then
    raise exception 'packages cursor is incomplete' using errcode = '22023';
  end if;

  select * into v_context from app.v32_customer_wallet_context(p_business_slug) limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;
  if not ('packages' = any(v_context.enabled_modules)) then
    raise exception 'packages module is unavailable for this business' using errcode = '42501';
  end if;

  with packages as (
    select cp.id,
           coalesce(nullif(to_jsonb(cp)->>'purchased_at','')::timestamptz,
                    nullif(to_jsonb(cp)->>'created_at','')::timestamptz,
                    'epoch'::timestamptz) as sort_at,
           nullif(to_jsonb(cp)->>'purchased_at','')::timestamptz as purchased_at,
           nullif(to_jsonb(cp)->>'expires_at','')::timestamptz as expires_at,
           /* nestly_v659 (owner ruling: "editing or deleting any packages should not affect
              packages that are sold ... nothing change for customers who bought the package").
              This was the ONE reader anywhere that took a buyer's package facts from the LIVE
              plan row instead of the snapshot written at purchase. Every other reader — the
              Customer packages page, the till, the session history, the receipt line — already
              uses these snapshot columns, which is why editing a sold plan changed nothing
              anywhere except here.
              It also fixes a bug that predates all of this: `remaining` is stored on the purchase
              while the denominator was live, so an owner raising a plan from 5 sessions to 10 made
              a fully-used package read "0 of 10 left" on the buyer's own card. Both halves of the
              fraction now come from the same purchase. */
           cp.plan_name_snapshot as plan_name, cp.sessions_snapshot as sessions_purchased,
           cp.remaining as sessions_remaining, cp.status,
           coalesce((
             select jsonb_agg(jsonb_build_object(
               'used_at', history.created_at,
               'remaining_after', history.remaining_after,
               'status', case when history.reversed then 'reversed' else 'used' end
             ) order by history.created_at desc)
             from (
               select use.created_at, use.remaining_after,
                      exists (select 1 from public.package_session_reversals rev
                               where rev.business_id = use.business_id and rev.consumption_id = use.id) as reversed
                 from public.package_session_consumptions use
                where use.business_id = v_context.business_id
                  and use.client_id = v_context.client_id
                  and use.client_package_id = cp.id
                order by use.created_at desc, use.id desc
                limit 10
             ) history
           ), '[]'::jsonb) as usage_history
      from public.client_packages cp
      /* Nothing is selected from the plan any more, so the join goes. It was an INNER join, which
         meant a buyer's package vanished from their own wallet if the plan row were ever removed —
         the snapshot is the record of what they bought, and it stands on its own. */
     where cp.business_id = v_context.business_id
       and cp.client_id = v_context.client_id
  ), eligible as (
    select * from packages
     where v_before_at is null or (sort_at, id) < (v_before_at, v_before_id)
     order by sort_at desc, id desc limit v_limit + 1
  ), visible as (
    select * from eligible order by sort_at desc, id desc limit v_limit
  )
  select jsonb_build_object(
    'items', coalesce((select jsonb_agg(jsonb_build_object(
      'plan_name', plan_name, 'sessions_purchased', sessions_purchased,
      'sessions_remaining', sessions_remaining, 'status', status,
      'purchased_at', purchased_at, 'expires_at', expires_at,
      'usage_history', usage_history
    ) order by sort_at desc, id desc) from visible), '[]'::jsonb),
    'next_cursor', case when (select count(*) from eligible) > v_limit then (
      select jsonb_build_object('before_at', sort_at, 'before_id', id, 'limit', v_limit)
        from visible order by sort_at, id limit 1
    ) else null end
  ) into v_result;

  return v_result;
end;
$function$
;

-- Restate the live ACL verbatim.
revoke all on function public.customer_get_packages(text, jsonb) from public, anon;
grant execute on function public.customer_get_packages(text, jsonb) to authenticated, service_role;

commit;
