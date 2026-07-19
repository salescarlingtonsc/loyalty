# Supabase Cutover Verification Gate

This gate proves that the source project `kyzovonwnscrzmkvocid`, target project `gadpooereceldfpfxsod`, and rehearsal branch `wtegnefsgnyxhflzizcu` are equivalent after migration without exposing customer data.

It is intentionally read-only. The SQL emits catalog metadata, fingerprints, row counts, storage/auth counts, cron/realtime definitions without raw commands, and tenant aggregates keyed only by `business_id` UUID. It must not output customer names, emails, phones, notes, auth hashes, tokens, gift-card codes, storage object names, or raw cron commands.

## Artifacts

- `db/cutover/source_inventory.sql`, `db/cutover/rehearsal_inventory.sql`, and `db/cutover/target_inventory.sql`: source/rehearsal/target catalog inventory, grants, RLS, policies, functions, triggers, row counts, auth user count, and storage bucket/object counts.
- `db/cutover/source_reconciliation.sql`, `db/cutover/rehearsal_reconciliation.sql`, and `db/cutover/target_reconciliation.sql`: source/rehearsal/target business aggregates, orphan checks, immutable sales flags, points/credit/gift-card/member liability checks, duplicate cron jobs, and function execute exposure.
- `db/cutover/compare-cutover-inventories.mjs`: deterministic offline comparator. It consumes JSON files only, rejects DB URLs/tokens/PII-shaped keys, fails closed on missing metrics, and exits nonzero for launch blockers.

## How To Run

Run these SQL files from a read-only verifier session with enough catalog visibility to count application tables. Do not run them through the public anon key.

Source:

```bash
psql -X -q -v ON_ERROR_STOP=1 -t -A -f db/cutover/source_inventory.sql "$SOURCE_READONLY_DB_URL" > source-inventory.json
jq -e 'type == "object" and .kind == "supabase_cutover_inventory_v1"' source-inventory.json >/dev/null
psql -X -q -v ON_ERROR_STOP=1 -t -A -f db/cutover/source_reconciliation.sql "$SOURCE_READONLY_DB_URL" > source-reconciliation.json
jq -e 'type == "object" and .kind == "supabase_cutover_reconciliation_v1"' source-reconciliation.json >/dev/null
jq -s '{inventory: .[0], reconciliation: .[1]}' source-inventory.json source-reconciliation.json > source-cutover.json
```

Rehearsal branch:

```bash
psql -X -q -v ON_ERROR_STOP=1 -t -A -f db/cutover/rehearsal_inventory.sql "$REHEARSAL_READONLY_DB_URL" > rehearsal-inventory.json
jq -e 'type == "object" and .kind == "supabase_cutover_inventory_v1"' rehearsal-inventory.json >/dev/null
psql -X -q -v ON_ERROR_STOP=1 -t -A -f db/cutover/rehearsal_reconciliation.sql "$REHEARSAL_READONLY_DB_URL" > rehearsal-reconciliation.json
jq -e 'type == "object" and .kind == "supabase_cutover_reconciliation_v1"' rehearsal-reconciliation.json >/dev/null
jq -s '{inventory: .[0], reconciliation: .[1]}' rehearsal-inventory.json rehearsal-reconciliation.json > rehearsal-cutover.json
```

Target:

```bash
psql -X -q -v ON_ERROR_STOP=1 -t -A -f db/cutover/target_inventory.sql "$TARGET_READONLY_DB_URL" > target-inventory.json
jq -e 'type == "object" and .kind == "supabase_cutover_inventory_v1"' target-inventory.json >/dev/null
psql -X -q -v ON_ERROR_STOP=1 -t -A -f db/cutover/target_reconciliation.sql "$TARGET_READONLY_DB_URL" > target-reconciliation.json
jq -e 'type == "object" and .kind == "supabase_cutover_reconciliation_v1"' target-reconciliation.json >/dev/null
jq -s '{inventory: .[0], reconciliation: .[1]}' target-inventory.json target-reconciliation.json > target-cutover.json
```

Compare:

```bash
node db/cutover/compare-cutover-inventories.mjs source-cutover.json rehearsal-cutover.json --out rehearsal-diff.json
node db/cutover/compare-cutover-inventories.mjs source-cutover.json target-cutover.json --out cutover-diff.json
```

The `psql` commands use `-X -q -t -A` plus wrapper-level `QUIET`, `tuples_only`, `format unaligned`, `footer off`, and `pager off` settings so stdout is a single JSON document. The comparator never accepts DB URLs as inputs. It only reads JSON files.

## Severity And Blocking Rules

- `P0_MISSING_METRIC`: required metric absent. Launch blocked.
- `P0_SECURITY`: RLS, policy, grants, function exposure, or privileged function posture drift. Launch blocked.
- `P0_FINANCIAL`: immutable sales flags, revenue, ledger, credit, points, or liability mismatch. Launch blocked.
- `P0_DATA_LOSS`: row count, tenant aggregate, auth/storage count, or orphan mismatch. Launch blocked.
- `P0_OPERATIONAL`: duplicate cron or realtime drift that can duplicate jobs or miss events. Launch blocked.
- `P1_SCHEMA_DRIFT`: catalog/schema drift. Launch blocked unless a written exception names the object and owner.
- `P2_REVIEW`: advisory only.

Launch is blocked by any P0, any unexplained P1, any missing required metric, any known-risk phone-only public RPC exposure, any unexpected anon/public function execute exposure, any nonzero orphan check, any ledger/view mismatch, any mutable sales grant, and any duplicate cron definition.

## Public RPC Exposure

The gate does not allow public RPCs by function name alone. It classifies anon/public execute grants by exact `schema_name`, `function_name`, and `identity_arguments`. A same-name overload is unexpected exposure and blocks launch.

`public.list_my_appointments(p_slug text, p_phone text)` and `public.request_change(p_slug text, p_appointment uuid, p_phone text, p_kind text, p_proposed timestamp with time zone, p_note text)` are known phone-only public access surfaces from the audit. They intentionally appear as `P0_SECURITY` findings until OTP or signed-token hardening exists. Preserving source/target parity does not waive this finding: if both source and target expose the same risky RPC, the cutover is still blocked.

## Required V17 Objects

The SQL is catalog-driven and will not fail if optional objects are absent. The final go-live gate still requires v17 business objects to be present and equivalent where the source contains them:

- Branch visibility helpers and policies: `app.can_see_branch`, `app.role_class`, `sales_branch_visibility`, `appointments_branch_visibility`, `payments_branch_visibility`, `expenses_branch_visibility`, `cash_drawer_sessions_branch_visibility`, and `cash_drawer_movements_branch_visibility`.
- Immutable sales snapshot columns and trigger: `counts_as_revenue`, `counts_as_visit`, `earns_points`, `policy_resolved_at`, and `trg_sales_immutable_guard`.
- Ledger surfaces: `points_ledger`, `points_batches`, `client_points_balance`, `credit_ledger`, `client_credit_balance`, `gift_cards`, and membership objects if they exist on the source.
- Operational surfaces: `supabase_realtime` publication entries and every `cron.job` definition by fingerprint.

If both source and target are missing an optional object, the comparator can pass equality, but that is not proof the product is ready for go-live. The acceptance matrix below decides when missing optional objects are acceptable.

## Acceptance Matrix

| Stage | Required Evidence | Pass Condition | Blocker |
| --- | --- | --- | --- |
| Rehearsal branch `wtegnefsgnyxhflzizcu` | Source vs rehearsal JSON compare | No P0/P1 findings; no PII guard failure | Any mismatch, missing metric, orphan, duplicate cron, or unexpected function exposure |
| Maintenance-window final restore | Source frozen, target restored, both SQL outputs rerun | Source and target row counts, tenant aggregates, auth user count, storage counts, migrations, policies, grants, cron, and realtime match | Any source write after freeze, any failed metric, or any count/financial/security drift |
| Login and token invalidation | Auth user count matches; user sessions intentionally expired or accepted as stale until JWT expiry | Users can sign in to target; old sessions cannot mutate source after cutover | Unknown session behavior or source still accepts writes |
| Frontend key cutover | Vercel env/app config points to target URL/key only after gate passes | Smoke login and core SME flows hit target project | App points to target before data gate passes |
| Rollback | Source remains intact and app key can revert | Rollback instruction names exact Vercel env change and DNS/cache expectation | Source modified during cutover or old project disabled too early |
| Post-cutover monitoring | Comparator rerun after first production traffic window; Supabase logs checked for RLS/API errors | No row-count regressions, cron duplication, auth spike, or policy errors | Any unexplained drift or elevated 4xx/5xx |

## Known Limits

Static SQL pattern tests only verify that these files avoid known raw PII projections. They are not runtime tenant-adversarial tests. They do not prove that an authenticated staff member cannot read another tenant, another branch, or another customer's data through every UI/RPC path. Keep the existing RLS adversarial gate as a separate runtime test requirement.

This gate also does not perform the migration, invalidate sessions, update frontend keys, deploy, or query any database from this workspace.
