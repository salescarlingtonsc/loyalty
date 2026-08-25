-- Rollback-only acceptance for nestly_v504 — the Meta WhatsApp Cloud API webhook inbox.
-- Run: supabase db query --linked -f db/tests/v504_whatsapp_webhook_inbox.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- What this proves, in the order the endpoint exercises it:
--   01  the table exists with RLS on and ZERO policies — unreadable and unwritable through
--       PostgREST by anon, authenticated and super admin alike; service_role bypass is the
--       only access path
--   02  the ingest RPC's grants are exactly service_role (no anon, no authenticated) — a
--       browser cannot forge a webhook delivery
--   03  a first delivery inserts: duplicate=false, received_count=1, and the observability
--       columns carry what the edge function extracted
--   04  IDEMPOTENCY, the reason this migration exists: the SAME digest re-ingested does NOT
--       insert a second row; it returns duplicate=true and bumps received_count. Meta retries
--       are byte-identical, so this is the real retry path, not an approximation
--   05  a retry does not disturb the stored payload or the processing state a future consumer
--       owns
--   06  a DIFFERENT digest is a different delivery and does insert
--   07  an unverified delivery is refused (42501) — the second wall behind the edge function,
--       so a future caller cannot widen the policy without editing SQL
--   08  a malformed envelope is refused (22023): bad digest, non-object payload, null flag
--   09  an unfamiliar payload SHAPE still stores — entry_kinds '{other}', ids null. A webhook
--       that rejects an undocumented field is a webhook Meta eventually disables.

begin;

create temp table _r(k text, v text) on commit drop;

-- ---------------------------------------------------------------- 01 surface
insert into _r
select '01 table+rls',
  case when (select relrowsecurity from pg_class where oid = 'public.whatsapp_webhook_events'::regclass)
        and (select count(*) from pg_policies
              where schemaname = 'public' and tablename = 'whatsapp_webhook_events') = 0
        and not has_table_privilege('anon', 'public.whatsapp_webhook_events', 'SELECT')
        and not has_table_privilege('authenticated', 'public.whatsapp_webhook_events', 'SELECT')
        and not has_table_privilege('authenticated', 'public.whatsapp_webhook_events', 'INSERT')
       then 'PASS rls on, 0 policies, no anon/authenticated grants'
       else 'FAIL surface is reachable' end;

-- ---------------------------------------------------------------- 02 grants
insert into _r
select '02 rpc grants',
  case when has_function_privilege('service_role',
         'public.ingest_whatsapp_webhook_event_v504(text,jsonb,boolean,text,text,text[],text[])', 'EXECUTE')
        and not has_function_privilege('anon',
         'public.ingest_whatsapp_webhook_event_v504(text,jsonb,boolean,text,text,text[],text[])', 'EXECUTE')
        and not has_function_privilege('authenticated',
         'public.ingest_whatsapp_webhook_event_v504(text,jsonb,boolean,text,text,text[],text[])', 'EXECUTE')
       then 'PASS service_role only'
       else 'FAIL grants are wrong' end;

-- A realistic Meta status callback and its digest (any 64-hex value stands in for the
-- edge function's sha256 of the raw body; the RPC only requires the shape).
create temp table _f(digest text, payload jsonb) on commit drop;
insert into _f values (
  repeat('a', 64),
  jsonb_build_object(
    'object', 'whatsapp_business_account',
    'entry', jsonb_build_array(jsonb_build_object(
      'id', '111111111111111',
      'changes', jsonb_build_array(jsonb_build_object(
        'field', 'messages',
        'value', jsonb_build_object(
          'messaging_product', 'whatsapp',
          'metadata', jsonb_build_object('display_phone_number','6582088809','phone_number_id','222222222222222'),
          'statuses', jsonb_build_array(jsonb_build_object(
            'id','wamid.TEST0001','status','delivered','timestamp','1787000000',
            'recipient_id','6582088809'))))))))
);

-- ---------------------------------------------------------------- 03 first delivery
create temp table _o(step text, result jsonb) on commit drop;
insert into _o
select 'first', public.ingest_whatsapp_webhook_event_v504(
  f.digest, f.payload, true, '111111111111111', '222222222222222',
  array['statuses'], array['wamid.TEST0001']) from _f f;

insert into _r
select '03 first insert',
  case when (select result->>'duplicate' from _o where step='first') = 'false'
        and (select (result->>'received_count')::int from _o where step='first') = 1
        and e.waba_id = '111111111111111' and e.phone_number_id = '222222222222222'
        and e.entry_kinds = array['statuses'] and e.meta_message_ids = array['wamid.TEST0001']
        and e.signature_verified and e.processing_status = 'pending' and e.received_count = 1
       then 'PASS inserted with observability intact'
       else 'FAIL first delivery ' || coalesce(e.processing_status,'<missing>') end
from public.whatsapp_webhook_events e where e.payload_sha256 = repeat('a', 64);

-- ---------------------------------------------------------------- 04 the retry
insert into _o
select 'retry', public.ingest_whatsapp_webhook_event_v504(
  f.digest, f.payload, true, '111111111111111', '222222222222222',
  array['statuses'], array['wamid.TEST0001']) from _f f;

insert into _r
select '04 retry is idempotent',
  case when (select count(*) from public.whatsapp_webhook_events
              where payload_sha256 = repeat('a', 64)) = 1
        and (select result->>'duplicate' from _o where step='retry') = 'true'
        and (select (result->>'received_count')::int from _o where step='retry') = 2
        and (select result->>'event_id' from _o where step='first')
          = (select result->>'event_id' from _o where step='retry')
       then 'PASS one row, received_count 2, same event_id'
       else 'FAIL a Meta retry created a second record' end;

-- ---------------------------------------------------------------- 05 retry disturbs nothing
insert into _r
select '05 retry preserves state',
  case when e.payload = (select payload from _f)
        and e.processing_status = 'pending' and e.processing_attempts = 0
        and e.processed_at is null and e.last_error is null
        and e.last_received_at >= e.received_at
       then 'PASS payload and processing state untouched'
       else 'FAIL a retry mutated payload or processing state' end
from public.whatsapp_webhook_events e where e.payload_sha256 = repeat('a', 64);

-- ---------------------------------------------------------------- 06 a genuinely new delivery
-- Two statements, not one. A function that INSERTs is not visible to the SAME
-- statement's snapshot, so calling it and counting rows in one SELECT reads the
-- table as it was BEFORE the call and reports a false failure. The endpoint
-- always calls once per request, which is what this shape reproduces.
insert into _o
select 'distinct', public.ingest_whatsapp_webhook_event_v504(
  repeat('b', 64), (select payload from _f), true, null, null,
  array['statuses'], array['wamid.TEST0002']);

insert into _r
select '06 distinct digest inserts',
  case when (select result->>'duplicate' from _o where step='distinct') = 'false'
        and (select count(*) from public.whatsapp_webhook_events
              where payload_sha256 in (repeat('a',64), repeat('b',64))) = 2
       then 'PASS a different body is a different delivery'
       else 'FAIL dedupe swallowed a distinct delivery' end;

-- ---------------------------------------------------------------- 07 unverified refused
do $$
declare v_code text;
begin
  begin
    perform public.ingest_whatsapp_webhook_event_v504(
      repeat('c', 64), '{"object":"whatsapp_business_account"}'::jsonb, false);
    v_code := 'NONE';
  exception when others then v_code := sqlstate;
  end;
  insert into _r values ('07 unverified refused',
    case when v_code = '42501' then 'PASS 42501 insufficient_privilege'
         else 'FAIL unverified delivery stored (' || v_code || ')' end);
end $$;

-- ---------------------------------------------------------------- 08 malformed envelopes
do $$
declare v_bad integer := 0; v_code text;
begin
  -- bad digest
  begin perform public.ingest_whatsapp_webhook_event_v504('not-a-digest', '{}'::jsonb, true);
  exception when others then if sqlstate = '22023' then v_bad := v_bad + 1; end if; end;
  -- payload is not an object
  begin perform public.ingest_whatsapp_webhook_event_v504(repeat('d',64), '[]'::jsonb, true);
  exception when others then if sqlstate = '22023' then v_bad := v_bad + 1; end if; end;
  -- null verification flag
  begin perform public.ingest_whatsapp_webhook_event_v504(repeat('e',64), '{}'::jsonb, null);
  exception when others then if sqlstate = '22023' then v_bad := v_bad + 1; end if; end;
  insert into _r values ('08 malformed refused',
    case when v_bad = 3 then 'PASS all three rejected 22023'
         else 'FAIL only ' || v_bad || ' of 3 rejected' end);
end $$;

-- ---------------------------------------------------------------- 09 unfamiliar shape stores
-- Split for the same snapshot reason as 06.
insert into _o
select 'unknown', public.ingest_whatsapp_webhook_event_v504(
  repeat('f', 64),
  '{"object":"whatsapp_business_account","entry":[{"id":"9","changes":[{"field":"some_future_field","value":{}}]}]}'::jsonb,
  true, '9', null, array['other'], array[]::text[]);

insert into _r
select '09 unknown shape stores',
  case when (select result->>'duplicate' from _o where step='unknown') = 'false'
        and (select entry_kinds from public.whatsapp_webhook_events
              where payload_sha256 = repeat('f',64)) = array['other']
       then 'PASS an undocumented field still records'
       else 'FAIL an unfamiliar payload was rejected' end;

select k as check_name, v as result from _r order by k;

rollback;
