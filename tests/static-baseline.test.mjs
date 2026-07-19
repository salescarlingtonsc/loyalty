import test from 'node:test';

import {
  checkCdnDependencyPins,
  checkCdnScriptIntegrity,
  checkMigrationFilenameSanity,
  checkPublicPageForms,
  checkStaticEntryFiles,
  checkSupabaseClientContract,
  checkSupabaseProjectReferences,
  checkVercelSecurityHeaders,
  repoRoot
} from '../scripts/quality/static-baseline.mjs';

test('static entry files and Vercel output directory exist', async () => {
  await checkStaticEntryFiles(repoRoot);
});

test('deployable app files do not mix Supabase project refs', async () => {
  await checkSupabaseProjectReferences(repoRoot);
});

test('deployable clients use the Singapore Supabase URL and publishable key', async () => {
  await checkSupabaseClientContract(repoRoot);
});

test('CDN dependency URLs are exact-version pinned', async () => {
  await checkCdnDependencyPins(repoRoot);
});

test('CDN script tags carry expected SRI metadata', async () => {
  await checkCdnScriptIntegrity(repoRoot);
});

test('public pages retain required form controls', async () => {
  await checkPublicPageForms(repoRoot);
});

test('migration filenames are unique and ordered sanely', async () => {
  await checkMigrationFilenameSanity(repoRoot);
});

test('Vercel security headers cover the current static app surface', async () => {
  await checkVercelSecurityHeaders(repoRoot);
});
