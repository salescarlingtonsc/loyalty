# PS-2 LIVE v70 — Independent Review Verdict: PASS V70

**Verdict:** PASS V70, first review, first try — reviewed at commit
`19affa1d07e0fe945eb2f9f55671a6b67a739ce7` (v70's build commit `2fc0b33f` is an ancestor;
its migration bytes survived the entire v69 rev-2/rev-3 rework unchanged).
**Migration:** `db/migrations/20260724_frenly_v70_legacy_non_overlap.sql` = mirror
`supabase/migrations/20260725110000_frenly_v70_legacy_non_overlap.sql`, byte-identical,
SHA-256 `8ea9790aafd1c03ed84c643cc179e3200a662664f1dec8e92da1327d994052d9`.
**Apply status at verdict time:** eligible; sequenced strictly AFTER v69 (v69 applied
2026-07-26). Dry-run gate verified: exactly one pending (`20260725110000`).

## What v70 delivers

1. **Non-overlap (§1):** a business `live` on stored value cannot mint NEW legacy gift-card
   value — both `issue_gift_card` overloads refuse with typed `sv_live_legacy_issue_blocked`
   via `app.sv_legacy_issue_guard`, placed AFTER the idempotent-replay branch (a completed
   pre-live issuance still replays) and BEFORE every write (refusals mutate nothing).
   Redemption of already-issued legacy value keeps working on a live business (money is
   honoured to extinction, never stranded). No migration of legacy balances into SV
   (would mint value without payment evidence — forbidden by v68a).
2. **Amount-specific acknowledgement (§2):** append-only `sv_legacy_acknowledgements`
   (monotonic `seq`, latest-wins) + `acknowledge_legacy_value`; `run_sv_reconciliation` nets
   legacy against the LATEST acknowledged amount only; drift in ANY direction (up, down, to
   zero) re-dirties with `acknowledgement_drift`; `get_sv_reconciliation` exposes
   `acknowledged_cents`.
3. **Classification (§3):** `sv_legacy_classifications` + `classify_legacy_business`
   (`pilot` / `qa_reset` / `retain_fixture`); inventory report; v70 deletes/resets NOTHING.
4. **Mechanism only:** postcondition-proven zero rows in both new tables at apply; the kopi
   tiam acknowledgement is a post-apply runtime act (contract §6), never pre-seeded.
   ZZ-SYNTHETIC deliberately reported-not-marked (marking would flip its v66 billing
   projection — the contract's "flag, don't guess" branch).

## Review highlights (reviewer executed, not argued)

- Full 110-migration canonical chain replay through v70; suite PASS; full matrix 69/69;
  validate 506/506; **13 reviewer-authored adversarial probes** in 3 rounds.
- **Mint-path enumeration independently confirmed COMPLETE** — the strongest evidence:
  `credit_ledger` has carried a machine-enforced 8-route write-scope allowlist since v34
  (direct positive insert = 42501, verified empirically), so there is structurally no
  unlisted store-credit mint; catalog query shows exactly the two gift-card overloads
  reference the guard.
- **`record_credit_tender` correctly NOT gated** — the pinned contract mislabelled it a
  minting path; it writes `entry_type='spend'` with negative deltas only. The builder caught
  the contract error; the reviewer confirmed it by reading the function. Gating it would
  have stranded customer credit at the counter.
- **Over-acknowledgement cannot mask real discrepancies:** only `missing_in_studio` is
  netted; a planted `orphan_legacy_record` survived a 999,999¢ acknowledgement.
- **Netting is latest-by-seq, not sum** (3 stacked acks → clean at the latest figure);
  negative amounts rejected at CHECK and RPC; 4999¢ ≠ 5000¢ asserted.
- **A live business is never harmed by reconciliation status:** v69's
  never-downgrade-a-live-tenant predicate is preserved byte-for-byte; card-redeemed-to-zero
  on a live business dirties reconciliation but authority STAYS `live`; re-acknowledging
  re-cleans. Function-replacement hygiene clean: four full CREATE OR REPLACE, no splices,
  each line-diffed against its true latest prior definition.
- Tenant isolation: all three new RPCs refuse cross-tenant (42501); both tables RLS-on,
  zero browser DML, immutability triggers (23001).

## Findings (none blocking)

- **LOW-1 — REQUIRED FIX next increment:** `acknowledge_legacy_value` validates
  `>= 0` but has no int4_max upper bound; acknowledging 3,000,000,000¢ is accepted and the
  nightly sweep then raises raw 22003 (isolated per-business by the sweep's exception
  handler, fail-closed, recoverable via a superseding acknowledgement). Contradicts the
  v65b typed-22023 convention. Requires a ~6-orders-of-magnitude typo to trigger.
- **LOW-2 — owner policy ruling requested (nil pilot consequence):** non-overlap is enforced
  for gift-card issuance only; on a live business, loyalty earn still mints promotional
  store credit (`on_sale_recorded` retention/referral rewards) and `redeem_points` still
  converts points into credit. Documented deviation, judged defensible: gating the universal
  earn signal would kill loyalty on the pilot; reconciliation compares gift_cards only; no
  cash is double-counted; no money stranded.
- INFO: drift collapses per-card discrepancy rows into one aggregate row (totals preserved
  in snapshot detail); `get_legacy_acknowledgements` had no in-suite ACL/functional test
  (reviewer covered it: cross-tenant read 42501, latest-wins field correct).

## Post-apply runtime acts (contract §6 — in order, after v70 is live)

1. Re-measure kopi tiam's outstanding legacy balance (5000¢ as of 2026-07-26). If it moved,
   STOP and re-confirm with the owner.
2. `acknowledge_legacy_value` for exactly the measured amount, reason
   "owner instruction 2026-07-26: honour to extinction; pilot candidate".
3. Classify: kopi tiam = `pilot`; QA Test Cafe + QA Go-Live Cafe = `qa_reset` candidates
   (recorded only — any actual clearing remains a separate owner-authorised act).

**Applying v70 moves zero value and activates nobody.** Post-apply verification must show
every real business still `unbuilt` and kopi tiam's $50 card still active and untouched.
