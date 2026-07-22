# P0-RLS-GRANTS-004 — Adversarial RLS and function-grant verification

## 1. Classification

**OWNER-ACTION-SCRIPTED.** The exact test the gate requires already exists and is designed to run
against production or a rehearsal branch with real principals:
`db/tests/rls_adversarial_isolation.sql`. It needs a human with a direct (non-anon-key) database
connection to run it — this agent's `execute_sql` access is read-only-SELECT and cannot `SET ROLE` /
mutate `request.jwt.claims` the way the suite requires, and must not perform even the suite's
rolled-back writes.

**Verified today (read-only, supports but does not substitute for the adversarial run):**
- Pulled the full function inventory for `public` and `app` (277 functions) with
  `has_function_privilege(..., 'EXECUTE')` for `anon`/`authenticated`/`PUBLIC` and each function's
  `proconfig`. Result: **0 of 253 `SECURITY DEFINER` functions lack a pinned `search_path`** (all show
  an explicit `search_path=...` entry) — this fully closes the classic search-path-hijack risk class
  across the board.
- Only 1 `SECURITY DEFINER` function in `public` is anon-executable
  (`get_customer_phone_otp_capabilities()`, see `P0-PUBLIC-ABUSE-002.md` — no data access, no write).
- Of the 47 `rls_enabled_no_policy` tables from the security advisor, 46 have **zero** table-level
  `SELECT`/`INSERT` grants for `anon` or `authenticated` (checked via `has_table_privilege`) — RLS with
  no policy plus no grant is doubly fail-closed. One exception, `public.leads`, has `SELECT` granted to
  both `anon` and `authenticated` with no matching policy — currently inert (RLS blocks all rows) but
  flagged as a hardening item in `ADVISOR_TRIAGE_2026-07-22.md` (NEEDS-FIX, not launch-blocking).
- The 113 `authenticated_security_definer_function_executable` warnings are the platform's own
  intended architecture (every module writes through a `SECURITY DEFINER` RPC that is expected to check
  tenant/staff ownership internally, not through table grants). That internal check is exactly what
  `rls_adversarial_isolation.sql` exists to prove at runtime with real principals — a static catalog
  read cannot substitute for it.

## 2. Preconditions

- A direct Postgres connection to `gadpooereceldfpfxsod` (or an isolated rehearsal branch first) with
  enough privilege to `SET ROLE authenticated` and set `request.jwt.claims`, per the suite's header
  comment. Not the anon/publishable key.
- At least two distinct tenants each with an active, non-super owner, and at least one super-admin
  account present in the target — the suite's setup block queries for these and raises `SETUP:` if it
  cannot find them; synthetic fixtures are acceptable.
- `psql`.

## 3. Procedure

1. Read the suite once before running it: `db/tests/rls_adversarial_isolation.sql`. It is written as
   `begin; \ir fixtures/pristine_chain_fixture.psql; do $adv$ ... end; $adv$; ` — i.e. it is designed to
   run inside one transaction that a human controls the `commit`/`rollback` of; do not let any wrapper
   auto-commit it. Confirm the end of the file rolls back (or explicitly `rollback;` yourself
   immediately after).
2. Run it against production (or the rehearsal branch, if the owner prefers to prove it there first):
   ```bash
   cd db/tests
   psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f rls_adversarial_isolation.sql
   ```
   The suite itself checks, per its header: cross-tenant reads/writes on
   `clients, sales, appointments, credit_ledger, payments, points_ledger, staff` return **empty-or-
   privilege-denied** for a real non-super owner against another tenant; ghost/anon identities; and a
   super-admin's read-only reach.
3. Also run `db/tests/v21_security_hardening.sql` (the other suite named explicitly in
   `POST_CLAUDE_RUNBOOK.md` step 6) the same way, and confirm it reports its checks on: anonymous/PUBLIC
   `SECURITY DEFINER` execution, the v19 service-only allowlist, RLS helper grants, search paths, direct
   intake privileges, and always-true write policies.
4. Re-pull the Supabase security advisor (`get_advisors type=security`) immediately after, and diff it
   against `ADVISOR_TRIAGE_2026-07-22.json` to confirm no new anon-executable or unpinned-search-path
   function has appeared since this plan was written.
5. Capture: transaction outcome (rolled back, not committed), pass/fail per assertion, and the advisor
   diff — no real tenant/business names or UUIDs from production, use role labels only
   ("ownerB/tenantB", "ownerA/super-admin") as the suite itself does.

## 4. Evidence capture

- Artifact path: `docs/launch/.evidence/<run-id>/P0-RLS-GRANTS-004.json`
- Example `checks`: `{"crossTenantReadsDenied": true, "crossTenantWritesDenied": true,
  "ghostAndAnonDenied": true, "superAdminReadOnlyConfirmed": true, "v21HardeningSuitePassed": true,
  "searchPathAuditZeroUnpinned": true, "advisorDiffClean": true}`
- `summary`: counts of tables/assertions checked and pass/fail totals only — no UUIDs, emails, or
  connection strings (the checker's unsafe-content scan will reject a `postgres://` value or a
  JWT-shaped string in the artifact).
- Hash-pin and register per `INDEX.md`.

## 5. Estimated wall-clock time

60-90 minutes, most of it fixture setup on first run; a rehearsal-branch dry run first is recommended
given the suite's own setup-precondition checks.
