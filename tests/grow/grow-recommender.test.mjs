// Independent contract tests for the Frenly Grow Program Recommender.
//
// Written FROM THE PINNED FORMULA CONTRACT, not from app/grow-recommender.js.
// This file is the independent check that the implementation matches the
// contract handed to the implementer — do not "fix" a test to match whatever
// the implementation happens to do; if the implementation disagrees with a
// case below, that is a contract violation to report, not a test bug.
//
// Guarded to SKIP CLEANLY when app/grow-recommender.js does not exist yet
// (the implementer may still be working). Re-run this file once the
// implementation lands to get real pass/fail results.

import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const require = createRequire(import.meta.url);
const IMPL_URL = new URL('../../app/grow-recommender.js', import.meta.url);
const IMPL_PATH = fileURLToPath(IMPL_URL);
const IMPL_EXISTS = existsSync(IMPL_PATH);

if (!IMPL_EXISTS) {
  test(
    'Grow Recommender contract (app/grow-recommender.js)',
    { skip: 'app/grow-recommender.js does not exist yet — implementation pending. Re-run this file once it lands.' },
    () => {}
  );
} else {
  const GrowRec = require(IMPL_PATH);

  // ---------------------------------------------------------------------
  // Shared helpers
  // ---------------------------------------------------------------------

  /** Calls fn(...args) and fails the test (with a clear message) if it throws. */
  function callNullSafe(fn, label, ...args) {
    let result;
    assert.doesNotThrow(() => {
      result = fn(...args);
    }, `${label} must be null-safe and never throw on invalid input`);
    return result;
  }

  /**
   * Accepts either whole-result null OR an object whose numeric fields are
   * all null as evidence of "null-shaped" handling of invalid input. The
   * contract's blanket null-safety clause does not pin down which shape
   * every function uses (see report: flagged ambiguity), so this helper
   * is deliberately permissive on shape while still rejecting leaked
   * numbers (NaN, Infinity, or a fabricated positive number).
   */
  function assertNullShaped(result, numericKeys) {
    if (result === null || result === undefined) return;
    assert.ok(
      typeof result === 'object',
      `expected null or an object for invalid input, got ${typeof result}`
    );
    for (const key of numericKeys) {
      const value = result[key];
      assert.ok(
        value === null || value === undefined,
        `expected ${key} to be null-shaped for invalid input, got ${JSON.stringify(value)}`
      );
    }
  }

  function roundToNearest(x, n) {
    return Math.round(x / n) * n;
  }

  // ---------------------------------------------------------------------
  // 1. givebackPct
  // ---------------------------------------------------------------------

  test('givebackPct: the three pinned contract examples, exactly', () => {
    assert.equal(
      GrowRec.givebackPct({ earnPointsPerDollar: 1, redeemPoints: 150, rewardCreditCents: 300 }),
      2
    );
    assert.equal(
      GrowRec.givebackPct({ earnPointsPerDollar: 100, redeemPoints: 150, rewardCreditCents: 300 }),
      200
    );
    assert.equal(
      GrowRec.givebackPct({ earnPointsPerDollar: 10, redeemPoints: 600, rewardCreditCents: 300 }),
      5
    );
  });

  test('givebackPct: kopi tiam incident regression — (100, 150, 300) must stay pinned at 200% giveback', () => {
    // This is the exact misconfiguration that motivated the recommender:
    // earn 100 pts/$, redeem for $3.00 credit at only 150 points ->
    // the business gives back $2 of credit for every $1 spent (200%).
    // If this regresses to anything other than exactly 200, the runaway
    // liability the recommender exists to prevent is back.
    const pct = GrowRec.givebackPct({
      earnPointsPerDollar: 100,
      redeemPoints: 150,
      rewardCreditCents: 300
    });
    assert.equal(pct, 200, 'kopi tiam incident case must compute to exactly 200% giveback');
  });

  test('givebackPct: 2-decimal rounding (earn 1, redeem 300, credit 100 -> 0.33)', () => {
    const pct = GrowRec.givebackPct({ earnPointsPerDollar: 1, redeemPoints: 300, rewardCreditCents: 100 });
    assert.equal(pct, 0.33);
  });

  test('givebackPct: null-safety on redeemPoints <= 0', () => {
    assert.equal(
      callNullSafe(GrowRec.givebackPct, 'givebackPct',
        { earnPointsPerDollar: 1, redeemPoints: 0, rewardCreditCents: 300 }),
      null
    );
    assert.equal(
      callNullSafe(GrowRec.givebackPct, 'givebackPct',
        { earnPointsPerDollar: 1, redeemPoints: -150, rewardCreditCents: 300 }),
      null
    );
  });

  test('givebackPct: null-safety on non-finite / negative / missing inputs', () => {
    const cases = [
      { earnPointsPerDollar: NaN, redeemPoints: 150, rewardCreditCents: 300 },
      { earnPointsPerDollar: 1, redeemPoints: NaN, rewardCreditCents: 300 },
      { earnPointsPerDollar: 1, redeemPoints: 150, rewardCreditCents: NaN },
      { earnPointsPerDollar: Infinity, redeemPoints: 150, rewardCreditCents: 300 },
      { earnPointsPerDollar: -1, redeemPoints: 150, rewardCreditCents: 300 },
      { earnPointsPerDollar: 1, redeemPoints: 150, rewardCreditCents: -300 },
      { earnPointsPerDollar: 1, redeemPoints: 150 }, // missing rewardCreditCents
      {} // everything missing
    ];
    for (const input of cases) {
      const result = callNullSafe(GrowRec.givebackPct, 'givebackPct', input);
      assert.equal(result, null, `expected null for ${JSON.stringify(input)}`);
    }
  });

  test('givebackPct: null-safety when called with null/undefined argument', () => {
    assert.equal(callNullSafe(GrowRec.givebackPct, 'givebackPct', null), null);
    assert.equal(callNullSafe(GrowRec.givebackPct, 'givebackPct', undefined), null);
  });

  // ---------------------------------------------------------------------
  // 2. recommendPoints
  // ---------------------------------------------------------------------

  test('recommendPoints: avgTicket 600 / target 5 -> credit 300, redeem 600, actual 5, cost 30 / 3000', () => {
    const r = GrowRec.recommendPoints({ avgTicketCents: 600, targetGivebackPct: 5 });
    assert.equal(r.earnPointsPerDollar, 10);
    assert.equal(r.rewardCreditCents, 300);
    assert.equal(r.redeemPoints, 600);
    assert.equal(r.actualGivebackPct, 5);
    assert.equal(r.costPerVisitCents, 30);
    assert.equal(r.costPer100VisitsCents, 3000);
    assert.ok(Array.isArray(r.reasoning) && r.reasoning.length > 0);
  });

  test('recommendPoints: avgTicket 250 / target 5 -> credit floors to 200, redeem 400, actual 5, cost 13', () => {
    const r = GrowRec.recommendPoints({ avgTicketCents: 250, targetGivebackPct: 5 });
    // roundToNearest(125, 100) = 100, which is below the 200-cent floor.
    assert.equal(r.rewardCreditCents, 200, 'reward credit must clamp up to the 200-cent floor');
    assert.equal(r.redeemPoints, 400);
    assert.equal(r.actualGivebackPct, 5);
    // Math.round(250 * 5 / 100) = Math.round(12.5) = 13 in JS (half rounds up).
    assert.equal(r.costPerVisitCents, 13);
    assert.equal(r.costPer100VisitsCents, 1300);
  });

  test('recommendPoints: avgTicket 8000 / target 2 -> credit ceilings to 2000, redeem 10000, actual 2', () => {
    const r = GrowRec.recommendPoints({ avgTicketCents: 8000, targetGivebackPct: 2 });
    // roundToNearest(4000, 100) = 4000, which is above the 2000-cent ceiling.
    assert.equal(r.rewardCreditCents, 2000, 'reward credit must clamp down to the 2000-cent ceiling');
    assert.equal(r.redeemPoints, 10000);
    assert.equal(r.actualGivebackPct, 2);
    assert.equal(r.costPerVisitCents, 160);
    assert.equal(r.costPer100VisitsCents, 16000);
  });

  test('recommendPoints: actualGivebackPct is RECOMPUTED after rounding, not a passthrough of the target', () => {
    // avgTicket 333 / target 7 is deliberately chosen so post-rounding
    // redeemPoints (300) does not land the actual giveback back on 7 —
    // it lands on 6.67. An implementation that just echoes the input
    // target instead of recomputing via formula 1 will fail this.
    const r = GrowRec.recommendPoints({ avgTicketCents: 333, targetGivebackPct: 7 });
    assert.equal(r.rewardCreditCents, 200);
    assert.equal(r.redeemPoints, 300);
    assert.equal(r.actualGivebackPct, 6.67);
    assert.notEqual(r.actualGivebackPct, 7, 'actualGivebackPct must not simply echo targetGivebackPct');
    assert.equal(r.costPerVisitCents, 22);
    assert.equal(r.costPer100VisitsCents, 2200);
  });

  test('recommendPoints: determinism — identical calls deep-equal', () => {
    const a = GrowRec.recommendPoints({ avgTicketCents: 733, targetGivebackPct: 4.5 });
    const b = GrowRec.recommendPoints({ avgTicketCents: 733, targetGivebackPct: 4.5 });
    assert.deepEqual(a, b);
  });

  test('recommendPoints: internal self-consistency invariants hold across a spread of inputs (incl. target extremes 0.5 and 20)', () => {
    const cases = [
      { avgTicketCents: 1000, targetGivebackPct: 0.5 },
      { avgTicketCents: 1000, targetGivebackPct: 20 },
      { avgTicketCents: 150, targetGivebackPct: 0.5 },
      { avgTicketCents: 150, targetGivebackPct: 20 },
      { avgTicketCents: 12000, targetGivebackPct: 0.5 },
      { avgTicketCents: 12000, targetGivebackPct: 20 },
      { avgTicketCents: 777, targetGivebackPct: 3.3 }
    ];
    for (const input of cases) {
      const r = GrowRec.recommendPoints(input);
      assert.equal(r.earnPointsPerDollar, 10, `earnPointsPerDollar must always be 10 for ${JSON.stringify(input)}`);
      assert.ok(
        r.rewardCreditCents >= 200 && r.rewardCreditCents <= 2000 && r.rewardCreditCents % 100 === 0,
        `rewardCreditCents ${r.rewardCreditCents} must be a clamp(...,200,2000) multiple of 100 for ${JSON.stringify(input)}`
      );
      assert.ok(
        r.redeemPoints >= 50 && r.redeemPoints % 50 === 0,
        `redeemPoints ${r.redeemPoints} must be >=50 and a multiple of 50 for ${JSON.stringify(input)}`
      );
      // actualGivebackPct must equal formula 1 recomputed from the rounded outputs.
      const recomputed = GrowRec.givebackPct({
        earnPointsPerDollar: 10,
        redeemPoints: r.redeemPoints,
        rewardCreditCents: r.rewardCreditCents
      });
      assert.equal(
        r.actualGivebackPct, recomputed,
        `actualGivebackPct must equal givebackPct(recomputed) for ${JSON.stringify(input)}`
      );
      assert.equal(
        r.costPerVisitCents, Math.round(input.avgTicketCents * r.actualGivebackPct / 100),
        `costPerVisitCents must equal round(avgTicket * actualGivebackPct / 100) for ${JSON.stringify(input)}`
      );
      assert.equal(r.costPer100VisitsCents, r.costPerVisitCents * 100);
      assert.ok(Array.isArray(r.reasoning) && r.reasoning.length > 0);
    }
  });

  test('recommendPoints: invalid inputs are null-safe', () => {
    const numericKeys = ['rewardCreditCents', 'redeemPoints', 'actualGivebackPct', 'costPerVisitCents', 'costPer100VisitsCents'];
    const cases = [
      { avgTicketCents: -600, targetGivebackPct: 5 },
      { avgTicketCents: NaN, targetGivebackPct: 5 },
      { avgTicketCents: 600, targetGivebackPct: 0 },
      { avgTicketCents: 600, targetGivebackPct: -5 },
      { avgTicketCents: 600, targetGivebackPct: NaN },
      { avgTicketCents: 600 }, // missing target
      {},
      null,
      undefined
    ];
    for (const input of cases) {
      const result = callNullSafe(GrowRec.recommendPoints, 'recommendPoints', input);
      assertNullShaped(result, numericKeys);
    }
  });

  // ---------------------------------------------------------------------
  // 3. recommendMembership
  // ---------------------------------------------------------------------

  test('recommendMembership: avgTicket 600 -> monthly 1500, breakeven 2.5', () => {
    const r = GrowRec.recommendMembership({ avgTicketCents: 600 });
    assert.equal(r.monthlyPriceCents, 1500);
    assert.equal(r.breakevenVisits, 2.5);
    assert.ok(Array.isArray(r.reasoning) && r.reasoning.length > 0);
  });

  test('recommendMembership: avgTicket 300 -> roundToNearest(750,500) rounds UP to 1000 (Math.round(1.5)=2), breakeven 3.3', () => {
    const r = GrowRec.recommendMembership({ avgTicketCents: 300 });
    assert.equal(r.monthlyPriceCents, 1000);
    assert.equal(r.breakevenVisits, 3.3);
  });

  test('recommendMembership: the 1000-cent floor actually kicks in (not just coincides with rounding)', () => {
    // avgTicket 100 -> raw = roundToNearest(250,500) = 500, which is BELOW
    // the 1000-cent floor, so the floor must lift it to 1000.
    const r = GrowRec.recommendMembership({ avgTicketCents: 100 });
    assert.equal(r.monthlyPriceCents, 1000, 'the min(...,1000) floor must apply when the raw rounded value is 500');
    assert.equal(r.breakevenVisits, 10);
  });

  test('recommendMembership: invalid inputs are null-safe', () => {
    const numericKeys = ['monthlyPriceCents', 'breakevenVisits'];
    for (const input of [{ avgTicketCents: -600 }, { avgTicketCents: NaN }, { avgTicketCents: 0 }, {}, null, undefined]) {
      const result = callNullSafe(GrowRec.recommendMembership, 'recommendMembership', input);
      assertNullShaped(result, numericKeys);
    }
  });

  // ---------------------------------------------------------------------
  // 4. recommendGiftCards
  // ---------------------------------------------------------------------

  test('recommendGiftCards: avgTicket 600 -> [500, 1000, 2500]', () => {
    const r = GrowRec.recommendGiftCards({ avgTicketCents: 600 });
    assert.deepEqual(r.denominationsCents, [500, 1000, 2500]);
    assert.ok(Array.isArray(r.reasoning) && r.reasoning.length > 0);
  });

  test('recommendGiftCards: avgTicket 400 -> [500, 1000, 1500]', () => {
    const r = GrowRec.recommendGiftCards({ avgTicketCents: 400 });
    assert.deepEqual(r.denominationsCents, [500, 1000, 1500]);
  });

  test('recommendGiftCards: tiny ticket (avgTicket 100) -> all three tiers round/floor to 500 and dedupe to a single denomination', () => {
    const r = GrowRec.recommendGiftCards({ avgTicketCents: 100 });
    assert.deepEqual(r.denominationsCents, [500]);
  });

  test('recommendGiftCards: denominations are always ascending and deduplicated', () => {
    for (const avgTicketCents of [100, 250, 400, 600, 999, 8000]) {
      const r = GrowRec.recommendGiftCards({ avgTicketCents });
      const sorted = [...r.denominationsCents].sort((a, b) => a - b);
      assert.deepEqual(r.denominationsCents, sorted, `denominations must already be ascending for avgTicket ${avgTicketCents}`);
      assert.equal(
        new Set(r.denominationsCents).size, r.denominationsCents.length,
        `denominations must be deduplicated for avgTicket ${avgTicketCents}`
      );
      for (const denom of r.denominationsCents) {
        assert.ok(denom >= 500, `denomination ${denom} must respect the 500-cent floor`);
      }
    }
  });

  test('recommendGiftCards: invalid inputs are null-safe', () => {
    for (const input of [{ avgTicketCents: -600 }, { avgTicketCents: NaN }, {}, null, undefined]) {
      const result = callNullSafe(GrowRec.recommendGiftCards, 'recommendGiftCards', input);
      if (result === null || result === undefined) continue;
      assert.ok(Array.isArray(result.denominationsCents), 'denominationsCents must at least be an array on invalid input');
      assert.equal(result.denominationsCents.length, 0, 'denominationsCents should be empty for invalid input');
    }
  });

  // ---------------------------------------------------------------------
  // 5. estimateRetentionLift
  // ---------------------------------------------------------------------

  test('estimateRetentionLift: the four pinned ranges, exactly', () => {
    const points = GrowRec.estimateRetentionLift('points');
    assert.equal(points.lowPct, 5);
    assert.equal(points.highPct, 15);
    assert.match(points.disclaimer.toLowerCase(), /estimate/);

    const membership = GrowRec.estimateRetentionLift('membership');
    assert.equal(membership.lowPct, 10);
    assert.equal(membership.highPct, 25);
    assert.match(membership.disclaimer.toLowerCase(), /estimate/);

    const giftcard = GrowRec.estimateRetentionLift('giftcard');
    assert.equal(giftcard.lowPct, 2);
    assert.equal(giftcard.highPct, 8);
    assert.match(giftcard.disclaimer.toLowerCase(), /estimate/);

    const bringback = GrowRec.estimateRetentionLift('bringback');
    assert.equal(bringback.lowPct, 5);
    assert.equal(bringback.highPct, 20);
    assert.match(bringback.disclaimer.toLowerCase(), /estimate/);
  });

  test('estimateRetentionLift: unknown type never throws; if an object comes back, it is estimate-shaped', () => {
    let result;
    assert.doesNotThrow(() => {
      result = GrowRec.estimateRetentionLift('not-a-real-type');
    });
    if (result !== null && result !== undefined) {
      assert.ok(typeof result.lowPct === 'number' || result.lowPct === null);
      assert.ok(typeof result.highPct === 'number' || result.highPct === null);
      assert.equal(typeof result.disclaimer, 'string');
      assert.match(result.disclaimer.toLowerCase(), /estimate/);
    }
  });

  test('estimateRetentionLift: null-safe on null/undefined/missing type', () => {
    assert.doesNotThrow(() => GrowRec.estimateRetentionLift(null));
    assert.doesNotThrow(() => GrowRec.estimateRetentionLift(undefined));
    assert.doesNotThrow(() => GrowRec.estimateRetentionLift());
  });

  // ---------------------------------------------------------------------
  // 6. catalogMetrics
  // ---------------------------------------------------------------------

  test('catalogMetrics: odd-count median is the middle value', () => {
    const items = [
      { name: 'Kopi', price_cents: 100 },
      { name: 'Chicken Rice', price_cents: 300 },
      { name: 'Laksa', price_cents: 200 }
    ];
    const r = GrowRec.catalogMetrics(items);
    assert.equal(r.avgTicketCents, 200);
    assert.equal(r.count, 3);
  });

  test('catalogMetrics: even-count median is the ROUNDED mean of the middle two (pinned example [400,600] -> 500)', () => {
    const r = GrowRec.catalogMetrics([
      { name: 'A', price_cents: 400 },
      { name: 'B', price_cents: 600 }
    ]);
    assert.equal(r.avgTicketCents, 500);
    assert.equal(r.count, 2);
  });

  test('catalogMetrics: even-count median rounding actually rounds (401,600 -> mean 500.5 -> 501)', () => {
    const r = GrowRec.catalogMetrics([
      { name: 'A', price_cents: 401 },
      { name: 'B', price_cents: 600 }
    ]);
    assert.equal(r.avgTicketCents, 501, 'Math.round(500.5) = 501 in JS (half rounds toward +Infinity)');
  });

  test('catalogMetrics: sampleItems are the top 3 by price desc, with name + price_cents', () => {
    const items = [
      { name: 'Kopi', price_cents: 150 },
      { name: 'Croissant', price_cents: 350 },
      { name: 'Chicken Rice', price_cents: 450 },
      { name: 'Latte', price_cents: 500 },
      { name: 'Set Meal', price_cents: 1200 }
    ];
    const r = GrowRec.catalogMetrics(items);
    assert.equal(r.count, 5);
    assert.equal(r.sampleItems.length, 3);
    assert.deepEqual(
      r.sampleItems.map((i) => i.name),
      ['Set Meal', 'Latte', 'Chicken Rice']
    );
    assert.deepEqual(
      r.sampleItems.map((i) => i.price_cents),
      [1200, 500, 450]
    );
    // Median of the full 5-item set (sorted: 150,350,450,500,1200) is 450.
    assert.equal(r.avgTicketCents, 450);
  });

  test('catalogMetrics: empty array -> {avgTicketCents:null, sampleItems:[], count:0}', () => {
    const r = GrowRec.catalogMetrics([]);
    assert.deepEqual(r, { avgTicketCents: null, sampleItems: [], count: 0 });
  });

  test('catalogMetrics: invalid (non-array) inputs -> {avgTicketCents:null, sampleItems:[], count:0}', () => {
    for (const input of [null, undefined, 'not-an-array', 42, {}, true]) {
      const result = callNullSafe(GrowRec.catalogMetrics, 'catalogMetrics', input);
      assert.deepEqual(result, { avgTicketCents: null, sampleItems: [], count: 0 }, `expected default shape for ${JSON.stringify(input)}`);
    }
  });

  // ---------------------------------------------------------------------
  // 7. Meta: reasoning / disclaimer hygiene across the whole surface
  // ---------------------------------------------------------------------

  test('meta: every reasoning array returned by the recommenders is a non-empty array of strings', () => {
    const outputs = [
      GrowRec.recommendPoints({ avgTicketCents: 600, targetGivebackPct: 5 }),
      GrowRec.recommendPoints({ avgTicketCents: 250, targetGivebackPct: 5 }),
      GrowRec.recommendMembership({ avgTicketCents: 600 }),
      GrowRec.recommendMembership({ avgTicketCents: 300 }),
      GrowRec.recommendGiftCards({ avgTicketCents: 600 }),
      GrowRec.recommendGiftCards({ avgTicketCents: 400 })
    ];
    for (const output of outputs) {
      assert.ok(Array.isArray(output.reasoning), 'reasoning must be an array');
      assert.ok(output.reasoning.length > 0, 'reasoning must be non-empty');
      for (const line of output.reasoning) {
        assert.equal(typeof line, 'string', 'every reasoning entry must be a string');
        assert.ok(line.trim().length > 0, 'reasoning strings must not be blank');
      }
    }
  });

  test('meta: every estimateRetentionLift disclaimer contains "estimate"', () => {
    for (const type of ['points', 'membership', 'giftcard', 'bringback']) {
      const r = GrowRec.estimateRetentionLift(type);
      assert.equal(typeof r.disclaimer, 'string');
      assert.match(r.disclaimer.toLowerCase(), /estimate/, `disclaimer for "${type}" must contain "estimate"`);
    }
  });

  // ---------------------------------------------------------------------
  // 8. Export surface
  // ---------------------------------------------------------------------

  test('module exports all six pinned pure functions', () => {
    for (const fnName of [
      'givebackPct',
      'recommendPoints',
      'recommendMembership',
      'recommendGiftCards',
      'estimateRetentionLift',
      'catalogMetrics'
    ]) {
      assert.equal(typeof GrowRec[fnName], 'function', `expected GrowRec.${fnName} to be a function`);
    }
  });
}
