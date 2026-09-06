/* nestly_v806 — a GUEST booking can auto-approve, instead of failing silently and sitting
   pending forever while an identical signed-in booking confirms.

   Audit finding W4G (P1, confirmed read-only against production gadpooereceldfpfxsod on
   2026-09-06 with a rolled-back probe run as the real principal).

   THE DEFECT — one NOT NULL column, an error nobody could see.
     app.v660_autoapprove_booking_request ends by creating the appointment:

       insert into public.appointments(business_id, client_id, staff_id, ...)
       values(v_req.business_id, v_req.customer_client_id, v_staff, ...)

     public.appointments.client_id is NOT NULL. booking_requests.customer_client_id is the
     SIGNED-IN customer's client row, filled in only on the bound path
     (app.request_bound_booking_v72 via app.resolve_verified_booking_client_v72). A guest —
     anyone who books from the public portal without signing in — files through
     public.request_booking, which writes name/email/phone and leaves customer_client_id NULL.
     So for a guest the insert raised 23502, and BOTH call sites swallow it:

       app.v660_booking_request_autoapprove()  -> begin ... exception when others then null; end
       public.internal_public_booking_submit(16 args) -> the same, v_auto_appointment := null

     The swallow is deliberate and stays (a failed auto-approve must never fail the customer's
     filing — v678). What it hid is that guest auto-approve could not succeed AT ALL. The
     business had switched auto-approve on; a signed-in customer's request confirmed instantly;
     the guest's identical request stayed 'new' and waited for a human who had been told the
     firm no longer needed to answer these. Live proof, rolled back, on production:

       GUEST submit on an auto-approve business
         -> answer.status=pending  request.status=new  appointment=<none>
            customer_client_id_is_null=true
       app.v660_autoapprove_booking_request called directly on that same request
         -> sqlstate=23502  "null value in column \"client_id\" of relation \"appointments\"
            violates not-null constraint"

     Exactly one variable separates the confirmed request from the abandoned one: whether the
     person was signed in when they booked.

   THE FIX — resolve the client the way the manual confirmation already does.
     public.staff_decide_booking_request_v73_v94_base, the path a human takes when they press
     Confirm on the same request, does this for a guest:

       v_client := app.upsert_portal_client(business, name, phone, email);
       perform app.apply_booking_consent(business, v_client, marketing_consent);

     public.request_booking's own auto-confirm branch (table bookings) does the identical two
     calls. v660 now does the same two calls, so auto-approve and manual approval create the
     SAME customer for the same request. That is the whole point: this is not a new customer
     route, it is the existing one, reached from the other decision.

     NO DUPLICATE CUSTOMERS. app.upsert_portal_client matches an existing row first, on
     clients.phone_norm (app.norm_phone, partial-unique on (business_id, phone_norm)) or on
     lower(email), and only inserts when neither matches — with an ON CONFLICT re-read for the
     concurrent case. A returning guest is recognised, not cloned.

     NO WIDENED PERMISSION. v660 was and remains reachable only by postgres: its two callers are
     SECURITY DEFINER, and its ACL is restated below unchanged. The customer gains no new right;
     the firm's own auto-approve setting is still the only thing that turns any of this on.

   WHERE THE RESOLUTION SITS. Immediately before the appointment insert, AFTER every one of
   v660's `return null` exits (not an auto-approve business, no service, slot in the past,
   service gone, no branch, the slot already claimed by another unanswered request, nobody free).
   A request that is not going to be approved must not create a customer as a side effect.

   REFUSING LOUDLY INSTEAD OF SWALLOWING. app.upsert_portal_client can, in principle, return NULL
   (a phone that normalises to NULL and an email that matches nothing, losing the ON CONFLICT
   race with nothing to re-read). Rather than let a NULL reach the NOT NULL column and become a
   swallowed 23502 again, v660 records a NAMED refusal in public.audit_log
   ('booking_request.auto_approve_skipped_v806', reason 'client_unresolved') and returns null.
   The request stays pending for a human — the correct, fail-closed outcome — and the skip is
   now visible in the audit trail instead of being invisible in an exception handler.
   audit_log's payload column is `detail`; it has never been `meta`.

   NOT CHANGED, deliberately:
     * booking_requests.customer_client_id. It means "the VERIFIED signed-in customer bound to
       this request" and is compared against app.booking_management_tokens.customer_client_id to
       detect an idempotency conflict. A guest is not that, and the manual confirmation path does
       not write it back either. The appointment's client_id carries the linkage, as it always
       has for a guest confirmed by hand.
     * The two exception handlers that swallow. They are the v678 fail-open guarantee. With the
       foreseeable throw removed and the remaining skip audited, they no longer hide anything.
     * Every other decision in v660 — the auto_approve_changes gate, the service/branch/slot
       checks, the overlap test against other unanswered requests, the staff choice and the
       deterministic `order by candidate.staff_id` fallback, the audit row it already writes.
       Only the client is new.

   Rollback suite: db/tests/v806_guest_booking_autoapprove.sql */
begin;

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
  v_client uuid;
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

  /* nestly_v806: public.appointments.client_id is NOT NULL, and a GUEST request carries no
     customer_client_id. Resolve the customer exactly as the manual confirmation does
     (public.staff_decide_booking_request_v73_v94_base) and as public.request_booking's own
     auto-confirm branch does — match an existing customer on normalised phone or email first,
     create one only when neither matches, and apply the booking's marketing consent only to a
     customer this filing actually created. Without this the insert below raised 23502 and both
     callers swallowed it, so guest auto-approve silently never happened. */
  if v_req.customer_client_id is not null then
    v_client := v_req.customer_client_id;
  else
    v_client := app.upsert_portal_client(v_req.business_id, v_req.name, v_req.phone, v_req.email);
    perform app.apply_booking_consent(v_req.business_id, v_client, v_req.marketing_consent);
  end if;
  if v_client is null then
    /* Fail closed, and say so. The request stays pending for a human rather than dying inside a
       caller's `exception when others then null`. */
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values(v_req.business_id, null, 'booking_request.auto_approve_skipped_v806',
      'booking_requests', v_req.id,
      jsonb_build_object('reason', 'client_unresolved', 'staff_id', v_staff,
                         'branch_id', v_branch, 'starts_at', v_starts));
    return null;
  end if;

  insert into public.appointments(business_id, client_id, staff_id, starts_at, ends_at, status,
    party_size, source, service_id, note, branch_id)
  values(v_req.business_id, v_client, v_staff, v_starts, v_ends, 'booked',
    greatest(coalesce(v_req.party_size, 1), 1), 'portal', v_req.service_id, v_req.notes, v_branch)
  returning id into v_appointment;

  update public.booking_requests
     set status = 'confirmed', appointment_id = v_appointment, expires_at = null
   where id = v_req.id;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values(v_req.business_id, null, 'booking_request.auto_approved_v660', 'booking_requests', v_req.id,
    jsonb_build_object('appointment_id', v_appointment, 'staff_id', v_staff, 'branch_id', v_branch,
                       'starts_at', v_starts, 'service_id', v_req.service_id,
                       'requested_staff', v_req.staff_id, 'client_id', v_client,
                       'guest', v_req.customer_client_id is null));

  return v_appointment;
end
$function$;

/* ACL restated verbatim from production (proacl {postgres=X/postgres}): this helper has never
   been callable by a client role and is not made callable here. Its two callers are SECURITY
   DEFINER and run as the owner. */
revoke all on function app.v660_autoapprove_booking_request(uuid) from public, anon, authenticated, service_role;

comment on function app.v660_autoapprove_booking_request(uuid) is
  'nestly_v660/v678/v806 decides an unanswered booking request when the firm has auto_approve_changes on. v806: a GUEST request (no customer_client_id) resolves its customer through app.upsert_portal_client + app.apply_booking_consent, the same two calls the manual confirmation makes, because public.appointments.client_id is NOT NULL and the insert used to raise a swallowed 23502. An unresolvable customer is recorded as booking_request.auto_approve_skipped_v806 and left pending, never silently dropped.';

-- =============================================================================================
-- Prove the change took, in the same transaction that made it.
-- =============================================================================================
do $verify$
declare
  v_def text := pg_get_functiondef('app.v660_autoapprove_booking_request(uuid)'::regprocedure);
begin
  if position('app.upsert_portal_client' in v_def) = 0
     or position('app.apply_booking_consent' in v_def) = 0 then
    raise exception 'nestly_v806: auto-approve does not resolve a guest customer the way the manual confirmation does'
      using errcode = 'XX001';
  end if;
  /* The appointment must be inserted with the RESOLVED client, not the request column that is
     NULL for every guest. If this string comes back, the defect is back. */
  if position('values(v_req.business_id, v_req.customer_client_id, v_staff' in v_def) <> 0 then
    raise exception 'nestly_v806: the appointment is still inserted with booking_requests.customer_client_id'
      using errcode = 'XX001';
  end if;
  if position('values(v_req.business_id, v_client, v_staff' in v_def) = 0 then
    raise exception 'nestly_v806: the appointment is not inserted with the resolved client'
      using errcode = 'XX001';
  end if;
  if position('auto_approve_skipped_v806' in v_def) = 0 then
    raise exception 'nestly_v806: an unresolvable customer is not recorded — it would be swallowed again'
      using errcode = 'XX001';
  end if;
  /* The client is resolved AFTER the last refusal, so a request that will not be approved never
     creates a customer. */
  if position('app.upsert_portal_client' in v_def) < position('if v_staff is null then return null; end if;' in v_def) then
    raise exception 'nestly_v806: the customer is resolved before auto-approve has finished refusing'
      using errcode = 'XX001';
  end if;
  if exists (select 1 from information_schema.routine_privileges
              where routine_schema = 'app'
                and routine_name = 'v660_autoapprove_booking_request'
                and grantee in ('anon','authenticated','service_role','PUBLIC')) then
    raise exception 'nestly_v806: the auto-approve helper became reachable by a client role'
      using errcode = 'XX001';
  end if;
  /* This migration assumes the constraint that caused the bug still exists. If client_id ever
     becomes nullable, the reasoning above needs re-reading rather than silently passing. */
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'appointments'
                and column_name = 'client_id' and is_nullable = 'YES') then
    raise exception 'nestly_v806: appointments.client_id is no longer NOT NULL — re-read this migration'
      using errcode = 'XX001';
  end if;
end
$verify$;

commit;
