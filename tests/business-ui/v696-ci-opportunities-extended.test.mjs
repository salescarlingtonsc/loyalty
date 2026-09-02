/* NESTLY v696 — Customer Intelligence opportunities panel, EXTENDED mode (p_extended=>true).
 *
 * db/migrations/20260902_nestly_v688_consultant_spine_v2.sql gave public.get_ci_opportunities_v1
 * a trailing `p_extended boolean default false`. With true, each candidate gains top-level
 * incentive{kind,declared}, why_now, reversal_condition, alternatives[{kind,primary,what,
 * cost_basis}], cost_basis; impact gains scenario_cents and expected_value ({cents,method,
 * inputs:{scored,abstained}} or {status:'unavailable',reason}); the payload gains report_sections
 * (strengths/failures/leakage/margin/unnoticed_behaviour/segments/change) and top_actions.
 *
 * This file proves:
 *  A. The RPC call site now passes p_extended:true (wiring, source-level).
 *  B. opportunitiesPanelHtmlV685 (extracted and EXECUTED via vm, same posture as
 *     v685-ci-surfaces.test.mjs) renders: expected value with scored/abstained counts, the
 *     honest 'unavailable' reason path, the scenario value labelled distinctly from expected
 *     value, the reversal condition, the primary alternative, and the incentive declaration.
 *  C. report_sections render as collapsible groups in the fixed order strengths, failures,
 *     leakage, margin, unnoticed_behaviour, segments, change; an empty section reads "Nothing
 *     surfaced above the evidence floor."; margin (always {status:'unavailable',reason}) renders
 *     its reason, never an empty-section placeholder pretending it's just empty.
 *  D. top_actions renders at the top of the panel, above the ranked list.
 *  E. No-invented-numbers: every "SGD X.XX" figure in the rendered HTML traces back to a cents
 *     value literally present in the fixture (impact.cents / impact.scenario_cents /
 *     impact.expected_value.cents) — nothing is computed client-side.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

/* -------------------------------------------------------------------------------------------
   A. Wiring: p_extended:true must be passed on the live RPC call site.
   ------------------------------------------------------------------------------------------- */

test('V696 wiring: get_ci_opportunities_v1 is called with p_extended:true', () => {
  const callStart = app.indexOf("sb.rpc('get_ci_opportunities_v1',{");
  assert.ok(callStart > -1, 'the get_ci_opportunities_v1 call site must exist');
  const callEnd = app.indexOf('})', callStart);
  const callSite = app.slice(callStart, callEnd + 2);
  assert.ok(/p_extended\s*:\s*true/.test(callSite),
    `the call site must pass p_extended:true, got: ${callSite}`);
});

test('V696 wiring: the call args object, executed, literally includes p_extended:true', () => {
  const callStart = app.indexOf("sb.rpc('get_ci_opportunities_v1',{");
  assert.ok(callStart > -1, 'the get_ci_opportunities_v1 call site must exist');
  const argsStart = app.indexOf('{', callStart);
  const argsEnd = app.indexOf('})', callStart);
  const argsSrc = app.slice(argsStart, argsEnd + 1);
  const sandbox = { S: { biz: { id: 'biz1' } }, fromDate: '2026-08-01', toDate: '2026-08-31', selectedBranchId: null };
  const context = vm.createContext(sandbox);
  const args = vm.runInContext(`(${argsSrc})`, context);
  assert.equal(args.p_extended, true, 'the executed args object must carry p_extended:true');
});

/* -------------------------------------------------------------------------------------------
   B. Extract the opportunities-panel block and execute it directly, same slice boundaries as
   tests/business-ui/v685-ci-surfaces.test.mjs's own oppStart/oppEnd anchors.
   ------------------------------------------------------------------------------------------- */

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
   Fixture shapes lifted from db/tests/executed/v688_corpus_spine_v2.sql's BIZ1 scenario:
   lapsed_regulars candidate — scenario_cents=30000, expected_value.cents=20889,
   inputs={scored:4,abstained:1}, incentive={kind:'none',declared:true}, cost_basis declared
   (0 cents), >=2 alternatives with exactly one primary (reminder_only, declared cost 0) and one
   'incentive'-kind alternative whose own cost_basis is unavailable. A second candidate
   (package_leakage) carries expected_value.cents=0 with inputs.abstained=5 (every holder
   abstains) — the "0 is a real answer, not a missing one" case. A third candidate (discovery
   domain) carries expected_value {status:'unavailable', reason:...} and scenario_cents=null (an
   association, not an incremental model — no fabricated value).
   ------------------------------------------------------------------------------------------- */

function lapsedRegularsCandidate() {
  return {
    id: 'lapsed_regulars', rank: 1, rank_class: 'quantified', domain: 'cadence',
    pattern: '12 regulars are already overdue against their own rhythm.',
    comparison: { kind: 'threshold', detail: 'overdue vs customer median interval' },
    impact: {
      cents: 30000, reason: null,
      scenario_cents: 30000,
      expected_value: {
        cents: 20889,
        method: 'sum over overdue regulars of app.return_probability_v681(...).probability * avg ticket',
        inputs: { scored: 4, abstained: 1 }
      }
    },
    action: { who: 'the owner', what: 'Contact the 12 overdue regulars this week.', when: 'this week', channel: 'whatsapp' },
    evidence: { source_rpc: 'public.get_ci_cadence_v1', refs: {} },
    evidence_class: 'ASSOCIATION',
    confidence: { n: 12, floor: 5, status: 'ok' },
    limitation: 'Observational, not a controlled experiment.',
    incentive: { kind: 'none', declared: true },
    why_now: '12 customers are already overdue against their OWN rhythm as of 2026-08-31.',
    reversal_condition: 'Reconsider this call if fewer than half of these 12 overdue customers return within 60 days.',
    alternatives: [
      { kind: 'reminder_only', primary: true, what: 'Contact without any discount or credit.',
        cost_basis: { status: 'declared', cents: 0, note: 'no spend' } },
      { kind: 'incentive', primary: false, what: 'Offer a discount or loyalty credit to prompt action.',
        cost_basis: { status: 'unavailable', reason: 'no discount-cost field in this schema' } }
    ],
    cost_basis: { status: 'declared', cents: 0, note: 'a reminder/operational action carries no incentive spend' }
  };
}

function zeroEvCandidate() {
  return {
    id: 'package_leakage:plan_small', rank: 2, rank_class: 'quantified', domain: 'packages',
    pattern: '150 cents of prepaid sessions on "Plan Small" are already unused.',
    comparison: { kind: 'threshold', detail: 'utilisation below floor' },
    impact: {
      cents: 150, reason: null,
      scenario_cents: 150,
      expected_value: { cents: 0, method: 'sum over holders...', inputs: { scored: 0, abstained: 5 } }
    },
    action: { who: 'the owner', what: 'Nudge Plan Small holders to book their remaining sessions.', when: 'this week', channel: 'whatsapp' },
    evidence: { source_rpc: 'public.get_ci_packages_v1', refs: {} },
    evidence_class: 'ASSOCIATION',
    confidence: { n: 5, floor: 5, status: 'ok' },
    limitation: 'Observational.',
    incentive: { kind: 'none', declared: true },
    why_now: '150 cents of prepaid sessions on "Plan Small" are already unused as of 2026-08-31.',
    reversal_condition: 'Reconsider this call if utilisation rises to 60% or above.',
    alternatives: [
      { kind: 'reminder_only', primary: true, what: 'Contact without any discount or credit.',
        cost_basis: { status: 'declared', cents: 0, note: 'no spend' } }
    ],
    cost_basis: { status: 'declared', cents: 0, note: 'a reminder/operational action carries no incentive spend' }
  };
}

function discoveryCandidate() {
  return {
    id: 'discovery:age_gender:F_25_34', rank: 3, rank_class: 'unquantified', domain: 'discovery',
    pattern: 'The "F 25-34" segment differs from the rest by 18 points.',
    comparison: { kind: 'cross_segment', detail: 'train vs rest diff 18 pp; holdout n=40, rate 62%' },
    impact: {
      cents: null, reason: 'an association, not an incremental model: no assumed uplift is smuggled in',
      scenario_cents: null,
      expected_value: { status: 'unavailable', reason: 'no behavioural model backs a discovered association' }
    },
    action: { who: 'the owner', what: 'Look at "F 25-34" specifically.', when: 'this review cycle', channel: 'analysis' },
    evidence: { source_rpc: 'public.get_ci_discovery_v1', refs: { dimension: 'age_gender' } },
    evidence_class: 'ASSOCIATION',
    confidence: { n: 40, floor: 5, status: 'ok' },
    limitation: 'An association, not causal.',
    incentive: { kind: 'none', declared: true },
    why_now: 'The pattern already replicated on holdout data as of 2026-08-31.',
    reversal_condition: 'Reconsider this call if the difference falls back under 18 points on the next holdout split.',
    alternatives: [
      { kind: 'reminder_only', primary: true, what: 'Look into this segment, no spend yet.',
        cost_basis: { status: 'declared', cents: 0, note: 'no spend' } }
    ],
    cost_basis: { status: 'declared', cents: 0, note: 'observation only' }
  };
}

const EXTENDED_PAYLOAD = {
  contract: 'ci_opportunities_v1',
  scope: { business_id: 'b1', branch_id: null, from: '2026-08-01', to: '2026-08-31', currency: 'SGD' },
  time_basis: 'sale_occurred_at',
  ranked: [lapsedRegularsCandidate(), zeroEvCandidate(), discoveryCandidate()],
  abstentions: [],
  comparisons: { subgroups_examined: 14, subgroups_promoted: 3, note: 'Promoted findings were selected from the examined set.' },
  observed_since: '2026-08-01T00:00:00Z',
  report_sections: {
    strengths: [],
    failures: ['lapsed_regulars'],
    leakage: ['package_leakage:plan_small'],
    margin: { status: 'unavailable', reason: 'no COGS/cost-of-goods field on services or sales in this schema' },
    unnoticed_behaviour: ['discovery:age_gender:F_25_34'],
    segments: [],
    change: []
  },
  top_actions: [lapsedRegularsCandidate(), zeroEvCandidate(), discoveryCandidate()]
};

/* -------------------------------------------------------------------------------------------
   B. Expected value / scenario value / reversal / alternative / incentive rendering.
   ------------------------------------------------------------------------------------------- */

test('V696 opportunitiesPanelHtmlV685: expected value renders with scored/abstained counts, distinct from scenario value', () => {
  const html = renderOpportunities(EXTENDED_PAYLOAD);
  assert.ok(html.includes('Expected value'), 'the "Expected value" label must render');
  assert.ok(html.includes('SGD 208.89'), 'expected_value.cents=20889 must render as SGD 208.89');
  assert.ok(html.includes('4 scored'), 'inputs.scored must render');
  assert.ok(html.includes('1 abstained'), 'inputs.abstained must render');
  assert.ok(html.includes('Scenario value'), 'the "Scenario value" label must render, distinct from Expected value');
  assert.ok(html.includes('SGD 300.00'), 'impact.scenario_cents=30000 must render as SGD 300.00');
});

test('V696 opportunitiesPanelHtmlV685: expected_value.cents=0 renders as a real zero, not blank/unavailable', () => {
  const html = renderOpportunities(EXTENDED_PAYLOAD);
  assert.ok(html.includes('SGD 0.00'), 'a genuine zero expected value must render as SGD 0.00');
  assert.ok(html.includes('5 abstained'), 'the package-leakage candidate\'s abstained count must render');
});

test('V696 opportunitiesPanelHtmlV685: an unavailable expected_value renders its honest server-supplied reason, never a computed number', () => {
  const html = renderOpportunities(EXTENDED_PAYLOAD);
  assert.ok(html.includes('no behavioural model backs a discovered association'),
    'the unavailable reason must render verbatim');
});

test('V696 opportunitiesPanelHtmlV685: the reversal condition renders under "What would prove this wrong"', () => {
  const html = renderOpportunities(EXTENDED_PAYLOAD);
  assert.ok(html.includes('What would prove this wrong'));
  assert.ok(html.includes('Reconsider this call if fewer than half of these 12 overdue customers return within 60 days.'));
});

test('V696 opportunitiesPanelHtmlV685: why_now renders', () => {
  const html = renderOpportunities(EXTENDED_PAYLOAD);
  assert.ok(html.includes('Why now'));
  assert.ok(html.includes('12 customers are already overdue against their OWN rhythm as of 2026-08-31.'));
});

test('V696 opportunitiesPanelHtmlV685: "Primary option" shows the primary alternative (v716 additionally lists every alternative elsewhere on the card, see v716-ci-opportunities-impact.test.mjs)', () => {
  const html = renderOpportunities(EXTENDED_PAYLOAD);
  assert.ok(html.includes('Primary option'));
  assert.ok(html.includes('Contact without any discount or credit.'), 'the primary (reminder_only) alternative must render');
});

test('V696 opportunitiesPanelHtmlV685: incentive declaration renders when declared', () => {
  const html = renderOpportunities(EXTENDED_PAYLOAD);
  assert.ok(html.includes('Incentive'));
  assert.ok(html.includes('No incentive'), 'kind:"none" must render a human label, not the raw string "none"');
});

test('V696 opportunitiesPanelHtmlV685: an undeclared incentive renders nothing for the incentive row', () => {
  const undeclared = { ...lapsedRegularsCandidate(), incentive: { kind: 'credit', declared: false } };
  const payload = { ...EXTENDED_PAYLOAD, ranked: [undeclared] };
  const html = renderOpportunities(payload);
  assert.ok(!html.includes('<span>Incentive</span>'), 'an undeclared incentive must not render an incentive row');
});

/* -------------------------------------------------------------------------------------------
   C. report_sections: fixed order, empty-section copy, margin's unavailable reason.
   ------------------------------------------------------------------------------------------- */

test('V696 opportunitiesPanelHtmlV685: report_sections render as collapsible groups in the fixed order', () => {
  const html = renderOpportunities(EXTENDED_PAYLOAD);
  const sections = [...html.matchAll(/data-section="([a-z_]+)"/g)].map((m) => m[1]);
  assert.deepEqual(sections, ['strengths', 'failures', 'leakage', 'margin', 'unnoticed_behaviour', 'segments', 'change']);
  const detailsCount = (html.match(/<details class="ci-report-section"/g) || []).length;
  assert.equal(detailsCount, 7, 'all seven sections must render, even the empty ones');
});

test('V696 opportunitiesPanelHtmlV685: an empty section reads "Nothing surfaced above the evidence floor."', () => {
  const html = renderOpportunities(EXTENDED_PAYLOAD);
  // strengths, segments and change are empty arrays in the fixture.
  const occurrences = (html.match(/Nothing surfaced above the evidence floor\./g) || []).length;
  assert.equal(occurrences, 3, 'strengths, segments and change are the three empty sections in this fixture');
});

test('V696 opportunitiesPanelHtmlV685: margin always renders its unavailable reason, never the empty-section copy', () => {
  const html = renderOpportunities(EXTENDED_PAYLOAD);
  assert.ok(html.includes('no COGS/cost-of-goods field on services or sales in this schema'));
});

test('V696 opportunitiesPanelHtmlV685: non-empty sections list the candidate ids they claim', () => {
  const html = renderOpportunities(EXTENDED_PAYLOAD);
  assert.ok(html.includes('package_leakage:plan_small'), 'leakage section must list its id');
  assert.ok(html.includes('discovery:age_gender:F_25_34'), 'unnoticed_behaviour section must list its id');
});

/* -------------------------------------------------------------------------------------------
   D. top_actions renders at the top of the panel, above the ranked list.
   ------------------------------------------------------------------------------------------- */

test('V696 opportunitiesPanelHtmlV685: top_actions renders above the ranked list', () => {
  const html = renderOpportunities(EXTENDED_PAYLOAD);
  const topActionsIdx = html.indexOf('Top actions');
  const rankedListIdx = html.indexOf('class="ci-opportunities-list"');
  assert.ok(topActionsIdx > -1, 'a "Top actions" heading must render');
  assert.ok(rankedListIdx > -1, 'the ranked list must render');
  assert.ok(topActionsIdx < rankedListIdx, 'top_actions must render above the ranked list');
  assert.ok(html.includes('Contact the 12 overdue regulars this week.'), 'a top action\'s own action.what must render');
});

test('V696 opportunitiesPanelHtmlV685: an empty top_actions array renders nothing extra (no empty heading)', () => {
  const payload = { ...EXTENDED_PAYLOAD, top_actions: [] };
  const html = renderOpportunities(payload);
  assert.ok(!html.includes('Top actions'), 'an empty top_actions array must not render a hollow heading');
});

/* -------------------------------------------------------------------------------------------
   E. No invented numbers: every "SGD X.XX" figure in the HTML must trace to a cents value
   literally present in the fixture (impact.cents / scenario_cents / expected_value.cents).
   ------------------------------------------------------------------------------------------- */

test('V696 opportunitiesPanelHtmlV685: no cents figure appears in the HTML that is not in the fixture', () => {
  const html = renderOpportunities(EXTENDED_PAYLOAD);
  const fixtureCents = new Set();
  for (const item of EXTENDED_PAYLOAD.ranked) {
    const i = item.impact || {};
    if (i.cents !== null && i.cents !== undefined) fixtureCents.add(Number(i.cents));
    if (i.scenario_cents !== null && i.scenario_cents !== undefined) fixtureCents.add(Number(i.scenario_cents));
    if (i.expected_value && i.expected_value.cents !== null && i.expected_value.cents !== undefined) {
      fixtureCents.add(Number(i.expected_value.cents));
    }
  }
  const renderedAmounts = [...html.matchAll(/SGD (-?[\d,]+\.\d{2})/g)].map((m) => Math.round(parseFloat(m[1].replace(/,/g, '')) * 100));
  assert.ok(renderedAmounts.length > 0, 'at least one money figure must render');
  for (const cents of renderedAmounts) {
    assert.ok(fixtureCents.has(cents), `rendered SGD amount for ${cents} cents does not trace back to any fixture cents field`);
  }
});

test('V696 opportunitiesPanelHtmlV685: a missing/malformed extended payload still renders without crashing', () => {
  const minimal = { ...EXTENDED_PAYLOAD, ranked: [{ id: 'x', rank: 1, rank_class: 'quantified', action: {}, confidence: {}, impact: {} }] };
  assert.doesNotThrow(() => renderOpportunities(minimal));
  const html = renderOpportunities(minimal);
  assert.ok(!html.includes('undefined'), 'a candidate missing every extended field must never render the literal string "undefined"');
});
