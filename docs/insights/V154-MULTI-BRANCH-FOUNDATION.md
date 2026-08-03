# V154 Safe Multi-Branch Foundation

## Result

V154 raises multi-branch readiness from **58 / 100** to **74 / 100** for the implemented foundation.

Post-V154 readiness score: 74 / 100.

Scoring method:

- 20 points: branch permission safety
- 15 points: reporting-scope contract
- 15 points: deduplicated customer and retention semantics
- 15 points: promotion branch targeting and redemption enforcement
- 10 points: campaign-preparation targeting
- 10 points: dashboard and merchant-insight scope support
- 15 points: enterprise completeness not yet implemented

The remaining 26 points are deferred because branch comparison UI, branch groups/regions, package portability decisions, and live push-campaign delivery require separate product and backend work.

## Operational branch

The operational branch is the single branch where staff are doing operational work: recording a sale, booking an appointment, managing waitlist entries, or redeeming an offer. Only one operational branch may be active at a time. Changing a reporting scope must not silently change the operational branch.

## Reporting scope

The reporting scope controls analytics and audience preparation. V154 supports:

- `current`: resolve to the current operational branch.
- `selected`: resolve to one or more explicitly selected authorised branches.
- `all`: resolve to all branches the authenticated membership may access.

Server-side branch permission enforcement is mandatory. Browser-provided branch IDs are not authority. Duplicate IDs are deduplicated, empty selected scopes are rejected, foreign-tenant branches are rejected, and unauthorised branches are rejected.

## Metric classes

Additive metrics:

- Revenue
- Valid visits
- Completed appointment counts where rows are branch-attributed
- Branch-attributed expenses
- Sale quantities
- Redemption counts

Deduplicated metrics:

- Unique customers
- Returning customers
- Inactive customers
- Customer demographics
- Campaign audience counts

Non-additive metrics:

- Percentages
- Rates
- Averages
- Average transaction amount
- Repeat-customer percentage
- Appointment utilisation
- Revenue concentration
- Business Health Summary indicators

Do not sum percentages. Do not average branch percentages. Percentages, rates, and averages must be recalculated from the combined authorised underlying rows.

Business-wide-only metrics:

- New customer members, unless an auditable acquisition branch exists.
- Loyalty and credit balances.
- Never-visited customers, unless an acquisition branch exists.

## Cross-branch customer identity

One customer is a business-level customer. The same canonical customer visiting multiple branches remains one customer. V154 deduplicates by canonical customer ID, not phone text in frontend code. V154 does not merge duplicate historical customer records.

## Retention semantics

All branches:

- Inactivity uses the customer's most recent valid visit across all included authorised branches.
- A customer is counted once.

Current or selected branches:

- The audience includes customers with at least one historical valid visit in the selected branch scope.
- Inactivity is measured from the most recent valid visit within that selected scope.
- The UI labels this as **Inactive in this branch scope**.

Never visited:

- Remains business-wide unless a canonical customer acquisition branch exists.

Required scenario:

- Customer visited Branch A 100 days ago and Branch B yesterday.
- All branches: active.
- Branch A scope: inactive 90+.
- Branch B scope: active.
- Selected A+B: active.
- Customer is counted once in each applicable scope.

Repeat-customer calculation:

- Unique repeat customers in scope divided by unique customers with at least one valid visit in scope.
- A repeat customer has at least two qualifying valid visits in scope.
- Zero denominator returns 0 and does not fabricate a percentage.

## Promotion scope

V154 supports:

- `all_branches`: available dynamically at all current and future eligible branches in the business.
- `selected_branches`: available only at explicitly mapped branches.

Existing promotions retain historical company-wide behaviour by default because no mapping means all branches.

Promotion creation and editing expose:

- All branches
- Current branch
- Selected branches

Current branch is stored as selected branches with one branch ID.

## Promotion redemption enforcement

Server-side promotion redemption enforcement verifies:

- Authenticated business membership
- Business ID
- Operational branch ID
- Promotion business ownership
- Promotion active status and dates
- Promotion branch availability
- Existing customer eligibility
- Existing staff permission
- Existing duplicate/limit rules

Rejected branch mismatch message:

`This promotion is not available at the selected branch.`

Historical redemptions keep their recorded branch and are not rewritten when promotion scope changes later.

## Campaign branch targeting

Campaign delivery remains disabled. V154 campaign preparation supports audience counts for:

- All branches
- Current branch
- Selected branches

Audience counts are server-derived and deduplicated by canonical customer ID. No live Send action is exposed.

## Expense and P&L treatment

Branch expenses are included when branch-attributed rows are in the selected reporting scope. Business-wide overhead is not silently allocated across selected branches. V154 does not change cash-basis, accrual, expense, or P&L formulas.

## Loyalty, credit, and package scope

Loyalty points and credits remain business/customer scoped. V154 does not make points or credit branch-specific.

Package portability remains ambiguous. V154 does not change package purchase, redemption, or session-portability semantics and does not claim packages work across all branches unless existing enforcement proves that case.

Packages remain ambiguous until a separate product decision defines purchase branch, redemption branch, service/resource compatibility, and server-side enforcement.

No financial, loyalty, credit, ledger, reversal, expense, P&L, appointment, billing, authentication, tenant, or role-authority semantics were changed.

## Remaining enterprise gaps

- Branch comparison dashboard: separate implementation required.
- Selected branch groups or regions: separate product model required.
- Package portability: product decision and enforcement required.
- Live push-campaign delivery: delivery infrastructure and consent/device enforcement required.
- New-customer acquisition branch: requires canonical acquisition field before branch-scoped new-member reporting.
