-- Nestly v289 — the public reschedule respects the business's appointment-changes setting.
--
-- v286 gated the portal's Change button on business_customer_capabilities_v89.
-- appointment_changes_enabled — but only in the CLIENT. internal_public_booking_change (the
-- guest manage-token path) never read the flag, so a crafted request could still file a
-- reschedule at a business that had switched customer appointment changes off. The server is
-- the boundary; the button was only ever a courtesy.
--
-- CANCEL is deliberately NOT gated: a customer who cannot come must always be able to say so —
-- refusing the cancellation does not preserve the appointment, it manufactures a no-show and
-- strands the slot. The flag governs changes the business must ACCOMMODATE (a new time), not
-- the customer's right to withdraw.
--
-- The guard sits after the appointment row is resolved (the business id comes from the token's
-- own appointment, never from the caller) and before any write. A missing capability row means
-- the business never enabled changes — fail closed, matching the reader
-- (customer_get_business_actions_v89 coalesces the same flag to false). The refusal is the
-- same 22023 'invalid request' every other precondition uses: the manage token is not an
-- oracle for a business's settings.
--
-- Everything else — token validation, fingerprint replay, the pending-conflict rule,
-- auto-approve-cancel — is byte-identical to the deployed definition.

begin;

CREATE OR REPLACE FUNCTION public.internal_public_booking_change(p_token_hash text, p_submission_id uuid, p_request_fingerprint text, p_kind text, p_proposed timestamp with time zone DEFAULT NULL::timestamp with time zone, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_token app.booking_management_tokens%rowtype;
  v_appt record;
  v_auto boolean;
  v_status text := 'pending';
  v_request uuid;
  v_prior app.booking_management_change_submissions%rowtype;
  v_result jsonb;
begin
  if p_token_hash !~ '^[0-9a-f]{64}$'
     or p_submission_id is null
     or p_request_fingerprint !~ '^[0-9a-f]{64}$'
     or p_kind not in ('cancel', 'reschedule')
     or char_length(coalesce(p_note, '')) > 500
     or (p_kind = 'cancel' and p_proposed is not null)
     or (p_kind = 'reschedule' and p_proposed is null) then
    raise exception using errcode = '22023', message = 'invalid request';
  end if;

  select * into v_token
    from app.booking_management_tokens t
   where t.token_hash = decode(p_token_hash, 'hex')
     and t.revoked_at is null and t.expires_at > clock_timestamp()
   for update;
  if not found then
    raise exception using errcode = '22023', message = 'invalid request';
  end if;

  select * into v_prior
    from app.booking_management_change_submissions s
   where s.management_token_id = v_token.id and s.submission_id = p_submission_id;
  if found then
    if v_prior.request_fingerprint <> decode(p_request_fingerprint, 'hex') then
      return jsonb_build_object('conflict', true);
    end if;
    return v_prior.result || jsonb_build_object('replayed', true);
  end if;

  if p_kind = 'reschedule' and
     (p_proposed < clock_timestamp() + interval '15 minutes'
      or p_proposed > clock_timestamp() + interval '365 days') then
    raise exception using errcode = '22023', message = 'invalid request';
  end if;

  select a.id, a.business_id, a.client_id, a.starts_at, a.ends_at, a.status,
         b.auto_approve_changes
    into v_appt
    from public.appointments a
    join public.businesses b on b.id = a.business_id
   where a.id = v_token.appointment_id and a.business_id = v_token.business_id
     and a.status = 'booked' and a.starts_at > clock_timestamp()
   for update of a;
  if not found then
    raise exception using errcode = '22023', message = 'invalid request';
  end if;

  -- v289: a reschedule is a change the business can switch off; the server is the boundary,
  -- the portal button only a courtesy. Cancel is never gated — refusing a cancellation does
  -- not keep the appointment, it manufactures a no-show. Missing capability row = fail closed,
  -- matching customer_get_business_actions_v89's coalesce(...,false) on the same flag.
  if p_kind = 'reschedule' and not coalesce((
    select cap.appointment_changes_enabled
      from public.business_customer_capabilities_v89 cap
     where cap.business_id = v_appt.business_id), false) then
    raise exception using errcode = '22023', message = 'invalid request';
  end if;

  select cr.id, cr.status into v_request, v_status
    from public.change_requests cr
   where cr.appointment_id = v_appt.id and cr.status = 'pending'
   order by cr.created_at desc
   limit 1;
  if found then
    return jsonb_build_object('conflict', true);
  end if;

  insert into public.change_requests
    (business_id, appointment_id, kind, proposed_at, phone, note, status)
  values
    (v_appt.business_id, v_appt.id, p_kind, p_proposed, null,
     nullif(btrim(p_note), ''), 'pending')
  returning id into v_request;

  v_auto := coalesce(v_appt.auto_approve_changes, false);
  -- Public reschedules always remain pending until the canonical availability,
  -- hours, capacity, staff and overlap engine can approve them.
  if v_auto and p_kind = 'cancel' then
    update public.appointments set status = 'cancelled'
     where id = v_appt.id and business_id = v_appt.business_id and status = 'booked';
    update public.change_requests
       set status = 'approved', decided_at = clock_timestamp()
     where id = v_request;
    v_status := 'approved';
  end if;

  update app.booking_management_tokens set last_used_at = clock_timestamp()
   where id = v_token.id;
  v_result := jsonb_build_object('id', v_request, 'status', v_status);
  insert into app.booking_management_change_submissions
    (management_token_id, submission_id, request_fingerprint, result)
  values
    (v_token.id, p_submission_id, decode(p_request_fingerprint, 'hex'), v_result);
  return v_result || jsonb_build_object('replayed', false);
end;
$function$;

-- CREATE OR REPLACE preserves the deployed grants; restated so a replay from an empty database
-- lands identically. This internal function is reachable only from the service-role edge
-- gateway — no API role may execute it.
revoke all on function public.internal_public_booking_change(text, uuid, text, text, timestamptz, text) from public, anon, authenticated;
grant execute on function public.internal_public_booking_change(text, uuid, text, text, timestamptz, text) to service_role;

commit;
