/* nestly_v889 — the Peekaa loop is back, and it still cannot ask to be pressed.
 *
 * Owner, twice: "i need to make my peekaa move", then "i still dont see the peekaa eyes move from
 * left to right". Both were right, and v888's first answer rested on a measurement error of mine:
 * I sampled /media/peekaa-loading.mp4 by SEEKING frame to frame, Chrome returned the same decoded
 * picture every time, and I reported the file as a still. Sampled during real playback through
 * requestVideoFrameCallback it is 118 presented frames, 118 DISTINCT pictures, and the left pupil
 * sweeps 64px across its eye. v666 removed a working animation.
 *
 * v666's reason was real too — in Low Power Mode iOS refuses muted inline autoplay and Safari
 * draws its own tap-to-play overlay. So the loop exists under four rules, in both places that
 * build it, and this file pins all four in both. The behaviour itself is executed in a real
 * browser by tests/browser/verify-v889-boot-loop.mjs (npm run test:browser).
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const indexHtml = readFileSync(new URL('../../app/index.html', import.meta.url), 'utf8');
const cui = readFileSync(new URL('../../app/customer-ui.js', import.meta.url), 'utf8');

/* Two copies exist for a structural reason: the boot screen runs before customer-ui.js loads and
   must be static HTML. They are not shared code, so they are kept honest here. */
const bootCopy = indexHtml.slice(indexHtml.indexOf('nestly_v889 — THE LOOP IS BACK'),
  indexHtml.indexOf('<div id="toast"'));
const cuiCopy = cui.slice(cui.indexOf('function upgradePeekaaLoopV889('),
  cui.indexOf('function upgradePeekaaLoopsV889('));

const COPIES = [['boot (app/index.html)', bootCopy], ['CUI (app/customer-ui.js)', cuiCopy]];

test('both copies exist and neither is empty', () => {
  for (const [name, copy] of COPIES) assert.ok(copy.length > 400, `${name} copy not found`);
});

test('rule 1 — the loop is created from script, never left in markup', () => {
  for (const [name, copy] of COPIES) {
    assert.match(copy, /createElement\('video'\)/, `${name} must build the element itself`);
  }
  /* Markup with a <video> in it can paint the browser's overlay while it loads; that is v666. */
  const markup = indexHtml.slice(indexHtml.lastIndexOf('data-boot-skeleton'),
    indexHtml.indexOf('<script>', indexHtml.lastIndexOf('data-boot-skeleton')));
  assert.doesNotMatch(markup, /<video/);
});

test('rule 2 — revealed only when the browser says it is PLAYING', () => {
  for (const [name, copy] of COPIES) {
    assert.match(copy, /addEventListener\('playing'/, `${name} must wait for the playing event`);
    assert.match(copy, /data-playing/, `${name} reveals via the attribute the stylesheet keys off`);
  }
  /* Hidden until then, so a refusal has nothing visible to draw a control on. */
  assert.match(indexHtml, /\.peekaa-loop-v889\{[^}]*opacity:0/);
  assert.match(indexHtml, /\.peekaa-loop-v889\[data-playing="1"\]\{opacity:1\}/);
});

test('rule 3 — a refusal or a decode error REMOVES it', () => {
  for (const [name, copy] of COPIES) {
    assert.match(copy, /addEventListener\('error',\s*drop\)/, `${name} must drop on decode error`);
    assert.match(copy, /started\s*&&\s*typeof started\.catch==='function'\s*\)\s*started\.catch\(drop\)/,
      `${name} must drop when play() rejects — that rejection IS the Low Power Mode refusal`);
  }
});

test('rule 4 — reduced motion and a missing codec are refused before anything is built', () => {
  for (const [name, copy] of COPIES) {
    assert.match(copy, /prefers-reduced-motion: reduce/, `${name} must honour reduced motion`);
    assert.match(copy, /canPlayType\('video\/mp4'\)/, `${name} must check the codec first`);
    assert.match(copy, /loop\.controls=false/, `${name} must never enable controls`);
  }
});

test('the still poster stays underneath, so the first frame needs no JavaScript', () => {
  assert.match(indexHtml, /<img class="boot-mark-v577" src="\/media\/peekaa-loading-poster\.png"/);
  assert.match(cui, /<img class="cui-loading-mark-v888" src="\/media\/peekaa-loading-poster\.png"/);
});

test('the loop is wired into every shared loading state, not just the boot screen', () => {
  assert.match(cui, /function enhance\(root\)\{associateLabels\(root\);enhanceTables\(root\);upgradePeekaaLoopsV889\(root\)\}/,
    'enhance() runs on every render, which is what makes this "everywhere when loading"');
  assert.match(cui, /querySelectorAll\('\.peekaa-mark-wrap-v889'\)/);
});

test('the seeking trap that caused the wrong call is recorded where the next person will look', () => {
  assert.match(indexHtml, /SEEKING frame to frame/);
  assert.match(indexHtml, /118 presented frames, 118 DISTINCT pictures/);
});
