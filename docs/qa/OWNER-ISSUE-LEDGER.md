# Owner issue ledger

Last consolidated: 2026-07-29

This ledger makes every owner complaint durable and prevents a screenshot from
being treated as an isolated one-off. Detailed surface and test mappings live
in `TRACEABILITY-MATRIX.md`.

## Lifecycle

| State | Meaning |
| --- | --- |
| `CAPTURED` | Requirement/symptom is recorded but not yet reproduced. |
| `REPRODUCED` | The symptom is observed with named fixture and evidence. |
| `IMPLEMENTED_UNVERIFIED` | Code exists, but the required acceptance evidence is incomplete. |
| `VERIFIED_LOCAL` | Relevant local automated tests pass. This is not browser, database, or production proof. |
| `VERIFIED_BROWSER` | Required real-browser journeys and viewports pass with artifacts. |
| `VERIFIED_DATABASE` | Persistent records and cross-surface projections are verified against the target database environment. |
| `VERIFIED_PRODUCTION` | The exact accepted version is verified in production after authorized release. |
| `DEFERRED_OWNER` | Owner intentionally deferred it; reason and date are recorded. |
| `BLOCKED` | A named external input or authority is required. |
| `SUPERSEDED` | A later owner decision replaced it; the replacement ID is recorded. |
| `CLOSED` | Every acceptance criterion has the required evidence and independent review. |

Do not skip directly from `CAPTURED` or `IMPLEMENTED_UNVERIFIED` to `CLOSED`.

## Evidence required in every issue

- exact complaint and source date/context;
- affected role, branch, sector, module, and device;
- realistic fixture;
- reproduction artifact;
- regression test name;
- owner -> staff -> customer evidence where data crosses surfaces;
- disabled/empty/denied/retry/refresh/mobile evidence when applicable;
- independent reviewer and verdict;
- production evidence only after an authorized release.

## Consolidated issue register

The source descriptions below consolidate the owner's cumulative instructions
and screenshots through 2026-07-29. `VERIFIED_LOCAL` means only the named local
phase has evidence; it is intentionally not marked closed.

| ID | Owner complaint / acceptance intent | Current state | Required proof before close |
| --- | --- | --- | --- |
| `AUTH-001` | Customer signup must work by Singapore mobile; normal login uses password/passkey, OTP only for account creation and forgot password; password reset, reveal controls, back navigation, and passkey placement must work. | `IMPLEMENTED_UNVERIFIED` | iPhone/Safari and Chrome journeys; one-OTP accounting; reset persistence; unsupported-passkey state. |
| `JOIN-001` | A business QR must remain active when signups are enabled; scan -> signup/sign-in -> automatic one-time business link. No customer search/self-link. | `IMPLEMENTED_UNVERIFIED` | New and existing customer browser runs, duplicate scan idempotency, disabled-link state, DB relationship. |
| `CUSTOMER-001` | Default customer home, compact logo programme selector, individual programme overview, profile menu, one notification action, English-only customer UI. | `IMPLEMENTED_UNVERIFIED` | Desktop/mobile visual artifacts using 0, 1, and 5+ programmes; keyboard/touch navigation. |
| `CUSTOMER-002` | Customer sees complete transactions, visits, points per transaction, reversals, packages, vouchers, and balances consistent with business records. | `IMPLEMENTED_UNVERIFIED` | Ledger-to-portal database comparison including reversal/retry/reload. |
| `CUSTUX-001` | Screenshot 2026-07-29: remove the confusing destructive Disconnect button and audit every customer control so its purpose is immediately understandable. | `VERIFIED_LOCAL` | v103 control inventory and DOM regressions prove Disconnect, duplicate Add programme, presentation Retry, and programme-level notification preferences are absent. Authenticated desktop/mobile browser artifacts remain required before close. |
| `CUSTUX-002` | Screenshot 2026-07-29: a linked programme shows "This programme could not be loaded" even while balance/rewards/history appear. Find the exact failing contract and provide a coherent recoverable experience. | `VERIFIED_LOCAL` | Root reproduced as omitted linked business UUID; v103 summary migration/rollback SQL and UI tests prove UUID projection, caller validation, linked/outsider/cross-firm denial, and optional-presentation fallback. Target reload evidence remains required before close. |
| `CUSTUX-003` | Screenshot 2026-07-29: 70,576 balance dominates the page, the balance is duplicated, and an empty Tier progress card says "Every visit still counts" twice. | `VERIFIED_LOCAL` | v103 tests use 70,576 and ordinary balances and prove one compact formatted balance, no duplicate points metric, and no tier surface without real progress. Authenticated 390px/desktop visual artifacts remain required before close. |
| `CUSTUX-004` | Screenshot 2026-07-29: Transactions & points should be supporting content under one History section rather than a competing programme block. | `VERIFIED_LOCAL` | v103 DOM tests prove one initially collapsed accessible History disclosure containing transactions and loyalty activity; empty success has no false Retry/Refresh. Authenticated mobile navigation remains required before close. |
| `CUSTUX-005` | Screenshot 2026-07-29: every eligible reward needs a clear "Redeem now" action beside it that prepares the customer QR. | `VERIFIED_LOCAL` | v89/v103 regressions prove eligible classic/catalog rewards show Redeem now and create idempotent pending intents; disabled/insufficient/ended states have no dead CTA. Target customer-to-staff scan evidence remains required before close. |
| `BOOKING-001` | Customer booking is visible only when enabled; staff appointments are searchable, editable, assignable by staff name, and distinguish duplicate customers by phone. | `IMPLEMENTED_UNVERIFIED` | Owner toggle -> customer visibility; staff amend -> customer update; branch/role denial. |
| `REDEEM-001` | Customer redemption is pending until a business scan/confirm; Quick Earn must expose scanning and prevent double redemption. | `IMPLEMENTED_UNVERIFIED` | QR lifecycle, expiry, concurrency/idempotency, insufficient points, customer/business sync. |
| `ONBOARD-001` | Every firm requires Super Admin approval before an owner can create/activate the account. Website signups appear in the onboarding board. | `IMPLEMENTED_UNVERIFIED` | Pending/approved/rejected/duplicate request and assigned-consultant journeys. |
| `MODULE-001` | Super Admin controls sector templates and firm/branch overrides; owners cannot escape the effective set; inventory and Customer Intelligence are hidden from firms. | `IMPLEMENTED_UNVERIFIED` | Sector/firm/branch matrices for owner/manager/front desk and direct-route denial. |
| `PLATFORM-001` | Super Admin/Admin/Sales permissions, searchable firms, streamlined kanban, inactivity notices, contact actions, branch/customer drill-down, reports, billing, and commissions. | `IMPLEMENTED_UNVERIFIED` | Role-isolated browser and DB scenarios, report scope, billing webhooks, calculation fixtures. |
| `INTEL-001` | Nestly consultants need sector/firm/branch customer intelligence and actionable consultative advice; firm owners must not access the module directly. | `IMPLEMENTED_UNVERIFIED` | Assigned consultant scope, aggregation math, recommendation provenance, owner denial. |
| `QUICK-001` | Quick Earn uses enabled catalogue items/variants, supports phone search, fast double-confirm corrections, and consistent points/sale outcomes. | `IMPLEMENTED_UNVERIFIED` | Duplicate names, catalog off/on, correction/reversal, lost response, double tap, ledger sync. |
| `GROW-001` | One guided Grow setup, visual overview, editable result, no hard refresh, understandable playbooks/studio, sector-specific recommendations with flexible ranges. | `VERIFIED_LOCAL` | Local v97-v102 UI tests exist; still requires desktop/mobile browser task completion and persisted reload evidence. |
| `I18N-001` | Business workspace toggles English/Chinese/Malay interface; no side-by-side Chinese content fields; customer stays English. | `IMPLEMENTED_UNVERIFIED` | Full-route translation inventory, persistence, missing-key and mixed-language check. |
| `BRAND-001` | Business logo/profile and programme images save and sync to customer cards; reported upload permission error must be fixed. | `VERIFIED_LOCAL` | v102 local regression passes; still requires authorized target storage upload, reload, owner/customer visual evidence, and denied-role test. |
| `PACKAGE-001` | Service variants, package list value/discount, owner-configurable package points, customer-owned package/voucher visibility and deduction in Quick Earn. | `VERIFIED_LOCAL` | v102 local regression/DB contract passes; still requires real-browser owner -> staff -> customer run and target DB evidence. |
| `GIFT-001` | New gift-card issuance is absent when disabled, while valid existing gifts remain redeemable. | `VERIFIED_LOCAL` | v102 local regression passes; still requires toggle/reload, staff UI, existing-liability redemption, and customer history evidence. |
| `NAV-001` | Left navigation must not auto-scroll, hard-refresh, blank the workspace, or lose draft state. | `IMPLEMENTED_UNVERIFIED` | Route sweep with saved scroll/draft state, slow network, chunk failure/retry, mobile. |
| `MOBILE-001` | Customer and business experiences must be PWA/mobile-ready now and compatible with a later native wrapper. | `IMPLEMENTED_UNVERIFIED` | Installability, safe areas, camera, passkey, push, offline/reconnect, iPhone/Android acceptance. |
| `NOTIFY-001` | Transactional in-app/Web Push for points, redemption, booking, package, and 3-day/1-day expiry; advanced promotions remain platform-mediated. | `IMPLEMENTED_UNVERIFIED` | Permission states, delivery records, dedupe, timezone, expiry scheduler, copy review. |
| `BILLING-001` | Automated subscription payment tracking; daily overdue notice and 14-day owner pause with representative contact. | `IMPLEMENTED_UNVERIFIED` | Stripe success/failure/refund/chargeback events, clock-bound notices, access pause/recovery. |
| `RELEASE-001` | Test every visible function/button with realistic owner, manager, front desk, customer, dual-role, platform roles and real sync; never overstate readiness. | `CAPTURED` | Every required matrix row verified; launch blocker manifest clear; Sol verdict; owner approval; post-release smoke. |

## How to add a new owner report

Add a row immediately, even when diagnosis is unknown. Then add a matching
traceability row with:

`ID | source | acceptance | owner config | staff action | customer projection |
fixture | negative states | automated evidence | browser evidence | DB evidence |
production evidence | state`

When one screenshot contains several failures, create separate IDs. A single
visual artifact may support several rows, but each row retains its own
acceptance criteria.
