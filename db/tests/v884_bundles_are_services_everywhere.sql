-- nestly_v884 rolled-back verification — a bundle is a service everywhere.
--
-- Run against production. Everything happens inside the transaction and the file ends in
-- `rollback;`. Fixture: owner + two bookable team members (A assigned to both member services,
-- B assigned to only one) + a bundle of two services (30 + 45 min, SGD 158, one member service
-- carrying a consumable).
--
--   1. the resolver answers a service and a bundle alike; the assignment rule keeps A, drops B;
--   2. the STAFF form path — book_appointment_smart_v47 with the bundle id in the service
--      position — books one 75-minute appointment at the bundle price, bundle_id stamped,
--      note "Bundle: …", assigned to A (B is not qualified);
--   3. the suggestion RPC accepts the bundle id and offers A, not B;
--   4. auto-approve confirms a bundle request by itself (auto_approve_changes on);
--   5. completion writes the till's member lines under the sale (each with bundle_id, summing
--      to the bundle price) and deducts the member service's consumable;
--   6. the customer appointments page and Book again name the bundle.

\set ON_ERROR_STOP on

begin;

create or replace function pg_temp.as_v884_user(
  p_uid uuid, p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config(
    'request.jwt.claims', json_build_object('sub', p_uid, 'role', p_role)::text, true
  );
end
$$;
grant execute on function pg_temp.as_v884_user(uuid, text) to public;

create or replace function pg_temp.approve_v884_workspace(p_business uuid)
returns void language sql as $$
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,
         decided_at=statement_timestamp(),
         decision_reason='approved synthetic rollback fixture',
         updated_at=statement_timestamp()
   where business_id=p_business and approval_status='pending'
$$;

do $test$
declare
  v_owner uuid := gen_random_uuid();
  v_business uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_owner_staff uuid := gen_random_uuid();
  v_staff_a uuid := gen_random_uuid();
  v_staff_b uuid := gen_random_uuid();
  v_service_1 uuid := gen_random_uuid();
  v_service_2 uuid := gen_random_uuid();
  v_product uuid := gen_random_uuid();
  v_batch uuid := gen_random_uuid();
  v_bundle uuid := gen_random_uuid();
  v_client uuid := gen_random_uuid();
  v_slug text := 'v884-' || v_business;
  v_item record;
  v_booking jsonb;
  v_suggest jsonb;
  v_result jsonb;
  v_request uuid;
  v_appointment record;
  v_sale uuid;
  v_lines integer;
  v_line_sum integer;
  v_page jsonb;
  v_repeat jsonb;
  v_starts timestamptz := ((current_date + 2) + time '12:00') at time zone 'Asia/Singapore';
begin
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_owner, 'authenticated', 'authenticated',
          'v884-owner-' || v_owner || '@example.test', '', now(), now(), now());

  insert into public.businesses(id, name, slug, currency, is_synthetic, booking_staff_choice, booking_auto_confirm, auto_approve_changes, enabled_modules)
  values (v_business, 'V884 Bundles', v_slug, 'SGD', true, true, false, true,
          array['dashboard','clients','sales','loyalty','retention','bookings','appointments','inventory']);
  perform pg_temp.approve_v884_workspace(v_business);

  insert into public.branches(id, business_id, name, timezone, active, is_default)
  values (v_branch, v_business, 'V884 Branch', 'Asia/Singapore', true, true);
  insert into public.branch_hours(business_id, branch_id, weekday, opens_at, closes_at)
  select v_business, v_branch, weekday, time '00:00', time '23:59' from generate_series(0, 6) weekday;

  insert into public.staff(id, business_id, user_id, role, full_name, active, customer_bookable)
  values (v_owner_staff, v_business, v_owner, 'owner', 'V884 Owner', true, false),
         (v_staff_a, v_business, null, 'staff', 'V884 A', true, true),
         (v_staff_b, v_business, null, 'staff', 'V884 B', true, true);
  insert into public.staff_branches(business_id, staff_id, branch_id)
  values (v_business, v_staff_a, v_branch), (v_business, v_staff_b, v_branch);
  update public.staff_hours set starts_at = time '00:00', ends_at = time '23:59' where staff_id in (v_staff_a, v_staff_b);

  insert into public.services(id, business_id, name, price_cents, duration_min, active, show_on_booking_page)
  values (v_service_1, v_business, 'V884 Massage', 8800, 30, true, true),
         (v_service_2, v_business, 'V884 Facial', 9800, 45, true, true);
  -- A can do both; B only the massage.
  insert into public.staff_services(business_id, staff_id, service_id)
  values (v_business, v_staff_a, v_service_1), (v_business, v_staff_a, v_service_2), (v_business, v_staff_b, v_service_1);

  insert into public.products(id, business_id, name, retail_price_cents, active)
  values (v_product, v_business, 'V884 Oil', 1200, true);
  insert into public.stock_batches(id, product_id, qty, received_on)
  values (v_batch, v_product, 10, current_date);
  insert into public.service_products(business_id, service_id, product_id, qty) values (v_business, v_service_1, v_product, 2);

  insert into public.bundles(id, business_id, name, price_cents, active) values (v_bundle, v_business, 'V884 Ritual', 15800, true);
  insert into public.bundle_items(bundle_id, service_id) values (v_bundle, v_service_1), (v_bundle, v_service_2);

  insert into public.clients(id, business_id, full_name, phone) values (v_client, v_business, 'V884 Customer', '+6591000884');

  -- 1. resolver + assignment rule
  select * into v_item from app.booking_item_v884(v_business, v_bundle);
  assert v_item.kind = 'bundle' and v_item.duration_min = 75 and v_item.price_cents = 15800, 'resolver: bundle';
  select * into v_item from app.booking_item_v884(v_business, v_service_1);
  assert v_item.kind = 'service' and v_item.duration_min = 30, 'resolver: service';
  assert app.staff_can_do_item_v884(v_business, v_staff_a, v_bundle), 'A can do the whole bundle';
  assert not app.staff_can_do_item_v884(v_business, v_staff_b, v_bundle), 'B cannot do the whole bundle';
  assert app.staff_can_do_item_v884(v_business, v_staff_b, v_service_1), 'B can do the massage alone';

  -- 2 + 3. the staff form path, as the owner
  perform pg_temp.as_v884_user(v_owner);
  v_suggest := public.suggest_appointment_staff_v47(v_business, v_branch, v_bundle, v_starts, 75, 5, 30, null);
  assert v_suggest is not null, 'suggestions must answer for a bundle id';
  assert exists (select 1 from jsonb_array_elements(v_suggest->'available_staff') s where (s->>'staff_id')::uuid = v_staff_a), 'A is offered';
  assert not exists (select 1 from jsonb_array_elements(v_suggest->'available_staff') s where (s->>'staff_id')::uuid = v_staff_b), 'B is not offered for the bundle';

  v_booking := public.book_appointment_smart_v47(v_business, v_client, v_branch, v_bundle, v_starts, 75, null, 'round_robin', 'bring a towel', 'v884-staff-' || v_bundle::text);
  reset role;
  assert v_booking->>'status' = 'booked', 'the staff form books a bundle: ' || v_booking::text;
  select * into v_appointment from public.appointments where id = (v_booking->>'appointment_id')::uuid;
  assert v_appointment.bundle_id = v_bundle and v_appointment.service_id is null, 'bundle stamped, no single service';
  assert v_appointment.ends_at - v_appointment.starts_at = interval '75 minutes', 'summed duration';
  assert v_appointment.total_cents = 15800, 'bundle price';
  assert v_appointment.note like 'Bundle: V884 Ritual%towel%', 'note names the bundle and keeps the staff note: ' || coalesce(v_appointment.note,'');
  assert v_appointment.staff_id = v_staff_a, 'round robin lands on the qualified person';

  -- 4. auto-approve for a public bundle request (a different day, so it does not clash)
  v_result := public.internal_public_booking_submit(
    v_slug, 'V884 Guest', 'guest884@example.com', null, null, 1,
    v_starts + interval '1 day', null, null, false,
    repeat('a', 64), repeat('b', 64), repeat('c', 64), null, null, null, v_bundle);
  v_request := nullif(v_result->>'request_id', '')::uuid;
  assert v_request is not null, 'request created';
  assert (select status from public.booking_requests where id = v_request) = 'confirmed', 'auto-approve confirmed the bundle request: ' || v_result::text;
  assert (select bundle_id from public.appointments where id = (select appointment_id from public.booking_requests where id = v_request)) = v_bundle, 'auto-approved appointment carries the bundle';

  -- 5. completion itemises like the till and deducts the member consumable
  update public.appointments set status = 'completed' where id = v_appointment.id;
  select id into v_sale from public.sales where appointment_id = v_appointment.id;
  assert v_sale is not null, 'completion created the sale';
  assert (select amount_cents from public.sales where id = v_sale) = 15800, 'sale billed at the bundle price';
  select count(*), sum(line_cents) into v_lines, v_line_sum from public.sale_items where sale_id = v_sale;
  assert v_lines = 2 and v_line_sum = 15800, 'two member lines summing to the bundle price, got ' || v_lines || ' / ' || coalesce(v_line_sum, 0);
  assert (select count(*) from public.sale_items where sale_id = v_sale and bundle_id = v_bundle) = 2, 'both lines carry the bundle';
  assert (select qty from public.stock_batches where id = v_batch) = 8, 'the massage consumable was deducted (10 - 2)';

  -- 6. customer readers name the bundle
  select jsonb_build_object('n', count(*)) into v_page
    from public.appointments a
    left join public.services s on s.id = a.service_id
    left join public.bundles b on b.id = a.bundle_id
   where a.id = v_appointment.id and coalesce(s.name, b.name) = 'V884 Ritual';
  assert (v_page->>'n')::integer = 1, 'the appointment resolves to the bundle name';
  assert position('bundle.name' in pg_get_functiondef('public.customer_get_appointments_page(text,jsonb)'::regprocedure)) > 0, 'customer appointments page reads the bundle name';
  assert position('bundle.name' in pg_get_functiondef('public.customer_get_booking_requests(integer,jsonb)'::regprocedure)) > 0, 'customer booking requests read the bundle name';
  assert position('bundle.id' in pg_get_functiondef('public.customer_get_repeat_booking_preference_v167(text,uuid)'::regprocedure)) > 0, 'Book again repeats a bundle';
  assert position('bundle.name' in pg_get_functiondef('public.internal_public_booking_lookup(text)'::regprocedure)) > 0, 'manage-booking lookup reads the bundle name';

  raise notice 'v884 verification passed';
end $test$;

rollback;
