# v24a-v40 database rehearsal evidence

Date: 2026-07-21 (Asia/Singapore)

Target: owner-authorized disposable development/test project `gadpooereceldfpfxsod` on PostgreSQL
17.6. No customer rows were read; only catalog metadata and aggregate counts were inspected.

The rehearsal executed the 20 pending migration bodies in canonical order inside one outer
transaction. It then executed each of the 20 SQL acceptance suites inside an isolated savepoint,
resetting database role and JWT session settings between suites. The final statement rolled back the
outer transaction.

Result marker returned by the database:

```text
full-v24a-v40-rollback-rehearsal-passed
```

Post-rehearsal non-persistence check:

- migration rows: 45;
- distinct migration versions: 45;
- latest version: `20260719190540` (v24);
- v24a-v40 sentinel tables present: 0;
- points ledger balance: 345;
- points batch remaining: 345; and
- credit ledger balance: 12000 cents.

The test-only v40 corruption fixture does not set `session_replication_role` and never disables all
triggers. It uses the application's guarded credit-ledger write seam, validates deferred constraints,
temporarily disables only `trg_loyalty_redemption_provenance_immutable`, restores that named trigger,
and is rolled back with its suite savepoint and the outer transaction.

This evidence proves compatibility with the existing disposable database and complete rollback-only
behavior. It is not a production verification, deployment approval, or release approval.
