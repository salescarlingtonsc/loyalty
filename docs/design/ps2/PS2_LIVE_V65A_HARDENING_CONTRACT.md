# PS-2 LIVE v65a — Plan-Config Hardening (PINNED)

Narrow forward-only hardening of the **applied+accepted** v65 (commit c23518c, PASS V65). **Do NOT edit
or reapply v65.** New migration `frenly_v65a_ps2live_plan_config_hardening` (canonical
`db/migrations/20260724_frenly_v65a_ps2live_plan_config_hardening.sql`; mirror version `20260725010000`).
CREATE-OR-REPLACE of 5 existing functions only — no new tables, no schema change, no product scope.
Still config-only: zero sv_lot_movements/lots, authority stays `unbuilt`. Owner directive: this close-out
must precede v66.

## 1. Complete idempotency request hashes (directive P2.1)
Every idempotency `request_hash` must contain every semantically meaningful request field, so the same key
with any changed meaningful field raises the standard typed conflict (22023 from `app.sv_plan_idem_lookup`),
and an identical normalized request replays. Recompute `v_hash` in:
- **publish_sv_plan_version**: `{op:'publish', business, draft, expected_revision, override_reason: normalized}`
  (normalized = `nullif(btrim(coalesce(override_reason,'')),'')`).
- **discard_sv_plan_draft**: `{op:'discard', business, draft, expected_revision, reason: normalized}`.
- **retire_sv_plan**: `{op:'retire', business, plan, reason: normalized}`.
- **reactivate_sv_plan**: `{op:'reactivate', business, plan, reason: normalized}`.
(create_draft/clone/guardrails already hash their meaningful fields — unchanged.) No duplicate operations,
audits, status events or versions on replay (the envelope short-circuits before any write).

## 2. Typed plan_id validation (directive P2.2)
In `app.sv_plan_assert_config`, when `plan_id` is present, validate it is a well-formed UUID (attempt the
cast inside a sub-block; on failure raise typed **22023** with a plain message). No raw 22P02 reaches the
caller from `create_sv_plan_draft`'s later cast.

## 3. Plan display-name contract (directive P2.3 — preferred model)
The plan **container keeps stable identity** (`sv_plans.id`). On publishing a new version to an EXISTING
plan, `publish_sv_plan_version` updates `sv_plans.name` to the new `customer_facing_name` **in the same
transaction** and appends an `audit_log` (`SV_PLAN_RENAMED`) with `old_name`/`new_name` when it changes.
Sold `sv_plan_versions` snapshots stay immutable (each carries its own frozen `customer_facing_name`). Result:
`sv_plans.name` never silently disagrees with the latest published version's name. (On first publish the
container is already created with that name — no rename row.)

## 4. Low-risk robustness closures (directive P2.4 — close the 3 accepted V65 notes)
In `app.sv_plan_assert_config`:
- **int4 range**: reject any integer field (price/bonus and the nullable ints) whose value is `> 2147483647`
  or `< -2147483648` with typed **22023** BEFORE the int4 cast (kills the raw 22003).
- **category canonicalises-to-empty**: reject an `eligible_service_categories` array whose elements are all
  blank after trim (0 non-blank) with typed 22023 (mirror the existing empty-array rule).
In publish/retire/reactivate: replace nullable-boolean assumptions with explicit `v_active is true` /
`v_active is not true` (defense-in-depth; `sv_plans.active` is NOT NULL so behaviour is unchanged).

## 5. Invariants / house rules
Canonical + byte-identical mirror; forward-only (v61-v65 files untouched); every replaced public RPC keeps
`security definer` + pinned `search_path` + `revoke all ... / grant execute to authenticated`; owner-only;
integer cents; no value/authority writes; the 5 replaced function bodies differ from v65 ONLY by the pinned
changes above. Migration registered in both order-plans + manifests; counts bumped (db exec 83→84, canonical
chain 99→100, pending 54→55). PS-GATES tripwire unchanged.

## 6. Tests (db/tests/v65a_ps2live_plan_config_hardening.sql — rolled back) + full gate matrix
Idempotency: publish same-key+same-request → exact replay; publish same-key + changed override_reason →
conflict; publish same-key + changed expected_revision → conflict; discard same-key + changed reason →
conflict; retire same-key + changed reason → conflict; reactivate same-key + changed reason → conflict.
Validation: malformed plan_id → 22023; cents > int4 → 22023; whitespace-only category array → 22023.
Display: renamed plan → `sv_plans.name` tracks the latest published version + SV_PLAN_RENAMED audit; sold
version snapshot byte-unchanged. Safety: zero duplicate audit/status/version rows on every replay; zero sv
lots/movements; authority stays unbuilt. Then: fresh full replay through v65a; v65 + v65a suites; real
two-connection publish harness; all prior SQL suites; writer registry; RLS/ACL/SECDEF scans; npm run validate;
secret scan; git diff --check. Independent reviewer inspects the exact frozen v65a commit → PASS V65A /
CHANGES REQUIRED / BLOCKED.

## 7. After PASS V65A
Apply v65a (new forward migration); normalize ONLY its ledger version to `20260725010000`; verify authority
unbuilt + zero lots/movements; push + reconcile remote main. Only then may v66 begin. Do NOT build staff
top-up selling, Till UI, payment evidence, checkout tender, or cutover in this pass.
