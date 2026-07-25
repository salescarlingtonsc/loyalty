# PS-2 LIVE Increment v68b — Lift the SV-Settlement Refusals + Net the Accounting Legs (PINNED)

Implements directive §6 of the RELEASE APPROVED pilot mandate, **part 2 of 2**. Forward-only.
Reviewer/orchestrator: Fable (this contract is the acceptance baseline). Builder base: the **v68a
freeze commit**. The migration itself moves ZERO value; prod authority stays `unbuilt` for every real
business; only the synthetic canary may gain synthetic evidence.

## A. The coupling — this is the whole point of the increment
v67 deliberately made an SV-settled sale unreversible from **both** directions (§11a in
`reverse_sale_v20_base`, §11b in `sv_reverse_spend`) because coherent stored-value restitution did not
exist. That refusal is what makes v67's §10 accounting sound: `sale_balance.sv_tender_totals` and
`get_revenue_summary.v_sv_cash` read a `consumed` tender as settled + realised cash-basis revenue and
**never net it back out**.

**Therefore: lifting EITHER refusal without netting BOTH legs in the SAME migration is a financial-
truth defect, and is an automatic BLOCKED verdict.** v68b must deliver, atomically:
1. coherent restitution (restore exactly what the spend drew), **and**
2. netting of both §10 surfaces, **and**
3. the lifting of §11a and §11b.

If any one of the three cannot be completed to this contract, ship none of them and report.

## 1. Reuse mandates (violations = automatic CHANGES REQUIRED)
- **Frozen oracle:** `docs/design/ps0/STORED_VALUE_CONTRACT.md` §6 — *"Reversal restores the exact
  lots"*: a sale reversal restores the exact per-lot allocation the spend drew (recorded `reversal`
  movements); if a target lot is now expired it is **restore-then-expire** (`+reversal` immediately
  followed by `−expiry`, both recorded — never a silent resurrection). Case (f) is the cents oracle.
- **Engine:** the v63 reversal machinery (`sv_reverse_spend` / its core) performs restitution. Do NOT
  write a parallel restore path. v67's `app.sv_spend_core` recorded the allocation; reversal consumes
  that record.
- **Kernel:** `reverse_sale_v20_base` remains the single money core every reversal funnels through.
- **Mint:** `record_sv_topup_sale` stays the ONLY mint (v66 tripwire must keep passing).
- **Movements:** the closed PS-0 8-kind vocab. No new kind.

## 2. Marking a settlement reversed — preserve v67's append-only guarantees
v67 froze a `consumed` tender: one-way `reserved → consumed|released`, terminal rows immutable, and
`sale_id`/`spend_operation_id` write-once. Two admissible designs:
- **(preferred) Append-only evidence.** Leave the tender row untouched and record the reversal in a
  new append-only table (e.g. `checkout_sv_tender_reversals`, one row per reversed settlement, unique
  on the tender, FK-bound, RLS'd). The §10 surfaces LEFT JOIN it to net.
- **(acceptable) Extend the machine.** Add a further ONE-WAY terminal transition `consumed →
  reversed`, keeping bindings frozen and every other illegal transition still raising. If you take
  this route you must update the guard and re-assert the FULL illegal-transition matrix.
State which you chose and why. **Do not loosen the frozen-binding rules under either design.** The v67
F2 partial unique indexes (`… where status='consumed'`) must remain valid and still block double
settlement.

## 3. Netting both legs (the load-bearing half)
- `sale_balance.sv_tender_totals` must EXCLUDE settlements whose sale has been reversed, so a reversed
  SV sale does not read as `paid` on a sale that no longer stands.
- `get_revenue_summary.v_sv_cash` must net the settlement out of cash-basis revenue on reversal.
  **Known trap (found by the v67 independent review):** `v_sv_cash` filters `s.reversal_of is null` on
  the ORIGINAL sale — and reversal never sets that column on the original — so keying the netting off
  `reversal_of` on the original sale silently does nothing. Key it off a signal that actually changes
  (your §2 marker). Prove the netting with before/after deltas, not by reading the SQL.
- `cash_collected` must NOT move on an SV reversal (no cash was collected for the SV portion, so none
  is returned); the cash remainder of a split sale nets through the existing payment-reversal path
  **exactly once** — prove no double-refund.
- Both surfaces are `security_invoker` views / hardened definer functions: preserve
  `with (security_invoker = on)` on any replaced view (v66a class regression — a static guard now
  checks this) and the canonical `search_path` on any replaced function (v67 D2 class).

## 4. Restitution semantics (no arbitrage)
- Restore **exactly** what was drawn: paid cents to the paid lot, bonus cents to the bonus lot, per the
  recorded allocation. Never convert bonus into paid, never into cash.
- Restore-then-expire when a target lot has since expired.
- A reversal must never increase a lot above `minted_cents`, never drive remaining below zero, and
  never create value that was not previously spent. `sv_total_outstanding` must return exactly to its
  pre-spend value for a full reversal.
- Partial/again: reversing twice must be idempotent-or-refused (v63 over-reversal bound stands).
- Interaction with v68a: a chargeback voids remaining; a later reversal of a sale settled from that
  operation must not resurrect voided value. Define and test this ordering explicitly.

## 5. Gates (unchanged pattern)
First-line `authority='live'` (typed `sv_not_live`) — real spend/reversal stays unreachable in prod
until v69; pause scopes `all`/`redeem` block reversal (a reversal is a redeem-family correction, v64);
synthetic-on-live refused (v66); the existing reversal permission (`refund_sales`) governs — do not
widen it; currency validated; all gates re-validated after locks (TOCTOU, v66/v67 pattern).

## 6. Idempotency + concurrency
`sv_operations` envelope (exact replay returns the stored result; changed-request same-key → typed
conflict). Two-connection harness: double reversal of one SV-settled sale → ONE restitution; reversal
racing an expiry sweep → consistent movements and derived balance; reversal racing a chargeback →
one winner, loser typed, no over-void and no resurrection.

## 7. Tests (`db/tests/v68b_…` rolled back + concurrency harness)
- PS-0 case (f) cents-exact, including the full bonus-lot trail `issue +1200, spend −128,
  expiry −1072, reversal +128, expiry −128` → 0.
- **The v67 crux, re-derived under the new rules:** enumerate every route that unwinds an SV
  settlement and prove each is now *coherent* rather than refused — restitution recorded, both §10
  legs netted, no double-count, `sale_balance` no longer showing the reversed sale as paid,
  `revenue_cash` netted down, `cash_collected` unmoved, outstanding restored.
- Split-tender reversal: SV portion restored to lots, cash portion refunded once via payments.
- Ordering matrix with v68a: chargeback-then-reversal and reversal-then-chargeback.
- Authority / pause / synthetic matrices; idempotent replay + same-key conflict; per-write-step atomic
  rollback injection (zero partial records); reservation-not-in-movements and outstanding invariants;
  v66 mint tripwire green; the v67 F2 settlement-uniqueness indexes still block double settlement.
- Chain gates: fresh full replay v61→v68b; ALL prior suites green (v67's suite will need its §11
  refusal assertions updated to the new expected behaviour — that is the ONE sanctioned edit to a
  prior suite, and it must be surgical and called out explicitly); `npm run validate`;
  `bash db/tests/v67_prod_shape_splice.sh` still passes; `git diff --check`.

## 8. Release ceremony (v67 lessons are binding)
Pending version `20260725080000`. **Any `pg_get_functiondef` splice needle MUST be comment-free AND
validated against PRODUCTION's live catalog before freeze** — rehearsal is not byte-faithful to prod
(GUARD 3 + v67 contract §9.1). Note that v68b will re-splice or replace functions v67 already
patched: the predecessor in prod now CONTAINS the v67 gates, so needles must be derived from the
**post-v67 prod shape**, not from the repo's pre-v67 text. **Before any apply:**
`supabase migration list --linked` must show exactly the intended pending migration and zero history
mismatches; never `--include-all`. Apply via `supabase db push --linked`. Freeze → independent
adversarial review on the exact SHA → **PASS V68B** → apply → post-apply verification → reconcile →
deploy.

## 9. Explicitly NOT in v68b
Cutover / live transition (v69); legacy gift-card/credit non-overlap (v70); customer self-service
refunds; real comms; activating any real business. Stored value remains `unbuilt` in production, so
every path built here stays structurally unreachable until v69.
