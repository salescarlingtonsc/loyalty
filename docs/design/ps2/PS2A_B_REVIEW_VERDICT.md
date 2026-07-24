# PS-2A Increment B Independent Review Verdict — shadow operations & reconciliation (v62)

Reviewer: independent adversarial reviewer (not the author). Scope: the exact frozen commit
`a4aa801` (delta `git diff 4bf22d0..a4aa801`, i.e. everything since the Increment-A commit —
the B contract, the design-only C contract, and the v62 migration/suite/bookkeeping).
**Build-only gate**: nothing applies to UAT or deploys regardless of verdict (owner's standing
PS-2 gate).

## Formal verdict: **PASS PS-2A-B**

v62 adds exactly the pinned Increment-B layer — the safe-subset authority transitions, an
append-only shadow-evaluation log, and a read-only reconciliation engine against the
`gift_cards` legacy analog — with no path that moves customer value, sends comms, or reaches
`live`. Every mandated property is verified, several live and adversarially (a real
owner-authed reconciliation run left the legacy and value spines byte-identical). Both
reviewer test-side fixes are legitimate and mask no defect; both judgment calls are sound. No
findings.

---

## Frozen state
HEAD `a4aa801`; parent `4bf22d0` (PS-2A-A, PASS). Tree clean. v62 migration hash
`4b460b9851ff7155ac91a99b1b94c7acaa1e6e9a827bae41194cda5059349ad6` matches both manifests; the
supabase mirror `20260724210000_*` is **byte-identical** (`cmp` clean). Three new tables
(`sv_shadow_evaluations`, `sv_reconciliation_snapshots`, `sv_reconciliation_discrepancies`).

## Independent verification performed (local cluster, `frenly_freeze` = fresh 96-chain replay)
- **Suite re-run**: `v62_ps2b_shadow_reconciliation.sql` → ALL PASS.
- **Owner-authed reconciliation probe (my own, rolled back)**: seeded three gift cards on a
  fresh tenant (active +5000, void +300, active 0), entered `shadow_testing`, md5'd the legacy
  spine and counted `sv_lot_movements`, ran `run_sv_reconciliation`, then re-measured:
  **`gift_cards` md5 UNCHANGED**, **`sv_lot_movements` UNCHANGED (0)**, discrepancy categories
  `{missing_in_studio, orphan_legacy_record}`, authority driven to `reconciliation_blocked`,
  and the distinct discrepancy content stable across repeated runs.
- **Internal authority-CHECK probe (my own)**: `app.sv_apply_authority_state(...,'live',...)`
  and `(...,'ready_for_cutover',...)` both **rejected 22023** — no bypass through the internal
  path; `shadow_testing` accepted.
- **Governance/bookkeeping machine-verified**: `node --test` on the tripwire + writer-registry
  + three phase0 suites → **36/36** (the +1 vs Increment A is the new gift_cards-read-only
  tripwire).

## Requirement-by-requirement

1. **Reconciliation is READ-ONLY against `gift_cards` and moves no value.** `run_sv_reconciliation`
   contains zero `INSERT/UPDATE/DELETE` against `gift_cards` (grep + the new corpus tripwire);
   it writes only evidence rows (`sv_shadow_evaluations`, `sv_reconciliation_snapshots`,
   `sv_reconciliation_discrepancies`, `audit_log`) and drives authority via the internal state
   path — never a value table. Confirmed live: the legacy spine (`gift_cards` md5) and the value
   spine (`sv_lot_movements`) were byte-/count-identical across a run, and a run wrote zero
   `sv_lot_movements`.
2. **`live` unreachable — now FOUR ways.** `set_sv_authority_state` has a hard CHECK
   (`p_state in unbuilt/shadow_testing/reconciliation_blocked`, else 22023); the internal
   `app.sv_apply_authority_state` carries the *same* CHECK (no bypass — verified live); the v61
   `sv_authority` guard still rejects `live`/`ready_for_cutover`; and the tripwire forbids any
   setter. Reconciliation drives `reconciliation_blocked` via the internal helper (not the public
   RPC), avoiding owner-recursion and passing `p_actor` explicitly. The blocked-lock holds: from
   `reconciliation_blocked` the only non-idempotent target is `shadow_testing` (never forward,
   never `unbuilt`). `get_sv_account.spendable = (state='live')` is therefore always false, with
   `authority_state` carried verbatim.
3. **Discrepancies preserved, tolerance 0, rerunnable, never auto-corrected.** The six-category
   CHECK is the frozen vocabulary; every discrepancy is written to an append-only table and
   surfaced by `get_sv_reconciliation` (never hidden); any discrepancy forces
   `reconciliation_blocked`. Reruns are content-deterministic via `legacy_ref =
   'legacy:giftcard:{id}'`. Invalid/negative/NULL balances and duplicate codes are **classified,
   not repaired** (defensive against direct-SQL/schema drift). The
   **orphan_legacy_record-vs-missing_in_studio split is defensible and I confirmed it live**: a
   *terminal* card (void/redeemed) still carrying value is an internally inconsistent,
   non-migratable row → `orphan_legacy_record`; an *active* card with outstanding value the
   studio has not adopted → `missing_in_studio`. Classifying by the legacy row's own consistency
   is precise and correct.
4. **`get_sv_account` extension minimal + truthful.** The v61→v62 function diff is **exactly two
   added lines** — `shadow_testing = (state='shadow_testing')` and a `disclaimer` (null only when
   live, i.e. never in PS-2A). Every prior field is byte-preserved; `spendable = (state='live')`
   is unchanged (always false); `authority_state` verbatim.
5. **House invariants.** All three new tables are append-only (shared `app.sv_immutable_guard`),
   RLS owner+SA read, revoked from public/anon/authenticated with SELECT-only grants (zero
   browser DML), composite tenant FKs (nullable `account_id` MATCH SIMPLE; composite snapshot
   FK), integer/bigint cents only (no float). Every new function is SECURITY DEFINER with pinned
   `search_path` and revoked, with minimal grants: `set_sv_authority_state` /
   `run_sv_reconciliation` / `get_sv_reconciliation` / `get_sv_account` granted to authenticated,
   the internal `sv_apply_authority_state` / `sv_write_shadow_evaluation` left un-granted.
   `set_sv_authority_state` and `run_sv_reconciliation` are **owner-only** (anon/frontdesk →
   42501/insufficient_privilege); reads are scoped to `p_business` (cross-tenant denied). The
   suite's fresh tenant C is created with the `loyalty` module so `create_business`'s guarded
   loyalty-draft seed succeeds (see 6b).
6. **Reviewer test-side fixes — both legitimate, neither masks a defect.**
   - **(a) T20:** replacing the fragile in-suite re-publish with a direct
     `app.ps1c2_effect_state(business,'apply_discount_amount') = 'live'` assertion is a
     **legitimate strengthening**. The property under test is *axis independence* (the checkout
     rule-execution axis can be `live` while the sv authority axis is `shadow_testing`);
     `ps1c2_effect_state` is the exact per-effect truth `ps1c2_rule_state` aggregates, and v60's
     suite already proves the full publish→aggregate-`live` path end-to-end (in the passing
     matrix). v62 does not touch the rule-state path (grep: 0 redefinitions of `ps1c2_*` /
     `get_programs_overview` / `ps1b_effect_family`), so the direct check tests an untouched,
     independently-proven function — no defect is masked.
   - **(b) tenant-C module list:** a necessary fixture correction (`create_business` seeds a
     guarded draft loyalty config that demands the `loyalty` module — matching the fixture's own
     tenants). It only makes the cross-tenant-denial setup succeed; the migration is untouched.
7. **SA read on `get_sv_reconciliation` — I agree it should be owner∨super_admin.** The
   super-admin scope is v14 platform-wide *read-everything, write-nothing*; every sv table
   already carries an `sa_read` RLS policy, so an SA can already read the underlying rows. The
   *mutating* RPCs (`set_sv_authority_state`, `run_sv_reconciliation`) are correctly **owner-only**
   (no SA). Read-for-SA / write-for-owner is the consistent split; strict owner-only on the read
   would be inconsistent with the rest of the platform.
8. **Scope / gates.** No spend/reserve/reverse/refund/expire/cutover surface exists (absent, not
   disabled). The tripwire keeps `sv_spend_allocation`/`refund_sv_operation` forbidden and the
   live-setter + balance-column assertions, and **adds** the gift_cards-read-only scan. The
   checkout kernel, executor, `benefit_registry`, and `points_ledger`/`credit_ledger` are
   untouched by v62 (grep: 0). Manifests coherent (db 93→94, canonical 95→96; hash matches); v21
   forward-scan includes v62 so its new authenticated RPCs are allowlist-covered; discover-writers
   classifies the three new tables as non-value evidence/log rows and the writer-registry
   documents the shadow/reconciliation writers truthfully.

## Observations (informational; not findings)
- **O1 (by-design).** `run_sv_reconciliation` writes one `sv_shadow_evaluations` row per gift
  card per run, so repeated runs grow the append-only shadow log. This is intentional (immutable
  evidence) and content-deterministic (the Direction-2 `missing_in_legacy` check uses
  `distinct legacy_ref`, so accumulation does not change the discrepancy set). Worth noting only
  for the future Increment-D UI/retention; no action needed for this gate.

## If/when the owner authorizes a UAT apply (belt-and-suspenders; not gate conditions)
1. After apply, run `run_sv_reconciliation` on a synthetic UAT tenant seeded with a positive and
   a void-with-balance gift card, and confirm the legacy `gift_cards` rows are byte-identical
   before/after and no `sv_lot_movements` were written.
2. Confirm `set_sv_authority_state` and `run_sv_reconciliation` reject a frontdesk/anon caller
   (42501) and that `get_sv_account` reports `spendable=false` / `shadow_testing` truthfully.
3. Confirm `benefit_registry.stored_value` and `points_ledger`/`credit_ledger` are untouched
   post-apply.
