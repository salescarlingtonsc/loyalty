# V153 Merchant Insights rule definitions

Date: 2026-08-03

V153 adds deterministic merchant insights to the business Dashboard and
retention-preparation UX to Customers. It does not use AI, external language
models, or invented values.

## Data sources

- Dashboard current-period data:
  `public.get_dashboard_summary(p_business, p_from, p_to, p_branch)`.
- Dashboard comparison-period data:
  the same RPC with the previous equivalent date range and same branch scope.
- Inactive-customer counts:
  `public.staff_list_customers_v129`.
- Customer retention readiness:
  `public.staff_list_customers_v129` loaded through the existing bounded
  paginated customer-directory pattern.

No V153 database migration is required.

## Period comparison

The current period is the inclusive Singapore operational date range selected
on Dashboard.

The comparison period is the previous equivalent number of complete days:

- Current: 5 Jul 2026 to 3 Aug 2026, 30 days.
- Previous: 5 Jun 2026 to 4 Jul 2026, 30 days.

## Insight rules

### Revenue trend

- Source: `get_dashboard_summary.revenue_cents`.
- Scope: selected branch when `p_branch` is a branch UUID; all permitted
  branches when `p_branch` is null.
- Minimum data: previous period revenue must be greater than zero.
- Threshold: absolute percentage movement of at least 10%.
- Positive title: `Revenue is increasing`.
- Negative title: `Revenue is lower`.
- Zero-base behaviour: if the previous period is zero, no percentage change is
  shown. If current revenue is positive, Peekaa shows `Revenue has started`.
- CTA: `View sales report`; negative/retention-adjacent state also links to
  inactive customers.

### Inactive customers

- Source: `staff_list_customers_v129`.
- Dashboard insight threshold: at least one customer inactive for 60+ complete
  Singapore days.
- Dashboard scope: business-wide customer inactivity, because the current
  customer RPC has no branch parameter.
- Customer-page readiness groups are mutually exclusive:
  - 30-59 days: no valid visit for 30 to 59 days.
  - 60-89 days: no valid visit for 60 to 89 days.
  - 90+ / never visited: no valid visit for at least 90 days, or no valid visit
    on record.
- CTA: `View inactive customers`; `Prepare campaign`.

### Busiest day

- Source: `get_dashboard_summary.visits_by_weekday`.
- Minimum data: at least two valid visits in the selected period.
- Calculation: weekday with the highest valid-visit count.
- CTA: `View appointment report`.
- The rule does not claim a cause. It only states the observed busiest weekday.

### Business Health Summary

V153 does not create a numeric Business Health Score.

Reason: a defensible score would require product decisions about weights,
normalisation, missing-data handling, and branch scope across unrelated metrics.
Compressing revenue, visits, and retention into a single score would be
subjective at this release boundary.

Instead, V153 displays separate deterministic indicators:

- Revenue trend: improving, stable, needs attention, or not enough data.
- Visit activity: improving, stable, needs attention, or not enough data.
- Retention: stable or needs attention based on 60+ inactive count.

## Campaign preparation

V153 supports draft preparation only.

The preparation modal includes:

- Campaign name.
- Campaign type.
- Audience definition.
- Branch scope.
- Matching-customer count.
- Consent/eligibility warning when supported.
- Message preview.
- Save draft.
- Cancel.

It intentionally has no `Send` action. Push notifications are described as
available only for customers with an installed Peekaa app and enabled
notifications. No live notification delivery or WhatsApp sending is added.

## Branch-scope semantics used by V153

- Revenue, valid visits, busiest days and revenue-over-time follow the existing
  dashboard branch scope.
- New customer members, age groups, recorded gender, inactive customers, credit
  and retention readiness are business-wide where current data does not provide
  safe branch attribution.
- Selected multiple-branch scope is not exposed because current Dashboard,
  Reports and customer APIs accept one branch UUID or null, not a branch list.

## Safety confirmation

V153 changes presentation, deterministic rule selection, and documentation
only. It does not change financial, loyalty, ledger, reversal, credit, package,
expense, P&L, appointment, billing, authentication, tenant or permission
semantics.
