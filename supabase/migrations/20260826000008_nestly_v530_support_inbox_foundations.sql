-- NESTLY v530 - SUPPORT INBOX FOUNDATIONS (C1 + C2 + C3)
--
-- Owner rulings 2026-08-26. Entirely inert: this migration creates the module
-- key, the routing tokens and the conversation store, and NOTHING writes to any
-- of it. The inbound router is v531; there is no outbound path anywhere.
--
-- C1, C2 and C3 land together because all three are inert DDL and each of the
-- four governance updates a migration costs must be re-reconciled against a main
-- branch that moves several times an hour. Splitting inert schema into three
-- migrations buys no safety and multiplies the rebase surface. v531 is separate
-- because it is the first thing that actually does something.
--
-- ===========================================================================
-- C1. THE MODULE KEY - and why this is the dangerous part
-- ===========================================================================
-- public.module_registry is the authority: app.resolve_module_dependencies
-- raises 22023 'unknown modules' for any key absent from it, and
-- app.effective_platform_module_mode_v94 returns 'disabled' for a key no
-- business has. A feature gated on an unregistered module key refuses everyone,
-- including owners - that exact bug shipped once already, gated on 'promotions',
-- a key the registry never defined.
--
-- The key is 'support' and it is deliberately CHANNEL-NEUTRAL (owner ruling), so
-- SMS, email or web chat can join later without a second permission migration.
-- Its label is 'Inbox' because that is what a merchant should read; the word
-- "support" is internal vocabulary and never appears in the business UI.
--
-- requires_modules = {clients}: the thread shows a customer summary when the
-- conversation is linked, and the nav item lives inside the Customers group.
-- Same shape as customerintel, which requires {sales, clients}.
--
-- NOT ADDED TO ANY SECTOR BUNDLE, on purpose. Adding 'support' to the published
-- bundles would put an empty Inbox in every tenant's navigation the moment this
-- applies. app.effective_platform_module_mode_v94 short-circuits on a
-- firm_override with mode 'rw' BEFORE it consults businesses.enabled_modules, so
-- a superadmin can grant one pilot firm the Inbox through the existing
-- public.platform_module_overrides_v94 table without touching sector policy or
-- any other tenant. That is the grant path for the C5 checkpoint.
--
-- ===========================================================================
-- C2. ENTRY TOKENS - a routing hint, not a credential
-- ===========================================================================
-- The token travels INSIDE the message body, via wa.me/<number>?text=PK-<token>.
-- Three consequences the design has to own rather than wish away:
--
--   1. It is visible to the customer and survives a screenshot. So it is
--      PER-BUSINESS, never per-customer, and it authenticates NOTHING. The worst
--      an attacker achieves by reusing one is starting a conversation attributed
--      to that business - which is what the link is for. Customer identity comes
--      from the phone number resolved WITHIN the already-known business, never
--      from the token.
--   2. It must be revocable and versioned, so a leaked printed QR can be killed.
--   3. It must be stripped before staff read the message, or the Inbox shows
--      'PK-7f3a...' as the customer's opening words. v531 does the stripping.
--
-- Only the HASH is stored. This follows the ten existing token_hash tables, most
-- directly public.business_customer_join_qr_v89, which is the same object for a
-- different purpose: per-business, hashed, versioned, revocable, expiring.
--
-- ===========================================================================
-- C3. THE CONVERSATION STORE
-- ===========================================================================
-- THE SAFETY PROPERTY IS AN ORDERING: resolve the BUSINESS first (from a token
-- or an explicit selection), and only then look up the client WITHIN that
-- business. Never phone -> business. A customer who has joined three Peekaa
-- salons has one phone number and three legitimate relationships; inferring from
-- the number alone would silently pick one.
--
-- AN UNROUTED CONVERSATION IS NOT A TENANT ROW AT ALL. It lives in
-- support_pending_conversations_v530, which HAS NO business_id column. That is
-- what makes cross-tenant ambiguity fail safe: there is no value any RLS policy
-- could match, so no merchant can see an unrouted conversation even in principle.
-- It becomes a real conversation only when a business is explicitly established.
--
-- Note the pending table stores NO message content - only that a number wrote in,
-- and how often. The words stay in whatsapp_webhook_events under v528's 7-day
-- retention and are copied forward only if the conversation is actually routed.
-- An enquiry that is never claimed by any business therefore evaporates on its
-- own rather than becoming a permanent record nobody owns.
--
-- client_id IS NULLABLE AND STAYS NULL (owner ruling): a stranger messaging a
-- business does not become that business's customer. Suppliers, wrong numbers
-- and spam must not pollute the CRM. A client is linked only by an existing
-- canonical Peekaa process - joining, booking, transacting, or staff explicitly
-- choosing to add them.
--
-- service_window_expires_at is STORED, not computed at render time. Meta allows
-- a free-form reply only within 24 hours of the customer's last message; a staff
-- member must learn that the window is shut BEFORE they type a paragraph, not
-- after they press send. v531 maintains it.
--
-- occurred_at carries META's timestamp, never arrival time: Meta does not
-- guarantee webhook delivery order, so a thread ordered by arrival can show a
-- reply above the question it answers.
--
-- THE AI SEAM, deliberately inert: support_messages_v530.suggestion_source
-- exists and is always NULL in V1. The rule it encodes is that a suggestion is a
-- DRAFT A HUMAN PROMOTES, never an autonomous send. No AI code ships here.

begin;

-- ===========================================================================
-- C1. Module key
-- ===========================================================================

insert into public.module_registry(module_key, label, requires_modules, recommended_modules, sort_order)
values ('support', 'Inbox', array['clients']::text[], array[]::text[], 35)
on conflict (module_key) do nothing;

-- ===========================================================================
-- C2. Entry tokens
-- ===========================================================================

create table public.business_support_entry_tokens_v530 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  -- Channel-neutral by construction, like the module key. Today only WhatsApp
  -- issues links, but the routing concept is identical for SMS or web chat.
  channel text not null default 'whatsapp' check (channel in ('whatsapp')),
  token_hash text not null check (token_hash ~ '^[0-9a-f]{64}$'),
  token_version integer not null default 1 check (token_version >= 1),
  status text not null default 'active' check (status in ('active', 'revoked')),
  expires_at timestamptz,
  issued_by uuid,
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  constraint business_support_entry_tokens_v530_revoked_shape
    check ((status = 'revoked') = (revoked_at is not null))
);

comment on table public.business_support_entry_tokens_v530 is
  'v530 per-business support entry-routing tokens. Only the SHA-256 hash is stored; the token itself is returned once at issue and never again. A routing hint, not a credential: it identifies which business a conversation belongs to and authenticates nobody.';

create unique index business_support_entry_tokens_v530_hash_uk
  on public.business_support_entry_tokens_v530 (token_hash);
-- At most one active token per business per channel: two live tokens for the
-- same business is an ambiguity with no upside, and makes revocation unclear.
create unique index business_support_entry_tokens_v530_active_uk
  on public.business_support_entry_tokens_v530 (business_id, channel)
  where status = 'active';

alter table public.business_support_entry_tokens_v530 enable row level security;
-- No policies and no grants: the hash must never reach a browser. Businesses read
-- their token STATUS through an RPC, and the token VALUE only at issue time.
revoke all privileges on table public.business_support_entry_tokens_v530
  from public, anon, authenticated;

-- ===========================================================================
-- C3a. Unrouted conversations - platform-owned, no business_id anywhere
-- ===========================================================================

create table public.support_pending_conversations_v530 (
  id uuid primary key default gen_random_uuid(),
  channel text not null default 'whatsapp' check (channel in ('whatsapp')),
  customer_phone_norm text not null check (customer_phone_norm ~ '^[0-9]{8}$'),
  state text not null default 'awaiting_selection'
    check (state in ('awaiting_selection', 'resolved', 'expired')),
  message_count integer not null default 1 check (message_count >= 1),
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  -- Set ONLY by an explicit customer selection. Never inferred.
  resolved_business_id uuid references public.businesses(id) on delete set null,
  resolved_at timestamptz,
  constraint support_pending_conversations_v530_resolved_shape
    check ((state = 'resolved') = (resolved_business_id is not null and resolved_at is not null))
);

comment on table public.support_pending_conversations_v530 is
  'v530 inbound messages that carried no routing context. Deliberately has NO business_id: an unrouted conversation is not a tenant row, so no RLS policy can match it and no merchant can see it. Stores no message content - the words stay in whatsapp_webhook_events under v528 retention until a business is explicitly established.';

create unique index support_pending_conversations_v530_awaiting_uk
  on public.support_pending_conversations_v530 (channel, customer_phone_norm)
  where state = 'awaiting_selection';

alter table public.support_pending_conversations_v530 enable row level security;
revoke all privileges on table public.support_pending_conversations_v530
  from public, anon, authenticated;

-- ===========================================================================
-- C3b. Conversations
-- ===========================================================================

create table public.support_conversations_v530 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  channel text not null default 'whatsapp' check (channel in ('whatsapp')),
  customer_phone_norm text not null check (customer_phone_norm ~ '^[0-9]{8}$'),

  -- NULLABLE AND STAYS NULL until a canonical Peekaa process links them.
  -- Messaging a business does not make you its customer (owner ruling).
  client_id uuid,

  state text not null default 'open' check (state in ('open', 'closed')),
  routing_source text not null
    check (routing_source in ('entry_token', 'customer_selected', 'continued')),
  entry_token_id uuid references public.business_support_entry_tokens_v530(id) on delete set null,

  assigned_staff_id uuid,
  handoff_state text not null default 'unassigned'
    check (handoff_state in ('unassigned', 'assigned', 'awaiting_customer', 'resolved')),

  opened_at timestamptz not null default now(),
  last_inbound_at timestamptz,
  last_outbound_at timestamptz,
  closed_at timestamptz,
  -- last_inbound_at + 24h. Stored so the UI can warn BEFORE a reply is typed.
  service_window_expires_at timestamptz,
  unread_count integer not null default 0 check (unread_count >= 0),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint support_conversations_v530_client_scope_fk
    foreign key (client_id, business_id)
    references public.clients(id, business_id) on delete set null,
  constraint support_conversations_v530_staff_scope_fk
    foreign key (assigned_staff_id, business_id)
    references public.staff(id, business_id) on delete set null,
  constraint support_conversations_v530_closed_shape
    check ((state = 'closed') = (closed_at is not null)),
  -- Declared here, not bolted on later: support_messages_v530's composite FK
  -- needs it to already exist, and a trailing ALTER made this migration fail
  -- with 42830 on the first dry run.
  constraint support_conversations_v530_id_business_uk unique (id, business_id)
);

comment on table public.support_conversations_v530 is
  'v530 tenant-scoped support conversations. business_id is established by an entry token or an explicit customer selection and then persists; it is NEVER inferred from the phone number. client_id stays NULL for an unknown sender.';

-- One open conversation per person per business per channel. A second inbound
-- continues the existing thread rather than forking it.
create unique index support_conversations_v530_open_uk
  on public.support_conversations_v530 (business_id, channel, customer_phone_norm)
  where state = 'open';
create index support_conversations_v530_inbox_idx
  on public.support_conversations_v530 (business_id, state, last_inbound_at desc);

alter table public.support_conversations_v530 enable row level security;
revoke all privileges on table public.support_conversations_v530
  from public, anon, authenticated;

-- Defence in depth. There are no table grants today - the Inbox reads through
-- RPCs that curate the columns - but if a future change ever grants SELECT, this
-- policy already makes that read tenant-safe. app.can_module_read resolves to
-- app.staff_module_mode_v94, which returns 'disabled' unless auth.uid() is
-- ACTIVE STAFF OF THIS BUSINESS, so a staff member of business B matches nothing
-- belonging to business A.
create policy support_conversations_v530_tenant_read
  on public.support_conversations_v530 for select
  using (app.can_module_read(business_id, 'support') or app.is_super_admin());

-- ===========================================================================
-- C3c. Messages
-- ===========================================================================

create table public.support_messages_v530 (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.support_conversations_v530(id) on delete cascade,
  -- Denormalised so RLS is a single-table predicate, not a join.
  business_id uuid not null references public.businesses(id) on delete cascade,

  direction text not null check (direction in ('inbound', 'outbound')),

  -- The Meta wamid. NEVER exposed to a browser: it base64-decodes to the
  -- sender's E.164 number, so it is personal data, not an opaque key.
  provider_message_id text,

  body text,
  -- META's timestamp, not arrival. Meta does not guarantee webhook order, and a
  -- thread sorted by arrival can show an answer above its question.
  occurred_at timestamptz not null,

  status text not null default 'received'
    check (status in ('received', 'queued', 'sent', 'delivered', 'read', 'failed')),
  delivered_at timestamptz,
  read_at timestamptz,
  failed_at timestamptz,
  error_code text,

  authored_by_staff_id uuid,
  -- THE AI SEAM. Always NULL in V1. Records where a DRAFT came from; a
  -- suggestion is something a human promotes, never an autonomous send.
  suggestion_source text,

  created_at timestamptz not null default now(),

  constraint support_messages_v530_conversation_scope_fk
    foreign key (conversation_id, business_id)
    references public.support_conversations_v530(id, business_id) on delete cascade,
  constraint support_messages_v530_inbound_shape
    check (direction = 'outbound' or authored_by_staff_id is null)
);

comment on table public.support_messages_v530 is
  'v530 support message history. provider_message_id (the Meta wamid) is personal data - it base64-decodes to the sender MSISDN - and must never reach a browser or a log line.';
comment on column public.support_messages_v530.suggestion_source is
  'v530 AI extension point, always NULL in V1. A suggestion is a draft a human promotes; nothing here ever sends autonomously.';

create unique index support_messages_v530_provider_uk
  on public.support_messages_v530 (business_id, provider_message_id)
  where provider_message_id is not null;
create index support_messages_v530_thread_idx
  on public.support_messages_v530 (conversation_id, occurred_at);

alter table public.support_messages_v530 enable row level security;
revoke all privileges on table public.support_messages_v530
  from public, anon, authenticated;

create policy support_messages_v530_tenant_read
  on public.support_messages_v530 for select
  using (app.can_module_read(business_id, 'support') or app.is_super_admin());

commit;
