-- nestly_v818 rollback suite.
--
-- Asserts every claim nestly_v818 makes, against an applied database, inside a transaction
-- that is ROLLED BACK. Nothing is left behind.
--
--   supabase db query --linked -f db/tests/v818_line_commission_branch_availability_booking_sync.sql
--
-- Before the migration was applied it was run the same way with the migration prepended and
-- its trailing `commit;` stripped, which is how the 31 assertions below were proved to
-- FAIL before and PASS after:
--   sed '$d' db/migrations/20261007_nestly_v818_*.sql > /tmp/v818.sql
--   cat db/tests/v818_line_commission_branch_availability_booking_sync.sql >> /tmp/v818.sql
--
-- The tenant used for the live-shaped assertions is the one in the owner's screenshots
-- (ÉLAN Wellness); the pure-resolver assertions do not depend on it.

begin;

do $suite$
declare
  c_biz     constant uuid := '8ccace3a-9736-447e-bb1e-da842622592d';  -- ÉLAN Wellness
  c_owner   constant uuid := '8efcffc8-61a5-4235-ad45-54a8954208f9';  -- Kiat Ke Ying (owner)
  c_branch  constant uuid := '586f4069-12cb-4f54-b37c-8c5742244520';  -- ÉLAN Wellness (active)
  c_offbr   constant uuid := 'a0d8c77f-64fe-4895-b659-d8fb01586330';  -- KKY demo Salon (INACTIVE)
  c_aroma   constant uuid := '8a191981-7df0-44e7-a452-92581e3c8ea3';  -- pinned to the off branch
  c_signature constant uuid := '274204da-ad83-4e3b-b7f5-30681788079d';
  c_amanda  constant uuid := '0fb55728-f2b3-4db9-87ec-574e93b80780';
  v_now     constant timestamptz := now();
  v_sale    uuid := gen_random_uuid();
  v_appt    uuid;
  v_req     uuid;
  v_client  uuid;
  v_product uuid;
  v_customer uuid;
  v_got     integer;
  v_txt     text;
  v_ok      boolean;
  n         integer := 0;
  procedure_note text;
begin
  -- Rates for the worked example the owner approved. Deliberately DIFFERENT so a
  -- per-line result cannot coincide with the old whole-basket result.
  perform set_config('app.sale_items_commission_backfill', '', true);
  update public.staff
     set commission_service_bps = null,      -- blank, exactly as photo 2 shows it
         commission_product_bps = 2000,      -- 20%
         commission_starts_on = null
   where id = c_amanda;
  update public.services set commission_bps = 1000, commission_flat_cents = null
   where id = c_signature;                   -- 10% service override, as photo 1 shows

  select id into v_client from public.clients where business_id = c_biz limit 1;
  select id into v_product from public.products where business_id = c_biz limit 1;

  ---------------------------------------------------------------- 1. per-line commission

  insert into public.sales(id, business_id, client_id, kind, amount_cents, occurred_at,
                           branch_id, staff_id)
  values (v_sale, c_biz, v_client, 'quick_sale', 11800, v_now, c_branch, c_amanda);

  insert into public.sale_items(sale_id, business_id, item_type, ref_id, description,
                                qty, unit_cents, line_cents)
  values (v_sale, c_biz, 'service', c_signature, 'Signature Relaxation Massage', 1, 8800, 8800);
  insert into public.sale_items(sale_id, business_id, item_type, ref_id, description,
                                qty, unit_cents, line_cents, product_id)
  values (v_sale, c_biz, 'retail', v_product, 'Massage Oil', 1, 3000, 3000, v_product);

  n := n + 1;
  select commission_rate_bps into v_got from public.sale_items
   where sale_id = v_sale and item_type = 'service';
  if v_got is distinct from 1000 then
    raise exception 'A%: service line took % bps, expected the service override 1000', n, v_got;
  end if;

  n := n + 1;
  select commission_cents into v_got from public.sale_items
   where sale_id = v_sale and item_type = 'service';
  if v_got is distinct from 880 then
    raise exception 'A%: service line paid %c, expected 880c (10%% of 8800)', n, v_got;
  end if;

  n := n + 1;
  select commission_rate_bps into v_got from public.sale_items
   where sale_id = v_sale and item_type = 'retail';
  if v_got is distinct from 2000 then
    raise exception 'A%: retail line took % bps, expected the member product rate 2000', n, v_got;
  end if;

  n := n + 1;
  select commission_cents into v_got from public.sale_items
   where sale_id = v_sale and item_type = 'retail';
  if v_got is distinct from 600 then
    raise exception 'A%: retail line paid %c, expected 600c (20%% of 3000)', n, v_got;
  end if;

  -- The whole point: the two lines pay two different rates. The pre-v811 header answer
  -- for this basket was 20% of 11800 = 2360c, which is the bug in photo 2 item 2.
  n := n + 1;
  select sum(commission_cents)::integer into v_got from public.sale_items where sale_id = v_sale;
  if v_got is distinct from 1480 then
    raise exception 'A%: basket paid %c, expected 1480c (880 service + 600 product)', n, v_got;
  end if;
  n := n + 1;
  if v_got = 2360 then
    raise exception 'A%: basket still paying the whole-basket product rate', n;
  end if;

  -- Read it back through the view, as the OWNER, the way Staff performance does.
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  select commission_cents into v_got from public.sale_commission where sale_id = v_sale;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_got is distinct from 1480 then
    raise exception 'A%: sale_commission reported %c to the owner, expected 1480c', n, v_got;
  end if;

  -- A manager holds view_finance and must read the SAME number, not a different one.
  n := n + 1;
  update public.staff set role = 'manager' where id = (
    select id from public.staff where business_id = c_biz and user_id is not null
       and role <> 'owner' limit 1);
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', '87cd2709-e6c3-43e7-acee-1379c0ce0c69', 'role', 'authenticated')::text, true);
  select commission_cents into v_got from public.sale_commission where sale_id = v_sale;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_got is distinct from 1480 then
    raise exception 'A%: a manager read %c where the owner read 1480c', n, v_got;
  end if;

  -- No service override -> the member's own service rate.
  n := n + 1;
  update public.services set commission_bps = null where id = c_signature;
  update public.staff set commission_service_bps = 1500 where id = c_amanda;
  if app.sale_item_commission_bps_v811(c_biz, 'service', c_signature, c_amanda, v_now)
     is distinct from 1500 then
    raise exception 'A%: a service with no override did not fall back to the member service rate', n;
  end if;

  -- A 0%% override is a real setting and beats the member's rate (v12 ruling).
  n := n + 1;
  update public.services set commission_bps = 0 where id = c_signature;
  if app.sale_item_commission_bps_v811(c_biz, 'service', c_signature, c_amanda, v_now)
     is distinct from 0 then
    raise exception 'A%: a 0%% service override did not beat the member service rate', n;
  end if;

  -- A fixed amount per service outranks the percentage, and multiplies by qty.
  n := n + 1;
  update public.services set commission_bps = 1000, commission_flat_cents = 500
   where id = c_signature;
  if app.sale_item_commission_flat_cents_v811(c_biz, 'service', c_signature, c_amanda, v_now, 8800)
     is distinct from 500 then
    raise exception 'A%: the per-service fixed amount did not resolve', n;
  end if;
  n := n + 1;
  if app.sale_item_commission_flat_cents_v811(c_biz, 'retail', v_product, c_amanda, v_now, 3000)
     is not null then
    raise exception 'A%: a fixed amount leaked onto a product line', n;
  end if;
  update public.services set commission_flat_cents = null where id = c_signature;

  -- commission_starts_on still zeroes anything before the member's start date.
  n := n + 1;
  update public.staff set commission_starts_on = (v_now at time zone 'Asia/Singapore')::date + 1
   where id = c_amanda;
  if app.sale_item_commission_bps_v811(c_biz, 'service', c_signature, c_amanda, v_now)
     is distinct from 0 then
    raise exception 'A%: a sale before commission_starts_on still paid', n;
  end if;
  update public.staff set commission_starts_on = null where id = c_amanda;

  -- A sale with no lines keeps the old header arithmetic, untouched.
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  select commission_cents into v_got from public.sale_commission
   where sale_id = '4d23c80a-beb4-4795-b883-c89d371b3e2c';  -- a reversal row, no lines
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_got is null then
    raise exception 'A%: a line-less sale stopped reporting a commission', n;
  end if;

  -- Every pre-v811 line now carries a snapshot.
  n := n + 1;
  select count(*)::integer into v_got from public.sale_items where commission_resolved_at is null;
  if v_got <> 0 then
    raise exception 'A%: % sale_items were left without a commission snapshot', n, v_got;
  end if;

  -- The append-only guard still refuses everything the backfill window does not name.
  n := n + 1;
  begin
    update public.sale_items set line_cents = line_cents + 1 where sale_id = v_sale;
    raise exception 'A%: sale_items accepted an UPDATE with no backfill window', n;
  exception when restrict_violation then null;
  end;

  n := n + 1;
  begin
    perform set_config('app.sale_items_commission_backfill', 'probe', true);
    update public.sale_items set line_cents = line_cents + 1 where sale_id = v_sale;
    raise exception 'A%: the backfill window let an economic fact change', n;
  exception when restrict_violation then null;
  end;

  n := n + 1;
  begin
    perform set_config('app.sale_items_commission_backfill', 'probe', true);
    update public.sale_items set commission_cents = 999999 where sale_id = v_sale;
    raise exception 'A%: the backfill window restated a snapshot that already existed', n;
  exception when restrict_violation then null;
  end;
  perform set_config('app.sale_items_commission_backfill', '', true);

  ------------------------------------------------------------- 2. branch availability

  -- The exact row from photo 6: pinned only to a branch that has been switched off.
  n := n + 1;
  if not exists (select 1 from public.service_branches
                  where service_id = c_aroma and branch_id = c_offbr) then
    raise exception 'A%: the fixture moved — Aromatherapy Ritual is no longer pinned to the off branch', n;
  end if;
  n := n + 1;
  if not app.branch_offers_service_v811(c_biz, c_aroma, c_branch) then
    raise exception 'A%: a service pinned only to an inactive branch is still hidden at the live branch', n;
  end if;

  -- It appears in the till catalogue again, as the owner.
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  select count(*)::integer into v_got
    from jsonb_array_elements(
           (public.business_get_checkout_catalogue_v94(c_biz, c_branch, false))->'items') item
   where (item->>'item_id')::uuid = c_aroma;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_got <> 1 then
    raise exception 'A%: the till catalogue returned % rows for the ringed service, expected 1', n, v_got;
  end if;

  -- A service pinned to nothing is available everywhere, exactly as before.
  n := n + 1;
  if not app.branch_offers_service_v811(c_biz, c_signature, c_branch) then
    raise exception 'A%: an unpinned service stopped being available', n;
  end if;

  -- NO WIDENING. Once a pin names a LIVE branch the service is restricted again, and a
  -- branch the pins do not name is refused. (Switching the off branch back on is not an
  -- option here — guard_branch_billing_authority_v621 forbids it — so the discrimination
  -- is proved from the other direction, with a live pin and an unnamed branch.)
  n := n + 1;
  insert into public.service_branches(business_id, service_id, branch_id)
  values (c_biz, c_signature, c_branch) on conflict do nothing;
  if not app.branch_offers_service_v811(c_biz, c_signature, c_branch) then
    raise exception 'A%: a service pinned to this live branch was refused here', n;
  end if;
  n := n + 1;
  if app.branch_offers_service_v811(c_biz, c_signature, gen_random_uuid()) then
    raise exception 'A%: a service pinned to one live branch leaked into a branch it does not name', n;
  end if;

  -- Products carried the identical hole.
  n := n + 1;
  insert into public.product_branches(business_id, product_id, branch_id)
  values (c_biz, v_product, c_offbr) on conflict do nothing;
  if not app.branch_offers_product_v627(c_biz, v_product, c_branch) then
    raise exception 'A%: a product pinned only to an inactive branch is still hidden', n;
  end if;
  -- Asking about a branch the pins do not name at all. (c_offbr cannot be used here: it
  -- IS named by the pin above, so "yes" would be the right answer for it.)
  n := n + 1;
  insert into public.product_branches(business_id, product_id, branch_id)
  values (c_biz, v_product, c_branch) on conflict do nothing;
  if app.branch_offers_product_v627(c_biz, v_product, gen_random_uuid()) then
    raise exception 'A%: a product pinned to one live branch leaked into a branch it does not name', n;
  end if;

  -- The customer booking portal reads the same authority now.
  n := n + 1;
  select pg_get_functiondef(p.oid) into v_txt
    from pg_proc p join pg_namespace n2 on n2.oid = p.pronamespace
   where n2.nspname = 'public' and p.proname = 'customer_get_business_presentation_v95';
  if position('branch_offers_service_v811' in v_txt) = 0 then
    raise exception 'A%: the customer booking portal still has its own copy of the predicate', n;
  end if;
  if position('from public.service_branches configured' in v_txt) > 0 then
    raise exception 'A%: the old inline predicate survived in the customer booking portal', n;
  end if;

  -- The portal is patched by string surgery against its live 20KB body, so prove it still
  -- RUNS and now returns the service that was hidden from customers online.
  -- The portal refuses anyone who is not an independent active customer, so it is called
  -- as one — the same principal a real customer browsing the booking page is.
  n := n + 1;
  select ci.auth_user_id into v_customer
    from public.customer_identities ci
   where ci.status = 'active'
     and not exists (select 1 from public.staff st where st.user_id = ci.auth_user_id)
   limit 1;
  if v_customer is null then
    raise exception 'A%: no active customer identity to call the booking portal as', n;
  end if;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_customer, 'role', 'authenticated')::text, true);
  select count(*)::integer into v_got
    from jsonb_array_elements(
           (public.customer_get_business_presentation_v95(c_biz, c_branch, 'en'))->'catalogue'->'services') svc
   where (svc->>'id')::uuid = c_aroma;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_got <> 1 then
    raise exception 'A%: the customer booking portal returned % rows for the ringed service, expected 1',
      n, v_got;
  end if;

  --------------------------------------------------- 3. a booking request follows its appointment

  -- Nothing stranded is left anywhere on the estate.
  n := n + 1;
  select count(*)::integer into v_got
    from public.booking_requests request
    join public.appointments appointment
      on appointment.id = request.appointment_id
     and appointment.business_id = request.business_id
   where appointment.status in ('cancelled', 'no_show')
     and request.status in ('new', 'pending', 'confirmed', 'waitlisted');
  if v_got <> 0 then
    raise exception 'A%: % booking requests still disagree with their appointment', n, v_got;
  end if;

  -- And the trigger closes every writer, not just the one the owner used.
  n := n + 1;
  -- No staff_id: guard_staff_blocked_time_v120 checks a named member's rota, and this
  -- assertion is about the request following the appointment, not about scheduling.
  insert into public.appointments(business_id, client_id, service_id, branch_id,
                                  starts_at, ends_at, status)
  values (c_biz, v_client, c_signature, c_branch,
          v_now + interval '2 days', v_now + interval '2 days 1 hour', 'booked')
  returning id into v_appt;
  insert into public.booking_requests(business_id, appointment_id, name, preferred_at, status)
  values (c_biz, v_appt, 'Suite probe', v_now + interval '2 days', 'confirmed')
  returning id into v_req;

  update public.appointments set status = 'cancelled' where id = v_appt;
  select status into v_txt from public.booking_requests where id = v_req;
  if v_txt is distinct from 'cancelled' then
    raise exception 'A%: cancelling an appointment left its request reading "%"', n, v_txt;
  end if;

  -- A request that was already declined is not rewritten.
  n := n + 1;
  update public.booking_requests set status = 'declined' where id = v_req;
  update public.appointments set status = 'booked' where id = v_appt;
  update public.appointments set status = 'no_show' where id = v_appt;
  select status into v_txt from public.booking_requests where id = v_req;
  if v_txt is distinct from 'declined' then
    raise exception 'A%: a settled request was overwritten to "%"', n, v_txt;
  end if;

  raise notice 'nestly_v818: % / % assertions passed', n, n;
end
$suite$;

rollback;
