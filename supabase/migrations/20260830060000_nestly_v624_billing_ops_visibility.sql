-- NESTLY v624 — billing operations become visible: the manual-payment queue gets a reader,
-- correlated billing anomalies become durable alert rows, and the reconciliation edge function
-- finally gets a schedule.
--
-- 1 · business_manual_payment_requests_v542 was written by tenants and readable by NOBODY
--     through any shipped surface (the v542 comment said "the Super Admin reads it with the
--     service role" — no such reader existed). platform_list_manual_payment_requests_v624
--     serves the console's Subscription-operations page.
--
-- 2 · Alerting is CORRELATED, not "no events in N hours = outage" (payment volume is far too
--     low for that). An alert row is raised when specific evidence disagrees:
--       checkout_unresolved   — a create_checkout command completed >24h ago, and the business
--                               still has no paid truth (the live drift: 6 checkouts, 0 events);
--       event_stuck           — a webhook event sits failed / processing for >1h despite the
--                               v281 redrive;
--       payment_failed        — subscriptions.payment_status is failed / action_required;
--       branch_awaiting       — an inactive pending_payment branch is >24h old;
--       manual_request_open   — a tenant's manual-payment request has waited >24h.
--     Deduped by (kind, object_id) while unresolved; resolving is an audited platform action.
--     Detection runs every 6 hours by cron. No Stripe network calls anywhere in it.
--
-- 3 · stripe-billing-reconcile (evidence-only drift detector) had no scheduler anywhere.
--     A daily pg_cron + pg_net call now drives it, using the v176 vault pattern
--     (v176_supabase_url) plus a new v624_reconcile_secret that must equal the function's
--     BILLING_RECONCILIATION_SECRET. The vault secret is seeded by the operator alongside this
--     migration (never committed); the cron no-ops with an alert row if the secret is absent.

begin;

-- ---------------------------------------------------------------------------
-- 1 · Manual-payment request queue reader.
-- ---------------------------------------------------------------------------
create or replace function public.platform_list_manual_payment_requests_v624(p_status text default null)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if not (app.is_super_admin() or app.v89_platform_can('billing', 'r')) then
    raise exception 'billing read access required' using errcode = '42501';
  end if;
  if p_status is not null and p_status not in ('open', 'superseded', 'actioned', 'withdrawn') then
    raise exception 'unknown status filter' using errcode = '22023';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', req.id,
             'business_id', req.business_id,
             'business_name', biz.name,
             'status', req.status,
             'contact_phone', req.contact_phone,
             'note', req.note,
             'requested_at', req.created_at,
             'superseded_at', req.superseded_at,
             'actioned_at', req.actioned_at,
             'subscription_status', sub.status,
             'payment_status', sub.payment_status
           ) order by req.created_at desc)
      from public.business_manual_payment_requests_v542 req
      join public.businesses biz on biz.id = req.business_id
      left join public.subscriptions sub on sub.business_id = req.business_id
     where p_status is null or req.status = p_status
  ), '[]'::jsonb);
end
$$;
revoke all on function public.platform_list_manual_payment_requests_v624(text) from public, anon;
grant execute on function public.platform_list_manual_payment_requests_v624(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 2 · Durable billing alerts.
-- ---------------------------------------------------------------------------
create table if not exists public.platform_billing_alerts_v624 (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in
    ('checkout_unresolved', 'event_stuck', 'payment_failed', 'branch_awaiting', 'manual_request_open', 'reconcile_unconfigured')),
  business_id uuid references public.businesses(id),
  object_id text not null,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid,
  resolution_note text
);
alter table public.platform_billing_alerts_v624 enable row level security;
revoke all on public.platform_billing_alerts_v624 from public, anon, authenticated;
create unique index if not exists platform_billing_alerts_v624_open_key
  on public.platform_billing_alerts_v624(kind, object_id) where resolved_at is null;

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

create or replace function public.platform_list_billing_alerts_v624(p_include_resolved boolean default false)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if not (app.is_super_admin() or app.v89_platform_can('billing', 'r')
          or app.v89_platform_can('automation', 'r')) then
    raise exception 'billing or automation read access required' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(to_jsonb(alert) order by alert.created_at desc)
      from (
        select a.id, a.kind, a.business_id, biz.name as business_name, a.object_id,
               a.detail, a.created_at, a.resolved_at
          from public.platform_billing_alerts_v624 a
          left join public.businesses biz on biz.id = a.business_id
         where p_include_resolved or a.resolved_at is null
         order by a.created_at desc
         limit 200
      ) alert
  ), '[]'::jsonb);
end
$$;
revoke all on function public.platform_list_billing_alerts_v624(boolean) from public, anon;
grant execute on function public.platform_list_billing_alerts_v624(boolean) to authenticated;

create or replace function public.platform_resolve_billing_alert_v624(p_alert uuid, p_note text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_alert public.platform_billing_alerts_v624%rowtype;
begin
  if not (app.is_super_admin() or app.v89_platform_can('billing', 'rw')) then
    raise exception 'billing write access required' using errcode = '42501';
  end if;
  if length(coalesce(btrim(p_note), '')) < 4 then
    raise exception 'a resolution note is required' using errcode = '22023';
  end if;
  select * into v_alert from public.platform_billing_alerts_v624 where id = p_alert for update;
  if v_alert.id is null then
    raise exception 'alert not found' using errcode = '42704';
  end if;
  if v_alert.resolved_at is not null then
    return jsonb_build_object('id', p_alert, 'already_resolved', true);
  end if;
  update public.platform_billing_alerts_v624
     set resolved_at = now(), resolved_by = auth.uid(), resolution_note = btrim(p_note)
   where id = p_alert;
  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (v_alert.business_id, auth.uid(), 'BILLING_ALERT_RESOLVED_V624', 'platform_billing_alerts_v624', p_alert,
          jsonb_build_object('kind', v_alert.kind, 'note', btrim(p_note)));
  return jsonb_build_object('id', p_alert, 'resolved', true);
end
$$;
revoke all on function public.platform_resolve_billing_alert_v624(uuid, text) from public, anon;
grant execute on function public.platform_resolve_billing_alert_v624(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3 · Schedules. Detection every 6 hours; reconcile daily at 03:30 SGT.
--     The reconcile call no-ops with a durable alert if the vault secret is
--     not seeded, rather than failing silently.
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
  perform net.http_post(
    url := v_url || '/functions/v1/stripe-billing-reconcile',
    headers := jsonb_build_object(
      'content-type', 'application/json',
      'x-nestly-reconciliation-secret', v_secret
    ),
    body := '{}'::jsonb
  );
end
$$;
revoke all on function app.run_billing_reconcile_call_v624() from public, anon, authenticated;

select cron.schedule(
  'nestly-v624-billing-alert-detect',
  '5 */6 * * *',
  $$select app.detect_billing_alerts_v624()$$
);

select cron.schedule(
  'nestly-v624-billing-reconcile',
  '30 19 * * *',
  $$select app.run_billing_reconcile_call_v624()$$
);

commit;
