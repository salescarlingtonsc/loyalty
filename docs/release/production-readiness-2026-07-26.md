# Nestly production-readiness ledger — 2026-07-26

## Current verdict

The workspace is a **local release candidate under construction**, not an
approved production release. Product implementation can be complete locally
while the governed production gate remains blocked. `node
scripts/launch-readiness/check.mjs` is the authority for that distinction: all
17 P0 items require hash-pinned staging/production evidence and independent Sol
acceptance. Source code and static tests cannot manufacture that evidence.

Sol accepted the exact corrected V125 candidate on 2026-08-01, and the owner
subsequently approved its commit, push, reviewed migration and deployment in
the same task. That approval is limited to V125; it does not convert unresolved
launch or store-publication rows into production proof and does not authorize
inventing missing Stripe, Apple or Google credentials.

## Product requirement coverage

| Requirement | Local implementation | Release proof still required |
| --- | --- | --- |
| Equal customer/business entry | Top-level chooser, persistent customer navigation, dual-role switching and customer home | Customer-only, business-only and dual-role browser acceptance on final build |
| Mobile OTP | Singapore normalization, fresh server capability checks, hosted provider transport and no production fixed-number bypass | Remove hosted test OTPs, verify Twilio/Turnstile settings and complete a real-device final-origin smoke |
| Customer/business synchronization | Relationship claim, booking identity/lifecycle, wallet/history projections and customer-safe readers | Applied migrations plus real-role cross-tenant and two-session sync tests |
| Customer history | Sales, points, rewards/value, visits, bookings, messages and corrections are exposed through bounded customer readers | High-volume pagination and final mobile browser acceptance |
| Fast sale correction | Double-confirm compensating correction without a minimum reason length | Financial replay/rollback and owner/manager/front-desk permission run |
| Staff names and module permissions | Display names, explicit per-staff module modes and inherited sector entitlements | Applied database permission matrix |
| Sector cookie-cutter modules | Super-admin sector templates; firm owners can only change staff allocation, not sector truth | Super-admin/owner denial matrix on rehearsal |
| Super-admin enterprise view | Firms, branches, customers, operational intelligence and scoped report surfaces | High-volume report accuracy and export acceptance |
| Owner customer intelligence | Returning customers, frequency, revenue per customer, history and confidence-banded three-month projection | Rehearsal data reconciliation and sparse/dense cohort acceptance |
| SME onboarding CRM | 17 stable stages, history, activities, conversion/onboarding core and enterprise completion phase | Disposable DB rollback suite and complete browser Kanban/import/detail acceptance |
| Private SME documents | Private 25 MiB vault, actor-bound one-time signing exchange, browser upload, server-observed size/SHA-256 finalization and short-lived reads | Clean-install bucket check plus upload/read/expiry acceptance with an authorized and unauthorized actor |
| Recurring Nestly billing | Quarterly, half-yearly and annual Stripe projections; webhook-paid truth and next-payment state | Stripe test-mode events, secret/config evidence and final webhook delivery |
| Payment automation | Scheduled bidirectional provider-vs-Nestly subscription/invoice reconciliation: two local keysets whose membership is pinned by `created_at <= snapshot` plus two bounded Stripe `starting_after` streams, durable partial-run cursors, scoped `missing_local`/`missing_provider` evidence and clean only after all four streams complete. The snapshot pins membership only; subscription and invoice state comparisons intentionally use the current/live values read during reconciliation. Command persistence uncertainty is retryable against the same Stripe idempotency evidence, while Billing Portal recovery explicitly replays session creation | Deploy worker, configure secret schedule, complete an entire reconciliation cycle with final `clean` (never `partial`) and exercise uncertain-command recovery |
| Consultant commission | Senior 30% base + deferred 10%; junior 20% + deferred 5%; 15%/5% renewals; GST excluded; refund/chargeback adjustments; setup fee included | Disposable SQL lifecycle run and finance acceptance |
| Installable mobile app | Manifest, icons, iOS Home Screen metadata, standalone safe areas, update UX and public offline fallback | HTTPS device install/update/reconnect run on current iOS Safari and Android Chrome |
| Native-store readiness | One-source Capacitor iOS/Android projects, pre-publication `asia.peekaa.app` identifier, Android API 36 target, Peekaa iOS/Android link declarations and icons, and bounded Network/Haptics/Share/Browser/App adapters | V134 changed the unpublished store identity before signing. Signed archives, verified `peekaa.asia` association files, Apple/Google teams, physical-device runs, store metadata and review remain required |

## Commission interpretation implemented

First-year paid SaaS invoice cash excluding GST creates two immutable
components:

- senior: 30% base eligible at payment and 10% service-anniversary component;
- junior: 20% base eligible at payment and 5% service-anniversary component.

The anniversary component is forecast immediately but cannot be approved until
12 months after onboarding, the consultant is still active, and the customer
has completed the paying year. For Stripe, the latter requires normalized paid
invoice evidence at or after the anniversary; manual billing requires an active
subscription. Renewal invoices at or after the anniversary use 15% senior and
5% junior. Refunds and chargebacks append proportional negative adjustments to
all components. Previously paid history is retained; negative adjustments
remain visible for recovery/netting.

## Mobile delivery boundary

The first delivery is an installable web app. Authenticated documents and API
responses are never cached by the service worker. Failed navigation uses a
self-contained public offline screen, because the live application cannot
truthfully operate without current server data.

The App Store/Play Store phase was activated by the owner on 2026-08-01 and
must reuse `app/` as the only web source.
It must add native identifiers, verified universal/app links, signing,
permission copy, secure credential handling and physical-device acceptance.
Those store-specific assets are intentionally not represented as complete now.

## Required release sequence

1. Finish local feature, static, build and migration-source validation.
2. Materialize one canonical migration chain and pin the exact source hash.
3. Replay that chain on a disposable Supabase-compatible database and run every
   v72+ rollback/concurrency suite.
4. Run responsive browser acceptance for owner, manager, front desk,
   customer-only, dual-role and super-admin journeys.
5. Obtain Sol's independent review and close every code finding.
6. Under owner release approval, apply database changes before dependent
   frontend/functions.
7. Configure hosted OTP, Stripe, scheduler, SMTP/comms, alerting and runtime
   origins/secrets without placing secrets in source. Follow
   `docs/release/owner-dashboard-environment-steps-v89.md`; production Auth must
   not retain a fixed test OTP.
8. Run final production smoke, reconciliation, backup/rollback and evidence
   capture. Only then may the launch gate move from `BLOCKED`.

## Stop conditions

Do not call the app production-ready if any of these are true:

- a required migration exists outside the canonical chain;
- the full Node/build suite is not green;
- disposable SQL replay/rollback has not run;
- customer/business sync or role journeys are unproven in a browser;
- the complete Stripe reconciliation cycle is `partial`, `mismatch`, `failed`, or otherwise not finally `clean`;
- the final hosted Auth/demo account is unproven;
- any P0 launch blocker is not `VERIFIED_PRODUCTION`;
- Sol has not accepted the completed phase.
