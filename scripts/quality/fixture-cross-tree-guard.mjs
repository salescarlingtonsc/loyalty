/**
 * CROSS-TREE CAPTURE GUARD (nestly_v448/v459, closes REG-009).
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
 *
 * NESTLY_V459 — TWO-MARKER POLL, mirroring the failure mode Agent B hit and this original v448
 * guard did not cover: `python3 -m http.server` resolves the file it serves by OPEN FILE
 * DESCRIPTOR / inode at request time, not by re-reading the path. If a docroot is `rm -rf`'d and
 * rebuilt (a fresh worktree checkout, a `git worktree remove` + re-add on the same path) while an
 * OLD server from before that is still bound to the same port, that server keeps answering 200
 * with the DELETED copy's bytes forever — no error, no hint, just permanently stale content. A
 * single fetch-and-hash (the original v448 behaviour) DOES still catch this correctly whenever
 * the stale bytes differ from the current tree's, exactly like the cross-tree case — but it does
 * so with only ONE data point and no retry, so a server that is merely mid-restart (a real,
 * transient, both-fixed state) fails exactly the same way as a permanently wrong one. This
 * version POLLS: it fetches repeatedly (bounded attempts, short delay) until the served bytes'
 * hash matches AND — when markers are supplied — until the CSS half and the JS half of the build
 * both carry their own named marker, or gives up and fails loudly with a diagnostic that names
 * which half (hash / CSS marker / JS marker) never matched. The two-marker split matters
 * separately from the hash for one specific real class of drift the CI/production app has and
 * this fixture format does not: app/app.js and app/customer-ui.js are compiled into separate
 * chunks by scripts/quality/stamp-app-bundle.mjs, so a tree whose stylesheet is current but whose
 * bundle is stale can serve a fresh-looking index.html and then run last week's JavaScript — the
 * hash alone would catch that too (the bytes differ), but the CSS/JS marker split gives a human a
 * one-line answer to "which half is stale" instead of a raw hash diff. v104/v142's fixtures are
 * single self-contained files (CSS and JS both inlined by their generator — verified: neither
 * embeds a `<script src=` pointing at an external chunk), so "two files" collapses to "two
 * markers within the one file" for these; verify-v441-preview-dock-scope.mjs is the sibling that
 * genuinely serves index.html and an external chunk as two files and already has its own
 * same-shaped probe.
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
 * @param {{css: string, js: string}} [options.markers] - literal substrings expected to appear in
 *   the served body: one from the CSS half of the build, one from the JS half. Optional — omit to
 *   fall back to a hash-only check. Callers expose these as env-overridable constants so the same
 *   script can be pointed at a deliberately unfixed/different tree for a negative control.
 * @param {number} [options.attempts] - how many times to poll before giving up (default 8)
 * @param {number} [options.delayMs] - delay between polls in ms (default 250)
 */
export async function assertFixtureMatchesTree({
  servedUrl, localFixtureUrl, label, markers, attempts = 8, delayMs = 250,
}) {
  const localPath = localFixtureUrl instanceof URL ? fileURLToPath(localFixtureUrl) : localFixtureUrl;
  const localBytes = await readFile(localFixtureUrl);
  const localHash = sha256(localBytes);

  if (markers) {
    // Sanity: if the marker itself is wrong (a typo, a renamed function), every poll below would
    // fail even against a perfectly fresh server, and that failure would misleadingly read as
    // "wrong tree" instead of "wrong marker". Catch that here, against the file this process
    // trusts unconditionally (its own disk), before ever touching the network.
    const localText = localBytes.toString('utf8');
    if (!localText.includes(markers.css)) {
      throw new Error(
        `CROSS-TREE CAPTURE GUARD (${label}): the CSS marker itself does not appear in ${localPath} `
        + `— the marker is wrong (or the fixture genuinely dropped that rule), not the server. Fix the `
        + `marker, or regenerate the fixture, before re-running.`
      );
    }
    if (!localText.includes(markers.js)) {
      throw new Error(
        `CROSS-TREE CAPTURE GUARD (${label}): the JS marker itself does not appear in ${localPath} `
        + `— the marker is wrong (or that function was renamed/removed), not the server. Fix the `
        + `marker, or regenerate the fixture, before re-running.`
      );
    }
  }

  let lastFailure = null;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      const response = await fetch(servedUrl);
      if (!response.ok) throw new Error(`HTTP ${response.status} ${response.statusText}`);
      const servedBytes = Buffer.from(await response.arrayBuffer());
      const servedHash = sha256(servedBytes);
      const hashOk = servedHash === localHash;
      let cssOk = true, jsOk = true;
      if (markers) {
        const servedText = servedBytes.toString('utf8');
        cssOk = servedText.includes(markers.css);
        jsOk = servedText.includes(markers.js);
      }
      if (hashOk && cssOk && jsOk) return; // fresh and matching — safe to reuse this server as-is
      lastFailure = { kind: 'mismatch', servedHash, hashOk, cssOk, jsOk };
    } catch (error) {
      lastFailure = { kind: 'fetch-error', error };
    }
    if (attempt < attempts) await new Promise(resolve => setTimeout(resolve, delayMs));
  }

  if (lastFailure.kind === 'fetch-error') {
    throw new Error(
      `CROSS-TREE CAPTURE GUARD (${label}): could not fetch the fixture at ${servedUrl} to verify it `
      + `matches ${localPath} in this tree after ${attempts} attempts (${lastFailure.error.message}). `
      + `Point the fixture URL env var at a server that serves THIS worktree — do not rely on `
      + `whatever answers the default port.`
    );
  }
  const { servedHash, hashOk, cssOk, jsOk } = lastFailure;
  const halves = markers
    ? ` (CSS marker ${cssOk ? 'OK' : 'MISSING'}, JS marker ${jsOk ? 'OK' : 'MISSING'})`
    : '';
  throw new Error(
    `CROSS-TREE CAPTURE GUARD (${label}): the fixture served at ${servedUrl} never matched `
    + `${localPath} in this tree after ${attempts} polls (served sha256 ${servedHash} vs local `
    + `sha256 ${localHash}${hashOk ? ', bytes equal but a marker check failed' : ''})${halves}. This `
    + `covers two known real failures: (1) a shared default port (e.g. 4173) answering from `
    + `ANOTHER SESSION'S server, and (2) a static file server (e.g. \`python3 -m http.server\`) `
    + `that resolved its docroot's files by inode at request time and kept serving a DELETED copy `
    + `after that docroot was rm -rf'd and rebuilt — in both cases the capture would otherwise `
    + `silently record the wrong build as a PASS. Point the fixture URL env var at a server rooted `
    + `at THIS worktree (see scripts/quality/regen-visual-fixtures.mjs), or restart whatever else `
    + `is bound to that port.`
  );
}
