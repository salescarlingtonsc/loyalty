# Nestly native-wrapper seam

Nestly is currently a mobile-first installable web application. Do not create
Capacitor iOS or Android projects until the PWA behavior has passed release
acceptance and the owner approves native-store work.

## Future wrapper boundary

- Keep `app/` as the canonical web source. A future deterministic build step
  should copy its reviewed static artifacts into a dedicated Capacitor
  `webDir`; native projects must never edit a second copy of application code.
- `app/pwa.js` deliberately skips service-worker registration when
  `Capacitor.isNativePlatform()` is true. Native builds should use bundled web
  assets and native update releases, not an independent service-worker cache.
- Use the existing publishable Supabase client configuration only. Never embed
  a service-role key, webhook secret, Stripe secret, or production operator
  credential in a native bundle.
- Define a small `window.NestlyNativeBridge` adapter only when a native feature
  is approved. Web code must retain browser fallbacks. Candidate ports are:
  secure credential storage, network status, push notifications, QR scanning,
  share sheets, haptics and external-link opening.
- Keep financial, loyalty, entitlement and authorization decisions in existing
  server contracts. Native plugins may capture input or deliver notifications;
  they must not become an alternate business-logic engine.

## Deep links and authentication

Before native setup, approve an application identifier, associated-domain
ownership and callback URLs. Use verified universal/app links under
`https://www.nestly.asia/`; do not rely on a custom scheme alone. Preserve the
same customer and business hash routes after the link reaches the web layer.
Password-recovery and sign-in callbacks must be tested on web, installed PWA,
iOS and Android independently.

## Suggested future sequence

1. Add Capacitor dependencies and config in a separately reviewed phase.
2. Generate native projects from a clean, reproducible command.
3. Configure associated domains, app links, signing and store identifiers.
4. Add only approved bridge plugins with permission copy and browser fallbacks.
5. Run role, transaction-sync, offline/reconnect and deep-link acceptance on
   physical iOS and Android devices.
6. Keep store release, signing credentials and production configuration behind
   the existing independent review and owner release gate.
