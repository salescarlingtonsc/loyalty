-- NESTLY v517 - WHATSAPP FOUNDATIONS: the fence, the switches, the eyes
--
-- Owner directive 2026-08-26: "keep building ... ensure the system is automated
-- at every level." This is the de-risking increment that must land BEFORE any
-- WhatsApp queue exists. It ships three things, all provably inert today, and
-- deliberately no queue, no sender and no template.
--
-- ===========================================================================
-- 1. THE FENCE. This is the reason this migration goes first.
-- ===========================================================================
-- app.run_outbox_sweep (v56, on cron every 2 minutes as 'frenly-outbox-sweep')
-- selects `from public.event_outbox where delivery_status in ('pending','failed')
-- and next_attempt_at <= now()`. It NEVER references the `consumer` column - I
-- checked the live production definition, not just the file.
--
-- The only thing making that safe is event_outbox_consumer_check, which today
-- pins consumer = 'comms'. So the sweep is correct by accident of a constraint
-- somewhere else. The moment anyone widens that CHECK to add a 'whatsapp'
-- consumer - the obvious next move, and one a reasonable person would make in a
-- migration that never touches this function - the sweep starts picking up
-- WhatsApp rows, writing each one into public.captured_messages with a
-- 'synthetic:...@example.test' recipient, and marking it 'delivered'.
--
-- That failure is worse than an outage. Every message reports perfect delivery
-- and none of them exist. And it is not cleanly reversible: captured_messages
-- carries app.captured_messages_guard, which refuses UPDATE and DELETE, so the
-- false evidence is permanent.
--
-- Adding the predicate now costs nothing - it is a logical tautology over all 4
-- existing rows, every one of them ('comms','delivered') - and it means the
-- widening, whenever it comes, is safe by construction rather than by memory.
-- The rest of the function is transcribed byte-for-byte from the live
-- definition; the WHERE clause is the only change.
--
-- ===========================================================================
-- 2. THE SWITCHES
-- ===========================================================================
-- Two rows in app.platform_feature_flags (v30), which already has RLS on, all
-- grants revoked, and app.platform_feature_enabled defaulting a MISSING key to
-- false. That default is why this is fail-closed by construction: code can ask
-- about a flag that was never seeded and get 'no'.
--
-- There is deliberately NO setter RPC. Flipping a platform flag stays a
-- service_role/SQL act - the same posture as public.super_admins, which has no
-- write policy at all. A superadmin console button that can switch on outbound
-- messaging for the whole platform is a button worth not building yet.
--
-- `on conflict do nothing` so replaying this migration can never switch OFF a
-- flag someone deliberately switched on.
--
-- ===========================================================================
-- 3. THE EYES
-- ===========================================================================
-- v504 gave public.whatsapp_webhook_events RLS with ZERO policies and revoked
-- every grant, so service_role is the only reader. That is the right posture for
-- raw webhook payloads containing customer phone numbers - but it means a super
-- admin opening the console gets 0 rows, which renders as "no traffic" when the
-- truth may be "no permission". Those must never look the same on a health
-- screen.
--
-- So: one SECURITY DEFINER aggregate reader, gated on
-- app.v89_platform_can('automation','r'), returning counts only. No payload, no
-- phone number, no message text, no customer identifier ever leaves the table.
--
-- One honesty detail worth stating: last_recorded_at is the last SUCCESSFULLY
-- RECORDED delivery. A POST rejected for a missing app secret returns 503 from
-- the edge function BEFORE it touches the database, so during the Meta setup
-- window this reader can read "nothing yet" while Meta is in fact calling us and
-- being turned away. The column is named for what it measures, and the console
-- must label it that way too.

begin;

-- ===========================================================================
-- 1. The fence
-- ===========================================================================

create or replace function app.run_outbox_sweep(p_limit integer default 200)
returns integer language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare o record; ev public.domain_events%rowtype; v_recipient text; v_done integer := 0; v_fail boolean;
begin
  for o in select * from public.event_outbox
            where delivery_status in ('pending','failed') and next_attempt_at <= now()
              -- v517: the capture provider serves the 'comms' consumer and ONLY that
              -- consumer. Without this, widening event_outbox_consumer_check elsewhere
              -- silently routes real messages into the synthetic sink and marks them
              -- delivered. See this migration's header.
              and consumer = 'comms'
            order by next_attempt_at for update skip locked limit greatest(p_limit, 1) loop
    update public.event_outbox set delivery_status = 'delivering', updated_at = now() where id = o.id;
    v_fail := nullif(current_setting('app.ps1b_capture_fail', true), '') = '1';
    begin
      if v_fail then raise exception 'simulated comms provider outage'; end if;
      select * into ev from public.domain_events where event_id = o.event_id;
      -- Synthetic-only recipient. A real address/number is structurally uninsertable.
      v_recipient := 'synthetic:' || coalesce(ev.subject_client_id::text, ev.subject_identity_id::text, o.event_id::text) || '@example.test';
      insert into public.captured_messages(business_id, event_id, outbox_id, channel, recipient, template_key, rendered)
      values(o.business_id, o.event_id, o.id, 'in_app', v_recipient, ev.event_type,
        jsonb_build_object('event_type', ev.event_type, 'subject_client_id', ev.subject_client_id))
      on conflict (outbox_id) do nothing;
      update public.event_outbox set delivery_status = 'delivered', attempts = attempts + 1, updated_at = now(), last_error = null
       where id = o.id;
      v_done := v_done + 1;
    exception when others then
      update public.event_outbox
         set attempts = attempts + 1,
             delivery_status = case when attempts + 1 >= max_attempts then 'dead_letter' else 'failed' end,
             next_attempt_at = now() + (least(power(2, attempts + 1), 3600) || ' seconds')::interval,
             last_error = sqlerrm, updated_at = now()
       where id = o.id;
    end;
  end loop;
  return v_done;
end $$;

-- Restated verbatim from the live proacl: this function is granted to nobody but
-- its owner, and the cron job runs as postgres.
revoke all on function app.run_outbox_sweep(integer) from public, anon, authenticated;

comment on function app.run_outbox_sweep(integer) is
  'v56 capture-provider sweep, fenced in v517 to consumer = ''comms'' so a future consumer cannot be silently swallowed by the synthetic sink.';

-- ===========================================================================
-- 2. The switches
-- ===========================================================================

insert into app.platform_feature_flags(feature_key, enabled)
values
  ('whatsapp_outbound', false),
  ('whatsapp_credit_charging_enabled', false)
on conflict (feature_key) do nothing;

-- ===========================================================================
-- 3. The eyes
-- ===========================================================================

create or replace function public.platform_get_whatsapp_health_v517()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_result jsonb;
begin
  if not app.v89_platform_can('automation', 'r') then
    raise exception 'platform automation read access required' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'outbound_enabled', app.platform_feature_enabled('whatsapp_outbound'),
    'credit_charging_enabled', app.platform_feature_enabled('whatsapp_credit_charging_enabled'),
    'webhook', jsonb_build_object(
      -- Counts only. Nothing here can identify a customer or a business.
      'total_recorded', count(*),
      'distinct_senders', count(distinct event.phone_number_id),
      'distinct_wabas', count(distinct event.waba_id),
      'retried_by_meta', count(*) filter (where event.received_count > 1),
      'unverified_signature', count(*) filter (where not event.signature_verified),
      'by_status', coalesce(
        (select jsonb_object_agg(grouped.processing_status, grouped.n)
           from (select inner_event.processing_status, count(*) as n
                   from public.whatsapp_webhook_events inner_event
                  group by inner_event.processing_status) grouped),
        '{}'::jsonb),
      'recorded_last_24h', count(*) filter (where event.last_received_at >= now() - interval '24 hours'),
      -- Named for exactly what it measures: a delivery Meta made that we STORED.
      -- A 503 for an unconfigured app secret never reaches this table.
      'last_recorded_at', max(event.last_received_at)
    )
  )
  into v_result
  from public.whatsapp_webhook_events event;

  return v_result;
end
$$;

revoke all on function public.platform_get_whatsapp_health_v517()
  from public, anon, authenticated;
-- Matches the live proacl of every sibling platform reader
-- (platform_get_automation_billing_v89, platform_list_sector_entitlements_v75):
-- authenticated + service_role, with the real gate INSIDE the function.
grant execute on function public.platform_get_whatsapp_health_v517() to authenticated, service_role;

comment on function public.platform_get_whatsapp_health_v517() is
  'v517 superadmin WhatsApp health. Aggregates only over public.whatsapp_webhook_events, which is otherwise unreadable through the API. Gated on app.v89_platform_can(''automation'',''r''). Exposes no payload, phone number or customer identifier.';

commit;
