-- NESTLY v678 — auto-approve honours the customer's staff and branch choice.
--
-- THE DEFECT (audit F062). v660 hooked auto-approve to trg_booking_request_autoapprove_v660,
-- an AFTER INSERT trigger on public.booking_requests. That was the right shape for the four
-- writers that existed, because every one of them writes the whole request in one INSERT.
-- The public booking path is the exception and nobody noticed: public.request_booking and
-- app.request_bound_booking_v72 insert the row WITHOUT staff_id/branch_id, and the 16-argument
-- public.internal_public_booking_submit (v183 staff choice, v327 branch choice) stamps the
-- customer's choice on afterwards with an UPDATE.
--
-- So at trigger time both columns were NULL. app.v660_autoapprove_booking_request read that as
-- "the customer did not ask for anybody", fell into its `elsif v_req.staff_id is null` branch,
-- picked the lowest-uuid free team member at coalesce(NULL, default branch), created the
-- appointment and set the request to 'confirmed'. The wrapper then wrote the customer's real
-- staff and branch onto a request that was already confirmed for somebody else, at the wrong
-- shop, and could not repair the appointment: its `if v_appointment is not null` branch reads
-- appointment_id out of the INNER result, which was built before the trigger's appointment
-- existed and never carries it. Observed live at Cubbly SPA on 2026-08-31 08:58:51Z: the
-- customer asked for Chuan and was booked with Kelvin.
--
-- Two further consequences of the same ordering, both fixed here:
--   * A customer who asked for a team member who is NOT free at that time was silently given a
--     substitute, instead of the correct outcome — leave it pending for a human to answer.
--   * The API answered with the inner hard-coded 'pending', so a customer whose booking had
--     already been confirmed was told to wait for manual review. app/app.js has carried the
--     'confirmed' card since the portal shipped and it was unreachable on this path.
--
-- THE FIX, AT THE WRITER. The choice cannot be moved into the INSERT without threading two more
-- parameters through public.request_booking (a stable guest RPC) and app.request_bound_booking_v72
-- and restating both — three large functions for two columns. Instead the auto-approve is
-- DEFERRED for exactly the window in which the row is knowingly incomplete: the 16-arg wrapper
-- raises a transaction-local flag around its call to the 14-arg submit, the trigger honours the
-- flag and does nothing, and the wrapper calls app.v660_autoapprove_booking_request itself once
-- the choice columns are written. Same helper, same availability authority, same fail-closed
-- behaviour — only the moment changes.
--
-- WHY A FLAG AND NOT A SECOND TRIGGER. A trigger on UPDATE OF staff_id/branch_id would fire for
-- every later edit of those columns by anyone (the staff decision path writes them too), so it
-- would have to re-derive "is this still the original filing?" from the row. The flag says the
-- one thing that is actually true and that only the caller can know: this INSERT is half of a
-- two-statement filing, do not judge it yet. It is set with set_config(..., true) — transaction
-- local — so it cannot leak into another statement, another session, or a failed transaction.
--
-- FAIL CLOSED IS PRESERVED IN BOTH DIRECTIONS. The deferred call is wrapped in the same
-- swallow-everything block the trigger used, so auto-approve still cannot make a filing fail.
-- And because the flag is only ever raised immediately around the inner submit and lowered on
-- the next line, an unexpected exit path leaves the trigger armed, not disarmed.
--
-- THE ANSWER IS RE-READ, NOT ASSERTED — the v663 rule. After the deferred attempt the request
-- row is read back; only a row that is genuinely 'confirmed' with an appointment upgrades the
-- reply, so no other status ('new', 'pending', 'waitlisted', 'declined') can be disturbed. The
-- idempotency token's stored initial_response is rewritten to match, so a replayed submission
-- tells the customer the same story as the first one.
--
-- NO SIGNATURE CHANGE. supabase/functions/public-booking/index.ts calls the same 16-argument RPC
-- with the same named arguments and is untouched.

begin;

-- ---------------------------------------------------------------------------------------------
-- 1. The trigger stands down while a two-statement filing is in flight.
--    app.v660_autoapprove_booking_request itself is NOT touched: its decision was never wrong,
--    it was only asked too early.
-- ---------------------------------------------------------------------------------------------
create or replace function app.v660_booking_request_autoapprove()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
begin
  /* nestly_v678 (audit F062): the public booking path files a request in two statements — the
     INSERT, then an UPDATE carrying the customer's chosen team member and branch. Judging the
     row between them books the wrong person at the wrong shop. The caller raises this
     transaction-local flag for exactly that window and runs the helper itself afterwards. */
  if coalesce(nullif(current_setting('app.v678_autoapprove_deferred', true), ''), 'off') = 'on' then
    return null;
  end if;

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

-- ---------------------------------------------------------------------------------------------
-- 2. The public submit files the request, writes the choice, and only then asks for a decision.
--
--    Everything before the inner call is v327 unchanged except that the business id is now
--    resolved unconditionally — the deferred auto-approve and the token rewrite need it even
--    when the customer expressed no preference. The "not found" raise stays inside the same
--    guard it was in, so a malformed or unknown slug still fails exactly where it failed before
--    (in the inner submit's own validation) for a caller that named no staff and no branch.
-- ---------------------------------------------------------------------------------------------
create or replace function public.internal_public_booking_submit(
  p_slug text, p_name text, p_email text, p_phone text, p_service uuid,
  p_party integer, p_preferred timestamptz, p_notes text, p_table_type uuid,
  p_consent boolean, p_token_hash text, p_idempotency_hash text,
  p_request_fingerprint text, p_authenticated_user uuid, p_staff uuid,
  p_branch uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_business_id uuid;
  v_result jsonb;
  v_request uuid;
  v_appointment uuid;
  v_auto_appointment uuid;
  v_final_status text;
  v_final_appointment uuid;
begin
  select business.id into v_business_id
    from public.businesses business
   where business.slug = p_slug
   limit 1;

  -- The staff/branch preference is validated BEFORE the shared submit path runs, so an
  -- invalid or foreign id is rejected outright rather than silently dropped.
  if (p_staff is not null or p_branch is not null) and v_business_id is null then
    raise exception 'invalid request' using errcode = '22023';
  end if;

  if p_staff is not null then
    if not exists (
      select 1 from public.businesses business
       where business.id = v_business_id
         and coalesce(business.booking_staff_choice, false)
    ) or not exists (
      select 1 from public.staff member
       where member.id = p_staff
         and member.business_id = v_business_id
         and coalesce(member.active, true)
         and coalesce(member.customer_bookable, true)
         and (p_branch is null or exists (
           select 1 from public.staff_branches assignment
            where assignment.business_id = v_business_id
              and assignment.staff_id = p_staff
              and assignment.branch_id = p_branch
         ))
    ) then
      raise exception 'invalid request' using errcode = '22023';
    end if;
    if p_service is not null
       and exists (
         select 1 from public.staff_services mapped
          where mapped.business_id = v_business_id and mapped.service_id = p_service
       )
       and not exists (
         select 1 from public.staff_services mapped
          where mapped.business_id = v_business_id
            and mapped.service_id = p_service
            and mapped.staff_id = p_staff
       ) then
      raise exception 'invalid request' using errcode = '22023';
    end if;
  end if;

  if p_branch is not null and not exists (
    select 1 from public.branches branch_row
     where branch_row.id = p_branch
       and branch_row.business_id = v_business_id
       and branch_row.active
  ) then
    raise exception 'invalid request' using errcode = '22023';
  end if;

  /* nestly_v678: hold the AFTER INSERT auto-approve for the length of the inner call. The row
     the inner submit writes does not yet carry staff_id/branch_id; deciding it there is what
     booked the wrong person. The flag is transaction-local and is lowered on the very next
     statement, so nothing else in this transaction — or any other — is affected. */
  perform set_config('app.v678_autoapprove_deferred', 'on', true);

  select public.internal_public_booking_submit(
    p_slug, p_name, p_email, p_phone, p_service, p_party, p_preferred,
    p_notes, p_table_type, p_consent, p_token_hash, p_idempotency_hash,
    p_request_fingerprint, p_authenticated_user
  ) into v_result;

  perform set_config('app.v678_autoapprove_deferred', 'off', true);

  /* A replay decided nothing new: the request already exists and has already been judged, and
     re-running the helper would ask it to re-decide its own answer. A conflict wrote nothing. */
  if v_result is null
     or coalesce((v_result->>'conflict')::boolean, false)
     or coalesce((v_result->>'replayed')::boolean, false) then
    return v_result;
  end if;

  v_request := nullif(v_result->>'request_id', '')::uuid;
  v_appointment := nullif(v_result->>'appointment_id', '')::uuid;

  if v_request is not null and (p_staff is not null or p_branch is not null) then
    update public.booking_requests
       set staff_id = case when p_staff is not null then p_staff else staff_id end,
           branch_id = case when p_branch is not null then p_branch else branch_id end
     where id = v_request
       and business_id = v_business_id;
  end if;
  if v_appointment is not null and (p_staff is not null or p_branch is not null) then
    -- The table/party path auto-confirms inside the inner submit and hands back a real
    -- appointment. The request is what the customer asked for, so the staff assignment is only
    -- applied when the slot is still unassigned. The branch was just created moments ago in this
    -- same transaction by the default-branch trigger and nothing else has had a chance to touch
    -- it yet, so the branch the customer asked for can simply overwrite it outright.
    if p_staff is not null then
      update public.appointments
         set staff_id = p_staff
       where id = v_appointment
         and business_id = v_business_id
         and staff_id is null;
    end if;
    if p_branch is not null then
      update public.appointments
         set branch_id = p_branch
       where id = v_appointment
         and business_id = v_business_id;
    end if;
  end if;

  /* nestly_v678: now — and only now — the row says what the customer asked for, so it can be
     judged. Wrapped exactly as the trigger wrapped it: auto-approve may decline for any reason,
     including an unexpected one, but it may never turn a filed booking into an error. */
  if v_request is not null then
    begin
      v_auto_appointment := app.v660_autoapprove_booking_request(v_request);
    exception when others then
      v_auto_appointment := null;
    end;

    /* Read the outcome back rather than asserting it (the v663 rule). Only a request that is
       genuinely confirmed with an appointment changes the answer; every other status is left
       exactly as the inner submit reported it. */
    select request_row.status, request_row.appointment_id
      into v_final_status, v_final_appointment
      from public.booking_requests request_row
     where request_row.id = v_request;

    if v_final_status = 'confirmed' and v_final_appointment is not null
       and v_final_appointment is distinct from v_appointment then
      v_result := v_result || jsonb_build_object(
        'status', 'confirmed',
        'appointment_id', v_final_appointment,
        'auto_approved', true);

      /* The idempotency token stores the answer the first submission was given. Left alone it
         would keep replaying 'pending' at a customer whose booking is confirmed. */
      update app.booking_management_tokens token
         set initial_response = v_result - 'replayed'
       where token.booking_request_id = v_request
         and token.business_id = v_business_id;
    end if;
  end if;

  return v_result;
end;
$$;

revoke all on function public.internal_public_booking_submit(
  text, text, text, text, uuid, integer, timestamptz, text, uuid, boolean, text, text, text, uuid, uuid, uuid
) from public;
revoke all on function public.internal_public_booking_submit(
  text, text, text, text, uuid, integer, timestamptz, text, uuid, boolean, text, text, text, uuid, uuid, uuid
) from anon;
revoke all on function public.internal_public_booking_submit(
  text, text, text, text, uuid, integer, timestamptz, text, uuid, boolean, text, text, text, uuid, uuid, uuid
) from authenticated;
grant execute on function public.internal_public_booking_submit(
  text, text, text, text, uuid, integer, timestamptz, text, uuid, boolean, text, text, text, uuid, uuid, uuid
) to service_role;

commit;
