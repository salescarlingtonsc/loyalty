# QA sweep harness

Boots the **real** Peekaa app against a Supabase test double so every screen renders with its
real render functions, then audits each route. Nothing here fakes UI — only the network under it.

```sh
npm install playwright --no-save --no-audit --no-fund   # not a project dependency
node tools/qa-sweep/sweep.mjs                           # writes results.json + shots/
node tools/qa-sweep/null-guard.mjs                      # unguarded null RPC payload reads
node tools/qa-sweep/verify-null.mjs                     # checks those against the SQL
node tools/qa-sweep/verify-rulings.mjs                  # asserts the UI standard in a real render
```

## What it covers
46 route renders (31 business @1280, 12 business @390, 3 customer @390): console/page errors,
blank pages, duplicate DOM ids, horizontal overflow, broken images, sub-44px tap targets, and the
full list of RPCs each screen asks for.

## What it does NOT cover
Everything server-side. The double stubs 407 `sb.rpc`, 226 `sb.from` and 63 `sb.auth` calls, so
this proves **nothing** about RLS, permissions, auth, OTP, realtime, payments, or the
business↔customer interaction. Passing this sweep is not a go-live signal.

## Fixture accuracy matters
Two "bugs" in the first run were wrong fixtures, not defects — `booking_policy` is a `text`
column and was stubbed as an object, which made `.trim()` throw. Before reporting anything this
harness surfaces, check the shape against `supabase/migrations/`. `db/database.types.ts` is a
stale placeholder and cannot be trusted for nullability.
