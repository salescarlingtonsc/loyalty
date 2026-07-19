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
  const vercelConfig = JSON.parse(await readFile(path.join(root, 'vercel.json'), 'utf8'));
  const outputDirectory = path.join(root, vercelConfig.outputDirectory || '');
  const outputInfo = await stat(outputDirectory);

  assert.ok(outputInfo.isDirectory(), `Vercel outputDirectory does not exist: ${vercelConfig.outputDirectory}`);
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
