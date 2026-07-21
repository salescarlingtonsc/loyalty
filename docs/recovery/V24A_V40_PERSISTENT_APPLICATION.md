# v24a-v40 persistent disposable-database application

Date: 2026-07-21 (Asia/Singapore)

Target: owner-authorized disposable development/test project `gadpooereceldfpfxsod`, PostgreSQL
17.6. This record is not production, deployment, browser, staging or release evidence.

## Apply result

Sol independently accepted the exact canonical chain and controlled apply procedure. The four
existing Frenly cron jobs were fingerprinted, confirmed idle and unique, and disabled in a committed
control transaction. The 20 canonical migrations were then applied in manifest order inside one
transaction. Each original SQL file's exact bytes were inserted into its matching
`supabase_migrations.schema_migrations` row in that same transaction.

Database result marker:

```text
persistent-v24a-v40-canonical-apply-passed
```

The first generated batch was rejected at parse time because its history-array dollar quote had one
extra delimiter. PostgreSQL parsed no statement and executed no `BEGIN`; verification showed the
database remained at 45/45 versions with all four cron jobs disabled. The local-only adapter was
corrected, its boundary was rechecked, and the second atomic batch passed. No migration row was
invented, skipped, reordered or manually repaired.

## Installed-schema verification

- migration history: 65 rows, 65 unique versions and 20 unique pending names;
- all 20 pending statement octet lengths and SHA-256 hashes match canonical local files;
- public tables: 99/99 RLS enabled and owned by `postgres`;
- browser definer exposure: zero anon and zero PUBLIC execution;
- definer search paths: zero unsafe public/app functions;
- customer flags: all six remain false;
- Realtime: exactly `appointments`, `booking_requests` and `notifications`;
- cron: the four captured definitions, schedules, database, username and command hashes were restored
  exactly, with four active, zero disabled and zero duplicate names;
- balances: points ledger 345, points batches 345, credit 12000 cents, zero mismatched customers;
- unchanged rows: 10 sales, 7 points entries, 3 credit entries, zero payments and zero redemptions;
- package state: one client package with five sessions remaining; and
- installed-schema SQL suites: all 20 passed inside isolated savepoints and a final rollback, returning
  `persistent-schema-v24a-v40-rollback-suites-passed`.

Local verification also passed 231/231 Node tests, static quality, runtime-config, both migration
manifests, canonical-plan validation and static build.

## Advisor review and accepted debt

Security advisors reported 78 authenticated `SECURITY DEFINER` functions. Those functions match the
reviewed authenticated RPC surface; all have internal authorization, pinned search paths and no
anon/PUBLIC execution. RLS-without-policy notices identify private deny-by-default tables.

`public.leads` retains inert browser `SELECT`, `REFERENCES`, `TRIGGER` and `MAINTAIN` grants while RLS
has zero policies. SELECT returns no rows; all writes and application/RPC paths are closed. Luna
recorded this as a strict least-privilege deviation. Sol independently accepted it as non-blocking P2
defense-in-depth debt for the current v24a-v40 scope. Any zero-grant repair must be a new, separately
reviewed forward migration; historical v21 must not be rewritten.

Performance advisors reported 201 unindexed foreign-key notices, 88 multiple-permissive-policy
notices, 34 unused-index notices and one Auth connection-pool informational notice. These are
optimization debt, not integrity failures, and should be measured before mechanical index or policy
changes.

## Remaining concurrency evidence

The reviewed v37 and v40 shell harnesses need at least two simultaneous PostgreSQL sessions. The
available managed connector serializes calls: a self-releasing lock-holder probe completed before a
second call could observe it, so no concurrency claim was made. No backend was terminated and no
temporary remote infrastructure was created. One clearly synthetic `V37 MCP concurrency` fixture
business was created by the failed-to-observe probe. It remains untouched by this local remediation.
A separately scoped cleanup command now lives at
`db/tests/cleanup_v37_mcp_concurrency_fixture.sh`; it defaults to a read-only inventory and requires
both the disposable-database guard and the exact fixture-specific confirmation phrase before invoking
the shared UUID/name/slug-guarded cleanup transaction.

Both concurrency harnesses now use bounded five-second holders that self-release naturally. They
never terminate a backend. Their intended connection contract is a passwordless PostgreSQL URL plus
`PGPASSWORD`; embedded URL userinfo passwords, percent-encoded userinfo separators and password-like
query parameters are rejected without printing the URL. Every foreground connection inherits a
30-second statement timeout and 10-second lock timeout, while holder and worker sessions retain
tighter task-specific limits. Each run derives unique application names from its preallocated owner
UUID, and polling compares those exact names.

UUIDs and exact synthetic emails are allocated before fixture writes. On a nonzero exit, traps first
signal only their owned child session PIDs, then wait for them before cleanup. Cleanup is one bounded
transaction and assumes every selected non-internal user trigger is initially origin-enabled
(`tgenabled = 'O'`); it refuses any other pre-existing trigger mode, temporarily disables only USER
triggers on the selected business table family, re-enables them, and asserts the origin-enabled mode
before commit. The executing database role must own those selected tables, and the disposable
database must be quiet enough for the bounded locks to complete. Exact business/auth identity guards
and zero-row postconditions remain mandatory. If cleanup fails, the harness emits only the first eight
sanitized, line-truncated log lines before deleting the temporary log; PASS is never printed.

Persistent schema and transaction behavior are accepted; true two-session v37/v40 concurrency
evidence remains a separate gate requiring a direct disposable-database connection.
