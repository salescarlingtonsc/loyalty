-- Rolled-back acceptance for v204 — a bundle is charged at the bundle price.
begin;

-- 1. Over EVERY bundle in the database, the expanded lines sum to exactly the bundle price.
--    This is the property the browser split used to claim and the server never honoured.
do $$
declare r record; v jsonb; v_sum bigint; v_checked int := 0;
begin
  for r in select id, business_id, name, price_cents from public.bundles where active loop
    v := app.ps1c_bundle_lines_v204(r.business_id, r.id, 1);
    if v->>'status' <> 'ok' then
      -- failing closed is allowed and is the safe outcome; it must never mis-price instead
      assert v->>'status' in ('empty_bundle','unpriced_bundle','inactive_bundle'),
        format('bundle %s returned an unexpected status %s', r.name, v->>'status');
      continue;
    end if;
    select coalesce(sum((line->>'line_cents')::bigint),0) into v_sum
      from jsonb_array_elements(v->'lines') line;
    assert v_sum = r.price_cents,
      format('bundle %s: parts sum to %s but the bundle costs %s', r.name, v_sum, r.price_cents);
    assert (v->>'total_cents')::bigint = r.price_cents,
      format('bundle %s: reported total is not the bundle price', r.name);
    v_checked := v_checked + 1;
  end loop;
  raise notice 'v204: % priced bundles all sum exactly to their own price', v_checked;
end$$;

-- 2. Quantity multiplies the BUNDLE, not the parts.
do $$
declare r record; v jsonb; v_sum bigint;
begin
  select id, business_id, price_cents into r from public.bundles b
   where b.active and app.ps1c_bundle_lines_v204(b.business_id,b.id,1)->>'status'='ok' limit 1;
  if not found then raise notice 'no priced bundle fixture; skipping'; return; end if;
  v := app.ps1c_bundle_lines_v204(r.business_id, r.id, 3);
  select coalesce(sum((line->>'line_cents')::bigint),0) into v_sum
    from jsonb_array_elements(v->'lines') line;
  assert v_sum = r.price_cents::bigint * 3, 'three bundles must cost three bundle prices';
end$$;

-- 3. A bundle belonging to another business is refused, not priced.
do $$
declare a record; b record; v jsonb;
begin
  select id, business_id into a from public.bundles limit 1;
  select id into b from public.businesses where id <> a.business_id limit 1;
  if a.id is null or b.id is null then raise notice 'no cross-tenant fixture; skipping'; return; end if;
  v := app.ps1c_bundle_lines_v204(b.id, a.id, 1);
  assert v->>'status' = 'unknown_bundle', 'a bundle must not price for another business';
end$$;

rollback;
