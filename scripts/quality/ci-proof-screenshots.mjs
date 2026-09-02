#!/usr/bin/env node
/**
 * CI-100-CHECKLIST proof-pack items 11 (browser screenshots for every Customer Intelligence
 * answer state) and 12 (failure/abstention screenshots).
 *
 *   node scripts/quality/ci-proof-screenshots.mjs
 *
 * WHAT THIS DOES
 *   1. Extracts each REAL renderer straight out of app/app.js and app/platform-console.js, using
 *      the exact same anchor strings the repo's own executing tests already use (cited per state
 *      below) — never a hand-copied re-implementation, so a fixture can never quietly drift from
 *      production behaviour the way tests/qa/REALISTIC-FIXTURES.md warns against.
 *   2. Feeds each renderer a fixture payload copied from the SQL/test truth tables named per
 *      state — never invented numbers.
 *   3. Wraps the rendered HTML in the app's real CSS and writes a static page per state under
 *      tests/browser/ci-proof/<state>.html.
 *   4. If playwright-core (or `playwright`) is importable, serves the pages with a plain
 *      `python3 -m http.server` (not `serve`, which drops query strings — see
 *      [[browser-evidence-playwright-core]]) and captures a mobile (390x844) and a desktop
 *      (1280x800) PNG per state into docs/qa/proof-pack/screenshots/, then writes
 *      docs/qa/proof-pack/SCREENSHOTS.md as the index (state, payload source, file, sha256,
 *      commit sha, capture date).
 *      If no Playwright driver is importable in this environment, the HTML pages and the index
 *      are still produced (with a PENDING screenshot column) and the script exits 0, saying so —
 *      per instruction, it stops there rather than fabricating PNGs.
 *
 * CSS SOURCING. The existing browser-fixture generators (tests/browser/generate-*.mjs) only ever
 * embed app/index.html's inline <style> block, because every surface they cover is styled
 * entirely from there. The Customer Intelligence panels are NOT: their markup (revenue-truth-
 * section, ci-opportunity-*, cui-table, dashboard-metric classes) is styled from the "business"
 * surface's lazily-loaded stylesheets (see app/index.html's per-surface asset manifest, ~line
 * 5849) — app/revenue-truth.css and app/app.css — and the platform console's consultative brief
 * is styled from app/platform-console.css, which the merchant document never loads at all. So the
 * CSS bundle here is assembled per page: index.html's inline <style> (base tokens/shell) +
 * app/app.css (extracted rules, dashboard-metric/cui-table) + app/revenue-truth.css
 * (revenue-truth-section family) for the business-surface states, and app/platform-console.css
 * added for the one platform-console state. This is documented rather than silent because it is
 * a real judgement call, not a copy of an existing recipe — grep found NO dedicated CSS at all
 * for several v685/v705/v712 class names (ci-opportunities-list, ci-opportunity-alternatives-list,
 * data-materiality-class, margin-guard row spans), so those elements currently render with
 * browser-default/inherited styling only. That is evidence of a real gap (flagged in the index),
 * not a bug in this script.
 *
 * FORMERLY A KNOWN GAP, NOW CLOSED (nestly_v734, check 97): the "stale-freshness envelope" state.
 * db/migrations/20260902_nestly_v722_freshness_and_brief_evidence.sql added a `freshness` block
 * (data_as_of/age_hours/stale/note) to app.ci_envelope_v680's payload shape, but no renderer read
 * it — recorded below (`notRenderable`) as NOT-RENDERABLE rather than faked. app/app.js and
 * app/platform-console.js each now carry a ciFreshnessCaptionHtmlV734 renderer, wired into every
 * CI panel and the consultant brief, so this is a real rendered screenshot (id
 * 'stale-freshness-envelope' in `states` below) — never a bare disclosure line on its own, always
 * the full panel underneath it, since a stale envelope discloses, it never withholds.
 */
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync, existsSync, statSync } from 'node:fs';
import { execFileSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';
import { isDirectCliInvocation } from './is-direct-cli-invocation.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const P = (...parts) => join(root, ...parts);

const app = readFileSync(P('app', 'app.js'), 'utf8');
const consoleJs = readFileSync(P('app', 'platform-console.js'), 'utf8');
const indexHtml = readFileSync(P('app', 'index.html'), 'utf8');
const appCss = existsSync(P('app', 'app.css')) ? readFileSync(P('app', 'app.css'), 'utf8') : '';
const revenueTruthCss = readFileSync(P('app', 'revenue-truth.css'), 'utf8');
const platformConsoleCss = readFileSync(P('app', 'platform-console.css'), 'utf8');

const commitSha = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root }).toString().trim();
const captureDate = new Date().toISOString().slice(0, 10);

const esc = (x) => String(x ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const money = (c) => 'SGD ' + ((Number(c) || 0) / 100).toFixed(2);
const walletDate = (v) => String(v ?? '');

/* ---------------------------------------------------------------------------------------------
   EXTRACTION — same anchor strings the cited executing tests already use. If app.js/platform-
   console.js changes and an anchor moves, this throws loudly rather than silently rendering a
   stale slice — the same posture regen-visual-fixtures.mjs's own fixtures take.
   --------------------------------------------------------------------------------------------- */
function slice(source, start, end, label) {
  const from = source.indexOf(start);
  if (from < 0) throw new Error(`${label}: start anchor not found: ${start}`);
  const to = end === null ? source.length : source.indexOf(end, from + start.length);
  if (end !== null && to <= from) throw new Error(`${label}: end anchor not found: ${end}`);
  return source.slice(from, end === null ? undefined : to);
}

// funnelConversionPanelHtmlV679 / demographicsPanelHtmlV679 / behaviourPanelHtmlV679 —
// anchors from tests/business-ui/v679-ci-analyst-panels.test.mjs.
const v679Block = slice(app, 'function ciMeasuredSinceInlineV679(', 'async function serviceMappingBoardPage(){', 'v679 block');

// opportunitiesPanelHtmlV685 (+ v705/v712 rendering helpers) — anchors from
// tests/business-ui/v685-ci-surfaces.test.mjs / v716-ci-opportunities-impact.test.mjs.
const oppBlock = slice(app, 'function ciOpportunityConfidenceV685(',
  '/* nestly_v679 — Customer intelligence gets three more evidence-safe panels', 'opportunities block');

// The four v650-era closures (acquisitionMarkupV650 / funnelMarkupV650 / contactabilityMarkupV650
// / categoryMixMarkupV650) — anchors from tests/business-ui/v685-ci-surfaces.test.mjs section B.
const ciStateBlock = slice(app, "let lastAcquisitionBundle=null,lastAcquisitionError=''",
  'const CUSTOMER_INTELLIGENCE_PAGE_SIZE=100;', 'ci closure state');
const ciRendererBlock = slice(app, "const scopeMoney=(cents,currency=S.biz.currency||'SGD')=>",
  'function ciCategoryMixWrapV650(){', 'ci closure renderers');
const ciClosureBlock = ciStateBlock + '\n' + ciRendererBlock;

// nestly_v734 (check 97): ciFreshnessCaptionHtmlV734 is called by opportunitiesPanelHtmlV685 and
// the v650 quartet, but is defined outside both oppBlock and ciClosureBlock's anchor ranges (it
// lives between ciMeasuredSinceInlineV679 and funnelConversionPanelHtmlV679, i.e. inside v679Block
// only) — pulled in verbatim here, same pattern the executing tests use for the same gap.
const freshnessHelperStart = app.indexOf('function ciFreshnessCaptionHtmlV734(payload){');
if (freshnessHelperStart < 0) throw new Error('ciFreshnessCaptionHtmlV734 not found');
const freshnessHelperEnd = app.indexOf('\n}', freshnessHelperStart) + 2;
const freshnessBlock = app.slice(freshnessHelperStart, freshnessHelperEnd);

// groupVisitDaysV719 / visitDaySummaryV719 (+ validVisitSales, sgt) — anchors from
// tests/business-ui/v719-visits-drilldown-days.test.mjs.
const sgtLine = app.match(/^const sgt=.*$/m);
if (!sgtLine) throw new Error('sgt() line not found');
const validVisitBlock = slice(app, 'function validVisitSales(', 'async function fetchRowsByIds(', 'validVisitSales');
const groupBlock = slice(app, 'function groupVisitDaysV719(', '/* V468 (owner photos 3, 8 and 9', 'v719 block');

// dashboardMetricTileHtmlV405 (+ dashboardDeltaChipV170, DASHBOARD_METRIC_DEFINITIONS_V405,
// dashboardMetricWasLineV387) — anchors from tests/business-ui/v694-recorded-revenue-tiles.test.mjs.
const chipBlock = slice(app, 'function dashboardDeltaChipV170(', 'function helpDotMarkupV385(', 'delta chip');
const defsStart = app.indexOf('const DASHBOARD_METRIC_DEFINITIONS_V405={');
const defsEnd = app.indexOf('};', defsStart) + 2;
const defsBlock = app.slice(defsStart, defsEnd);
const tileBlock = slice(app, 'function dashboardMetricWasLineV387(', 'function dashboardDeltaLegendV385(', 'dashboard tile');

// ownerErrorText / OWNER_ERROR_NOISE_RULES_V170 — the app-wide RPC-error -> owner-copy translator,
// used here for the "RPC 42501 refusal" state (app/app.js ~line 2291/2325).
const errorMapBlock = slice(app, 'const OWNER_ERROR_NOISE_RULES_V170=[', 'const fail=e=>{', 'owner error map');

// consultativeIntelligenceHtml — anchors from
// tests/platform-console/v727-consultant-brief-unavailable.test.mjs.
const consultativeBlock = slice(consoleJs, 'function consultativeIntelligenceHtml(',
  'async function renderEnterpriseReport(', 'consultative brief');

// nestly_v734 (check 97): consultativeIntelligenceHtml calls platform-console.js's own copy of
// ciFreshnessCaptionHtmlV734, defined earlier in the file (next to dateTime), outside
// consultativeBlock's anchor range — pulled in verbatim, same pattern as
// tests/platform-console/v727-consultant-brief-unavailable.test.mjs's own fix for this gap.
const consoleFreshnessStart = consoleJs.indexOf('function ciFreshnessCaptionHtmlV734(payload) {');
if (consoleFreshnessStart < 0) throw new Error('platform-console.js ciFreshnessCaptionHtmlV734 not found');
const consoleFreshnessEnd = consoleJs.indexOf('\n  }', consoleFreshnessStart) + '\n  }'.length;
const consoleFreshnessBlock = consoleJs.slice(consoleFreshnessStart, consoleFreshnessEnd);

/* ---------------------------------------------------------------------------------------------
   VM RUNNERS
   --------------------------------------------------------------------------------------------- */
function runCiClosure() {
  const sandbox = { esc, walletDate, S: { biz: { currency: 'SGD' } } };
  const context = vm.createContext(sandbox);
  context.__exports = {};
  vm.runInContext(
    freshnessBlock + '\n' +
    ciClosureBlock +
    `\n__exports.acquisition=()=>acquisitionMarkupV650();` +
    `__exports.funnel=()=>funnelMarkupV650();` +
    `__exports.contactability=()=>contactabilityMarkupV650();` +
    `__exports.categoryMix=()=>categoryMixMarkupV650();` +
    `__exports.setAcquisition=(bundle,err)=>{lastAcquisitionBundle=bundle;lastAcquisitionError=err||'';};` +
    `__exports.setFunnel=(bundle,err)=>{lastFunnelBundle=bundle;lastFunnelError=err||'';};` +
    `__exports.setContactability=(bundle,err)=>{lastContactabilityBundle=bundle;lastContactabilityError=err||'';};` +
    `__exports.setCategoryMix=(bundle,err)=>{lastCategoryMixBundle=bundle;lastCategoryMixError=err||'';};` +
    `__exports.setCategoryCustomerCache=(nodeKey,cached)=>{categoryCustomersCacheV650.set(nodeKey,cached);};` +
    `__exports.expandNode=(nodeKey)=>{expandedCategoryNodesV650.add(nodeKey);};`,
    context
  );
  return context.__exports;
}

function renderV679(payload, which) {
  const sandbox = {
    esc, money, walletDate,
    CUI: { icon: () => '', emptyState: ({ title, body }) => `<div class="empty"><b>${title}</b><p>${body}</p></div>` }
  };
  const context = vm.createContext(sandbox);
  context.__exports = {};
  vm.runInContext(
    `${v679Block}\n__exports.funnel=funnelConversionPanelHtmlV679;` +
    `__exports.demographics=demographicsPanelHtmlV679;__exports.behaviour=behaviourPanelHtmlV679;`,
    context
  );
  return context.__exports[which](payload);
}

function renderOpportunities(payload) {
  const sandbox = {
    esc, walletDate,
    ciEmptyPanelV679: (headingId, eyebrow, title, message) => `<section class="revenue-truth-section" aria-labelledby="${headingId}">
      <div class="revenue-truth-section-head"><div><span class="revenue-truth-eyebrow">${esc(eyebrow)}</span>
      <h2 id="${headingId}">${esc(title)}</h2></div></div>
      <div class="empty">${esc(message)}</div></section>`
  };
  const context = vm.createContext(sandbox);
  context.__exports = {};
  vm.runInContext(freshnessBlock + '\n' + oppBlock + '\n__exports.render=opportunitiesPanelHtmlV685;', context);
  return context.__exports.render(payload);
}

function renderVisitDrilldown(rows) {
  const sandbox = { money };
  const context = vm.createContext(sandbox);
  context.__exports = {};
  vm.runInContext(
    `${sgtLine[0]}\n${validVisitBlock}\n${groupBlock}\n` +
    `__exports.groups=groupVisitDaysV719(${JSON.stringify(rows)});` +
    `__exports.summaries=__exports.groups.map(visitDaySummaryV719);`,
    context
  );
  return context.__exports;
}

function renderDashboardTile(key, metric) {
  const sandbox = { esc, workspaceTemplateAttributeV97: (attribute, keyName, values) => `${attribute}="${esc(JSON.stringify(values))}"` };
  const context = vm.createContext(sandbox);
  context.__exports = {};
  vm.runInContext(
    `${chipBlock}\n${defsBlock}\n${tileBlock}\n__exports.render=dashboardMetricTileHtmlV405;__exports.defs=DASHBOARD_METRIC_DEFINITIONS_V405;`,
    context
  );
  const def = context.__exports.defs[key];
  return context.__exports.render(metric, def, { previousFrom: null, previousTo: null, days: 0 });
}

function renderOwnerErrorText(error) {
  const context = vm.createContext({});
  context.__exports = {};
  vm.runInContext(`${errorMapBlock}\n__exports.text=ownerErrorText;`, context);
  return context.__exports.text(error);
}

function renderConsultativeBrief(report, affinity, recommendations) {
  const sandbox = {
    escapeHtml: esc,
    asObject: (x) => (x && typeof x === 'object' && !Array.isArray(x)) ? x : {},
    asArray: (x) => Array.isArray(x) ? x : [],
    currency: (c, cur) => `${cur || 'SGD'} ${((Number(c) || 0) / 100).toFixed(2)}`,
    dateTime: (v) => walletDate(v, true) || String(v ?? ''),
    pt: (s, vars) => vars ? Object.keys(vars).reduce((out, k) => out.replaceAll(`{${k}}`, String(vars[k])), s) : s,
    platformStatus: (s) => String(s ?? ''),
    localizedEmptyHtml: (msg) => `<div class="empty">${esc(msg)}</div>`,
    localizedRouteNoteHtml: (t, b) => `<div class="note"><b>${esc(t)}</b><p>${esc(b)}</p></div>`,
    CUI: {
      status: (label) => `<span class="status">${esc(label)}</span>`,
      icon: () => '',
      card: ({ title, body }) => `<section class="card"><h3>${esc(title)}</h3>${body}</section>`,
      table: ({ headers, rows }) =>
        `<table><thead><tr>${headers.map((h) => `<th>${esc(h)}</th>`).join('')}</tr></thead>` +
        `<tbody>${rows.map((r) => `<tr>${r.map((c) => `<td>${c}</td>`).join('')}</tr>`).join('')}</tbody></table>`
    }
  };
  const context = vm.createContext(sandbox);
  context.__exports = {};
  vm.runInContext(
    consoleFreshnessBlock + '\n' + consultativeBlock + '\n__exports.render=consultativeIntelligenceHtml;',
    context);
  return context.__exports.render(report, affinity, recommendations, sandbox.CUI);
}

/* ---------------------------------------------------------------------------------------------
   FIXTURES — every payload copied from a named source, per the task brief.
   --------------------------------------------------------------------------------------------- */

// funnelConversionPanelHtmlV679 — v673_corpus_funnels.sql main scenario, lifted verbatim from
// tests/business-ui/v679-ci-analyst-panels.test.mjs FUNNEL_MAIN.
const FUNNEL_MAIN = {
  window_days: 30, time_basis: 'sale_occurred_at',
  stage_1_to_2: { numerator: 4, denominator: 6, pct: 66.7 },
  stage_2_to_3: { numerator: 2, denominator: 4, pct: 50.0 },
  immature: { first_stage: 1, second_stage: 0 },
  bottleneck: 'second_to_third',
  evidence: { n: 6, floor: 5, status: 'ok' },
  observed_since: '2026-08-01T00:00:00Z'
};

// nestly_v734 (check 97) — the shared envelope `freshness` block (data_as_of/observed_since/
// generated_at/age_hours/stale/note), now rendered by ciFreshnessCaptionHtmlV734. Value lifted
// verbatim from db/tests/executed/v722_corpus_freshness_brief.sql's F2 scenario (one sale ~100
// hours old: stale=true, age_hours>48) and from
// tests/business-ui/v734-ci-freshness-caption.test.mjs's own FRESHNESS_STALE fixture. Layered
// onto FUNNEL_MAIN so the screenshot shows a real, fully-rendered panel with the stale disclosure
// underneath it, not a bare caption in isolation.
const FUNNEL_MAIN_STALE = {
  ...FUNNEL_MAIN,
  freshness: {
    data_as_of: '2026-08-29T06:00:00Z', observed_since: FUNNEL_MAIN.observed_since,
    generated_at: '2026-09-02T10:00:00Z', age_hours: 100.0, stale: true,
    note: 'data_as_of is the most recent recorded sale for this scope, not the requested reporting period; stale means that sale is more than 48 hours old.'
  }
};

// demographicsPanelHtmlV679 — v674_corpus_demographics.sql R1 block, lifted verbatim from the
// same test file's DEMOGRAPHICS_R1.
const DEMOGRAPHICS_R1 = {
  time_basis: 'sale_occurred_at',
  cells: [
    { age_band: '25_30', gender: 'female', customers: 5, revenue_cents: 75000, visits: 5, atv_cents: 18750, evidence: { n: 5, floor: 5, status: 'ok' } },
    { age_band: '31_40', gender: 'male', customers: 2, revenue_cents: 12000, visits: 2, atv_cents: null, evidence: { n: 2, floor: 5, status: 'insufficient' } }
  ],
  unclassified: { customers: 2, revenue_cents: 12000 },
  coverage: { demographics: { numerator: 7, denominator: 9, pct: 77.8 }, revenue: { numerator: 87000, denominator: 99000, pct: 87.9 } },
  observed_since: '2026-08-20T00:00:00Z'
};

// behaviourPanelHtmlV679 — v675_corpus_behaviour.sql PART A, lifted verbatim from the same file's
// DAYPART_A.
const DAYPART_A = {
  time_basis: 'sale_occurred_at',
  basis_note: 'Bucketed on sale_occurred_at, till time not arrival time.',
  weekdays: [
    { dow: 1, label: 'Monday', visits: 6, revenue_cents: 12000, revenue_per_visit_cents: 2000, weekday_occurrences: 2, visits_per_occurrence: { numerator: 6, denominator: 2, pct: 300.0 }, evidence: { n: 6, floor: 5, status: 'ok' } },
    { dow: 3, label: 'Wednesday', visits: 2, revenue_cents: 100000, revenue_per_visit_cents: null, weekday_occurrences: 2, visits_per_occurrence: { numerator: 2, denominator: 2, pct: null }, evidence: { n: 2, floor: 5, status: 'insufficient' } },
    { dow: 6, label: 'Saturday', visits: 5, revenue_cents: 45000, revenue_per_visit_cents: 9000, weekday_occurrences: 2, visits_per_occurrence: { numerator: 5, denominator: 2, pct: 250.0 }, evidence: { n: 5, floor: 5, status: 'ok' } }
  ],
  busiest_weekday: { dow: 1, label: 'Monday', visits: 6 },
  most_valuable_weekday: { dow: 6, label: 'Saturday', revenue_per_visit_cents: 9000 },
  observed_since: '2026-08-15T00:00:00Z'
};

// opportunitiesPanelHtmlV685, extended (materiality/margin_guard/impact.capacity) — copied
// verbatim from tests/business-ui/v716-ci-opportunities-impact.test.mjs V716_PAYLOAD, itself
// shaped from db/migrations/20260902_nestly_v705_spine_v3.sql and
// db/migrations/20260902_nestly_v712_spine_wording_closures.sql.
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
      margin: { status: 'blocked', margin_cents: 500, reason: 'incentive 800 cents would exceed the 500-cent margin (price 1000, cost 500)' },
      capacity: { status: 'not_applicable' }, retention_risk: { status: 'not_applicable' }
    },
    action: { who: 'the owner', what: 'Review the loyalty credit terms for this service.', when: 'this cycle', channel: 'analysis' },
    evidence: { source_rpc: 'public.get_ci_loyalty_programmes_v1', refs: {} },
    evidence_class: 'ASSOCIATION', confidence: { n: 12, floor: 5, status: 'ok' },
    limitation: 'Observational, not a controlled experiment. incentive 800 cents would exceed the 500-cent margin (price 1000, cost 500)',
    incentive: { kind: 'credit', declared: true },
    why_now: 'The cannibalisation share is already measurable as of 2026-09-01.',
    reversal_condition: 'Reconsider this call if the redemption share falls back under baseline.',
    materiality: { numerator: 120000, denominator: 8000000, pct: 1.5 }, materiality_class: 'material',
    margin_guard: { status: 'blocked', margin_cents: 500, reason: 'incentive 800 cents would exceed the 500-cent margin (price 1000, cost 500)' },
    capacity: null, concentration: null,
    alternatives: [
      { kind: 'reminder_only', primary: true, what: 'Contact without any discount or credit.', cost_basis: { status: 'declared', cents: 0, note: 'no spend' } },
      { kind: 'incentive', primary: false, what: 'Offer a discount or loyalty credit to prompt action.', cost_basis: { status: 'unavailable', reason: 'no discount-cost field in this schema' } }
    ],
    cost_basis: { status: 'declared', cents: 0, note: 'observation only' }
  };
}
function minorMarginUnavailableCandidate() {
  return {
    id: 'no_discount_reminder', rank: 2, rank_class: 'unquantified', domain: 'discount_dependency',
    pattern: '3 customers have never bought without a discount attached.',
    comparison: { kind: 'threshold', detail: 'discount-attached share' },
    impact: {
      cents: 900, reason: null, scenario_cents: 900,
      expected_value: { cents: 900, method: 'sum over discount-only buyers', inputs: { scored: 3, abstained: 0 } },
      affected_customers: { status: 'ok', n: 3 }, revenue_cents: { status: 'ok', cents: 900 },
      margin: { status: 'unavailable', reason: 'no cost recorded for this service; enter costs in Settings', margin_cents: null },
      capacity: { status: 'not_applicable' }, retention_risk: { status: 'not_applicable' }
    },
    action: { who: 'the owner', what: 'Send these 3 customers a full-price reminder.', when: 'this week', channel: 'whatsapp' },
    evidence: { source_rpc: 'public.get_ci_discount_dependency_v1', refs: {} },
    evidence_class: 'ASSOCIATION', confidence: { n: 3, floor: 5, status: 'insufficient' },
    limitation: 'Below the evidence floor.', incentive: { kind: 'credit', declared: true },
    why_now: 'The discount-only share is already measurable as of 2026-09-01.',
    reversal_condition: 'Reconsider this call if the discount-only share rises.',
    materiality: { numerator: 900, denominator: 8000000, pct: 0.01 }, materiality_class: 'minor',
    margin_guard: { status: 'unavailable', reason: 'no cost recorded for this service; enter costs in Settings', margin_cents: null },
    capacity: null, concentration: null,
    alternatives: [
      { kind: 'reminder_only', primary: true, what: 'Contact without any discount or credit.', cost_basis: { status: 'declared', cents: 0, note: 'no spend' } },
      { kind: 'incentive', primary: false, what: 'Offer a discount or loyalty credit to prompt action.', cost_basis: { status: 'unavailable', reason: 'no discount-cost field in this schema' } }
    ],
    cost_basis: { status: 'declared', cents: 0, note: 'observation only' }
  };
}
function capacityUnavailableCandidate() {
  return {
    id: 'gateway_followthrough:facial', rank: 3, rank_class: 'unquantified', domain: 'service_intelligence',
    pattern: '8 first-time facial buyers never returned for a second visit.',
    comparison: { kind: 'threshold', detail: 'first-to-second conversion' },
    impact: {
      cents: null, reason: 'an association, not an incremental model', scenario_cents: null,
      expected_value: { status: 'unavailable', reason: 'no behavioural model backs this association' },
      affected_customers: { status: 'ok', n: 8 }, revenue_cents: { status: 'not_applicable' },
      margin: { status: 'not_applicable', reason: 'no incentive spend for this candidate' },
      capacity: { status: 'unavailable', reason: 'no staff schedule rows recorded' }, retention_risk: { status: 'not_applicable' }
    },
    action: { who: 'the owner', what: 'Follow up with these 8 first-time buyers.', when: 'this week', channel: 'whatsapp' },
    evidence: { source_rpc: 'public.get_ci_service_intelligence_v1', refs: {} },
    evidence_class: 'ASSOCIATION', confidence: { n: 8, floor: 5, status: 'ok' }, limitation: 'Observational, not causal.',
    incentive: { kind: 'none', declared: true }, why_now: 'The gap is already measurable as of 2026-09-01.',
    reversal_condition: 'Reconsider this call if the return rate rises above baseline.',
    materiality: { numerator: null, denominator: 8000000, pct: null }, materiality_class: 'unquantified',
    margin_guard: null, capacity: { status: 'unavailable', reason: 'no staff schedule rows recorded' }, concentration: null,
    alternatives: [
      { kind: 'reminder_only', primary: true, what: 'Contact without any discount or credit.', cost_basis: { status: 'declared', cents: 0, note: 'no spend' } },
      { kind: 'service_recovery', primary: false, what: 'Re-run the first-visit experience for a sample of recent buyers at no charge to find what is actually going wrong before spending on acquisition.', cost_basis: { status: 'unavailable', reason: 'no discount-cost field in this schema' } },
      { kind: 'incentive', primary: false, what: 'Offer a discount or loyalty credit to prompt a second visit.', cost_basis: { status: 'unavailable', reason: 'no discount-cost field in this schema' } }
    ],
    cost_basis: { status: 'declared', cents: 0, note: 'observation only' }
  };
}
function strengthNoActionCandidate() {
  return {
    id: 'strength:category:facial', rank: 4, rank_class: 'strength', domain: 'category_mix',
    pattern: '"Facial" is this business\'s strongest category by revenue.',
    comparison: { kind: 'baseline', detail: 'top category by revenue' },
    impact: {
      cents: 200000, reason: null, scenario_cents: null,
      expected_value: { status: 'unavailable', reason: 'a strength is not itself an actionable dollar estimate' },
      affected_customers: { status: 'ok', n: 20 }, revenue_cents: { status: 'ok', cents: 200000 },
      margin: { status: 'not_applicable', reason: 'no incentive spend for this candidate' },
      capacity: { status: 'not_applicable' }, retention_risk: { status: 'not_applicable' }
    },
    action: { who: 'the owner', what: 'Keep promoting "Facial".', when: 'ongoing', channel: 'analysis' },
    evidence: { source_rpc: 'public.get_ci_category_mix_v1', refs: {} },
    evidence_class: 'DIRECT_FACT', confidence: { n: 20, floor: 5, status: 'ok' }, limitation: 'A strength, not a risk.',
    incentive: { kind: 'none', declared: true }, why_now: '"Facial" is already the top category as of 2026-09-01.',
    reversal_condition: 'Reconsider this call if its revenue falls under 200000 cents.',
    materiality: { numerator: 200000, denominator: 8000000, pct: 2.5 }, materiality_class: 'material',
    margin_guard: null, capacity: null,
    concentration: { top1_share_bps: 4200, mean_excl_top1: 15.3, skew_note: 'Its top customer alone accounts for 42% of the category.' },
    alternatives: [
      { kind: 'no_action', primary: true, what: 'keep doing this; nothing to change', cost_basis: { status: 'declared', cents: 0, note: 'no spend' } },
      { kind: 'reminder_only', primary: false, what: 'No action needed beyond monitoring.', cost_basis: { status: 'declared', cents: 0, note: 'no spend' } }
    ],
    cost_basis: { status: 'declared', cents: 0, note: 'observation only' }
  };
}
const OPPORTUNITIES_EXTENDED = {
  contract: 'ci_opportunities_v1',
  scope: { business_id: 'b1', branch_id: null, from: '2026-08-01', to: '2026-09-01', currency: 'SGD' },
  time_basis: 'sale_occurred_at',
  ranked: [materialBlockedMarginCandidate(), minorMarginUnavailableCandidate(), capacityUnavailableCandidate(), strengthNoActionCandidate()],
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

// opportunitiesPanelHtmlV685, abstention-only outcome — copied verbatim from
// tests/business-ui/v685-ci-surfaces.test.mjs OPPORTUNITIES_DO_NOTHING.
const OPPORTUNITIES_DO_NOTHING = {
  contract: 'ci_opportunities_v1',
  scope: { business_id: 'b1', branch_id: null, from: '2026-08-01', to: '2026-08-31', currency: 'SGD' },
  time_basis: 'sale_occurred_at',
  ranked: [{
    id: 'do_nothing', rank: 1, rank_class: 'do_nothing', domain: 'none',
    pattern: 'No opportunity clears the evidence bar',
    comparison: { kind: 'threshold', detail: 'all 8 candidate evaluation(s) were made and every one abstained' },
    impact: { cents: null, reason: 'nothing is being recommended, so there is nothing to value' },
    action: { who: 'the consultant', what: 'Take no action from this analysis.', when: 'revisit at the next review', channel: 'none' },
    evidence: { source_rpc: 'public.get_ci_funnel_conversion_v1, ...', refs: { candidates_examined: 8, candidates_promoted: 0, abstentions: [] } },
    evidence_class: 'DIRECT_FACT', confidence: { n: 0, floor: 5, status: 'insufficient' },
    limitation: '"No opportunity" is a statement about what this period\'s data can support, not a finding that the business has none.'
  }],
  abstentions: [],
  comparisons: { subgroups_examined: 8, subgroups_promoted: 0, note: 'Promoted findings were selected from the examined set.' },
  observed_since: '2026-08-01T00:00:00Z'
};

// opportunitiesPanelHtmlV685, RPC-error path.
const OPPORTUNITIES_RPC_ERROR = { error: { message: 'evidence engine timed out' } };

// categoryMixMarkupV650 — a "whale" distribution: one node concentrating almost all revenue and
// customers, shaped exactly like get_ci_category_mix_v1's own output (numerator/denominator-free
// aggregate rows: node_key/label/revenue_cents/customer_count), same shape as
// tests/business-ui/v685-ci-surfaces.test.mjs's CATEGORY_MIX_PARITY fixture. Values are
// constructed for this proof pack (not lifted from a corpus file, since no corpus fixture happens
// to be whale-shaped) to depict a single dominant category — cited here rather than silently
// invented.
const CATEGORY_MIX_WHALE = {
  status: 'ready',
  coverage: { classified_pct_bps: 9800, projected_share_bps: 0 },
  categories: [
    { node_key: 'spa.signature_ritual', label: 'Signature Ritual', revenue_cents: 9200000, customer_count: 41 },
    { node_key: 'spa.facials', label: 'Facials', revenue_cents: 310000, customer_count: 18 },
    { node_key: 'spa.nails', label: 'Nails', revenue_cents: 96000, customer_count: 9 },
    { node_key: 'spa.retail', label: 'Retail', revenue_cents: 41000, customer_count: 6 }
  ],
  observed_since: '2026-08-01T00:00:00Z'
};

// categoryMixMarkupV650, below-small-cell-floor drill — copied verbatim from
// tests/business-ui/v685-ci-surfaces.test.mjs CATEGORY_MIX_PARITY + its "beauty.nails" suppressed
// customer cache.
const CATEGORY_MIX_PARITY = {
  status: 'ready',
  coverage: { classified_pct_bps: 9500, projected_share_bps: 0 },
  categories: [
    { node_key: 'beauty.facials', label: 'Facials', revenue_cents: 500000, customer_count: 12 },
    { node_key: 'beauty.nails', label: 'Nails', revenue_cents: 30000, customer_count: 3 }
  ],
  observed_since: '2026-08-01T00:00:00Z'
};
const CATEGORY_MIX_NAILS_SUPPRESSED = {
  data: {
    customers: [],
    suppressed: { reason: 'below_small_cell_floor', floor: 5, cohort_size: 3, note: 'Naming a cohort this small would identify its members.' }
  }
};

// contactabilityMarkupV650, RPC-error path — copied verbatim from
// tests/business-ui/v685-ci-surfaces.test.mjs.
const CONTACTABILITY_ERROR = 'permission denied';

// visit-day drill-down rows — copied verbatim (with the doc's own reasoning) from
// tests/business-ui/v719-visits-drilldown-days.test.mjs's main scenario: "R three same-day + next
// day + a week later, C five distinct days -> KPI 8 not 10, R 3, C 5."
function sale({ id, clientId, name, day, time = '10:00:00', amount, countsAsVisit = true, reversalOf = null }) {
  return { id, client_id: clientId, clients: name ? { full_name: name } : null, occurred_at: `${day}T${time}.000Z`, amount_cents: amount, counts_as_visit: countsAsVisit, reversal_of: reversalOf };
}
const VISIT_DAY_ROWS = [
  sale({ id: 'r1', clientId: 'r', name: 'Rina', day: '2026-09-01', time: '01:00:00', amount: 1500 }),
  sale({ id: 'r2', clientId: 'r', name: 'Rina', day: '2026-09-01', time: '04:00:00', amount: 2000 }),
  sale({ id: 'r3', clientId: 'r', name: 'Rina', day: '2026-09-01', time: '08:00:00', amount: 1000 }),
  sale({ id: 'r4', clientId: 'r', name: 'Rina', day: '2026-09-02', time: '01:00:00', amount: 800 }),
  sale({ id: 'r5', clientId: 'r', name: 'Rina', day: '2026-09-09', time: '01:00:00', amount: 500 }),
  sale({ id: 'c1', clientId: 'c', name: 'Chandra', day: '2026-09-01', amount: 100 }),
  sale({ id: 'c2', clientId: 'c', name: 'Chandra', day: '2026-09-02', amount: 100 }),
  sale({ id: 'c3', clientId: 'c', name: 'Chandra', day: '2026-09-03', amount: 100 }),
  sale({ id: 'c4', clientId: 'c', name: 'Chandra', day: '2026-09-04', amount: 100 }),
  sale({ id: 'c5', clientId: 'c', name: 'Chandra', day: '2026-09-05', amount: 100 })
];

// dashboardMetricTileHtmlV405, revenue tile — copied verbatim from
// tests/business-ui/v694-recorded-revenue-tiles.test.mjs.
const REVENUE_TILE_METRIC = { key: 'revenue', value: 'SGD 4560.00', hint: '', delta: null, was: null };

// ownerErrorText, RPC 42501 refusal — a real Postgres/PostgREST row-level-security refusal string
// (the exact class OWNER_ERROR_NOISE_RULES_V170's `permission denied for (table|function|schema|
// relation)|row-level security` rule matches), fed through the app's own top-level error
// translator rather than the panel-local ciQuietErrorV650 idiom used elsewhere in this pack.
const RPC_42501_ERROR = { message: 'permission denied for function get_ci_opportunities_v1', code: '42501' };

// consultativeIntelligenceHtml — K1 (unavailable, below floor) and K2 (ok) — copied verbatim from
// tests/platform-console/v727-consultant-brief-unavailable.test.mjs.
const K1_UNAVAILABLE = {
  scope: { business_id: 'b1', business_name: 'Tiny Firm', branch_id: null, from: '2026-08-01', to: '2026-08-31' },
  kpis: { net_revenue_cents: 15000, visits: 3, active_customers: 2, returning_customers: 0, average_order_cents: null, currency: 'SGD', evidence: { n: 2, floor: 5, status: 'insufficient' }, status: 'unavailable' },
  cohorts: { definitions: { champions: '5+ purchases; last purchase in final 30 days' }, counts: { champions: 0, loyal: 1, at_risk: 1 }, evidence: { n: 2, floor: 5, status: 'insufficient' }, status: 'unavailable' },
  customer_intelligence: { total_customers: 2, customers_with_purchase: 2, customers_over_90_days_inactive: 0, top_customer_revenue_cents: null, evidence: { n: 2, floor: 5, status: 'insufficient' }, status: 'unavailable' },
  data_quality: { confidence: 'not_enough_data', message: 'Below the evidence floor.' }
};
const K1_AFFINITY = { enabled: true, pairs: [] };
const K1_RECS = { recommendations: [] };
const K2_OK = {
  scope: { business_id: 'b2', business_name: 'Healthy Firm', branch_id: null, from: '2026-08-01', to: '2026-08-31' },
  kpis: { net_revenue_cents: 456000, visits: 137, active_customers: 40, returning_customers: 10, average_order_cents: 3328, currency: 'SGD', evidence: { n: 40, floor: 5, status: 'ok' }, status: 'ok' },
  cohorts: { definitions: { champions: '5+ purchases; last purchase in final 30 days' }, counts: { champions: 6, loyal: 12, at_risk: 3 }, evidence: { n: 40, floor: 5, status: 'ok' }, status: 'ok' },
  customer_intelligence: { total_customers: 40, customers_with_purchase: 35, customers_over_90_days_inactive: 5, top_customer_revenue_cents: 98000, evidence: { n: 40, floor: 5, status: 'ok' }, status: 'ok' },
  data_quality: { confidence: 'ready', message: 'Item coverage is complete for this scope.' }
};
const K2_AFFINITY = { enabled: true, pairs: [] };
const K2_RECS = { recommendations: [] };

/* ---------------------------------------------------------------------------------------------
   PAGE ASSEMBLY
   --------------------------------------------------------------------------------------------- */
const inlineStyle = indexHtml.match(/<style>([\s\S]*?)<\/style>/)?.[1];
if (!inlineStyle) throw new Error('index.html production inline stylesheet missing');

function page({ title, css, bodyHtml, sourceHash }) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="ci-proof-source-sha256" content="${sourceHash}">
<title>${esc(title)}</title>
<style>
${css}
.ci-proof-shell{max-width:920px;margin:0 auto;padding:20px}
.ci-proof-provenance{margin-bottom:14px;color:var(--muted,#6b7280);font-size:12px;overflow-wrap:anywhere}
</style>
</head>
<body>
<div class="ci-proof-shell">
<p class="ci-proof-provenance">CI-100 proof pack · production-render harness · source ${sourceHash}</p>
${bodyHtml}
</div>
</body>
</html>
`;
}

const BUSINESS_CSS = [inlineStyle, appCss, revenueTruthCss].join('\n');
const PLATFORM_CSS = [inlineStyle, appCss, platformConsoleCss].join('\n');

function hashOf(...parts) {
  return createHash('sha256').update(parts.join('\n')).digest('hex');
}

/* ---------------------------------------------------------------------------------------------
   STATE LIST — id, human title, payload-source citation, and how to produce the body HTML.
   --------------------------------------------------------------------------------------------- */
const states = [];

// -- Answer states (checklist item 11) --------------------------------------------------------

states.push({
  id: 'funnel-conversion-mature',
  title: 'CI Funnel Conversion — mature scenario',
  source: 'funnelConversionPanelHtmlV679(FUNNEL_MAIN); FUNNEL_MAIN copied from tests/business-ui/v679-ci-analyst-panels.test.mjs, lifted from db/tests/executed/v673_corpus_funnels.sql',
  css: BUSINESS_CSS,
  body: () => renderV679(FUNNEL_MAIN, 'funnel'),
  hash: () => hashOf(v679Block, JSON.stringify(FUNNEL_MAIN))
});

// nestly_v734 (check 97): the shared envelope `freshness` block now has a real renderer
// (ciFreshnessCaptionHtmlV734), closing the gap this file used to record as NOT-RENDERABLE
// ('stale-freshness-envelope', see git history) — same panel/fixture as funnel-conversion-mature
// above, with a stale freshness block layered on top, so the screenshot proves both the panel's
// real numbers AND the "Data may be out of date" disclosure render together, never one instead
// of the other.
states.push({
  id: 'stale-freshness-envelope',
  title: 'CI Funnel Conversion — stale freshness envelope disclosed, panel still renders in full',
  source: 'funnelConversionPanelHtmlV679(FUNNEL_MAIN_STALE) via ciFreshnessCaptionHtmlV734; freshness block lifted from db/tests/executed/v722_corpus_freshness_brief.sql F2 and tests/business-ui/v734-ci-freshness-caption.test.mjs FRESHNESS_STALE',
  css: BUSINESS_CSS,
  body: () => renderV679(FUNNEL_MAIN_STALE, 'funnel'),
  hash: () => hashOf(freshnessBlock, v679Block, JSON.stringify(FUNNEL_MAIN_STALE))
});

states.push({
  id: 'demographics-cells',
  title: 'CI Demographics — evidence-ok + below-floor cells',
  source: 'demographicsPanelHtmlV679(DEMOGRAPHICS_R1); DEMOGRAPHICS_R1 copied from tests/business-ui/v679-ci-analyst-panels.test.mjs, lifted from db/tests/executed/v674_corpus_demographics.sql R1',
  css: BUSINESS_CSS,
  body: () => renderV679(DEMOGRAPHICS_R1, 'demographics'),
  hash: () => hashOf(v679Block, JSON.stringify(DEMOGRAPHICS_R1))
});

states.push({
  id: 'behaviour-weekday',
  title: 'CI Behaviour — busiest vs most-valuable weekday',
  source: 'behaviourPanelHtmlV679(DAYPART_A); DAYPART_A copied from tests/business-ui/v679-ci-analyst-panels.test.mjs, lifted from db/tests/executed/v675_corpus_behaviour.sql PART A',
  css: BUSINESS_CSS,
  body: () => renderV679(DAYPART_A, 'behaviour'),
  hash: () => hashOf(v679Block, JSON.stringify(DAYPART_A))
});

states.push({
  id: 'opportunities-extended',
  title: 'CI Opportunities — materiality/margin_guard/capacity extended payload',
  source: 'opportunitiesPanelHtmlV685(OPPORTUNITIES_EXTENDED); copied from tests/business-ui/v716-ci-opportunities-impact.test.mjs V716_PAYLOAD, shaped from db/migrations/20260902_nestly_v705_spine_v3.sql and 20260902_nestly_v712_spine_wording_closures.sql',
  css: BUSINESS_CSS,
  body: () => renderOpportunities(OPPORTUNITIES_EXTENDED),
  hash: () => hashOf(oppBlock, JSON.stringify(OPPORTUNITIES_EXTENDED))
});

states.push({
  id: 'category-mix-whale',
  title: 'CI Category Mix — whale distribution',
  source: 'categoryMixMarkupV650() over CATEGORY_MIX_WHALE; shaped like get_ci_category_mix_v1\'s aggregate-row output (same shape as CATEGORY_MIX_PARITY in tests/business-ui/v685-ci-surfaces.test.mjs), values constructed for this proof pack to depict one dominant category — see script header',
  css: BUSINESS_CSS,
  body: () => { const p = runCiClosure(); p.setCategoryMix(CATEGORY_MIX_WHALE, ''); return p.categoryMix(); },
  hash: () => hashOf(ciClosureBlock, JSON.stringify(CATEGORY_MIX_WHALE))
});

states.push({
  id: 'visit-day-drilldown',
  title: 'Dashboard Visits KPI drill-down — grouped by (client, SG day)',
  source: 'groupVisitDaysV719()/visitDaySummaryV719() over VISIT_DAY_ROWS, copied verbatim from tests/business-ui/v719-visits-drilldown-days.test.mjs main scenario ("KPI 8 not 10, R 3, C 5"); table markup reproduced from openDashboardMetricRowsV388\'s visits branch (app/app.js)',
  css: BUSINESS_CSS,
  body: () => {
    const { groups } = renderVisitDrilldown(VISIT_DAY_ROWS);
    const rows = groups.map((group) => {
      const label = group.clientId ? esc(group.name) : `${esc(group.name)}`;
      const summary = `${group.count === 1 ? '1 ticket' : `${group.count} tickets`} · ${money(group.amountCents)}`;
      return `<tr><td data-label="When">${esc(group.occurredAt.slice(0, 10))}</td><td data-label="Customer">${label}</td><td data-label="Visit">${esc(summary)}</td></tr>`;
    }).join('');
    return `<section class="revenue-truth-section"><div class="revenue-truth-section-head"><div><span class="revenue-truth-eyebrow">Dashboard drill-down</span><h2>Valid visits · 8 rows (10 raw sales)</h2></div></div>
      <div class="cui-table-wrap" tabindex="0"><table class="cui-table" data-responsive="true"><thead><tr><th>When</th><th>Customer</th><th>Visit</th></tr></thead><tbody>${rows}</tbody></table></div></section>`;
  },
  hash: () => hashOf(sgtLine[0], validVisitBlock, groupBlock, JSON.stringify(VISIT_DAY_ROWS))
});

states.push({
  id: 'dashboard-revenue-tile',
  title: 'Dashboard KPI tile — "Peekaa recorded revenue" label',
  source: 'dashboardMetricTileHtmlV405 for the revenue key; metric fixture copied from tests/business-ui/v694-recorded-revenue-tiles.test.mjs',
  css: BUSINESS_CSS,
  body: () => `<div style="max-width:280px">${renderDashboardTile('revenue', REVENUE_TILE_METRIC)}</div>`,
  hash: () => hashOf(chipBlock, defsBlock, tileBlock, JSON.stringify(REVENUE_TILE_METRIC))
});

states.push({
  id: 'consultative-brief-ok',
  title: 'Consultant brief — K2 healthy firm (status ok)',
  source: 'consultativeIntelligenceHtml(K2_OK,...); copied verbatim from tests/platform-console/v727-consultant-brief-unavailable.test.mjs K2_OK',
  css: PLATFORM_CSS,
  body: () => renderConsultativeBrief(K2_OK, K2_AFFINITY, K2_RECS),
  hash: () => hashOf(consultativeBlock, JSON.stringify(K2_OK))
});

// -- Failure / abstention states (checklist item 12) -------------------------------------------

states.push({
  id: 'rpc-42501-refusal',
  title: 'Failure — RPC 42501 refusal, owner-facing translation',
  source: 'ownerErrorText(RPC_42501_ERROR); RPC_42501_ERROR is a real Postgres/PostgREST row-level-security refusal shape matched by OWNER_ERROR_NOISE_RULES_V170 (app/app.js)',
  css: BUSINESS_CSS,
  body: () => `<div class="err" role="alert">${esc(renderOwnerErrorText(RPC_42501_ERROR))}</div><p class="muted small" style="margin-top:10px">Raw server error (never shown to the owner): ${esc(RPC_42501_ERROR.message)} (${RPC_42501_ERROR.code})</p>`,
  hash: () => hashOf(errorMapBlock, JSON.stringify(RPC_42501_ERROR))
});

states.push({
  id: 'panel-rpc-error',
  title: 'Failure — CI Contactability panel RPC error path',
  source: 'contactabilityMarkupV650() after setContactability(null,\'permission denied\'); copied verbatim from tests/business-ui/v685-ci-surfaces.test.mjs',
  css: BUSINESS_CSS,
  body: () => { const p = runCiClosure(); p.setContactability(null, CONTACTABILITY_ERROR); return p.contactability(); },
  hash: () => hashOf(ciClosureBlock, CONTACTABILITY_ERROR)
});

states.push({
  id: 'opportunities-abstention-only',
  title: 'Failure/abstention — do_nothing outcome, every candidate abstained',
  source: 'opportunitiesPanelHtmlV685(OPPORTUNITIES_DO_NOTHING); copied verbatim from tests/business-ui/v685-ci-surfaces.test.mjs',
  css: BUSINESS_CSS,
  body: () => renderOpportunities(OPPORTUNITIES_DO_NOTHING),
  hash: () => hashOf(oppBlock, JSON.stringify(OPPORTUNITIES_DO_NOTHING))
});

states.push({
  id: 'opportunities-rpc-error',
  title: 'Failure — CI Opportunities panel RPC error path',
  source: 'opportunitiesPanelHtmlV685({error:{message:\'evidence engine timed out\'}}); copied verbatim from tests/business-ui/v685-ci-surfaces.test.mjs',
  css: BUSINESS_CSS,
  body: () => renderOpportunities(OPPORTUNITIES_RPC_ERROR),
  hash: () => hashOf(oppBlock, JSON.stringify(OPPORTUNITIES_RPC_ERROR))
});

states.push({
  id: 'category-mix-below-floor',
  title: 'Failure/abstention — below small-cell floor, suppressed cohort',
  source: 'categoryMixMarkupV650() with node beauty.nails expanded and its suppressed customer cache; copied verbatim from tests/business-ui/v685-ci-surfaces.test.mjs CATEGORY_MIX_PARITY',
  css: BUSINESS_CSS,
  body: () => {
    const p = runCiClosure();
    p.setCategoryMix(CATEGORY_MIX_PARITY, '');
    p.expandNode('beauty.nails');
    p.setCategoryCustomerCache('beauty.nails', CATEGORY_MIX_NAILS_SUPPRESSED);
    return p.categoryMix();
  },
  hash: () => hashOf(ciClosureBlock, JSON.stringify(CATEGORY_MIX_PARITY), JSON.stringify(CATEGORY_MIX_NAILS_SUPPRESSED))
});

states.push({
  id: 'consultative-brief-unavailable',
  title: 'Failure/abstention — K1 tiny firm, below evidence floor',
  source: 'consultativeIntelligenceHtml(K1_UNAVAILABLE,...); copied verbatim from tests/platform-console/v727-consultant-brief-unavailable.test.mjs K1_UNAVAILABLE (a REFUTER finding: this payload used to print "SGD 0.00" instead of the evidence note)',
  css: PLATFORM_CSS,
  body: () => renderConsultativeBrief(K1_UNAVAILABLE, K1_AFFINITY, K1_RECS),
  hash: () => hashOf(consultativeBlock, JSON.stringify(K1_UNAVAILABLE))
});

/* ---------------------------------------------------------------------------------------------
   BUILD — pure (no fs writes). Exported so a test can regenerate the pages in-memory and diff
   against the committed files, without this module's CLI path (file writes, screenshot capture)
   running as a side effect of merely being imported. See is-direct-cli-invocation.mjs's own
   header for why that guard exists (NESTLY_V459): `node --test` collects every .mjs under a
   `tests`/`test` directory and runs it — this file lives under scripts/, not tests/, so it is
   never itself collected, but the exported builder is imported BY a tests/ file, and that file's
   top-level `await` must not trip a rebuild-and-write of the very fixtures it is diffing.
   --------------------------------------------------------------------------------------------- */
const outDir = P('tests', 'browser', 'ci-proof');

// nestly_v734 (check 97): this used to be a documented NOT-RENDERABLE gap
// ('stale-freshness-envelope') — no renderer read app.ci_envelope_v680's `freshness` block, so
// there was no real renderer to execute. ciFreshnessCaptionHtmlV734 closes that gap; the state is
// now a real screenshot (see the 'stale-freshness-envelope' entry in `states` below), so this
// list is empty rather than removed outright — kept as the documented mechanism for any future
// gap, per the same "stop rather than fabricate" instruction this file's header describes.
export const notRenderable = [];

export function buildCiProofPages() {
  return states.map((state) => {
    const bodyHtml = state.body();
    const sourceHash = state.hash();
    const html = page({ title: `Peekaa CI-100 proof — ${state.title}`, css: state.css, bodyHtml, sourceHash });
    return { id: state.id, title: state.title, source: state.source, html, sourceHash, filePath: join(outDir, `${state.id}.html`) };
  });
}

function writeHtmlPages(manifest) {
  mkdirSync(outDir, { recursive: true });
  for (const state of manifest) {
    writeFileSync(state.filePath, state.html);
    process.stdout.write(`  wrote tests/browser/ci-proof/${state.id}.html\n`);
  }
}

/* ---------------------------------------------------------------------------------------------
   SCREENSHOTS (playwright-core, or `playwright` if that is what is installed)
   --------------------------------------------------------------------------------------------- */
function friendlyDriverLabel(modulePath) {
  // PLAYWRIGHT_MODULE points at a package's entry file (must be index.js per the operator
  // recipe), e.g. .../node_modules/playwright-core/index.js -> label it by the package
  // directory name rather than leaking the full scratch-install path into the committed index.
  const match = String(modulePath).match(/node_modules\/([^/]+)\/[^/]+$/);
  return match ? match[1] : modulePath;
}

async function tryImportPlaywright() {
  const candidates = process.env.PLAYWRIGHT_MODULE ? [process.env.PLAYWRIGHT_MODULE] : ['playwright-core', 'playwright'];
  for (const name of candidates) {
    try {
      const mod = await import(name);
      return { name: friendlyDriverLabel(name), chromium: mod.chromium ? mod.chromium : mod.default.chromium };
    } catch { /* try next */ }
  }
  return null;
}

function sha256File(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

function writeIndex(manifest, screenshotStatus) {
  const evidenceDir = P('docs', 'qa', 'proof-pack', 'screenshots');
  const lines = [];
  lines.push('# CI-100-CHECKLIST proof-pack — items 11/12 screenshot index');
  lines.push('');
  lines.push(`Commit SHA: \`${commitSha}\``);
  lines.push(`Capture date: ${captureDate}`);
  lines.push(`Screenshot capture: ${screenshotStatus}`);
  lines.push('');
  lines.push('| State | Payload source | HTML page | Viewport | PNG | sha256 |');
  lines.push('|---|---|---|---|---|---|');
  for (const state of manifest) {
    const relHtml = `tests/browser/ci-proof/${state.id}.html`;
    for (const viewport of ['mobile-390x844', 'desktop-1280x800']) {
      const pngPath = join(evidenceDir, `${state.id}-${viewport}.png`);
      const relPng = `docs/qa/proof-pack/screenshots/${state.id}-${viewport}.png`;
      const exists = existsSync(pngPath);
      const sha = exists ? sha256File(pngPath) : '(pending)';
      const sizeOk = exists && statSync(pngPath).size > 5 * 1024;
      lines.push(`| ${state.id} | ${state.source} | ${relHtml} | ${viewport} | ${exists ? relPng : '(pending)'}${exists && !sizeOk ? ' ⚠️ under 5KB' : ''} | ${sha} |`);
    }
  }
  lines.push('');
  if (notRenderable.length) {
    lines.push('## Not renderable (documented gap, no screenshot produced)');
    lines.push('');
    for (const gap of notRenderable) {
      lines.push(`- **${gap.id}** — ${gap.reason}`);
    }
    lines.push('');
  }
  writeFileSync(P('docs', 'qa', 'proof-pack', 'SCREENSHOTS.md'), lines.join('\n') + '\n');
}

async function main() {
  const manifest = buildCiProofPages();
  writeHtmlPages(manifest);

  const pw = await tryImportPlaywright();
  if (!pw) {
    writeIndex(manifest, 'PENDING — no playwright-core/playwright module importable in this environment. HTML pages and index were produced; PNG capture was not attempted, per instruction (stop after HTML+index when the driver is unavailable rather than fabricate screenshots).');
    process.stdout.write('\nplaywright-core is not importable in this environment. Stopping after HTML pages + index (docs/qa/proof-pack/SCREENSHOTS.md), per instruction.\n');
    return;
  }

  const evidenceDir = P('docs', 'qa', 'proof-pack', 'screenshots');
  mkdirSync(evidenceDir, { recursive: true });

  const PORT = Number(process.env.CI_PROOF_PORT || 8917);
  const server = spawn('python3', ['-m', 'http.server', String(PORT), '--bind', '127.0.0.1'], { cwd: root, stdio: 'ignore' });
  await new Promise((resolve) => setTimeout(resolve, 600));

  const browser = await pw.chromium.launch({
    headless: true,
    ...(process.env.PLAYWRIGHT_EXECUTABLE_PATH ? { executablePath: process.env.PLAYWRIGHT_EXECUTABLE_PATH } : {})
  });
  try {
    const viewports = { 'mobile-390x844': { width: 390, height: 844 }, 'desktop-1280x800': { width: 1280, height: 800 } };
    for (const state of manifest) {
      for (const [name, size] of Object.entries(viewports)) {
        const page = await browser.newPage({ viewport: size, deviceScaleFactor: 1 });
        await page.goto(`http://127.0.0.1:${PORT}/tests/browser/ci-proof/${state.id}.html`, { waitUntil: 'networkidle' });
        await page.screenshot({ path: join(evidenceDir, `${state.id}-${name}.png`), fullPage: true });
        await page.close();
        process.stdout.write(`  captured ${state.id} (${name})\n`);
      }
    }
  } finally {
    await browser.close();
    server.kill();
  }
  writeIndex(manifest, `captured with ${pw.name}`);
  process.stdout.write('\nScreenshots and index written to docs/qa/proof-pack/.\n');
}

if (isDirectCliInvocation(import.meta.url)) {
  await main();
}
