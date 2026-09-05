import assert from 'node:assert/strict';
import { readdir, readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { repoRoot, checkStaticEntryFiles, checkVercelSecurityHeaders } from './static-baseline.mjs';

const __filename = fileURLToPath(import.meta.url);

export const requiredStaticHtmlEntries = Object.freeze([
  'data-request.html',
  'index.gen.html',  // nestly_v527: what /app actually serves — index.html minus its inline stylesheet
  'index.html',
  'join.html',
  // V274: the marketing landing page is what "/" now rewrites to; index.html moved to /app.
  'landing.html',
  'offline.html',
  'privacy.html',
  /* nestly_v755 (c8b08111 / 3a5476c0: "Razorpay edge functions replace Stripe billing and
     Connect"): Razorpay Checkout runs on its OWN page, deliberately, so that app/index.html's
     CSP never has to allow a third-party script origin. It carries its own scoped CSP and its
     own app/vercel.json header rule, so it is a required release artifact, not stray output. */
  'razorpay-checkout.html',
  // nestly_v672: the public support desk, rewritten from /support.
  'support.html',
  'terms.html'
]);

export function assertStaticHtmlArtifacts(entries) {
  assert.deepEqual(
    [...entries].sort(),
    requiredStaticHtmlEntries,
    'Static build output must expose only the required release HTML artifacts.'
  );
}

export async function validateStaticBuild(root = repoRoot) {
  // The Vercel project's Root Directory is `app`, so the effective config is app/vercel.json
  // and the deployed output is the app directory itself (no outputDirectory override).
  const vercelConfig = JSON.parse(await readFile(path.join(root, 'app', 'vercel.json'), 'utf8'));
  assert.equal(vercelConfig.outputDirectory, undefined,
    'app/vercel.json must not set outputDirectory: the Vercel Root Directory is already app.');
  const outputDirectory = path.join(root, 'app');
  const outputInfo = await stat(outputDirectory);

  assert.ok(outputInfo.isDirectory(), 'Vercel root directory app/ does not exist.');
  await checkStaticEntryFiles(root);
  await checkVercelSecurityHeaders(root);

  const entries = (await readdir(outputDirectory)).filter((entry) => entry.endsWith('.html'));
  assertStaticHtmlArtifacts(entries);

  return { outputDirectory, entries: entries.sort() };
}

if (process.argv[1] === __filename) {
  const { outputDirectory, entries } = await validateStaticBuild();
  console.log(`Static build validation passed for ${path.relative(repoRoot, outputDirectory) || '.'}: ${entries.join(', ')}`);
}
