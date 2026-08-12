-- Rollback-only acceptance for v290 — customer withdrawal of an un-actioned booking request.
--
-- Drives REAL tenant rows inside one transaction, impersonating the request's own customer via
-- the transaction-local JWT claims auth.uid() reads. Proves:
--   * the customer the reader RPC would show this request to can withdraw it (status ->
--     'cancelled');
--   * withdrawing again replays as success — a double-tap is one decision;
--   * a decided/converted request refuses with already_actioned;
--   * anyone else's session gets 42501, and anon has no EXECUTE at all.

begin;

do $suite$
declare
  v_link record;
  v_request uuid;
  v_result jsonb;
  v_errored boolean;
begin
  select link.business_id, link.client_id, link.auth_user_id into v_link
    from public.customer_links link
    join public.customer_identities identity
      on identity.id = link.identity_id and identity.status = 'active'
     and identity.auth_user_id = link.auth_user_id
   where link.state = 'verified' and link.unlinked_at is null
   limit 1;
  if v_link is null then
    raise exception 'v290: no verified customer link to test against';
  end if;

  insert into public.booking_requests
    (business_id, name, phone, party_size, preferred_at, status, customer_client_id)
  values
    (v_link.business_id, 'V290 Suite', '81800000', 2,
     now() + interval '3 days', 'pending', v_link.client_id)
  returning id into v_request;

  insert into app.booking_management_tokens
    (token_hash, idempotency_hash, request_fingerprint, business_id,
     booking_request_id, expires_at, initial_response,
     authenticated_user_id, customer_client_id)
  values
    (sha256('v290-suite-token'::bytea), sha256('v290-suite-idem'::bytea),
     sha256('v290-suite-fp'::bytea), v_link.business_id,
     v_request, now() + interval '30 days', '{}'::jsonb,
     v_link.auth_user_id, v_link.client_id);

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_link.auth_user_id, 'role', 'authenticated')::text, true);

  v_result := public.customer_withdraw_booking_request_v290(v_request);
  if v_result->>'status' <> 'cancelled' or (v_result->>'replayed')::boolean then
    raise exception 'v290: first withdrawal must cancel, got %', v_result;
  end if;
  if (select status from public.booking_requests where id = v_request) <> 'cancelled' then
    raise exception 'v290: the row must actually be cancelled';
  end if;

  v_result := public.customer_withdraw_booking_request_v290(v_request);
  if not (v_result->>'replayed')::boolean then
    raise exception 'v290: a second tap must replay as success, got %', v_result;
  end if;

  update public.booking_requests set status = 'confirmed' where id = v_request;
  v_errored := false;
  begin
    perform public.customer_withdraw_booking_request_v290(v_request);
  exception when others then
    v_errored := sqlerrm = 'already_actioned';
  end;
  if not v_errored then
    raise exception 'v290: a decided request must refuse with already_actioned';
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  v_errored := false;
  begin
    perform public.customer_withdraw_booking_request_v290(v_request);
  exception when others then
    v_errored := sqlstate = '42501';
  end;
  if not v_errored then
    raise exception 'v290: another session must be refused with 42501';
  end if;

  if has_function_privilege('anon', 'public.customer_withdraw_booking_request_v290(uuid)', 'EXECUTE') then
    raise exception 'v290: anon must not hold EXECUTE';
  end if;

  raise notice 'v290 acceptance: all assertions passed';
end $suite$;

rollback;
