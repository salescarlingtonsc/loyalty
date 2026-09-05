/* NESTLY v771 — the Owner brief on Customer intelligence.
 *
 * ownerBriefHtmlV771 is a PURE top-level function taking one plain object, for exactly this
 * reason: the whole brief can be executed here against fixtures shaped like the real RPC
 * payloads, rather than asserted by grepping source. The fixtures below are transcribed from a
 * verbatim production capture (business "Cubbly SPA", 2026-09-05) of get_revenue_truth_v106,
 * get_customer_lifecycle_v107, get_customer_intelligence_v83, client_packages,
 * get_ci_service_intelligence_v1 and get_ci_opportunities_v1's abstention list — so the shapes
 * this file proves against are shapes production actually emits, not shapes invented to pass.
 *
 * Two owner rules are tested as rules, not as style: the brief never names WhatsApp (the standing
 * analytics ruling), and it never leaks the machine vocabulary an owner should not have to learn
 * ("bps", "cents", and the raw NaN/undefined/null that a missing field turns into when a renderer
 * interpolates without guarding).
 *
 * The last test is the only source-level one, and it is here because paint() is closure-bound
 * inside customerIntelligencePage() and cannot be called: it proves the brief is composed FIRST
 * and that the detail disclosure really wraps the previously-flat section list.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

const START = 'function ownerBriefHtmlV771(brief){';
const fnStart = app.indexOf(START);
assert.ok(fnStart > -1, 'ownerBriefHtmlV771 must be a top-level function in app/app.js');
const fnEnd = app.indexOf('\n}', fnStart) + 2;
assert.ok(fnEnd > fnStart, 'ownerBriefHtmlV771 must close at column zero');
const block = app.slice(fnStart, fnEnd);

/* The stubs are the five names the renderer is allowed to reach for. If it ever grows a sixth,
   this harness fails with a ReferenceError rather than silently testing a different function. */
function render(brief) {
  const sandbox = {
    esc: (x) => String(x ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'),
    money: (c) => 'SGD ' + ((c || 0) / 100).toFixed(2),
    walletDate: (v) => `WD:${v}`,
    CUI: { icon: () => '<svg aria-hidden="true"></svg>' },
    S: { biz: { currency: 'SGD' }, myRole: 'owner' }
  };
  const context = vm.createContext(sandbox);
  context.__exports = {};
  vm.runInContext(`${block}\n__exports.brief=ownerBriefHtmlV771;`, context);
  return context.__exports.brief(brief);
}

/* Visible text only: tag names, class names and attribute values are machinery, not copy. */
const textOf = (html) => html.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
/* Block F renders two labelled lists in one section; this returns the <li>s under one label. */
const listUnder = (html, label) => {
  const at = html.indexOf(label);
  if (at < 0) return [];
  const from = html.indexOf('<ul', at);
  if (from < 0) return [];
  return html.slice(from, html.indexOf('</ul>', from)).match(/<li[^>]*>[\s\S]*?<\/li>/g) || [];
};
const sectionOf = (html, className) => {
  const at = html.indexOf(`class="${className}"`);
  if (at < 0) return '';
  const open = html.lastIndexOf('<section', at);
  const close = html.indexOf('</section>', at);
  return html.slice(open, close + '</section>'.length);
};

/* ==================================================================================================
   Fixtures — transcribed from the production capture.
   ================================================================================================== */
const TRUTH = {
  status: 'ok',
  scope: { period: { to: '2026-09-06', from: '2025-09-06' }, currency: 'SGD', branch_id: null },
  totals: {
    known_revenue_minor: 659330, itemized_transactions: 47, anonymous_transactions: 1,
    completed_transactions: 47, anonymous_revenue_minor: 3000, identified_transactions: 46,
    identified_revenue_minor: 656330
  }
};
const LIFECYCLE = {
  status: 'ok',
  metrics: {
    new_customers: 4, reactivated_customers: 0, repeat_purchasers_in_period: 3,
    transacting_identified_customers: 6
  }
};
const CUSTOMERS = [
  {
    email: null, phone: null, client_id: '268cb96d-e6cc-4217-99f6-884b006ba7a3',
    full_name: 'Erased customer', visit_count: 18, purchase_count: 32,
    last_purchase_at: '2026-09-02T04:47:50.743878+00:00', net_revenue_cents: 357030,
    returning_customer: true, cash_collected_cents: 157030, days_since_last_purchase: 3,
    average_days_between_purchases: 1.3, average_revenue_per_purchase_cents: 11157
  },
  {
    email: null, phone: '81234567', client_id: '91f58f07-b70f-40de-a93a-61a198798867',
    full_name: 'P0 Test Customer', visit_count: 1, purchase_count: 1,
    last_purchase_at: '2026-07-19T16:38:15.577914+00:00', net_revenue_cents: 4500,
    returning_customer: false, cash_collected_cents: 0, days_since_last_purchase: 47,
    average_days_between_purchases: null, average_revenue_per_purchase_cents: 4500
  },
  {
    email: null, phone: '812345678', client_id: 'a88f18a6-183b-469e-baaa-b35c62da70fd',
    full_name: 'Lee Chuan Seng', visit_count: 0, purchase_count: 0,
    last_purchase_at: null, net_revenue_cents: 0, returning_customer: false,
    cash_collected_cents: 0, days_since_last_purchase: null,
    average_days_between_purchases: null, average_revenue_per_purchase_cents: 0
  }
];
const SUMMARY = {
  known_customers: 11, active_customers: 7, net_revenue_cents: 656330,
  returning_rate_pct: 42.9, returning_customers: 3, cash_collected_cents: 411830
};
const PACKAGES = [
  {
    id: '2420b5a3-1bd8-4dc0-854d-bf8e6760217f', client_id: '268cb96d-e6cc-4217-99f6-884b006ba7a3',
    remaining: 3, sessions_snapshot: 4, status: 'active',
    purchased_at: '2026-08-30T04:06:00.711987+00:00', expires_at: '2027-08-30T15:59:59.999999+00:00',
    plan_name_snapshot: 'Special Package (3x Facial + 1x Spa)',
    list_unit_cents_snapshot: null, price_cents_snapshot: null
  },
  {
    id: '59981410-a5f0-4607-ae33-7c08128c1814', client_id: 'b6454672-38a8-49cb-af4f-8e98fafae2ed',
    remaining: 3, sessions_snapshot: 5, status: 'active',
    purchased_at: '2026-08-26T13:53:10.626865+00:00', expires_at: null,
    plan_name_snapshot: '5x facial', list_unit_cents_snapshot: null, price_cents_snapshot: null
  }
];
const SERVICES = {
  services: [
    {
      buyers: 5, orders: 15, service_id: 'fb40ad58-65a0-47bb-a2f3-5f16a70a3a4b',
      repeat_rate: { pct: 20, numerator: 1, denominator: 5 }, service_name: 'facial',
      gateway_count: 3, repeat_buyers: 1, revenue_cents: 153000,
      evidence: { n: 5, floor: 5, status: 'ok' }
    },
    {
      buyers: 4, orders: 12, service_id: '8546bd52-f06c-4f88-92b5-f79fa82cf960',
      repeat_rate: { pct: null, numerator: 2, denominator: 4 }, service_name: 'spa',
      gateway_count: 2, repeat_buyers: 2, revenue_cents: 144000,
      evidence: { n: 4, floor: 5, status: 'insufficient' }
    }
  ],
  truncated: false
};
const ABSTENTIONS = [
  { reason: 'no bottleneck is nameable: a stage rate is null or the two stages are tied', generator: 'funnel_bottleneck' },
  { reason: 'no customer is overdue against a rhythm of their own: every overdue customer is judged on the business fallback, which says nothing about that person', generator: 'lapsed_regulars' },
  { reason: '4 package(s) sold in the window is below the sample floor of 5', generator: 'package_leakage:1a999dfc-cf3e-42af-8a6c-62f7030de4aa' },
  { reason: '2 package(s) sold in the window is below the sample floor of 5', generator: 'package_leakage:76eec23c-b44c-4087-b00e-94d3e625dd38' },
  { reason: '1 package(s) sold in the window is below the sample floor of 5', generator: 'package_leakage:4399efa0-9c48-40c7-a55f-91f8282eb92b' },
  { reason: "the firm's own first-to-second funnel rate is unavailable or below the sample floor, so there is no baseline to judge a service against", generator: 'gateway_followthrough' },
  { reason: 'below_evidence_floor: ', generator: 'no_discount_reminder' },
  { reason: 'no active loyalty programme has a within-cycle cannibalisation share at or above the 50.0% bar', generator: 'loyalty_cannibalisation_gap' },
  { reason: "no staff member's mix-adjusted index is below the 0.80 bar", generator: 'staff_mix_underperformance' },
  { reason: 'no matured send cohort clears the evidence floor, or no associated-purchase rate is available', generator: 'campaigns' }
];
const ATTENTION_TWO = {
  rows: [
    {
      client_id: '268cb96d-e6cc-4217-99f6-884b006ba7a3', full_name: 'Siti Rahman',
      phone: '81863833', status: 'overdue', last_visit_days: 62, cadence_days: 21.4,
      monthly_value_cents: 12000
    },
    {
      client_id: 'a88f18a6-183b-469e-baaa-b35c62da70fd', full_name: 'Wei Ling',
      phone: null, status: 'due', last_visit_days: 18, cadence_days: 17.6,
      monthly_value_cents: 8000
    }
  ],
  summary: { due: 1, overdue: 1, slipping: 0, considered: 9, one_time_count: 2, monthly_at_risk_cents: 12000 }
};

const FULL = {
  currency: 'SGD', periodDays: 31, from: '2026-08-06', to: '2026-09-05',
  truth: TRUTH, truthPrev: null,
  lifecycle: LIFECYCLE, lifecyclePrev: null,
  attention: ATTENTION_TWO, attentionError: '',
  packages: PACKAGES, packagesError: '',
  customers: CUSTOMERS, summary: SUMMARY,
  services: SERVICES, servicesError: '',
  abstentions: ABSTENTIONS,
  canOpenCustomers: true
};

/* ==================================================================================================
   1. Block A — this period at a glance, and the comparison against the window before it.
   ================================================================================================== */

test('V771 block A prints the recorded revenue and abstains from a comparison with no earlier window', () => {
  const html = render(FULL);
  const glance = sectionOf(html, 'ci-brief-glance-v771');
  assert.ok(glance.includes('SGD 6593.30'), 'the revenue tile prints known_revenue_minor as money');
  assert.ok(glance.includes('Customers who bought'), 'the second tile is named in plain English');
  assert.ok(textOf(glance).includes('6'), 'transacting_identified_customers is printed');
  assert.ok(textOf(glance).includes('4'), 'new_customers is printed');
  assert.equal((glance.match(/no earlier data to compare/g) || []).length, 3,
    'with no previous window every tile says so rather than printing a growth figure');
});

test('V771 block A computes the period-over-period change to a whole percent, in both directions', () => {
  const up = sectionOf(render({ ...FULL, truthPrev: { totals: { known_revenue_minor: 439553 } } }),
    'ci-brief-glance-v771');
  assert.ok(up.includes('vs the previous 31 days: +50%'),
    '6593.30 against 4395.53 is a 50% rise');

  const down = sectionOf(render({ ...FULL, truthPrev: { totals: { known_revenue_minor: 879107 } } }),
    'ci-brief-glance-v771');
  assert.ok(down.includes('vs the previous 31 days: −25%'),
    '6593.30 against 8791.07 is a 25% fall, printed with a real minus sign');

  const flat = sectionOf(render({ ...FULL, truthPrev: { totals: { known_revenue_minor: 659330 } } }),
    'ci-brief-glance-v771');
  assert.ok(flat.includes('vs the previous 31 days: no change'));

  /* A zero denominator is the trap this guard exists for: it is a number, and dividing by it
     yields Infinity, which is exactly the sort of thing an owner must never be shown. */
  const fromZero = sectionOf(render({ ...FULL, truthPrev: { totals: { known_revenue_minor: 0 } } }),
    'ci-brief-glance-v771');
  assert.ok(fromZero.includes('no earlier data to compare'));
  assert.ok(!/Infinity/.test(fromZero));
});

/* ==================================================================================================
   2. Block B — customers to bring back. One action per row, and never a WhatsApp one.
   ================================================================================================== */

test('V771 block B offers a call only to a row that has a number, and an Open only when permitted', () => {
  const withAccess = sectionOf(render(FULL), 'ci-brief-bringback-v771');
  assert.ok(withAccess.includes('href="tel:81863833"'), 'the row with a phone gets a Call link');
  assert.equal((withAccess.match(/href="tel:/g) || []).length, 1,
    'the row without a phone gets no tel link at all');
  assert.equal((withAccess.match(/href="#\/client\//g) || []).length, 2,
    'both rows open into the customer record when Customers is readable');

  const withoutAccess = sectionOf(render({ ...FULL, canOpenCustomers: false }), 'ci-brief-bringback-v771');
  assert.equal((withoutAccess.match(/href="#\/client\//g) || []).length, 0,
    'no record link is offered to someone who cannot open Customers');
  assert.ok(withoutAccess.includes('href="tel:81863833"'), 'the call survives without Customers access');
});

test('V771 block B keeps Call and Open side by side in one action cell', () => {
  /* The responsive table makes each td a two-column grid with right-aligned content, so two bare
     sibling links become two grid items and the second drops to its own row on the left — on a
     375px phone that reads as a second customer. Both links must sit inside one inline-flex span. */
  const section = sectionOf(render(FULL), 'ci-brief-bringback-v771');
  const cells = section.match(/<td data-label="Action">[\s\S]*?<\/td>/g) || [];
  assert.equal(cells.length, 2, 'both bring-back rows carry an action cell');
  const overdue = cells.find((cell) => cell.includes('tel:81863833'));
  assert.ok(overdue, 'the overdue row is the one with a phone number');
  const wrapper = overdue.match(/<span class="ci-brief-actions-v771" style="([^"]*)">([\s\S]*?)<\/span>/);
  assert.ok(wrapper, 'the two links are wrapped in a single ci-brief-actions-v771 span');
  assert.ok(wrapper[1].includes('display:inline-flex'), 'the wrapper is an inline flex row');
  assert.ok(wrapper[1].includes('white-space:nowrap'), 'so the pair cannot break across lines');
  assert.ok(wrapper[2].includes('href="tel:81863833"') && wrapper[2].includes('href="#/client/'),
    'and BOTH links are inside it, not one inside and one after');
  assert.ok(!/<\/span>\s*<a /.test(overdue), 'no action link escapes the wrapper');
});

test('V771 block B counts overdue customers in the singular and the plural', () => {
  const one = sectionOf(render(FULL), 'ci-brief-bringback-v771');
  assert.ok(one.includes('<b>1 customer overdue</b>'), 'one is a customer, not customers');
  assert.ok(one.includes('about SGD 120.00 a month of regular spend at risk'));

  const two = sectionOf(render({
    ...FULL,
    attention: { ...ATTENTION_TWO, summary: { ...ATTENTION_TWO.summary, slipping: 1, monthly_at_risk_cents: 20000 } }
  }), 'ci-brief-bringback-v771');
  assert.ok(two.includes('<b>2 customers overdue</b>'), 'overdue and slipping are counted together');
});

test('V771 block B prints each customer’s own rhythm, and is absent when it may not be read', () => {
  const section = sectionOf(render(FULL), 'ci-brief-bringback-v771');
  assert.ok(section.includes('21 days'), 'cadence_days is rounded to whole days');
  assert.ok(section.includes('62 days ago'), 'last_visit_days is stated as days ago');
  assert.ok(section.includes('Overdue') && section.includes('Due back'), 'statuses keep their labels');
  assert.ok(section.includes('2 customers visited once in the last year and never came back.'));

  const empty = sectionOf(render({ ...FULL, attention: { rows: [], summary: {} } }), 'ci-brief-bringback-v771');
  assert.ok(empty.includes('Nobody is overdue against their own visit rhythm right now.'));

  const failed = render({ ...FULL, attention: null, attentionError: 'permission denied for function' });
  assert.ok(failed.includes('Customers to bring back could not load.'));
  assert.ok(failed.includes('permission denied for function'), 'the reason is shown, not swallowed');

  const denied = render({ ...FULL, attention: null, attentionError: '' });
  assert.equal(sectionOf(denied, 'ci-brief-bringback-v771'), '',
    'no permission and no error means the block is absent, not empty');
});

/* ==================================================================================================
   3. Block C — prepaid sessions still unused.
   ================================================================================================== */

test('V771 block C rolls package rows up per customer and withholds a value it cannot prove', () => {
  const section = sectionOf(render(FULL), 'ci-brief-unused-v771');
  assert.ok(section.includes('2 customers hold 6 unused sessions'),
    'two holders, three sessions each');
  assert.ok(!/worth about/.test(section),
    'with no per-session list price on either row, no total is claimed');
  assert.ok(section.includes('Special Package (3x Facial + 1x Spa)'), 'the plan is named');
  /* The second holder is not in the v83 page at all, so there is no name and no last visit for
     them — the brief must still print a row rather than drop a customer holding paid-for work. */
  assert.ok(section.includes('no visit recorded'));
  assert.ok(section.includes('>Customer<'), 'an unknown holder is called Customer, never blank');
});

test('V771 block C totals the unused value once every row carries a list price', () => {
  const priced = PACKAGES.map((row) => ({ ...row, list_unit_cents_snapshot: 5000 }));
  const section = sectionOf(render({ ...FULL, packages: priced }), 'ci-brief-unused-v771');
  assert.ok(section.includes('SGD 300.00'), '6 sessions at SGD 50.00 each');
  assert.ok(section.includes('SGD 150.00'), 'and each holder carries their own share of it');

  /* One missing snapshot is enough to make the whole figure a guess. */
  const partial = [priced[0], PACKAGES[1]];
  const mixed = sectionOf(render({ ...FULL, packages: partial }), 'ci-brief-unused-v771');
  assert.ok(!/worth about/.test(mixed), 'a partial price set produces no headline total');
  assert.ok(mixed.includes('SGD 150.00'), 'the row that can be valued still is');
});

test('V771 block C is empty-stated when nothing is held and absent when packages cannot be read', () => {
  assert.ok(sectionOf(render({ ...FULL, packages: [] }), 'ci-brief-unused-v771')
    .includes('Every prepaid session has been used.'));
  assert.ok(render({ ...FULL, packages: null, packagesError: 'relation does not exist' })
    .includes('Prepaid sessions still unused could not load.'));
  assert.equal(sectionOf(render({ ...FULL, packages: null, packagesError: '' }), 'ci-brief-unused-v771'), '',
    'no packages module and no error means the block is absent');
});

/* ==================================================================================================
   4. Block D — your top customers.
   ================================================================================================== */

test('V771 block D ranks only customers who actually spent, and shares them against the whole', () => {
  const section = sectionOf(render(FULL), 'ci-brief-top-v771');
  const rows = section.match(/<tr><td data-label="Customer">/g) || [];
  assert.equal(rows.length, 2, 'the zero-revenue customer is not a top customer');
  const first = section.indexOf('Erased customer');
  const second = section.indexOf('P0 Test Customer');
  assert.ok(first > -1 && second > first, 'the biggest spender is ranked first');
  assert.ok(section.includes('SGD 3570.30'));
  assert.ok(section.includes('54% of revenue'), '357030 of 656330 is 54%');
  assert.ok(section.includes('Your top 2 customers are 55% of revenue.'));
  /* "of revenue" is short enough to be misread as all revenue, so the caption states the
     denominator once, under the table, rather than lengthening every cell. */
  assert.ok(section.includes('Shares are of revenue from known customers. Walk-in sales with no name attached are not included.'));

  const noTotal = sectionOf(render({ ...FULL, summary: { net_revenue_cents: 0 } }), 'ci-brief-top-v771');
  assert.ok(!/% of revenue/.test(noTotal),
    'with no identified-revenue total there is no share to state');
});

test('V771 block D borrows the bring-back status instead of judging cadence itself', () => {
  /* There is ONE cadence authority and it is get_attention_list_v548. The Note column repeats the
     status that reader gave the same client, or stays empty — it never re-derives a verdict from
     days_since_last_purchase and average_days_between_purchases, which is what it used to do and
     which called a customer with a 1.3-day rhythm "quiet" three days after a visit. */
  const html = render(FULL);
  assert.ok(!/Quiet lately/.test(html), 'the browser-side cadence verdict is gone entirely');

  const section = sectionOf(html, 'ci-brief-top-v771');
  const notes = section.match(/<td data-label="Note">[\s\S]*?<\/td>/g) || [];
  assert.equal(notes.length, 2, 'one Note cell per ranked customer');

  /* CUSTOMERS[0] is in the attention rows as 'overdue'; CUSTOMERS[1] is not in them at all. */
  const rows = section.split('<tr>');
  const erased = rows.find((row) => row.includes('Erased customer'));
  const other = rows.find((row) => row.includes('P0 Test Customer'));
  assert.match(erased, /<td data-label="Note">.*?>Overdue<.*?<\/td>/,
    'a customer the bring-back reader called overdue carries that exact pill');
  assert.match(other, /<td data-label="Note"><\/td>/,
    'a customer the bring-back reader never named carries an empty Note cell');

  /* Flip the same client to 'slipping' and the Note follows the server, not a local rule. */
  const slipping = sectionOf(render({
    ...FULL,
    attention: { ...ATTENTION_TWO, rows: [{ ...ATTENTION_TWO.rows[0], status: 'slipping' }] }
  }), 'ci-brief-top-v771');
  assert.ok(slipping.includes('Slipping away'), 'the pill is whatever the reader said');
  assert.ok(!/Overdue/.test(slipping));

  /* With no attention bundle at all — no permission, or a failed read — every Note is empty. */
  const noReader = sectionOf(render({ ...FULL, attention: null, attentionError: '' }), 'ci-brief-top-v771');
  assert.equal((noReader.match(/<td data-label="Note"><\/td>/g) || []).length, 2,
    'no bring-back reader means no notes, never a locally invented one');
});

test('V771 block D empty-states rather than showing a table of nobody', () => {
  /* nestly_v776: the copy used to say "No identified customer revenue", borrowing the reader's
     word for a customer a sale can be attributed to. An owner does not have that vocabulary, and
     the whole-brief scan below now enforces its absence. What the state means is unchanged. */
  assert.ok(sectionOf(render({ ...FULL, customers: [] }), 'ci-brief-top-v771')
    .includes('No customer revenue on record for this period yet.'));
});

/* ==================================================================================================
   5. Block E — which service brings people back.
   ================================================================================================== */

test('V771 block E states the repeat count and refuses a rate it has no evidence for', () => {
  const section = sectionOf(render(FULL), 'ci-brief-services-v771');
  assert.ok(section.includes('1 of 5 (20%)'), 'facial cleared the floor, so the rate is shown');
  assert.ok(section.includes('2 of 4 — too few to say'),
    'spa did not, so the counts stand alone and the rate is withheld');
  assert.ok(section.indexOf('facial') < section.indexOf('spa'), 'ordered by how many bought it');
  assert.ok(section.includes('SGD 1530.00') && section.includes('SGD 1440.00'));
  assert.ok(section.includes('First-time customers it brought in'),
    'the gateway count is named in words an owner uses');

  assert.ok(sectionOf(render({ ...FULL, services: { services: [] } }), 'ci-brief-services-v771')
    .includes('No service sales in this period yet.'));
  assert.ok(render({ ...FULL, services: null, servicesError: 'statement timeout' })
    .includes('Which service brings people back could not load.'));
});

/* ==================================================================================================
   6. Block F — what Peekaa cannot tell you yet.
   ================================================================================================== */

test('V771 block F says each withheld finding once, in plain English, with no machine vocabulary', () => {
  const section = sectionOf(render(FULL), 'ci-brief-limits-v771');
  const items = section.match(/<li[^>]*>([\s\S]*?)<\/li>/g) || [];
  assert.equal(items.length, 8, 'ten abstentions over eight distinct findings');

  const packageItems = items.filter((item) => /package plans/.test(item));
  assert.equal(packageItems.length, 1, 'three suppressed plans are one sentence, not three');
  assert.ok(packageItems[0].includes('(3 plans)'), 'and the sentence says how many');

  assert.ok(section.includes('Whether a plain reminder works as well as a discount'),
    'the dictionary sentence replaces the raw "below_evidence_floor: " reason');
  assert.ok(!section.includes('below evidence floor'), 'the raw reason is not shown at all');
  assert.ok(section.includes('Peekaa withholds a finding rather than guess.'));

  assert.ok(!textOf(section).includes('_'),
    'no snake_case identifier survives into the copy an owner reads');

  assert.equal(sectionOf(render({ ...FULL, abstentions: [] }), 'ci-brief-limits-v771'), '',
    'nothing withheld means no block');
});

test('V771 block F separates a clean result from a missing one', () => {
  /* The loyalty-cannibalisation and staff-mix generators abstain BECAUSE they looked and found
     nothing over the bar. Filing that under "cannot tell you yet" reads as a hole in the product
     rather than the reassurance it is, so it gets its own list and its own wording. */
  const section = sectionOf(render(FULL), 'ci-brief-limits-v771');

  const cleared = listUnder(section, 'Checked — nothing to flag');
  assert.equal(cleared.length, 2, 'exactly the two generators that report a clean check');
  assert.ok(cleared.some((item) => item.includes('Your loyalty rewards are not paying customers who would have come anyway.')));
  assert.ok(cleared.some((item) => item.includes('No staff member’s customers return noticeably less than the others’.')));
  for (const item of cleared) {
    assert.ok(!/needs /.test(item), 'a clean check never asks for more evidence');
  }

  const pending = listUnder(section, 'Not enough evidence yet');
  assert.equal(pending.length, 6, 'the remaining six are genuinely waiting on evidence');
  const packageItem = pending.filter((item) => /package plans/.test(item));
  assert.equal(packageItem.length, 1);
  assert.ok(packageItem[0].includes('(3 plans)'),
    'the collapsed package sentence belongs under the evidence list, not the cleared one');
  assert.ok(!cleared.some((item) => /package plans/.test(item)));

  /* A fixture with only cleared abstentions must not print an empty evidence label, or vice versa. */
  const onlyCleared = sectionOf(render({
    ...FULL, abstentions: [{ generator: 'staff_mix_underperformance', reason: 'x' }]
  }), 'ci-brief-limits-v771');
  assert.ok(onlyCleared.includes('Checked — nothing to flag'));
  assert.ok(!onlyCleared.includes('Not enough evidence yet'), 'an empty list prints no label');

  const onlyPending = sectionOf(render({
    ...FULL, abstentions: [{ generator: 'campaigns', reason: 'x' }]
  }), 'ci-brief-limits-v771');
  assert.ok(onlyPending.includes('Not enough evidence yet'));
  assert.ok(!onlyPending.includes('Checked — nothing to flag'));
});

test('V771 block F falls back to the server reason, tidied, for a generator it does not know', () => {
  const section = sectionOf(render({
    ...FULL,
    abstentions: [{ generator: 'some_future_finding:abc', reason: 'not_enough_matched_visits: ' }]
  }), 'ci-brief-limits-v771');
  assert.ok(section.includes('Not enough matched visits'),
    'underscores become spaces, the trailing colon goes, and the sentence starts with a capital');
  assert.ok(!textOf(section).includes('_'));
});

/* ==================================================================================================
   7. The two standing rules, over every fixture this file has.
   ================================================================================================== */

test('V771 the brief never names WhatsApp and never leaks machine vocabulary', () => {
  const cases = [
    FULL,
    { ...FULL, truthPrev: { totals: { known_revenue_minor: 439553 } }, lifecyclePrev: LIFECYCLE },
    { ...FULL, canOpenCustomers: false },
    { ...FULL, attention: null, attentionError: 'permission denied', packages: null, packagesError: 'nope', services: null, servicesError: 'timeout' },
    { ...FULL, customers: [], packages: [], services: { services: [] }, abstentions: [] },
    { ...FULL, truth: {}, lifecycle: {}, summary: {}, attention: { rows: [{}], summary: {} }, packages: [{}], services: { services: [{}] }, abstentions: [{}] }
  ];
  for (const [index, fixture] of cases.entries()) {
    const html = render(fixture);
    assert.ok(!/whatsapp/i.test(html), `fixture ${index}: analytics must not display anything with WhatsApp`);
    const text = textOf(html);
    for (const banned of ['NaN', 'undefined', 'null', 'bps', 'cents', 'identified']) {
      assert.ok(!text.includes(banned), `fixture ${index}: "${banned}" must never reach an owner (${text.slice(0, 400)})`);
    }
  }
});

test('V771 the brief renders from nothing at all rather than throwing', () => {
  for (const input of [{}, null, undefined, [], 'not an object', 7]) {
    const html = render(input);
    assert.ok(typeof html === 'string');
    assert.ok(html.includes('<section class="card ci-owner-brief-v771" aria-labelledby="ciOwnerBriefTitleV771">'),
      'the section root is always returned');
    assert.ok(!/NaN|undefined|Infinity/.test(textOf(html)));
  }
});

/* ==================================================================================================
   8. Composition — the one thing that cannot be executed from here.
   ================================================================================================== */

test('V771 paint puts the brief first and files the old page behind one closed disclosure', () => {
  const paint = app.slice(app.indexOf('body.innerHTML=`${ownerBriefMarkupV771()}'));
  const line = paint.slice(0, paint.indexOf('`;') + 2);
  assert.ok(line.indexOf('${ownerBriefMarkupV771()}') < line.indexOf('${activeExecutionMarkup}'),
    'the brief is composed before anything that used to open this page');
  assert.ok(line.includes('<details class="card ci-detailed-analysis-v771" id="ciDetailedAnalysisV771">'));
  assert.ok(!line.includes(' open>'), 'the disclosure is closed by default');
  const detail = line.slice(line.indexOf('ci-detailed-analysis-body-v771'));
  assert.ok(detail.includes('${activeExecutionMarkup}'),
    'everything that followed the brief is inside the disclosure');
  assert.ok(detail.includes('${ciBehaviourMarkupV679()}${ciOpportunitiesMarkupV685()}'),
    'the existing section concatenation is carried inside byte-identically');
  assert.ok(detail.includes('</div></details>'));
});
