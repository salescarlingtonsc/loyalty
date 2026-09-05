import assert from 'node:assert/strict';
import test from 'node:test';

import {
  assertStaticHtmlArtifacts,
  requiredStaticHtmlEntries,
  validateStaticBuild
} from '../../scripts/quality/build-static.mjs';
import { repoRoot } from '../../scripts/quality/static-baseline.mjs';

test('release artifact contract contains the public pages and offline fallback', () => {
  assert.deepEqual(requiredStaticHtmlEntries, [
    'data-request.html',
    /* nestly_v527: /app serves this — index.html with its 512KB inline stylesheet swapped for a
       fingerprinted <link>. index.html stays the source every test and fixture reads. */
    'index.gen.html',
    'index.html',
    'join.html',
    'landing.html',
    'offline.html',
    'privacy.html',
    /* nestly_v782: c8b08111 / 3a5476c0 moved billing from Stripe to Razorpay, and Razorpay
       Checkout deliberately runs on its own page so the app shell's CSP never allows a
       third-party script origin. It is a shipped release artifact with its own vercel header. */
    'razorpay-checkout.html',
    'support.html',
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
