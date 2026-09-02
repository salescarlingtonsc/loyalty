/* NESTLY v734 (check 97: freshness and stale states) — v722 gave every CI reader that goes
 * through app.ci_envelope_v680 a top-level `freshness` block ({data_as_of, observed_since,
 * generated_at, age_hours, stale, note}), but shipped no renderer for it. This is the ONE
 * renderer, ciFreshnessCaptionHtmlV734, reused by every CI panel on the Customer Intelligence
 * page and by platform-console.js's own copy for the consultant brief.
 *
 * The three fixture shapes below are lifted verbatim from db/tests/executed/v722_corpus_freshness_brief.sql:
 *   F1  fresh — one sale 1 hour old: stale=false, age_hours<2, data_as_of=that sale's occurred_at.
 *   F2  stale — one sale 100 hours old: stale=true, age_hours>48.
 *   F3  no data — zero sales at all: data_as_of=null, stale=true, the SQL's own "No sales
 *       recorded yet for this scope; treat any finding as provisional." note.
 * A fourth case (freshness key entirely absent, e.g. a payload from a pre-v722 server or a
 * reader this envelope never touched) must render nothing and never throw.
 *
 * Tests execute the helper directly, then execute it again wired into one full panel
 * (funnelConversionPanelHtmlV679) to prove the wiring, not just the helper in isolation. Per
 * owner instruction (task brief for this change): freshness is DISCLOSURE ONLY — a stale
 * payload still renders the panel in full underneath the caption, never a withheld/refused
 * state, and age is always the server's own age_hours, never recomputed client-side.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

const blockStart = app.indexOf('function ciMeasuredSinceInlineV679(');
const blockEnd = app.indexOf('async function serviceMappingBoardPage(){', blockStart);
assert.ok(blockStart > -1 && blockEnd > blockStart,
  'the v679 panels + shared helpers (incl. ciFreshnessCaptionHtmlV734) must be top-level functions before serviceMappingBoardPage');
const block = app.slice(blockStart, blockEnd);

assert.ok(block.includes('function ciFreshnessCaptionHtmlV734(payload){'),
  'ciFreshnessCaptionHtmlV734 must live in the same top-level block as the panels it is wired into');

function render() {
  const sandbox = {
    esc: (x) => String(x ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'),
    money: (c) => 'SGD ' + ((c || 0) / 100).toFixed(2),
    walletDate: (v) => `WD:${v}`,
    CUI: { icon: () => '', emptyState: ({ title, body }) => `<div class="empty"><b>${title}</b><p>${body}</p></div>` }
  };
  const context = vm.createContext(sandbox);
  context.__exports = {};
  vm.runInContext(
    `${block}\n__exports.caption=ciFreshnessCaptionHtmlV734;` +
    `__exports.funnel=funnelConversionPanelHtmlV679;`,
    context
  );
  return context.__exports;
}

/* ---------------------------------------------------------------------------------------------
   F1 — fresh: one sale 1 hour old
   --------------------------------------------------------------------------------------------- */
const FRESHNESS_FRESH = {
  data_as_of: '2026-09-02T09:00:00Z',
  observed_since: '2026-08-01T00:00:00Z',
  generated_at: '2026-09-02T10:00:00Z',
  age_hours: 1.0,
  stale: false,
  note: 'data_as_of is the most recent recorded sale for this scope, not the requested reporting period; stale means that sale is more than 48 hours old.'
};

test('V734 caption: a fresh payload prints "Data as of <date> · <age>" and no stale line', () => {
  const { caption } = render();
  const html = caption({ freshness: FRESHNESS_FRESH });
  assert.ok(html.includes('Data as of WD:2026-09-02T09:00:00Z'), 'data_as_of reaches the caption via walletDate');
  assert.ok(html.includes('1.0 hour old') || html.includes('1.0 hours old'), 'age_hours is the server value, verbatim');
  assert.ok(!html.includes('may be out of date'), 'a fresh payload never shows the stale disclosure');
  assert.ok(!html.includes(FRESHNESS_FRESH.note), 'the fresh note text is never shown — it only appears under stale');
});

/* ---------------------------------------------------------------------------------------------
   F2 — stale: one sale 100 hours old, with the server's own note
   --------------------------------------------------------------------------------------------- */
const FRESHNESS_STALE = {
  data_as_of: '2026-08-29T06:00:00Z',
  observed_since: '2026-08-01T00:00:00Z',
  generated_at: '2026-09-02T10:00:00Z',
  age_hours: 100.0,
  stale: true,
  note: 'data_as_of is the most recent recorded sale for this scope, not the requested reporting period; stale means that sale is more than 48 hours old.'
};

test('V734 caption: a stale payload adds "Data may be out of date" with the server note verbatim', () => {
  const { caption } = render();
  const html = caption({ freshness: FRESHNESS_STALE });
  assert.ok(html.includes('Data as of WD:2026-08-29T06:00:00Z'), 'the fresh-line caption still renders under stale');
  assert.ok(html.includes('100.0 hours old'));
  assert.ok(html.includes('Data may be out of date'), 'the stale disclosure line must appear');
  assert.ok(html.includes('last sale'), 'the stale line names what is stale');
  assert.ok(html.includes(FRESHNESS_STALE.note), 'the server’s note is reproduced verbatim, not paraphrased');
});

test('V734 caption: stale never means withheld — the helper only ever adds text, never a refusal', () => {
  const { caption } = render();
  const html = caption({ freshness: FRESHNESS_STALE });
  assert.ok(!/refus|withheld|cannot recommend|not available/i.test(html),
    'freshness disclosure must never read as a refusal to render — Peekaa discloses staleness, it does not gate on it');
});

/* ---------------------------------------------------------------------------------------------
   F3 — no data at all: data_as_of null, stale true, the SQL's own note
   --------------------------------------------------------------------------------------------- */
const FRESHNESS_NO_DATA = {
  data_as_of: null,
  observed_since: null,
  generated_at: '2026-09-02T10:00:00Z',
  age_hours: null,
  stale: true,
  note: 'No sales recorded yet for this scope; treat any finding as provisional.'
};

test('V734 caption: zero sales on record renders "no recorded sale yet" and stays stale — never a crash', () => {
  const { caption } = render();
  const html = caption({ freshness: FRESHNESS_NO_DATA });
  assert.ok(html.includes('no recorded sale yet'), 'a null data_as_of never prints as a fabricated date');
  assert.ok(html.includes('age unknown'), 'a null age_hours never prints as a fabricated number');
  assert.ok(html.includes('Data may be out of date'));
  assert.ok(html.includes(FRESHNESS_NO_DATA.note));
});

/* ---------------------------------------------------------------------------------------------
   Freshness-absent — an older server, or a reader this envelope never touched: no caption, no
   crash. Matches v722's own F5 case (get_ci_opportunities_v1 keeps ITS OWN freshness shape,
   which does not carry age_hours/stale/data_as_of at all).
   --------------------------------------------------------------------------------------------- */
test('V734 caption: a payload with no freshness key renders nothing and never throws', () => {
  const { caption } = render();
  assert.equal(caption(null), '');
  assert.equal(caption(undefined), '');
  assert.equal(caption({}), '');
  assert.equal(caption({ observed_since: '2026-08-01T00:00:00Z' }), '');
  assert.doesNotThrow(() => caption({ freshness: 'not-an-object' }));
  assert.equal(caption({ freshness: 'not-an-object' }), '');
});

test('V734 caption: an opportunities-shaped local freshness (observed_since_min, no age_hours/stale) renders nothing', () => {
  const { caption } = render();
  // v722 deliberately leaves get_ci_opportunities_v1's bespoke freshness shape untouched by the
  // shared envelope (F5 in the corpus) — this helper must not misread it as the shared shape.
  const html = caption({ freshness: { observed_since_min: '2026-08-01T00:00:00Z' } });
  assert.equal(html, '', 'a freshness block without age_hours/stale must not fabricate a caption from partial data');
});

/* ---------------------------------------------------------------------------------------------
   Wired into a real panel — funnelConversionPanelHtmlV679 — for fresh, stale and absent, proving
   this is not just a standalone helper but actually reaches the page.
   --------------------------------------------------------------------------------------------- */
const FUNNEL_BASE = {
  window_days: 30, time_basis: 'sale_occurred_at',
  stage_1_to_2: { numerator: 4, denominator: 6, pct: 66.7 },
  stage_2_to_3: { numerator: 2, denominator: 4, pct: 50.0 },
  immature: { first_stage: 1, second_stage: 0 },
  bottleneck: 'second_to_third',
  evidence: { n: 6, floor: 5, status: 'ok' },
  observed_since: '2026-08-01T00:00:00Z'
};

test('V734 wiring: funnelConversionPanelHtmlV679 renders the fresh caption', () => {
  const { funnel } = render();
  const html = funnel({ ...FUNNEL_BASE, freshness: FRESHNESS_FRESH });
  assert.ok(html.includes('Data as of WD:2026-09-02T09:00:00Z'));
  assert.ok(!html.includes('may be out of date'));
  assert.ok(html.includes('4 of 6 returned (66.7%)'), 'the panel still renders its own real numbers alongside the caption');
});

test('V734 wiring: funnelConversionPanelHtmlV679 renders the stale disclosure but still shows the full panel', () => {
  const { funnel } = render();
  const html = funnel({ ...FUNNEL_BASE, freshness: FRESHNESS_STALE });
  assert.ok(html.includes('Data may be out of date'));
  assert.ok(html.includes(FRESHNESS_STALE.note));
  assert.ok(html.includes('4 of 6 returned (66.7%)'),
    'a stale freshness block must never withhold the panel’s own real numbers — disclosure only');
  assert.ok(html.includes('Second to third visit'), 'the bottleneck verdict still renders under stale evidence');
});

test('V734 wiring: funnelConversionPanelHtmlV679 with no freshness key at all renders exactly as before v722', () => {
  const { funnel } = render();
  const html = funnel({ ...FUNNEL_BASE });
  assert.ok(!html.includes('ci-freshness-caption-v734'), 'no freshness key means no caption markup at all');
  assert.ok(html.includes('4 of 6 returned (66.7%)'));
});

/* ---------------------------------------------------------------------------------------------
   Wiring: source-level check that every named panel actually calls the shared helper — same
   posture as v679's own "wiring" test (call sites, not behaviour, for the ones not separately
   executed above).
   --------------------------------------------------------------------------------------------- */
test('V734 wiring: every named CI panel calls the shared freshness helper', () => {
  const callSites = [
    ['funnelConversionPanelHtmlV679', /function funnelConversionPanelHtmlV679\(payload\)\{[\s\S]*?ciFreshnessCaptionHtmlV734\(p\)/],
    ['demographicsPanelHtmlV679', /function demographicsPanelHtmlV679\(payload\)\{[\s\S]*?ciFreshnessCaptionHtmlV734\(p\)/],
    ['behaviourPanelHtmlV679', /function behaviourPanelHtmlV679\(payload\)\{[\s\S]*?ciFreshnessCaptionHtmlV734\(p\)/],
    ['opportunitiesPanelHtmlV685', /function opportunitiesPanelHtmlV685\(payload\)\{[\s\S]*?ciFreshnessCaptionHtmlV734\(payload\)/]
  ];
  for (const [name, pattern] of callSites) {
    assert.ok(pattern.test(app), `${name} must call ciFreshnessCaptionHtmlV734`);
  }
  const v650Panels = ['categoryMixMarkupV650(){', 'acquisitionMarkupV650(){', 'funnelMarkupV650(){', 'contactabilityMarkupV650(){'];
  for (const marker of v650Panels) {
    const start = app.indexOf(`function ${marker}`);
    assert.ok(start > -1, `${marker} must exist`);
    const end = app.indexOf('\n  }', start);
    assert.ok(end > start, `${marker} must be closed`);
    assert.ok(app.slice(start, end).includes('ciFreshnessCaptionHtmlV734('),
      `${marker} must call the shared freshness helper`);
  }
});
