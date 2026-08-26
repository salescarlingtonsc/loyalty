import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  criticalCssFor, selectorCanMatchSkeleton, compoundKey, buildArtifacts, checkArtifacts
} from '../../scripts/quality/extract-app-css.mjs';

/* nestly_v530 — the boot skeleton stops waiting for the whole stylesheet.
 *
 * After v527 the document was 8 KB but first paint still landed at ~556 ms, because a
 * <link rel="stylesheet"> in the HEAD is render-blocking: nothing is drawn until all 62 KB
 * arrives. Four variants were raced in Chrome at 900 kbps:
 *
 *   link in head (control)                    never painted before the sheet landed
 *   inline critical CSS, link still in head   never painted before the sheet landed
 *   inline critical CSS, link at end of body  first paint 532 ms
 *   inline critical CSS, media=print swap     first paint 356 ms
 *
 * Inlining critical CSS ALONE changes nothing. That measurement is why the link moved too, and
 * end-of-body was chosen over the faster media swap: a stylesheet still blocks everything AFTER
 * it, so the real app UI cannot paint unstyled — the browser guarantees it rather than a race
 * between a 62 KB sheet and 1.5 MB of JavaScript.
 */

const repo = new URL('../../', import.meta.url);
const shipped = readFileSync(new URL('app/index.gen.html', repo), 'utf8');
const source = readFileSync(new URL('app/index.html', repo), 'utf8');
const fullCss = readFileSync(new URL('app/app.css', repo), 'utf8');
const head = shipped.slice(0, shipped.indexOf('<body'));
const critical = shipped.match(/<style id="criticalCssV530">([\s\S]*?)<\/style>/)?.[1] ?? '';

test('V530 the generated pair is current', async () => {
  const { stale } = await checkArtifacts();
  assert.deepEqual(stale, [], 'run `npm run app-css`');
});

test('V530 the head can paint the skeleton on its own', () => {
  assert.ok(critical.length > 0, 'the head carries an inline critical block');
  assert.ok(critical.includes('.pf-skeleton'), 'which styles the skeleton bars');
  assert.ok(critical.includes('@keyframes wallet-loading'),
    'and their shimmer — dropping the keyframes would leave a visibly static skeleton');
  assert.ok(critical.includes('animation:wallet-loading'), 'with the animation actually applied');
  assert.ok(critical.includes(':root'), 'and the design tokens the rest of it reads');
  assert.ok(critical.length < 20_000,
    `critical CSS must stay small or it defeats itself; it is ${critical.length} bytes`);
});

test('V530 no render-blocking stylesheet stands between the head and the skeleton', () => {
  /* THE FINDING THAT DECIDED THE DESIGN: with the link still in the head, inlining critical CSS
     bought nothing at all. If a future edit moves it back, this test is what says so. */
  assert.ok(!/<link rel="stylesheet" href="\/app\.css/.test(head),
    'app.css must NOT be a blocking stylesheet in the head — that is what delayed first paint');
  assert.match(head, /<link rel="preload" as="style" href="\/app\.css\?b=[0-9a-f]{12}">/,
    'it is preloaded from the head instead, so the download still starts immediately');
});

test('V530 the full stylesheet still blocks the real UI, so nothing paints unstyled', () => {
  const sheet = shipped.match(/<link rel="stylesheet" href="(\/app\.css\?b=[0-9a-f]{12})">/);
  assert.ok(sheet, 'the real stylesheet link still exists');
  assert.ok(shipped.lastIndexOf(sheet[0]) < shipped.lastIndexOf('</body>'),
    'and sits at the end of the body');
  assert.ok(shipped.indexOf('data-boot-skeleton') < shipped.lastIndexOf(sheet[0]),
    'AFTER the skeleton, which is why the skeleton may paint first');
  assert.ok(shipped.indexOf('id="root"') < shipped.lastIndexOf(sheet[0]),
    'and before nothing that matters — #root is above it, so the router\'s output is covered');
  const preload = head.match(/<link rel="preload" as="style" href="(\/app\.css\?b=[0-9a-f]{12})">/);
  assert.equal(preload[1], sheet[1],
    'the preload and the stylesheet must name the same build, or the file is fetched twice');
  assert.ok(!/media="print"/.test(shipped),
    'the media swap was rejected: it makes the sheet non-blocking and risks unstyled real content');
});

test('V530 the inline rules are a byte-identical subset, so they cannot conflict', () => {
  /* The kept rules exist twice — inline and in app.css. They can only be harmless if they are
     identical AND app.css comes later, which the document order above already proves. */
  const rules = critical.split('\n').filter((line) => line.includes('{') && !line.startsWith('@'));
  assert.ok(rules.length > 20, 'there are real rules to check');
  for (const rule of rules.slice(0, 200)) {
    assert.ok(fullCss.includes(rule),
      `inline rule is not present verbatim in app.css, so the two could disagree: ${rule.slice(0, 80)}`);
  }
});

test('V530 selector matching is per-token, not a substring search', () => {
  assert.equal(selectorCanMatchSkeleton('a'), true, 'the skip link is an anchor');
  assert.equal(selectorCanMatchSkeleton('.card'), true);
  assert.equal(selectorCanMatchSkeleton('.wallet-inner .card'), true);
  assert.equal(selectorCanMatchSkeleton('.customer-expiring-list a'), false,
    'a bare-substring matcher wrongly kept this one — the class is not in the skeleton');
  assert.equal(selectorCanMatchSkeleton('.grow-points-gift-card-v343'), false);
  assert.equal(selectorCanMatchSkeleton('body.dark .card'), true);
  assert.equal(compoundKey('.card[aria-busy]:hover'), '.card');
  assert.equal(compoundKey('div.wallet-inner'), 'div');
  assert.equal(compoundKey(':root'), ':root');
});

test('V530 the extractor refuses to emit a set that cannot style the skeleton', () => {
  assert.throws(() => buildArtifacts(source.replace(/\.pf-skeleton/g, '.renamed-skeleton')),
    /does not style the boot skeleton/,
    'silently shipping a critical set that misses the skeleton would undo this change');
});

test('V530 the critical set is a small fraction of the stylesheet', () => {
  const derived = criticalCssFor(fullCss);
  assert.ok(derived.length < fullCss.length / 10,
    `critical must stay a small subset: ${derived.length} of ${fullCss.length}`);
  assert.equal(derived, critical, 'and the document carries exactly what the extractor derives');
});
