# V145 launch feature-freeze audit

- Date: 2026-08-03
- Branch: `codex/v145-launch-freeze-reconciled`
- Worktree: `/Users/cs/Downloads/loyalty-main-v145-reconciled`
- Worktree HEAD: V141 production record `c7a6e926b039dae4c5d4600a212b35433f84cb8d`
- Merge base: `origin/main` `dcb01c13035897d3d439ad1b551981a0e881a3c6`
- Candidate scope: reconciled uncommitted V144 plus V145 changes and evidence

Current evidence state: `VERIFIED_DATABASE`. The reconciled migration chain,
disposable database suites, current desktop/390px browser acceptance, complete
validation/build and strict control inventory pass on this exact uncommitted
candidate. Sol independently accepted the frozen candidate on 2026-08-03 with
no P0/P1/P2 release-blocking findings after repeating the source, database and
browser gates. This state is still not `CLOSED`, authenticated-target proof or
production proof.

Scope is deliberately frozen. This candidate adds no product feature, module,
dashboard, route or workflow. It corrects existing reporting and retention
semantics, labels mixed scopes honestly, removes launch access to an unready
stored-value surface, limits the existing advanced-rule surface to management
of already-published rules, and adds verification infrastructure only.

## Reproduction and read-only production evidence

The exact V144 source was inspected before implementation. Read-only aggregate
queries against the active production project found:

- four original visit rows that had been fully reversed, across three
  businesses;
- eight identified non-visit sales, across three businesses;
- 23 points earn rows, all linked to sales;
- Stored value authorities: five `unbuilt`, one `shadow_testing`, zero `live`;
- Program Studio: three published rules, two active for one firm, zero drafts;
  one published discount effect is live, while a notification effect remains
  unbuilt.

No production row was changed and no customer-identifying value was copied into
the repository or this evidence.

The audit reproduced these faults:

1. Dashboard visit and weekday totals counted both a reversed original and its
   reversal. “Unique customers” also counted identified gift-card and other
   non-visit sales.
2. Period-and-branch values appeared beside business-wide current balances
   without saying their scopes. Reports claimed a common scope although points,
   liabilities and active memberships use different scopes.
3. Branch points were calculated from a business-wide points read. Revenue by
   day omitted zero-revenue dates.
4. P&L and staff details depended on raw Data API result sets that can stop at
   1,000 rows. P&L category totals ignored expense foreign-exchange conversion,
   month boundaries were UTC-sensitive, and missing months disappeared.
5. Customer profile and bring-back calculations could retain a fully reversed
   sale as the last valid visit.
6. Stored value was reachable even though no authority is live. Program Studio
   offered authoring choices backed by shadow or unbuilt effects while existing
   published rules still require an owner pause/control path.
7. Customer account creation advertised a disabled **WhatsApp — coming soon**
   OTP channel even though that provider capability is not live.
8. Browser acceptance exposed a separate Singapore calendar defect:
   `shiftSgDateInput('2026-08-03', 1)` returned `2026-08-03`. The helper created
   Singapore midnight and converted it back through UTC before slicing the date.
   Date-walking report loops could therefore fail to advance.

## Corrected contracts

### Dashboard and retention

- A valid visit is an original visit-classified sale with `reversal_of is null`
  for which no reversal row exists. Reversal records, fully reversed originals,
  and non-visit sales do not count as visits or visiting customers.
- Revenue remains the signed sale ledger in the selected Singapore date range
  and selected branch.
- Gross points earned are sale-linked earn entries whose source sale is in the
  selected branch and period.
- Daily revenue returns every Singapore calendar date in the requested range,
  including zero-value days.
- Dashboard cards now say whether they are selected-period/branch or
  business-wide/current values.
- Customer profile, bring-back audience and daily report reuse the valid-visit
  contract instead of deriving incompatible local formulas.
- Singapore input-date arithmetic now uses calendar components in UTC only as a
  timezone-independent date-number calculation. Leap-day and forward/backward
  boundaries are regression-covered.

### Reports, P&L and staff detail

- Reports labels operational, loyalty, liability and membership scopes
  separately.
- `get_reports_summary` is a bounded aggregate. It validates the authenticated
  user, tenant, Reports permission, selected-branch visibility and V94
  branch-effective Reports mode. An all-branch request fails closed if any active
  branch is hidden or Reports-disabled. It exposes no raw rows and calls the
  private gift-card liability helper from a fixed search path.
- P&L reads one server aggregate rather than capped raw sales and expense rows.
  It includes foreign-exchange-adjusted expense categories, a complete monthly
  sequence, Singapore month boundaries and the server-authoritative net value.
- Staff performance pages through all commission ledger records. The UI calls
  them “Signed ledger records”/“Ledger records”, not “Sales”.

### Launch-visible incomplete surfaces

- Stored value is absent from Grow and its typed legacy route redirects with the
  truthful message **Stored value is not available for launch**.
- Program Studio exposes no create/resume authoring path at launch. Owners may
  still inspect and pause already-published advanced rules so existing customer
  promises are manageable; non-owner and unavailable states have no writer.
- WhatsApp OTP appears only when both the runtime flag and server capability are
  live. The unready channel is absent instead of displayed as “coming soon”.
- The source-bound dashboard and P&L acceptance contains no placeholder,
  coming-soon, sample-metric or demo-data copy.

## Red-first regression evidence

- `tests/business-ui/v145-launch-freeze-audit.test.mjs` initially failed 8/8 on
  the V144 source. It now passes **37/37** corrected metric, permission,
  incomplete-surface and traceability contracts.
- Real-browser acceptance then exposed the date-shift defect. The added exact
  regression initially passed 8/9 and failed with expected `2026-08-04`, actual
  `2026-08-03`; after the fix its exact contract remains covered in the current
  37-test suite.
- The combined V145/V119/V47/V102 focused run passes **55/55**, covering
  Singapore dates and labels, date arithmetic, valid visits, daily-report
  reuse, complete P&L aggregates, uncapped staff detail, Reports scopes,
  customer fact availability, branch/module permission boundaries,
  hidden/management-only incomplete surfaces and the database migration
  contract.

## Database evidence

- A fresh disposable PostgreSQL rehearsal applied all **176/176** canonical
  migrations.
- `db/tests/v145_launch_freeze_metrics.sql` passes through rollback and emits:
  - `V145 launch-freeze metric suite: ALL PASS`
  - `V145 rollback residue: ZERO`
- The suite proves one valid visit against a fully reversed visit and an
  identified non-visit sale; exact branch-linked points; zero-filled dates;
  explicit scope metadata; a 1,001-row aggregate beyond the Data API default;
  Singapore month boundaries; FX-adjusted categories; complete months; owner,
  Reports-read-only, denied, foreign-tenant, unassigned-branch,
  branch-Reports-disabled and partial all-branch paths; stable empty/retry
  behavior; and invalid-range denial.
- The V144 consent and V145 launch-freeze suites both pass against the final
  176-file schema through rollback. The post-rollback tenant/user residue query
  returns `0|0`.
- The database and canonical migration copies are byte-identical.

## Browser and UI evidence

The exact current production Dashboard, Reports, Daily report, Customer 360,
Expenses, P&L, customer inbox and Studio safety renderer source is embedded in
the deterministic fixture with SHA-256
`8aba36e19a47a5b82627490fa448bf250c2f9337909ee963ce4ec2ca2355f41b`.
Local Google Chrome acceptance passes at 1440px and a 390px-class viewport:

- exact dashboard values and scope labels;
- 30 daily labels including zero-revenue dates;
- server-authoritative P&L net, complete category/month aggregates;
- transient P&L failure handled once, one successful retry and cleared error;
- stable empty P&L state;
- unavailable business-wide credit remains explicitly unavailable, rather than
  appearing as zero, for a branch-limited Dashboard and Reports reader;
- module-disabled and Loyalty-disabled drilldowns expose no unauthorized or
  misleading action;
- Customer 360 facts, optional-facet retry, Daily report, read-only Expenses,
  customer inbox preferences and the system launch-safety actor render their
  bounded existing workflows;
- no framework overlay, browser exception or outer-page overflow;
- every visible tested action is at least 44px.

Artifacts:

- `v145-launch-freeze-browser/dashboard-desktop-1440.png`
- `v145-launch-freeze-browser/dashboard-mobile-390.png`
- `v145-launch-freeze-browser/dashboard-gated-mobile-390.png`
- `v145-launch-freeze-browser/dashboard-loyalty-off-mobile-390.png`
- `v145-launch-freeze-browser/dashboard-credit-unavailable-mobile-390.png`
- `v145-launch-freeze-browser/reports-money-desktop-1440.png`
- `v145-launch-freeze-browser/reports-money-mobile-390.png`
- `v145-launch-freeze-browser/reports-credit-unavailable-mobile-390.png`
- `v145-launch-freeze-browser/daily-desktop-1440.png`
- `v145-launch-freeze-browser/daily-mobile-390.png`
- `v145-launch-freeze-browser/customer-360-desktop-1440.png`
- `v145-launch-freeze-browser/customer-360-mobile-390.png`
- `v145-launch-freeze-browser/customer-360-feedback-retry-mobile-390.png`
- `v145-launch-freeze-browser/expenses-read-only-desktop-1440.png`
- `v145-launch-freeze-browser/expenses-read-only-mobile-390.png`
- `v145-launch-freeze-browser/pnl-desktop-1440.png`
- `v145-launch-freeze-browser/pnl-retry-success-mobile-390.png`
- `v145-launch-freeze-browser/pnl-empty-mobile-390.png`
- `v145-launch-freeze-browser/customer-inbox-desktop-1440.png`
- `v145-launch-freeze-browser/customer-inbox-mobile-390.png`
- `v145-launch-freeze-browser/studio-launch-safety-attribution-mobile-390.png`

The screenshots prove layout and visible copy. Chart data assertions inspect the
exact renderer configurations; the deterministic browser fixture stubs Chart.js
instead of treating a drawn canvas as numeric proof.

## Complete local validation and control inventory

- `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate` passes
  static quality, runtime configuration, migration manifests, canonical
  materialization, **1,490/1,490 automated tests**, and the complete static web
  build for `index.html`, `join.html`, `offline.html`, `privacy.html`,
  `terms.html` and `data-request.html`.
- Strict existing-workspace inventory: 25 expected business routes and nine
  platform routes are all mapped. Across 313 literal controls, 289 buttons and
  24 links have zero unlabeled, unwired, invalid-anchor, hidden-route-target or
  non-semantic-click findings.
- `git diff --check` passes.

## Remaining boundary

This is local browser and disposable-database evidence, not authenticated target
or production proof. It does not close unrelated owner-ledger rows. The live
Stripe catalogue and signed webhook remain external production configuration
evidence for self-service payment; V145 neither fabricates nor bypasses them.
Sol independently accepted the exact frozen candidate on 2026-08-03 with no
P0/P1/P2 release-blocking findings. A subsequent owner approval scoped
specifically to V145 remains required before any commit, push, merge, migration
or production deployment. No release action or production write is authorized
by this audit alone.
