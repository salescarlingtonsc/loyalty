# WP-00/WP-01 Local History Recovery and Baseline Design

Status: local-only evidence was exhausted, then owner-authorized catalog recovery completed. The
clean-room baseline remains a reviewed fallback design and is not required for the current deployed
history.

2026-07-21 catalog update: all 45 deployed migration rows were recovered from the authorized
development/test project's migration catalog with 81 exact statement records and per-statement
SHA-256 evidence. The local-evidence classifications below are retained as an audit of what was and
was not recoverable from the repository alone; they are not the final catalog classification. The
final classification is exact statement evidence for all requested v3-v7, v11c, v14a-d and v15a-d
objects. Only the original raw file separators/trailing bytes for the 37-statement `remote_schema`
row remain unavailable, so that executable file is explicitly a deterministic reconstruction of
exact statements rather than a claim of exact original file bytes.

This record remains non-executable and does not authorize migration application, infrastructure
creation, production access, or treating inferred SQL as historical SQL. A later owner authorization
identified project `gadpooereceldfpfxsod` as disposable development/test and permitted catalog
inspection. Exact recovery and canonical ordering are now tracked in
`docs/recovery/CANONICAL_MIGRATION_ORDER.md`; no database mutation is part of this recovery step.

## Trusted local search boundary

The recovery pass inspected, without modifying them:

- every reachable Git ref, branch and tag;
- all reflogs and stash references;
- deleted-file history and every object named by `git rev-list --objects --all`;
- unreachable commits, trees and blobs reported by `git fsck --full --no-reflogs --unreachable`;
- repository SQL, notes, tests, docs, generated-type history and later migration replacements;
- repository-local hidden artifacts and Supabase CLI metadata;
- local Supabase CLI trace filenames/content matches for the missing migration names; and
- local files with dump, backup, archive, migration or schema names, excluding dependency caches.

No exact missing statement body or statement hash was found. No deleted or unreachable executable
v3-v7, v11c, v14a-d or v15a-d migration exists. The local Supabase traces contain no matching
migration names, and the workspace contains no database dump/backup archive carrying them.

The note hashes below prove only the exact bytes of the local notes. They are not migration SQL
hashes and must never be promoted into history checksums:

| Local evidence | Raw-byte SHA-256 |
|---|---|
| `20260716_frenly_v3_engine.note.md` | `b3de36385078edf2d26b7cff498e790e8dbc774f42131921e988935ba05ce292` |
| `20260716_frenly_v4_onboarding.note.md` | `fe8d09c3f41dbe60fbef185f6ce509ae2a10298aedfab95eb76ad26d61fa66a9` |
| `20260716_frenly_v5_memberships_giftcards.note.md` | `658dd890cb5b2df96be3266d1701ca9c52c453acb6d3ee0859966808ca7a00d3` |
| `20260716_frenly_v6_ops.note.md` | `eff331e5f961f90d4c94caadaf64613c424f8d95b3f7338befecb1c48c4f8fd5` |
| `20260716_frenly_v7_team_brand.note.md` | `4431b9096f2357cde7a6fc673ce74031ff1ac0af0f8da555881c9699ab90374c` |
| `20260718_frenly_v14_rls_billing_modules_till.note.md` | `4345db683f2def1d0f5a0eb4c336540274189b5fce3602dd728eb1930fd9aa14` |
| `20260718_frenly_v15_bookings_capacity_notify.note.md` | `bf110143e25f9e2c8a69e07f7768a24acc7eb54c40216f193c11bd8839813fbc` |

## Recoverability classification

`Exact statements` is authoritative only when the original SQL bytes and an independently anchored
hash exist. `Object evidence` describes how much can be learned without inventing historical SQL.

| History reservation | Exact statements/hash | Object evidence | Local evidence and limit |
|---|---|---|---|
| v3 engine | **MISSING** | **PARTIAL** | Note and later v20/v23 replacements identify expiry, points batches, referral, consent and audit contracts. Original tables, policies, triggers, backfill and cron statements are absent. |
| v4 onboarding RPC | **MISSING** | **INFERRED** | Note plus later v11a/v25 replacements establish the atomic onboarding contract. Exact original body and grants are absent. |
| v5 memberships/gift cards | **MISSING** | **PARTIAL** | Note and later v20 function bodies expose current behavior. Base constraints, policies, triggers, audits and cron statements are absent. |
| v6 operations/modules | **MISSING** | **PARTIAL** | Note plus v8/v12a reveal current appointment function behavior. The original completion trigger and complete resources/inventory/waitlist/package/bundle DDL are absent. |
| v7 team/brand | **MISSING** | **INFERRED** | Note and surviving UI establish invite and brand contracts. Exact invite DDL, functions, policies and grants are absent. |
| v11c revoke truncate | **MISSING** | **PARTIAL** | Parity docs and v12 comments name `frenly_v11c_revoke_truncate` and report fleet-wide authenticated `TRUNCATE` revocation. No SQL, note, complete table list or hash exists. |
| v14a-d adjuncts | **MISSING** | **PARTIAL** | The detailed v14 note names all four migrations and many objects. `v14_platform.sql` explicitly depends on them; it is not their replacement. Generated policies, function bodies, seed/backfill and exact hardening statements are absent. |
| v15a-d | **MISSING** | **PARTIAL** | The detailed v15 note names all four migrations, tables, RPC contracts, Realtime and cron behavior. Exact concurrency, trigger, RLS, publication and cron statements are absent. |

There are zero locally **EXACT** recoveries. No historical SQL file may be created from the partial or
inferred columns above.

## Object-level recovery inventory

Classification is against the missing historical definition, not whether a later migration happens
to contain a current replacement body. “Unnamed” is intentional where local evidence gives behavior
but not the deployed object name.

| Object or family | Kind | History | Provenance | Class | Unresolved definition components |
|---|---|---|---|---|---|
| `loyalty_programs.expiry_mode`, `expiry_days` | columns/constraints | v3 | v3 note; later v23f repair | PARTIAL | Original defaults, checks, backfill and statement bytes |
| `points_batches` | table | v3 | v3 note; later v20/v23 consumers | PARTIAL | Original columns, constraints, indexes, RLS and backfill SQL |
| `app.run_points_expiry()` | function | v3 | v3 note; current body in v20 | PARTIAL | Original body, owner, grants and historical search path |
| `public.run_expiry_now(uuid)` | RPC | v3 | v3 note; current body in v20 | PARTIAL | Original body, grants and errors |
| unnamed points-expiry job | cron job | v3 | v3 note gives 19:00 UTC schedule | PARTIAL | Job name, command bytes, database/role and activation statement |
| `referral_programs` | table | v3 | v3 note; later sale-trigger consumers | PARTIAL | Original DDL, RLS, indexes and seed/backfill behavior |
| `clients.referral_code` and unnamed generator/unique set | column, trigger, index | v3 | v3 note | PARTIAL | Generator body/name, exact uniqueness semantics and backfill SQL |
| one-referral-per-referred-client rule | constraint/index | v3 | v3 note | INFERRED | Object name, predicate, null behavior and statement bytes |
| `app.on_sale_recorded()` v3 referral behavior | trigger function revision | v3 | v3 note; many later full replacements | PARTIAL | Exact v3 body and preservation boundary |
| `consents` | table | v3 | v3 note; later v14/v15 references | PARTIAL | Original DDL, RLS, grants and append-only enforcement |
| `audit_log` | table | v3 | v3 note; many later writers | PARTIAL | Original DDL, RLS, grants and immutability enforcement |
| unnamed audit trigger set | triggers/functions | v3 | v3 note names covered relation families | PARTIAL | Exact trigger/function names, event coverage and bodies |
| `public.redeem_points(uuid,uuid)` | RPC | v3 | v3 note; later replacements in v20/v24/v34 | PARTIAL | Original body, grants and batch-drain implementation |
| `public.adjust_points(uuid,uuid,integer,text)` | RPC | v3 | v3 note; current body in v20 | PARTIAL | Original body, grants and audit behavior |
| referrals-module tenant backfill | data change | v3 | v3 note | INFERRED | Exact update predicate, prior values and affected row evidence |
| `public.create_business(text,text,text,text[])` | RPC | v4 | v4 note; later v11a/v25 replacements | INFERRED | Original body, return shape, search path, grants and side effects |
| `membership_plans` | table | v5 | v5 note; later consumers | PARTIAL | Original DDL, cadence checks, RLS and indexes |
| `memberships` | table | v5 | v5 note; later v20 consumers | PARTIAL | Original DDL, live-membership uniqueness, RLS and period checks |
| `public.enroll_membership(uuid,uuid,uuid)` | RPC | v5 | v5 note; current replacement in v20 | PARTIAL | Original body, grants, locking and idempotency |
| `app.run_membership_renewals()` | function | v5 | v5 note; current replacement in v20 | PARTIAL | Original catch-up bound, locking, owner and search path |
| unnamed membership-renewal job | cron job | v5 | v5 note gives 19:10 UTC schedule | PARTIAL | Job name, command bytes and activation statement |
| membership exclusion in `app.on_sale_recorded()` | trigger function revision | v5 | v5 note; later full replacements | PARTIAL | Exact historical predicate/body |
| `public.issue_gift_card` | RPC | v5 | v5 note; later v9/v11/v20 evidence | PARTIAL | Original signature/body, code generation, grants and sale semantics |
| `public.redeem_gift_card(uuid,text,uuid,integer)` | RPC | v5 | v5 note; current replacement in v20 | PARTIAL | Original body, locking, grants and partial-redemption rules |
| gift-card integration with `credit_ledger` | ledger behavior | v5 | v5 note; later function consumers | PARTIAL | Exact write route, constraints and audit linkage |
| unnamed membership audit trigger set | triggers/functions | v5 | v5 note | INFERRED | Names, covered events and exact bodies |
| `app.on_appointment_completed()` v6 | trigger function | v6 | v6 note; current bodies in v8/v12a | PARTIAL | Original body and security metadata |
| unnamed appointment-completion trigger | trigger | v6 | v6 note; later files only replace function | MISSING | Exact name, timing, event predicate and creation statement |
| `appointments.service_id`, `resource_id`, `note` | columns/FKs | v6 | v6 note; later consumers | PARTIAL | Types/defaults, FK actions, indexes and backfill |
| `resources` | table | v6 | v6 note; UI/later consumers | PARTIAL | Original DDL, RLS, grants and indexes |
| `product_stock` | view | v6 | v6 note; later inventory consumers | PARTIAL | Original query, security mode and grants |
| unnamed retail FEFO sale trigger/function | trigger/function | v6 | v6 note; current replacement in v20 | PARTIAL | Historical body, trigger metadata and under-stock policy |
| `waitlist` | table | v6 | v6 note; later v15 consumers | PARTIAL | Original DDL, status check, RLS and indexes |
| `package_plans`, `client_packages` | tables | v6 | v6 note; later v10/v34/v39 consumers | PARTIAL | Original DDL, constraints, RLS and indexes |
| `public.sell_package`, `public.use_package_session` | RPCs | v6 | v6 note; later replacements | PARTIAL | Original signatures/bodies, grants and idempotency |
| `bundles`, `bundle_items` | tables | v6 | v6 note; later UI/types references | PARTIAL | Original DDL, tenant FKs, RLS and indexes |
| `public.convert_booking_request(uuid)` | RPC | v6 | v6 note; later v15/v19 wrappers | PARTIAL | Original body, locking, grants and conversion guard |
| `staff_invites` | table | v7 | v7 note; v14 role-fix evidence | INFERRED | Original DDL, role/status checks, RLS and code index |
| `public.create_invite`, `public.accept_invite` | RPCs | v7 | v7 note; later allowlists/UI | INFERRED | Exact signatures/bodies, code generation, locking and grants |
| `businesses.brand_color`, `booking_policy` | columns/checks | v7 | v7 note; later UI/RPC projections | PARTIAL | Original types/defaults/checks and backfill |
| `public.get_business_public` v7 projection | RPC revision | v7 | v7 note; later v15/v19 replacements | PARTIAL | Exact v7 body, return type and grants |
| fleet-wide authenticated `TRUNCATE` revocation | grant set | v11c | parity docs; v12 comments | PARTIAL | Complete relation set, exact statements, defaults handling and hash |
| `super_admins`, `app.is_super_admin()` | table/function | v14a | v14 note; later v14-platform/v21 consumers | PARTIAL | Original DDL/body, owners, grants and seed statement |
| 46 unnamed `*_sa_read` policies | policy set | v14a | v14 note names scope/count | PARTIAL | Exact generated policy names/table list/expressions and statements |
| canonical `staff.role` / `staff_invites.role` checks | constraints/backfill | v14a | v14 note | PARTIAL | Constraint names, exact expressions and update SQL |
| `app.role_perms()` compatibility revision | function | v14a | v14 note; later permission consumers | PARTIAL | Original body and grants |
| `app.norm_phone(text)`, `clients.phone_norm` | function/generated column | v14a | v14 note; later consumers | PARTIAL | Exact helper body, generated expression and migration sequence |
| unnamed `(business_id,phone_norm)` partial unique index | index | v14a | v14 note | PARTIAL | Index name and exact predicate/statement |
| `subscriptions`, `app.billable_seats()`, `v_business_billing` | table/function/view | v14b | v14 note; v14-platform consumers | PARTIAL | Original DDL/bodies, security mode, policies and onboarding seed |
| `staff.modules`, `module_templates` | column/table | v14b | v14 note; later UI/functions | PARTIAL | Original DDL, checks, RLS and indexes |
| `app.can_module`, `app.staff_modules` | functions | v14b | v14 note; later policies/consumers | PARTIAL | Original bodies, volatility, owners and grants |
| `get_my_modules`, `set_staff_modules`, `save_module_template`, `apply_module_template` | RPCs | v14b | v14 note; later allowlists/UI | PARTIAL | Exact signatures/bodies, locking and grants |
| unnamed module RLS replacement set | policies | v14b | v14 note names relation families | PARTIAL | Exact policy names/expressions and statements |
| `businesses.join_enabled` | column | v14c | v14 note; v14-platform/later gateway consumers | PARTIAL | Original default/check/backfill statement |
| `get_join_page`, `join_program` | public RPCs | v14c | v14 note; later v19 wrappers | PARTIAL | Exact signatures/bodies, rate boundary and grants |
| `lookup_client_by_phone`, `record_sale_by_phone`, `quick_add_client` | till RPCs | v14c | v14 note; app and later security allowlists | PARTIAL | Exact bodies, locking, grants and side effects |
| `sales.idem_key` and unnamed partial unique index | column/index | v14c | v14 note; till idempotency consumers | PARTIAL | Original column/index statements and predicate |
| two unnamed v14 IMMUTABLE helper search-path repairs | function alterations | v14d | v14 note | MISSING | Complete helper identity arguments and exact ALTER statements |
| `booking_tables` | table | v15a | v15 note; later v24c consumers | PARTIAL | Original DDL, RLS, grants and indexes |
| `notifications` | table | v15a | v15 note; later UI/allowlists | PARTIAL | Original DDL, kind check, RLS, grants and indexes |
| booking settings on `businesses` | four columns/checks | v15a | v15 note | PARTIAL | Exact defaults/check names/backfill statements |
| booking lifecycle columns/check on `booking_requests` | columns/constraint | v15a | v15 note; later migrations | PARTIAL | Exact FK actions, status constraint name/expression and indexes |
| `appointments.table_type_id`; `waitlist.booking_request_id`, `table_type_id` | columns/FKs | v15a | v15 note | PARTIAL | Exact FK actions, nullability, indexes and backfill |
| `v_table_availability` | security-invoker view | v15a | v15 note | PARTIAL | Exact query, ownership and grants |
| Realtime publication/replica identity set | publication metadata | v15a | v15 note names three relations | PARTIAL | Exact ALTER PUBLICATION/REPLICA IDENTITY statements and prior state |
| `request_booking`, `get_booking_availability`, `get_business_public` | RPC revisions | v15b | v15 note; later v19 wrappers | PARTIAL | Exact bodies, locking, result types and grants |
| `list_my_appointments`, `request_change`, `app.phone_match_key` | RPC/helper revisions | v15b | v15 note; later gateways | PARTIAL | Exact bodies, helper definition and grants |
| `set_booking_settings`, `get_notifications`, `mark_notification_read`, `mark_all_notifications_read` | RPCs | v15b | v15 note; UI/allowlists | PARTIAL | Exact signatures/bodies, locks and grants |
| `import_bookings` | RPC | v15b | v15 note; later importer consumer | PARTIAL | Exact body, validation, error contract and grants |
| unnamed booking notification trigger set | triggers/functions | v15b | v15 note | INFERRED | Trigger names/events, function bodies and notification dedupe |
| `app.expire_stale_bookings()` and `frenly-booking-expiry` | function/cron job | v15b | v15 note gives per-minute schedule/name | PARTIAL | Exact body, owner/search path, cron command and activation statement |
| conversion idempotency guard | function revision/guard | v15c | v15 note | INFERRED | Exact object/body, exception contract and locking |
| booking marketing-consent propagation | function revision/data writes | v15d | v15 note | INFERRED | Exact request signature/body, escalation rule and consent statements |

## Option A: exact-history restoration

Option A remains preferred because it is the only route that can preserve original policy generation,
backfills, function semantics, cron and publication changes. It is no longer owner-blocked: recovery
from the authorized disposable project's migration catalog is in progress. Each reservation remains
non-deployable until its exact bytes and catalog hash are materialized and independently verified.

An item may move from blocked to exact only through this sequence:

1. Obtain an owner-approved copy from the preservation archive or the authorized disposable
   development/test project's migration catalog. Production remains out of scope.
2. Record the source artifact identifier, original migration version/name, raw byte length and SHA-256
   outside the mutable repository as the review trust anchor.
3. Verify the bytes contain exactly one named historical migration and no credentials, customer data,
   connection strings or unrelated statements.
4. Compare the statement hash with independently preserved history/catalog evidence. A filename or
   prose note is insufficient.
5. Preserve the exact bytes without normalization, formatting or inferred repairs. Corrections belong
   in a new migration, never in recovered history.
6. Replace the matching `missing-history-reservation` only after independent Sol review. Re-run the
   manifest generator and retain its new external digest.

If any step fails, the reservation remains `exactEvidence: "missing"`.

## Option B: clean-room baseline design fallback

Option B is a new, reviewed schema baseline, not a reconstruction of historical migration text. No
executable baseline is authored in WP-01.

### Required inputs

- an owner-approved catalog-only export from an isolated source or preservation artifact;
- server/Postgres/Supabase component versions and enabled extensions;
- schemas, types, relations, sequences, views and generated expressions;
- functions/procedures with identity arguments, result types, language, volatility, security mode,
  owner, full definition and configured `search_path`;
- constraints, indexes, triggers and dependency ordering;
- relation owners, grants/default privileges, RLS enable/force state and complete policies;
- Realtime publication membership and replica identity;
- cron job schedule/command definitions with jobs disabled for rehearsal;
- non-sensitive reference/config seeds separated from tenant/customer data; and
- aggregate reconciliation evidence for tables and financial/loyalty liabilities.

### Baseline package design

1. `catalog/` — normalized, redacted catalog snapshots with raw hashes.
2. `baseline/` — a newly authored idempotence-free, apply-once schema artifact generated from the
   reviewed catalog, with no claim that it equals missing history.
3. `post-baseline/` — existing forward migrations mapped to unique proposed deploy versions.
4. `verification/` — catalog, ACL/RLS, function, trigger, cron, Realtime and aggregate expectations.
5. `provenance.json` — source hashes, tool versions, reviewers, known exclusions and external anchor.

### Acceptance gates

- Build only in a disposable non-production environment with no production data.
- Apply the baseline once, then all forward migrations once, using the explicit manifest order.
- Require exact catalog/security comparison and all rollback, concurrency and adversarial suites.
- Prove browser configuration targets that environment and cannot target production in non-production
  mode.
- Do not insert fabricated v3-v15 rows into migration history. Record the clean baseline under a new,
  truthful version/name.
- Require independent Sol review before any release planning.

Supabase's current guidance recommends separate local, staging and production environments and testing
migrations before production release. Browser clients may contain a publishable key, or a legacy anon
key during transition, but never a secret/service-role key. See the official
[Managing Environments](https://supabase.com/docs/guides/deployment/managing-environments) and
[Understanding API Keys](https://supabase.com/docs/guides/getting-started/api-keys) guidance.

## Migration-order artifact and trust boundary

`db/migrations/migration-order.plan.json` is an explicit planning document. It reserves every locally
missing history item and lists every executable SQL file exactly once. It deliberately places v12a
before v12 and does not derive order by lexical filename sorting.

`scripts/migrations/generate-manifest.mjs` validates path containment, strict schemas, semantic names,
complete SQL coverage, reservation coverage and unique, valid, strictly monotonic proposed deploy
versions. It hashes each executable file's raw bytes and emits the manifest plus a digest file.

The generated `sourceDeployVersionCollisions` field also records the unresolved deploy-version
collisions in the source filenames. It is deterministic and covers executable SQL only:

- `20260717`: 7 executable migrations;
- `20260718`: 3 executable migrations;
- `20260719`: 5 executable migrations; and
- `20260720`: 28 executable migrations.

Accordingly, `sourceCollisionsResolved` is `false`. The unique proposed versions describe a reviewed
future naming plan; they do not repair or authorize applying the colliding source files.

The manifest and digest are mutable repository files, not an independent trust anchor. Existing plan
entries are append-only by policy: changing an existing path, order or proposed version requires a
new review record and explicit owner/Sol approval. A release process must preserve the accepted digest
outside the repository and compare it before applying anything. The current status
`planning_only_not_deployable` is a hard block, not advisory text.
