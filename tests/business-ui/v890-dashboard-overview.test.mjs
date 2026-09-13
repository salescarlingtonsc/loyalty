import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
/* nestly_v890 — owner ruling 2026-09-13: the Dashboard card is a simple overview (three tiles and
   one link); the sentences and every grouped answer moved into Customer intelligence, read from
   the same cached response. These tests execute the tile builder against the v826 fixture shape
   and pin the composition on both pages. */
const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
function extractFunction(src, name) {
  const m = new RegExp(`^(?:async )?function ${name}\\(`, 'm').exec(src);
  assert.ok(m, `missing function ${name}`);
  const acc = [];
  for (const line of src.slice(m.index).split('\n')) { acc.push(line); if (line === '}') return acc.join('\n'); }
  throw new Error('no close');
}
function tiles(brief) {
  const ctx = vm.createContext({
    esc: (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])),
    money: (c) => `SGD ${((c || 0) / 100).toFixed(2)}`,
  });
  for (const name of ['ownerBriefPctV826', 'ownerBriefTileV890', 'ownerBriefOverviewV890']) vm.runInContext(extractFunction(app, name), ctx);
  return vm.runInContext(`ownerBriefOverviewV890(${JSON.stringify(brief)})`, ctx);
}
const cubbly = {
  week: { status: 'ok', revenue_cents: 3000, visits: 2, revenue_delta_pct: -96.4, baseline: { revenue_cents: 83166 }, driver: 'basket' },
  customers: { status: 'ok', new_customers: 0, returning_customers: 1 },
  at_risk: { status: 'ok', overdue: 1, slipping: 0, monthly_at_risk_cents: 145706 },
};
test('v890: three tiles, plain words, no sentences', () => {
  const html = tiles(cubbly);
  assert.equal((html.match(/dashboard-brief-tile-v890/g) || []).length, 3);
  assert.match(html, /Last 7 days<\/span>.*SGD 30\.00/s);
  assert.match(html, /96% below a normal week \(SGD 831\.66\)/);
  assert.match(html, /Customers this week<\/span>.*<div class="v">1<\/div>.*0 new · 1 returning/s);
  assert.match(html, /Regulars overdue<\/span>.*<div class="v">1<\/div>.*SGD 1457\.06 a month at stake/s);
  assert.match(html, /is-warn/);
  assert.doesNotMatch(html, /Busiest|reward|outlet|Suggested|All answers/i, 'analytics sentences stay off the Dashboard');
  const text = html.replace(/<[^>]+>/g, ' ');
  assert.doesNotMatch(text, /NaN|undefined|\bnull\b/);
});
test('v890: absent facts render a dash, never a zero; no overdue is good news', () => {
  const html = tiles({ week: { status: 'unavailable' }, customers: {}, at_risk: { status: 'ok', overdue: 0, slipping: 0 } });
  assert.equal((html.match(/<div class="v">—<\/div>/g) || []).length, 2);
  assert.match(html, /Nobody is overdue/);
  assert.match(html, /is-good/);
  assert.equal(tiles(null).match(/dashboard-brief-tile-v890/g).length, 3, 'a null brief still draws three tiles');
});
test('v890: the Dashboard card links to Customer intelligence and carries no list', () => {
  const renderer = extractFunction(app, 'ownerBriefRenderV826');
  assert.match(renderer, /href="#\/customerintel">Full brief in Customer intelligence</);
  assert.match(renderer, /canReadModule\('customerintel'\)/, 'the link is gated on the module');
  assert.match(renderer, /ownerBriefOverviewV890\(response\?\.brief\)/);
  const dash = app.slice(app.indexOf('async function dashboard(){'), app.indexOf('async function dashboard(){') + 6000);
  assert.match(dash, /id="dashboardBriefTiles"/);
  assert.match(dash, /<h2 class="eyebrow" id="dashboardBriefTitle">This week<\/h2>/);
});
test('v890: Customer intelligence composes the nightly brief between the Owner brief and Detailed analysis', () => {
  const ci = app.slice(app.indexOf('async function customerIntelligencePage(){'));
  const paint = ci.indexOf('${ownerBriefMarkupV771()}${nightlyBriefMarkupV890()}<details class="card ci-detailed-analysis-v771"');
  assert.ok(paint > 0, 'nightly brief sits after the Owner brief and before the disclosure');
  assert.match(ci, /ownerBriefFetchV826\(\)\.catch\(\(\)=>null\)/, 'read through the shared, cached fetch');
  assert.equal((app.match(/sb\.rpc\('get_owner_brief_v1'/g) || []).length, 1, 'still exactly one call site');
});
