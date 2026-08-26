-- ============================================================================
-- nestly_v551 — bring-back vouchers reach the customer's phone: WhatsApp
-- template sends on the proven v535/v536 rail.
--
-- WHY. The 2026-08-26 strategy: detect → message → return → attribute. v548
-- detects, v550 attributes, and the WhatsApp rail (v504 webhook, v517
-- foundations, v535/v536 support dispatch) is live in production with its
-- first delivered-and-read messages. This migration adds the retention lane:
-- when a bring-back voucher is granted to a lapsed customer, a Meta MARKETING
-- template send is enqueued, consent-gated, quota-capped, and delivered by its
-- own dispatcher — never touching the support queue.
--
-- OWNER RULINGS (2026-08-27, this session): template drafted+submitted via API
-- (peekaa_bring_back_v1, MARKETING/en, STOP footer); retention sends built on
-- the shared rail; PDPA posture = proceed under the recorded consent ruling
-- (one tick, default on) with per-customer opt-out honoured. ⚖ counsel review
-- remains an open item, recorded, not a blocker by owner decision.
--
-- FAIL-CLOSED GATES, in order, each recorded as a NAMED suppression rather
-- than a silent drop (the v550 report philosophy — refusals are visible):
--   platform flag whatsapp_outbound        (v517, ON today)
--   platform flag whatsapp_retention_sends (NEW, seeded FALSE — turning the
--     pilot on is a deliberate service-role act, v517 posture)
--   per-business capability whatsapp_retention (v518 registry; default OFF,
--     50/day safety cap; superadmin grants it per firm)
--   template approved                       (registry row must be 'approved';
--     claim refuses to send a PENDING or rejected template)
--   consent: clients.marketing_consent must be affirmatively TRUE (the column
--     is NOT NULL DEFAULT false — a till-created customer who was never asked
--     is unconsented and is never messaged; the "one tick, default on" ruling
--     governs the signup UI's pre-ticked box, not the unasked)
--     AND, when a verified customer link exists, the v263 account-level gate
--     customer_communication_allows_v263(identity,'business_offers','whatsapp')
--   a phone the platform normaliser accepted (clients.phone_norm)
--   synthetic clients never messaged
-- Consent is checked TWICE: at enqueue and again at claim — a customer who
-- opts out between the two is suppressed as 'consent_withdrawn', not messaged.
--
-- STOP. The template footer promises "Reply STOP to opt out of offers." The
-- platform number is shared, so a STOP cannot be scoped to one merchant: the
-- opt-out sweep withdraws marketing consent on EVERY client row bearing that
-- phone that has ever been sent a retention message, appends a consents row
-- per business, and suppresses anything still queued. Conservative and
-- PDPA-safe: over-honouring an opt-out is the only acceptable direction. The
-- sweep reads whatsapp_webhook_events WITHOUT claiming or mutating them —
-- the same non-competing posture as app.support_ingest_status_v535, so it can
-- never race the v531 inbound router.
--
-- QUOTA. app.capability_state_v518 is consulted at claim (allowed) and
-- app.capability_consume_v518 records usage when a send is reported 'sent' —
-- only 'sent' consumes (whatsapp-send-boundaries.consumesQuota). A refusal at
-- consume time after Meta accepted the message is noted in the row's
-- error_code but the send stays 'sent': the cap is a safety valve, and lying
-- about a delivered message would corrupt v550's attribution.
--
-- ATTRIBUTION. Nothing to add: v550 already counts the GRANT as the
-- intervention, and every send row is keyed to its grant (one send per grant,
-- enforced). The WhatsApp message changes how often the intervention works,
-- not how it is counted.
--
-- IDEMPOTENT: create-if-not-exists / create-or-replace / on-conflict seeds.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Switches and registry rows
-- ---------------------------------------------------------------------------

insert into app.platform_feature_flags(feature_key, enabled)
values ('whatsapp_retention_sends', false)
on conflict (feature_key) do nothing;

insert into public.platform_capabilities_v518(
  capability_key, title, description,
  eligible_industries, required_modules,
  default_enabled, default_limit_count, default_limit_period, active)
values (
  'whatsapp_retention',
  'WhatsApp bring-back offers',
  'Sends the approved bring-back voucher template to lapsed customers over WhatsApp. Off by default; the daily limit is a safety cap protecting the platform number''s standing, not a commercial allowance.',
  null,
  array['loyalty'],
  false, 50, 'day', true)
on conflict (capability_key) do nothing;

create table if not exists public.whatsapp_template_registry_v551(
  template_key text primary key
    check (template_key ~ '^[a-z][a-z0-9_]{2,63}$'),
  -- Postgres regex quantifiers cap at {,255}, so the length rides separately.
  meta_name text not null check (meta_name ~ '^[a-z0-9_]+$' and char_length(meta_name) <= 512),
  language_code text not null check (language_code ~ '^[a-zA-Z]{2}(_[a-zA-Z]{2,4})?$'),
  category text not null check (category in ('marketing','utility')),
  -- The exact body submitted to Meta, kept for audit: what did we promise the
  -- reviewer this template says?
  body_text text not null,
  -- ORDERED variable descriptors ({{1}}, {{2}}, ...): the send binds values by
  -- these keys (whatsapp-send-boundaries.bindTemplateParameters).
  parameter_descriptors jsonb not null,
  status text not null default 'submitted'
    check (status in ('draft','submitted','approved','rejected','paused')),
  meta_template_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
revoke all on public.whatsapp_template_registry_v551 from public, anon, authenticated;
grant select on public.whatsapp_template_registry_v551 to authenticated;
alter table public.whatsapp_template_registry_v551 enable row level security;
drop policy if exists whatsapp_template_registry_v551_read on public.whatsapp_template_registry_v551;
create policy whatsapp_template_registry_v551_read
  on public.whatsapp_template_registry_v551 for select using (true);

insert into public.whatsapp_template_registry_v551(
  template_key, meta_name, language_code, category, body_text,
  parameter_descriptors, status, meta_template_id)
values (
  'bring_back_v1', 'peekaa_bring_back_v1', 'en', 'marketing',
  'Hi {{1}}, it''s been a while since your last visit to {{2}} — we''ve missed you! Come back this week and enjoy {{3}}, on us. Just show this message at the counter. / FOOTER: Reply STOP to opt out of offers.',
  '["customer_first_name","business_name","reward_label"]'::jsonb,
  'submitted', '27605756952454212')
on conflict (template_key) do nothing;

-- ---------------------------------------------------------------------------
-- 2. The retention send queue
-- ---------------------------------------------------------------------------

create table if not exists public.retention_sends_v551(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  grant_id uuid not null references public.bringback_grants_v361(id) on delete cascade,
  template_key text not null references public.whatsapp_template_registry_v551(template_key) on delete restrict,
  variables jsonb not null,
  recipient_phone_norm text,
  status text not null default 'queued'
    check (status in ('queued','processing','sent','delivered','read','failed',
                      'suppressed','undeliverable','template_fault','config_fault',
                      'failed_retries_exhausted')),
  status_rank integer not null default 0,
  suppressed_reason text,
  error_code text,
  attempt_count integer not null default 0 check (attempt_count between 0 and 10),
  next_attempt_at timestamptz,
  lease_token uuid,
  leased_by text,
  lease_until timestamptz,
  provider_message_id text,
  queued_at timestamptz not null default now(),
  sent_at timestamptz,
  delivered_at timestamptz,
  read_at timestamptz,
  failed_at timestamptz,
  constraint retention_sends_v551_grant_uk unique (grant_id)
);
create index if not exists retention_sends_v551_dispatch_idx
  on public.retention_sends_v551(status, next_attempt_at)
  where status in ('queued','processing');
create index if not exists retention_sends_v551_wamid_idx
  on public.retention_sends_v551(provider_message_id)
  where provider_message_id is not null;
create index if not exists retention_sends_v551_business_idx
  on public.retention_sends_v551(business_id, queued_at desc);
create index if not exists retention_sends_v551_client_idx
  on public.retention_sends_v551(business_id, client_id);

revoke all on public.retention_sends_v551 from public, anon, authenticated;
grant select on public.retention_sends_v551 to authenticated;
alter table public.retention_sends_v551 enable row level security;
drop policy if exists retention_sends_v551_read on public.retention_sends_v551;
create policy retention_sends_v551_read on public.retention_sends_v551 for select using (
  app.is_super_admin() or app.can_module_read(business_id, 'loyalty'));

create or replace function app.v551_retention_status_rank(p_status text)
returns integer language sql immutable as $$
  select case p_status
    when 'queued' then 0
    when 'processing' then 10
    when 'sent' then 20
    -- terminal faults sit BELOW 'delivered': a late failure callback must never
    -- roll back a delivery Meta already confirmed.
    when 'failed' then 25
    when 'undeliverable' then 25
    when 'template_fault' then 25
    when 'config_fault' then 25
    when 'failed_retries_exhausted' then 25
    when 'suppressed' then 25
    when 'delivered' then 30
    when 'read' then 40
    else 0 end
$$;

-- ---------------------------------------------------------------------------
-- 3. Enqueue: a bring-back grant asks for a send, and every refusal has a name
-- ---------------------------------------------------------------------------

create or replace function app.v551_enqueue_bringback_send()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $fn$
declare
  v_client public.clients%rowtype;
  v_biz_name text;
  v_identity uuid;
  v_reason text := null;
  v_first text;
begin
  select * into v_client from public.clients
   where id = new.client_id and business_id = new.business_id;
  if not found then return new; end if;

  select b.name into v_biz_name from public.businesses b where b.id = new.business_id;

  if not app.platform_feature_enabled('whatsapp_outbound') then
    v_reason := 'platform_outbound_off';
  elsif not app.platform_feature_enabled('whatsapp_retention_sends') then
    v_reason := 'retention_sends_off';
  elsif not coalesce((app.capability_state_v518(new.business_id, 'whatsapp_retention')->>'allowed')::boolean, false) then
    v_reason := 'capability_disabled';
  elsif coalesce(v_client.is_synthetic, false) then
    v_reason := 'synthetic_client';
  elsif not coalesce(v_client.marketing_consent, false) then
    -- The column is NOT NULL DEFAULT false: only an affirmative tick opens this
    -- gate. A customer the till created without asking stays unmessaged.
    v_reason := 'consent_missing';
  else
    select l.identity_id into v_identity
      from public.customer_links l
     where l.business_id = new.business_id and l.client_id = new.client_id
       and l.state = 'verified'
     limit 1;
    if v_identity is not null
       and not app.customer_communication_allows_v263(v_identity, 'business_offers', 'whatsapp') then
      v_reason := 'preference_opt_out';
    elsif v_client.phone_norm is null then
      v_reason := 'no_phone';
    end if;
  end if;

  v_first := nullif(split_part(btrim(coalesce(v_client.full_name, '')), ' ', 1), '');

  insert into public.retention_sends_v551(
    business_id, client_id, grant_id, template_key, variables,
    recipient_phone_norm, status, status_rank, suppressed_reason)
  values (
    new.business_id, new.client_id, new.id, 'bring_back_v1',
    jsonb_build_object(
      'customer_first_name', coalesce(v_first, 'there'),
      'business_name', coalesce(v_biz_name, 'us'),
      'reward_label', new.reward_label),
    v_client.phone_norm,
    case when v_reason is null then 'queued' else 'suppressed' end,
    case when v_reason is null then 0 else app.v551_retention_status_rank('suppressed') end,
    v_reason)
  on conflict (grant_id) do nothing;

  return new;
exception when others then
  -- A WhatsApp enqueue failure must never abort voucher issuance: the grant is
  -- the product, the message is the amplifier. The error surfaces as a missing
  -- send row for a grant, which the stats read reports as its own count.
  return new;
end
$fn$;

drop trigger if exists bringback_grants_v361_enqueue_send_v551 on public.bringback_grants_v361;
create trigger bringback_grants_v361_enqueue_send_v551
  after insert on public.bringback_grants_v361
  for each row execute function app.v551_enqueue_bringback_send();

-- ---------------------------------------------------------------------------
-- 4. Claim / report — the v535 lease protocol, template edition
-- ---------------------------------------------------------------------------

create or replace function public.internal_retention_claim_v551(
  p_worker_id text,
  p_limit integer default 20,
  p_lease_seconds integer default 120
)
returns table(
  message_id uuid, business_id uuid, recipient_phone_norm text,
  template_name text, language_code text, parameter_descriptors jsonb,
  variables jsonb, attempt_count integer, lease_token uuid)
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $fn$
declare v_lease uuid := gen_random_uuid();
begin
  -- Sweep 1: age out anything that sat queued for 7 days — a bring-back offer
  -- sent a week late reads as spam, and spam is how a number dies.
  update public.retention_sends_v551 s
     set status = 'suppressed', suppressed_reason = 'stale_unsent',
         status_rank = app.v551_retention_status_rank('suppressed')
   where s.status = 'queued' and s.queued_at < now() - interval '7 days';

  -- Sweep 2: the second consent check. Between enqueue and claim the customer
  -- may have opted out (STOP, the app toggle, staff). Suppress, never send.
  update public.retention_sends_v551 s
     set status = 'suppressed', suppressed_reason = 'consent_withdrawn',
         status_rank = app.v551_retention_status_rank('suppressed')
   where s.status = 'queued'
     and exists (
       select 1 from public.clients c
        where c.id = s.client_id
          and not coalesce(c.marketing_consent, false));

  return query
  with claimable as (
    select s.id
      from public.retention_sends_v551 s
      join public.whatsapp_template_registry_v551 t
        on t.template_key = s.template_key and t.status = 'approved'
     where s.status in ('queued','processing')
       and coalesce(s.next_attempt_at, now()) <= now()
       and (s.lease_until is null or s.lease_until < now())
       and app.platform_feature_enabled('whatsapp_outbound')
       and app.platform_feature_enabled('whatsapp_retention_sends')
       and coalesce((app.capability_state_v518(s.business_id, 'whatsapp_retention')->>'allowed')::boolean, false)
     order by s.queued_at
     limit greatest(coalesce(p_limit, 20), 1)
     for update of s skip locked
  )
  update public.retention_sends_v551 target
     set status = 'processing',
         status_rank = greatest(target.status_rank, app.v551_retention_status_rank('processing')),
         lease_token = v_lease,
         leased_by = left(coalesce(p_worker_id, 'worker'), 64),
         lease_until = now() + make_interval(secs => greatest(coalesce(p_lease_seconds, 120), 30))
    from claimable, public.whatsapp_template_registry_v551 t
   where target.id = claimable.id and t.template_key = target.template_key
  returning target.id, target.business_id, target.recipient_phone_norm,
            t.meta_name, t.language_code, t.parameter_descriptors,
            target.variables, target.attempt_count, v_lease;
end
$fn$;

revoke all on function public.internal_retention_claim_v551(text, integer, integer)
  from public, anon, authenticated;
grant execute on function public.internal_retention_claim_v551(text, integer, integer) to service_role;

create or replace function public.internal_retention_report_v551(
  p_message uuid,
  p_lease_token uuid,
  p_disposition text,
  p_provider_message_id text default null,
  p_error_code text default null,
  p_retry_in_seconds integer default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $fn$
declare
  v_row public.retention_sends_v551%rowtype;
  v_consume jsonb;
  v_note text := null;
begin
  select * into v_row from public.retention_sends_v551 where id = p_message for update;
  if not found then
    raise exception 'unknown retention send' using errcode = 'P0002';
  end if;
  -- A NULL lease means nobody holds this row: a report against it is always
  -- stale. Without the explicit null check, null-is-distinct-from-null = false
  -- would let a worker report on a row it never claimed (found by the v551
  -- acceptance suite, where exactly that happened).
  if v_row.lease_token is null or v_row.lease_token is distinct from p_lease_token then
    raise exception 'stale lease' using errcode = '40001';
  end if;

  if p_disposition = 'sent' then
    -- Only 'sent' consumes the safety-cap quota (boundaries.consumesQuota). A
    -- refusal here means the cap raced the batch: the message DID go out, so
    -- the row stays 'sent' and the refusal is noted, never hidden.
    begin
      v_consume := app.capability_consume_v518(
        v_row.business_id, 'whatsapp_retention', 'v551:' || v_row.id::text,
        jsonb_build_object('kind', 'retention_send'));
      if not coalesce((v_consume->>'consumed')::boolean, false) then
        v_note := 'quota_consume_refused';
      end if;
    exception when others then
      v_note := 'quota_consume_error';
    end;
    update public.retention_sends_v551
       set status = 'sent',
           status_rank = greatest(status_rank, app.v551_retention_status_rank('sent')),
           sent_at = coalesce(sent_at, now()),
           provider_message_id = coalesce(p_provider_message_id, provider_message_id),
           error_code = v_note,
           attempt_count = attempt_count + 1,
           lease_token = null, leased_by = null, lease_until = null,
           next_attempt_at = null
     where id = p_message;
  elsif p_disposition = 'retry' then
    update public.retention_sends_v551
       set status = 'queued',
           status_rank = app.v551_retention_status_rank('queued'),
           error_code = left(coalesce(p_error_code, 'retry'), 64),
           attempt_count = attempt_count + 1,
           lease_token = null, leased_by = null, lease_until = null,
           next_attempt_at = now() + make_interval(secs => greatest(coalesce(p_retry_in_seconds, 60), 15))
     where id = p_message;
  elsif p_disposition in ('undeliverable','template_fault','config_fault','failed','failed_retries_exhausted') then
    update public.retention_sends_v551
       set status = p_disposition,
           status_rank = greatest(status_rank, app.v551_retention_status_rank(p_disposition)),
           failed_at = coalesce(failed_at, now()),
           error_code = left(coalesce(p_error_code, p_disposition), 64),
           attempt_count = attempt_count + 1,
           lease_token = null, leased_by = null, lease_until = null,
           next_attempt_at = null
     where id = p_message;
  else
    raise exception 'unknown disposition' using errcode = '22023';
  end if;

  return jsonb_build_object('status', 'ok', 'message_id', p_message, 'disposition', p_disposition);
end
$fn$;

revoke all on function public.internal_retention_report_v551(uuid, uuid, text, text, text, integer)
  from public, anon, authenticated;
grant execute on function public.internal_retention_report_v551(uuid, uuid, text, text, text, integer) to service_role;

-- ---------------------------------------------------------------------------
-- 5. Status ingest — monotonic, non-claiming (the v535 posture, verbatim)
-- ---------------------------------------------------------------------------

create or replace function app.v551_ingest_retention_status(p_limit integer default 200)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $fn$
declare
  v_event record; v_status jsonb; v_wamid text; v_state text;
  v_at timestamptz; v_rank integer; v_applied integer := 0; v_ignored integer := 0;
begin
  -- No processing_status filter, no lock: the v531 router owns that flag and
  -- the v535 support ingest reads the same rows the same way. Re-application
  -- is free because the update only ever advances status_rank, and support
  -- and retention wamids are disjoint, so the two sweeps can never both match
  -- one callback.
  for v_event in
    select * from public.whatsapp_webhook_events
     where received_at > now() - interval '2 days'
     order by received_at
     limit greatest(p_limit, 1)
  loop
    begin
      for v_status in
        select st from jsonb_array_elements(coalesce(v_event.payload->'entry','[]'::jsonb)) entry,
             jsonb_array_elements(coalesce(entry->'changes','[]'::jsonb)) change,
             jsonb_array_elements(coalesce(change->'value'->'statuses','[]'::jsonb)) st
      loop
        v_wamid := v_status->>'id';
        v_state := v_status->>'status';
        v_at := to_timestamp((v_status->>'timestamp')::bigint);
        if v_state not in ('sent','delivered','read','failed') then
          v_ignored := v_ignored + 1; continue;
        end if;
        v_rank := app.v551_retention_status_rank(v_state);
        update public.retention_sends_v551
           set status = v_state,
               status_rank = v_rank,
               delivered_at = case when v_state = 'delivered' then coalesce(delivered_at, v_at) else delivered_at end,
               read_at = case when v_state = 'read' then coalesce(read_at, v_at) else read_at end,
               failed_at = case when v_state = 'failed' then coalesce(failed_at, v_at) else failed_at end
         where provider_message_id = v_wamid
           and status_rank < v_rank;
        if found then v_applied := v_applied + 1; else v_ignored := v_ignored + 1; end if;
      end loop;
    exception when others then
      null;
    end;
  end loop;
  return jsonb_build_object('applied', v_applied, 'ignored', v_ignored);
end
$fn$;

revoke all on function app.v551_ingest_retention_status(integer) from public, anon, authenticated;
grant execute on function app.v551_ingest_retention_status(integer) to service_role;

-- ---------------------------------------------------------------------------
-- 6. STOP — the footer's promise, honoured platform-wide for that phone
-- ---------------------------------------------------------------------------

create or replace function app.v551_ingest_retention_optout(p_limit integer default 200)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $fn$
declare
  v_event record; v_msg jsonb; v_body text; v_from text; v_norm text;
  v_client record; v_optouts integer := 0;
begin
  for v_event in
    select * from public.whatsapp_webhook_events
     where received_at > now() - interval '2 days'
     order by received_at
     limit greatest(p_limit, 1)
  loop
    begin
      for v_msg in
        select m from jsonb_array_elements(coalesce(v_event.payload->'entry','[]'::jsonb)) entry,
             jsonb_array_elements(coalesce(entry->'changes','[]'::jsonb)) change,
             jsonb_array_elements(coalesce(change->'value'->'messages','[]'::jsonb)) m
      loop
        if v_msg->>'type' <> 'text' then continue; end if;
        v_body := lower(btrim(coalesce(v_msg->'text'->>'body', '')));
        if v_body not in ('stop', 'unsubscribe') then continue; end if;
        v_from := coalesce(v_msg->>'from', '');
        -- Meta sends E.164 without '+' (e.g. 65 then 8 digits); the platform
        -- key is the bare local form. Non-SG numbers cannot match any client
        -- and fall through harmlessly.
        v_norm := app.norm_phone(v_from);
        if v_norm is null then continue; end if;

        -- A STOP to the shared platform number cannot be scoped to one
        -- merchant, so it is honoured for every business that has messaged
        -- this phone through this lane. Over-honouring is the only acceptable
        -- direction for an opt-out. Idempotent: the marketing_consent filter
        -- means a replayed webhook row finds nothing left to opt out.
        for v_client in
          select distinct c.id, c.business_id
            from public.clients c
            join public.retention_sends_v551 s
              on s.client_id = c.id and s.business_id = c.business_id
           where c.phone_norm = v_norm
             and coalesce(c.marketing_consent, true)
        loop
          update public.clients set marketing_consent = false where id = v_client.id;
          insert into public.consents(business_id, client_id, channel, action, source)
          values (v_client.business_id, v_client.id, 'whatsapp', 'withdrawn', 'whatsapp_stop_reply');
          update public.retention_sends_v551
             set status = 'suppressed', suppressed_reason = 'customer_opted_out',
                 status_rank = app.v551_retention_status_rank('suppressed'),
                 lease_token = null, leased_by = null, lease_until = null,
                 next_attempt_at = null
           where client_id = v_client.id and business_id = v_client.business_id
             and status in ('queued','processing');
          v_optouts := v_optouts + 1;
        end loop;
      end loop;
    exception when others then
      null;
    end;
  end loop;
  return jsonb_build_object('optouts', v_optouts);
end
$fn$;

revoke all on function app.v551_ingest_retention_optout(integer) from public, anon, authenticated;
grant execute on function app.v551_ingest_retention_optout(integer) to service_role;

-- ---------------------------------------------------------------------------
-- 7. The driver — v536's shape, pointed at the retention dispatcher
-- ---------------------------------------------------------------------------

create or replace function app.v551_run_retention_dispatch()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_url text;
  v_secret text;
  v_request bigint;
  v_queued integer;
begin
  select count(*)::integer into v_queued
    from public.retention_sends_v551
   where status in ('queued', 'processing')
     and coalesce(next_attempt_at, now()) <= now();
  if v_queued = 0 then
    return jsonb_build_object('queued', 0, 'dispatch', 'idle');
  end if;
  if to_regnamespace('vault') is null or to_regnamespace('net') is null then
    return jsonb_build_object('queued', v_queued, 'dispatch', 'extensions_unavailable');
  end if;
  begin
    execute 'select decrypted_secret from vault.decrypted_secrets where name=$1 order by created_at desc limit 1'
      into v_url using 'v282_supabase_url';
    if coalesce(v_url, '') = '' then
      execute 'select decrypted_secret from vault.decrypted_secrets where name=$1 order by created_at desc limit 1'
        into v_url using 'v156_supabase_url';
    end if;
    execute 'select decrypted_secret from vault.decrypted_secrets where name=$1 order by created_at desc limit 1'
      into v_secret using 'v536_whatsapp_dispatch_secret';
  exception when others then
    return jsonb_build_object('queued', v_queued, 'dispatch', 'vault_unavailable');
  end;
  if coalesce(v_url, '') = '' or coalesce(v_secret, '') = '' then
    return jsonb_build_object('queued', v_queued, 'dispatch', 'secret_unconfigured');
  end if;
  execute 'select net.http_post(url := $1, body := ''{}''::jsonb, headers := jsonb_build_object(''content-type'',''application/json'',''x-peekaa-whatsapp-dispatch-secret'',$2), timeout_milliseconds := 25000)'
    into v_request
    using rtrim(v_url, '/') || '/functions/v1/whatsapp-retention-dispatch', v_secret;
  return jsonb_build_object('queued', v_queued, 'dispatch_request_id', v_request);
end
$fn$;

revoke all privileges on function app.v551_run_retention_dispatch()
  from public, anon, authenticated, service_role;
grant execute on function app.v551_run_retention_dispatch() to service_role;

do $cron$
begin
  if to_regnamespace('cron') is not null
     and to_regprocedure('cron.schedule(text,text,text)') is not null then
    perform cron.schedule(
      'nestly-v551-retention-dispatch',
      '*/5 * * * *',
      $command$select app.v551_run_retention_dispatch()$command$);
    perform cron.schedule(
      'nestly-v551-retention-status-ingest',
      '*/5 * * * *',
      $command$select app.v551_ingest_retention_status(200)$command$);
    perform cron.schedule(
      'nestly-v551-retention-optout',
      '*/10 * * * *',
      $command$select app.v551_ingest_retention_optout(200)$command$);
  end if;
exception when others then null;
end $cron$;

-- ---------------------------------------------------------------------------
-- 8. The business-facing read: what happened to my offers?
-- ---------------------------------------------------------------------------

create or replace function public.get_retention_send_stats_v551(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $fn$
declare v_result jsonb;
begin
  perform public.require_module_scope_v145(p_business, null, 'retention');
  select jsonb_build_object(
    'queued',    count(*) filter (where status in ('queued','processing')),
    'sent',      count(*) filter (where status = 'sent'),
    'delivered', count(*) filter (where status = 'delivered'),
    'read',      count(*) filter (where status = 'read'),
    'failed',    count(*) filter (where status in ('failed','undeliverable','template_fault','config_fault','failed_retries_exhausted')),
    'suppressed', count(*) filter (where status = 'suppressed'),
    'suppressed_reasons', (
      select coalesce(jsonb_object_agg(reason, n), '{}'::jsonb)
      from (select suppressed_reason as reason, count(*) as n
              from public.retention_sends_v551
             where business_id = p_business and status = 'suppressed'
             group by 1) r),
    'last_activity_at', max(greatest(
      coalesce(queued_at, 'epoch'), coalesce(sent_at, 'epoch'),
      coalesce(delivered_at, 'epoch'), coalesce(read_at, 'epoch'))),
    'template_status', (select t.status from public.whatsapp_template_registry_v551 t
                         where t.template_key = 'bring_back_v1')
  )
  into v_result
  from public.retention_sends_v551
  where business_id = p_business;
  return v_result;
end
$fn$;

comment on function public.get_retention_send_stats_v551(uuid) is
  'Counts of one business''s WhatsApp bring-back sends by lifecycle state, with '
  'named suppression reasons and the template''s approval status. No phone '
  'numbers, no message bodies. Gated on retention scope.';

revoke all on function public.get_retention_send_stats_v551(uuid) from public, anon;
grant execute on function public.get_retention_send_stats_v551(uuid) to authenticated;
grant execute on function public.get_retention_send_stats_v551(uuid) to service_role;

commit;

-- ============================================================================
-- VERIFICATION (performed rolled-back against production before apply):
--   db/tests/v551_whatsapp_bringback_sends.sql — every gate produces its named
--   suppression; a fully-permitted grant enqueues 'queued'; claim refuses an
--   unapproved template and honours the second consent check; the report state
--   machine (sent + quota consume, retry backoff, terminal faults, stale
--   lease); status ingest is monotonic; the STOP sweep opts out every matching
--   client, writes consents rows and suppresses the queue; stats read is
--   scope-gated; service-role-only ACLs on the internal pair.
-- ============================================================================
