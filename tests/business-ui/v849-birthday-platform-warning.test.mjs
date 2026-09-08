/* nestly_v849 — the birthday save toast stops lying, and the lie stops being the only surface.
 *
 * THE DEFECT. The platform switch `customer_birthday_benefits` has been OFF since 2026-07-22, so
 * no birthday gift is actually delivered to any customer, anywhere. Four businesses have an
 * active, published birthday programme and the owner-side save handler nevertheless told them
 * "Birthday gift saved and live for customers" — an unconditional toast that inspected only
 * `saved?.status` and `saveError?.code`, never the platform's own answer to "is this actually
 * reaching anyone".
 *
 * THE SERVER CONTRACT (built on a sibling branch, landed together with this one; not touched
 * here — no SQL in this diff). Both business_save_birthday_program_v424 and
 * get_active_birthday_program now ALWAYS return a `warnings` array (possibly empty) of
 * {code, message}, where `message` is already a finished sentence written for a business owner.
 * The v145 rule applies: the server decides, the client renders — branch on `code`, never on
 * message text, and the raw `code` string must never reach the screen.
 *
 * THE FIX, in three small functions in app/app.js (all new, all shared by both call sites so the
 * toast and the standing banner cannot say different things):
 *   birthdayPlatformWarningsV849(source)   — pulls a shape-checked warnings array off any RPC
 *                                             response; the single point that is fail-soft.
 *   birthdaySaveToastTextV849(saved,paused)— the save toast. Warned: says the gift was saved AND
 *                                             relays the server's own sentence. Unwarned or the
 *                                             field missing entirely: byte-identical to the toast
 *                                             that shipped before this change.
 *   birthdayPlatformNoticeHtmlV849(warns)  — a standing `<div class="notice warn" role="status">`
 *                                             band, the exact classes nestly_v521's
 *                                             growRedemptionBandV521 already established for the
 *                                             same shape of problem (a working setup the platform
 *                                             is not actually serving). Empty warnings -> ''.
 *
 * Every test below EXECUTES the shipped source — lifted verbatim out of app/app.js and run
 * against stubs, following the pattern tests/business-ui/v829-merchant-scanner-counter-fixes.
 * test.mjs already uses on this branch — because a test that only greps app.js stays green while
 * the behaviour underneath it is dead.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const appJs = await readFile(path.join(root, 'app/app.js'), 'utf8');

/* Slice [from, end-of-`to`] — the end marker is INCLUDED. Same helper v829's test defines. */
const block = (from, to) => {
  const a = appJs.indexOf(from);
  assert.ok(a > -1, `missing block start: ${from}`);
  const b = appJs.indexOf(to, a);
  assert.ok(b > a, `missing block end: ${to}`);
  return appJs.slice(a, b + to.length);
};

const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
}[c]));

/* ---------------------------------------------------------------- the three helpers, executed */

/* Lazy and memoised, exactly like v829's buildMaps: a file that throws on import should only ever
   fail the test that actually exercises the broken bit, not every test in the file. */
const buildHelpers = () => {
  const src = block(
    'function birthdayPlatformWarningsV849(source){',
    '  </div>`;\n}'
  );
  return new Function('esc', `${src}
    return {birthdayPlatformWarningsV849,birthdaySaveToastTextV849,birthdayPlatformNoticeHtmlV849};`)(esc);
};
let helpersCache = null;
const H = () => (helpersCache ||= buildHelpers());

const WARNING = { code: 'birthday_delivery_disabled',
  message: 'Birthday gifts are not being delivered to customers right now. This is a platform ' +
    'setting on our end, not something you need to fix.' };

/* ---------------------------------------------------------------- birthdayPlatformWarningsV849 */

test('birthdayPlatformWarningsV849 passes through a real warnings array untouched', () => {
  assert.deepEqual(H().birthdayPlatformWarningsV849({ programs: [{}], warnings: [WARNING] }), [WARNING]);
});

test('birthdayPlatformWarningsV849 treats an absent field as empty, not as an error', () => {
  assert.deepEqual(H().birthdayPlatformWarningsV849({ programs: [{}] }), []);
  assert.deepEqual(H().birthdayPlatformWarningsV849(null), []);
  assert.deepEqual(H().birthdayPlatformWarningsV849(undefined), []);
});

test('birthdayPlatformWarningsV849 drops a warning that has no readable message rather than crash', () => {
  assert.deepEqual(H().birthdayPlatformWarningsV849({ warnings: [{ code: 'x' }, null, { code: 'y', message: '' }] }), []);
  assert.deepEqual(H().birthdayPlatformWarningsV849({ warnings: 'not-an-array' }), []);
});

/* ---------------------------------------------------------------- birthdaySaveToastTextV849 */

test('a warned save tells the owner the gift was saved AND that it will not be delivered', () => {
  const said = H().birthdaySaveToastTextV849({ status: 'published', warnings: [WARNING] }, false);
  assert.match(said, /saved/i, 'the owner\'s work really was saved and the toast must say so');
  assert.ok(said.includes(WARNING.message), 'the server\'s own owner-facing sentence must be relayed verbatim');
  assert.notEqual(said, 'Birthday gift saved and live for customers',
    'a warned save must not claim delivery when the platform switch says otherwise');
});

test('an unwarned save shows EXACTLY today\'s message — live and paused', () => {
  assert.equal(
    H().birthdaySaveToastTextV849({ status: 'published', warnings: [] }, false),
    'Birthday gift saved and live for customers');
  assert.equal(
    H().birthdaySaveToastTextV849({ status: 'published', warnings: [] }, true),
    'Birthday gift saved and paused');
});

test('a missing `warnings` field (an older server mid-deploy) behaves like the unwarned case', () => {
  assert.equal(
    H().birthdaySaveToastTextV849({ status: 'published' }, false),
    'Birthday gift saved and live for customers');
  assert.equal(
    H().birthdaySaveToastTextV849({ status: 'published' }, true),
    'Birthday gift saved and paused');
});

test('the raw warning `code` string never reaches the toast', () => {
  const said = H().birthdaySaveToastTextV849({ status: 'published', warnings: [WARNING] }, false);
  assert.doesNotMatch(said, /birthday_delivery_disabled/,
    'the machine code must never be shown to a business owner');
});

test('multiple warnings are all relayed, not just the first', () => {
  const second = { code: 'another_code', message: 'A second, unrelated notice for the owner.' };
  const said = H().birthdaySaveToastTextV849({ status: 'published', warnings: [WARNING, second] }, false);
  assert.ok(said.includes(WARNING.message) && said.includes(second.message));
});

/* ---------------------------------------------------------------- birthdayPlatformNoticeHtmlV849 */

test('the standing banner renders the reader\'s warnings and reuses the v521 notice classes', () => {
  const html = H().birthdayPlatformNoticeHtmlV849([WARNING]);
  assert.match(html, /class="notice warn"/, 'must reuse the existing standing-notice class, not invent one');
  assert.match(html, /role="status"/, 'a standing condition, not an alert that demands acknowledgement');
  assert.ok(html.includes(WARNING.message), 'the server\'s owner-facing sentence must actually be shown');
});

test('the banner disappears when warnings are empty or the field is absent', () => {
  assert.equal(H().birthdayPlatformNoticeHtmlV849([]), '');
  assert.equal(H().birthdayPlatformNoticeHtmlV849(undefined), '');
  assert.equal(H().birthdayPlatformNoticeHtmlV849(null), '');
});

test('the raw warning `code` string never reaches the banner, and the message is escaped', () => {
  const html = H().birthdayPlatformNoticeHtmlV849([WARNING]);
  assert.doesNotMatch(html, /birthday_delivery_disabled/,
    'the machine code must never be printed on the screen');
  const xss = { code: 'birthday_delivery_disabled', message: 'Watch this <script>alert(1)</script> & "quotes"' };
  const escaped = H().birthdayPlatformNoticeHtmlV849([xss]);
  assert.doesNotMatch(escaped, /<script>/, 'server text is rendered through esc(), never trusted raw HTML');
  assert.match(escaped, /&lt;script&gt;/);
});

/* ---------------------------------------------------------------- wiring: the real call sites */

test('the real save handler calls the shared toast function with what the server actually returned', () => {
  /* Executed: the exact tail of $('birthdaySaveV364').onclick — from the status check through the
     toast() call — lifted out and run, so this proves the handler is WIRED to
     birthdaySaveToastTextV849 rather than merely defining it unused nearby. */
  const tailSrc = block(
    "if(saved?.status!=='published')return finish('The birthday gift was not made live. Reload and try again.');",
    'toast(birthdaySaveToastTextV849(saved,pausedV849));'
  );
  const said = [];
  const finished = [];
  const closed = [];
  const run = new Function('saved', 'finish', '$', 'close', 'toast', 'birthdaySaveToastTextV849', tailSrc);
  const els = { birthdayActiveV364: { checked: false } };
  const $ = id => els[id];
  run(
    { status: 'published', warnings: [WARNING] },
    m => finished.push(m),
    $,
    () => closed.push(1),
    m => said.push(m),
    H().birthdaySaveToastTextV849
  );
  assert.deepEqual(finished, [], 'a published save with a warning must not be turned into an error');
  assert.deepEqual(closed, [1], 'the modal still closes — the save genuinely happened');
  assert.equal(said.length, 1);
  assert.ok(said[0].includes(WARNING.message));
  assert.notEqual(said[0], 'Birthday gift saved and live for customers');
});

test('the real save handler falls back to today\'s toast when the server sends no warning', () => {
  const tailSrc = block(
    "if(saved?.status!=='published')return finish('The birthday gift was not made live. Reload and try again.');",
    'toast(birthdaySaveToastTextV849(saved,pausedV849));'
  );
  const said = [];
  const run = new Function('saved', 'finish', '$', 'close', 'toast', 'birthdaySaveToastTextV849', tailSrc);
  const els = { birthdayActiveV364: { checked: true } };
  const $ = id => els[id];
  run({ status: 'published', warnings: [] }, () => {}, $, () => {}, m => said.push(m), H().birthdaySaveToastTextV849);
  assert.deepEqual(said, ['Birthday gift saved and live for customers']);
});

test('a non-published save is still refused before any toast is shown (unchanged behaviour)', () => {
  const tailSrc = block(
    "if(saved?.status!=='published')return finish('The birthday gift was not made live. Reload and try again.');",
    'toast(birthdaySaveToastTextV849(saved,pausedV849));'
  );
  const said = [];
  const finished = [];
  const run = new Function('saved', 'finish', '$', 'close', 'toast', 'birthdaySaveToastTextV849', tailSrc);
  const $ = () => ({ checked: true });
  run({ status: 'draft' }, m => finished.push(m), $, () => { throw new Error('must not close') },
    m => said.push(m), H().birthdaySaveToastTextV849);
  assert.deepEqual(finished, ['The birthday gift was not made live. Reload and try again.']);
  assert.deepEqual(said, [], 'nothing is toasted when the save itself did not publish');
});

/* ---------------------------------------------------------------- wiring: the overview snapshot */

test('growOverviewSnapshot exposes birthdayWarnings straight off get_active_birthday_program', () => {
  /* Source-level, paired with the executed tests above: proves the RPC's `warnings` field is
     actually plumbed into the snapshot the birthday screen reads, through the same fail-soft
     helper — not a second, drifting implementation. */
  assert.match(appJs, /birthdayWarnings:birthdayError\?\[\]:birthdayPlatformWarningsV849\(birthday\),/,
    'the overview snapshot must read warnings off the birthday RPC response via the shared helper');
});

test('the birthday screen renders the banner from the snapshot the overview produced', () => {
  /* Source-level, paired with the executed birthdayPlatformNoticeHtmlV849 tests above: proves
     growBirthdayPageV382 — the landing page opened from the Programmes list, read fresh every
     time the owner opens it — actually calls the renderer with the snapshot's field, so an owner
     who opens the page tomorrow sees the same answer the save toast gave them today. */
  assert.match(appJs, /\$\{birthdayPlatformNoticeHtmlV849\(snapshot\.birthdayWarnings\)\}/,
    'growBirthdayPageV382 must render the standing banner from snapshot.birthdayWarnings');
});
