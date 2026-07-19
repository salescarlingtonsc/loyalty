import assert from 'node:assert/strict';
import test from 'node:test';

import {
  assertStaticHtmlArtifacts,
  requiredStaticHtmlEntries,
  validateStaticBuild
} from '../../scripts/quality/build-static.mjs';
import { repoRoot } from '../../scripts/quality/static-baseline.mjs';

test('release artifact contract contains exactly the five public HTML pages', () => {
  assert.deepEqual(requiredStaticHtmlEntries, [
    'data-request.html',
    'index.html',
    'join.html',
    'privacy.html',
    'terms.html'
  ]);
  assert.doesNotThrow(() => assertStaticHtmlArtifacts(requiredStaticHtmlEntries));
});

test('release artifact contract rejects missing and unexpected HTML pages', () => {
  assert.throws(
    () => assertStaticHtmlArtifacts(requiredStaticHtmlEntries.filter((entry) => entry !== 'terms.html')),
    /only the required release HTML artifacts/
  );
  assert.throws(
    () => assertStaticHtmlArtifacts([...requiredStaticHtmlEntries, 'debug.html']),
    /only the required release HTML artifacts/
  );
});

test('current static release artifacts satisfy the contract', async () => {
  await validateStaticBuild(repoRoot);
});
