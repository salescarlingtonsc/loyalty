# PS-2 LIVE v65b — Numeric-Safe Integer Range Guard (PINNED, narrow)

Closes the single LOW residual from PASS V65A: integer inputs beyond BIGINT range still threw raw `22003`
because `app.sv_plan_assert_config` cast to `::bigint` before comparing to `int4_max`. Forward-only; **do
NOT edit v65 or v65a.** New migration `frenly_v65b_ps2live_numeric_range_guard` (canonical
`db/migrations/20260724_frenly_v65b_ps2live_numeric_range_guard.sql`; mirror version `20260725020000`).
CREATE-OR-REPLACE of **exactly one** function (`app.sv_plan_assert_config`) — no other function, no table,
no schema change. Config-only (zero sv_lot_movements/lots; authority stays `unbuilt`).

## The only change
In `app.sv_plan_assert_config`, replace every `(v#>>'{}')::bigint` range comparison with `(v#>>'{}')::numeric`
(the 5 sites: price/bonus `< 0` and `> int4_max`; nullable-int `<= 0`, `< 0`, `> int4_max`). `numeric`
cannot overflow, so a value beyond BIGINT range reaches the `> int4_max` comparison and is rejected with the
existing typed `22023` instead of a raw `22003` from the cast. `int4_max` stays `2147483647`.

Every other line of the function — the allowed-key set, plan_id UUID validation, enum checks, array/category
checks, text length, effective_at, and the exact error messages/SQLSTATE — is BYTE-IDENTICAL to v65a. The
v65a↔v65b diff must be ONLY the 5 `::bigint`→`::numeric` tokens.

## Behaviour contract
- Inputs INSIDE int4 range keep current behaviour (2147483647 accepted where otherwise valid; 0 accepted;
  negatives/zero rejected by the existing `< 0` / `<= 0` guards with their current messages).
- Any integer OUTSIDE int4 range → typed `22023` (never raw `22003` or `22P02`):
  - `2147483648` (int4_max + 1) → 22023;
  - `-2147483649` (below int4_min; caught by the negative guard) → 22023;
  - `9223372036854775808` (bigint_max + 1 — the value that used to throw 22003) → 22023;
  - arbitrarily larger integers → 22023.
- Zero data / security / stored-value side effects; authority remains `unbuilt`; no value written.

## Tests (db/tests/v65b_ps2live_numeric_range_guard.sql — rolled back)
Exact boundary matrix on `create_sv_plan_draft` (price/bonus path AND a nullable-int path):
`2147483647` accepted; `2147483648` → 22023; `-2147483649` → 22023; `9223372036854775808` → 22023 (both a
price field and a nullable-int field, proving both cast sites are numeric-safe); an arbitrarily larger
integer (e.g. `99999999999999999999999999999999`) → 22023. Plus: the returned SQLSTATE is `22023` (never
`22003`); zero sv lots/movements; authority unbuilt. Full gate matrix: fresh replay through v65b; v65 + v65a
+ v65b suites; prior suite matrix; two-connection harness; RLS/ACL/SECDEF scans; writer registry; npm run
validate; secret scan; git diff --check. Independent reviewer inspects the exact frozen v65b commit → PASS
V65B / CHANGES REQUIRED / BLOCKED.

## After PASS V65B
Apply v65b; normalize ONLY its ledger version to `20260725020000`; verify authority unbuilt + zero
lots/movements; push + reconcile main. Then **immediately begin v66** (staff-assisted top-up sale + Till +
payment evidence + plan limits). Do NOT touch checkout tender, refund engine, cutover, or communications in
v65b. Migration registered in both order-plans + manifests (db exec 84→85, canonical chain 100→101, pending
55→56).
