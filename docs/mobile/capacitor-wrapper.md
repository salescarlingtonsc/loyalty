# Nestly native-wrapper seam

Nestly is a mobile-first installable web application. The owner activated
native-store work on 2026-08-01. V125 uses Capacitor with the stable application
identifier `asia.nestly.app`; `app/` remains the only application source and
`npm run mobile:sync` prepares the reviewed web bundle before native sync.

## Wrapper boundary

- Keep `app/` as the canonical web source. The deterministic preparation step
  copies its reviewed static artifacts into the dedicated Capacitor
  `webDir`; native projects must never edit a second copy of application code.
- `app/pwa.js` deliberately skips service-worker registration when
  `Capacitor.isNativePlatform()` is true. Native builds should use bundled web
  assets and native update releases, not an independent service-worker cache.
- Use the existing publishable Supabase client configuration only. Never embed
  a service-role key, webhook secret, Stripe secret, or production operator
  credential in a native bundle.
- Define a small `window.NestlyNativeBridge` adapter only for reviewed native
  features. Web code must retain browser fallbacks. Candidate future ports are:
  secure credential storage, network status, push notifications, QR scanning,
  share sheets, haptics and external-link opening.
- Keep financial, loyalty, entitlement and authorization decisions in existing
  server contracts. Native plugins may capture input or deliver notifications;
  they must not become an alternate business-logic engine.

## Deep links and authentication

The application identifier is `asia.nestly.app`. Associated-domain ownership,
signing-team identifiers and callback URLs still require owner-controlled Apple
and Google credentials. Use verified universal/app links under
`https://www.nestly.asia/`; do not rely on a custom scheme alone. Preserve the
same customer and business hash routes after the link reaches the web layer.
Password-recovery and sign-in callbacks must be tested on web, installed PWA,
iOS and Android independently.

The packaged WebViews use the fixed origins `capacitor://localhost` on iOS and
`https://localhost` on Android. They are explicit server allowlist entries,
not dashboard-configurable wildcards. Cloudflare Turnstile must allow the exact
hostname `localhost`; server verification continues to require `success=true`,
the exact action and a hostname equal to the already allowlisted request
origin. A production key that has not been configured for `localhost` fails
closed and is a release blocker.

Every customer-facing QR, portal, join, booking-management and platform invite
link is generated under the one canonical public origin
`https://www.nestly.asia`. A local WebView origin must never be copied, shared
or encoded into a QR. The bundled `index.html` carries its own restrictive CSP
because Vercel response headers do not protect packaged files.

## Publication sequence and current blockers

1. Generate/sync native projects from the clean `npm run mobile:sync` command.
2. Configure associated domains, app links, signing, store identifiers and the
   production Turnstile hostname `localhost`.
3. Add only approved bridge plugins with permission copy and browser fallbacks.
4. Run role, transaction-sync, offline/reconnect and deep-link acceptance on
   physical iOS and Android devices.
5. Keep store release, signing credentials and production configuration behind
   the existing independent review and owner release gate.

Source generation is not publication proof. This machine currently lacks full
Xcode, CocoaPods, a Java runtime and the Android SDK, so V125 cannot yet produce
signed archives or run simulators/physical devices here. Apple Developer/App
Store Connect and Google Play Console teams, distribution signing, the Apple
Team ID, Android signing certificate SHA-256, bank/merchant verification, store
privacy answers, screenshots and physical-device acceptance remain external
owner-controlled gates. The app must not be called App Store or Play Store
ready until those artifacts and store reviews are recorded.
