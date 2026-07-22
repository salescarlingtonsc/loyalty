# Frenly production-readiness review — 2026-07-22

## Verdict

Frenly is **not production-ready today**. The independent launch gate is the authority: all 17 P0 controls remain `BLOCKED` because no hash-pinned production evidence has been accepted. Local implementation quality and passing tests do not override that gate.

The competitive audit's central conclusion is sound: Frenly's database integrity is ahead of its live product composition and release discipline. The immediate priority is one provable release, not more feature breadth.

## Corrections and new evidence

### Gift Cards

The current production database contract is healthy:

- `staff_list_gift_cards(uuid, integer)` is owned by `postgres`, is `SECURITY DEFINER`, and has a pinned search path.
- `authenticated` can execute the RPC; `anon` cannot.
- authenticated clients cannot select the underlying `gift_cards` table directly.
- the RPC enforces the module-read boundary.
- an authenticated owner browser check successfully loaded the Gift Cards page and its bounded card list.

The audit's observed `permission denied for table gift_cards` message was real, but it is not reproducible against the present Gift Cards RPC contract. The alert remained in the accessibility live region after a successful route change, which made a historical failure look current. Do not weaken table grants to hide it.

### Billing

A separate live Settings failure is reproducible and has an exact catalog cause:

- `public.v_business_billing` is a `security_invoker` view and is selectable by `authenticated`.
- the view calls `app.billable_seats(uuid)`.
- `app.billable_seats(uuid)` is not executable by `authenticated`.

Directly granting the internal function would expose an unsafe primitive. The approved remediation pattern is a tenant-authorized public RPC that validates the caller, executes with a pinned search path, returns only the permitted business projection, and keeps the internal function private.

### Release truth

The production frontend and production database are not a coherent release:

- live index SHA-256: `8b58c625d97ea524a81ca36e7deacec1e1f2e0ce16b8e2e5a3276c201a6bc8c9`
- live `Last-Modified`: `2026-07-21 13:21:27 UTC`
- the live artifact has no `/api/build` identity endpoint and does not match the current feature branch or `origin/main`.
- the live frontend lacks v48 appointment rescheduling, Quick Earn, the current Cloudflare `connect-src`, and current route cleanup while the database migration ledger includes v48.
- the live browser console still records Turnstile widget-cleanup warnings.

This frontend/backend skew is a P0 release failure. A release is not identifiable merely because a deployment URL responds.

### Supabase advisors

The read-only production advisor snapshot is not clean and must be triaged before release:

- security: 161 notices — 47 informational `RLS enabled/no policy` findings and 114 warnings about executable `SECURITY DEFINER` functions;
- performance: 368 notices — 261 unindexed foreign keys, 19 unused indexes, 87 multiple-permissive-policy warnings, and one Auth connection-strategy notice.

These counts are not equivalent to 114 confirmed vulnerabilities or 368 required launch fixes. Some no-policy tables are intentionally RPC-only, and many definer functions are deliberate guarded transaction boundaries. Each warning nevertheless needs catalog-backed classification as accepted-by-design, corrected, or launch-blocking. In particular, the anonymously executable phone-OTP capability function and every authenticated definer function must be checked for exact grants, pinned search paths, caller authorization, and bounded output. Performance warnings need workload-based prioritization; the high unindexed-foreign-key count is a credible scale risk.

## Local Phase 0 remediation

The local remediation package adds:

1. A fail-closed `/api/build` endpoint that exposes only a validated commit SHA and environment.
2. Visible build identity in authenticated and public UI surfaces.
3. Static contracts for release identity, Gift Cards ACL boundaries, route mapping, and the full canonical role matrix.
4. A corrected launch runbook that treats the immutable v1-v49a, 77-file canonical manifest as the deploy-order authority.
5. An active-owner-authorized Billing read boundary aligned with owner-only Settings, plus a generic retryable UI failure state (v49), without granting clients access to the internal seat-count function.

No item above is production evidence until the exact reviewed commit is deployed and verified.

## Launch gate status

Current result: **0/17 P0 controls closed**.

The owner must supply business decisions for:

- cutover ownership and maintenance window;
- PDPA operating owners and privacy-contact process;
- commercial model: manual invoicing or an integrated payment processor;
- initial launch scope, including whether Gift Cards is included.

Controlled provider or production checks are still required for public abuse resistance, booking-token lifecycle, real-principal RLS, financial rollback, reporting scale, Auth/SMTP, notifications, backup restore, observability, Singapore-time boundaries, credential rotation, and post-cutover smoke.

## Smallest safe pilot scope

The first production pilot should include only:

- owner/staff authentication;
- customers, services, branches, and v48 appointments;
- Quick Earn with manual tender;
- core loyalty and retention;
- bounded reports;
- Gift Cards only after the authenticated owner/manager/staff/front-desk/read-only/denied matrix passes on the deployed artifact.

Do not advertise or expose public booking, outbound notifications, customer phone/WhatsApp registration, subscriptions, storefront payments, or automated refunds until their providers and evidence gates pass.

## Gap-closing sequence

1. Finish and independently review the Phase 0 local remediation.
2. Run the complete local validation suite and manifest checks.
3. Freeze a candidate commit and record its SHA.
4. Apply the exact canonical migration chain to an isolated rehearsal environment.
5. Run real-principal desktop and 390px mobile matrices for owner, manager, staff, front desk, bookkeeper, customer, dual-role, and denied identities using synthetic data.
6. Rehearse rollback, backup restore, public abuse, booking-token, finance, reporting, Auth, notification, observability, and SGT boundary cases.
7. Deploy the same immutable commit through the repository's approved Git-connected release path.
8. Verify served HTML, CSP, `/api/build`, database ledger, and provider configuration against that SHA.
9. Capture redacted hash-pinned evidence for every blocker and obtain independent Sol acceptance.
10. Release only when `node scripts/launch-readiness/check.mjs` prints `Launch gate: PASS` and the owner gives the applicable release approval.

## Competitive path after stabilization

Once Phase 0 passes, close the product gap in this order:

1. Replace entity-heavy navigation with role-based workspaces: Front Desk, Deliver Service, Checkout, and Owner Review.
2. Turn public booking into a short availability-first flow with progressive disclosure.
3. Build a guided retention-program composer around repeat-visit outcomes, not database concepts.
4. Connect visit, appointment, checkout, loyalty, retention, referral, membership, and customer-wallet journeys.
5. Add measured UX gates: task completion, time to first program, booking completion, return rate, reward liability, and support-error rate.

Frenly should differentiate through provable retention outcomes, transparent customer value, and safe money/loyalty ledgers—not by copying the broadest competitor feature list.
