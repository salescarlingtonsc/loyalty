# V135 business Google authentication evidence

Date: 2026-08-02 (Asia/Singapore)

## Owner requirement and release boundary

The owner requires business sign-in and owner sign-up to offer Google login
using the already-created Peekaa Web OAuth client, and reports that production
still displays Nestly. V135 covers only the application Google entry/callback,
the canonical Peekaa authentication configuration checklist, and regression
evidence. It does not launch Stripe, publish native-store binaries, assign a
business role from OAuth metadata, or authorize production release by itself.

## Reproduction

- `https://www.peekaa.asia/api/build` served commit `d9936245...`.
- `https://www.peekaa.asia/brand-config.js` exposed `productName: 'Nestly'`
  and canonical domain `https://www.nestly.asia`.
- Production `/auth/v1/settings` reported Google enabled, but served `d993624`
  and V134 commit `9575605` contained no business Google action,
  `signInWithOAuth`, or callback consumer.
- `www.peeekaa.asia` (three `e` characters) did not resolve. The canonical
  product domain is `www.peekaa.asia` (two `e` characters).

## Observable acceptance contract

1. Business sign-in and owner sign-up each expose one **Continue with Google**
   action with a minimum 44px target at desktop and 390px. Because Google may
   create an unknown identity, both Google entry points require explicit Terms
   and Privacy acceptance before provider handoff; email owner signup uses the
   same legal gate.
2. The app records a recent same-tab pending attempt, requests only
   `openid email profile`, returns to
   `https://www.peekaa.asia/business?oauth=business`, establishes one Supabase
   session, and immediately removes credentials from the browser URL. Missing,
   malformed, expired or already-consumed attempts fail visibly without
   accepting callback tokens.
3. OAuth start canonicalizes to `https://www.peekaa.asia/business` before
   writing the origin-scoped marker. The production release must also make
   bare and legacy hosts redirect to canonical `www` before serving auth UI.
4. OAuth never writes role, staff, business or authorization metadata. Existing
   server persona and payment state remain authoritative.
5. New Google identities continue through the existing self-service owner
   setup; existing identities retain only their server-derived roles.
6. Provider cancel/error, missing tokens, rejected session, replay/refresh and
   stale password-recovery state remain recoverable.
7. Platform-admin, customer and native-companion auth do not expose this web
   owner Google action.

## Red-first regression and automated evidence

Before implementation:

```text
node --test tests/business-ui/v135-business-google-auth.test.mjs
0/3 passed
```

After implementation:

```text
node --test tests/business-ui/v135-business-google-auth.test.mjs \
  tests/browser/v130-self-serve-visual.test.mjs \
  tests/business-ui/v130-self-serve-business-onboarding.test.mjs \
  tests/public-gateway/public-gateway.test.mjs
45/45 passed; the V135 security/behavior subset is 8/8.
```

The V135 regression proves canonical redirect construction,
`signInWithOAuth({ provider: 'google' })`, exact scopes, absence of role
metadata, business-only entry actions, 44px styling, shared legal consent,
same-tab/recent attempt validation, callback token consumption/scrubbing,
thrown and returned start-error recovery, and OAuth consumption before
password recovery.

Complete candidate gates:

```text
EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate
1403/1403 passed; static quality, runtime config, migration manifest/order and
static build passed.

npm run mobile:store:validate
passed; signing and live association identifiers remain external inputs.

app/index.html == Android packaged index.html == iOS packaged index.html
passed byte-for-byte after npm run mobile:sync.
```

The V130 actual-renderer fixture was regenerated from the changed production
signup renderer and its source-digest regression passes. `git diff --check`
passes.

## Browser acceptance

Local source was served with SPA fallback at `127.0.0.1:4174`.

- Desktop business sign-in: Peekaa logo, business/customer switch, exactly one
  **Continue with Google** action, conditional-new-account Terms/Privacy gate,
  and preserved email/password fallback.
- Desktop owner sign-up: Peekaa heading, exactly one Google action positioned
  after the shared Terms/Privacy checkbox; that checkbox gates both Google and
  email/password account creation.
- Desktop `/admin`: Peekaa identity and zero Google actions.
- 390×844 business sign-in: viewport width 390, document scroll width 390,
  conditional-new-account legal gate present, Google action height 44px,
  document scroll width 390, Peekaa logo present.
- Regenerated V130 production-renderer fixture at 390×844: executable Peekaa
  signup heading, shared legal checkbox before one Google action, action height
  44px, document scroll width 390, zero browser errors; clicking Google without
  consent stayed on the fixture and displayed the exact legal-acceptance error.
- Turnstile connection failure on localhost remained explicit and recoverable;
  it did not conceal or disable the independent Google action.

These checks prove presentation and callback code, not a completed production
Google identity or workspace record.

## Provider configuration inspection

Read-only authenticated inspection established:

- Google Cloud client **Peekaa Web** is enabled.
- Its authorized redirect URI is exactly
  `https://gadpooereceldfpfxsod.supabase.co/auth/v1/callback`.
- Production Supabase Auth reports Google enabled.
- Supabase Site URL is still `https://peekaa.asia`.
- Supabase redirect rows include `https://peekaa.asia` and
  `https://peekaa.asia/**`, but omit canonical `https://www.peekaa.asia` and
  `https://www.peekaa.asia/**`.

Before production Google acceptance, the reviewed provider cutover must set
Site URL to `https://www.peekaa.asia` and add both canonical `www` redirect
rows. The existing Nestly rows may remain temporarily for recovery links until
the separately reviewed legacy-domain redirect is live.

## Remaining evidence before close

1. Obtain a subsequent owner release approval scoped to V135.
2. Commit/push/merge only after approval; apply the reviewed Supabase URL
   configuration and deploy the exact main commit.
3. In production, use new synthetic Google identity
   `qa.v135.google.owner@peekaa.invalid` and an existing synthetic owner to
   prove callback, one session, onboarding/workspace projection, refresh,
   cancel/error and no privilege escalation. Do not use a real owner identity
   as QA evidence.
4. Record served commit, canonical branding, desktop/390px browser artifacts,
   provider redirect state and the persistent workspace/persona result.

Current state: `VERIFIED_BROWSER`. It is not production proof and is not
`CLOSED`.

## Independent Sol review

Sol independently checksummed the frozen candidate and returned **ACCEPT** with
no P0, P1 or P2 findings. The reviewer reproduced the 45/45 focused set,
8/8 V135 security/behavior subset, 1,403/1,403 full gate plus build, native
store validation, web/Android/iOS byte equality and clean diff. The review
confirmed immediate credential scrubbing, recent legal-accepted single-use
same-tab callback enforcement, no OAuth role metadata, no unsolicited/expired/
replayed session establishment, both legal gates, and admin/customer/native
exclusion.

This acceptance is limited to V135 and permits only a subsequent owner release
decision. It does not approve live Stripe mutation, native-store publication,
or a broader production-readiness claim.
