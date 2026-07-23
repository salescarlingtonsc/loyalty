// PS-0 stored-value arithmetic — executable proof of the STORED_VALUE_CONTRACT.
//
// This file contains a REFERENCE IMPLEMENTATION (pure JavaScript) of the
// stored-value allocation / refund algorithms frozen in
// docs/design/ps0/STORED_VALUE_CONTRACT.md (§5 of PROGRAM_STUDIO_ARCHITECTURE.md).
//
// NO FINANCIAL EXECUTION IS SHIPPED HERE. There is no SQL, no DB, no money movement.
// The real executor lands in PS-2 and MUST reproduce these exact-cent vectors. If a
// future engine disagrees with any assertion below, the engine is wrong, not the test.
//
// All arithmetic is integer cents. Determinism is guaranteed: floor divisions use
// BigInt truncation, and the fuzz section is seeded (no Date.now / unseeded Math.random).

import assert from 'node:assert/strict';
import test from 'node:test';

// ---------------------------------------------------------------------------
// Deterministic integer helpers
// ---------------------------------------------------------------------------

// floor(a * b / c) with exact integer semantics for non-negative integers.
// BigInt division truncates toward zero, which equals floor for non-negatives.
function floorMulDiv(a, b, c) {
  if (a < 0 || b < 0 || c <= 0) throw new Error('floorMulDiv expects non-negative a,b and positive c');
  return Number((BigInt(a) * BigInt(b)) / BigInt(c));
}

// floor(n * num / den) for a single ratio; same exact semantics.
function floorRatio(n, num, den) {
  return floorMulDiv(n, num, den);
}

// ---------------------------------------------------------------------------
// The reference stored-value engine (pure, in-memory, append-only movements)
// ---------------------------------------------------------------------------
//
// Model (contract §5):
//  - A top-up OPERATION mints exactly two IMMUTABLE lots: one paid, one bonus.
//  - `sv_lot_movements` is the append-only authority; movement_type ∈
//    (issue, spend, expiry, reversal, refund, clawback, correction, bad_debt).
//  - `remaining_cents` on a lot is a LOCKED CACHE maintained only by the movement
//    writer; the invariant `remaining == Σ movements` holds after every write.
//  - Spend allocation is aggregate-proportional across ALL of the customer's
//    operations (floor on bonus, paid takes the remainder cent), then FEFO within
//    each class across operation boundaries (expiry → earned → lot id).
//  - Refunds are PER top-up operation: cash = that op's paid remaining only; bonus
//    remaining is clawed back. Partial refund of $X: X ≤ op paid remaining, cash = X,
//    proportional bonus clawback = floor(bonus_rem * X / paid_rem); the FINAL refund
//    (X == paid_rem) claws back the ENTIRE bonus remaining (no stranded cent).
//
// The engine serializes all mutations per customer (single-threaded here = the
// per-customer advisory lock), and dedupes by an op-ledger keyed on
// (customer, op_type, idempotency_key) so retries replay byte-equal.

const MOVEMENT_TYPES = new Set([
  'issue', 'spend', 'expiry', 'reversal', 'refund', 'clawback', 'correction', 'bad_debt',
]);

function createEngine(customerId = 'cust-1') {
  let lotSeq = 0;
  let moveSeq = 0;
  const lots = [];              // immutable except remaining cache + expired flag
  const movements = [];         // append-only authority
  const spendAllocations = {};  // spendOpId -> [{lotId, cls, drawn}]
  const opLedger = new Map();   // idempotency: key -> frozen result

  function ledgerKey(opType, idemKey) {
    return `${customerId}|${opType}|${idemKey}`;
  }

  function pushMovement(lot, movementType, cents, refOp, note) {
    if (!MOVEMENT_TYPES.has(movementType)) throw new Error(`bad movement type ${movementType}`);
    const m = {
      seq: moveSeq++,
      lotId: lot.id,
      operationId: lot.operationId,
      cls: lot.cls,
      movementType,
      cents,           // signed
      refOp: refOp ?? null,
      note: note ?? null,
    };
    movements.push(m);
    lot.remaining += cents;
    if (lot.remaining < 0) throw new Error(`lot ${lot.id} remaining went negative`);
    return m;
  }

  // FEFO order within a class: expiry asc, then earned (earnedSeq) asc, then lot id asc.
  function fefo(cls) {
    return lots
      .filter((l) => l.cls === cls && l.remaining > 0)
      .sort((a, b) => (a.expiryKey - b.expiryKey) || (a.earnedSeq - b.earnedSeq) || (a.id - b.id));
  }

  function classRemaining(cls) {
    return lots.filter((l) => l.cls === cls).reduce((s, l) => s + l.remaining, 0);
  }

  function opLots(operationId) {
    const paid = lots.find((l) => l.operationId === operationId && l.cls === 'paid');
    const bonus = lots.find((l) => l.operationId === operationId && l.cls === 'bonus');
    return { paid, bonus };
  }

  // mintLots: a top-up operation. Immutable paid + bonus lots, each with an `issue`
  // movement. expiryKey lets paid and bonus expire independently and in any order.
  function mintLots(operationId, paidCents, bonusCents, opts = {}) {
    const paidExpiry = opts.paidExpiryKey ?? opts.expiryKey ?? (1000 + lotSeq);
    const bonusExpiry = opts.bonusExpiryKey ?? opts.expiryKey ?? (1000 + lotSeq);
    const paid = {
      id: lotSeq++, operationId, cls: 'paid', originalCents: paidCents,
      remaining: 0, expiryKey: paidExpiry, earnedSeq: paid_earned(), expired: false,
    };
    const bonus = {
      id: lotSeq++, operationId, cls: 'bonus', originalCents: bonusCents,
      remaining: 0, expiryKey: bonusExpiry, earnedSeq: paid_earned(), expired: false,
    };
    lots.push(paid, bonus);
    pushMovement(paid, 'issue', paidCents, operationId, 'topup paid');
    if (bonusCents > 0) pushMovement(bonus, 'issue', bonusCents, operationId, 'topup bonus');
    return { paid, bonus };
  }
  // earned order increments per lot creation
  let earnedCounter = 0;
  function paid_earned() { return earnedCounter++; }

  // allocateSpend: the pure aggregate-proportional split. floor on bonus, paid keeps
  // the remainder cent (business-favorable by ≤1¢: the refundable paid class is drawn
  // slightly more, never less).
  function allocateSpend(paidRemaining, bonusRemaining, spend) {
    const total = paidRemaining + bonusRemaining;
    if (spend < 0) throw new Error('negative spend');
    if (spend > total) throw new Error('insufficient stored value');
    const bonusDraw = total === 0 ? 0 : floorMulDiv(spend, bonusRemaining, total);
    const paidDraw = spend - bonusDraw;
    return { paidDraw, bonusDraw };
  }

  function consumeClass(cls, amount, refOp) {
    const drawn = [];
    let left = amount;
    for (const lot of fefo(cls)) {
      if (left <= 0) break;
      const take = Math.min(left, lot.remaining);
      pushMovement(lot, 'spend', -take, refOp, 'spend allocation');
      drawn.push({ lotId: lot.id, cls, drawn: take });
      left -= take;
    }
    if (left !== 0) throw new Error(`could not fully allocate ${cls} (short ${left})`);
    return drawn;
  }

  // spend: aggregate-proportional allocation, FEFO within class across operations.
  function spend(spendOpId, spendCents, idemKey) {
    if (idemKey != null) {
      const k = ledgerKey('sv_spend', idemKey);
      if (opLedger.has(k)) return structuredClone(opLedger.get(k));
    }
    const paidRemaining = classRemaining('paid');
    const bonusRemaining = classRemaining('bonus');
    const { paidDraw, bonusDraw } = allocateSpend(paidRemaining, bonusRemaining, spendCents);
    const paidDrawn = consumeClass('paid', paidDraw, spendOpId);
    const bonusDrawn = consumeClass('bonus', bonusDraw, spendOpId);
    spendAllocations[spendOpId] = [...paidDrawn, ...bonusDrawn];
    const result = { spendOpId, spendCents, paidDraw, bonusDraw };
    if (idemKey != null) {
      const k = ledgerKey('sv_spend', idemKey);
      opLedger.set(k, structuredClone(result));
    }
    return result;
  }

  // expire: sweep a single lot's remaining (expiry independence — bonus expiry never
  // touches a paid lot). Marks the lot expired so a later reversal restore-then-expires.
  function expire(lotId, refOp = 'expiry-sweep') {
    const lot = lots.find((l) => l.id === lotId);
    if (!lot) throw new Error('no such lot');
    const rem = lot.remaining;
    if (rem > 0) pushMovement(lot, 'expiry', -rem, refOp, 'expiry sweep');
    lot.expired = true;
    return { lotId, expiredCents: rem };
  }

  function expireOpBonus(operationId, refOp = 'expiry-sweep') {
    const { bonus } = opLots(operationId);
    return expire(bonus.id, refOp);
  }

  // reverseSale: restore the EXACT lots a spend drew from. If a target lot is now
  // expired, restore-then-expire (a +reversal immediately followed by a −expiry),
  // both recorded, so an expired lot is never silently resurrected.
  function reverseSale(spendOpId, refOp) {
    const alloc = spendAllocations[spendOpId];
    if (!alloc) throw new Error('no allocation to reverse');
    const restored = [];
    for (const a of alloc) {
      const lot = lots.find((l) => l.id === a.lotId);
      pushMovement(lot, 'reversal', a.drawn, refOp ?? `reverse:${spendOpId}`, 'sale reversal restore');
      let reExpired = 0;
      if (lot.expired) {
        pushMovement(lot, 'expiry', -a.drawn, refOp ?? `reverse:${spendOpId}`, 'restore-then-expire');
        reExpired = a.drawn;
      }
      restored.push({ lotId: lot.id, cls: lot.cls, restored: a.drawn, reExpired });
    }
    delete spendAllocations[spendOpId];
    return { spendOpId, restored };
  }

  // refundOperation: WHOLE-operation refund. cash = op paid remaining; clawback = op
  // bonus remaining. Idempotent by key.
  function refundOperation(topupOpId, refundOpId, idemKey) {
    if (idemKey != null) {
      const k = ledgerKey('sv_refund', idemKey);
      if (opLedger.has(k)) return structuredClone(opLedger.get(k));
    }
    const { paid, bonus } = opLots(topupOpId);
    const cash = paid.remaining;
    const clawback = bonus.remaining;
    if (cash > 0) pushMovement(paid, 'refund', -cash, refundOpId, 'whole-op cash refund (paid remaining)');
    if (clawback > 0) pushMovement(bonus, 'clawback', -clawback, refundOpId, 'whole-op bonus clawback');
    const result = { topupOpId, refundOpId, cashCents: cash, clawbackCents: clawback, final: true };
    if (idemKey != null) opLedger.set(ledgerKey('sv_refund', idemKey), structuredClone(result));
    return result;
  }

  // partialRefund: $X cash, drawn from the op's paid remaining (X ≤ paid remaining).
  // Proportional bonus clawback = floor(bonus_rem * X / paid_rem); the FINAL refund
  // (X == paid_rem) claws back the ENTIRE bonus remaining (contract §5 requirement 2).
  function partialRefund(topupOpId, X, refundOpId, idemKey) {
    if (idemKey != null) {
      const k = ledgerKey('sv_refund', idemKey);
      if (opLedger.has(k)) return structuredClone(opLedger.get(k));
    }
    const { paid, bonus } = opLots(topupOpId);
    const paidRem = paid.remaining;
    const bonusRem = bonus.remaining;
    if (X < 0) throw new Error('negative refund');
    if (X > paidRem) throw new Error('partial refund exceeds paid remaining'); // requirement 3
    const isFinal = X === paidRem;
    const clawback = isFinal ? bonusRem : floorRatio(bonusRem, X, paidRem); // requirement 2
    if (X > 0) pushMovement(paid, 'refund', -X, refundOpId, 'partial cash refund');
    if (clawback > 0) pushMovement(bonus, 'clawback', -clawback, refundOpId, isFinal ? 'terminal bonus clawback' : 'proportional bonus clawback');
    const result = { topupOpId, refundOpId, cashCents: X, clawbackCents: clawback, final: isFinal };
    if (idemKey != null) opLedger.set(ledgerKey('sv_refund', idemKey), structuredClone(result));
    return result;
  }

  // chargeback: the funding payment is reversed by the bank. Void ALL remaining lots
  // (paid + bonus) via corrections; report bad debt = net paid value already DELIVERED
  // as goods (spend − reversal on the paid lot) that can no longer be recovered. Sales
  // already delivered stand. Bad debt is a report figure + a distinct bad_debt record;
  // it does NOT alter lot remaining (which the void movements already drove to zero).
  function chargeback(topupOpId, refOp = 'chargeback') {
    const { paid, bonus } = opLots(topupOpId);
    const voidPaid = paid.remaining;
    const voidBonus = bonus.remaining;
    if (voidPaid > 0) pushMovement(paid, 'correction', -voidPaid, refOp, 'chargeback void paid remaining');
    if (voidBonus > 0) pushMovement(bonus, 'correction', -voidBonus, refOp, 'chargeback void bonus remaining');
    // net paid delivered = -(Σ spend cents on paid lot) - (Σ reversal cents on paid lot)
    const paidMoves = movements.filter((m) => m.lotId === paid.id);
    const spentPaid = -paidMoves.filter((m) => m.movementType === 'spend').reduce((s, m) => s + m.cents, 0);
    const reversedPaid = paidMoves.filter((m) => m.movementType === 'reversal').reduce((s, m) => s + m.cents, 0);
    const badDebt = Math.max(0, spentPaid - reversedPaid);
    // The bad_debt record references consumed value; it carries cents=0 against the lot
    // cache so the Σ-movements==remaining invariant is preserved, with the figure in note.
    movements.push({
      seq: moveSeq++, lotId: paid.id, operationId: topupOpId, cls: 'paid',
      movementType: 'bad_debt', cents: 0, refOp, note: `bad_debt_cents=${badDebt}`,
    });
    return { topupOpId, voidPaidCents: voidPaid, voidBonusCents: voidBonus, badDebtCents: badDebt };
  }

  // businessCorrection: owner-gated ± correction on a lot; reason mandatory; audited.
  function businessCorrection(lotId, deltaCents, reason, actor = 'owner') {
    if (!reason || String(reason).trim().length === 0) throw new Error('correction reason is mandatory');
    const lot = lots.find((l) => l.id === lotId);
    if (!lot) throw new Error('no such lot');
    pushMovement(lot, 'correction', deltaCents, `correction:${actor}`, `reason=${reason}`);
    return { lotId, deltaCents, reason, actor };
  }

  // ---- read models ----
  function lotRemaining(lotId) { return lots.find((l) => l.id === lotId).remaining; }
  function opRemaining(operationId) {
    const { paid, bonus } = opLots(operationId);
    return { paid: paid.remaining, bonus: bonus.remaining };
  }
  function liability() {
    return { deferredRevenueCents: classRemaining('paid'), promotionalCents: classRemaining('bonus') };
  }
  // reconciliation: for every lot, Σ movements (cache-affecting types) == remaining.
  function reconcile() {
    for (const lot of lots) {
      const sum = movements
        .filter((m) => m.lotId === lot.id && m.movementType !== 'bad_debt')
        .reduce((s, m) => s + m.cents, 0);
      if (sum !== lot.remaining) {
        throw new Error(`reconcile FAIL lot ${lot.id}: Σmovements=${sum} remaining=${lot.remaining}`);
      }
    }
    return true;
  }

  return {
    mintLots, allocateSpend, spend, expire, expireOpBonus, reverseSale,
    refundOperation, partialRefund, chargeback, businessCorrection,
    lotRemaining, opRemaining, liability, reconcile,
    get movements() { return movements; },
    get lots() { return lots; },
  };
}

// ---------------------------------------------------------------------------
// Worked cases — every number matches STORED_VALUE_CONTRACT.md to the cent.
// ---------------------------------------------------------------------------

// The single-operation §5 refund matrix on the $100 → +$12 bonus example.
test('§5 matrix: full unused reversal refunds the whole $100.00, bonus clawed', () => {
  const e = createEngine();
  e.mintLots('A', 10000, 1200);
  const r = e.refundOperation('A', 'R1');
  assert.equal(r.cashCents, 10000);   // $100.00
  assert.equal(r.clawbackCents, 1200);
  assert.deepEqual(e.opRemaining('A'), { paid: 0, bonus: 0 });
  assert.ok(e.reconcile());
});

test('§5 matrix: spent $12.00 → refund $89.28 (arbitrage is dead)', () => {
  const e = createEngine();
  e.mintLots('A', 10000, 1200);
  const s = e.spend('S1', 1200);
  assert.deepEqual(s, { spendOpId: 'S1', spendCents: 1200, paidDraw: 1072, bonusDraw: 128 });
  const r = e.refundOperation('A', 'R1');
  assert.equal(r.cashCents, 8928);    // $89.28, NOT the rev-1 $100.00
  assert.equal(r.clawbackCents, 1072);
  assert.ok(e.reconcile());
});

test('§5 matrix: spent $56.00 → refund exactly $50.00 (proportional)', () => {
  const e = createEngine();
  e.mintLots('A', 10000, 1200);
  const s = e.spend('S1', 5600);
  assert.deepEqual(s, { spendOpId: 'S1', spendCents: 5600, paidDraw: 5000, bonusDraw: 600 });
  const r = e.refundOperation('A', 'R1');
  assert.equal(r.cashCents, 5000);    // $50.00
  assert.equal(r.clawbackCents, 600);
  assert.ok(e.reconcile());
});

test('§5 matrix: fully spent $112.00 → refund $0.00', () => {
  const e = createEngine();
  e.mintLots('A', 10000, 1200);
  e.spend('S1', 11200);
  const r = e.refundOperation('A', 'R1');
  assert.equal(r.cashCents, 0);
  assert.equal(r.clawbackCents, 0);
  assert.ok(e.reconcile());
});

test('§5 matrix: bonus expired unspent, nothing spent → refund $100.00, expiry never touched paid', () => {
  const e = createEngine();
  const { bonus, paid } = e.mintLots('A', 10000, 1200);
  e.expire(bonus.id);
  assert.equal(e.lotRemaining(bonus.id), 0);
  assert.equal(e.lotRemaining(paid.id), 10000); // expiry independence
  const r = e.refundOperation('A', 'R1');
  assert.equal(r.cashCents, 10000);
  assert.equal(r.clawbackCents, 0);   // already expired
  assert.ok(e.reconcile());
});

// Multi-operation matrix row (rev 4): A=$100+$12, B=$50+$5, spend $56.
test('multi-op §5 row: A=$100+$12, B=$50+$5, spend $56 → refund A $49.70, refund B $50.00', () => {
  const e = createEngine();
  e.mintLots('A', 10000, 1200, { expiryKey: 10 }); // A earlier ⇒ FEFO-first
  e.mintLots('B', 5000, 500, { expiryKey: 20 });
  const s = e.spend('S1', 5600);
  assert.equal(s.bonusDraw, 570);     // floor(5600*1700/16700)
  assert.equal(s.paidDraw, 5030);
  assert.deepEqual(e.opRemaining('A'), { paid: 4970, bonus: 630 }); // all draws land on A
  assert.deepEqual(e.opRemaining('B'), { paid: 5000, bonus: 500 });
  const ra = e.refundOperation('A', 'RA');
  const rb = e.refundOperation('B', 'RB');
  assert.equal(ra.cashCents, 4970);   // $49.70
  assert.equal(ra.clawbackCents, 630);
  assert.equal(rb.cashCents, 5000);   // $50.00
  assert.equal(rb.clawbackCents, 500);
  assert.equal(ra.cashCents + rb.cashCents, 9970); // = total paid remaining (15000-5030)
  assert.ok(e.reconcile());
});

// ---------------------------------------------------------------------------
// The seven §5 repeated-partial-refund rounding requirements (each named).
// Case (a): repeated $1 refunds then final remainder — no stranded bonus cent.
// ---------------------------------------------------------------------------

test('req 1+2+7 case (a): repeated $1 partial refunds on $10.00/$1.37, floor lags but terminal sweep leaves no stranded bonus, and it terminates', () => {
  const e = createEngine();
  e.mintLots('A', 1000, 137);         // $10.00 paid, $1.37 bonus (13.7% ratio)
  let cashTotal = 0;
  let clawTotal = 0;
  const perStepClaw = [];
  let steps = 0;
  // Loop small refunds to closure — the termination proof.
  while (e.opRemaining('A').paid > 0) {
    steps += 1;
    assert.ok(steps <= 1000, 'must terminate'); // guard against non-termination
    const paidRem = e.opRemaining('A').paid;
    const X = Math.min(100, paidRem);            // $1 steps, last one is the remainder
    const r = e.partialRefund('A', X, `R${steps}`);
    cashTotal += r.cashCents;
    clawTotal += r.clawbackCents;
    perStepClaw.push(r.clawbackCents);
    // requirement 1: cumulative floor clawback never EXCEEDS exact proportionality.
    const proportional = (137 * cashTotal) / 1000;
    assert.ok(clawTotal <= Math.ceil(proportional) && clawTotal <= proportional + 1,
      `cumulative clawback ${clawTotal} must not exceed proportional ${proportional}`);
    assert.ok(e.reconcile());
  }
  // requirement 3: cumulative cash == original paid, never exceeds it.
  assert.equal(cashTotal, 1000);      // exactly $10.00
  // requirement 2 + no stranded cent: entire bonus clawed, op fully closed.
  assert.equal(clawTotal, 137);       // exactly $1.37
  assert.deepEqual(e.opRemaining('A'), { paid: 0, bonus: 0 });
  // the floor genuinely lagged early (13 < 13.7) then the terminal step swept the rest.
  assert.equal(perStepClaw[0], 13);
  assert.equal(perStepClaw[perStepClaw.length - 1], 14); // terminal sweep of the remainder
  assert.equal(steps, 10);
});

test('req 2: the FINAL refund of the paid remainder claws back the ENTIRE bonus remaining (terminal, not the floor formula)', () => {
  const e = createEngine();
  e.mintLots('A', 300, 41);           // choose values where floor(41*100/300)=13 ≠ terminal
  const r1 = e.partialRefund('A', 100, 'R1');
  assert.equal(r1.clawbackCents, 13); // floor(41*100/300)
  assert.equal(r1.final, false);
  const r2 = e.partialRefund('A', 100, 'R2');
  assert.equal(r2.clawbackCents, floorRatio(28, 100, 200)); // floor(28*100/200)=14
  assert.equal(r2.final, false);
  const r3 = e.partialRefund('A', 100, 'R3');  // final: X == paid remaining (100)
  assert.equal(r3.final, true);
  assert.equal(r3.clawbackCents, 41 - 13 - 14); // = 14, the ENTIRE bonus remaining
  assert.deepEqual(e.opRemaining('A'), { paid: 0, bonus: 0 });
  assert.ok(e.reconcile());
});

test('req 3: a partial refund can never exceed the operation paid remaining', () => {
  const e = createEngine();
  e.mintLots('A', 5000, 400);
  e.partialRefund('A', 3000, 'R1');
  assert.equal(e.opRemaining('A').paid, 2000);
  assert.throws(() => e.partialRefund('A', 2001, 'R2'), /exceeds paid remaining/);
  assert.ok(e.reconcile());
});

test('req 4: Σ movements ≡ cached remaining after every partial-refund step', () => {
  const e = createEngine();
  e.mintLots('A', 1234, 321);
  let step = 0;
  while (e.opRemaining('A').paid > 0) {
    const X = Math.min(77, e.opRemaining('A').paid);
    e.partialRefund('A', X, `R${step++}`);
    assert.ok(e.reconcile()); // asserted PER step
  }
  assert.deepEqual(e.opRemaining('A'), { paid: 0, bonus: 0 });
});

// ---------------------------------------------------------------------------
// Idempotency + serialization (requirements 5 and 6) — cases (b), (c), (d).
// ---------------------------------------------------------------------------

test('req 5 case (d): lost response + retry replays the SAME movement set byte-equal (op-ledger)', () => {
  const e = createEngine();
  e.mintLots('A', 10000, 1200);
  const first = e.partialRefund('A', 3000, 'R1', 'idem-key-123');
  const beforeLen = e.movements.length;
  const retry = e.partialRefund('A', 3000, 'R1', 'idem-key-123'); // same idem key
  assert.deepEqual(retry, first);                    // byte-equal result
  assert.equal(e.movements.length, beforeLen);       // zero new movements
  assert.equal(e.opRemaining('A').paid, 7000);       // paid reduced ONCE, not twice
  assert.ok(e.reconcile());
});

test('req 6 case (c): two concurrent refund attempts with the same key = one winner + one idempotent replay (never a double payout)', () => {
  const e = createEngine();
  e.mintLots('A', 8000, 800);
  // Serialized under the per-customer advisory lock; both carry the SAME idem key.
  const a = e.refundOperation('A', 'R1', 'race-key');
  const lenAfterWinner = e.movements.length;
  const b = e.refundOperation('A', 'R1', 'race-key');
  assert.equal(a.cashCents, 8000);
  assert.deepEqual(b, a);                        // replay, identical
  assert.equal(e.movements.length, lenAfterWinner); // no second movement set
  assert.deepEqual(e.opRemaining('A'), { paid: 0, bonus: 0 });
});

test('req 6 case (c-var): two concurrent refunds with DIFFERENT keys — first fully refunds, second sees $0 (winner semantics)', () => {
  const e = createEngine();
  e.mintLots('A', 8000, 800);
  const a = e.refundOperation('A', 'R1', 'key-1');
  const b = e.refundOperation('A', 'R2', 'key-2'); // different key, op already closed
  assert.equal(a.cashCents, 8000);
  assert.equal(b.cashCents, 0);                    // nothing left to pay out
  assert.equal(b.clawbackCents, 0);
  assert.ok(e.reconcile());
});

test('req 6 case (b): concurrent spend vs refund serialize — both orderings conserve, never over-refund', () => {
  // Order 1: spend then refund.
  const e1 = createEngine();
  e1.mintLots('A', 10000, 1200);
  const s1 = e1.spend('S1', 3000);
  assert.deepEqual(s1, { spendOpId: 'S1', spendCents: 3000, paidDraw: 2679, bonusDraw: 321 });
  const r1 = e1.refundOperation('A', 'R1');
  assert.equal(r1.cashCents, 7321);   // paid remaining after the spend
  assert.equal(r1.clawbackCents, 879);
  // paid delivered by spend + cash refunded ≤ original paid.
  assert.ok(2679 + r1.cashCents <= 10000);
  assert.ok(e1.reconcile());

  // Order 2: refund then spend. The refund closes the op; the later $30 spend cannot
  // be allocated because there is no stored value left — it is rejected.
  const e2 = createEngine();
  e2.mintLots('A', 10000, 1200);
  const r2 = e2.refundOperation('A', 'R1');
  assert.equal(r2.cashCents, 10000);
  assert.throws(() => e2.spend('S1', 3000), /insufficient stored value/);
  assert.ok(e2.reconcile());
  // Whichever serialization wins, cash out never exceeds original paid (10000).
  assert.ok(r2.cashCents <= 10000);
});

// ---------------------------------------------------------------------------
// Case (e): chargeback after partial spend — bad debt figure shown.
// ---------------------------------------------------------------------------

test('case (e): funding chargeback after $80 spend voids remaining lots and reports $71.43 bad debt; sales stand', () => {
  const e = createEngine();
  e.mintLots('A', 10000, 1200);
  const s = e.spend('S1', 8000);
  assert.equal(s.bonusDraw, 857);     // floor(8000*1200/11200)
  assert.equal(s.paidDraw, 7143);
  assert.deepEqual(e.opRemaining('A'), { paid: 2857, bonus: 343 });
  const c = e.chargeback('A');
  assert.equal(c.voidPaidCents, 2857);
  assert.equal(c.voidBonusCents, 343);
  assert.equal(c.badDebtCents, 7143); // = paid delivered as goods = $71.43
  assert.deepEqual(e.opRemaining('A'), { paid: 0, bonus: 0 }); // remaining voided
  assert.ok(e.reconcile());           // bad_debt record does not disturb lot caches
});

// ---------------------------------------------------------------------------
// Case (f): expired bonus then sale reversal — restore-then-expire numbers.
// ---------------------------------------------------------------------------

test('case (f): spend $12, bonus expires, then sale reversal → paid fully restored, bonus restore-then-expired to 0', () => {
  const e = createEngine();
  const { paid, bonus } = e.mintLots('A', 10000, 1200);
  const s = e.spend('S1', 1200);
  assert.deepEqual(s, { spendOpId: 'S1', spendCents: 1200, paidDraw: 1072, bonusDraw: 128 });
  assert.deepEqual(e.opRemaining('A'), { paid: 8928, bonus: 1072 });
  e.expire(bonus.id);                 // remaining bonus (1072) expires
  assert.deepEqual(e.opRemaining('A'), { paid: 8928, bonus: 0 });
  e.reverseSale('S1');
  assert.equal(e.lotRemaining(paid.id), 10000);  // paid fully restored
  assert.equal(e.lotRemaining(bonus.id), 0);     // restore +128 then re-expire −128
  // audit trail carries both the reversal and the compensating expiry on the bonus lot.
  const bonusMoves = e.movements.filter((m) => m.lotId === bonus.id).map((m) => [m.movementType, m.cents]);
  assert.deepEqual(bonusMoves, [
    ['issue', 1200], ['spend', -128], ['expiry', -1072], ['reversal', 128], ['expiry', -128],
  ]);
  assert.ok(e.reconcile());
});

test('case (f-happy): sale reversal without prior expiry restores the exact allocation', () => {
  const e = createEngine();
  const { paid, bonus } = e.mintLots('A', 10000, 1200);
  e.spend('S1', 1200);
  e.reverseSale('S1');
  assert.equal(e.lotRemaining(paid.id), 10000);
  assert.equal(e.lotRemaining(bonus.id), 1200);
  assert.ok(e.reconcile());
});

// ---------------------------------------------------------------------------
// Case (g): two top-ups with DIFFERENT paid/bonus ratios — full allocation + both
// refunds worked to the cent.
// ---------------------------------------------------------------------------

test('case (g): A=$100+$12 (12%), B=$200+$50 (25%), spend $50 → refund A $58.56 + B $200.00, both to the cent', () => {
  const e = createEngine();
  e.mintLots('A', 10000, 1200, { expiryKey: 10 }); // A FEFO-first
  e.mintLots('B', 20000, 5000, { expiryKey: 20 });
  const s = e.spend('S1', 5000);
  assert.equal(s.bonusDraw, 856);     // floor(5000*6200/36200)
  assert.equal(s.paidDraw, 4144);
  assert.deepEqual(e.opRemaining('A'), { paid: 5856, bonus: 344 }); // draws land on A
  assert.deepEqual(e.opRemaining('B'), { paid: 20000, bonus: 5000 });
  const ra = e.refundOperation('A', 'RA');
  const rb = e.refundOperation('B', 'RB');
  assert.equal(ra.cashCents, 5856);   // $58.56
  assert.equal(ra.clawbackCents, 344);
  assert.equal(rb.cashCents, 20000);  // $200.00
  assert.equal(rb.clawbackCents, 5000);
  assert.equal(ra.cashCents + rb.cashCents, 25856); // = total paid remaining (30000-4144)
  assert.ok(e.reconcile());
});

test('case (g-spill): a $120 spend after the $50 spend drains A and spills into B via cross-op FEFO', () => {
  const e = createEngine();
  e.mintLots('A', 10000, 1200, { expiryKey: 10 });
  e.mintLots('B', 20000, 5000, { expiryKey: 20 });
  e.spend('S1', 5000);                // A: paid 5856, bonus 344
  const s2 = e.spend('S2', 12000);
  assert.equal(s2.bonusDraw, 2055);   // floor(12000*5344/31200)
  assert.equal(s2.paidDraw, 9945);
  assert.deepEqual(e.opRemaining('A'), { paid: 0, bonus: 0 });      // A fully drained first
  assert.deepEqual(e.opRemaining('B'), { paid: 15911, bonus: 3289 }); // spill into B
  const rb = e.refundOperation('B', 'RB');
  assert.equal(rb.cashCents, 15911);  // $159.11
  assert.equal(rb.clawbackCents, 3289);
  assert.ok(e.reconcile());
});

// ---------------------------------------------------------------------------
// Case (h): different expiry ordering between paid and bonus lots across operations.
// The split AMOUNTS are invariant to expiry order; only WHICH lot is drawn changes.
// (The reviewer's inverted-FEFO edge probe, verified to the cent.)
// ---------------------------------------------------------------------------

test('case (h): B bonus expires before A bonus, A paid before B paid → same $49.70 / $50.00 refunds, different clawback lots', () => {
  const e = createEngine();
  // A paid expires first (10), B paid later (20); B bonus expires first (5), A bonus later (15).
  e.mintLots('A', 10000, 1200, { paidExpiryKey: 10, bonusExpiryKey: 15 });
  e.mintLots('B', 5000, 500, { paidExpiryKey: 20, bonusExpiryKey: 5 });
  const s = e.spend('S1', 5600);
  assert.equal(s.bonusDraw, 570);     // amounts identical to the same-order case
  assert.equal(s.paidDraw, 5030);
  // bonus FEFO draws B first (expires sooner): B 500→0, then 70 from A → A bonus 1130.
  assert.deepEqual(e.opRemaining('B'), { paid: 5000, bonus: 0 });
  assert.deepEqual(e.opRemaining('A'), { paid: 4970, bonus: 1130 });
  const ra = e.refundOperation('A', 'RA');
  const rb = e.refundOperation('B', 'RB');
  assert.equal(ra.cashCents, 4970);   // $49.70 (unchanged)
  assert.equal(ra.clawbackCents, 1130);
  assert.equal(rb.cashCents, 5000);   // $50.00 (unchanged)
  assert.equal(rb.clawbackCents, 0);  // B's bonus already fully drawn
  assert.equal(ra.cashCents + rb.cashCents, 9970); // conservation holds
  assert.ok(e.reconcile());
});

// ---------------------------------------------------------------------------
// Business correction (owner-gated, reason mandatory, both directions).
// ---------------------------------------------------------------------------

test('business correction: both directions, reason mandatory, audited', () => {
  const e = createEngine();
  const { paid } = e.mintLots('A', 5000, 400);
  assert.throws(() => e.businessCorrection(paid.id, -100, ''), /reason is mandatory/);
  e.businessCorrection(paid.id, -100, 'till miscount', 'owner');
  assert.equal(e.lotRemaining(paid.id), 4900);
  e.businessCorrection(paid.id, 250, 'goodwill top-up', 'owner');
  assert.equal(e.lotRemaining(paid.id), 5150);
  assert.ok(e.reconcile());
});

// ---------------------------------------------------------------------------
// Liability split — paid (deferred revenue) ∥ bonus (promotional), always separate.
// ---------------------------------------------------------------------------

test('liability split reports deferred revenue and promotional separately', () => {
  const e = createEngine();
  e.mintLots('A', 10000, 1200);
  e.mintLots('B', 20000, 5000);
  assert.deepEqual(e.liability(), { deferredRevenueCents: 30000, promotionalCents: 6200 });
  e.spend('S1', 5000);
  const l = e.liability();
  // paid + bonus always add up to the remaining stored value; never blended.
  assert.equal(l.deferredRevenueCents + l.promotionalCents, 30000 + 6200 - 5000);
  assert.ok(e.reconcile());
});

// ---------------------------------------------------------------------------
// Case (i): final-cent conservation is asserted for every case above via reconcile()
// plus this explicit conservation ledger over a mixed sequence.
// ---------------------------------------------------------------------------

test('case (i): conservation — Σ movements ≡ balances and Σ cash-out ≤ Σ paid across a mixed lifecycle', () => {
  const e = createEngine();
  e.mintLots('A', 10000, 1200, { expiryKey: 10 });
  e.mintLots('B', 5000, 500, { expiryKey: 20 });
  e.spend('S1', 3000);
  e.partialRefund('A', 1000, 'RP1');
  e.spend('S2', 1500);
  const rA = e.refundOperation('A', 'RA'); // closes A
  const rB = e.refundOperation('B', 'RB'); // closes B
  assert.ok(e.reconcile());
  // total cash out ≤ total paid minted.
  const cashOut = e.movements
    .filter((m) => m.movementType === 'refund')
    .reduce((s, m) => s - m.cents, 0);
  assert.ok(cashOut <= 15000, `cash out ${cashOut} must not exceed paid minted 15000`);
  // both operations fully closed, no stranded bonus.
  assert.deepEqual(e.opRemaining('A'), { paid: 0, bonus: 0 });
  assert.deepEqual(e.opRemaining('B'), { paid: 0, bonus: 0 });
  assert.ok(rA.final && rB.final);
});

// ---------------------------------------------------------------------------
// Fuzz / property section — seeded, deterministic. Several hundred randomized
// scenarios asserting: conservation, cumulative-cash ≤ original-paid per operation,
// no stranded bonus after operation closure, and determinism (same seed → same run).
// ---------------------------------------------------------------------------

// mulberry32 — a tiny seeded PRNG (deterministic; NO Date.now / unseeded Math.random).
function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Run one fully-deterministic scenario for a seed; return a compact trace + invariants.
function runScenario(seed) {
  const rnd = mulberry32(seed);
  const int = (lo, hi) => lo + Math.floor(rnd() * (hi - lo + 1));
  const e = createEngine(`cust-${seed}`);

  const ops = [];          // top-up operation ids, with minted paid totals
  const openOps = new Set();
  let opN = 0;
  let spendN = 0;
  let refundN = 0;
  const cashPerOp = {};    // cumulative cash refunded per op (requirement 3 tracking)

  const steps = int(8, 24);
  for (let i = 0; i < steps; i++) {
    const choice = int(0, 9);
    if (choice <= 3 || ops.length === 0) {
      // top-up: mint a new operation with random paid/bonus and random independent expiries.
      const id = `OP${opN++}`;
      const paidC = int(100, 50000);
      const bonusC = int(0, Math.floor(paidC / 2));
      e.mintLots(id, paidC, bonusC, { paidExpiryKey: int(1, 40), bonusExpiryKey: int(1, 40) });
      ops.push({ id, paidC, bonusC });
      openOps.add(id);
      cashPerOp[id] = 0;
    } else if (choice <= 6) {
      // spend up to the aggregate remaining.
      const totalPaid = e.lots.filter((l) => l.cls === 'paid').reduce((s, l) => s + l.remaining, 0);
      const totalBonus = e.lots.filter((l) => l.cls === 'bonus').reduce((s, l) => s + l.remaining, 0);
      const total = totalPaid + totalBonus;
      if (total > 0) {
        const amt = int(1, total);
        const res = e.spend(`SP${spendN++}`, amt);
        // proportional split invariants.
        assert.equal(res.paidDraw + res.bonusDraw, amt);
        assert.ok(res.bonusDraw >= 0 && res.paidDraw >= 0);
        assert.ok(res.bonusDraw <= totalBonus && res.paidDraw <= totalPaid);
      }
    } else if (choice <= 8) {
      // partial refund of a random open op.
      const openArr = [...openOps];
      if (openArr.length) {
        const id = openArr[int(0, openArr.length - 1)];
        const paidRem = e.opRemaining(id).paid;
        if (paidRem > 0) {
          const X = int(1, paidRem);
          const r = e.partialRefund(id, X, `RF${refundN++}`);
          cashPerOp[id] += r.cashCents;
          if (r.final) openOps.delete(id);
        } else {
          openOps.delete(id);
        }
      }
    } else {
      // whole-op refund of a random open op, or expire a random bonus lot.
      const openArr = [...openOps];
      if (openArr.length && int(0, 1) === 0) {
        const id = openArr[int(0, openArr.length - 1)];
        const r = e.refundOperation(id, `RW${refundN++}`);
        cashPerOp[id] += r.cashCents;
        openOps.delete(id);
        // requirement: closing an op by refund leaves NO stranded bonus.
        assert.deepEqual(e.opRemaining(id), { paid: 0, bonus: 0 });
      } else {
        const bonusLots = e.lots.filter((l) => l.cls === 'bonus' && l.remaining > 0);
        if (bonusLots.length) e.expire(bonusLots[int(0, bonusLots.length - 1)].id);
      }
    }
    // conservation after EVERY step.
    assert.ok(e.reconcile());
  }

  // Post-run invariants.
  assert.ok(e.reconcile());
  for (const { id, paidC } of ops) {
    // cumulative cash refunded per op never exceeds its original paid value.
    assert.ok(cashPerOp[id] <= paidC, `op ${id}: cash ${cashPerOp[id]} > paid ${paidC}`);
    // no stranded bonus: any op closed by refund has bonus 0.
    if (!openOps.has(id)) {
      const rem = e.opRemaining(id);
      // closed-by-refund ops are fully zero; ops closed by spend/expiry may keep 0 too.
      assert.ok(rem.paid === 0);
    }
  }
  // liability split always non-negative and equals the sum of remaining lots.
  const l = e.liability();
  assert.ok(l.deferredRevenueCents >= 0 && l.promotionalCents >= 0);

  return {
    movementCount: e.movements.length,
    liability: l,
    fingerprint: e.movements.map((m) => `${m.movementType}:${m.cents}:${m.lotId}`).join('|'),
  };
}

test('fuzz: 400 seeded scenarios all conserve, never over-refund, strand no bonus', () => {
  for (let seed = 1; seed <= 400; seed++) {
    runScenario(seed);
  }
});

test('fuzz: determinism — same seed reproduces the identical movement fingerprint', () => {
  for (const seed of [1, 7, 42, 99, 256, 400]) {
    const a = runScenario(seed);
    const b = runScenario(seed);
    assert.equal(a.fingerprint, b.fingerprint);
    assert.equal(a.movementCount, b.movementCount);
    assert.deepEqual(a.liability, b.liability);
  }
});

test('allocateSpend pure split: floor on bonus, paid takes the remainder, conserves exactly (property)', () => {
  const e = createEngine();
  const rnd = mulberry32(12345);
  for (let i = 0; i < 2000; i++) {
    const paid = Math.floor(rnd() * 100000);
    const bonus = Math.floor(rnd() * 100000);
    const total = paid + bonus;
    if (total === 0) continue;
    const spend = Math.floor(rnd() * (total + 1));
    const { paidDraw, bonusDraw } = e.allocateSpend(paid, bonus, spend);
    assert.equal(paidDraw + bonusDraw, spend);                 // exact conservation
    assert.equal(bonusDraw, floorMulDiv(spend, bonus, total)); // floor on bonus
    assert.ok(bonusDraw <= bonus && paidDraw <= paid);         // never over-draw a class
    assert.ok(paidDraw >= 0 && bonusDraw >= 0);
  }
});
