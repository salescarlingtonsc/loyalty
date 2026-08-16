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
const viewExpression = source.match(
  /const programmeView=(\[[^\]]*\]\.includes\(String\(hashParam\|\|''\)\)\?String\(hashParam\):'list');/
)?.[1];

test('V366 the three router pieces are still where this test reads them', () => {
  assert.ok(tokenLine, 'directFocusTokens must exist');
  assert.ok(moveLine, 'the hash-to-focus move must exist');
  assert.ok(viewExpression, 'programmeView must be resolved from hashParam');
});

const resolve = new Function('hashParam', `
  let routedFocus=null;
  ${tokenLine}
  const hashParamBaseV294=String(hashParam||'').replace(/~?ctx-(points|tiers)$/,'');
  ${moveLine}
  const programmeView=${viewExpression};
  return {programmeView,routedFocus};`);

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
