-- NESTLY v535 - C6 M1: THE OUTBOUND REPLY CHOKEPOINT
--
-- Owner approval 2026-08-26 with rulings. A human staff member types a reply in
-- the WhatsApp Inbox and the customer receives it from the shared Peekaa number.
-- No AI, no templates, no automation, no attachments.
--
-- THIS MIGRATION SHIPS INERT. It creates the queue, the chokepoint and the
-- status ingest, but schedules NO cron and the pilot capability is OFF for every
-- business including Cubbly. v536 wires the dispatcher. Nothing can send today.
--
-- ===========================================================================
-- ONE ROW PER LOGICAL MESSAGE - which is what idempotency actually means
-- ===========================================================================
-- The outbound state lives ON support_messages_v530 rather than in a second
-- delivery table. A separate queue would mean two rows per reply and two places
-- to ask "did this send?", and the owner's ruling is explicit: a double-click, a
-- refresh, a network failure, an Edge retry or a staff Retry press must never
-- produce a second WhatsApp message for the same logical reply. One row, one
-- idempotency key, one unique index. Retry is then not a policy anyone has to
-- remember - it is arithmetic.
--
-- unique (conversation_id, idempotency_key) is the whole contract. The client
-- generates the key once per composer session and REUSES it on every retry;
-- editing the body is a new logical send and gets a new key (owner ruling 5).
--
-- ===========================================================================
-- PILOT GATING: TWO INDEPENDENT SWITCHES, BOTH MUST BE ON
-- ===========================================================================
-- Owner ruling 1: outbound must not be global. So:
--   * app.platform_feature_enabled('whatsapp_outbound') is the PLATFORM master
--     kill switch - one flip stops every tenant instantly.
--   * the v518 capability 'whatsapp_support_reply' is the PER-FIRM gate, seeded
--     default_enabled=false, so a business that can SEE a read-only Inbox still
--     cannot send. Only an explicit superadmin grant turns one firm on.
-- Neither alone is sufficient. A business with the capability but the master
-- switch off sends nothing; the master switch on with no grant sends nothing.
--
-- ===========================================================================
-- THE SAFETY CAP IS THE QUOTA, NOT A PRICE
-- ===========================================================================
-- Owner ruling 2: a conservative business-scoped DAILY cap, server-enforced,
-- idempotent, named reason, no double consumption on retry, configurable later.
-- That is exactly app.capability_consume_v518 with limit_period='day' - already
-- advisory-locked per (firm, capability), already idempotent on an idem key,
-- already refusing with 'quota_exhausted'. Reusing it means the cap cannot drift
-- from the quota engine, and the superadmin setter already configures it.
-- NO PRICE IS EXPRESSED ANYWHERE. whatsapp_credit_charging_enabled stays false.
--
-- The reply's idempotency key IS the capability idem key, so a retry that
-- returns the original message also returns the original quota consumption.
-- A retried send cannot spend the cap twice.
--
-- ===========================================================================
-- MERCHANT IDENTITY IS SERVER-GENERATED
-- ===========================================================================
-- Owner ruling 3. rendered_body = businesses.name || ': ' || what staff typed,
-- composed INSIDE this SECURITY DEFINER function from the canonical business
-- record. The browser supplies only the message body; it cannot supply, alter or
-- remove the prefix, because it never passes one. Staff see what they typed;
-- the customer sees the prefixed form; rendered_body is the durable evidence of
-- exactly what left Peekaa.
--
-- ===========================================================================
-- PROVIDER MESSAGE IDS ARE PII
-- ===========================================================================
-- Owner ruling 4, and it is not a formality: wamid.HBgK<base64> decodes to the
-- sender's E.164 number. provider_message_id therefore stays out of every
-- browser payload (the v531 readers already never project it), out of ordinary
-- logs, and inside retention/erasure. This migration adds no new place for it
-- to leak.
--
-- ===========================================================================
-- STATUS IS MONOTONIC BY RANK, NOT BY ARRIVAL
-- ===========================================================================
-- Meta does not guarantee callback order, so a late 'sent' can arrive after
-- 'read'. Ranking makes the downgrade impossible rather than unlikely:
--   queued 0 < processing 10 < sent 20 < failed 25 < delivered 30 < read 40
-- 'failed' outranks 'sent' because Meta reports failure INSTEAD of delivery -
-- but it sits below delivered/read, so a message the customer demonstrably
-- received can never be relabelled as failed.

begin;

-- ===========================================================================
-- 1. Outbound state on the message row
-- ===========================================================================

alter table public.support_messages_v530
  add column if not exists idempotency_key text,
  add column if not exists rendered_body text,
  add column if not exists queued_at timestamptz,
  add column if not exists sent_at timestamptz,
  add column if not exists attempt_count integer not null default 0,
  add column if not exists next_attempt_at timestamptz,
  add column if not exists lease_token uuid,
  add column if not exists leased_by text,
  add column if not exists lease_until timestamptz,
  add column if not exists last_http_status integer,
  add column if not exists status_rank integer not null default 0;

comment on column public.support_messages_v530.rendered_body is
  'v535 exactly what left Peekaa: businesses.name || '': '' || the staff body, composed server-side. The browser never supplies a prefix and cannot remove one.';
comment on column public.support_messages_v530.idempotency_key is
  'v535 durable per-logical-message key. Reused on every retry; a new key only when the operator edits the body. unique(conversation_id, idempotency_key) makes a duplicate customer message impossible.';
comment on column public.support_messages_v530.status_rank is
  'v535 monotonic guard. queued 0 < processing 10 < sent 20 < failed 25 < delivered 30 < read 40. A late callback can never downgrade a message the customer already read.';

-- The whole duplicate-prevention contract, in one index.
create unique index if not exists support_messages_v530_idem_uk
  on public.support_messages_v530 (conversation_id, idempotency_key)
  where idempotency_key is not null;

create index if not exists support_messages_v530_outbound_queue_idx
  on public.support_messages_v530 (status, next_attempt_at)
  where direction = 'outbound';

-- 'processing' joins the vocabulary; everything else is unchanged.
alter table public.support_messages_v530
  drop constraint if exists support_messages_v530_status_check;
alter table public.support_messages_v530
  add constraint support_messages_v530_status_check
  check (status in ('received','queued','processing','sent','delivered','read','failed'));

create or replace function app.support_status_rank_v535(p_status text)
returns integer language sql immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select case p_status
    when 'queued' then 0 when 'processing' then 10 when 'sent' then 20
    when 'failed' then 25 when 'delivered' then 30 when 'read' then 40
    else 0 end
$$;
revoke all on function app.support_status_rank_v535(text) from public, anon, authenticated;

-- ===========================================================================
-- 2. The pilot capability + daily safety cap
-- ===========================================================================
-- default_enabled FALSE: seeding this row grants nobody anything. 50/day is a
-- conservative rate-control ceiling, not a price.

insert into public.platform_capabilities_v518(
  capability_key, title, description,
  eligible_industries, required_modules,
  default_enabled, default_limit_count, default_limit_period, active)
values (
  'whatsapp_support_reply',
  'WhatsApp Inbox replies',
  'Lets staff reply to a routed WhatsApp conversation from the Peekaa number. Off by default; the daily limit is a safety cap, not a commercial allowance.',
  null,
  array['support'],
  false, 50, 'day', true)
on conflict (capability_key) do nothing;

-- ===========================================================================
-- 3. THE CHOKEPOINT
-- ===========================================================================

create or replace function app.support_reply_v535(
  p_business uuid,
  p_conversation uuid,
  p_body text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_conversation public.support_conversations_v530%rowtype;
  v_existing public.support_messages_v530%rowtype;
  v_staff public.staff%rowtype;
  v_business public.businesses%rowtype;
  v_body text;
  v_rendered text;
  v_quota jsonb;
  v_id uuid;
begin
  v_body := btrim(coalesce(p_body, ''));

  if coalesce(btrim(p_idempotency_key), '') = '' or char_length(btrim(p_idempotency_key)) < 8 then
    raise exception 'a durable idempotency key is required' using errcode = '22023';
  end if;

  -- (0) THE RETURNING RETRY, checked FIRST and before any gate. A message
  -- already accepted must return its original outcome even if the window has
  -- since closed or the cap has since filled - otherwise a retry after a
  -- client timeout would report a failure for a message the customer has.
  select * into v_existing from public.support_messages_v530
   where conversation_id = p_conversation
     and idempotency_key = btrim(p_idempotency_key);
  if found then
    return jsonb_build_object(
      'status', 'ok', 'duplicate', true, 'message_id', v_existing.id,
      'message_status', v_existing.status);
  end if;

  -- (1) business active / not suspended
  if not app.business_workspace_open_v94(p_business) then
    return jsonb_build_object('status','refused','reason','business_not_active');
  end if;

  -- (2) support module WRITE (read-only staff are refused here)
  if not app.can_module_write(p_business, 'support') then
    return jsonb_build_object('status','refused','reason','no_support_write_permission');
  end if;

  -- (3) the acting staff member, resolved server-side. Never taken from input.
  select * into v_staff from public.staff
   where business_id = p_business and user_id = auth.uid() and active
   order by case when role = 'owner' then 0 else 1 end, created_at limit 1;
  if not found then
    return jsonb_build_object('status','refused','reason','not_staff_of_this_business');
  end if;

  -- (4) the conversation must BELONG to this business. business_id is in the
  -- predicate, so guessing another tenant's conversation id matches nothing.
  select * into v_conversation from public.support_conversations_v530
   where id = p_conversation and business_id = p_business;
  if not found then
    return jsonb_build_object('status','refused','reason','conversation_not_found');
  end if;

  -- (5) routed. An unrouted enquiry lives in the pending table and has no
  -- business, so it cannot reach this line - but state the rule anyway.
  if v_conversation.routing_source is null then
    return jsonb_build_object('status','refused','reason','conversation_not_routed');
  end if;

  -- (6) not closed
  if v_conversation.state <> 'open' then
    return jsonb_build_object('status','refused','reason','conversation_closed');
  end if;

  -- (7) SERVICE WINDOW, judged by the server clock. The browser's countdown is a
  -- courtesy; this is the authority.
  if v_conversation.service_window_expires_at is null
     or v_conversation.service_window_expires_at <= now() then
    return jsonb_build_object('status','refused','reason','service_window_closed',
      'service_window_expires_at', v_conversation.service_window_expires_at);
  end if;

  -- (8) content validation. WhatsApp's text ceiling is 4096; the prefix has to
  -- fit inside it too, so the body is bounded well below.
  if v_body = '' then
    return jsonb_build_object('status','refused','reason','empty_message');
  end if;
  if char_length(v_body) > 3000 then
    return jsonb_build_object('status','refused','reason','message_too_long');
  end if;
  -- Reject non-printable control characters, but NOT newlines or tabs: a
  -- multi-line reply is ordinary, a NUL byte is not.
  if v_body ~ '[^[:print:][:space:]]' then
    return jsonb_build_object('status','refused','reason','invalid_characters');
  end if;

  -- (9) the PLATFORM master switch
  if not app.platform_feature_enabled('whatsapp_outbound') then
    return jsonb_build_object('status','refused','reason','outbound_not_enabled');
  end if;

  -- (10) the PER-FIRM gate and the daily safety cap, in one call. Keyed on the
  -- reply's own idempotency key, so a retry consumes nothing extra.
  v_quota := app.capability_consume_v518(
    p_business, 'whatsapp_support_reply', btrim(p_idempotency_key),
    jsonb_build_object('conversation_id', p_conversation));
  if (v_quota->>'consumed') is distinct from 'true' then
    return jsonb_build_object('status','refused',
      'reason', coalesce(v_quota->>'reason','capability_refused'),
      'remaining', v_quota->'remaining');
  end if;

  -- The merchant identity prefix, composed here from the canonical record.
  select * into v_business from public.businesses where id = p_business;
  v_rendered := btrim(coalesce(v_business.name, 'Peekaa')) || ': ' || v_body;

  insert into public.support_messages_v530(
    conversation_id, business_id, direction, body, rendered_body,
    occurred_at, status, status_rank, authored_by_staff_id,
    idempotency_key, queued_at, next_attempt_at, attempt_count)
  values (p_conversation, p_business, 'outbound', v_body, v_rendered,
          now(), 'queued', app.support_status_rank_v535('queued'), v_staff.id,
          btrim(p_idempotency_key), now(), now(), 0)
  returning id into v_id;

  update public.support_conversations_v530
     set last_outbound_at = now(), unread_count = 0, updated_at = now(),
         handoff_state = case when handoff_state = 'unassigned' then 'assigned' else handoff_state end,
         assigned_staff_id = coalesce(assigned_staff_id, v_staff.id)
   where id = p_conversation;

  return jsonb_build_object(
    'status','ok','duplicate',false,'message_id',v_id,'message_status','queued',
    'remaining', v_quota->'remaining');
end
$fn$;

revoke all on function app.support_reply_v535(uuid, uuid, text, text)
  from public, anon, authenticated;

-- The browser's only door. Thin wrapper so the app-facing name is public.* like
-- every other RPC the SPA calls.
create or replace function public.business_support_send_reply_v535(
  p_business uuid,
  p_conversation uuid,
  p_body text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
begin
  return app.support_reply_v535(p_business, p_conversation, p_body, p_idempotency_key);
end
$fn$;

revoke all on function public.business_support_send_reply_v535(uuid, uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.business_support_send_reply_v535(uuid, uuid, text, text)
  to authenticated;
grant execute on function public.business_support_send_reply_v535(uuid, uuid, text, text)
  to service_role;

-- ===========================================================================
-- 4. Dispatcher claim / report
-- ===========================================================================

create or replace function public.internal_support_claim_outbound_v535(
  p_worker_id text,
  p_limit integer default 20,
  p_lease_seconds integer default 120
)
returns table(
  message_id uuid, business_id uuid, recipient_phone_norm text,
  rendered_body text, attempt_count integer, lease_token uuid)
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare v_lease uuid := gen_random_uuid();
begin
  return query
  with claimable as (
    select m.id
      from public.support_messages_v530 m
     where m.direction = 'outbound'
       and m.status in ('queued','processing')
       and coalesce(m.next_attempt_at, now()) <= now()
       and (m.lease_until is null or m.lease_until < now())
     order by m.queued_at
     limit greatest(coalesce(p_limit, 20), 1)
     for update skip locked
  )
  update public.support_messages_v530 target
     set status = 'processing',
         status_rank = greatest(target.status_rank, app.support_status_rank_v535('processing')),
         lease_token = v_lease, leased_by = left(coalesce(p_worker_id,'worker'), 64),
         lease_until = now() + make_interval(secs => greatest(coalesce(p_lease_seconds,120), 30))
    from claimable
   where target.id = claimable.id
  returning target.id, target.business_id,
            (select c.customer_phone_norm from public.support_conversations_v530 c
              where c.id = target.conversation_id),
            target.rendered_body, target.attempt_count, v_lease;
end
$fn$;

revoke all on function public.internal_support_claim_outbound_v535(text, integer, integer)
  from public, anon, authenticated;
grant execute on function public.internal_support_claim_outbound_v535(text, integer, integer)
  to service_role;

create or replace function public.internal_support_report_outbound_v535(
  p_message uuid,
  p_lease_token uuid,
  p_disposition text,
  p_provider_message_id text default null,
  p_error_code text default null,
  p_http_status integer default null,
  p_retry_in_seconds integer default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare v_row public.support_messages_v530%rowtype;
begin
  select * into v_row from public.support_messages_v530 where id = p_message for update;
  if not found then
    raise exception 'unknown outbound message' using errcode = 'P0002';
  end if;
  -- A stale lease means another worker owns this row now. Refuse rather than
  -- overwrite: the v95 protocol, and the reason a slow worker cannot resurrect
  -- a message someone else already sent.
  if v_row.lease_token is distinct from p_lease_token then
    raise exception 'stale lease' using errcode = '40001';
  end if;

  if p_disposition = 'sent' then
    update public.support_messages_v530
       set status = 'sent',
           status_rank = greatest(status_rank, app.support_status_rank_v535('sent')),
           provider_message_id = p_provider_message_id,
           sent_at = now(), last_http_status = p_http_status,
           attempt_count = attempt_count + 1,
           lease_token = null, leased_by = null, lease_until = null,
           error_code = null, next_attempt_at = null
     where id = p_message;
  elsif p_disposition = 'retry' then
    update public.support_messages_v530
       set status = 'queued',
           attempt_count = attempt_count + 1,
           last_http_status = p_http_status, error_code = p_error_code,
           next_attempt_at = now() + make_interval(secs => greatest(coalesce(p_retry_in_seconds, 30), 5)),
           lease_token = null, leased_by = null, lease_until = null
     where id = p_message;
  else
    update public.support_messages_v530
       set status = 'failed',
           status_rank = greatest(status_rank, app.support_status_rank_v535('failed')),
           failed_at = now(), last_http_status = p_http_status,
           error_code = left(coalesce(p_error_code, p_disposition), 64),
           attempt_count = attempt_count + 1,
           lease_token = null, leased_by = null, lease_until = null,
           next_attempt_at = null
     where id = p_message;
  end if;

  return jsonb_build_object('status','ok','message_id',p_message,'disposition',p_disposition);
end
$fn$;

revoke all on function public.internal_support_report_outbound_v535(uuid, uuid, text, text, text, integer, integer)
  from public, anon, authenticated;
grant execute on function public.internal_support_report_outbound_v535(uuid, uuid, text, text, text, integer, integer)
  to service_role;

-- ===========================================================================
-- 5. Status callback ingest - monotonic by rank
-- ===========================================================================

create or replace function app.support_ingest_status_v535(p_limit integer default 200)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_event record; v_status jsonb; v_wamid text; v_state text;
  v_at timestamptz; v_rank integer; v_applied integer := 0; v_ignored integer := 0;
begin
  -- Deliberately does NOT filter on processing_status and takes no row lock.
  -- The v531 inbound router owns that flag and flips it to 'processed'; if this
  -- sweep also claimed on it, whichever ran second would find nothing and every
  -- delivery/read callback would be silently lost. Re-reading a webhook row is
  -- free here because the update below only ever ADVANCES status_rank, so
  -- applying the same callback twice changes nothing.
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
        v_rank := app.support_status_rank_v535(v_state);

        -- The monotonic guard: only advance. A late 'sent' after 'read' matches
        -- nothing because 40 > 20, so the row is left exactly as it was.
        update public.support_messages_v530
           set status = v_state,
               status_rank = v_rank,
               delivered_at = case when v_state = 'delivered' then coalesce(delivered_at, v_at) else delivered_at end,
               read_at = case when v_state = 'read' then coalesce(read_at, v_at) else read_at end,
               failed_at = case when v_state = 'failed' then coalesce(failed_at, v_at) else failed_at end
         where provider_message_id = v_wamid
           and direction = 'outbound'
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

revoke all on function app.support_ingest_status_v535(integer)
  from public, anon, authenticated;
grant execute on function app.support_ingest_status_v535(integer) to service_role;

-- ===========================================================================
-- 6. The thread reader learns to say whether a reply is possible
-- ===========================================================================
-- The page RENDERS this answer instead of deciding for itself, so turning
-- outbound on is a server change, not a front-end release.

create or replace function public.business_support_get_thread_v531(
  p_business uuid,
  p_conversation uuid,
  p_limit integer default 200
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_conversation public.support_conversations_v530%rowtype;
  v_messages jsonb;
  v_can boolean := false;
  v_reason text := null;
  v_state jsonb;
begin
  if not app.can_module_read(p_business, 'support') then
    raise exception 'support module read access required' using errcode = '42501';
  end if;

  select * into v_conversation from public.support_conversations_v530
   where id = p_conversation and business_id = p_business;
  if not found then
    raise exception 'conversation not found' using errcode = 'P0002';
  end if;

  select coalesce(jsonb_agg(entry order by entry->>'occurred_at'), '[]'::jsonb)
    into v_messages
  from (
    select jsonb_build_object(
      'message_id', m.id,
      'direction', m.direction,
      -- Staff see what a human typed. rendered_body (with the server prefix) is
      -- evidence, not UI, and provider_message_id is PII and never projected.
      'body', m.body,
      'occurred_at', m.occurred_at,
      'status', m.status,
      'error_code', m.error_code,
      'authored_by_staff_id', m.authored_by_staff_id
    ) as entry
    from public.support_messages_v530 m
    where m.conversation_id = p_conversation and m.business_id = p_business
    order by m.occurred_at
    limit greatest(coalesce(p_limit, 200), 1)
  ) rows;

  -- Same order as the chokepoint, so the UI's explanation matches the refusal
  -- the server would actually give.
  if not app.can_module_write(p_business, 'support') then v_reason := 'no_support_write_permission';
  elsif v_conversation.state <> 'open' then v_reason := 'conversation_closed';
  elsif v_conversation.service_window_expires_at is null
     or v_conversation.service_window_expires_at <= now() then v_reason := 'service_window_closed';
  elsif not app.platform_feature_enabled('whatsapp_outbound') then v_reason := 'outbound_not_enabled';
  else
    v_state := app.capability_state_v518(p_business, 'whatsapp_support_reply');
    if (v_state->>'allowed') = 'true' then v_can := true;
    else v_reason := coalesce(v_state->>'reason','capability_refused'); end if;
  end if;

  return jsonb_build_object(
    'conversation_id', v_conversation.id,
    'is_known_customer', v_conversation.client_id is not null,
    'client_id', v_conversation.client_id,
    'display_name', coalesce(
      (select nullif(btrim(c.full_name), '') from public.clients c where c.id = v_conversation.client_id),
      '+65 ' || substr(v_conversation.customer_phone_norm,1,4) || ' ' || substr(v_conversation.customer_phone_norm,5,4)),
    'state', v_conversation.state,
    'handoff_state', v_conversation.handoff_state,
    'assigned_staff_id', v_conversation.assigned_staff_id,
    'service_window_open', v_conversation.service_window_expires_at > now(),
    'service_window_expires_at', v_conversation.service_window_expires_at,
    'can_reply', v_can,
    'reply_disabled_reason', v_reason,
    'messages', v_messages);
end
$fn$;

revoke all on function public.business_support_get_thread_v531(uuid, uuid, integer)
  from public, anon, authenticated;
grant execute on function public.business_support_get_thread_v531(uuid, uuid, integer)
  to authenticated;
grant execute on function public.business_support_get_thread_v531(uuid, uuid, integer)
  to service_role;

commit;
