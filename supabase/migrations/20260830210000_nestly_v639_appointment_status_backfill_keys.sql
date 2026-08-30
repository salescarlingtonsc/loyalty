-- NESTLY v639 — Phase A follow-up: v631's audit_log backfill matched zero rows because the
-- live APPOINTMENT_STATUS detail keys are 'to'/'from', not 'status'. Re-run with the real
-- keys — which also recovers the true from_status the original design thought was lost.
-- (The v631 source file's backfill is aligned to the same keys; this migration is the
-- corrective data pass for the already-applied production run.)
begin;

insert into public.appointment_status_events
  (business_id, appointment_id, from_status, to_status, at, actor, actor_kind, note)
select a.business_id, a.entity_id,
       a.detail->>'from',
       a.detail->>'to',
       a.created_at, a.actor, 'system', 'backfill:audit_log'
  from public.audit_log a
 where a.action = 'APPOINTMENT_STATUS'
   and a.entity = 'appointments'
   and a.detail->>'to' is not null
   and exists (select 1 from public.appointments ap
                where ap.id = a.entity_id and ap.business_id = a.business_id)
   and not exists (select 1 from public.appointment_status_events e
                    where e.appointment_id = a.entity_id
                      and e.to_status = a.detail->>'to'
                      and e.at = a.created_at);

commit;
