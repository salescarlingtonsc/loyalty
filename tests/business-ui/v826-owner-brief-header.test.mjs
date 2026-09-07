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
