/* NESTLY v892 — request parity for the Business Intelligence redesign.
 *
 * The v892 work is a PRESENTATION redesign of #/customerintel. The owner's contract for it is
 * explicit: the page must keep asking the backend exactly the same questions, with exactly the
 * same argument shapes, in exactly the same order. Nothing about the redesign may add a request,
 * drop one, re-scope one, or move a metric's meaning into the browser.
 *
 * So this file does not assert prose. It extracts the `Promise.all([...])` that run() awaits,
 * splits it into its top-level entries, normalises each one (comments and whitespace removed)
 * and compares the ordered result against a snapshot captured from the page BEFORE the redesign
 * landed (tests/fixtures/bi-request-parity-v892.json). It also captures every other backend call
 * the page makes — the pagination walk, the category drill, the CSV export — because a redesign
 * that quietly re-scoped one of those would be just as wrong.
 *
 * The ONE permitted difference is the page's default report period, which the owner changed from
 * 365 days to 30. That is asserted separately and deliberately, against the value the snapshot
 * records, so the diff is reviewed rather than absorbed: the default is a control's initial
 * value, and no metric may hard-code it.
 *
 * If the snapshot file is absent the first run writes it. That is the capture path; it is not a
 * licence to delete the file to make a failure go away.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const snapshotPath = join(root, 'tests', 'fixtures', 'bi-request-parity-v892.json');

const PAGE_START = 'async function customerIntelligencePage(){';
const pageStart = app.indexOf(PAGE_START);
assert.ok(pageStart > -1, 'customerIntelligencePage must be a top-level function in app/app.js');
const pageEnd = app.indexOf('\n}', app.indexOf("$('ciCsv').onclick=async()=>{", pageStart)) + 2;
assert.ok(pageEnd > pageStart, 'the page function must close at column zero');
const page = app.slice(pageStart, pageEnd);

/* Strip /* *​/ comments and collapse whitespace. A comment is documentation; a line break is
   formatting. Neither is a question asked of the backend, so neither belongs in the snapshot. */
const normalise = (source) => source
  .replace(/\/\*[\s\S]*?\*\//g, ' ')
  .replace(/\s+/g, ' ')
  .trim();

/* Split an argument list on top-level commas — string, bracket and template literal aware, so a
   comma inside {p_business:S.biz.id,…} or inside a nested call never splits an entry. */
function topLevelEntries(rawSource) {
  /* Comments go FIRST: a prose comma inside an explanatory comment is not a top-level comma,
     and splitting before stripping would cut one request into three. */
  const source = rawSource.replace(/\/\*[\s\S]*?\*\//g, ' ');
  const entries = [];
  let depth = 0, quote = '', start = 0;
  for (let at = 0; at < source.length; at += 1) {
    const char = source[at];
    if (quote) {
      if (char === '\\') { at += 1; continue; }
      if (char === quote) quote = '';
      continue;
    }
    if (char === "'" || char === '"' || char === '`') { quote = char; continue; }
    if (char === '(' || char === '[' || char === '{') { depth += 1; continue; }
    if (char === ')' || char === ']' || char === '}') { depth -= 1; continue; }
    if (char === ',' && depth === 0) { entries.push(source.slice(start, at)); start = at + 1; }
  }
  entries.push(source.slice(start));
  return entries.map(normalise).filter(Boolean);
}

function promiseAllEntries() {
  const marker = ']=await Promise.all([';
  const at = page.indexOf(marker);
  assert.ok(at > -1, "run() must still await one Promise.all of the page's reads");
  const from = at + marker.length;
  let depth = 1, to = from;
  for (; to < page.length && depth > 0; to += 1) {
    const char = page[to];
    if (char === '[' || char === '(' || char === '{') depth += 1;
    else if (char === ']' || char === ')' || char === '}') depth -= 1;
  }
  return topLevelEntries(page.slice(from, to - 1));
}

/* Every backend call the page makes, in source order, whether or not it is in the Promise.all. */
function pageCalls() {
  return [...normalise(page).matchAll(/sb\.(rpc|from)\('([a-z0-9_]+)'/g)].map((match) => `${match[1]}:${match[2]}`);
}

const current = { promiseAll: promiseAllEntries(), calls: pageCalls() };

if (!existsSync(snapshotPath)) {
  writeFileSync(snapshotPath, `${JSON.stringify({
    captured_at_default_from_shift: -364,
    note: 'Captured from app/app.js before the v892 Business Intelligence redesign. The only '
      + 'permitted difference afterwards is the default report period, asserted separately.',
    promiseAll: current.promiseAll,
    calls: current.calls
  }, null, 2)}\n`);
}
const snapshot = JSON.parse(readFileSync(snapshotPath, 'utf8'));

test('v892: the page asks the backend the same questions, in the same order, with the same arguments', () => {
  assert.deepEqual(current.promiseAll, snapshot.promiseAll,
    'the run() fan-out must be byte-identical to the pre-redesign capture');
  assert.equal(current.promiseAll.length, snapshot.promiseAll.length,
    'the redesign may neither add nor drop a request');
});

test('v892: every other backend call on the page — pagination, drill-down, export — is unchanged', () => {
  assert.deepEqual(current.calls, snapshot.calls,
    'the follow-up reads must be the same calls in the same order');
});

test('v892: the ONLY changed default is the report period — 365 days becomes 30', () => {
  /* Owner ruling: the page opens on the last 30 days, computed the way the Dashboard computes
     its own 30-day window (today-29..today). The snapshot records what it used to be. */
  assert.equal(snapshot.captured_at_default_from_shift, -364, 'the capture recorded the old default');
  assert.match(page, /const today=singaporeIsoDate\(\),from=shiftSingaporeDate\(today,-29\);/,
    'the default period is today-29..today, the Dashboard\'s own 30-day window');
  assert.doesNotMatch(page, /shiftSingaporeDate\(today,-364\)/, 'the 365-day default is gone');
});

test('v892: the default period is a control value only — no metric is computed from a literal 30', () => {
  /* Explicit scope: every read inside the fan-out takes the date inputs the owner can change
     (fromDate/toDate, and the comparison window derived from periodDays), never a fixed number
     of days. A literal 30 or -29 inside the fan-out would mean a metric had quietly pinned
     itself to the default instead of following the picker. */
  const fanOut = current.promiseAll.join('\n');
  assert.doesNotMatch(fanOut, /-29\b/, 'no request hard-codes the 30-day default');
  assert.doesNotMatch(fanOut, /\b30\b/, 'no request hard-codes a 30-day window');
  assert.match(fanOut, /p_from:fromDate/, 'the reads still follow the From input');
  assert.match(fanOut, /p_to:toDate/, 'the reads still follow the To input');
  assert.match(fanOut, /p_from:comparisonFromDate/, 'the comparison window is still derived from periodDays');
});
