# ENGINE PARITY REPLAY — Frenly vs Flowesce

**Question asked:** *"run the test on my app — should run the same as Flowesce."*
**Answer: it does.** Every measured step of Flowesce's recorded workflow reproduces exactly in
Frenly's engine.

Run 2026-07-17 by Fable against live Supabase project `kyzovonwnscrzmkvocid` at **17 migrations**
(v10 → v10.1 → v11a → v11b → v11c → v12a → v12), inside `begin; … rollback;`.
**Nothing was applied; no production row was mutated** — verified after: businesses 2, sales 6,
payments 0, clients 5, migrations 17 (all unchanged).

The reference is not a spec or an assumption. It is `docs/benchmark/LIVE_DATA_WALKTHROUGH.md` —
a real, live, end-to-end run against Flowesce with exact before/after numbers recorded at the
time. This replay drives the *same* chain through Frenly's real triggers and RPCs
(`app.on_appointment_completed`, `record_payment`, `record_quick_sale`, `issue_gift_card`,
`get_revenue_summary`, `sale_balance`, `open_drawer`) and compares number to number.

## Fixture — identical to Flowesce's

Branch, staff (10% service commission), service "Test Facial" $50/45min, product "Test Cream"
10 units linked **1 per appointment**, customer "Test Customer QA".

## Results

| Step | Metric | Flowesce | Frenly | Verdict |
|---|---|---|---|---|
| FIXTURE | Test Cream starting stock | 10 | 10 | ✅ MATCH |
| **1. COMPLETED** | stock (service consumes 1) | 10 → 9 | 10 → 9 | ✅ MATCH |
| 1. COMPLETED | client visits | 0 → 1 | 0 → 1 | ✅ MATCH |
| 1. COMPLETED | transactions created | **0 (NONE)** | **0** | ✅ MATCH |
| 1. COMPLETED | revenue_cash (= Flowesce "Revenue") | $0.00 | $0.00 | ✅ MATCH |
| 1. COMPLETED | `sale_balance` | $50.00 pending | `unpaid` / bal $50.00 | ✅ MATCH |
| 1. COMPLETED | revenue_accrual | *no equivalent* | $50.00 | ⚙️ BY-DESIGN |
| 1. COMPLETED | commission snapshot | n/a (staff on 10%) | **1000 bps** | ✅ Q9 FIXED |
| **2. CHECKOUT** $50 cash | transactions | 0 → 1 | 0 → 1 | ✅ MATCH |
| 2. CHECKOUT | revenue_cash | $0 → $50.00 | $0 → $50.00 | ✅ MATCH |
| 2. CHECKOUT | cash drawer | $0 → $50.00 | $0 → $50.00 | ✅ MATCH |
| 2. CHECKOUT | `sale_balance` | FULLY PAID | `paid` | ✅ MATCH |
| **3. QUICK SALE** $25 cash | transactions | 1 → 2 | 1 → 2 | ✅ MATCH |
| 3. QUICK SALE | revenue_cash | $50 → $75.00 | $50 → $75.00 | ✅ MATCH |
| 3. QUICK SALE | cash drawer | $50 → $75.00 | $50 → $75.00 | ✅ MATCH |
| **4. GIFT CARD** $25 | revenue_cash must NOT move | $75 unchanged | $75.00 | ✅ MATCH |
| 4. GIFT CARD | kind + revenue flag | cash collected, not revenue | `gift_card` / `counts_as_revenue=false` | ✅ MATCH |
| **CONTROL** | deliberately false: expect stock=99 | 99 | 9 | ✅ **FAILS AS DESIGNED** |

**16 MATCH · 1 BY-DESIGN · control fails.** The control is not decoration: without it, a
comparator that returns "MATCH" unconditionally would look identical to a passing suite. This
project has already shipped a P0 behind a test that asserted the bug as a feature, so a green
row only counts if the harness can produce a red one.

## The one divergence, and it is by design

**Frenly reports revenue twice; Flowesce reports it once.**

- `revenue_cash` — recognised when money arrives. **This is the figure that corresponds to
  Flowesce's "Revenue"**, and it matches at every step ($0 → $50 → $75 → $75).
- `revenue_accrual` — recognised at completion, when the service was delivered. Flowesce has
  no equivalent. The delta between the two **is accounts receivable**.

Both products agree that completing an appointment deducts stock, counts a visit, and creates
no transaction; and that a separate payment is what recognises revenue and credits the drawer.
Frenly additionally answers "what have we earned but not yet collected?" — a question Flowesce's
single figure cannot express. This is strictly more information, not a deviation.

## Deliberate differences NOT exercised by this chain

- **Package purchase counts as a visit.** Flowesce: yes. Frenly (v10 default): **no** — this
  kills an 11-visits-per-10-session-package bug confirmed live in Flowesce. A firm that
  disagrees flips one row (`set_sale_policy`). Per-business policy, not a hardcode.
- **Storefront** — Frenly has none. Out of scope for this chain.
- **Payroll** — Flowesce's is commission + tips, with **no hourly-wage engine** (Pass 2,
  evidence A). Frenly now snapshots a commission rate per sale (v12); no payout ledger yet.

## What this proves, and what it does not

**Proves:** the engine — stock consumption, visit counting, completion≠payment, revenue
recognition timing, cash-drawer crediting, gift-card exclusion, and commission attribution —
behaves the same as Flowesce on the same inputs.

**Does not prove:** the UI. Production still serves an older build (`dpl_3yUATu1JscGN2RqFahb8ULKoo91C`);
the patched `app/index.html` reads the snapshot columns but is not deployed. This replay tests
the database, which is where all of the above logic lives.

**Not covered here:** refunds (design only — `docs/design/REFUND_ARCHITECTURE.md`, 7 open owner
decisions), concurrency, and the 22 modules still at NO PARITY
(`docs/parity/FLOWESCE_TO_AVOCADO_PARITY_MATRIX.md`).

## Re-running this as a regression suite

The full SQL chain is in the session transcript and is re-runnable verbatim: it creates its own
tenant via `create_business`, drives the four steps, asserts each number, and rolls back. Two
gotchas cost time and are worth recording so the next run doesn't repeat them:
`products.retail_price_cents` (not `price_cents`), `stock_batches` has **no** `business_id`, and
`sale_balance.payment_status` (not `status`). Several RPCs are permission-gated via
`app.has_perm` and fail closed without an impersonated owner JWT — that is correct behaviour,
not a bug.
