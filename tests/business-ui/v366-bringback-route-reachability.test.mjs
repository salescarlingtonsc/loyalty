/* V366 — the Bring-back page must actually be reachable.
 *
 * v361 shipped a Bring-back module rendered when programmeView === 'bringback'. It never once
 * rendered in production: 'bringback' was ALSO in growPage's directFocusTokens set, which is read
 * first, so '#/grow/bringback' was rewritten into a FOCUS and programmeView fell back to 'list'.
 * routedAction then mapped that focus onto the winback surface, mounting the old Retention
 * programs deep editor — the screen the owner photographed and reported as "not fixed", twice.
 *
 * These tests execute the router's OWN two lines out of the shipped source rather than grepping
 * for them, because the defect was an interaction between two lines that each looked correct.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const source = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

const tokenLine = source.match(/const directFocusTokens=new Set\(\[[^\]]*\]\);/)?.[0];
const moveLine = source.match(/if\(!routedFocus&&\(directFocusTokens\.has\(hashParamBaseV294\)[^\n]*\n/)?.[0]?.trim();
/* V371 lifted the view list into one frozen constant shared with the deep-link guard
   (hashParamIsProgrammeView), because the two literals had drifted — this very route was added to
   one and not the other. Both the constant and the expression are pulled out of the shipped source
   so these cases still execute the router's own code, not a copy of it. */
const viewsConst = source.match(/const GROW_PROGRAMME_VIEWS_V371=Object\.freeze\(\[[^\]]*\]\);/)?.[0];
const viewExpression = source.match(
  /const programmeView=(GROW_PROGRAMME_VIEWS_V371\.includes\(String\(hashParam\|\|''\)\)\?String\(hashParam\):'list');/
)?.[1];
const guardExpression = source.match(
  /const hashParamIsProgrammeView=(GROW_PROGRAMME_VIEWS_V371\.includes\(String\(hashParam\|\|''\)\));/
)?.[1];

test('V366 the router pieces are still where this test reads them', () => {
  assert.ok(tokenLine, 'directFocusTokens must exist');
  assert.ok(moveLine, 'the hash-to-focus move must exist');
  assert.ok(viewsConst, 'the shared view list must exist');
  assert.ok(viewExpression, 'programmeView must be resolved from hashParam');
  assert.ok(guardExpression, 'the deep-link guard must read the SAME list, never its own literal');
});

const resolve = new Function('hashParam', `
  let routedFocus=null;
  ${viewsConst}
  ${tokenLine}
  const hashParamBaseV294=String(hashParam||'').replace(/~?ctx-(points|tiers)$/,'');
  ${moveLine}
  const programmeView=${viewExpression};
  const hashParamIsProgrammeView=${guardExpression};
  return {programmeView,routedFocus,hashParamIsProgrammeView};`);

test('V371 every view is also recognised by the deep-link guard, so none mounts a stray surface', () => {
  /* The sibling defect to V366, found by the V371 audit. programmeView and hashParamIsProgrammeView
     were two separate literals; V366 added 'bringback' to the first only, so opening the Bring-back
     page resolved as a view AND fell through to mountGrowSurface with draftOverride:'bringback' —
     a deep editor surface the owner never asked for, handed a view name where a draft id belongs.
     They read one frozen constant now, and this case proves the two answers cannot disagree. */
  for (const view of ['bringback', 'points', 'tiers', 'offers', 'history', 'overview', 'setup',
                      'ongoing', 'available', 'settings']) {
    const resolved = resolve(view);
    assert.equal(resolved.programmeView, view, `${view} must render as itself`);
    assert.equal(resolved.hashParamIsProgrammeView, true,
      `#/grow/${view} must be recognised as a view, or it also mounts a deep editor surface`);
  }
  // A genuine deep-link token is still NOT a view, so the editor path it needs stays open.
  assert.equal(resolve('birthday').hashParamIsProgrammeView, false);
});

test('V366 every dedicated Programmes view resolves as a VIEW, never as a focus token', () => {
  for (const view of ['bringback', 'points', 'tiers', 'offers', 'history', 'overview']) {
    const resolved = resolve(view);
    assert.equal(resolved.programmeView, view, `#/grow/${view} must render the ${view} view`);
    assert.equal(resolved.routedFocus, null, `#/grow/${view} must not be treated as a focus token`);
  }
});

test('V366 the remaining focus tokens still reach their editors', () => {
  for (const focus of ['earning', 'classic', 'birthday', 'add', 'new']) {
    const resolved = resolve(focus);
    assert.equal(resolved.routedFocus, focus, `${focus} must still be a focus token`);
    assert.equal(resolved.programmeView, 'list');
  }
});

test('V366 no view name may ever be a focus token again', () => {
  const views = [...viewExpression.matchAll(/'([a-z]+)'/g)].map(([, name]) => name);
  const tokens = [...tokenLine.matchAll(/'([a-z]+)'/g)].map(([, name]) => name);
  const both = views.filter((name) => tokens.includes(name));
  assert.deepEqual(both, [], `a name in both lists is unreachable as a view: ${both.join(', ')}`);
});
