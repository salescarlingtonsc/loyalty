-- Rollback-only acceptance for V282 — communications foundation.
--
-- Runs against the REAL production tenants inside ONE transaction and ends in a deliberate
-- `raise exception 'V282_RESULT ALL PASS -- %'`, following the V280 convention: the raise both
-- PRINTS the values behind every assertion (a bare `assert` that passes prints nothing, so a green
-- run would be indistinguishable from a run that asserted nothing) and aborts the transaction, so
-- the suite rolls itself back even when fed to a single-statement executor that never reaches the
-- trailing `rollback;`.
--
-- What this proves, in order:
--   1  THE SWEEP EXPIRES what has lapsed: a 'stored' bottle past its window becomes 'expired' and
--      gains exactly one 'expire' event.
--   2  THE SWEEP REMINDS ahead of the window, once: a bottle inside the reminder horizon produces
--      exactly one 'v282_bottle_expiry' inbox row for the verified customer, with the right topic,
--      title, body and deadline.
--   3  IDEMPOTENCY, the property the whole thing turns on: a SECOND sweep in the same transaction
--      reports 0 expired and 0 reminded and writes no further row of any kind.
--   4  THE HORIZON IS REAL: a bottle outside the reminder window is untouched.
--   5  THE V263 SWITCH IS HONOURED: with rewards_and_points/in_app withdrawn, an otherwise
--      identical bottle produces NO inbox row - and still no error.
--   6  PUSH ELIGIBILITY: the new (source_kind, topic) pair is eligible; a wrong pair is not; and
--      neither anon nor authenticated holds EXECUTE on the dispatcher tick.
--   7  CONSENT HISTORY IS OWN-ROWS-ONLY: the caller sees their own v263 and v92 evidence, never
--      another customer's, and an unauthenticated call is refused.
--   8  PARTNER OBLIGATIONS: every RPC refuses a fully authorised business owner with 42501; a super
--      admin can register a partner, record a suppression instruction (idempotently), and
--      acknowledge it exactly once; disclosures are append-only; a suppression's substance cannot
--      be edited.
--   9  BAR SETTINGS: the reminder window is owner-writable, readable, and bounded.
--
-- Client behaviour is proven in tests/customer-modules/v282-comms-foundation.test.mjs.

begin;

create or replace function pg_temp.as_v282_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  reset role;
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', p_role)::text, true);
end
$$;
grant execute on function pg_temp.as_v282_user(uuid, text) to public;

do $v282$
declare
  v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_industry_before text;
  v_modules_before text[];
  v_owner uuid;
  -- CORRECTION 2026-08-12 (first run against prod): section 8 needs a TENANT actor that is
  -- distinct from the fixture tenant's owner. The Cubbly fixture's approved owner
  -- (f73a9423-…) is ALSO a row in public.super_admins, and app.is_super_admin() is purely
  -- `auth.uid() in super_admins` — so `platform_list_partner_obligations_v282` correctly
  -- ALLOWED it and the "must refuse a business owner" assertion failed. The bug was in the
  -- suite, not the migration: it conflated "an owner" with "an actor holding no platform
  -- rights". v_owner stays the fixture tenant's owner (section 9 needs is_salon_owner on
  -- v_biz); v_tenant is a separately chosen owner proven NOT to be a super admin.
  v_tenant uuid;
  v_super uuid;
  v_link public.customer_links%rowtype;
  v_other_identity uuid;
  v_other_auth uuid;
  v_seq integer;
  v_lapsed uuid;
  v_due uuid;
  v_far uuid;
  v_muted uuid;
  v_sweep jsonb;
  v_again jsonb;
  v_status text;
  v_count integer;
  v_before integer;
  v_after integer;
  v_event public.customer_in_app_inbox_events%rowtype;
  v_partner uuid;
  v_suppression uuid;
  v_payload jsonb;
  v_rpc text;
  v_raised boolean;
  v_log text := '';
begin
  -- -----------------------------------------------------------------------
  -- Fixture. Deterministic, and refuses to run rather than skip: a suite that
  -- tested nothing must not look green (the V280 lesson).
  -- -----------------------------------------------------------------------
  select business.industry into v_industry_before
    from public.businesses business where business.id = v_biz;
  if v_industry_before is null then
    raise exception 'V282_RESULT SKIPPED -- fixture tenant % not found', v_biz;
  end if;

  select staff_row.user_id into v_owner
    from public.staff staff_row
   where staff_row.business_id = v_biz and staff_row.role = 'owner'
     and staff_row.active and staff_row.access_state = 'approved'
   order by staff_row.user_id
   limit 1;
  if v_owner is null then
    raise exception 'V282_RESULT SKIPPED -- fixture needs an approved owner';
  end if;

  -- CORRECTION 2026-08-12: see the v_tenant declaration. An approved, active owner of ANY
  -- tenant that holds no platform rights, so section 8's 42501 assertions test the guard
  -- rather than the actor. Verified in prod against Hougang ABC's owner
  -- (c1389083-92e2-41ed-be7e-a2b2c31dac9c), which this predicate also admits.
  select staff_row.user_id into v_tenant
    from public.staff staff_row
   where staff_row.role = 'owner' and staff_row.active
     and staff_row.access_state = 'approved'
     and not exists (select 1 from public.super_admins admin
                      where admin.user_id = staff_row.user_id)
   order by staff_row.user_id
   limit 1;
  if v_tenant is null then
    raise exception 'V282_RESULT SKIPPED -- fixture needs an owner who is not a super admin';
  end if;

  select * into v_link from public.customer_links link
   where link.business_id = v_biz and link.state = 'verified' and link.unlinked_at is null
   order by link.created_at, link.id
   limit 1;
  if v_link.id is null then
    raise exception 'V282_RESULT SKIPPED -- fixture needs a verified customer link';
  end if;

  select identity.id, identity.auth_user_id into v_other_identity, v_other_auth
    from public.customer_identities identity
   where identity.id <> v_link.identity_id and identity.status = 'active'
   order by identity.id
   limit 1;
  if v_other_identity is null then
    raise exception 'V282_RESULT SKIPPED -- fixture needs a second customer identity';
  end if;

  select admin.user_id into v_super from public.super_admins admin
   order by admin.user_id limit 1;
  if v_super is null then
    raise exception 'V282_RESULT SKIPPED -- fixture needs a super admin';
  end if;
  -- CORRECTION 2026-08-12: assert the separation the suite now depends on, so this can never
  -- silently regress into the vacuous state described above.
  if exists (select 1 from public.super_admins admin where admin.user_id = v_tenant) then
    raise exception 'V282_RESULT SKIPPED -- the tenant actor must not hold platform rights';
  end if;

  v_log := v_log || format('fixture biz=%s owner=%s tenant=%s super=%s identity=%s; ',
    v_biz, v_owner, v_tenant, v_super, v_link.identity_id);

  select coalesce(max(bottle.serial_seq), 0) into v_seq
    from public.bar_bottles bottle where bottle.business_id = v_biz;

  insert into public.bar_bottles (business_id, client_id, serial_year, serial_seq,
    label, status, expires_at)
  values (v_biz, v_link.client_id, 2999, v_seq + 1, 'ZZ v282 lapsed', 'stored', now() - interval '1 day')
  returning id into v_lapsed;
  insert into public.bar_bottles (business_id, client_id, serial_year, serial_seq,
    label, status, expires_at)
  values (v_biz, v_link.client_id, 2999, v_seq + 2, 'ZZ v282 due', 'stored', now() + interval '3 days')
  returning id into v_due;
  insert into public.bar_bottles (business_id, client_id, serial_year, serial_seq,
    label, status, expires_at)
  values (v_biz, v_link.client_id, 2999, v_seq + 3, 'ZZ v282 far', 'stored', now() + interval '60 days')
  returning id into v_far;

  -- -----------------------------------------------------------------------
  -- 1 + 2. One sweep expires the lapsed bottle and reminds on the due one.
  -- -----------------------------------------------------------------------
  v_sweep := app.v282_sweep_bottle_expiry();

  select bottle.status into v_status from public.bar_bottles bottle where bottle.id = v_lapsed;
  assert v_status = 'expired', 'a lapsed in-storage bottle must be expired by the sweep';
  select count(*)::integer into v_count from public.bar_bottle_events event
   where event.bottle_id = v_lapsed and event.kind = 'expire';
  assert v_count = 1, 'exactly one expire event per bottle';
  v_log := v_log || format('1 expire status=%s events=%s; ', v_status, v_count);

  select bottle.status into v_status from public.bar_bottles bottle where bottle.id = v_due;
  assert v_status = 'stored', 'a bottle inside its window must not be expired';

  select count(*)::integer into v_count
    from public.customer_in_app_inbox_events event
   where event.identity_id = v_link.identity_id
     and event.source_kind = 'v282_bottle_expiry';
  assert v_count = 1, format('exactly one reminder must be enqueued, found %s', v_count);
  select * into v_event from public.customer_in_app_inbox_events event
   where event.identity_id = v_link.identity_id and event.source_kind = 'v282_bottle_expiry';
  assert v_event.topic = 'value_expiry', 'the reminder must carry the value_expiry topic';
  assert v_event.title = 'Your bottle expires soon', 'the reminder title must be in the vocabulary';
  assert v_event.body = 'Open this business wallet before the bottle kept for you is collected.',
    'the reminder body must be in the vocabulary';
  assert v_event.deadline_at is not null and v_event.deadline_at > now(),
    'the reminder deadline is the bottle window and must still be open';
  v_log := v_log || format('2 remind topic=%s deadline=%s; ', v_event.topic, v_event.deadline_at);

  -- 4. The far bottle is outside the horizon and was not touched at all.
  select count(*)::integer into v_count from public.bar_bottle_events event
   where event.bottle_id = v_far;
  assert v_count = 0, 'a bottle outside the reminder horizon must be untouched';
  v_log := v_log || '4 horizon=PASS; ';

  -- -----------------------------------------------------------------------
  -- 3. Idempotency. The second sweep must write nothing at all.
  -- -----------------------------------------------------------------------
  select count(*)::integer into v_before from public.customer_in_app_inbox_events event
   where event.source_kind = 'v282_bottle_expiry';
  v_again := app.v282_sweep_bottle_expiry();
  assert (v_again->>'expired')::integer = 0,
    format('a second sweep must expire nothing, reported %s', v_again->>'expired');
  assert (v_again->>'reminded')::integer = 0,
    format('a second sweep must remind nobody, reported %s', v_again->>'reminded');
  select count(*)::integer into v_after from public.customer_in_app_inbox_events event
   where event.source_kind = 'v282_bottle_expiry';
  assert v_before = v_after, 'a second sweep must not add an inbox row';
  select count(*)::integer into v_count from public.bar_bottle_events event
   where event.bottle_id in (v_lapsed, v_due);
  assert v_count = 2, format('one expire and one reminder event in total, found %s', v_count);
  v_log := v_log || format('3 idempotent second=%s rows=%s; ', v_again, v_count);

  -- -----------------------------------------------------------------------
  -- 5. An explicit V263 withdrawal suppresses the reminder.
  -- -----------------------------------------------------------------------
  insert into public.customer_communication_preferences_v263 (
    identity_id, auth_user_id, category, channel, enabled
  ) values (
    v_link.identity_id, v_link.auth_user_id, 'rewards_and_points', 'in_app', false
  )
  on conflict (identity_id, category, channel) do update set enabled = false;

  insert into public.bar_bottles (business_id, client_id, serial_year, serial_seq,
    label, status, expires_at)
  values (v_biz, v_link.client_id, 2999, v_seq + 4, 'ZZ v282 muted', 'stored', now() + interval '2 days')
  returning id into v_muted;

  v_sweep := app.v282_sweep_bottle_expiry();
  assert (v_sweep->>'reminded')::integer = 0,
    format('a withdrawn in-app switch must suppress the reminder, reported %s', v_sweep->>'reminded');
  select count(*)::integer into v_count from public.bar_bottle_events event
   where event.bottle_id = v_muted;
  assert v_count = 0, 'a suppressed reminder must not write a bottle event either';
  v_log := v_log || '5 withdrawal-honoured=PASS; ';

  delete from public.customer_communication_preferences_v263
   where identity_id = v_link.identity_id
     and category = 'rewards_and_points' and channel = 'in_app';

  -- -----------------------------------------------------------------------
  -- 6. Push eligibility and the dispatcher tick's ACL.
  -- -----------------------------------------------------------------------
  assert app.customer_push_event_eligible_v95('v282_bottle_expiry', 'value_expiry'),
    'the bottle expiry reminder must be push-eligible';
  assert not app.customer_push_event_eligible_v95('v282_bottle_expiry', 'promotion_alerts'),
    'the pair, not the kind, is what makes an event eligible';
  assert app.customer_push_event_eligible_v95('v122_promotion_new', 'promotion_alerts'),
    'the eight pre-existing pairs must survive the restatement';
  assert not has_function_privilege('anon', 'app.v282_run_customer_push_dispatch()', 'execute'),
    'anon must not be able to tick the dispatcher';
  assert not has_function_privilege('authenticated', 'app.v282_run_customer_push_dispatch()', 'execute'),
    'a signed-in customer must not be able to tick the dispatcher';
  assert not has_function_privilege('authenticated', 'app.v282_sweep_bottle_expiry(timestamptz)', 'execute'),
    'a signed-in customer must not be able to run the sweep';
  v_log := v_log || '6 push-eligibility+acl=PASS; ';

  -- -----------------------------------------------------------------------
  -- 7. Consent history is own-rows-only.
  -- -----------------------------------------------------------------------
  insert into public.customer_communication_preference_audit_v263 (
    identity_id, auth_user_id, scope, category, channel, enabled, source, request_hash
  ) values (
    v_link.identity_id, v_link.auth_user_id, 'single', 'business_offers', 'email', false,
    'communications_screen', repeat('a', 64)
  );
  insert into public.customer_communication_preference_audit_v263 (
    identity_id, auth_user_id, scope, category, channel, enabled, source, request_hash
  ) values (
    v_other_identity, v_other_auth, 'all', null, null, true,
    'communications_screen', repeat('b', 64)
  );

  -- The expected size is COMPUTED from the caller's own rows rather than assumed, because the
  -- fixture tenant is a real one and its customer may already carry evidence from earlier work.
  -- An assertion that only checked "the other customer's row is absent" would pass vacuously the
  -- day the caller happens to have a row of the same shape.
  select least(
    (select count(*) from public.customer_communication_preference_audit_v263 audit
      where audit.identity_id = v_link.identity_id)
    + (select count(*) from public.customer_platform_marketing_consent_events consent
        where consent.identity_id = v_link.identity_id),
    100)::integer
   into v_count;

  perform pg_temp.as_v282_user(v_link.auth_user_id);
  v_payload := public.customer_get_consent_history_v282();
  reset role;
  assert jsonb_array_length(v_payload->'entries') = v_count,
    format('the caller must see exactly their own %s rows, saw %s',
      v_count, jsonb_array_length(v_payload->'entries'));
  assert exists (
    select 1 from jsonb_array_elements(v_payload->'entries') entry
     where entry->>'entry_kind' = 'marketing_channel'
       and entry->>'channel' = 'email'
       and (entry->>'enabled')::boolean is false
  ), 'the caller''s own per-channel withdrawal must appear';
  -- And rows really were excluded: the other identity's all-channel grant exists in the table and
  -- is not in the payload, which is what makes the exact-count assertion above meaningful rather
  -- than a tautology about an empty table.
  select count(*)::integer into v_before
    from public.customer_communication_preference_audit_v263 audit
   where audit.identity_id = v_other_identity;
  assert v_before > 0, 'the isolation fixture row must exist';
  assert jsonb_array_length(v_payload->'entries') < v_before + v_count,
    'another customer''s consent evidence must never appear';
  v_log := v_log || format('7 history entries=%s; ', jsonb_array_length(v_payload->'entries'));

  v_raised := false;
  begin
    perform pg_temp.as_v282_user(null, 'anon');
    perform public.customer_get_consent_history_v282();
  exception when others then
    v_raised := true;
  end;
  reset role;
  assert v_raised, 'an unauthenticated consent-history call must be refused';
  v_log := v_log || '7 anon-refused=PASS; ';

  -- -----------------------------------------------------------------------
  -- 8. Partner obligations.
  -- -----------------------------------------------------------------------
  foreach v_rpc in array array[
    'select public.platform_list_partner_obligations_v282(10)',
    'select public.platform_save_partner_v282(null, ''ZZ v282'', ''testing'', ''prospective'')',
    'select public.platform_record_partner_suppression_v282(''00000000-0000-0000-0000-000000000000''::uuid, ''customer_request'', ''k'', null)',
    'select public.platform_acknowledge_partner_suppression_v282(''00000000-0000-0000-0000-000000000000''::uuid, ''ref'')'
  ] loop
    v_raised := false;
    -- CORRECTION 2026-08-12: was v_owner, which is a super admin on the fixture tenant.
    perform pg_temp.as_v282_user(v_tenant);
    begin
      execute v_rpc;
    exception when insufficient_privilege then
      v_raised := true;
    when others then
      reset role;
      raise exception 'V282: % raised % instead of 42501 for a business owner', v_rpc, sqlstate;
    end;
    reset role;
    assert v_raised, format('%s must refuse a business owner', v_rpc);
  end loop;
  v_log := v_log || '8 tenant-denied=PASS; ';

  perform pg_temp.as_v282_user(v_super);
  v_payload := public.platform_save_partner_v282(null, 'ZZ v282 partner',
    'Suppression evidence acceptance fixture.', 'active');
  v_partner := (v_payload->>'partner_id')::uuid;
  assert v_partner is not null, 'a super admin must be able to register a partner';

  v_payload := public.platform_record_partner_suppression_v282(
    v_partner, 'consent_withdrawn', 'v282-suite-key', v_link.identity_id);
  assert v_payload->>'status' = 'ok', 'the first suppression instruction must be recorded';
  v_suppression := (v_payload->>'suppression_id')::uuid;
  v_payload := public.platform_record_partner_suppression_v282(
    v_partner, 'consent_withdrawn', 'v282-suite-key', v_link.identity_id);
  assert v_payload->>'status' = 'duplicate_ignored',
    'a replayed suppression instruction must not be recorded twice';
  assert (v_payload->>'suppression_id')::uuid = v_suppression,
    'the replay must return the original instruction';

  v_payload := public.platform_acknowledge_partner_suppression_v282(v_suppression, 'PARTNER-ACK-1');
  assert v_payload->>'status' = 'ok', 'an acknowledgement must be recordable';
  v_raised := false;
  begin
    perform public.platform_acknowledge_partner_suppression_v282(v_suppression, 'PARTNER-ACK-2');
  exception when others then
    v_raised := true;
  end;
  assert v_raised, 'an acknowledgement must be recordable exactly once';

  v_payload := public.platform_list_partner_obligations_v282(50);
  reset role;
  assert exists (
    select 1 from jsonb_array_elements(v_payload->'partners') entry
     where (entry->>'id')::uuid = v_partner
       and (entry->>'open_suppressions')::integer = 0
  ), 'the console read must show the partner with its acknowledged instruction closed';
  assert exists (
    select 1 from jsonb_array_elements(v_payload->'suppressions') entry
     where (entry->>'id')::uuid = v_suppression
       and entry->>'acknowledged_at' is not null
       and entry->>'scope' = 'one_customer'
  ), 'the console read must show the acknowledgement';
  v_log := v_log || format('8 partner=%s suppression=%s; ', v_partner, v_suppression);

  v_raised := false;
  begin
    update public.partner_suppressions_v282 set reason = 'platform_decision' where id = v_suppression;
  exception when others then
    v_raised := true;
  end;
  assert v_raised, 'the substance of a suppression instruction must be immutable';

  insert into public.partner_disclosures_v282 (
    partner_id, identity_id, auth_user_id, scope_version, dataset
  ) values (
    v_partner, v_link.identity_id, v_link.auth_user_id,
    '2026-08-10-partner-sharing-v3', 'contact_details'
  );
  v_raised := false;
  begin
    update public.partner_disclosures_v282 set dataset = 'marketing_audience'
     where partner_id = v_partner;
  exception when others then
    v_raised := true;
  end;
  assert v_raised, 'a disclosure record must be append-only';
  v_log := v_log || '8 append-only=PASS; ';

  -- -----------------------------------------------------------------------
  -- 9. The reminder window is owner-writable and bounded.
  -- -----------------------------------------------------------------------
  -- V75 installed app.business_sector_modules_guard_v75, a BEFORE UPDATE trigger that refuses ANY
  -- change to industry or enabled_modules for a business carrying a sector assignment - which the
  -- fixture tenant does. Its documented escape hatch is a session GUC naming the business being
  -- synced; open it for the flip and shut it again immediately, exactly as v278's suite does. A
  -- test must not leave the entitlement guard disarmed for anything it goes on to do.
  select business.enabled_modules into v_modules_before
    from public.businesses business where business.id = v_biz;
  perform set_config('app.sector_entitlement_sync', v_biz::text, true);
  update public.businesses
     set industry = 'bar',
         enabled_modules = (select array_agg(distinct value)
                              from unnest(coalesce(v_modules_before, '{}'::text[])
                                || array['bottles', 'clients', 'sales']) value)
   where id = v_biz;
  perform set_config('app.sector_entitlement_sync', '', true);
  perform pg_temp.as_v282_user(v_owner);
  v_payload := public.bar_save_expiry_reminder_days_v282(v_biz, 14);
  assert (v_payload->>'reminder_days')::integer = 14, 'the reminder window must be saveable';
  v_payload := public.bar_get_bottle_setup_v278(v_biz);
  assert (v_payload->>'reminder_days')::integer = 14,
    'the setup read must return the saved reminder window';
  v_raised := false;
  begin
    perform public.bar_save_expiry_reminder_days_v282(v_biz, 0);
  exception when others then
    v_raised := true;
  end;
  reset role;
  assert v_raised, 'a reminder window of zero days must be refused';
  perform set_config('app.sector_entitlement_sync', v_biz::text, true);
  update public.businesses
     set industry = v_industry_before, enabled_modules = v_modules_before
   where id = v_biz;
  perform set_config('app.sector_entitlement_sync', '', true);
  v_log := v_log || '9 reminder-window=PASS; ';

  raise exception 'V282_RESULT ALL PASS -- %', v_log;
end
$v282$;

rollback;
