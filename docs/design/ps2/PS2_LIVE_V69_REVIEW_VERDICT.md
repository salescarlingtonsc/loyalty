# PS-2 LIVE v69 — Independent Review Verdict: PASS V69 (rev-3)

**Verdict:** PASS V69 REV-3 on frozen commit `19affa1d07e0fe945eb2f9f55671a6b67a739ce7`.
**Migration:** `db/migrations/20260724_frenly_v69_controlled_cutover.sql` = mirror
`supabase/migrations/20260725100000_frenly_v69_controlled_cutover.sql`, byte-identical,
SHA-256 `96814350032d720e18ba08d232c412ff60649cff4d78c21941a77cfae3753601`.
**Applied to production 2026-07-26** by the owner via `supabase db push --linked` (exact bytes,
one transaction, canonical ledger version `20260725100000` — no normalisation needed). The
in-apply automation postcondition reported all three cron jobs scheduled and active.

## Review arc (three revisions, two independent reviewers, all defects executed not argued)

- **rev-1 `fb2c5d5` — CHANGES REQUIRED.** D1 MEDIUM: header claimed the designation singleton
  enforced "one pilot business"; reviewer proved revoke-A → designate-B → cutover-B reached
  TWO simultaneously-live businesses via fully sanctioned calls. D2 raw 23505 on designation
  collision; D3–D5 doc/comment defects.
- **rev-2 `d2a01aa` — D1–D5 closed.** One-live-platform-wide made STRUCTURAL: partial unique
  index `sv_authority_one_live_per_asset_uk on public.sv_authority (asset) where state='live'`
  (a true platform singleton, since `asset` is CHECK-bound to `stored_value`) + typed
  `sv_pilot_already_live` in `app.sv_cutover_readiness` so preview and act agree + typed
  `sv_pilot_already_designated` under the global designation mutex (D2). Independent review
  verified D1 BY EXECUTION: replayed the rev-1 exploit (typed refusal), ran a genuine
  two-connection uncommitted race with the guard trigger disabled (loser blocked on the index
  entry, then 23505 on the winner's commit; loser succeeded when the winner aborted — no false
  positive), and swept the catalog (exactly two authority writers, one events writer, no
  bypass). **But found one NEW defect:**
- **MEDIUM-1 (reproduced live):** `sv_cutover_business` re-read the designation UNLOCKED after
  readiness; a concurrent revoke in that window produced a completed cutover whose immutable
  `sv_cutover_events` + `audit_log` rows carried `designation_id`/`designated_by` = NULL —
  the super-admin co-authorization of the platform's most consequential irreversible action,
  erased unrepairably (hard immutability trigger + UNIQUE(business_id, asset)). Not an
  authorization bypass (readiness had validated a real designation) and the one-live bound
  was unaffected — purely audit attribution. Orchestrator ruling: fail closed, never proceed
  with corrupted attribution; the "pin readiness-time id and proceed" alternative was
  REJECTED (it would attribute a cutover to a designation actively revoked by completion).
- **rev-3 `19affa1` — PASS.** The attribution read now happens under the SAME global mutex
  designate/revoke already take (`pg_advisory_xact_lock(hashtextextended('v69:sv_designation',0))`),
  with a typed `sv_designation_revoked` (22023) refusal if the designation vanished — nothing
  mutated, idempotency key not burned, retriable after re-designation. Second independent
  review confirmed by execution: race reproduced against rev-3 (typed refusal, zero rows,
  key free) AND a negative control with the rev-2 body restored (NULL-attribution row
  reproduced; the new tests fail loudly — proving they are load-bearing, not tautological).
  Diff rev-2→rev-3 = two additive hunks; D1–D5 mechanisms byte-identical. Deadlock excluded
  empirically: the designate/revoke path holds zero locks the cutover path holds. INFO-1
  applied: postcondition asserts the one-live index is keyed on exactly `(asset)`.

## What v69 delivers

Evidence-gated, audited, idempotent, fail-closed cutover: `sv_cutover_business` (one business
per call, tripwire-asserted never-global), `sv_cutover_events` (append-only, one function
writer), `sv_cutover_designations` (super-admin co-authorization, global-mutex-serialised),
`app.sv_cutover_readiness` shared oracle (preview ⇔ act agreement), truthful
`preview_sv_cutover` (hardcoded `ready:false` removed). Three cron jobs wired and REQUIRED
for go-live (`frenly-sv-expiry` 35 19 UTC, `frenly-sv-tender-release` */3 min,
`frenly-sv-reconciliation` 45 19 UTC; `sv_automation_missing` refusal if any missing/inactive).
`live` is not reversible by RPC (`sv_live_not_reversible`); pause is the emergency control.
PS-0 lettered-case oracle re-run cents-exact against a genuinely live business (first time
outside a forced-live shim). v68b LOW-1 resolved as option (b): 40P01 documented as an
accepted retriable outcome on both reversal doors, asserted in-suite.

## Post-apply production state (verified 2026-07-26)

All 4 real businesses `unbuilt`; canary `shadow_testing`; 0 cutover events; 0 designations;
3 SV cron jobs active; 0 real SV lots; kopi tiam's legacy card intact (active, 5000¢);
ledger tip `20260725100000`; security advisor **0 ERROR** (183 WARN / 49 INFO — standing
pre-existing classes).

## Open findings carried forward

- INFO (rev-3 review): the fix reasons under READ COMMITTED; under REPEATABLE READ the defect
  cannot occur either (single snapshot). PostgREST is READ COMMITTED. No action.
- INFO-2/INFO-3 (rev-2 review): designating an already-live business burns the slot
  (harmless, manually revocable); the pilot slot is structurally one-way — retiring a live
  pilot requires its own future increment (disclosed in migration §5). Owner may later rule
  on serial pilot switching.

**Applying v69 cut over nobody.** Designation + cutover of the pilot business remain separate
owner acts, gated on v70's acknowledgement mechanism and the launch-evidence decisions.
