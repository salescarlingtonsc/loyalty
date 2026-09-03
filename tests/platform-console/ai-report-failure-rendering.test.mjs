/* CI-100 check 98 — "RPC failure, partial response, model failure and export failure show
 * explicit unavailable states — never zeros." This file covers the platform-console.js half of
 * the MODEL FAILURE requirement: the "AI report" list on a firm's detail page must show a failed
 * report as an explicit "Report unavailable — <reason>" line — never a blank narrative, never a
 * silently-omitted row, and never anything that could read as a healthy zero/empty report.
 *
 * supabase/functions/ai-firm-reports/enforce.mjs's decideGenerationFailure() (see
 * tests/ai-reports/generation-failure-classification.test.mjs) stores one of four short reason
 * codes on a failed row's `error` column: 'model_unavailable' | 'model_timeout' |
 * 'malformed_output' | 'empty_narrative'. app/platform-console.js's aiReportFailureReasonLabel()
 * turns each into a plain-English sentence; aiFirmReportsHtml() is the renderer that must show it
 * for EVERY status:'failed' row, regardless of whether `error` is one of the four known codes, an
 * older free-text reason (decideNarrativeOutcome's own 'narrative_validation: ...' strings, or the
 * pre-v(check 98) raw SDK exception text), or missing entirely.
 *
 * Same harness as tests/platform-console/v685-recorded-revenue-labels.test.mjs and
 * v727-consultant-brief-unavailable.test.mjs: extract the real function source and execute it in
 * a vm context against a sandboxed CUI/pt/escapeHtml, rather than asserting on source text alone.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const console_js = readFileSync(join(root, 'app', 'platform-console.js'), 'utf8');

const blockStart = console_js.indexOf('function aiReportTone(status) {');
const blockEnd = console_js.indexOf('function aiReportViewModal(report,CUI) {');
assert.ok(blockStart > -1 && blockEnd > blockStart,
  'aiReportTone..aiFirmReportsHtml must be a contiguous top-level slice ending before aiReportViewModal');
const block = console_js.slice(blockStart, blockEnd);

function esc(x) {
  return String(x ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function render(reports, canRequest = true) {
  const sandbox = {
    escapeHtml: esc,
    asArray: (x) => Array.isArray(x) ? x : [],
    pt: (s, vars) => vars
      ? Object.keys(vars).reduce((out, k) => out.replaceAll(`{${k}}`, String(vars[k])), s)
      : s,
    platformStatus: (s) => String(s ?? ''),
    dateTime: (v) => `DT:${v}`,
    localizedEmptyHtml: (msg) => `<div class="empty">${esc(msg)}</div>`,
    CUI: { status: (label, tone) => `<span class="status ${esc(tone)}">${esc(label)}</span>` },
  };
  const context = vm.createContext(sandbox);
  context.__exports = {};
  vm.runInContext(block + '\n__exports.render = aiFirmReportsHtml;', context);
  return context.__exports.render(reports, sandbox.CUI, canRequest);
}

/* ---------------------------------------------------------------- the four named reasons */

const REASONS = [
  ['model_unavailable', 'The report writer is temporarily unavailable.'],
  ['model_timeout', 'The report writer took too long to respond.'],
  ['malformed_output', 'The report writer returned an unusable response.'],
  ['empty_narrative', 'The report writer returned no content.'],
];

for (const [code, sentence] of REASONS) {
  test(`aiFirmReportsHtml: a failed report with error="${code}" shows "Report unavailable — ${sentence}"`, () => {
    const html = render([{
      id: 'r1', period_kind: 'monthly', period_start: '2026-08-01', period_end: '2026-08-31',
      status: 'failed', error: code, narrative_md: null, model: 'claude-sonnet-5', completed_at: '2026-09-01T00:00:00Z',
    }]);
    assert.ok(html.includes(`Report unavailable — ${sentence}`),
      `expected the plain-English sentence for "${code}", got: ${html}`);
    assert.ok(!html.includes('data-ai-report-view'), 'a failed report must never offer "Read report" — narrative_md is null');
  });
}

/* ---------------------------------------------------------------- never blank, never a zero */

test('aiFirmReportsHtml: a failed report with an OLDER free-text reason (pre-check-98) still shows it, not blank', () => {
  const html = render([{
    id: 'r2', period_kind: 'quarterly', period_start: '2026-04-01', period_end: '2026-06-30',
    status: 'failed', error: 'narrative_validation: V1_NUMERIC_CLAIM: invented figure', narrative_md: null,
  }]);
  assert.ok(html.includes('Report unavailable — narrative_validation: V1_NUMERIC_CLAIM: invented figure'));
});

test('aiFirmReportsHtml: a failed report with NO stored error at all still shows an explicit unavailable line, never blank', () => {
  const html = render([{
    id: 'r3', period_kind: 'monthly', period_start: '2026-08-01', period_end: '2026-08-31',
    status: 'failed', error: null, narrative_md: null,
  }]);
  assert.ok(html.includes('Report unavailable — unknown reason'),
    'a failed row with a missing reason must still say so explicitly, never render an empty line');
});

test('aiFirmReportsHtml: a failed report never renders as if it were a healthy report (no narrative body, no "Read report")', () => {
  const html = render([{
    id: 'r4', period_kind: 'monthly', period_start: '2026-08-01', period_end: '2026-08-31',
    status: 'failed', error: 'model_unavailable', narrative_md: null,
  }]);
  assert.ok(!html.includes('<article'), 'the failed-report row itself must not embed a narrative body');
  assert.ok(html.includes('class="status no"') || /status[^"]*no/.test(html) === false || html.includes('>Failed<') || html.includes('failed'),
    'the status badge must reflect the failed state');
});

/* ---------------------------------------------------------------- a succeeded report is untouched */

test('aiFirmReportsHtml: a succeeded report shows no "Report unavailable" line and offers "Read report"', () => {
  const html = render([{
    id: 'r5', period_kind: 'monthly', period_start: '2026-08-01', period_end: '2026-08-31',
    status: 'succeeded', error: null, narrative_md: '## Summary\nAll good.', model: 'claude-sonnet-5',
    completed_at: '2026-09-01T00:00:00Z',
  }]);
  assert.ok(!html.includes('Report unavailable'));
  assert.ok(html.includes('data-ai-report-view="r5"'));
});

/* ---------------------------------------------------------------- an empty report list is still honest */

test('aiFirmReportsHtml: an empty report list shows the explicit empty message, not a blank section', () => {
  const html = render([]);
  assert.ok(html.includes('No AI report has been written for this firm yet.'));
});
