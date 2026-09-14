# Peekaa WhatsApp Phase 1 — Architecture Audit & Implementation Plan

Audited 2026-08-25 against production `gadpooereceldfpfxsod` and `origin/main` @ `875ae943` (nestly_v503).
**No code has been changed. This document is for approval only.**

---

## 1. Existing architecture found

### 1.1 The headline correction

> **There is no Twilio SMS implementation in Peekaa.** The brief asked me to inspect one and integrate
> with it. It does not exist. `twilio` appears only in three test files and four design documents, all
> describing it as *deferred*. `CLAUDE.md` has recorded "Stripe SG auto-charge and WhatsApp/SMS remain
> deferred" since v9.
>
> **Peekaa has never sent an outbound message to a phone number.** Not SMS, not WhatsApp, not email.

This is good news for the risk profile — there are no competing reminder jobs to collide with — and bad
news for the schedule, because there is no channel-router precedent to extend either.

### 1.2 What "WhatsApp" means in Peekaa today

Three things, none of them an API integration:

| Surface | What it actually is |
|---|---|
| `app-business.js` V330 — booking confirmation, appointment detail, client row | A `wa.me/` **deep link**. Staff tap it, their own WhatsApp opens with a pre-filled draft, they press send themselves. |
| `platform-console.js` SME CRM | Same — `wa.me/` links on prospect contact cards. |
| `app-customer.js` phone OTP | A `whatsapp` channel option on the sign-in OTP, gated behind `window.__FRENLY_CUSTOMER_WHATSAPP_OTP_ENABLED__` **and** a server capability probe. Both are off. This is a *Supabase Auth* code path, not a Peekaa send path. |

Plus a data model that already anticipates the channel: `app.communication_channels_v263()` returns
`['in_app','push','email','sms','whatsapp','call']`, and the bottle-service reminder picker offers
WhatsApp with the source comment: *"WhatsApp and email SENDING are deferred platform-wide; recording the
answer now means the later sweep does not have to ask the customer again."*

### 1.3 Notification / delivery infrastructure that DOES exist

I found four separate delivery-shaped systems. Only one of them is a real dispatcher, and it is not currently sending.

**A. In-app inbox — `public.notifications` (v33/v46).** 11 rows in prod. `business_id`, `kind`, `title`,
`body`, `ref_table`, `ref_id`, `read_at`. Read via `app.get_notifications`. This is a real, working,
tenant-scoped channel. **Reuse as the `in_app` channel — do not duplicate.**

**B. Web push — `customer_push_*_v95` + `customer-push-dispatch` edge function.** This is the *only*
production dispatcher pattern in the codebase and it is the correct template:

```
pg_cron (*/5)  →  app.v282_run_customer_push_dispatch()
                    ├─ reads vault.decrypted_secrets  (url + shared secret)
                    └─ net.http_post → /functions/v1/customer-push-dispatch
                                          ├─ verifies x-nestly-push-dispatch-secret
                                          ├─ rpc internal_customer_push_claim_v95  (lease, 120s, limit 50)
                                          ├─ send (bounded concurrency 8)
                                          └─ rpc internal_customer_push_report_v95 (p_idempotency_key)
```

It has: leases (`lease_token`/`lease_until`/`leased_by`), `attempt_count < 5`, `next_attempt_at`,
`status ∈ queued|retry|…`, fail-closed on unmappable event types, an idempotency key on the report call,
and an eligibility whitelist `app.customer_push_event_eligible_v95(source_kind, topic)`.

**⚠ Finding:** `v282_supabase_url` and `v282_push_dispatch_secret` are **absent from vault**. The cron has
been returning `{"dispatch":"secret_unconfigured"}` every five minutes since v282. `customer_push_subscriptions_v95`
has 0 rows, so nothing is being missed — but web push is dark in production and nobody has noticed.

**C. Growth delivery lifecycle — `growth_deliveries_v108` / `growth_delivery_dispatches_v110` /
`growth_delivery_backoff_policies_v112`.** Architecturally the closest thing to what the brief describes:
provider-neutral, `provider text`, `lifecycle_status ∈ queued|scheduled|delivering|delivered|held_out|
suppressed|failed|cancelled`, `attempt_count 0..5`, `next_attempt_at`, `provider_message_id`, `failure_code`,
a service claim/complete RPC pair, an append-only `growth_delivery_state_events_v110`, and a suppression
vocabulary that already names `consent_withdrawn`, `quiet_hours`, `frequency_cap`, `budget_cap`, `feature_disabled`.

**It is 0 rows in production and I recommend against reusing it.** Its foreign keys make every delivery
mandatory-belong to a `growth_executions_v108` row with a `link_id` and an `entitlement_id` — it models
*"an approved marketing campaign issues a single-use offer entitlement to a segment member"*. An appointment
reminder has no execution, no segment, and no entitlement. Bending it would mean synthesising fake executions
for every transactional message. Its *vocabulary* is worth copying verbatim; its *tables* are not.

**D. Synthetic capture harness — `event_outbox` + `app.run_outbox_sweep` (cron `*/2`) → `captured_messages`.**
4 rows. The sweep writes `recipient = 'synthetic:<uuid>@example.test'` with the source comment *"A real
address/number is structurally uninsertable."* This is a PS1B **simulation**, not a sender. Leave it alone.

**E. `customer_notification_outbox` (v33).** Despite the name, it is hard-locked by CHECK constraints to
`channel = 'in_app'`, `event_type = 'appointment_action_requested'`, `topic = 'booking_updates'`. It carries
*customer→business* action requests, not outbound messages. Not a spine.

### 1.4 Consent

Two stores, deliberately different, and the difference matters:

- **`customer_notification_preferences` (v33)** — per `(business_id, client_id/link_id, topic, channel)`,
  channel domain `{email, in_app}`, **absence = do not send**, has `quiet_hours_start/end/timezone`. Empty in prod.
- **`customer_communication_preferences_v263`** — account-scoped (`identity_id`), **deviation-only, absence = ON**,
  channel domain includes `whatsapp`, category domain is exactly three **marketing** categories
  (`business_offers`, `rewards_and_points`, `peekaa_updates`). 0 rows.
  Gate: `app.customer_communication_allows_v263(identity, category, channel)`.
  Audit trail: `customer_communication_preference_audit_v263`.

The v263 migration header contains a load-bearing invariant I must not break:

> `'booking_updates'` is deliberately absent: an appointment confirmation is not marketing, so it has no
> category and therefore no switch anywhere. **A row that suppresses an appointment confirmation cannot be
> stored, not merely cannot be written.**

`app.communication_category_for_topic_v263()` returns NULL for transactional topics, and
`customer_communication_allows_v263` short-circuits `true` on a NULL category.

Also present: `public.consents` (15 rows — `business_id`, `client_id`, `channel`, `action`, `source`, `actor`),
`customer_platform_marketing_consent_events` (append-only, immutability-triggered), and
`app.apply_booking_consent` / `app.staff_set_marketing_consent`.

### 1.5 Phone normalisation

`app.norm_phone(text)` exists, is `IMMUTABLE`, and is the single canonical utility. It folds
`+65 8186 3833` / `6581863833` / `065…` → `81863833`, validates the SG prefix set `{3,6,8,9}`, and returns
**NULL** for anything non-SG. `clients.phone_norm` is a GENERATED column with a partial unique index on
`(business_id, phone_norm)`. 36 of 39 prod clients have one.

**Gap:** it returns 8-digit *local* form. Meta needs E.164 (`6582088809`, no `+`). No E.164 helper exists.

### 1.6 Credits / wallet / cost

- `public.credit_ledger` is **customer store credit**, guarded (memory: only 8 named routes may append).
  **Not** a business messaging wallet. Do not touch it.
- A reserve/commit/release triple already exists for offer budgets: `budget_periods` (`committed_cents`,
  `cap_cents`), `budget_reservations` (`amount_cents`, `entitlement_id`), `budget_commitment_releases`.
  Correct *shape*, wrong *scope* (bound to growth entitlements).
- Cost rules: `growth_cost_rules_v114`, `economic_cost_rules_v109` — versioned, `cost_method`/`cost_value`/
  `currency`/`effective_from`/`effective_to`/`idempotency_key`. Good precedent for pricing a message later.
- Billing: `subscriptions`, `billing_plan_catalog_v124`, Stripe Connect + billing webhooks are live.

### 1.7 Appointments

`public.appointments`: `id, business_id, client_id, staff_id, starts_at, ends_at, status, total_cents,
created_at, party_size, source, service_id, resource_id, note, branch_id, table_type_id`. 18 rows.

**No reminder columns. No reminder job. No reminder state anywhere.** The 27 pg_cron jobs contain nothing
resembling an appointment reminder. Booking lifecycle RPCs exist (`convert_booking_request`,
`manage-booking` edge function, `notify_on_booking_request`, `notify_on_change_request`), and they write
`notifications` rows for *staff*, never to the customer's phone.

### 1.8 Webhook precedent

`stripe-billing-webhook` (verify_jwt=false) + `billing_provider_events` is the idempotency template:
signature verified before parsing, event persisted by provider event id, replay is a no-op. `_shared/security.ts`
has `sha256Hex` and HMAC helpers. `_shared/gateway.ts` has the Turnstile-gated, `cf-connecting-ip`-keyed
rate limiter from v19.

### 1.9 Superadmin

`app/platform-console.js` — a full platform console with health/inventory sections. Memory notes every
console change must update its inventories. Super admin = `leechuanseng.biz@gmail.com`, scope = read every
tenant / write platform tables only, via `app.is_super_admin()` and 46 `<t>_sa_read` policies.

---

## 2. Gaps

| # | Gap | Severity |
|---|---|---|
| G1 | **No central messaging spine.** Each of the four delivery systems is welded to one purpose. Nothing accepts `(business, customer, event_type, channel)` and routes it. | Blocking |
| G2 | **No outbound phone channel at all.** No Meta client, no BSP, no SMS. | Blocking |
| G3 | **No Meta webhook.** No `verify_jwt=false` function, no verify-challenge handler, no status ledger. | Blocking |
| G4 | **No template registry.** No approved-template concept, no `template_key → meta_template_name` map, no variable contract. | Blocking |
| G5 | **No transactional consent store.** v263 covers marketing only, and *by design* cannot express "this customer opted in to WhatsApp from this merchant". v33 covers only `{email,in_app}`. | Blocking (PDPA ⚖) |
| G6 | **No appointment reminder scheduling of any kind.** No due-time computation, no idempotent one-reminder-per-appointment guarantee, no cancel/reschedule suppression. | Blocking |
| G7 | **No E.164 formatter.** `app.norm_phone` stops at 8-digit local. | Small |
| G8 | **No business messaging wallet.** Budget triple exists but is entitlement-scoped. | Deferred-safe |
| G9 | **No business-facing comms settings.** No automation toggles, no reminder-timing control, no sent/delivered/failed counters. | Blocking for Phase 1 UI |
| G10 | **No superadmin messaging health view.** | Blocking for Phase 1 UI |
| G11 | **Web push dispatcher is unconfigured in prod** (`v282_*` vault secrets missing). Pre-existing, unrelated, but the same vault mechanism WhatsApp will use. | Should fix |
| G12 | **No quiet-hours enforcement on any live path.** v33 has the columns; nothing reads them. | Medium |

---

## 3. Exact implementation plan

### 3.1 Architecture decision

I am building the central spine the brief asks for as **new tables**, because all three reuse candidates are
structurally locked (§1.3 C/E). To honour *"do not create another parallel notification system"*, the new
engine **owns routing only** and delegates every non-WhatsApp channel to the system that already implements it:

```
appointments · rewards · points · stamps · tiers · promotions · CRM · campaigns
                              │
                              ▼   app.emit_messaging_event_v504(...)   ← the ONLY entry point
                       messaging_events                                  (business_id scoped, idempotent)
                              │
                              ▼   app.route_messaging_event_v504()
                      messaging_deliveries          one row per (event, channel)
                              │
              ┌───────────────┼─────────────────┬──────────────────┐
              ▼               ▼                 ▼                  ▼
        channel=whatsapp  channel=in_app   channel=push       channel=sms/email
        whatsapp_messages  → public.        → customer_push_    → NOT IMPLEMENTED
        + Meta Cloud API     notifications     deliveries_v95      (router returns
        (new dispatcher)     (EXISTING)        (EXISTING)          'channel_unavailable')
```

Nothing existing is rewritten. `notifications` and `customer_push_deliveries_v95` keep their current writers;
the router becomes an *additional* writer.

### 3.2 Migrations

Version numbers are provisional — `origin/main` is at **v503** and is shared with parallel sessions, so I will
rebase and take the next free block immediately before writing. Each migration carries the 8-part governance
update (two file copies, explicit grants, both plan files, both manifests, six hardcoded test counts, rollback
suite, writer-registry entries).

**`nestly_v504_messaging_spine`** — the engine.

- `public.messaging_events` — `id, business_id, branch_id NULL, client_id, identity_id NULL, event_type,
  source_ref_table, source_ref_id, idempotency_key, payload jsonb, scheduled_for, status, created_at, processed_at`.
  `UNIQUE (business_id, idempotency_key)` — this is the duplicate-prevention primitive.
  `event_type` CHECK over the 12 types in the brief. Branch FK is the composite `(branch_id, business_id)`
  form used by v110 so a branch can never cross tenants.
- `public.messaging_deliveries` — `id, event_id, business_id, branch_id, client_id, channel, status, attempt_count
  (0..5), next_attempt_at, lease_token, lease_until, leased_by, suppression_reason, failure_code, failure_detail,
  created_at, updated_at`. `UNIQUE (event_id, channel)` — a Meta retry can never create a second delivery.
  Status vocabulary copied from v110: `queued|scheduled|delivering|sent|delivered|read|suppressed|failed_retryable|failed_final|cancelled`.
  Suppression vocabulary copied from v110 plus `no_consent`, `invalid_phone`, `template_unapproved`,
  `automation_disabled`, `business_inactive`, `insufficient_credits`.
- `public.messaging_delivery_events` — append-only state transitions (mirrors `growth_delivery_state_events_v110`).
- `app.norm_phone_e164_v504(text)` — wraps `app.norm_phone`, returns `'65'||local` or NULL. One utility, no duplication.
- `app.emit_messaging_event_v504()` — SECURITY DEFINER, the single entry point. Explicit `p_business_id`,
  never inferred from a phone number.
- `app.route_messaging_event_v504()` — resolves per-business automation config + consent + channel availability,
  writes deliveries or a suppression.
- RLS on all three: tenant `business_id` policies + `<t>_sa_read` super-admin SELECT policies, matching v14.

**`nestly_v505_whatsapp_channel`** — the WhatsApp channel.

- `public.whatsapp_templates` — `id, template_key UNIQUE, meta_template_name, category (UTILITY|MARKETING|AUTHENTICATION),
  language, status (draft|submitted|approved|rejected|paused|disabled), purpose, variable_contract jsonb, enabled,
  created_at, updated_at`. **Platform-owned: no `business_id`. RLS = super-admin write, authenticated read.**
  Merchants cannot submit templates in Phase 1.
- `public.whatsapp_messages` — `id, business_id, branch_id, client_id, delivery_id UNIQUE, meta_message_id UNIQUE NULL,
  phone_e164, template_key, template_category, direction (outbound|inbound), status, sent_at, delivered_at, read_at,
  failed_at, error_code, error_message, created_at`. `UNIQUE (meta_message_id)` is the webhook idempotency anchor.
- `public.whatsapp_webhook_events` — `id, meta_event_id UNIQUE, received_at, payload_digest, processed_at, outcome`.
  Mirrors `billing_provider_events`: a Meta retry hits the unique index and returns 200 without side effects.
  **Stores a SHA-256 digest, not the raw payload** — no customer phone numbers persisted twice.
- `internal_whatsapp_claim_v505(p_worker_id, p_limit, p_lease_seconds)` / `internal_whatsapp_report_v505(...,
  p_idempotency_key)` — exact shape of the v95 pair, `service_role` only.
- `app.whatsapp_apply_status_v505(p_meta_message_id, p_status, p_at, p_error_code, p_error_message)` —
  monotonic: `sent → delivered → read` only ever advances; an out-of-order or replayed callback is a no-op.

**`nestly_v506_messaging_consent`** — consent, scoped to the merchant relationship.

- `public.customer_messaging_preferences` — `business_id, client_id, identity_id NULL, channel,
  transactional_enabled, marketing_enabled, consent_source, consent_at, withdrawn_at, updated_at`,
  PK `(business_id, client_id, channel)`. Append-only audit sibling.
- `app.messaging_consent_allows_v506(p_business_id, p_client_id, p_channel, p_event_type)`:
  1. marketing event types (`birthday`, `customer_winback`, `reward_expiring`, promotional) →
     **must** have an explicit `marketing_enabled = true` row **AND** pass the existing
     `app.customer_communication_allows_v263(identity, category, channel)`. Absence = do not send.
  2. transactional event types (appointment_*, points_earned, stamps_earned, reward_unlocked, tier_upgraded) →
     require `transactional_enabled = true` for WhatsApp specifically. v263 is **not** consulted — its
     invariant (§1.4) says a transactional message has no switch there, and I am not weakening it.
- Backfill: `app.apply_booking_consent` and the join/registration paths write a WhatsApp transactional row when
  the customer ticks the existing consent box. **No blanket backfill of existing clients** — a pre-existing
  client with no row is unreachable until they consent. That is the safe default and I will not override it.

**`nestly_v507_appointment_reminders`** — the first producer.

- `public.business_messaging_settings` — `business_id PK, whatsapp_enabled, reminder_channel
  (whatsapp|sms|email|push|none, default none), reminder_lead_minutes (default 1440), automation flags jsonb
  (`appointment_confirmation`, `appointment_reminder`, `appointment_rescheduled`, `appointment_cancelled`,
  `points_earned`, `stamps_earned`, `reward_unlocked`, `tier_upgraded`, `promotional`), quiet_hours_start/end,
  updated_at`. **Every flag defaults FALSE.** A business that does nothing sends nothing.
- `app.schedule_appointment_reminder_v507(p_appointment_id)` — computes due time, emits a `messaging_events`
  row with `idempotency_key = 'appt_reminder:' || appointment_id || ':' || starts_at`.
  **The `starts_at` in the key is what makes reschedule correct**: a moved appointment produces a new key,
  and `app.cancel_messaging_events_for_ref_v507()` cancels the queued rows carrying the old one.
- Triggers on `appointments`: AFTER INSERT → confirmation + schedule reminder; AFTER UPDATE OF `starts_at` →
  cancel old, emit rescheduled, schedule new; AFTER UPDATE OF `status` → on `cancelled`, cancel every queued
  delivery for that appointment and emit the cancellation notice. All fail-soft: a messaging failure must
  never abort a booking write.
- pg_cron `nestly-v507-messaging-router` (`*/5`) → `app.run_messaging_router_v507(500)` (promotes due
  `scheduled` events to `queued` deliveries).
- pg_cron `nestly-v507-whatsapp-dispatch` (`*/2`) → `app.v507_run_whatsapp_dispatch()` (vault + pg_net → edge fn,
  exact copy of `v282_run_customer_push_dispatch`).

**`nestly_v508_messaging_credits`** — architecture only, charging OFF.

- `public.messaging_credit_ledger` — append-only. `business_id, delivery_id, kind (reserve|capture|release|refund|topup),
  amount_cents, currency, reason, created_at`, `UNIQUE (delivery_id, kind)`. That unique constraint **is** the
  idempotency guarantee: a webhook retry attempting a second `capture` violates it and is swallowed.
- `public.messaging_credit_balance` view = `sum(topup) - sum(capture) + sum(release|refund)`.
- `public.messaging_price_rules` — versioned, modelled on `growth_cost_rules_v114`. **Seeded with no rows.
  No commercial prices are hardcoded.**
- `public.platform_messaging_config` — super-admin-only, single row, `whatsapp_credit_charging_enabled boolean
  DEFAULT false`. While false the router **skips the credit check entirely** — it does not reserve, does not
  capture, and writes no ledger rows.

### 3.3 Edge functions

**`supabase/functions/whatsapp-dispatch/index.ts`** (`verify_jwt = false`) — cloned structurally from
`customer-push-dispatch`: shared-secret header check → claim RPC → bounded-concurrency send to
`https://graph.facebook.com/v21.0/{PHONE_NUMBER_ID}/messages` → report RPC. Fails closed on an unknown
template. Never logs the token, the full phone number, or the rendered body.

**`supabase/functions/whatsapp-webhook/index.ts`** (`verify_jwt = false`):
- `GET` → Meta verify challenge, constant-time compare against `WHATSAPP_VERIFY_TOKEN`.
- `POST` → **verify `X-Hub-Signature-256` (HMAC-SHA256 with the app secret) against the raw body before
  parsing**, insert into `whatsapp_webhook_events` (unique `meta_event_id` → replay is a 200 no-op), then
  `app.whatsapp_apply_status_v505` per status. Inbound free-form messages are **recorded and ignored** —
  no auto-reply, no inbox, per the brief.
- Always returns 200 on a well-formed signed request so Meta does not enter retry backoff.

**`supabase/functions/_shared/whatsapp.ts`** — env accessors, template renderer, error mapper
(Meta code → `failed_retryable` vs `failed_final`; `131026`/`470`/`131047` are terminal for that send,
`4`/`80007`/`130429` rate limits are retryable), and a redactor used by every log line.

Secrets, server-side only, set with `supabase secrets set` — never in `app/`, never in a bundle:
`WHATSAPP_ACCESS_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_BUSINESS_ACCOUNT_ID`,
`WHATSAPP_VERIFY_TOKEN`, `WHATSAPP_APP_SECRET`, `WHATSAPP_DISPATCH_SECRET`.
Vault entries for the cron leg: `v507_supabase_url`, `v507_whatsapp_dispatch_secret`.
While I am there I will also populate the missing `v282_*` vault secrets (G11).

### 3.4 Message content

Rendered from a template whose **first body variable is always the business name**, so the merchant is
prominent even though the sender is Peekaa:

```
[Cubbly Salon]

Hi Sarah 👋

Your appointment is tomorrow:
Service: Hair Treatment
Date: 26 Aug 2026
Time: 3:00 PM
Location: Cubbly Salon — Tampines

Manage booking: {{link}}
```

Footer on every template: *"Sent by Peekaa on behalf of this business."* No template claims the number
belongs to the merchant. All times rendered through the existing SGT anchoring (`sgt()`/`sgIso()`), never
browser-local.

### 3.5 Frontend

**Business** — one new section inside the existing `settingsPage()` in `app/app-business.js`. **No new
sidebar module** (and note: memory records that `'promotions'` was once gated on a non-existent module key —
I will not invent a `'messaging'` key; the section is owner/manager-gated the way the other Settings panels are).
Shows: `Status ✓ Managed by Peekaa`, the automation checkboxes, reminder-timing select, and this month's
sent / delivered / failed counts from a read RPC. Shows **none** of: token, WABA id, phone number id, webhook config.

**Superadmin** — a WhatsApp health card in `app/platform-console.js`: connection state, sender identity,
today's queued/sent/delivered/read/failed, and a troubleshooting lookup by business / customer / meta message id /
status / error. Phone numbers rendered **masked** (`•••• 8809`) unless the row is expanded.

Both need `docs/design/ps0/writer-registry.json` entries, and `npm run bundle-stamp` before push (memory:
pushing `app.js` alone ships nothing — the CDN pins it for 4h).

### 3.6 Commit sequence

1. `feat(messaging): central messaging event spine` — v504 + tests
2. `feat(messaging): WhatsApp channel tables and template registry` — v505 + tests
3. `feat(messaging): merchant-scoped messaging consent` — v506 + tests
4. `feat(messaging): WhatsApp dispatcher and Meta webhook` — edge functions + `_shared/whatsapp.ts`
5. `feat(appointments): confirmation and reminder messaging` — v507 + triggers + cron
6. `feat(messaging): credit architecture, charging disabled` — v508
7. `feat(settings): business WhatsApp automations` — business UI
8. `feat(platform): WhatsApp health and troubleshooting` — console UI

Each commit runs its own rolled-back prod chain test before apply, per the v14/v10 precedent.

### 3.7 Test plan (every item from the brief, plus what the audit added)

| Test | Method |
|---|---|
| Tenant isolation | Rolled-back prod suite, `set local role authenticated` as a Business-B member; assert 0 rows and 42501 on write across all five new tables. Memory: verify as the real role, not the privileged one. |
| Duplicate prevention | Emit the same appointment reminder twice → one `messaging_events` row (unique idem key), one delivery. |
| Meta webhook retry | Replay the identical status payload 3× → one `whatsapp_messages` row, one `capture` ledger row, timestamps unchanged. |
| Status progression | `sent → delivered → read`; then replay `sent` after `read` → no regression. |
| Retry | Force a retryable Meta error → `failed_retryable`, `attempt_count+1`, backoff; at 5 → `failed_final`, no further claims. |
| Invalid phone | Non-SG / null `phone_norm` → `suppressed / invalid_phone`, zero Meta calls. |
| Missing consent | No consent row → `suppressed / no_consent`. |
| Disabled automation | Flag false → **no `messaging_events` row created at all**. |
| Cancelled appointment | Cancel → queued reminder `cancelled`, dispatcher never claims it. |
| Rescheduled appointment | Move `starts_at` → old key cancelled, new key queued, exactly one reminder survives. |
| Deleted / anonymised customer | Delete client → FK `ON DELETE RESTRICT` or cascade-to-cancel; assert no send and no orphan. |
| Suspended business | Set lifecycle inactive → `suppressed / business_inactive`. |
| Insufficient credits | Enable charging in the test tx, zero balance → `suppressed / insufficient_credits`, no Meta call, no ledger capture. |
| Marketing gate | P2 event types with charging/marketing template unapproved → suppressed. |
| End-to-end | One real send to **+65 82088809** on the pilot tenant before any merchant is enabled. |

---

## 4. Meta setup — the manual checklist for you

I cannot do any of this; it needs your Meta login and, at two steps, a payment method. Do them in order.

**A. Business portfolio**
1. Open <https://business.facebook.com> → confirm (or create) the **Peekaa** business portfolio.
2. Business settings → Business info → complete legal name, address, website `https://www.peekaa.asia`.
3. Start **Meta Business Verification** (Security Centre → Verify). *Start this first — it can take days,
   and the unverified tier caps you at 250 business-initiated conversations per 24h.*

**B. WhatsApp Business Account + number**
4. Business settings → Accounts → WhatsApp Accounts → **Create a WhatsApp Business Account**.
5. Add the Peekaa sender number.
   ⚠ **About +65 82088809:** confirm before you start whether that number is currently registered on the
   consumer WhatsApp or WhatsApp Business *app*. If it is, you must **delete that account inside the app
   first** — a number cannot be on both, and migrating it will disconnect your personal chats permanently.
   Tell me which you want: (a) use 82088809 as the Peekaa platform sender, or (b) use it only as the **test
   recipient** and register a separate number as the sender. **(b) is what I recommend** — the platform
   sender should be a dedicated line you never carry in your pocket.
6. Verify the number by SMS or voice call.
7. Set the **display name** to `Peekaa` and submit it for review. Set the profile photo, category, and the
   business description.

**C. App**
8. <https://developers.facebook.com> → Create app → type **Business** → name it `Peekaa Messaging`.
9. Add the **WhatsApp** product. Link it to the WABA from step 4.
10. App settings → Basic → copy the **App Secret** (this is `WHATSAPP_APP_SECRET`).
11. WhatsApp → API Setup → copy the **Phone number ID** and the **WhatsApp Business Account ID**.

**D. Token**
12. Business settings → Users → **System Users** → add `peekaa-messaging` with the **Admin** role.
13. Assign the app and the WABA to it, with **Full control**.
14. Generate a token with `whatsapp_business_messaging` + `whatsapp_business_management`, expiry **Never**.
    Copy it once — it is not shown again. This is `WHATSAPP_ACCESS_TOKEN`.

**E. Webhook** *(do this after I have deployed the function — I will give you the URL)*
15. Invent a long random string for `WHATSAPP_VERIFY_TOKEN` and send it to me.
16. App → WhatsApp → Configuration → Webhook → Callback URL
    `https://gadpooereceldfpfxsod.supabase.co/functions/v1/whatsapp-webhook`, Verify token = the string above.
17. Subscribe to **`messages`** only. Do not subscribe to the other fields in Phase 1.

**F. Templates**
18. WhatsApp Manager → Message templates → create four **UTILITY** templates in **English**:
    `peekaa_appointment_confirmation`, `peekaa_appointment_reminder`, `peekaa_appointment_rescheduled`,
    `peekaa_appointment_cancelled`. I will give you the exact body text and variable order after approval —
    **the variable order is a contract with the code and must match exactly.**
19. Submit and wait for `APPROVED`. (Utility templates usually clear within minutes to hours.)

**G. Billing & secrets**
20. Add a payment method to the WABA (Meta bills per conversation; utility conversations initiated by you
    are charged, and the free-tier allowance varies by country).
21. Send me: `WHATSAPP_ACCESS_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_BUSINESS_ACCOUNT_ID`,
    `WHATSAPP_APP_SECRET`, `WHATSAPP_VERIFY_TOKEN`.
    **Send them through a channel you are comfortable with — not in a public place.** I will set them with
    `supabase secrets set` and they will never touch the repo or a browser bundle.

I will not guess or invent any value in this list.

---

## 5. Risks

**R1 — Unwanted messages to real customers (highest).** Peekaa has 39 production clients across 14 real
businesses, 36 with phone numbers, and none of them has ever agreed to receive WhatsApp from Peekaa.
*Mitigations:* every automation flag defaults FALSE; consent is absence-means-NO for WhatsApp in both
directions; no backfill of consent for existing clients; the dispatcher is gated on a
`platform_messaging_config.whatsapp_sending_enabled` master switch that I will ship **off** and turn on for
exactly one pilot tenant. First live send goes to your own number.

**R2 — Damage to production appointments.** New triggers on `appointments` could abort a booking write.
*Mitigation:* every messaging trigger is `AFTER`, wrapped in an exception block that swallows and logs;
a rolled-back chain test asserts a booking still commits when the messaging path raises. This is the same
failure mode as the v385 profile-save bug (a non-SECURITY-DEFINER trigger broke every save for weeks) and
the v378 finalize loop — I will not repeat either.

**R3 — Duplicate reminders.** *Mitigation:* `UNIQUE (business_id, idempotency_key)` on events and
`UNIQUE (event_id, channel)` on deliveries; the key embeds `starts_at` so reschedules replace rather than
duplicate; `UNIQUE (meta_message_id)` makes webhook replay inert. There is **no existing reminder job to
collide with**, which removes the biggest class of this risk.

**R4 — Cross-tenant leakage.** *Mitigation:* `business_id` NOT NULL on every table, composite branch FKs,
RLS from day one, super-admin SELECT-only policies, and `emit_messaging_event_v504` takes an explicit
`p_business_id` — **the code never looks a business up from a phone number.** A phone number is ambiguous
across tenants by construction (the same person is a client of several businesses) and treating it as an
identifier would be the leak.

**R5 — Unexpected Meta charges.** Every business-initiated conversation costs money from your first send.
*Mitigation:* master switch off; per-business enable; bounded retries (5, then terminal); a terminal-vs-retryable
error map so a rejected template does not burn five paid attempts; and a `messaging_credit_ledger` recording
every send from day one even while merchant charging is disabled, so you can see the true cost before pricing it.

**R6 — Secret exposure.** *Mitigation:* Deno env + vault only; nothing in `app/`, `RUNTIME_CONFIG`, or any
bundle; a redactor applied to every log line; error responses return a code, never a token or a Meta body.
I will add a test asserting no `WHATSAPP_` string appears in the built browser bundles.

**R7 — Version-number collision.** `origin/main` is at v503 and other sessions share the sequence
(this has bitten before). *Mitigation:* rebase onto `origin/main` and claim the block immediately before writing.

**R8 — Local tree is 120 migrations stale.** My working copy is at v383; `origin/main` is v503. All DB findings
above are from **production** and are current, but the `app/*.js` line numbers I cite are from the stale tree.
*Mitigation:* I will build on a fresh `origin/main` worktree and re-locate every UI insertion point there.

**R9 — PDPA ⚖.** Sending marketing over WhatsApp from a platform number on behalf of a merchant raises consent-
wording and sender-identification questions I am not qualified to answer. *Mitigation:* Phase 1 enables **only**
UTILITY/transactional templates; every P2 marketing type is built but left disabled pending your counsel review.
This is a flag, not a compliance claim.

**R10 — The 24-hour customer service window.** Outside it you may only send approved templates; free-form is
rejected. Phase 1 is template-only, so this is a non-issue *now* but constrains any future inbox.

---

## Awaiting your approval

Two answers I need before I start:

1. **Is +65 82088809 the platform sender, or the test recipient?** (I recommend test recipient — see step B5.)
2. **Confirm the pilot tenant** for the first live send. Cubbly is the demo tenant; `qa-kopi-lab` is the
   simulation tenant. Neither has real customers, which is what I want for the first end-to-end test.

On approval I execute §3.6 in order, test as per §3.7, and return a production-readiness report.
