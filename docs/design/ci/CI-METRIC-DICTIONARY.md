# CI metric dictionary — frozen contract (v684)

**This document is a rendering, not the source of truth.** The canonical definitions live in
SQL: `app.ci_metric_dictionary_v1()` (wrapped for callers as `public.get_ci_dictionary_v1()`,
gated only on `auth.uid()` not null — no business or branch scope, since nothing here is
tenant data). Implementation: `db/migrations/20260920_nestly_v684_metric_dictionary.sql`.
Current version string: **`ci_dictionary_v684_1`**.

Every entry below is a direct transcription of one `metrics.<key>` object the function returns
— same `definition` / `unit` / `numerator` / `denominator` / `source_function` /
`since_version` / `notes` fields, same wording. If this file and the SQL function ever
disagree, the SQL function wins; re-generate this file from it rather than editing either in
isolation. `db/tests/executed/v684_corpus_dictionary.sql` asserts the SQL function's key set
matches the fifteen headings below exactly (T2), so a key cannot drift out of sync silently.

This closes acceptance checks 11 and 29
(`docs/qa/CI-ACCEPTANCE-VERDICT-2026-09-02.md`): one versioned metric dictionary, and the five
contradictory concepts — loyal, frequent, retained, high-LTV, at-risk — defined disjointly and
testably. The classifier that computes those five concepts from this dictionary's own
definitions is `app.ci_customer_classes_v1(p_business, p_client, p_as_of)`, covered in its own
section below.

## revenue

Recorded revenue: the net minor-currency amount of original sales with `counts_as_revenue=true`,
after native full-sale reversals and reconciled external refund allocations, bucketed to a
period by the sale's effective outlet timezone.

- **Unit:** currency minor units (cents), business currency
- **Numerator:** `sum(v106 net_minor)` over eligible original sales in the period
- **Denominator:** — (an absolute total, not a rate)
- **Source function:** `public.get_revenue_truth_v106`
- **Since:** v106
- **Notes:** `formula_metadata.version=revenue_truth_v106_1`. Invariant:
  `known_revenue = identified_revenue + anonymous_revenue`. `counts_as_revenue` is a
  per-business, per-sale-kind **policy** (`app.sale_policy_set`, v10), not a fixed list of sale
  kinds.

## visit

A qualifying visit: an original sale with `counts_as_visit=true`, not itself a reversal
(`reversal_of is null`) and not itself later reversed. v673's funnel/retention readers
additionally bucket the visit to one Singapore-time calendar date (`visit_date`), so more than
one qualifying sale on the same SGT day is a single visit for sequencing purposes.

- **Unit:** count (sale-level unless noted as day-deduped)
- **Source function:** `app.customer_cadence_batch_v1`, `public.get_ci_funnel_conversion_v1`,
  `public.get_ci_retention_windows_v1`
- **Since:** v107 (sale-level count); v673 (day-deduped `visit_date`)
- **Notes:** **DISCLOSED DIVERGENCE, not reconciled here.** v107/v651 (`paid_visits`) and v179
  (`lifetime_visits`) count one visit per qualifying SALE row; v673 dedupes same-SGT-day sales
  into a single `visit_date` for first/second/third-visit sequencing. Both are "as implemented"
  in live production readers.

## transaction

A completed transaction: an original sale (`reversal_of is null`) whose v106 residual (net)
amount, after native reversals and reconciled external refund allocations, is greater than zero
as of the report's `as_of` instant.

- **Unit:** count
- **Numerator:** `count(*) filter (where net_minor > 0)`
- **Source function:** `public.get_revenue_truth_v106`
- **Since:** v106
- **Notes:** A sale can be revenue-qualifying (`counts_as_revenue`) without being
  visit-qualifying (`counts_as_visit`), or the reverse; "transaction" here is specifically the
  revenue reader's `completed_transactions` figure.

## new

`new_customer`: the client's first-ever eligible purchase (`counts_as_visit=true`, v106
residual > 0) has a local business date in `[p_from, p_to)`.

- **Unit:** count of transacting identified customers
- **Numerator:** `count(*) filter (where first_ever_business_date in [p_from,p_to))`
- **Denominator:** `transacting_identified_customers` (for a rate; the raw count is not itself
  a rate)
- **Source function:** `public.get_customer_lifecycle_v107`
- **Since:** v107
- **Notes:** Business-wide identity for the "first-ever" test; period activity is scoped to the
  selected branch when `p_branch` is given (v107 header).

## existing_returning

`existing_returning_customer`: at least one eligible purchase strictly before `p_from` AND at
least one eligible purchase in `[p_from,p_to)`.

- **Unit:** count of transacting identified customers
- **Numerator:** `count(*) filter (where purchased_before_period)`
- **Denominator:** `transacting_identified_customers`
- **Source function:** `public.get_customer_lifecycle_v107`
- **Since:** v107
- **Notes:** Not the same population as `repeat` — a customer can be `existing_returning` with
  exactly one purchase in the current period.

## repeat

`repeat_purchaser_in_period`: at least two eligible purchases in `[p_from,p_to)`, regardless of
the customer's age — deliberately **not** a synonym for `existing_returning`.

- **Unit:** count of transacting identified customers
- **Numerator:** `count(*) filter (where period_purchases >= 2)`
- **Denominator:** `transacting_identified_customers`
- **Source function:** `public.get_customer_lifecycle_v107`
- **Since:** v107
- **Notes:** A brand-new customer who buys twice in their very first period is `repeat=true` and
  `new=true` simultaneously; the two are independent flags on the same reader.

## reactivated

`reactivated_customer`: an `existing_returning` customer whose first in-period purchase follows
a lapse (`gap_days`) strictly greater than the effective threshold — the customer's own median
interval multiplied by the business's `reactivation_multiplier` when
`interval_observations` clears `customer_interval_min_observations`, else the business
`fallback_lapse_days`.

- **Unit:** count of transacting identified customers
- **Numerator:** `count(*) filter (where purchased_before_period and gap_days > effective_lapse_days)`
- **Denominator:** `transacting_identified_customers`
- **Source function:** `public.get_customer_lifecycle_v107`, `app.customer_cadence_batch_v1`
- **Since:** v107 (definition); v651 (canonical median/threshold computation, re-pointing v107
  at it byte-identically)
- **Notes:** Migration-default policy: `fallback_lapse_days=90`,
  `customer_interval_min_observations=3`, `reactivation_multiplier=2.0`, effective from
  `-infinity` until an owner or super-admin publishes a business-specific one.

## retained

Fixed-window retention: within a cohort of clients whose first visit falls in a period, the
share with **any** qualifying visit strictly after their own first visit and within a fixed
horizon of it. `public.get_ci_retention_windows_v1` reports horizons {30, 60, 90, 180, 365}
days at cohort level; `app.ci_customer_classes_v1` (below) is a single-customer instance fixed
at the 90-day horizon.

- **Unit:** rate (customers returned / cohort size)
- **Numerator:** customers with a qualifying visit in `(first_visit_date, first_visit_date + horizon]`
- **Denominator:** `cohort_n` (the cohort's full size, mature cells only)
- **Source function:** `public.get_ci_retention_windows_v1`, `app.ci_customer_classes_v1`
- **Since:** v673
- **Notes:** A (cohort, horizon) **cell** — not any one customer's own date — is reported only
  once fully matured (`cohort_month_last_day + horizon <= today`, SGT); an immature cell is
  named in `immature_cells`, never silently omitted. `retained` is a **one-time historical
  fact** about a customer's first visit, unlike `lapsed`/`at_risk`, which describe current
  standing — a customer can be `retained=true` and `at_risk=true` simultaneously.

## lapsed

`deviation_state='overdue'`: as of `p_as_of`, the days since a client's last qualifying visit
exceed the effective lapse threshold (customer median interval x `reactivation_multiplier`
when `interval_observations` clears `customer_interval_min_observations`, else
`fallback_lapse_days`) — the identical threshold construction v107 uses for `reactivated`, now
named once.

- **Unit:** boolean, per customer
- **Source function:** `app.customer_cadence_v1`
- **Since:** v651
- **Notes:** Other `deviation_state` values from the same function: `due`, `late`,
  `within_cycle`. `lapsed` here means specifically `overdue` — see `at_risk` for why this is
  one of **two** live at-risk policies, not the only one.

## at_risk

**TWO LIVE POLICIES answer "is this customer at risk", and they deliberately disagree** —
disclosed here, not reconciled:

1. **AI-report policy** (`public.get_report_insight_evidence_v179`): a "regular" (2+ lifetime
   `counts_as_visit` visits) whose last visit is a FIXED 45–180 days before the report's
   `p_to`; a single-visit customer is never at risk under this policy no matter how old that
   visit is.
2. **CI policy** (`app.customer_cadence_v1` / `app.ci_customer_classes_v1`):
   `deviation_state='overdue'` — an OWN-RHYTHM comparison against the customer's median
   interval, or the business `fallback_lapse_days` (90 by default) when there is not enough
   interval evidence. There is no fixed day window and no minimum-visit-count gate under this
   policy.

- **Unit:** boolean or count, per policy
- **Source function:** `public.get_report_insight_evidence_v179`, `app.customer_cadence_v1`
- **Since:** v179 (AI-report policy); v651 (CI policy)
- **Notes:** **TENSION DISCLOSED**: a customer with one huge purchase long ago clears the v179
  "2+ lifetime visits" gate as false (v179 never flags them) while the CI policy's 90-day
  fallback can independently call the same customer overdue.
  `app.ci_customer_classes_v1.at_risk` implements the **CI policy only**; it is not a merge of
  the two.

## ltv

**Realised** lifetime value, **not projected**: the sum of `amount_cents` across every sale of
every kind for the client, business-wide, with no branch scope and no date window, and with
reversals excluded on **both** sides (a reversal row and the original sale it reverses both
drop out).

- **Unit:** currency minor units (cents)
- **Numerator:** `sum(sales.amount_cents)` where `reversal_of is null` and not later reversed
- **Source function:** `public.staff_list_customers_v155` (`lifetime_spend_cents`)
- **Since:** v629
- **Notes:** Deliberately counts package/membership/gift-card sale kinds too — owner ruling:
  "everything the customer paid" — unlike v106's `counts_as_revenue`-gated revenue figure. A
  package **session** is a $0 sale and adds nothing; the package was already counted at its
  full price when it was sold.

## atv

Average transaction value: `revenue_cents` divided by the count of **revenue-qualifying** sales
(`counts_as_revenue`) in the cell — not `counts_as_visit`. A $0 or non-revenue visit moves
footfall (the `visits` figure) but has no "transaction value" and is excluded from the ATV
denominator.

- **Unit:** currency minor units (cents) per revenue-qualifying transaction
- **Numerator:** `revenue_cents` (cell)
- **Denominator:** count of `counts_as_revenue` sales in the cell
- **Source function:** `public.get_ci_demographics_v1`
- **Since:** v674
- **Notes:** Below the k=5 evidence floor (`app.subgroup_evidence_v1`) the cell keeps its real
  customers/revenue_cents/visits and `atv_cents` is nulled — never dropped, never a fabricated
  average from a handful of people.

## identified_coverage

The share of a population (sales, transactions, or customers) carrying a linked, non-null
`client_id`, always reported beside the eligible total via `app.rate_block_v1` rather than as a
bare percentage.

- **Unit:** rate
- **Numerator:** `identified_revenue_minor` / `identified_transactions` /
  `identified_transaction_pct` — per reader
- **Denominator:** `known_revenue_minor` / `eligible_transactions` /
  `transacting_identified_customers` — per reader
- **Source function:** `public.get_revenue_truth_v106`, `public.get_customer_lifecycle_v107`,
  `public.get_ci_demographics_v1`
- **Since:** v106
- **Notes:** One concept, several call sites; each reader states its own numerator/denominator
  pair rather than this dictionary inventing a single formula that would not match any one of
  them exactly.

## cadence_median

`median_interval_days`: the median (`percentile_cont 0.5`) of a client's paid-visit-to-paid-visit
gaps in days, computed only over qualifying visits (`counts_as_visit`, not reversed) before the
computation's cutoff date, via the canonical `app.customer_cadence_batch_v1`. Null when the
client has fewer than 2 such visits (zero measured intervals).

- **Unit:** days (median)
- **Source function:** `app.customer_cadence_batch_v1`
- **Since:** v651 (extracted verbatim from v107's original `interval_evidence` CTE; no
  behaviour change)
- **Notes:** Whether the median is **trusted** for a policy decision (vs falling back to
  `fallback_lapse_days`) depends on `interval_observations >=
  customer_lifecycle_policies_v107.customer_interval_min_observations` (default 3) — the
  median can be non-null and still be policy-ignored below that floor.

## return_probability

A memoryless-exponential hazard on the customer's own rhythm:
`P(return within H days of p_as_of) = 1 - exp(-H / m)`, where `m` is the median inter-visit
interval from the v651 canonical cadence authority (`app.customer_cadence_batch_v1`) and `H`
defaults to 30 days. Distinct from `retained` (a one-time historical fact) and
`lapsed`/`at_risk` (a current rhythm-deviation fact): this is a **forward-looking probability**,
not a backward-looking classification.

- **Unit:** probability in [0,1], null when abstaining
- **Source function:** `app.return_probability_v681`, `public.evaluate_return_probability_v681`
- **Since:** v681
- **Notes:** **Abstains** (`status='insufficient'`, `probability=null`) when measured intervals
  k < 3 — a fixed floor independent of any business's own cadence policy, stricter than
  `app.customer_cadence_v1`'s policy-configurable gate, because a probability claim is a
  stronger statement than a lapse classification. Deliberately does **not** use
  days-already-elapsed-since-last-visit as a covariate: the exponential is memoryless by
  construction, so folding that in would not change the number.
  `public.evaluate_return_probability_v681` measures calibration/discrimination against a
  temporally-held-out real outcome rather than asserting the model works.

---

## The five contradictory concepts, defined disjointly

`app.ci_customer_classes_v1(p_business uuid, p_client uuid, p_as_of timestamptz)` computes all
five as one payload, each derived from the dictionary entries above rather than reimplemented:

| Class | Rule | Derived from |
|---|---|---|
| `frequent` | median inter-visit interval <= 14 days AND >= 3 measured observations | `cadence_median` |
| `loyal` | >= 6 qualifying visits in the last 180 days AND **NOT** `at_risk` | `visit`, `at_risk` |
| `retained` | any qualifying visit within 90 days of the client's first-ever visit | `retained` (single-customer, 90d horizon) |
| `high_ltv` | lifetime spend >= the business's own 80th percentile of identified-customer lifetime spend | `ltv` |
| `at_risk` | `deviation_state='overdue'` (CI policy only — see `at_risk` above) | `lapsed` |

**Why `at_risk` and `loyal` are mutually exclusive by construction, not by coincidence:**
`loyal` is computed as `(visits_180d >= 6) AND NOT at_risk`, reusing the SAME `at_risk` boolean
the function returns — not a second, independently-derived "not overdue" check that could drift
out of sync. Algebraically, `at_risk = true` implies `NOT at_risk = false` implies
`loyal = false`, for every input, before any fixture data is ever seeded.

**Why `frequent` does not imply `loyal`:** frequency describes a customer's past rhythm; loyalty
additionally requires that rhythm still be current. A frequent customer who has since gone
overdue is `frequent=true, loyal=false` (see fixture customer G below).

**Why `retained` is not folded into the other four:** it answers a different question in
*time* — a one-time historical fact about a customer's very first visit — while `lapsed`,
`at_risk`, `frequent` and `loyal` all describe **current** standing as of `p_as_of`. A customer
can be `retained=true` and `at_risk=true` simultaneously (they came back once, long ago, and
have since gone quiet again).

### Fixture truth table (`db/tests/executed/v684_corpus_dictionary.sql`)

| Customer | Scenario | frequent | loyal | retained | high_ltv | at_risk |
|---|---|---|---|---|---|---|
| F | 8 visits every 10d, last 5d ago | true | true | true | false | false |
| G | 6 visits every 7d, last 40d ago | true | **false** | true | false | **true** |
| H | one $50,000 purchase, 300d ago | false | false | false | true | true |
| I | 2 visits, 100 days apart | false | false | **false** | false | true |

Customer H is the honest, non-assumed case this dictionary calls out explicitly: a single
purchase gives `interval_observations=0`, which is still `< customer_interval_min_observations`
(3), so `app.customer_cadence_v1` falls back to the business's 90-day `fallback_lapse_days`
exactly as it would for any under-evidenced customer — this is v651's own documented behaviour,
not a special "cannot assess" path (that path is reserved for a customer with **zero** paid
visits at all, `status != 'ready'`). At 300 days since that one visit, H is `overdue` under the
CI policy and therefore `at_risk=true`, even though the v179 AI-report policy would never flag
H at all (it never clears the "2+ lifetime visits" gate). Both are correct under their own
policy; this is the same tension the `at_risk` entry above discloses.

Every seeded customer satisfies `NOT (at_risk AND loyal)`. Customer G is additionally
mutation-checked: adding one more real visit 3 days before `p_as_of` (append-only `sales`
forbids editing the existing row) leaves the median interval unchanged (7 days) but flips
`deviation_state` off `overdue`, and the classifier's `at_risk`/`loyal` outputs flip with it —
proof that the disjointness holds because of live computation, not a hardcoded pair.
