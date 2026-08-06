import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { bundleFingerprint, stamp, stampedTag } from '../../scripts/quality/stamp-app-bundle.mjs';

/* Cloudflare rewrites the browser-facing max-age on /app.js no matter what the origin sends, so
   the query fingerprint is the only thing that gets a returning visitor onto new code on the very
   next load. It is worthless if it drifts, so the suite owns it. */
test('app/index.html requests the exact app.js bytes it was shipped with', async () => {
  const { current, expected } = await stamp();
  assert.equal(current, expected,
    'app/index.html is stamped for different bundle bytes. Run: node scripts/quality/stamp-app-bundle.mjs --write');
});

test('the stamp is derived from the bundle and is a stable, cache-safe token', async () => {
  const bundle = await readFile(new URL('../../app/app.js', import.meta.url));
  const fingerprint = bundleFingerprint(bundle);
  assert.match(fingerprint, /^[0-9a-f]{12}$/);
  assert.equal(fingerprint, bundleFingerprint(bundle), 'hashing must be deterministic');
  assert.notEqual(fingerprint, bundleFingerprint(Buffer.concat([bundle, Buffer.from('\n')])),
    'a one-byte change must produce a different url');
  assert.equal(stampedTag(fingerprint), `<script src="/app.js?b=${fingerprint}" defer></script>`);
});

test('the document loads the bundle deferred and exactly once', async () => {
  const document = await readFile(new URL('../../app/index.html', import.meta.url), 'utf8');
  const references = [...document.matchAll(/src="\/app\.js(\?[^"]*)?"/g)];
  assert.equal(references.length, 1, 'a second copy of the bundle would double-execute the app');
  assert.match(document, /<script src="\/app\.js\?b=[0-9a-f]{12}" defer><\/script>/);
});
