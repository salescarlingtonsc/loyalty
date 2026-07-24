# PS-2A Increment B — Shadow Operations & Reconciliation (PINNED)

Builds on Increment A (v61, reviewed PASS at commit `4bf22d0`). Migration **v62**. Base: repo HEAD
`cef6bf7`, rehearsal chain 95. **Still forbidden:** production cutover, real value movement, real
comms, `live`/`ready_for_cutover` authority. Build-only gate: no UAT apply/deploy without separate
owner word.

## Purpose
Give the stored-value ledger a **shadow-testing mode** and a **reconciliation engine** against the
designated read-only legacy analog (`gift_cards`, per Increment-A ground truth G2), so a future
cutover phase has evidence. Nothing here makes stored value spendable.

## What Increment B adds

### 1. Authority-state transitions (the safe subset only)
`public.set_sv_authority_state(p_business, p_asset, p_state, p_reason)` — owner-only, audited.
- **Hard CHECK: `p_state in ('unbuilt','shadow_testing','reconciliation_blocked')` only.** The `live`
  and `ready_for_cutover` states remain unreachable — this RPC cannot name them, and the v61
  `sv_authority` guard still rejects any transition into them. So `live` stays unreachable *four*
  ways now (no live-setter, this RPC's CHECK, the guard, the tripwire).
- Idempotent; `unbuilt ⇄ shadow_testing` freely; `→ reconciliation_blocked` from either; a business
  with open discrepancies cannot leave `reconciliation_blocked` except back to `shadow_testing`
  (never forward) until discrepancies clear.
- Audit `SV_AUTHORITY_STATE_SET` with actor/reason/from/to.

### 2. Shadow evaluation log
`public.sv_shadow_evaluations` — append-only record of a *proposed* stored-value operation computed
without asserting authority. Columns: id, business_id, account_id (nullable), asset, operation_type,
proposed_movements jsonb (the signed movement plan the engine *would* write), proposed_total_cents,
legacy_ref text (deterministic, e.g. `legacy:giftcard:{id}` when derived from the analog), computed_at,
config note. RLS owner+sa read; append-only guard; no browser writes. **A shadow evaluation writes
NOTHING to sv_lot_movements** (assert: value tables byte-identical across a shadow run).

### 3. Reconciliation engine (read-only against the analog)
- `public.sv_reconciliation_snapshots` — one row per (business, run_id): captured_at, actor, source
  (`gift_cards`), totals, status (`clean`|`blocked`). Append-only.
- `public.sv_reconciliation_discrepancies` — per (run_id, subject): category, legacy_ref (deterministic),
  client_id nullable, legacy_cents, studio_cents, delta_cents, detail jsonb. Append-only. Categories
  (CHECK): `missing_in_studio`, `missing_in_legacy`, `amount_mismatch`, `orphan_legacy_record`,
  `duplicate_legacy_event`, `invalid_legacy_balance`.
- `public.run_sv_reconciliation(p_business)` — owner-only. Reads `gift_cards` **read-only** (never
  writes/updates/deletes a gift-card row — assert), computes the studio-side projection (Σ sv_lot_movements
  per account, which is 0 in a fresh tenant), diffs per customer/asset with **tolerance 0**, classifies
  every discrepancy, writes one snapshot + N discrepancy rows. Deterministic `legacy_ref` makes reruns
  idempotent (a rerun with unchanged inputs produces the same discrepancy set; use a run_id but the
  discrepancy *content* is stable — reconciliation is rerunnable and rollback-safe). If any discrepancy
  exists → set `sv_authority` to `reconciliation_blocked` (via the internal state path) and snapshot
  status `blocked`; else `clean`. **Never auto-corrects or writes a legacy row.** Handles: NULL/negative
  legacy balance → `invalid_legacy_balance`; a gift card with no matching studio account →
  `orphan_legacy_record`/`missing_in_studio` (classify precisely and document which); duplicate legacy
  codes → `duplicate_legacy_event`.
- `public.get_sv_reconciliation(p_business)` — owner read: latest snapshot + its discrepancies +
  current authority state. **Discrepancies are shown, never hidden.**

### 4. Truthful shadow state (tests 19/20)
Extend `get_sv_account` so its response distinguishes shadow from spendable: it already returns
`authority_state` verbatim and `spendable=(state='live')`; add `shadow_testing boolean =
(authority_state='shadow_testing')` and a `disclaimer` field the UI renders ("simulated — not
spendable") whenever not live. A shadow-only account/asset must NEVER report a spendable/live status.
(No UI in B; the field exists for D.)

## Invariants (added to the v61 set; all machine-tested)
- A shadow evaluation changes NO value table (sv_lot_movements / sv_lots / points_ledger /
  credit_ledger / gift_cards byte-identical before/after — md5 assertion).
- Reconciliation reads `gift_cards` read-only: zero INSERT/UPDATE/DELETE on gift_cards (assert no
  gift-card row mutated across a run).
- Every discrepancy is preserved and inspectable; tolerance is 0; nothing auto-fixed.
- An open discrepancy forces `reconciliation_blocked` and cannot advance toward cutover.
- `set_sv_authority_state` cannot name `live`/`ready_for_cutover` (CHECK) and the guard still rejects them.
- Reconciliation is rerunnable (deterministic legacy_ref) and rollback-safe (all in one txn).
- Owner-only on all three new RPCs; anon/staff denied; cross-tenant denied; RLS on all new tables.

## Adversarial tests (Increment B slice of the owner's 25)
17. Shadow operation never changes the legacy authoritative balance (gift_cards untouched; md5 equal).
18. A shadow mismatch is recorded and visible (seed a gift-card balance with no studio account →
    a discrepancy row exists and `get_sv_reconciliation` surfaces it; authority → reconciliation_blocked).
19. A shadow-only effect never reports `live` (authority shadow_testing → get_sv_account spendable=false,
    shadow_testing=true).
20. A mixed-authority program never displays a bare `live` — reconfirm the PS-1C.2 rule-state path is
    untouched and stored-value authority is a separate axis that never shows live in B.
Plus: reconciliation reads gift_cards read-only (no mutation); rerun determinism (same discrepancy
content); invalid/negative legacy balance classified not fixed; duplicate legacy code classified;
authority-state RPC rejects live/ready_for_cutover (CHECK) and only owner may call; a shadow run writes
zero sv_lot_movements; regression — v61 foundation suite + PS-1C.2 emergency pause + checkout still pass.

## House rules
Canonical + byte-identical mirror; RLS/ACL/definer-search_path/revoke on everything; append-only guards;
composite tenant FKs; integer cents; writer-registry + discovery 0/0; PS-GATES note; tripwire keeps
`sv_spend_allocation`/`refund_sv_operation` forbidden (Increment C) and the live-setter + balance-column
assertions; manifests 95→96 / db 93→94. No change to checkout kernel, executor, or any prior phase.
