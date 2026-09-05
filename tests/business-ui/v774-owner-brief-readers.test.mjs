/* NESTLY v774 — the five v772 readers behind the Owner brief's new blocks.
 *
 * G "Money recorded vs collected"  · get_ci_cash_gap_v1
 * H "Staff: who brings customers back" · get_ci_staff_rebooking_v1
 * I "Most popular rewards"        · get_ci_reward_popularity_v1
 * J "When customers come in"      · get_ci_visit_rhythm_v1
 * K "Who your customers are"      · get_ci_demographic_totals_v1
 *
 * Same posture as tests/business-ui/v771-owner-brief.test.mjs: ownerBriefHtmlV771 is a pure
 * top-level function taking one plain object, so the whole brief is EXECUTED here against
 * fixtures rather than asserted by grepping source. The fixtures are transcribed from the
 * predetermined truth table at the head of db/tests/v772_corpus_owner_brief_readers.sql — the
 * rolled-back acceptance fixture that proves the migration — so the shapes and the numbers this
 * file asserts against are the ones the readers were proven to emit, not shapes invented to pass.
 *
 * Three rules are tested as rules rather than as style. A null pct is "too few to say" and never
 * a rounded zero. A suppressed cell is "fewer than 5" and never 0. And the brief never prints the
 * machine vocabulary an owner should not have to learn — no WhatsApp (the standing analytics
 * ruling), no bps, no cents, no evidence class, no raw NaN/undefined/null.
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

/* The stubs are the names the renderer is allowed to reach for. A sixth one fails here with a
   ReferenceError rather than silently testing a different function. */
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

const textOf = (html) => html.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
const sectionOf = (html, className) => {
  const at = html.indexOf(`class="${className}"`);
  if (at < 0) return '';
  const open = html.lastIndexOf('<section', at);
  const close = html.indexOf('</section>', at);
  return html.slice(open, close + '</section>'.length);
};
const rowsOf = (section, label) =>
  (section.match(new RegExp(`<td data-label="${label}">[\\s\\S]*?</td>`, 'g')) || []).map(textOf);

const OK = { n: 5, floor: 5, status: 'ok' };
const LOW = { n: 1, floor: 5, status: 'insufficient' };

/* ==================================================================================================
   Fixtures — TRUTH TABLES 1..5 of db/tests/v772_corpus_owner_brief_readers.sql.
   ================================================================================================== */

/* TRUTH TABLE 1. 14 sales, 124000 recorded, 49000 collected, 75000 outstanding, 3 fully paid,
   2 partly, 9 unpaid; collected_share 39.5; one deposit and one refund reported, never counted. */
const CASH_GAP = {
  scope: { business_id: 'b', branch_id: null, from: '2026-03-02', to: '2026-03-29' },
  totals: {
    revenue_recorded_cents: 124000, collected_cents: 49000, outstanding_cents: 75000,
    overpaid_cents: 2000, sales_count: 14, sales_fully_paid: 3, sales_partly_paid: 2,
    sales_unpaid: 9,
    collected_share: { numerator: 49000, denominator: 124000, pct: 39.5 }
  },
  by_method: [
    { method: 'card', cents: 24000, payments: 2 },
    { method: 'cash', cents: 22000, payments: 2 },
    { method: 'paynow', cents: 10000, payments: 1 }
  ],
  refunds_cents: 5000,
  unapplied_payment_kinds: [{ kind: 'deposit', cents: 2000, payments: 1 }],
  unapplied_note: 'Deposits and no-show fees touched these sales but are not counted as collected against them.',
  unlinked_payments: { count: 2, cents: 4500 },
  unlinked_note: 'Payments in this window that reach no in-scope sale.',
  outstanding_sales: [],
  outstanding_by_customer: [
    { client_id: 'c7', client_name: 'ZZ Gil', sales: 1, outstanding_cents: 20000 },
    { client_id: 'c3', client_name: 'ZZ Cara', sales: 2, outstanding_cents: 15000 }
  ],
  names_visible: true,
  names_note: 'Customer names are shown only to a caller who holds the clients module.',
  time_basis: 'sale_occurred_at',
  basis_note: 'A sale with no payment row is either unpaid or was paid without being recorded; this reader cannot tell the two apart.',
  evidence_class: 'DIRECT_FACT'
};

/* TRUTH TABLE 2, CALL D. A is 4 of 5 at 80% and +30 points on the firm's 50%; B has four
   matured customers, one under the evidence floor, so both of B's rates are withheld. */
const STAFF = {
  window_days: 60,
  visit_definition: 'one per customer per calendar day (Asia/Singapore) per attributed staff member',
  firm: {
    matured: 8, immature: 0,
    returned_any: { numerator: 4, denominator: 8, pct: 50.0 },
    evidence: { n: 8, floor: 5, status: 'ok' }
  },
  staff: [
    {
      staff_id: 'st-a', full_name: 'ZZ Alpha', active: true, visits: 8, customers: 5,
      revenue_cents: 65000, revenue_per_visit_cents: 8125, matured: 5, immature: 0,
      returned_any: { numerator: 4, denominator: 5, pct: 80.0 },
      returned_same_staff: { numerator: 3, denominator: 5, pct: 60.0 },
      vs_firm_points: 30.0, evidence: OK
    },
    {
      staff_id: 'st-b', full_name: 'ZZ Beta', active: false, visits: 4, customers: 4,
      revenue_cents: 49000, revenue_per_visit_cents: 12250, matured: 4, immature: 0,
      returned_any: { numerator: 0, denominator: 4, pct: null },
      returned_same_staff: { numerator: 0, denominator: 4, pct: null },
      vs_firm_points: null, evidence: { n: 4, floor: 5, status: 'insufficient' }
    }
  ],
  unattributed_visits: 1,
  anonymous_visits: 1,
  anonymous_note: 'Anonymous sales carry no identity.',
  time_basis: 'sale_occurred_at',
  evidence_class: 'ASSOCIATION',
  limitation: 'Which customers a staff member serves is not random; a higher return rate is an association, not proof the staff member caused it.'
};

/* TRUTH TABLE 3. rw1 62.5% of redemptions; rw2 and rw4 below the floor; rw3 live and never
   redeemed, which is the row an owner most needs and the one a filter would have removed. */
/* TRUTH TABLE 2, CALL E — p_as_of 2026-04-01, so 03-02 + 60 days has not arrived: nothing has
   matured, and every rate is 0 of 0. That is the calendar's answer, not the staff member's. */
const STAFF_IMMATURE = {
  ...STAFF,
  firm: {
    matured: 0, immature: 8,
    returned_any: { numerator: 0, denominator: 0, pct: null },
    evidence: { n: 0, floor: 5, status: 'insufficient' }
  },
  staff: [
    {
      ...STAFF.staff[0], matured: 0, immature: 5,
      returned_any: { numerator: 0, denominator: 0, pct: null },
      returned_same_staff: { numerator: 0, denominator: 0, pct: null },
      vs_firm_points: null
    },
    {
      ...STAFF.staff[1], matured: 0, immature: 1,
      returned_any: { numerator: 0, denominator: 0, pct: null },
      returned_same_staff: { numerator: 0, denominator: 0, pct: null },
      vs_firm_points: null
    }
  ]
};

const REWARDS = {
  scope_note: 'Redemptions are business-wide; the branch filter does not apply to this reader.',
  rewards: [
    {
      reward_id: 'rw1', reward_name: 'ZZ Free Coffee', active: true, paused: false,
      redemptions: 5, customers: 5, points_spent: 150,
      share_of_redemptions: { numerator: 5, denominator: 8, pct: 62.5 },
      redeemers_share: { numerator: 5, denominator: 9, pct: 55.6 }, evidence: OK
    },
    {
      reward_id: 'rw2', reward_name: 'ZZ Free Cake', active: true, paused: true,
      redemptions: 1, customers: 1, points_spent: 50,
      share_of_redemptions: { numerator: 1, denominator: 8, pct: null },
      redeemers_share: { numerator: 1, denominator: 9, pct: null }, evidence: LOW
    },
    {
      reward_id: 'rw4', reward_name: 'ZZ Retired Treat', active: false, paused: false,
      redemptions: 1, customers: 1, points_spent: 20,
      share_of_redemptions: { numerator: 1, denominator: 8, pct: null },
      redeemers_share: { numerator: 1, denominator: 9, pct: null }, evidence: LOW
    },
    {
      reward_id: 'rw3', reward_name: 'ZZ Never Redeemed', active: true, paused: false,
      redemptions: 0, customers: 0, points_spent: 0,
      share_of_redemptions: { numerator: 0, denominator: 8, pct: null },
      redeemers_share: { numerator: 0, denominator: 9, pct: null },
      evidence: { n: 0, floor: 5, status: 'insufficient' }
    }
  ],
  unattributed_redemptions: { redemptions: 1, customers: 1, points_spent: 10 },
  totals: { redemptions: 8, customers: 8, points_spent: 230, eligible_customers: 9 },
  time_basis: 'redemption_redeemed_at',
  evidence_class: 'DIRECT_FACT',
  limitation: 'Counts points and stamp reward redemptions only; welcome, birthday, bring-back and referral gifts are granted rather than redeemed and are reported separately.'
};

/* TRUTH TABLE 4. The window is 2026-03-02..03-29 — 28 days, four of every weekday. Only the
   seven days that saw a sale carry visits; the rest are the reader's zero-fill. */
const DAY_LABELS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const DAY_FACTS = {
  '2026-03-02': [2, 20000, 2], '2026-03-03': [2, 20000, 2], '2026-03-04': [2, 30000, 2],
  '2026-03-05': [1, 20000, 1], '2026-03-09': [2, 10000, 2], '2026-03-10': [1, 5000, 1],
  '2026-03-11': [1, 5000, 1], '2026-03-12': [1, 7000, 1], '2026-03-13': [1, 3000, 0],
  '2026-03-16': [1, 4000, 1]
};
const RHYTHM_DAYS = Array.from({ length: 28 }, (unused, index) => {
  const date = new Date(Date.UTC(2026, 2, 2 + index));
  const key = date.toISOString().slice(0, 10);
  const [visits, revenue, identified] = DAY_FACTS[key] || [0, 0, 0];
  const jsDow = date.getUTCDay();
  return {
    date: key, dow: jsDow === 0 ? 7 : jsDow, label: DAY_LABELS[jsDow],
    visits, revenue_cents: revenue, identified_customers: identified
  };
});
const WEEKDAY = (dow, label, visits, per, revenue) =>
  ({ dow, label, visits, occurrences: 4, per_occurrence: per, revenue_cents: revenue, evidence: { n: 4, floor: 4, status: 'ok' } });
const RHYTHM = {
  visit_definition: 'one qualifying sale row bucketed on the Asia/Singapore calendar day and hour of sale_occurred_at',
  days: RHYTHM_DAYS,
  current: { visits: 14, revenue_cents: 124000 },
  previous: { from: '2026-02-02', to: '2026-03-01', visits: 1, revenue_cents: 10000 },
  change: { visits_pct: 1300.0, revenue_pct: 1140.0 },
  weekdays: [
    WEEKDAY(1, 'Monday', 5, 1.3, 34000), WEEKDAY(2, 'Tuesday', 3, 0.8, 25000),
    WEEKDAY(3, 'Wednesday', 3, 0.8, 35000), WEEKDAY(4, 'Thursday', 2, 0.5, 27000),
    WEEKDAY(5, 'Friday', 1, 0.3, 3000), WEEKDAY(6, 'Saturday', 0, 0.0, 0),
    WEEKDAY(7, 'Sunday', 0, 0.0, 0)
  ],
  slowest_weekdays: [
    { dow: 6, label: 'Saturday', visits: 0, occurrences: 4, per_occurrence: 0.0 },
    { dow: 7, label: 'Sunday', visits: 0, occurrences: 4, per_occurrence: 0.0 }
  ],
  busiest_weekdays: [
    { dow: 1, label: 'Monday', visits: 5, occurrences: 4, per_occurrence: 1.3 },
    { dow: 2, label: 'Tuesday', visits: 3, occurrences: 4, per_occurrence: 0.8 }
  ],
  hour_blocks: [
    { block_start: 8, label: '8am–10am', visits: 0, revenue_cents: 0, days_with_visits: 0, share: { numerator: 0, denominator: 14, pct: null } },
    { block_start: 10, label: '10am–12pm', visits: 10, revenue_cents: 75000, days_with_visits: 7, share: { numerator: 10, denominator: 14, pct: 71.4 } },
    { block_start: 14, label: '2pm–4pm', visits: 3, revenue_cents: 45000, days_with_visits: 3, share: { numerator: 3, denominator: 14, pct: 21.4 } },
    { block_start: 18, label: '6pm–8pm', visits: 1, revenue_cents: 4000, days_with_visits: 1, share: { numerator: 1, denominator: 14, pct: null } }
  ],
  open_blocks: [
    { block_start: 10, label: '10am–12pm', visits: 10, days_with_visits: 7 },
    { block_start: 14, label: '2pm–4pm', visits: 3, days_with_visits: 3 }
  ],
  open_block_rule: 'a two-hour block counts as open when it saw visits on at least 3 days',
  slowest_blocks: [
    { block_start: 14, label: '2pm–4pm', visits: 3, days_with_visits: 3 },
    { block_start: 10, label: '10am–12pm', visits: 10, days_with_visits: 7 }
  ],
  busiest_blocks: [
    { block_start: 10, label: '10am–12pm', visits: 10, days_with_visits: 7 },
    { block_start: 14, label: '2pm–4pm', visits: 3, days_with_visits: 3 }
  ],
  age_by_block: [
    { block_start: 10, label: '10am–12pm', age_band: '25_30', visits: 8, suppressed: false },
    { block_start: 14, label: '2pm–4pm', age_band: '25_30', visits: null, suppressed: true },
    { block_start: 14, label: '2pm–4pm', age_band: '41_50', visits: null, suppressed: true },
    { block_start: 18, label: '6pm–8pm', age_band: '25_30', visits: null, suppressed: true }
  ],
  age_by_block_note: 'A cell below the shared 5-visit floor keeps its place and reports visits as null with suppressed true.',
  coverage: { age_known: { numerator: 12, denominator: 13, pct: 92.3 } },
  time_basis: 'sale_occurred_at',
  evidence_class: 'DIRECT_FACT'
};

/* TRUTH TABLE 5. Nine customers, eight with a gender and eight with an age; the ninth of each
   sits OUTSIDE the share denominator and on its own Unknown line. */
const DEMOGRAPHICS = {
  population: { customers: 9, revenue_cents: 121000 },
  gender: [
    { gender: 'female', customers: 6, share: { numerator: 6, denominator: 8, pct: 75.0 }, revenue_cents: 90000 },
    { gender: 'male', customers: 2, share: { numerator: 2, denominator: 8, pct: 25.0 }, revenue_cents: 27000 }
  ],
  unknown_gender: { customers: 1, revenue_cents: 4000 },
  age_bands: [
    { age_band: '25_30', customers: 6, share: { numerator: 6, denominator: 8, pct: 75.0 }, revenue_cents: 74000 },
    { age_band: '41_50', customers: 2, share: { numerator: 2, denominator: 8, pct: 25.0 }, revenue_cents: 40000 }
  ],
  unknown_age: { customers: 1, revenue_cents: 7000 },
  evidence: { gender: OK, age_band: OK },
  coverage: {
    gender_known: { numerator: 8, denominator: 9, pct: 88.9 },
    age_known: { numerator: 8, denominator: 9, pct: 88.9 }
  },
  by_item: [
    {
      item_id: null, item_name: 'ZZ Haircut', item_type: 'service', revenue_cents: 72000,
      buyers: 6, buyers_known_gender: 6, buyers_known_age: 5,
      by_gender: [
        { gender: 'female', buyers: 5, revenue_cents: 65000, share_of_item_buyers: { numerator: 5, denominator: 6, pct: 83.3 }, evidence: OK },
        { gender: 'male', buyers: 1, revenue_cents: 7000, share_of_item_buyers: { numerator: 1, denominator: 6, pct: null }, evidence: LOW }
      ],
      by_age_band: [
        { age_band: '25_30', buyers: 5, revenue_cents: 65000, share_of_item_buyers: { numerator: 5, denominator: 5, pct: 100.0 }, evidence: OK }
      ]
    },
    {
      item_id: null, item_name: 'ZZ Colour', item_type: 'service', revenue_cents: 49000,
      buyers: 4, buyers_known_gender: 4, buyers_known_age: 3,
      by_gender: [
        { gender: 'female', buyers: 3, revenue_cents: 29000, share_of_item_buyers: { numerator: 3, denominator: 4, pct: null }, evidence: LOW },
        { gender: 'male', buyers: 1, revenue_cents: 20000, share_of_item_buyers: { numerator: 1, denominator: 4, pct: null }, evidence: LOW }
      ],
      by_age_band: []
    }
  ],
  item_share_note: 'share_of_item_buyers is measured against that item’s buyers whose gender or age is known.',
  time_basis: 'sale_occurred_at',
  evidence_class: 'DIRECT_FACT',
  limitation: 'Gender and date of birth are known only for customers who gave them when creating their Peekaa account or whose profile a staff member completed; walk-ins added at the till have neither until someone records it.'
};

const FULL = {
  currency: 'SGD', periodDays: 28, from: '2026-03-02', to: '2026-03-29',
  truth: null, truthPrev: null, lifecycle: null, lifecyclePrev: null,
  attention: null, attentionError: '', packages: null, packagesError: '',
  customers: [], summary: null, services: null, servicesError: '', abstentions: null,
  cashGap: CASH_GAP, cashGapError: '',
  staff: STAFF, staffError: '',
  rewards: REWARDS, rewardsError: '',
  rhythm: RHYTHM, rhythmError: '',
  demographics: DEMOGRAPHICS, demographicsError: '',
  canOpenCustomers: true
};

/* ==================================================================================================
   G — money recorded vs collected.
   ================================================================================================== */

test('V774 block G states recorded, collected and outstanding with the base of every share beside it', () => {
  const section = sectionOf(render(FULL), 'ci-brief-cash-v774');
  assert.ok(section, 'the cash-gap block renders');
  assert.ok(section.includes('SGD 1240.00'), 'revenue recorded');
  assert.ok(section.includes('SGD 490.00'), 'collected');
  assert.ok(section.includes('SGD 750.00'), 'outstanding');
  const text = textOf(section);
  assert.ok(text.includes('40% of revenue recorded'), 'the collected share is a whole percent against a named base');
  assert.ok(text.includes('across 14 sales'));
  assert.ok(text.includes('9 sales unpaid · 2 partly paid'));
  assert.ok(text.includes('By method: card SGD 240.00 · cash SGD 220.00 · paynow SGD 100.00'));
  assert.ok(text.includes('2 payments worth SGD 45.00 are not linked to any sale in this period.'));
  assert.ok(text.includes('Refunds: SGD 50.00'));
  assert.ok(text.includes('3 of 14 sales are fully paid.'));
  assert.ok(text.includes('Peekaa cannot tell the two apart.'), 'block G note is owner copy, not the server basis_note');
  assert.ok(!/this reader/.test(text), 'the server basis_note must not be printed verbatim');
  assert.ok(text.includes('A sale with no payment row is either unpaid or was paid without being recorded'),
    'the reader states its own limit, verbatim, rather than the brief paraphrasing it');
  assert.ok(!text.includes('DIRECT_FACT'), 'the evidence class never reaches an owner');
  assert.ok(!text.includes('deposit'), 'the unapplied kinds are not presented as collected money');
});

test('V774 block G lists open bills, links them only when Customers is readable, and says when names are withheld', () => {
  const section = sectionOf(render(FULL), 'ci-brief-cash-v774');
  assert.ok(section.includes('ZZ Gil') && section.includes('ZZ Cara'));
  assert.ok(section.includes('SGD 200.00') && section.includes('SGD 150.00'));
  assert.equal((section.match(/href="#\/client\//g) || []).length, 2);
  assert.ok(!textOf(section).includes('Names are hidden for your role.'));

  const sealed = sectionOf(render({
    ...FULL,
    cashGap: {
      ...CASH_GAP, names_visible: false,
      outstanding_by_customer: [{ client_id: 'c7', client_name: null, sales: 1, outstanding_cents: 20000 }]
    },
    canOpenCustomers: false
  }), 'ci-brief-cash-v774');
  const sealedText = textOf(sealed);
  assert.ok(sealedText.includes('Names are hidden for your role.'));
  assert.ok(sealedText.includes('Customer'), 'a withheld name still renders a row, labelled plainly');
  assert.ok(!sealedText.includes('ZZ Gil'));
  assert.equal((sealed.match(/href="#\/client\//g) || []).length, 0);
  assert.ok(sealedText.includes('SGD 200.00'), 'every figure survives the name gate');
});

test('V774 block G says so when nothing is outstanding', () => {
  const section = sectionOf(render({
    ...FULL,
    cashGap: {
      ...CASH_GAP,
      totals: { ...CASH_GAP.totals, outstanding_cents: 0, sales_unpaid: 0, sales_partly_paid: 0 },
      outstanding_by_customer: []
    }
  }), 'ci-brief-cash-v774');
  assert.ok(textOf(section).includes('Every recorded sale in this period has a payment recorded against it.'));
});

/* ==================================================================================================
   H — staff rebooking.
   ================================================================================================== */

test('V774 block H compares each staff member against the firm and withholds a rate under the floor', () => {
  const section = sectionOf(render(FULL), 'ci-brief-staff-v774');
  const text = textOf(section);
  assert.ok(text.includes('Across everyone: 4 of 8 came back within 60 days (50%)'));
  assert.ok(section.includes('Came back within 60 days'), 'the window is named in the column, not assumed');

  assert.ok(text.includes('ZZ Alpha'));
  assert.ok(text.includes('4 of 5 (80%)'), 'a rate over the floor prints its counts AND its percent');
  assert.ok(text.includes('3 of 5 (60%)'), 'returning to the same person is a separate, narrower figure');
  assert.ok(text.includes('+30 pts'));
  assert.ok(text.includes('SGD 81.25'), 'revenue per visit comes from the reader, not from a division here');
  assert.ok(!/<th>Visits<\/th>/.test(section) && !/data-label="Visits"/.test(section),
    'V522: a bare Visits column on this page collides with the customer table\'s Paid visits');
  assert.ok(section.includes('<th>Valid visits</th>'));

  assert.ok(text.includes('ZZ Beta (no longer active)'), 'an inactive staff member still gets their row');
  assert.ok(text.includes('0 of 4 — too few to say'),
    'four matured customers is under the floor, so the rate is withheld — never rounded to 0%');
  assert.ok(!text.includes('0 of 4 (0%)'));
  assert.ok(text.includes('1 visit had no staff recorded.'));
  assert.ok(text.includes('a higher return rate is an association, not proof'));
  assert.ok(!text.includes('ASSOCIATION'), 'the evidence class itself never reaches an owner');
});

test('V774 block H prints a dash, not a zero, where the reader gave no comparison', () => {
  const section = sectionOf(render(FULL), 'ci-brief-staff-v774');
  const vsFirm = rowsOf(section, 'vs firm');
  assert.deepEqual(vsFirm, ['+30 pts', '—'],
    'a null vs_firm_points is absent, not "0 pts" — the firm rate it would compare against is itself withheld');
});

test('V774 block H separates a cohort that is too RECENT from one that is too SMALL', () => {
  /* Until a customer's first visit is window_days old they cannot yet have failed to come back.
     The reader reports them as immature and returns 0 of 0; printing that as "too few to say"
     reads as a verdict on the staff member when it is a verdict on the calendar. */
  const section = sectionOf(render({ ...FULL, staff: STAFF_IMMATURE }), 'ci-brief-staff-v774');
  const text = textOf(section);
  assert.ok(text.includes('Across everyone: 8 customers too recent to judge — a customer counts after 60 days.'));
  assert.deepEqual(rowsOf(section, 'Came back within 60 days'),
    ['5 customers too recent to judge', '1 customer too recent to judge'],
    'and the singular is a singular');
  assert.deepEqual(rowsOf(section, 'To the same person'),
    ['5 customers too recent to judge', '1 customer too recent to judge']);
  assert.ok(!text.includes('too few to say'), 'nothing here is a sample-size statement');
  assert.ok(!text.includes('0 of 0'));

  /* A cohort that HAS matured but sits under the floor keeps the sample-size wording. */
  const matured = sectionOf(render(FULL), 'ci-brief-staff-v774');
  assert.ok(textOf(matured).includes('0 of 4 — too few to say'));
  assert.ok(!textOf(matured).includes('too recent to judge'));
});

test('V774 block H says so when nobody was attributed a visit', () => {
  const section = sectionOf(render({ ...FULL, staff: { ...STAFF, staff: [], firm: null, unattributed_visits: 0 } }), 'ci-brief-staff-v774');
  assert.ok(textOf(section).includes('No staff-attributed visits in this period yet.'));
});

/* ==================================================================================================
   I — reward popularity.
   ================================================================================================== */

test('V774 block I keeps the reward nobody redeemed, which is the row the block exists for', () => {
  const section = sectionOf(render(FULL), 'ci-brief-rewards-v774');
  const text = textOf(section);
  assert.ok(text.includes('8 redemptions by 8 customers, out of 9 who visited.'));
  assert.ok(text.includes('ZZ Never Redeemed'), 'a live reward with zero redemptions still renders');
  assert.equal((section.match(/<td data-label="Reward">/g) || []).length, 4, 'all four rewards render');

  /* A share of a KNOWN total is a fact, so the counts always print and the percent joins them
     only when the server supplied one. Contrast the rate over PEOPLE beside it, where a missing
     pct is a sample-size statement and has to say so. */
  assert.deepEqual(rowsOf(section, 'Share of all redemptions'),
    ['5 of 8 (63%)', '1 of 8', '1 of 8', '0 of 8']);
  assert.deepEqual(rowsOf(section, 'Redeemed by'),
    ['5 of 9 (56%)', '1 of 9 — too few to say', '1 of 9 — too few to say', '0 of 9 — too few to say']);

  /* Owner copy, not the reader's own sentences: the scope note named a filter and the limitation
     named an RPC, neither of which an owner has any way to read. */
  assert.ok(text.includes('Counted across all branches.'));
  assert.ok(text.includes('Counts points and stamp rewards only. Welcome, birthday, bring-back and referral gifts are given rather than redeemed, so they are not listed here.'));
  assert.ok(!text.includes('Redemptions are business-wide'));
  assert.ok(!/get_ci_/.test(text), 'no reader is ever named to an owner');
});

test('V774 block I marks a paused reward and a switched-off one, and marks neither when the reader said neither', () => {
  const section = sectionOf(render(FULL), 'ci-brief-rewards-v774');
  const pills = section.match(/<td data-label="Status">([\s\S]*?)<\/td>/g).map(textOf);
  assert.deepEqual(pills, ['', 'Paused', 'Off', ''],
    'rw1 live, rw2 paused, rw4 no longer active, rw3 live');

  /* A reward whose loyalty_rewards row is gone carries active and paused as null, not false.
     "Off" there would be the brief asserting something the reader deliberately did not. */
  const deleted = sectionOf(render({
    ...FULL,
    rewards: { ...REWARDS, rewards: [{ ...REWARDS.rewards[0], active: null, paused: null }] }
  }), 'ci-brief-rewards-v774');
  assert.deepEqual((deleted.match(/<td data-label="Status">([\s\S]*?)<\/td>/g) || []).map(textOf), ['']);
});

test('V774 block I says so when no reward was redeemed at all', () => {
  const section = sectionOf(render({
    ...FULL,
    rewards: { ...REWARDS, rewards: [], totals: { redemptions: 0, customers: 0, points_spent: 0, eligible_customers: 9 } }
  }), 'ci-brief-rewards-v774');
  const text = textOf(section);
  assert.ok(text.includes('0 redemptions by 0 customers, out of 9 who visited.'));
  assert.ok(text.includes('No reward redemptions in this period.'));
});

/* ==================================================================================================
   J — visit rhythm.
   ================================================================================================== */

test('V774 block J reads the window total from the reader and never sums the days array', () => {
  const section = sectionOf(render(FULL), 'ci-brief-when-v774');
  const text = textOf(section);
  assert.ok(text.includes('Valid visits'));
  assert.ok(text.includes('14'), 'current.visits, which v775 added for exactly this tile');
  assert.ok(text.includes('vs the previous 28 days: +1300%'), 'captioned by change.visits_pct');
  assert.ok(text.includes('Days covered'));
  assert.ok(text.includes('2026-03-02 to 2026-03-29'));

  /* The proof that the tile READS the total rather than deriving it: hand the reader a total
     that disagrees with the days array and the tile must follow the reader. Every `share`
     denominator and `change` on this payload was computed from that same figure, so a browser-
     side sum could silently disagree with the percentages printed beneath it. */
  const disagreeing = sectionOf(render({
    ...FULL, rhythm: { ...RHYTHM, current: { visits: 99, revenue_cents: 124000 } }
  }), 'ci-brief-when-v774');
  const tile = disagreeing.slice(0, disagreeing.indexOf('Busiest day'));
  assert.ok(textOf(tile).includes('99'));
  assert.ok(!textOf(tile).includes('14'), 'the days array is never summed into this tile');

  /* An older payload with no `current` abstains rather than falling back to a sum. */
  const older = { ...RHYTHM };
  delete older.current;
  const withoutTotal = sectionOf(render({ ...FULL, rhythm: older }), 'ci-brief-when-v774');
  const olderTile = withoutTotal.slice(0, withoutTotal.indexOf('Busiest day'));
  assert.ok(textOf(olderTile).includes('—'));
  assert.ok(!textOf(olderTile).includes('14'));
});

test('V774 block J abstains from the comparison when there is no earlier window', () => {
  const section = sectionOf(render({
    ...FULL, rhythm: { ...RHYTHM, change: { visits_pct: null, revenue_pct: null } }
  }), 'ci-brief-when-v774');
  assert.ok(textOf(section).includes('no earlier data to compare'));
  assert.ok(!textOf(section).includes('vs the previous 28 days'));

  const down = sectionOf(render({
    ...FULL, rhythm: { ...RHYTHM, change: { visits_pct: -25.4, revenue_pct: null } }
  }), 'ci-brief-when-v774');
  assert.ok(textOf(down).includes('vs the previous 28 days: −25%'), 'a fall carries a real minus sign');
});

test('V774 block J ranks the week and the two-hour blocks from the reader, and hides a closed block', () => {
  const section = sectionOf(render(FULL), 'ci-brief-when-v774');
  const text = textOf(section);
  assert.ok(text.includes('Busiest days: Monday, Tuesday · Slowest days: Saturday, Sunday'));
  assert.ok(text.includes('Busiest open times: 10am–12pm, 2pm–4pm · Quietest open times: 2pm–4pm, 10am–12pm'));
  assert.ok(text.includes('a two-hour block counts as open when it saw visits on at least 3 days'));

  /* V522's rule holds for these blocks too: a bare "Visits" column on this page would read as
     the customer table's Paid visits, which counts only visits that charged. These five readers
     scope on sales.counts_as_visit — the Dashboard's counter — so the column carries that name
     and the block says once which of the two it is. */
  assert.ok(!/<th>Visits<\/th>/.test(section) && !/data-label="Visits"/.test(section));
  assert.ok(section.includes('<th>Valid visits</th>'));
  assert.ok(text.includes("That is the Dashboard's counter, not the Paid visits column above."));
  const perDay = rowsOf(section, 'Visits per day');
  assert.deepEqual(perDay, ['1.3', '0.8', '0.8', '0.5', '0.3', '0.0', '0.0'],
    'per_occurrence to one decimal, straight from the reader');

  const times = rowsOf(section, 'Time');
  assert.ok(times.includes('10am–12pm') && times.includes('2pm–4pm') && times.includes('6pm–8pm'));
  assert.ok(!times.includes('8am–10am'), 'a block with no visits that never opened is not a row');
  assert.ok(text.includes('10 of 14 (71%)'), 'the share of visits carries its own base');
  assert.ok(text.includes('1 of 14 — too few to say'), 'and a withheld share says so');
});

test('V774 block J prints a suppressed age cell as "fewer than 5" and never as zero', () => {
  const section = sectionOf(render(FULL), 'ci-brief-when-v774');
  const text = textOf(section);
  assert.ok(text.includes('Who comes when'));
  const whoCame = rowsOf(section, 'Who came');
  assert.deepEqual(whoCame, [
    '25–30: 8',
    '25–30: fewer than 5 · 41–50: fewer than 5',
    '25–30: fewer than 5'
  ], 'one row per block, every band kept in place, a below-floor cell named rather than zeroed');
  assert.ok(text.includes('Age known for 12 of 13 visits.'));
});

test('V774 block J shows only the last fourteen days of the daily table', () => {
  const section = sectionOf(render(FULL), 'ci-brief-when-v774');
  const dates = rowsOf(section, 'Date');
  assert.equal(dates.length, 14);
  assert.equal(dates[0], '2026-03-16');
  assert.equal(dates[13], '2026-03-29');
  assert.ok(!section.includes('2026-03-02</b>'), 'the first day of a 28-day window is not in the last-14 table');

  const noDays = sectionOf(render({ ...FULL, rhythm: { ...RHYTHM, days: [] } }), 'ci-brief-when-v774');
  assert.ok(!textOf(noDays).includes('Last 14 days'), 'no days, no table');
});

/* ==================================================================================================
   K — demographic totals.
   ================================================================================================== */

test('V774 block K measures every share against the known population and names the rest separately', () => {
  const section = sectionOf(render(FULL), 'ci-brief-who-v774');
  const text = textOf(section);
  assert.ok(text.includes('Female'), 'the stored value is shown as a word an owner reads');
  assert.ok(!text.includes('female'), 'and never as the stored token');
  assert.ok(text.includes('6 of 8 (75%)'), 'the share is against the eight customers whose gender is known');
  assert.ok(text.includes('Unknown: 1 customer'));
  assert.ok(text.includes('Gender known for 8 of 9 customers.'));
  assert.ok(text.includes('Age known for 8 of 9 customers.'));
  assert.ok(text.includes('25–30') && text.includes('41–50'), 'age bands print as ranges, not as stored keys');
  assert.ok(!text.includes('25_30'));
});

test('V774 block K breaks each item down by group, withholding a share under the floor', () => {
  const section = sectionOf(render(FULL), 'ci-brief-who-v774');
  const text = textOf(section);
  assert.ok(text.includes('What each group buys'));
  assert.deepEqual(rowsOf(section, 'Women'), ['5 of 6 (83%)', '3 of 4 — too few to say']);
  assert.deepEqual(rowsOf(section, 'Men'), ['1 of 6 — too few to say', '1 of 4 — too few to say'],
    'a withheld percent still shows what the count is measured against');
  assert.deepEqual(rowsOf(section, 'Top age band'), ['25–30 (100%)', '—'],
    'an item whose age split is entirely below the floor names no top band at all');
});

test('V774 block K explains the gap in words an owner can act on', () => {
  const text = textOf(sectionOf(render(FULL), 'ci-brief-who-v774'));
  assert.ok(text.includes('Gender and date of birth are known only for customers who created a Peekaa account or whose profile a staff member completed. Walk-ins added at the till have neither until someone records it.'));
});

test('V774 block K says what to do when nobody has told you anything yet', () => {
  const section = sectionOf(render({
    ...FULL,
    demographics: {
      ...DEMOGRAPHICS, gender: [], age_bands: [], by_item: [],
      unknown_gender: { customers: 9, revenue_cents: 121000 },
      unknown_age: { customers: 9, revenue_cents: 121000 }
    }
  }), 'ci-brief-who-v774');
  assert.ok(textOf(section).includes(
    'No customer has a gender or date of birth on record yet. Customers who create a Peekaa account are asked for both.'));
});

/* ==================================================================================================
   Absence, refusal, and the standing vocabulary rules.
   ================================================================================================== */

test('V774 a reader that returned nothing and raised nothing removes its block entirely', () => {
  const html = render({
    ...FULL,
    cashGap: null, cashGapError: '', staff: null, staffError: '',
    rewards: null, rewardsError: '', rhythm: null, rhythmError: '',
    demographics: null, demographicsError: ''
  });
  for (const className of ['ci-brief-cash-v774', 'ci-brief-staff-v774', 'ci-brief-rewards-v774',
    'ci-brief-when-v774', 'ci-brief-who-v774']) {
    assert.equal(sectionOf(html, className), '', `${className} is absent, not an empty shell`);
  }
  assert.ok(html.includes('<section class="card ci-owner-brief-v771"'), 'the brief itself still renders');
});

test('V774 a reader that refused shows one quiet error row and blanks nothing else', () => {
  const html = render({
    ...FULL,
    cashGap: null, cashGapError: 'permission denied for function get_ci_cash_gap_v1',
    staff: null, staffError: 'timeout',
    rewards: null, rewardsError: 'branch does not belong to business',
    rhythm: null, rhythmError: 'nope',
    demographics: null, demographicsError: 'nope'
  });
  assert.ok(sectionOf(html, 'ci-brief-cash-v774').includes('<div class="err" role="status">'));
  assert.ok(sectionOf(html, 'ci-brief-cash-v774').includes('Money recorded vs collected could not load.'));
  assert.ok(sectionOf(html, 'ci-brief-staff-v774').includes('Staff: who brings customers back could not load.'));
  assert.ok(sectionOf(html, 'ci-brief-rewards-v774').includes('Most popular rewards could not load.'));
  assert.ok(sectionOf(html, 'ci-brief-when-v774').includes('When customers come in could not load.'));
  assert.ok(sectionOf(html, 'ci-brief-who-v774').includes('Who your customers are could not load.'));
  assert.equal((html.match(/<div class="err" role="status">/g) || []).length, 5);
});

test('V774 the new blocks never name WhatsApp and never leak machine vocabulary', () => {
  const cases = [
    FULL,
    { ...FULL, canOpenCustomers: false },
    { ...FULL, cashGap: null, cashGapError: 'x', staff: null, staffError: 'x', rewards: null, rewardsError: 'x', rhythm: null, rhythmError: 'x', demographics: null, demographicsError: 'x' },
    { ...FULL, cashGap: {}, staff: {}, rewards: {}, rhythm: {}, demographics: {} },
    { ...FULL, staff: STAFF_IMMATURE },
    {
      ...FULL,
      cashGap: { totals: {}, by_method: [{}], outstanding_by_customer: [{}], unlinked_payments: {} },
      staff: { firm: {}, staff: [{}] },
      rewards: { totals: {}, rewards: [{}] },
      rhythm: { days: [{}], weekdays: [{}], hour_blocks: [{}], age_by_block: [{ block_start: 0 }], busiest_weekdays: [{}], slowest_weekdays: [{}], coverage: {} },
      demographics: { gender: [{}], age_bands: [{}], by_item: [{}], coverage: {} }
    }
  ];
  const NEW_BLOCKS = ['ci-brief-when-v774', 'ci-brief-cash-v774', 'ci-brief-staff-v774',
    'ci-brief-rewards-v774', 'ci-brief-who-v774'];
  for (const [index, fixture] of cases.entries()) {
    const html = render(fixture);
    assert.ok(!/whatsapp/i.test(html), `fixture ${index}: analytics must not display anything with WhatsApp`);
    /* The whole brief, against the v771 list. */
    const wholeText = textOf(html);
    for (const banned of ['NaN', 'undefined', 'null', 'bps', 'cents', 'Infinity', 'identified']) {
      assert.ok(!wholeText.includes(banned),
        `fixture ${index}: "${banned}" must never reach an owner (${wholeText.slice(0, 500)})`);
    }
    /* The five new blocks, against the fuller owner list. "identified" now appears in the
       whole-brief scan above too: nestly_v776 reworded block D's empty state, which was the one
       place in the brief still using it. */
    const newText = textOf(NEW_BLOCKS.map((className) => sectionOf(html, className)).join(' '));
    /* Blocks I and K were given owner copy in place of the readers' own closing sentences, so
       neither may name a reader. Block G still prints its basis_note verbatim — that sentence is
       the one thing an owner has to know about the figures above it — so the check is scoped
       rather than applied to the whole brief. */
    for (const className of ['ci-brief-rewards-v774', 'ci-brief-who-v774']) {
      const owned = textOf(sectionOf(html, className));
      assert.ok(!/reader|get_ci_/.test(owned), `fixture ${index}: ${className} speaks to an owner`);
    }
    for (const banned of ['NaN', 'undefined', 'null', 'bps', 'cents', 'identified',
      'DIRECT_FACT', 'ASSOCIATION', 'evidence', 'Infinity', '_']) {
      assert.ok(!newText.includes(banned),
        `fixture ${index}: "${banned}" must never reach an owner (${newText.slice(0, 500)})`);
    }
  }
});

test('V774 the brief still renders from an empty object with all five readers unwired', () => {
  const html = render({});
  assert.ok(html.includes('<section class="card ci-owner-brief-v771" aria-labelledby="ciOwnerBriefTitleV771">'));
  assert.ok(!/NaN|undefined|Infinity/.test(textOf(html)));
  for (const className of ['ci-brief-cash-v774', 'ci-brief-staff-v774', 'ci-brief-rewards-v774',
    'ci-brief-when-v774', 'ci-brief-who-v774']) {
    assert.equal(sectionOf(html, className), '');
  }
});

/* ==================================================================================================
   Composition and wiring — the parts that cannot be executed from here.
   ================================================================================================== */

test('V774 the brief reads in the order an owner asks the questions in', () => {
  const at = (needle) => block.indexOf(needle);
  /* nestly_v778 inserted block L ("Your branches side by side") directly after block A: which
     branches this brief covers is the question an owner asks before any of the ones below it, and
     the answer has to sit next to the totals it splits. The rest of the order is untouched. */
  const line = app.slice(app.indexOf('    ${glanceV771}${branchesV778}${whenV774}'));
  const order = line.slice(0, line.indexOf('\n'));
  assert.equal(order.trim(),
    '${glanceV771}${branchesV778}${whenV774}${bringBackV771}${cashGapV774}${unusedV771}${topCustomersV771}${servicesV771}${staffBlockV774}${rewardsBlockV774}${whoV774}${limitsV771}');
  assert.ok(at('const glanceV771=') > -1 && at('let whenV774=') > -1,
    'every block still assembles its own markup before the section is concatenated');
});

test('V774 all five readers are called with the page scope, and captured independently', () => {
  for (const rpc of ['get_ci_cash_gap_v1', 'get_ci_staff_rebooking_v1', 'get_ci_reward_popularity_v1',
    'get_ci_visit_rhythm_v1', 'get_ci_demographic_totals_v1']) {
    const at = app.indexOf(`sb.rpc('${rpc}'`);
    assert.ok(at > -1, `${rpc} is called from the page`);
    const call = app.slice(at, app.indexOf('})', at));
    assert.ok(call.includes('p_business:S.biz.id'), `${rpc} is scoped to the open business`);
    assert.ok(call.includes('p_branch:selectedBranchId||null'), `${rpc} respects the top bar's branch scope`);
    assert.ok(call.includes('p_from:fromDate') && call.includes('p_to:toDate'), `${rpc} takes the report range`);
    assert.ok(!call.includes('p_as_of'), `${rpc} leaves p_as_of to the reader's own default`);
  }
  assert.ok(app.includes("p_window_days:60,p_branch:selectedBranchId||null"),
    'the staff reader is given its rebooking window explicitly');

  for (const name of ['CashGap', 'StaffRebooking', 'RewardPopularity', 'VisitRhythm', 'DemographicTotals']) {
    assert.ok(app.includes(`last${name}BundleV774=`), `${name} has its own bundle`);
    assert.ok(app.includes(`last${name}ErrorV774=`), `${name} has its own error, so one refusal blanks one block`);
  }
});
