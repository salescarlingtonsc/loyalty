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
  assert.match(fn, /if\(!definition\)\{console\.error\('unknown grow surface',surface\);return\}/,
    'the guard must run before any definition.* access');
  assert.ok(fn.indexOf('if(!definition)') < fn.indexOf('definition.hash'),
    'guard must precede the definition.hash read');
});

test('programme-view tab hashes never mount an engine surface', () => {
  // V271 added 'overview' and 'history'; they are views of this page, so they must be in the same
  // guard — a view hash that reached the surface dictionary is what crashed this page once.
  /* V301 ADDITION (owner 2026-08-13: the one-page setup wizard): 'setup' is another VIEW of
     this page, so it joins the same guard for the same reason 'overview' and 'history' did — a
     view hash that reached the surface dictionary is what crashed this page once. */
  assert.match(app, /hashParamIsProgrammeView=\['overview','history','offers','points','tiers','ongoing','available','settings','setup'\]\.includes\(String\(hashParam\|\|''\)\)/);
  assert.match(app, /if\(!hashParamIsProgrammeView&&\(\(routedAction&&isOwner\)\|\|\(hashParam&&isOwner\)\|\|routedSurface==='studio'\)\)/);
});

test('the route crash card uses owner language, not raw error.message', () => {
  const idx = app.indexOf('unavailable`,message:');
  assert.ok(idx > 0);
  assert.match(app.slice(idx - 200, idx + 200), /ownerErrorText\(error\)/,
    'route-level errorState must route through ownerErrorText');
});
