-- FRENLY v38 - CUSTOMER PERSONAS AND PRIVATE FEATURE GATES
--
-- Local review candidate. This adds the safe persona resolver used by the
-- frontend route switcher. It intentionally returns no client IDs, contacts,
-- notes, balances, or cross-firm totals.

begin;

insert into app.platform_feature_flags(feature_key, enabled) values
  ('customer_identity', false),
  ('customer_claims', false),
  ('customer_email_otp', false)
on conflict (feature_key) do nothing;

-- Authenticated clients may learn only whether a global customer surface is
-- available. The private flag table, operator identity, and change history stay
-- inaccessible. This is the normal UI authority; the browser constant is only
-- an emergency fail-closed kill switch.
create or replace function public.get_customer_feature_capabilities()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if auth.uid() is null then
    raise exception 'authenticated session required' using errcode = '28000';
  end if;
  return jsonb_build_object(
    'customer_identity', app.platform_feature_enabled('customer_identity'),
    'customer_claims', app.platform_feature_enabled('customer_claims'),
    'customer_wallet', app.platform_feature_enabled('customer_wallet'),
    'customer_actions', app.platform_feature_enabled('customer_actions'),
    'customer_notifications', app.platform_feature_enabled('customer_notifications'),
    'customer_email_otp', app.platform_feature_enabled('customer_email_otp')
  );
end $$;

revoke all on function public.get_customer_feature_capabilities() from public, anon;
grant execute on function public.get_customer_feature_capabilities() to authenticated;

create or replace function public.get_my_personas()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_staff jsonb := '[]'::jsonb;
  v_customer jsonb := '[]'::jsonb;
  v_default_route text := '#/';
begin
  if v_actor is null then
    raise exception 'authenticated session required' using errcode = '28000';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'business_slug', b.slug,
    'business_name', b.name,
    'role', s.role,
    'modules', case
      when s.role = 'owner' then coalesce(b.enabled_modules, '{}'::text[])
      when s.modules is null then coalesce(b.enabled_modules, '{}'::text[])
      else (
        select coalesce(array_agg(m order by m), '{}'::text[])
          from unnest(coalesce(b.enabled_modules, '{}'::text[])) m
         where m = any(s.modules)
      )
    end
  ) order by b.name, b.slug), '[]'::jsonb)
    into v_staff
    from public.staff s
    join public.businesses b on b.id = s.business_id
   where s.user_id = v_actor
     and s.active;

  if app.platform_feature_enabled('customer_identity')
     and app.platform_feature_enabled('customer_claims')
     and app.platform_feature_enabled('customer_wallet') then
    select coalesce(jsonb_agg(jsonb_build_object(
      'business_slug', b.slug,
      'business_name', b.name
    ) order by b.name, b.slug), '[]'::jsonb)
      into v_customer
      from public.customer_identities ci
      join public.customer_links l
        on l.identity_id = ci.id
       and l.auth_user_id = v_actor
       and l.state = 'verified'
      join public.businesses b on b.id = l.business_id
     where ci.auth_user_id = v_actor
       and ci.status = 'active';
  end if;

  if jsonb_array_length(v_staff) > 0 then
    v_default_route := '#/workspace/' || (v_staff->0->>'business_slug') || '/dashboard';
  elsif jsonb_array_length(v_customer) > 0 then
    v_default_route := '#/wallet';
  elsif app.platform_feature_enabled('customer_identity') then
    v_default_route := '#/claim';
  end if;

  return jsonb_build_object(
    'staff', v_staff,
    'customer', v_customer,
    'default_route', v_default_route
  );
end $$;

revoke all on function public.get_my_personas() from public, anon;
grant execute on function public.get_my_personas() to authenticated;

commit;
