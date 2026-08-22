/**
 * CROSS-TREE CAPTURE GUARD (nestly_v448, closes part of REG-009).
 *
 * tests/browser/verify-v104-promotions-visual.mjs and verify-v142-connect-paynow.mjs fetch a
 * fixture served over HTTP, defaulting to port 4173 — a port shared by sibling worktrees and by
 * other sessions' own regen servers (scripts/quality/regen-visual-fixtures.mjs binds it too).
 * When some OTHER session's server happens to be listening on that port while a capture runs,
 * the capture does not fail: it fetches THEIR fixture, screenshots THEIR render, and reports
 * PASS with a sourceHash that belongs to a tree nobody asked it to look at. This happened for
 * real (see AUDIT-MAP §4 REG-009) and is the exact failure mode this guard closes.
 *
 * assertFixtureMatchesTree() proves, before any browser is launched, that the fixture the
 * capture is about to load over HTTP is byte-identical to the fixture committed on disk IN THIS
 * WORKTREE. A mismatch throws with a message that names both hashes and both locations, so the
 * failure reads as "wrong tree" rather than as a flaky screenshot diff.
 */
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

/**
 * @param {object} options
 * @param {string} options.servedUrl - the HTTP URL the capture is about to fetch the fixture from
 * @param {string|URL} options.localFixtureUrl - file:// URL (or path) of the fixture on disk in this tree
 * @param {string} options.label - short id for the fixture, used only in the error message (e.g. 'v104')
 */
export async function assertFixtureMatchesTree({ servedUrl, localFixtureUrl, label }) {
  const localPath = localFixtureUrl instanceof URL ? fileURLToPath(localFixtureUrl) : localFixtureUrl;
  const localBytes = await readFile(localFixtureUrl);
  let servedBytes;
  try {
    const response = await fetch(servedUrl);
    if (!response.ok) throw new Error(`HTTP ${response.status} ${response.statusText}`);
    servedBytes = Buffer.from(await response.arrayBuffer());
  } catch (error) {
    throw new Error(
      `CROSS-TREE CAPTURE GUARD (${label}): could not fetch the fixture at ${servedUrl} to verify it `
      + `matches ${localPath} in this tree (${error.message}). Point the fixture URL env var at a `
      + `server that serves THIS worktree — do not rely on whatever answers the default port.`
    );
  }
  const localHash = sha256(localBytes);
  const servedHash = sha256(servedBytes);
  if (localHash !== servedHash) {
    throw new Error(
      `CROSS-TREE CAPTURE GUARD (${label}): the fixture served at ${servedUrl} (sha256 ${servedHash}) `
      + `does NOT match ${localPath} in this tree (sha256 ${localHash}). This is the failure where a `
      + `shared default port (e.g. 4173) answers from ANOTHER SESSION'S server and the capture would `
      + `otherwise silently record the wrong build as a PASS. Point the fixture URL env var at a server `
      + `rooted at THIS worktree (see scripts/quality/regen-visual-fixtures.mjs), or stop whatever else `
      + `is bound to that port.`
    );
  }
}
