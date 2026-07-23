# PS-0 Event Contract (scope B) — FREEZE

Status: **PS-0 contract, freeze-ready.** Author: PS-0 contracts author. Reports to Fable 5.
Source of authority: `docs/design/PROGRAM_STUDIO_ARCHITECTURE.md` rev 4, §3, §6, §7, §10,
plus decision logs §1/§1a/§1b/§1c. This document EXPANDS §6 into a freeze-ready registry
and envelope contract; it does not redesign. Every schema claim is grounded in
`supabase/migrations/*.sql` (latest migration wins). Points where precision forced a
decision the architecture left open are listed in **§9 Decisions made during freeze**.

> **Build status of the tables specified here.** `domain_events`, `event_outbox`,
> `rule_effect_log`, `benefit_registry`, and `benefit_fulfilments` **do not exist in the
> live schema today** (grep of every `create table` across `supabase/migrations/*.sql`
> confirms — see the writer-audit deliverable). They are introduced in PS-1A/PS-1B per
> ARCHITECTURE §17. This contract is the freeze that those migrations must implement. The
> *producers* named here are all **live today** and are cited to their current tables/RPCs.

---

## 1. The immutable envelope: `domain_events`

`domain_events` is append-only and immutable. It is written by a producer **in the same
transaction as the source fact** (ARCHITECTURE §6). One row = one economically distinct
domain fact.

### 1.1 Fields (verbatim-consistent with §6, typed and made precise)

| Column | Type | Null | Rule |
|---|---|---|---|
| `event_id` | uuid | no | PK, `default gen_random_uuid()`. **Reference identity only** — never a dedup key (§6 owner correction). |
| `business_id` | uuid | no | FK → `businesses(id)`. Tenant scope; every RLS + `sa_read` policy keys on it (§18). |
| `event_type` | text | no | CHECK against the registered set (§2). Immutable enum extended only by additive migration. |
| `schema_version` | smallint | no | Payload schema version for this `event_type`. Starts at `1`. Part of the producer-identity unique key. |
| `source_operation_id` | text | no | **Deterministic** producer identity component (§3). Text so both uuid-derived and composed scheduled/period keys fit one column. |
| `subject_client_id` | uuid | yes | FK → `clients(id, business_id)` composite. Present for customer-subject events. |
| `subject_identity_id` | uuid | yes | FK → `customer_identities(id)`. Present when the subject is a wallet identity (customer-app origin). |
| `occurred_at` | timestamptz | no | Business time of the source fact (e.g. `sales.occurred_at`). |
| `recorded_at` | timestamptz | no | `default now()`. Wall-clock insert time. Immutable once written. |
| `config_version_id` | uuid | yes | FK → `firm_config_versions(id, business_id)`. The config in force when the fact occurred; stamped like `sales.config_version_id` / `credit_ledger.config_version_id` (`supabase/migrations/20260721000005_frenly_v26_immutable_config_versions.sql:155,158`). |
| `payload` | jsonb | no | Canonical payload (§4). `CHECK (jsonb_typeof(payload) = 'object')`. |
| `payload_hash` | text | no | `CHECK (payload_hash ~ '^[0-9a-f]{64}$')` — sha256 hex of the canonical payload (§5). |

### 1.2 Immutability & append-only requirements

- **No UPDATE, no DELETE, ever.** Enforced by a `BEFORE UPDATE OR DELETE` guard trigger that
  raises, exactly as the live append-only pattern
  (`app.v41_operation_immutable_guard`, `supabase/migrations/20260721074441_frenly_v41_customer_module_hardening.sql:260`;
  `visit_feedback` DELETE → `23001`, UPDATE → `42501`, per `db/tests/v53_visit_feedback.sql:213-219`).
- **`recorded_at`, `payload`, `payload_hash` are write-once.** A correction is a NEW event
  (§7), never a mutation.
- **Composite tenant FKs** (`(subject_client_id, business_id)`, `(config_version_id, business_id)`)
  so an event can never reference another tenant's row — same discipline as
  `credit_ledger_client_same_tenant` (`…v20_financial_engine.sql:493`).
- **RLS + `sa_read`** on the table; `revoke all … from public, anon, authenticated`; writes
  only through `security definer` producers (§18, matching every post-v33 table).

### 1.3 Producer identity — the deduplication contract (§6 owner correction)

```
UNIQUE (business_id, event_type, source_operation_id, schema_version)
```

`event_id` (a random uuid) is **identity for referencing** an event; it is **never** a
deduplication key. The producer-identity unique key guarantees the same source fact cannot
be emitted twice as two economically equivalent events under two fresh UUIDs. Producers
insert with `ON CONFLICT (business_id, event_type, source_operation_id, schema_version) DO
NOTHING` — a re-invocation of any producer with the same source fact inserts **zero** rows.

**Schema upgrades are not a dedup bypass.** Emitting an already-emitted source fact under a
higher `schema_version` is a distinct unique-key tuple and would therefore insert a second
row — this is **forbidden** by the correction rules (§7): a superseding restatement of an
existing fact must be a typed correction event that *references* the original, never a silent
re-emit under a bumped version.

---

## 2. Event registry

Every event type below is a **source fact** produced by a live mechanism. Effects (points
earn, retention grant, discount, notification) are **driven off these events by rules**;
they are not themselves envelope events (ARCHITECTURE §3 — `rule_effect_log` references
`domain_events`, `benefit_fulfilments`; §6 — producers write events, effects consume them).

`schema_version = 1` for every entry at freeze. "Producer (live today)" cites the current
writer; "→ event on cutover" means the producer emits the envelope row once PS-1B lands.

### 2.1 Transactional producers (source_operation_id = source row/operation key)

| # | `event_type` | Producer (live today) | `source_operation_id` derivation | Subject |
|---|---|---|---|---|
| 1 | `sale.completed` | Sale pipeline: `record_quick_sale` (`…v20_financial_engine.sql:1649`), `record_sale_by_phone` (`…v20:964` / `…v14c`), `record_cart_sale` (`…v20`), appointment-completion sale (`app.on_sale_recorded`, `…v10_sale_policy.sql:76`) | `sale:{sales.id}` | `subject_client_id = sales.client_id` (nullable — walk-in/gift-card issuance has none) |
| 2 | `sale.reversed` | Sale reversal engine (`sale_reversal_audits`, `…v20_financial_engine.sql`; `sale_reversal_payment_links`) | `sale_reversal:{sale_reversal_audits.id}` | subject = reversed sale's `client_id` |
| 3 | `points.redeemed` | `redeem_points` / `redeem_reward` via `loyalty_operations` (`…v24a_redemption_idempotency.sql:11`) + `loyalty_redemptions` (`…v23_loyalty_points_tiers.sql:33`) | `loyalty_op:{loyalty_operations.id}` | `subject_client_id = loyalty_operations.client_id` |
| 4 | `giftcard.issued` | `issue_gift_card` (`…v41:234`, op-ledger `gift_card_issue_operations`) | `giftcard_issue:{gift_card_issue_operations.id}` | subject = `purchaser_client_id` (nullable) |
| 5 | `giftcard.redeemed` | `redeem_gift_card` (`…v20_financial_engine.sql`) | `giftcard_redeem:{gift_cards.id}:{credit_ledger.id}` (the load row it mints) | `subject_client_id = p_client` |
| 6 | `package.sold` | `sell_package` (`…v51a_idempotent_sell_overloads.sql:33`, op-ledger `sale_intent_operations`) | `sale_intent:{sale_intent_operations.id}` | subject = `client_packages.client_id` |
| 7 | `package.session_used` | `use_package_session` (`…v34_reversal_provenance.sql`, op-ledger `package_session_consumptions`) | `pkg_consumption:{package_session_consumptions.id}` | subject = consumption `client_id` |
| 8 | `package.session_reversed` | package reversal (`package_session_reversals`, `…v34`) | `pkg_reversal:{package_session_reversals.id}` | subject = `client_id` |
| 9 | `membership.enrolled` | `enroll_membership` (`…v20`; op-ledger `sale_intent_operations` kind `membership_enroll`, `…v51a:33`) | `sale_intent:{sale_intent_operations.id}` | subject = `memberships.client_id` |
| 10 | `membership.renewed` | `app.run_membership_renewals()` per-membership renewal write (`…v20:1311`) — a per-row transactional fact even though invoked by cron | `membership_renewal:{memberships.id}:{period_key}` (see §3.2) | subject = `memberships.client_id` |
| 11 | `birthday.activated` | `customer_birthday_activation_operations` (`…c45_birthday_benefits.sql:147`) | `birthday_activation:{customer_birthday_activation_operations.id}` | `subject_identity_id = identity_id`, `subject_client_id = client_id` |
| 12 | `birthday.redeemed` | `customer_birthday_redemptions` (op_kind=`redemption`, `…c45:165`) | `birthday_redemption:{customer_birthday_redemptions.id}` | subject = `client_id` |
| 13 | `birthday.redemption_reversed` | `customer_birthday_redemptions` (op_kind=`reversal`) | `birthday_redemption:{customer_birthday_redemptions.id}` | subject = `client_id` |
| 14 | `referral.qualified` | referral qualification on first qualifying sale (`app.on_sale_recorded`, `…v10:76`; `referrals.status='qualified'`, `…frenly_init.sql:117`; legacy provenance `legacy_referral_*`, `…v20`) | `referral_qualify:{referrals.id}` | subject = `referred_client_id` |
| 15 | `credit.tendered` | credit tender allocation (`credit_tenders`, `…v20_financial_engine.sql:539`) | `credit_tender:{credit_tenders.id}` | subject = `client_id` |
| 16 | `payment.recorded` | `payments` insert (`…v11b_money.sql`) | `payment:{payments.id}` | subject = `payments.client_id` (nullable) |
| 17 | `consent.changed` | `consents` insert (`…v3_engine.sql:96`) | `consent:{consents.id}` | subject = `consents.client_id` |
| 18 | `feedback.submitted` | `customer_submit_visit_feedback` (`…v53_visit_feedback.sql`; `visit_feedback`) | `visit_feedback:{visit_feedback.id}` | subject = `client_id` / `identity_id` |

**PS-2+ transactional producers (specified now, emit on their phase):**

| # | `event_type` | Producer (future) | `source_operation_id` | Subject |
|---|---|---|---|---|
| 19 | `stored_value.topup` | SV top-up op → `sv_lots` mint (PS-2, §5) | `sv_op:{sv_operation_id}` | subject client |
| 20 | `stored_value.spent` | SV spend allocation → `sv_lot_movements` (PS-2) | `sv_spend:{operation}:{movement}` (registered key, §3, N6) | subject client |
| 21 | `stored_value.refunded` | SV refund op (PS-2, §5 refund matrix) | `sv_refund:{sv_operation_id}` | subject client |
| 22 | `tier.changed` | tier engine (PS-3, `client_tier_status`, §12) | `tier_eval:{client}:{period_key}` | subject client |

### 2.2 Scheduled / period producers (source_operation_id = deterministic source key)

These fire from `pg_cron`. A re-run of the same sweep/period **must** produce the same
producer identity so the unique key swallows it (§6). Format per §3.2.

| # | `event_type` | Producer (live today) | `source_operation_id` derivation | Subject |
|---|---|---|---|---|
| 23 | `points.expired` | `app.run_points_expiry()` cron `frenly-points-expiry` (`…v3_engine.sql:291`; `…v20:1054`; schedule `0 19 * * *` UTC = 03:00 SGT, `…v3` cron.schedule) | per expired batch: `sweep:points_expiry:{business}:{sgt_date}:{points_batches.id}` | subject = batch `client_id` |
| 24 | `membership.renewal_swept` | `app.run_membership_renewals()` cron `frenly-membership-renewals` (`…v5:148`; `…v20:1311`; `10 19 * * *`) | `sweep:membership_renewals:{business}:{sgt_date}` (sweep-run event; the per-membership renewal is event #10) | none (business-level) |
| 25 | `booking.expired` | `app.expire_stale_bookings()` cron `frenly-booking-expiry` (`…v15b:76`; `* * * * *`) | per expired booking: `sweep:booking_expiry:{business}:{booking_id}` | subject = booking client (nullable) |
| 26 | `expense.recurred` | cron `frenly-expense-recurrences` (`…v11b_money.sql`, `20 19 * * *`; `expense_recurrences`) | `sweep:expense_recurrence:{business}:{recurrence_id}:{sgt_period}` | none (business-level) |

**PS-3+ period producers (specified now):**

| # | `event_type` | Producer (future) | `source_operation_id` | Subject |
|---|---|---|---|---|
| 27 | `recurring_perk.materialised` | lazy entitlement materialisation (PS-1B/§15) | `period:{rule}:{client}:{period_key}` | subject client |
| 28 | `tier.entry_reward` | tier-entry reward (PS-3, §12) | `tier_entry:{client}:{tier}` | subject client |

---

## 3. Canonical `source_operation_id` derivation

`source_operation_id` is **always deterministic from the source fact** (§6). It is the input
to the producer-identity unique key. Two rules, one per producer class.

### 3.1 Transactional producers
`source_operation_id = '{prefix}:{operation-ledger id | source row id}'`, using the
**operation-ledger row** where one exists (it is already the idempotency authority):
`loyalty_operations`, `sale_intent_operations`, `gift_card_issue_operations`,
`package_session_consumptions`, `customer_birthday_*_operations`, `credit_tenders`. Where no
op-ledger exists, the source business row id is used (`sale:{sales.id}`,
`consent:{consents.id}`). Because those ledgers already carry
`UNIQUE(business_id, idempotency_key)` (e.g. `sale_intent_operations`, `…v51a:33`;
`loyalty_operations`, `…v24a:11`), the derived `source_operation_id` inherits their
exactly-once guarantee, and the envelope unique key is a redundant second guard by
construction.

### 3.2 Scheduled / period producers
`source_operation_id = 'sweep:{job}:{business}:{sgt_date}[:{row}]'` or
`'period:{rule}:{client}:{period_key}'`. The date/period token is **SGT-derived** and
canonical (e.g. `2026-08`, `2026-W32-day15`, matching the live SGT `period_key` convention in
`…v15` / recurring-perk §15). Determinism requirement: **the token is computed from the
scheduled period boundary, never from `now()`** — so a delayed or re-run sweep for the same
SGT date/period yields byte-identical `source_operation_id` and is swallowed by the unique
key. (Decision D1.)

---

## 4. Payload canonicalization & schema v1

Each `event_type` has a **registered payload schema** at `schema_version = 1`: an explicit,
ordered field list of scalars and catalog references only. Canonicalization rule (identical
to the rule-compiler canonical form, ARCHITECTURE §8, and to the live request-hash pattern
`request_hash = md5(request_payload::text)` on typed jsonb, `…v24a:11`,
`…v34:package_session_consumptions`):

1. **Object keys sorted** ascending (byte order).
2. **Numbers normalized** — integer cents as integers, no trailing zeros, no locale.
3. **No floats for money** — money is always integer cents (matches every `*_cents` column).
4. **No server clock, no random, no PII beyond the registered subject fields** inside payload
   (subject linkage lives in envelope columns `subject_client_id`/`subject_identity_id`, not
   duplicated in payload — keeps redaction scoped, §8).
5. **Prices/costs are server-resolved catalog references**, never client-supplied (§8, §9-arch).

Payload v1 field lists (money = integer cents throughout):

| `event_type` | Payload v1 fields |
|---|---|
| `sale.completed` | `sale_id`, `kind` (∈ `sales_kind_check`: `service\|retail\|membership\|quick_sale\|gift_card\|package`, `…v10:7`), `amount_cents`, `branch_id`, `staff_id`, `line_item_ids[]` (`sale_items`, `…v51`), `counts_as_revenue`, `counts_as_visit`, `earns_points` (resolved from `app.sale_policy`, `…v10:69`) |
| `sale.reversed` | `sale_id`, `reversal_audit_id`, `reason_code`, `amount_cents` |
| `points.redeemed` | `loyalty_operation_id`, `operation_type` (`redeem_points\|redeem_reward`), `reward_id`, `points_spent`, `credit_cents` |
| `giftcard.issued` | `gift_card_id`, `sale_id`, `amount_cents` |
| `giftcard.redeemed` | `gift_card_id`, `credit_ledger_id`, `loaded_cents`, `remaining_cents` |
| `package.sold` | `sale_intent_operation_id`, `client_package_id`, `plan_id`, `sessions`, `price_cents` |
| `package.session_used` | `consumption_id`, `client_package_id`, `remaining_before`, `remaining_after`, `sale_id` |
| `membership.enrolled` / `membership.renewed` | `membership_id`, `plan_id`, `period_key`, `credit_cents` (if plan grants credit) |
| `birthday.activated` | `entitlement_id`, `birthday_program_version_id`, `birthday_year`, `benefit_snapshot_hash` |
| `birthday.redeemed` / `…reversed` | `redemption_id`, `entitlement_id`, `branch_id` |
| `referral.qualified` | `referral_id`, `referrer_client_id`, `referred_client_id`, `reward_cents` |
| `credit.tendered` | `credit_tender_id`, `sale_id`, `payment_id`, `amount_cents`, `balance_before_cents`, `balance_after_cents` |
| `payment.recorded` | `payment_id`, `sale_id`, `method`, `kind`, `amount_cents` |
| `consent.changed` | `consent_id`, `channel`, `action` (`granted\|withdrawn`) |
| `points.expired` | `points_batch_id`, `expired_points`, `sgt_date` |
| `stored_value.topup` (PS-2) | `sv_operation_id`, `plan_version_id`, `paid_cents`, `bonus_cents` |
| `stored_value.spent` (PS-2) | `operation_id`, `movement_id`, `paid_draw_cents`, `bonus_draw_cents` |

Adding a field, changing a type, or removing a field ⇒ **`schema_version = 2`** with an
explicit upgrade migration; producers never silently reinterpret v1 (§8-arch).

---

## 5. Hash rules

`payload_hash = sha256(canonical_json(payload))` in lowercase hex, 64 chars, CHECK-constrained.

- Computed **at write time**, inside the producer transaction, over the §4-canonical form.
- The live codebase uses `md5` for op-ledger request hashes (`…v24a:11`, `…c45:103`); this
  contract upgrades the *event envelope* to **sha256** to match §6's explicit `payload_hash
  (sha256)` and the rule-compiler's sha256 `rule_hash` (§8). (Decision D2 — records the
  md5→sha256 choice so it is not re-litigated; op-ledger md5 hashes are untouched.)
- The hash joins the config-snapshot hash chain conceptually (config version is an envelope
  column), giving drift detection and tamper-evidence.
- **Redaction preserves hash verifiability** — see §8.

---

## 6. Replay rules (exactly-once, by construction)

Two independent uniqueness layers, both real DB constraints (ARCHITECTURE §3, §6):

1. **Event re-emit is swallowed by producer identity.** Re-invoking any producer with the
   same source fact hits `UNIQUE(business_id, event_type, source_operation_id, schema_version)`
   with `ON CONFLICT DO NOTHING` → 0 new rows. (Contract test PS0-EVT-1.)
2. **Effect replay is swallowed by effect identity.** `rule_effect_log` carries
   `UNIQUE(event_id, rule_id, effect_index)` (§6). An event can drive each effect of each rule
   **exactly once, ever**. Re-running the evaluator over an already-processed event inserts 0
   effect rows. (Contract test PS0-EVT-2.)

Because (1) prevents a duplicate *event* and (2) prevents a duplicate *effect* even for the
same event, **neither a duplicate fact nor a duplicate consequence can exist** — replay is
safe with no compensating logic. Fulfilment-side double-execution is additionally blocked by
`benefit_fulfilments UNIQUE(business_id, canonical_benefit_key)` (see
`BENEFIT_REGISTRY_CONTRACT.md`; ARCHITECTURE §3, §7).

Contract-test matrix (PS-0 exit, ARCHITECTURE §17 "identity/uniqueness … contract tests
green"): PS0-EVT-1 re-emit=0; PS0-EVT-2 effect-replay=0; PS0-EVT-3 schema-bump-without-
correction is rejected; PS0-EVT-4 scheduled re-run of same SGT period=0 new rows.

---

## 7. Correction-event rules

**A wrong event is never mutated and never deleted** (§1.2). A wrong or superseded fact is
restated by a **typed correction event that references the original**:

- Correction events carry a `correction_of_event_id` (FK → `domain_events.event_id`, same
  business) and a `correction_reason` code inside their registered payload. They use a
  distinct `event_type` from the class of correcting fact already in the registry — the
  domain already models corrections as **new signed facts**, so no generic `event.corrected`
  is introduced:
  - a mis-stated sale → `sale.reversed` (event #2) then a fresh `sale.completed`;
  - a wrong points redemption → the reversal path (`loyalty_redemption_reversals`, `…v34:66`
    area) surfaces as a `points.redeemed` correction referencing the original op;
  - a birthday redemption error → `birthday.redemption_reversed` (event #13), which
    `customer_birthday_redemptions` already models as `operation_kind='reversal'` with a
    mandatory `original_redemption_id` and a 3–500-char `reason` (`…c45:172-193`).
- The original event's `payload_hash` remains valid and verifiable — corrections **add**
  history, they never rewrite it. Reversals in the live schema are all append-only signed
  rows with `active` flags and `original_*_id` back-references (birthday `active`, `…c45:177`;
  loyalty reversals, package reversals — all v34), so the envelope correction rule is a
  faithful generalization of an existing, tested pattern.
- **A schema upgrade is not a correction** and cannot be used to silently re-emit (§1.3, §4).

---

## 8. Retention & redaction (PDPA ⚖️)

Events with a customer subject (`subject_client_id` / `subject_identity_id`) fall under PDPA.
The design keeps **hash verifiability intact under redaction**:

- **PII minimization first.** Payloads carry **ids and integer amounts only** — no name,
  phone, email, DOB, or free text (§4 rule 4). Subject linkage is envelope columns, not
  payload. Free-text customer content (e.g. feedback comment) is **not** copied into the
  event payload; the event references the source row id (`visit_feedback:{id}`) and the PII
  stays in the source table under its own RLS/redaction. This makes most events structurally
  free of redactable payload PII.
- **When a redactable field is unavoidable**, redaction is performed by **hashing the
  canonical-with-redaction-markers form**, not by nulling in place:
  - The canonical payload reserves redactable fields behind a stable marker. To redact field
    `f`, its value is replaced by the sentinel object `{"__redacted__":"f","at":"<ts>"}` and
    `payload_hash` is **recomputed over the redacted-canonical form**, with the pre-redaction
    hash preserved in an append-only `event_redactions(event_id, prior_payload_hash,
    redacted_fields[], redacted_at, actor)` log.
  - Verifiability is therefore preserved in **two tiers**: (a) current `payload_hash` always
    verifies against the current (possibly redacted) payload — an auditor can always confirm
    the row is internally consistent; (b) the redaction log proves *what changed and when*
    without retaining the erased value. Because non-subject events carry no PII, their hashes
    are immutable forever. (Decision D3 — this deviates from the strict "immutable
    `payload_hash`" of §1.2 **only** for PDPA erasure of subject-PII fields, and only via the
    logged, hash-recomputing path; the erasure is itself an append-only, audited fact.
    Flagged for orchestrator ruling because §1.2 states `payload_hash` is write-once.)
- **Retention window.** Events are retained for the tenant's configured audit horizon;
  subject-PII redaction can be applied earlier on a verified erasure request without deleting
  the event row (the economic fact and its hash survive; only the erasable field is markered).
  The concrete horizon value is deferred to the accounting/PDPA worksheet ⚖️ (Open Q O1).

---

## 9. Synchronous vs asynchronous split (verbatim-consistent with §6)

A communications / analytics / summary failure can **never** reverse a completed business
transaction. This is structural, not disciplinary.

| Effect | Class | Executes | A failure rolls back… |
|---|---|---|---|
| Checkout discount application | **Sync** | inside the sale transaction | that sale transaction |
| Tender allocation *when a tender occurs* (stored-value allocation, credit tender, payment rows) | **Sync** | inside the allocation's own transaction | **only that allocation**, never a sale already completed (§6, rev 4 N4) |
| Points earn | **Sync** | inside the sale transaction | that sale |
| Package session use | **Sync** | inside its transaction | that consumption |
| Inventory deduction | **Sync** | inside the sale transaction | that sale |
| Commission snapshot | **Sync** | inside the sale transaction | that sale |
| Financial reward grants / credits | **Sync** | inside their transaction | that grant transaction |
| Communications (notifications, WhatsApp/SMS/email) | **Async** | after commit, via outbox | only the delivery attempt |
| Analytics / summaries / non-critical notifications | **Async** | after commit, via outbox | only that async job |

**Tender is optional and decoupled** (rev 3 B2): the live completion≠payment invariant
stands — a sale may complete paid, partially paid, or on account
(`payments.kind`/`method`, `…v11b_money.sql`; `p_paid=false`, A/R = accrual − cash). Loyalty
and completion effects fire **at completion** per the product's first principle; each tender
allocation, whenever it later happens, is itself atomic (`credit_tenders` carries its own
`operation_id` + `idempotency_key`, `…v20:539`).

**Outbox mechanism (the cited structural guarantee).** All async effects go through the NEW
`event_outbox` table (PS-1B), the **sole delivery-state authority** (rev 4 B4): status
machine per `(event_id, consumer)` — `pending → delivering → delivered | failed(attempt n,
backoff) → dead_letter`, at-least-once with idempotent consumers. The checkout transaction
**only ever writes the outbox row**; delivery happens after commit, elsewhere — so a
communication failure cannot touch the committed checkout. The live v33
`customer_notification_outbox` (`…v33_customer_actions_notifications.sql:103`;
`delivery_status ∈ (pending,suppressed,failed)`, pinned `topic='booking_updates'`,
`channel='in_app'`, append-only) is **deliberately not modified**: it is the notification
consumer's immutable **evidence** store. Division of authority is crisp — `event_outbox` =
the only delivery-state authority; v33 = the only notification-evidence authority; no state
is represented in both. Dead-letter surfaces in the owner overview.

**Event lifecycle state machine (§6, terminal states explicit):**
`occurred → recorded (immutable) → sync effects applied in-txn → outbox rows (pending →
delivering → delivered | failed×N → dead_letter → owner-visible)`. Terminal states:
`delivered`, `dead_letter`. No silent transitions.

---

## 10. Decisions made during freeze (flag to orchestrator)

- **D1 — scheduled `source_operation_id` uses the period boundary, not `now()`.** §6 gives the
  format but not the clock source; I pinned it to the scheduled boundary so re-runs dedup.
  Low risk; consistent with the SGT `period_key` convention.
- **D2 — event `payload_hash` is sha256; op-ledger request hashes stay md5.** §6 says sha256
  for the envelope; the live op-ledgers use md5. I did not touch the md5 ledgers; only the new
  envelope uses sha256. Confirm you want a single hash family long-term.
- **D3 — PDPA redaction recomputes `payload_hash` over a redacted-canonical form**, with a
  prior-hash redaction log, deviating from strict write-once `payload_hash` (§1.2) **only** for
  subject-PII erasure. This is the deliberate design the task asked me to "design carefully and
  flag." Needs an owner/reviewer ruling because it trades absolute hash immutability for PDPA
  erasability. The mitigation (PII-minimized payloads) makes this path rare.
- **D4 — corrections reuse existing typed reversal event types** (`sale.reversed`,
  `birthday.redemption_reversed`, points/package reversals) rather than a generic
  `event.corrected`, because the live schema already models every correction as a new signed
  row. If a generic correction type is preferred, it is additive.
- **D5 — `membership.renewed` (#10) is classed transactional though invoked by cron**, because
  the renewal writes one membership's fact atomically; the cron run itself is the separate
  business-level sweep event (#24). This split avoids conflating "a renewal happened" with "the
  nightly job ran."
- **D6 — registry completeness is judged against live producers + §3/§6/§10**, not a fixed
  count. Events #19–22, #27–28 are specified now but emit only on their phase (PS-2/PS-3).

## 11. Open questions

- **O1** — Concrete event retention horizon (PDPA ⚖️) is deferred to the accounting/PDPA
  worksheet; §8 specifies the mechanism, not the number.
- **O2** — Whether `sale.reversed` should also emit paired inverse effect events or rely on the
  reversal engine's existing signed rows for downstream re-judgement (current design: rely on
  existing rows; the event is the trigger).
- **O3** — `stored_value.spent` `source_operation_id` uses the N6 registered key
  `sv_spend:{operation}:{movement}`; confirm the movement id is stable across replays before
  PS-2 (it is minted append-only, so it should be).

## 12. Schema evidence relied on

`credit_ledger`/entry types `…frenly_init.sql:94-104` (rename `…v2_saas.sql:12`; +cols
`…v20_financial_engine.sql:478`; `config_version_id` `…v26_immutable_config_versions.sql:158`);
`sales` + `kind` CHECK `…v2_saas.sql:44` / `…v10_sale_policy.sql:7`; `idem_key`
`…v14c…:8`; `config_version_id` `…v26…:155`; `points_ledger`/`points_batches`
`…v2_saas.sql:64` / `…v3_engine.sql:9`; `loyalty_operations` `…v24a…:11`; `loyalty_redemptions`
`…v23_loyalty_points_tiers.sql:33`; `loyalty_redemption_provenance` `…v34…:66`;
`gift_card_issue_operations` `…v41…:234`; `sale_intent_operations` `…v51a…:33`;
`package_session_consumptions`/`…_reversals` `…v34…:18`; `customer_birthday_entitlements`/
`…_redemptions`/`…_activation_operations` `…c45…:116,165,147`; `customer_notification_outbox`
`…v33…:103`; `payments` `…v11b_money.sql`; `credit_tenders`/`financial_operations`
`…v20_financial_engine.sql:539`; `firm_config_versions` `…v26…:13`; `consents` `…v3…:96`;
crons `…v3…:291` (points expiry `0 19 * * *`), `…v5…:148` (renewals `10 19 * * *`),
`…v15b…:76` (booking expiry `* * * * *`), `…v11b` (expense recurrences `20 19 * * *`);
append-only guard `app.v41_operation_immutable_guard` `…v41…:260`.
