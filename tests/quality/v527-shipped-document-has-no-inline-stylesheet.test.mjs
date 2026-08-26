import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  buildArtifacts, stripCssComments, checkArtifacts, fingerprint
} from '../../scripts/quality/extract-app-css.mjs';

/* nestly_v527 — the shipped app document stops carrying its own stylesheet.
 *
 * Measured on the live site 26 Aug 2026: app/index.html is 512,382 bytes, 98% of it one inline
 * <style> block, served max-age=0 — so 135KB crossed the wire on EVERY visit and nothing painted
 * until it parsed. First contentful paint 3,052 ms; the server answered in 583 ms.
 *
 * app/index.html stays the SOURCE (175 test files read CSS out of it, and every visual fixture
 * embeds it — moving it would put all of that in one sweep). The generated pair beside it is what
 * customers download. These assertions run the generator; they do not grep for it.
 */

const repo = new URL('../../', import.meta.url);
const source = readFileSync(new URL('app/index.html', repo), 'utf8');
const shippedHtml = readFileSync(new URL('app/index.gen.html', repo), 'utf8');
const shippedCss = readFileSync(new URL('app/app.css', repo), 'utf8');
const vercel = JSON.parse(readFileSync(new URL('app/vercel.json', repo), 'utf8'));
const sw = readFileSync(new URL('app/sw.js', repo), 'utf8');

test('V527 the generated pair is current — a stale one would ship yesterday\'s styles', async () => {
  const { stale } = await checkArtifacts();
  assert.deepEqual(stale, [],
    'run `npm run app-css` — the shipped document and stylesheet are behind app/index.html');
});

test('V527 the shipped document carries a fingerprinted link and no inline stylesheet', () => {
  assert.equal((shippedHtml.match(/<style/g) || []).length, 0,
    'not one <style> block may survive into the document customers download');
  const link = shippedHtml.match(/<link rel="stylesheet" href="\/app\.css\?b=([a-f0-9]{12})">/);
  assert.ok(link, 'the document links the stylesheet instead');
  assert.equal(link[1], fingerprint(shippedCss),
    'and the fingerprint matches the bytes — a mismatched one is a stale CDN copy served forever');
});

test('V527 the shipped document is a fraction of the source it came from', () => {
  assert.ok(source.length > 400_000, 'the source still holds the stylesheet and its comments');
  assert.ok(shippedHtml.length < 20_000,
    `the shipped document should be small; it is ${shippedHtml.length} bytes`);
  assert.ok(shippedHtml.length * 20 < source.length,
    'the whole point is that the document no longer carries the stylesheet');
});

test('V527 stripping comments cannot change a single rule', () => {
  /* The browser-parse equivalence was proven in Chrome when this shipped (3,134 rules, identical
     serialisation both ways). What this asserts is the property that made that true: the stripper
     only ever removes comments, so brace and declaration structure is preserved exactly. */
  const withComments = source.match(/<style[^>]*>([\s\S]*?)<\/style>/)[1];
  const stripped = stripCssComments(withComments);
  const bare = (text) => text.replace(/\/\*[\s\S]*?\*\//g, '');
  const shape = (text) => ({
    open: (text.match(/\{/g) || []).length,
    close: (text.match(/\}/g) || []).length,
    at: (text.match(/@[a-z-]+/g) || []).length,
    decls: (text.match(/[a-zA-Z-]+\s*:/g) || []).length
  });
  assert.deepEqual(shape(stripped), shape(bare(withComments)),
    'the stripper removed something that was not a comment');
  assert.ok(!stripped.includes('/*'), 'and left no comment behind');
  assert.ok(stripped.length < withComments.length * 0.8,
    'comments really were a quarter of the stylesheet');
});

test('V527 the routes customers arrive on serve the generated document', () => {
  const app = vercel.rewrites.filter((r) => ['/app', '/business', '/admin'].includes(r.source));
  assert.equal(app.length, 3, 'the three app entry points are all rewritten');
  for (const rule of app) {
    assert.equal(rule.destination, '/index.gen.html', `${rule.source} must serve the generated document`);
  }
  const css = vercel.headers.find((h) => h.source === '/app.css');
  assert.ok(css, 'the stylesheet needs its own cache rule or it inherits the default');
  const value = css.headers.find((h) => h.key.toLowerCase() === 'cache-control')?.value || '';
  assert.match(value, /immutable/,
    'the whole win is that a fingerprinted stylesheet is downloaded once and never again');
  assert.match(value, /max-age=31536000/);
});

test('V527 the offline shell caches the shipped document, not the fat source', () => {
  assert.ok(sw.includes("await fetch('/app',{cache:'reload'})"),
    'the service worker must precache the SHIPPED document — caching /index.html would put the '
    + '512KB inline stylesheet straight back into the offline shell');
  assert.ok(!sw.includes("await fetch('/index.html',{cache:'reload'})"));
  assert.match(sw, /const CACHE_VERSION='v20-/,
    'the cache version must move, or existing installs keep serving the old heavy shell');
  assert.match(sw, /<link\[\^>\]\+rel="stylesheet"\[\^>\]\+href="\(\[\^"\]\+\)"/,
    'and the shell scan still picks the stylesheet up as a cached asset');
});

test('V527 the extractor refuses to run on a document with nothing to extract', () => {
  assert.throws(() => buildArtifacts('<html><body>no styles here</body></html>'),
    /no <style> block/,
    'silently producing an empty stylesheet would ship an unstyled app');
});
