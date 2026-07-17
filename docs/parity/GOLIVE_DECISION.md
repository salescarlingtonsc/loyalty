# FRENLY — GO-LIVE DECISION (Singapore controlled pilot)

**Date:** 2026-07-17 · **Decision owner:** Fable (Release QA Lead / Go-Live Owner)
**Verdict: GO** (upgraded from CONDITIONAL GO — all three conditions met and verified; see §19).

> **C1 MET** — P0 fix deployed via git, commit `2ec0f568`, verified: deployed bytes contain zero
> `reversal_of`, md5 `1ba102b1370feff5468243b44174deb1`.
> **C2 MET** — canonical pilot URL = `loyalty-pi-seven.vercel.app` (project `loyalty`, git-connected
> to `salescarlingtonsc/loyalty@main`; pushing to main auto-deploys).
> **C3 MET** — post-deploy browser smoke test PASS, 0 P0. Dashboard renders; console clean of
> `column ... does not exist`; 2 Jul 3:00 PM survived the portal→staff round trip exactly.
> **Residual, accepted:** mobile viewport UNTESTED (tooling could not resize); non-SGT browser
> timezone unverified. Neither blocks a controlled SGT desktop pilot.

---

## 1. Current HEAD and deployment (verified, not assumed)
- Repo: `/Users/cs/Downloads/loyalty-main`, branch `master`, HEAD `800a8d9`.
- Uncommitted: `app/index.html` (the P0 fix, md5 `1ba102b1370feff5468243b44174deb1`) + doc files. `.git` is lock-contended by the owner's own terminal.
- Supabase project `kyzovonwnscrzmkvocid`, **17 migrations applied** (v10 → v10.1 → v11a → v11b → v11c → v12a → v12).
- **Two Vercel projects both serve the app** (finding — needs owner decision):
  - `frenly-app` → `frenly-app.vercel.app` (READY)
  - `loyalty` → `loyalty-pi-seven.vercel.app` (READY) ← the screenshot's URL; CLAUDE.md calls this the *marketing* site, but it is serving the app.
- **Both live URLs currently serve the BROKEN build** (`reversal_of` P0). The fix is committed-locally but **not deployed**.

## 2. Included in the pilot
Dashboard · Customers · Appointments (+ public booking portal, change requests) · Sales/Quick sale · Services · Bookings · Waitlist · Inventory (FEFO) · Packages · Loyalty (points) · Retention · Referrals · Memberships · Gift cards · Reports · Settings. Multi-tenant onboarding with industry→module presets.

## 3. Disabled / not exposed for the pilot
Payments ledger, Cash drawer, Expenses, Payroll/commission, Branches management, Refunds. **All of these exist in the DB engine (v11a/b, v12) but have NO frontend entry point** — they are not in the sidebar and not clickable, so the "don't leave unfinished financial actions visible" rule is satisfied by construction. Refunds have no engine either (deferred). Stripe auto-charge and WhatsApp/SMS remain owner-deferred.

## 4-6. Test totals
- **Security/isolation/financial/loyalty/auth gate:** 51 assertions, **49 PASS / 2 FAIL (both P2) / 0 P0-P1.**
- **Engine parity replay vs Flowesce (prior turn):** 16/16 MATCH + control failed as designed.
- **Policy-snapshot P0:** confirmed CLOSED in production (revenue stable across a live policy flip; read-time control diverged to prove it).

## 7. P0 issues
- **P0-1 — `sales.reversal_of does not exist`** breaks the dashboard on both live URLs. **FIXED in code** (5 refs removed; refund/reversal state was deferred, so the terms were no-ops). **Not yet deployed.** This is the only P0.

## 8. P1 issues
None open. (Timezone and full browser onboarding are untested *this build* — see conditions, treated as a pre-merchant gate, not an open defect.)

## 9. Fixes completed this pass
- P0-1 `reversal_of` removed from `app/index.html`; schema-drift sweep of every `.select()`/`.insert()`/`.update()`/`.rpc()` in the app found **no other mismatch**.
- Q9 (service commission always zero) fixed + v12a/v12 applied (prior turn).

## 10. Remaining P2/P3 backlog
- **P2:** `sales.client_id` and `appointments.service_id` are simple FKs, not tenant-composite — a tenant can reference *another tenant's* client/service id **within its own partition**. RLS blocks all reads of and writes into the other tenant, so this is referential hygiene, not exposure (proven). Fix = mirror the composite same-tenant FK pattern already used on `payments`. Harden before or shortly after pilot.
- **P2:** Week-view bucketing still uses browser-local time (works on an SGT browser; fragile off-SGT).
- **P3:** Q14 (package commission timing), Q15 (completion drops `branch_id`), Q16 (FEFO re-deduct on re-complete), full Flowesce parity (22 modules), refunds, the money-module UIs.

## 11. Tenant-isolation result
**PASS.** As a real `authenticated` Tenant-A principal (owner, staff, anon, and rota-only null-user), every read of B's clients/appointments/sales/loyalty/staff/branches/revenue and every cross-tenant write/attach/RPC **failed closed** with real engine errors. Canary control (as `postgres`, RLS bypassed) *did* see B's data, proving the harness is falsifiable. 2 P2 FK-hygiene deviations, no exposure.

## 12. Financial-integrity result
**PASS, 0 failures.** Revenue = sum of rows whose own snapshot `counts_as_revenue` (not a live join); gift-card issuance excluded; explicit-false/explicit-true/null-inherit all correct; idempotency keys prevent double-charge.

## 13. Loyalty-integrity result
**PASS, 0 failures.** One sale cannot earn twice (unique index blocks the re-fire, shown). Package purchase ≠ visit by default; session use = visit. Membership earns nothing. Referral qualifies once. Balances are views over append-only ledgers — no mutable balance to diverge.

## 14. Authentication result
**PASS.** Anon cannot read financial tables; normal staff cannot call owner-only policy functions (`has_perm` denial shown); TRUNCATE revoked fleet-wide (v11c). Note: signup had no email-confirmation gate in prior testing — acceptable for a controlled pilot, flag for later.

## 15. Timezone result
**NOT RE-TESTED this build (condition C3).** Portal date round-trip was fixed and verified in v1.6 (customer picks 2 Jul 3pm → staff see 2 Jul 3pm); the `sgt()`/`sgIso()` +08:00 helpers are still present and the P0 fix didn't touch date logic. Must be re-confirmed in-browser post-deploy before real merchants.

## 16. Deployment result
Pipeline works (800a8d9 deployed cleanly). **Current live build is broken** by P0-1. Two projects serve the app — owner must pick the canonical pilot URL.

## 17. Database migration status
17 applied, verified live. No unapplied migration is required for the pilot. (Written-but-unapplied: the v12-series is already applied; nothing pending blocks launch.)

## 18. Rollback readiness
- **UI:** Vercel keeps prior deployments; instant rollback to any READY build via the dashboard. The last-good pre-`reversal_of` build is a rollback candidate.
- **DB:** no migration in this launch step. All engine changes are already live and were each verified by rolled-back chain tests before applying.

## 19. FINAL DECISION — CONDITIONAL GO
The included pilot scope is **safe on security, tenant isolation, and financial/loyalty integrity** — the dimensions the owner ranked 1-3. The pilot may launch **only** after these conditions, none of which is a redesign:

- **C1 — Deploy the P0 fix.** Production is broken until the `reversal_of` build ships. (md5 `1ba102b1370feff5468243b44174deb1`.)
- **C2 — Pick ONE canonical pilot URL** and ensure it serves the fix. If both `frenly-app` and `loyalty` stay live, both must get the fixed build — leaving either on the old build re-exposes P0-1.
- **C3 — Post-deploy browser smoke test, green, before inviting real merchants:** onboard a fresh QA merchant → login → create service + customer → book via portal (confirm **2 Jul 3pm shows as 2 Jul 3pm in SGT**) → complete appointment → dashboard renders with numbers → logout/login persists. This is the only gate that can't run until the fix is live.

Not blocking, do soon: the 2 P2 composite-FK hardenings.

## 20. Exact launch steps
1. Owner resolves C2: canonical URL = `______` (recommend `frenly-app.vercel.app`; repurpose or redeploy `loyalty` deliberately).
2. Commit the fix: `git add app/index.html && git commit -m "fix: drop sales.reversal_of refs (column deferred with refunds) — unblocks dashboard"`.
3. Push: `git push origin master:main`.
4. Deploy to the canonical project: `npx vercel deploy --prod` (link first if needed). Verify **live ETag == `1ba102b1370feff5468243b44174deb1`** and that the served HTML no longer contains `reversal_of`.
5. Run the C3 smoke test on the deployed URL.
6. If C3 is green → **GO live to pilot merchants.** If any C3 step fails → NO-GO, fix, redeploy.
7. Day-1 monitoring: watch for any `column ... does not exist` / PostgREST 400s in the browser console; watch `get_revenue_summary` for errors; confirm no cross-tenant rows ever render.
