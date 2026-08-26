-- NESTLY v531 - SUPPORT INBOUND ROUTER AND READ-ONLY INBOX (C4 + C5 server half)
--
-- Owner gate 2026-08-26: C1-C5 only. This migration reads inbound WhatsApp
-- deliveries and turns them into tenant-scoped conversations. It contains NO
-- outbound path of any kind - no Graph API call, no queue, no reply RPC. The
-- only way a message leaves Peekaa remains: there isn't one.
--
-- ===========================================================================
-- THE ROUTING RULE, in the order it is evaluated
-- ===========================================================================
--   1. A VALID entry token in the body        -> that business. routing_source='entry_token'
--   2. No token, EXACTLY ONE open conversation for this phone
--                                              -> continue it. routing_source unchanged
--   3. Everything else                         -> PENDING. No business. No guess.
--
-- Case 3 deliberately swallows every ambiguity:
--   * no token and no open conversation        -> a stranger, business unknown
--   * no token and TWO open conversations      -> a customer of two Peekaa firms.
--     This is the case the owner's ruling exists for. The phone number alone
--     cannot say which firm they meant, so we must not choose. Pending.
--   * a token that is revoked, expired, unknown or malformed -> pending. An
--     invalid token is NOT a reason to fall back to guessing; it is a reason to
--     ask. A revoked token must never still route.
--
-- Because C6 is gated, we cannot yet SEND the "which business?" selector. So a
-- pending row records that someone wrote in and stops there. That is the honest
-- state of a receive-only system, and it is visible to Peekaa alone.
--
-- ===========================================================================
-- WHAT THE ROUTER WILL NOT DO
-- ===========================================================================
--   * It will not create a clients row. Owner ruling: messaging a business does
--     not make you its customer. It LINKS to a client that already exists in
--     THAT business, matched on phone_norm; otherwise client_id stays NULL and
--     the Inbox says "Unknown".
--   * It will not infer a business from a phone number. The phone is only ever
--     consulted AFTER a business is known, to find that business's own client.
--   * It will not mix two businesses into one thread. A new valid token for a
--     different business opens a SEPARATE conversation; the old one is left
--     alone, not re-pointed.
--   * It will not put the routing token in front of staff. The token is stripped
--     from the stored body, so the Inbox shows what the customer meant to say.
--
-- ===========================================================================
-- ORDERING AND IDEMPOTENCY
-- ===========================================================================
-- occurred_at is META's timestamp, never arrival: Meta does not guarantee
-- webhook order. support_messages_v530 is unique on (business_id,
-- provider_message_id), so a Meta retry - or a re-run of this sweep over the
-- same webhook row - inserts nothing the second time.
--
-- The sweep claims webhook rows with `for update skip locked` and flips
-- processing_status, so two concurrent runs cannot double-handle one delivery.

begin;

-- ===========================================================================
-- 1. Token helpers
-- ===========================================================================

-- The marker the wa.me link embeds. Bounded and anchored so a customer typing
-- something that merely looks token-ish cannot select a tenant.
create or replace function app.support_extract_entry_token_v531(p_body text)
returns text
language sql
immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select (regexp_match(coalesce(p_body, ''), 'PK-([A-Za-z0-9_-]{22,64})'))[1]
$$;

-- What staff actually read. Removes the token and any "(Ref: ...)" wrapper the
-- prefilled link put around it, then tidies the whitespace that leaves behind.
create or replace function app.support_strip_entry_token_v531(p_body text)
returns text
language sql
immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select nullif(btrim(regexp_replace(
    regexp_replace(coalesce(p_body, ''),
      '\(\s*(Ref|Ref\.|Reference)?\s*:?\s*PK-[A-Za-z0-9_-]{22,64}\s*\)', '', 'gi'),
    'PK-[A-Za-z0-9_-]{22,64}', '', 'g')), '')
$$;

-- ===========================================================================
-- 2. Token issue / status / revoke  (C2 functional half)
-- ===========================================================================

-- Returns the token ONCE. Only the hash is stored, so it can never be read back
-- - the same posture as business_customer_join_qr_v89.
create or replace function public.business_issue_support_entry_token_v531(
  p_business uuid,
  p_channel text default 'whatsapp'
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_token text;
  v_hash text;
  v_version integer;
  v_id uuid;
begin
  if not app.can_module_write(p_business, 'support') then
    raise exception 'support module write access required' using errcode = '42501';
  end if;
  if p_channel <> 'whatsapp' then
    raise exception 'unsupported channel' using errcode = '22023';
  end if;

  select coalesce(max(token_version), 0) + 1 into v_version
    from public.business_support_entry_tokens_v530
   where business_id = p_business and channel = p_channel;

  -- 32 bytes of urlsafe randomness, matching the join-QR strength.
  -- pgcrypto lives in the `extensions` schema on Supabase, which is NOT on this
  -- function's search_path. Qualify it rather than widening search_path — a
  -- SECURITY DEFINER function with a loose search_path is a privilege-escalation
  -- shape, and the first run of the acceptance suite caught this as a 42883.
  v_token := replace(replace(encode(extensions.gen_random_bytes(32), 'base64'), '+', '_'), '/', '-');
  v_token := replace(v_token, '=', '');
  v_hash := app.ps1b_sha256(v_token);

  update public.business_support_entry_tokens_v530
     set status = 'revoked', revoked_at = now()
   where business_id = p_business and channel = p_channel and status = 'active';

  insert into public.business_support_entry_tokens_v530(
    business_id, channel, token_hash, token_version, status, issued_by)
  values (p_business, p_channel, v_hash, v_version, 'active', auth.uid())
  returning id into v_id;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, auth.uid(), 'support_entry_token_issued',
          'business_support_entry_tokens_v530', v_id,
          jsonb_build_object('channel', p_channel, 'token_version', v_version));

  -- The ONLY time the token value exists outside the caller's browser.
  return jsonb_build_object(
    'status', 'ok', 'token_version', v_version, 'token', 'PK-' || v_token);
end
$fn$;

revoke all on function public.business_issue_support_entry_token_v531(uuid, text)
  from public, anon, authenticated;
grant execute on function public.business_issue_support_entry_token_v531(uuid, text)
  to authenticated;
grant execute on function public.business_issue_support_entry_token_v531(uuid, text)
  to service_role;

-- Status only. Never returns the hash, never the token.
create or replace function public.business_get_support_entry_status_v531(
  p_business uuid,
  p_channel text default 'whatsapp'
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare v_row public.business_support_entry_tokens_v530%rowtype;
begin
  if not app.can_module_read(p_business, 'support') then
    raise exception 'support module read access required' using errcode = '42501';
  end if;
  select * into v_row from public.business_support_entry_tokens_v530
   where business_id = p_business and channel = p_channel and status = 'active';
  if not found then
    return jsonb_build_object('has_active_token', false);
  end if;
  return jsonb_build_object(
    'has_active_token', true,
    'token_version', v_row.token_version,
    'issued_at', v_row.created_at,
    'expires_at', v_row.expires_at);
end
$fn$;

revoke all on function public.business_get_support_entry_status_v531(uuid, text)
  from public, anon, authenticated;
grant execute on function public.business_get_support_entry_status_v531(uuid, text)
  to authenticated;
grant execute on function public.business_get_support_entry_status_v531(uuid, text)
  to service_role;

-- ===========================================================================
-- 3. THE ROUTER  (C4)
-- ===========================================================================

create or replace function app.support_route_inbound_v531(p_limit integer default 200)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_event record;
  v_change jsonb;
  v_message jsonb;
  v_phone_raw text;
  v_phone text;
  v_body text;
  v_clean text;
  v_token text;
  v_business uuid;
  v_token_id uuid;
  v_routing text;
  v_open_count integer;
  v_conversation uuid;
  v_client uuid;
  v_occurred timestamptz;
  v_wamid text;
  v_routed integer := 0;
  v_pending integer := 0;
  v_skipped integer := 0;
begin
  for v_event in
    select * from public.whatsapp_webhook_events
     where processing_status = 'pending'
     order by received_at
     for update skip locked
     limit greatest(p_limit, 1)
  loop
    begin
      for v_change in
        select change
          from jsonb_array_elements(coalesce(v_event.payload->'entry', '[]'::jsonb)) entry,
               jsonb_array_elements(coalesce(entry->'changes', '[]'::jsonb)) change
      loop
        for v_message in
          select msg from jsonb_array_elements(
            coalesce(v_change->'value'->'messages', '[]'::jsonb)) msg
        loop
          v_phone_raw := v_message->>'from';
          v_phone := app.norm_phone(v_phone_raw);
          v_wamid := v_message->>'id';
          v_occurred := to_timestamp((v_message->>'timestamp')::bigint);
          v_body := coalesce(v_message->'text'->>'body', '');

          -- A number app.norm_phone cannot fold is not a Singapore mobile. Fail
          -- VISIBLY: skip it and say so, rather than inventing an address.
          if v_phone is null then
            v_skipped := v_skipped + 1;
            continue;
          end if;

          v_token := app.support_extract_entry_token_v531(v_body);
          v_clean := app.support_strip_entry_token_v531(v_body);
          v_business := null;
          v_token_id := null;
          v_routing := null;

          -- (1) a VALID token wins.
          if v_token is not null then
            select token_row.business_id, token_row.id
              into v_business, v_token_id
              from public.business_support_entry_tokens_v530 token_row
             where token_row.token_hash = app.ps1b_sha256(v_token)
               and token_row.status = 'active'
               and (token_row.expires_at is null or token_row.expires_at > now());
            if v_business is not null then
              v_routing := 'entry_token';
            end if;
            -- An invalid/revoked/expired token falls through to pending, NOT to
            -- continuation: a killed token must never route again.
          end if;

          -- (2) no valid token: continue an existing thread only if there is
          -- EXACTLY ONE. Two open conversations means two businesses have a
          -- claim and the phone number cannot arbitrate.
          if v_business is null and v_token is null then
            -- Counted and fetched SEPARATELY on purpose. The obvious
            -- `select count(*), min(business_id)` does not compile: Postgres has
            -- no min() for uuid, and because the router swallows exceptions per
            -- event, that mistake failed EVERY untokened message into
            -- 'failed' silently rather than loudly. Caught by the acceptance
            -- suite before any real traffic took this path.
            select count(*) into v_open_count
              from public.support_conversations_v530 conversation
             where conversation.customer_phone_norm = v_phone
               and conversation.channel = 'whatsapp'
               and conversation.state = 'open';
            if v_open_count = 1 then
              select conversation.business_id into v_business
                from public.support_conversations_v530 conversation
               where conversation.customer_phone_norm = v_phone
                 and conversation.channel = 'whatsapp'
                 and conversation.state = 'open';
              v_routing := 'continued';
            else
              -- Zero (a stranger) or two-or-more (two firms have a claim).
              -- Either way the phone number cannot arbitrate. Pending.
              v_business := null;
            end if;
          end if;

          -- (3) still unknown: pending. No business, no tenant row, no guess.
          if v_business is null then
            insert into public.support_pending_conversations_v530(
              channel, customer_phone_norm, state, message_count, first_seen_at, last_seen_at)
            values ('whatsapp', v_phone, 'awaiting_selection', 1, now(), now())
            on conflict (channel, customer_phone_norm) where state = 'awaiting_selection'
            do update set message_count = public.support_pending_conversations_v530.message_count + 1,
                          last_seen_at = now();
            v_pending := v_pending + 1;
            continue;
          end if;

          -- The business is now known. ONLY NOW may we look at the phone, and
          -- only to find THIS business's own client. Never creates one.
          select client_row.id into v_client
            from public.clients client_row
           where client_row.business_id = v_business
             and client_row.phone_norm = v_phone
           limit 1;

          insert into public.support_conversations_v530(
            business_id, channel, customer_phone_norm, client_id, state,
            routing_source, entry_token_id, opened_at, last_inbound_at,
            service_window_expires_at, unread_count)
          values (v_business, 'whatsapp', v_phone, v_client, 'open',
                  coalesce(v_routing, 'entry_token'), v_token_id, now(), v_occurred,
                  v_occurred + interval '24 hours', 1)
          on conflict (business_id, channel, customer_phone_norm) where state = 'open'
          do update set
            last_inbound_at = greatest(
              public.support_conversations_v530.last_inbound_at, excluded.last_inbound_at),
            service_window_expires_at = greatest(
              public.support_conversations_v530.service_window_expires_at,
              excluded.service_window_expires_at),
            unread_count = public.support_conversations_v530.unread_count + 1,
            -- Link a client we did not know about before, but never unlink one.
            client_id = coalesce(public.support_conversations_v530.client_id, excluded.client_id),
            updated_at = now()
          returning id into v_conversation;

          insert into public.support_messages_v530(
            conversation_id, business_id, direction, provider_message_id,
            body, occurred_at, status)
          values (v_conversation, v_business, 'inbound', v_wamid,
                  v_clean, v_occurred, 'received')
          on conflict (business_id, provider_message_id)
            where provider_message_id is not null
          do nothing;

          v_routed := v_routed + 1;
        end loop;
      end loop;

      update public.whatsapp_webhook_events
         set processing_status = 'processed', processed_at = now(),
             processing_attempts = processing_attempts + 1
       where id = v_event.id;

    exception when others then
      update public.whatsapp_webhook_events
         set processing_status = 'failed',
             processing_attempts = processing_attempts + 1,
             last_error = sqlerrm
       where id = v_event.id;
    end;
  end loop;

  return jsonb_build_object(
    'routed', v_routed, 'pending', v_pending, 'skipped_non_sg', v_skipped);
end
$fn$;

revoke all on function app.support_route_inbound_v531(integer)
  from public, anon, authenticated;
grant execute on function app.support_route_inbound_v531(integer) to service_role;

do $cron$
begin
  if to_regnamespace('cron') is not null
     and to_regprocedure('cron.schedule(text,text,text)') is not null then
    perform cron.schedule(
      'nestly-v531-support-inbound-router',
      '* * * * *',
      $command$select app.support_route_inbound_v531(200)$command$);
  end if;
exception when others then null;
end $cron$;

-- ===========================================================================
-- 4. The Inbox reads  (C5 server half)
-- ===========================================================================
-- Curated JSON, never table grants. This is what keeps the wamid out of the
-- browser by construction rather than by the front-end remembering not to ask.

create or replace function public.business_support_list_conversations_v531(
  p_business uuid,
  p_state text default 'open',
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare v_rows jsonb;
begin
  if not app.can_module_read(p_business, 'support') then
    raise exception 'support module read access required' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(entry order by entry->>'last_inbound_at' desc), '[]'::jsonb)
    into v_rows
  from (
    select jsonb_build_object(
      'conversation_id', conversation.id,
      -- The customer's own number, which they chose to message this business
      -- from. Formatted for reading, never the raw provider value.
      'display_name', coalesce(nullif(btrim(client_row.full_name), ''),
                               '+65 ' || substr(conversation.customer_phone_norm,1,4)
                                      || ' ' || substr(conversation.customer_phone_norm,5,4)),
      'is_known_customer', conversation.client_id is not null,
      'client_id', conversation.client_id,
      'unread_count', conversation.unread_count,
      'last_message', (
        select left(coalesce(m.body, ''), 140) from public.support_messages_v530 m
         where m.conversation_id = conversation.id
         order by m.occurred_at desc limit 1),
      'last_inbound_at', conversation.last_inbound_at,
      'assigned_staff_id', conversation.assigned_staff_id,
      'assigned_staff_name', staff_row.full_name,
      'handoff_state', conversation.handoff_state,
      'state', conversation.state,
      'service_window_open', conversation.service_window_expires_at > now(),
      'service_window_expires_at', conversation.service_window_expires_at
    ) as entry
    from public.support_conversations_v530 conversation
    left join public.clients client_row on client_row.id = conversation.client_id
    left join public.staff staff_row on staff_row.id = conversation.assigned_staff_id
    where conversation.business_id = p_business
      and (p_state is null or conversation.state = p_state)
    order by conversation.last_inbound_at desc nulls last
    limit greatest(coalesce(p_limit, 100), 1)
  ) rows;

  return jsonb_build_object('business_id', p_business, 'conversations', v_rows);
end
$fn$;

revoke all on function public.business_support_list_conversations_v531(uuid, text, integer)
  from public, anon, authenticated;
grant execute on function public.business_support_list_conversations_v531(uuid, text, integer)
  to authenticated;
grant execute on function public.business_support_list_conversations_v531(uuid, text, integer)
  to service_role;

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
begin
  if not app.can_module_read(p_business, 'support') then
    raise exception 'support module read access required' using errcode = '42501';
  end if;

  -- business_id is in the predicate, not merely trusted from the caller: a
  -- conversation id from another tenant simply does not match.
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
      'body', m.body,
      'occurred_at', m.occurred_at,
      'status', m.status,
      'authored_by_staff_id', m.authored_by_staff_id
      -- provider_message_id is deliberately absent. It decodes to the sender's
      -- phone number, so it is personal data and never leaves the server.
    ) as entry
    from public.support_messages_v530 m
    where m.conversation_id = p_conversation and m.business_id = p_business
    order by m.occurred_at
    limit greatest(coalesce(p_limit, 200), 1)
  ) rows;

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
    -- C5 is read-only by construction, and the UI reads this rather than
    -- assuming. When C6 ships this becomes a real capability check.
    'can_reply', false,
    'reply_disabled_reason', 'outbound_not_enabled',
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
