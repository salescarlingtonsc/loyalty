# PS-2A Increment C — Redemption / Spend / Reverse / Refund / Expiry Mechanics (PINNED)

Builds on Increments A (v61) + B (v62). Migration **v63**. **Still forbidden:** production cutover,
real value movement, real comms, `live`/`ready_for_cutover`. Build-only gate.

## The single hard safety property of Increment C
Every value-moving path built here — spend, reserve, release, reverse, refund, expire — is **guarded
so it can only ever run when `sv_authority.state = 'live'`, which is unreachable in PS-2A**. Therefore
Increment C ships the *complete redemption machinery and its exact PS-0 arithmetic*, but **no real
customer value can move**, because every entry point checks authority=live and hard-fails otherwise
(`22023 'sv_not_live: stored value is not the authority for this business'`). The tests exercise the
machinery by (a) unit-testing the pure allocation/refund SQL functions directly, and (b) driving the
gated RPCs on a synthetic tenant whose authority is forced to `live` **only inside a rolled-back test
transaction via a test-only shim** — never in any migration, never persistently, never on UAT. If a
clean shim is impossible, the RPCs are tested for their gate (they refuse) and the arithmetic is proven
through the pure functions; document which.

## Arithmetic authority
Implements docs/design/ps0/STORED_VALUE_CONTRACT.md §3–§6 **exactly**. The frozen oracle is
tests/program-studio/ps0-sv-arithmetic.test.mjs (26 vectors + 2000-iteration property test). The SQL
allocation must produce **identical** `paid_draw`/`bonus_draw`/clawback/reversal outcomes.

### Spend allocation (§3) — pure function `app.sv_allocate_spend(business, account, spend_cents)`
- `total_paid = Σ remaining(paid lots, all ops)`, `total_bonus = Σ remaining(bonus)`, `total = sum`.
- reject if `spend > total`.
- `bonus_draw = floor(spend × total_bonus / total)`; `paid_draw = spend − bonus_draw` (paid takes the
  remainder cent — business-favorable ≤1¢).
- within each class, consume lots **FEFO across operations**: `expiry_key asc NULLS LAST → earned_seq
  asc → lot id asc`. Returns the per-lot draw plan (never over-draws a lot).
- Returns a plan (jsonb array of {lot_id, class, cents}); the caller writes one `spend` movement per lot.

### Refund (§4, SF2) — per top-up operation
- refund scope = one operation's single paid lot + single bonus lot.
- whole-op: `cash = paid_remaining`, `clawback = bonus_remaining`.
- partial of cash `X` (SF2): `X ≤ paid_remaining`; non-final `clawback = floor(bonus_remaining × X /
  paid_remaining)`; **final step (X == paid_remaining) `clawback = bonus_remaining`** (no stranded bonus).
- writes `refund` (paid −) + `clawback` (bonus −) movements.
- §5 seven requirements are the acceptance tests; cumulative clawback never exceeds proportional and the
  repeated-partial sequence terminates with paid→0 and bonus→0 together.

### Expiry (§6) — `sv_expire_lot` / sweep
- expiring a lot sweeps only that lot's remaining; **paid and bonus independent**. Cannot expire
  already-spent or already-expired value (remaining computed from Σ movements; a `−expiry` of exactly
  remaining, never more). Idempotent by lot+day key.

### Reversal (§6) — restores the exact lots
- a spend reversal restores the exact per-lot allocation the spend drew (recorded `reversal +`
  movements, keyed to the spend operation). **Restore-then-expire**: if a restored lot is now past its
  `expiry_key`, immediately record a `−expiry` for the restored amount (both movements recorded; never
  silently resurrected). Case (f) trail must reproduce: `issue +1200, spend −128, expiry −1072,
  reversal +128, expiry −128` summing to 0.
- reversal cannot exceed the remaining reversible amount of the referenced spend (bounded; over-reversal
  fails).

### bad_debt / correction — chargeback (§6)
- funding chargeback: `correction ±` voids remaining; `bad_debt` (cents=0) records the loss figure.
  (May be deferred to a follow-up if it expands scope — document; the kind is already in the CHECK.)

## RPCs (all owner/service, SECURITY DEFINER, pinned search_path, revoked, idempotency-keyed via
sv_operations, and ALL gated on authority=live):
- `public.sv_reserve(business, account, cents, idem)` → a hold row; `public.sv_release(reservation, idem)`.
  Reservations live in `public.sv_reservations` (append-only status: active→consumed|released;
  available_balance = Σ movements − Σ active reservations — update app.sv_available_balance to subtract holds).
- `public.sv_spend(business, account, cents, idem)` → allocates + writes spend movements atomically
  (or consumes a reservation). One-winner concurrency via row locks over the lot set in FEFO order.
- `public.sv_reverse_spend(business, spend_operation, idem)` → restore-then-expire.
- `public.refund_sv_operation(business, topup_operation, cash_cents|null=whole, idem)` → SF2 refund.
- `public.sv_expire_due(business, limit)` → service/cron sweep of lots past expiry_key.

## Checkout integration — SHADOW ONLY
Do NOT modify ps1c_plan_checkout / record_cart_sale in Increment C. Stored-value tender is designed but
inert: a `sv_checkout_quote` may be computed (what SV would cover) and recorded, but no checkout path
consumes it while authority≠live. Document the integration point for the future cutover phase. The
existing checkout financial logic is byte-unchanged (prove via predecessor diff = no diff).

## Invariants (added; machine-tested with REAL concurrency where noted)
- no spend exceeds available balance (checked under lock); concurrent double-spend impossible (2-conn harness).
- redemption at exactly available balance succeeds; above fails with no partial write.
- reversal idempotent; over-reversal fails; reversal restores exact lots (case f trail).
- expiry cannot expire spent/expired value; independent per class.
- every value RPC hard-refuses unless authority=live (proven: default synthetic tenant is unbuilt → all refuse).
- allocation/refund match PS-0 vectors byte-for-byte (SQL vs the JS oracle on the same inputs).
- integer cents; append-only; no mutable balance; tenant-scoped; failed txn leaves no orphan movement/reservation.

## Adversarial tests (owner's 3–8, 16 + PS-0 conformance)
3 concurrent redemptions no overspend (REAL 2-conn) · 4 exact-balance spend · 5 over-balance fails no partial ·
6 reversal idempotent · 7 over-reversal fails · 8 expiry can't expire spent · 16 duplicate checkout no
double-spend (idempotency) · PS-0: allocation vectors, SF2 partial-refund case (a) worked example to closure,
case (f) reversal trail, bonus-expired-unspent refund, whole-op refund · every RPC refuses when not live ·
regression: v61+v62 suites + PS-1C.2 checkout/pause unchanged.

## House rules
Canonical + byte-identical mirror; RLS/ACL/definer/revoke; append-only guards; composite FKs; integer cents;
writers 0/0; PS-GATES; tripwire now REMOVES sv_spend_allocation/refund_sv_operation from forbidden (built)
but ADDS an assertion that no value RPC lacks the authority=live gate; manifests 96→97 / db 94→95. Checkout
kernel + executor + all prior phases byte-unchanged.
