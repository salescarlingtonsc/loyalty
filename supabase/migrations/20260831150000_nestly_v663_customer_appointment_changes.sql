/* nestly_v663 — a confirmed booking becomes changeable from the booking itself, and the
   auto-approve tick finally decides whether that change needs anyone's permission.

   Owner ruling (2026-08-31 review, photos 1 and 2): "confirmed appointment should be Modify &
   Cancel ... if there's a tick on photo 2 it should auto amend without business approval ... but
   if requires approval - please let customer know, and attach the exact phone number to let
   customer call".

   Three things were missing on the server, and the browser cannot invent any of them:

   1. AUTO-APPROVE NEVER REACHED THE CUSTOMER APP. v660 built app.v660_autoapprove_booking_request
      and wired it into the public booking path only. customer_reschedule_appointment_v508 filed
      its replacement request and returned 'pending' unconditionally — so a business with the box
      TICKED still made its customers wait, and app.js's own toast branch on `auto_approved` was
      unreachable code. The reschedule now offers the same request to the same helper; the helper
      keeps its own auto_approve_changes test, so a business with the box unticked is unaffected.

   2. CANCEL WAS ALL-OR-NOTHING. customer_cancel_appointment_v655 cancelled the appointment
      outright the moment appointment_changes_enabled was on, whatever auto-approve said. The two
      settings mean different things: the first says a confirmed booking MAY be changed, the
      second says the change needs no answer. Without auto-approve the cancellation is now a
      PENDING public.change_requests row — the table the business's own Bookings page already
      lists and decides through decide_change — and the appointment stays booked until they
      answer. Nothing is silently dropped, and nothing is cancelled behind the counter's back.

   3. THE CUSTOMER HAD NO NUMBER TO CALL. The appointments feed carried the branch name and
      address since v580 but not its phone, so "call them instead" could only be written as a
      sentence with no number in it. branches.phone travels with the row it belongs to; a branch
      with no number on file simply sends none, and the app says so rather than printing a blank.

   Rollback suite: db/tests/v663_customer_appointment_changes.sql */
begin;

-- =============================================================================================
-- 1. The appointments feed carries the branch's phone number.
--    Same projection as branch_address (nullif/btrim, from the branch actually joined to the
--    appointment), so a multi-branch firm gives the number of the shop the customer is going to
--    rather than a head-office line.
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.customer_get_appointments_page(p_business_slug text, p_cursor jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_context record;
  v_cursor jsonb := coalesce(p_cursor, '{}'::jsonb);
  v_limit integer := 20;
  v_as_of timestamptz := statement_timestamp();
  v_cursor_group integer;
  v_cursor_at timestamptz;
  v_cursor_id uuid;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if jsonb_typeof(v_cursor) <> 'object' then
    raise exception 'invalid appointments cursor' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_object_keys(v_cursor) as keys(key)
              where key not in ('limit','as_of','sort_group','starts_at','id')) then
    raise exception 'invalid appointments cursor' using errcode = '22023';
  end if;
  begin
    v_limit := least(greatest(coalesce((v_cursor->>'limit')::integer, 20), 1), 50);
    v_as_of := coalesce(nullif(v_cursor->>'as_of', '')::timestamptz, v_as_of);
    v_cursor_group := nullif(v_cursor->>'sort_group', '')::integer;
    v_cursor_at := nullif(v_cursor->>'starts_at', '')::timestamptz;
    v_cursor_id := nullif(v_cursor->>'id', '')::uuid;
  exception when others then
    raise exception 'invalid appointments cursor' using errcode = '22023';
  end;
  if v_cursor_group is not null and v_cursor_group not in (0,1) then
    raise exception 'invalid appointments cursor' using errcode = '22023';
  end if;
  if num_nonnulls(v_cursor_group,v_cursor_at,v_cursor_id) not in (0,3) then
    raise exception 'appointments cursor is incomplete' using errcode = '22023';
  end if;

  select * into v_context from app.v32_customer_wallet_context(p_business_slug) limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;
  if not ('appointments' = any(v_context.enabled_modules)) then
    raise exception 'appointments module is unavailable for this business' using errcode = '42501';
  end if;

  with ordered as (
    select a.id, a.starts_at, a.ends_at, a.status,
           case when a.status = 'booked' and a.starts_at >= v_as_of then 0 else 1 end as sort_group,
           s.name as service_name, br.name as branch_name, nullif(btrim(br.address), '') as branch_address,
           nullif(btrim(br.phone), '') as branch_phone
      from public.appointments a
      left join public.services s on s.id = a.service_id and s.business_id = a.business_id
      left join public.branches br on br.id = a.branch_id and br.business_id = a.business_id
     where a.business_id = v_context.business_id
       and a.client_id = v_context.client_id
       and a.status in ('booked','completed','cancelled','no_show')
  ), eligible as (
    select * from ordered
     where v_cursor_group is null
        or sort_group > v_cursor_group
        or (
          sort_group = v_cursor_group and (
            (sort_group = 0 and (starts_at,id) > (v_cursor_at,v_cursor_id))
            or (sort_group = 1 and (starts_at,id) < (v_cursor_at,v_cursor_id))
          )
        )
     order by sort_group,
              case when sort_group=0 then starts_at end asc,
              case when sort_group=1 then starts_at end desc,
              case when sort_group=0 then id end asc,
              case when sort_group=1 then id end desc
     limit v_limit + 1
  ), visible as (
    select * from eligible
     order by sort_group,
              case when sort_group=0 then starts_at end asc,
              case when sort_group=1 then starts_at end desc,
              case when sort_group=0 then id end asc,
              case when sort_group=1 then id end desc
     limit v_limit
  )
  select jsonb_build_object(
    'items', coalesce((select jsonb_agg(jsonb_build_object(
      'appointment_id', id, 'starts_at', starts_at, 'ends_at', ends_at,
      'status', status, 'service_name', service_name, 'branch_name', branch_name,
      'branch_address', branch_address, 'branch_phone', branch_phone
    ) order by sort_group,
               case when sort_group=0 then starts_at end asc,
               case when sort_group=1 then starts_at end desc,
               case when sort_group=0 then id end asc,
               case when sort_group=1 then id end desc) from visible), '[]'::jsonb),
    'next_cursor', case when (select count(*) from eligible) > v_limit then (
      select jsonb_build_object(
        'as_of', v_as_of, 'sort_group', sort_group, 'starts_at', starts_at,
        'id', id, 'limit', v_limit
      ) from visible
       order by sort_group,
                case when sort_group=0 then starts_at end asc,
                case when sort_group=1 then starts_at end desc,
                case when sort_group=0 then id end asc,
                case when sort_group=1 then id end desc
       offset v_limit - 1 limit 1
    ) else null end
  ) into v_result;

  return v_result;
end;
$function$;

revoke all on function public.customer_get_appointments_page(text, jsonb) from public, anon;
grant execute on function public.customer_get_appointments_page(text, jsonb) to authenticated, service_role;

-- =============================================================================================
-- 2. The customer surface can see whether a change will need an answer.
--    appointment_changes.enabled already says "you may ask"; auto_approve says "and nobody has to
--    say yes". Both are needed to write an honest sentence BEFORE the customer presses anything.
--    It is reported false whenever changes are disabled, because an auto-approval of an action
--    that cannot be taken is not a fact about anything.
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.customer_get_business_actions_v89(p_business uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_identity uuid;v_client uuid;v_result jsonb;
  v_program public.loyalty_programs%rowtype;
begin
  v_identity:=app.v31_current_identity();
  select link.client_id into v_client from public.customer_links link
  where link.identity_id=v_identity and link.auth_user_id=auth.uid()
    and link.business_id=p_business and link.state='verified';
  if not found then raise exception 'verified customer link required' using errcode='42501';end if;
  select * into v_program from public.loyalty_programs program
    where program.business_id=p_business and program.active
    order by program.id limit 1;
  select jsonb_build_object(
    'business',jsonb_build_object('id',business.id,'slug',business.slug,
      'name',business.name,'industry',business.industry,'currency',business.currency),
    'booking',jsonb_build_object('enabled',
      coalesce(capability.booking_enabled,false)
      and app.v89_business_module_enabled(p_business,'bookings') and exists(
        select 1 from public.services service where service.business_id=p_business
          and service.active and service.show_on_booking_page),
      'public_slug',case when coalesce(capability.booking_enabled,false)
        and app.v89_business_module_enabled(p_business,'bookings') and exists(
        select 1 from public.services service where service.business_id=p_business
          and service.active and service.show_on_booking_page)
        then business.slug else null end),
    'redemption',jsonb_build_object(
      'enabled',coalesce(capability.redemption_enabled,false)
        and app.v89_business_module_enabled(p_business,'loyalty')
        and v_program.id is not null,
      -- v376: the points-for-store-credit action is never offered. v375 retired the model and made
      -- app.redeem_points_v40_internal refuse, so leaving this in place would have shown a customer
      -- a redemption their own counter could no longer honour.
      'classic',null::jsonb),
    'appointment_changes',jsonb_build_object(
      'enabled',coalesce(capability.appointment_changes_enabled,false)
        and app.v89_business_module_enabled(p_business,'appointments'),
      -- nestly_v663: does a permitted change still need the business to say yes?
      'auto_approve',coalesce(capability.appointment_changes_enabled,false)
        and app.v89_business_module_enabled(p_business,'appointments')
        and coalesce(business.auto_approve_changes,false)),
    -- nestly_v432: availability from the one core the counter and the catalogue read. This adds
    -- the tier gate and the past-card-end rule this list was missing, and pins stamp gifts to
    -- the customer's open-cycle config exactly as redemption does. Restricted rewards remain
    -- truthfully excluded from this actionable scan list (customer QR redemption carries no
    -- visit context in v89).
    'rewards',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',core.reward_id,'name',core.customer_name,
        'redemption_kind','catalog_reward',
        'cost_points',core.cost_points,
        'source',core.source,
        'unit',core.unit,
        'availability',case
          when not coalesce(capability.redemption_enabled,false)
            or not app.v89_business_module_enabled(p_business,'loyalty')
            then 'disabled'
          else core.availability end
      ) order by core.sort,core.reward_id)
      from app.reward_availability_v432(p_business, v_client, now()) core
      where core.branch_count=0 and core.service_count=0 and core.product_count=0
    ),'[]'::jsonb)
  ) into v_result
  from public.businesses business
  left join public.business_customer_capabilities_v89 capability
    on capability.business_id=business.id
  where business.id=p_business;
  return v_result;
end;
$function$;

revoke all on function public.customer_get_business_actions_v89(uuid) from public, anon;
grant execute on function public.customer_get_business_actions_v89(uuid) to authenticated, service_role;

-- =============================================================================================
-- 3. The reschedule reports what actually happened to it.
--    v660 auto-approves through trg_booking_request_autoapprove_v660, an AFTER INSERT trigger on
--    public.booking_requests, so the replacement request THIS function files was already being
--    confirmed on the spot at an auto-approving business with a free slot. What was wrong was the
--    answer: the result object was built from the values passed in and hard-coded 'pending', so a
--    customer whose new time had already been accepted, and whose appointment already existed,
--    was told to wait for it. app.js has carried the `auto_approved` branch of that toast since
--    v660 and it was unreachable.
--    The row is simply re-read after the insert — the AFTER ROW trigger has fired by then — and
--    the outcome reported as it stands. No second auto-approve attempt: calling the helper again
--    here would ask it to re-decide a request it has already decided.
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
  v_auto_appointment uuid;
  v_request_status text;
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
     Fail closed: a business with no capability row cannot have opted in. */
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

  /* nestly_v663: read the request back rather than asserting its state. trg_booking_request_
     autoapprove_v660 has already run by this point and may have confirmed it and created the
     appointment; saying 'pending' regardless was the one thing this function could not know. */
  select r.status, r.appointment_id into v_request_status, v_auto_appointment
    from public.booking_requests r
   where r.id = v_request_id;

  v_result := jsonb_build_object(
    'status', coalesce(v_request_status, 'pending'),
    'auto_approved', v_auto_appointment is not null,
    'appointment_id', v_auto_appointment,
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
      'auto_approved_appointment_id', v_auto_appointment,
      'source', 'customer_reschedule_v508'));

  return v_result;
end;
$function$;

revoke all on function public.customer_reschedule_appointment_v508(text, uuid, timestamptz, text) from public, anon;
grant execute on function public.customer_reschedule_appointment_v508(text, uuid, timestamptz, text) to authenticated, service_role;

-- =============================================================================================
-- 4. Cancelling a confirmed booking asks, unless the business said it need not be asked.
--    v655 cancelled outright whenever appointment_changes_enabled was on. That conflated the two
--    settings the owner keeps as separate boxes: "customers may change a confirmed appointment"
--    and "accept their change without waiting for you". Without the second, the cancellation is
--    now a pending public.change_requests row — the table the Bookings page already lists and
--    decides through public.decide_change — and the appointment stays booked meanwhile. The
--    guest manage-link path (public.request_change) has behaved exactly this way since it shipped;
--    this makes the signed-in customer's cancel the same act rather than a privileged one.
--
--    A second press while a request is pending returns that request instead of filing another:
--    the customer asked for a state and is already in it.
-- =============================================================================================
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
  v_auto boolean := false;
  v_appt public.appointments%rowtype;
  v_phone text;
  v_request_id uuid;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;

  -- One cancel of one appointment at a time, per customer.
  perform pg_advisory_xact_lock(hashtextextended(
    'v655:cancel:' || v_actor::text || ':' || coalesce(p_appointment::text, ''), 0));

  -- Identical to v508: business, client and identity all derive from auth.uid(); the slug only
  -- narrows the verified relationship. A customer can never reach another customer's row.
  select l.business_id, l.client_id, coalesce(b.enabled_modules, '{}'::text[]),
         coalesce(b.auto_approve_changes, false)
    into v_business_id, v_client_id, v_enabled_modules, v_auto
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

  /* nestly_v660 (owner ruling 2026-08-31): the tick governs whether a CONFIRMED appointment may
     be changed at all. Fail closed: a business with no capability row cannot have opted in. */
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
    return jsonb_build_object('status', 'ok', 'auto_approved', true,
                              'appointment_id', v_appt.id, 'replayed', true);
  end if;
  if v_appt.status <> 'booked' then
    raise exception 'already_actioned' using errcode = '22023';
  end if;

  if v_auto then
    update public.appointments
       set status = 'cancelled'
     where id = v_appt.id and business_id = v_business_id;

    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (v_business_id, v_actor, 'appointment.cancelled_by_customer', 'appointments', v_appt.id,
            jsonb_build_object('client_id', v_client_id, 'starts_at', v_appt.starts_at,
                               'service_id', v_appt.service_id, 'source', 'v663:auto_approved'));

    return jsonb_build_object('status', 'ok', 'auto_approved', true,
                              'appointment_id', v_appt.id, 'replayed', false);
  end if;

  -- nestly_v663: no auto-approve, so this is a request and not a cancellation.
  select r.id into v_request_id
    from public.change_requests r
   where r.business_id = v_business_id
     and r.appointment_id = v_appt.id
     and r.kind = 'cancel'
     and r.status = 'pending'
   order by r.created_at
   limit 1;
  if found then
    return jsonb_build_object('status', 'pending', 'auto_approved', false,
                              'appointment_id', v_appt.id, 'request_id', v_request_id,
                              'replayed', true);
  end if;

  select c.phone into v_phone from public.clients c
   where c.id = v_client_id and c.business_id = v_business_id;

  insert into public.change_requests(business_id, appointment_id, kind, proposed_at, phone, note, status)
  values (v_business_id, v_appt.id, 'cancel', null, v_phone,
          'Cancellation asked for in the Peekaa app.', 'pending')
  returning id into v_request_id;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (v_business_id, v_actor, 'appointment.cancel_requested_by_customer', 'appointments', v_appt.id,
          jsonb_build_object('client_id', v_client_id, 'starts_at', v_appt.starts_at,
                             'service_id', v_appt.service_id, 'change_request_id', v_request_id,
                             'source', 'v663'));

  return jsonb_build_object('status', 'pending', 'auto_approved', false,
                            'appointment_id', v_appt.id, 'request_id', v_request_id,
                            'replayed', false);
end;
$function$;

revoke all on function public.customer_cancel_appointment_v655(text, uuid) from public, anon;
grant execute on function public.customer_cancel_appointment_v655(text, uuid) to authenticated, service_role;

commit;
