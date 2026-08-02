# V144 self-service subscription consent acceptance

Date: 2026-08-03
Branch: `codex/v144-self-service-subscription-consent`
Scope: owner signup consent, legal-page return, honest empty catalogue state,
prospective subscription refund policy, and provider-paid activation evidence.

## Reproduction and root cause

The owner screenshot was reproduced as the existing fail-closed branch of
`get_self_serve_checkout_v130`: the browser receives no complete sellable
combination when the Stripe annual/monthly catalogue or the published
Loyalty-capable sector list is empty. The UI did not request management
approval. It correctly refused to create a workspace or charge, but the prior
message did not tell the owner what configuration was missing.

V130 already stages a workspace only after an authenticated owner selects an
exact sector, cadence and capacity, creates a hosted Stripe Checkout command,
and opens access only after the matching provider-paid invoice. V144 preserves
that authority and makes the empty state actionable. Publishing the real Stripe
catalogue is an external production operation and is not simulated by this
candidate.

## Observable result

- Signup says **I agree to the Terms of Service and acknowledge the Privacy
  Policy**. It does not claim that the owner read either document.
- Terms and Privacy are visibly underlined, independently openable links. The
  checkbox can be selected without opening either link.
- Both legal pages show a 44px **Back to owner account creation** action targeting
  `/business?signup=1`; the normal browser Back action remains available.
- New Terms accepted on or after 3 August 2026 say subscription fees are
  non-refundable after payment, subject to mandatory law or an express written
  Peekaa exception. Earlier earned written refund windows remain unchanged.
- New-policy paid invoices create immutable first-paid evidence and activate the
  self-service workspace once. They do not create a money-back window.
- An empty/incomplete Stripe catalogue explains the missing annual/monthly plan
  or sector, creates no workspace or charge, and offers retry/support actions.

## Automated and database evidence

- Red-first regression: `tests/business-ui/v144-self-serve-consent.test.mjs`
  failed 5/5 before implementation, then passed 5/5.
- Current auth/onboarding regressions pass, including V130, V135 and V138.
- Canonical and planning migration manifests pass with 175 canonical entries and
  173 planning entries.
- Fresh local PostgreSQL 17 rehearsal applied all 175 canonical migrations.
- `db/tests/v130_self_serve_business_onboarding.sql`: PASS / ROLLBACK. It proves
  the exact Stripe-paid invoice opens one workspace using V144 first-paid
  evidence, rejects mismatched provider states, and replays without duplication.
- `db/tests/v144_self_serve_subscription_consent.sql`: PASS / ROLLBACK. It proves
  exact legal hashes, the new default, immutable historical refund-window
  persistence, immutable new first-paid evidence, no manufactured new refund
  window, RLS and browser-role denial.
- Post-suite residue: `public.businesses=0`, `auth.users=0`.
- Complete repository validation passed: static quality, runtime configuration,
  migration manifests, canonical materialization, **1,443/1,443 automated
  tests**, and the static production build.
- Existing V104, V105, V129, V130 and V131 source-bound visual fixtures were
  regenerated from the current application source; the V104 Chrome metrics and
  desktop/390px/412px captures were refreshed and pass their exact source-hash
  checks.

## Browser evidence

`tests/browser/verify-v138-business-google-auth.mjs` passes the real current
signup renderer at 390px: one signup-only checkbox, exact 2026-08-03 legal
hashes, no unchecked OAuth departure, no login checkbox, and no horizontal
overflow.

`tests/browser/verify-v144-self-serve-consent.mjs` passes Terms and Privacy at
1440px and 390px, including 44px return target, exact return URL, prospective
policy copy and zero outer overflow. Screenshots:

- `v144-self-serve-consent-browser/terms-desktop-1440.png`
- `v144-self-serve-consent-browser/terms-mobile-390.png`
- `v144-self-serve-consent-browser/privacy-desktop-1440.png`
- `v144-self-serve-consent-browser/privacy-mobile-390.png`

## Remaining boundary

This is local candidate evidence, not production proof. Before the screenshot's
registration journey can accept real money, an independently accepted V144 must
receive owner release approval, the reviewed migration/web app must be released,
and the real Stripe catalogue/webhook must be configured and verified with a
live-safe test. No production state was changed during this work.
