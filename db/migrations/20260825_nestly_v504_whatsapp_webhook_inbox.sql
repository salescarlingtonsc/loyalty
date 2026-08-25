-- NESTLY v504 - META WHATSAPP CLOUD API WEBHOOK INBOX
--
-- Owner directive 2026-08-25: build ONLY the webhook foundation for the Meta
-- WhatsApp Cloud API. Not the chatbot, not automatic replies, not business
-- routing, not the send path. Meta's dashboard is sitting on
-- "Connect on WhatsApp > Basic setup > Step 2 Production setup > Configure
-- Webhooks" and needs a Callback URL that answers its GET challenge and can
-- absorb POST deliveries without corrupting anything.
--
-- WHAT THIS IS. One durable inbox table and one ingest RPC, in the exact shape
-- v77 already uses for Stripe (public.billing_provider_events +
-- public.ingest_stripe_billing_event_v77): the edge function verifies the
-- provider's signature, hands the raw envelope to a SECURITY DEFINER RPC, and
-- the RPC is the only thing that writes. Nothing reads this table yet and
-- nothing acts on it. That is deliberate - a row here is evidence that Meta
-- called us, not an instruction to do anything.
--
-- WHY DEDUPE ON THE PAYLOAD DIGEST AND NOT ON A META EVENT ID.
-- A Meta webhook POST has no top-level event id. The body is
-- {object, entry:[{id, changes:[{value:{...}, field}]}]} and one delivery can
-- carry several statuses and several inbound messages at once. Meta retries by
-- re-POSTing the SAME bytes, so the digest of the raw body is the only key that
-- is both available and correct at this layer, and it needs no assumption
-- whatsoever about the payload's internal shape - which is precisely the
-- assumption the owner asked us not to make yet. Per-message decomposition
-- (one row per wamid, joined to a business) is a later migration; doing it now
-- would require guessing how phone_number_id maps to a tenant, and Peekaa has
-- no such mapping yet because there is exactly one Peekaa-owned sender.
--
-- A duplicate therefore does not insert. It bumps received_count and
-- last_received_at, so "did Meta retry this?" and "did we double-handle it?"
-- are answerable from the row itself rather than from logs that expire.
--
-- WHY THE EXTRACTED COLUMNS ARE ALL NULLABLE AND UNCONSTRAINED.
-- waba_id, phone_number_id, entry_kinds and meta_message_ids are read out of
-- the envelope by the edge function purely so a human can find a delivery
-- without opening the jsonb. They are observability, not contract. A payload
-- shape Meta has not documented yet still stores cleanly as entry_kinds
-- '{other}' and both ids null, and still returns 200 - a webhook that 500s on
-- an unfamiliar field is a webhook Meta eventually disables.
--
-- SIGNATURE STATUS IS RECORDED, NOT ASSUMED. signature_verified is NOT NULL and
-- the edge function sets it true only after an X-Hub-Signature-256 HMAC check
-- against the Meta app secret. The function refuses unverified POSTs outright,
-- so in normal operation every row is true; the column exists so that if that
-- policy is ever relaxed, the relaxation is visible in the data rather than
-- buried in a deployment.
--
-- ⚖️ PDPA note for counsel, not a compliance claim: an inbound WhatsApp payload
-- contains a customer's phone number and message text. This table stores the
-- raw envelope, is unreadable through the API (RLS on, zero policies, all
-- grants revoked), and is written only by service_role. No retention sweep is
-- defined here because nothing writes to it in production until the owner
-- completes Meta setup; a retention job belongs with the first real traffic.

begin;

-- ===========================================================================
-- 1. The inbox
-- ===========================================================================

create table public.whatsapp_webhook_events (
  id uuid primary key default gen_random_uuid(),
  provider text not null default 'meta_whatsapp'
    check (provider = 'meta_whatsapp'),

  -- Digest of the exact bytes Meta POSTed. See the header note.
  payload_sha256 text not null check (payload_sha256 ~ '^[0-9a-f]{64}$'),
  payload jsonb not null check (jsonb_typeof(payload) = 'object'),

  -- Observability only. Never routed on, never constrained.
  waba_id text check (waba_id is null or char_length(waba_id) between 1 and 64),
  phone_number_id text
    check (phone_number_id is null or char_length(phone_number_id) between 1 and 64),
  entry_kinds text[] not null default '{}',
  meta_message_ids text[] not null default '{}',

  signature_verified boolean not null,

  -- 'pending' is the only status anything writes today. The rest exist so the
  -- consumer this migration deliberately does not build has somewhere to land.
  processing_status text not null default 'pending'
    check (processing_status in ('pending', 'processed', 'ignored', 'failed')),
  processing_attempts integer not null default 0 check (processing_attempts >= 0),
  last_error text,
  processed_at timestamptz,

  received_count integer not null default 1 check (received_count >= 1),
  received_at timestamptz not null default now(),
  last_received_at timestamptz not null default now(),

  constraint whatsapp_webhook_events_dedupe_uk unique (provider, payload_sha256)
);

comment on table public.whatsapp_webhook_events is
  'v504 durable inbox for Meta WhatsApp Cloud API webhook deliveries. One row per distinct raw POST body; a Meta retry bumps received_count instead of inserting. Written only by public.ingest_whatsapp_webhook_event_v504 as service_role. Nothing consumes it yet.';
comment on column public.whatsapp_webhook_events.payload_sha256 is
  'SHA-256 of the exact raw request body. The idempotency key - Meta retries are byte-identical and carry no top-level event id.';
comment on column public.whatsapp_webhook_events.entry_kinds is
  'Observability only: which change kinds the envelope carried (statuses / messages / other). Never routed on.';
comment on column public.whatsapp_webhook_events.signature_verified is
  'True only after an X-Hub-Signature-256 HMAC check against the Meta app secret. The edge function refuses unverified POSTs, so this is true for every row written in normal operation.';

-- Finding a delivery by the Meta message id a customer or Meta support quotes.
create index whatsapp_webhook_events_message_ids_idx
  on public.whatsapp_webhook_events using gin (meta_message_ids);
-- The consumer this migration does not build will want its work queue.
create index whatsapp_webhook_events_pending_idx
  on public.whatsapp_webhook_events (processing_status, received_at)
  where processing_status in ('pending', 'failed');

-- RLS on with ZERO policies: unreadable and unwritable through PostgREST by
-- anon, authenticated and even a super admin. service_role bypasses RLS, which
-- is the only access path this table is meant to have.
alter table public.whatsapp_webhook_events enable row level security;
revoke all privileges on table public.whatsapp_webhook_events
  from public, anon, authenticated;

-- ===========================================================================
-- 2. The only writer
-- ===========================================================================

create or replace function public.ingest_whatsapp_webhook_event_v504(
  p_payload_sha256 text,
  p_payload jsonb,
  p_signature_verified boolean,
  p_waba_id text default null,
  p_phone_number_id text default null,
  p_entry_kinds text[] default '{}',
  p_meta_message_ids text[] default '{}'
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_inserted uuid;
  v_row public.whatsapp_webhook_events%rowtype;
begin
  -- Envelope validation, not payload interpretation. A malformed envelope is
  -- the caller's bug and must not become a row; an unfamiliar payload SHAPE is
  -- Meta's business and stores fine.
  if p_payload_sha256 !~ '^[0-9a-f]{64}$'
     or jsonb_typeof(p_payload) <> 'object'
     or p_signature_verified is null then
    raise exception 'invalid WhatsApp webhook envelope' using errcode = '22023';
  end if;

  -- An unverified delivery is not evidence of anything and must not be stored.
  -- The edge function already refuses these; this is the second wall, so a
  -- future caller cannot quietly widen the policy without editing SQL.
  if p_signature_verified is not true then
    raise exception 'unverified WhatsApp webhook delivery rejected' using errcode = '42501';
  end if;

  insert into public.whatsapp_webhook_events(
    payload_sha256, payload, signature_verified,
    waba_id, phone_number_id, entry_kinds, meta_message_ids
  ) values (
    p_payload_sha256, p_payload, p_signature_verified,
    nullif(btrim(coalesce(p_waba_id, '')), ''),
    nullif(btrim(coalesce(p_phone_number_id, '')), ''),
    coalesce(p_entry_kinds, '{}'),
    coalesce(p_meta_message_ids, '{}')
  )
  on conflict (provider, payload_sha256) do nothing
  returning id into v_inserted;

  if v_inserted is not null then
    return jsonb_build_object(
      'status', 'accepted', 'duplicate', false,
      'event_id', v_inserted, 'received_count', 1);
  end if;

  -- Meta retried. Record that it did, and say so, without touching the payload
  -- or any processing state the (future) consumer owns.
  update public.whatsapp_webhook_events
     set received_count = received_count + 1,
         last_received_at = now()
   where provider = 'meta_whatsapp'
     and payload_sha256 = p_payload_sha256
  returning * into v_row;

  return jsonb_build_object(
    'status', 'accepted', 'duplicate', true,
    'event_id', v_row.id, 'received_count', v_row.received_count);
end
$$;

revoke all on function public.ingest_whatsapp_webhook_event_v504(
  text, jsonb, boolean, text, text, text[], text[]
) from public, anon, authenticated;
grant execute on function public.ingest_whatsapp_webhook_event_v504(
  text, jsonb, boolean, text, text, text[], text[]
) to service_role;

comment on function public.ingest_whatsapp_webhook_event_v504(
  text, jsonb, boolean, text, text, text[], text[]
) is
  'v504 sole writer for public.whatsapp_webhook_events. Idempotent on the raw-body digest: a byte-identical Meta retry bumps received_count and returns duplicate=true rather than inserting. Refuses any delivery not marked signature-verified.';

commit;
