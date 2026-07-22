# P0-TARGET-RUNTIME-014 — Deployed app uses only the Singapore target URL/key/CSP

## 1. Classification

**ENGINEERING-PREP-COMPLETE**; **OWNER-ACTION-SCRIPTED** for the actual deploy-and-inspect step.

**Verified today:**
- `config/runtime/production.json` pins `projectRef: gadpooereceldfpfxsod`,
  `supabaseUrl: https://gadpooereceldfpfxsod.supabase.co`, and the current publishable key.
- `scripts/runtime-config/generate.mjs` generates `app/runtime-config.js` and `app/vercel.json` from
  that one file (`npm run runtime-config:check` passes today), replacing the hardcoded-URL problem the
  v41 audit flagged as SEC-002 ("App hardcodes production Supabase URL/key, making safe browser routing
  impossible").
- `app/api/build.js` implements the fail-closed `/api/build` identity endpoint the readiness review
  said was missing ("the live artifact has no `/api/build` identity endpoint") — it only returns a
  validated 40-hex commit SHA and Vercel environment name, and refuses (`available:false`, HTTP 503) if
  either looks malformed.
- `npm run build` passes today and produces exactly `data-request.html, index.html, join.html,
  privacy.html, terms.html`.
- The full `npm test` run (393/393) includes and passes "deployable app files do not mix Supabase
  project refs" and "deployable clients use the Singapore Supabase URL and publishable key."
- The production readiness review recorded a **specific past failure mode** worth re-checking at deploy
  time: the live artifact it inspected on 2026-07-21 did not match `origin/main` and lacked several
  shipped features — i.e. a green local build has previously not implied the *deployed* artifact matched
  it. This gate's evidence must be captured against the actual deployed URL, not the local build alone.

## 2. Preconditions

- The candidate commit is frozen and its SHA recorded (shared precondition with `P0-RELEASE-BUILD-017`
  and `P0-POST-CUTOVER-SMOKE-016`).
- Vercel deploy access for whoever performs the deploy step; this agent must not deploy.

## 3. Procedure

1. Re-run locally: `export EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod && npm run
   runtime-config:check && npm run build && npm test`.
2. Deploy the frozen commit through the repository's normal git-connected Vercel path (per `CLAUDE.md`:
   "the LIVE, current app is the git-connected `loyalty` Vercel project... auto-deploying on every push").
3. Fetch the served `index.html` and headers from the production URL; confirm the only Supabase project
   reference present is `gadpooereceldfpfxsod` and CSP `connect-src` lists only that origin plus the
   required CDN origins (already asserted statically — confirm the deployed bytes match).
4. Hit `/api/build` on the deployed URL; confirm it returns `available:true` with a commit SHA equal to
   the one just deployed.
5. Confirm the canonical production URL, the Supabase Auth Site URL/redirect settings, and the frontend
   build all agree on the same target project (cross-check with whatever `P0-AUTH-EMAIL-008` recorded
   for the redirect allowlist).
6. Confirm no service-role credential appears anywhere in the static files or Vercel client-exposed
   environment variables.

## 4. Evidence capture

- Artifact path: `docs/launch/.evidence/<run-id>/P0-TARGET-RUNTIME-014.json`
- Example `checks`: `{"runtimeConfigCheckPassed": true, "buildPassed": true, "testsPassed": true,
  "deployedHtmlSingleProjectRef": true, "cspOriginsCorrect": true, "buildEndpointMatchesDeployedSha": true,
  "authRedirectAllowlistAgrees": true, "noServiceRoleInClientFiles": true}`
- Do not place the deployed HTML, the full CSP header string, or the publishable key value itself in the
  artifact if it would trip the checker's URL/JWT-shaped-token scan — record booleans and the commit SHA
  (a 40-hex string is not one of the checker's four unsafe patterns, so the SHA itself is fine to
  include).
- Hash-pin and register per `INDEX.md`.

## 5. Estimated wall-clock time

20-30 minutes once the commit is frozen and deploy access is available — this is one of the fastest
gates given how much of the mechanism already exists and passes locally.
