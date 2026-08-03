# V153 Multi-Branch Capability Readiness

Date: 2026-08-03

## Overall readiness score

**58 / 100**

Scoring method:

- 20 points: permission and tenant-safety enforcement.
- 20 points: correct single-branch reporting.
- 20 points: correct all-branches consolidated reporting.
- 15 points: selected multiple-branch reporting.
- 10 points: cross-branch customer, loyalty, credit and package clarity.
- 10 points: promotion/campaign branch targeting and redemption enforcement.
- 5 points: owner-facing scope clarity.

Current score rationale:

- Tenant isolation and one-branch access checks are strong.
- Owner/manager all-branches consolidated Dashboard and Reports are partly
  supported through `p_branch = null`.
- Selected multiple-branch dashboards are not supported.
- Promotion branch targeting is intentionally not supported.
- Push-campaign branch targeting is not ready.
- Some customer, loyalty, package and liability metrics are business-wide and
  must remain clearly labelled.

## Current architecture summary

- Dashboard RPC: `get_dashboard_summary(p_business, p_from, p_to, p_branch)`.
  It accepts one branch UUID or null for consolidated scope.
- Reports RPC: `get_reports_summary(p_business, p_from, p_to, p_branch)`.
  It accepts one branch UUID or null and denies whole-business scope to
  branch-limited users when reports are incomplete.
- Customer directory RPC: `staff_list_customers_v129(...)` has no branch
  parameter. Customer inactivity is currently business-wide.
- Branch permission authority: `app.can_see_branch(...)`.
  Owner/manager can read branch or whole-business scope; branch-limited staff
  require an assigned branch and cannot request null all-business scope.
- Promotion architecture is company-wide. V104 promotion tests and product
  evidence reject non-null branch input.

## Capability classification

| Capability | Readiness | Notes |
| --- | --- | --- |
| One selected branch Dashboard | Supported and production-ready | Revenue, valid visits and revenue/weekday charts are branch-filtered. |
| All Branches Dashboard | Supported with scope caveats | Owner/manager only. Some cards are business-wide by nature and must stay labelled. |
| Selected multiple-branch Dashboard | Not supported | APIs accept one branch UUID or null, not a list. |
| Reports by one branch | Supported and production-ready | Existing RPC enforces branch scope. |
| Consolidated Reports | Supported with scope caveats | Requires complete module authority and whole-business permission. |
| Branch comparison | Partially supported | Can be queried one branch at a time, but there is no safe comparison UI/API contract. |
| Customer inactivity | Supported business-wide | Current RPC has no branch parameter. |
| Branch-level inactivity | Unsafe or ambiguous | Product semantics are not defined for a customer active in Branch B but inactive in Branch A. |
| Loyalty points | Partially supported | Points attach to business/customer with sale linkage; UI must not overclaim branch-specific portability rules. |
| Customer credit | Supported business-wide | Current balance is business/customer scoped and must not be labelled branch-specific. |
| Packages and sessions | Partially supported | Purchase/use are sale/service/branch-adjacent, but enterprise cross-branch portability requires a dedicated acceptance pass. |
| Promotions all branches | Supported and production-ready | Current promotions are company-wide. |
| Promotions one branch | Not supported | Non-null branch input is rejected. |
| Promotions multiple branches | Not supported | No many-to-many promotion-branch scope. |
| Promotion redemption branch enforcement | Not supported for branch-specific offers | Branch-specific offers are not modelled; visual-only targeting would be unsafe. |
| Push-campaign branch targeting | Not supported | Delivery is not live; audience branch association semantics are undecided. |
| Merchant insights | Supported with scope caveats | V153 uses existing Dashboard and customer queries and labels scope. |

## Explicit answers

1. **Can Peekaa currently show a correct consolidated All Branches dashboard?**

   Yes, for owner/manager users and supported metrics, with scope caveats.
   Revenue, valid visits, busiest days and revenue-over-time are aggregation-safe
   through the existing Dashboard RPC. New customer members, age, recorded
   gender, credit and inactive customers are business-wide and must remain
   labelled as such.

2. **Can Peekaa currently show a selected multiple-branch dashboard?**

   No. Current Dashboard and Reports APIs accept one branch UUID or null. They
   do not accept a branch ID list or branch-group identifier.

3. **Can Peekaa correctly compare one branch against another?**

   Partially. Equivalent single-branch data can be queried separately, but a
   production branch-comparison screen would need explicit contracts for rates,
   deduplicated customer counts, permissions and incomplete scopes.

4. **Are customers deduplicated correctly across branches?**

   Customer identity is business-level in the current customer directory and
   sale/client model. Retention groups count customer records once business-wide.
   A future enterprise branch report still needs a dedicated duplicate-phone and
   cross-branch-activity acceptance pass before exposing branch-level retention.

5. **Do loyalty points follow customers across branches?**

   Points are business/customer scoped with sale-linked earning and redemption
   evidence. They can be shown business-wide, but branch-specific loyalty
   portability must not be claimed without a dedicated branch-programme policy.

6. **Do credits follow customers across branches?**

   Current customer credit balance is business/customer scoped and therefore
   business-wide. Branch-specific credit should remain hidden until a separate
   scope model exists.

7. **Do packages or package sessions work across branches?**

   Partially/ambiguous. Package purchase and redemption behaviour exists, but
   cross-branch portability depends on service/package/branch policy and needs a
   dedicated release before being advertised as enterprise-grade.

8. **Can promotions currently target one branch, multiple selected branches,
   and all branches?**

   All branches: yes, company-wide promotions are supported.
   One branch: no.
   Multiple selected branches: no.

9. **Can promotion redemption be enforced by branch server-side?**

   Not for branch-specific promotions because branch-specific promotions are not
   currently modelled. Server-side branch enforcement is a release blocker before
   branch-targeted promotions can be exposed.

10. **Can future push campaigns target one branch, multiple selected branches,
   and all branches?**

   All-business campaign preparation can be represented. Live push delivery and
   branch targeting are not production-ready. One-branch and multi-branch push
   targeting need customer-branch association semantics, server-side audience
   counts, consent/device eligibility and delivery receipts.

11. **Minimum work for safe enterprise-grade multi-branch support**

   - Define product semantics for operational branch vs reporting scope.
   - Add API contracts that accept authorized branch arrays.
   - Add or expose many-to-many branch scope where needed.
   - Add server-side promotion redemption checks by branch.
   - Define customer association rules: membership branch, last-visited branch,
     most-visited branch, any-visited branch or preferred branch.
   - Add deduplicated customer aggregation and branch-comparison contracts.
   - Add RLS/permission tests for owner, manager, branch manager, front desk and
     restricted staff.

12. **Capabilities safe to expose immediately**

   - One selected branch reporting for currently supported metrics.
   - Owner/manager all-branches consolidated Dashboard/Reports with labels.
   - Business-wide retention readiness.
   - Company-wide promotions.
   - V153 deterministic merchant insights with branch-scope labels.

13. **Capabilities that must remain hidden**

   - Selected multiple-branch dashboards.
   - Branch-targeted promotions.
   - Branch-targeted campaign sending.
   - Branch comparison dashboard.
   - Branch-level customer inactivity claims.
   - Branch-specific loyalty/credit/package portability claims.

## Gap effort

| Gap | Effort | Assumption |
| --- | --- | --- |
| Clarify labels for already-supported all-branch metrics | Small | No schema change; UI copy only. |
| Add branch-array reporting APIs and tests | Medium | Existing branch permission helper can be reused. |
| Selected multiple-branch frontend controls | Medium | Depends on branch-array APIs and URL state. |
| Branch comparison dashboard | Medium | Depends on stable comparison API contracts. |
| Branch-level retention semantics | Medium | Requires product decision plus server query changes. |
| Branch-targeted promotions | Large | Requires scope model, redemption enforcement, customer visibility and tests. |
| Branch-targeted push campaigns | Large | Requires canonical delivery system, consent/device eligibility and branch association semantics. |
| Package portability policy | Medium | Requires product decision and package/session acceptance tests. |

## Recommended release sequence

1. V153: deterministic insights and readiness documentation.
2. Future branch-scope foundations: branch-array API contracts, scope labels and
   permission tests.
3. Future retention release: product decision for branch-level inactivity and
   customer-branch association.
4. Future promotion release: branch-scope data model plus server redemption
   enforcement.
5. Future campaign release: delivery receipts, device eligibility and
   branch-aware audience counts.

## Safety confirmation

This review changes no production data and does not alter any financial,
loyalty, ledger, reversal, expense, P&L, appointment, billing, authentication,
tenant or permission semantics.
