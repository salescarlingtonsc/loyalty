# P0-TEST-CREDENTIALS-015 — Test accounts, known credentials, API keys, migration access

## 1. Classification

**OWNER-ACTION-SCRIPTED.** This is an inventory-and-rotate action against live identity/secret stores
this agent cannot read or write (Supabase Dashboard service-role key, Vercel environment variables,
any provider dashboards) — it is inherently a human action, not something evidence-plannable down to a
script.

**Verified today (partial, from what this agent's read-only access can see):**
- `db/tests/v20_financial_concurrency.sh` (and the sibling concurrency harnesses) explicitly refuse to
  run without `V20_CONFIRM_DISPOSABLE_DB=YES` and reject a `DATABASE_URL` containing an embedded
  password, requiring `PGPASSWORD` separately — i.e. the repo's own tooling already tries to keep
  credentials out of shell history and command-line arguments. That is a good practice signal but is not
  itself proof that no *stale* credential is still valid somewhere.
- `docs/supabase-sync/CLI_RUNBOOK.md` independently documents the same discipline for the migration
  harness (`OLD_DB_URL`/`NEW_DB_URL` from environment only, never as arguments).
- This agent cannot enumerate Supabase Auth users, API key history, or Vercel secrets — this whole gate
  is genuinely outside this agent's reach and must be performed by a human with Dashboard/provider
  access.

## 2. Preconditions

- Dashboard/provider access to: Supabase Auth (user list), Supabase API settings (key history/rotation),
  Vercel project environment variables, and any other provider credential created during development or
  migration (e.g. anything used in `docs/supabase-sync/CLI_RUNBOOK.md`'s dump/restore process).
- A list of every known test login or shared password used during development (this is institutional
  knowledge, not something in the repo).

## 3. Procedure

1. Enumerate Supabase Auth users on `gadpooereceldfpfxsod`; identify any created for development/testing
   and either remove them or label/isolate them from merchant reporting (the manifest's own success
   criteria: "Synthetic smoke accounts are isolated, labeled, and excluded from merchant reporting or
   removed after verification").
2. Rotate the Supabase service-role key and any other credential shared during development, migration,
   or the `docs/supabase-sync/CLI_RUNBOOK.md` cutover process, plus any third-party provider key touched
   during that work.
3. Rotate any known test login password.
4. Recheck least-privilege: confirm operator/service accounts use named roles, not a shared credential,
   and that each has a recovery owner.
5. Re-run whatever synthetic accounts remain (e.g. those used for `P0-POST-CUTOVER-SMOKE-016`) and
   confirm they are clearly labeled as synthetic, not counted in merchant-facing reporting.

## 4. Evidence capture

- Artifact path: `docs/launch/.evidence/<run-id>/P0-TEST-CREDENTIALS-015.json`
- Example `checks`: `{"testAccountsInventoried": true, "testAccountsRemovedOrIsolated": true,
  "serviceRoleKeyRotated": true, "devMigrationCredentialsRotated": true,
  "knownTestLoginsRotated": true, "leastPrivilegeRecheckPassed": true,
  "syntheticAccountsLabeledAndExcluded": true}`
- This is the single gate where redaction discipline matters most: never place any actual credential,
  key, password, or the literal string `service_role` value in the artifact (the checker's
  `UNSAFE_VALUE_PATTERNS` explicitly greps for the word `service_role` and JWT-shaped strings and will
  reject the whole artifact) — record only "rotated: yes/no" and a rotation date.
- Hash-pin and register per `INDEX.md`.

## 5. Estimated wall-clock time

45-75 minutes, mostly the enumeration step; rotation itself is quick once the list is built.
