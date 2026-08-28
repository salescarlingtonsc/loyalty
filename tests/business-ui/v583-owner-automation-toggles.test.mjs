/* nestly_v583 — the owner's WhatsApp automation card renders what it claims to.
 *
 * WHY THIS TEST EXISTS. A grep for the four column names would stay green while
 * the card rendered nothing, rendered a dead toggle for a lane the business was
 * never granted, or leaked delivery-platform jargon at a shopkeeper. So this
 * EXECUTES the real growWaAutomationCardHtmlV583 out of app/app.js — the same
 * extraction technique as tests/whatsapp/v538-inbox-navigation.test.mjs — and
 * asserts on the HTML an owner would actually receive.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const app = readFileSync(resolve(ROOT, 'app/app.js'), 'utf8');

function boundedRange(startMarker, endPattern) {
  const all = app.split('\n');
  const from = all.findIndex(l => l.startsWith(startMarker));
  assert.ok(from >= 0, `missing ${startMarker}`);
  const to = all.findIndex((l, i) => i > from && endPattern.test(l));
  assert.ok(to > from, `no end for ${startMarker}`);
  return all.slice(from, to + 1).join('\n');
}

function loadRenderer() {
  const escLine = app.split('\n').find(l => l.startsWith('const esc='));
  assert.ok(escLine, 'missing the production esc helper');
  const fn = boundedRange('function growWaAutomationCardHtmlV583(state){', /^\}$/);
  /* eslint-disable no-new-func */
  return new Function(`${escLine}\n${fn}\nreturn growWaAutomationCardHtmlV583;`)();
}

const render = loadRenderer();

const ALL_GRANTED = { appointments: true, bringback: true };
const BIZ_ALL_ON = {
  wa_confirmation_enabled: true,
  wa_reminder_24h_enabled: true,
  wa_reminder_short_enabled: true,
  wa_bringback_enabled: true
};

const ROWS = [
  ['wa_confirmation_enabled', 'Booking confirmation'],
  ['wa_reminder_24h_enabled', 'Appointment reminder'],
  ['wa_reminder_short_enabled', 'Short-notice reminder'],
  ['wa_bringback_enabled', 'Bring back quiet customers']
];

test('all four lanes render as owner-facing rows', () => {
  const html = render({ business: BIZ_ALL_ON, capabilities: ALL_GRANTED, canEdit: true });
  for (const [key, title] of ROWS) {
    assert.ok(html.includes(`data-wa-auto-row-v583="${key}"`), `no row for ${key}`);
    assert.ok(html.includes(title), `row ${key} is missing its title "${title}"`);
    assert.ok(html.includes(`data-wa-auto-toggle-v583="${key}"`), `row ${key} has no toggle`);
  }
  assert.equal((html.match(/data-wa-auto-row-v583=/g) || []).length, 4,
    'exactly four rows, no more and no fewer');
});

test('every row explains what the CUSTOMER receives', () => {
  const html = render({ business: BIZ_ALL_ON, capabilities: ALL_GRANTED, canEdit: true });
  /* One line of plain explanation per row — a switch with no consequence stated
     is a switch the owner will not touch. */
  for (const [, title] of ROWS) {
    const after = html.slice(html.indexOf(title));
    const note = /<p class="muted small" style="margin:2px 0 0">([^<]+)<\/p>/.exec(after);
    assert.ok(note, `row "${title}" has no explanation line at all`);
    assert.match(note[1], /customer/i, `row "${title}" never says what the customer gets`);
    assert.ok(note[1].length >= 40, `row "${title}" explanation is too thin: ${note[1]}`);
  }
});

test('the copy carries no delivery-platform vocabulary', () => {
  const forbidden = [/\bwamid\b/i, /\btemplates?\b/i, /\bWABA\b/i, /\bMeta\b/i,
    /\bopt-?in\b/i, /\bwebhook\b/i, /\bAPI\b/];
  for (const canEdit of [true, false]) {
    for (const caps of [ALL_GRANTED, { appointments: false, bringback: false }]) {
      const html = render({ business: BIZ_ALL_ON, capabilities: caps, canEdit });
      const words = html.replace(/<[^>]*>/g, ' ');
      for (const re of forbidden) {
        assert.doesNotMatch(words, re,
          `owner-facing copy leaked ${re} (canEdit=${canEdit}, granted=${caps.appointments})`);
      }
    }
  }
});

test('a lane the business was never granted renders unavailable, not as a dead toggle', () => {
  const html = render({
    business: BIZ_ALL_ON,
    capabilities: { appointments: false, bringback: true },
    canEdit: true
  });
  for (const key of ['wa_confirmation_enabled', 'wa_reminder_24h_enabled', 'wa_reminder_short_enabled']) {
    assert.ok(html.includes(`data-wa-auto-unavailable-v583="${key}"`),
      `${key} should render as unavailable when the capability is absent`);
    assert.ok(!html.includes(`data-wa-auto-toggle-v583="${key}"`),
      `${key} must not render a toggle the business cannot use`);
  }
  assert.match(html, /Not included in your plan yet/,
    'the ceiling must be legible to the owner, not silent');
  /* The granted lane is unaffected — the ceiling is per capability, not per card. */
  assert.ok(html.includes('data-wa-auto-toggle-v583="wa_bringback_enabled"'),
    'a granted lane must keep its toggle when a different capability is absent');
});

test('a switched-off lane reads off, a switched-on lane reads on', () => {
  const html = render({
    business: { ...BIZ_ALL_ON, wa_reminder_short_enabled: false },
    capabilities: ALL_GRANTED,
    canEdit: true
  });
  const shortRow = html.slice(html.indexOf('data-wa-auto-row-v583="wa_reminder_short_enabled"'));
  const shortToggle = shortRow.slice(0, shortRow.indexOf('</div>'));
  assert.match(shortToggle, /aria-pressed="false"/, 'the off lane must report itself off');
  const confRow = html.slice(html.indexOf('data-wa-auto-row-v583="wa_confirmation_enabled"'));
  assert.match(confRow.slice(0, confRow.indexOf('</div>')), /aria-pressed="true"/,
    'the on lane must report itself on');
});

test('a non-owner sees the state but is given no switch', () => {
  const html = render({ business: BIZ_ALL_ON, capabilities: ALL_GRANTED, canEdit: false });
  assert.ok(!html.includes('data-wa-auto-toggle-v583='),
    'only an owner may write these columns — RLS would refuse anyone else');
  assert.equal((html.match(/data-wa-auto-readonly-v583=/g) || []).length, 4,
    'a non-owner still sees all four states');
  assert.match(html, /Only an owner can change these/);
});

test('the card is hosted on the bring-back surface and loaded there', () => {
  /* The renderer being correct proved nothing on v538 until the nav actually
     reached it, so assert the host element and its loader call both exist. */
  assert.ok(app.includes('<div id="growWaAutomationCardV583"></div>'),
    'the card has no host element on #/grow/bringback');
  assert.ok(app.includes('loadGrowWaAutomationCardV583(outerMain)'),
    'nothing ever calls the loader');
  const hostAt = app.indexOf('<div id="growWaAutomationCardV583"></div>');
  const stripAt = app.indexOf('<div id="growBbWhatsappStripV551"></div>');
  assert.ok(Math.abs(hostAt - stripAt) < 200,
    'the card must sit adjacent to the v551 delivery strip');
});

test('the bring-back delivery strip can name the new suppression reason', () => {
  /* app.v551_enqueue_bringback_send now writes automation_off_for_business; a
     reason the strip cannot name renders as a generic "held by a safety check",
     which would blame Peekaa for the owner's own decision. */
  assert.match(app, /automation_off_for_business:'you switched this message off/);
});
