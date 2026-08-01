-- NESTLY V127 - PERMISSION-SAFE PUBLISHED BIRTHDAY READER
--
-- Local forward-only review candidate. The published birthday table remains
-- browser-closed. This replaces the existing narrow RPC so an active staff
-- member with effective Loyalty read access can see the same non-customer,
-- published programme copy in the unified Rewards overview. It does not grant
-- table access, expose dates of birth or entitlements, or add write authority.

begin;

create or replace function public.get_active_birthday_program(
  p_business_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_version uuid;
  v_as_of timestamptz:=statement_timestamp();
begin
  if auth.uid() is null
     or not app.can_module_read(p_business_id, 'loyalty') then
    raise exception 'loyalty read access required' using errcode = '42501';
  end if;

  select business.active_config_version_id into v_version
    from public.businesses business
   where business.id = p_business_id;

  if v_version is null then
    return jsonb_build_object(
      'status','unavailable','as_of',v_as_of,'programs','[]'::jsonb
    );
  end if;

  return jsonb_build_object(
    'status','published',
    'as_of',v_as_of,
    'programs',coalesce((
      select jsonb_agg(jsonb_build_object(
        'program_id',program.program_id,
        'active',program.active,
        'customer_label',program.customer_label,
        'customer_description',program.customer_description,
        'customer_terms',program.customer_terms,
        'fulfillment_kind',program.fulfillment_kind,
        'discount_percent',program.discount_percent,
        'manual_item',program.manual_item,
        'window_days_before',program.window_days_before,
        'window_days_after',program.window_days_after,
        'sort',program.sort
      ) order by program.sort,program.program_id)
        from public.birthday_program_versions program
       where program.business_id = p_business_id
         and program.config_version_id = v_version
    ),'[]'::jsonb)
  );
end
$$;

comment on function public.get_active_birthday_program(uuid) is
  'Returns non-customer published birthday programme copy to active staff with effective Loyalty read access; the underlying table remains browser-closed.';

revoke all on function public.get_active_birthday_program(uuid)
  from public, anon, authenticated;
grant execute on function public.get_active_birthday_program(uuid)
  to authenticated;

commit;
