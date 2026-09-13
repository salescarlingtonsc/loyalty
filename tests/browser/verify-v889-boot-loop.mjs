/* nestly_v889 — EXECUTED proof that the Peekaa loop plays at boot and can never draw a play button.
 *
 * The structural rules are pinned by tests/quality/v889-peekaa-loop.test.mjs. This file proves the
 * behaviour those rules exist to produce, in a real browser, because the defect v666 removed the
 * loop for was a browser behaviour and nothing about the source could have shown it.
 *
 * Three conditions:
 *   1. normal            — the loop plays, is revealed, and its currentTime advances
 *   2. autoplay refused  — the element is REMOVED, so Safari's tap-to-play overlay has no host
 *   3. reduced motion    — no loop is built at all
 * In every case the still mark must survive, because it is what the customer actually looks at.
 *
 * The refusal is produced by making play() reject with NotAllowedError, which is exactly what iOS
 * Low Power Mode does. Chrome's --autoplay-policy flag does NOT block muted autoplay and proves
 * nothing here; that was checked.
 *
 * Run by `npm run test:browser`. BOOT_URL comes from the runner, whose server resolves /media/…
 * through the app/ docroot the deployed site uses.
 */
import assert from 'node:assert/strict';

const base = process.env.V889_BOOT_URL || 'http://127.0.0.1:4173/index.html';
const playwright = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const chromium = playwright.chromium || playwright.default?.chromium;

const browser = await chromium.launch({
  ...(process.env.PLAYWRIGHT_EXECUTABLE_PATH ? { executablePath: process.env.PLAYWRIGHT_EXECUTABLE_PATH } : {}),
});

async function boot({ refuse = false, reducedMotion } = {}) {
  const context = await browser.newContext(reducedMotion ? { reducedMotion } : {});
  const page = await context.newPage();
  /* Keep the boot screen on screen: the router replaces it as soon as the bundle runs. */
  await page.route(/app-(core|customer|business|auth|i18n)\.js/, route => route.abort());
  if (refuse) {
    await page.addInitScript(() => {
      HTMLMediaElement.prototype.play = () =>
        Promise.reject(Object.assign(new Error('blocked'), { name: 'NotAllowedError' }));
    });
  }
  await page.goto(base, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('.boot-mark-v577');
  await page.waitForTimeout(2500);
  const state = await page.evaluate(() => {
    const loop = document.querySelector('.peekaa-loop-v889');
    return {
      loopPresent: Boolean(loop),
      videosInDocument: document.getElementsByTagName('video').length,
      revealed: loop ? loop.getAttribute('data-playing') === '1' : false,
      paused: loop ? loop.paused : null,
      opacity: loop ? getComputedStyle(loop).opacity : null,
      controls: loop ? loop.controls : null,
      time: loop ? loop.currentTime : null,
      stillVisible: Boolean(document.querySelector('.boot-mark-v577')?.clientWidth),
    };
  });
  const later = await page.evaluate(async () => {
    await new Promise(resolve => setTimeout(resolve, 700));
    const loop = document.querySelector('.peekaa-loop-v889');
    return loop ? loop.currentTime : null;
  });
  await context.close();
  return { ...state, timeLater: later };
}

try {
  const normal = await boot();
  assert.ok(normal.loopPresent, 'the loop must be built when the browser allows it');
  assert.ok(normal.revealed, 'the loop is revealed only on its own playing event — it never fired');
  assert.equal(normal.paused, false, 'the loop must actually be playing');
  assert.equal(normal.controls, false, 'controls must never be enabled');
  assert.equal(normal.opacity, '1', 'a playing loop must be visible');
  assert.ok(normal.timeLater > normal.time, 'currentTime must advance — a frozen loop is not motion');
  assert.ok(normal.stillVisible, 'the still mark stays underneath');

  const refused = await boot({ refuse: true });
  assert.equal(refused.loopPresent, false, 'a refused loop must be REMOVED, not left hidden');
  assert.equal(refused.videosInDocument, 0,
    'no media element may survive a refusal — that element is what draws the tap-to-play overlay');
  assert.ok(refused.stillVisible, 'the customer still gets the mark');

  const reduced = await boot({ reducedMotion: 'reduce' });
  assert.equal(reduced.loopPresent, false, 'reduced motion must build no loop at all');
  assert.equal(reduced.videosInDocument, 0);
  assert.ok(reduced.stillVisible);

  process.stdout.write(`${JSON.stringify({ status: 'PASS', normal, refused, reduced }, null, 1)}\n`);
} finally {
  await browser.close();
}
