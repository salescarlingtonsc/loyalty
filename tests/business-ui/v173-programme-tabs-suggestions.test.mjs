import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* V173 Programmes simplification (owner request 2026-08-06): the Overview / Ongoing /
   Available tabs rendered IDENTICAL content in production because the row-filter set the
   hidden attribute while .grow-programme-row declares display:grid, which overrides the UA's
   [hidden]{display:none}. Plus: every not-set-up programme row now carries a concrete
   "Suggested" strip with a one-tap prefill into the right editor. */

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(resolve(repoRoot, 'app/index.html'), 'utf8');

test('the hidden attribute actually hides programme rows (tab filter is real)', () => {
  assert.match(app, /\.grow-programme-row\[hidden\]\{display:none!important\}/);
  assert.match(app, /\.programme-category\[hidden\]\{display:none!important\}/);
  // the filter itself must still exist
  assert.match(app, /const show=programmeView==='ongoing'\?isOngoing:!isOngoing;/);
});

test('tabs are named for what they show', () => {
  assert.match(app, /programmeTab\('ongoing','Running'\)/);
  assert.match(app, /programmeTab\('available','To set up'\)/);
  assert.match(app, /Live for your customers right now\./);
  assert.match(app, /suggested starting point you can use in one tap/);
});

test('every not-set-up growth surface has a suggestion with a one-tap prefill', () => {
  const start = app.indexOf('const suggestions={');
  assert.ok(start > 0);
  const block = app.slice(start, start + 1200);
  for (const kind of ['birthday', 'bringback', 'referrals']) {
    assert.match(block, new RegExp(`${kind}:\\{text:`), `${kind} suggestion must exist`);
  }
  assert.match(app, /data-suggest-use=/);
  // strips are siblings of the row buttons, never nested interactive controls
  assert.match(app, /row\.insertAdjacentHTML\('afterend',`<div class="programme-suggest"/);
});

test('each suggestion kind has a consumer that fills the real editor fields once', () => {
  assert.match(app, /pendingProgrammeSuggestV172\?\.kind!=='birthday'\)return false;/);
  assert.match(app, /pendingProgrammeSuggestV172\?\.kind==='bringback'&&\$\('rn'\)/);
  assert.match(app, /pendingProgrammeSuggestV172\?\.kind==='referral'&&\$\('fm'\)/);
  // one-shot: every consumer clears the pending value
  const clears = app.match(/const suggest=pendingProgrammeSuggestV172;pendingProgrammeSuggestV172=null;/g) || [];
  assert.ok(clears.length >= 3, 'all three consumers must consume exactly once');
});

test('the suggestion wiring lives in growPage render path, not a nested helper', () => {
  // It first shipped inside openRewardsAutoSetup, so it never ran on page render and no
  // strip ever appeared in production. Position is the behaviour here.
  const block = app.indexOf('const suggestions={');
  const growPage = app.indexOf('async function growPage');
  const mountSurface = app.indexOf('async function mountGrowSurface');
  assert.ok(block > growPage, 'must be inside growPage');
  assert.ok(block < mountSurface,
    'must run in growPage render path, before the nested mountGrowSurface/auto-setup helpers');
  const filter = app.indexOf("const show=programmeView==='ongoing'?isOngoing:!isOngoing;");
  assert.ok(block > filter, 'must run after the tab filter so hidden rows are skipped');
});

test('suggestion rows are queried from outerMain, not document', () => {
  // A document-wide query ran against the previous page's DOM and inserted nothing at all
  // in production. The tab filter above it already scopes to outerMain; match it.
  const start = app.indexOf('const suggestions={');
  const block = app.slice(start, start + 1800);
  assert.match(block, /outerMain\.querySelectorAll\('\.grow-programme-row'\)/);
  assert.doesNotMatch(block, /document\.querySelectorAll\('\.grow-programme-row'\)/);
});

test('V174: two tabs only, Running is default, advanced settings stay reachable', () => {
  assert.doesNotMatch(app, /programmeTab\('overview'/);
  assert.doesNotMatch(app, /programmeTab\('settings'/);
  assert.match(app, /\?String\(hashParam\):'ongoing';/, 'bare #\/grow must land on Running');
  assert.match(app, /id="growSecondarySettings"/, 'advanced settings section must remain on-page');
  assert.match(app, /Nothing is running yet\./, 'Running must explain itself when empty');
});
