# V124 Stripe launch pricing — local acceptance

Date: 1 August 2026
Branch: `codex/v124-stripe-pricing`
State: `VERIFIED_LOCAL` — not production or live-Stripe evidence

## Accepted local contract

- Annual is selected by default: SGD 1,188 collected per year (SGD 99/month equivalent).
- Monthly is SGD 149/month. SGD 168/month is comparison metadata only.
- 1,000 customer profiles are included; every selected extra block of 1,000 is SGD 10/month or SGD 120/year.
- Staff access is included and never changes the price. V124 exposes customer-capacity increases only.
- The owner sees the exact recurring total, included modules, exclusions, template-assisted promotion wording, Stripe Checkout/portal actions, and the legal operator before provider redirect. V145 clarifies that the shipped helper is deterministic and is not generative AI.
- The earliest successful paid Stripe invoice for the matching V124 provider subscription fixes one exact 30-day money-back request deadline. A matching historical invoice is backfilled; an unrelated legacy renewal cannot create a new window. Later invoices, cadence/capacity changes, cancellation, or reactivation cannot move it forward.
- A prorated plan change with a Stripe `pending_update` remains `uncertain`, never `completed`; exact-command recovery can complete only after provider items match and the pending update clears.
- A complete processed Stripe subscription snapshot removes local provider items omitted by Stripe, so a deleted capacity add-on cannot remain projected.
- The owner browser keeps one request key and command ID for the same selected billing intent across lost-response retries and never claims that an ambiguous provider call left the subscription unchanged.
- Terminal failed/canceled commands render an explicit failure and clear the finished attempt; they are never described as successfully submitted.
- Every price-bearing command snapshots the exact catalogue row. Recovery continues to use those original provider price IDs after a later catalogue rollover, and an uncertain increase can recover after its webhook has projected the requested capacity.
- Terms and Privacy are published as version `2026-08-01` with exact SHA-256 manifests while prior acceptance/marketing-consent evidence remains valid.

## Automated evidence

- `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate`: PASS — 1,339/1,339 tests and six static pages built.
- Fresh PostgreSQL 17 rehearsal: PASS — all 164 canonical migrations applied in order.
- `db/tests/v124_stripe_launch_pricing.sql`: PASS and `ROLLBACK`.
- The rollback suite proves 1,000/3,000 pricing, request replay/conflict, one-command catalogue snapshots across rollover, uncertain recovery after equal provider projection, five staff with no seat charge, 1,000-profile enforcement with profile 1,001 denied, no decrease through a cadence change, authoritative stale-item deletion, legacy-invoice exclusion, matching-subscription backfill, and the exact first-paid deadline.
- Stripe reconciliation compares subscription status, renewal facts, price IDs, and capacity quantities; a price/quantity drift is a mismatch.
- The guarded Stripe catalogue setup script is idempotent and refuses mutation without `--apply`; it additionally refuses a live key without `--allow-live`.

## Browser evidence

- Desktop 1280×720: the local root, Privacy, and Terms pages load with meaningful content, no framework overlay, no horizontal overflow, and working policy navigation. Terms visibly contain monthly/annual pricing, customer capacity, staff inclusion, and the 30-day request wording.
- Mobile 390×844: Terms and Data Request have `clientWidth = scrollWidth = 390`; navigation wraps; the legal email action is present; no browser console errors occur on the policy pages.
- The root login fails closed on localhost when Cloudflare Turnstile rejects the unregistered local origin (`110200`); the Sign in action remains disabled and an explicit Retry security check control is shown.

## Evidence still required before release or closure

- An authenticated target owner session for the Settings checkout UI at desktop and 390px.
- Stripe test-mode product/Price creation, Checkout completion, webhook projection, portal return, proration, failed payment, refund, chargeback, lost-response, and reconciliation evidence.
- A subsequent owner `RELEASE APPROVED: V124 ...` instruction.
- Authorized production migration/deploy, live Stripe catalogue mapping, production smoke, monitored mailbox test, formal DPO/counsel gates, and any tax-registration decision.

No production migration, Stripe account mutation, secret change, commit, push, or deployment occurred during this local acceptance.

## Independent-review history

Sol rejected the first V124 candidate on 1 August 2026 for five release blockers: false completion while Stripe payment confirmation remained pending, a cadence-command capacity-decrease bypass, stale deleted Stripe items, legacy-unsafe money-back capture without backfill, and non-durable browser retry keys. Follow-up review then found exact recovery blocked after equal webhook projection, false success copy for terminal commands, and catalogue rollover risk. Each finding received a failing regression before correction. Sol subsequently accepted the exact corrected local candidate with no remaining in-scope code blocker and confirmed eligibility for a later V124-specific owner release approval. The authenticated target/provider and governance limits above remain open, so this is still `VERIFIED_LOCAL`, not closed or production proof.
