/**
 * Builds an isolated, disposable copy of the parts of this repo that
 * scripts/quality/regen-visual-fixtures.mjs and tests/browser/generate-*.mjs need to run for
 * real — app/, supabase/ (two edge functions v142's generator reads), scripts/quality/, and
 * either specific tests/browser/ files or the whole directory.
 *
 * WHY THIS EXISTS (nestly_v459). tests/browser/v448-regen-fixtures-port-safety.test.mjs used to
 * spawn the REAL regen-visual-fixtures.mjs against the REAL repo root — so every `npm test` run
 * actually regenerated every checked-in fixture HTML as a side effect of testing the script's
 * port-binding behaviour. That is precisely the kind of mutation the coordinator's "the gate is
 * nondeterministic" report was about: `npm test` is supposed to be read-only, and a "does the
 * port logic work" test silently rewriting tracked evidence files (racing whatever OTHER test
 * happens to read them concurrently) is a real instance of that, independent of and in addition
 * to node's own test-file discovery behaviour (see is-direct-cli-invocation.mjs). Every test that
 * needs to run the real regen script or a real generator now does so against a sandbox built by
 * this module, never against the working tree.
 *
 * realpath() matters: os.tmpdir() on macOS returns a path through the /var -> /private/var
 * symlink, but Node's ESM loader resolves import.meta.url through the REAL path. Without
 * canonicalizing the sandbox root once here, process.argv[1] (as spawned) and import.meta.url
 * (as resolved by the loader) would disagree inside the sandbox for reasons that have nothing to
 * do with what is actually under test.
 */
import { cp, mkdtemp, mkdir, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = fileURLToPath(new URL('../../', import.meta.url));

/**
 * @param {string[]} [only] - specific filenames under tests/browser/ to copy (keeps callers that
 *   only need one generator+fixture pair fast and free of unrelated sibling files). Omit to copy
 *   the whole tests/browser/ directory.
 */
export async function buildRepoTestSandbox(only) {
  const dir = await realpath(await mkdtemp(join(tmpdir(), 'peekaa-repo-sandbox-')));
  await cp(join(repoRoot, 'app'), join(dir, 'app'), { recursive: true });
  await cp(join(repoRoot, 'supabase'), join(dir, 'supabase'), { recursive: true });
  await cp(join(repoRoot, 'scripts', 'quality'), join(dir, 'scripts', 'quality'), { recursive: true });
  if (only) {
    await mkdir(join(dir, 'tests', 'browser'), { recursive: true });
    for (const name of only) {
      await cp(join(repoRoot, 'tests', 'browser', name), join(dir, 'tests', 'browser', name));
    }
  } else {
    await cp(join(repoRoot, 'tests', 'browser'), join(dir, 'tests', 'browser'), { recursive: true });
  }
  return dir;
}

export { repoRoot };
