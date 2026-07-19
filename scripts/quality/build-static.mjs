import assert from 'node:assert/strict';
import { readdir, readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { repoRoot, checkStaticEntryFiles, checkVercelSecurityHeaders } from './static-baseline.mjs';

const __filename = fileURLToPath(import.meta.url);

export const requiredStaticHtmlEntries = Object.freeze([
  'data-request.html',
  'index.html',
  'join.html',
  'privacy.html',
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
