# PS-2 LIVE Increment v67 — Stored Value as Checkout-Kernel Tender (PINNED)

Implements directive §4/§5 of the RELEASE APPROVED pilot mandate. Forward-only; v61–v66b untouched.
Reviewer/orchestrator: Fable (this contract is the pinned acceptance baseline). Builder base commit:
`867b9a77fdce2575f5eca3da84f4329c2bca730a` (v66b freeze). After independent **PASS V67** the standing
pilot mandate covers apply + normalize + deploy without re-asking. The migration itself moves ZERO value;
prod authority stays `unbuilt` for every real business; the synthetic canary may only gain synthetic,
non-spendable evidence.

## A. What v67 is — and is not
v67 wires the EXISTING v63 spend engine into the EXISTING PS-1C checkout kernel as a tender. It builds
NO new spend arithmetic, NO new mint path, NO cutover, NO live transition, NO customer self-service
payment, NO cross-business value, NO C2C, NO cash-out, NO real comms. Real SV spend remains structurally
unreachable until v69 cutover (state `live` is still unreachable in prod; the v66 live-state gates stand).

## 1. Reuse mandates (violations = automatic CHANGES REQUIRED)
- **Spend engine:** `public.sv_reserve` / `sv_release` / `sv_spend` + `app.sv_available_balance` /
  `sv_allocate_spend` / `sv_checkout_quote` (v63) are THE engine. v67 may extend them with
  CREATE-OR-REPLACE (forward semantics preserved) but must NOT create a parallel
  allocation/spend/balance implementation. PS-0 `docs/design/ps0/STORED_VALUE_CONTRACT.md` arithmetic is
  frozen oracle: proportional paid/bonus consumption, FEFO by `expiry_key` then `earned_seq`,
  deterministic spend order per plan-version snapshot.
- **Kernel:** `evaluate_checkout` (v59) + `record_cart_sale/9` (v58/v59) are THE checkout. Extend their
  bodies; do not fork a second evaluate/finalise pair. The single-use token, cart_hash binding, config
  binding, TTL, and stale→re-evaluate→explicit-confirm semantics all stand.
- **Mint:** `record_sv_topup_sale` stays the ONLY mint (v66 tripwire must keep passing).

## 2. Token binds snapshot + reservation
- Opting into SV tender at evaluation creates ONE reservation (via the v63 reservation machinery,
  `sv_operations`-enveloped) bound to the evaluation token: amount = min(requested SV portion, available
  balance), TTL = the token's TTL. Re-evaluation atomically releases the prior token's reservation and
  creates the new one. Token expiry/abandonment → reservation released by the existing sweep pattern
  (extend the v58 sweep; no new cron unless proven necessary).
- Finalisation (`record_cart_sale/9`) consumes the reservation via `sv_spend` INSIDE the same atomic
  transaction as the sale: sale row + spend movements + tender evidence commit or roll back together.
- Drift of ANY bound fact (SV balance, config version, cart hash, current sellable state, reservation
  missing/expired) → typed `stale_evaluation` → the UI re-evaluates once and requires explicit confirm
  (existing kernel behaviour; never silent retry loops).

## 3. Reservation accounting invariant (closes the v66 forward-watch LOW note)
Reservations NEVER write `sv_lot_movements`. `app.sv_total_outstanding` (v66) remains the gross
movements sum; available-to-spend = outstanding − active reservations = `app.sv_available_balance`.
A tripwire test must assert no reservation path inserts movements, and that
`sv_total_outstanding` is unchanged by reserve/release cycles. v67 must also fix the v66 suite's
line-~213 cosmetic comment ("synthetic customer refused" vs is_synthetic=false insert) — test file
comment only, no migration edits.

## 4. Split tender + accounting (PS-0 frozen)
- A checkout may pay: SV only, SV + one other method (cash/card_terminal/paynow/manual), or no SV.
  SV portion ≤ available balance AND ≤ bill total after discounts. Remainder = existing tender path.
- The sale row stays the FULL discounted total through the existing finaliser (legacy earn on the
  discounted amount is unchanged). The SV-paid portion writes spend movements (paid/bonus split per
  PS-0) + tender evidence; the cash-collected figure for reporting excludes the SV portion (spending
  stored value collects no new cash). Paid-lot spend recognizes revenue per the PS-0 accounting
  worksheet; bonus-lot spend is promotional exposure, never revenue. No double-count: the original
  top-up stays cash-collected/liability; v67 must not create a second revenue event for the same cents
  beyond the PS-0 model.
- Loyalty interplay: points earn on the sale per existing sale policy (SV tender does not change the
  earn base in v67; any earn-exclusion policy is a later owner decision — document, don't invent).

## 5. Gates (first-line, v63/v66 pattern preserved)
Spend/reserve refuse unless authority = `live` (typed `sv_not_live`) — meaning real spend stays
unreachable in prod until v69. On `live`: synthetic business/client refused (v66 rule). Pause scopes
'all'/'redeem' block reserve+spend (v64). Permission: the checkout actor needs the existing sale
permissions only — spending SV at the till requires no extra grant, but `can_see_branch` and tenant
checks stand. Currency must equal the business currency. All gates re-validated at finalisation after
locks (TOCTOU, v66 pattern).

## 6. Idempotency + concurrency
`sv_operations` envelope for reserve/spend/release (v63 semantics: exact replay returns the stored
result; changed-request same-key → typed conflict). Two-connection harness must prove: double-finalise
of one token → one spend; two tokens racing one balance → one winner + one typed insufficient/stale;
reserve/release/expiry races leave movements sum and available balance consistent.

## 7. UI (server-authoritative, deploys with v67)
Till checkout: an "Use stored value" tender option appears ONLY when the server (extended
evaluate_checkout response or sv_checkout_quote) reports spendable balance > 0 — structurally never in
prod this phase. Amounts/split/remainder all rendered from server response; the client computes nothing.
Stale → re-evaluate-once → explicit confirm. No wallet UI in v67.

## 8. Tests (db/tests/v67_… rolled back + concurrency harness)
Full matrix: reserve→finalise happy path (forced-live shim, v63 precedent); split-tender arithmetic vs
the PS-0 oracle vectors; insufficient balance; drift matrix (balance/config/cart/reservation-expired →
stale_evaluation); pause matrix; authority matrix (unbuilt/shadow/ready refuse; live+synthetic refuse);
idempotent replay + same-key conflict; two-connection double-spend + one-winner; atomic rollback
injection at each write step (zero partial records incl. reservations); reservation-not-in-movements +
outstanding-gross tripwires; v66 mint tripwire still green; refund interplay (refund_sv_operation on a
partially-spent top-up still matches v63 suite). Chain gates: fresh full replay v61→v67; v61–v66b
suites green (reinstate fixture updated only if v67 retires something — avoid retiring); validate;
build; writer registry (curate any new/changed writer identities + browser bindings); git diff --check.

**rev-5 additions.** (a) `db/tests/v67_prod_shape_splice.sh` — the PRODUCTION-SHAPE splice parity
harness (see §9.1): rebuild through v66b, strip the full-line `--` comments out of the live
`public.sv_reverse_spend` body to reproduce prod's shape, then apply v67 and re-run the whole suite
against it. It also asserts the rev-4 comment-anchored needle drops to **0** occurrences in that
shape while the rev-5 needle stays at **1**. (b) Two partial unique indexes on
`checkout_sv_tenders (business_id, spend_operation_id)` and `(business_id, sale_id)` `where status =
'consumed'` make the settlement 1:1 that §10 and §11 both assume STRUCTURAL rather than conventional
(review finding F2: the guard trigger required a consumed row to carry both bindings but not that
they were unclaimed, so a direct `service_role` UPDATE could settle a second tender onto an
already-settled sale + spend op and inflate `sv_settled_cents` / `revenue_cash`). Both indexes are
probed one at a time in the suite, by index name.

## 9. Registration + release
Pending version `20260725060000` (canonical 104→105, pending 59→60, db manifest 102→103, collision
20260724 16→17, preflight map += v67, fixture deploy-version bump if colliding). Freeze → independent
adversarial review on the exact SHA → **PASS V67** → apply to prod (byte-fidelity hash check vs
rehearsal, normalized-comment fallback documented) → normalize ledger → reconcile main → verify
/api/build → §10-style safety catalog (real businesses: authority unbuilt, 0 real
lots/movements/payments/reservations; canary: synthetic evidence only).

### 9.1 STANDING RULE — splice needles anchor on comment-free code, validated against prod
**Every `pg_get_functiondef` splice (the v49a idiom, used by §11a and §11b) MUST anchor its needle
on COMMENT-FREE code, MUST splice in a comment-free block, and MUST have its needle validated
against PRODUCTION's live catalog before the migration is frozen.**

Why: the local rehearsal chain replays `db/migrations/*.sql` through `psql`, which preserves comments
verbatim. Production was built through the Supabase MCP `apply_migration`, which **condenses full-line
`--` comments out of large function bodies** (observed on v66's `record_sv_topup_sale` and across the
v60 wave; prod's live `sv_reverse_spend` body keeps only its 2 trailing `--` markers and none of its
10 full-line comments). **The rehearsal DB is therefore not byte-faithful to production for function
bodies.** A comment-anchored needle matches once in rehearsal and **zero times in prod**, so the
splice raises `unexpected <fn> predecessor definition (needle occurrences: 0)` and rolls the ENTIRE
migration back. This is exactly what v67 rev-4's §11b needle would have done; it passed every local
gate and was caught only by reading the production catalog. No amount of local rehearsal finds it.

Enforcement: `tests/phase0-foundation/pending-migration-hardening-guards.test.mjs` **GUARD 3** fails
any pending migration whose splice needle or spliced-in block contains `--` (and fails closed when a
needle cannot be parsed); `db/tests/v67_prod_shape_splice.sh` rehearses the apply against a
production-shaped predecessor by stripping the full-line comments out of the live body first.
A pre-freeze read of prod's `pg_get_functiondef` for the target function remains mandatory — the
guard proves the needle *can* match a comment-stripped body, only prod proves it *does*.
