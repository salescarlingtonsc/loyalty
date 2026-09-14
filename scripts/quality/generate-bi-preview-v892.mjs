/* nestly_v892 — a static preview of the Business Intelligence primary surface, for owner
 * acceptance at 1440 and 375 without a login, a database or a running app.
 *
 * It extracts the v892 presentation layer straight out of app/app.js — the same source the app
 * ships — runs it in a sandbox against a Cubbly-shaped fixture bundle, and writes the rendered
 * snapshot, cards, pulse, health and overnight strip into one page that links the REAL
 * app/app.css and app/revenue-truth.css. So what the owner screenshots is what the page renders,
 * not a mock-up of it.
 *
 * Three states are rendered side by side, because an owner acceptance that only ever sees the
 * happy path is not an acceptance:
 *   1. a real month  — everything present, a comparison available, three things to know, a full
 *                       "Who buys what" with mixed known and unknown crowds, and four ideas;
 *   2. a thin month  — no earlier window, no cash reader, one customer, nothing ranked, and both
 *                       nestly_v902 sections absent rather than rendered empty;
 *   3. a new business — no sales, no customers, no readers at all.
 *
 * Run: node scripts/quality/generate-bi-preview-v892.mjs
 * Then open tests/browser/bi-preview-v892.html in a browser.
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const from = app.indexOf('/* nestly_v892 — BUSINESS INTELLIGENCE');
const to = app.indexOf('/* nestly_v892 END —', from);
if (from < 0 || to < from) throw new Error('the v892 presentation layer was not found in app/app.js');
const block = app.slice(from, to);

function surface(lines) {
  const context = vm.createContext({
    esc: (x) => String(x ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'),
    money: (c) => `SGD ${((c || 0) / 100).toFixed(2)}`,
    walletDate: (v) => String(v),
    CUI: { icon: () => '' },
    S: { biz: { currency: 'SGD' }, myRole: 'owner' },
    RevenueTruthUI: {
      money: (cents, currency) => new Intl.NumberFormat('en-SG', {
        style: 'currency', currency: String(currency || 'SGD'), currencyDisplay: 'code',
        minimumFractionDigits: 2, maximumFractionDigits: 2
      }).format(Number(cents) / 100)
    },
    ownerBriefLinesV826: () => lines
  });
  context.__exports = {};
  vm.runInContext(`${block}
    __exports.render=(bundles,response)=>{
      const model=biModelV892(bundles);
      return biSnapshotHtmlV892(model)
        +biInsightsHtmlV892(biSelectInsightsV892(model))
        +biWhoBuysHtmlV902(model)
        +biPulseHtmlV892(model)
        +biHealthHtmlV892(model)
        +biIdeasHtmlV902(model)
        +biOvernightStripHtmlV892(response);
    };`, context);
  return context.__exports.render;
}

/* ---- Fixture: one real month at Cubbly SPA ------------------------------------------------ */
const REAL = {
  currency: 'SGD', periodDays: 30, from: '2026-08-16', to: '2026-09-14',
  scope: { branchId: null, branchCode: null, branchName: null, companySlug: 'cubbly', companyName: 'Cubbly SPA' },
  truth: { status: 'ok', totals: { known_revenue_minor: 668330, identified_revenue_minor: 656330 } },
  truthPrev: { status: 'ok', totals: { known_revenue_minor: 596723 } },
  lifecycle: { status: 'ok', metrics: { transacting_identified_customers: 9, new_customers: 3 } },
  lifecyclePrev: { status: 'ok', metrics: { transacting_identified_customers: 8, new_customers: 2 } },
  cashGap: {
    totals: {
      revenue_recorded_cents: 668330, collected_cents: 421429, outstanding_cents: 244500,
      sales_count: 24, sales_fully_paid: 16, sales_partly_paid: 2, sales_unpaid: 6,
      collected_share: { numerator: 421429, denominator: 668330, pct: 63.0 }
    },
    unlinked_payments: { count: 1, cents: 4500 }, refunds_cents: 0,
    outstanding_by_customer: [{ client_id: 'c7', client_name: 'Gil Tan', sales: 1, outstanding_cents: 200000 }],
    names_visible: true
  },
  /* nestly_v894: the first row is an identity erased under PDPA — erase_client_v290's own
     placeholder, verbatim — so the preview demonstrates that the card DESCRIBES the customer
     rather than heading itself "Erased customer usually visits every 19 days". */
  attention: {
    rows: [
      { client_id: 'c9', full_name: 'Erased customer', phone: null, status: 'slipping', last_visit_days: 48, cadence_days: 19.2 },
      { client_id: 'c2', full_name: 'Wei Ling', phone: null, status: 'due', last_visit_days: 18, cadence_days: 17.6 }
    ],
    summary: { due: 1, overdue: 2, slipping: 1, considered: 9, one_time_count: 2, monthly_at_risk_cents: 145700 }
  },
  packages: [
    { client_id: 'c1', remaining: 3, status: 'active', plan_name_snapshot: '4x Facial', list_unit_cents_snapshot: 9000 },
    { client_id: 'c2', remaining: 3, status: 'active', plan_name_snapshot: '5x Spa', list_unit_cents_snapshot: 12000 }
  ],
  customers: [
    { client_id: 'c1', full_name: 'Siti Rahman', net_revenue_cents: 357030, days_since_last_purchase: 62 },
    { client_id: 'c2', full_name: 'Wei Ling', net_revenue_cents: 180000, days_since_last_purchase: 18 },
    { client_id: 'c3', full_name: 'Kumar Rajan', net_revenue_cents: 34000, days_since_last_purchase: 3 }
  ],
  summary: { net_revenue_cents: 656330 },
  opportunities: {
    scope: { currency: 'SGD' },
    ranked: [
      {
        id: 'coverage_defect', rank: 1, rank_class: 'foundation', domain: 'coverage',
        pattern: 'Only 56.8% of revenue is sorted into categories, and 33% of customers have an age on file.',
        action: { what: 'Map every service and product to a category in Settings.' },
        impact: { cents: null }, confidence: { n: 24, floor: 5, status: 'ok' },
        limitation: 'Coverage is not accuracy.'
      },
      /* nestly_v894: the third card the owner marked up. Its `pattern` is the analyst sentence
         production really emits, cents and all — the preview proves none of it reaches the
         screen, and that the heading is built from evidence.refs instead. */
      {
        id: 'category_concentration', rank: 2, rank_class: 'unquantified', domain: 'category_mix',
        pattern: '141000 cents of 168000 cents of classified revenue — 83.9% — comes from a single '
          + 'category (Facial), bought by 6 customers. Its top customer alone accounts for 39.8% of the category.',
        action: { what: 'Treat Facial as a single point of failure.' },
        impact: { cents: null }, confidence: { n: 6, floor: 5, status: 'ok' },
        concentration: { top1_share_bps: 3980, mean_excl_top1: 16000 },
        evidence: {
          source_rpc: 'public.get_ci_category_mix_v1',
          refs: {
            top_category: { node_key: 'facial', label: 'Facial', revenue_cents: 141000, customer_count: 6 },
            classified_revenue_cents: 168000, top_share_bps: 8393, coverage: { classified_pct_bps: 5680 }
          }
        },
        evidence_class: 'DIRECT_FACT',
        limitation: 'A concentrated mix is not automatically a fault.',
        reversal_condition: 'Reconsider if the share falls below the bar.'
      },
      {
        id: 'package_leakage:plan_small', rank: 4, rank_class: 'quantified', domain: 'packages',
        pattern: 'Six prepaid facial packages have sessions left that nobody has booked.',
        action: { what: 'Call the six holders and book their remaining sessions.' },
        impact: { cents: 54000 }, confidence: { n: 9, floor: 5, status: 'ok' },
        evidence: { refs: { plan_name: '4x Facial', unused_sessions: 6, per_session_cents: 9000 } },
        evidence_class: 'DIRECT_FACT',
        limitation: 'It cannot see a session booked outside Peekaa.',
        reversal_condition: 'Peekaa drops this once the remaining sessions are booked.'
      }
    ],
    report_sections: { strengths: [], leakage: ['package_leakage:plan_small'], failures: [] }
  },
  rhythm: {
    weekdays: [
      { dow: 2, label: 'Tuesday', visits: 5, occurrences: 4, per_occurrence: 1.3, revenue_cents: 116900 },
      { dow: 5, label: 'Friday', visits: 1, occurrences: 4, per_occurrence: 0.3, revenue_cents: 9000 }
    ],
    busiest_weekdays: [{ dow: 2, label: 'Tuesday', visits: 5, occurrences: 4, per_occurrence: 1.3 }],
    /* nestly_v902: the server names its own quiet day, which is what the third idea quotes. */
    slowest_weekdays: [{ dow: 5, label: 'Friday', visits: 1, occurrences: 4, per_occurrence: 0.3 }]
  },
  /* nestly_v902: get_ci_demographic_totals_v1's own by_item, with one of every case the section
     has to handle — a till bookkeeping line with no catalogue id (dropped), an item whose buyers
     told the business both things, one that told it only their age and below the server's own
     evidence floor, one that told it only their gender, and one that told it nothing. */
  demographics: {
    coverage: { gender_known: { numerator: 3, denominator: 9, pct: 33.3 }, age_known: { numerator: 3, denominator: 9, pct: 33.3 } },
    by_item: [
      {
        item_id: null, item_name: 'Cart line', item_type: 'custom', revenue_cents: 220000, buyers: 14,
        by_gender: [{ gender: 'female', buyers: 14, share_of_item_buyers: { numerator: 14, denominator: 14, pct: 100.0 }, evidence: { n: 14, floor: 5, status: 'ok' } }],
        by_age_band: [{ age_band: '25_30', buyers: 14, share_of_item_buyers: { numerator: 14, denominator: 14, pct: 100.0 }, evidence: { n: 14, floor: 5, status: 'ok' } }]
      },
      {
        item_id: 'svc_facial', item_name: 'Signature facial', item_type: 'service', revenue_cents: 141000, buyers: 6,
        buyers_known_gender: 6, buyers_known_age: 5,
        by_gender: [
          { gender: 'female', buyers: 5, revenue_cents: 120000, share_of_item_buyers: { numerator: 5, denominator: 6, pct: 83.3 }, evidence: { n: 5, floor: 5, status: 'ok' } },
          { gender: 'male', buyers: 1, revenue_cents: 21000, share_of_item_buyers: { numerator: 1, denominator: 6, pct: null }, evidence: { n: 1, floor: 5, status: 'insufficient' } }
        ],
        by_age_band: [{ age_band: '25_30', buyers: 5, revenue_cents: 118000, share_of_item_buyers: { numerator: 5, denominator: 5, pct: 100.0 }, evidence: { n: 5, floor: 5, status: 'ok' } }]
      },
      {
        item_id: 'svc_colour', item_name: 'Hair colour', item_type: 'service', revenue_cents: 96000, buyers: 4,
        buyers_known_gender: 0, buyers_known_age: 4, by_gender: [],
        by_age_band: [{ age_band: '41_50', buyers: 3, revenue_cents: 72000, share_of_item_buyers: { numerator: 3, denominator: 4, pct: null }, evidence: { n: 3, floor: 5, status: 'insufficient' } }]
      },
      {
        item_id: 'prd_shampoo', item_name: 'Repair shampoo', item_type: 'product', revenue_cents: 24000, buyers: 5,
        buyers_known_gender: 5, buyers_known_age: 0,
        by_gender: [{ gender: 'male', buyers: 4, revenue_cents: 19000, share_of_item_buyers: { numerator: 4, denominator: 5, pct: 80.0 }, evidence: { n: 4, floor: 5, status: 'ok' } }],
        by_age_band: []
      },
      {
        item_id: 'svc_massage', item_name: 'Head massage', item_type: 'service', revenue_cents: 18000, buyers: 3,
        buyers_known_gender: 0, buyers_known_age: 0, by_gender: [], by_age_band: []
      },
      {
        item_id: 'svc_brow', item_name: 'Brow shaping', item_type: 'service', revenue_cents: 6000, buyers: 2,
        buyers_known_gender: 2, buyers_known_age: 2,
        by_gender: [{ gender: 'female', buyers: 2, share_of_item_buyers: { numerator: 2, denominator: 2, pct: 100.0 }, evidence: { n: 2, floor: 5, status: 'insufficient' } }],
        by_age_band: [{ age_band: '20_24', buyers: 2, share_of_item_buyers: { numerator: 2, denominator: 2, pct: 100.0 }, evidence: { n: 2, floor: 5, status: 'insufficient' } }]
      }
    ]
  },
  categoryMix: { status: 'ok', coverage: { classified_pct_bps: 5680 } },
  contactability: { business_offers: { customers: 9, allowed_by_channel: { sms: 6, email: 4 } } },
  funnelConversion: { stage_1_to_2: { numerator: 3, denominator: 7, pct: 42.9 } },
  action: { allowed: false, title: '', finding: '', costMinor: null }
};

/* ---- Fixture: a thin month — no earlier window, no cash reader, one customer -------------- */
const THIN = {
  currency: 'SGD', periodDays: 30, from: '2026-08-16', to: '2026-09-14',
  scope: { branchId: 'b1', branchCode: 'TMP', branchName: 'Tampines' },
  truth: { status: 'ok', totals: { known_revenue_minor: 4500 } },
  truthPrev: null,
  lifecycle: { status: 'ok', metrics: { transacting_identified_customers: 1, new_customers: 1 } },
  lifecyclePrev: null,
  cashGap: null, attention: null, packages: [], customers: [{ client_id: 'c1', full_name: 'First customer', net_revenue_cents: 4500 }],
  summary: { net_revenue_cents: 4500 },
  opportunities: { ranked: [], report_sections: {} },
  rhythm: null, demographics: null, categoryMix: null, contactability: null,
  funnelConversion: { stage_1_to_2: { numerator: 0, denominator: 1, pct: null } },
  action: { allowed: false }
};

/* ---- Fixture: a brand-new business — nothing recorded at all ------------------------------ */
const EMPTY = {
  currency: 'SGD', periodDays: 30, from: '2026-08-16', to: '2026-09-14',
  scope: { branchId: null, companyName: 'New business' },
  truth: { status: 'insufficient' }, lifecycle: { status: 'insufficient' },
  cashGap: null, attention: null, packages: null, customers: [], summary: null,
  opportunities: null, rhythm: null, demographics: null, categoryMix: null,
  contactability: null, funnelConversion: null, action: { allowed: false }
};

const BRIEF_LINES = [
  { kind: 'plain', text: 'Last 7 days: SGD 1,240.00, 12% above a normal week (SGD 1,107.00). More people, not bigger orders.' },
  { kind: 'plain', text: 'Busiest day Tuesday, slowest Friday, quietest stretch 3pm–5pm (8% of visits).' },
  { kind: 'plain', text: '3 new customers, 6 returning.' },
  { kind: 'warn', text: '2 regulars are overdue their usual visit (SGD 240.00 a month at stake).' },
  { kind: 'plain', text: 'Most redeemed reward: Free scalp massage (7 in 8 weeks).' }
];

const renderReal = surface(BRIEF_LINES);
const renderBare = surface([]);
const pane = (title, note, html) => `<section class="bi-preview-pane">
  <header class="bi-preview-head"><h2>${title}</h2><p>${note}</p></header>
  <div class="main">${html}</div>
</section>`;

const page = `<!doctype html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Peekaa — Business Intelligence preview (nestly_v892)</title>
<link rel="stylesheet" href="../../app/app.css">
<link rel="stylesheet" href="../../app/revenue-truth.css">
<style>
  body{margin:0;background:var(--bg);color:var(--ink);font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text','Inter',system-ui,sans-serif}
  .bi-preview-pane{max-width:1180px;margin:0 auto;padding:20px 16px 40px}
  .bi-preview-head{padding:18px 0 10px;border-bottom:1px dashed var(--line);margin-bottom:16px}
  .bi-preview-head h2{margin:0;font-size:15px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted)}
  .bi-preview-head p{margin:4px 0 0;font-size:13px;color:var(--ink2)}
</style>
</head>
<body>
${pane('1 · A real month', 'Everything present: a comparison against the previous 30 days, three things to know (money not collected, a customer whose identity was erased, and the single-category exposure), Who buys what with one of every crowd case, a full pulse, every health row, and four ideas.', renderReal(REAL, { data_status: 'ok', as_of: '2026-09-14', brief: { week: {} } }))}
${pane('2 · A thin month, one branch selected', 'No earlier window to compare against, no payments reader, one customer, nothing ranked yet — and Peekaa says which of those it is. Who buys what and Ideas to try are absent, not empty.', renderBare(THIN, null))}
${pane('3 · A brand-new business', 'No sales, no customers, no readers. Every figure is a dash and nothing is invented as a zero.', renderBare(EMPTY, null))}
</body>
</html>
`;

const out = join(root, 'tests', 'browser', 'bi-preview-v892.html');
writeFileSync(out, page);
process.stdout.write(`wrote ${out}\n`);
