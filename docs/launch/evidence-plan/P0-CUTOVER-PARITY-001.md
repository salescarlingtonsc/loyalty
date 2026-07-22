# P0-CUTOVER-PARITY-001 — Source-to-target schema, data, auth, storage, and configuration parity

## 1. Classification

**OWNER-ACTION-SCRIPTED**, with one **OWNER-DECISION** that must be resolved before step 3 below.

The mechanical tooling is complete and exists in-repo (`docs/supabase-sync/VERIFICATION_GATE.md`,
`docs/supabase-sync/CLI_RUNBOOK.md`, `db/cutover/*.sql`, `db/cutover/compare-cutover-inventories.mjs`,
`scripts/supabase-sync/sync.sh`). What remains is (a) an owner ruling on scope, (b) applying the last
three pending migrations, and (c) a human running the read-only comparator and the manual Dashboard
attestation — none of this can be fabricated or run by an agent under the DB-write restriction in
this task.

**Verified today (read-only, `mcp__…5cc852de…__list_migrations` against `gadpooereceldfpfxsod`):**
production has **75 of the 78** migrations in `supabase/canonical-migration-order.manifest.json`
applied. The three missing are, in order: `20260722134000_frenly_v49_billing_projection_rpc`,
`20260722140000_frenly_v49a_lint_and_rehearsal_repairs`, `20260722141000_frenly_v49b_reports_read_authorization`.
Note the canonical manifest's own `catalogAppliedCount: 45 / pendingCount: 33` fields are a **frozen
historical snapshot** from when the catalog-recovery evidence was authored (see
`scripts/migrations/materialize-canonical-order.mjs` lines 323-324 — those two numbers are hardcoded
constants, not a live query) — do not read "33 pending" as current truth. Only 3 are actually pending.

## 2. Preconditions

- **OWNER-DECISION (blocking):** `docs/supabase-sync/VERIFICATION_GATE.md` requires a read-only
  comparator run against the frozen **source** project `kyzovonwnscrzmkvocid`. The user's memory file
  `production-database-decision.md` records an owner ruling: "use gadpooereceldfpfxsod; do NOT use
  kyzovonwnscrzmkvocid — retired." The owner must state explicitly whether that ruling forbids even a
  read-only, no-write comparator SELECT against the retired project for this one-time historical parity
  proof, or whether it only forbids treating it as live/production. Two closure paths follow from the
  answer:
  - **Path A (comparator permitted):** run the full source-vs-target diff in `VERIFICATION_GATE.md`.
  - **Path B (comparator forbidden):** re-scope this gate's evidence to canonical-migration-chain
    completeness + the manual Dashboard configuration-parity attestation only, and record in the
    evidence summary that the original 2026-07-18 port is treated as an accepted historical fact, not
    re-verified.
- A read-only Postgres URL to `gadpooereceldfpfxsod` (`TARGET_READONLY_DB_URL`), and — Path A only — a
  read-only URL to `kyzovonwnscrzmkvocid` (`SOURCE_READONLY_DB_URL`).
- `RELEASE APPROVED` (the owner's literal phrase, per `CLAUDE.md`'s hard release gate) before the three
  pending migrations are applied to production — this agent cannot apply them under the DB-write
  restriction regardless.
- `jq`, `psql` (PostgreSQL 17 client), Node.js 18+.

## 3. Procedure

1. Resolve the OWNER-DECISION above and pick Path A or Path B.
2. Confirm the migration chain locally (already verified PASS today, re-run to reconfirm freshness):
   ```bash
   export EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod
   npm run migration-manifest:check
   npm run canonical-migrations:check
   ```
3. After `RELEASE APPROVED`, apply the three pending migrations to `gadpooereceldfpfxsod` in order
   (v49 → v49a → v49b) through the project's normal migration-apply path, then re-run read-only
   `list_migrations` (via the Supabase MCP for `gadpooereceldfpfxsod`) to confirm all 78 are present.
4. **Path A only** — from `docs/supabase-sync/VERIFICATION_GATE.md`, run against each side:
   ```bash
   psql -X -q -v ON_ERROR_STOP=1 -t -A -f db/cutover/source_inventory.sql "$SOURCE_READONLY_DB_URL" > source-inventory.json
   psql -X -q -v ON_ERROR_STOP=1 -t -A -f db/cutover/source_reconciliation.sql "$SOURCE_READONLY_DB_URL" > source-reconciliation.json
   jq -s '{inventory: .[0], reconciliation: .[1]}' source-inventory.json source-reconciliation.json > source-cutover.json
   psql -X -q -v ON_ERROR_STOP=1 -t -A -f db/cutover/target_inventory.sql "$TARGET_READONLY_DB_URL" > target-inventory.json
   psql -X -q -v ON_ERROR_STOP=1 -t -A -f db/cutover/target_reconciliation.sql "$TARGET_READONLY_DB_URL" > target-reconciliation.json
   jq -s '{inventory: .[0], reconciliation: .[1]}' target-inventory.json target-reconciliation.json > target-cutover.json
   node db/cutover/compare-cutover-inventories.mjs source-cutover.json target-cutover.json --out cutover-diff.json
   ```
   Confirm `cutover-diff.json` reports zero P0/P1 findings.
5. Complete the manual Dashboard configuration-parity attestation exactly as specified in
   `docs/supabase-sync/CLI_RUNBOOK.md` ("Manual configuration gate"): Auth/SMTP/CAPTCHA, extensions,
   Storage, Edge Functions, secrets, network restrictions — write the
   `manual-config-gadpooereceldfpfxsod.verified` attestation block described there.
6. Storage byte verification: if `preflight`/inventory reports a nonzero `storage_object_count`,
   complete the external byte-copy verification described in the same runbook's "Storage byte gate"
   before treating this closed.

## 4. Evidence capture

- Artifact path: `docs/launch/.evidence/<run-id>/P0-CUTOVER-PARITY-001.json`
- Required shape (exact keys only — the gate checker rejects extras):
  ```json
  {
    "kind": "launch_readiness_evidence_v1",
    "blockerId": "P0-CUTOVER-PARITY-001",
    "stage": "PRODUCTION",
    "targetRef": "gadpooereceldfpfxsod",
    "capturedAt": "<UTC ISO-8601, e.g. 2026-07-23T02:00:00Z>",
    "result": "PASS",
    "checks": {
      "migrationManifestCheck": true,
      "canonicalMigrationsCheck": true,
      "allCanonicalMigrationsApplied": true,
      "comparatorZeroFindings": true,
      "manualConfigParityAttested": true
    },
    "summary": "78/78 canonical migrations applied; comparator zero findings (or: re-scoped per owner ruling, see run notes); Dashboard configuration parity attested by <role label>."
  }
  ```
  If Path B was chosen, drop `comparatorZeroFindings` from `checks` (every remaining key must be `true`)
  and say so plainly in `summary`.
- Redaction: never place `SOURCE_READONLY_DB_URL`/`TARGET_READONLY_DB_URL`, any `postgres://` value,
  auth tokens, or customer data in the artifact or its summary — counts and pass/fail booleans only.
  The checker's `assertSafeContent` will itself reject a URL, email, phone number, JWT-shaped string, or
  the literal text `service_role` anywhere in the JSON, so keep it to labels and booleans.
- Hash-pin: `shasum -a 256 docs/launch/.evidence/<run-id>/P0-CUTOVER-PARITY-001.json`
- Register the `{ "path": ..., "sha256": ... }` pair in this blocker's `evidence` array in
  `launch-blockers.json`, and only then move `status` to `VERIFIED_PRODUCTION` (its `verification.stage`
  is already `PRODUCTION`, so no other field needs to change).

## 5. Estimated wall-clock time

- Owner decision alone: 15-30 minutes.
- Path B (re-scoped): ~45 minutes once the migrations are applied.
- Path A (full comparator): 2-4 hours including source/target dump extraction, `jq` combination, and
  the manual Dashboard walkthrough — most of this is credential setup and Dashboard review, not the
  scripted parts.
