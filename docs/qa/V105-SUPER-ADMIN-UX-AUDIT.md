# V105 super-admin task-efficiency and information-architecture audit

Status: local candidate verified by automation and deterministic browser
acceptance. Production remains unchanged. This evidence does not authorize a
commit, migration, production-data change, merge, push, or deployment.

Date: 29 July 2026
Candidate: `codex/v104-marketing-offers` working tree
Roles: super admin, admin, sales staff, denied/non-platform account
Viewports: 1440×1100 and 390×844

## Outcome

The blank `/admin` page and the most costly administration UX problems are
addressed in the local candidate. They remain pending independent reviewer
acceptance and an authenticated production smoke:

- the route paints a loading state immediately and awaits the platform
  renderer, so asynchronous boot failures reach a visible recovery boundary;
- the localized customer-UI facade no longer violates frozen-object Proxy
  invariants;
- the default destination is **Today**, not a module roster;
- the navigation now exposes five primary jobs—Today, Firms, Reports, Finance,
  System health—with low-frequency Platform controls separated;
- applications, onboarding exceptions, overdue billing, payable commissions,
  and reconciliation incidents appear in one urgency-ordered work queue, each
  with reason, status, age, SLA, owner, and one primary action;
- onboarding attention exhausts the server-authoritative v88 cursor pages;
  every cap-only Today reader exposes complete, partial, or unavailable
  coverage, so a capped or failed source can never produce a false exact count
  or **You are caught up** claim;
- sector defaults have one home, firm/branch exceptions have one Firm 360
  manager, Reports owns report generation, Finance owns payment resolution,
  and System health owns technical reconciliation;
- normal forms use names, SGD, and percentages instead of raw IDs, cents, and
  basis points;
- large directories render a bounded first page and require an explicit
  **Load 50 more** action;
- filters and open-record state are encoded in the URL for refresh/back
  recovery;
- the Firm 360 module manager uses six plain-language groups, one selector per
  capability, one reset action, and one save action.

Production `nestly.asia/admin` still serves the earlier console asset and can
remain blank until this candidate is independently accepted and released.

## Root cause of the blank page

Two defects combined:

1. The localization wrapper proxied a frozen `customer-ui.js` helper and
   returned wrapped functions for non-configurable properties. This violates
   JavaScript Proxy invariants and throws before the console can paint.
2. The application route returned the asynchronous platform render without
   awaiting it. A rejected render promise therefore bypassed the existing
   route-level recovery UI.

The candidate uses a configurable facade that calls the original helper with
its original receiver, paints an explicit loading state, normalizes direct and
nested platform paths, and uses `return await` so missing modules and rejected
renders produce a visible retry state.

## Efficiency verdict

Before this change, the console felt like an implementation dashboard: nine
equal-weight modules, duplicated reporting and module controls, long pages,
technical units, and no single answer to “what should I do now?” A fast
operator had to remember where each backend concept lived.

The candidate feels materially faster:

- **Daily work:** open Today and follow the next action.
- **A firm:** search once, open the firm name, then manage its branches,
  customers, subscription, and module exceptions in one context.
- **A report:** keep the selected firm/branch/date scope and continue to
  Reports.
- **A payment problem:** resolve in Finance; inspect provider/reconciliation
  detail only in System health.
- **A template:** use Platform controls; exceptions remain in Firm 360.

It is now task-first enough for an acceptance candidate. It is not declared
production-ready because authenticated production smoke and reviewer approval
are still release-gated.

## Button decisions

### Removed or demoted

- Duplicate **Open** beside a clickable firm name.
- Duplicate report builder inside Firms.
- Per-module **Edit** buttons in the effective-module table.
- Duplicate desktop **Workspace** action when the persistent rail already
  provides **Back to workspace**.
- Specialist Firm 360 actions from the primary toolbar; they now live under
  **More actions**.
- Full CRM board and 250-record prospect read from the initial Today view.
- Configuration coverage and read-only roster cards from Today.
- Billing reconciliation history from Finance.

### Retained

- One primary action in every Today row.
- **Apply scope**, **Clear**, and **Continue in Reports** because they change,
  reset, or hand off an explicit scope.
- One **Manage firm modules** action plus one **Manage branch** action per
  branch.
- **Reset all to sector defaults** and **Save module access** in the bulk
  manager.
- Language choice, Sign out, contact actions, and permission-appropriate deep
  links.

## Exact acceptance evidence

| Requirement | Acceptance criterion | Evidence | Result |
| --- | --- | --- | --- |
| `ADMINBOOT-001` | Direct/nested `/admin` never leaves an unexplained blank page. | `v105-admin-boot-resilience.test.mjs`; loading, missing-module and async-rejection harnesses. | Verified locally |
| `ADMINIA-001 / ADM-01` | Today contains all required exception domains with one next action and decision context. | Realistic spa/application/billing/commission/reconciliation fixture; `v105-admin-task-closure.test.mjs`; desktop/mobile images. | Verified locally/browser harness |
| `ADM-02` | Sales defaults to scoped Today and sees only Today, Firms/Onboarding, Reports. | Role-normalization and navigation tests; visual role sweep. | Verified locally/browser harness |
| `ADM-03` | Scoped role Firm 360 is server-authoritative and forged URLs do not fall into enterprise readers. | Assigned-report RPC assertions and denial-state tests. | Verified locally |
| `ADM-04` | One canonical report builder; Firms hands off scope. | URL round-trip test and absence of inline report implementation. | Verified locally |
| `ADM-05` | Sector defaults and firm/branch exceptions have one canonical home. | Source-boundary tests; Firm 360 visual module-manager evidence. | Verified locally/browser harness |
| `ADM-06` | Finance resolves billing; System health owns reconciliation history. | Route/source ownership regression. | Verified locally |
| `ADM-07` | Frequent actions remain visible; specialist actions use one disclosure. | Firm 360 action inventory regression. | Verified locally |
| `ADM-08` | Forms use human units and names. | Exact SGD/cents and percent/basis-point conversion tests; UI label regressions. | Verified locally |
| `ADM-09` | First paint does not exhaust every firm/prospect page. | RPC argument assertions for 50-row pages and explicit load-more wiring. | Verified locally |
| `ADM-10` | Firm and onboarding scope survives refresh/back. | Hash round-trip and renderer state tests; onboarding reload browser harness. | Verified locally/browser harness |
| `ADM-11` | Mobile has no horizontal overflow and interactive controls are at least 44px. | Deterministic production-component fixture at 390×844. | Verified browser harness |
| `ADM-12` | Denied accounts receive a meaningful nonblank state without a dead retry action. | `role=denied` fixture and screenshot: Back + Sign out, zero retry buttons. | Verified browser harness |
| `ADM-13` | A temporary access-check failure must not be presented as revoked access. | Forced `platform_list_my_access_v89` failure: one retry, Back, and explicit “access has not been removed” copy. | Verified browser harness |
| `ADM-14` | Today never hides work behind a first-page cap while implying complete coverage. | `v105-today-coverage.test.mjs`: attention row 251 is fetched through the v88 cursor; firms/billing/commissions/applications/automation expose partial coverage at their exact caps; unavailable RPC coverage replaces caught-up copy; the task UI remains limited to 12 rows. | Verified locally |
| `ADM-15` | Delegated Admin and Sales Today must not derive queues or exact KPIs from only the first 50 assigned firms. | `v105-today-coverage.test.mjs`: both delegated roles exhaust the snapshot-frozen v105 keyset cursor and surface an actionable blocked firm at row 51; a forced one-page guard reports partial coverage, renders derived KPIs as lower bounds, and suppresses “You are caught up”. | Verified locally |

## Browser metrics

The acceptance fixture imports the real `customer-ui.js`,
`platform-console.js`, inline application CSS, and `platform-console.css`.
It does not duplicate production component HTML. Its generated stylesheet
hash is recorded in the fixture.

| Scenario | Result |
| --- | --- |
| Super-admin Today, 1440×1000 | 4 actionable items, 4 primary actions, no horizontal overflow |
| Super-admin Today, 390×844 | 4 actionable items, 4 primary actions, no horizontal overflow |
| Admin Today | Today/Firms/Reports only; 2 scoped items; no overflow |
| Sales Today | Today/Firms/Reports only; 2 assigned-scope items; no overflow |
| Denied account | Nonblank “Platform access unavailable” recovery state; no platform navigation |
| Temporary access-check failure | One Try again action, one Back action, explicit access-not-removed copy, no overflow |
| Onboarding deep link and reload | Route and load-more state remain available; no overflow |
| Firm 360 | One bulk module-manager action; zero per-module Edit buttons |
| Module manager, desktop/mobile | 6 groups, 19 module rows/selectors, one Reset, one Save, zero visible sub-44px targets, no overflow |

Artifacts:

- `docs/qa/evidence/v105-admin-today-desktop.png`
- `docs/qa/evidence/v105-admin-today-mobile.png`
- `docs/qa/evidence/v105-admin-module-manager-desktop.png`
- `docs/qa/evidence/v105-admin-module-manager-mobile.png`
- `docs/qa/evidence/v105-admin-access-denied-mobile.png`
- `docs/qa/evidence/v105-admin-access-failure-mobile.png`

## Automated gates

- Today coverage increment: **33/33 passed** across
  `v105-today-coverage.test.mjs`, `v105-admin-task-closure.test.mjs`, and
  `v105-admin-task-navigation.test.mjs`.
- Focused v105, localization, and migration suite: **80/80 passed** after
  adding boot, access-failure, visual-fixture, Firm 360, canonical migration,
  and compatibility coverage.
- Full repository suite: **1,074/1,074 passed**.
- Static build: passed.
- Repository validation: passed.
- `git diff --check`: passed.
- No migration was applied and no production data was changed.

### Today coverage truth

The coverage disclosure is intentionally server-contract-specific:

- **Onboarding attention:** every safe v88 keyset page is loaded against one
  snapshot; a paging guard stop is explicitly partial.
- **Firms:** the authoritative total remains exact, while Today discloses when
  only the first 50 directory summaries are present.
- **Billing:** fewer than 250 rows is complete; exactly 250 is labelled
  partial because v77 exposes neither a cursor nor total.
- **Commission accruals:** fewer than 100 is complete; exactly 100 is partial
  for the same reason.
- **Owner applications:** v95's `truncated` flag is shown directly; the UI
  never converts 100 returned rows into an exact total.
- **Automation:** the latest run's item detail remains actionable. Multiple
  returned runs, a 50-run cap, or failed detail reads make coverage partial or
  unavailable and direct the operator to System health.
- **Delegated Admin/Sales scope:** every safe v105 keyset page is loaded
  against the RPC's frozen firm snapshot and delegated-scope snapshot.
  If the guard stops early, exact server `total_count` remains exact while
  derived queue/KPI counts are labelled as lower bounds; empty partial results
  never produce “You are caught up”.

This closes the false-completeness UI defect. It does not invent missing
pagination support in legacy RPCs; those sources remain visibly partial until
their server contracts gain authoritative totals/cursors.

## Remaining release gates

1. Obtain Sol’s independent accept/reject verdict.
2. If accepted, obtain owner release approval for this exact candidate.
3. Only then commit, push, deploy, and run authenticated production smoke:
   direct `/admin`, refresh/back, all four role states, Today actions, Firm
   360/module manager, and mobile.

Until those gates complete, the accurate status is **verified local/browser
candidate; production unchanged**.

## One step beyond competitors

After release, the next improvement should not add more navigation. Add an
operator command layer over the same permission model:

- universal search for firm, owner phone, branch, invoice, and consultant;
- saved role-specific Today views and SLA subscriptions;
- one-click “prepare monthly review” that opens the exact firm/branch report
  with evidence and previous-review comparison;
- keyboard command palette for expert operators;
- usage telemetry measuring time-to-first-action, queue completion, failed
  searches, repeated backtracking, and abandoned forms.

That would make Nestly not only feature-complete, but faster to operate than
module-centric SME CRMs.
