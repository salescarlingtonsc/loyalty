/* nestly_v888 — owner 2026-09-13: "i need to make my peekaa move — it should auto play and does
   not require anyone to press play."

   The request was to restore the v462 loop that v666 removed. Measuring the asset first changed
   the answer: /media/peekaa-loading.mp4 is a still image encoded as a five-second video — nine
   timestamps across its 5.04s decoded to canvas at 540x540 differ by zero pixels. Restoring it
   could not have produced motion, only a 67KB download of the picture the poster already shows,
   plus v666's tap-to-play overlay again.

   So the boot mark moves by CSS. What this file protects is the pair of properties the owner
   actually asked for — it moves, and nothing can ask the customer to start it. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const shipped = readFileSync(new URL('../../app/index.html', import.meta.url), 'utf8');
const generated = readFileSync(new URL('../../app/index.gen.html', import.meta.url), 'utf8');
const css = readFileSync(new URL('../../app/app.css', import.meta.url), 'utf8');

test('the boot mark carries a looping animation', () => {
  assert.match(css, /@keyframes bootPeek-v888/);
  assert.match(css, /\.boot-mark-wrap-v888 \.boot-mark-v577\{[^}]*animation:bootPeek-v888 [^}]*infinite/);
});

test('the animation is real movement, not a no-op keyframe set', () => {
  /* Brace-balanced, so a reformat of the emitted stylesheet cannot quietly shrink what is read. */
  const at = css.indexOf('@keyframes bootPeek-v888');
  assert.ok(at > -1, 'the keyframes exist');
  let depth = 0, end = at;
  for (let i = css.indexOf('{', at); i < css.length; i++) {
    if (css[i] === '{') depth++;
    else if (css[i] === '}' && --depth === 0) { end = i; break; }
  }
  const block = css.slice(at, end);
  const transforms = [...block.matchAll(/transform:([^;}]+)/g)].map(m => m[1].trim());
  assert.ok(transforms.length >= 3, `the keyframes must define several positions, got ${transforms.length}`);
  assert.ok(new Set(transforms).size >= 3, 'and those positions must actually differ');
});

test('a customer who asked for less motion gets none', () => {
  assert.match(css, /@media \(prefers-reduced-motion:reduce\)\{[^}]*\.boot-mark-wrap-v888 \.boot-mark-v577\{animation:none\}/);
});

test('nothing on the boot screen can ask to be pressed', () => {
  /* v666's defect: a <video> that will not autoplay makes the BROWSER draw a tap-to-play overlay,
     which no attribute suppresses. The guarantee is structural — there is no media element on the
     boot screen at all, in either the authored or the shipped document. */
  for (const [name, doc] of [['index.html', shipped], ['index.gen.html', generated]]) {
    /* The LAST occurrence: the first ones are the stylesheet's own [data-boot-skeleton] rules,
       and slicing from there swallows most of the document — which is how this assertion first
       "failed" against markup that was already correct. */
    const boot = doc.slice(doc.lastIndexOf('data-boot-skeleton'), doc.indexOf('id="toast"'));
    assert.doesNotMatch(boot, /<video|<audio/, `${name} put a media element back on the boot screen`);
    assert.doesNotMatch(boot, /controls/, `${name} boot screen gained a control`);
  }
});

test('the still mark is still what paints, so the first frame needs no JavaScript', () => {
  const boot = shipped.slice(shipped.lastIndexOf('data-boot-skeleton'), shipped.indexOf('id="toast"'));
  assert.match(boot, /<img class="boot-mark-v577" src="\/media\/peekaa-loading-poster\.png"/);
  assert.match(boot, /<span class="boot-mark-wrap-v888">/);
});

test('the measurement that produced this decision is recorded next to it', () => {
  /* The next person will be asked for the video back too. The finding has to be where they look. */
  /* app.css is emitted without comments, so the record lives in the authored document. */
  assert.match(shipped, /still image encoded as a\s+five-second video/);
  assert.match(shipped, /ZERO pixels differ/);
});
