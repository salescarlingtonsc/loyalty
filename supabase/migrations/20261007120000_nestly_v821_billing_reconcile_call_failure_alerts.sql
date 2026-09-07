-- NESTLY v821 — a failing nightly reconciliation call is visible EVERY night it fails, and a
-- reconciliation that simply stops running raises an alert of its own.
--
-- WHAT WENT WRONG. nestly_v791 restored the Stripe reconciler edge function with a named import
-- (drainBoundedProviderPages) that nestly_v755 had deleted from
-- supabase/functions/_shared/billing-reconciliation.ts. The deployed worker therefore failed at
-- boot, and public.platform_billing_reconcile_calls_v634 recorded status_code=503,
-- outcome='failed', body {"code":"BOOT_ERROR"} on 2026-09-05 and 2026-09-06 (and transport
-- timeouts on 2026-09-04). Platform billing had not reconciled against Stripe for three nights.
--
-- WHAT THE DETECTOR ACTUALLY DID — read from production before writing a line of this migration,
-- because the reported symptom and the real defect were not the same thing.
-- app.check_billing_reconcile_calls_v634() DID raise: alert 6c231a6c-… kind 'reconcile_failed',
-- object_id 'reconcile', is OPEN. What it did NOT do is make the ongoing-ness visible. nestly_v634
-- deliberately keeps ONE open 'reconcile_failed' row and refreshes its `detail` ("a nightly job
-- that fails every night must not create a nightly row"), so:
--
--   * the row's created_at froze at 2026-09-04 18:05 and never moved, while the console's
--     "Raised" column is created_at — three consecutive failed nights read on screen as one
--     four-day-old complaint that might already be over;
--   * nothing anywhere counts the failures, so "it failed once and nobody has looked" and "it
--     has failed every night since Friday" are the same picture;
--   * and the whole mechanism is downstream of a call HAPPENING. If cron job
--     nestly-v624-billing-reconcile were unscheduled, paused, or its net.http_post never
--     returned a request id, no call row would exist, nothing would settle, and NO alert of any
--     kind would ever be raised. Silence and health were indistinguishable.
--
-- WHAT THIS MIGRATION DOES. Two new alert kinds beside the existing one, which is left exactly
-- as nestly_v634 designed it:
--
--   1. 'reconcile_call_failed' — raised by app.check_billing_reconcile_calls_v634() whenever a
--      reconciliation CALL settles 'failed' or 'unknown' (a 5xx such as the BOOT_ERROR 503, a
--      transport error, a timeout, or a request pg_net has no response for). DEDUPLICATED PER
--      UTC DAY: object_id is 'reconcile:YYYY-MM-DD' taken from the call's requested_at, so the
--      existing partial unique index platform_billing_alerts_v624_open_key (kind, object_id)
--      WHERE resolved_at IS NULL admits exactly one open row per day and a second failure that
--      same day refreshes it instead. Three failed nights are now three rows with three
--      truthful Raised dates, and the count is the outage's length.
--
--   2. 'reconcile_stale' — raised by app.detect_billing_alerts_v624() (which cron runs every six
--      hours) when cron job nestly-v624-billing-reconcile is ACTIVE and there has been no call
--      with outcome='succeeded' in the last 36 hours. 36 hours, not 24: the job runs nightly at
--      19:30 UTC and its receipt is settled at 19:55, so a 24-hour window would alarm on a
--      perfectly healthy estate every evening between the six-hourly detector pass and that
--      night's run. 36 hours skips exactly one scheduled night and no more. One open row at a
--      time (object_id 'reconcile') — this is a standing condition, not a per-occurrence event,
--      and it clears itself the moment a run succeeds. Gated on the job being active so a
--      deliberately unscheduled reconciler (a paused estate, a restore) does not nag.
--
-- Both new kinds join 'reconcile_failed' and 'reconcile_unconfigured' in the existing self-heal
-- loop: a 2xx call resolves every open reconciliation alert with the same note and the same
-- BILLING_ALERT_AUTORESOLVED_V634 audit row, so a fixed deploy silences all of them at once and
-- nobody hand-resolves a stale complaint.
--
-- THE ONE SCHEMA CHANGE. public.platform_billing_alerts_v624.kind carries a CHECK allowlist of
-- the seven kinds that existed before today. A new kind is therefore not a naming choice: an
-- insert of an unlisted kind raises 23514, and because that insert happens INSIDE
-- app.check_billing_reconcile_calls_v634(), the whole settle-and-raise pass would roll back and
-- take the existing alerting down with it. Section 1b widens that allowlist to nine, restating
-- the full set rather than patching it.
--
-- WHAT THIS MIGRATION DOES NOT TOUCH. app.run_billing_reconcile_call_v624() (the dispatcher and
-- its 'reconcile_unconfigured' vault check), public.platform_billing_alerts_v624's columns,
-- indexes, RLS and grants, the 'reconcile_failed' contract itself, the four cron schedules, and
-- every other detector block inside app.detect_billing_alerts_v624() — those five blocks are
-- restated below character-for-character from the live production definition read on
-- 2026-09-07, because this function is replaced whole rather than patched.
--
-- FORM. Both functions are restated in full (CREATE OR REPLACE, same signature, same
-- SECURITY DEFINER, same pinned search_path) rather than patched by extract-and-diff. The
-- pre-flight $v821_pre$ block below is what makes a full restatement safe: it asserts that the
-- live body about to be replaced is the one this migration was written against, by requiring the
-- comment-free anchors of every block being carried forward to be present exactly once. If
-- production has drifted, this migration refuses rather than silently reverting somebody's work.
--
-- ACCEPTANCE: db/tests/v821_billing_reconcile_call_failure_alerts.sql (and the identical
-- db/tests/executed/ copy). Replay: LC_ALL=C node scripts/db-tests/run.mjs --migrated-only --filter=v821

begin;

set local search_path = pg_catalog, public, app, pg_temp;

-- ============================================================================================
-- 1 · PRE-FLIGHT — the live bodies are the ones this migration was written against.
-- ============================================================================================
do $v821_pre$
declare
  v_check text;
  v_detect text;
begin
  select pg_get_functiondef(p.oid) into v_check
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'check_billing_reconcile_calls_v634';
  if v_check is null then
    raise exception 'v821: app.check_billing_reconcile_calls_v634() is not present -- nestly_v634 must be applied first';
  end if;

  select pg_get_functiondef(p.oid) into v_detect
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'detect_billing_alerts_v624';
  if v_detect is null then
    raise exception 'v821: app.detect_billing_alerts_v624() is not present -- nestly_v624 must be applied first';
  end if;

  /* The settle-and-raise machinery this migration extends. */
  if position('''reconcile_failed'', ''reconcile''' in v_check) = 0
     or position('app.check_billing_reconcile_calls_v634()' in v_detect) = 0
  then
    raise exception 'v821: the live reconciliation-alert bodies are not the ones v821 was written '
      'against -- production has drifted; re-read pg_get_functiondef before replacing them';
  end if;

  /* The five detector blocks carried forward verbatim. If any has changed name, this migration
     would silently revert it. */
  if position('''checkout_unresolved''' in v_detect) = 0
     or position('''event_stuck''' in v_detect) = 0
     or position('''payment_failed''' in v_detect) = 0
     or position('''branch_awaiting''' in v_detect) = 0
     or position('''manual_request_open''' in v_detect) = 0
  then
    raise exception 'v821: app.detect_billing_alerts_v624() does not carry the five detector '
      'blocks v821 restates -- refusing to replace it whole';
  end if;

  /* The kind allowlist this migration widens. */
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.platform_billing_alerts_v624'::regclass
       and conname = 'platform_billing_alerts_v624_kind_check'
       and position('''reconcile_failed''' in pg_get_constraintdef(oid)) > 0)
  then
    raise exception 'v821: platform_billing_alerts_v624_kind_check is missing or is not the '
      'allowlist v821 was written against';
  end if;

  /* The per-day dedup depends entirely on this index existing. */
  if not exists (
    select 1 from pg_indexes
     where schemaname = 'public'
       and tablename = 'platform_billing_alerts_v624'
       and indexname = 'platform_billing_alerts_v624_open_key')
  then
    raise exception 'v821: platform_billing_alerts_v624_open_key is missing -- the per-day '
      'deduplication of reconcile_call_failed has nothing to conflict on';
  end if;
end
$v821_pre$;

-- ============================================================================================
-- 1b · THE KIND ALLOWLIST. public.platform_billing_alerts_v624.kind carries a CHECK allowlist,
--      so a new kind is not a naming choice — an insert of an unlisted kind raises 23514, which
--      inside app.check_billing_reconcile_calls_v634() would roll back the settle-and-raise pass
--      whole and take the EXISTING alerting down with it. The allowlist is restated in full (the
--      seven live kinds plus the two v821 adds) rather than patched, so this line is the one
--      place the set is written down.
-- ============================================================================================
alter table public.platform_billing_alerts_v624
  drop constraint platform_billing_alerts_v624_kind_check;
alter table public.platform_billing_alerts_v624
  add constraint platform_billing_alerts_v624_kind_check
  check (kind = any (array[
    'checkout_unresolved'::text,
    'event_stuck'::text,
    'payment_failed'::text,
    'branch_awaiting'::text,
    'manual_request_open'::text,
    'reconcile_unconfigured'::text,
    'reconcile_failed'::text,
    'reconcile_call_failed'::text,
    'reconcile_stale'::text
  ]));

-- ============================================================================================
-- 2 · app.check_billing_reconcile_calls_v634() — settle each pending call, and raise BOTH the
--     standing complaint (unchanged) and a per-day record of this particular failure.
-- ============================================================================================
create or replace function app.check_billing_reconcile_calls_v634()
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_call record;
  v_response record;
  v_raised integer := 0;
  v_succeeded boolean := false;
  v_outcome text;
  v_detail jsonb;
  v_alert record;
  v_day text;
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

      /* v821: and ONE row PER DAY beside it, so the length of an outage is readable. The
         standing 'reconcile_failed' row above keeps the created_at of the FIRST failure
         forever, which is why three consecutive BOOT_ERROR nights (2026-09-04..06) looked on
         screen like a single four-day-old complaint. The day comes from the call's own
         requested_at in UTC, not from now(), so a receipt settled after midnight is still
         attributed to the night it was dispatched. */
      v_day := to_char((v_call.requested_at at time zone 'UTC')::date, 'YYYY-MM-DD');
      insert into public.platform_billing_alerts_v624 (kind, object_id, detail)
      values ('reconcile_call_failed', 'reconcile:' || v_day,
              v_detail || jsonb_build_object('outcome', v_outcome, 'call_id', v_call.id,
                                             'requested_at', v_call.requested_at,
                                             'utc_day', v_day))
      on conflict (kind, object_id) where resolved_at is null
      do update set detail = excluded.detail;
      v_raised := v_raised + 1;
    end if;
  end loop;

  if v_succeeded then
    /* Self-healing: the config was fixed, so the standing complaint is superseded. v821 adds the
       two new reconciliation kinds to the same sweep — one green run clears the whole family, or
       an operator would be left hand-resolving a per-day backlog of already-fixed nights. */
    for v_alert in
      select id, kind from public.platform_billing_alerts_v624
       where kind in ('reconcile_failed', 'reconcile_unconfigured',
                      'reconcile_call_failed', 'reconcile_stale')
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
$function$;

-- ============================================================================================
-- 3 · app.detect_billing_alerts_v624() — the five existing blocks, restated character-for-
--     character from the live definition, plus the staleness detector.
-- ============================================================================================
create or replace function app.detect_billing_alerts_v624()
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_inserted integer := 0;
  v_row integer;
  v_last_success timestamptz;
  v_job_active boolean;
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

  /* v821 — reconcile_stale: the reconciler is SUPPOSED to run and has not come back green.
     Every alert above (and every reconcile_failed) is downstream of a call actually happening.
     A reconciler that stopped being called — an unscheduled or paused cron job, an http_post
     that never produced a request id, an edge function that answers nothing at all — produced
     no call row, settled nothing, and raised nothing: silence read as health. This asks the
     opposite question, of the record rather than of an event.

     36 hours, not 24: the job is nightly at 19:30 UTC and its receipt settles at 19:55, while
     this detector runs every six hours. A 24-hour window would fire on a healthy estate every
     evening in the gap between the last detector pass and that night's run. 36 hours tolerates
     exactly one skipped night and no more.

     Gated on the job being ACTIVE: an estate that has deliberately unscheduled or paused the
     reconciler (a restore, a maintenance window, cron.alter_job(active => false)) is not
     failing, and an alert nobody can action is noise that teaches operators to ignore the
     panel. */
  select coalesce(bool_or(j.active), false) into v_job_active
    from cron.job j
   where j.jobname = 'nestly-v624-billing-reconcile';

  select max(c.requested_at) into v_last_success
    from public.platform_billing_reconcile_calls_v634 c
   where c.outcome = 'succeeded';

  if v_job_active
     and (v_last_success is null or v_last_success < now() - interval '36 hours')
  then
    insert into public.platform_billing_alerts_v624 (kind, object_id, detail)
    values ('reconcile_stale', 'reconcile',
            jsonb_build_object(
              'why', 'no successful billing reconciliation call in the last 36 hours',
              'job', 'nestly-v624-billing-reconcile',
              'last_success_at', v_last_success,
              'hours_since_success',
                case when v_last_success is null then null
                     else round(extract(epoch from (now() - v_last_success)) / 3600.0, 1)
                end))
    on conflict (kind, object_id) where resolved_at is null
    do update set detail = excluded.detail;
    get diagnostics v_row = row_count; v_inserted := v_inserted + v_row;
  end if;

  return v_inserted;
end
$function$;

-- ============================================================================================
-- 4 · ACLs restated, not assumed. Both are cron-only maintenance entry points: nothing but the
--     job owner may call them, and a same-signature CREATE OR REPLACE must not have widened
--     that. (Live production ACL before this migration: postgres=X/postgres on both.)
-- ============================================================================================
revoke all on function app.check_billing_reconcile_calls_v634() from public, anon, authenticated;
revoke all on function app.detect_billing_alerts_v624() from public, anon, authenticated;

do $v821_acl$
begin
  if pg_catalog.has_function_privilege('anon', 'app.check_billing_reconcile_calls_v634()', 'execute')
     or pg_catalog.has_function_privilege('authenticated', 'app.check_billing_reconcile_calls_v634()', 'execute')
     or pg_catalog.has_function_privilege('anon', 'app.detect_billing_alerts_v624()', 'execute')
     or pg_catalog.has_function_privilege('authenticated', 'app.detect_billing_alerts_v624()', 'execute')
  then
    raise exception 'v821: a tenant-facing role can execute a billing maintenance function';
  end if;
end
$v821_acl$;

-- ============================================================================================
-- 5 · IN-TRANSACTION VERIFICATION — behaviour, not source text.
--
--     Every fixture below is written inside a PL/pgSQL SUB-TRANSACTION that is ALWAYS rolled
--     back. This is not tidiness, it is safety: the fixtures upsert onto the SAME
--     (kind, object_id) rows production already holds — production is carrying an open
--     'reconcile_failed' / 'reconcile' row from the real BOOT_ERROR outage — and the green-run
--     fixture auto-resolves every open reconciliation alert. Deleting the fixtures afterwards
--     could not undo that: the upsert had already overwritten a real alert's detail, the
--     resolution had already been written, and a delete keyed on the fixture call ids would
--     have removed the GENUINE outage row. A migration must never edit, resolve, or garbage-
--     collect real alert or audit rows. So the whole scenario runs to its last assertion and is
--     then thrown away wholesale by raising the P0821 sentinel, which the handler swallows.
--     A real assertion failure raises P0001 (or any other errcode), is NOT caught, and aborts
--     the migration exactly as before.
-- ============================================================================================
do $v821_verify$
declare
  v_req_a bigint;
  v_req_b bigint;
  v_call_a uuid;
  v_call_b uuid;
  v_day_a text;
  v_day_b text;
  v_n integer;
  v_job_active boolean;
  v_alerts_before bigint;
  v_calls_before bigint;
  v_audit_before bigint;
  v_alerts_after bigint;
  v_calls_after bigint;
  v_audit_after bigint;
begin
  /* Captured OUTSIDE the sub-transaction, so the leak check below is measured against the
     production state this migration found, not against anything the fixtures created. */
  select count(*) into v_alerts_before from public.platform_billing_alerts_v624;
  select count(*) into v_calls_before from public.platform_billing_reconcile_calls_v634;
  select count(*) into v_audit_before from public.audit_log
   where action = 'BILLING_ALERT_AUTORESOLVED_V634';

  begin
    /* A 503 BOOT_ERROR receipt from two nights ago, and another from last night: the exact shape
       production recorded on 2026-09-05 and 2026-09-06. */
    /* Real pg_net gives net._http_response.id NO default (the worker copies the request id in),
       so a fixture must bring its own id or `returning id` yields NULL and the call insert fails
       its NOT NULL — which is exactly how the first production apply of this file was refused. */
    v_req_a := coalesce((select max(id) from net._http_response), 0) + 900001;
    v_req_b := v_req_a + 1;
    insert into net._http_response (id, status_code, content)
    values (v_req_a, 503, '{"code":"BOOT_ERROR","message":"Function failed to start (please check logs)"}');
    insert into net._http_response (id, status_code, content)
    values (v_req_b, 503, '{"code":"BOOT_ERROR","message":"Function failed to start (please check logs)"}');

    insert into public.platform_billing_reconcile_calls_v634 (net_request_id, requested_at)
    values (v_req_a, now() - interval '48 hours') returning id into v_call_a;
    insert into public.platform_billing_reconcile_calls_v634 (net_request_id, requested_at)
    values (v_req_b, now() - interval '24 hours') returning id into v_call_b;

    v_day_a := to_char(((now() - interval '48 hours') at time zone 'UTC')::date, 'YYYY-MM-DD');
    v_day_b := to_char(((now() - interval '24 hours') at time zone 'UTC')::date, 'YYYY-MM-DD');

    perform app.check_billing_reconcile_calls_v634();

    /* Each failed night has its own open row, with its own truthful Raised date. */
    select count(*) into v_n
      from public.platform_billing_alerts_v624
     where kind = 'reconcile_call_failed'
       and resolved_at is null
       and object_id in ('reconcile:' || v_day_a, 'reconcile:' || v_day_b);
    if v_n <> (case when v_day_a = v_day_b then 1 else 2 end) then
      raise exception 'v821 verify: a 503 BOOT_ERROR reconciliation call did not raise one '
        'reconcile_call_failed alert per UTC day (found %)', v_n;
    end if;

    /* The 503 body reached the alert, not just the outcome word. */
    if not exists (
      select 1 from public.platform_billing_alerts_v624
       where kind = 'reconcile_call_failed'
         and object_id = 'reconcile:' || v_day_b
         and resolved_at is null
         and detail->>'status_code' = '503'
         and detail->>'outcome' = 'failed'
         and detail->>'call_id' = v_call_b::text)
    then
      raise exception 'v821 verify: the reconcile_call_failed alert does not carry the 503 receipt';
    end if;

    /* The standing nestly_v634 complaint still exists and is still ONE row — whether or not this
       estate already held an open one before the fixtures ran. The count is exactly 1 either way,
       and the row we are looking at is the one the FIXTURE upsert path produced: its detail
       carries the last failed fixture call (calls settle in requested_at order, so v_call_b is
       the one that wrote it). Asserting the detail, not just the count, is what stops a
       pre-existing production row from satisfying this check on its own. */
    select count(*) into v_n
      from public.platform_billing_alerts_v624
     where kind = 'reconcile_failed' and resolved_at is null;
    if v_n <> 1 then
      raise exception 'v821 verify: the nestly_v634 one-open-row reconcile_failed contract broke '
        '(found % open rows)', v_n;
    end if;
    if not exists (
      select 1 from public.platform_billing_alerts_v624
       where kind = 'reconcile_failed'
         and object_id = 'reconcile'
         and resolved_at is null
         and detail->>'call_id' = v_call_b::text)
    then
      raise exception 'v821 verify: the single open reconcile_failed row was not refreshed by the '
        'newest failed call — the one-open-row upsert path did not run';
    end if;

    /* Staleness: with the job active and no successful call in the record, the detector complains
       about the silence itself. */
    select coalesce(bool_or(j.active), false) into v_job_active
      from cron.job j where j.jobname = 'nestly-v624-billing-reconcile';
    if v_job_active then
      perform app.detect_billing_alerts_v624();
      if not exists (
        select 1 from public.platform_billing_alerts_v624
         where kind = 'reconcile_stale' and object_id = 'reconcile' and resolved_at is null)
      then
        raise exception 'v821 verify: no successful reconciliation in 36h did not raise '
          'reconcile_stale while nestly-v624-billing-reconcile is active';
      end if;
    end if;

    /* A green run supersedes the whole family, per-day rows included. */
    v_req_a := v_req_b + 1;
    insert into net._http_response (id, status_code, content)
    values (v_req_a, 200, '{"status":"clean"}');
    insert into public.platform_billing_reconcile_calls_v634 (net_request_id)
    values (v_req_a) returning id into v_call_a;
    perform app.check_billing_reconcile_calls_v634();

    select count(*) into v_n
      from public.platform_billing_alerts_v624
     where kind in ('reconcile_failed', 'reconcile_call_failed', 'reconcile_stale')
       and resolved_at is null;
    if v_n <> 0 then
      raise exception 'v821 verify: a successful reconciliation left % reconciliation alert(s) open', v_n;
    end if;

    /* Every assertion passed. Throw the whole scenario away — fixtures, upserted details,
       auto-resolutions and their audit rows — by failing the sub-transaction on purpose. */
    raise exception 'v821 verify: rollback sentinel' using errcode = 'P0821';
  exception
    when sqlstate 'P0821' then
      null;  -- expected: assertions all passed, fixtures rolled back
  end;

  /* Nothing leaked. If the sub-transaction had not rolled back — or had rolled back only
     partially — one of these three counts would differ from the state captured above. */
  select count(*) into v_alerts_after from public.platform_billing_alerts_v624;
  select count(*) into v_calls_after from public.platform_billing_reconcile_calls_v634;
  select count(*) into v_audit_after from public.audit_log
   where action = 'BILLING_ALERT_AUTORESOLVED_V634';

  if v_alerts_after <> v_alerts_before then
    raise exception 'v821 verify: the verification block leaked billing alert rows (% before, % after)',
      v_alerts_before, v_alerts_after;
  end if;
  if v_calls_after <> v_calls_before then
    raise exception 'v821 verify: the verification block leaked reconcile call rows (% before, % after)',
      v_calls_before, v_calls_after;
  end if;
  if v_audit_after <> v_audit_before then
    raise exception 'v821 verify: the verification block leaked BILLING_ALERT_AUTORESOLVED_V634 '
      'audit rows (% before, % after)', v_audit_before, v_audit_after;
  end if;

  raise notice 'v821: reconcile_call_failed (per UTC day) and reconcile_stale (36h) verified in '
    'a rolled-back sub-transaction; production state unchanged';
end
$v821_verify$;

commit;
