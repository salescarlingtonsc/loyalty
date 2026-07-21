-- Pin search_path on the two v14 IMMUTABLE helpers (Supabase linter 0011).
-- Both only touch pg_catalog builtins, so pinning is behaviour-neutral.
-- norm_phone backs a GENERATED column on clients.phone_norm; replacing the body
-- identically (signature, volatility, return type unchanged) is allowed.
create or replace function app.norm_phone(p text)
returns text language sql immutable
set search_path = pg_catalog, pg_temp as $$
  select case
           when length(d) = 8  and left(d,1) in ('3','6','8','9') then d
           when length(d) = 10 and left(d,2) = '65'
                and substr(d,3,1) in ('3','6','8','9')            then substr(d,3,8)
           when length(d) = 11 and left(d,3) = '065'
                and substr(d,4,1) in ('3','6','8','9')            then substr(d,4,8)
           else null
         end
  from (select regexp_replace(coalesce(p,''), '[^0-9]', '', 'g') as d) _;
$$;

create or replace function app.role_perms(p_role text)
returns text[] language sql immutable
set search_path = pg_catalog, pg_temp as $$
  select case p_role
    when 'owner'      then array['view_sales','create_sales','refund_sales',
                                 'reclassify_sales','view_finance','manage_sale_policy',
                                 'manage_team','manage_billing']
    when 'manager'    then array['view_sales','create_sales','refund_sales','view_finance']
    when 'staff'      then array['view_sales','create_sales']
    when 'frontdesk'  then array['view_sales','create_sales']
    when 'bookkeeper' then array['view_sales','view_finance']
    when 'stylist'      then array['view_sales','create_sales']
    when 'receptionist' then array['view_sales','create_sales']
    else array[]::text[]
  end
$$;