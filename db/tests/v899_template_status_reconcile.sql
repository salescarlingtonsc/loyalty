-- nestly_v899 rolled-back verification — Meta's answer gets written down.
--
-- Run against production. Everything happens inside the transaction and the file ends in
-- `rollback;`, so the registry is exactly as it was when this finishes.
--
--   1. the drift v898 had to fix by hand now fixes itself: a row put back to 'submitted' is
--      returned to 'approved' by one reconcile call, and the call says so;
--   2. running it again changes nothing — idempotent, not churning;
--   3. it never invents a row: an observation for a meta_name this registry does not hold
--      writes nothing and adds nothing;
--   4. 'approved' is the only status that can open the gate — a paused observation closes it;
--   5. a status outside the registry's vocabulary is refused and reported, not forced in;
--   6. and the contract the sender binds parameters against is untouched by all of it.

\set ON_ERROR_STOP on

begin;

do $test$
declare
  v_result jsonb;
  v_status text;
  v_body text;
  v_descriptors jsonb;
  v_rows_before integer;
  v_rows_after integer;
begin
  select count(*) into v_rows_before from public.whatsapp_template_registry_v551;
  select body_text, parameter_descriptors into v_body, v_descriptors
    from public.whatsapp_template_registry_v551 where template_key = 'appointment_updated';

  -- 1. the v898 drift, reconciled instead of typed in
  update public.whatsapp_template_registry_v551
     set status = 'submitted'
   where template_key = 'appointment_updated';

  v_result := public.internal_whatsapp_template_reconcile_v899(
    '[{"meta_name":"peekaa_appt_updated","status":"approved","meta_template_id":"2204154080535364"}]'::jsonb);
  assert (v_result->>'ok')::boolean, format('reconcile failed: %s', v_result);
  assert (v_result->>'changed_count')::integer = 1,
    format('one row should have changed, got %s', v_result);

  select status into v_status
    from public.whatsapp_template_registry_v551 where template_key = 'appointment_updated';
  assert v_status = 'approved', format('the row should read approved, got %s', v_status);

  -- 2. idempotent
  v_result := public.internal_whatsapp_template_reconcile_v899(
    '[{"meta_name":"peekaa_appt_updated","status":"approved","meta_template_id":"2204154080535364"}]'::jsonb);
  assert (v_result->>'changed_count')::integer = 0,
    format('a second identical reconcile must change nothing, got %s', v_result);

  -- 3. never invents a row
  v_result := public.internal_whatsapp_template_reconcile_v899(
    '[{"meta_name":"someone_elses_template","status":"approved","meta_template_id":"999"}]'::jsonb);
  assert (v_result->>'changed_count')::integer = 0,
    format('an unregistered template must change nothing, got %s', v_result);
  select count(*) into v_rows_after from public.whatsapp_template_registry_v551;
  assert v_rows_after = v_rows_before,
    format('reconcile must never add a row: %s before, %s after', v_rows_before, v_rows_after);

  -- 4. it closes the gate as readily as it opens it
  v_result := public.internal_whatsapp_template_reconcile_v899(
    '[{"meta_name":"peekaa_appt_updated","status":"paused","meta_template_id":null}]'::jsonb);
  assert (v_result->>'changed_count')::integer = 1, format('the pause should have landed: %s', v_result);
  select status into v_status
    from public.whatsapp_template_registry_v551 where template_key = 'appointment_updated';
  assert v_status = 'paused', format('a paused template must not read approved, got %s', v_status);
  -- and pausing must not discard the Meta id we already hold
  assert (select meta_template_id from public.whatsapp_template_registry_v551
           where template_key = 'appointment_updated') = '2204154080535364',
    'a null observation must not erase a known Meta id';

  -- 5. a status outside the vocabulary is refused, named, and writes nothing
  v_result := public.internal_whatsapp_template_reconcile_v899(
    '[{"meta_name":"peekaa_appt_updated","status":"quarantined","meta_template_id":null}]'::jsonb);
  assert (v_result->>'changed_count')::integer = 0,
    format('an unmappable status must write nothing, got %s', v_result);
  assert jsonb_array_length(v_result->'unmappable') = 1,
    format('an unmappable status must be reported, got %s', v_result);
  select status into v_status
    from public.whatsapp_template_registry_v551 where template_key = 'appointment_updated';
  assert v_status = 'paused', 'the refused observation must have left the row alone';

  -- a malformed payload is refused whole
  v_result := public.internal_whatsapp_template_reconcile_v899('{"not":"an array"}'::jsonb);
  assert (v_result->>'ok')::boolean is not true, format('a non-array payload must be refused: %s', v_result);

  -- 6. the parameter contract is untouched by every call above
  assert (select body_text from public.whatsapp_template_registry_v551
           where template_key = 'appointment_updated') = v_body,
    'reconcile must never rewrite body_text';
  assert (select parameter_descriptors from public.whatsapp_template_registry_v551
           where template_key = 'appointment_updated') = v_descriptors,
    'reconcile must never rewrite the parameter descriptors';

  raise notice 'v899 reconcile verified';
end
$test$;

-- The grant boundary, read from the catalogue rather than asserted in prose.
do $guards$
declare
  v_acl text;
begin
  select coalesce(array_to_string(p.proacl::text[], ','), '') into v_acl
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'internal_whatsapp_template_reconcile_v899';
  assert v_acl like '%service_role=X%', format('service_role must execute: %s', v_acl);
  assert v_acl not like '%anon=X%' and v_acl not like '%authenticated=X%',
    format('no browser role may reconcile the send gate: %s', v_acl);
  raise notice 'v899 grants verified';
end
$guards$;

rollback;
