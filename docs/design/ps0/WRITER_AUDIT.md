# PS-0 — Exhaustive Transaction-Writer Audit

> Authority: `docs/design/PROGRAM_STUDIO_ARCHITECTURE.md` §9 (Unified Checkout Kernel
> HARD PREREQUISITE) and §17 (PS-0 row). This audit's output is **authoritative for the
> kernel gate** and deliberately does **not** stop at a predetermined count — the machine
> discovery re-runs and diffs clean, so the enumeration is repeatable and complete.
>
> Read-only analysis. No database was touched. Deliverables:
> `scripts/ps0/discover-writers.mjs`, `docs/design/ps0/writer-registry.json`, this file,
> and `tests/program-studio/ps0-writer-registry.test.mjs`.

## 1. Method (repeatable)

`scripts/ps0/discover-writers.mjs` is a static analyser over three surfaces:

1. **`supabase/migrations/*.sql`** — every `CREATE FUNCTION` body is located by dollar-quote
   matching that skips single-quoted string literals (so a value-table name inside a `RAISE`
   message or a commented-out line is never counted). Definitions are **replayed in migration
   order** — `CREATE OR REPLACE` overwrites the keyed body; **`ALTER FUNCTION … RENAME TO`**,
   **`… SET SCHEMA`** and **`DROP FUNCTION`** re-key / move / delete it. This is what keeps the
   reversal engine's `*_v20_base` / `*_v34_base` bodies visible and what drops the stale
   overloads `record_sale_by_phone/7` after v47a cleanup. Overloads are keyed by **arity**
   (matching Postgres object identity). A **call graph** over the resolved set surfaces
   *delegating* entry points (e.g. `record_sale_by_phone → record_quick_sale`,
   `reverse_sale → reverse_sale_v34_base → reverse_sale_v20_base`) that carry no direct DML
   yet reach a value writer.
2. **`supabase/functions/**/*.ts`** — Edge Functions: `.rpc(...)` and `.from(...).insert/update/
   delete/upsert` (service-role).
3. **`app/index.html`, `app/customer-ui.js`, `app/join.html`** — browser `.from(...).write` and
   `.rpc('...')` call sites; each RPC call is flagged for whether it reaches a value-writing RPC.

The **value-table registry is declared in the script** (`VALUE_TABLES`) — 34 tables across
sale spine, ledgers, stored instruments, packages, memberships, loyalty fulfilment/redemption,
birthday entitlements, campaigns, inventory, P&L, reversal provenance, and idempotency op-ledgers.
Output is a deterministic sorted JSON inventory. `tests/program-studio/ps0-writer-registry.test.mjs`
re-runs discovery and asserts every discovered identity is either a curated `writers` entry or an
allowlisted benign one — a new writer cannot land uncurated.

Run it: `node scripts/ps0/discover-writers.mjs`. Regression guard runs under `npm run validate`.

## 2. Counts (this pass)

| Surface | Total | Value-impacting |
|---|---|---|
| DB function writers (direct DML) | 41 | 38 |
| DB delegating entry points (no DML, reach a writer) | 12 | 12 |
| DB triggers reaching a value write | 4 of 131 | 4 |
| Migration-time backfills (run-once) | 25 | 25 |
| Edge Functions with direct value writes | 4 scanned | **0** |
| Browser direct table writes | 28 | **2** |
| Browser RPC call sites | 101 | 19 reach a value writer |
| **Discovered identities (test-diffed)** | **211** | 102 |

Registry: **78 curated writers**, **133 allowlisted** (benign/read-only/run-once), 211 covered exactly.

**Stored value: confirmed absent.** No `stored_value` / `sv_lots` / `sv_lot_movements` /
`sv_plans` table exists. `gift_cards` is single-balance credit (redemption writes `credit_ledger`,
never a lot), not the lot-based stored value PS-2 introduces.

## 3. The sale spine is trigger-centralised (the central structural fact)

Every writer that inserts a `sales` row inherits one shared contract, because the invariants live
on the **`sales` table triggers**, not in the callers:

| Timing | Trigger | Function | Effect |
|---|---|---|---|
| BEFORE INSERT | `trg_sale_policy_snapshot` | `on_sale_policy_snapshot` | stamps the **v10 sale-policy snapshot** on the row |
| BEFORE INSERT | `trg_sales_config_version` | `stamp_config_version` | stamps the **immutable config version** |
| BEFORE INSERT | `trg_sale_commission_snapshot` | `on_sale_commission_snapshot` | stamps the **commission** snapshot (v12/13/22) |
| BEFORE INSERT | `trg_cart_line_stock_stamp` | `cart_line_stock_stamp` | stamps FEFO product/qty from a GUC (cart) |
| BEFORE INSERT | `trg_sales_default_branch` | `set_row_branch` | default branch |
| BEFORE INSERT | `trg_sale_reversal_insert_guard` | `sales_reversal_insert_guard` | blocks reversal rows unless created via `reverse_sale` (GUC handshake) |
| AFTER INSERT | `trg_sale_recorded` | **`on_sale_recorded`** | **the single earn/qualify engine**: points/stamps, retention grants, referral qualify, credit grants — resolves v10 policy + config version |
| AFTER INSERT | `trg_sale_stock_deduct` | `on_sale_stock_deduct` | FEFO inventory deduction |
| BEFORE UPDATE/DELETE | `trg_sales_immutable_guard` | `sales_immutable_guard` | **append-only**: DELETE always blocked; UPDATE blocked except a single-column whitelist under `app.reclassify_sale` / `app.sales_backfill` GUCs |

**Consequence for the kernel:** no sale-inserting path can bypass policy resolution, config
stamping, commission, loyalty earn, or FEFO — they are structural. The Unified Checkout Kernel
**must keep inserting `sales` rows** so `on_sale_recorded` fires **exactly once** (the single-count
guarantee). Earning must never be duplicated into the kernel. `sales` is append-only; value changes
happen through **new reversing rows**, never updates.

## 4. Compact writer table (DB value writers)

Kernel column: **SAFE** = idempotent + fits the kernel contract as-is; **NEEDS-WORK** = must be
folded/adapted; **MUST-NOT (as-is)** = a live integrity hazard the kernel must absorb. Full
per-writer detail (reads, payment, loyalty, commission, package/membership, inventory, reporting,
reversal, UI route, kernel verdict) is in `writer-registry.json`.

| Writer (schema.name/arity) | Rows written | Idempotency | Lock | Kernel |
|---|---|---|---|---|
| `record_quick_sale/9` | sales, financial_operations | financial_operations op-ledger (key) | row | **SAFE — kernel candidate** |
| `record_cart_sale/7` | sale_items (+ delegates money → record_quick_sale) | reuses parent sale key | row | NEEDS-WORK (line-item wrapper; PS-1C discount lines land here) |
| `record_sale_by_phone/9` | → record_quick_sale | inherits kernel key | row | SAFE (adapter) |
| `on_appointment_completed` (trigger) | sales, stock_batches | one sale per appointment | — | NEEDS-WORK (route completion sale via kernel) |
| `on_sale_recorded` (trigger) | points_ledger, points_batches, reward_grants, credit_ledger | one per sale insert | — | **SAFE — the single earn engine; keep** |
| `on_sale_stock_deduct` (trigger) | stock_batches | per sale insert | — | SAFE |
| `sell_package/3` | sales, client_packages | **NONE** | none | **MUST-NOT — non-idempotent, still granted + UI-called** |
| `sell_package/4` | sale_intent_operations (→ /3) | advisory + op-ledger | adv | NEEDS-WORK (wraps /3) |
| `use_package_session/3` | client_packages, package_session_consumptions, sales | advisory + op-ledger | adv | SAFE |
| `use_package_session/2` | client_packages, sales | NONE (**execute REVOKED v34**) | row | SAFE (dead) |
| `enroll_membership/3` | sales, memberships, credit_ledger | **NONE intrinsic** | row | NEEDS-WORK |
| `enroll_membership_v41/3` | → enroll_membership | **NONE** | row | **MUST-NOT — non-idempotent, still granted + UI-called** |
| `enroll_membership_v41/4` | sale_intent_operations (→ /3) | advisory + op-ledger | adv | NEEDS-WORK (wraps /3) |
| `run_membership_renewals` (cron) | sales, memberships, credit_ledger | per-period + SKIP LOCKED | row | NEEDS-WORK |
| `set_membership_status/3` | memberships | status flip | row | SAFE |
| `issue_gift_card/5` | sales, gift_cards, gift_card_issue_operations | advisory + op-ledger | adv | SAFE |
| `issue_gift_card/4` | sales, gift_cards | NONE (**execute REVOKED v41**) | none | SAFE (dead) |
| `redeem_gift_card/4` | credit_ledger, gift_cards | **NONE (row lock + balance only)** | row | NEEDS-WORK (MEDIUM finding) |
| `record_credit_tender/5` | payments, credit_tenders, credit_ledger, financial_operations | op-ledger (key) | row | SAFE (UI-unwired) |
| `record_payment/12` | payments | op-ledger + advisory | adv | SAFE — **deposits + no-show fees writer** (UI-unwired) |
| `open_drawer/3`, `close_drawer/4`, `record_drawer_movement/6` | cash_drawer_* | **NONE** | row/none | SAFE (owner cash log; MINOR) |
| `adjust_points/4` | points_ledger, points_batches | **NONE** | row | NEEDS-WORK (MEDIUM finding) |
| `redeem_points/3` | → redeem_points_v40_internal | op-ledger (key) | — | SAFE |
| `redeem_points/2` | credit_ledger, points_* | NONE (**execute REVOKED v24a**) | row | SAFE (dead) |
| `redeem_points_v40_internal/3` | credit_ledger, points_*, loyalty_operations | op-ledger | row | SAFE |
| `redeem_reward_core/7` | loyalty_redemptions(+drains/prov), points_*, credit_ledger, loyalty_operations | op-ledger + config version | row | SAFE |
| `redeem_reward/4`, `/5`, `redeem_reward_at_context/7` | → core / direct | op-ledger | row | SAFE |
| `run_points_expiry_for_business/1` (cron) | points_batches, points_ledger | set-based sweep (self-idempotent) | row | SAFE |
| `reverse_sale/6` → `_v34_base` → `_v20_base` | sales, payments, credit_ledger, sale_reversal_audits, sale_reversal_payment_links, package_session_reversals, client_packages | op-ledger (key) | row | NEEDS-WORK (3-layer wrapper stack) |
| `reverse_loyalty_redemption/4` → `_v34_base` | loyalty_redemption_reversals, points_*, credit_ledger | op-ledger + config version | row | NEEDS-WORK |
| `refund_sale/6` | → reverse_sale | via reverse_sale | row | SAFE (alias) |
| `reclassify_sale_policy/3` | sales (counts_as_revenue only) | governed GUC + guard whitelist | row | SAFE |
| `customer_activate_birthday_benefit/2` | customer_birthday_entitlements (+activation op) | op-ledger + config version | row | SAFE |
| `redeem_customer_birthday_benefit/4` | customer_birthday_entitlements, customer_birthday_redemptions | op-ledger | row | SAFE |
| `reverse_customer_birthday_benefit_for_client/4` → `..._redemption/3` | customer_birthday_entitlements, customer_birthday_redemptions | op-ledger | row | SAFE |
| `issue_campaign_offer/6` | retention_campaign_grants | advisory + op-ledger | adv | NEEDS-WORK (legacy budget authority) |
| `record_campaign_returns/2` | retention_campaign_returns | advisory + op-ledger | adv | SAFE (measurement) |
| `activate_retention_campaign/4` | retention_campaign_members (audience) | advisory + op-ledger | adv | SAFE (audience) |
| `run_expense_recurrences` (cron) | expenses, expense_recurrences | per-period guard | none | SAFE (P&L) |
| `set_expense_void/3` | expenses (void flag) | status flip | none | SAFE (P&L) |
| `commit_import_job/1` | stock_batches | advisory (commit-once) | adv | SAFE (opening inventory) |

## 5. Findings

### 5a. HARD findings

1. **`sell_package/3` — non-idempotent value writer, granted and directly UI-called.**
   The 3-arg `sell_package(uuid,uuid,uuid)` inserts `sales` + `client_packages` with **no
   idempotency key and no advisory lock**, its execute grant to `authenticated` was **never
   revoked** (v10), and the standalone Packages page calls it directly at
   **`app/index.html:6539`** (3 args). The idempotent 4-arg overload exists (v51a) and the cart
   path uses it (`:4090`), but the standalone page was not migrated. A double-tap / retry creates
   a duplicate package sale + duplicate `client_packages` row + duplicate loyalty earn (the sale
   insert fires `on_sale_recorded`). UI toast even says "revenue booked, loyalty earned".

2. **`enroll_membership_v41/3` — non-idempotent membership enrol, granted and directly UI-called.**
   The 3-arg overload is a thin passthrough to `enroll_membership/3` with **no key, no lock**;
   `enroll_membership/3` has no intrinsic idempotency (FOR UPDATE only). It is granted, and the
   standalone Memberships page calls it directly at **`app/index.html:5816`** (3 args), while the
   cart path uses the idempotent 4-arg at `:4092`. Double-tap = duplicate membership + duplicate
   sale.

3. **Browser-direct value writes (2).** `app/index.html` writes value tables via raw PostgREST,
   bypassing any RPC and any idempotency:
   - `expenses` INSERT at **`:7003`** (P&L cost row).
   - `stock_batches` INSERT at **`:6500`** (inventory receiving; double-tap duplicates a batch,
     over-counting on-hand and skewing FEFO).
   Both are RLS-gated owner/manager actions and neither is customer-facing value movement, but
   both alter value/P&L state client-side with no idempotency or audit-RPC parity. They should
   move behind RPCs.

### 5b. MEDIUM findings

4. **`redeem_gift_card` (and `redeem_gift_card_v41`, UI `:5892`) has no idempotency key** — it
   relies on `FOR UPDATE` + balance decrement, so a retry within remaining balance re-issues
   `credit_ledger` credit. No dedicated reversal path for gift-card redemption exists.
5. **`adjust_points/4` (UI `:3519`) has no idempotency key** — a double-submit doubles the manual
   points adjustment (`points_ledger` + `points_batches`).

### 5c. MINOR findings

6. Cash-drawer writers (`open_drawer`, `close_drawer`, `record_drawer_movement`) have no
   idempotency; double-tap duplicates a movement. Owner-side cash log, not customer value.

### 5d. Positive / non-findings (assurance)

- **No policy-snapshot bypass among sale writers** — policy/config/commission snapshots and
  loyalty earn are trigger-driven on `sales`, so all 8 sale-inserting paths (`record_quick_sale`,
  `sell_package/3`, `enroll_membership/3`, `issue_gift_card`, `use_package_session`,
  `run_membership_renewals`, `on_appointment_completed`, reverse bases) get them uniformly (§3).
- **Edge Functions write no value.** `public-join`/`public-booking`/`manage-booking` write only
  `clients` / `booking_requests` (booking requests reach value only later via
  `convert_booking_request` → appointment → completion sale, which is inside the trigger contract).
- **`app/customer-ui.js` makes no backend calls** — it is a pure presentation module; the customer
  surface's writes all route through curated RPCs invoked by `index.html`.
- **Legacy non-idempotent overloads are mostly dead**: `issue_gift_card/4`, `redeem_points/2`,
  `use_package_session/2` all had `EXECUTE` **revoked** from `authenticated` when their idempotent
  successors shipped. `sell_package/3` and `enroll_membership_v41/3` are the outliers (findings 1–2).
- **`sales` is genuinely append-only** — DELETE always blocked; the only permitted UPDATEs are a
  column-whitelisted `counts_as_revenue` reclassification and guarded migration backfills.

## 6. Kernel-gap list (what the Unified Checkout Kernel must absorb)

The kernel gate in §9 lists a minimum surface; PS-0 confirms it and adds the following, which the
PS-1C exit test must replay through one kernel with byte-reconciled ledgers:

1. **Keep the sales-trigger contract.** The kernel's single write path must still `INSERT` into
   `sales` so policy/config/commission/FEFO/earn fire once. Do **not** re-implement earning inside
   the kernel.
2. **Own the line-item + discount layer.** `record_cart_sale` is the only line-item writer and
   applies no discounts/tender; extend it (or the kernel) with the signed discount-line type and
   the `checkout_evaluations` token + atomic revalidation.
3. **Own the tender step.** `record_credit_tender` (credit) and `record_payment`
   (cash/card/paynow/**deposit**/**no_show_fee**/refund) are the intended tender writers — both
   idempotent, both currently UI-unwired (finance pilot-disabled). The kernel tender step calls
   these; stored-value tender (PS-2) mirrors them.
4. **Collapse duplicate/overloaded write paths into one each:** package sale (`sell_package/3`
   vs `/4` + revoke /3, migrate UI `:6539`), membership enrol (`enroll_membership_v41/3` vs `/4` +
   migrate UI `:5816`), reward redemption (`redeem_reward/4` vs `/5` vs `redeem_reward_at_context`),
   refund alias (`refund_sale` → `reverse_sale`), and the 3-layer reversal stack
   (`reverse_sale` v40 → v34_base → v20_base; same for loyalty redemption reversal).
5. **Make gift-card redemption and manual point adjustment idempotent** (findings 4–5) — under the
   kernel or the additive `loyalty_ledger_write_guard` studio scope.
6. **Reconcile the non-checkout value writers** the kernel does not route but must keep single-count
   with: gift-card issue/redeem, points redeem/reward/expiry, birthday activate/redeem/reverse,
   campaign grants/returns (legacy budget authority until the engine cuts over, §11), package
   session consumption, membership renewal cron, expense/recurrence P&L.
7. **Move the two browser-direct value writes behind RPCs** (`expenses`, `stock_batches`) so every
   value/P&L mutation is server-mediated, idempotent, and audited.
8. **Stored value is greenfield** — no lot tables exist; PS-2 builds them; `gift_cards` stays
   single-balance credit until then.

## 7. Reproduce / verify

```
node scripts/ps0/discover-writers.mjs                 # deterministic JSON inventory
node --test tests/program-studio/ps0-writer-registry.test.mjs   # exhaustiveness guard (7 tests)
EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate   # full suite (green)
```
