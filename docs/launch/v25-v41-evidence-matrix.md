# Frenly v25-v41 Completion Evidence Matrix

Date: 2026-07-20 (Asia/Singapore)
Verdict: CHANGES REQUIRED

Evidence states:

- `PROVEN_LOCAL`: direct local evidence covers the stated behavior.
- `IMPLEMENTED_UNPROVEN`: implementation exists, but runtime or journey evidence is missing.
- `CONTRADICTED`: current source directly conflicts with the requirement.
- `MISSING`: no implementation evidence exists.
- `OWNER_GATE`: requires an operational owner decision or external system.

Static source-pattern tests never promote a runtime behavior to `PROVEN_LOCAL` by
themselves.

## Configuration and imports

| Requirement | Current evidence | State | Closure evidence |
|---|---|---|---|
| Required module dependency graph | v24b registry, owner RPC, settings explanation, Node tests | IMPLEMENTED_UNPROVEN | Runtime enable/disable and transitive dependency tests with owner/staff/foreign principals |
| Redemption idempotency | v24a operations and retry keys; structural tests | IMPLEMENTED_UNPROVEN | Concurrent same-key replay and changed-payload conflict on disposable DB |
| Atomic backend imports | v24c owner jobs, tenant-bound rows, advisory commit lock, UI upload controls | IMPLEMENTED_UNPROVEN | Runtime rollback, two-session concurrency, malformed/cross-tenant CSV, and all six entity journeys |
| Draft-first onboarding | v25 inactive draft and explicit publish UI | IMPLEMENTED_UNPROVEN | Fresh-business runtime test proving no earn/redeem before publish |
| Immutable program/reward/tier versions | v26-v27 tables, guards, hashes, projection; direct live writes revoked | IMPLEMENTED_UNPROVEN | Full-chain publish/concurrent sale/rollback-as-new-version suite |
| Draft reward eligibility preserved | v36 exact-version owner RPC, stable reward IDs, row locks, mandatory stale-hash protection, fail-closed editor state, and browser preservation tests | IMPLEMENTED_UNPROVEN | Execute the v36 multi-principal, stale-write, publish, and read/save-vs-publish SQL cases on the restored disposable chain |
| Editable rich reward catalog | Reward editor and draft save exist | IMPLEMENTED_UNPROVEN | Runtime create/edit/archive/eligibility/publish and historical redemption stability |
| Editable reward taxonomy | Add and retire foundations exist; behavior kind immutable | IMPLEMENTED_UNPROVEN | Runtime rename/sort/retire, historical grant snapshot, and owner/foreign denial |
| Versioned retention programs | v37b local implementation: every pre-v37 config receives the formerly global live rules; draft/hash/publish/rollback uses typed versions; grants snapshot immutable real periods and stable-program/customer overlap locking prevents remint across publications; taxonomy labels remain serialized live display metadata | IMPLEMENTED_UNPROVEN | Execute the authored rollback suite and business-row sale/publish race harness on an approved disposable production-equivalent database |
| Branch overrides editable | v37 owner-only save/remove draft RPCs, same-business and hash validation, inherit/override UI, and shared resolver preview are present | IMPLEMENTED_UNPROVEN | Execute branch precedence, removal, stale-hash, principal, and cross-tenant SQL cases on the restored disposable chain |
| Typed custom customer fields | Definition/value tables and owner UI exist | IMPLEMENTED_UNPROVEN | Runtime type, option, classification, cross-tenant, archive, and customer exclusion tests |
| Explainable recommendation draft | v35 uses industry/catalog aggregates and creates inactive editable draft | IMPLEMENTED_UNPROVEN | Runtime idempotency, changed-input conflict, no auto-publish, and draft-editor journey |

## Customer identity and wallet

| Requirement | Current evidence | State | Closure evidence |
|---|---|---|---|
| Separate customer identity | v30 auth-bound identity and verified-contact evidence | IMPLEMENTED_UNPROVEN | Runtime customer/staff/dual-role and contact-proof adversarial suite |
| Secure exact-email and invitation claims | v31 RPCs and append-only claim evidence | IMPLEMENTED_UNPROVEN | Runtime duplicate/no-enumeration, expiry, replay, theft, unlink, and cross-firm suite |
| Customer identity/claim UI | v38 implements `/#/claim`, identity start, email/invitation claim, token scrubbing, generic outcomes, and retry states | IMPLEMENTED_UNPROVEN | Complete authenticated loading/success/generic-failure/retry/mobile journeys with synthetic users |
| Server-derived personas | v38 adds the authenticated allowlisted `get_my_personas` resolver and route-context persona switcher without privilege union | IMPLEMENTED_UNPROVEN | Execute customer-only, staff-only, dual-role, inactive-membership, and cross-tenant SQL/browser cases |
| Signed-in state on direct portal | v38 adds optional signed-in portal context while retaining the public Turnstile gateway path | IMPLEMENTED_UNPROVEN | Verify guest and signed-in desktop/mobile journeys plus unchanged Turnstile, origin, rate-limit, and public-field boundaries |
| Per-firm wallet isolation | v32 cards are separate and raw tables remain closed | IMPLEMENTED_UNPROVEN | Runtime Customer A/B, slug substitution, staff-only, and dual-role suite |
| Rewards and loyalty activity | v39 adds auth-derived, allowlisted catalog/activity RPCs, bounded cursors, expiry state, counter-claim UI, and independent section retries | IMPLEMENTED_UNPROVEN | Execute v39 rollback suite on the restored full chain, then run authenticated desktop/mobile customer journeys |
| Package and membership detail | v39 adds customer-safe plan/session/expiry/usage and membership-period RPCs with data-aware module hiding | IMPLEMENTED_UNPROVEN | Execute v39 package/membership fixtures against the restored historical v5-v6 schemas and complete browser journeys |
| Appointment actions | v33 immutable request and notification outbox foundations; UI behind disabled flag | IMPLEMENTED_UNPROVEN | Runtime ownership, replay/conflict, staff receipt, opt-out, and browser journey |
| Relevant modules only | v39 capability resolver is module- and data-aware; SPA creates only relevant Book/Rewards/Activity/Packages/Membership/Appointments sections, rechecks race-empty sections, and has a wallet-level empty/retry state | IMPLEMENTED_UNPROVEN | Empty-capability and each-industry authenticated mobile rendering tests |
| Customer email OTP | No customer OTP UI; SMTP intentionally deferred | OWNER_GATE | Production SMTP, sender auth, Turnstile, rate limits, recovery and mailbox evidence |
| Customer feature enablement | v38 replaces normal routing decisions with private server-derived capability/persona gates; operational email OTP and customer actions remain deliberately fail-closed | OWNER_GATE | Enable only after SMTP, sender authentication, Turnstile, rate-limit, monitoring, recovery, and support ownership gates close |

## Financial correction and module integration

| Requirement | Current evidence | State | Closure evidence |
|---|---|---|---|
| Append-only package reversal | v34 provenance and wrapper exist | IMPLEMENTED_UNPROVEN | Runtime exact replay/conflict, expiry/later-use refusal, and zero-payment proof |
| Append-only loyalty reversal | v34 provenance, FEFO drains and compensation exist | IMPLEMENTED_UNPROVEN | Runtime spent-credit, legacy provenance, config-version, and ledger=batch suite |
| Staff reversal workflow | v40 adds an authenticated bounded reversal read model with validated `all`/`package` modes, exact accessible-row counts and partial-result disclosure; hardens loyalty compensation by immutable selected-branch scope; and wires confirmed reason/reference/idempotency flows exclusively to `reverse_sale` and `reverse_loyalty_redemption`. Package no-refund, provenance refusal, completed result, replay, and conflict states are rendered | IMPLEMENTED_UNPROVEN | Execute v20-v22, v34, and v40 rollback suites on the restored chain; complete owner/manager/restricted/inactive/customer/anon browser journeys |
| Inventory drawdown linked to appointments/sales | Existing completion trigger and inventory tables predate phases | IMPLEMENTED_UNPROVEN | End-to-end appointment completion, exact FEFO drawdown, reversal/restock policy evidence |
| Reports reflect reversals and immutable config | v40 sales/customer/package histories show original↔reversal links and the same relationship net on both sides; Reports/Daily Report and RFC4180 CSV exports use signed rows, relationship IDs, reversal reasons, and relationship net values. Daily Report uses complete paged reads with exclusive SGT bounds | IMPLEMENTED_UNPROVEN | Execute SGT range/pagination reconciliation against runtime rows and compare report totals, CSV signed sums, payments, ledgers, and batches |
| Transactional customer modules | v41 replaces split client/consent/referral and gift-card issuance writes with authenticated, serialized, hash-bound RPCs; removes browser raw writes; and exposes bearer-safe bounded gift-card lists | IMPLEMENTED_UNPROVEN | Execute both v41 rollback suites on the restored canonical chain, including forced event failure, exact replay/conflict, cross-tenant, inactive/restricted/anon, and card/sale reconciliation cases |
| Till customer privacy boundary | v41 forward-hardens `lookup_client_by_phone` and `record_sale_by_phone` with effective clients-read plus create-sales authorization; same-key Till sales serialize and changed stored sale fields conflict | IMPLEMENTED_UNPROVEN | Runtime prove r/rw/absent-key cases. P1 debt: a valid legacy Till replay reports the current points balance, not an immutable response-time balance snapshot |
| Tier multiplier uses one configuration | Business row locks serialize sale/publish; resolver still reads live projection | IMPLEMENTED_UNPROVEN | Version-aware resolver and v1/v2 multiplier regression test |

## Security and verification

| Requirement | Current evidence | State | Closure evidence |
|---|---|---|---|
| No anon/PUBLIC SECURITY DEFINER execution | v21 allowlists and static catalog assertions | IMPLEMENTED_UNPROVEN | Runtime all-schema catalog check after full v41 chain |
| Customer/staff policy separation | RPC checks and adversarial SQL files exist | IMPLEMENTED_UNPROVEN | Execute every multi-principal suite on disposable production-equivalent DB |
| Full executable migration chain | v3-v7, v14 adjuncts, and v15 are represented by note files | CONTRADICTED | Restore exact executable migrations or create reviewed immutable schema baseline |
| SQL behavioral evidence | v25-v35 rollback files exist but were not executed against full chain | MISSING | Disposable DB apply-once plus every v20-v41 rollback and concurrency suite |
| Browser journey evidence | File URL automation was blocked; no accepted authenticated journey run | MISSING | Supported local/preview browser run across desktop and mobile with synthetic users |
| Static validation | Independent local run: full `npm run validate` 192/192 and five-page build pass; focused v28/v37/v39 20/20; v40 financial-integrity 17/17; v37/v40 shell syntax and `git diff --check` pass | PROVEN_LOCAL | Preserve exact command output as local source/static evidence; this does not replace runtime SQL or browser evidence |
| Production launch manifest | 17 P0 gates remain blocked | OWNER_GATE | Hash-pinned evidence and named owner acceptance for every gate |

## Acceptance rule

Sol may accept a source/static implementation slice while clearly retaining its
`IMPLEMENTED_UNPROVEN` runtime classification. Full v41 acceptance requires every
in-scope row to become `PROVEN_LOCAL` or to be an explicit external `OWNER_GATE` that
remains fail-closed. No `CONTRADICTED`, `MISSING`, or `IMPLEMENTED_UNPROVEN` row may
remain in the full v41 acceptance scope.
