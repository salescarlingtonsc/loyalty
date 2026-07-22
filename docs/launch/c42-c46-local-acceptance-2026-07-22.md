# C42–C46 local acceptance evidence — 2026-07-22

Scope: isolated local Supabase only, synthetic data only. No remote project,
production data, commit, push, or deployment was used. This is implementation
evidence, not approval to launch SMS, WhatsApp, or production services.

## Database and release integrity

- Clean canonical replay: 71 migrations, versions `20260718152809` through
  `20260722120000`.
- Focused rollback suites: v21, v41 hardening, v41 integrity, C42, C44, C45,
  C46, and v46a all passed.
- C45 concurrency under `/bin/sh`: passed.
- C46 concurrency under `/bin/sh`: passed.
- Post-suite cleanup: zero synthetic businesses and auth users; C45/C46 feature
  flags restored disabled.
- Full `npm run validate`: 344/344 Node tests passed; immutable migration
  manifests, full canonical chain, runtime configuration, and five-page static
  build passed.
- Canonical v46a source/deploy SHA-256:
  `b7a82268626234af24cba95fce8a9a5041d649b84c898e420e63c797724815d4`.

## Authenticated browser matrix

Executed at `2026-07-22T04:01:37.768Z` against the local Supabase API with
three synthetic auth personas and two synthetic customer-business links.
Desktop and 390px mobile viewports were exercised. Result: 32/32 passed.
The JSON report SHA-256 was
`cd887df7eb231ae10ec5779898ce94b8204f024092319dfe51dfce939508a1d3`.

- Owner dashboard height remained stable and bounded.
- Owner dashboard rendered a meaningful heading.
- Owner Customers, Loyalty, Retention, Referrals, Memberships, and Gift cards
  rendered the expected route and had no unnamed visible form controls.
- “Never expire” hid and disabled the expiry-days control.
- Owner dashboard visible controls met the 44px target and had accessible names.
- Owner mobile dashboard had no horizontal overflow.
- Loyalty-read staff could not edit firm expiry configuration.
- Customer wallet used a plain-language heading and showed two businesses with
  separate balances.
- A customer could open one business programme; detail had one primary heading,
  44px targets, plain-language expiry, and next-reward guidance.
- Customer mobile wallet retained its primary heading without horizontal
  overflow.
- No local app or Supabase response returned an HTTP error.

Screenshots were retained outside the repository and deliberately not added to
source control. Their SHA-256 values were:

- owner dashboard desktop:
  `3b6dfab490ccedd0e1dfcc28e16311b9c5974d7d86cae1ffc69583d761e373f2`
- owner dashboard mobile:
  `51ee82e27198ee68da10ac171ae50f8192c071f6e5785f268c36795f5e5fab2f`
- customer wallet desktop:
  `4298020bfad844e670748450b9cc5bd1a7cf4a39c2014bedf0cdca57b0f3e7b4`
- customer wallet mobile:
  `fa618add89994788ff644fb29416bcc0df7c3fe28132c8d4fdfddbe3b597bd93`

## Not covered

Real SMS/WhatsApp delivery, sender registration, Turnstile-provider integration,
remote isolated Supabase acceptance, and real-device recovery/throttling remain
outside this local evidence and must stay launch-blocking until separately
configured and approved.
