# PS-2A Increment C Independent Review Verdict — redemption mechanics + PS-0 arithmetic (v63)

Reviewer: independent adversarial reviewer (not the author). Scope: the exact frozen commit
`a2d1b89` (delta `git diff a4aa801..a2d1b89`, including the design-only Increment-D contract).
**Build-only gate**: nothing applies to UAT or deploys regardless of verdict (owner's standing
PS-2 gate).

## Formal verdict: **PASS PS-2A-C**

v63 ships the complete stored-value redemption machinery — spend, reserve/release, reverse,
refund, expiry — implementing the frozen PS-0 §3–§6 arithmetic exactly, with every value-moving
entry point hard-gated on `sv_authority.state='live'`, which is unreachable in PS-2A. I
independently reproduced the PS-0 arithmetic cent-for-cent, proved the gate blocks all six RPCs
with zero writes on the ship-default tenant, and ran a real two-connection spend race to a
one-winner result. No findings.

---

## Frozen state
HEAD `a2d1b89`; parent `a4aa801` (PS-2A-B, PASS). Tree clean. v63 migration hash
`3c5a8f7956082a3f054655820ba23e4651caaa1138ca22e14f26171a3cc18519` matches both manifests; the
supabase mirror `20260724220000_*` is **byte-identical** (`cmp` clean).

## Independent verification performed (local cluster; `frenly_freeze` = fresh 97-chain replay)
- **SQL suite re-run** → ALL PASS; **JS oracle** `ps0-sv-arithmetic.test.mjs` → **26/26**;
  governance (tripwire + writer-registry + 3 phase0) → all pass (fail 0).
- **PS-0 arithmetic driven directly against the pure SQL planners** (my own fixtures):
  - `sv_allocate_spend(10000 paid, 2000 bonus, 1000)` → **bonus_draw=166, paid_draw=834**;
    spend 12001 → `ok=false`; spend 12000 (exact) → `bonus_draw=2000`.
  - `sv_plan_refund` single partial (paid=1000, bonus=137, X=100) → **cash=100, clawback=13,
    final=false** = `floor(137×100/1000)`.
  - **Case (a) to closure**: ten $1 refunds applied in sequence → **total cash=1000, total
    clawback=137, paid_remaining=0, bonus_remaining=0** (terminal sweep leaves no stranded bonus).
  - **FEFO**: two paid lots (expiry 2027 vs 2026-06) → the allocator draws the **earlier-expiry
    lot first** (`expiry_key asc NULLS LAST → earned_seq → id`).
- **The gate, without any shim**: on a default `unbuilt` tenant, `sv_reserve` / `sv_release` /
  `sv_spend` / `sv_reverse_spend` / `refund_sv_operation` / `sv_expire_due` each raised **22023
  `sv_not_live`** with **movements delta = 0, reservations delta = 0**.
- **Real two-connection concurrency**: cloned the freeze DB and ran `v63_ps2c_concurrency.sh` →
  one `ok` + one `insufficient (0 available)`, **exactly one spend op, Σ movements = 0, zero
  negative lots**; dropped the clone.

## Requirement-by-requirement

1. **No real value can move.** Every value RPC's first line after the owner check is the gate
   `if coalesce((select state from sv_authority …),'unbuilt') <> 'live' then raise '22023
   sv_not_live'` — fail-closed on a missing row, before any DML (proven live: zero writes on an
   unbuilt tenant). Because `'live'` is unreachable (A/B property: no setter, the v61 guard, the
   v62 CHECK, the tripwire), the gate can never be satisfied in production. The pure planners
   (`sv_allocate_spend` / `sv_plan_refund` / `sv_checkout_quote`) carry no gate but perform **no
   DML** (verified) — they only compute, and only a gated RPC applies their plan.
2. **PS-0 arithmetic exact.** `sv_allocate_spend` computes `bonus_draw = floor(spend×total_bonus
   /total)` in bigint, `paid_draw = spend − bonus_draw`, rejects `spend > total`, and consumes
   FEFO across operations — matching every micro-check and the FEFO ordering. `sv_plan_refund`
   implements SF2: whole-op `clawback = bonus_remaining`, partial non-final `clawback =
   floor(bonus_remaining×X/paid_remaining)`, and the **final step (X == paid_remaining) claws the
   entire bonus** (terminal sweep). I reproduced the allocation vectors, the SF2 partial, the
   case-(a) worked example to `{0,0}` closure, and FEFO order against the frozen contract with no
   cent disagreeing. The JS oracle (26 vectors + property test) passes as a regression.
3. **Concurrency — real, no double-spend.** One-winner from a per-account `pg_advisory_xact_lock`
   plus FEFO `FOR UPDATE` row locks: the loser re-reads the drained balance (fresh READ COMMITTED
   statement after the lock) and refuses **before** writing. Independently reproduced (one ok /
   one insufficient / one spend / Σ=0 / no negative lot).
4. **Adversarial 4–8, 16.** Spend at exactly available succeeds; above available raises
   `sv_not_live`/insufficient **before any write** (atomic — the check precedes the op/movement
   inserts); `sv_reverse_spend` replays on the same key and refuses a second reverse of the same
   spend op under a different key (bounded — the over-reversal check on the reverse-op result);
   `sv_expire_due` sweeps exactly `remaining` and skips lots at `remaining ≤ 0` (cannot expire
   spent/already-expired value); duplicate `sv_spend` under one key returns the cached result (one
   effect). The `restore-then-expire` reversal writes `reversal +` then, if the restored lot is
   past `expiry_key`, `−expiry` for the same amount — reproducing the case-(f) trail to a zero
   sum. All covered by the suite (via the shim) and consistent with my code trace.
5. **Checkout kernel + prior phases byte-unchanged.** v63 does not define
   `record_cart_sale`/`ps1c_plan_checkout`/`evaluate_checkout`/`ps1b_execute_event` (grep: 0 —
   the one match is a comment), and the new tripwire "checkout kernel byte-UNCHANGED by every PS-2
   increment" enforces that those functions may only be defined in v51/v58/v59/v60. Stored-value
   tender stays inert (`sv_checkout_quote` computes; nothing consumes it). points/credit/
   gift_cards/benefit_registry untouched.
6. **House invariants.** `sv_reservations` has an append-only guard (no DELETE; identity/amount
   immutable; status one-way `active→consumed|released`), RLS owner+SA read, zero browser DML,
   composite tenant FKs, integer cents. The v61-deferred per-kind sign CHECKs are added and
   correct (`spend/expiry/refund/clawback < 0`, `reversal > 0`, `correction ±`); they constrain
   only their kinds, so the `issue`-only mint path is untouched and existing rows satisfy them.
   Every new function is SECURITY DEFINER with pinned `search_path`, revoked from
   public/anon/authenticated; the six value RPCs grant execute to authenticated and are
   owner-only; the pure/internal helpers stay un-granted. `sv_available_balance` now subtracts Σ
   active reservations — byte-equivalent today because no reservation can be created while
   authority ≠ `live`. Failed transactions leave no orphan movement/reservation (all writes follow
   the gate/validation and share one txn).
7. **Test shim honesty — legitimate, clearly bounded; the gate is tested without it.** The gated
   RPCs' arithmetic is exercised via `pg_temp.v63_force_live` (a session-local function inside
   `BEGIN/ROLLBACK` that transiently disables the `sv_authority` guard, forces `'live'`,
   re-enables the guard) — never in a migration, never persisted, never on UAT; the concurrency
   harness does the same only inside a disposable, dropped DB. Crucially the header pins **THE
   GATE as the primary safety test on an `unbuilt` tenant WITHOUT the shim**, which I independently
   reproduced. The shim manipulates the *data the gate reads*, not the gate *logic*, so it cannot
   mask a broken gate (a missing gate would fail the unbuilt-refusal test). The reviewer's
   test-side execute-grant on the shim is a session-local `pg_temp` grant, harmless. I agree with
   the technique.
8. **Scope / gates.** The tripwire removes the now-built `sv_spend_allocation`/`refund_sv_operation`
   from the forbidden set and **adds two strong structural assertions**: every value RPC must carry
   the `<> 'live'` + `sv_not_live` gate, and the checkout kernel may be defined only in v51/58/59/60.
   The live-setter, balance-column, and gift_cards-read-only assertions are retained. Manifests
   coherent (db 94→95, canonical 96→97; hash matches); v21 forward-scan includes v63; discover-writers
   classifies `sv_reservations` as a non-value hold ledger; PS-GATES documents Increment C under the
   same PS-2 authorization (no new phase; PS-3+ stay `no`).

## Builder caveat — judgment
- **#3 `sv_reservations.status='consumed'` defined-but-unused — acceptable.** It is a
  forward-declared status for the future cutover phase (a checkout reservation turned into a
  spend); the CHECK and guard permit `active→consumed`, but no PS-2A function sets it, and no
  reservation can even exist while authority ≠ `live`. Documented, inert, and gated — a harmless
  forward hook, not dead-weight risk.

## Observations (informational; not findings)
- **O1 (by-design).** `sv_expire_due` writes an `sv_operations` row even on a no-op sweep run (a
  sweep-ran audit record); the *value* effect is correctly idempotent per lot (a rerun finds
  `remaining=0` and writes no movement). Sweeps are naturally idempotent by the `remaining` check,
  not a caller idem key — correct for a cron surface.
- **O2 (future perf, moot in PS-2A).** The over-reversal guard scans reverse-op `result` JSON
  (no dedicated index). Fine at foundation scale and never exercised while authority ≠ `live`;
  worth an index if/when a cutover phase makes reversals live.

## If/when the owner authorizes a UAT apply (belt-and-suspenders; not gate conditions)
1. On UAT, confirm every value RPC refuses with `sv_not_live` on a real `unbuilt` tenant and
   writes nothing.
2. Re-run the two-connection spend race against a disposable UAT-schema clone (never the live DB).
3. Confirm the checkout kernel functions and points/credit/gift_cards are byte-identical
   post-apply (predecessor diff empty).
