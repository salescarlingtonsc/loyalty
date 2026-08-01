# V134 Peekaa branding and Stripe setup evidence

Date: 2026-08-02  
Branch: `codex/v134-peekaa-stripe-branding`  
Base: `d993624` (`origin/main`)  
State: `VERIFIED_DATABASE` for the V134 application/migration candidate;
live Stripe remains `REPRODUCED`

## Owner instruction

The owner supplied a new logo and selected the product name **Peekaa**, public
domain `peekaa.asia`, and monitored mailbox `admin.peekaa@gmail.com`. The owner
also requested help completing Stripe and offered to control Google Chrome for
identity, OTP, representative and bank steps.

The legal merchant remains **NESTLY TECHNOLOGIES PTE. LTD. (UEN 202634502E)**.
This phase does not rename the registered legal entity.

## Reproduction

The unmodified production source at `d993624` contained the visible product
name “Nestly” in 373 repository files, `nestly.asia` in 27,
`nestlyasia@gmail.com` in 10, and the unpublished native identifier
`asia.nestly.app` in 14. The web, PWA, iOS and Android assets were the old
brand. The active production Stripe catalogue remained empty, so the existing
owner checkout could not create a provider checkout session.

The supplied master is a 1254×1254 opaque RGB PNG. Its SHA-256 digest is
`4d9b6b9db64ede6d5366d5765402594aa16c71148c124c08dd13da74b25773f1`.

## Implemented local change

- one immutable runtime brand contract now projects **Peekaa**,
  `https://www.peekaa.asia`, `admin.peekaa@gmail.com`, and the new asset paths;
- public, auth, share, legal, install, offline, push and current platform copy
  use the new identity while the legal operator and UEN remain exact;
- the PWA manifest, favicon, Apple touch icon, service-worker cache and install
  metadata use the Peekaa artwork;
- the unpublished native identity is consistently `asia.peekaa.app`, with
  Peekaa display names, app icons, splash screens and association domains on
  iOS and Android;
- legacy globals, persisted keys, Stripe lookup keys and migration names remain
  compatible; exact old public origins remain only as temporary redirect/CORS
  compatibility while the domain transition is completed;
- the Stripe catalogue bootstrap presents Peekaa but preserves the reviewed
  recurring contract: SGD 149 monthly, SGD 1,188 annually, SGD 10 monthly or
  SGD 120 annually per extra 1,000 customers, exclusive tax behavior, no staff
  charge, and no GST collection by the application;
- the setup utility remains mutation guarded by `--apply`; live mode additionally
  requires `--allow-live`, and provider secrets are read only from the process
  environment;
- V134 adds a paired legal-document migration because the public Terms and
  Privacy bytes changed. It preserves historical acceptances and recognises
  both the prior and current consent-document hashes. The migration was applied
  only to a disposable local rehearsal database and rolled back by its acceptance
  suites; production was not changed.

Changing the relying-party domain means passkeys enrolled for `nestly.asia`
cannot be transferred to `peekaa.asia`. Existing users must first sign in with
password/OTP and enrol a new Peekaa passkey after the new domain is active.

## Asset inventory

| Asset | Dimensions / constraint | SHA-256 |
| --- | --- | --- |
| `assets/brand/peekaa-master.png` | 1254×1254, opaque RGB | `4d9b6b9db64ede6d5366d5765402594aa16c71148c124c08dd13da74b25773f1` |
| `app/brand/peekaa-logo.png` | 890×568, transparent full lockup | `f7054190f8a5b402a94a0c460c85c71d3b48c03a308c392b14e9cb7cf3a05604` |
| `app/brand/peekaa-mark.png` | 574×321, transparent mark | `6065ee106251cae8105121d9bdda85082c39715b1918557e3fd74fe724b86030` |
| `app/icons/peekaa-32.png` | 32×32, opaque RGB | `f805302dfcfb3d528ab07c3751193293252ae675926b748cc5db35177b7aa8a6` |
| `app/icons/peekaa-192.png` | 192×192, opaque RGB | `dea215c737712023b87dc52ad1a032c628265a53743455dbab3f9f31fcf703f6` |
| `app/icons/peekaa-512.png` | 512×512, opaque RGB | `66c412ed57b6e0a668063a7827134ac0a5d0c7e5c0ebf0f976a29cfedf703663` |
| `app/icons/apple-touch-icon.png` | 180×180, opaque RGB | `3212c1f0a9e26f37dbc7f82bb3772fcfa5fd2cde736ebc2786705f8f4f72b2a3` |
| iOS App Store icon | 1024×1024, opaque RGB | `9df536e0ffbfbb445b2cea2eb9df19c5007ec05761426137c2a0f999741251a8` |

Android density icons and iOS/Android splash images are deterministic
derivatives of the same master. No temporary attachment binary or customer PII
was added.

## Automated evidence

Red-first regression and reviewer corrections:

- `tests/branding/v134-peekaa-rebrand.test.mjs`
- before implementation: 0/4 passed;
- after implementation and the Sol correction cycle: 7/7 passed:
  - canonical product identity and compatibility global;
  - public/PWA metadata and exact icon shapes;
  - native package/display/association consistency and opaque 1024px icon;
  - reviewed Stripe amounts/tax contract with Peekaa presentation.
  - existing reviewed Stripe objects converge to Peekaa presentation and the
    second run performs no provider mutation;
  - economic conflicts fail closed before any provider write;
  - current platform, dunning and no-GST surfaces cannot project the retired
    product identity.

Validation completed locally:

- `npm run mobile:sync` — passed;
- `npm run mobile:store:validate` — passed;
- canonical `index.html`, `platform-console.js` and `platform-console.css` are
  byte-equal to both refreshed Android and iOS packaged bundles;
- `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run quality` — passed;
- `npm run runtime-config:check` — passed;
- `npm run build` — passed;
- migration materialisation, canonical-order and manifest checks — passed;
- `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate` —
  1,395/1,395 tests passed plus the quality, runtime configuration, migration
  manifest, canonical migration and static-build gates.

The V104 source-bound evidence was recaptured from the current production
renderer in the owner-attached Chrome browser. Its exact source SHA-256 is
`40f848061d2848f5aa105dda75fe2314b67ec768c13283215abce352c39741ca`.

Database rehearsal used an explicitly named disposable PostgreSQL 17 clone of
the existing V129 synthetic rehearsal. V130–V134 applied in order. Both
`db/tests/v134_peekaa_brand_legal.sql` and the corrected
`db/tests/v124_stripe_launch_pricing.sql` completed under `ON_ERROR_STOP=1`
and rolled back. The V134 suite proves exact active hashes, private ACLs,
current write/replay/conflict behavior, byte-identical historical legal
acceptances, prior-consent compatibility, anonymous/outsider denial, final
V84/V78/V102/V106/V109 runtime presentation, durable notice sanitisation,
legacy-notice preflight and the current legal-operator no-GST identity. The
disposable database was then dropped; production was not touched.

## Browser and provider status

The owner-attached Chrome browser captured the actual signed-out application,
owner Stripe setup component, platform console and current extracted promotion
renderer. The signed-out app loads the supplied Peekaa logo and Peekaa install
prompt at 1440px and 390px; the 390px render has no horizontal overflow and
every visible interactive control is at least 44px high. This proves the
signed-out brand and recoverable Turnstile connection-error state, not a
successful sign-in journey. The owner setup at
1440px and 390px shows Peekaa, `peekaa.asia`, the reviewed annual/monthly
pricing, no-GST statement and Stripe handoff with no horizontal overflow. The
platform console loads the same logo at 1440px and 390px, remains ready and has
no horizontal overflow. The promotion desktop modal is a labelled
`role="dialog"`, has `aria-modal="true"`, and initially focuses its close
button. Both promotion mobile widths stack the two cards, open the requested
Terms row, wrap the deliberately long token and have
`scrollWidth = clientWidth`.
Artifacts:

- `docs/qa/evidence/v134-browser/peekaa-auth-desktop-1440.jpg`
- `docs/qa/evidence/v134-browser/peekaa-auth-mobile-390.jpg`
- `docs/qa/evidence/v134-browser/peekaa-owner-setup-desktop-1440.jpg`
- `docs/qa/evidence/v134-browser/peekaa-owner-setup-mobile-390.jpg`
- `docs/qa/evidence/v134-browser/peekaa-platform-desktop-1440.jpg`
- `docs/qa/evidence/v134-browser/peekaa-platform-mobile-390.jpg`
- `docs/qa/evidence/v134-browser/peekaa-brand-render-metrics.json`
- `docs/qa/evidence/v134-browser/promotions-desktop-1440.jpg`
- `docs/qa/evidence/v134-browser/promotions-mobile-390.jpg`
- `docs/qa/evidence/v134-browser/promotions-mobile-412.jpg`
- `docs/qa/evidence/v104-promotions-production-render-metrics.json`

### Authenticated live-account audit, 2026-08-02

After the owner opened the authenticated Stripe Dashboard, a read-only audit
of account `acct_1TzKwRLjvwAsL93H` established:

- the account is in live mode, has no active account-status tasks, and exposes
  live API-key controls;
- the configured SGD payout destination is DBS Bank/POSB ending `9997`, but
  payouts are set to manual rather than automatic;
- Cards, Apple Pay, Link and PayNow are enabled and Stripe reports no payment
  method requiring action;
- the active live product catalogue contains 0 products and 0 Prices;
- the Workbench has no webhook destination;
- Stripe Tax has not been activated, which is consistent with the current
  no-GST launch policy; the application must continue to create exclusive-tax
  Prices without attaching tax rates or enabling automatic tax;
- the default Stripe branding has no icon or logo and still uses Stripe's
  default colours;
- Checkout, Payment Links and Customer Portal still use Stripe-owned domains;
- the account's public business website and statement descriptor still use the
  retired Nestly identity, while the Stripe profile already uses
  `admin.peekaa@gmail.com`, `https://www.peekaa.asia`, and handle `@peekaa`;
- the primary Stripe user login is not `admin.peekaa@gmail.com`; changing the
  login identity and completing any resulting verification must remain an
  owner-controlled step;
- the owner subsequently specified a private Stripe account/contact phone
  (redacted from the repository) and account email `admin.peekaa@gmail.com`. These belong to account
  recovery/contact settings and must not enable the customer-facing support
  phone on receipts or Checkout;
- the customer portal has invoice history, billing-information update, payment
  method update, and end-of-period cancellation enabled, but has no Peekaa
  redirect, Terms link, Privacy link, portal header, custom domain, or active
  no-code link;
- the Billing failure policy currently cancels a subscription after Stripe
  exhausts its card retries. That must be reconciled with Peekaa's reviewed
  provider-confirmed day-14 workspace-pause/recovery contract before release;
- Checkout does not currently display support contact information, consistent
  with the owner's instruction not to show the customer-service phone on
  receipts/payment surfaces.

No credential, API key, webhook secret, full bank number, identity-document
value or other private account datum was copied into the repository or this
evidence. No setting was saved and no provider mutation occurred during the
audit.

No Stripe login, OTP, identity, representative, bank, catalogue, webhook,
secret or live-mode change has been performed. No production data, migration,
domain, deployment, commit or push was performed.

## Remaining release gates

1. In owner-controlled Stripe, complete sign-in/OTP/identity/bank steps; inspect
   account legal identity, email, domain and branding without exposing secrets.
2. Configure and verify the four Prices in Stripe test mode, signed webhook,
   checkout, payment projection, next date, refund window, failure/replay,
   day-14 handling and reconciliation using synthetic data.
3. Obtain a fresh independent Sol review of the corrected exact V134 candidate.
4. Obtain a subsequent owner approval explicitly scoped to V134 before any
   commit, push, production migration, production secret, live Stripe catalogue,
   domain/DNS or production deployment action.
5. After an authorised release, prove the new domain and association files over
   HTTP 200, preserve old-domain redirects, re-enrol passkeys, run signed native
   device acceptance, and complete a separately authorised live Stripe smoke.

The corrected V134 application and migration candidate is locally browser- and
database-verified. It is not yet provider-verified, independently accepted,
committed, pushed, deployed or live.

## Independent Sol review, 2026-08-02

Sol independently reviewed the exact uncommitted candidate and returned
**REJECT / NOT ACCEPTED for release approval**. No production Stripe change is
permitted from that candidate. Reproduced blockers are now durable as
`STRIPE-CATALOG-CONVERGE-001`, `BRAND-RUNTIME-FALLBACK-001` and
`LEGAL-V134-VERIFY-001`.

The reviewer independently reproduced 109/109 focused passes and the exact
1,390/1,391 full-suite result, but found:

- zero live Product/Price and webhook configuration plus 0/17 launch P0s proven
  closed;
- existing Stripe objects would retain retired customer-visible presentation;
- current dunning/platform/no-GST fallbacks can still expose Nestly;
- the V134 legal SQL acceptance does not yet prove final-chain compatibility;
- the Chrome source-bound evidence remains stale and the full suite remains red.

The provider audit remains read-only. The corrective implementation now adds
provider-object convergence, runtime fallback removal, executable final-chain
legal compatibility, fresh Chrome artifacts and a completely green 1,395-test
gate. It requires a fresh independent Sol verdict before a new owner release
approval can authorize live Stripe or production mutations.
