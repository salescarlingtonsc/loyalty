# PS-2 LIVE v65a (plan-config hardening) — Independent Review Verdict

## VERDICT: `PASS V65A`

Independent adversarial review of the **exact frozen commit** (verified from bytes + execution).

- **Frozen commit:** `63fd33ed5ee5499d5e1c5eadb982709eb18b38a6` (branch `codex/phase0-transaction-foundation`)
- **Canonical:** `db/migrations/20260724_frenly_v65a_ps2live_plan_config_hardening.sql`
- **Mirror:** `supabase/migrations/20260725010000_frenly_v65a_ps2live_plan_config_hardening.sql`
- **SHA-256 (both, byte-identical):** `b13e9a2c9c3c4ba8c94bcae1f46b20deb52233e3746f247a743bd58995e0b245` — **MATCHED**
- Pure CREATE-OR-REPLACE of exactly 5 functions (`app.sv_plan_assert_config`, `publish_sv_plan_version`,
  `discard_sv_plan_draft`, `retire_sv_plan`, `reactivate_sv_plan`); no new tables, no DDL, no schema
  change, no lot/movement/authority write. v65 files untouched.

## Requirement groups — all present + correct (bytes + execution)
1. **Complete idempotency hashes** — publish `{op,business,draft,expected_revision,override_reason:norm}`;
   discard `{…,expected_revision,reason:norm}`; retire/reactivate `{…,reason:norm}`. Same key + changed
   override_reason / expected_revision / reason → `22023` on all of publish/discard/retire/reactivate;
   identical normalized request → verbatim replay with exactly 1 operation/version/audit/status row (no
   duplicates). jsonb canonicalises → argument order does not affect the hash (verified). create_draft/
   clone/guardrails hashing untouched.
2. **Typed plan_id UUID** — malformed plan_id → `22023` (no raw `22P02`).
3. **Display-name contract** — republish of a renamed draft updates `sv_plans.name` in-txn + one
   `SV_PLAN_RENAMED` audit (old/new); prior version snapshot byte-unchanged; first publish and same-name
   republish produce no rename row.
4. **Robustness** — `2147483647` accepted, `2147483648` → `22023` (correct int4 boundary); all-blank
   category array → `22023`; explicit `v_active is true / is not true`.

The 5 replaced bodies differ from their v65 form ONLY by the pinned changes (confirmed by file diff AND a
deployed-`prosrc` diff between a v65-only DB and a v65+v65a DB). All RPCs retain SECURITY DEFINER + pinned
search_path + revoke/grant + owner-only. v65 suite still passes (behaviour preserved).

## Evidence run (independent)
v65→v65a apply clean on PG17; `V65 SUITE PASS` + `V65A SUITE PASS`; own adversarial probe battery
(idempotency replay/conflict with row-count assertions on all 4 ops, rename + version immutability,
plan_id/int4/category validation, jsonb order-independence) all pass; `npm run validate` 461/0 + build;
`git diff --check` clean; manifest/order counts bumped exactly as pinned.

## Residual note (LOW, non-blocking, NOT CHANGES REQUIRED)
Integer inputs **beyond BIGINT range** (>9,223,372,036,854,775,807 — i.e. >9.2 quintillion cents) still
throw raw `22003` from the `::bigint` intermediate in the range guard, before the `> int4_max` comparison
(`…v65a…:55-56` price/bonus, `:62-64` nullable ints). NOT a regression (v65 threw `22003` at the same cast
for such values); the entire realistic int4→bigint window — including the boundary `2147483648` — is
correctly rejected with typed `22023`; impact is error-code fidelity only at physically-impossible
magnitudes, input still rejected, txn aborts, nothing written, zero security/authority/value/data impact.
Recommended (not required) future hardening: compare via `::numeric` or wrap the range casts in a sub-block.
