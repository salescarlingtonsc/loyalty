-- Rollback-only acceptance for nestly_v824 — API WhatsApp sending is off, manual WhatsApp is not.
--   supabase db query --linked -f db/tests/v824_whatsapp_api_sends_off.sql
--
-- Every check CALLS the real enqueue path (app.whatsapp_enqueue_appointment_notice_v557, the
-- function both appointment triggers call) against the one tenant that actually holds the
-- whatsapp_appointment_notification capability — the Cubbly demo, source of all seven failed
-- sends — so a refusal here is the master switch and not some other gate.
--
--   A1  both platform flags read false
--   A2  POSITIVE CONTROL: with the master switch forced ON inside this transaction, the same
--       booking on the same tenant DOES queue a send. Without this, A3/A4 would pass just as
--       happily on a tenant that could never send — which is what the first probe of this
--       change did on ÉLAN (it holds no capability), proving nothing.
--   A3  with the switch off, the enqueue call is refused with reason outbound_not_enabled and
--       writes no row
--   A4  the trigger path — a real INSERT into appointments — queues nothing
--   A5  the manual WhatsApp button's inputs are untouched: the customer's phone still resolves
--
-- NEGATIVE CONTROL: on the database before v824, A1 fails ("whatsapp_outbound is still on").

begin;

do $suite$
declare
  c_biz     constant uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';  -- Cubbly SPA
  c_branch  constant uuid := '9a9081fb-fb48-49c7-a1c7-2bfb3d3ec263';
  c_service constant uuid := 'fb40ad58-65a0-47bb-a2f3-5f16a70a3a4b';
  v_client  uuid;
  v_appt    uuid;
  v_res     jsonb;
  v_before  bigint; v_after bigint;
  n         integer := 0;
begin
  select c.id into v_client from public.clients c
   where c.business_id = c_biz and not coalesce(c.is_synthetic,false) and c.phone_norm is not null
   order by c.created_at limit 1;
  if v_client is null then
    raise exception 'A0: no non-synthetic Cubbly customer with a phone to book';
  end if;

  n := n + 1;
  if exists (select 1 from app.platform_feature_flags
              where feature_key in ('whatsapp_outbound','whatsapp_retention_sends') and enabled) then
    raise exception 'A%: whatsapp_outbound is still on', n;
  end if;

  -- A2 positive control: prove the path can send when the switch is on.
  n := n + 1;
  update app.platform_feature_flags set enabled = true where feature_key = 'whatsapp_outbound';
  insert into public.appointments(business_id, client_id, service_id, branch_id, starts_at, ends_at, status)
  values (c_biz, v_client, c_service, c_branch, now() + interval '6 days', now() + interval '6 days 1 hour', 'booked')
  returning id into v_appt;
  select count(*) into v_before from public.whatsapp_template_sends_v557 where business_id = c_biz;
  -- the trigger already ran on the insert above; count what it queued, then call the function
  -- directly for the same appointment so the reason is visible if it refused
  v_res := app.whatsapp_enqueue_appointment_notice_v557(c_biz, v_appt, 'appointment_confirmation');
  select count(*) into v_after from public.whatsapp_template_sends_v557 where business_id = c_biz;
  if not exists (select 1 from public.whatsapp_template_sends_v557 where appointment_id = v_appt) then
    raise exception 'A%: with the switch ON nothing was queued for a Cubbly booking — the control is not live (%)',
      n, left(v_res::text, 300);
  end if;

  -- A3 switch off: refused for the right reason, nothing written.
  n := n + 1;
  update app.platform_feature_flags set enabled = false where feature_key = 'whatsapp_outbound';
  insert into public.appointments(business_id, client_id, service_id, branch_id, starts_at, ends_at, status)
  values (c_biz, v_client, c_service, c_branch, now() + interval '7 days', now() + interval '7 days 1 hour', 'booked')
  returning id into v_appt;
  v_res := app.whatsapp_enqueue_appointment_notice_v557(c_biz, v_appt, 'appointment_confirmation');
  if coalesce(v_res->>'status','') <> 'refused' or coalesce(v_res->>'reason','') <> 'outbound_not_enabled' then
    raise exception 'A%: with the switch OFF the enqueue answered % (expected refused / outbound_not_enabled)',
      n, left(v_res::text, 300);
  end if;

  -- A4 the trigger path queued nothing for that booking either.
  n := n + 1;
  if exists (select 1 from public.whatsapp_template_sends_v557 where appointment_id = v_appt) then
    raise exception 'A%: the booking trigger queued a send with the master switch off', n;
  end if;

  -- A5 the manual button's data is not on this path.
  n := n + 1;
  if (select phone_norm from public.clients where id = v_client) is null then
    raise exception 'A%: the customer phone the manual WhatsApp button uses is gone', n;
  end if;

  raise notice 'nestly_v824: % / % assertions passed', n, n;
end
$suite$;

rollback;
