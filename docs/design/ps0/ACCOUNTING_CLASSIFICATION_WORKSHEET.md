# PS-0 Accounting Classification Worksheet

Status: **PS-0 deliverable (Contents item G — see `PROGRAM_STUDIO_ARCHITECTURE.md` §17, PS-0
row: "…accounting-classification worksheet ⚖️").** Author: Fable 5. Date: 2026-07-23.
Grounded against `supabase/migrations/*.sql` as it exists in this repo today (branch
`codex/phase0-transaction-foundation`), not merely against the architecture document —
every "today" claim below cites the migration file and function/table that produces it.

---

## 0. What this is — and what it is NOT (read first)

**This worksheet is a product/accounting *configuration* aid. It is not a legal opinion, not
an accounting compliance certification, and not tax advice.** ⚖️ Every classification choice
below must be reviewed and selected by the business's own accountant (and, for GST and other
statutory questions, its own advisor or IRAS guidance) before it is treated as the business's
accounting policy. Frenly computes the underlying numbers precisely and consistently — it does
not, and cannot, know which accounting treatment is correct for a given firm's structure,
industry, or filing position.

**No figure produced by this platform is an "exact accounting liability" until the business's
accountant has selected a policy for the relevant item below and that selection has been
reviewed.** Every number in Frenly's reporting is a computed fact under a *default* or
*currently-selected* policy — it becomes the firm's accounting truth only once an accountant
has signed off on that policy (§14). This mirrors the standing rule already written into the
architecture (`PROGRAM_STUDIO_ARCHITECTURE.md` §10, measure 6): "Accounting estimate — only
after an accounting policy is selected, labeled 'requires accountant review'; nothing is ever
presented as an exact accounting liability before that ⚖️."

## 1. How to use this worksheet

For each of the ten items in §4, the accountant (with the owner) should:
1. Read **"Today (verified)"** — what the platform actually records right now, with citations.
2. Answer the **classification question**.
3. Pick one of the **configurable options** (or state a different one — Frenly's job is to
   expose the mechanism, not to prescribe the answer). Where a mechanism to encode the choice
   already exists in the schema, it is named explicitly. Where it does not exist yet, that is
   stated plainly as **planned** — this worksheet does not pretend a future capability is live.
4. Record the choice, date, and name in the sign-off table (§14).
5. Where a live RPC exists to encode the choice (`set_sale_policy`, `reclassify_sale_policy`),
   an engineer applies it under the owner's authorization — this worksheet is the input to that
   step, not a substitute for it.

## 2. Legend

- **DEFAULT-SUGGESTION** — a starting point offered for the accountant to confirm, adjust, or
  reject. Never means "compliant," "correct," or "recommended by Frenly's own authority" — it
  means "the option that requires the least deviation from the platform's current live
  behaviour, or the most common SG small-business convention," stated so the accountant has
  a baseline to react to rather than a blank page.
- **Today (verified)** — behaviour confirmed by reading the actual `supabase/migrations/*.sql`
  file in this repository, cited by filename and function/table/trigger name.
- **Planned** — described in `PROGRAM_STUDIO_ARCHITECTURE.md` but not present in any migration
  in this repo; verified absent by direct search, not assumed absent.
- ⚖️ — flags a point needing the business's own counsel/accountant, not a Frenly answer.

---

## 3. Snapshot of the accounting-relevant mechanism (for orientation)

| Mechanism | What it does | Where |
|---|---|---|
| `sale_policies` / `app.sale_policy_defaults()` / `app.sale_policy_set()` | Per-business, per-`sales.kind` override of three orthogonal flags: `counts_as_revenue`, `counts_as_visit`, `earns_points`. NULL = inherit the platform default. | `supabase/migrations/20260718180019_frenly_v10_sale_policy.sql` |
| Policy **snapshot** on `sales` | The resolved policy is copied onto the `sales` row itself (`counts_as_revenue`/`counts_as_visit`/`earns_points`/`policy_resolved_at`) at INSERT time and frozen — historical reporting always reads the sale's own snapshot, never a live re-resolution, so changing a policy tomorrow never silently rewrites yesterday's numbers. | `supabase/migrations/20260718180110_frenly_v10_1_policy_snapshot.sql`, trigger `app.on_sale_policy_snapshot` |
| `public.reclassify_sale_policy(sale_id, counts_as_revenue, reason)` | Owner-only, audited, reason-mandatory RPC to **restate revenue classification on one already-recorded sale** — the literal "accountant reviewed it and the answer changed" mechanism. Changes `counts_as_revenue` **only**; `counts_as_visit`/`earns_points` are permanently frozen because loyalty ledgers were already written against them. | `supabase/migrations/20260718180110_frenly_v10_1_policy_snapshot.sql` |
| `public.get_revenue_summary(business, from, to, branch)` | Returns `revenue_accrual_cents`, `revenue_cash_cents`, `cash_collected_cents`, `unpaid_balance_cents`, `expenses_cents`, `net_accrual_cents`, `net_cash_cents` — accrual and cash computed side by side, always. | `supabase/migrations/20260718180329_frenly_v11b_money.sql` |
| `public.sale_balance` (view) | Per-sale `paid_cents`, `balance_cents`, `payment_status ∈ {unpaid, partial, paid, overpaid}`. | `supabase/migrations/20260718180329_frenly_v11b_money.sql` |
| `public.reverse_sale(...)` | Books a **signed, negative-amount sale row** of the same `kind`, referencing the original via `reversal_of` — append-only, never an UPDATE/DELETE of the original. | `supabase/migrations/20260719034201_frenly_v20_financial_engine.sql` (superseding an earlier v20 draft; extended by v34) |
| `app.get_dashboard_kpis` / `app.get_reports_summary` | `revenue_by_kind` / `non_revenue_by_kind` (split by `counts_as_revenue`), `credit_liability_cents` (sum of positive `client_credit_balance`), `gift_card_liability_cents` (sum of active `gift_cards.balance_cents`), `active_memberships`. | `supabase/migrations/20260719032517_frenly_v18_scalable_reporting.sql` |

---

## 4. Classification items

### 4.1 Sale revenue — service / retail / quick_sale kinds (accrual vs cash timing)

**Today (verified).** A `sales` row is created by `record_quick_sale`, `record_cart_sale`
(one parent row per cart), `record_sale_by_phone`, or the appointment-completion trigger. At
INSERT, `app.on_sale_policy_snapshot()` freezes `counts_as_revenue`/`counts_as_visit`/
`earns_points` from `app.sale_policy(business, kind)`. The platform default
(`app.sale_policy_defaults()`) marks `service`, `retail`, and `quick_sale` all
`counts_as_revenue = true, counts_as_visit = true, earns_points = true`.
`get_revenue_summary` already computes **both** bases continuously, not just one:
`revenue_accrual_cents` = Σ `sales.amount_cents` where `counts_as_revenue`, dated by
`sales.occurred_at` (recognized when the sale/service event is recorded, independent of
payment); `revenue_cash_cents` = Σ linked `payments.amount_cents` for those same
revenue-flagged sales, dated by `payments.occurred_at` (recognized only when cash is actually
received). `app.get_reports_summary` additionally breaks totals out as `revenue_by_kind` /
`non_revenue_by_kind`.

**Classification question.** Should [service | retail | quick_sale] revenue be recognized on
an **accrual** basis (at the point of sale/service completion — matching when the loyalty-earn
event also fires) or a **cash** basis (at the point payment is actually received) for this
business's internal management reporting and, separately, for what its bookkeeper posts to the
general ledger? These need not be the same answer.

**Configurable options.**
| Option | Mechanism |
|---|---|
| **Accrual-basis internal reporting** — **DEFAULT-SUGGESTION** | Read `revenue_accrual_cents` / `revenue_by_kind` as "revenue." Matches SG norms for service/retail businesses recognizing revenue at point of delivery. |
| Cash-basis internal reporting | Read `revenue_cash_cents` as "revenue" instead. Both are computed today; this is a reporting-lens choice, not a schema change. |
| Per-kind revenue-flag override, going forward | `public.set_sale_policy(business, kind, counts_as_revenue, counts_as_visit, earns_points)` — owner-only. Future sales of that kind snapshot the new flag; past sales are untouched. |
| Historical restatement of one sale | `public.reclassify_sale_policy(sale_id, counts_as_revenue, reason)` — owner-only, audited, reason ≥ 10 characters, changes only that one sale's revenue flag. |

**Feeds:** `get_revenue_summary.revenue_accrual_cents` / `.revenue_cash_cents` /
`.net_accrual_cents` / `.net_cash_cents`; `get_reports_summary.revenue_by_kind` /
`.non_revenue_by_kind`; owner CSV sales export (`counts_as_revenue` column,
`app/index.html` ≈L6720).

---

### 4.2 Unpaid sale / receivable (`p_paid = false`, partial tender)

**Today (verified).** `record_quick_sale(..., p_paid boolean default true)` and
`record_payment(...)` allow a sale to be recorded with **no** payment row (fully on account) or
a payment **less than** the total (partial tender) — nothing forces `paid = total` at sale
time. `public.sale_balance` (a view, `supabase/migrations/20260718180329_frenly_v11b_money.sql`)
computes, per sale: `paid_cents` (Σ linked `payments`), `balance_cents = amount_cents −
paid_cents`, and `payment_status ∈ {unpaid, partial, paid, overpaid}`.
`get_revenue_summary.unpaid_balance_cents` = Σ `sale_balance.balance_cents` for
revenue-flagged sales with `balance_cents > 0` in the period — this **is** the platform's
accounts-receivable figure, computed live from the ledger, not stored as a separate balance.

**Classification question.** Is an unpaid/partially-paid sale recognized as revenue at all
(accrual, with the gap booked as a receivable) — or excluded from revenue until collected
(pure cash basis, no A/R concept on the books)? Separately: at what point, if any, does an
aged unpaid balance become a bad-debt write-off, and who authorizes it? (**No such mechanism
exists on the platform today** — flagged, not answered, below.)

**Configurable options.**
| Option | Mechanism |
|---|---|
| **Accrual revenue + A/R** — **DEFAULT-SUGGESTION** | `unpaid_balance_cents` is the receivable; consistent with §4.1's accrual default already producing `revenue_accrual_cents` unconditionally on payment. |
| Cash-only revenue, no A/R | Report only `revenue_cash_cents`; treat `unpaid_balance_cents` as a memo/collections worklist, not a balance-sheet figure. |
| Bad-debt / write-off policy | **Planned, not built.** There is no aging bucket, no write-off flag, and no reversal-for-uncollectible path today; an aged unpaid sale simply stays open in `sale_balance` indefinitely. If the firm needs this, it is a scoping item for engineering, not a policy toggle that exists yet. |

**Feeds:** `sale_balance.balance_cents` / `.payment_status`; `get_revenue_summary.unpaid_balance_cents`.

---

### 4.3 Gift-card issue (cash collected, not revenue) and redemption (revenue recognition point)

**Today (verified).** `public.issue_gift_card` (`supabase/migrations/20260718175936_frenly_v9_giftcard_revenue.sql`)
inserts a `gift_cards` row (`balance_cents = initial_cents, status = 'active'`) **and** a
`sales` row with `kind = 'gift_card'`. The platform default pins
`gift_card → counts_as_revenue = false, counts_as_visit = false, earns_points = false` — cash
collected, not revenue, no loyalty side-effect (this is the CLAUDE.md v9 rule, verified live
and unchanged through v10.1's snapshot mechanism). `get_reports_summary.gift_card_liability_cents`
= Σ `gift_cards.balance_cents` where `status = 'active'` — reported as a liability line,
separate from `credit_liability_cents`. Redemption — `public.redeem_gift_card`
(`supabase/migrations/20260719034201_frenly_v20_financial_engine.sql`) — decrements
`gift_cards.balance_cents`, flips `status → 'redeemed'` at zero, and inserts **one**
`credit_ledger` row (`entry_type = 'gift_card_load'`) for the amount loaded — a one-way
conversion of card balance into spendable promotional credit. **No `sales` row is written at
redemption.** The revenue event happens later, when that credit is actually spent as `credit`
tender against a real `service`/`retail`/`quick_sale` sale — which is itself revenue-flagged
and accrual/cash-tracked exactly per §4.1.

**Classification question.** Confirm the recognition sequence — **issue = liability only;
redemption-into-credit = still a liability, merely relabeled from card balance to store
credit; spend of that credit against a real sale = the revenue event** — matches this firm's
own treatment of gift cards as deferred revenue. Separately ⚖️: does the firm intend to ever
recognize **breakage** (unredeemed gift-card value, after some period, as revenue)? **No
expiry or breakage mechanism exists on `gift_cards` today** — there is no expiry column and no
sweep job — so this option is not currently expressible, only discussable.

**Configurable options.**
| Option | Mechanism |
|---|---|
| **Deferred revenue until spent** — **DEFAULT-SUGGESTION** | This is the platform's current, structural behaviour — no configuration needed, only accountant confirmation. |
| Breakage recognition after N months unredeemed | **Not built.** Would require a new `gift_cards.expires_at` (or equivalent) column and a sweep/recognition job before this is a real option, not merely a policy flag to flip. |

**Feeds:** `gift_card_liability_cents` (balance-sheet-style liability); `revenue_by_kind`
never carries a `'gift_card'` entry by construction; the eventual spend appears in ordinary
`revenue_accrual_cents` / `revenue_cash_cents` under whichever kind the redeeming sale was.

---

### 4.4 Customer-paid stored value (deferred revenue) — **PS-2, planned**

**Today (verified absent).** Searched every file in `supabase/migrations/` for `sv_lots`,
`sv_plan_versions`, `sv_lot_movements`, and the string `'topup'` — **zero matches.**
`sales.kind`'s live CHECK constraint (`service|retail|membership|quick_sale|gift_card|package`,
per `20260718180019_frenly_v10_sale_policy.sql`) has no `topup` value, and
`app.sale_policy_defaults()` has no `topup` row. This capability does not exist in the
database yet.

**Planned mechanism (`PROGRAM_STUDIO_ARCHITECTURE.md` §5, decision S1).** A top-up will mint
two **immutable** `sv_lots` (paid class + bonus class); all balance change flows through
append-only `sv_lot_movements`. PS-2's migration is specified to extend the `sales.kind` CHECK
with `'topup'` and add an `app.sale_policy_defaults()` row of
`(counts_as_revenue=false, counts_as_visit=false, earns_points=false)` — explicitly "the v9
gift-card precedent," reused deliberately rather than reinvented.

**Classification question (answered in advance, so a policy exists before the mechanism
ships).** Should customer-paid stored value be deferred revenue at top-up (mirroring gift
cards), recognized only when the paid-class balance is spent? Is stored value ever cash-
refundable (unlike a gift card today, which has no refund path at all)?

**Configurable options.**
| Option | Mechanism |
|---|---|
| **Deferred revenue at top-up, recognized at spend** — **DEFAULT-SUGGESTION** | Pins the architecture's own S1 default (`counts_as_revenue=false`), symmetric with gift cards. |
| Refundable per §5's refund matrix | Cash refund = paid-class remaining only; bonus-class remaining is clawed back at refund time. Fully specified in the architecture (numeric matrix, `PROGRAM_STUDIO_ARCHITECTURE.md` §5) but **not built**. |

**Feeds (once built):** a new `stored_value_liability_cents`-style report line — paid-class
and bonus-class shown **separately, always** per architecture §4's single-representation
invariant, never blended into one "value" figure.

---

### 4.5 Promotional top-up bonus (promotional expense timing) — **PS-2, planned**

**Today (verified absent).** Same grep result as §4.4 — no bonus-class lots exist anywhere in
the schema.

**Planned mechanism.** Bonus-class `sv_lots` mint alongside paid-class lots at top-up; a spend
draws proportionally from both classes (floor-rounded, business-favorable by ≤1¢); unspent
bonus is clawed back — never cashed out — on refund or expiry (architecture §5, full numeric
matrix).

**Classification question.** Two valid treatments exist; both are presented, neither is
favored by the platform:
1. **Expense-at-issue** — recognize the promotional bonus as a marketing/promotional expense
   the moment it is granted (at top-up). Simpler; symmetric with how a discount coupon is
   often expensed on issue. Can overstate expense if the bonus is later clawed back on refund
   or expires unused.
2. **Expense-at-consumption** — recognize the promotional cost only as bonus cents are
   actually drawn in a `spend` movement. More conservative; matches the platform's stated
   realized-cost discipline elsewhere (`PROGRAM_STUDIO_ARCHITECTURE.md` §10: "Realized cost is
   computed **only** from `benefit_fulfilments`" / fulfilment records, never from the grant).

**Configurable options.**
| Option | Mechanism |
|---|---|
| **Expense-at-consumption** — **DEFAULT-SUGGESTION** | Consistent with the platform's single-count/realized-cost design elsewhere (§10); avoids re-computation on refund clawback. |
| Expense-at-issue | Simpler bookkeeping; some SME accountants prefer it. Explicitly offered, not favored. |

**Feeds (once built):** a future `promotional_expense_cents` line sourced from
`sv_lot_movements` — either `spend` movements (class=bonus) under treatment 2, or `issue`
movements under treatment 1, **never both**, to avoid double-expensing the same bonus cent.

---

### 4.6 Points and non-cash rewards (provision/expense estimation, breakage) — **partly live, economics planned**

**Today (verified).** Points earn/redeem is live: `points_ledger`
(`entry_type ∈ {earn, redeem, expire, adjust}`) + `points_batches` (FEFO detail, `remaining`,
`expires_at`). Redemption (`public.redeem_points` / `app.redeem_reward_core`) converts points
into a `credit_ledger` entry (or an entitlement), draining `points_batches` FEFO; since
`supabase/migrations/20260721000013_frenly_v34_reversal_provenance.sql`, every redemption's
drain and any reversal of it carries exact provenance
(`loyalty_redemption_provenance`, `loyalty_redemption_batch_drains`,
`loyalty_redemption_reversals`). Retention-program non-cash rewards (`reward_grants`) and
referral rewards post directly to `credit_ledger` (`'loyalty_earn'` / `'referral_reward'`) **at
grant time** — today's "cost" of a loyalty reward is already realized in the credit ledger the
moment it's granted, not estimated.

**What is not built:** any expected-liability *provision* for points currently outstanding but
unredeemed (i.e., "if every point sitting in customer wallets were redeemed today, what would
it cost"), and no breakage/expiry-adjusted discount on that provision. Verified no
`economic_assumptions` table exists anywhere in `supabase/migrations/` — the architecture
labels this PS-4, explicitly not yet built.

**Classification question.** How should the firm treat its outstanding, unexpired points
balance for accounting purposes: as a provisioned liability (estimated redemption cost), or
expensed only when actually redeemed (no provision, cash-basis-style, matching today's gift-
card and credit treatment)?

**Configurable options.**
| Option | Mechanism |
|---|---|
| **No provision; expense only at redemption** — **DEFAULT-SUGGESTION for a pilot-stage SME** | Matches the current, only implemented mechanism exactly — zero new build, appropriate while outstanding balances are small/immaterial. |
| Estimated provision (cohort model) | Architecture §10's planned low/base/high scenario columns, weighted cost-per-point over the active reward mix, expiry-breakage discount, seeded from the business's own redemption history (or industry-pack priors before ≥N observations). Explicitly labeled "requires accountant review," never presented as an exact liability. **Not built.** |

**Feeds:** today, `get_reports_summary.points_by_type` and `credit_ledger`
(`loyalty_earn`/`referral_reward` entries feeding `credit_liability_cents`); once PS-4 ships, a
new `points_exposure_cents` line (three scenario columns), reported **separately** from the
realized `credit_liability_cents`, never blended into it.

---

### 4.7 Packages (revenue upfront vs deferred per session)

**Today (verified).** `public.sell_package`
(`supabase/migrations/20260718180019_frenly_v10_sale_policy.sql`) inserts
`client_packages(remaining = plan.sessions)` and a `sales` row
`kind = 'package', amount_cents = plan.price_cents` — the **full** price billed upfront.
Default policy: `package → counts_as_revenue = true, counts_as_visit = false,
earns_points = true`. `public.use_package_session`
(`supabase/migrations/20260721000013_frenly_v34_reversal_provenance.sql`) decrements
`client_packages.remaining` and inserts a **separate** `sales` row per session used —
`kind = 'service', amount_cents = 0` — the retention-visit record (a $0 sale still counts as a
visit under `service`'s default `counts_as_visit = true`; source: the code comment in v34
itself — *"This is the retention-visit record: amount_cents = 0 and no payment is created"*).

**The CLAUDE.md v9-review open question, verified still live and unresolved in the current
schema.** Package revenue is booked in **full** at the moment of purchase
(`counts_as_revenue = true` on the `'package'`-kind sale), and points are earned on the
**full** package price at purchase (`earns_points = true`) — not spread across sessions as
they are consumed. v10 fixed the previously double-counted-visits defect
(`package.counts_as_visit = false`, so only the $0 per-session rows count as visits — one
visit per session actually used, not eleven for a ten-session package), but it did **not**
change the revenue-upfront-in-full or points-upfront-in-full treatment. CLAUDE.md records this
explicitly as open, pending an owner/accountant decision — "revenue-upfront may be deliberate
(the UI copy says 'revenue upfront'), but ... not changed" — this worksheet does not resolve
it; it hands the accountant the exact live behaviour to confirm or reject.

**Classification question.** Should package revenue be recognized **upfront** (in full, at
sale) or **deferred** and recognized proportionally as each session is consumed (matching when
the service is actually delivered)? Separately: should loyalty points be earned upfront on the
full package price, or per-session as sessions are used?

**Configurable options.**
| Option | Mechanism |
|---|---|
| **Revenue upfront, points upfront** — **DEFAULT-SUGGESTION (= current live behaviour)** | Requires no engineering change — only the accountant's confirmation that upfront recognition is acceptable for this firm's own accounts (many SG salon/spa/gym package products are sold and accounted for exactly this way). |
| Revenue deferred per session | **Not built.** Would require recognizing `1/N` of `plan.price_cents` on each `use_package_session` call instead of booking the full amount at `sell_package` — an engineering item if selected, not a policy toggle that exists yet. |
| Points earned per session, not upfront | **Not built.** Would require moving the earn trigger from the `'package'`-kind purchase sale to each `$0 kind='service'` session-use sale, and a non-amount-based earn rule (today's earn math is `floor(amount_cents/100 × rate)`, which is 0 on a $0 row). |

**Feeds:** `revenue_by_kind['package']`; `get_revenue_summary.revenue_accrual_cents`;
the visit-count/retention window in `app.on_sale_recorded` (reads `counts_as_visit`);
`get_reports_summary.points_by_type['earn']`.

---

### 4.8 Memberships (cadence revenue, credit drops)

**Today (verified).** `public.enroll_membership`
(`supabase/migrations/20260719034201_frenly_v20_financial_engine.sql`) inserts
`memberships(status = 'active', current_period_end = now() + cadence)` **and** a `sales` row
`kind = 'membership', amount_cents = plan.price_cents` (dues, billed at enrollment). Default
policy: `membership → counts_as_revenue = true, counts_as_visit = false,
earns_points = false` — dues are revenue but never a loyalty-earning "visit" or a points
event, a first-principles distinction the trigger already enforces. If the plan carries
`credit_cents > 0`, the **same transaction** also posts a `credit_ledger` row
(`entry_type = 'membership_credit', amount_cents = +credit_cents`) — the monthly/periodic
in-store-credit perk, converted into spendable promotional credit, exactly matching
`PROGRAM_STUDIO_ARCHITECTURE.md` §4's "Credit drops post to `credit_ledger` (recorded
conversion)." `app.run_membership_renewals()` re-runs this same pairing (a fresh dues sale +
a fresh credit drop) on every cadence rollover.

**Classification question.** Confirm that dues are recognized as revenue **at the moment
each cadence charge is booked** (today: each renewal is its own dated `sales` row — a monthly
plan books 12 separate revenue events across a year; an annual plan books one large revenue
event on its renewal date) matches this firm's own treatment. Separately, confirm the credit
drop is treated as a **promotional/marketing cost** (its face value, tracked via
`credit_liability_cents` until spent) rather than as a reduction of membership revenue — the
platform already keeps it structurally outside the `sales`/revenue path (a `credit_ledger`
grant, never a discount on the membership sale itself).

**Configurable options.**
| Option | Mechanism |
|---|---|
| **Cadence-point revenue recognition** — **DEFAULT-SUGGESTION (= current live behaviour)** | Each enrollment/renewal is its own dated sale; no configuration needed beyond confirmation. |
| Ratable/deferred recognition across the period | **Not built.** E.g., spreading an annual plan's dues evenly over 12 months rather than booking the full year on renewal day. Today an annual membership books its full year's dues on one date, same mechanism as monthly, just a larger figure. |

**Feeds:** `revenue_by_kind['membership']`; `get_reports_summary.active_memberships`;
`credit_liability_cents` (via `membership_credit` entries, until spent).

---

### 4.9 Refunds and reversals (contra-revenue vs expense; v20/v34 signed reversal semantics)

**Today (verified).** `public.reverse_sale`
(`supabase/migrations/20260719034201_frenly_v20_financial_engine.sql`, extended by
`supabase/migrations/20260721000013_frenly_v34_reversal_provenance.sql` for packages/loyalty
redemptions) inserts a **new** `sales` row with `reversal_of = <original>.id` and
`amount_cents = −original.amount_cents` — a signed, mirror-image row, never an UPDATE or
DELETE of the original (`sales` is append-only, enforced by `app.sales_immutable_guard`). The
reversal row carries forward the original sale's `kind`, so a reversed `retail` sale's negative
row is itself `kind = 'retail'` — reporting sums (plain `Σ amount_cents`) net the pair to zero
automatically. **This is why reporting reads as a signed additive sum, not a separate
"refunds" subtraction line: the reversal *is* a contra-revenue entry, by construction, within
the same kind.** Cash actually returned to the customer is a **separate** `payments` row
(`kind = 'refund', amount_cents < 0`), capped at the sale's validated paid amount; at present
only cash and store-credit tenders are refundable through this path — the migration's own
error text: *"launch refunds support only cash and proven store credit; provider-settled
methods are disabled."* Referral rewards **are** clawed back on reversal (a negative
`credit_ledger` `'manual_adjust'` entry). **Points earned on the reversed sale are explicitly
NOT clawed back at launch** — the migration's own comment states the reason directly:
*"Launch-safe points policy: observe, but do not claw back. Earned points may already have
been redeemed into credit and the current schema has no immutable redemption-to-earn
provenance or tenant policy that can prove the correct compensating chain."* Package-session
and loyalty-redemption reversals get their own exact provenance/reversal tables in v34
(`package_session_reversals`, `loyalty_redemption_reversals`), following the same
signed-sale-row pattern.

**Classification question.** Confirm that "reversal = a signed negative sale of the same kind,
netting automatically into that kind's revenue total" is the treatment this firm's accountant
wants — as opposed to booking refunds as a **separate** expense/contra-revenue line distinct
from gross revenue by kind. Separately ⚖️: the points-not-clawed-back gap above is a real,
disclosed limitation — the accountant should decide whether it is material enough to require a
manual, off-platform adjusting entry until a compensating mechanism ships.

**Configurable options.**
| Option | Mechanism |
|---|---|
| **Signed contra-revenue, netted within the same kind** — **DEFAULT-SUGGESTION (= current live behaviour)** | Only implemented mechanism today; the alternative below needs no new engineering, only a different report view. |
| Separate "Refunds & reversals" P&L line | Achievable **today** as a pure reporting-presentation choice — filter `sales` on `reversal_of IS NOT NULL` and show that total separately instead of netting it into the kind total. The underlying data already carries the distinction (`reversal_of`, `reversal_reason`, `reversal_actor`); no schema change needed. |

**Feeds:** nets automatically into `revenue_by_kind` / `revenue_accrual_cents` /
`revenue_cash_cents` (signed sum); the owner CSV sales export exposes `reversal_of`,
`reversal_sale_id`, `signed_amount_additive`, `relationship_net_original_only`, and `reason`
columns explicitly for this reconciliation (`app/index.html` ≈L6720–6721).

---

### 4.10 GST classification inputs (inclusive pricing default, discount-before-GST base; rate as config input)

**Today (verified).** A rate **input** primitive already exists and predates Program Studio:
`businesses.tax_rate_bps` (business-wide default) and `branches.tax_rate_bps` (nullable
per-branch override), both `integer 0–10000` — i.e. 0.00%–100.00%, expressed in basis points;
**no rate is hardcoded anywhere in the codebase.** Resolved by
`app.effective_tax_bps(branch) = coalesce(branch.tax_rate_bps, business.tax_rate_bps)`
(`supabase/migrations/20260718180155_frenly_v11a_branches_staff_services.sql`).
**Verified this field is currently dormant:** a search for `effective_tax_bps` / `tax_rate_bps`
across every file in `supabase/migrations/` shows it defined once and never referenced
again — no sale-recording RPC (`record_quick_sale`, `record_cart_sale`, `sell_package`,
`enroll_membership`, `issue_gift_card`) multiplies against it. `sales.amount_cents` today is
simply the caller-supplied total; whether that figure is GST-inclusive or exclusive is an
operational/UI convention today, **not something the database computes or enforces.**

The actual GST-aware computation — "tax base computed on the discounted total... SG overlay
default: GST-inclusive pricing" — is a **Program Studio §9 planned** behaviour, part of the
Unified Checkout Kernel's money order of operations (line discounts → bill discounts → tax
base on the discounted total → rounding → fixed total at completion), explicitly gated behind
PS-1C and marked "classification map reviewable ⚖️" in the architecture itself — not yet built
or applied to any live sale.

**Classification question.** (1) Is this business's pricing **GST-inclusive** (the
displayed/charged price already contains GST; GST is backed out for reporting) or
**GST-exclusive** (GST is added on top of the displayed price)? (2) What is this business's
current effective GST rate and registration status — entered as data via `tax_rate_bps`,
never assumed by the platform? (3) When a discount is applied, is GST computed on the
pre-discount or the post-discount amount (discount-before-GST-base)?

**Configurable options.**
| Option | Mechanism |
|---|---|
| **GST-inclusive pricing; discount applied before the GST base is computed** — **DEFAULT-SUGGESTION** (a starting point reflecting common SG retail/F&B/services convention — never asserted as the compliant answer) | `tax_rate_bps` holds the rate as data; the discount-before-tax-base computation is the planned §9 kernel behaviour. |
| GST-exclusive pricing (rate added on top) | Same rate field, different application order — a §9 kernel configuration choice once built. |
| Not GST-registered / rate = 0 | `tax_rate_bps = 0` is the column's own default — valid and common for a small pilot-stage SME below the registration threshold. The accountant, not the platform, confirms current registration status. |

**Feeds:** no live report line today (the field is unused); once wired (PS-1C or later), would
feed a GST output/input reconciliation line and the discounted-total tax base used at
checkout. **No GST rate or registration claim is made by this worksheet or the platform** ⚖️.

---

## 5. Known current-behaviour flags (read before signing off)

These are things this audit found while verifying the items above — not new classification
questions, but disclosures the accountant/owner should have visibility into before signing
off, because they affect how much weight to put on today's numbers for the affected kinds.

1. **`record_cart_sale` (v51) item-type permissiveness vs. wiring gap.** The `sale_items` CHECK
   constraint and `record_cart_sale`'s own line-type validation accept
   `item_type ∈ {service, retail, package, membership, gift_card, custom}` as descriptive line
   items inside **one** parent `sales` row of `kind = 'quick_sale'`
   (`supabase/migrations/20260723120000_frenly_v51_sale_line_items.sql`). The RPC does **not**
   call `sell_package` / `enroll_membership_v41` / `issue_gift_card` for those line types and
   does **not** apply their dedicated (`revenue=false`/`visit=false`/`points=false`-style)
   `sale_policy` — the **entire cart total**, including any `gift_card` or `membership` line,
   would be billed under the parent's `quick_sale` policy (revenue = true, visit = true,
   points = true) if such a line were ever actually submitted this way. **Verified this is not
   a live production risk through the shipped UI**: `app/index.html` (≈L3842–3852) explicitly
   documents and correctly implements routing gift-card/package/membership additions through
   their own dedicated RPCs, one call per line, **never** as `record_cart_sale` line items —
   the code comment states plainly *"the engine treats those item_types as descriptive; the
   real package/membership sale rows come only from the overloads."* This is consistent with,
   and reinforces, `PROGRAM_STUDIO_ARCHITECTURE.md` §9's listing of gift-card issue/redemption
   and package sell/session-use as separate writer surfaces from the till/cart path. It remains
   a **database-layer** gap worth a defensive follow-up (a CHECK narrowing `record_cart_sale`'s
   accepted `item_type`s to what it actually wires, `service|retail|custom`) so a future direct
   API caller — not the shipped UI — cannot mis-bill a gift-card or membership line as ordinary
   revenue. This is a code-path hardening item for the PS-0 writer audit, not something this
   worksheet's policy choices can resolve.
2. **Package revenue/points-upfront** (§4.7) — confirmed still the live, unresolved-by-design
   state exactly as CLAUDE.md's v9-review note describes; not a regression, not yet a decision.
3. **Points not clawed back on sale reversal** (§4.9) — disclosed directly in the v20
   migration's own code comment; a known, intentional launch-scope limitation, not an
   oversight.
4. **`tax_rate_bps` is a live, unused config column** (§4.10) — the input primitive exists
   ahead of the computation that will consume it.
5. **No aged-receivable / bad-debt write-off mechanism** (§4.2) — an unpaid sale stays open in
   `sale_balance` indefinitely; there is no write-off flag or reversal-for-uncollectible path.
6. **No gift-card/stored-value expiry or breakage mechanism** (§4.3/§4.4) — `gift_cards` has
   no expiry column; breakage recognition is not expressible today, only discussable.

None of the above contradicts `PROGRAM_STUDIO_ARCHITECTURE.md` §5, §10, or §17 — the
architecture document's own decision log and sequencing table already scope stored value,
economics, and the writer audit as **not yet built** (PS-2/PS-4, PS-0 respectively), and item 1
above is, if anything, independent confirmation that the architecture's planned writer-audit
scope (§9) correctly anticipates gift-card/package surfaces as distinct from the cart.

---

## 6. Sign-off table

To be completed by the business's own accountant (with the owner). Each row's "Policy chosen"
should name one of the options in the matching §4 item, or a stated alternative. Leaving a row
blank means the platform's **DEFAULT-SUGGESTION** applies provisionally, but is **not** an
accounting sign-off — it is simply what the system will report until a policy is chosen.

| # | Item | Policy chosen | Effective date | Accountant name | Signature / initials | Notes |
|---|---|---|---|---|---|---|
| 4.1 | Sale revenue (service/retail/quick_sale) — accrual vs cash | | | | | |
| 4.2 | Unpaid sale / receivable treatment | | | | | |
| 4.3 | Gift-card issue & redemption recognition | | | | | |
| 4.4 | Customer-paid stored value (PS-2, planned) | | | | | |
| 4.5 | Promotional top-up bonus expense timing (PS-2, planned) | | | | | |
| 4.6 | Points / non-cash rewards provisioning (PS-4, planned) | | | | | |
| 4.7 | Packages — revenue/points upfront vs deferred | | | | | |
| 4.8 | Memberships — dues recognition & credit-drop treatment | | | | | |
| 4.9 | Refunds & reversals — contra-revenue vs separate expense | | | | | |
| 4.10 | GST — inclusive/exclusive, discount-before-base, rate | | | | | |
| — | **GST registration status & current rate** (data, not advice) | rate: _____ bps; registered: Y / N | | | | ⚖️ business's own filing status |
| — | **Overall sign-off**: I have reviewed the above and understand that Frenly computes these figures under the policies selected here, and that they are not a substitute for my own review of the business's statutory accounts. | | | | | |

---

## 7. Mapping note — from this worksheet to the market-overlay accounting map

The policy choices recorded in §6 are the accounting-classification **inputs** that two later
architecture mechanisms consume, not a new mechanism of their own:

- **§10 (Economics)** consumes the revenue/points/provisioning choices directly: which sale
  kinds count as revenue (§4.1, §4.3, §4.7, §4.8), how refunds net (§4.9), and whether points
  exposure is provisioned or expensed-at-redemption (§4.6) all feed straight into the "six
  separated measures" §10 defines (customer face value, estimated variable cost, granted
  exposure, realized fulfilment cost, expected future cost, and the accounting estimate that
  "requires accountant review") — this worksheet is what makes measure 6 answerable per firm.
- **§16 (Templates and composer)** is where a **Singapore market overlay** would eventually
  package a *default* answer to every question in §4 — e.g. GST-inclusive pricing, package
  revenue-upfront, deferred stored value — as the starting configuration a new SG firm gets at
  Quick-Start time, with this worksheet's per-firm sign-off (§6) always able to override the
  overlay's defaults for that one business. Note precisely: `PROGRAM_STUDIO_ARCHITECTURE.md`
  §10 itself does not use the phrase "market-overlay accounting map" — the overlay/composer
  mechanism is specified in §16 (`template_pack_versions`, `market_overlay_versions`,
  provenance pinning), while §10 defines the economics measures those overlay defaults would
  feed. This note connects the two accurately rather than asserting a citation that isn't
  there; **no overlay encoding this worksheet's answers exists yet** — §16 is PS-5, the last
  phase in the sequencing table (§17), and nothing in this worksheet is a substitute for that
  future, explicit engineering step.

Until PS-5 ships, every classification in §6 is applied **per firm**, by hand, through the live
mechanisms named in §3–§4 (`set_sale_policy`, `reclassify_sale_policy`, and reporting-lens
choices that need no schema change) — never silently assumed by the platform.
