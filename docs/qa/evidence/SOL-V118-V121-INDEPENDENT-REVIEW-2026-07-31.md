# Sol independent review — V118 through V121

Date: 2026-07-31
Verdict: **accepted as `VERIFIED_LOCAL` only**
Release authorization: **owner supplied `RELEASE APPROVED push and deploy` on 2026-07-31; production evidence pending**

## Reviewed scope

Sol independently reviewed the recovered `Audit feature sync and usability`
work through:

- V118 task-first workspace and appointment UX;
- V119 explicit availability, effective-module refresh, and capacity truth;
- V120 durable staff blocked times; and
- V121 appointment completion → sale/loyalty → customer projection truth.

Luna performed a separate read-only review. Terra was the builder and did not
approve its own work.

## Independent evidence

- Full repository gate:
  `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate`
  → **1,311 passed, 0 failed**, with quality, runtime configuration,
  migration manifests, the 161-file canonical chain, and static build green.
- V120 rollback SQL passed on disposable PostgreSQL 17.
- V120 real two-session block/block and block/appointment races passed in both
  writer orderings. The dedicated database was dropped and absence verified.
- V121 rollback SQL passed on a fresh 161-migration PostgreSQL 17 database:
  enabled Loyalty produced one SGD 60 sale and one +600 earn; replay produced
  no duplicate; firm-disabled, branch-disabled, and branch-read-only Loyalty
  produced their sales with zero new points; wrong-branch completion produced
  no mutation; all three customer-safe readers agreed with the persistent
  enabled balance. The dedicated database was dropped and absence verified.
- V120/V121 source and Supabase mirrors are byte-identical.
- `git diff --check` is clean.

Reviewed migration hashes:

```text
c51a23e5554b52a1209885ccbc2d5702ebb62514079961a79ebc8a708fec6340
  V120 staff blocked-time migration
571cd4e6e367d1b8d540d739df9cc6f74db9ffeda1f9f379e82ae3aa057629c0
  V121 effective Loyalty sale-earn boundary migration
```

## Residual release blockers

This is local acceptance, not release acceptance. The following remain:

- authenticated owner/front-desk/read-only/customer journeys against the exact
  candidate database at desktop and a 390px-class viewport;
- target create → reload/reconnect → remove persistence and cross-branch
  blocked-time redaction;
- appointment-linked reversal/correction → customer-history acceptance;
- `TEAM-001` overnight and authenticated stale/branch evidence;
- isolation of the mixed dirty V115–V121 worktree onto an exact candidate based
  on current `origin/main`; and
- the owner's exact `RELEASE APPROVED` authorization before commit, push,
  production migration, deployment, or production smoke.
