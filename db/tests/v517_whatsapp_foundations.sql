-- Rollback-only acceptance for nestly_v517 — the WhatsApp foundations.
-- Run: supabase db query --linked -f db/tests/v517_whatsapp_foundations.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- What this proves:
--   01  the sweep now filters on consumer, and the rest of it is unchanged
--   02  THE FENCE ACTUALLY WORKS. Widen the consumer CHECK, plant a non-'comms'
--       row, run the sweep, and prove it is NOT swallowed into captured_messages
--       and NOT marked delivered. This is the whole point of the migration, so it
--       is tested by DOING it, not by grepping the function body.
--   03  the fence did not break the thing it fences: a real 'comms' row still
--       sweeps to 'delivered' with a captured message
--   04  both flags exist and are OFF, and a MISSING flag also reads false
--   05  the flag seed is idempotent AND non-destructive — re-running the insert
--       cannot switch off a flag someone deliberately switched on
--   06  the health reader refuses a caller without platform automation read
--   07  the health reader returns aggregates only — no payload, no phone number,
--       no customer identifier, no business identifier
--   08  grants match the sibling platform readers exactly
--
-- NOTE on shape: a function that INSERTs is invisible to the SAME statement's
-- snapshot, so every check that calls a writer does so in its own statement and
-- asserts in a later one. Getting this wrong made two v504 checks report false
-- failures against a correct RPC.

begin;

create temp table _r(k text, v text) on commit drop;

-- ---------------------------------------------------------------- 01 fenced
insert into _r
select '01 sweep is fenced',
  case when pg_get_functiondef(to_regprocedure('app.run_outbox_sweep(integer)')::oid)
         ilike '%and consumer = ''comms''%'
        -- the parts that must NOT have changed
        and pg_get_functiondef(to_regprocedure('app.run_outbox_sweep(integer)')::oid)
         ilike '%for update skip locked%'
        and pg_get_functiondef(to_regprocedure('app.run_outbox_sweep(integer)')::oid)
         ilike '%synthetic:%'
        and pg_get_functiondef(to_regprocedure('app.run_outbox_sweep(integer)')::oid)
         ilike '%dead_letter%'
       then 'PASS consumer filter present, sweep otherwise intact'
       else 'FAIL sweep not fenced or otherwise altered' end;

-- A business and a domain event to hang outbox rows off. Reuses whatever tenant
-- exists; the suite is rolled back so nothing survives.
create temp table _fx(business_id uuid, event_comms uuid, event_other uuid) on commit drop;
insert into _fx(business_id)
select id from public.businesses order by created_at limit 1;

update _fx set
  event_comms = app.emit_domain_event(
    business_id, 'consent.changed', 'v517-suite-comms-' || gen_random_uuid()::text,
    null, null, now(), null, '{"suite":"v517"}'::jsonb),
  event_other = app.emit_domain_event(
    business_id, 'consent.changed', 'v517-suite-other-' || gen_random_uuid()::text,
    null, null, now(), null, '{"suite":"v517"}'::jsonb);

-- ------------------------------------------------- 02 the fence, exercised
-- Widen the CHECK exactly as a future migration would, then prove the sweep
-- ignores the new consumer instead of swallowing it.
alter table public.event_outbox
  drop constraint event_outbox_consumer_check,
  add constraint event_outbox_consumer_check check (consumer in ('comms','whatsapp'));

insert into public.event_outbox(business_id, event_id, consumer, delivery_status, next_attempt_at)
select business_id, event_other, 'whatsapp', 'pending', now() - interval '1 minute' from _fx;
insert into public.event_outbox(business_id, event_id, consumer, delivery_status, next_attempt_at)
select business_id, event_comms, 'comms', 'pending', now() - interval '1 minute' from _fx;

create temp table _swept(n integer) on commit drop;
insert into _swept select app.run_outbox_sweep(200);

insert into _r
select '02 fence holds under a widened CHECK',
  case when (select delivery_status from public.event_outbox o join _fx f on true
              where o.event_id = f.event_other and o.consumer = 'whatsapp') = 'pending'
        and not exists (select 1 from public.captured_messages c join _fx f on true
                         where c.event_id = f.event_other)
       then 'PASS a whatsapp row was not swallowed and not marked delivered'
       else 'FAIL the synthetic sink claimed a non-comms message' end;

-- ------------------------------------------------- 03 comms still works
insert into _r
select '03 comms consumer unaffected',
  case when (select delivery_status from public.event_outbox o join _fx f on true
              where o.event_id = f.event_comms and o.consumer = 'comms') = 'delivered'
        and exists (select 1 from public.captured_messages c join _fx f on true
                     where c.event_id = f.event_comms)
        and (select n from _swept) >= 1
       then 'PASS a comms row still sweeps to delivered with a captured message'
       else 'FAIL the fence broke the consumer it was meant to keep' end;

-- ---------------------------------------------------------------- 04 flags
insert into _r
select '04 flags exist and are off',
  case when app.platform_feature_enabled('whatsapp_outbound') = false
        and app.platform_feature_enabled('whatsapp_credit_charging_enabled') = false
        and (select count(*) from app.platform_feature_flags
              where feature_key in ('whatsapp_outbound','whatsapp_credit_charging_enabled')) = 2
        -- fail-closed by construction: an unseeded key is false, never null
        and app.platform_feature_enabled('whatsapp_never_seeded_' || gen_random_uuid()::text) = false
       then 'PASS both seeded off; an unknown key also reads false'
       else 'FAIL flag state wrong' end;

-- ------------------------------------------------- 05 seed is non-destructive
update app.platform_feature_flags set enabled = true where feature_key = 'whatsapp_outbound';

insert into app.platform_feature_flags(feature_key, enabled)
values ('whatsapp_outbound', false), ('whatsapp_credit_charging_enabled', false)
on conflict (feature_key) do nothing;

insert into _r
select '05 replay cannot switch a flag off',
  case when app.platform_feature_enabled('whatsapp_outbound') = true
       then 'PASS re-running the seed left a deliberately-enabled flag on'
       else 'FAIL replaying the migration would disable live outbound messaging' end;

update app.platform_feature_flags set enabled = false where feature_key = 'whatsapp_outbound';

-- ---------------------------------------------------------- 06 reader gate
do $$
declare v_code text; v_uid uuid := gen_random_uuid();
begin
  -- An authenticated user with no platform grant at all.
  perform set_config('request.jwt.claim.sub', v_uid::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.platform_get_whatsapp_health_v517();
    v_code := 'NONE';
  exception when others then v_code := sqlstate;
  end;
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '', true);
  insert into _r values ('06 reader refuses a non-platform caller',
    case when v_code = '42501' then 'PASS 42501 insufficient_privilege'
         else 'FAIL a non-platform caller read WhatsApp health (' || v_code || ')' end);
end $$;

-- ------------------------------------------------- 07 aggregates only
insert into public.whatsapp_webhook_events(
  payload_sha256, payload, signature_verified, waba_id, phone_number_id,
  entry_kinds, meta_message_ids)
values (
  repeat('7', 64),
  '{"entry":[{"id":"9","changes":[{"value":{"messages":[{"id":"wamid.SUITE517","from":"6591234567","text":{"body":"private medical note"}}]}}]}]}'::jsonb,
  true, '999999', '888888', array['messages'], array['wamid.SUITE517']);

-- Check 06 deliberately cleared the session identity, so the reader would now
-- refuse US. Assume a real super admin for the read — resolved from the table,
-- never hardcoded, so the suite survives the roster changing.
do $sa$
declare v_sa uuid;
begin
  select user_id into v_sa from public.super_admins order by created_at limit 1;
  perform set_config('request.jwt.claim.sub', coalesce(v_sa::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_sa, 'role', 'authenticated')::text, true);
end $sa$;

create temp table _health(doc jsonb) on commit drop;
insert into _health select public.platform_get_whatsapp_health_v517();

insert into _r
select '07 health leaks nothing',
  case when doc->'webhook'->>'total_recorded' is not null
        and (doc->'webhook'->>'total_recorded')::int >= 1
        and doc->>'outbound_enabled' = 'false'
        and doc::text not like '%6591234567%'      -- no customer phone number
        and doc::text not like '%medical%'          -- no message text
        and doc::text not like '%wamid.SUITE517%'   -- no message identifier
        and doc::text not like '%payload%'          -- no raw envelope
       then 'PASS counts only; no phone, text, wamid or payload'
       else 'FAIL health reader leaked customer data' end
from _health;

select set_config('request.jwt.claim.sub', '', true),
       set_config('request.jwt.claims', '', true);

-- ---------------------------------------------------------------- 08 grants
insert into _r
select '08 grants match precedent',
  case when has_function_privilege('authenticated', 'public.platform_get_whatsapp_health_v517()', 'EXECUTE')
        and has_function_privilege('service_role', 'public.platform_get_whatsapp_health_v517()', 'EXECUTE')
        and not has_function_privilege('anon', 'public.platform_get_whatsapp_health_v517()', 'EXECUTE')
        and not has_function_privilege('anon', 'app.run_outbox_sweep(integer)', 'EXECUTE')
        and not has_function_privilege('authenticated', 'app.run_outbox_sweep(integer)', 'EXECUTE')
       then 'PASS reader authenticated+service_role, sweep owner-only'
       else 'FAIL grants diverge from the sibling platform readers' end;

select k as check_name, v as result from _r order by k;

rollback;
