# PS-2A — Stored-Value Authority Contract (PINNED)

Owner authorization: PS-2A build (foundation + authority), 2026-07-24. **Production cutover of
stored-value authority is NOT authorized.** No real customer value moves in this phase; no real
communications. Baseline verified independently: HEAD `3e61778` (parent `ade72e1`), tree clean,
canonical chain 94 / db 92, UAT ledger 94 ending `frenly_v60_ps1c2_execution_state`.

This contract IMPLEMENTS the already-frozen `docs/design/ps0/STORED_VALUE_CONTRACT.md` (PS-0, review
PASS). Where the two ever disagree, **PS-0 wins** — that document is the frozen arithmetic authority
(aggregate-proportional allocation, cross-operation FEFO, floor-on-bonus rounding, per-operation
refunds, terminal clawback, expiry independence, reversal-restores-exact-lots, liability split), and
its 26 arithmetic vectors + 2 000-iteration property test are the acceptance oracle. PS-2A adds the
*authority, control and safety* layer PS-0 deliberately left unbuilt.

---

## 0. Ground truth that shaped this contract (verified, not assumed)

| # | Finding | Consequence |
|---|---|---|
| G1 | **No stored-value implementation exists.** 0 `sv_*` tables; no top-up feature; no API route, edge function, trigger or cron touching stored value. Only PS-0 docs, the registry key template, and the tripwire. | PS-2A is greenfield. Nothing to preserve, nothing to migrate *in this phase*. |
| G2 | **No legacy stored-value authority exists to shadow.** The nearest legacy prepaid analog is `gift_cards` (3 synthetic rows) which carries a **mutable `balance_cents` column and zero triggers** — precisely the anti-pattern this contract forbids. | "Shadow the legacy system" is reinterpreted honestly (§7): reconciliation runs **read-only against gift_cards** as the designated legacy prepaid analog, and the sv ledger starts **empty**. Gift-card migration is explicitly OUT of PS-2A scope (it would move real customer value). |
| G3 | **`benefit_registry` cannot express ledger authority.** Its CHECK allows only `legacy_trigger→{legacy,shadow,rolled_back}` and `studio_executor→{studio,unbuilt}`. `studio_executor + shadow` is structurally impossible, and 4 of the owner's 7 required states have no representation. | Ledger authority lives in a **dedicated `sv_authority` table** (§2). `benefit_registry.stored_value` stays `studio_executor/unbuilt`, untouched, until a future cutover phase. This satisfies "do not force a rule-state model onto ledger authority". |
| G4 | **Shadow-tested rule effects are points/credit, not stored value.** `grant_credit` and `earn_bonus_points` resolve to family `points_loyalty`, state `shadow` (verified live). | Routing them into the sv ledger would **treat points as currency** — forbidden by the owner's §4 and by CLAUDE.md's first principle ("Points ≠ credit"). PS-2A therefore does **not** touch those effects; they keep shadow-logging exactly as today. |
| G5 | Integer-value discipline already holds: no `double precision`/`real` money anywhere; the only `numeric` columns are *rates* (`earn_points_per_dollar`, `points_multiplier`). | The integer-cents invariant is a continuation, not a new rule. |
| G6 | House idempotency convention = per-domain op-ledger: `unique(business_id, operation_type, idempotency_key)` + `request_hash` + cached result + advisory lock (15 existing `*_operations` tables). | PS-2A reuses it verbatim (§5). |
| G7 | PS-GATES has **PS-2 = `no`**, and `tests/program-studio/ps0-no-executor.test.mjs` forbids the function names `sv_topup`, `sv_spend_allocation`, `refund_sv_operation`, `sv_lot_movement` while PS-2 is gated. | PS-2A must flip PS-2 to `yes` **in the same reviewed change** that lands the schema, and re-scope the tripwire to what remains forbidden (cutover + real comms), never delete it. |
| G8 | `app.loyalty_ledger_write_guard` remains legacy-only; the deferred "studio scopes" were never added. | PS-2A adds **no** scope to it. Stored value is a separate ledger with its own guard. |

---

## 1. Vocabulary (unambiguous; "credit" is never used for a customer asset)

| Term | Meaning in PS-2A |
|---|---|
| **Account** | `sv_accounts` row: the (business, customer) container for one asset. Holds **no balance column**. |
| **Asset / value type** | The kind of value in an account. PS-2A ships exactly one: `stored_value` (prepaid). Points and promotional credit are **separate legacy assets in their own ledgers** and are out of scope. |
| **Class** | A partition *within* stored value: `paid` (customer cash; refundable; deferred revenue) or `bonus` (promotional; never cash-out). Per PS-0 §2. |
| **Lot** | `sv_lots`: an immutable minted parcel of one class from one top-up operation, with its own `expiry_key`. |
| **Ledger entry / movement** | `sv_lot_movements`: **the authority.** Append-only signed rows. **Kind vocabulary is PS-0 §2's frozen 8-kind set** — `issue`,`spend`,`expiry`,`reversal`,`refund`,`clawback`,`correction`,`bad_debt` — so the frozen PS-0 arithmetic oracle applies to the later increments with no schema change (reconciled from the earlier draft's `mint`/`adjust`). Increment A writes only `issue`. Note `sv_operations.operation_type` is a *distinct* axis (the caller's intent: `topup`/`grant`/`spend`/… ) and legitimately retains `adjust`. |
| **Grant** | An operator/promotional increase (bonus class) with actor + reason. |
| **Earn** | A rule- or purchase-driven increase. In PS-2A: top-up only. |
| **Top-up** | The purchase operation minting one paid lot + one bonus lot. |
| **Redeem / spend** | A decrease allocated across lots by PS-0 §3. |
| **Reservation / hold** | A soft claim on available balance during checkout; not yet a spend. |
| **Release** | Cancelling a reservation; restores available balance; never deletes history. |
| **Expire** | A decrease by expiry sweep; independent per class. |
| **Reverse** | A signed offsetting movement referencing a prior operation; restores exact lots (PS-0). |
| **Refund** | A per-operation cash return (paid class only) + terminal bonus clawback. |
| **Available balance** | Σ movements − active reservations. **Derived, never stored.** |
| **Pending balance** | Σ active reservations. |
| **Expired balance** | Σ expiry movements. |
| **Reversed amount** | Σ reversal movements against an operation; bounded by the remaining reversible amount. |
| **Authority** | Which system is the source of truth for spendable stored value (§2). |
| **Shadow comparison** | A recorded, non-mutating projection of what the sv ledger *would* hold, versus the legacy analog. |
| **Reconciliation discrepancy** | A preserved, inspectable difference. **Never auto-corrected.** |

---

## 2. Authority model (dedicated; server is the only source of truth)

`public.sv_authority` — one row per (business_id, asset). States:

`unbuilt` → `shadow_testing` → `reconciliation_blocked` ⇄ `ready_for_cutover` → `live` ⇄ `paused` → `retired`

- **unbuilt** — no sv objects in use for this tenant. **PS-2A ships every tenant here.**
- **shadow_testing** — sv operations may be simulated; **no customer may spend sv**; legacy remains authoritative.
- **reconciliation_blocked** — a discrepancy exists; cutover is refused until cleared. Terminal-until-resolved.
- **ready_for_cutover** — reconciliation clean; **still not live**; requires a separate, later-phase action.
- **live** — sv is authoritative and spendable. **Unreachable in PS-2A: no function exists that can set it.**
- **paused** — see §8.
- **retired** — superseded; history preserved.

**Hard PS-2A gate:** the only transitions PS-2A implements are `unbuilt ⇄ shadow_testing`, `→ reconciliation_blocked`, and `→ paused`. **No function that sets `live` or `ready_for_cutover` exists in PS-2A** — the safest possible gate: an absent function cannot be invoked, mis-permissioned, or accidentally exposed. Cutover is a future authorized phase.

The browser never infers authority; it renders `sv_authority` verbatim (§10).

---

## 3. Ledger invariants (machine-testable)

1. `sv_lot_movements` is append-only (no UPDATE/DELETE; guard trigger).
2. No mutable balance column exists on any sv table (`sv_accounts` and `sv_lots` carry no writable balance; any cached `remaining_cents` is guard-maintained and reconciled to Σ movements, never client-writable).
3. Balances are **derived** from movements (± active reservations).
4. An idempotency key cannot create value twice (§5).
5. A redemption cannot exceed available balance (checked under lock).
6. Concurrent redemptions cannot double-spend (row-lock ordering; proven by a real two-connection harness).
7. A reversal references a valid prior operation and offsets it.
8. A reversal cannot exceed the remaining reversible amount.
9. Expiry cannot expire already-spent or already-expired value.
10. Every entry is scoped to the correct (business, customer, lot); composite tenant FKs.
11. Tenant isolation enforced at the database layer (RLS + composite FKs).
12. All value is **integer cents** (`integer` per-row, `bigint` aggregates); no float.
13. Mutations are atomic (single transaction; partial failure leaves nothing).
14. History survives pause, cutover and rollback.
15. Retries return the original recorded result, never a duplicate effect.
16. No browser role can insert an authoritative entry (all writes via `SECURITY DEFINER` RPCs; direct table writes revoked).
17. Every value-moving function pins `search_path` and is revoked from `public/anon/authenticated`.
18. Only registered server paths may invoke value-moving operations (writer registry).

---

## 4. Asset model (decided, with justification)

**Stored value is a third, distinct asset — not points, not promotional credit.**

Frenly already runs two append-only ledgers: `points_ledger` (points, which earn/expire then redeem *into* credit) and `credit_ledger` (promotional credit in cents). CLAUDE.md's first principle is "Points ≠ credit". Stored value is a *prepaid customer asset* with cash-refund semantics that neither existing ledger models. Therefore:

- **Separate ledger, shared operation model.** `sv_lot_movements` is its own authority; it reuses the house op-ledger/idempotency/guard conventions but shares no rows with points or credit.
- **Points are never converted into stored value in PS-2A**, and no points/credit effect is rerouted (G4).
- **Unit** — integer cents. **Rounding** — floor-on-bonus with the paid class taking the remainder cent (PS-0 §3); business-favorable by ≤1¢ per spend.
- **Denomination** — top-up plans pin price + bonus ladder in an immutable `sv_plan_versions` snapshot.
- **Expiry** — per lot, `expiry_key`; **paid and bonus expire independently**.
- **Negative balance** — forbidden; a spend that would go negative is rejected atomically.
- **Transfer between customers** — not supported in PS-2A.
- **Cross-program / cross-studio** — an account is scoped to exactly one business; no cross-tenant fungibility, ever.
- **Fungibility** — fungible *for spend* (aggregate-proportional across operations), **non-fungible for refund** (refunds are per source operation, paid class only).
- **Partial redemption** — allowed.

---

## 5. Idempotency contract

`public.sv_operations` — house pattern, verbatim:
- `unique(business_id, operation_type, idempotency_key)`; `request_hash` (sha256 of the canonical request); cached `result` jsonb; actor; created_at; advisory-lock serialization.
- **Operation types** pinned by CHECK: `topup`, `grant`, `spend`, `reserve`, `release`, `expire`, `reverse`, `refund`, `adjust`.
- **Identical retry** → the cached result, no new movement.
- **Conflicting retry** (same key, different `request_hash`) → **fail closed**, `22023`.
- **Partial prior failure / rollback** → the op row and its movements share one transaction, so a rolled-back attempt leaves no op row and the key is reusable.
- **Concurrent duplicates** → advisory lock + unique constraint; exactly one winner, the loser replays the cached result.

---

## 6. Checkout redemption (built, but not enabled)

Contract covers balance validation → reserve-or-direct-spend → finalize → failure → abandonment → reversal/refund → duplicate submit → stale quote → concurrent checkout → mixed payment → zero-total → partial redemption → ownership/tenant scope.

**PS-2A ships this in shadow only.** The checkout kernel's live financial path (`ps1c_plan_checkout` / `record_cart_sale/9`) is **not modified in Increment A/B**. Any later kernel touch must first pass a function-level predecessor diff proving isolation (§ Existing-path regression proof), and stored value cannot be tendered while `sv_authority` ≠ `live` — which PS-2A makes unreachable.

---

## 7. Reconciliation and migration (honest, given G2)

There is **no incumbent stored-value engine**. Reconciliation in PS-2A therefore:
- captures **legacy opening balances read-only** from the designated analog (`gift_cards.balance_cents`) into `sv_reconciliation_snapshots`, without writing to or "fixing" any legacy row;
- uses **deterministic migration identifiers** (`legacy:giftcard:{gift_card_id}`) so a rerun is a no-op;
- reconciles **per customer and per asset**;
- classifies discrepancies: `missing_in_studio`, `missing_in_legacy`, `amount_mismatch`, `orphan_legacy_record`, `duplicate_legacy_event`, `invalid_legacy_balance` (negative/NULL);
- **tolerance = 0.** No exceptions in PS-2A.
- preserves every discrepancy as an inspectable row; **nothing is auto-corrected or silently repaired**;
- is **rerunnable** and rollback-safe;
- gates cutover: any open discrepancy forces `reconciliation_blocked`.

**Gift-card migration (moving real value) is explicitly out of PS-2A scope.**

---

## 8. Pause and kill controls (dedicated table — not the rule pause)

`studio_rule_emergency_pauses` is keyed on a **rule_id** with rule-engine semantics; ledger authority needs **business/asset scope and operation-family granularity**. Reusing it would be misleading. PS-2A adds `public.sv_pauses`:
- scope: `all` | `earn` (grants/top-ups) | `redeem` (spends/reservations);
- owner-only; actor, reason (≥3 chars), timestamp; append-only with lift-once (write-once) semantics;
- idempotent pause and lift; one active pause per (business, asset, scope) via partial unique index;
- **no history deletion**; **no implicit lift** — publishing a configuration version cannot lift an sv pause.

**Pinned policy — spending during an earn pause:** an `earn` pause blocks new grants/top-ups but **customers may continue to spend value they already hold.** Rationale: value already granted is a customer entitlement; freezing it would convert an operational safety action into a customer-visible seizure. Stopping spend requires an explicit `redeem` or `all` pause. (Moot while authority is never `live`, but pinned so behaviour is unambiguous at cutover.)

---

## 9. Permissions

| Capability | owner | manager | staff/frontdesk | service_role | anon | authenticated (browser) |
|---|---|---|---|---|---|---|
| View own-tenant balances//history | ✓ | ✓ | ✓ (read) | ✓ | ✗ | via RPC only |
| Top-up / grant | ✓ | ✗ (PS-2A) | ✗ | ✓ | ✗ | RPC only |
| Spend / reserve / release | ✓ | ✓ | ✓ | ✓ | ✗ | RPC only |
| Manual adjustment | ✓ only | ✗ | ✗ | ✓ | ✗ | RPC only |
| Reversal / refund | ✓ only | ✗ | ✗ | ✓ | ✗ | RPC only |
| Expiry sweep | ✗ (cron/service) | ✗ | ✗ | ✓ | ✗ | ✗ |
| Reconciliation run/read | ✓ | ✗ | ✗ | ✓ | ✗ | RPC only |
| Emergency pause / lift | ✓ only | ✗ | ✗ | ✗ | ✗ | RPC only |
| Cutover | **nobody — no function exists in PS-2A** | | | | | |
| View audit detail | ✓ | ✗ | ✗ | ✓ | ✗ | RPC only |

**Every manual adjustment is an append-only ledger event with actor + reason. There is no editable balance field anywhere.** Direct table INSERT/UPDATE/DELETE is revoked from `anon` and `authenticated` on every sv table.

---

## 10. UI truthfulness

- Render `sv_authority.state` and reconciliation status **verbatim** from the server; never infer.
- **Never present stored value as spendable while authority ≠ `live`.** Shadow figures are labelled "simulated — not spendable".
- Show pause status, scope and reason; show reconciliation failures rather than hiding them.
- Dangerous owner actions require explicit confirmation.
- **Fail closed**: if an authority/preview RPC errors, show an error state and disable the control — never assume live.
- Controls are hidden from roles that cannot execute them.

---

## Increment plan (PS-2A)

- **A — Foundation:** accounts, plans/plan-versions, lots, movements (authority), `sv_operations` idempotency envelope, derived-balance functions, `sv_authority` (`unbuilt` only), RLS/ACLs/guards, invariant suite. *No spend path, no UI.*
- **B — Shadow operations:** simulated top-up/spend against PS-0 arithmetic on synthetic tenants; `sv_shadow_evaluations`; reconciliation snapshots + discrepancy reporting vs the gift-card analog (read-only). **Legacy balances untouched; points/credit effects untouched (G4).**
- **C — Redemption mechanics:** reservation/atomic-spend, reversal, replay/concurrency protection — all unreachable while authority ≠ `live`. Checkout kernel unmodified.
- **D — Controls & UI:** pause/lift, owner controls, reconciliation view, authority chips, cutover **preview only** (no cutover action exists).

Independent adversarial review of one frozen commit gates any UAT apply or deploy.
