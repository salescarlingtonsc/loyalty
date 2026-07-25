# PS-2 LIVE Increment v68a — Chargeback, Bad Debt, Correction, Refund Caps (PINNED)

Implements directive §6 of the RELEASE APPROVED pilot mandate, **part 1 of 2**. Forward-only;
v61–v67 untouched in behaviour. Reviewer/orchestrator: Fable (this contract is the acceptance
baseline). Builder base commit: `ad5cc7b` (v67 applied + deployed). The migration itself moves ZERO
value; prod authority stays `unbuilt` for every real business; only the synthetic canary may gain
synthetic evidence.

## Why v68 is split (orchestration decision)
Directive §6 covers refund + reversal + chargeback + expiry. The **reversal** half is coupled to
v67's accounting: lifting either §11 refusal REQUIRES netting the settlement legs out of
`sale_balance.sv_tender_totals` AND `get_revenue_summary.v_sv_cash` **in the same increment**. That
coupled change deserves its own contract and its own adversarial review.
- **v68a (this doc):** chargeback + bad debt + business correction + refund caps + expiry matrix.
  Independent of the coupling. Does NOT touch §11a/§11b — an SV-settled sale stays unreversible.
- **v68b (next):** lift §11a + §11b, coherent SV-settled reversal, and the settlement-leg netting,
  atomically together.

## A. What v68a is — and is not
It completes the PS-0 §6 "other operations" surface on top of the v63 engine. It builds NO new
allocation arithmetic, NO new mint path, NO cutover, NO live transition, NO customer self-service,
NO real comms, and it does NOT lift the v67 reversal refusals. Real stored value stays structurally
unreachable: every write path keeps the v63/v66 first-line `authority='live'` gate, which is
unreachable in prod until v69.

## 1. Reuse mandates (violations = automatic CHANGES REQUIRED)
- **Frozen oracle:** `docs/design/ps0/STORED_VALUE_CONTRACT.md` §4/§6/§9 is authoritative arithmetic.
  Its lettered cases and cents-exact vectors are the acceptance oracle — do not re-derive them.
- **Engine:** `app.sv_allocate_spend`, `app.sv_available_balance`, `app.sv_lot_remaining`,
  `app.sv_plan_refund` (v63) are THE engine. Extend by CREATE-OR-REPLACE preserving unrelated bytes;
  build no parallel allocation/balance/refund implementation.
- **Envelope:** every new op goes through the `sv_operations` idempotency envelope (unique
  business/operation_type/idempotency_key + request_hash + advisory lock + cached-result replay,
  changed-request same-key → typed conflict).
- **Movements:** the PS-0 8-kind vocab is closed — `issue/spend/expiry/reversal/refund/clawback/
  correction/bad_debt`. v68a introduces the first writers for **`correction`** and **`bad_debt`**
  (verify that claim against the live catalog before building; the v67 review found neither had a
  writer). No new kind may be added.
- **Mint:** `record_sv_topup_sale` stays the ONLY mint (v66 tripwire must keep passing).

## 2. Chargeback (PS-0 §6, case (e))
`public.sv_chargeback_topup(business, topup_operation, reason, idempotency_key)` — owner-gated.
The funding payment was reversed by the bank, so:
- **Void ALL remaining** on that operation's lots — paid remaining and bonus remaining — via
  negative `correction` movements (PS-0 says void via `correction`; do not invent a new kind).
- **Bad debt = net paid value already delivered as goods** = `Σspend − Σreversal` on that
  operation's PAID lot. Record it as a `bad_debt` movement of **zero balance effect** or as an
  operation-result field — it must NOT double-subtract value already voided. State which
  representation you chose and prove the movements still sum to the derived remaining.
- Sales already delivered **stand** (no sale is reversed, no goods clawed back).
- Case (e) vector is the oracle: $100 paid + $12 bonus, $80 spend → void paid 2 857 + bonus 343,
  **bad debt = 7 143¢**.
- The top-up's `sv_topup_payments` row is immutable (v66); record the chargeback as an append-only
  `sv_topup_payment_events` row (`event_type='chargeback'`) — do not mutate the payment.
- ⚖️ **Flag, do not decide:** the accounting treatment of bad debt (write-off vs contra-revenue, GST)
  is owner + accountant territory (PS-0 §11.3). Emit the number and the evidence; classify nothing.

## 3. Prior-refund-then-chargeback (PS-0 §11.4 — pinned default, owner-ratifiable)
PS-0 leaves this to PS-2 policy. **Pinned safe default:** a chargeback voids only what REMAINS and
reports goods-delivered bad debt; it does **not** attempt to recover cash already refunded to the
customer. The double-loss (business refunded cash *and* the funding was clawed back) is surfaced
explicitly in the operation result as a distinct figure (e.g. `cash_already_refunded_cents`) so the
owner can see it, and is written to `audit_log`. Do not net it against anything. Document the choice
in the migration header as a pinned default awaiting owner ratification.

## 4. Business correction (PS-0 §6)
`public.sv_correct_lot(business, lot, cents, reason, idempotency_key)` — owner-gated, **reason
mandatory** (reject empty/whitespace, min 3 chars, typed 22023), **both directions** (positive and
negative), fully audited. Invariants: a correction may never drive a lot's derived remaining below
zero, nor above its `minted_cents`; it never touches another lot; it is not a mint (the v66 tripwire
must still show `record_sv_topup_sale` as the only paid-lot minter).

## 5. Refund caps + no-arbitrage (directive §6)
Extend/verify on the v63 refund path:
- **Cash-refund cap:** cumulative cash refunded for a top-up operation may never exceed the cash
  actually collected for it (`sv_topup_payments.amount_cents`), and never exceeds paid remaining.
  Enforce structurally; typed refusal on breach.
- **No refund arbitrage:** spending bonus then refunding all paid must not leave the customer ahead.
  The PS-0 safe default already implies this (cash = paid remaining only; bonus clawed back at
  refund). Prove it with an explicit adversarial case: spend drawn proportionally, then full refund →
  customer receives ≤ cash paid, bonus remaining is voided, no stranded bonus cent.
- **Unused-only refund** (directive wording): support the stricter owner-configurable variant where a
  refund is permitted ONLY when the operation has been wholly unspent. Config-driven, default OFF
  (v65 plan-version config is the natural home — reuse it; do not invent a parallel config table).

## 6. Expiry matrix (PS-0 §6)
Verify and harden, do not redesign: expiry independence (a bonus expiry never touches a paid lot);
**restore-then-expire** for reversal onto an already-expired lot (`+reversal` immediately followed by
`−expiry`, both recorded — never a silent resurrection). Case (f) is the oracle, including the exact
bonus-lot movement trail `issue +1200, spend −128, expiry −1072, reversal +128, expiry −128 → 0`.

## 7. Gates + idempotency (unchanged pattern)
First-line `authority='live'` (typed `sv_not_live`); pause scopes — chargeback/correction are
redemption-family corrections, so `all`/`redeem` pauses block them (state the mapping explicitly);
synthetic-on-live refused (v66); owner-only for chargeback and correction; currency validated;
all gates re-validated after locks (TOCTOU, v66/v67 pattern). Two-connection harness: concurrent
chargeback of one op → one effect; chargeback racing a refund → one winner, the loser typed, and the
lot never over-voided.

## 8. Tests (`db/tests/v68a_…` rolled back + concurrency harness)
The PS-0 **lettered cases and frozen cents vectors** (§9 tables) are the oracle — assert cents-exact,
including case (e) chargeback and case (f) restore-then-expire, the §5 seven rounding requirements,
and the §10 invariants on every case plus fuzz. Plus: correction rejects empty reason / over-void /
over-mint; cash-refund cap breach refused; no-arbitrage adversarial case; unused-only variant on and
off; authority/pause/synthetic matrices; idempotent replay + same-key conflict; per-write-step atomic
rollback injection (zero partial records); `sv_total_outstanding` and reservation invariants intact;
v66 mint tripwire green; v67 §11a/§11b refusals **still refuse** (v68a must not weaken them).
Chain gates: fresh full replay v61→v68a; ALL prior suites green; `npm run validate`; `git diff
--check`; writer registry curated for every new identity.

## 9. Release ceremony (unchanged, plus the v67 lessons)
Registration in both plans/manifests; pending version `20260725070000`. **If any
`pg_get_functiondef` splice is used:** the needle MUST be comment-free AND validated against
PRODUCTION's live catalog before freeze (GUARD 3 + contract v67 §9.1 — rehearsal is not byte-faithful
to prod). **Before any apply:** `supabase migration list --linked` must show exactly the intended
pending migration and zero history mismatches; never `--include-all`. Apply via
`supabase db push --linked` (exact bytes, one transaction). Freeze → independent adversarial review on
the exact SHA → **PASS V68A** → apply → post-apply catalog + safety verification → reconcile → deploy.

## 10. Explicitly NOT in v68a
Lifting §11a/§11b; SV-settled sale reversal; settlement-leg netting; cutover; customer-facing refund
UI; real comms; activating any real business. Stored value remains `unbuilt` in production.
