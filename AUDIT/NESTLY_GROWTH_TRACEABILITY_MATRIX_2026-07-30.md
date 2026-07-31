# Nestly Growth Closure Traceability Matrix

**Frozen baseline:** `6226777e34c41ac1bc5f6ec10edd13332e17c929`
**Working branch:** `codex/v89-security-readiness`
**Local candidate corpus:** 773 product/source/evidence files excluding this
self-referential matrix, SHA-256
`7b00764cae2f347ca36ea79d284d5c78b8bdf04a07291517591c798ab548a022`
**Tracked diff SHA-256 (same exclusion):**
`3b9eb0bf9bc949b4e523da51c2c4d08c22bc6eb48d2ce18cd078e87c4758e3bc`
**Rule:** A row is `Verified locally` only when its exact acceptance criterion has
both implementation evidence and an executable regression. Local verification is
not evidence of production deployment, production data, or a real customer outcome.

## Status vocabulary

- **Verified locally** — implementation and automated local evidence pass.
- **In independent review** — implementation and exact automated local evidence
  pass, but the frozen candidate is not counted as closed until Sol independently
  accepts it.
- **In verification** — implementation exists but the complete acceptance journey
  is not yet green.
- **In build** — acceptance criterion is defined and implementation is underway.
- **Owner/pilot required** — code cannot manufacture the external or historical
  evidence; this is intentionally left until all locally controllable work is done.

## Cumulative revenue-intelligence closure

| ID | Requirement / complaint | Exact acceptance criterion | Implementation evidence | Executable evidence | Status |
|---|---|---|---|---|---|
| P0.1 | Revenue totals must not overstate the business | Known, identified, anonymous, itemized and reconciled coverage are separate; identical replay is harmless; conflicting replay is quarantined; refunds reconcile once | `v106_revenue_truth_foundation`; v112 canonical source/idempotency serialization and immutable receipts | v106 and v112 Node/SQL suites; true two-session v112 same-source/same-key and same-source/different-key races | In independent review |
| P0.2 | “Returning” and total revenue were ambiguous | Existing-returning, repeat-in-period and reactivated have distinct formulas; zero denominators stay unavailable; scope/as-of/coverage travel with every metric | `v107_customer_lifecycle_contract`; `revenue-truth.js` | `v107-customer-lifecycle-contract.test.mjs`; `v107_customer_lifecycle_contract.sql`; `revenue-truth-ui.test.mjs` | In independent review |
| P0.3 | Duplicate/anonymous identity cannot be guessed | Cross-business or ambiguous identities never auto-merge; proposals, approval, replay and reversal remain auditable; coverage changes only after approved proof | v111 identity proposal/proof/decision/reversal workflow | v111 Node/SQL suites plus true two-session approval-first and link-first race harness | In independent review |
| P1.1 | Owner needs one defensible next action | The server returns at most one current recommendation with evidence window, audience, exclusions, revenue range, cost, confidence, expiry and policy version | `v108_measured_bringback_loop`; v113 effective-identity consumers; `revenue-truth.js` | v108/v113 Node and rollback SQL suites, including corrected-identity overlap and offer access | In independent review |
| P1.2 | “Sent” must mean real execution, not UI intent | Owner preview/approve is explicit; current consent, frequency cap, quiet hours, cost cap and idempotency are rechecked server-side; delivery state is not inferred from a click | v108 execution contract; v110 delivery lifecycle; v112 request locks and backoff | v108/v110/v112 Node/SQL suites and true two-session v112 mutation/callback races | In independent review |
| P1.3 | Customer offer must link to the purchase exactly once | Customer gets one opaque single-use QR; merchant cannot redeem it before checkout; successful redemption contains the completed sale and recommendation lineage; reversal is evented | `v108_measured_bringback_loop`; merchant scanner in `app/index.html` | v108 merchant/customer UI tests and rollback SQL redemption/reversal journey | In independent review |
| P1.4 | Results must update without manual “returned” clicks | Completed and reversed sales update treatment/holdout outcomes; small/invalid samples suppress causal claims; result separates associated from estimated incremental revenue | v108 measured outcomes; v113 effective-identity attribution | v108/v113 Node and rollback SQL suites with correction during a running experiment | In independent review |
| P1.5 | The system must learn without calling noise a win | Every recommendation has decision/result history; prediction, cost, result and confidence are visible; inconclusive is not a win; policy version is immutable | v108 measured learning; v113 effective-identity result attribution; `growth-offers.js` | v108/v113 SQL and UI suites | In independent review |
| P2.1 | Profit and ROI were impossible | Effective-dated item, benefit and delivery costs are traceable; profit/ROI are unavailable unless the configured coverage gate passes | v109 item economics; v114 effective-dated benefit/provider-delivery cost rules and period economics | v109/v114 Node and rollback SQL suites, including incomplete-coverage fail-closed cases | In independent review |
| P2.2 | Owner cannot tell why revenue changed | Server decomposes the comparison-period delta into identified-customer count, frequency, AOV, anonymous revenue and residual; contributions reconcile within rounding; identity and itemization coverage are explicit; product price/volume/mix is explicitly `not_claimed` until complete itemization and a versioned taxonomy exist | v109 deterministic drivers; v113 effective-identity and itemization-coverage decomposition; `sector-economics.js` | v109/v113 seeded current/comparison, corrected identity, anonymous, branch, residual and partial-itemization SQL/UI cases | In independent review |
| P2.3 | More playbooks must not multiply incomplete modules | Every additional playbook reuses consent, decision, delivery, entitlement, holdout and outcome lineage; none is enabled before the first loop is proven | reusable v108 contract; templates remain gated | Type-specific regression suite after measured pilot | Owner/pilot required |
| P2.4 | Marketing wording must be useful but never invent facts | Numbers, dates, eligibility and CTA destination are locked; output is schema-valid, versioned and owner-approved; deterministic zero-cost fallback always works | `governed-offer-copy.js`; final approved wording is stored by the v108 approval lineage | `v109-governed-offer-copy.test.mjs`; v108 owner double-confirmation tests | In independent review |
| P2.5 | Supported sectors need different cadence | Every rule names sector, evidence, fallback, suppression and effective policy version; safe owner override is audited; no universal churn number | `v109_economics_driver_sector_policy`; `sector-economics.js` | Canonical `fnb`, `facial`, `salon`, `fitness`, `retail`, `massage` and complete `other` fallback fixtures plus audited override SQL/UI suites; clinic/tuition are not advertised as supported sectors | In independent review |

## Cross-surface acceptance journeys

| Journey | Acceptance criterion | Evidence | Status |
|---|---|---|---|
| Owner configuration → staff sale → customer offer | Approved offer is visible only to its eligible customer; staff must complete the matching sale before scanning; customer and owner histories show the same lineage | realistic v108 DB journey + `v108-growth-offers-ui.test.mjs` + `v108-growth-offer-merchant-ui.test.mjs` | Verified locally |
| Disabled/empty | Feature flag off, no consent, no coverage, no recommendation, no reward and no offer each show a truthful empty/suppressed state and expose no unusable primary action | v108 DB journey + owner/customer UI state tests | Verified locally |
| Retry/replay | Retry reuses authority/idempotency; duplicate delivery, scan, callback or sale cannot double-spend or double-count; failed delivery cannot be claimed before its versioned due time | v106/v108/v110/v112 DB tests; true two-session v112 harness; owner/customer double-click and retry tests | In independent review |
| Branch/tenant/permission | Wrong tenant/branch/customer is denied; finance costs remain finance-only; sales staff cannot see unassigned firms | v106–v108 DB role/tenant tests; owner UI permission tests | Verified locally |
| Refresh/mobile | Customer, business and Platform entry state survives refresh; 375 px layout has no horizontal overflow; every visible action is at least 44 px; skip links resolve to one main landmark; each entry has one page heading; reduced motion is respected | rendered browser acceptance + `customer-enterprise-ui.test.mjs` + `phase1-customer-first-class.test.mjs` | Verified locally |
| Production | Required migrations applied, functions reachable, authenticated role journeys and provider state verified against the promoted build | owner release + production smoke | Owner/pilot required |

## Independent-review remediation ledger

The first Sol review rejected closure despite green tests because several tests
used browser-shaped fixtures instead of the live SQL contract. Every row below
must be fixed, exercised with a regression that reproduces the original failure,
and independently re-reviewed.

| ID | Review finding | Exact closure criterion | Status |
|---|---|---|---|
| IR-01 | UI sent `p_as_of: null` and consumed invented result aliases | UI sends a real as-of instant, uses the same half-open period on every module, and consumes only SQL-returned field names | Ready for Sol re-review |
| IR-02 | New definer RPCs and RLS allowed branch-limited staff to cross branch scope | Every reader/writer/RLS path denies a foreign branch and reserves business-wide scope for global authority | Ready for Sol re-review |
| IR-03 | Growth redemption accepted an old or cross-branch sale | Redemption requires a completed, unreversed, same-client/same-branch sale after entitlement issuance and replays the same receipt | Ready for Sol re-review |
| IR-04 | Reconciliation coverage was presented as merchant-total revenue | Reconciliation proves exact event type and amount for each native sale; UI calls it native-record reconciliation and never merchant-total completeness | Ready for Sol re-review |
| IR-05 | Positive point estimates could be labelled a win while the interval included zero | `won` requires minimum samples and a confidence interval wholly above zero; otherwise result is inconclusive | Ready for Sol re-review |
| IR-06 | Sector policy and owner overrides were display-only | Effective sector policy and enforceable suppressions materially control generation and are version-lineaged in each recommendation | Ready for Sol re-review |
| IR-07 | No application action generated the first recommendation | Authorized owner can explicitly refresh the recommendation with clear disabled, empty, error, branch and retry states | Ready for Sol re-review |
| IR-08 | Concurrent external refunds could exceed the original sale | Reconciliation serializes per sale and different refund events cannot allocate more than the residual sale value | Ready for Sol re-review |
| IR-09 | Approval did not recheck flags, entitlement, module or policy state | Approval revalidates every execution guard after preview and refuses disabled/stale state | Ready for Sol re-review |
| IR-10 | Scanner retry minted a new idempotency key | Lost-response retry retains one key until terminal receipt/reset and returns the original receipt | Ready for Sol re-review |
| IR-11 | Governed copy could invent eligibility, conditions and CTA facts | Server persists a versioned locked schema for value, expiry, eligibility, conditions and CTA destination; arbitrary copy cannot alter it | Ready for Sol re-review |
| IR-12 | Authenticated intelligence page created multiple `h1` elements | Customer Intelligence renders exactly one page `h1`; embedded revenue/economics sections start at `h2` | Ready for Sol re-review |
| IR-13 | Selected end-date semantics differed between modules | Revenue, lifecycle, economics and drivers share one non-null half-open period and one as-of contract | Ready for Sol re-review |
| IR-14 | Growth records hardcoded SGD | Recommendation, briefing, offer and result currency comes from the effective business currency contract or is suppressed | Ready for Sol re-review |
| IR-15 | Recommendation dedupe ignored amount, member and evidence changes | Dedupe fingerprint includes material amounts, cohort membership/evidence, policy and currency | Ready for Sol re-review |
| IR-16 | Overlapping recommendations could contaminate treatment and holdout | Approval atomically rechecks and reserves members so no live experiment overlaps either arm | Ready for Sol re-review |
| IR-17 | Sector suppressions were descriptive metadata only | Required evidence for each canonical supported sector is enforced; unavailable evidence suppresses the recommendation truthfully; unsupported sectors use the complete `other` fallback and are never marketed as bespoke policies | Ready for Sol re-review |
| IR-18 | Unknown-sector fallback was malformed and unsupported sectors were advertised as reachable | Fallback contains the complete parameter contract; normal onboarding resolves every canonical supported sector; unsupported sectors do not have unreachable bespoke policy claims | Ready for Sol re-review |
| IR-19 | Any reconciliation row could mark a transaction reconciled | Only a matching completed-transaction event and amount can reconcile a native completed sale | Ready for Sol re-review |
| IR-20 | Same-day concurrent refresh was not idempotent | Concurrent identical refreshes converge on one recommendation without a unique-key error | Ready for Sol re-review |
| IR-21 | Idempotency keys were not request-hash bound and pre-lock checks raced | Request and canonical record locks precede mutation; same key plus identical canonical payload returns the immutable first receipt; same key plus changed payload conflicts for every new mutation | Ready for Sol re-review |
| IR-22 | v108/v109 ignored v106 external partial-refund allocations | One shared as-of residual-sale truth feeds recommendations, outcomes, profit/ROI and driver decomposition | Ready for Sol re-review |
| IR-23 | Approval jumped directly to `delivered` without a real delivery lifecycle | Provider-neutral queued, scheduled, delivering, delivered, failed and cancelled states are durable; quiet hours schedule rather than discard; cancel/retry/callback paths recheck every execution guard; versioned 60/300/900/3600-second backoff and five-attempt exhaustion are enforced | Ready for Sol re-review |
| IR-24 | The lifecycle contract aggregated identities but did not implement proposal, proof, approval, rejection or reversal | Identity changes are append-only, evidence-backed, business-scoped, ambiguity-safe and request-hash idempotent; reversal restores prior attribution and has adversarial regressions | Ready for Sol re-review |
| IR-25 | Null and blank monetary inputs were coerced to explicit zero in revenue and governed-copy adapters | `null`, omitted and blank remain unavailable throughout SQL-shaped adapters and never render as `SGD 0.00`; explicit numeric zero remains distinguishable | Ready for Sol re-review |
| IR-26 | Sector registry omitted supported `massage` and advertised clinic/tuition policies normal onboarding could not assign | One canonical taxonomy is used by onboarding, policy resolution and UI; massage resolves correctly; clinic/tuition are either truly assignable or not claimed; `other` has a complete fallback | Ready for Sol re-review |
| IR-27 | The revenue-opportunity range and “confidence” overstated an unversioned 3–10% heuristic | Monetary opportunity is withheld until calibrated outcome evidence exists, or the exact assumption is versioned and disclosed; data-quality confidence is never presented as outcome confidence | Ready for Sol re-review |
| IR-28 | Approved/running executions disappeared from the briefing and latest history ignored branch scope | Owner briefing exposes branch-correct queued/running/delivery/provisional/final states and failures throughout the full lifecycle; no active action vanishes between approval and finalization | Ready for Sol re-review |

## Current verification evidence

> **Independent-review gate:** the four withheld/failed rows from Sol's latest
> 36/40 review now have exact local implementations and regressions. They remain
> unscored
> until Sol reviews the newly frozen candidate; a builder does not approve its
> own work.

- A clean `supabase db reset` applied the complete canonical history through
  v114 after the final reporting-contract timestamp repair.
- Rollback-only SQL acceptance passed for every growth increment from **v106
  through v114** on that clean database.
- True two-session concurrency passed for:
  - v111 approval-first and verified-link-first identity commit orderings;
  - v112 same source/same request, same source/different requests, concurrent
    v108/v109 mutations, and callback/inner-transition receipt replay in two
    consecutive serialized full-harness passes on the final candidate;
  - v113 correction-first and growth-first identity reservation orderings;
  - v114 same-request and changed-payload effective-cost rule races.
- The owner delivery projection now distinguishes ordinary delivery from
  `entitlement_suppressed`, exposes only an allowlisted suppression reason tied
  to the dispatch's current state event, and never exposes provider message
  identifiers. The UI renders the exact owner truth
  **“Message delivered; offer not issued — reason”** and fails closed for an
  unknown reason as **“Message delivered; offer issuance status unavailable”**,
  never as an issued offer.
- The pending-migration preflight bounds each public function to its own header,
  identifies both plain `CREATE` and `CREATE OR REPLACE` `SECURITY DEFINER`
  declarations, parses their identity arguments, and requires an active,
  top-level, exact-overload `REVOKE ALL ... FROM PUBLIC` after that definition.
  Deliberate wrong-role, wrong-overload, split-statement, plain-create,
  revoke-before-drop/recreate and intervening-`app`-function contamination
  fixtures prove incomplete or unrelated clauses cannot produce a false pass.
  Commented text, nested block comments, ordinary literals, dollar-quoted
  bodies and PostgreSQL `E'…'` literals with escaped quotes also cannot spoof
  the revocation proof.
- `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate` passed:
  static quality, runtime configuration, migration manifest, canonical
  materialization, **1,013/1,013 Node tests**, and all six static application
  builds.
- Migration source/deploy mirrors for v106–v114 are byte-identical and
  `git diff --check` passes.
- Local rendered acceptance remains green at 375×812 for overflow, 44 px touch
  targets, reload/deep-link retention, one main landmark, one page heading and
  reduced-motion handling.
- Local browser, database and test evidence does not substitute for a promoted
  build, authoritative provider data, a statistically powered real pilot, or a
  physical-device test.

## Owner-controlled items intentionally left last

1. Production migration and release approval.
2. Real merchant/POS or import reconciliation source and any provider credentials.
3. A real measured pilot with enough treatment/holdout observations to finalize an
   incremental result and unlock additional playbooks.
4. Authoritative product/service cost data needed for profit coverage.
5. Physical iPhone/Android notification, camera, passkey and installed-PWA checks.

Until those rows are completed, Nestly may be described only according to the
latest independent Sol verdict. Local closure never means “100/100
production-proven.”
