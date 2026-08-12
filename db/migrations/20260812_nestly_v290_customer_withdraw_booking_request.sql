-- Nestly v290 — a signed-in customer can withdraw a booking request nobody has actioned yet.
--
-- The audit's one remaining feature gap on the Bookings loop: a customer could cancel a
-- confirmed APPOINTMENT (customer_request_appointment_action) and a guest could cancel via the
-- manage-token link, but a signed-in customer's REQUEST — still sitting in the business's inbox
-- as new/pending/waitlisted — had no customer-side exit. The business would decide over a
-- request the customer no longer wanted.
--
-- Identity is resolved EXACTLY as customer_get_booking_requests resolves it — the verified
-- customer link on the request's business AND a booking management token binding this request
-- to this authenticated user — so a customer can withdraw precisely the rows that page shows
-- them, nothing more. The row is locked; only an un-actioned request (no appointment yet,
-- status new/pending/waitlisted, not expired) can move to 'cancelled', the status the model
-- already has for a request that will not proceed. Withdrawing an already-cancelled own request
-- replays as success (a double-tap is a decision made once); a decided or converted request
-- refuses with 'already_actioned' so the customer is told to use the appointment flow instead.

begin;

create or replace function public.customer_withdraw_booking_request_v290(p_request uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $fn$
declare
  v_actor uuid := auth.uid();
  v_request public.booking_requests%rowtype;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if p_request is null then
    raise exception 'invalid booking request' using errcode = '22023';
  end if;

  select request.* into v_request
    from public.customer_identities identity
    join public.customer_links link
      on link.identity_id = identity.id
     and link.auth_user_id = identity.auth_user_id
     and link.state = 'verified'
    join public.booking_requests request
      on request.business_id = link.business_id
     and request.customer_client_id = link.client_id
    join app.booking_management_tokens token
      on token.business_id = request.business_id
     and token.booking_request_id = request.id
     and token.customer_client_id = request.customer_client_id
     and token.authenticated_user_id = v_actor
   where identity.auth_user_id = v_actor
     and identity.status = 'active'
     and request.id = p_request
   for update of request;
  if not found then
    raise exception 'booking request not found' using errcode = '42501';
  end if;

  if v_request.status = 'cancelled' then
    return jsonb_build_object('status','cancelled','replayed',true);
  end if;
  if v_request.appointment_id is not null
     or v_request.status not in ('new','pending','waitlisted') then
    raise exception 'already_actioned' using errcode = '22023';
  end if;

  update public.booking_requests
     set status = 'cancelled'
   where id = v_request.id and business_id = v_request.business_id;

  return jsonb_build_object('status','cancelled','replayed',false);
end;
$fn$;

revoke all on function public.customer_withdraw_booking_request_v290(uuid) from public, anon;
grant execute on function public.customer_withdraw_booking_request_v290(uuid) to authenticated, service_role;

commit;
