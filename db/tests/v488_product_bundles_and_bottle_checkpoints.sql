-- Rolled-back proof for nestly_v488. Safe against production: one transaction, ROLLBACK at the
-- end, no fixture row survives. Run with: supabase db query --linked -f db/tests/v488_...sql
--
-- Fixtures: Bistro 999 (a3b7acb1…) is the live bar tenant; its owner is 5c6c34e8…, and its
-- stored "Heiniken 240ml" bottle (41480722…) carries a verified customer link — which is what
-- the sweep assertions ride, with p_now shifted rather than the bottle's own date touched.
begin;

do $$
declare
  v_biz uuid := 'a3b7acb1-c2c6-46fb-a8cf-36b190a61b0a';
  v_owner uuid := '5c6c34e8-36a3-4c0e-9071-ebfe774fc9c9';
  v_bottle uuid := '41480722-2762-4033-aa5e-43ef4f1f1c81';
  v_expires timestamptz;
  v_svc uuid; v_prod uuid; v_bundle uuid;
  v_res jsonb; v_lines jsonb; v_plan jsonb;
  v_sum bigint; v_kinds text[];
  v_before int; v_after int;
  v_title text;
begin
  -- ---- act as the real owner, not as postgres ------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  -- ---- 1. schema: exactly one member kind per row --------------------------------------------
  insert into public.services (business_id, name, price_cents, duration_min, active)
  values (v_biz, 'v488 test pour', 3000, 30, true) returning id into v_svc;
  insert into public.products (business_id, name, retail_price_cents, active)
  values (v_biz, 'v488 test bottle', 7000, true) returning id into v_prod;

  begin
    insert into public.bundle_items (bundle_id, service_id, product_id)
    values (gen_random_uuid(), v_svc, v_prod);
    raise exception 'FAIL 1a: a row carrying BOTH member kinds was accepted';
  exception
    when check_violation then null;      -- expected: bundle_items_one_member_v488
    when foreign_key_violation then
      raise exception 'FAIL 1a: check must fire before the FK — both-kinds row got past the check';
  end;
  begin
    insert into public.bundle_items (bundle_id, service_id, product_id)
    values (gen_random_uuid(), null, null);
    raise exception 'FAIL 1b: a row carrying NEITHER member kind was accepted';
  exception when check_violation then null;
  end;
  raise notice 'PASS 1: bundle_items enforces exactly one of service_id / product_id';

  -- ---- 2. create_bundle_v488: one service + one product is a real bundle ---------------------
  v_res := public.create_bundle_v488(v_biz, 'v488 pour + bottle', 8000,
    array[v_svc], array[v_prod], 'v488-test-'||gen_random_uuid());
  if v_res->>'status' <> 'created' then
    raise exception 'FAIL 2: create_bundle_v488 said %', v_res;
  end if;
  v_bundle := (v_res->>'bundle_id')::uuid;
  if (select count(*) from public.bundle_items where bundle_id = v_bundle and product_id = v_prod) <> 1
     or (select count(*) from public.bundle_items where bundle_id = v_bundle and service_id = v_svc) <> 1 then
    raise exception 'FAIL 2: membership rows are not the one service + one product that was sent';
  end if;
  raise notice 'PASS 2: create_bundle_v488 stores a mixed service+product membership';

  -- ---- 3. ps1c_bundle_lines_v204: both kinds priced, pro-rata, sum EXACTLY the price ---------
  v_res := app.ps1c_bundle_lines_v204(v_biz, v_bundle, 1);
  if v_res->>'status' <> 'ok' then
    raise exception 'FAIL 3: bundle pricing said %', v_res;
  end if;
  select coalesce(sum((l->>'line_cents')::int),0),
         array_agg(l->>'kind' order by l->>'kind')
    into v_sum, v_kinds
    from jsonb_array_elements(v_res->'lines') l;
  if v_sum <> 8000 then
    raise exception 'FAIL 3: lines sum to % not the 8000 bundle price', v_sum;
  end if;
  if v_kinds <> array['product','service'] then
    raise exception 'FAIL 3: expected one product + one service line, got %', v_kinds;
  end if;
  if exists (select 1 from jsonb_array_elements(v_res->'lines') l
              where l->>'kind'='service' and nullif(l->>'service_id','') is null) then
    raise exception 'FAIL 3: a service line dropped service_id — the CDN-window compat key';
  end if;
  raise notice 'PASS 3: bundle pricing splits across both kinds and sums exactly to the price';

  -- ---- 4. ps1c_plan_checkout: the product member is a plain product plan line ----------------
  v_plan := app.ps1c_plan_checkout(v_biz, null, null,
    jsonb_build_array(jsonb_build_object('catalog_kind','bundle','catalog_id',v_bundle,'qty',1)),
    null);
  if v_plan->>'status' <> 'ok' then
    raise exception 'FAIL 4: plan_checkout said %', v_plan;
  end if;
  if not exists (select 1 from jsonb_array_elements(v_plan->'server_lines') l
                  where l->>'catalog_kind'='product'
                    and (l->>'catalog_id')::uuid = v_prod
                    and (l->>'bundle_id')::uuid = v_bundle) then
    raise exception 'FAIL 4: no product server line carrying the bundle provenance, got %',
      v_plan->'server_lines';
  end if;
  if (v_plan->>'subtotal_cents')::int <> 8000 then
    raise exception 'FAIL 4: plan subtotal % <> 8000', v_plan->>'subtotal_cents';
  end if;
  raise notice 'PASS 4: plan_checkout prices a mixed bundle and keeps product provenance';

  -- ---- 5. update_bundle_v488 replaces the whole membership -----------------------------------
  v_res := public.update_bundle_v488(v_biz, v_bundle, null, null,
    array[]::uuid[], array[v_prod, v_prod], null);
  -- dedupe leaves ONE product = 1 member, below the floor of 2 → must refuse
  raise exception 'FAIL 5: a one-member bundle was accepted';
exception
  when others then
    if sqlerrm not like '%between 2 and 50%' then raise; end if;
    raise notice 'PASS 5: update_bundle_v488 holds the 2-member floor across both kinds';
end $$;

-- The block above ended in a caught exception, which poisons nothing outside it, but plpgsql
-- rolled its subtransaction back — so the sweep half runs in a fresh block on the same
-- still-open transaction.
do $$
declare
  v_biz uuid := 'a3b7acb1-c2c6-46fb-a8cf-36b190a61b0a';
  v_bottle uuid := '41480722-2762-4033-aa5e-43ef4f1f1c81';
  v_expires timestamptz;
  v_before int; v_after int;
  v_title text;
begin
  select expires_at into v_expires from public.bar_bottles where id = v_bottle;
  if v_expires is null then
    raise exception 'FAIL 6: fixture bottle % is gone — pick another stored+linked bottle', v_bottle;
  end if;

  -- Every count below is scoped to THIS business: at a shifted p_now, some OTHER tenant's
  -- stored bottle may legitimately enter its own checkpoint window, and its events must not
  -- fail this suite. Titles are asserted by EXISTENCE, not by "latest row" — inside one
  -- transaction every insert shares one created_at, so ordering by it is a coin toss.
  select count(*) into v_before from public.customer_in_app_inbox_events
   where source_kind = 'v282_bottle_expiry' and business_id = v_biz;

  -- 6a. Six days out → the 7-day checkpoint (and ONLY it: min over matches).
  perform app.v282_sweep_bottle_expiry(v_expires - interval '6 days');
  select count(*) into v_after from public.customer_in_app_inbox_events
   where source_kind = 'v282_bottle_expiry' and business_id = v_biz;
  if v_after <> v_before + 1
     or not exists (select 1 from public.customer_in_app_inbox_events
                     where source_kind = 'v282_bottle_expiry' and business_id = v_biz
                       and title = 'Your bottle expires in 7 days') then
    raise exception 'FAIL 6a: expected exactly one new 7-day event, got % new rows',
      v_after - v_before;
  end if;

  -- 6b. The same moment again → deduped, nothing new.
  perform app.v282_sweep_bottle_expiry(v_expires - interval '6 days');
  select count(*) into v_after from public.customer_in_app_inbox_events
   where source_kind = 'v282_bottle_expiry' and business_id = v_biz;
  if v_after <> v_before + 1 then
    raise exception 'FAIL 6b: re-running the same checkpoint duplicated the event';
  end if;

  -- 6c. Two days out → the 3-day checkpoint fires as its own event.
  perform app.v282_sweep_bottle_expiry(v_expires - interval '2 days');
  select count(*) into v_after from public.customer_in_app_inbox_events
   where source_kind = 'v282_bottle_expiry' and business_id = v_biz;
  if v_after <> v_before + 2
     or not exists (select 1 from public.customer_in_app_inbox_events
                     where source_kind = 'v282_bottle_expiry' and business_id = v_biz
                       and title = 'Your bottle expires in 3 days') then
    raise exception 'FAIL 6c: expected a second, 3-day event, got % new rows',
      v_after - v_before;
  end if;

  -- 6d. Twelve hours out → the day-of checkpoint.
  perform app.v282_sweep_bottle_expiry(v_expires - interval '12 hours');
  select count(*) into v_after from public.customer_in_app_inbox_events
   where source_kind = 'v282_bottle_expiry' and business_id = v_biz;
  if v_after <> v_before + 3
     or not exists (select 1 from public.customer_in_app_inbox_events
                     where source_kind = 'v282_bottle_expiry' and business_id = v_biz
                       and title = 'Your bottle expires today') then
    raise exception 'FAIL 6d: expected a third, day-of event, got % new rows',
      v_after - v_before;
  end if;

  -- 6e. Past expiry → the bottle is marked expired, not reminded again.
  perform app.v282_sweep_bottle_expiry(v_expires + interval '1 hour');
  if (select status from public.bar_bottles where id = v_bottle) <> 'expired' then
    raise exception 'FAIL 6e: the sweep did not expire a past-window bottle';
  end if;
  select count(*) into v_after from public.customer_in_app_inbox_events
   where source_kind = 'v282_bottle_expiry' and business_id = v_biz;
  if v_after <> v_before + 3 then
    raise exception 'FAIL 6e: expiring the bottle enqueued a fourth reminder';
  end if;

  raise notice 'PASS 6: 7-day, 3-day and day-of checkpoints each fire exactly once, then expiry';
end $$;

rollback;

-- Post-flight (run separately if paranoid): the fixture names must not survive.
--   select count(*) from public.services where name = 'v488 test pour';        -- 0
--   select count(*) from public.products where name = 'v488 test bottle';      -- 0
