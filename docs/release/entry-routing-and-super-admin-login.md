# Entry routing and super-admin login

## Public entry paths

- `/` is the customer entry. A signed-out visitor sees mobile verification; a registered, signed-in customer is sent to their wallet.
- `/business` is the business entry. A signed-out visitor sees email/password authentication. A signed-in staff member is sent to their business workspace; someone with several workspaces chooses one.
- Existing customer and workspace hash deep links remain authoritative. `/#/customer`, `/#/wallet`, `/#/wallet/{business}`, and `/#/workspace/{business}/{module}` continue to work.
- The legacy `/#/login` route remains an alias of the business entry.

The customer entry does not display an account-type choice. Its only business affordance is a low-emphasis `Business sign in` footer link. The installed PWA opens the customer entry by default and exposes separate Customer and Business shortcuts.

## Hidden super-admin entry

`/admin` is a direct, unlinked entry for an existing authorized super-admin. It uses the normal business email/password authentication method and then resolves to `/#/platform`. Its screen is labelled `Super admin sign in` and deliberately omits customer navigation and account creation. There is intentionally no `/admin` link in public navigation.

The Platform route is evaluated before tenant workspace discovery, so a super-admin does not need to own a business workspace. The platform console still obtains its roster and data through the existing guarded super-admin RPCs, including `super_admin_list_businesses`; the clean route adds no client-side authorization bypass.

Login steps:

1. Open `/admin`.
2. Sign in with an existing Supabase Auth account that is already present in the application’s super-admin allowlist.
3. The unchanged Platform console performs its normal authorization check and loads the platform dashboard.

The hash-compatible equivalent is `/#/platform`.

This routing change does not create an Auth user, add a super-admin allowlist row, store a password, change production data, or apply a migration. Local test-account provisioning remains an explicit developer operation through `npm run dev:bootstrap-superadmin` and requires an execution-time password; it was not run for this change.

## Hosting and PWA behavior

`app/vercel.json` rewrites the exact clean `/business` and `/admin` paths to the static SPA document. The same rewrites live in `config/runtime/vercel.template.json` so generated runtime artifacts stay in sync.

The service worker keeps navigation network-first and never persists the authenticated application shell. When offline, clean entry-path navigation continues to use the existing public offline fallback rather than a stale signed-in page.
