# PS-2 LIVE Increment 1 (v65) — Independent Review Verdict

## VERDICT: `PASS V65`

Independent adversarial review of the **exact frozen commit** (not the builder's report).

- **Frozen commit:** `c23518cbd93aa79fe781fe2800253ce212f164d4` (branch `codex/phase0-transaction-foundation`)
- **Canonical migration:** `db/migrations/20260724_frenly_v65_ps2live_plan_config.sql`
- **Supabase mirror:** `supabase/migrations/20260725000000_frenly_v65_ps2live_plan_config.sql`
- **SHA-256 (both, byte-identical):** `3052b4feb62baca5b48d10fced8942efaac57f43f3eb98246fb8de2c92d32a51` — **MATCHED**

## Finding-by-finding (verified from the frozen bytes + live execution)
1. **Immutable retirement** — no `retired_at` column on the version (only in comments noting its removal); retire/reactivate mutate only `sv_plans.active` + append-only `sv_plan_status_events`; no UPDATE/DELETE of `sv_plan_versions`. Probe: direct UPDATE/DELETE on a published version blocked (23001); row byte-identical after retire. ✓
2. **Positive paid** — `price_cents <= 0` is a typed `22023` structural error before insert (v61 CHECK is the backstop). ✓
3. **Configurable guardrails** — `set_sv_plan_guardrails` validates `0<=warn<=hard<=10000`, idempotent, audited; reads coalesce to 3000/7000. ✓
4. **Eligibility validation + canonicalisation** — cross-tenant/inactive branch/service/product become structural errors (preview + publish); arrays distinct+sorted; empty rejected; null=all. ✓
5. **Strict config patch** — unknown keys/wrong types/malformed scalars/over-long text → typed `22023`; missing=unchanged; JSON null clears only nullable. Probe: `10.0`/`10.5` rejected, `1e4`→10000. ✓
6. **Optimistic concurrency** — `revision`+`expected_revision` on update/publish/discard, typed `22023` on mismatch. ✓
7. **Publish locks plan row** — `SELECT … FROM sv_plans … FOR UPDATE` before numbering; two-connection harness → exactly one version, one real publish + one clean replay, never a raw 23505. ✓
8. **Circular draft↔version FKs + one-draft-one-version** — both composite FKs + partial unique on `source_draft_id`; second version from one draft → 23505. ✓
9. **Explicit points policy** — only `topup_purchase_earns_points` + `stored_value_spend_earns_points`; no bare `earns_points`. ✓
10. **Purchase window pair + max_balance fit** — both-or-neither; `max_balance < price+bonus` is a structural error. ✓
11. **Preview separation + publish gate** — `validation_errors`/`warnings`/`override_required`/`publishable` separate; publish re-runs validation fresh, blocks structural errors incl. required `customer_terms`; override only bypasses the discount hard-limit. ✓
12. **Full lifecycle** — discard/clone-to-draft/retire/reactivate; publishing under a retired plan denied until explicit reactivation (no silent reactivation). ✓
13. **Complete read shape** — `get_sv_plans` returns full per-version config + status history + guardrails; owner-or-SA gated. ✓
14. **Idempotency envelope + audit** — `sv_plan_operations` (business, op_type, key, request_hash, actor, result), append-only, advisory-locked, on create/publish/discard/clone/retire/reactivate/guardrail; hash conflict on same-key/different-payload → 22023; every state change audited. ✓

## Security / house-rules sweep — clean
Every new table: RLS on, browser `revoke all`, only `SELECT` to authenticated, owner+SA read policies, no write policies. All 10 public RPCs EXECUTE to `authenticated` only (no anon/PUBLIC); all `app.*` helpers no browser EXECUTE. All SECURITY DEFINER pin `search_path`. No dynamic SQL. Composite tenant FKs. **Zero writes to `sv_lots`/`sv_lot_movements`/`sv_authority`; authority stays `unbuilt`.**

## Independent evidence run
- SHA-256 of both files from `c23518c` = expected; byte-diff identical.
- Fresh v64-based DB: migration applies cleanly; `V65 SUITE PASS`.
- `npm run validate` → green (461/461 tests, build passed).
- Two-connection publish harness → PASS (one version, one clean replay, zero value moved).
- 6 hand-written adversarial probes (mutate published version, jsonb type-confusion, integer overflow, cross-tenant plan_id, same-key/different-payload replay, value/authority side-effects) → all correct.

## Non-blocking notes (LOW / informational — NOT CHANGES REQUIRED)
1. A cents value exceeding int4 (e.g. `9999999999`) throws raw `22003` (numeric_value_out_of_range) at the cast/`v_total` sum instead of a typed `22023`. Owner-only, absurd values, transaction aborts with no bad data.
2. A whitespace-only `eligible_service_categories` element passes the length check then canonicalises to `{}` (matches nothing) → an overridable warning only. Owner-only, no enforcement until v67.
3. `if not v_active` in publish relies on `v_active` never being NULL, which the composite `on delete restrict` FK on `sv_plan_drafts.plan_id` guarantees. Defense-in-depth nit only, unreachable.

_(These three are addressed in the forward migration `frenly_v65a_ps2live_plan_config_hardening`; v65 itself is accepted and not rolled back or rewritten.)_
