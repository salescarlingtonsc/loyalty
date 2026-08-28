-- ============================================================================
-- nestly_v580 — AN APPOINTMENT MESSAGE FOLLOWS ITS APPOINTMENT
--
-- P1, proven by executed probe during the 2026-08-28 ship-readiness audit:
-- queue a confirmation and a reminder, cancel the appointment, run the claim —
-- BOTH rows came back leased and ready to send. The claim CTE filtered on the
-- queue row's own status only and never looked at the appointment again. So a
-- cancelled appointment still messaged the customer, a deleted appointment's
-- row (FK on delete set null) still sent, and a reminder for a time that no
-- longer exists (reschedule = in-place UPDATE of starts_at; the idem key
-- carries the OLD time) still went out.
--
-- The message is a claim ABOUT the appointment. If the appointment is gone,
-- cancelled, or moved, the claim is false and must not be delivered.
--
-- THE ONE CHECK THAT CLOSES ALL THREE HOLES: at claim time, the row must still
-- describe a real, booked appointment at the very time baked into its
-- idempotency key (kind:appointment_id:starts_at@UTC — v557 chose that key
-- precisely so a reschedule re-arms; this makes the stale key self-identifying).
--   * cancelled / completed / no_show  -> status <> 'booked'   -> suppress
--   * deleted                          -> appointment_id null  -> suppress
--   * rescheduled away                 -> key time mismatch    -> suppress
--     (its replacement row, queued by the sweep with the NEW time, matches)
--
-- Suppression is EXPLICIT, not a silent filter: rows are marked
-- status='failed' with a NAMED last_error_code before the claim runs, so an
-- operator can see why the lane went quiet instead of wondering. And the quota
-- unit reserved at enqueue is RELEASED (v572 compensating row) — a merchant is
-- never charged for a message about an appointment that stopped existing.
--
-- The predicate is ALSO kept inside the claimable CTE (belt and braces): the
-- suppression sweep and the claim are two statements, and an appointment can be
-- cancelled between them.
-- ============================================================================

begin;

create or replace function public.internal_whatsapp_claim_template_sends_v557(
  p_worker_id text,
  p_limit integer default 20,
  p_lease_seconds integer default 120
)
returns table(
  message_id uuid, business_id uuid, recipient_phone_norm text,
  template_name text, language_code text, parameters jsonb,
  attempt_count integer, lease_token uuid)
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_lease uuid := gen_random_uuid();
  v_stale record;
begin
  -- v580: a queued notice whose appointment is gone, no longer booked, or no
  -- longer at the time in the key is suppressed BY NAME, and its quota unit is
  -- given back. Named reasons, never a silent filter.
  for v_stale in
    select m.id, m.business_id, m.idempotency_key,
           case
             when m.appointment_id is null then 'appointment_deleted'
             when a.status is distinct from 'booked' then 'appointment_' || coalesce(a.status,'missing')
             else 'appointment_rescheduled'
           end as why
      from public.whatsapp_template_sends_v557 m
      left join public.appointments a on a.id = m.appointment_id
     where m.status in ('queued','processing')
       and (m.lease_until is null or m.lease_until < now())
       and (
         m.appointment_id is null
         or a.status is distinct from 'booked'
         or m.idempotency_key <> (m.kind || ':' || m.appointment_id::text || ':'
              || to_char(a.starts_at at time zone 'UTC', 'YYYYMMDD"T"HH24MISS'))
       )
     for update of m skip locked
  loop
    update public.whatsapp_template_sends_v557
       set status = 'failed',
           status_rank = greatest(status_rank, app.support_status_rank_v535('failed')),
           last_error_code = left(v_stale.why, 64),
           next_attempt_at = null,
           lease_token = null, leased_by = null, lease_until = null
     where id = v_stale.id;
    -- The unit was reserved at enqueue under this same key; the customer will
    -- never receive this message, so the merchant gets it back.
    perform app.capability_release_v572(
      v_stale.business_id, 'whatsapp_appointment_notification',
      v_stale.idempotency_key, v_stale.why);
  end loop;

  return query
  with claimable as (
    select m.id
      from public.whatsapp_template_sends_v557 m
      join public.appointments a
        on a.id = m.appointment_id
       and a.status = 'booked'
       and m.idempotency_key = (m.kind || ':' || m.appointment_id::text || ':'
             || to_char(a.starts_at at time zone 'UTC', 'YYYYMMDD"T"HH24MISS'))
     where m.status in ('queued','processing')
       and coalesce(m.next_attempt_at, now()) <= now()
       and (m.lease_until is null or m.lease_until < now())
       and coalesce((app.business_may_initiate_comms_v572(m.business_id,'whatsapp','transactional')->>'allowed')::boolean, false)
     order by m.queued_at
     limit greatest(coalesce(p_limit, 20), 1)
     for update of m skip locked
  )
  update public.whatsapp_template_sends_v557 target
     set status = 'processing',
         status_rank = greatest(target.status_rank, app.support_status_rank_v535('processing')),
         lease_token = v_lease,
         leased_by = left(coalesce(p_worker_id, 'worker'), 64),
         lease_until = now() + make_interval(secs => greatest(coalesce(p_lease_seconds, 120), 30))
    from claimable
   where target.id = claimable.id
  returning target.id, target.business_id, target.recipient_phone_norm,
            target.template_name, target.language_code, target.parameters,
            target.attempt_count, v_lease;
end
$fn$;

revoke all on function public.internal_whatsapp_claim_template_sends_v557(text, integer, integer)
  from public, anon, authenticated;
grant execute on function public.internal_whatsapp_claim_template_sends_v557(text, integer, integer)
  to service_role;

comment on function public.internal_whatsapp_claim_template_sends_v557(text, integer, integer) is
  'v580 claim for appointment template sends. Before leasing, suppresses (by name, with quota release) any queued row whose appointment is deleted, no longer booked, or no longer at the time in its idempotency key — a message about an appointment that stopped existing must not be delivered. The same predicate guards the claim CTE against a cancel racing between the sweep and the lease.';

commit;
