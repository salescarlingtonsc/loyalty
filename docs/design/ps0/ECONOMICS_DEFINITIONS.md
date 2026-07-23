# PS-0 Economics Definitions (scope F) — FREEZE

Status: **PS-0 contract, freeze-ready.** Reports to Fable 5. Authority:
`docs/design/PROGRAM_STUDIO_ARCHITECTURE.md` rev 4 §10 (six measures + points exposure) and
§11 (budget commitment), with the single-count guarantee from §3/§7. Every schema claim
grounded in `supabase/migrations/*.sql` (latest wins). Forced decisions → **§5 Decisions made
during freeze**. Sibling PS-0 artifact: the **accounting-classification worksheet ⚖️**
(`docs/design/ps0/ACCOUNTING_CLASSIFICATION_WORKSHEET.md`, authored separately — §4 references
it).

> **Build status.** `benefit_fulfilments`, `economic_assumptions`, and `budget_periods` are
> PS-1B/PS-4 tables that **do not exist today**. This freeze defines the measures they compute;
> the cited *source* columns (`points_batches`, `loyalty_rewards`, `loyalty_redemptions`,
> `reward_grants`, `retention_campaign_grants`) are **live today**.

---

## 1. The six measures (§10, frozen)

The **single-count guarantee (§3 B1/B3/N1):** every `rule_effect_log` row that moves or
promises value references **exactly one** `benefit_fulfilments` row (unique by
`canonical_benefit_key`). Every cost measure below reads **only** `benefit_fulfilments` for
amounts — the effect log contributes attribution, never amounts. Therefore no measure can
double-count across grants / redemptions / birthday / campaign / SV bonus. This is the double-
count guard cited in every row.

| # | Measure | Precise definition | Exact source (tables · columns · filters) | Update timing | Double-count guard |
|---|---|---|---|---|---|
| **1** | **Customer face value** | What the customer sees ("$5 off", "500 credit") — the headline promise, never a cost | `Σ benefit_fulfilments.face_value_cents` over the scope. Today's underlying columns: `loyalty_redemptions.credit_cents` (`…v23:40`), `reward_grants.reward_type/reward_value` (`…v2_saas.sql:109`), `customer_birthday_entitlements.benefit_snapshot` (`…c45:127`), `retention_campaign_grants` offer | At fulfilment / grant write | One fulfilment row per benefit (unique key); face value is per-row |
| **2** | **Estimated variable cost** | Margin-band model estimate of the business's variable cost of the benefit, with a confidence tag per input source | `Σ benefit_fulfilments.estimated_cost_cents`, carrying `cost_basis` + `cost_confidence` (`BENEFIT_REGISTRY_CONTRACT.md §4`). Bases: `credit_face` (high), `catalog_cost` (medium, from product/service catalog), `benefit_snapshot` (medium), `owner_offer_cost` (high, `retention_campaign_grants.offer_cost_cents` `…v50:158`), `discount_face` (high), `margin_band` (low) | Captured **at fulfilment time**, immutable thereafter | Amounts read only from the single fulfilment row |
| **3** | **Granted exposure** | Outstanding promises not yet redeemed, risk-weighted: `Σ (outstanding face/cost × scenario redemption rate × est. cost)` | Outstanding = `benefit_fulfilments` promise rows still unredeemed; today's live promises: `reward_grants` where `status='granted'` (`…v2_saas.sql:112`), `customer_birthday_entitlements` where `status='available'` (`…c45:124`), unredeemed `retention_campaign_grants`. Rates from `economic_assumptions` (PS-4) | Nightly + on grant/redeem | Each promise = one fulfilment row; redemption flips it, never adds a second |
| **4** | **Realized fulfilment cost (period)** | Actual cost incurred in the period, net of reversals | `Σ benefit_fulfilments.estimated_cost_cents WHERE occurred_at ∈ period`, **minus** reversal rows (`reverses_fulfilment_id IS NOT NULL`, negative amounts, §8-registry) | As fulfilments occur | **Only** from fulfilment records (§10); reversals net to zero under the same key |
| **5** | **Expected future cost** | Forward liability estimate: the **cohort points model (§2)** for outstanding points + expected redemption of outstanding entitlements | `points_batches` (cohorts) + outstanding `benefit_fulfilments` promises + `economic_assumptions` scenario rates/breakage | Nightly | Points via cohort (not per-earn rows, D-registry-1); entitlements via their single promise rows |
| **6** | **Accounting estimate** ⚖️ | An accounting figure **only after an accounting policy is explicitly selected and reviewed** — always labeled *"requires accountant review"* | Derived from measures 3–5 under the selected policy in the accounting worksheet ⚖️ | Only when a policy is active | **Never presented as an exact accounting liability before a reviewed policy exists** (§4) |

All six are **reported side by side** (§10). Measures are read-models over real
`benefit_fulfilments` + real ledgers — copies are structurally impossible (§2-arch singleton
"one projection layer").

---

## 2. Cohort-based points-exposure model (§10, spelled out)

Points exposure is **never** the minimum credit-per-point ratio (the rev-1 defect). It is a
cohort model over outstanding points.

### 2.1 Cohort definition
Outstanding points are the live `points_batches` rows with `remaining > 0`
(`…v3_engine.sql:9-20`: `earned`, `remaining`, `earned_at`, `expires_at`). A **cohort** groups
these by:
- **expiry cohort** — bucketed by `expires_at` window (e.g. calendar month of expiry), and
- **expiry mode** — `loyalty_programs.expiry_mode ∈ (none, inactivity, fixed)` +
  `expiry_days`/`points_expiry_days` (`…v3:4-6`; `…v23:5`).

Points in `expiry_mode='none'` cohorts never break by expiry; `fixed`/`inactivity` cohorts
carry a breakage term (§2.4).

### 2.2 Scenario redemption rate (low / base / high)
Three scenario rates per cohort, from `economic_assumptions` (PS-4; `business_id`, `scenario`,
`redemption_rate`, `source`, `n_observations`, versioned on the config spine):
- **Seeded from the business's own history once `n_observations ≥ N`** — realized redemption
  share = redeemed points ÷ earned points over a trailing window, from `loyalty_redemptions`
  (`…v23:33`) vs `points_ledger` earns.
- **Industry-pack priors before that** (cold start), tagged **low confidence**.
- `N` (the cold-start threshold) is an assumption value, versioned, owner-visible. (D1.)

### 2.3 Weighted cost per point
Over the **active reward mix**, not a single ratio:
- Per active reward, cost-per-point = `loyalty_rewards.credit_cents ÷ loyalty_rewards.cost_points`
  (`…v23:14-15`, both live, `cost_points > 0`).
- **Weights = trailing redemption shares** — each reward's share of recent redemptions
  (`loyalty_redemptions.reward_id`, `…v23:37`).
- **Cold start = catalog-uniform** (every active reward weighted equally) tagged **low
  confidence**, until enough redemptions exist to weight by share.

### 2.4 Breakage
`(1 − expiry_breakage_for_cohort)` — the fraction of the cohort expected to expire unredeemed,
by expiry mode. `none` → 0 breakage; `fixed`/`inactivity` → a mode-specific rate from
`economic_assumptions`.

### 2.5 The formula
```
points_exposure(scenario) =
  Σ over cohorts c [
      remaining_points(c)
      × redemption_rate(scenario)        -- §2.2, seeded or prior
      × weighted_cost_per_point          -- §2.3, mix-weighted
      × (1 − breakage(c))                -- §2.4, by expiry mode
  ]
```
**All three scenario columns (low/base/high) are always shown** (§10). Assumptions are
editable and **versioned** on the config spine (`firm_config_versions`, `…v26:13`) — every
economics read is reproducible against the assumption version in force.

---

## 3. Owner budget commitment semantics (§11, verbatim-consistent)

| Effect class | Budget committed | Mechanism |
|---|---|---|
| Checkout discount | During atomic checkout | Reservation row written in the sale transaction against the locked period counter; token revalidation re-checks (§9-arch) |
| Entitlement (incl. tier entry, occasion, campaign offers) | At grant | Reservation created with the entitlement; redemption consumes the reservation, never new budget |
| Display-only benefit | Never | No counter touch |
| Recurring entitlement | Once per customer-period | The lazy-materialisation unique key (§15-arch) doubles as the budget key |

**`budget_periods`** (PS-1B; `business_id`, `rule/component`, `period_start/end` **SGT**,
`committed_cents`, `cap_cents`) — **row-locked at commit time**. When one transaction must lock
several period rows (multi-component checkout), locks are acquired in a **deterministic global
order `(business_id, rule_id, period_start)`** so deadlock is impossible by construction (rev 4
S8-R). The counter is **the** authority; reservations are also individually recorded (rows
reconcile to the counter in every suite).

**Invariant (the promise-keeping guarantee):** *an issued promise keeps its reservation
permanently; budget exhaustion refuses only NEW grants/discounts* (outcome `budget_exhausted`,
owner-alerted). **A customer can never lose an issued benefit because someone else redeemed
first.**

**Dual-authority avoidance (rev 3 S5):** v50 campaigns keep their existing sum()-based cap
under **`legacy` execution authority**; when the campaign engine cuts over, its budget moves
onto `budget_periods` in the same migration — **at no point do two counters govern one
budget** (`retention_campaign_grants`/`retention_campaigns` live cap logic, `…v50`).

---

## 4. Nothing is an accounting liability until policy is selected ⚖️

**Explicit frozen rule:** measures 1–5 are **management estimates** — face value, variable-cost
estimates, risk-weighted exposure, realized variable cost, and expected future cost. **None of
them is an accounting liability.** Measure 6 (accounting estimate) is produced **only after an
accounting policy is explicitly selected and reviewed by a qualified accountant** ⚖️, and is
**always** rendered with the label *"requires accountant review"*.

- The platform **never** presents any number as an exact accounting liability before a reviewed
  policy exists (§10 measure 6; §7-arch decision 7).
- Policy selection, the classification map (deferred-revenue vs promotional, GST treatment,
  breakage recognition), and the ⚖️ SG-specific reviews live in the **accounting-classification
  worksheet** (`docs/design/ps0/ACCOUNTING_CLASSIFICATION_WORKSHEET.md`), the sibling PS-0
  deliverable. This document computes the inputs; the worksheet governs whether/how they become
  accounting figures.
- Consistent with the live product's existing revenue-recognition discipline: gift-card issue is
  **cash collected, not revenue** (v9, `…v9_giftcard_revenue.sql:8`); top-up will be
  `revenue=false` (§5-arch S1); membership/package revenue is policy-driven (`sale_policies`,
  `…v10:15`). Economics reporting must not silently reclassify any of these.

---

## 5. Decisions made during freeze (flag to orchestrator)

- **D1 — the cold-start observation threshold `N` is an assumption value, versioned, not a code
  constant.** §10 says "once ≥ N observations" without pinning N. I made it owner-visible +
  spine-versioned so the low→base confidence transition is auditable. Confirm a default (e.g.
  N=30 redemptions) belongs in the industry pack.
- **D2 — weighted cost-per-point weights are trailing redemption shares from
  `loyalty_redemptions.reward_id`.** §10 says "trailing redemption shares"; I pinned the source
  and the cold-start fallback (catalog-uniform, low confidence).
- **D3 — realized cost (measure 4) nets reversals via `reverses_fulfilment_id`**, consistent
  with the registry reversal contract (`BENEFIT_REGISTRY_CONTRACT.md §8`). A reversed benefit
  stops counting without deleting history.
- **D4 — breakage is keyed on `expiry_mode` per cohort**, with `none` → 0 breakage. §10 says
  "(1 − expiry breakage for the cohort's expiry mode)"; I grounded the mode to
  `loyalty_programs.expiry_mode` (`…v3:4`) / v23 points-expiry columns.
- **D5 — `economic_assumptions` and `budget_periods` are named as PS-4/PS-1B tables**; this
  freeze defines the columns they must carry (scenario, redemption_rate, source, n_observations,
  breakage_rate, cost inputs; period counters). Their DDL lands in those phases.
- **D6 — measure 6 requires a *selected policy*, not merely a worksheet.** I read §10 strictly:
  the worksheet enables the policy; only an explicitly selected + reviewed policy yields measure
  6. Absent that, measure 6 is blank/"requires accountant review", never a number.

## 6. Open questions

- **O1** — Default industry-pack redemption-rate priors (low/base/high) per vertical — deferred
  to the pack authoring (PS-5) and the accounting worksheet ⚖️.
- **O2** — Whether `free_item` retention grants should cost at **catalog price** or **catalog
  variable cost (COGS)** — affects measure 2 confidence; this contract uses `catalog_cost`
  (variable) with medium confidence. Needs owner/accountant ruling.
- **O3** — Breakage recognition timing (immediate vs at-expiry) is an accounting-policy
  question routed to the worksheet ⚖️, not decided here.

## 7. Schema evidence relied on
`points_batches` (`earned`, `remaining`, `earned_at`, `expires_at`) `…v3_engine.sql:9-20`;
`loyalty_programs` (`expiry_mode`, `expiry_days`) `…v3:4-6`, points-expiry cols `…v23:5`;
`loyalty_rewards` (`cost_points`, `credit_cents`) `…v23_loyalty_points_tiers.sql:14-15`;
`loyalty_redemptions` (`reward_id`, `credit_cents`) `…v23:33-40`; `reward_grants`
(`reward_type`, `reward_value`, `status`) `…v2_saas.sql:103-115`; `retention_campaign_grants`
(`offer_cost_cents`) `…v50_retention_measurement.sql:151-158`; `customer_birthday_entitlements`
(`benefit_snapshot`, `status`) `…c45:124-127`; `sale_policies` / v9 gift-card revenue rule
`…v10_sale_policy.sql:15` / `…v9_giftcard_revenue.sql:8`; `firm_config_versions` `…v26:13`.
