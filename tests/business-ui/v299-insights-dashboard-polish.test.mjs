/* V299 Business Insights / Dashboard presentation polish — regressions.
 *
 * Each assertion fails against the pre-V299 source:
 *  1. `.metric` and `.report-scope-card` finally have CSS — every Insights tab's headline
 *     number rendered at body size directly beneath the 1.85rem V297 verdict value.
 *  2. The Dashboard delta chip speaks the same three-tone language as Insights: a fall is
 *     the red `no` pill, not the same grey `off` pill a flat 0% gets.
 *  3. The V297 cards no longer restate the previous-period figure the verdict band one line
 *     above them already states (the exact duplication V200 removed from the Dashboard).
 *  4. The report share-bar palette reads from :root --chart-* tokens instead of six literals,
 *     and the bring-back playbook reuses the same bar component instead of a third hand-rolled
 *     idiom, with its headline in ink rather than the disabled grey.
 *  5. The Dashboard KPI grid is tile-count-agnostic (2 or 3 tiles no longer float in a fixed
 *     4-column row).
 *  6. Business Insights has quick date-range presets (7/30/90 days, 6/12 months) that fill the
 *     SAME From/To pair and press the same Run — no new computation path.
 *  7. Customer 360 states Member since from the already-fetched client row; the dead
 *     '30_59' inactivity assignment (overwritten on the next line since V290) is gone.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const app=await readFile(new URL('../../app/app.js',import.meta.url),'utf8');
const indexHtml=await readFile(new URL('../../app/index.html',import.meta.url),'utf8');

test('.metric and .report-scope-card have real rules',()=>{
  assert.match(indexHtml,/\.metric\{font-size:1\.6rem;font-weight:750/);
  assert.match(indexHtml,/@media\(max-width:720px\)\{\.metric\{font-size:22px\}\}/);
  assert.match(indexHtml,/\.report-scope-card\{padding:16px 18px\}/);
  assert.match(indexHtml,/\.report-scope-card \.range input\[type=date\]\{width:auto;min-width:150px\}/);
});

test('dashboard delta chip gains the down tone',()=>{
  assert.match(app,/metric-delta pill \$\{change>0\?'ok':change<0\?'no':'off'\}/);
});

test('V297 cards do not restate the previous-period figure under their own verdict band',()=>{
  assert.doesNotMatch(app,/booked hours in the previous \$\{scope\.days\}-day period/);
  assert.doesNotMatch(app,/\$\{previousReturning\} in the previous \$\{scope\.days\}-day period/);
});

test('share-bar palette reads from tokens and the playbook reuses the shared bar',()=>{
  assert.match(indexHtml,/--chart-1:#C24135; --chart-2:#1F6B48; --chart-3:#1F5199; --chart-4:#8A5A12; --chart-5:#7A2E9D; --chart-6:#6B6673;/);
  assert.match(app,/const REPORT_SHARE_COLOURS_V297=\['var\(--chart-1\)','var\(--chart-2\)','var\(--chart-3\)','var\(--chart-4\)','var\(--chart-5\)','var\(--chart-6\)'\]/);
  assert.match(app,/<div class="report-share-bar-v297" style="margin-top:4px"><span style="width:\$\{Math\.max\(value\/scale\*100,value>0\?4:0\)\}%;background:\$\{colour\}"><\/span><\/div>/);
  assert.doesNotMatch(app,/height:12px;border-radius:6px;background:var\(--line\);overflow:hidden;margin-top:3px/);
  assert.match(app,/return `<div class="metric">\$\{esc\(headline\)\}<\/div>/);
  assert.doesNotMatch(app,/font-size:1\.7rem;font-weight:700;color:var\(--muted\)/);
});

test('dashboard KPI grid is tile-count-agnostic',()=>{
  assert.match(indexHtml,/\.dashboard-kpis\.v150-dashboard-kpis\{grid-template-columns:repeat\(auto-fit,minmax\(170px,1fr\)\)\}/);
  assert.doesNotMatch(indexHtml,/\.dashboard-kpis\.v150-dashboard-kpis\{grid-template-columns:repeat\(4,minmax\(150px,1fr\)\)\}/);
});

test('Business Insights carries quick-range presets that press the existing Run',()=>{
  assert.match(app,/\[\[7,'7 days'\],\[30,'30 days'\],\[90,'90 days'\],\[182,'6 months'\],\[365,'12 months'\]\]/);
  assert.match(app,/data-report-preset-days="\$\{presetDays\}"/);
  assert.match(app,/\$\('rf'\)\.value=shiftSgDateInput\(today,-\(presetDays-1\)\);/);
  assert.match(app,/data-report-preset-days[\s\S]{0,400}?\$\('rgo'\)\.click\(\);/);
  assert.match(indexHtml,/\.report-scope-presets\{display:flex;gap:6px;flex-wrap:wrap;margin-top:10px\}/);
});

test('customer 360 states Member since from the fetched row',()=>{
  assert.match(app,/select\('id,business_id,full_name,phone,email,referral_code,marketing_consent,created_at'\)/);
  assert.match(app,/c\.created_at\?summaryRowV294\('Member since',`<b>\$\{esc\(formatCustomerJoinedDateV141\(c\.created_at\)\)\}<\/b>`\):''/);
});
