# V131 store publication readiness

Date: 1 August 2026
Candidate baseline: `7fdc9485d849f91a82e49b164740d0144afabc39`
State: `IMPLEMENTED_UNVERIFIED`

## Owner instruction

The owner asked: **“Please ensure the app publish is ready to live.”** This
follows the explicit request to verify iOS and Android production readiness.

## Reproduction evidence

- `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate` passes
  1,380/1,380 Node tests and the static production build.
- `npm run mobile:sync` succeeds for iOS and Android; `npx cap doctor` reports
  both projects healthy.
- The bundled native source is the same `app/` source and therefore exposes the
  new-owner Stripe Checkout and existing Billing Portal/plan-change controls.
- Customer profile has no authenticated in-app account-deletion request. The
  public data-request page requires a separate manual contact flow.
- `https://www.nestly.asia/.well-known/apple-app-site-association` and
  `https://www.nestly.asia/.well-known/assetlinks.json` both return HTTP 404
  without redirects.
- `sips` reports `hasAlpha: yes` for the 1024×1024 iOS App Store icon.
- `xcodebuild` resolves only to Command Line Tools; `simctl` is unavailable;
  Java has no runtime; Android SDK variables and tools are absent; macOS reports
  zero valid code-signing identities.
- Available disk space is below 1 GiB, insufficient for current Xcode and
  Android toolchains.

## Exact local acceptance

1. Web business signup and reviewed Stripe truth remain unchanged.
2. Packaged native builds are purchase-free companions with no Stripe purchase,
   portal, upgrade, external payment link or steering copy.
3. A signed-in customer, owner or staff member can initiate one account-deletion
   request inside account settings after a clear destructive confirmation. The
   request is tenant/user scoped, replay-safe, does not delete value immediately,
   survives refresh and states the 30-calendar-day response window.
4. The iOS store icon has no alpha channel.
5. Association generation/validation fails closed without real Apple/Google
   identifiers; no placeholder credential is shipped.
6. Desktop, 390px and 412px interaction evidence covers success, denied, retry,
   pending and native/web split states; database evidence covers ACL, replay and
   zero immediate value deletion.
7. Full validation and independent Sol review pass on the exact candidate.

## External publication acceptance

Publication remains blocked until the owner-controlled Apple and Google teams
provide signing identifiers/material, current toolchains produce signed
artifacts, live association files return valid no-redirect JSON, Turnstile
accepts the exact `localhost` packaged hostname, store declarations and review
credentials are complete, and physical iPhone/Android journeys pass.

## Implemented local contract

- Website owner signup and V124/V130 Stripe onboarding remain present.
- Capacitor iOS/Android business entry is a purchase-free companion: it keeps
  existing-account sign-in but replaces new-owner signup, pending Checkout and
  owner billing changes with explicit non-purchasing states. No external
  payment link or purchase button is rendered in the packaged path.
- Customer profile and the owner/staff account menu expose one separated
  **Request account deletion** action. The confirmation dialog requires the
  exact word `DELETE`, reuses one browser request key after a lost response,
  reports the persisted 30-day due date, and never calls an Auth admin delete.
- The V131 migration adds one private, RLS-forced deletion-request queue with
  authenticated subject-only request/status RPCs, exact replay, one open
  request per identity, a bounded super-admin queue and no browser table grant.
  The request writer does not delete or mutate identity, tenant, payment,
  customer-history or customer-value records.
- The 1024px iOS App Store icon is RGB without alpha. The store-readiness tool
  checks it and both Capacitor privacy manifests.
- Association generation refuses missing or malformed owner identifiers and
  writes reviewed AASA/assetlinks payloads only to an explicit output folder.
  No placeholder Team ID or signing fingerprint is committed.

## Executed evidence

- Red-before-green regression: `tests/mobile/v131-store-publication-readiness.test.mjs`
  initially failed all four reproduced boundaries; it now passes 4/4.
- `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate` passes
  1,380/1,380 Node tests, static quality, runtime config, both migration
  manifests and the production static build.
- `npm run mobile:sync` passes for iOS and Android; `npx cap doctor` reports
  both generated projects healthy with Capacitor 8.5.0.
- `npm run mobile:store:validate` passes local package, icon and dependency
  privacy-manifest checks. Its association generator is regression-tested to
  fail without real identifiers and to emit the exact package/team binding
  when valid synthetic identifiers are supplied.
- Android is configured with application ID `asia.nestly.app`, version code 1,
  version 1.0 and target/compile API 36. iOS is configured with the same bundle
  ID, version/build 1.0/1 and deployment target iOS 15; an iOS 26 SDK archive
  still cannot be demonstrated without the required full Xcode 26 toolchain.
- The deterministic browser harness executes the current production native
  companion and deletion functions. Chromium passed desktop 1280×900, iPhone
  390×844 and Android-class 412×915 with no console/page errors, no horizontal
  overflow, 44px minimum visible buttons, disabled confirmation before exact
  `DELETE`, successful pending response, and dialog focus on Close. The same
  390×844 harness separately passed persisted-pending, status-load failure and
  lost-response/retry states; the retry reused the same idempotency key and no
  browser state created an unconfirmed request.
- The first independent Sol review rejected five exact gaps: native website
  payment steering, missing deletion access in blocked signed-in states,
  non-exact server confirmation, incomplete browser error-state evidence and a
  PNG validator that did not reject `tRNS`. The candidate now removes steering,
  exposes deletion in each signed-in blocked state, enforces byte-exact
  `DELETE` in SQL with negative rollback cases, covers the additional browser
  states and parses PNG chunks to reject `tRNS`.
- Sol's next focused pass found that the deletion action was still absent from
  several signed-in choice/error routes and that the PNG test did not execute
  the validator against a transparent fixture. Those routes now render and
  wire the same deletion control, the regression test checks each bounded
  production source block, and a synthetic `tRNS` PNG is rejected by the real
  CLI. Browser execution covered persona choice, customer unavailable,
  capability error, persona error, inactive staff, native companion and web
  payment-pending views: every view exposed the deletion action, retained 44px
  buttons, had no horizontal overflow and emitted no browser error.
- Sol's final pass found one last native-session edge: the signed-in return
  action rendered sign-in without ending the existing session. The corrected
  action now performs channel cleanup, awaits Auth sign-out, resets client
  state and only then renders sign-in; an extracted-helper regression verifies
  that exact order and a browser click reaches the truthful signed-out state.
  Sol independently **ACCEPTED** the final local V131 candidate with no
  P0/P1/P2 findings. Database rehearsal is recorded below; signing,
  live-association, store-console and physical-device evidence remain external.
- Visual evidence:
  `v131-native-business-desktop.png`,
  `v131-native-business-mobile-390.png`,
  `v131-account-deletion-desktop.png`,
  `v131-account-deletion-mobile-390.png`, and
  `v131-account-deletion-android-412.png`,
  `v131-persona-deletion-desktop.png`, and
  `v131-payment-pending-deletion-desktop.png` in this evidence directory.

## Additional database evidence

- The existing non-production Supabase `migration-rehearsal` branch was
  advanced through V132. `db/tests/v131_store_publication_readiness.sql` passed
  after its harness restored the privileged role before inspecting the private
  queue, then deliberately re-entered `authenticated` for the denial check.
  The executed test proves byte-exact confirmation, exact retry, one open
  request, the 30-day deadline, other-user/anonymous/table denial and zero Auth
  deletion. A post-test query returned zero synthetic Auth users, businesses
  and deletion requests.

## Evidence not available on this Mac

- The root filesystem has about 225 MiB free, Xcode resolves only to Command
  Line Tools, Java and Android SDK variables/tools are absent, and macOS reports
  zero valid signing identities. A signed archive/AAB and physical-device run
  cannot truthfully be produced here.
- Live AASA and assetlinks are still HTTP 404 until the real Apple Team ID and
  Play signing SHA-256 are supplied and the generated payloads are deployed.

Because signing, live-association, store-console and physical-device proof
remain external, this phase is `IMPLEMENTED_UNVERIFIED`; it is not `CLOSED`,
production-ready, or submitted to either store.
