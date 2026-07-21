# Frenly v41 independent status, blocker, and execution audit

**Audit date:** 2026-07-21 (Singapore)

**Repository:** `/Users/cs/Downloads/loyalty-main`

**Branch inspected:** `codex/phase0-transaction-foundation`

**HEAD anchor:** `a71178a4a0d55eb2f878de1e09665fc0fa6a0f8f`

**Scope:** local, read-only application/database audit plus this report. No application code, migration, test, Git index, remote service, production system, or customer data was changed.

**Evidence qualification:** This is the authoritative narrative status/blocker snapshot, not immutable execution evidence. The HEAD anchor does not identify the 64 mutable untracked files or four tracked modifications. No SHA-256 run manifest was created in this audit because the owner authorized one report, not a broader evidence-publication package; EVID-003 remains open and requires a later hash manifest for every modified/untracked file and captured command artifact (the report itself can be covered by a detached manifest).

## 1. Executive summary

**Current launch verdict: RELEASE HOLD.** Frenly does not meet the owner's definition of perfect and is not ready for v41 runtime acceptance, pilot release, or production release.

The v36-v40 work is genuinely present in the local working tree and its source/static validation is strong: the independently rerun full suite passed 192/192, the five-page static build passed, focused v28/v37/v39 passed 20/20, focused v34/v40 passed 17/17, the v37/v40 shell harnesses passed syntax validation, and `git diff --check` passed. That proves source presence and static contracts only.

The implementation cannot yet earn database or browser acceptance:

1. A clean database cannot be reconstructed. Executable v3-v7, v14a-d, and v15a-d migrations are absent from all inspected local Git evidence. Later migrations explicitly depend on those missing objects.
2. Migration identifiers are not deployment-grade: multiple SQL files share the same leading Supabase migration version (`20260717`, `20260718`, `20260719`, and `20260720`). The local sanity test does not detect this.
3. v24a-v40 are not in branch history. At the pre-report audit snapshot they existed as 63 untracked files plus four tracked modifications. This report is the 64th untracked file; a clean checkout at the HEAD anchor contains none of them.
4. There is no approved disposable production-equivalent database, authenticated synthetic browser environment, SMTP sandbox, or accepted runtime evidence.
5. The browser is hard-wired to the production Supabase project, so safe browser testing cannot begin without a separately approved configuration change.
6. Several visible workflows are materially incomplete or misleading: authenticated appointment requests have no staff completion path; Waitlist “Booked” creates no appointment; Resources are not connected to availability; Settings retains a non-atomic CSV import; appointment export is capped at 25 rows; and some direct writes can leave partial state or report success after an ignored error.
7. Checkout is not unified. Quick Sale is an atomic single-amount/single-tender RPC, while Till uses a different no-payment gateway; appointment completion creates a sale without checkout/payment; package, membership, gift-card/credit, split tender, tax, line items, receipt, full supported reversal, and exact inventory restoration are not one coherent transaction flow.
8. All 17 current P0 launch blockers in `docs/launch/launch-blockers.json` remain `BLOCKED`. The older `docs/parity/GOLIVE_DECISION.md` says GO and is stale, contradictory release guidance.

Meaningful work can continue locally after owner review, but the first package must establish a canonical reconstructible database boundary and safe environment routing. Broad feature work before that would compound migration and proof debt.

### How far Frenly is from the written goal

- **Source/static:** v36-v40 slices are credible, but the full Phase 0-12 product is incomplete.
- **Database runtime:** zero accepted full-chain proof because the chain is not reconstructible.
- **Browser runtime:** zero accepted authenticated desktop/mobile proof.
- **Launch operations:** 17/17 P0 gates blocked.
- **World-class differentiation:** nearly all Phase 12 capabilities are missing; the current recommendation engine is a deterministic draft heuristic, not a margin-aware or churn decisioning system.

The complete gap is closed only when the dependency-ordered work packages in section 12 pass independent SQL, RLS/ACL, concurrency, financial reconciliation, browser, operational, and Sol review gates.

## 2. Evidence model and truthful verdict

This audit keeps four evidence levels separate:

| Level | Meaning | Current highest accepted evidence |
|---|---|---|
| A. Source presence | UI, migration, RPC, trigger, or logic exists in the working tree. | Present for many v36-v40 features. |
| B. Static contract proof | Tests inspect symbols, structure, permissions, code patterns, or build output. | 192/192 and focused suites pass. |
| C. Database runtime proof | Complete chain applies and behavior executes against a real schema with real roles, RLS, constraints, and concurrency. | None accepted. |
| D. Browser journey proof | Authenticated desktop/mobile journey completes and database, ledger, audit, and report effects reconcile. | None accepted. |

An RPC existing does not prove that it compiles against the historical schema. A static RLS assertion does not prove tenant isolation with real principals. A rendered route does not prove its controls complete the intended transaction.

### Launch verdict

| Area | Verdict | Basis |
|---|---|---|
| v36-v40 source/static slices | PASS SOURCE/STATIC | Independent local validation and source inspection. |
| Complete migration chain | CHANGES REQUIRED | Missing executable history and duplicate migration versions. |
| Database behavior | BLOCKED | No reconstructible chain or approved disposable database. |
| Browser behavior | BLOCKED | No safely routed authenticated environment or accepted journeys. |
| Phase 0-10 product criteria | PARTIAL | Significant implemented source plus material missing/contradicted workflows. |
| Singapore launch readiness | RELEASE HOLD | 17/17 current P0 blockers remain blocked. |
| Phase 12 differentiation | CHANGES REQUIRED | Most written differentiators are missing. |

## 3. Current branch and worktree state

| Check | Truthful result |
|---|---|
| Current branch | `codex/phase0-transaction-foundation` |
| HEAD | `a71178a4a0d55eb2f878de1e09665fc0fa6a0f8f` — `docs(launch): publish Part C design baseline` |
| Cached relation to `origin/main` | 0 behind / 0 ahead; remote freshness was not fetched because this audit is local-only. |
| Branch upstream | None configured. |
| Modified tracked files | 4: `app/index.html`, v19 gateway migration, v21 hardening migration, v21 SQL test. |
| Untracked files | Audit snapshot before this report: 63 individual files—20 migrations, 22 database tests/harnesses, four launch documents, and 17 application/static test files under five test directories. After creating this permitted report: 64. |
| Staged files | None. |
| v36-v40 present | Yes, in untracked migrations/tests and the modified app; not in commit history. |
| Reproducible from clean checkout | No. A checkout of HEAD loses v24a-v40 and all associated untracked tests/docs. |
| Hidden local dependencies | `.env.local`, `.vercel/`, and `supabase/.temp/` exist but are ignored. They were not used as acceptance evidence. `.env.local` contains only a redacted Vercel OIDC key name. |
| Generated artifacts | `db/database.types.ts` is a stale `export {}` placeholder and cannot describe or recover the schema. The static app build uses `app/` directly and creates no authoritative generated bundle. |

### Modified tracked files

- `app/index.html`
- `db/migrations/20260718180602_frenly_v19_public_gateway_security.sql`
- `db/migrations/20260719_frenly_v21_security_hardening.sql`
- `db/tests/v21_security_hardening.sql`

### Untracked implementation groups

- Migrations: v24a-v40, including v37 and v37b (20 files).
- Database tests: v24a-v40 SQL suites and v37/v40 concurrency harnesses (22 files).
- Documents: `v25-v35-local-acceptance.md`, `v25-v41-evidence-matrix.md`, `v36-v41-remediation-contract.md`, `v36-v41-worker-prompts.md`.
- Static/application tests: `tests/customer-wallet/`, `tests/financial-integrity/`, `tests/phase0-foundation/`, `tests/phase1-import/`, and `tests/phase2-config/` (17 files).

### Independently rerun validation

| Command/check | Result | Evidence class |
|---|---|---|
| `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate` | 192/192 tests; five HTML pages built | PASS SOURCE/STATIC |
| Focused v28/v37/v39 test files | 20/20 | PASS SOURCE/STATIC |
| Focused v34/v40 test files | 17/17 | PASS SOURCE/STATIC |
| v40-only focused suite | 10/10 | PASS SOURCE/STATIC |
| `sh -n` v20/v37/v40 harnesses | Pass | PASS SOURCE/STATIC; syntax only |
| `git diff --check` | Pass | PASS SOURCE/STATIC |

The Node run emits `MODULE_TYPELESS_PACKAGE_JSON` for `_shared/validation.ts`; this is non-blocking configuration/performance hygiene, not runtime acceptance.

### Contradictory, parallel, or stale accepted artifacts

- `docs/parity/GOLIVE_DECISION.md` records GO against an older project/build; the current launch manifest says 17 P0 blockers are blocked. The current manifest governs; the older GO must be retired or clearly archived.
- `docs/benchmark/IMPLEMENTATION_ROADMAP.md` stops at Phase 5; the owner contract runs through Phase 12.
- `docs/benchmark/OPEN_QUESTIONS.md` retains stale product/repository questions.
- The staged import foundation coexists with a visible Settings importer that writes clients directly in chunks.
- Sales Quick Sale and Till present parallel sale gateways with different payment/accounting behavior.
- Legacy `change_requests` staff handling coexists with v33 `customer_appointment_actions`; the new wallet action path has no staff consumer.
- Generated database types are stale and the referenced `db/README.md` does not exist.
- The browser hardcodes the production Supabase URL/key in `app/index.html`; hidden local configuration cannot redirect it safely.

## 4. Phase 0-12 requirement evidence

The per-requirement classification uses only the owner's Part 2 labels. Phase exits use only the final-report verdict labels.

### Phase 0 — Product Truth and Safety

| Requirement | Classification | Finding / work to pass |
|---|---|---|
| Current database and UI capability inventory | PROVEN SOURCE/STATIC | Inventory documents and this audit exist; refresh after canonical baseline. |
| Module dependency registry | PROVEN SOURCE/STATIC | v24b registry and static tests exist; execute against full schema and verify UI behavior. |
| Configuration-field matrix | PARTIALLY IMPLEMENTED | Loyalty blueprint is detailed; business, service, inventory, booking, finance, and communications fields are not one current matrix. |
| Read versus write permission matrix | PARTIALLY IMPLEMENTED | RLS/grant documents and tests exist, but no complete route/control-to-role matrix has runtime proof. |
| Event and side-effect map | PARTIALLY IMPLEMENTED | Design documents cover loyalty/refunds; checkout, appointment, inventory, communications, and reporting diverge as described in section 9. |
| Historical-data rules | PARTIALLY IMPLEMENTED | v26-v40 snapshot/provenance rules are strong; general catalogue/pricing/booking configuration and inventory movements are not fully prospective/versioned. |
| Updated database types | CONTRADICTED BY CURRENT CODE | `db/database.types.ts` is empty/stale. Generate only from reviewed canonical schema. |
| Removal of stale documentation and misleading UI claims | CONTRADICTED BY CURRENT CODE | Stale GO, Phase 0-5 roadmap, Resources claim, Waitlist “Booked,” and tenant-isolation copy remain. |

**Exit:** CHANGES REQUIRED. Static discovery exists, but canonical truth, permissions, generated types, and UI/document claims are not closed.

### Phase 1 — Simple Interface Foundation

| Requirement | Classification | Finding / work to pass |
|---|---|---|
| One primary task per screen | PARTIALLY IMPLEMENTED | Several screens are focused; Settings, Loyalty, and reporting surfaces combine many responsibilities. Browser usability proof missing. |
| Plain-language fields | PARTIALLY IMPLEMENTED | Much copy is plain; technical/config language and misleading status wording remain. |
| Basic mode by default | PARTIALLY IMPLEMENTED | Some progressive disclosure exists, not a consistent app-wide mode. |
| Advanced settings progressively revealed | PARTIALLY IMPLEMENTED | Loyalty editors do this selectively; no consistent cross-module contract. |
| Recommended values with explanations | PARTIALLY IMPLEMENTED | Onboarding and retention presets exist; recommendation basis/cost is incomplete. |
| Input examples | PARTIALLY IMPLEMENTED | Present in selected forms only. |
| Immediate validation | PARTIALLY IMPLEMENTED | Shared validation/static checks exist; many direct-write forms depend on server/toast errors. |
| Draft, Live, Paused and Retired states | PARTIALLY IMPLEMENTED | Loyalty/retention cover several states; catalog, pricing, booking, inventory, and communications do not consistently. |
| Preview before publishing | PARTIALLY IMPLEMENTED | Loyalty configuration has preview-like draft editing; no general configuration preview engine. |
| Configuration rollback | PARTIALLY IMPLEMENTED | Loyalty/retention rollback-as-new-version exists in source; general configuration rollback does not. |
| No deletion of transaction-used records | PARTIALLY IMPLEMENTED | Archive/retire patterns exist, but no runtime proof or universal constraint. |
| Touch-friendly controls | IMPLEMENTED BUT UNPROVEN | Responsive CSS exists; no tablet/mobile browser acceptance. |
| Consistent actions | CONTRADICTED BY CURRENT CODE | Parallel Till/Sales, two importers, legacy/new booking requests, and ignored-error writes are inconsistent. |
| Useful empty states | PARTIALLY IMPLEMENTED | Wallet has independent states; several staff pages lack durable loading/error/denied/retry states. |

**Exit:** PARTIAL. Required closure: remove contradictory paths, standardize state/action contracts, and pass desktop/tablet/mobile usability journeys.

### Phase 2 — Configuration and Module Engine

| Requirement | Classification | Finding / work to pass |
|---|---|---|
| Draft, preview, publish and rollback | PARTIALLY IMPLEMENTED | Loyalty/retention source exists; not a general engine and runtime is unproven. |
| Immutable configuration versions | PARTIALLY IMPLEMENTED | v26-v37 covers loyalty/retention; services, prices, packages, memberships, bookings, tax, and communications remain mutable/live. |
| Future-only rule and price changes | PARTIALLY IMPLEMENTED | Loyalty transactions stamp versions; service/product/package/membership pricing is not comprehensively prospective. |
| Module dependencies | PROVEN SOURCE/STATIC | Registry, validation, and UI foundations exist; database/browser behavior remains unproven. |
| Configuration health | PARTIALLY IMPLEMENTED | Dependency warnings exist; no complete cross-module health/reconciliation view. |
| Dependency recommendations | PARTIALLY IMPLEMENTED | Some module recommendations exist; no accepted runtime/browser proof. |
| Branch overrides | PROVEN SOURCE/STATIC | v29/v37 branch override editor and tests exist; database/browser proof missing. |
| Custom customer fields | PROVEN SOURCE/STATIC | Schema/UI/static support exists; runtime permissions and browser proof missing. |
| Optional industry presets | PARTIALLY IMPLEMENTED | Basic onboarding recommendation source exists; no reviewed preset library and evidence. |
| Basic and advanced modes | PARTIALLY IMPLEMENTED | Selective UI treatment, not a complete engine-wide behavior. |

**Exit:** PARTIAL. Expand versioning beyond loyalty, prove dependency/branch behavior at runtime, and unify health and preview semantics.

### Phase 3 — Business, Branch and Team Setup

| Requirement | Classification | Finding / work to pass |
|---|---|---|
| Business identity, currency, timezone, tax and branding | PARTIALLY IMPLEMENTED | Identity/branding foundations exist; tax/currency/timezone configuration and enforcement are incomplete. |
| Branch hours, closures and contacts | PARTIALLY IMPLEMENTED | Branch/contact/hours foundations exist; closures and availability integration are incomplete. |
| Staff profiles, roles, branches and status | IMPLEMENTED BUT UNPROVEN | Source/UI/RLS foundations exist; full role/branch browser matrix missing. |
| Staff schedules and leave | PARTIALLY IMPLEMENTED | Hours exist; complete leave/schedule workflow and availability connection do not. |
| Staff-service eligibility | IMPLEMENTED BUT UNPROVEN | Assignment source exists; no authoritative availability/browser proof. |
| Read and edit permissions | IMPLEMENTED BUT UNPROVEN | Source policies and module permissions exist; runtime adversarial proof missing. |
| Percentage and flat commissions | PARTIALLY IMPLEMENTED | Commission snapshot paths exist; complete editable policy coverage is incomplete. |
| Commission effective dates | PARTIALLY IMPLEMENTED | Immutable transaction snapshots help history; a full future-effective editor is not proven. |
| CSV import and duplicate review | CONTRADICTED BY CURRENT CODE | Staged atomic foundation exists, but Settings exposes partial direct inserts; duplicate-review browser proof missing. |

**Exit:** PARTIAL. Close onboarding subscription regression, schedule/leave/closure semantics, permission proof, and one atomic import path.

### Phase 4 — Services, Products and Catalogue

| Requirement | Classification | Finding / work to pass |
|---|---|---|
| Edit, clone, activate, retire and schedule future changes | PARTIALLY IMPLEMENTED | Basic add/toggle/retire exists; clone and prospective scheduling are incomplete. |
| Service price, duration, category and description | IMPLEMENTED BUT UNPROVEN | Basic service fields/UI exist; database/browser evidence missing. |
| Deposits, processing time and buffers | CONTRADICTED BY CURRENT CODE | Deposit values may be recorded but are not charged/enforced; processing/buffer behavior is incomplete. |
| Branch, staff and resource eligibility | CONTRADICTED BY CURRENT CODE | Branch/staff foundations exist; resources are explicitly not wired to availability. |
| Product SKU, category, cost, retail price and reorder level | PARTIALLY IMPLEMENTED | Product/price/stock basics exist; full cost/category/reorder policy lifecycle is incomplete. |
| Bundles and add-ons | PARTIALLY IMPLEMENTED | Bundles exist; create is multi-write and can leave an empty bundle; add-on lifecycle is incomplete. |
| Product consumption by services | IMPLEMENTED BUT UNPROVEN | FEFO trigger source exists; repeated completion/locking/under-stock defects remain. |
| Versioned packages and memberships | PARTIALLY IMPLEMENTED | Operational plans exist, but comprehensive immutable versions and prospective changes do not. |
| Customer-facing names, images, descriptions and terms | PARTIALLY IMPLEMENTED | Names/basic descriptions exist; images/terms and customer-facing governance are incomplete. |

**Exit:** PARTIAL. Establish immutable catalogue versions, atomic bundle editing, real eligibility/availability, and deposits/buffers.

### Phase 5 — Unified Sales and Checkout

| Requirement | Classification | Finding / work to pass |
|---|---|---|
| Basket with service and product items | MISSING | Quick Sale records one amount; no authoritative basket/line-item checkout. |
| Customer, staff and branch attribution | PARTIALLY IMPLEMENTED | Branch/customer supported; current UI often sends `staff=null`. |
| Quantity, discounts, tax and notes | MISSING | Not present as a unified checkout contract. |
| Cash, card, PayNow/manual reference, credit and split tender | PARTIALLY IMPLEMENTED | One payment method is supported; no split tender and credit/gift-card are separate paths. |
| Package, membership, gift-card and store-credit use | CONTRADICTED BY CURRENT CODE | Separate operational actions exist, not unified checkout tenders/benefits. |
| Idempotent checkout | PROVEN SOURCE/STATIC | `record_quick_sale` has source/static idempotency; Till differs and runtime proof is missing. |
| Receipt and payment reconciliation | PARTIALLY IMPLEMENTED | Reports/CSV foundations exist; receipt and complete reconciliation are absent. |
| Commission, loyalty and inventory updates in one transaction | PARTIALLY IMPLEMENTED | Sale triggers connect effects, but Quick Sale has no items and appointment completion diverges. Runtime reconciliation missing. |
| Complete reversal and refund workflow | CONTRADICTED BY CURRENT CODE | Partial refunds and several sale kinds are rejected; inventory, earned points, and retention benefits may remain. |

**Exit:** CHANGES REQUIRED. A single authoritative basket/payment/benefit/receipt/reversal transaction is required before browser acceptance.

### Phase 6 — Appointments and Bookings

| Requirement | Classification | Finding / work to pass |
|---|---|---|
| Branch, staff, service and resource availability | CONTRADICTED BY CURRENT CODE | Resources are not wired and no authoritative slot engine exists. |
| Create, edit, reschedule and cancel | CONTRADICTED BY CURRENT CODE | Direct create/status controls exist; authenticated requests cannot be processed by staff and editing is incomplete. |
| Deposits and cancellation rules | CONTRADICTED BY CURRENT CODE | Fields/copy exist without enforced charge/policy lifecycle. |
| Recurring appointments | MISSING | No recurring model or workflow found. |
| Real slot capacity | CONTRADICTED BY CURRENT CODE | v15 describes a global pool, explicitly not date/time slot capacity. |
| Waitlist conversion | CONTRADICTED BY CURRENT CODE | “Booked” only changes waitlist status. |
| No-show handling | PARTIALLY IMPLEMENTED | Status control exists; financial/capacity/audit behavior is incomplete and unproven. |
| Secure customer self-management | IMPLEMENTED BUT UNPROVEN | v19 opaque token gateway/static tests exist; runtime negative/browser proof absent. |
| Booking-to-appointment-to-checkout progression | CONTRADICTED BY CURRENT CODE | Conversion and completion fragments exist; no coherent deposit/availability/checkout journey. |

**Exit:** CHANGES REQUIRED. Build authoritative availability/action processing and connect booking to unified checkout.

### Phase 7 — Inventory Operations

| Requirement | Classification | Finding / work to pass |
|---|---|---|
| Receiving and supplier references | PARTIALLY IMPLEMENTED | Batch receiving exists; supplier/provenance workflow does not. |
| Batch, expiry and FEFO | IMPLEMENTED BUT UNPROVEN | Source exists for expiry/drawdown; full-chain reconciliation missing. |
| Sale and service-consumption drawdown | IMPLEMENTED BUT UNPROVEN | Triggers exist; repeated completion, row-lock, and under-stock risks remain. |
| Wastage and damage | MISSING | No reasoned movement workflow. |
| Branch stock and transfers | MISSING | No branch-owned movement/transfer lifecycle. |
| Stocktake | MISSING | No session, variance, approval, or audit workflow. |
| Reorder alerts | PARTIALLY IMPLEMENTED | UI uses a hard-coded low threshold; no configurable policy. |
| Negative-stock policy | CONTRADICTED BY CURRENT CODE | Under-stock is silently under-consumed rather than blocked/configured/audited. |
| Inventory movement ledger | MISSING | Mutable balances cannot prove exact movement provenance. |
| Reversal-aware restoration | CONTRADICTED BY CURRENT CODE | Reversal reports manual/no-restock and lacks exact batch-consumption provenance. |

**Exit:** CHANGES REQUIRED. An append-only branch stock movement ledger is the prerequisite for exact drawdown, stocktake, transfer, and reversal.

### Phase 8 — Loyalty, Retention and Growth

| Requirement | Classification | Finding / work to pass |
|---|---|---|
| Points, stamps and tiers as versioned configurations | PROVEN SOURCE/STATIC | v24-v37 source/tests exist; database/browser proof missing. |
| Editable reward catalogue | PROVEN SOURCE/STATIC | v27/v36 editor/source/static contracts pass. |
| Branch, service and product eligibility | PROVEN SOURCE/STATIC | Normalized eligibility and branch overrides exist; runtime proof missing. |
| Usage limits and expiry | IMPLEMENTED BUT UNPROVEN | Source models exist; clean-chain/runtime proof absent. |
| Fulfilment and claim states | PARTIALLY IMPLEMENTED | Counter claim/status copy exists; full operational fulfilment lifecycle is incomplete. |
| Redemption idempotency | PROVEN SOURCE/STATIC | v24a operations/tests exist; concurrency SQL not executed against full schema. |
| Referral qualification and fraud controls | PARTIALLY IMPLEMENTED | First-qualified-sale rules exist; self-referral/duplicate identity/rate/attribution defenses are incomplete. |
| Retention segments and win-back programmes | PARTIALLY IMPLEMENTED | Versioned visit rules exist; win-back campaign execution/delivery does not. |
| Birthday, inactivity and milestone automation | MISSING | No complete lifecycle automation engine. |
| Programme cost and break-even simulation | MISSING | Cost fields are insufficient; v35 sets estimated reward cost to zero. |

**Exit:** PARTIAL. Core versioning is strong in source; operations, fraud, automation, economics, database, and browser proof remain.

### Phase 9 — Customer Wallet and Communications

| Requirement | Classification | Finding / work to pass |
|---|---|---|
| Verified customer identity | PROVEN SOURCE/STATIC | v30/v38 source/static contracts exist; gates are off and runtime proof absent. |
| Secure business-customer links | PROVEN SOURCE/STATIC | Exact-email/invitation binding and audit exist in source; adversarial runtime proof absent. |
| Per-business wallet cards | PROVEN SOURCE/STATIC | v32/v39 safe projections and UI exist; cross-customer/browser proof missing. |
| Loyalty, rewards, packages and appointments | PROVEN SOURCE/STATIC | Capability-filtered paginated wallet source exists; authenticated browser proof missing. |
| Email OTP after production SMTP | BLOCKED BY OWNER DECISION | Gate defaults off; requires approved SMTP/test infrastructure and later production acceptance. |
| Email, WhatsApp and SMS preference model | CONTRADICTED BY CURRENT CODE | Only email/in-app are accepted; WhatsApp/SMS absent. |
| Business-specific templates | MISSING | No governed template editor/versioning found. |
| Delivery status, retry and failure handling | CONTRADICTED BY CURRENT CODE | Outbox records states but invokes no provider/delivery worker. |
| Consent, unlinking and data-request journeys | IMPLEMENTED BUT UNPROVEN | Source/static pages exist; operational/browser rehearsal missing. |

**Exit:** PARTIAL. Wallet reading is a strong static slice; customer actions, communication delivery, preferences/templates, and runtime/browser proof block acceptance.

### Phase 10 — Reports and Owner Control Centre

| Requirement | Classification | Finding / work to pass |
|---|---|---|
| Daily sales and payment reconciliation | IMPLEMENTED BUT UNPROVEN | v40 paging/export source exists; runtime ledger/payment reconciliation missing. |
| Revenue, expenses and P&L | IMPLEMENTED BUT UNPROVEN | UI/RPC source exists; full-chain and role proof missing. |
| Appointment utilisation | MISSING | No authoritative utilization model/report. |
| Staff productivity and commission | IMPLEMENTED BUT UNPROVEN | Snapshot/report source exists; runtime/browser permission proof missing. |
| Customer return rate and churn risk | MISSING | No cohort/churn risk report. |
| Loyalty liability and reward cost | PARTIALLY IMPLEMENTED | Credit/gift-card/points fragments exist; cost/breakage/full reconciliation incomplete. |
| Inventory value and risk | MISSING | No valuation, ageing, expiry exposure, or shrinkage report. |
| Campaign and referral ROI | MISSING | No incremental attribution/ROI model. |
| Exception inbox | MISSING | No financial/inventory/provider/data-quality exception queue. |
| Scheduled owner summary | MISSING | No scheduled generation/delivery. |

**Exit:** PARTIAL. Basic financial reports exist in source; complete owner-control reporting and runtime scale/timezone proof remain.

### Phase 11 — Singapore Launch Readiness

| Requirement | Classification | Finding / work to pass |
|---|---|---|
| All launch gates | BLOCKED BY INFRASTRUCTURE | 17/17 manifest blockers remain blocked; some also require owner decisions. |
| PDPA operating rehearsal | BLOCKED BY OWNER DECISION | Runbook exists; named owner and synthetic rehearsal required. |
| Production SMTP | BLOCKED BY OWNER DECISION | Provider/configuration and acceptance not approved. |
| Backup and PITR restore rehearsal | BLOCKED BY OWNER DECISION | Requires isolated infrastructure, named owner, and evidence. |
| Monitoring and named alert recipients | BLOCKED BY OWNER DECISION | No alert-delivery proof or accepted recipients. |
| Credential rotation | BLOCKED BY OWNER DECISION | Operational execution/attestation required. |
| Concurrency and load testing | BLOCKED BY INFRASTRUCTURE | Harnesses exist for selected paths; no complete database/load environment. |
| Complete browser journeys | BLOCKED BY INFRASTRUCTURE | No safely routed authenticated synthetic environment. |
| Support and incident procedures | BLOCKED BY OWNER DECISION | Named owners, escalation, drill, and acceptance needed. |
| Pilot onboarding playbook | CONTRADICTED BY CURRENT CODE | Historical GO material conflicts with current blockers and schema state. |

**Exit:** RELEASE HOLD. No launch requirement has production acceptance.

### Phase 12 — World-Class Differentiation

| Requirement | Classification | Finding / work to pass |
|---|---|---|
| Margin-aware loyalty recommendations | CONTRADICTED BY CURRENT CODE | v35 is an editable average-price heuristic with zero estimated reward cost. |
| Configuration impact simulation | MISSING | No liability/cost/earn-frequency simulator. |
| Churn and next-best-action recommendations | MISSING | No predictive/decisioning engine. |
| Multilingual customer surfaces | MISSING | No EN/ZH/MS/TA localization framework. |
| Apple and Google wallet passes | MISSING | No pass generation/lifecycle. |
| API and webhooks | MISSING | No supported customer-facing integration product. |
| POS, accounting and commerce integrations | MISSING | No adapter lifecycle or supported connectors. |
| Franchise controls | MISSING | Branches are tenant-local, not franchise/group governance. |
| Automated data-quality detection | PARTIALLY IMPLEMENTED | Import validation catches some bad rows; no continuous cross-module engine. |
| Industry benchmark reporting | MISSING | Competitor research exists; no anonymized in-product benchmark capability. |

**Exit:** CHANGES REQUIRED. Differentiation should wait until Phases 6-11 no longer have contradicted, missing, or unproven acceptance rows.

## 5. Independent v36-v40 verification

| Version | Implemented and source/static-proven | Database runtime | Browser runtime | Known defect / evidence gap | Sol verdict |
|---|---|---|---|---|---|
| v36 | Draft reward editing, stable reward identity, normalized eligibility, version-scoped rows, mandatory expected hash, `40001` conflict, configuration row lock, and fail-closed UI. Focused source/static checks pass. | None accepted | None accepted | Full-chain SQL, publish race, restrictions-survive-publication, role, and browser editor evidence missing. | PASS SOURCE/STATIC |
| v37 | Typed versioned retention, backfill contract, taxonomy, branch override editor RPC, immutable version/real-window grant provenance, stable-program/customer overlap lock, anti-remint rules, draft visibility, and owner editor. Focused static checks and shell syntax pass. | None accepted | None accepted | Authored SQL/concurrency harness has not run; clean chain unavailable; editor mobile/conflict journeys absent. | PASS SOURCE/STATIC |
| v38 | Identity, exact-email/invitation claim, token scrubbing, recipient binding, customer/staff personas, switching, sign-out/context clearing, unlink, fail-closed gates, locks/idempotency, and raw-table revokes exist in source/static contracts. | None accepted | None accepted | Gates default off; no SMTP; invitation issuance has no operator UI; rate-limited attempt storage amplification; real-role isolation and stolen/replayed-token tests absent. | PASS SOURCE/STATIC |
| v39 | Safe wallet projections, reward/activity/package/membership/appointment detail, bounded cursors, upcoming/recent ordering, capability filtering, and independent wallet states exist; focused static tests pass. | None accepted | None accepted | Customer A/B and cross-business runtime proof absent; no authenticated desktop/mobile proof; customer appointment actions have no staff lifecycle. | PASS SOURCE/STATIC |
| v40 | Authoritative Quick Sale RPC, one payment/branch attribution, idempotency, reversal wrappers, package/loyalty provenance, serialization, replay/conflict semantics, branch checks, paged reports, full-history v40 export, RFC4180 helper, reversal UI, and compensating history have source/static proof. Focused suites pass. | None accepted | None accepted | It is not unified checkout; Till diverges; unsupported sale kinds/tenders/partial refund; earned points, retention benefits, and inventory may remain; no runtime reconciliation. | PASS SOURCE/STATIC |

### v36 lock/volatility conclusion

The v36 draft RPC uses a locking and expected-hash contract appropriate for conflict detection. It does not incorrectly declare mutation logic `STABLE`, takes a shared configuration lock, preserves stable reward identity, and rebuilds eligibility inside the versioned draft. Static inspection supports the intended safety properties. Only a real concurrent publish/edit execution can promote that conclusion to database runtime acceptance.

### v37 anti-remint conclusion

The source binds grants to immutable configuration versions and real programme/customer windows, while the advisory overlap lock prevents a publish or rollback from reminting the same economic window. Backfill and taxonomy display metadata are represented. Runtime acceptance still requires the rollback SQL and two-session harness on a complete database.

### v38 persona/security conclusion

The source is deliberately server-derived and fail-closed, and raw customer tables are revoked from browser roles. That is the correct architecture. It remains unproven with real Auth JWTs, cross-tenant principals, expired/replayed invitations, dual-role navigation, and provider-backed OTP. A source assertion cannot substitute for those tests.

### v39 wallet conclusion

The wallet reader is one of the stronger UI slices: bounded RPC projections, cursor pagination, capability filtering, and section-level states are present. Its acceptance boundary is read-only wallet behavior. It cannot compensate for the broken appointment-action staff lifecycle or absent communication delivery.

### v40 financial conclusion

The v40 slice improves atomic reversal orchestration and report/export source contracts. Its name must not be interpreted as a complete checkout/refund system. The supported Quick Sale operation is one amount plus one payment method; exact inventory restoration, full benefit clawback, provider settlement, partial refunds, and multiple value instruments remain outside the implemented contract.

## 6. Missing migration-chain analysis

### Search performed

The audit inspected reachable branches/remotes, tags, file history and deleted paths, reflog entries, unreachable commits/trees/blobs, old local checkouts under the permitted local roots, note files, later migrations, test assumptions, schema/design documents, and generated types. No executable originals for v3-v7, v14a-d, or v15a-d were found. The note files are contracts, not authoritative historical SQL.

### Recoverability and object inventory

| Missing migration | Objects and behavior indicated by trusted local evidence | Local provenance | Classification |
|---|---|---|---|
| v3 | Loyalty expiry columns; `points_batches`; FIFO/expiry adjustment, redemption, and cron jobs; referral programmes/codes/qualification; `consents`; `audit_log`; supporting triggers, policies, grants, constraints, indexes, and backfill. | `20260716_frenly_v3_engine.note.md`, commit `86ba596`; later v20/v23 replacement callers/bodies. | PARTIALLY RECOVERABLE. Original DDL, backfill, RLS, trigger, grant, and cron SQL are absent. |
| v4 | Atomic authenticated `create_business`: business, founding owner, default loyalty programme, audit; later default branch/staff-branch behavior. | `20260716_frenly_v4_onboarding.note.md`, commit `aeaf466`; later v11a/v25 replacements. | RECONSTRUCTABLE WITH INFERENCE. Later bodies are compatible contracts, not original SQL. |
| v5 | `membership_plans`, `memberships`, enrol/renew functions and cron; gift-card issue/redeem; ledger/audit integration; policies, grants, constraints, indexes. | `20260716_frenly_v5_memberships_giftcards.note.md`, commit `aeaf466`; later v20 current bodies. | PARTIALLY RECOVERABLE. Foundational DDL/RLS/cron/audit details absent. |
| v6 | Resources; product stock view/batches and FEFO; waitlist; package plans/client packages; bundles/items; appointment/sale columns; appointment completion trigger; booking conversion; RLS/ACL. | `20260716_frenly_v6_ops.note.md`, commit `b2d6c18`; later v8/v12a function bodies. | PARTIALLY RECOVERABLE. Trigger creation and much base schema/security are absent. |
| v7 | Staff invites, create/accept functions, role constraints; branding/policy columns; public business projection; audit and access controls. | `20260716_frenly_v7_team_brand.note.md`, commit `b2d6c18`; surviving UI/callers. | RECONSTRUCTABLE WITH INFERENCE. Exact invite schema/functions/policies absent. |
| v14a-d adjunct | `super_admins`; about 46 super-admin read policies; role normalization; `norm_phone`; normalized client phone; subscriptions/billing view/seats; module templates/permissions; join/till RPCs; sale idempotency; ACL/default/search-path hardening. | `20260718_frenly_v14_rls_billing_modules_till.note.md`, commit `1760ee9`; additive `v14_platform.sql`; later callers. | PARTIALLY RECOVERABLE. Generated policies, functions, backfills, subscription seed, exact order, and checksums absent. |
| v15a-d | `booking_tables`, notifications, booking/business/appointment/waitlist fields, availability view, booking/request/change/convert/settings/import functions, triggers, RLS/ACL, Realtime publication, expiry cron. | `20260718_frenly_v15_bookings_capacity_notify.note.md`, commit `cb02e1f`; later wrappers/callers. | PARTIALLY RECOVERABLE. Exact concurrency, policies, triggers, publication, grants, and cron SQL absent. |

No missing historical migration is **EXACTLY RECOVERABLE** from local evidence. The exact artifacts, hashes, and deployed migration-history rows are **NOT RECOVERABLE FROM LOCAL EVIDENCE**.

### Definitive clean-chain failures

- v20 aborts unless v3/v5 gateways already exist, including points expiry/adjustment, gift-card redemption, membership enrolment/renewal, and earlier sale behavior.
- v19 wraps/renames public gateways whose original v14/v15 definitions are missing.
- v8 and v12a replace `app.on_appointment_completed()` but never recreate the missing v6 trigger. A fresh database can have the function yet never execute the completion side effects.
- `20260718_frenly_v14_platform.sql` explicitly describes itself as additive and dependent on v14a-d/v15a-d already being live.
- `db/database.types.ts` is empty and provides no recovery evidence.

### Migration identifier/order defect

Supabase migration tooling uses the numeric filename prefix as the migration version. The repository contains repeated leading versions:

| Prefix | Files |
|---|---:|
| `20260716` | 1 |
| `20260717` | 7 |
| `20260718` | 3 |
| `20260719` | 5 |
| `20260720` | 28 |

These counts include executable `db/migrations/*.sql` files only; note `.md` files are excluded. The static sanity test checks date/semantic `vNN` naming, not unique deployable versions. Duplicate deployable versions are therefore confirmed for `20260717` through `20260720`. The test also represents v12 before v12a although documentation records live order v12a → v12. Even complete historical restoration would still require a reviewed unique immutable migration manifest.

### Option A versus Option B

| Criterion | Option A — exact historical restoration | Option B — reviewed immutable baseline |
|---|---|---|
| Accuracy | Highest if authoritative statements and checksums can be exported. | High only if built from an exact trusted catalog export, not notes. |
| Auditability | Preserves historical statements/order. | Clear single clean-room boundary with a hash-pinned object manifest. |
| Existing production compatibility | Best match to existing migration history. | Must never be applied to production; clean environments only. Production keeps its history. |
| Clean-room reproducibility | Good after unique order/checksum reconciliation. | Strongest once the baseline is complete and immutable. |
| Risk | Remote artifacts may be unavailable, divergent, or contain historical assumptions. | Omitting ACLs, owners, triggers, cron, Realtime, extensions, or safe seed data is a severe risk. |
| Rollback | Historical rollback semantics may be unavailable. | Destroy/recreate disposable environment; later corrections are forward-only. |
| Maintenance | Preserves a long fragile chain. | Shorter, explicit supported bootstrap boundary. |
| Later migrations unchanged | Only after order conflicts are resolved. | Must prove the first reliable later migration applies unchanged to the baseline. |

**Recommendation: Option A first, with Option B as the bounded fallback.** Under separate owner approval, perform a read-only export of authoritative migration statements/hashes and the complete deployed catalog. If exact v3-v15 statements are available and consistent, restore them. If not, create Option B from the trusted catalog export—not from note-file inference. The baseline must include schemas, extensions, types, tables/sequences/views, generated columns, constraints/indexes/triggers, function definitions/owners/search paths/ACLs, RLS enable/force state and policies, publications, cron, and safe reference/configuration seeds. It must be clean-room-only and independently reviewed before any later migration is applied.

Do not silently recreate historical SQL from notes and do not execute either option without a separate scoped approval.

## 7. Blocker register

Legend: **Local** means the correction can be authored locally; **Owner** means owner approval is required; **Prod** means eventual production access is needed. Every P0 below blocks launch.

### A. Product blockers

| ID | Sev | Phase | Impact and evidence | Required correction and test | Dependencies | Local / Owner / Prod | Launch |
|---|---|---:|---|---|---|---|---|
| PROD-001 | P0 | 5 | No unified basket/checkout; Quick Sale, Till, appointment completion, packages, memberships, gift cards, and credit diverge. | Define and implement one atomic checkout with line items, tax, tender, benefit use, receipt, audit; test idempotency/reconciliation. | DATA-001/2, OWNER-002 | Yes / Yes / Later | Blocks |
| PROD-002 | P0 | 6,9 | Wallet appointment requests remain pending; staff reads legacy `change_requests`. | One authoritative request lifecycle with staff approve/decline/apply, immutable outcome, stable retry key; SQL + browser journey. | DATA-001, SEC-001 | Yes / No / No | Blocks |
| PROD-003 | P1 | 6 | Waitlist “Booked” only changes status. | Atomic conversion RPC creates/links appointment or rename/remove control; capacity/conflict/idempotency tests. | PROD-005, OWNER-004 | Yes / Yes / No | Blocks |
| PROD-004 | P1 | 4,6 | Resources are described as assignable but excluded from availability. | Wire resource eligibility/capacity or remove claim until supported; overlap/browser tests. | OWNER-004 | Yes / Yes / No | Blocks |
| PROD-005 | P0 | 6 | Direct appointment creation has no authoritative availability, overlap, recurring, deposit, cancellation, or time-zone contract. | Build time-safe branch/staff/service/resource slot engine and mutation RPCs; concurrency/SGT tests. | DATA-001/2, OWNER-004 | Yes / Yes / No | Blocks |
| PROD-006 | P1 | 2-4 | Configuration versioning is loyalty-centric; service/prices/packages/memberships/bookings remain mutable. | Extend prospective versions/preview/publish/rollback to transaction-used config; history tests. | DATA-001, OWNER-003 | Yes / Yes / No | Blocks |
| PROD-007 | P1 | 9 | Invitation consumption exists but no operator issuance/delivery workflow. | Add role-gated issuance UI and sandbox delivery lifecycle; security/browser tests. | COMMS-001, OWNER-006 | Yes / Yes / No | Blocks |

### B. Data blockers

| ID | Sev | Phase | Impact and evidence | Required correction and test | Dependencies | Local / Owner / Prod | Launch |
|---|---|---:|---|---|---|---|---|
| DATA-001 | P0 | 0,11 | v3-v7/v14/v15 executable SQL absent; fresh chain fails. | Option A export or reviewed baseline; hash manifest; clean apply/catalog diff. | OWNER-001, INFRA-001 | Partial / Yes / Read-only source or trusted backup | Blocks |
| DATA-002 | P0 | 0,11 | Reused numeric migration versions and ambiguous v12/v12a order. | Create immutable unique ordering/manifest compatible with chosen baseline; CLI clean-apply test. | DATA-001 | Yes / No / No | Blocks |
| DATA-003 | P0 | 0 | v24a-v40 were 63 untracked files plus four modifications before this report (64 untracked after it); clean clone cannot reproduce. | After owner later authorizes Git publication, isolate reviewed sequence; before that, preserve worktree and generate hash manifest. | Sol acceptance of packages | Yes / Yes for later commit/push / No | Blocks |
| DATA-004 | P1 | 0 | Generated types are empty/stale. | Generate types from accepted disposable canonical schema; compile/static drift check. | DATA-001, INFRA-001 | Partial / Yes / No | Blocks |
| DATA-005 | P0 | 3 | v25 replaces `create_business` but omits v14-described subscription seed; no compensating executable proof. | Define authoritative subscription creation, implement atomically or prove trigger; onboarding SQL/browser test. | DATA-001, OWNER-003 | Yes / Yes / No | Blocks |
| DATA-006 | P0 | 6,7 | Missing v6 completion trigger; repeated completion can deduct stock even when sale insert conflicts. | Restore one trigger; guard side effects on successful transition/sale; repeat/concurrent completion reconciliation. | DATA-001, INV-001 | Yes / No / No | Blocks |

### C. Security blockers

| ID | Sev | Phase | Impact and evidence | Required correction and test | Dependencies | Local / Owner / Prod | Launch |
|---|---|---:|---|---|---|---|---|
| SEC-001 | P0 | 0,9,11 | RLS/ACL/definer isolation is static-only; missing base policies/functions prevent full review. | Real owner/staff/customer/dual/anon cross-tenant and cross-branch adversarial suite plus grant inventory. | DATA-001/2, INFRA-001 | Tests local / Yes / Later final-target proof | Blocks |
| SEC-002 | P0 | 9,11 | App hardcodes production Supabase URL/key, making safe browser routing impossible. | Add explicit build/runtime config seam with fail-closed environment identity; prove no prod ref in test bundle. | OWNER-001 | Yes / Yes / No | Blocks |
| SEC-003 | P0 | 6,11 | Public booking/management abuse, origin, rate, token expiry/replay remain runtime-unproven. | Disposable Turnstile/gateway negative tests and final production smoke under later approval. | INFRA-001/2 | Tests local / Yes / Later | Blocks |
| SEC-004 | P1 | 9 | Claim rate-limited attempts can continue writing unlimited attempt/audit rows with new keys. | Bound/storage-safe rate limiter; concurrent abuse and retention tests. | DATA-001 | Yes / No / No | Blocks |
| SEC-005 | P1 | 6 | Staff schedule selector exposes “All staff”; hard per-staff policy is documented as future work. | Decide visibility policy; enforce server-side and run role/branch matrix. | OWNER-005, SEC-001 | Yes / Yes / No | Blocks |

### D. Financial blockers

| ID | Sev | Phase | Impact and evidence | Required correction and test | Dependencies | Local / Owner / Prod | Launch |
|---|---|---:|---|---|---|---|---|
| FIN-001 | P0 | 5 | Till creates sale without payment/drawer while Quick Sale can create both; both appear as checkout and omit staff attribution. | Retire/route through one financial RPC; full sale/payment/drawer/commission/loyalty reconciliation. | PROD-001, OWNER-002 | Yes / Yes / No | Blocks |
| FIN-002 | P0 | 5,7 | Reversal leaves inventory, earned points, and non-referral retention benefits; several tenders/kinds unsupported. | Owner-approved compensation policy plus immutable provenance and atomic wrapper; reversal matrix. | INV-001, OWNER-002 | Yes / Yes / No | Blocks |
| FIN-003 | P0 | 3,4 | Add customer, bundle creation, and Settings CSV perform separate writes; failure can leave partial state. | Route each through one transaction/idempotent staged job; injected-failure and replay tests. | DATA-001 | Yes / No / No | Blocks |
| FIN-004 | P1 | 10 | Appointment/customer exports cap or corrupt data: appointments limit 25; some CSV paths replace commas instead of quoting. | Cursor through full history and use one RFC4180 encoder; >1,000-row and hostile-field tests. | DATA-001, INFRA-001 | Yes / No / No | Blocks |

### E. UX blockers

| ID | Sev | Phase | Impact and evidence | Required correction and test | Dependencies | Local / Owner / Prod | Launch |
|---|---|---:|---|---|---|---|---|
| UX-001 | P0 | 1,11 | 202 visible buttons exist, but most staff modules lack accepted loading/empty/denied/error/retry/conflict/mobile proof. | State contract per route and desktop/390px/tablet browser suite. | INFRA-002, product fixes | Yes / Yes / No | Blocks |
| UX-002 | P1 | 1,6 | Misleading controls/copy: Waitlist “Booked,” Resources assignability, “every table” isolation claim. | Correct behavior or wording; content assertion and usability tests. | PROD-003/4, SEC-001 | Yes / No / No | Blocks |
| UX-003 | P1 | 3,4 | Multiple direct-write buttons ignore errors and update UI optimistically. | Centralize error handling; injected-denial/failure tests; never show false success. | DATA-001 | Yes / No / No | Blocks |
| UX-004 | P1 | 10 | Browser-local `Date` drives appointment week; SGT behavior can differ by client zone. | Explicit business timezone conversions; SGT/non-SGT browser and month-boundary tests. | OWNER-003, INFRA-002 | Yes / Yes / No | Blocks |

### F. Infrastructure blockers

| ID | Sev | Phase | Impact and evidence | Required correction and test | Dependencies | Local / Owner / Prod | Launch |
|---|---|---:|---|---|---|---|---|
| INFRA-001 | P0 | 11 | No approved disposable Singapore Supabase project or database URL. | Owner approves isolated project; provision synthetic-only environment after DATA-001/2/SEC-002. | OWNER-001 | No / Yes / No | Blocks |
| INFRA-002 | P0 | 9,11 | No SMTP capture, Turnstile test setup, authenticated personas, or browser target. | Approved sandbox services/personas and redacted evidence capture. | INFRA-001, OWNER-006 | Partial / Yes / No | Blocks |
| INFRA-003 | P0 | 11 | Backup/PITR, monitoring, alert recipients, load, and incident environment are unproven. | Restore drill, alerts, representative load, incident/support rehearsal with named owners. | Runtime product pass | No / Yes / Later | Blocks |

### G. Evidence blockers

| ID | Sev | Phase | Impact and evidence | Required correction and test | Dependencies | Local / Owner / Prod | Launch |
|---|---|---:|---|---|---|---|---|
| EVID-001 | P0 | 0-11 | No accepted full-chain SQL, rollback, RLS, ACL, or financial run. | Execute all suites once on hash-pinned canonical environment; capture redacted artifacts. | DATA-001/2, INFRA-001 | No / Yes / No | Blocks |
| EVID-002 | P0 | 1-11 | No accepted authenticated desktop/mobile journeys. | Run section 11 journey matrix with traces, screenshots, DB/audit/report reconciliation. | Product fixes, INFRA-002 | No / Yes / No | Blocks |
| EVID-003 | P1 | 0 | Evidence is tied to mutable untracked files, not immutable source hashes. | Generate run manifest/SHA-256 inventory now; later bind evidence to reviewed commit under approval. | DATA-003 | Yes / Later Git approval / No | Blocks |
| EVID-004 | P1 | 11 | No representative scale, concurrency, SGT-boundary, or failure-injection evidence. | >1,205-row, multi-session, SGT/non-SGT, and injected-failure matrix. | INFRA-001/2 | Tests local / Yes / No | Blocks |

### H. Owner-decision blockers

| ID | Sev | Phase | Decision that must not be guessed | Needed before | Local / Prod | Launch |
|---|---|---:|---|---|---|---|
| OWNER-001 | P0 | 0,11 | Authorize read-only trusted schema/migration recovery and/or an isolated Singapore test project; choose exact-history-first with baseline fallback. | DATA-001, SEC-002, INFRA-001 | Planning local / no production writes | Blocks |
| OWNER-002 | P0 | 5,7 | Supported tenders, tax, receipts, split tender, partial refunds, provider settlement, points/retention clawback, inventory restock, and negative-stock policy. | Checkout/reversal/inventory design | Yes / Later | Blocks |
| OWNER-003 | P1 | 2-4 | Canonical currency/timezone/tax, subscription/billing model, configuration scopes/effective dates, and catalogue versioning policy. | Setup/config/onboarding packages | Yes / Later | Blocks |
| OWNER-004 | P1 | 6 | Booking capacity model, resources, buffers, deposits, cancellation/no-show rules, recurring series, and waitlist semantics. | Appointment package | Yes / Later | Blocks |
| OWNER-005 | P1 | 3,6,10 | Exact staff/manager/bookkeeper branch visibility and edit rights. | Permission matrix and browser fixtures | Yes / Later | Blocks |
| OWNER-006 | P0 | 9,11 | Communication channels/provider, sender identities, template ownership, retry SLA, SMTP sandbox, and permission to create synthetic recipients. | Communications/runtime browser work | Partial / Later | Blocks |
| OWNER-007 | P0 | 11 | Named DPO/retention policy, support/incident owners, alert recipients, backup/PITR owner, pilot cohort, and release approver. | Operational rehearsals | No / Later | Blocks |
| OWNER-008 | P2 | 12 | Differentiator scope, pricing/funding, markets/languages, pass/integration/franchise priorities, and benchmark privacy policy. | Phase 12 implementation | Yes / Later | Does not block initial core closure; blocks written perfect goal |

### Crosswalk to the governed 17-blocker launch manifest

`docs/launch/launch-blockers.json` remains the canonical production gate register. The audit IDs above decompose product/data/security/evidence work; they do not replace or renumber the 17 governed blockers.

| Governed manifest blocker | Audit closure dependencies |
|---|---|
| P0-CUTOVER-PARITY-001 | DATA-001, DATA-002, DATA-003, DATA-004, DATA-005, DATA-006, INFRA-001, EVID-001 |
| P0-PUBLIC-ABUSE-002 | SEC-003, INFRA-002, EVID-001, EVID-002 |
| P0-BOOKING-TOKEN-003 | PROD-002, PROD-005, SEC-003, EVID-001, EVID-002 |
| P0-RLS-GRANTS-004 | SEC-001, SEC-005, DATA-001, EVID-001 |
| P0-FINANCE-REVERSAL-005 | PROD-001, FIN-001, FIN-002, FIN-003, DATA-006, EVID-001, EVID-004, OWNER-002 |
| P0-REPORTING-SCALE-006 | FIN-004, UX-004, EVID-004, INFRA-001 |
| P0-PDPA-OPERATIONS-007 | PROD-007, OWNER-006, OWNER-007, EVID-002 |
| P0-AUTH-EMAIL-008 | SEC-002, SEC-003, INFRA-002, OWNER-006, EVID-002 |
| P0-NOTIFICATIONS-009 | PROD-002, PROD-007, INFRA-002, OWNER-006, EVID-002 |
| P0-PAYMENTS-SUBSCRIPTIONS-010 | PROD-001, DATA-005, FIN-001, FIN-002, OWNER-002, OWNER-003, EVID-001 |
| P0-BACKUP-ROLLBACK-011 | DATA-001, DATA-002, INFRA-003, EVID-001, OWNER-007 |
| P0-OBSERVABILITY-012 | INFRA-003, OWNER-007, EVID-004 |
| P0-SGT-TIMEZONE-013 | UX-004, EVID-004, OWNER-003, INFRA-002 |
| P0-TARGET-RUNTIME-014 | SEC-002, INFRA-001, EVID-002 |
| P0-TEST-CREDENTIALS-015 | SEC-002, INFRA-003, OWNER-007 |
| P0-POST-CUTOVER-SMOKE-016 | UX-001, EVID-001, EVID-002, EVID-004, INFRA-003 |
| P0-RELEASE-BUILD-017 | DATA-003, SEC-002, EVID-003, EVID-002 |

Closure requires both the governed blocker's own success criteria/evidence and every applicable audit dependency. An audit ID closing does not automatically close a governed blocker.

## 8. Visible route, tab, button, and action audit

### Inventory method and state legend

Static inspection found five HTML pages, 202 literal button instances in `app/index.html`, three in `join.html`, dynamic row-action templates, route links, modal controls, and legal/data-request links. Every literal `app/index.html` button ID has a handler reference except Turnstile retry controls, which are wired indirectly by `mountTurnstile`. Handler presence is not end-to-end proof.

State codes below: **L** loading, **S** success, **E** empty, **R** error/retry, **D** disabled/permission, **C** conflict/idempotency, **M** responsive/mobile. `Strong` means the source contains explicit section states; `Partial` means toast/implicit or missing states; all browser evidence is `MISSING`.

### Route and control register

| Route/page | Persona, role, scope | Visible controls/actions (including dynamic row actions) | Backend/source of truth | State/static assessment | Keep visible? |
|---|---|---|---|---|---|
| `#/` auth/workspace chooser | Guest or authenticated; server membership determines workspaces | Retry security check, Continue, Reload, sign in, Forgot password, Create my workspace, Join team, persona/workspace switch | Supabase Auth, staff memberships, customer persona RPCs, Turnstile | L/S/R/D partial; C absent; M CSS only. Auth project is hardcoded. | Yes after safe routing/runtime proof. |
| Password reset states | Guest/auth recovery | Send reset link, Back to sign in, Update password, Request a new reset link | Supabase Auth | L/S/R/D partial; browser/email proof missing. | Yes after SMTP/auth proof. |
| `#/claim` | Authenticated customer/dual persona; no firm scope until claim | Sign out, claim action, Retry, Open wallet | v30/v31/v38 identity and claim RPCs | Strong generic result/static security; runtime abuse/identity proof missing. | Yes; gate must remain off until accepted. |
| `#/wallet` | Authenticated customer/dual persona | business-card selection, wallet Retry/Refresh, Sign out | v32/v39 safe wallet RPCs | Strong L/E/R/D source; M CSS; no browser proof. | Yes when customer identity gate is accepted. |
| `#/wallet/{slug}` | Linked authenticated customer; one business | Back, Sign out, Disconnect, per-section Retry/Refresh, reward counter claim, appointment Change, activity/packages/appointments Load more | v31 unlink; v32/v39 wallet RPCs; v33 action RPC | Wallet reads strong; action lifecycle contradicted; per-click UUID breaks logical retry. | Read cards yes; hide Change until staff lifecycle exists. |
| Wallet change modal | Linked customer to exact appointment | Close, Send request | `customer_request_appointment_action`; `customer_appointment_actions` | L/S/R partial; C contradicted; staff outcome absent. | No launch visibility until PROD-002 closes. |
| Workspace global shell | Authenticated staff; enabled module + staff module permissions + business/branch membership | Sign out, module sidebar/nav, Import, Mark all read | server membership/module RPCs plus client routing | Client visibility foundations exist; full server role matrix unproven. | Yes after SEC-001. |
| Universal import modal | Authorized staff; selected business | Close, Paste from Excel, Upload file, Preview, Import, Done | v24c stage/commit import jobs | Static atomic foundation; browser/error/replay proof missing. | Yes; must become the sole import path. |
| Reversal modal | Finance-authorized staff; sale branch/business | Close, Confirm reversal, Cancel, Verify exact replay | v20/v34/v40 reversal RPC wrapper | Source/static C/replay strong; economic contract incomplete. | Only for explicitly supported sale/tender kinds. |
| `dashboard` | Staff; enabled dashboard and branch scope | 7d/30d/90d, Apply, Export CSV, setup-guide Hide/Copy/Just me | report RPCs, business/staff state | L/S/E/R partial; report scale/timezone unproven. | Yes after report truth/capping audit. |
| `clients`, `client` | Authorized staff; business scope | Add customer, Save, Cancel, Previous/Next, dynamic customer row, Adjust, Redeem, consent toggle, custom-field Save/Clear, Show earlier, Reverse ledger actions, Copy referral | clients, consents, custom fields; points/reward/reversal RPCs | Direct multi-write add can leave partial state; L/E/R/C inconsistent; exports/imports diverge. | Yes after atomic create and states. |
| `till` | Till-authorized staff; branch/business | Find, dynamic customer result, Try/Different number, Add & continue, Redeem reward, Confirm, Next customer, Record sale | `record_sale_by_phone`, reward RPCs | Financially diverges from Quick Sale; no payment/drawer; staff attribution null. | No as “checkout” until unified; otherwise label limited sale record. |
| `sales` | Sales/finance role; branch scope | date filters, Apply, Export CSV, Reverse rows, Quick Sale | `record_quick_sale`, v40 report/reversal RPCs | Source/static idempotency/reversal strong; single amount/tender only; browser proof absent. | Yes with capability wording and supported-kind gating. |
| `services` | Owner/manager or configured editor; business/branch | Add service, dynamic active toggle, Create bundle, resource Add, staff-service Add/Remove | services, bundles/items, resources, staff-services direct writes | Bundle can be partial; service toggle may ignore error; resource claim contradicted. | Yes after atomicity/availability/copy fixes. |
| `bookings` | Booking staff; business/branch | Copy portal link, table Add, Save booking rules, request → Appointment, Approve/Decline, capacity/remove, Import bookings | booking tables/settings/requests/change_requests/import functions | Legacy action path only; global capacity; import path needs atomic proof. | Yes after one authoritative booking/action model. |
| `loyalty` | Owner/manager loyalty editor; business/branch override | Retry, Inherit firm setting, Save branch, Edit reward/tier, Add reward/tier, remove tier, Create recommended draft, Save/Publish, modal Close/Save/Archive | v26-v37 config versions, draft/edit/publish RPCs | Source/static strong C/draft; DB/browser missing; no general config engine. | Yes after runtime and conflict journeys. |
| `retention` | Owner/manager loyalty editor | Retry, Leave draft, Publish draft, Create editing draft, Create rollback draft, three presets, Save/Cancel, Edit/toggle programmes, Rename/Sort/Retire types, Add reward type, Save program | v35/v37b typed config and publish/rollback RPCs | Source/static strong; economics/delivery absent; browser/runtime missing. | Yes as editable recommendation, not AI optimization. |
| `referrals` | Authorized staff | Save program, Copy referral (customer route) | referral programs/codes/qualification | Basic source; comprehensive fraud/ROI absent. | Yes with limited claims. |
| `memberships` | Authorized sales/admin | Create plan, Enroll/charge, dynamic actions, Pause, Cancel@end, Resume | membership tables/RPCs | Separate from checkout; provider/dunning/versioning missing. | Yes only as manual internal workflow. |
| `giftcards` | Authorized sales/admin | Sell card/generate code, Redeem full balance to credit | gift-card/credit RPCs | Separate value conversion, not checkout tender; runtime proof absent. | Yes with precise “convert to store credit” wording. |
| `appointments` | Staff; intended branch/role scope | Book appointment, List/Week tabs, Previous/Next, Print, CSV, Complete, No-show, Cancel | appointments direct writes; completion trigger; report query | Direct create, browser-local time, all-staff selector, 25-row CSV, missing trigger/repeat-stock risk. | No launch acceptance until PROD-005/DATA-006. |
| `waitlist` | Booking staff; branch/business | Add, Contacted, Booked, delete | waitlist direct writes | “Booked” is false; error handling weak; no appointment/capacity transaction. | Hide/rename Booked until conversion exists. |
| `inventory` | Inventory staff; business (branch model incomplete) | Add product, Receive batch | products, stock batches | Basic source; no supplier/movement/branch/transfer/stocktake/reversal. | Yes only as limited product/batch view with accurate copy. |
| `packages` | Authorized sales/admin | Create, Sell/charge, Use session, Restore session | package plans/client packages/session operations | Separate from checkout; compensating provenance source exists; runtime unproven. | Yes with role/idempotency proof. |
| `branches` | Owner/manager | Add branch, Save/Cancel, Edit, Staff count | branches/staff-branches | Basic CRUD source; hours/closures/availability not complete. | Yes after permissions and availability integration. |
| `reports` | Owner/manager/bookkeeper per policy | Run, Export sales CSV | report RPCs | v40 pagination source; runtime scale/role/SGT proof missing. | Yes after full-history reconciliation. |
| `staffperf` | Owner/manager/bookkeeper per decision | date ranges, Apply | staff commission/performance views/RPCs | Snapshot source exists; role intent/browser proof missing. | Owner decision required. |
| `dailyreport` | Owner/manager/bookkeeper per decision | date ranges, Apply, Generate, Export CSV, Print | v40 daily report/read model | RFC4180 source strong; runtime full-history/payment reconciliation missing. | Yes after runtime proof. |
| `pnl`, `expenses` | Owner/bookkeeper; business/branch policy | Run, Export CSV, Print, Add expense, Void | expenses/P&L RPCs/tables | Basic source; role/reconciliation/runtime proof missing. | Yes after role and finance acceptance. |
| `setup` | Owner | Hide guide, Copy link, Just me for now | setup/business state | Source only; claims must match implemented modules. | Yes as guide after copy audit. |
| `settings` | Owner/authorized admin | Save branding/business, Save modules, Create invite, retire field, Add field, field Save, modal Close/Save as template/Apply, module/remove/copy/revoke invite, Import customers, Copy join link, Download QR, other Save buttons | businesses/modules/staff invites/custom fields/templates plus direct clients insert | Crowded; visible direct CSV violates atomic import; invite/security/runtime unproven; some mutable live config. | Yes after splitting only by real tasks and removing bypass. |
| `platform` | Super-admin only | platform reads/actions rendered by role | v14 platform objects/policies | Missing base v14 adjunct prevents reconstructible/security proof. | Hidden for everyone else; accept only after real super-admin/tenant tests. |
| `/b/{slug}` public booking route | Guest; one published business | Retry security check, Request booking, Open booking | public gateway/Turnstile; booking RPCs | Static gateway hardening exists; abuse/token/capacity runtime missing. | Gate until SEC-003/PROD-005 pass. |
| Public booking management | Guest with scoped opaque token | Copy private link, Cancel booking, Request reschedule | v19 management token functions/change request | Static token design; staff integration and runtime negative proof missing. | Keep only when token/action lifecycle accepted. |
| `/join.html` | Invited staff | Try again, Retry security check, Join now | invite acceptance gateway/Auth/Turnstile | Handler/source present; missing v7/v14 base and browser security proof. | Gate until chain and journey pass. |
| `/privacy.html`, `/terms.html` | Public | legal navigation and section links | static documents | Source present; legal/owner review required before production truth claim. | Yes after owner/legal acceptance. |
| `/data-request.html` | Public/customer | Privacy/Terms/Data request links, Start request by email | `mailto:` to interim privacy contact | No in-product status/audit/SLA; operational rehearsal absent; would send real communication. | Keep only with accepted interim process and named owner. |

### Control-level findings

- No literal button appears handlerless, but several handlers are behaviorally dead or incomplete.
- `walletChangeSend` creates a new idempotency UUID on every click. A lost response/retry can create a duplicate logical request.
- Waitlist `Booked` changes a label, not the underlying business event.
- Service/membership/waitlist direct mutations can ignore errors and refresh or toast as if successful.
- Customer creation inserts client, then consent, then referral in separate operations; consent failure is ignored and referral failure leaves a partial customer.
- Bundle creation inserts the bundle and items separately; item failure leaves an empty bundle.
- Appointments list/export uses `.limit(25)`.
- Appointment/customer CSV paths do not consistently use the v40 RFC4180 encoder.
- Module visibility has server-derived foundations, but only real JWT/RLS/browser tests can prove irrelevant modules stay hidden.
- No mobile acceptance exists for any control despite responsive CSS.

## 9. Module-connection audit

### Checkout side effects

| Required effect | Current connection | Verdict / risk |
|---|---|---|
| Sale | Quick Sale inserts one sale atomically; Till uses a different gateway. | PARTIAL |
| Sale items, quantity, discount, tax, notes | No authoritative basket/line-item model in the visible checkout. | MISSING |
| Payments | Quick Sale supports one payment; Till records no payment. | CONTRADICTED |
| Commission | Trigger snapshots exist, but UI frequently attributes no staff. | PARTIAL |
| Loyalty/reward progress | Sale triggers award points/stamps/referral/retention. | IMPLEMENTED BUT UNPROVEN; replacement-trigger composition risk. |
| Package/membership benefit | Separate buttons/operations, not checkout. | CONTRADICTED |
| Gift card/store credit | Gift card converts to credit; not integrated tender/split tender. | CONTRADICTED |
| Inventory | Retail/service trigger fragments exist; Quick Sale has no item basket. | PARTIAL |
| Receipt | No complete receipt lifecycle. | MISSING |
| Reports/audit/reversal provenance | v40 read model/audit/provenance source exists. | PASS SOURCE/STATIC for supported slice only. |

`record_quick_sale` correctly reserves an idempotent financial operation and writes its supported sale/payment atomically. It is not a unified checkout. `record_sale_by_phone` in Till inserts only a sale; the two user-facing paths therefore create different cash/payment/accounting outcomes.

### Appointment completion side effects

Intended sequence: appointment status transition → service sale → payment/checkout → package/benefit use → loyalty/reward → commission/staff performance → customer history/reports → service-product FEFO.

Current behavior diverges:

- Missing v6 trigger means a fresh chain never invokes the replacement completion function.
- The function inserts the sale with `ON CONFLICT DO NOTHING`, then deducts stock regardless of whether the sale was inserted. Re-completing can double-consume stock without a second sale.
- No payment or checkout is created.
- Package/membership benefit selection is not integrated.
- Under-stock silently consumes what is available and still completes the service.
- FEFO loops lack explicit row locks.
- Reversal does not restore the consumed batches.

This event is **CHANGES REQUIRED**.

### Reversal side effects

The v20 → v34 → v40 wrapper stack provides an atomic negative sale, supported refund/payment/credit evidence, referral/package/loyalty compensations where modeled, commission netting, audit, replay, and conflict behavior.

Material gaps:

- Earned points are observed but deliberately not clawed back.
- Non-referral retention benefits already issued are not reversed.
- Inventory restock is unsupported and the UI always requests `none`.
- Provider-settled tenders and some original sale kinds fail closed.
- Partial refunds are rejected.
- Legacy rows without provenance fail closed.

The UI must describe this as a constrained compensating reversal, not a complete refund, until OWNER-002 and FIN-002 close.

### Configuration publish side effects

The v37b publication transaction serializes on the business, creates/supersedes immutable versions, updates the active pointer and compatibility projections, stamps taxonomy/reward/retention metadata, and audits the publication. Rollback is a new version, preserving history.

Risks:

- Browser create-draft, save, and publish are separate transactions; failed publishing leaves a draft (live behavior remains unchanged, which is safe, but cleanup/retry UX is incomplete).
- `publish_loyalty_config` and sale triggers are repeatedly replaced wholesale; each replacement must manually preserve all prior module side effects.
- Some tier resolution still uses the live compatibility projection rather than exact transaction-versioned tier rows.
- The v25 `create_business` replacement may have dropped v14 subscription seeding.
- Equivalent versioning does not cover most non-loyalty configuration.

### Customer relationship claim side effects

The claim RPCs atomically bind a verified identity/business relationship, claim-attempt evidence, and audit under advisory locking/idempotency. Invitation tokens are recipient-bound and scrubbed from the URL; unlink evidence exists; persona context is cleared on switch/sign-out.

Gaps:

- `customer_create_identity` and claim are separate browser transactions; failed claim can leave an unlinked identity.
- Exact-email claim depends on a unique legacy client email; stale/reassigned data can link the wrong real-world record without an operational identity-resolution policy.
- Rate-limited requests can still append attempt/audit rows with new keys.
- Invitation issue/delivery lacks an operator UI/provider lifecycle.
- No real cross-business/customer browser proof exists.

### Architectural step beyond competitors

After core closure, replace “one large trigger that every migration redefines” with composable, versioned event handlers and an immutable outbox. Add an append-only stock movement ledger and automated cross-ledger invariants (sale value = tenders + receivable; reversal compensation nets the declared policy; stock consumption/restoration links exact batches; every customer-value effect links the initiating operation). This gives SMEs understandable correction history while providing stronger auditability and reconciliation than typical lightweight loyalty/POS products.

## 10. Exact v41 disposable environment requirements

Do not create this environment until OWNER-001 and OWNER-006 are explicitly approved and DATA-001/2 plus SEC-002 have an accepted design.

### Environment contract

| Area | Requirement |
|---|---|
| Project | A single-purpose Supabase project in Singapore, named `frenly-v41-<reviewed-short-sha>-sg`; synthetic data only; no network, replication, secret, credential, storage, or Auth relationship with production. |
| Runtime identity | Test bundle must visibly assert a non-production environment and fail closed if the configured project ref equals production. URL, publishable key, Edge Function base, Turnstile site key, and gate profile must come from an explicit approved configuration seam. |
| Version pinning | Record source SHA plus uncommitted-file SHA-256 manifest, migration/baseline hashes, Node/npm versions, Supabase CLI version, PostgreSQL version, and exact command inventory. |
| Region/time | Singapore region; business timezone `Asia/Singapore`; tests also run from a non-SGT browser timezone. |
| Extensions/publications | Reproduce the trusted catalog exactly. Local contracts indicate at least `pgcrypto`, `pg_cron`, and Supabase Realtime publication membership; do not infer extras from notes. Record extension versions, cron jobs, and publications. |
| Database | Apply the exact-history or accepted baseline sequence once to an empty project. No manual dashboard DDL. Validate schemas, types, tables, columns, constraints, indexes, triggers, functions, owners, search paths, grants/default privileges, RLS/force state, policies, publications, cron, and safe seeds. |
| Auth | Email/password enabled for synthetic users; approved redirect URLs only; no production identities; email confirmation behavior explicitly pinned; token lifetime/refresh/session settings recorded. |
| Turnstile | Cloudflare test credentials or an owner-approved test widget; strict test origins; never reuse production secret. |
| SMTP | Capture-only sandbox or approved synthetic mailbox provider. No real customer addresses or uncontrolled sends. Record message ID/status without body/recipient leakage. |
| Edge/gateway | Test deployment of public gateway functions with isolated secrets, origin list, redacted logs, and rate limits. No production function invocation. |
| Feature gates | Explicit test profile; exercise each gate off independently and together before enabling only the fixture journeys that need it. |

### Synthetic personas and tenancy

- **Tenant A:** owner, admin/manager, finance-authorized bookkeeper, restricted branch staff, front-desk staff, inactive staff, customer-only user, dual staff/customer user, and unaffiliated user.
- **Tenant B:** owner, staff, and customer canaries for cross-tenant denial.
- At least two branches in Tenant A and one in Tenant B, with distinct staff assignments, hours, closures, services, resources, and module sets.
- Identity fixtures: one exact unique email, duplicate-email ambiguity, unlinked identity, expiring invitation, expired invitation, replayed invitation, stolen token, and stale/reassigned-email case.

### Synthetic business data

- Services/products/bundles/resources/staff-service mappings and branch availability.
- Packages, memberships, gift cards, store credit, loyalty points/stamps/tiers, reward eligibility, retention programmes, referral codes, and notification preferences.
- Published configuration v1/v2, one draft, one rollback-as-new-version, one branch override, retired catalog rows, and historical transactions stamped to earlier versions.
- Appointments/bookings/waitlist/no-show/cancellation/change-action fixtures at overlap/capacity/time boundaries.
- FEFO batches with multiple expiries, sufficient and insufficient stock, plus damage/transfer/stocktake/reversal fixtures after those features exist.
- Sales/payments/credits/reversals for each owner-approved tender/kind; exact replay, changed replay, concurrent credit/reversal, and failure-injection fixtures.
- At least **1,205 sales** so every report crosses typical API page limits; wallet sections spanning multiple cursors; rows at SGT `23:59:59`/`00:00:00`, month end, leap/date/DST-client boundaries (business remains SGT).

### Reset, apply, fixture, evidence, and teardown procedure

1. Destroy and recreate the disposable project, or restore a known-empty owner-approved template; never “clean” production or a shared database.
2. Verify project ref/region/environment guard before secrets are made available to commands.
3. Apply the hash-pinned canonical migration/baseline chain once. Fail on duplicate version, warning, manual object, or catalog drift.
4. Export and compare the complete catalog/object/ACL/RLS/publication/cron inventory.
5. Create synthetic Auth principals, then load deterministic tenant/branch/product/financial fixtures through a reviewed seed procedure.
6. Run all SQL rollback suites from the first reliable version through v40, `rls_adversarial_isolation.sql`, v21 catalog ACL tests, v20/v37/v40 concurrency harnesses, migration rollback/smoke checks, and the >1,205-row scale/timezone matrix.
7. Run the browser journeys in section 11 at desktop, tablet, and 390px mobile where applicable.
8. Reconcile final sales, items, payments, receivables, credit, loyalty, reward, package, membership, commission, inventory, reports, and audit effects to the declared policy.
9. Capture redacted artifacts, build `manifest.json`, compute SHA-256 for every artifact, and have Luna verify fixtures/tests before Sol reviews results.
10. Revoke/delete sandbox keys and users, delete captured mail, destroy the disposable project, and retain only approved redacted/hash-pinned evidence.

### Secret and evidence handling

- Pass secrets through approved environment injection; never print, echo, serialize, commit, screenshot, or include them in HAR/trace output.
- Redact bearer tokens, cookies, project keys, email addresses, phone numbers, invitation/management tokens, and raw payloads.
- Evidence set: run manifest; source/file hashes; migration apply log; catalog/ACL/RLS/function inventory; per-suite result; concurrency transcript/final reconciliation; financial/stock/report reconciliation JSON; query timings/page counts; desktop/tablet/mobile screenshots; console log; redacted trace/HAR; SGT/non-SGT results; teardown attestation.

### Owner approvals required before creation

1. Project creation/region/billing and isolated project administrator.
2. Read-only source migration/catalog recovery or approved baseline input.
3. Test SMTP/Turnstile/provider accounts and permission to create synthetic users/send capture-only messages.
4. Runtime configuration seam scope and environment identity guard.
5. Named evidence custodian, retention period, and teardown owner.

## 11. Required browser journeys

Each journey must run against the environment above. “Evidence” means redacted screenshots/trace/console plus database, ledger, audit, and report assertions bound to the run manifest.

| ID | Persona / device / starting data | Steps and expected UI | Expected writes, ledger, audit, report effects | Negative, idempotency, permission tests | Pass evidence |
|---|---|---|---|---|---|
| BJ-01 New SME owner setup | New synthetic owner; desktop + 390px; no tenant | Sign up/confirm, create workspace, select modules, review inactive recommended loyalty draft, publish only after preview. Clear L/E/R/D/C states. | One business, owner staff, default branch/assignment, subscription per approved model, draft config, audit; no earn effect before publish. | Retry same onboarding key; duplicate slug; unauthenticated; injected subscription/config failure leaves zero partial tenant. | UI trace plus exact row/audit counts and active-version assertion. |
| BJ-02 Branch and team | Owner, then manager/restricted staff; desktop/tablet; Tenant A | Add branch, contacts/hours/closure, invite staff, assign roles/branches/services/schedule/leave; accept invite. | Versioned/atomic setup records and invitation audit; no cross-branch access. | Expired/replayed/stolen invite; manager cannot self-promote; inactive/restricted staff denied; exact retry. | Persona screenshots plus RLS/audit matrix. |
| BJ-03 Catalogue/config publication | Owner/manager; desktop; two branches | Create/edit/clone service/product/package/membership; resource/staff eligibility; draft, preview, publish, future change, retire, rollback. | Immutable versions and active pointers; transaction-used old versions unchanged; audit. | Concurrent publish/edit conflict; invalid dependency; unauthorized staff; retry publish. | Version hashes, before/after historical query, conflict trace. |
| BJ-04 Direct public booking | Guest mobile; available/full slots and waitlist fixtures | Browse business, select branch/service/staff/resource/time, Turnstile, request; full→waitlist/reject; use private management link. | Atomic booking/hold/waitlist and audit/rate evidence; no duplicate customer/consent. | Invalid origin, burst, missing/expired/replayed/cross-booking token, overlap, changed retry. | Gateway logs redacted, row counts, token hash/grant proof, screenshots. |
| BJ-05 Relationship claim/My Frenly | Customer and dual role; desktop/mobile; unique/duplicate/invited fixtures | Create identity, generic claim result, invitation claim, wallet cards, switch wallet/workspace, unlink. | Verified link/attempt/audit; invitation status once; unlink audit; no raw-table access. | Duplicate email non-disclosure; stolen/replayed/expired invite; Customer A/B and Tenant A/B denial; exact/changing idempotency key. | Auth/RLS transcript, safe projection payloads, persona screenshots. |
| BJ-06 Appointment completion to checkout | Front desk + assigned staff; desktop/tablet; booked appointment and basket | Check in/edit/reschedule, complete into unified checkout, select items/customer/staff/branch/tender/benefit, confirm receipt. | Exactly one appointment transition, sale/items/payments/tax/commission/loyalty/package/membership/inventory/audit; reports reconcile. | Repeat completion, insufficient stock, overlap, tender failure, unauthorized branch, injected side-effect failure all leave declared atomic result. | Cross-ledger reconciliation and receipt/audit screenshots. |
| BJ-07 Loyalty/reward/package lifecycle | Customer mobile + staff till; published config v1/v2 | Earn points/stamps, qualify reward/retention, view wallet, redeem/claim/use package/membership, publish change, earn again. | Events stamp exact versions/windows; balances and immutable history correct; no remint after rollback. | Concurrent redemption, replay/changed request, ineligible branch/product/service, expired/limit reached, Customer B denial. | Ledger/provenance reconciliation plus wallet/till traces. |
| BJ-08 Sale reversal | Bookkeeper/authorized manager; desktop; supported sales and benefits | Open full history, reverse supported ordinary sale/package/reward, confirm, verify replay, inspect history/reports/CSV. | Negative sale/refund/credit, benefit and inventory compensation per approved policy, commission net, audit, reports reconcile. | Changed replay conflict; concurrent credit; unsupported tender/kind explicit; cross-branch/role denial; double reversal. | Transaction transcript and exact net-zero/policy reconciliation. |
| BJ-09 Role restrictions | Owner, manager, bookkeeper, branch staff, inactive staff, customer, anon; desktop/mobile | Visit every route/control; confirm relevant modules only and permitted reads/actions. | Only authorized audit events; denied attempts create no business changes. | Cross-business/branch/customer direct URL, raw table, and RPC calls. | Route/action permission matrix with real JWTs and DB before/after. |
| BJ-10 Customer appointment action | Linked customer mobile + front desk desktop | Submit cancel/reschedule, staff sees exact immutable request, approves/declines, customer sees outcome. | One action record/outcome, one appointment change, audit and notification outbox. | Lost-response exact retry replays; changed retry conflicts; another customer/business denied; expired appointment rejected. | Dual-persona traces and one-effect DB assertions. |
| BJ-11 Feature gates/communications | Customer/guest; desktop/mobile; sandbox SMTP/Turnstile | Disable each customer gate independently/together; enable approved gates; issue invite/OTP/notification; observe pending/sent/failed/retry. | Gate audit, outbox attempt/status, captured message ID, consent/preferences; no send when disabled/opted out. | Provider timeout/bounce, retry limit, invalid origin, revoked consent, unauthorized template edit. | Capture-only provider record plus redacted outbox/audit trace. |
| BJ-12 Reports, exports, and SGT | Owner/bookkeeper; desktop; 1,205+ sales and time boundaries | Daily/sales/P&L/staff reports, filters, export/print from SGT and non-SGT browsers. | Full rows exactly once; payment/reversal/commission/tax totals reconcile; SGT boundaries stable. | API page boundary, commas/quotes/newlines/formula-like CSV fields, denied branch, provider/timezone errors. | Row/hash/totals comparison and CSV parser proof. |
| BJ-13 Inventory operations | Inventory manager + restricted staff; tablet; multi-branch batches | Receive with supplier, consume sale/service FEFO, waste/damage, transfer, stocktake, reorder, reverse. | Append-only movements link exact source/batches/branches/reasons; balances/value/risk/reports reconcile. | Concurrent drawdown, insufficient/negative policy, duplicate receive/transfer, unauthorized branch, reversal replay. | Movement-ledger reconciliation and UI/audit trace. |
| BJ-14 Error/state/mobile sweep | Every persona; 390px/tablet/desktop; empty and failing fixtures | Exercise every visible route/control under loading, success, empty, denied, error/retry, disabled, and conflict states; keyboard/touch navigation. | No unintended write on navigation/retry; only successful actions audit. | Network loss, 401 refresh, 403, 409/40001, 429, 500, slow response, double tap. | Screenshot/state matrix, accessibility scan, trace, zero-partial-write assertions. |

## 12. Dependency-ordered remediation and assignment plan

### Real execution sequence

This sequence follows blockers, not phase numbers.

1. **WP-00 Canonical truth and decision lock.** Resolve OWNER-001 through OWNER-007 enough to prevent guessed schema/product behavior; retire contradictory GO/roadmap/UI claims.
2. **WP-01 Reconstructible database boundary.** Recover exact migration evidence or build the reviewed clean-room baseline; unique migration manifest; fix stale types only after a successful clean apply.
3. **WP-02 Safe environment routing and test harness contract.** Add non-production configuration seam and environment guard; design fixtures/evidence while infrastructure approval proceeds.
4. **WP-03 Transaction kernel/unified checkout.** One basket/tender/benefit/receipt operation and declared reversal policy.
5. **WP-04 Appointment integrity.** Trigger/transition fix, authoritative availability, customer/staff action lifecycle, waitlist conversion, and checkout progression.
6. **WP-05 Inventory movement ledger.** Exact branch/batch provenance, operations, negative policy, and reversal restoration.
7. **WP-06 Atomic setup/catalog/import.** Subscription onboarding, client/consent/referral, bundle/item, single staged import, and prospective non-loyalty configuration.
8. **WP-07 Wallet/communications operations.** Invitation issuance, templates/preferences/provider outbox/retry and rate-limit correction.
9. **WP-08 Reporting/control centre.** Remove truncation, one CSV engine, utilization/churn/liability/inventory/ROI/exceptions/summary.
10. **WP-09 Database runtime acceptance.** Provision approved environment; clean apply; run SQL/RLS/ACL/concurrency/financial/scale/timezone suites.
11. **WP-10 Browser and usability acceptance.** Run BJ-01 through BJ-14 on desktop/tablet/mobile.
12. **WP-11 Operational launch gates.** PDPA, SMTP, backup/PITR, monitoring, rotation, incident/support, pilot. Then Sol final launch review.
13. **WP-12 Differentiation.** Only after core/launch criteria pass, implement optional owner-prioritized Phase 12 capability with privacy/economic guardrails.

### Work assignment matrix

| WP | Phase / priority / severity | Accountable lead; support; reviewer | Exact task and expected modules/files | Prerequisites | Acceptance: automated/runtime/browser/deliverables | Parallelism / blocks / approvals / stop |
|---|---|---|---|---|---|---|
| WP-00 | 0 / first / P0 | **Owner**; Terra documents; **Sol** reviews | Decide schema recovery, financial/booking/role/comms policies; canonical roadmap/evidence/permission/event matrices; retire stale GO/copy. Docs only. | This audit | Static link/consistency tests; signed decision record; no runtime/browser. | Terra docs and Luna test inventory can parallel without touching same files. Blocks all design work. Owner approval yes; prod no. Stop on undecided economic/security behavior. |
| WP-01 | 0,11 / first / P0 | **Terra**; Luna fixtures; **Sol** reviews | Trusted exact migration recovery or clean-room baseline; unique manifest; missing trigger/object closure; generated types after apply. `db/migrations`, manifest, types, catalog scripts. | OWNER-001/WP-00 | Clean empty apply; catalog/ACL/RLS diff; later migrations unchanged; hash-pinned evidence. Browser none. | Cannot parallel with other migration authors. Blocks all runtime/product DB migrations. Owner approval for trusted read/project; production writes no. Stop if provenance is inferential. |
| WP-02 | 0,11 / first / P0 | **Terra**; Luna environment guards/tests; **Sol** security review | Runtime config seam, prod-ref fail guard, version pins, fixture/evidence contract. App bootstrap/build/test config only. | OWNER-001, accepted design | Bundle never contains prod ref in test; config/secret redaction tests; disposable smoke later. | Can parallel with WP-01 if no same app/migration files. Blocks browser work. Owner approval yes; prod no. Stop on any production credential/path. |
| WP-03 | 5 / critical / P0 | **Terra**; Luna financial/concurrency tests; **Sol** financial review | Unified checkout and reversal contract: basket/items/tax/tenders/benefits/receipt/operation provenance; route Till/Sales/appointment through it. | WP-00 decisions, WP-01 | Unit/static; rollback/failure injection; concurrent replay/conflict; full cross-ledger runtime; BJ-06/08. | Migration/UI files reserved to Terra; Luna independently authors fixtures/tests in separate files. Blocks WP-04/05/08. Owner financial approval yes; prod no. Stop if accounting policy unclear. |
| WP-04 | 6 / critical / P0 | **Terra**; Luna booking/concurrency/browser tests; **Sol** architecture/security review | Completion transition/trigger, SGT slot availability, resource/staff/branch capacity, deposits/cancellation/recurrence, customer action lifecycle, waitlist conversion. | WP-01, WP-03 interface, OWNER-004/5 | Overlap/capacity/action SQL; repeat completion; RLS; BJ-04/06/10. | Some test design parallels WP-03; implementation waits for checkout contract. Blocks booking launch and utilization. Owner policy approval yes; prod no. |
| WP-05 | 7 / critical / P0 | **Terra**; Luna movement/reconciliation tests; **Sol** financial/data review | Append-only branch/batch stock movements, supplier/receive/waste/transfer/stocktake/reorder/negative/reversal. | WP-01, WP-03 reversal contract, OWNER-002 | FEFO locks/concurrency; exact balance/valuation/restoration; BJ-13 and BJ-06/08 reconciliation. | Design can parallel WP-04; shared checkout migrations sequenced. Blocks exact financial reversal/inventory reports. Owner approval yes; prod no. |
| WP-06 | 2-4 / high / P0 | **Terra**; Luna failure/duplicate tests; **Sol** data review | Atomic onboarding subscription, customer/consent/referral, bundle/items, sole staged import; prospective catalogue/config versions. | WP-01, OWNER-003 | Injected-failure/replay/duplicate/history SQL; BJ-01/03; no partial rows. | Independent sub-slices only if files/migrations do not overlap. Blocks trustworthy setup/config. Owner model approval yes; prod no. |
| WP-07 | 9 / high / P0 | **Terra**; Luna abuse/provider/browser tests; **Sol** privacy/security review | Invitation issuance, bounded claims, channel preferences, templates, provider outbox/status/retry/failure. | WP-01/02, OWNER-006/7 | Rate/concurrency/RLS; capture-only provider; BJ-05/10/11; consent/unlink/data request. | Local schemas/tests can proceed; provider runtime waits approval. Blocks wallet communications/PDPA. Owner/services yes; prod no. Stop before real send. |
| WP-08 | 10 / high / P1 | **Terra**; Luna scale/timezone/CSV tests; **Sol** financial/product review | Full-history reports, RFC4180 exports, utilization/churn/liability/cost/inventory/ROI/exceptions/scheduled summary. | WP-03-07 data contracts | >1,205 rows, SGT/non-SGT, hostile CSV, role/reconciliation; BJ-12. | Report work follows stable event schemas; test fixture design can parallel. Blocks owner-control acceptance. Owner KPI/recipient decisions yes; prod no. |
| WP-09 | 0-11 / gate / P0 | **Luna**; Terra fixes only failed implementation; **Sol** accepts | Provision/test disposable environment, load independent fixtures, run clean apply and full SQL/RLS/ACL/concurrency/load matrix, hash evidence. | WP-01-08, INFRA approval | All authored suites pass against complete schema; catalog/reconciliation artifacts. | No feature implementation in same evidence run. Blocks browser/launch. Owner project/services yes; prod no. Stop on chain drift or leaked secret. |
| WP-10 | 1-11 / gate / P0 | **Luna**; Terra fixes defects in separate cycles; **Sol** accepts | Automate/execute BJ-01..14 desktop/tablet/mobile and SGT/non-SGT; state/permission/accessibility matrix. | WP-09 database pass, SMTP/Turnstile sandbox | Traces/screenshots/DB/audit/report reconciliation; all visible controls have accepted state/role outcome. | Can parallel journeys after frozen build; builders cannot approve. Blocks launch. Owner infrastructure yes; prod no. Stop and fail on any partial effect or unexplained console/network error. |
| WP-11 | 11 / release gate / P0 | **Owner**; Luna rehearses; **Sol** final acceptance | PDPA, SMTP, backup/PITR, monitoring/alerts, credential rotation, incident/support, pilot playbook, final launch manifest. | WP-09/10 accepted | Rehearsal/restore/alert/rotation/load/support evidence; 17 blockers closed by their criteria. | Operational work can parallel where independent. Blocks any release. Owner yes; production access only under later release approval. Stop until every P0 is verified. |
| WP-12 | 12 / later / P2 | **Terra**; Luna experiments/guardrails; **Sol** product/privacy review | Owner-prioritized margin simulation, churn/NBA, localization, passes, APIs/connectors, franchise, data-quality, benchmarks. | Core and launch acceptance; OWNER-008 | Per-feature economic/privacy/security tests and customer evidence; no automatic config publication. | Parallel by isolated products after architecture boundaries. Blocks written “perfect,” not core pilot. Owner yes; external/prod later. Stop if recommendation is not editable/explainable. |

### Parallel-work plan

- After WP-00 decisions, Terra can work on WP-01 while Luna independently finalizes deterministic fixture generators and expected invariants for WP-03/04/05 in separate test-only files.
- WP-02 app configuration work can parallel WP-01 only if it does not touch migration/order files.
- For each high-risk package, Terra owns implementation; Luna owns adversarial/failure/concurrency tests in separate files; Sol reads both only after each candidate is frozen.
- Appointment and inventory design may proceed in parallel after the checkout/reversal interfaces are fixed, but migrations touching sales, appointment completion, stock, or reversal wrappers must be sequenced, never concurrently edited.
- Runtime and browser execution wait for the owner-approved environment and an immutable candidate manifest.

### Critical path to launch

`Owner decisions → trusted schema boundary → unique clean migration apply → safe test routing → unified checkout/reversal → appointment/action integrity → inventory provenance → atomic setup/import/config → communications/reporting → database runtime acceptance → browser acceptance → operational rehearsals → Sol final acceptance → owner release decision`

### First three tasks after scoped owner approval

1. **WP-00/OWNER-001:** recover and checksum the authoritative migration/catalog evidence read-only, then make the exact-history-versus-baseline decision without applying anything.
2. **WP-01 design:** produce the unique immutable migration manifest and baseline/restore candidate with object-by-object provenance; Sol reviews before execution.
3. **WP-02:** add the explicit non-production configuration seam and production-ref guard so a future disposable browser build cannot reach production.

### Exact future prompts

**Terra prompt**

> Work locally on WP-01 and WP-02 only after the owner’s scoped approval. Preserve the current worktree. Do not commit, push, deploy, access or write production, apply migrations remotely, or print secrets. Recover only owner-authorized trusted read-only migration/catalog evidence; do not infer historical SQL. Produce a hash-pinned unique migration manifest or reviewed clean-room baseline candidate, plus a fail-closed runtime configuration seam that refuses the production project in test mode. Add local static tests, but do not claim database/browser acceptance. Stop for any provenance ambiguity or scope expansion and hand the candidate to Luna and Sol.

**Luna prompt**

> Remain independent of Terra’s implementation. Work locally on adversarial fixtures and tests for WP-01 through WP-03 only: clean-chain/catalog invariants, duplicate migration-version detection, onboarding atomicity/subscription seed, unified checkout/reversal cross-ledger invariants, RLS/ACL principals, concurrency/replay/conflict, failure injection, >1,205-row reporting, and SGT boundaries. Do not edit Terra’s implementation files, approve Terra’s work, create remote infrastructure, send communications, commit, push, deploy, or access production. Mark tests unexecuted where the approved disposable environment does not yet exist.

**Sol prompt**

> Review the frozen WP-01/WP-02 candidate read-only and independently. Verify provenance, unique migration ordering, complete catalog coverage, production compatibility, RLS/ACL/security-definer safety, subscription/onboarding side effects, environment fail-closed behavior, and whether later migrations apply unchanged by contract. Distinguish source/static from database/browser proof. Do not implement fixes or approve your own work. Return only the allowed verdict labels, exact blockers, and evidence needed for the next gate. No production access, migrations, commit, push, or deployment.

## 13. Owner decisions required

The owner should answer these in a written decision record before relevant implementation begins:

1. Approve or deny read-only retrieval of trusted source migration/catalog evidence and the disposable Singapore project; accept Option A first with Option B fallback or choose another explicitly reviewed strategy.
2. Define checkout tenders, split tender, tax, receipt, provider settlement, partial refund support, gift-card/store-credit/package/membership semantics, and exact reversal/clawback/restock policy.
3. Define negative/insufficient stock policy and whether service completion must block, warn, or create an exception.
4. Define booking capacity/resource/buffer/deposit/cancellation/no-show/recurrence/waitlist policy.
5. Define currency/timezone/tax/subscription rules and prospective versioning scope for services, prices, packages, memberships, and bookings.
6. Approve exact owner/manager/bookkeeper/front-desk/staff read/edit/branch permissions.
7. Choose communication channels/providers, sender identities, templates, consent separation, retry/failure SLA, and test recipients.
8. Name PDPA/data-retention, backup/PITR, monitoring/alerts, incident/support, pilot, evidence retention, and release owners.
9. Prioritize Phase 12 markets/languages/passes/integrations/franchise/benchmark work and approve privacy/economic guardrails.

## 14. Work that can continue safely

After the owner accepts this plan, the following remains safe and meaningful locally under separately scoped approval:

- Canonical documentation/decision records and removal of contradictory claims.
- Read-only local history/catalog-contract analysis and immutable file-hash manifesting.
- Unique migration-order/baseline design without applying it.
- Source/static tests for duplicate migration versions, environment guards, failure injection, idempotency, reconciliation invariants, CSV, SGT boundaries, and browser journey specifications.
- Runtime configuration seam and production-project refusal tests.
- Product/database implementation packages only after their owner decisions and dependency gates are met.

Further broad feature implementation before DATA-001/2 and OWNER-002/4 are resolved would create churn because transaction, appointment, inventory, and proof contracts would still be unstable.

## 15. Work that must not proceed

Until separate scoped approvals and prerequisite gates are satisfied, do not:

- access or modify production, production migration history, data, Auth, storage, functions, secrets, providers, monitoring, or backups;
- apply any missing/restored/baseline/current migration to a remote database;
- create a remote database/project, test users, provider account, or real communication;
- use real customer data or production credentials in fixtures/evidence;
- rename/reorder migrations, generate schema types from an unaccepted schema, or invent historical SQL from notes;
- enable customer identity/OTP/actions/notifications or public booking gates against production;
- stage, commit, push, deploy, merge, reset, discard, or clean the current worktree;
- treat static tests as database/browser acceptance;
- assign production release work before WP-09, WP-10, WP-11, and Sol acceptance pass.

## 16. Exact next approval wording

If the owner agrees, the smallest safe next authorization is:

> I approve WP-00, WP-01 design/recovery, and WP-02 local implementation only. Codex may preserve the current working tree; perform owner-authorized read-only retrieval of trusted migration statements, hashes, and catalog metadata from the named non-writing source; prepare but not apply a hash-pinned exact-history restoration or clean-room baseline candidate; and add a local fail-closed runtime configuration seam that cannot target the production project in test mode. Codex may add local tests and documentation. Codex must not write to production, apply remote migrations, create remote infrastructure, use real customer data, send communications, stage, commit, push, deploy, merge, reset, discard, or change secrets. Terra implements, Luna independently tests, and Sol reviews read-only. Stop and ask me if exact migration provenance cannot be established or if any action would exceed this scope.

This wording does **not** authorize a disposable project. A second approval should name the Singapore test project, budget/administrator, SMTP/Turnstile sandboxes, synthetic-user permission, evidence retention, and teardown owner after Sol accepts the WP-01/WP-02 candidate.

## Independent acceptance statement

Terra and Luna contributed read-only audit findings. Neither approves implementation. Sol independently accepts this report's status classification as an authoritative narrative audit only. Sol does **not** approve the implementation, database runtime, browser behavior, architecture at runtime, pilot, production, or release. As of this audit, the only correct product and release verdict is **RELEASE HOLD**.
