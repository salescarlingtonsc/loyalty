# PS-0 — Stored-Value Contract (FROZEN)

Status: **PS-0 (contracts only). FROZEN.** No financial execution is implemented by
this document or its companion tests. The arithmetic below is proven executably by a
pure-JavaScript **reference implementation** in
`tests/program-studio/ps0-sv-arithmetic.test.mjs`; the real SQL lands in **PS-2** and
**must reproduce these exact-cent vectors**. If the PS-2 engine ever disagrees with a
number here, the engine is wrong.

Authority: §5 (and §4 value-domain, §6 event identity) of
`docs/design/PROGRAM_STUDIO_ARCHITECTURE.md`, revision 4, which passed independent
review (`PROGRAM_STUDIO_REVIEW_VERDICT.md`, round 3 PASS). This contract also clears
the review's SF2 (partial-refund wording) by pinning cash semantics and gives every
matrix row a numbered, executable test.

All amounts are **integer cents**. All divisions **floor** (BigInt truncation toward
zero). "Business-favorable by ≤1¢" always means the refundable *paid* class is drawn
slightly more, never less.

---

## 1. Scope of the freeze

Frozen here (each with an executable test):

- Plan versions and **immutable lots**; the append-only movement ledger with **all
  eight movement types**.
- **Aggregate-proportional spend allocation** with **cross-operation FEFO**
  (expiry → earned → lot id), **floor-on-bonus rounding with paid remainder**.
- **Per-operation refunds**: whole-operation, and partial with the **SF2 cash
  formula** and the **seven numbered rounding requirements**.
- **Terminal full-bonus clawback** (closing an operation strands no bonus cent).
- **Expiry independence**; **reversal-restores-exact-lots** (including
  restore-then-expire); **funding chargeback + bad-debt**; **business corrections**.
- **Idempotency** (op-ledger) + **per-customer advisory serialization**.
- **Liability split** (paid deferred-revenue ∥ bonus promotional).

Deliberately **NOT** in this contract (owner-deferred to PS-2 and downstream, per §5 /
§17): the `sales.kind='topup'` CHECK extension and the
`app.sale_policy_defaults()` topup row (`revenue=false, visit=false, points=false`);
the `stored_value` tender in the checkout kernel; Stripe SG auto-charge; the
SG PS-Act T&C review ⚖️. Purchase accounting (paid = deferred revenue, bonus =
promotional) is stated but its ledger posting is a PS-2 concern.

---

## 2. Structure — plan versions, immutable lots, append-only movements

**Plan versions.** `sv_plans` gains immutable `sv_plan_versions` (§13). A top-up pins
its exact `plan_version_id` and embeds a complete `terms_snapshot` (price, bonus
ladder, expiry terms, eligibility). Consumption/refund logic reads the purchase's own
snapshot, never the live plan.

**Immutable lots.** A top-up **operation** mints exactly **two immutable** `sv_lots`
rows:

| field | meaning |
|---|---|
| `class` | `paid` (customer cash) or `bonus` (promotional, never cash-out) |
| `original_cents` | minted amount (immutable) |
| `remaining_cents` | **locked cache**, maintained only by the movement writer in-txn |
| `expiry_key` | FEFO primary; **paid and bonus expire independently** |
| `earned_seq` | FEFO secondary (creation order) |
| `source operation` | the top-up op every lot traces back to |

**Append-only movements.** `sv_lot_movements` is **the authority**. `remaining_cents`
is a denormalized cache; the invariant **`remaining ≡ Σ movements`** holds after every
write (asserted per step in the suite and by a nightly sweep). Movement types:

| type | sign | written by |
|---|---|---|
| `issue` | + | top-up mint |
| `spend` | − | spend allocation |
| `expiry` | − | expiry sweep |
| `reversal` | + | sale reversal (restore) |
| `refund` | − | per-op cash refund (paid class only) |
| `clawback` | − | bonus clawback at refund |
| `correction` | ± | chargeback void / owner correction |
| `bad_debt` | 0¹ | chargeback loss record (report figure) |

¹ `bad_debt` carries `cents=0` against the lot cache (it references *already-consumed*
value, not remaining), so it never disturbs the `remaining ≡ Σ movements` invariant;
the loss figure lives on the record.

---

## 3. Spend allocation — aggregate-proportional, cross-operation FEFO

At spend time, over **all** of the customer's operations:

```
total_paid  = Σ remaining(paid  lots, all ops)
total_bonus = Σ remaining(bonus lots, all ops)
total       = total_paid + total_bonus                 (spend ≤ total, else rejected)

bonus_draw  = floor(spend × total_bonus / total)        # floor on bonus
paid_draw   = spend − bonus_draw                        # paid takes the remainder cent
```

Then within each class, consume lots **FEFO across operation boundaries**:
`expiry_key` asc → `earned_seq` asc → `lot id` asc. Inverting one class's expiry order
changes **which** lot is drawn, never the drawn **amounts** or any refund outcome
(proven by case (h)).

Rounding is deterministic and **business-favorable by ≤1¢ per spend**: flooring bonus
draws the refundable paid class up by the remainder cent.

Worked micro-checks (all in the test):

| total_paid | total_bonus | spend | bonus_draw | paid_draw |
|---|---|---|---|---|
| 10 000 | 1 200 | 1 200 | `floor(1200×1200/11200)=128` | 1 072 |
| 10 000 | 1 200 | 5 600 | `floor(5600×1200/11200)=600` | 5 000 |
| 15 000 | 1 700 | 5 600 | `floor(5600×1700/16700)=570` | 5 030 |

A 2 000-iteration seeded property test asserts `paid_draw + bonus_draw == spend`,
`bonus_draw == floor(spend×bonus/total)`, and neither class is over-drawn.

---

## 4. Refund model — per operation

**Refund scope is per top-up operation** (§5, S2). Every lot traces to its source op;
a refund targets exactly one operation's single paid lot + single bonus lot. A
"refund my whole balance" iterates the customer's operations **newest-first** (each is
an independent per-op refund).

**Safe-default rule:** **cash refund = that operation's paid-class remaining only;
the operation's bonus remaining is clawed back (expired) at refund time.** Nothing
looser is expressible; owner-configurable variants may only be *stricter* (e.g.
no partial refunds).

**Whole-operation refund.**
```
cash      = op.paid_remaining          # $ to customer
clawback  = op.bonus_remaining         # bonus voided
```

**Partial refund of $X (SF2 pinned).** `X` is **cash returned to the customer**,
drawn from that operation's **paid** remaining (`X ≤ paid_remaining`, always). Bonus
is never paid as cash; it is clawed back proportionally:
```
X ≤ paid_remaining                                  # requirement 3, enforced
clawback = floor(bonus_remaining × X / paid_remaining)      # non-final step
clawback = bonus_remaining                                  # FINAL step (X == paid_remaining)
```
The **final** refund (the one that zeroes paid) claws back the **entire** bonus
remaining — the terminal sweep, not the floor formula — so closing an operation leaves
**no stranded bonus cent** (requirement 2).

---

## 5. The seven numbered rounding requirements (§5) → tests

| # | Requirement | Proven by (named test) |
|---|---|---|
| 1 | Repeated small/1-cent partial refunds allowed; floor clawback may **lag** proportionality between steps but **never exceeds it cumulatively** | `req 1+2+7 case (a) …` (asserts `clawTotal ≤ proportional` every step) |
| 2 | The **final** refund of the paid remainder claws back the **entire** bonus remaining (terminal, not floor) — no stranded bonus cent | `req 2: the FINAL refund … ENTIRE bonus remaining` |
| 3 | Cumulative cash per operation **never exceeds** original paid (`X ≤ paid_remaining` at every step + movement-sum invariant) | `req 3: a partial refund can never exceed …` |
| 4 | After every movement, `Σ movements per lot ≡ cached remaining` | `req 4: Σ movements ≡ cached remaining … per step` |
| 5 | Determinism under retries: every refund op carries an idempotency key; lost-response + retry replays the **byte-equal** movement set | `req 5 case (d): lost response + retry replays …` |
| 6 | Determinism under concurrency: per-customer advisory-lock serialization; two concurrent refunds → one movement set + one replay; concurrent spend+refund serialize on consistent remainders | `req 6 case (c)`, `req 6 case (c-var)`, `req 6 case (b)` |
| 7 | A repeated-partial-refund sequence always **terminates**: paid remaining strictly decreases to 0 and (per req 2) bonus reaches exactly 0 when paid does | `req 1+2+7 case (a) …` (loops to closure with a termination guard) |

**Case (a) worked** — $10.00 paid / $1.37 bonus (13.7% ratio), repeated $1 refunds:

| step | X (cash) | paid before | bonus before | clawback | cumulative claw | proportional (13.7·n) |
|---|---|---|---|---|---|---|
| 1 | 100 | 1 000 | 137 | `floor(137·100/1000)=13` | 13 | 13.7 |
| 2 | 100 | 900 | 124 | `floor(124·100/900)=13` | 26 | 27.4 |
| 3 | 100 | 800 | 111 | `floor(111·100/800)=13` | 39 | 41.1 |
| 4 | 100 | 700 | 98 | `floor(98·100/700)=14` | 53 | 54.8 |
| 5 | 100 | 600 | 84 | 14 | 67 | 68.5 |
| 6 | 100 | 500 | 70 | 14 | 81 | 82.2 |
| 7 | 100 | 400 | 56 | 14 | 95 | 95.9 |
| 8 | 100 | 300 | 42 | 14 | 109 | 109.6 |
| 9 | 100 | 200 | 28 | 14 | 123 | 123.3 |
| **10 (final)** | 100 | 100 | 14 | **14 (entire bonus)** | **137** | 137.0 |

Cash total **$10.00** (= original paid), clawback total **$1.37** (= original bonus),
operation closed at `{paid:0, bonus:0}` with **no stranded cent**. The floor lags
(13 < 13.7) early; the terminal step sweeps the remainder. Cumulative clawback never
exceeds proportional at any step.

---

## 6. Other operations

**Expiry independence.** Expiring a lot sweeps only that lot's remaining; a bonus
expiry never touches a paid lot. (Matrix row "bonus expired unspent" → refund
$100.00, clawback 0.)

**Reversal restores the exact lots.** A sale reversal restores the exact per-lot
allocation the spend drew (recorded `reversal` movements). If a target lot is now
**expired**, it is **restore-then-expire**: a `+reversal` immediately followed by a
`−expiry`, both recorded — an expired lot is never silently resurrected. Case (f):

- Spend $12 → bonus −128, paid −1 072 (`{paid:8928, bonus:1072}`).
- Bonus lot expires → `−1 072` (`{paid:8928, bonus:0}`).
- Sale reversal → paid `+1 072` (→10 000); bonus `+128` then `−128` (→0).
- Bonus lot movement trail: `issue +1200, spend −128, expiry −1072, reversal +128,
  expiry −128` — sums to 0 ≡ remaining. Paid restored fully to 10 000.

**Funding chargeback + bad debt.** The funding payment is reversed by the bank. Void
**all** remaining lots (paid + bonus) via `correction`; the **bad debt** is the net
paid value already **delivered as goods** (`Σspend − Σreversal` on the paid lot) that
voiding cannot recover. Sales already delivered stand. Case (e), after an $80 spend on
$100 paid / $12 bonus:

- Spend $80 → bonus −857, paid −7 143 (`{paid:2857, bonus:343}`).
- Chargeback → void paid 2 857, void bonus 343 (both → 0).
- **Bad debt = 7 143¢ = $71.43** (the paid value consumed as goods).
  ⚖️ Exact bad-debt accounting treatment requires accountant review.

**Business corrections.** Owner-gated `correction` movement, **reason mandatory**,
both directions, audited. (Rejects an empty reason.)

---

## 7. Idempotency & serialization

**Op-ledger idempotency.** Every value-moving op carries an idempotency key; the engine
keys an op-ledger on `(customer, op_type, idempotency_key)`. A replay returns the
stored result **byte-equal** and writes **zero** new movements (case (d): a $30 partial
refund retried under the same key leaves paid at 7 000, one movement set).

**Per-customer advisory serialization.** All of a customer's stored-value mutations
serialize on a per-customer advisory lock (modeled here as single-threaded execution):

- **Two concurrent whole-refunds, same key** (case (c)): one winner materializes
  ($80.00), the other is an idempotent replay — never a double payout.
- **Two refunds, different keys** (case (c-var)): the first fully refunds ($80.00),
  the second observes a closed op and returns **$0.00**.
- **Concurrent spend vs refund** (case (b)): spend-then-refund → spend $30 (bonus 321,
  paid 2 679) then refund cash **$73.21**; refund-then-spend → refund $100.00 then the
  $30 spend is **rejected** (insufficient stored value). Either serialization conserves
  and never lets cash-out exceed original paid.

---

## 8. Liability split

`v_customer_value` always reports paid and bonus **separately, never blended**:

```
deferred_revenue_cents = Σ remaining(paid  lots)   # customer cash, deferred revenue
promotional_cents      = Σ remaining(bonus lots)   # promotional, never cash-out
```

---

## 9. Worked-case results table (cents) — the frozen vectors

All verified by `tests/program-studio/ps0-sv-arithmetic.test.mjs`.

### Single-operation §5 matrix — $100 paid (10 000) + $12 bonus (1 200)

| Case | spend | bonus_draw | paid_draw | cash refunded | bonus clawback | note |
|---|---|---|---|---|---|---|
| Full unused reversal | — | — | — | **10 000 ($100.00)** | 1 200 | customer & business whole |
| Spent $12.00 | 1 200 | 128 | 1 072 | **8 928 ($89.28)** | 1 072 | rev-1 arbitrage dead (would've been $100.00) |
| Spent $56.00 | 5 600 | 600 | 5 000 | **5 000 ($50.00)** | 600 | exactly proportional |
| Fully spent $112.00 | 11 200 | 1 200 | 10 000 | **0 ($0.00)** | 0 | nothing to refund |
| Bonus expired, nothing spent | — | — | — | **10 000 ($100.00)** | 0 | expiry never touched paid |

### Multi-operation — A=$100+$12 (10 000/1 200), B=$50+$5 (5 000/500), spend $56

| step | value |
|---|---|
| aggregate | paid 15 000 / bonus 1 700 / total 16 700 |
| spend $56 | bonus_draw `floor(5600·1700/16700)=570`, paid_draw 5 030 (all on A) |
| A remaining | paid 4 970 / bonus 630 |
| B remaining | paid 5 000 / bonus 500 |
| **refund A** | **4 970 ($49.70)** cash + 630 clawback |
| **refund B** | **5 000 ($50.00)** cash + 500 clawback |
| conservation | 4 970 + 5 000 = 9 970 = total paid remaining (15 000 − 5 030) ✓ |

### The lettered PS-0 cases

| case | scenario | headline result | conservation |
|---|---|---|---|
| (a) | $10.00/$1.37, ten $1 refunds to closure | cash $10.00, clawback $1.37, **no stranded cent** | Σ per-lot ≡ remaining every step |
| (b) | concurrent spend vs refund | spend-first cash $73.21; refund-first rejects the spend | cash-out ≤ 10 000 both orders |
| (c) | two same-key whole refunds | one $80.00 payout + one byte-equal replay | one movement set |
| (d) | lost response + retry (same key) | $30 refund applied **once**, paid 7 000 | zero new movements on retry |
| (e) | chargeback after $80 spend | void 2 857 paid + 343 bonus; **bad debt $71.43** | remaining → 0, invariant intact |
| (f) | expired bonus then sale reversal | paid → 10 000; bonus restore-then-expire → 0 | bonus trail sums to 0 |
| (g) | A=$100+$12, B=$200+$50, spend $50 | refund A **$58.56** (claw 344), refund B **$200.00** (claw 5 000) | 5 856 + 20 000 = 25 856 = paid remaining |
| (g-spill) | then spend $120 | A drained; B paid 15 911 / bonus 3 289; refund B **$159.11** | cross-op FEFO exercised |
| (h) | inverted expiry order (B bonus first) | refund A **$49.70** (claw 1 130), refund B **$50.00** (claw 0) | 9 970 = 9 970; amounts unchanged vs same-order |
| (i) | mixed lifecycle (2 ops, 2 spends, partial + whole refunds) | both ops closed `{0,0}`, cash-out ≤ paid minted | Σ movements ≡ balances |

Rounding detail for (g): `bonus_draw = floor(5000·6200/36200) = 856`, `paid_draw =
4 144`, drawn wholly from A (FEFO-first). Detail for (g-spill): `bonus_draw =
floor(12000·5344/31200) = 2 055`, `paid_draw = 9 945`.

---

## 10. Invariants (asserted in every case + fuzz)

1. **Conservation:** for every lot, `Σ movements ≡ remaining` (cache-affecting types).
2. **Cumulative cash ≤ original paid** per operation.
3. **No stranded bonus** after an operation is **closed by refund** (`{paid:0,
   bonus:0}`).
4. **Determinism:** same seed → identical movement fingerprint (proven over seeds
   {1,7,42,99,256,400}).

The fuzz section runs **400 seeded scenarios** (8–24 randomized steps each: top-ups
with independent paid/bonus expiries, aggregate-proportional spends, partial and whole
refunds, expiries) asserting all four after **every** step and at end-of-run, plus a
2 000-iteration `allocateSpend` property test.

---

## 11. Contract ambiguities pinned during PS-0 (flag for orchestrator)

1. **`tier_entry` key arity mismatch (cross-doc).** §3 registers
   `tier_entry:{client}:{tier}`; §12 uses
   `tier_entry:{business}:{client}:{tier}`. The benefit-key generator follows **§3**
   (the task's authority) — `tier_entry:{client}:{tier}` — because
   `canonical_benefit_key` is already scoped by `business_id` in the
   `UNIQUE(business_id, canonical_benefit_key)` constraint, so `{business}` in the key
   is redundant. **Orchestrator: reconcile §3 vs §12 wording** before PS-3.
2. **Per-event key template wording (N6).** §3 registers
   `sv_spend:{operation}:{movement}` and `discount:{sale}:{rule}:{effect_index}`; the
   verdict's N6 note suggested `sv_move:{movement_id}` / `discount:{sale}:{effect}`.
   PS-0 froze the **§3** forms. **Orchestrator: confirm §3 is canonical** and update
   the verdict's N6 note, or vice-versa.
3. **Bad-debt accounting basis (⚖️).** PS-0 defines bad debt as *net paid value already
   delivered as goods* (`Σspend − Σreversal` on the paid lot). This is a defensible
   engineering definition but the accounting treatment (write-off vs contra-revenue,
   GST implications) is **owner + accountant** territory. Flagged, not decided.
4. **Interaction of prior refunds with a later chargeback.** The contract voids
   remaining and reports goods-delivered bad debt; it does **not** attempt to recover
   cash **already refunded** to the customer before a chargeback (a double-loss edge:
   business refunded cash *and* the funding was clawed back). PS-0 leaves this to the
   PS-2 fraud/chargeback policy — **flagged** as an owner decision, since the safe
   default (paid-only cash refund) already limits exposure to paid remaining at each
   step.
5. **SF1 (informational).** The architecture's §3 ERD (l.89) and §17 PS-1B row still
   carry the abandoned "generalize v33 outbox" wording; §6 is authoritative (NEW
   `event_outbox`). Out of PS-0 stored-value scope, but noted so the orchestrator
   clears it before PS-1B, per the verdict.

---

## 12. Test map

| Contract clause | Test file |
|---|---|
| §2–§10 stored-value arithmetic (all cases + fuzz) | `tests/program-studio/ps0-sv-arithmetic.test.mjs` |
| §6 canonical event identity + effect uniqueness | `tests/program-studio/ps0-event-identity.test.mjs` |
| §3 canonical benefit-key templates | `tests/program-studio/ps0-benefit-keys.test.mjs` |
| §17 no-executor gate (this phase) | `tests/program-studio/ps0-no-executor.test.mjs` + `docs/design/ps0/PS-GATES.md` |

Run: `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate` (these run
under `npm test`).
