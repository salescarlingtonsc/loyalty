-- nestly_v603 — Customer packages says when it was bought, when it was last used, and can show
-- one package's own history.
--
-- OWNER (Customer packages photo): "Add! Date Bought dd/mm/yy | Last Used dd/mm/yy" between
-- Package and Left, "History" beside Use session, and a line from the per-row History down to the
-- "Recent session correction history" block at the bottom. Asked which was meant; owner chose
-- "Per-row History, delete the section" — every row carries its own, so the shared block goes.
--
-- Date bought was already in the payload and only needed rendering. This migration adds the two
-- things the screen could not have known:
--
-- 1. last_used_at on each package. A consumption that was later UNDONE is not a use, so reversed
--    rows are excluded — otherwise a package whose only session was refunded by mistake would
--    read as recently used and nobody would chase it.
--
-- 2. staff_package_session_history_v603, one package's own sessions. The page already loads a
--    business-wide reversal workflow, but its rows are sales and carry no link back to the
--    package they spent, so they cannot be grouped per row. This reads
--    package_session_consumptions, which holds exactly that link, and returns the SALE id each
--    row was recorded against so the existing Undo session use button keeps working unchanged.
--
-- Rollback: db/tests/v603_package_history_and_dates.sql

begin;

CREATE OR REPLACE FUNCTION public.staff_list_package_entitlements_v102(p_business uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
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
      'purchased_at',customer_package.purchased_at,
      -- nestly_v603 (owner photo: "Add! Date Bought dd/mm/yy | Last Used dd/mm/yy"). Date bought
      -- was already here; last used was not, and it is the column that tells a member of staff
      -- whether a package is being worked through or has gone quiet. A consumption that was later
      -- undone is not a use, so reversed rows are excluded rather than counted.
      'last_used_at',(
        select max(used.created_at)
          from public.package_session_consumptions used
         where used.client_package_id=customer_package.id
           and used.business_id=customer_package.business_id
           and not exists(
             select 1 from public.package_session_reversals undone
              where undone.consumption_id=used.id))
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
grant execute on function public.staff_list_package_entitlements_v102(uuid) to authenticated, service_role;

create or replace function public.staff_package_session_history_v603(
  p_business uuid, p_client_package uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_package public.client_packages%rowtype;
begin
  if not app.can_module(p_business,'packages') then
    raise exception 'packages access is required' using errcode='42501';
  end if;
  select * into v_package from public.client_packages
   where id=p_client_package and business_id=p_business;
  if not found then
    raise exception 'package not found in this business' using errcode='42704';
  end if;

  return jsonb_build_object(
    'client_package_id',v_package.id,
    'plan_name',v_package.plan_name_snapshot,
    'sessions',v_package.sessions_snapshot,
    'remaining',v_package.remaining,
    'purchased_at',v_package.purchased_at,
    'expires_at',v_package.expires_at,
    'sessions_used',coalesce((
      select jsonb_agg(jsonb_build_object(
        'consumption_id',used.id,
        'sale_id',used.sale_id,
        'used_at',used.created_at,
        'remaining_after',used.remaining_after,
        -- The undo is reported per row rather than inferred from the count, so a package with one
        -- use and one undo cannot read as two separate events.
        'reversed',exists(select 1 from public.package_session_reversals undone
                           where undone.consumption_id=used.id),
        'reversed_at',(select max(undone.created_at) from public.package_session_reversals undone
                        where undone.consumption_id=used.id)
      ) order by used.created_at desc)
      from public.package_session_consumptions used
     where used.client_package_id=v_package.id
       and used.business_id=p_business),'[]'::jsonb)
  );
end
$function$;

revoke all on function public.staff_package_session_history_v603(uuid, uuid) from public, anon;
grant execute on function public.staff_package_session_history_v603(uuid, uuid) to authenticated, service_role;

commit;
