import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* V172 regression: #/grow/ongoing|available|settings carry the TAB name in the deep-link
   parameter slot. The handler built {surface:'overview'}, indexed a dictionary holding only
   rewards|winback|studio, and crashed the workspace on definition.hash — from the page's own
   tabs. These assertions pin both layers of the fix. */

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = (readFileSync(resolve(repoRoot, 'app/index.html'),'utf8')+'\n'+readFileSync(resolve(repoRoot, 'app/app.js'),'utf8'));

test('mountGrowSurface refuses unknown surfaces instead of crashing', () => {
  const fn = app.slice(app.indexOf('async function mountGrowSurface'), app.indexOf('const preserveExactRoute'));
  assert.match(fn, /const definition=surfaceDefinition\[surface\];/);
  /* nestly_v435: the guard still refuses and returns, but the page's OWN tab names (overview /
     ongoing / available / settings, and an empty slot) no longer shout console.error on every
     Overview render — 22 errors per visit buried real ones in the 2026-08-22 simulation.
     Genuinely unknown values still log. */
  assert.match(fn, /if\(!definition\)\{/,
    'the guard must run before any definition.* access');
  assert.match(fn, /console\.error\('unknown grow surface',surface\)/,
    'a genuinely unknown surface is still reported');
  assert.match(fn, /\['overview','ongoing','available','settings',''\]\.includes\(String\(surface\|\|''\)\)/,
    'the page\'s own tab names are a silent no-op, not console noise');
  assert.ok(fn.indexOf('if(!definition)') < fn.indexOf('definition.hash'),
    'guard must precede the definition.hash read');
});

test('programme-view tab hashes never mount an engine surface', () => {
  // V271 added 'overview' and 'history'; they are views of this page, so they must be in the same
  // guard — a view hash that reached the surface dictionary is what crashed this page once.
  /* V301 ADDITION (owner 2026-08-13: the one-page setup wizard): 'setup' is another VIEW of
     this page, so it joins the same guard for the same reason 'overview' and 'history' did — a
     view hash that reached the surface dictionary is what crashed this page once. */
  /* V371 lifted the view list into one frozen constant shared with programmeView, because the two
     literals had drifted (V366 added 'bringback' to one only, so the Bring-back page also mounted a
     deep editor surface). The guard reads that constant now. */
  assert.match(app, /const hashParamIsProgrammeView=GROW_PROGRAMME_VIEWS_V371\.includes\(String\(hashParam\|\|''\)\);/);
  assert.match(app, /if\(!hashParamIsProgrammeView&&\(\(routedAction&&isOwner\)\|\|\(hashParam&&isOwner\)\|\|routedSurface==='studio'\)\)/);
});

test('the route crash card uses owner language, not raw error.message', () => {
  const idx = app.indexOf('unavailable`,message:');
  assert.ok(idx > 0);
  assert.match(app.slice(idx - 200, idx + 200), /ownerErrorText\(error\)/,
    'route-level errorState must route through ownerErrorText');
});
