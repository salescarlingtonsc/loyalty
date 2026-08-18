import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

/* V389 — the owner's photo 1 of 2026-08-18: the Modules list on Settings, chips lying on top of
 * one another with their backgrounds broken across lines. "the modules are lump together, very
 * messy. i need you to have a structure and frame it easier to read."
 *
 * It had a cause, not just a look. The list wore .platform-module-list and .chip, and BOTH are
 * defined only in app/platform-console.css — a stylesheet app.js fetches on demand for #/platform
 * routes (loadPlatformConsoleAssetsV184) and which this page therefore never loads. With no rules
 * at all the container had no layout and each chip fell back to an inline span, which is exactly
 * what an inline element with a background does when it wraps.
 */

const appJs=readFileSync(new URL('../../app/app.js',import.meta.url),'utf8');
const indexHtml=readFileSync(new URL('../../app/index.html',import.meta.url),'utf8');
const consoleCss=readFileSync(new URL('../../app/platform-console.css',import.meta.url),'utf8');
const consoleJs=readFileSync(new URL('../../app/platform-console.js',import.meta.url),'utf8');

const settings=(()=>{
  const from=appJs.indexOf('async function settingsPage(){');
  const to=appJs.indexOf('/* ---------- billing (read-only) ---------- */',from);
  assert.ok(from>=0&&to>from);
  return appJs.slice(from,to);
})();

test('V389 the Settings module list no longer borrows the platform console\'s stylesheet',()=>{
  assert.doesNotMatch(settings,/class="platform-module-list"/,
    'this page never loads platform-console.css, so that container has no rules here');
  assert.doesNotMatch(settings,/class="chip on"/);
  /* The precise defect: .chip is styled in this stylesheet but sets no display, so without the
     flex container it stayed inline and its padded background broke across every wrapped line. */
  assert.match(indexHtml,/^\.chip\{(?!.*display)/m);
  assert.match(settings,/class="settings-module-grid-v389"/);
});

test('V389 the class it uses is styled in the stylesheet this page actually loads',()=>{
  for(const rule of ['.settings-module-grid-v389','.settings-module-v389',
                     '.settings-module-name-v389','.settings-module-uses-v389'])
    assert.ok(indexHtml.includes(rule),`${rule} must be styled in app/index.html`);
  /* The regression that started this: a background on an element that is not laid out as a block. */
  assert.match(indexHtml,/\.settings-module-v389\{display:flex;flex-direction:column;/);
});

test('V389 the console keeps its own list — this fix did not reach across into it',()=>{
  assert.match(consoleCss,/\.platform-module-list\{/);
  assert.match(consoleJs,/platform-module-list/);
});

test('V389 the module name leads and its dependencies are a quieter second line',()=>{
  /* "uses Customers, Sales & refunds" was half the title before; it is a footnote now. */
  assert.match(settings,/<span class="settings-module-name-v389">\$\{CUI\.icon\(MODULES\[m\]\[0\]/);
  assert.match(settings,/<span class="settings-module-uses-v389">uses \$\{esc\(dependencyText\(m\)\)\}/);
  /* Long names and long dependency lists must not push the cell wider than its column. */
  assert.match(indexHtml,/\.settings-module-name-v389 b\{font-weight:650;overflow-wrap:anywhere\}/);
  assert.match(indexHtml,/\.settings-module-uses-v389\{[^}]*overflow-wrap:anywhere/);
});

test('V389 it is a grid that reflows, so a phone gets columns rather than one long strip',()=>{
  const grid=indexHtml.match(/\.settings-module-grid-v389\{([^}]*)\}/)?.[1]||'';
  assert.match(grid,/display:grid/);
  const min=Number(grid.match(/minmax\((\d+(?:\.\d+)?)px/)?.[1]);
  assert.ok(min>0&&min<=170,`a ${min}px minimum still fits two columns on a 375px phone`);
  assert.match(grid,/repeat\(auto-fill/);
});

test('V389 an entitlement with no dependencies prints no empty second line',()=>{
  assert.match(settings,/\$\{dependencyText\(m\)\?`<span class="settings-module-uses-v389">/);
});

test('V389 no modules assigned still says so',()=>{
  assert.match(settings,/No optional modules are assigned\./);
});
