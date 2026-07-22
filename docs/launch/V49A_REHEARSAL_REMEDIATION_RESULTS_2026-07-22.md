# v49a local rehearsal remediation — implementation results

Date: 2026-07-22 (Asia/Singapore)

Status: implementation verification complete; independent frozen-tree evidence and Sol review remain required. No remote database, production data, deployment, commit, or push was used.

## Forward-only migration

- Added canonical v49a after v49 at deploy version `20260722140000`.
- Kept the `db/migrations` source and `supabase/migrations` target byte-identical.
- Replaced `clock_timestamp()` in the STABLE v48 appointment suggestion with one captured `statement_timestamp()` value.
- Added explicit `uuid[]` casts in the retained v20 reclassification and reversal implementations.
- Removed the unused v27 reward-draft variable.
- Guarded all three catalog-derived replacements against unexpected predecessor definitions and reasserted the existing search paths, security attributes, and ACL boundaries.

## Deterministic final-chain tests

- Clean local reset: PASS, 77 unique migrations, last version `20260722140000`.
- Final ledger state after rollback suites: 77 migrations, 0 businesses, 0 auth users.
- SQL/RLS/ACL rollback matrix: 35/35 PASS, including the focused v49a catalog suite.
- Focused Node static matrix: 41/41 PASS.
- Migration manifest check: PASS.
- Canonical materialization check: PASS.
- DB and canonical manifest SHA-256 companion checks: PASS.

The shared pristine fixture creates two deterministic synthetic businesses, confirmed owners, clients, one published loyalty configuration, and one exact super-admin read-only principal inside the including suite's transaction. Each including suite owns `BEGIN`/`ROLLBACK`; the shared fixture cannot commit independently.

## Concurrency implementation verification

All six repository concurrency harnesses passed locally:

- v20 same-key tender replay and competing credit balance race: PASS.
- v37 sale-versus-retention-publish immutable-version race: PASS (`1|1`, one shared config lineage, value `202`, two immutable versions).
- v40 tender-versus-redemption-reversal race: PASS (`0|1|0|100|100`).
- C45 activation/redeem/reversal/expiry concurrency: PASS.
- C46 inbox sync/state concurrency: PASS.
- v47 booking conflict and Quick Earn idempotency concurrency: PASS.

The v20, v37, and v40 setup phases now seed synthetic rows only with the privileged fixture connection. Every raced business operation runs as an authenticated principal through the current runtime RPC. v20 now uses the same exact-scope cleanup guard and passwordless URL policy as the later harnesses.

## Lint result

The five targeted v48 audit findings are absent from the final catalog: no volatile clock call in the STABLE suggestion function, both empty UUID arrays are explicitly typed, and the unused reward-editor variable is gone. Supabase DB lint still reports older unrelated unused-variable/retired-overload warnings; those were not silently widened into this forward migration.
