/* Regression guard for the V200 production outage.
   V200 deleted `const headline` from the dashboard renderer and left four references behind.
   node --check passed, all ~1850 tests passed, the build shipped, and every dashboard threw
   "Can't find variable: headline" on load. Nothing in the suite could have caught it, because
   an undeclared identifier is a runtime ReferenceError and no test executes that render path.
   This test is the thing that would have. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { findUndeclared } from '../../scripts/quality/undeclared-identifiers.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const source = readFileSync(join(root, 'app', 'app.js'), 'utf8');

test('every versioned identifier referenced in app/app.js has a declaration', () => {
  const { checked, missing } = findUndeclared(source);
  assert.ok(checked > 100, `expected to check a meaningful number of references, got ${checked}`);
  assert.deepEqual(
    missing.map((entry) => entry.name),
    [],
    'these names are referenced but never declared — they will throw ReferenceError in production'
  );
});

test('the guard actually catches the V200 bug shape', () => {
  // Proof the check is not vacuous: reintroduce exactly what V200 shipped.
  const broken = source.replace(
    'function insightCardV153(insight){',
    'function unusedProbeV999(){return orphanedConstV200}\nfunction insightCardV153(insight){'
  );
  assert.notEqual(broken, source, 'probe anchor must exist');
  const { missing } = findUndeclared(broken);
  assert.ok(
    missing.some((entry) => entry.name === 'orphanedConstV200'),
    'a reference with no declaration must be reported'
  );
});
