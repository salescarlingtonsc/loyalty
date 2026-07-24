# PS-2A Increment D Independent Review Verdict — pause controls + owner UI + cutover preview (v64)

Reviewer: independent adversarial reviewer (not the author). Scope: the exact frozen commit
`cab6b56` (delta `git diff a2d1b89..cab6b56`, including the design-only D contract + the C
verdict doc). **The final PS-2 increment.** Build-only gate: nothing applies to UAT or deploys
regardless of verdict (owner's standing PS-2 gate).

## Formal verdict: **PASS PS-2A-D**

v64 adds the dedicated stored-value pause ledger, its owner-only pause/lift RPCs, the pause TEETH
inside the seven value RPCs (each changed by ONLY the added guard), the owner authority/cutover
read surface (both `can_cutover` and `ready` hardcoded false), and a truthful owner UI. Every
mandated property is verified — several live and adversarially, including the pinned policy that an
earn pause does not block spend. No findings.

**PS-2A is now complete: all four increments (A/B/C/D) reviewed PASS, and the whole of PS-2 remains
entirely build-only — no UAT apply, no deploy — pending the owner's separate word.**

---

## Frozen state
HEAD `cab6b56`; parent `a2d1b89` (PS-2A-C, PASS). Tree clean. v64 migration hash
`e933602caa7f74a65d6882721c478f22b54b432ef2f5a786cdb16796f6da43c5` matches both manifests; the
supabase mirror `20260724230000_*` is **byte-identical** (`cmp` clean).

## Independent verification performed (local cluster; `frenly_freeze` = fresh 98-chain replay)
- **Suite re-run** → ALL PASS; **governance** (tripwire + writer-registry + 3 phase0) → **41/41**.
- **Byte-diff of all 7 redefined value RPCs** against their v61/v63 predecessors: each differs by
  **exactly** the inserted pause guard (`sv_topup`/`sv_grant` +6, the five Increment-C RPCs +7),
  **−0 removed**; the v63 `sv_not_live` gate is preserved as the first check.
- **Pinned pause matrix, live (force-live shim, rolled back):** earn-pause + `sv_spend` →
  **SUCCEEDS**; redeem-pause + `sv_spend` → **REFUSED `sv_paused`, zero writes**; earn-pause +
  `sv_topup` (shadow_testing) → **REFUSED `sv_paused`**.
- **No implicit lift, live:** placed an `all` pause, published a loyalty config version → the pause
  **stays active** (count 1). Idempotent pause (one active per scope). Overview `can_cutover=false`,
  `spendable=false`, `authority_state='unbuilt'` (verbatim); preview `ready=false`.
- **Guard, live:** DELETE / scope-mutate / re-lift of an `sv_pauses` row all **BLOCKED (23001)**.
- **No cutover function** exists (grep across the corpus).

## Requirement-by-requirement

1. **Pause is a real second barrier; predecessor gates intact.** The byte-diff proves each of the
   seven RPCs (`sv_topup`, `sv_grant`, `sv_spend`, `sv_reserve`, `sv_reverse_spend`,
   `refund_sv_operation`, `sv_expire_due`) is byte-identical to its predecessor except the one
   inserted `app.sv_pause_active` guard, and the Increment-C RPCs keep `sv_not_live` as the first,
   independent check. Family mapping matches the contract: `earn` for topup/grant/refund, `redeem`
   for reserve/spend/reverse, `all_only` for the expiry sweep. `app.sv_pause_active` correctly maps
   `earn→{all,earn}`, `redeem→{all,redeem}`, `all_only→{all}`.
2. **Pinned policy — an earn pause does not block spend.** `sv_spend` consults the `redeem` family,
   which matches only `all`/`redeem` pauses, never `earn`. Proven live (earn-pause spend succeeds;
   redeem/all-pause spend refuses `sv_paused` with zero writes; earn-pause topup refuses) and by the
   suite's 9/10/11 matrix (history preserved; lifting one scope restores only that family).
3. **`sv_release` intentionally ungated — I agree.** A release returns held value to available (the
   redeem family's *undo*); it writes **no** `sv_lot_movements` — it only flips a reservation to
   `released`, restoring available. Gating it by `redeem`/`all` would *strand* held value during a
   pause, contradicting parent §8 ("a pause never strands held value"). The contract §1 lists
   exactly the seven gated RPCs and omits release. Keeping it available is the correct, §8-consistent
   design (and moot for real value, since no reservation can exist while authority ≠ `live`).
4. **`sv_pauses` house invariants.** Append-only + write-once (DELETE/identity-mutation/re-lift all
   rejected `restrict_violation`, verified live), one active pause per (business, asset, scope) via a
   partial unique index, RLS owner+SA read, browser writes revoked, composite tenant FK, integer
   scope CHECK. `sv_pause`/`sv_lift_pause` are owner-only, audited, idempotent (active pause replayed;
   lift-of-none a no-op). **No implicit lift** — verified live (config publish leaves the pause
   active) and by a new tripwire asserting `sv_pauses.lifted_at` is set only inside
   `public.sv_lift_pause`.
5. **Cutover cannot happen.** No function performs a cutover (grep + a new tripwire forbidding nine
   cutover names); `get_sv_authority_overview.can_cutover` and `preview_sv_cutover.ready` are
   **hardcoded false** (verified live); `preview_sv_cutover` is read-only and enumerates the real
   blockers. `sv_authority` is **read-only in v64** (never transitioned); `'live'`/`'ready_for_cutover'`
   remain unreachable across the whole A→D chain.
6. **UI truthfulness (§10).** The new owner-only Stored-value area renders `authority_state`
   **verbatim** (`ov.authority_state`, "never inferred"); the words "spendable"/"available to spend"
   **never appear** for the asset (grep of the section ≈ lines 7050-7380 → none); shadow figures are
   labelled "simulated"; reconciliation discrepancies are shown, never hidden; pause status/scope/
   reason are shown; the cutover control is a **permanently disabled** affordance with no click
   handler (`disabled aria-disabled="true"`, "Cutover (not available)"); it **fails closed** (an
   overview/reconciliation RPC error → error state, no controls). RPC shapes
   (`get_sv_authority_overview` / `preview_sv_cutover`) match the UI reads.
7. **Scope / gates.** v64 does not redefine the checkout kernel (`ps1c_plan_checkout` /
   `record_cart_sale` / `evaluate_checkout`), the executor (`ps1b_execute_event`), or the PS-1C.2
   `studio_rule_emergency_pauses` (which stays present and distinct from `sv_pauses`) — the only
   matches are comments; points/credit/gift_cards/benefit_registry untouched. The tripwire adds three
   real assertions (each redefined RPC carries the pause + predecessor gate and sv_release is not
   redefined; `lifted_at` set only in `sv_lift_pause`; no cutover action + can_cutover/ready false)
   while retaining the live-setter/balance-column/gift_cards-read-only ones. Manifests coherent
   (db 95→96, canonical 97→98; hash matches); v21 forward-scan includes v64.
8. **Writer-registry after two parallel agents + the whole-of-PS-2 safety story.** The shared
   registry has **256 ids with 0 duplicates** (independently recomputed); the `ps0-writer-registry`
   discovery test passes (0 missing / 0 stale). **A→D: there is no path by which real customer value
   moves, real comms send, or a cutover occurs in this frozen state** — every redemption RPC is gated
   on the unreachable `'live'` (four ways: no setter, the v61 guard, the v62 CHECK, the tripwire),
   `topup`/`grant` mint only shadow value that is never `spendable=(state='live')=false`, the pause is
   an added second barrier, there is no comms surface anywhere in PS-2, and no cutover function exists
   with `can_cutover`/`ready` hardcoded false.

## Observations (informational; not findings)
- The pause is a genuine second gate that is *operative* in PS-2A for `sv_topup`/`sv_grant` (which
  run in `shadow_testing`) and *defensive* for the redemption RPCs (whose `sv_not_live` gate fires
  first while authority ≠ `live`). Both are correct and independently tested.

## PS-2A completion note
All four increments are reviewed PASS: A (foundation, `4bf22d0`), B (shadow + reconciliation,
`a4aa801`), C (redemption mechanics + PS-0 arithmetic, `a2d1b89`), D (pause controls + UI + cutover
preview, `cab6b56`). The stored-value subsystem is complete and self-consistent, and remains
**entirely build-only** — no UAT apply and no deploy are authorized by any of these verdicts;
production cutover, real value movement, and real comms stay out of reach pending the owner's
separate instruction.

## If/when the owner authorizes a UAT apply (belt-and-suspenders; not gate conditions)
1. On UAT, confirm an earn pause blocks a shadow `sv_topup` while (under no shim) every redemption
   RPC still refuses with `sv_not_live`, and that a config publish never lifts an active sv pause.
2. Confirm `get_sv_authority_overview.can_cutover` and `preview_sv_cutover.ready` are false, and that
   the UI shows the disabled cutover affordance and fails closed on an RPC error.
3. Confirm the checkout kernel, executor, `studio_rule_emergency_pauses`, and points/credit/gift_cards
   are byte-identical post-apply.
