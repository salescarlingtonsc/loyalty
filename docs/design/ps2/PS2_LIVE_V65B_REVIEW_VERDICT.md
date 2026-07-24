# PS-2 LIVE v65b (numeric-safe range guard) — Independent Review Verdict

## VERDICT: `PASS V65B`

Independent adversarial review of the exact frozen commit (bytes + full-catalog prosrc diff + execution).

- **Frozen commit:** `fc8ea1e98cdcfd8ca4d12a7d5fbdaf82763b8bf3`
- **Canonical:** `db/migrations/20260724_frenly_v65b_ps2live_numeric_range_guard.sql`
- **Mirror:** `supabase/migrations/20260725020000_frenly_v65b_ps2live_numeric_range_guard.sql`
- **SHA-256 (both, byte-identical):** `8192c611e41730b43d0cddb13c4eb7e9233bb81e48400c3f6c9ec0d5dedee276` — **MATCHED**

## Scope — exactly one function, one kind of change
A full-catalog prosrc comparison across all 427 app+public functions between a `v65+v65a` DB and a
`v65+v65a+v65b` DB shows **only `app.sv_plan_assert_config` differing**; relation (725), policy (256) and
trigger (168) counts identical — no table/DDL/schema change. That function's diff is **exactly** the 5
range-comparison casts changed `::bigint`→`::numeric` (price/bonus `<0` and `>int4_max`; nullable-int
`<=0`, `<0`, `>int4_max`) — 10 diff lines, nothing else. Allowed-key set, plan_id UUID check,
enum/array/category/text/effective_at checks, and every message + SQLSTATE byte-identical; the only
remaining `bigint` is the unchanged `int4_max constant bigint` declaration. Attributes preserved: IMMUTABLE,
`search_path=pg_catalog,public,app,pg_temp`, execute revoked from public/anon/authenticated.

## Boundary matrix (own probes, asserting exact SQLSTATE)
| input | fields | observed |
|---|---|---|
| 2147483647 | price / max_balance / paid_expiry | accepted |
| 2147483648 | price / max_balance / paid_expiry | **22023** |
| -2147483649 | price | **22023** |
| 9223372036854775808 (bigint_max+1) | price, bonus, max_balance_cents, paid_expiry_days, min_spend_cents, purchase_lifetime_cap | **22023** (all) |
| 99999999999999999999999999999999 | price, paid_expiry_days | **22023** |

Off-by-one correct (int4_max accepted, +1 rejected); never `22003`/`22P02`. **Regression baseline proven:**
on a v65a-only DB, bigint_max+1 threw raw `22003` on both a price field and a nullable-int field — the LOW
residual was real; v65b returns typed `22023`. In-range invalid input keeps byte-identical v65a
messages/SQLSTATE; the non-integer guard still precedes the cast.

## Evidence
V65 + V65A + V65B suites PASS on the v65+v65a+v65b chain; 0 sv_lots / 0 sv_lot_movements / no stored_value
authority row written (unbuilt); `npm run validate` 461/0 + build; `git diff --check` clean; the frozen
commit appends only the v65b entry to the manifests (deploy `…000139`, pending version `20260725020000`) —
no reordering or removal.

## Defects
None found.
