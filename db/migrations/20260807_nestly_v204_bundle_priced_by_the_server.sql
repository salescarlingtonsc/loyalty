-- NESTLY v204 — a bundle is charged at the bundle price.
--
-- Owner: "facial = $30, spa = $30, where bundle rainbow of both = $40. it should charge
-- bundle rainbow $40 (not individual services)."
--
-- WHAT WAS ACTUALLY WRONG
-- The till split the bundle price across its services client-side and displayed those
-- figures, but buildEvalLines sends `{catalog_kind, catalog_id, qty}` and NOTHING else —
-- by design, because ps1c_plan_checkout rejects any client-supplied price outright
-- ('client_priced'). So the split never reached the server. app.ps1c_plan_checkout had no
-- concept of a bundle at all and priced each service from the catalogue.
--
-- The cart therefore showed one number and the customer was charged another: a Rainbow
-- special of 30 + 30 priced at 40 rang up as 60. Every bundle ever sold was charged at the
-- sum of its parts, so a discount bundle silently gave the customer nothing and a premium
-- bundle silently gave the firm nothing.
--
-- THE FIX KEEPS THE INVARIANT THAT CAUSED IT
-- "Nothing is client-priceable" is the right rule and stays exactly as it is. A bundle
-- becomes a CATALOGUE kind the server prices itself: the till sends
-- {catalog_kind:'bundle', catalog_id:<bundle>, qty:n} and the server reads
-- public.bundles.price_cents. The client still cannot name a price.
--
-- One bundle line expands into one server line per service so commission, per-service
-- reporting and inventory still attribute correctly — but the expanded lines are allocated
-- FROM the bundle price and sum to it exactly, with the last line absorbing the rounding
-- remainder. A 40 bundle over two equal services is 20 + 20, never 20 + 20 + a stray cent.

begin;

create or replace function app.ps1c_bundle_lines_v204(
  p_business uuid, p_bundle uuid, p_qty int)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_price int; v_name text; v_active boolean;
  v_rows int; v_list bigint := 0; v_alloc bigint := 0; v_share int;
  v_out jsonb := '[]'::jsonb; r record; v_i int := 0; v_total bigint;
begin
  select b.price_cents, b.name, b.active into v_price, v_name, v_active
    from public.bundles b where b.id = p_bundle and b.business_id = p_business;
  if not found then
    return jsonb_build_object('status','unknown_bundle',
      'reason','this bundle does not belong to this business');
  end if;
  if not coalesce(v_active,false) then
    return jsonb_build_object('status','inactive_bundle',
      'reason','this bundle is not available for sale');
  end if;
  if coalesce(v_price,0) < 1 then
    return jsonb_build_object('status','unpriced_bundle',
      'reason','this bundle has no price set');
  end if;

  -- Only services that are themselves still sellable. A bundle must not become a side door
  -- that sells a service the firm has retired.
  select count(*), coalesce(sum(greatest(s.price_cents,0)),0)
    into v_rows, v_list
    from public.bundle_items bi
    join public.services s on s.id = bi.service_id and s.business_id = p_business
   where bi.bundle_id = p_bundle and s.active;
  if coalesce(v_rows,0) < 1 then
    return jsonb_build_object('status','empty_bundle',
      'reason','this bundle has no sellable services in it');
  end if;

  v_total := v_price::bigint * p_qty;

  -- Allocate the BUNDLE price across the services in proportion to their list prices, so a
  -- 100 bundle of a 30 and a 70 service reports 30/70 of the revenue, not 50/50. The last
  -- row takes whatever is left, which is what makes the parts sum to the whole exactly.
  for r in
    select s.id, s.name, greatest(s.price_cents,0) as list
      from public.bundle_items bi
      join public.services s on s.id = bi.service_id and s.business_id = p_business
     where bi.bundle_id = p_bundle and s.active
     order by s.name, s.id
  loop
    v_i := v_i + 1;
    if v_i = v_rows then
      v_share := (v_total - v_alloc)::int;
    elsif v_list > 0 then
      v_share := floor(v_total * r.list / v_list)::int;
    else
      v_share := floor(v_total / v_rows)::int;
    end if;
    v_alloc := v_alloc + v_share;
    v_out := v_out || jsonb_build_object(
      'service_id', r.id,
      'name', r.name || ' · ' || v_name,
      'line_cents', greatest(v_share,0));
  end loop;

  return jsonb_build_object('status','ok','bundle_name',v_name,
    'total_cents', v_total, 'lines', v_out);
end
$$;

revoke all on function app.ps1c_bundle_lines_v204(uuid,uuid,int) from public, anon, authenticated;

commit;
