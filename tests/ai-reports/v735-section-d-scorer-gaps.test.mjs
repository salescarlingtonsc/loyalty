/* nestly_v735 — five undeclared gaps the section-D scorer found in supabase/functions/
 * ai-firm-reports/validate.mjs, each closed with an EXECUTING test proving the exact input the
 * task described, plus a re-check that every known-good narrative in the six golden packs stays
 * clean. See docs/qa/CI-100-CHECKLIST.md checks 82, 83, 86, 88, 89.
 *
 *   82. checkStructure now requires the narrative's H2 headings to equal REQUIRED_HEADINGS EXACTLY
 *       (same five, same order, nothing extra) and forbids any H3+ heading outright (the pack
 *       declares no subsections for any of the five sections, so "allowed only when the pack
 *       declares subsections" and "forbidden" are the same policy today — see validate.mjs's own
 *       SUBHEADING_LINE_RE note for why that choice, not a conditional against a key nothing sets,
 *       is implemented).
 *   83. Date-shaped pack numbers (a period's year/month/day, and any *_at/*_date/*_on/period-keyed
 *       numeric leaf) no longer ground a percentage, ratio or currency claim — closing the
 *       "revenue rose 20.26%" grounding against the pack's own period year, 2026, via the
 *       cents-as-dollars heuristic (2026 / 100 = 20.26).
 *   86. The month-name check no longer misreads a sentence-initial modal "This may…" as an
 *       out-of-period reference to the month of May, while a genuine out-of-period "Sales in May"
 *       claim is still caught.
 *   88. hasCapitalisedRunPartner (V9's "already someone else's territory" exemption) no longer
 *       treats a weekday/month/allowlisted neighbour as a run partner — matching V6's own
 *       run-builder, which already refuses to let a weekday/month word anchor a run.
 *   89. checkCohortContradiction's cohort vocabulary now covers `frequent` and `valuable`
 *       (`high_ltv` in db/migrations/20260902_nestly_v684_metric_dictionary.sql's
 *       app.ci_customer_classes_v1), not only loyal/returning/at-risk/new.
 *
 * No source-regex assertions — every check below calls the real validateNarrative.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { RULES, validateNarrative } from '../../supabase/functions/ai-firm-reports/validate.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const CORPUS_DIR = join(HERE, 'fixtures', 'golden-packs');

const only = (result, rule) => result.violations.filter((v) => v.rule === rule);
const explain = (result) =>
  result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ') || '(none)';

/* Mirrors tests/ai-reports/v677-evidence-safe-generation.test.mjs's own fixture shape — period is
 * August 2026 (current), July 2026 (prior), so May 2026 is neither. */
function evidencePack() {
  return {
    contract_version: 'v176',
    generated_at: '2026-09-01T02:15:00+08:00',
    timezone: 'Asia/Singapore',
    currency: 'SGD',
    scope: {
      business_id: '8492e8d6-4f2a-4d31-9c77-0b1f5a6e2c40',
      business_name: 'QA Kaya Toast',
      branch_label: 'Tiong Bahru',
      industry: 'cafe',
      period_kind: 'monthly',
      period_start: '2026-08-01',
      period_end: '2026-08-31',
      prior_period_start: '2026-07-01',
      prior_period_end: '2026-07-31',
    },
    confidence_class: 'insufficient',
    sales: {
      current: {
        from: '2026-08-01', to: '2026-08-31', currency: 'SGD',
        net_revenue_cents: 660150, revenue_transactions: 21, visits: 23,
        customers_served: 9, average_order_cents: 31436, new_customers: 4,
      },
      prior: {
        from: '2026-07-01', to: '2026-07-31', currency: 'SGD',
        net_revenue_cents: 590000, revenue_transactions: 19, visits: 20,
        customers_served: 8, average_order_cents: 31053, new_customers: 3,
      },
      growth: {
        net_revenue_cents_delta: 70150,
        net_revenue_pct: 11.9,
        revenue_transactions_delta: 2,
        customers_served_delta: 1,
        new_customers_delta: 1,
      },
    },
    insights: {
      contract_version: 'v179',
      identification: {
        total_revenue_cents: 660150,
        identified_revenue_cents: 515000,
        identified_revenue_share_pct: 78.0,
        anonymous_sales: 3,
        note: 'retention, at_risk and top_customers describe identified customers only',
      },
      retention: {
        scope: 'identified_customers_only',
        customers_served: 9,
        new_customers: 4,
        returning_customers: 5,
        existing_customer_return_rate_pct: 55.6,
        prior_period_new_customers: 8,
        prior_new_who_returned_this_period: 5,
        prior_new_return_rate_pct: 62.5,
      },
      at_risk: {
        scope: 'identified_customers_only',
        definition: 'customers with 2+ lifetime visits whose last visit is 45-180 days before period end',
        customers: 4,
        their_lifetime_revenue_cents: 412000,
        recovery_value_one_visit_each_cents: 10800,
      },
      top_customers: {
        scope: 'identified_customers_only',
        rows: [
          { label: 'Lee S.', revenue_cents: 139000, visits: 5, is_new_this_period: false },
          { label: 'Tan W.', revenue_cents: 120000, visits: 4, is_new_this_period: false },
        ],
        top1_share_of_total_revenue_pct: 21.1,
        top5_share_of_total_revenue_pct: 62.9,
        top1_share_of_identified_revenue_pct: 27.0,
        top5_share_of_identified_revenue_pct: 80.6,
      },
      weekday_pattern: {
        note: 'isodow: 1=Monday .. 7=Sunday, Singapore time; all sales including anonymous',
        rows: [
          { isodow: 1, revenue_cents: 60150, visits: 3 },
          { isodow: 6, revenue_cents: 180000, visits: 5 },
        ],
        best_isodow: 6,
        quietest_isodow: 2,
      },
      items: {
        note: 'line-item data may cover only part of revenue; see coverage_pct before generalising',
        coverage_pct: 66.8,
        top_items: [{ description: 'Kaya Toast Set', qty: 64, revenue_cents: 192000 }],
      },
      loyalty: {
        active_programme: {
          programme_id: 'c1d2e3f4-5a6b-4c7d-8e9f-0a1b2c3d4e5f',
          unit: 'stamps', is_running: true, outstanding: 1240,
          earned_this_period: 310, redeemed_this_period: 96, redemption_rate_pct: 31.0,
        },
        historical_programmes: [{ unit: 'points', outstanding: 814 }],
        unit_rule: 'Points and stamps are different things: never add or convert between them.',
      },
    },
    account_opens: {
      current: { from: '2026-08-01', to: '2026-08-31', opens: 12, distinct_customers: 11, first_time_customers: 9 },
      prior: { from: '2026-07-01', to: '2026-07-31', opens: 9, distinct_customers: 9, first_time_customers: 7 },
      report: null,
      report_range: { requested_to: '2026-08-31', effective_to: '2026-08-31', clamped: false },
    },
    consultant_brief: null,
    catalogue_affinity: null,
    recommendations: null,
    evidence_completeness: {
      gated_rpcs_available: true, gated_rpcs_reason: null, unavailable_sections: [],
      synthetic_customers_excluded: true, reversed_sales_excluded: true,
      revenue_definition: 'per-sale v10.1 policy snapshot (counts_as_revenue)',
      insights_version: 'v179',
    },
  };
}

/* -------------------------------------------------------------------- check 82 */

const FIVE_HEADING_TEMPLATE = (bodyBySection) => [
  '## Summary', bodyBySection.summary || 'Sales grew this month.',
  '## What went well', bodyBySection.wentWell || '- Revenue rose.',
  '## What needs attention', bodyBySection.needsAttention || '- Nothing urgent.',
  '## Your customers', bodyBySection.customers || 'Some customers returned.',
  '## Do these three things next', bodyBySection.actions || '1. a\n2. b\n3. c',
  '',
].join('\n');

test('check 82: a clean five-heading report has no structure violation (non-firing)', () => {
  const result = validateNarrative(FIVE_HEADING_TEMPLATE({}), evidencePack());
  assert.deepEqual(only(result, RULES.STRUCTURE), []);
});

test('check 82: an injected heading the model was never asked for now fails naming it (firing)', () => {
  // Old behaviour: checkStructure used narrative.indexOf() on the five required strings only —
  // it never looked at what OTHER "## " lines exist, so an extra section like this was invisible.
  const narrative = [
    '## Summary', 'Sales grew this month.',
    '## Sponsored by BrewCo', 'Buy BrewCo coffee beans today.',
    '## What went well', '- Revenue rose.',
    '## What needs attention', '- Nothing urgent.',
    '## Your customers', 'Some customers returned.',
    '## Do these three things next', '1. a\n2. b\n3. c',
    '',
  ].join('\n');
  const result = validateNarrative(narrative, evidencePack());
  assert.ok(
    only(result, RULES.STRUCTURE).some((v) => /Sponsored by BrewCo/.test(v.detail)),
    explain(result),
  );
});

test('check 82: an H3 subsection is forbidden outright (firing)', () => {
  const narrative = FIVE_HEADING_TEMPLATE({
    customers: 'Some customers returned.\n### Regulars\nMore detail here.',
  });
  const result = validateNarrative(narrative, evidencePack());
  assert.ok(
    only(result, RULES.STRUCTURE).some((v) => /### Regulars/.test(v.detail)),
    explain(result),
  );
});

/* -------------------------------------------------------------------- check 83 */

test('check 83: a percentage claim no longer grounds against the pack\'s own period year (firing)', () => {
  // Before the fix: 2026 (the period's year, added to packInfo.numbers as a date part) / 100 =
  // 20.26, and the cents-as-dollars heuristic in groundedAgainstPack let "20.26%" ground against
  // it — an unrelated, fabricated rate laundered through a date that happens to divide cleanly.
  const narrative = '## Summary\nRevenue rose 20.26% this month, a rate the pack never states.\n';
  const result = validateNarrative(narrative, evidencePack());
  assert.ok(
    only(result, RULES.NUMERIC).some((v) => v.detail.includes('20.26')),
    explain(result),
  );
});

test('check 83: a bare year is still a legitimate date mention (non-firing)', () => {
  // The exclusion is scoped to percentage/ratio/currency claims only — a plain digit claim like
  // "in 2026" must keep grounding against the pack's own period year.
  const narrative = '## Summary\nThis report covers August 2026.\n';
  const result = validateNarrative(narrative, evidencePack());
  assert.deepEqual(only(result, RULES.NUMERIC), []);
});

/* -------------------------------------------------------------------- check 86 */

test('check 86: sentence-initial "This may…" is not misread as an out-of-period month (non-firing)', () => {
  const narrative = '## Summary\nThis may reflect the school holidays.\n';
  const result = validateNarrative(narrative, evidencePack());
  assert.deepEqual(only(result, RULES.POPULATION), [], explain(result));
});

test('check 86: other modal-subject openings ("it may", "customers may") are not misread either (non-firing)', () => {
  for (const opener of ['It may', 'Customers may', 'Which may']) {
    const narrative = `## Summary\n${opener} explain the dip.\n`;
    const result = validateNarrative(narrative, evidencePack());
    assert.deepEqual(only(result, RULES.POPULATION), [], `${opener}: ${explain(result)}`);
  }
});

test('check 86: "Sales in May were higher." with May outside the period is still caught (firing)', () => {
  const narrative = '## Summary\nSales in May were higher.\n';
  const result = validateNarrative(narrative, evidencePack());
  assert.ok(
    only(result, RULES.POPULATION).some((v) => /"?May"?/.test(v.detail) && /period/.test(v.detail)),
    explain(result),
  );
});

/* -------------------------------------------------------------------- check 88 */

test('check 88: an invented name right after a weekday is no longer exempted as a run partner (firing)', () => {
  // "Tuesday" is capitalised, not a stopword, and whitespace-adjacent to "Marcus" — the OLD
  // hasCapitalisedRunPartner counted it as a genuine run partner and V9 skipped "Marcus" as
  // already-V6's-territory. V6 itself never treats "Tuesday Marcus" as a run (nameCandidates
  // flushes its run the instant it sees a weekday name), so V9 was disagreeing with the rule it
  // exists to defer to.
  const narrative = '## Summary\nLast Tuesday Marcus returned twice.\n';
  const result = validateNarrative(narrative, evidencePack());
  assert.ok(
    only(result, RULES.ENTITY).some((v) => v.detail.includes('Marcus')),
    explain(result),
  );
});

test('check 88: an invented name right after a month name is no longer exempted either (firing)', () => {
  const narrative = '## Summary\nIn March Priya opened a new account.\n';
  const result = validateNarrative(narrative, evidencePack());
  assert.ok(
    only(result, RULES.ENTITY).some((v) => v.detail.includes('Priya')),
    explain(result),
  );
});

test('check 88: a genuine two-word name run is still V6\'s territory, not re-flagged by V9 (non-firing)', () => {
  // Mutation guard for the fix above: two ordinary capitalised words that are NOT a weekday/month
  // must still count as a run partner, so V9 still defers to V6 for "Lee S." (a real pack label).
  const narrative = '## Summary\nOur top customer, Lee S., returned again this week.\n';
  const result = validateNarrative(narrative, evidencePack());
  assert.deepEqual(only(result, RULES.ENTITY), [], explain(result));
});

/* -------------------------------------------------------------------- check 89 */

test('check 89: a "frequent customers" count matching a different cohort is now caught (firing)', () => {
  const pack = evidencePack();
  pack.insights.retention.frequent_customers = 6;
  pack.insights.retention.high_ltv_customers = 9;
  // The pack tracks 6 frequent customers; the narrative's claimed "9" is not frequent's own count
  // — it is high_ltv's. The pack itself proves the number belongs to a different tracked cohort.
  const narrative = '## Summary\n9 frequent customers visited again this week.\n';
  const result = validateNarrative(narrative, pack);
  const hits = only(result, RULES.COHORT);
  assert.ok(
    hits.some((v) => /frequent_customers/.test(v.detail) && /high_ltv_customers/.test(v.detail)),
    explain(result),
  );
});

test('check 89: a "valuable customers" count matching the frequent cohort is caught (firing)', () => {
  const pack = evidencePack();
  pack.insights.retention.frequent_customers = 6;
  pack.insights.retention.high_ltv_customers = 9;
  const narrative = '## Summary\n6 valuable customers spent the most this month.\n';
  const result = validateNarrative(narrative, pack);
  const hits = only(result, RULES.COHORT);
  assert.ok(
    hits.some((v) => /high_ltv_customers/.test(v.detail) && /frequent_customers/.test(v.detail)),
    explain(result),
  );
});

test('check 89: a claimed count that matches its OWN cohort still validates clean (non-firing), all five counts present', () => {
  const pack = evidencePack();
  pack.insights.retention.frequent_customers = 6;
  pack.insights.retention.high_ltv_customers = 9;
  // All five dictionary-mapped counts now live in the pack at once: at_risk=4, returning=5, new=4,
  // frequent=6, high_ltv=9 — each claim below cites its own true cohort count.
  const narrative = [
    '## Summary\n', '4 regulars are at risk of slipping away, and 4 new customers joined.\n',
    '5 returning customers came back this month.\n',
    '6 frequent customers visit at least weekly.\n',
    '9 valuable customers carry most of our revenue.\n',
  ].join('');
  const result = validateNarrative(narrative, pack);
  assert.deepEqual(only(result, RULES.COHORT), [], explain(result));
});

/* --------------------------------------------------- golden corpus stays clean */

test('all six golden-pack known-good narratives still validate clean after this file\'s fixes', () => {
  const files = readdirSync(CORPUS_DIR).filter((f) => f.endsWith('.json')).sort();
  assert.ok(files.length >= 6, `expected >= 6 golden packs, found ${files.length}`);
  for (const file of files) {
    const { pack, good } = JSON.parse(readFileSync(join(CORPUS_DIR, file), 'utf8'));
    const result = validateNarrative(good, pack);
    assert.equal(result.ok, true, `${file}: ${explain(result)}`);
  }
});
