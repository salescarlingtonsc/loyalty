import { pathToFileURL } from 'node:url';

/**
 * NESTLY_V459 — the gate was nondeterministic (P1). `node --test` (no path argument) recursively
 * collects EVERY .mjs file under any directory literally named `test` or `tests` — no filename
 * pattern required. That means every tests/browser/generate-*.mjs fixture generator WAS a "test
 * file" as far as the runner was concerned: node ran each one in its own child process with
 * `process.argv[1]` set to that very file, which is exactly the condition every one of them used
 * to decide "I was invoked directly as a script, so write the fixture to disk." So `npm test`
 * silently rewrote the checked-in fixture HTMLs it was ALSO, in the same run, comparing against
 * for byte-equality — a race between the generator and its own parity test decided by scheduling,
 * not by whether the fixture was actually stale. Reproduced on this Node version (24.16.0):
 * `node --test` sets `NODE_TEST_CONTEXT` (observed value "child-v8") in every child it spawns;
 * a plain `node <file>` invocation — by hand, or via scripts/quality/regen-visual-fixtures.mjs,
 * which spawns each generator as ITS OWN child_process — never sets it.
 *
 * isDirectCliInvocation() is the corrected guard: true only when this process was launched to
 * run `moduleUrl` AS A SCRIPT and is not one of node's own test-runner children. Import it in
 * place of the old inline `process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url`
 * check in every tests/browser/generate-*.mjs.
 */
export function isDirectCliInvocation(moduleUrl) {
  if (process.env.NODE_TEST_CONTEXT) return false;
  return Boolean(process.argv[1]) && pathToFileURL(process.argv[1]).href === moduleUrl;
}
