/* NESTLY v716 — Customer Intelligence opportunities panel, the v705 + v712 "consultant spine v3"
 * additions rendered in the merchant opportunities card (app/app.js, ciOpportunityCardHtmlV685 and
 * its e15faa11 helpers).
 *
 * db/migrations/20260902_nestly_v705_spine_v3.sql and db/migrations/20260902_nestly_v712_spine_
 * wording_closures.sql give every extended-mode candidate:
 *   - materiality {numerator, denominator, pct} (app.rate_block_v1's shape) + materiality_class
 *     ('material'|'minor'|'unquantified')
 *   - margin_guard {status:'ok'|'blocked'|'unavailable', margin_cents, reason} — present only
 *     when incentive.kind is 'credit'/'discount' (null otherwise)
 *   - impact.affected_customers / impact.revenue_cents / impact.margin / impact.capacity /
 *     impact.retention_risk, each {status:'ok'|'unavailable'|'not_applicable', ...} — never a
 *     fabricated number standing in for "unknown"
 *   - concentration {top1_share_bps, mean_excl_top1, skew_note} on the category_mix candidate
 *   - alternatives[] always >=2 distinct kinds including a non-incentive one (no_action,
 *     operational_change, rebooking, reminder_only, service_recovery)
 *   - a 'campaigns' domain candidate (ASSOCIATION-class, rank_class 'unquantified')
 *
 * This file proves the render side, extracted and EXECUTED via vm (same posture as
 * v696-ci-opportunities-extended.test.mjs):
 *  A. materiality_class renders as a <=3-word chip ("Material"/"Minor"/"Unquantified").
 *  B. margin_guard renders "Margin ok" + margin_cents, "Blocked: <server reason>" verbatim, or
 *     "Enter costs in Settings" when unavailable; renders nothing when margin_guard is absent
 *     (incentive.kind not credit/discount).
 *  C. impact.capacity renders booked/available/pct verbatim when ok, the honest reason when
 *     unavailable, and nothing when not_applicable.
 *  D. impact.retention_risk renders the at_risk_n verbatim when ok, and nothing when
 *     not_applicable.
 *  E. concentration renders its skew_note verbatim when present, nothing when absent.
 *  F. ALL alternatives render (primary first), each with a <=3-word kind label — including the
 *     strength generators' new no_action-primary shape.
 *  G. No invented numbers: every SGD amount and every percentage in the rendered HTML traces to a
 *     figure literally present in the fixture.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

const oppStart = app.indexOf('function ciOpportunityConfidenceV685(');
const oppEnd = app.indexOf('/* nestly_v679 — Customer intelligence gets three more evidence-safe panels', oppStart);
assert.ok(oppStart > -1 && oppEnd > oppStart, 'opportunitiesPanelHtmlV685 and its helpers must be top-level functions');
const oppBlock = app.slice(oppStart, oppEnd);

function renderOpportunities(payload) {
  const esc = (x) => String(x ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  const sandbox = {
    esc,
    walletDate: (v) => `WD:${v}`,
    ciEmptyPanelV679: (headingId, eyebrow, title, message) => `<section class="revenue-truth-section" aria-labelledby="${headingId}">
      <div class="revenue-truth-section-head"><div><span class="revenue-truth-eyebrow">${esc(eyebrow)}</span>
      <h2 id="${headingId}">${esc(title)}</h2></div></div>
      <div class="empty">${esc(message)}</div></section>`
  };
  const context = vm.createContext(sandbox);
  context.__exports = {};
  vm.runInContext(oppBlock + '\n__exports.render=opportunitiesPanelHtmlV685;', context);
  return context.__exports.render(payload);
}

/* -------------------------------------------------------------------------------------------
   Fixture candidates — shapes lifted from db/migrations/20260902_nestly_v705_spine_v3.sql and
   db/migrations/20260902_nestly_v712_spine_wording_closures.sql (the generic post-gate lateral
   pass, section 5f/6, and db/tests/executed/v712_corpus_spine_closures.sql's asserted shapes:
   materiality is app.rate_block_v1's own {numerator,denominator,pct} shape, not a bare "bps").
   ------------------------------------------------------------------------------------------- */

// 1 · material + blocked margin (loyalty_cannibalisation_gap: incentive.kind='credit', the ONE
//     candidate whose incentive is itself a spend, per v705's own JC3).
function materialBlockedMarginCandidate() {
  return {
    id: 'loyalty_cannibalisation_gap', rank: 1, rank_class: 'unquantified', domain: 'loyalty_programmes',
    pattern: 'Loyalty credit redemption is cannibalising full-price sales for 12 customers.',
    comparison: { kind: 'threshold', detail: 'redemption share vs baseline' },
    impact: {
      cents: 120000, reason: null, scenario_cents: 120000,
      expected_value: { cents: 120000, method: 'sum over redeeming customers', inputs: { scored: 12, abstained: 0 } },
      affected_customers: { status: 'ok', n: 12 },
      revenue_cents: { status: 'ok', cents: 120000 },
      margin: { status: 'blocked', margin_cents: 500,
        reason: 'incentive 800 cents would exceed the 500-cent margin (price 1000, cost 500)' },
      capacity: { status: 'not_applicable' },
      retention_risk: { status: 'not_applicable' }
    },
    action: { who: 'the owner', what: 'Review the loyalty credit terms for this service.', when: 'this cycle', channel: 'analysis' },
    evidence: { source_rpc: 'public.get_ci_loyalty_programmes_v1', refs: {} },
    evidence_class: 'ASSOCIATION',
    confidence: { n: 12, floor: 5, status: 'ok' },
    limitation: 'Observational, not a controlled experiment. incentive 800 cents would exceed the 500-cent margin (price 1000, cost 500)',
    incentive: { kind: 'credit', declared: true },
    why_now: 'The cannibalisation share is already measurable as of 2026-09-01.',
    reversal_condition: 'Reconsider this call if the redemption share falls back under baseline.',
    materiality: { numerator: 120000, denominator: 8000000, pct: 1.5 },
    materiality_class: 'material',
    margin_guard: { status: 'blocked', margin_cents: 500,
      reason: 'incentive 800 cents would exceed the 500-cent margin (price 1000, cost 500)' },
    capacity: null,
    concentration: null,
    alternatives: [
      { kind: 'reminder_only', primary: true, what: 'Contact without any discount or credit.',
        cost_basis: { status: 'declared', cents: 0, note: 'no spend' } },
      { kind: 'incentive', primary: false, what: 'Offer a discount or loyalty credit to prompt action.',
        cost_basis: { status: 'unavailable', reason: 'no discount-cost field in this schema' } }
    ],
    cost_basis: { status: 'declared', cents: 0, note: 'observation only' }
  };
}

// 2 · minor + margin unavailable (no_discount_reminder: same incentive.kind='credit' shape, but
//     no cost_cents recorded on the named service -> honest 'unavailable', never a guessed cost).
function minorMarginUnavailableCandidate() {
  return {
    id: 'no_discount_reminder', rank: 2, rank_class: 'unquantified', domain: 'discount_dependency',
    pattern: '3 customers have never bought without a discount attached.',
    comparison: { kind: 'threshold', detail: 'discount-attached share' },
    impact: {
      cents: 900, reason: null, scenario_cents: 900,
      expected_value: { cents: 900, method: 'sum over discount-only buyers', inputs: { scored: 3, abstained: 0 } },
      affected_customers: { status: 'ok', n: 3 },
      revenue_cents: { status: 'ok', cents: 900 },
      margin: { status: 'unavailable',
        reason: 'no cost recorded for this service; enter costs in Settings', margin_cents: null },
      capacity: { status: 'not_applicable' },
      retention_risk: { status: 'not_applicable' }
    },
    action: { who: 'the owner', what: 'Send these 3 customers a full-price reminder.', when: 'this week', channel: 'whatsapp' },
    evidence: { source_rpc: 'public.get_ci_discount_dependency_v1', refs: {} },
    evidence_class: 'ASSOCIATION',
    confidence: { n: 3, floor: 5, status: 'insufficient' },
    limitation: 'Below the evidence floor.',
    incentive: { kind: 'credit', declared: true },
    why_now: 'The discount-only share is already measurable as of 2026-09-01.',
    reversal_condition: 'Reconsider this call if the discount-only share rises.',
    materiality: { numerator: 900, denominator: 8000000, pct: 0.01 },
    materiality_class: 'minor',
    margin_guard: { status: 'unavailable',
      reason: 'no cost recorded for this service; enter costs in Settings', margin_cents: null },
    capacity: null,
    concentration: null,
    alternatives: [
      { kind: 'reminder_only', primary: true, what: 'Contact without any discount or credit.',
        cost_basis: { status: 'declared', cents: 0, note: 'no spend' } },
      { kind: 'incentive', primary: false, what: 'Offer a discount or loyalty credit to prompt action.',
        cost_basis: { status: 'unavailable', reason: 'no discount-cost field in this schema' } }
    ],
    cost_basis: { status: 'declared', cents: 0, note: 'observation only' }
  };
}

// 3 · capacity unavailable (gateway_followthrough, domain=service_intelligence — one of the four
//     capacity-relevant domains — but this business has no staff_hours rows).
function capacityUnavailableCandidate() {
  return {
    id: 'gateway_followthrough:facial', rank: 3, rank_class: 'unquantified', domain: 'service_intelligence',
    pattern: '8 first-time facial buyers never returned for a second visit.',
    comparison: { kind: 'threshold', detail: 'first-to-second conversion' },
    impact: {
      cents: null, reason: 'an association, not an incremental model', scenario_cents: null,
      expected_value: { status: 'unavailable', reason: 'no behavioural model backs this association' },
      affected_customers: { status: 'ok', n: 8 },
      revenue_cents: { status: 'not_applicable' },
      margin: { status: 'not_applicable', reason: 'no incentive spend for this candidate' },
      capacity: { status: 'unavailable', reason: 'no staff schedule rows recorded' },
      retention_risk: { status: 'not_applicable' }
    },
    action: { who: 'the owner', what: 'Follow up with these 8 first-time buyers.', when: 'this week', channel: 'whatsapp' },
    evidence: { source_rpc: 'public.get_ci_service_intelligence_v1', refs: {} },
    evidence_class: 'ASSOCIATION',
    confidence: { n: 8, floor: 5, status: 'ok' },
    limitation: 'Observational, not causal.',
    incentive: { kind: 'none', declared: true },
    why_now: 'The gap is already measurable as of 2026-09-01.',
    reversal_condition: 'Reconsider this call if the return rate rises above baseline.',
    materiality: { numerator: null, denominator: 8000000, pct: null },
    materiality_class: 'unquantified',
    margin_guard: null,
    capacity: { status: 'unavailable', reason: 'no staff schedule rows recorded' },
    concentration: null,
    alternatives: [
      { kind: 'reminder_only', primary: true, what: 'Contact without any discount or credit.',
        cost_basis: { status: 'declared', cents: 0, note: 'no spend' } },
      { kind: 'service_recovery', primary: false,
        what: 'Re-run the first-visit experience for a sample of recent buyers at no charge to find what is actually going wrong before spending on acquisition.',
        cost_basis: { status: 'unavailable', reason: 'no discount-cost field in this schema' } },
      { kind: 'incentive', primary: false, what: 'Offer a discount or loyalty credit to prompt a second visit.',
        cost_basis: { status: 'unavailable', reason: 'no discount-cost field in this schema' } }
    ],
    cost_basis: { status: 'declared', cents: 0, note: 'observation only' }
  };
}

// 4 · strength with no_action primary (nestly_v712 check 77: strength:category now carries a NEW
//     no_action, primary=true alternative, plus the existing reminder_only demoted to primary=false).
function strengthNoActionCandidate() {
  return {
    id: 'strength:category:facial', rank: 4, rank_class: 'strength', domain: 'category_mix',
    pattern: '"Facial" is this business\'s strongest category by revenue.',
    comparison: { kind: 'baseline', detail: 'top category by revenue' },
    impact: {
      cents: 200000, reason: null, scenario_cents: null,
      expected_value: { status: 'unavailable', reason: 'a strength is not itself an actionable dollar estimate' },
      affected_customers: { status: 'ok', n: 20 },
      revenue_cents: { status: 'ok', cents: 200000 },
      margin: { status: 'not_applicable', reason: 'no incentive spend for this candidate' },
      capacity: { status: 'not_applicable' },
      retention_risk: { status: 'not_applicable' }
    },
    action: { who: 'the owner', what: 'Keep promoting "Facial".', when: 'ongoing', channel: 'analysis' },
    evidence: { source_rpc: 'public.get_ci_category_mix_v1', refs: {} },
    evidence_class: 'DIRECT_FACT',
    confidence: { n: 20, floor: 5, status: 'ok' },
    limitation: 'A strength, not a risk.',
    incentive: { kind: 'none', declared: true },
    why_now: '"Facial" is already the top category as of 2026-09-01.',
    reversal_condition: 'Reconsider this call if its revenue falls under 200000 cents.',
    materiality: { numerator: 200000, denominator: 8000000, pct: 2.5 },
    materiality_class: 'material',
    margin_guard: null,
    capacity: null,
    concentration: { top1_share_bps: 4200, mean_excl_top1: 15.3,
      skew_note: 'Its top customer alone accounts for 42% of the category.' },
    alternatives: [
      { kind: 'no_action', primary: true, what: 'keep doing this; nothing to change',
        cost_basis: { status: 'declared', cents: 0, note: 'no spend' } },
      { kind: 'reminder_only', primary: false, what: 'No action needed beyond monitoring.',
        cost_basis: { status: 'declared', cents: 0, note: 'no spend' } }
    ],
    cost_basis: { status: 'declared', cents: 0, note: 'observation only' }
  };
}

const V716_PAYLOAD = {
  contract: 'ci_opportunities_v1',
  scope: { business_id: 'b1', branch_id: null, from: '2026-08-01', to: '2026-09-01', currency: 'SGD' },
  time_basis: 'sale_occurred_at',
  ranked: [materialBlockedMarginCandidate(), minorMarginUnavailableCandidate(),
    capacityUnavailableCandidate(), strengthNoActionCandidate()],
  abstentions: [],
  comparisons: { subgroups_examined: 20, subgroups_promoted: 4, note: 'Promoted findings were selected from the examined set.' },
  observed_since: '2026-08-01T00:00:00Z',
  report_sections: {
    strengths: ['strength:category:facial'], failures: ['loyalty_cannibalisation_gap'],
    leakage: ['no_discount_reminder'], margin: { status: 'unavailable', reason: 'n/a' },
    unnoticed_behaviour: ['gateway_followthrough:facial'], segments: [], change: []
  },
  top_actions: []
};

/* -------------------------------------------------------------------------------------------
   A. materiality_class renders as a <=3-word chip.
   ------------------------------------------------------------------------------------------- */

test('V716 opportunitiesPanelHtmlV685: materiality_class renders as a <=3-word chip (Material/Minor/Unquantified)', () => {
  const html = renderOpportunities(V716_PAYLOAD);
  assert.ok(/data-materiality-class="material"[^<]*>Material</.test(html), 'material chip must render "Material"');
  assert.ok(/data-materiality-class="minor"[^<]*>Minor</.test(html), 'minor chip must render "Minor"');
  assert.ok(/data-materiality-class="unquantified"[^<]*>Unquantified</.test(html), 'unquantified chip must render "Unquantified"');
});

/* -------------------------------------------------------------------------------------------
   B. margin_guard: ok / blocked / unavailable / absent.
   ------------------------------------------------------------------------------------------- */

test('V716 opportunitiesPanelHtmlV685: a blocked margin_guard renders "Blocked: <server reason>" verbatim', () => {
  const html = renderOpportunities(V716_PAYLOAD);
  assert.ok(html.includes('Blocked: incentive 800 cents would exceed the 500-cent margin (price 1000, cost 500)'),
    'the blocked reason must render verbatim, unmodified');
});

test('V716 opportunitiesPanelHtmlV685: an unavailable margin_guard renders "Enter costs in Settings"', () => {
  const html = renderOpportunities(V716_PAYLOAD);
  assert.ok(html.includes('Enter costs in Settings'));
});

test('V716 opportunitiesPanelHtmlV685: an ok margin_guard renders "Margin ok" with margin_cents', () => {
  const ok = { ...materialBlockedMarginCandidate(),
    margin_guard: { status: 'ok', margin_cents: 500, reason: null } };
  const html = renderOpportunities({ ...V716_PAYLOAD, ranked: [ok] });
  assert.ok(html.includes('Margin ok'), 'the ok label must render');
  assert.ok(html.includes('SGD 5.00'), 'margin_cents=500 must render as SGD 5.00');
});

test('V716 opportunitiesPanelHtmlV685: a null margin_guard (incentive.kind not credit/discount) renders no Margin row', () => {
  const html = renderOpportunities(V716_PAYLOAD);
  // capacityUnavailableCandidate and strengthNoActionCandidate both carry margin_guard:null.
  const cardStart = html.indexOf('gateway_followthrough:facial\'s own capacity below has no bearing here');
  // Simpler, direct check: count of "<span>Margin</span>" rows must equal exactly the two
  // candidates that declare a non-null margin_guard (material + minor), not all four candidates.
  const marginRowCount = (html.match(/<span>Margin<\/span>/g) || []).length;
  assert.equal(marginRowCount, 2, 'only the two candidates with a non-null margin_guard may render a Margin row');
});

/* -------------------------------------------------------------------------------------------
   C. impact.capacity: ok / unavailable / not_applicable.
   ------------------------------------------------------------------------------------------- */

test('V716 opportunitiesPanelHtmlV685: impact.capacity unavailable renders the honest reason verbatim', () => {
  const html = renderOpportunities(V716_PAYLOAD);
  assert.ok(html.includes('no staff schedule rows recorded'));
});

test('V716 opportunitiesPanelHtmlV685: impact.capacity ok renders booked/available/pct verbatim', () => {
  const withCapacity = { ...capacityUnavailableCandidate(),
    impact: { ...capacityUnavailableCandidate().impact,
      capacity: { status: 'ok', booked_minutes: 480, available_minutes: 960, pct: 50.0 } } };
  const html = renderOpportunities({ ...V716_PAYLOAD, ranked: [withCapacity] });
  assert.ok(html.includes('480'), 'booked_minutes must render verbatim');
  assert.ok(html.includes('960'), 'available_minutes must render verbatim');
  assert.ok(html.includes('50'), 'pct must render verbatim');
});

test('V716 opportunitiesPanelHtmlV685: impact.capacity not_applicable renders no Capacity row', () => {
  const html = renderOpportunities(V716_PAYLOAD);
  // materialBlockedMarginCandidate and minorMarginUnavailableCandidate both carry
  // impact.capacity:{status:'not_applicable'}; only capacityUnavailableCandidate's row should show.
  const capacityRowCount = (html.match(/<span>Capacity<\/span>/g) || []).length;
  assert.equal(capacityRowCount, 1, 'only the one candidate with a non-not_applicable capacity may render a Capacity row');
});

/* -------------------------------------------------------------------------------------------
   D. impact.retention_risk: ok / not_applicable.
   ------------------------------------------------------------------------------------------- */

test('V716 opportunitiesPanelHtmlV685: impact.retention_risk ok renders at_risk_n verbatim', () => {
  const withRisk = { ...materialBlockedMarginCandidate(),
    impact: { ...materialBlockedMarginCandidate().impact,
      retention_risk: { status: 'ok', at_risk_n: 12 } } };
  const html = renderOpportunities({ ...V716_PAYLOAD, ranked: [withRisk] });
  assert.ok(html.includes('Retention risk'));
  assert.ok(html.includes('12 at risk'), 'at_risk_n=12 must render verbatim');
});

test('V716 opportunitiesPanelHtmlV685: impact.retention_risk not_applicable renders no Retention risk row', () => {
  const html = renderOpportunities(V716_PAYLOAD);
  assert.ok(!html.includes('Retention risk'), 'every fixture candidate here carries not_applicable; no row should render');
});

/* -------------------------------------------------------------------------------------------
   E. concentration: present / absent.
   ------------------------------------------------------------------------------------------- */

test('V716 opportunitiesPanelHtmlV685: concentration renders its skew_note verbatim when present', () => {
  const html = renderOpportunities(V716_PAYLOAD);
  assert.ok(html.includes('Its top customer alone accounts for 42% of the category.'));
});

test('V716 opportunitiesPanelHtmlV685: a null concentration renders no concentration paragraph for that candidate', () => {
  const html = renderOpportunities({ ...V716_PAYLOAD, ranked: [materialBlockedMarginCandidate()] });
  assert.ok(!html.includes('ci-opportunity-concentration'));
});

/* -------------------------------------------------------------------------------------------
   F. ALL alternatives render, primary first, <=3-word kind labels — incl. the strength
   generator's new no_action-primary shape (nestly_v712 check 77).
   ------------------------------------------------------------------------------------------- */

test('V716 opportunitiesPanelHtmlV685: every alternative kind renders, primary listed first', () => {
  const html = renderOpportunities({ ...V716_PAYLOAD, ranked: [capacityUnavailableCandidate()] });
  const list = html.slice(html.indexOf('ci-opportunity-alternatives-list'));
  const kinds = [...list.matchAll(/<li[^>]*><strong>([^<]+)<\/strong>/g)].map((m) => m[1]);
  assert.deepEqual(kinds.slice(0, 3), ['Reminder only', 'Service recovery', 'Incentive'],
    'all three alternative kinds must render, primary (reminder_only) first');
});

test('V716 opportunitiesPanelHtmlV685: strength:category\'s no_action alternative renders primary, ahead of reminder_only', () => {
  const html = renderOpportunities({ ...V716_PAYLOAD, ranked: [strengthNoActionCandidate()] });
  const list = html.slice(html.indexOf('ci-opportunity-alternatives-list'));
  const kinds = [...list.matchAll(/<li[^>]*><strong>([^<]+)<\/strong>/g)].map((m) => m[1]);
  assert.deepEqual(kinds, ['No action', 'Reminder only']);
  assert.ok(html.includes('keep doing this; nothing to change'));
});

test('V716 opportunitiesPanelHtmlV685: every rendered alternative kind label is <=3 words', () => {
  const html = renderOpportunities(V716_PAYLOAD);
  const labels = [...html.matchAll(/ci-opportunity-alternatives-list[^]*?<\/ul>/g)]
    .flatMap((block) => [...block[0].matchAll(/<strong>([^<]+)<\/strong>/g)].map((m) => m[1]));
  assert.ok(labels.length > 0, 'at least one alternative label must render');
  for (const label of labels) {
    assert.ok(label.trim().split(/\s+/).length <= 3, `alternative label "${label}" exceeds 3 words`);
  }
});

/* -------------------------------------------------------------------------------------------
   G. No invented numbers: every SGD amount and every percentage in the HTML traces to a figure
   literally present in the fixture.
   ------------------------------------------------------------------------------------------- */

test('V716 opportunitiesPanelHtmlV685: no SGD amount or percentage in the HTML is absent from the fixture', () => {
  const html = renderOpportunities(V716_PAYLOAD);

  const fixtureCents = new Set();
  const fixturePcts = new Set();
  for (const item of V716_PAYLOAD.ranked) {
    const i = item.impact || {};
    if (i.cents !== null && i.cents !== undefined) fixtureCents.add(Number(i.cents));
    if (i.scenario_cents !== null && i.scenario_cents !== undefined) fixtureCents.add(Number(i.scenario_cents));
    if (i.expected_value && i.expected_value.cents !== null && i.expected_value.cents !== undefined) {
      fixtureCents.add(Number(i.expected_value.cents));
    }
    if (item.margin_guard && item.margin_guard.margin_cents !== null && item.margin_guard.margin_cents !== undefined) {
      fixtureCents.add(Number(item.margin_guard.margin_cents));
    }
    if (item.materiality_class && item.materiality && item.materiality.pct !== null && item.materiality.pct !== undefined) {
      fixturePcts.add(Number(item.materiality.pct));
    }
    if (i.capacity && i.capacity.pct !== null && i.capacity.pct !== undefined) fixturePcts.add(Number(i.capacity.pct));
    if (item.concentration && item.concentration.top1_share_bps !== null && item.concentration.top1_share_bps !== undefined) {
      fixturePcts.add(Math.round(item.concentration.top1_share_bps / 100));
    }
  }

  const renderedAmounts = [...html.matchAll(/SGD (-?[\d,]+\.\d{2})/g)]
    .map((m) => Math.round(parseFloat(m[1].replace(/,/g, '')) * 100));
  for (const cents of renderedAmounts) {
    assert.ok(fixtureCents.has(cents), `rendered SGD amount for ${cents} cents does not trace back to any fixture cents field`);
  }

  const renderedPcts = [...html.matchAll(/\((\d+(?:\.\d+)?)%\)/g)].map((m) => Number(m[1]));
  for (const pct of renderedPcts) {
    assert.ok(fixturePcts.has(pct) || html.includes(`${pct}% of the category`),
      `rendered percentage ${pct}% does not trace back to any fixture figure`);
  }
  assert.ok(renderedAmounts.length > 0 || renderedPcts.length > 0, 'at least one figure must render for this fixture');
});

test('V716 opportunitiesPanelHtmlV685: a missing/malformed v705/v712 payload still renders without crashing', () => {
  const minimal = { ...V716_PAYLOAD,
    ranked: [{ id: 'x', rank: 1, rank_class: 'quantified', action: {}, confidence: {}, impact: {} }] };
  assert.doesNotThrow(() => renderOpportunities(minimal));
  const html = renderOpportunities(minimal);
  assert.ok(!html.includes('undefined'), 'a candidate missing every v705/v712 field must never render the literal string "undefined"');
});
