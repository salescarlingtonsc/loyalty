-- Rollback-only acceptance for nestly_v528 — raw WhatsApp webhook retention.
-- Run: supabase db query --linked -f db/tests/v528_whatsapp_webhook_retention.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
--   01  grants: service_role only — no anon, no authenticated
--   02  THE WINDOW HOLDS BOTH WAYS: an 8-day-old row is deleted, a 6-day-old row
--       and a row written seconds ago both survive. A retention job that deletes
--       fresh rows is an outage, so the survival half matters as much as the
--       deletion half.
--   03  the purge is bounded by p_limit
--   04  a zero/negative retention window is REFUSED, not treated as "delete all"
--   05  an out-of-range limit is refused
--   06  the cron job exists, is active, and carries the 7-day argument
--   07  ingestion still works after a purge, and the fresh row is untouched

begin;

create temp table _r(k text, v text) on commit drop;

-- ---------------------------------------------------------------- 01 grants
insert into _r
select '01 grants',
  case when has_function_privilege('service_role',
         'public.purge_whatsapp_webhook_events_v528(integer,integer)', 'EXECUTE')
        and not has_function_privilege('anon',
         'public.purge_whatsapp_webhook_events_v528(integer,integer)', 'EXECUTE')
        and not has_function_privilege('authenticated',
         'public.purge_whatsapp_webhook_events_v528(integer,integer)', 'EXECUTE')
       then 'PASS service_role only'
       else 'FAIL grants are wrong' end;

-- Three synthetic rows straddling the 7-day boundary.
insert into public.whatsapp_webhook_events(
  payload_sha256, payload, signature_verified, entry_kinds, meta_message_ids, received_at, last_received_at)
values
  (repeat('1',64), '{"suite":"v528","age":"8d"}'::jsonb, true, array['messages'], array['wamid.V528OLD'],
   now() - interval '8 days', now() - interval '8 days'),
  (repeat('2',64), '{"suite":"v528","age":"6d"}'::jsonb, true, array['messages'], array['wamid.V528EDGE'],
   now() - interval '6 days', now() - interval '6 days'),
  (repeat('3',64), '{"suite":"v528","age":"now"}'::jsonb, true, array['messages'], array['wamid.V528FRESH'],
   now(), now());

create temp table _p(step text, n integer) on commit drop;
insert into _p select 'sweep', public.purge_whatsapp_webhook_events_v528(5000, 7);

-- ------------------------------------------------- 02 the window, both ways
insert into _r
select '02 window holds both ways',
  case when not exists (select 1 from public.whatsapp_webhook_events where payload_sha256 = repeat('1',64))
        and exists (select 1 from public.whatsapp_webhook_events where payload_sha256 = repeat('2',64))
        and exists (select 1 from public.whatsapp_webhook_events where payload_sha256 = repeat('3',64))
       then 'PASS 8d deleted; 6d and fresh both survived'
       else 'FAIL retention window is wrong' end;

-- ---------------------------------------------------------------- 03 bounded
insert into public.whatsapp_webhook_events(
  payload_sha256, payload, signature_verified, received_at, last_received_at)
select md5('v528-bulk-' || g)::text || md5('x')::text, '{"suite":"v528"}'::jsonb, true,
       now() - interval '30 days', now() - interval '30 days'
from generate_series(1,5) g;

insert into _p select 'bounded', public.purge_whatsapp_webhook_events_v528(2, 7);

insert into _r
select '03 bounded by p_limit',
  case when (select n from _p where step='bounded') = 2
       then 'PASS deleted exactly 2 when asked for 2'
       else 'FAIL limit ignored (' || coalesce((select n::text from _p where step='bounded'),'null') || ')' end;

-- ------------------------------------------- 04 a zero window is refused
do $$
declare v_zero text; v_neg text;
begin
  begin perform public.purge_whatsapp_webhook_events_v528(100, 0); v_zero := 'NONE';
  exception when others then v_zero := sqlstate; end;
  begin perform public.purge_whatsapp_webhook_events_v528(100, -1); v_neg := 'NONE';
  exception when others then v_neg := sqlstate; end;
  insert into _r values ('04 zero/negative window refused',
    case when v_zero = '22023' and v_neg = '22023'
         then 'PASS a window that would delete live rows is refused'
         else 'FAIL zero=' || v_zero || ' neg=' || v_neg end);
end $$;

-- ------------------------------------------------- 05 limit range refused
do $$
declare v_lo text; v_hi text;
begin
  begin perform public.purge_whatsapp_webhook_events_v528(0, 7); v_lo := 'NONE';
  exception when others then v_lo := sqlstate; end;
  begin perform public.purge_whatsapp_webhook_events_v528(10001, 7); v_hi := 'NONE';
  exception when others then v_hi := sqlstate; end;
  insert into _r values ('05 limit range refused',
    case when v_lo = '22023' and v_hi = '22023' then 'PASS 0 and 10001 both refused'
         else 'FAIL lo=' || v_lo || ' hi=' || v_hi end);
end $$;

-- ---------------------------------------------------------------- 06 cron
insert into _r
select '06 cron scheduled',
  case when exists (
    select 1 from cron.job
     where jobname = 'nestly-v528-whatsapp-webhook-retention'
       and active
       and command like '%purge_whatsapp_webhook_events_v528(5000, 7)%')
       then 'PASS daily job active with the 7-day argument'
       else 'FAIL cron job missing, inactive, or wrong arguments' end;

-- ------------------------------------------- 07 ingestion still works
create temp table _i(doc jsonb) on commit drop;
insert into _i select public.ingest_whatsapp_webhook_event_v504(
  repeat('9',64), '{"suite":"v528","after":"purge"}'::jsonb, true, null, null,
  array['messages'], array['wamid.V528AFTER']);

insert into _r
select '07 ingestion unaffected by the sweep',
  case when (select doc->>'duplicate' from _i) = 'false'
        and exists (select 1 from public.whatsapp_webhook_events where payload_sha256 = repeat('9',64))
        and exists (select 1 from public.whatsapp_webhook_events where payload_sha256 = repeat('3',64))
       then 'PASS a new delivery still records; the fresh row is still there'
       else 'FAIL the purge interfered with ingestion' end;

select k as check_name, v as result from _r order by k;

rollback;
