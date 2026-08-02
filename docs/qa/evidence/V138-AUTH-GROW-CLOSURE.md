# V138 auth and Grow closure — local evidence

Date: 2026-08-02
Branch: `codex/v138-auth-grow-closure`
Issues: `AUTH-CONSENT-001`, `AUTH-SESSION-001`, `GROW-EDIT-001`,
`GROW-VISIBILITY-001`, `GROW-HUB-001`, `BRAND-TURNSTILE-001`

Production-component source SHA-256:
`3273ef5391b7e7248f3b2ffe7cdec3832fac8f73bc8e831077bd1486a136f7c3`.

Business-auth renderer source SHA-256:
`1b8bd46682a48130e3f699b8bac78b0126fa063bb0255e151c5614c6795e30ab`.

V138 source/deploy migration SHA-256 (byte-identical mirrors):
`2bad0d853541bf126aca8c104f671ae73c863efd57c109fdc6685f3bcd9ee7f3`.

## Observable candidate behavior

- Ordinary email and Google sign-in contains no Terms/Privacy checkbox. The
  server admits Google sign-in only for an existing active business persona.
  Google signup first records a short-lived no-PII consent attempt pinned to
  the exact active 2 August Terms and Privacy versions/hashes; the authenticated
  Google callback consumes it into private append-only user-bound evidence.
  Provider tokens are first installed in a memory-only Supabase client; the
  application persists them only after server admission, so interruption,
  reload or another tab cannot inherit an unadmitted identity.
- The browser Supabase client persists and auto-refreshes its local session;
  normal route changes do not sign the owner out. Explicit sign-out remains the
  user-controlled termination path.
- The business sidebar exposes one **Grow** destination. The complete overview
  contains earning, every reward, birthday, bring-back, referrals, memberships
  and gift cards, including not-set-up and paused states. The `#/grow` route is
  entitlement-neutral: retention-only access does not depend on Loyalty.
- Each eligible row opens its exact stable record/control. A live reward,
  Birthday benefit or Bring-back rule missing from an older draft is copied
  into that draft and then opened. Reward service eligibility is copied too.
  The operations are owner-only, stale-write guarded, idempotent and never
  publish or remove unrelated draft work. An exact retry using the pre-request
  hash after a committed-but-lost response returns the same row.
- A retention-only owner can create or resume the shared editable draft through
  `create_grow_config_draft_v138` without receiving Loyalty write authority.
  The RPC clones the published Loyalty portion unchanged solely to preserve the
  unified draft model, then opens the exact Bring-back rule directly. Owner,
  manager, cross-tenant and anonymous database cases are all asserted.
- Reward **Done** and successful reward save return to the Grow overview. Each
  other editor exposes **Back to Grow overview**.
- Existing programme visibility switches remain explicit. The disposable V138
  suite proves disabled referrals issue no reward and inactive memberships
  create neither membership nor sale. The current Birthday suite proves OFF
  hides new eligibility after customer refresh while preserving an existing
  immutable promise. Earn/reward, Bring-back and Gift-card boundaries continue
  to preserve history and liabilities while blocking new inactive actions.
- The PWA cache version changes, a new Peekaa shell activates immediately, and
  brand/lifecycle assets use network-first with offline fallback. This closes
  the stale customer-visible **Install Nestly** cache path without caching API
  or authenticated responses.

## Evidence

- Red-first regression: the initial V138 auth/Grow suite failed 6 cases; the
  new PWA/Done regression then failed 4 cases before implementation.
- Focused Node regression:
  `v135-business-google-auth.test.mjs`, `v136-grow-streamline.test.mjs`,
  `v137-minimal-auto-rewards.test.mjs`,
  `v138-auth-grow-closure.test.mjs`, `pwa-infrastructure.test.mjs` and
  `customer-auth-controls.test.mjs`.
- Production-renderer Chrome acceptance:
  `tests/browser/verify-reward-overview-owner.mjs` passes at desktop and
  375/390/412px-class mobile viewports with zero horizontal overflow, 44px
  targets, exact duplicate-name reward UUID routing, exact bring-back routing,
  read-only/disabled/empty/retry states and no automatic publication.
- Actual-renderer Google Auth Chrome acceptance:
  `tests/browser/verify-v138-business-google-auth.mjs` verifies unchecked and
  checked signup, checkbox-free existing login, exact legal-version preflight,
  admitted/rejected server callback, forged signup token, expired and replayed
  callback state, plus a forced interruption immediately after memory-only
  token exchange followed by reload with no persisted session, at a 390px
  viewport. Artifacts are in
  `docs/qa/evidence/v138-business-google-auth-browser/`.
- Browser artifacts are in
  `docs/qa/evidence/reward-overview-owner-browser/`, including
  `owner-auto-review-desktop-1440.png`,
  `owner-exact-reward-editor-desktop-1440.png`,
  `owner-auto-review-small-375.png` and `manager-read-only-mobile-390.png`.
- Disposable database regression:
  `db/tests/v138_auth_grow_closure.sql` validates exact reward/Birthday/
  Bring-back materialization, eligibility copying, unrelated-row preservation,
  old-hash lost-response replay, stale-hash rejection, audit uniqueness,
  tenant/anonymous denial, Referral/Membership OFF boundaries and no
  publication. `db/tests/v45_birthday_benefits.sql` validates owner OFF → new
  customer unavailable while an existing promise survives. Both passed and
  rolled back.
- The same V138 rollback suite also validates existing-Google login, new-Google
  login denial, Google-provider binding, exact legal version/hash storage,
  unchecked/wrong-version/expired/forged/cross-user denial, same-user
  lost-response replay, private-table ACLs and exact anon/authenticated RPC
  grants.
- Complete local gate:
  `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate` passes
  quality/runtime/migration checks, 1,429/1,429 Node tests and static build.

## External provider boundary

Cloudflare Turnstile code `110200` was reproduced because the widget hostname
allowlist contains the legacy hosts but not the canonical Peekaa hosts. The
production release step must add both `peekaa.asia` and `www.peekaa.asia`, then
verify sign-in, signup, password reset and join on the canonical `www` host.
That provider change is not local code evidence and remains release-gated.

## Evidence limit

This file records local source, browser and disposable-database evidence only.
It is not production proof. Independent Sol review accepted this exact frozen
candidate with 0 P0, 0 P1 and 0 P2 findings after the interruption/persistence
correction. Commit and push still require the owner's subsequent scoped release
approval; production migration, Cloudflare mutation and deployment remain
separately gated.
