# V125 no-GST billing and native-store foundation — local acceptance

Date: 1 August 2026
Branch: `codex/v124-stripe-pricing`
Billing state: `VERIFIED_LOCAL`
Native-store state: `IMPLEMENTED_UNVERIFIED`

## Stripe account handoff

A separate Singapore Stripe account was created for NESTLY TECHNOLOGIES PTE.
LTD. with account ID `acct_1TzKwRLjvwAsL93H`. The onboarding flow verified UEN
`202634502E`, selected recurring payments and invoicing, and left tax collection
disabled. Singpass/MyInfo is complete and Stripe marks representative, owner
and director identity complete. The owner-controlled flow is now at product
classification, followed by public details, statement descriptor, settlement
bank details and final submission. No Stripe secret was copied into the
repository or changed in production.

## No-GST and overdue implementation

- The V125 singleton policy records `gst_registered=false`, disables automatic
  tax collection, and accepts only explicit `exclusive` Stripe Price behavior.
- Catalogue setup and the billing executor verify exclusive provider Prices;
  Checkout sends `automatic_tax.enabled=false` and no default tax rates.
- Existing-subscription mutation and uncertain recovery clear and verify
  automatic tax, subscription defaults and every item tax rate before a
  command can complete.
- Stripe tax normalization is a separate non-pending mutation. Prorated pending
  updates contain no automatic-tax, default-tax-rate or item-tax-rate fields,
  and every subscription mutation is followed by a fresh provider retrieve so
  an idempotent response cannot conceal later external tax drift. That fresh
  state must also match the requested price, quantity and cancel/resume state
  before Nestly records command completion.
- Subscription, invoice, payment-attempt and adjustment tax writes fail closed
  independent of V124 term/event arrival order. Migration preflight aborts on
  historical tax rather than rewriting financial evidence.
- Owner and platform billing readers expose provider totals unchanged and label
  tax as `GST not charged`; they fail closed if a V124 projection contains tax.
- The existing provider-backed lifecycle remains open through overdue day 13,
  pauses the owner workspace at day 14, preserves customer records, and reopens
  after a causally newer paid invoice.

## Native foundation

- Capacitor 8.5.0 projects are generated from the only application source,
  `app/`, under identifier `asia.nestly.app`.
- Android uses compile/target SDK 36, refuses cleartext traffic, disables backup,
  declares camera access and carries the Nestly HTTPS app-link intent.
- iOS targets iOS 15, declares camera purpose, non-exempt encryption status and
  the Nestly associated domain.
- App, Browser, Haptics, Network and Share adapters are bounded behind
  `window.NestlyNativeBridge`; web fallbacks remain authoritative.
- Packaged origins are exact allowlist entries, Turnstile remains
  action/hostname-bound to `localhost`, and outward QR/share/invite links use
  only `https://www.nestly.asia`.
- Business-invite and password-reset email callbacks also resolve through the
  canonical public HTTPS origin rather than a local WebView origin.
- Both bundled HTML entrypoints include the restrictive CSP that Vercel response
  headers cannot supply inside the WebView.
- Default Capacitor icons were replaced with branded Nestly icons.

## Automated and database evidence

- Provider-tax/native focused regressions: PASS — 37/37, including behavioral
  pending-update payload coverage and rejection of fresh tax-clean-but-wrong
  provider state. Combined V124/V125/gateway regressions: PASS — 49/49.
- `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate`: PASS —
  1,348/1,348 tests plus static build on the exact corrected candidate.
- `npm run mobile:sync`: PASS for iOS and Android with five plugins.
- `npx cap doctor`: reports current 8.5.0 dependencies and both native projects
  looking healthy. The command returns a non-zero shell status on this machine
  despite both platform success messages, so it is not treated as a signed-build
  result.
- Fresh PostgreSQL 17 rehearsal: all 165 canonical migrations apply in order.
- `db/tests/v124_stripe_launch_pricing.sql`: PASS and `ROLLBACK`.
- `db/tests/v125_no_gst_and_overdue.sql`: PASS and `ROLLBACK`.
- Post-suite residue: `auth_users=0`, `businesses=0`.

The V125 rollback suite rejects an inclusive catalogue proposal and non-zero
provider invoices both before and after V124 terms exist, verifies zero
tax/total equality in the owner reader, denies an unrelated authenticated user,
and proves day-13 access, day-14 pause, retained customer identity and
provider-paid recovery.

## Browser evidence

The production billing component was executed with realistic V125 provider
projections, not a reimplemented visual:

- 1280×720: annual renders SGD 1,188.00/year, GST SGD 0.00, the legal operator,
  included modules and an enabled secure-checkout button with no overflow.
- 390×844: selecting monthly and 3,000 profiles renders SGD 169.00/month; all
  buttons are at least 44px and `scrollWidth=clientWidth=390`. The existing
  install prompt's `Not now` control dismisses it and leaves secure checkout
  enabled and unobscured.
- The first run exposed 417px overflow from non-wrapping billing-cycle cards;
  the component and regression were corrected before the passing capture.

Artifacts:

- `docs/qa/evidence/v125-browser/public-desktop-1280.png`
- `docs/qa/evidence/v125-browser/billing-desktop-1280.png`
- `docs/qa/evidence/v125-browser/billing-mobile-390.png`

Initial review reproduced Turnstile code `110200` because the production widget
does not yet allow `localhost`. The corrected code is fail-closed and requires
that exact hostname before device acceptance. The isolated production billing
component reports no page errors.

## Remaining release and publication gates

This evidence does not make V125 production-ready or store-ready. Still needed:

1. Owner completes Stripe product/public/statement details, settlement-bank
   verification and final submission.
2. Live Stripe Products/Prices, webhook/reconciliation secrets and provider
   event acceptance are configured under a reviewed V125 release.
3. Full Xcode, Java and Android SDK toolchains build signed archives.
4. Apple Developer/App Store Connect and Google Play Console teams provide
   signing, hosted link association, privacy/support metadata and screenshots.
5. Physical iPhone and Android acceptance covers authentication, deep links,
   camera denial/retry, offline/reconnect, background/resume and update.
6. Sol accepted the exact corrected candidate and the owner subsequently
   approved V125 commit, push, reviewed migration and deployment on 2026-08-01.
   Production execution and post-release evidence must still be recorded.

At the time of this pre-release evidence capture, no V125 commit, push,
production migration, production secret change or deployment had occurred.
