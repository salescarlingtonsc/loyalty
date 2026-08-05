-- Peekaa V167 phase 3: safe repeat-booking preference and explicit package history provenance.
-- Forward repair: re-create these additive RPCs. Rollback: revoke/drop only these V167 RPCs.

begin;

create or replace function public.customer_get_repeat_booking_preference_v167(
  p_business_slug text,
  p_appointment uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_context record;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if p_business_slug is null or p_appointment is null then
    raise exception 'invalid repeat booking request' using errcode = '22023';
  end if;

  select * into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'business_slug', v_context.business_slug,
    'appointment_id', appointment.id,
    'service_id', service.id,
    'service_name', service.name,
    'staff_id', staff_member.id,
    'staff_name', staff_member.full_name
  ) into v_result
    from public.appointments appointment
    join public.services service
      on service.business_id = appointment.business_id
     and service.id = appointment.service_id
     and service.active
     and service.show_on_booking_page
    left join public.staff staff_member
      on staff_member.business_id = appointment.business_id
     and staff_member.id = appointment.staff_id
     and staff_member.active
     and appointment.branch_id is not null
     and exists (
       select 1
         from public.staff_branches assignment
        where assignment.business_id = appointment.business_id
          and assignment.branch_id = appointment.branch_id
          and assignment.staff_id = staff_member.id
     )
     and (
       not exists (
         select 1
           from public.staff_services configured
          where configured.business_id = appointment.business_id
            and configured.service_id = appointment.service_id
       )
       or exists (
         select 1
           from public.staff_services qualified
          where qualified.business_id = appointment.business_id
            and qualified.service_id = appointment.service_id
            and qualified.staff_id = staff_member.id
       )
     )
   where appointment.business_id = v_context.business_id
     and appointment.client_id = v_context.client_id
     and appointment.id = p_appointment
     and appointment.status = 'completed'
     and appointment.starts_at < statement_timestamp();

  return coalesce(v_result, jsonb_build_object(
    'business_slug', v_context.business_slug,
    'appointment_id', p_appointment,
    'service_id', null,
    'service_name', null,
    'staff_id', null,
    'staff_name', null
  ));
end;
$$;

create or replace function public.customer_get_transaction_history_v167(
  p_business_slug text,
  p_cursor jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_context record;
  v_result jsonb;
  v_items jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;

  select * into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  v_result := public.customer_get_transaction_history_v81(p_business_slug, p_cursor);

  select coalesce(jsonb_agg(
    case
      when item->>'source_kind' = 'sale' and package_use.id is not null then
        item || jsonb_build_object(
          'is_package_session', true,
          'package_name', customer_package.plan_name_snapshot,
          'package_purchased_at', customer_package.purchased_at,
          'package_reference', left(customer_package.id::text, 8)
        )
      else item || jsonb_build_object('is_package_session', false)
    end
    order by ordinal
  ), '[]'::jsonb) into v_items
    from jsonb_array_elements(coalesce(v_result->'items', '[]'::jsonb))
         with ordinality listed(item, ordinal)
    left join public.package_session_consumptions package_use
      on listed.item->>'source_kind' = 'sale'
     and package_use.business_id = v_context.business_id
     and package_use.client_id = v_context.client_id
     and package_use.sale_id = nullif(listed.item->>'source_id', '')::uuid
    left join public.client_packages customer_package
      on customer_package.business_id = package_use.business_id
     and customer_package.client_id = package_use.client_id
     and customer_package.id = package_use.client_package_id;

  return jsonb_set(v_result, '{items}', v_items, true);
end;
$$;

revoke all on function public.customer_get_repeat_booking_preference_v167(text, uuid)
  from public, anon, authenticated;
revoke all on function public.customer_get_transaction_history_v167(text, jsonb)
  from public, anon, authenticated;
grant execute on function public.customer_get_repeat_booking_preference_v167(text, uuid)
  to authenticated;
grant execute on function public.customer_get_transaction_history_v167(text, jsonb)
  to authenticated;

commit;
