/* nestly_v660 — three owner rulings from the 2026-08-31 review, each closing a setting or an
   action that did not do what its label promised.

   1. "Customer appointment changes" now governs reschedule/cancel of a CONFIRMED appointment,
      and a pending request stays freely changeable.
   2. "Auto-approve reschedule/cancel requests" now confirms a request on the spot when the slot
      is genuinely free — for new appointments and for reschedules alike.
   3. Services and Products get the Delete the owner asked for, on the Packages model: removed
      when nothing refers to it, switched off and kept when something does.

   Each section carries its own reasoning below. Rollback suite: db/tests/v660_owner_rulings.sql */
begin;

-- =============================================================================================
-- 1. "Customer appointment changes" finally governs what its label promises.
--    Owner ruling: "this check of box is for appointments that are confirmed - the check will
--    determine if business allow for reschedule/cancel after confirmation. because if pending
--    they can edit or cancel freely before approval."
--    business_customer_capabilities_v89.appointment_changes_enabled has existed since v89 and
--    gated nothing the customer app uses: its only enforcement points were the legacy v33
--    action-request table and the guest manage-link. An owner with the box UNTICKED still had
--    customers cancelling and rescheduling confirmed appointments.
--    A PENDING request is untouched. It is withdrawn through customer_withdraw_booking_request_v290
--    and amended through customer_amend_booking_request_v627, and neither is gated — that is the
--    "freely before approval" half of the ruling.
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.customer_reschedule_appointment_v508(p_business_slug text, p_appointment uuid, p_preferred_at timestamp with time zone, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_slug text := lower(btrim(coalesce(p_business_slug, '')));
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_identity_id uuid;
  v_link_id uuid;
  v_business_id uuid;
  v_client_id uuid;
  v_enabled_modules text[];
  v_appt public.appointments%rowtype;
  v_client public.clients%rowtype;
  v_request_id uuid := gen_random_uuid();
  v_result jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if p_preferred_at is null or p_preferred_at <= now() then
    raise exception 'the new time must be in the future' using errcode = '22023';
  end if;
  if v_note is not null and length(v_note) > 750 then
    raise exception 'note must not exceed 750 characters' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'v508:reschedule:' || v_actor::text || ':' || coalesce(p_appointment::text, ''), 0));

  select ci.id, l.id, l.business_id, l.client_id, coalesce(b.enabled_modules, '{}'::text[])
    into v_identity_id, v_link_id, v_business_id, v_client_id, v_enabled_modules
    from public.customer_identities ci
    join public.customer_links l
      on l.identity_id = ci.id
     and l.auth_user_id = v_actor
     and l.state = 'verified'
    join public.businesses b on b.id = l.business_id
   where ci.auth_user_id = v_actor
     and ci.status = 'active'
     and b.slug = v_slug
   limit 1;
  if not found or not ('appointments' = any(v_enabled_modules)) then
    raise exception 'verified customer link and appointment required' using errcode = '42501';
  end if;

  /* nestly_v660 (owner ruling 2026-08-31): "this check of box is for appointments that are
     confirmed - the check will determine if business allow for reschedule/cancel after
     confirmation. because if pending they can edit or cancel freely before approval."
     business_customer_capabilities_v89.appointment_changes_enabled has existed since v89 and,
     until now, gated nothing this screen uses: the only enforcement points were the legacy v33
     action-request table and the guest manage-link, while the customer app's own reschedule and
     cancel never read it. The checkbox therefore said one thing and the app did another — an
     owner with the box UNTICKED still had customers cancelling confirmed appointments.
     It is read HERE, in the authority, not just hidden in the browser: a flag enforced only by
     which button is drawn is not a permission. A PENDING request is untouched by this — it is
     withdrawn and amended through customer_withdraw_booking_request_v290 /
     customer_amend_booking_request_v627, which is the "freely before approval" half of the
     ruling, and neither is gated. Fail closed: a business with no capability row cannot have
     opted in, so coalesce to false. */
  if not coalesce((select capability.appointment_changes_enabled
                     from public.business_customer_capabilities_v89 capability
                    where capability.business_id = v_business_id), false) then
    raise exception 'appointment_changes_disabled' using errcode = '42501';
  end if;

  select * into v_appt
    from public.appointments a
   where a.id = p_appointment
     and a.business_id = v_business_id
     and a.client_id = v_client_id
   for update;
  if not found then
    raise exception 'verified customer link and appointment required' using errcode = '42501';
  end if;
  if v_appt.status <> 'booked' then
    raise exception 'already_actioned' using errcode = '22023';
  end if;

  if (select count(*) from public.booking_requests r
       where r.business_id = v_business_id
         and r.customer_client_id = v_client_id
         and r.created_at >= now() - interval '15 minutes') >= 5 then
    raise exception 'too many booking requests; try later' using errcode = '42901';
  end if;

  select * into v_client from public.clients c
   where c.id = v_client_id and c.business_id = v_business_id;
  if not found then
    raise exception 'verified customer link and appointment required' using errcode = '42501';
  end if;

  update public.appointments
     set status = 'cancelled'
   where id = v_appt.id and business_id = v_business_id;

  insert into public.booking_requests(
    id, business_id, name, phone, email, service_id, party_size, preferred_at, notes,
    status, customer_client_id, staff_id, branch_id, marketing_consent
  ) values (
    v_request_id, v_business_id,
    coalesce(nullif(btrim(coalesce(v_client.full_name, '')), ''), 'Customer'),
    v_client.phone, v_client.email,
    v_appt.service_id, 1, p_preferred_at,
    'Reschedule: replaces the cancelled '
      || to_char(v_appt.starts_at at time zone 'Asia/Singapore', 'DD Mon HH24:MI')
      || ' appointment.' || coalesce(' ' || v_note, ''),
    'pending', v_client_id, v_appt.staff_id, v_appt.branch_id, false
  );

  v_result := jsonb_build_object(
    'status', 'pending',
    'request_id', v_request_id,
    'cancelled_appointment_id', v_appt.id,
    'preferred_at', p_preferred_at);

  insert into app.booking_management_tokens(
    token_hash, idempotency_hash, request_fingerprint,
    business_id, booking_request_id, appointment_id,
    authenticated_user_id, customer_client_id,
    expires_at, initial_response
  ) values (
    sha256(convert_to(gen_random_uuid()::text, 'UTF8')),
    sha256(convert_to('v508:' || v_actor::text || ':' || v_appt.id::text, 'UTF8')),
    sha256(convert_to(v_appt.id::text || ':' || p_preferred_at::text, 'UTF8')),
    v_business_id, v_request_id, null,
    v_actor, v_client_id,
    greatest(p_preferred_at, now()) + interval '30 days', v_result
  );

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (v_business_id, v_actor, 'appointment.rescheduled_as_fresh_request', 'appointments', v_appt.id,
    jsonb_build_object('cancelled_appointment_id', v_appt.id,
      'old_starts_at', v_appt.starts_at,
      'new_request_id', v_request_id,
      'preferred_at', p_preferred_at,
      'source', 'customer_reschedule_v508'));

  return v_result;
end;
$function$
;

revoke all on function public.customer_reschedule_appointment_v508(text, uuid, timestamptz, text) from public, anon;
grant execute on function public.customer_reschedule_appointment_v508(text, uuid, timestamptz, text) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.customer_cancel_appointment_v655(p_business_slug text, p_appointment uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_slug text := lower(btrim(coalesce(p_business_slug, '')));
  v_business_id uuid;
  v_client_id uuid;
  v_enabled_modules text[];
  v_appt public.appointments%rowtype;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;

  -- One cancel of one appointment at a time, per customer.
  perform pg_advisory_xact_lock(hashtextextended(
    'v655:cancel:' || v_actor::text || ':' || coalesce(p_appointment::text, ''), 0));

  -- Identical to v508: business, client and identity all derive from auth.uid(); the slug only
  -- narrows the verified relationship. A customer can never reach another customer's row.
  select l.business_id, l.client_id, coalesce(b.enabled_modules, '{}'::text[])
    into v_business_id, v_client_id, v_enabled_modules
    from public.customer_identities ci
    join public.customer_links l
      on l.identity_id = ci.id
     and l.auth_user_id = v_actor
     and l.state = 'verified'
    join public.businesses b on b.id = l.business_id
   where ci.auth_user_id = v_actor
     and ci.status = 'active'
     and b.slug = v_slug
   limit 1;
  if not found or not ('appointments' = any(v_enabled_modules)) then
    raise exception 'verified customer link and appointment required' using errcode = '42501';
  end if;

  /* nestly_v660 (owner ruling 2026-08-31): "this check of box is for appointments that are
     confirmed - the check will determine if business allow for reschedule/cancel after
     confirmation. because if pending they can edit or cancel freely before approval."
     business_customer_capabilities_v89.appointment_changes_enabled has existed since v89 and,
     until now, gated nothing this screen uses: the only enforcement points were the legacy v33
     action-request table and the guest manage-link, while the customer app's own reschedule and
     cancel never read it. The checkbox therefore said one thing and the app did another — an
     owner with the box UNTICKED still had customers cancelling confirmed appointments.
     It is read HERE, in the authority, not just hidden in the browser: a flag enforced only by
     which button is drawn is not a permission. A PENDING request is untouched by this — it is
     withdrawn and amended through customer_withdraw_booking_request_v290 /
     customer_amend_booking_request_v627, which is the "freely before approval" half of the
     ruling, and neither is gated. Fail closed: a business with no capability row cannot have
     opted in, so coalesce to false. */
  if not coalesce((select capability.appointment_changes_enabled
                     from public.business_customer_capabilities_v89 capability
                    where capability.business_id = v_business_id), false) then
    raise exception 'appointment_changes_disabled' using errcode = '42501';
  end if;

  select * into v_appt
    from public.appointments a
   where a.id = p_appointment
     and a.business_id = v_business_id
     and a.client_id = v_client_id
   for update;
  if not found then
    raise exception 'verified customer link and appointment required' using errcode = '42501';
  end if;
  if v_appt.status = 'cancelled' then
    -- Replay of a successful cancel is a success, not an error: the customer asked for a state
    -- and the row is in it.
    return jsonb_build_object('status', 'ok', 'appointment_id', v_appt.id, 'replayed', true);
  end if;
  if v_appt.status <> 'booked' then
    raise exception 'already_actioned' using errcode = '22023';
  end if;

  update public.appointments
     set status = 'cancelled'
   where id = v_appt.id and business_id = v_business_id;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (v_business_id, v_actor, 'appointment.cancelled_by_customer', 'appointments', v_appt.id,
          jsonb_build_object('client_id', v_client_id, 'starts_at', v_appt.starts_at,
                             'service_id', v_appt.service_id, 'source', 'v655'));

  return jsonb_build_object('status', 'ok', 'appointment_id', v_appt.id, 'replayed', false);
end
$function$
;

revoke all on function public.customer_cancel_appointment_v655(text, uuid) from public, anon;
grant execute on function public.customer_cancel_appointment_v655(text, uuid) to authenticated, service_role;

-- =============================================================================================
-- 2. "Auto-approve reschedule/cancel requests" finally means something for the customer app.
--    Owner ruling: "once there are empty slots - the reschedule should be auto approved. same for
--    new appointments are also auto approved (if check the box)."
--    businesses.auto_approve_changes has been read in exactly one place — internal_public_booking_change
--    — and there it auto-applies a CANCEL arriving through a guest manage-link, nothing else. For a
--    customer using the app the box did nothing at all: a cancel was always immediate and a
--    reschedule always waited in Bookings.
--
--    WHERE THIS HOOKS, AND WHY IT IS A TRIGGER. A booking request is created by four different
--    writers (the guest portal, the bound-customer path, the reschedule, and the owner's own
--    re-file), through three layers of SECURITY DEFINER functions. Hooking each one would mean
--    restating three large functions and would still miss the next writer. One AFTER INSERT
--    trigger on booking_requests catches every path that exists and every path that is added.
--
--    WHY IT DOES NOT REUSE convert_booking_request / book_appointment_smart_v47. Both demand a
--    STAFF session: staff_decide_booking_request_v73_v94_base raises 42501 when auth.uid() is null,
--    and book_appointment_smart_v47_v94_base additionally requires can_module_write. Neither can
--    run on a customer's or the gateway's connection, which is exactly when a request is filed.
--    What must NOT be re-derived is the availability decision, and it is not: this delegates to
--    app.staff_free_for_appointment_v47, the same single-slot authority the staff booker uses.
--
--    IT ALSO CLOSES A GAP IN THAT AUTHORITY. v47 does not look at booking_requests at all, so it
--    would call a slot free that another unanswered request has already claimed. The day-lister
--    (internal_public_booking_availability) does block those, and this mirrors that rule — without
--    it, auto-approve would be a way to double-book through the back door.
--
--    FAIL CLOSED, ALWAYS. Anything unresolved — no service, no free staff, a slot in the past, a
--    business that has not ticked the box — leaves the request exactly as it was: 'pending', for a
--    human to answer. It never raises, so a filing can never fail because auto-approve could not
--    make up its mind.
-- =============================================================================================
create or replace function app.v660_autoapprove_booking_request(p_request uuid)
returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_req public.booking_requests%rowtype;
  v_business public.businesses%rowtype;
  v_service public.services%rowtype;
  v_branch uuid;
  v_staff uuid;
  v_starts timestamptz;
  v_ends timestamptz;
  v_duration integer;
  v_appointment uuid;
begin
  select * into v_req from public.booking_requests where id = p_request for update;
  if not found then return null; end if;
  -- Only an unanswered request is a candidate. A row already confirmed, declined, cancelled or
  -- carrying an appointment is somebody's decision and is never revisited.
  if v_req.status not in ('new','pending','waitlisted') or v_req.appointment_id is not null then
    return null;
  end if;

  select * into v_business from public.businesses where id = v_req.business_id;
  if not found or not coalesce(v_business.auto_approve_changes, false) then return null; end if;

  -- A table/party request without a service has no duration and no staff to check; it keeps the
  -- capacity path it already had.
  if v_req.service_id is null or v_req.preferred_at is null then return null; end if;
  v_starts := v_req.preferred_at;
  if v_starts <= now() then return null; end if;

  select * into v_service from public.services
   where id = v_req.service_id and business_id = v_req.business_id and coalesce(active, true);
  if not found then return null; end if;
  v_duration := greatest(coalesce(v_service.duration_min, 60), 5);
  v_ends := v_starts + make_interval(mins => v_duration);

  v_branch := coalesce(v_req.branch_id, app.default_branch(v_req.business_id));
  if v_branch is null then return null; end if;

  -- The slot must not already be claimed by ANOTHER unanswered request. app.staff_free_for_appointment_v47
  -- does not consider booking_requests; the day-lister does, and auto-approve must agree with the
  -- day-lister or it becomes a way to double-book.
  if exists (
    select 1 from public.booking_requests other
     where other.business_id = v_req.business_id
       and other.id <> v_req.id
       and other.status in ('new','pending','waitlisted')
       and other.appointment_id is null
       and other.preferred_at is not null
       and coalesce(other.branch_id, v_branch) = v_branch
       and (v_req.staff_id is null or other.staff_id is null or other.staff_id = v_req.staff_id)
       and other.preferred_at < v_ends
       and other.preferred_at + make_interval(mins => v_duration) > v_starts
  ) then
    return null;
  end if;

  -- The team member the customer asked for, if they asked and are still free; otherwise the first
  -- bookable one who is. Deterministic order, so the same request always resolves the same way.
  if v_req.staff_id is not null
     and app.staff_free_for_appointment_v47(v_req.business_id, v_req.staff_id, v_branch,
           v_req.service_id, v_starts, v_ends, null) then
    v_staff := v_req.staff_id;
  elsif v_req.staff_id is null then
    select candidate.staff_id into v_staff
      from app.v183_bookable_staff(v_req.business_id, v_req.service_id, null, v_branch) candidate
     where app.staff_free_for_appointment_v47(v_req.business_id, candidate.staff_id, v_branch,
             v_req.service_id, v_starts, v_ends, null)
     order by candidate.staff_id
     limit 1;
  end if;
  if v_staff is null then return null; end if;

  insert into public.appointments(business_id, client_id, staff_id, starts_at, ends_at, status,
    party_size, source, service_id, note, branch_id)
  values(v_req.business_id, v_req.customer_client_id, v_staff, v_starts, v_ends, 'booked',
    greatest(coalesce(v_req.party_size, 1), 1), 'portal', v_req.service_id, v_req.notes, v_branch)
  returning id into v_appointment;

  update public.booking_requests
     set status = 'confirmed', appointment_id = v_appointment, expires_at = null
   where id = v_req.id;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values(v_req.business_id, null, 'booking_request.auto_approved_v660', 'booking_requests', v_req.id,
    jsonb_build_object('appointment_id', v_appointment, 'staff_id', v_staff, 'branch_id', v_branch,
                       'starts_at', v_starts, 'service_id', v_req.service_id,
                       'requested_staff', v_req.staff_id));

  return v_appointment;
end
$function$;

revoke all on function app.v660_autoapprove_booking_request(uuid) from public, anon, authenticated, service_role;

create or replace function app.v660_booking_request_autoapprove()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
begin
  /* Never let auto-approve break the filing. A request that could not be auto-approved — for any
     reason at all, including an unexpected one — must still exist as 'pending' for a human. */
  begin
    perform app.v660_autoapprove_booking_request(new.id);
  exception when others then
    null;
  end;
  return null;
end
$function$;

revoke all on function app.v660_booking_request_autoapprove() from public, anon, authenticated, service_role;

drop trigger if exists trg_booking_request_autoapprove_v660 on public.booking_requests;
create trigger trg_booking_request_autoapprove_v660
  after insert on public.booking_requests
  for each row execute function app.v660_booking_request_autoapprove();

-- =============================================================================================
-- 3. Delete on Services and Products, following the Packages model.
--    Owner: photo 7's row "will be the model that other modules follow (status / edit / delete)
--    will be the same for products & services". v658 aligned Status and Edit; this is Delete.
--
--    WHY IT CANNOT SIMPLY DELETE. A service or a product is referenced far more widely than a
--    package plan, and several of those references are ON DELETE RESTRICT: appointment_services
--    and loyalty_reward_services for a service, sale_items, bar_bottles and
--    loyalty_reward_products for a product. The moment either has been used ONCE, a raw delete
--    raises 23503 — which is exactly how the v601 package delete failed in production, behind a
--    generic toast, until v655 fixed it. Worse, several other references CASCADE silently:
--    deleting a service would take its branch list, its staff mapping and its BUNDLE MEMBERSHIP
--    with it, and a bundle that quietly loses a member still charges the bundle price, spreading
--    it across the survivors.
--
--    SO THE RULE IS THE PACKAGES RULE, with a wider definition of "used": if anything at all
--    refers to it — a past appointment or sale, a booking request, a waitlist entry, a package, a
--    reward, a bundle, a tier discount's eligibility — it is switched OFF and KEPT, with the
--    decision recorded. Only something nothing refers to is actually removed. An owner is never
--    shown a delete that silently rewrites a bundle's economics or strands a receipt.
--
--    retired_at is added to both tables for the same reason package_plans needed it in v601:
--    `active=false` is a pause, and there was nowhere to record that this one was a decision.
-- =============================================================================================
alter table public.services add column if not exists retired_at timestamptz;
alter table public.products add column if not exists retired_at timestamptz;

create or replace function public.business_manage_catalogue_item_v660(
  p_business uuid, p_kind text, p_item uuid, p_action text)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_kind text := lower(btrim(coalesce(p_kind, '')));
  v_used integer := 0;
  v_name text;
  v_active boolean;
  v_retired timestamptz;
  v_retiring boolean := false;
begin
  if p_action <> 'delete' then
    raise exception 'unsupported catalogue action' using errcode = '22023';
  end if;
  if v_kind not in ('service','product') then
    raise exception 'catalogue item must be a service or a product' using errcode = '22023';
  end if;
  -- Each catalogue lives behind its own module, exactly as its page does.
  if not app.can_module_write(p_business, case when v_kind = 'service' then 'services' else 'inventory' end) then
    raise exception 'catalogue write access is required' using errcode = '42501';
  end if;

  if v_kind = 'service' then
    select name, active, retired_at into v_name, v_active, v_retired
      from public.services where id = p_item and business_id = p_business for update;
    if not found then raise exception 'service not found in this business' using errcode = '42704'; end if;
    select
      (select count(*) from public.appointment_services x where x.service_id = p_item)
    + (select count(*) from public.appointments x where x.service_id = p_item)
    + (select count(*) from public.booking_requests x where x.service_id = p_item)
    + (select count(*) from public.waitlist x where x.service_id = p_item)
    + (select count(*) from public.package_plans x where x.service_id = p_item)
    + (select count(*) from public.loyalty_reward_services x where x.service_id = p_item)
    + (select count(*) from public.bundle_items x where x.service_id = p_item)
    + (select count(*) from public.tier_benefit_scope_v656 x where x.service_id = p_item)
    + (select count(*) from public.sale_items x where x.business_id = p_business and x.ref_id = p_item)
      into v_used;
  else
    select name, active, retired_at into v_name, v_active, v_retired
      from public.products where id = p_item and business_id = p_business for update;
    if not found then raise exception 'product not found in this business' using errcode = '42704'; end if;
    select
      (select count(*) from public.sale_items x where x.product_id = p_item)
    + (select count(*) from public.sales x where x.product_id = p_item)
    + (select count(*) from public.stock_batches x where x.product_id = p_item)
    + (select count(*) from public.bar_bottles x where x.product_id = p_item)
    + (select count(*) from public.loyalty_reward_products x where x.product_id = p_item)
    + (select count(*) from public.bundle_items x where x.product_id = p_item)
    + (select count(*) from public.tier_benefit_scope_v656 x where x.product_id = p_item)
    + (select count(*) from public.tier_benefits_v365 x where x.product_id = p_item)
    + (select count(*) from public.service_products x where x.product_id = p_item)
      into v_used;
  end if;

  if v_used > 0 then
    if v_retired is not null then
      raise exception 'this item is already off sale' using errcode = '22023';
    end if;
    v_retiring := true;
    if v_kind = 'service' then
      update public.services set active = false, retired_at = now()
       where id = p_item and business_id = p_business;
    else
      update public.products set active = false, retired_at = now()
       where id = p_item and business_id = p_business;
    end if;
  else
    if v_kind = 'service' then
      delete from public.services where id = p_item and business_id = p_business;
    else
      delete from public.products where id = p_item and business_id = p_business;
    end if;
  end if;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values(p_business, auth.uid(),
         v_kind || '.' || case when v_retiring then 'retire' else 'delete' end,
         case when v_kind = 'service' then 'services' else 'products' end, p_item,
         jsonb_build_object('name', v_name, 'used_by', v_used, 'retired', v_retiring));

  return json_build_object('status','ok','kind',v_kind,
    'action', case when v_retiring then 'retire' else 'delete' end,
    'item_id', p_item, 'used_by', v_used);
end
$function$;

revoke all on function public.business_manage_catalogue_item_v660(uuid, text, uuid, text) from public, anon;
grant execute on function public.business_manage_catalogue_item_v660(uuid, text, uuid, text) to authenticated, service_role;

commit;
