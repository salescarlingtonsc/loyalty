/* nestly_v748 — closing the redemption QR leaves the customer where they were.
 *
 * OWNER (2026-09-03, photo 4, then in their own words): "before clicking i am looking at the
 * rewards list, then i click the qrcode, if i close the qrcode i should still be looking at the
 * 'reward list' like nothing happened."
 *
 * Nothing NAVIGATES — v524 closed that door and its route guard still holds. What moved was the
 * SCROLL. Closing fires two repaints: loadRewards() replaces #walletRewards wholesale, then the
 * counter moment repaints the body. The body repaint holds scrollTop itself
 * (customerWalletSilentPaintV333); the section repaint does not, and it is the one whose height
 * changes, so the page slid out from under the reader.
 *
 * These EXECUTE the shipped helper rather than grepping for it — the block is lifted verbatim
 * out of app/app.js and driven against a fake scroller and a hand-cranked rAF clock.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const app = await readFile(new URL('../../app/app.js', import.meta.url), 'utf8');

const start = app.indexOf('function customerHoldWalletScrollV748(');
assert.ok(start > 0, 'the shipped helper must still be there');
const end = app.indexOf('\n}\n', start);
assert.ok(end > start, 'and must still be one top-level function');
const src = app.slice(start, end + 2);

/* A scroller a repaint can shove, a window whose listeners we can fire, and a rAF we step by
   hand so the ~700ms window is deterministic instead of wall-clock flaky. */
const rig = ({ startAt = 900 } = {}) => {
  const scroller = { scrollTop: startAt };
  const listeners = new Map();
  const frames = [];
  let now = 0;
  const scope = {
    document: { scrollingElement: scroller, documentElement: scroller },
    window: {
      addEventListener: (name, fn) => {
        if (!listeners.has(name)) listeners.set(name, new Set());
        listeners.get(name).add(fn);
      },
      removeEventListener: (name, fn) => listeners.get(name)?.delete(fn)
    },
    requestAnimationFrame: fn => frames.push(fn),
    Date: { now: () => now }
  };
  const names = Object.keys(scope);
  const hold = new Function(...names, `${src}\nreturn customerHoldWalletScrollV748;`)(
    ...names.map(n => scope[n])
  );
  const step = (advanceMs = 16) => {
    now += advanceMs;
    const due = frames.splice(0, frames.length);
    due.forEach(fn => fn());
  };
  const fire = name => [...(listeners.get(name) || [])].forEach(fn => fn());
  return { scroller, hold, step, fire, listeners, framesPending: () => frames.length };
};

test('a repaint that shoves the page is undone on the next frame', () => {
  const { scroller, hold, step } = rig({ startAt: 900 });
  hold();
  // loadRewards() replaces the section; it is shorter, so the browser clamps the scroll.
  scroller.scrollTop = 0;
  step();
  assert.equal(scroller.scrollTop, 900, 'the customer is put back where they were reading');
});

test('it keeps holding across several repaints, not just the first', () => {
  const { scroller, hold, step } = rig({ startAt: 640 });
  hold();
  for (const shove of [0, 120, 0]) {
    scroller.scrollTop = shove;
    step();
    assert.equal(scroller.scrollTop, 640);
  }
});

test('the customer scrolling for themselves ends the hold at once', () => {
  const { scroller, hold, step, fire, listeners } = rig({ startAt: 500 });
  hold();
  fire('wheel');
  scroller.scrollTop = 120;
  step();
  assert.equal(scroller.scrollTop, 120, 'a deliberate gesture is never fought');
  for (const name of ['wheel', 'touchstart', 'keydown', 'pointerdown']) {
    assert.equal(listeners.get(name)?.size ?? 0, 0, `${name} listener was released`);
  }
});

test('a touch, a key and a pointer end it too — not only the wheel', () => {
  for (const gesture of ['touchstart', 'keydown', 'pointerdown']) {
    const { scroller, hold, step, fire } = rig({ startAt: 300 });
    hold();
    fire(gesture);
    scroller.scrollTop = 40;
    step();
    assert.equal(scroller.scrollTop, 40, `${gesture} must stand the hold down`);
  }
});

test('a plain scroll event does NOT stand it down', () => {
  /* The trap this test exists to keep shut: a section repainting shorter fires a scroll event
     too, so standing down on `scroll` would disable the hold in the exact case it is for. */
  const { scroller, hold, step, fire } = rig({ startAt: 700 });
  hold();
  fire('scroll');
  scroller.scrollTop = 0;
  step();
  assert.equal(scroller.scrollTop, 700);
});

test('it releases itself once the settling window is over', () => {
  const { scroller, hold, step, framesPending, listeners } = rig({ startAt: 800 });
  hold();
  step(1000); // past the ~700ms window
  assert.equal(framesPending(), 0, 'it stops asking for frames');
  assert.equal(listeners.get('wheel')?.size ?? 0, 0, 'and lets its listeners go');
  scroller.scrollTop = 10;
  step();
  assert.equal(scroller.scrollTop, 10, 'a later scroll is the customer\'s own business');
});

test('the returned release is callable and idempotent', () => {
  const { scroller, hold, step } = rig({ startAt: 250 });
  const release = hold();
  release();
  release();
  scroller.scrollTop = 0;
  step();
  assert.equal(scroller.scrollTop, 0);
});

test('both QR close paths hold the scroll', () => {
  const calls = app.match(/onClose:\(\)=>\{customerHoldWalletScrollV748\(\);loadRewards\(\);/g) || [];
  assert.equal(calls.length, 2,
    'the gift QR and the points-reward QR both close through the hold');
});
