/* nestly_v826 — the owner brief header on the Home dashboard.

   The sentence builder (ownerBriefLinesV826) is EXTRACTED from app/app.js and EXECUTED against
   real snapshot payloads captured from production on 2026-09-08 (rolled-back run of
   app.refresh_owner_brief_v826), so the test proves what the owner reads, not that a string
   exists in the source. The three payload shapes the server can produce are covered: a business
   with enough history (Cubbly), one without (ÉLAN), and a reader that refused. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const index = readFileSync(join(root, 'app', 'index.html'), 'utf8');
const registry = JSON.parse(readFileSync(join(root, 'docs', 'design', 'ps0', 'writer-registry.json'), 'utf8'));

function extractFunction(src, name) {
  const m = new RegExp(`^(?:async )?function ${name}\\(`, 'm').exec(src);
  assert.ok(m, `extractFunction: missing function ${name}`);
  const acc = [];
  for (const line of src.slice(m.index).split('\n')) {
    acc.push(line);
    if (line === '}') return acc.join('\n');
  }
  throw new Error(`extractFunction: no column-0 closing brace found for ${name}`);
}

function builder() {
  const ctx = { money: (c) => `SGD ${((c || 0) / 100).toFixed(2)}` };
  vm.createContext(ctx);
  for (const name of ['ownerBriefHourV826', 'ownerBriefPctV826', 'ownerBriefSignedV826', 'ownerBriefLinesV826']) {
    vm.runInContext(extractFunction(app, name), ctx);
  }
  return (brief) => vm.runInContext('ownerBriefLinesV826', ctx)(brief);
}

/* nestly_v828 — same extraction approach, plus ownerBriefAnswersV828 itself, which calls
   ownerBriefLinesV826 internally to reuse six of its sentences. */
function answersBuilder() {
  const ctx = { money: (c) => `SGD ${((c || 0) / 100).toFixed(2)}` };
  vm.createContext(ctx);
  for (const name of ['ownerBriefHourV826', 'ownerBriefPctV826', 'ownerBriefSignedV826', 'ownerBriefLinesV826', 'ownerBriefAnswersV828']) {
    vm.runInContext(extractFunction(app, name), ctx);
  }
  // JSON round-trip: the vm context is a different realm, so its arrays/objects fail
  // assert.deepEqual's reference checks even when structurally identical. Every value here is
  // JSON-safe (strings/numbers/booleans/null), so the round-trip is lossless.
  return (brief) => JSON.parse(JSON.stringify(vm.runInContext('ownerBriefAnswersV828', ctx)(brief)));
}

/* Captured 2026-09-08 from the rolled-back production run (Cubbly SPA, three outlets, one with
   evidence). Figures are the demo tenant's own. */
const cubbly = {
  contract_version: 'owner_brief_v826',
  as_of: '2026-09-07',
  week: { status: 'ok', from: '2026-09-01', to: '2026-09-07', revenue_cents: 27500, visits: 4, basket_cents: 6875,
    new_customers: 5, baseline: { weeks: 8, revenue_cents: 79729, visits: 4.3, basket_cents: 18760, evidence: 'ok' },
    revenue_delta_pct: -65.5, visits_delta_pct: -5.9, basket_delta_pct: -63.4, driver: 'basket' },
  outlets: { status: 'ok', best: { name: 'Cubbly · Orchard', revenue_delta_pct: -65.5 }, worst: null,
    outlets: [{ name: 'Cubbly · Orchard', revenue_delta_pct: -65.5, evidence: 'ok' }, { name: 'Kopitiam 2', revenue_delta_pct: null, evidence: 'insufficient' }] },
  daypart: { status: 'ok', evidence: 'ok', busiest_weekday: { dow: 1, label: 'Monday', visits: 21 },
    slowest_weekday: { dow: 4, label: 'Thursday', visits: 5, visits_per_occurrence_pct: 55.6 },
    quietest_hours: { start_hour: 14, end_hour: 17, visits: 3, share_pct: 3.4 } },
  customers: { status: 'ok', new_customers: 3, returning_customers: 1, repeat_in_period_rate_pct: 0 },
  at_risk: { status: 'ok', overdue: 0, due: 0, slipping: 0, considered: 2, monthly_at_risk_cents: 0 },
  rewards: { status: 'ok', redemptions: 16, redeeming_customers: 4, eligible_customers: 9,
    top: { name: 'Free Lotion', redemptions: 7, evidence: 'insufficient' }, ignored_active: 2 },
  action: { status: 'ok', data_status: 'not_computed', top_action: null, last_result: null },
};

/* ÉLAN Wellness: one outlet, eight-week baseline below the evidence floor. */
const elan = {
  contract_version: 'owner_brief_v826',
  as_of: '2026-09-07',
  week: { status: 'ok', revenue_cents: 95000, visits: 5, basket_cents: 19000, new_customers: 5,
    baseline: { weeks: 8, revenue_cents: 4813, visits: 1.5, basket_cents: 3208, evidence: 'insufficient' },
    revenue_delta_pct: null, visits_delta_pct: null, basket_delta_pct: null, driver: null },
  outlets: { status: 'single_outlet' },
  daypart: { status: 'ok', evidence: 'insufficient', busiest_weekday: { dow: 1, label: 'Monday', visits: 12 },
    slowest_weekday: { dow: 2, label: 'Tuesday', visits: 6 }, quietest_hours: null },
  customers: { status: 'ok', new_customers: 4, returning_customers: 1 },
  at_risk: { status: 'ok', overdue: 0, slipping: 1, monthly_at_risk_cents: 174656 },
  rewards: { status: 'ok', redemptions: 2, top: { name: 'Head & Shoulder Release', redemptions: 2 }, ignored_active: 2 },
  action: { status: 'ok', data_status: 'not_computed', top_action: null },
};

test('v826: a business with history reads its week against a normal week, with the driver named', () => {
  const lines = builder()(cubbly);
  const texts = lines.map((l) => l.text);
  assert.equal(texts[0], 'Last 7 days: SGD 275.00, 66% below a normal week (SGD 797.29). Smaller orders, not fewer people.');
  assert.equal(lines[0].kind, 'warn');
  assert.ok(texts.includes('Cubbly · Orchard: 66% below its normal week. The other outlets have too little history to compare.'));
  assert.ok(texts.includes('Busiest day Monday, slowest Thursday, quietest stretch 2pm–5pm (3% of visits).'));
  assert.ok(texts.includes('3 new customers, 1 returning.'));
  assert.ok(texts.includes('No regulars overdue their usual visit.'));
  assert.ok(texts.includes('Most redeemed reward: Free Lotion (7 in 8 weeks). 2 active rewards were never redeemed.'));
  assert.equal(lines.length, 6, 'no line is invented for a null top action');
});

test('v826: a business without history is told so, never handed a percentage', () => {
  const lines = builder()(elan);
  const texts = lines.map((l) => l.text);
  assert.equal(texts[0], 'Last 7 days: SGD 950.00 from 5 visits. Not enough history yet to say what a normal week looks like.');
  assert.ok(!texts.some((t) => /%/.test(t) && /normal week/.test(t)), 'no delta against an insufficient baseline');
  assert.ok(texts.includes('Busiest day Monday, slowest Tuesday.'), 'no quiet-hours clause without evidence');
  assert.ok(texts.includes('1 regular is overdue their usual visit (SGD 1746.56 a month at stake).'));
  assert.ok(!texts.some((t) => /outlet/i.test(t)), 'a single outlet has no outlet line');
});

test('v826: a reader the server marked unavailable is left out, not guessed', () => {
  const lines = builder()({ ...cubbly, week: { status: 'unavailable', reason: 'x' }, daypart: { status: 'unavailable' }, rewards: { status: 'unavailable' } });
  const texts = lines.map((l) => l.text);
  assert.equal(texts[0], 'Last 7 days could not be prepared.');
  assert.ok(!texts.some((t) => /Busiest|reward/i.test(t)));
  assert.equal(builder()(null).length, 0);
});

test('v826: a two-outlet business names who carried the week and who is dragging', () => {
  const lines = builder()({ ...cubbly, outlets: { status: 'ok', best: { name: 'Tampines', revenue_delta_pct: 11.2 }, worst: { name: 'Bedok', revenue_delta_pct: -9.4 } } });
  assert.ok(lines.map((l) => l.text).includes('Tampines carried the week (+11%). Bedok is dragging (−9%).'));
});

test('v826: the card is wired — markup under the title bar, one read per session, registered', () => {
  const dash = app.slice(app.indexOf('async function dashboard(){'));
  assert.ok(dash.indexOf('id="dashboardBrief"') < dash.indexOf('dashboard-schedule-glance'), 'the brief sits above the schedule glance');
  assert.ok(/loadOwnerBriefV826\(dashboardRoot\)/.test(dash), 'the dashboard loads the brief on first paint');
  const loader = extractFunction(app, 'loadOwnerBriefV826');
  assert.match(loader, /sb\.rpc\('get_owner_brief_v1',\{p_business:S\.biz\.id\}\)/);
  assert.match(loader, /ownerBriefCacheV826\.key===key/, 'the response is cached per business per Singapore day');
  assert.equal((app.match(/sb\.rpc\('get_owner_brief_v1'/g) || []).length, 1, 'exactly one call site');
  assert.ok(index.includes('.dashboard-brief-v826{'), 'the card has its style');
  assert.ok(registry.allowlist.some((w) => w.id === 'browser.rpc:app/app.js:get_owner_brief_v1'), 'registered in the writer-registry allowlist, beside get_reports_summary');
});

/* nestly_v828 — ownerBriefAnswersV828. `facts` below are the REAL Cubbly SPA numbers pinned in
   scratchpad/v828/{money,items,people,ahead}/*.RESULT.md (rolled-back production probes,
   captured 2026-09-08), not invented figures. Grouped into the 7 "Ask My Business" worries. */
const cubblyFacts = {
  day: { status: 'ok', source: 'public.get_dashboard_summary_v155',
    yesterday: { date: '2026-09-07', weekday_label: 'Monday', revenue_cents: 0, visits: 0 },
    baseline: { weeks: 8, revenue_cents: 9813, visits: null, evidence: 'insufficient' },
    revenue_delta_pct: null },
  month: { status: 'ok', source: 'app.v176_sales_window',
    mtd: { from: '2026-09-01', to: '2026-09-07', revenue_cents: 27500 },
    previous_month_same_days: { from: '2026-08-01', to: '2026-08-07', revenue_cents: 61000 },
    revenue_delta_pct: -54.9, days_elapsed: 7, days_in_month: 30, on_pace_cents: 117857 },
  liability: { status: 'ok', as_of: '2026-09-07', credit_liability_cents: 0, gift_card_liability_cents: 5000,
    stored_value_liability_cents: null, unredeemed_reward_grants: { count: 0 }, known_cents_total: 5000 },
  points_expiry: { status: 'ok', source: 'public.points_ledger', from: '2026-06-10', to: '2026-09-07',
    earned_points: 82581, expired_points: 0, expired_pct_of_earned: 0, evidence: 'ok' },
  items: { status: 'ok', evidence: 'ok', from: '2026-07-14', to: '2026-09-07', lines_seen: 100,
    top_by_revenue: [
      { name: 'package sold: 5x facial', item_type: 'package', units: 1, revenue_cents: 160000, margin_cents: null },
      { name: 'facial', item_type: 'service', units: 19, revenue_cents: 159000, margin_cents: null },
      { name: 'spa', item_type: 'service', units: 14, revenue_cents: 144000, margin_cents: null },
    ],
    top_by_margin: [], cost_known_revenue_pct: 0 },
  dying: { status: 'ok', evidence: 'ok', current_from: '2026-08-11', current_to: '2026-09-07', lines_seen: 99,
    dying_items: [{ name: 'package sold: 5x spa session', current_28d_cents: 0, baseline_mean_28d_cents: 20000, decline_pct: 100, lost_revenue_cents: 20000 }] },
  pairs: { status: 'ok', evidence: 'insufficient', from: '2026-07-14', to: '2026-09-07', multi_line_sales_seen: 12, top_pairs: null },
  discounts: { status: 'ok', evidence: 'insufficient', from: '2026-07-14', to: '2026-09-07', discount_lines_seen: 0, total_discount_cents: null, staff: null, staff_note: null, by_rule: null },
  stock: { status: 'ok', evidence: 'insufficient', products_with_stock_tracking: 0, running_out: null },
  staff: { status: 'ok', evidence: 'ok', from: '2026-07-14', to: '2026-09-07', weeks: 8, sales_with_staff_attribution: 45,
    hours_basis: 'weekly pattern x 8',
    staff: [
      { staff_id: 'chuan', name: 'Chuan', rostered_hours: 432, revenue_cents: 189230, sales: 44, items_per_sale: 1.0, revenue_per_rostered_hour_cents: 438 },
      { staff_id: 'kelvin', name: 'Kelvin', rostered_hours: 432, revenue_cents: 200, sales: 1, items_per_sale: 1.0, revenue_per_rostered_hour_cents: 0 },
      { staff_id: 'devi', name: 'Devi', rostered_hours: 432, revenue_cents: 0, sales: 0, items_per_sale: null, revenue_per_rostered_hour_cents: 0 },
    ],
    quiet_overlap: { status: 'ok', most_overstaffed_block: { block: '9-12', staff_rostered: 144, sales: 1, staff_per_sale: 144 } } },
  multi_outlet: { status: 'ok', source: 'public.sales + app.ci_visit_day_v699', from: '2026-03-12', to: '2026-09-07',
    branches: 2, identified_customers: 9, multi_outlet_customers: 0, multi_outlet_share_pct: 0.0,
    mean_visit_days_multi_outlet: null, mean_visit_days_single_outlet: 4.1 },
  birthdays: { status: 'ok', month: 9, year: 2026, birthday_clients_this_month: 1, granted_this_month: 0, redeemed_this_month: 0 },
  member_lift: { status: 'no_memberships', source: 'public.memberships' },
  referrals: { status: 'ok', source: 'public.referrals', from: '2026-06-10', to: '2026-09-07', evidence: 'insufficient', referred_customers: 0 },
  anomalies: { status: 'ok', from: '2026-07-14', to: '2026-09-07', flags: 1,
    rule_a_redemption_burst: { count: 1, examples: [{ client_id: '268cb96d', day: '2026-08-21', count: 4 }] },
    rule_b_staff_concentration: { flagged: false, total_redemptions: 5, top: { actor: 'x', staff_name: 'Chuan', count: 5, share_pct: 100 }, evidence: 'insufficient' },
    rule_c_multi_branch_same_day: { count: 0, examples: [] } },
  stamps: { status: 'ok', source: 'public.points_ledger + public.stamp_cycles', from: '2026-06-10', to: '2026-09-07',
    cycles_started: 9, cycles_completed: 4, completion_pct: 44.4, evidence: 'ok', dropoff_stamp: null },
  bookings_ahead: { status: 'ok', source: 'public.appointments',
    next_7_days: { from: '2026-09-08', to: '2026-09-14', bookings: 0 },
    same_week_last_year: { from: '2025-09-08', to: '2025-09-14', bookings: 0, delta_pct: null },
    same_days_last_week: { from: '2026-09-01', to: '2026-09-07', bookings: 2, delta_pct: -100 } },
  memberships_due: { status: 'no_memberships', source: 'public.memberships' },
  slot_trend: { status: 'ok', source: 'public.get_ci_daypart_v1',
    reference_weekday: { dow: 0, label: 'Sunday', chosen_from: 'weeks 1-4' },
    windows: {
      weeks_1_4: { from: '2026-08-11', to: '2026-09-07', total_visits: 49, reference_weekday_share_pct: 14.3, evidence: 'ok' },
      weeks_5_8: { from: '2026-07-14', to: '2026-08-10', total_visits: 0, reference_weekday_share_pct: null, evidence: 'insufficient' },
      weeks_9_12: { from: '2026-06-16', to: '2026-07-13', total_visits: 0, reference_weekday_share_pct: null, evidence: 'insufficient' },
    },
    trend: null },
};
const cubblyWithFacts = { ...cubbly, facts: cubblyFacts };

/* Every fact set to `{status:'unavailable'}` — the server-side reader threw for all 19. */
const allUnavailableFacts = Object.fromEntries(
  ['day', 'month', 'liability', 'points_expiry', 'items', 'dying', 'pairs', 'discounts', 'stock', 'staff',
    'multi_outlet', 'birthdays', 'member_lift', 'referrals', 'anomalies', 'stamps', 'bookings_ahead',
    'memberships_due', 'slot_trend'].map((k) => [k, { status: 'unavailable', reason: 'x' }]),
);
const briefAllUnavailable = { ...cubbly, facts: allUnavailableFacts };

/* Every "does not apply to this business" status the fact functions can return. */
const notApplicableFacts = {
  ...cubblyFacts,
  multi_outlet: { status: 'single_outlet', source: 'public.branches', branches: 1 },
  member_lift: { status: 'no_memberships', source: 'public.memberships' },
  stamps: { status: 'no_stamp_card', source: 'public.business_programmes' },
  bookings_ahead: { status: 'no_appointments', source: 'public.appointments' },
  memberships_due: { status: 'no_memberships', source: 'public.memberships' },
};
const briefNotApplicable = { ...cubbly, facts: notApplicableFacts };

test('v828: real Cubbly figures group into the 7 worries, in order, with specific sentences', () => {
  const groups = answersBuilder()(cubblyWithFacts);
  assert.deepEqual(groups.map((g) => g.worry), [
    'Am I okay?',
    'When am I busy, when am I dead?',
    'What sells, what should I stop making?',
    'Who am I losing?',
    'Is the loyalty programme worth it?',
    'Is my team performing?',
    'What is coming that I should prepare for?',
  ]);
  const flat = groups.flatMap((g) => g.items);
  const byQuestion = (q) => flat.find((i) => i.question === q);

  const day = byQuestion('How did we do yesterday? Is that normal?');
  assert.equal(day.answer, 'Yesterday (Monday) was SGD 0.00. Not enough history yet to say what a normal Monday looks like.');
  assert.equal(day.kind, 'plain');

  const month = byQuestion('This month so far, am I ahead or behind?');
  assert.equal(month.answer, 'Day 7 of the month: SGD 275.00 versus SGD 610.00 at this point last month, 55% below last month. On pace for SGD 1178.57 this month.');
  assert.equal(month.kind, 'warn');

  const items = byQuestion('Top ten by revenue. Now top ten by profit.');
  assert.equal(items.answer, 'Top seller by revenue: package sold: 5x facial (SGD 1600.00). Margin is unknown — no item in your catalogue has a cost price set yet.');
  assert.equal(items.kind, 'warn');

  const staff = byQuestion('Sales per staff, per shift, fair to the hours they worked?');
  assert.equal(staff.answer, 'Chuan earns the most per rostered hour (SGD 4.38); Devi is rostered 432 hours with 0 sales in the window.');
  assert.equal(staff.kind, 'warn');

  const anomalies = byQuestion('Is anyone gaming it?');
  assert.equal(anomalies.answer, '1 flag raised: 1 case of a customer redeeming 3+ rewards in one day.');
  assert.equal(anomalies.kind, 'warn');

  const stamps = byQuestion('How many stamp cards get finished?');
  assert.equal(stamps.answer, '4 of 9 stamp cards started in the last 90 days were completed (44.4%).');
  assert.equal(stamps.kind, 'plain');

  // Insufficient-evidence facts are present as a muted "not enough history" line, not omitted.
  const pairs = byQuestion('What do people buy together?');
  assert.equal(pairs.answer, 'Not enough history yet.');
  assert.equal(pairs.kind, 'muted');

  // Both member_lift and memberships_due read status:'no_memberships' for Cubbly (per
  // people.RESULT.md / ahead.RESULT.md — production holds zero membership rows for this
  // tenant), so both questions are entirely absent, not answered with a hollow zero.
  assert.equal(byQuestion('Do members spend more than non-members?'), undefined);
  assert.equal(byQuestion('Which memberships expire or failed to renew this month?'), undefined);
});

test('v828: every fact unavailable reads as "could not be prepared last night", no group left unhandled', () => {
  const groups = answersBuilder()(briefAllUnavailable);
  assert.ok(groups.length >= 1, 'the reused (non-facts) topics still produce groups');
  const factQuestions = new Set([
    'How did we do yesterday? Is that normal?', 'This month so far, am I ahead or behind?',
    'If every customer redeemed tomorrow, what would it cost me?', 'Is the quiet new, or always like that?',
    'Top ten by revenue. Now top ten by profit.', 'What is dying?', 'What do people buy together?',
    'Who is giving discounts, and on what?', 'Who visits more than one outlet?',
    'Birthdays this month. Did we actually send anything?', 'How much expires unused?',
    'Do members spend more than non-members?', 'Referrals. Do the friends stick?',
    'How many stamp cards get finished?', 'Is anyone gaming it?',
    'Sales per staff, per shift, fair to the hours they worked?',
    'What runs out before the next delivery?', 'Next seven days of bookings versus the same week last year?',
    'Which memberships expire or failed to renew this month?',
  ]);
  const flat = groups.flatMap((g) => g.items);
  for (const item of flat) {
    if (factQuestions.has(item.question)) {
      assert.equal(item.answer, 'Could not be prepared last night.', `${item.question} should read unavailable`);
      assert.equal(item.kind, 'muted');
    }
  }
  assert.ok(flat.some((i) => factQuestions.has(i.question)), 'at least one unavailable fact rendered');
});

test('v828: statuses that mean "does not apply here" omit the question entirely', () => {
  const groups = answersBuilder()(briefNotApplicable);
  const flat = groups.flatMap((g) => g.items);
  const questions = flat.map((i) => i.question);
  assert.ok(!questions.includes('Who visits more than one outlet?'), 'single_outlet is omitted');
  assert.ok(!questions.includes('Do members spend more than non-members?'), 'no_memberships is omitted');
  assert.ok(!questions.includes('How many stamp cards get finished?'), 'no_stamp_card is omitted');
  assert.ok(!questions.includes('Next seven days of bookings versus the same week last year?'), 'no_appointments is omitted');
  assert.ok(!questions.includes('Which memberships expire or failed to renew this month?'), 'no_memberships (memberships_due) is omitted');
});

test('v828: no answer ever prints undefined, null or NaN', () => {
  for (const brief of [cubblyWithFacts, briefAllUnavailable, briefNotApplicable]) {
    const groups = answersBuilder()(brief);
    const json = JSON.stringify(groups);
    assert.ok(!/undefined/.test(json), 'no "undefined" substring in the rendered groups');
    assert.ok(!/\bnull\b/.test(json), 'no "null" substring in the rendered groups');
    assert.ok(!/NaN/.test(json), 'no "NaN" substring in the rendered groups');
  }
});

test('v828: the dashboard markup wires the "All answers" disclosure', () => {
  const renderer = extractFunction(app, 'ownerBriefRenderV826');
  assert.match(renderer, /dashboard-brief-more/, 'the render path builds the disclosure');
  assert.match(renderer, /ownerBriefAnswersV828\(response\?\.brief\)/);
  const dash = app.slice(app.indexOf('async function dashboard(){'));
  assert.ok(dash.includes('id="dashboardBriefMore"'), 'the markup carries a mount point for it');
  assert.ok(index.includes('.dashboard-brief-more{'), 'the disclosure has its own style block');
});
