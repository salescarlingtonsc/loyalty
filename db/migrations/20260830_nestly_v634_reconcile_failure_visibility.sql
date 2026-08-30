-- NESTLY v634 — a reconciliation run that does not happen must be visible.
--
-- v624 gave stripe-billing-reconcile a schedule but fired it and forgot it:
-- app.run_billing_reconcile_call_v624 called net.http_post and discarded the request id, so the
-- HTTP result was never read by anything. Production proved the cost within a day — the first
-- real invocation returned 401 reconciliation_authentication_required (the vault copy of the
-- shared secret did not match the edge function's BILLING_RECONCILIATION_SECRET) and NOTHING
-- recorded it: no alert, no row, nothing on the health page. The nightly job would have failed
-- silently forever. That is precisely the class of silent failure v624 existed to end, so it is
-- closed here rather than left as a known gap.
--
-- Shape:
--   · every call is now recorded in platform_billing_reconcile_calls_v634 with its pg_net
--     request id and an outcome that starts at 'pending';
--   · app.check_billing_reconcile_calls_v634() reads net._http_response and settles each pending
--     call — 2xx is 'succeeded', anything else (including a transport error or a timeout) is
--     'failed', and a call with no response row after 2 hours is 'unknown';
--   · 'failed' and 'unknown' raise ONE open alert (kind='reconcile_failed', object_id='reconcile'
--     — a singleton, so a repeatedly failing nightly job cannot spam the queue; the detail is
--     refreshed in place with the latest status and call id);
--   · a later success RESOLVES any open reconcile_failed / reconcile_unconfigured alert as
--     superseded, with an audit row, so the health page self-heals once the config is fixed.
--
-- Timing: pg_net discards responses after 6 hours (pg_net.ttl), so the checker runs on its own
-- cron 25 minutes after the reconcile job, and is ALSO called by the 6-hourly v624 detector so a
-- manually triggered call is settled without waiting for the nightly slot. 'unknown' after two
-- hours is deliberate and fail-closed: a run whose result we cannot see is not a run we may
-- report as healthy.

begin;

-- ---------------------------------------------------------------------------
-- 1 · The alert vocabulary learns the new kind.
-- ---------------------------------------------------------------------------
alter table public.platform_billing_alerts_v624
  drop constraint platform_billing_alerts_v624_kind_check;
alter table public.platform_billing_alerts_v624
  add constraint platform_billing_alerts_v624_kind_check
  check (kind in (
    'checkout_unresolved', 'event_stuck', 'payment_failed', 'branch_awaiting',
    'manual_request_open', 'reconcile_unconfigured', 'reconcile_failed'));

-- ---------------------------------------------------------------------------
-- 2 · The call ledger.
-- ---------------------------------------------------------------------------
create table if not exists public.platform_billing_reconcile_calls_v634 (
  id uuid primary key default gen_random_uuid(),
  net_request_id bigint not null,
  requested_at timestamptz not null default now(),
  checked_at timestamptz,
  status_code integer,
  outcome text not null default 'pending'
    check (outcome in ('pending', 'succeeded', 'failed', 'unknown')),
  detail jsonb not null default '{}'::jsonb
);
alter table public.platform_billing_reconcile_calls_v634 enable row level security;
revoke all on public.platform_billing_reconcile_calls_v634 from public, anon, authenticated;
create index if not exists platform_billing_reconcile_calls_v634_pending
  on public.platform_billing_reconcile_calls_v634(requested_at) where outcome = 'pending';

-- ---------------------------------------------------------------------------
-- 3 · The caller now keeps its receipt. Behaviour is otherwise identical to
--     v624, including the unconfigured-vault alert.
-- ---------------------------------------------------------------------------
create or replace function app.run_billing_reconcile_call_v624()
returns void
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_url text;
  v_secret text;
  v_request_id bigint;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'v176_supabase_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'v624_reconcile_secret';
  if v_url is null or v_secret is null then
    insert into public.platform_billing_alerts_v624 (kind, object_id, detail)
    values ('reconcile_unconfigured', 'vault',
            jsonb_build_object('missing_url', v_url is null, 'missing_secret', v_secret is null))
    on conflict do nothing;
    return;
  end if;
  select net.http_post(
    url := v_url || '/functions/v1/stripe-billing-reconcile',
    headers := jsonb_build_object(
      'content-type', 'application/json',
      'x-nestly-reconciliation-secret', v_secret
    ),
    body := '{}'::jsonb
  ) into v_request_id;
  /* v634: the receipt. Without this row the HTTP result is unobservable. */
  insert into public.platform_billing_reconcile_calls_v634 (net_request_id)
  values (v_request_id);
end
$$;
revoke all on function app.run_billing_reconcile_call_v624() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4 · The checker: settle pending calls, raise or clear the singleton alert.
-- ---------------------------------------------------------------------------
create or replace function app.check_billing_reconcile_calls_v634()
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_call record;
  v_response record;
  v_raised integer := 0;
  v_succeeded boolean := false;
  v_outcome text;
  v_detail jsonb;
  v_alert record;
begin
  for v_call in
    select * from public.platform_billing_reconcile_calls_v634
     where outcome = 'pending'
     order by requested_at
  loop
    select r.status_code, r.timed_out, r.error_msg, left(coalesce(r.content, ''), 500) as content
      into v_response
      from net._http_response r
     where r.id = v_call.net_request_id;

    if not found then
      /* No response row. Before two hours it may simply not have returned yet; after that we
         cannot tell "expired" from "never answered", and an unverifiable run is not a healthy
         one. pg_net keeps responses for 6 hours, so this threshold sits well inside the window. */
      if v_call.requested_at >= now() - interval '2 hours' then
        continue;
      end if;
      v_outcome := 'unknown';
      v_detail := jsonb_build_object(
        'why', 'no pg_net response row was found for this request',
        'net_request_id', v_call.net_request_id);
    elsif coalesce(v_response.timed_out, false) then
      v_outcome := 'failed';
      v_detail := jsonb_build_object('why', 'the reconciliation request timed out',
                                     'net_request_id', v_call.net_request_id);
    elsif v_response.error_msg is not null then
      v_outcome := 'failed';
      v_detail := jsonb_build_object('why', 'transport error', 'error', v_response.error_msg,
                                     'net_request_id', v_call.net_request_id);
    elsif v_response.status_code between 200 and 299 then
      v_outcome := 'succeeded';
      v_detail := jsonb_build_object('status_code', v_response.status_code,
                                     'body', v_response.content);
      v_succeeded := true;
    else
      v_outcome := 'failed';
      v_detail := jsonb_build_object('status_code', v_response.status_code,
                                     'body', v_response.content,
                                     'net_request_id', v_call.net_request_id);
    end if;

    update public.platform_billing_reconcile_calls_v634
       set outcome = v_outcome,
           checked_at = now(),
           status_code = v_response.status_code,
           detail = v_detail
     where id = v_call.id;

    if v_outcome in ('failed', 'unknown') then
      /* ONE open alert at a time — a nightly job that fails every night must not create a
         nightly row. The detail is refreshed so the newest failure is the one on screen. */
      insert into public.platform_billing_alerts_v624 (kind, object_id, detail)
      values ('reconcile_failed', 'reconcile',
              v_detail || jsonb_build_object('outcome', v_outcome, 'call_id', v_call.id,
                                             'requested_at', v_call.requested_at))
      on conflict (kind, object_id) where resolved_at is null
      do update set detail = excluded.detail;
      v_raised := v_raised + 1;
    end if;
  end loop;

  if v_succeeded then
    /* Self-healing: the config was fixed, so the standing complaint is superseded. */
    for v_alert in
      select id, kind from public.platform_billing_alerts_v624
       where kind in ('reconcile_failed', 'reconcile_unconfigured')
         and resolved_at is null
    loop
      update public.platform_billing_alerts_v624
         set resolved_at = now(),
             resolution_note = 'superseded by a successful reconciliation run'
       where id = v_alert.id;
      insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
      values (null, null, 'BILLING_ALERT_AUTORESOLVED_V634', 'platform_billing_alerts_v624',
              v_alert.id,
              jsonb_build_object('kind', v_alert.kind,
                                 'why', 'a later reconciliation call returned 2xx'));
    end loop;
  end if;

  return v_raised;
end
$$;
revoke all on function app.check_billing_reconcile_calls_v634() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5 · The v624 detector settles pending calls too, so a manual trigger is
--     never left unobserved until the nightly slot. Byte-faithful re-emission
--     of the live v624 body with one added block; the returned count now
--     includes reconciliation alerts, which is what "how many did you raise"
--     is supposed to mean.
-- ---------------------------------------------------------------------------
create or replace function app.detect_billing_alerts_v624()
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_inserted integer := 0;
  v_row integer;
begin
  -- v634: settle any pending reconciliation call before reporting on billing health.
  v_inserted := v_inserted + app.check_billing_reconcile_calls_v634();

  -- checkout_unresolved: a live checkout was minted, then silence.
  insert into public.platform_billing_alerts_v624 (kind, business_id, object_id, detail)
  select 'checkout_unresolved', cmd.business_id, cmd.provider_object_id,
         jsonb_build_object('command_id', cmd.id, 'requested_at', cmd.requested_at,
                            'cadence', cmd.requested_cadence)
    from public.billing_commands cmd
    left join public.subscriptions sub on sub.business_id = cmd.business_id
   where cmd.command_type = 'create_checkout'
     and cmd.status = 'completed'
     and cmd.provider_object_id is not null
     and cmd.requested_at < now() - interval '24 hours'
     and coalesce(sub.payment_status, 'not_collected') <> 'paid'
  on conflict do nothing;
  get diagnostics v_row = row_count; v_inserted := v_inserted + v_row;

  -- event_stuck: the durable inbox is holding an event the redrive could not finish.
  insert into public.platform_billing_alerts_v624 (kind, business_id, object_id, detail)
  select 'event_stuck', ev.business_id, ev.event_id,
         jsonb_build_object('event_type', ev.event_type, 'processing_status', ev.processing_status,
                            'attempts', ev.processing_attempts)
    from public.billing_provider_events ev
   where ev.processing_status in ('failed', 'processing')
     and ev.received_at < now() - interval '1 hour'
  on conflict do nothing;
  get diagnostics v_row = row_count; v_inserted := v_inserted + v_row;

  -- payment_failed: Stripe told us collection is in trouble.
  insert into public.platform_billing_alerts_v624 (kind, business_id, object_id, detail)
  select 'payment_failed', sub.business_id, sub.business_id::text,
         jsonb_build_object('payment_status', sub.payment_status, 'next_payment_at', sub.next_payment_at)
    from public.subscriptions sub
   where sub.payment_status in ('failed', 'action_required')
  on conflict do nothing;
  get diagnostics v_row = row_count; v_inserted := v_inserted + v_row;

  -- branch_awaiting: an inactive pending_payment shell has waited a day.
  insert into public.platform_billing_alerts_v624 (kind, business_id, object_id, detail)
  select 'branch_awaiting', b.business_id, b.id::text,
         jsonb_build_object('branch_name', b.name, 'since', b.updated_at)
    from public.branches b
   where b.billing_state = 'pending_payment'
     and not b.active
     and b.updated_at < now() - interval '24 hours'
  on conflict do nothing;
  get diagnostics v_row = row_count; v_inserted := v_inserted + v_row;

  -- manual_request_open: a tenant asked to pay and has been waiting a day.
  insert into public.platform_billing_alerts_v624 (kind, business_id, object_id, detail)
  select 'manual_request_open', req.business_id, req.id::text,
         jsonb_build_object('requested_at', req.created_at, 'contact_phone', req.contact_phone)
    from public.business_manual_payment_requests_v542 req
   where req.status = 'open'
     and req.created_at < now() - interval '24 hours'
  on conflict do nothing;
  get diagnostics v_row = row_count; v_inserted := v_inserted + v_row;

  return v_inserted;
end
$$;
revoke all on function app.detect_billing_alerts_v624() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6 · Its own schedule, 25 minutes after the reconcile job, inside pg_net's
--     6-hour response window and clear of the other 19:xx sweeps.
-- ---------------------------------------------------------------------------
select cron.schedule(
  'nestly-v634-reconcile-check',
  '55 19 * * *',
  $$select app.check_billing_reconcile_calls_v634()$$
);

commit;
