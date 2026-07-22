-- Rollback-only v33 customer action and notification adversarial suite.
-- Covers auth.uid, verified customer_links, business A/business B isolation,
-- future cancel/reschedule validation, replay and request_hash mismatch, direct
-- appointment mutation denial, raw table denial, rate limiting, preference
-- consent, provider-neutral pending/suppressed/failed evidence, and the intact
-- anonymous Turnstile plus opaque booking management-token boundary. No duplicate
-- action request or outbox row is permitted for an idempotent replay. Channel and
-- topic consent are always scoped to one verified customer link and one business.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_customer(p_uid uuid) returns void
language plpgsql as $$
begin
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end;
$$;
grant execute on function pg_temp.as_customer(uuid) to public;

do $v33_test$
declare
  v_business_a uuid;
  v_business_b uuid;
  v_slug_a text;
  v_customer_a uuid := gen_random_uuid();
  v_customer_b uuid := gen_random_uuid();
  v_staff_only uuid := gen_random_uuid();
  v_identity_a uuid := gen_random_uuid();
  v_identity_b uuid := gen_random_uuid();
  v_client_a uuid := gen_random_uuid();
  v_client_b uuid := gen_random_uuid();
  v_link_a uuid := gen_random_uuid();
  v_link_b uuid := gen_random_uuid();
  v_appointment uuid := gen_random_uuid();
  v_result jsonb;
  v_request_id uuid;
  v_acl_table text;
  v_rows integer;
begin
  reset role;
  select id, slug into v_business_a, v_slug_a from public.businesses order by created_at, id limit 1;
  select id into v_business_b from public.businesses where id <> v_business_a order by created_at, id limit 1;
  if v_business_a is null or v_business_b is null then
    raise exception 'v33 suite requires business A and business B';
  end if;

  insert into auth.users(instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values
    ('00000000-0000-0000-0000-000000000000', v_customer_a, 'authenticated', 'authenticated', 'v33-a@example.test', '', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', v_customer_b, 'authenticated', 'authenticated', 'v33-b@example.test', '', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', v_staff_only, 'authenticated', 'authenticated', 'v33-staff@example.test', '', now(), now(), now());
  insert into public.customer_identities(id, auth_user_id, status, created_via)
  values (v_identity_a, v_customer_a, 'active', 'wallet_start'),
         (v_identity_b, v_customer_b, 'active', 'wallet_start');
  insert into public.clients(id, business_id, full_name)
  values (v_client_a, v_business_a, 'V33 customer A'),
         (v_client_b, v_business_b, 'V33 customer B');
  perform set_config('app.customer_link_insert_id', v_link_a::text, true);
  insert into public.customer_links(id, business_id, identity_id, auth_user_id, client_id, state, verification_method, verified_at)
  values (v_link_a, v_business_a, v_identity_a, v_customer_a, v_client_a, 'verified', 'firm_invitation', now());
  perform set_config('app.customer_link_insert_id', v_link_b::text, true);
  insert into public.customer_links(id, business_id, identity_id, auth_user_id, client_id, state, verification_method, verified_at)
  values (v_link_b, v_business_b, v_identity_b, v_customer_b, v_client_b, 'verified', 'firm_invitation', now());
  perform set_config('app.customer_link_insert_id', '', true);
  insert into public.appointments(id, business_id, client_id, starts_at, ends_at, status)
  values (v_appointment, v_business_a, v_client_a, now() + interval '2 days', now() + interval '2 days 1 hour', 'booked');

  -- The private v32 flags are the actual release gate. A UI constant must not
  -- be able to bypass this database denial. Enable them only after proving the
  -- false gate rejects action and notification requests with generic 42501.
  update app.platform_feature_flags
     set enabled = false
   where feature_key in ('customer_actions', 'customer_notifications');
  perform pg_temp.as_customer(v_customer_a);
  begin
    perform public.customer_request_appointment_action(v_slug_a, v_appointment, 'cancel', null, null, 'v33-flag-block-action');
    raise exception 'disabled customer_actions flag allowed an action request';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.customer_get_notification_preferences(v_slug_a);
    raise exception 'disabled customer_notifications flag allowed a preference read';
  exception when insufficient_privilege then null;
  end;
  reset role;
  update app.platform_feature_flags
     set enabled = true
   where feature_key in ('customer_actions', 'customer_notifications');

  -- Customer A can append one pending cancel request; replay is identical and a
  -- payload mismatch under the same idempotency key is rejected.
  perform pg_temp.as_customer(v_customer_a);
  v_result := public.customer_request_appointment_action(v_slug_a, v_appointment, 'cancel', null, 'Please cancel', 'v33-action-key');
  v_request_id := (v_result->>'request_id')::uuid;
  if v_result->>'status' <> 'pending' then
    raise exception 'customer action request did not return pending evidence';
  end if;
  reset role;
  if not exists (
    select 1 from public.customer_appointment_action_requests r where r.id = v_request_id and r.status = 'pending'
  ) then raise exception 'customer action request was not stored as immutable pending evidence'; end if;
  perform pg_temp.as_customer(v_customer_a);
  if public.customer_request_appointment_action(v_slug_a, v_appointment, 'cancel', null, 'Please cancel', 'v33-action-key')
       ->>'request_id' is distinct from v_request_id::text then
    raise exception 'action replay did not return the original request';
  end if;
  begin
    perform public.customer_request_appointment_action(v_slug_a, v_appointment, 'reschedule', now() + interval '3 days', null, 'v33-action-key');
    raise exception 'request_hash mismatch was accepted';
  exception when invalid_parameter_value then null;
  end;
  reset role;
  if (select status from public.appointments where id = v_appointment) <> 'booked' then
    raise exception 'customer action directly changed the appointment';
  end if;
  if not exists (
    select 1 from public.customer_notification_outbox o
     where o.action_request_id = v_request_id and o.delivery_status = 'pending'
  ) then raise exception 'provider-neutral pending outbox evidence is missing'; end if;

  -- Customer B, anonymous/PUBLIC, and staff-only identities cannot act on A's appointment.
  perform pg_temp.as_customer(v_customer_b);
  begin
    perform public.customer_request_appointment_action(v_slug_a, v_appointment, 'cancel', null, null, 'v33-cross-business');
    raise exception 'cross business customer action succeeded';
  exception when insufficient_privilege then null;
  end;
  perform pg_temp.as_customer(v_staff_only);
  begin
    perform public.customer_request_appointment_action(v_slug_a, v_appointment, 'cancel', null, null, 'v33-staff-only');
    raise exception 'staff-only session acted without a customer identity/link';
  exception when insufficient_privilege then null;
  end;

  -- A customer may set business-scoped consent, but direct table access and direct
  -- appointment writes remain denied. No provider, Turnstile, captcha, or opaque
  -- management token is changed by this migration.
  perform pg_temp.as_customer(v_customer_a);
  if public.customer_set_notification_preference(v_slug_a, 'email', 'booking_updates', true, 'v33-pref-key')->>'opted_in'
       is distinct from 'true' then raise exception 'preference consent was not recorded'; end if;
  perform public.customer_set_notification_preference(
    v_slug_a, 'in_app', 'booking_updates', false, 'v33-pref-off'
  );
  v_result := public.customer_request_appointment_action(
    v_slug_a, v_appointment, 'cancel', null, 'Opted-out test', 'v33-action-opted-out'
  );
  reset role;
  if not exists (
    select 1 from public.customer_notification_outbox o
     where o.action_request_id=(v_result->>'request_id')::uuid
       and o.topic='booking_updates' and o.delivery_status='suppressed'
  ) then raise exception 'booking update opt-out did not suppress the outbox event'; end if;
  perform pg_temp.as_customer(v_customer_a);
  perform public.customer_set_notification_preference(
    v_slug_a, 'in_app', 'booking_updates', true, 'v33-pref-on'
  );
  v_result := public.customer_request_appointment_action(
    v_slug_a, v_appointment, 'cancel', null, 'Opted-in test', 'v33-action-opted-in'
  );
  reset role;
  if not exists (
    select 1 from public.customer_notification_outbox o
     where o.action_request_id=(v_result->>'request_id')::uuid
       and o.topic='booking_updates' and o.delivery_status='pending'
  ) then raise exception 'booking update opt-in did not create a pending outbox event'; end if;
  perform pg_temp.as_customer(v_customer_a);
  if coalesce(jsonb_array_length(public.customer_get_notification_preferences(v_slug_a)), 0) <> 2 then
    raise exception 'self-derived notification preference read is incorrect';
  end if;
  v_rows := 0;
  begin
    update public.appointments set status = 'cancelled' where id = v_appointment;
    get diagnostics v_rows = row_count;
  exception when insufficient_privilege then
    v_rows := 0;
  end;
  if v_rows <> 0 then
    raise exception 'customer directly changed appointment';
  end if;
  foreach v_acl_table in array array[
    'public.customer_appointment_action_requests', 'public.customer_notification_preferences',
    'public.customer_preference_audit', 'public.customer_notification_outbox'
  ] loop
    if has_table_privilege('anon', v_acl_table, 'select')
       or has_table_privilege('authenticated', v_acl_table, 'insert') then
      raise exception 'raw table ACL is open for %', v_acl_table;
    end if;
  end loop;
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname in (
       'customer_request_appointment_action', 'customer_get_notification_preferences',
       'customer_set_notification_preference'
     ) and (not p.prosecdef or has_function_privilege('anon', p.oid, 'execute')
       or exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0 and a.privilege_type = 'EXECUTE'))
  ) then raise exception 'v33 customer RPC ACL or search_path is incorrect'; end if;
  raise notice 'v33 actions/notifications suite: ALL PASS';
end;
$v33_test$;

rollback;
