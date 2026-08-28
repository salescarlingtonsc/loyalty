/* nestly_v580 — the bring-back WhatsApp strip must never show an owner a raw
 * snake_case suppression code, and the confirmation-template save handler
 * must format errors the same way every other handler in the file does.
 *
 * WHY THIS TEST EXISTS. reasonLabelV551 had a wrong key (platform_outbound_off
 * instead of the server's real outbound_off) and a `||k` fallback, so both a
 * known-but-mistyped reason AND any future unmapped reason printed straight
 * snake_case to the owner. This extracts the REAL reasonLabelV551 map (and
 * the reasonBits fallback expression) out of app/app.js and runs it against
 * every reason the server can currently write, plus a made-up future one,
 * asserting none of them ever renders raw.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const app = readFileSync(resolve(ROOT, 'app/app.js'), 'utf8');

/* Every reason the server (get_retention_send_stats_v551 and friends) can
   write today, per the E1 defect spec. */
const SERVER_REASONS = [
  'retention_sends_off', 'outbound_off', 'capability_disabled',
  'synthetic_client', 'consent_missing', 'whatsapp_consent_absent',
  'whatsapp_consent_withdrawn', 'preference_opt_out', 'no_phone',
  'cooldown_active', 'platform_hold', 'business_not_active',
  'demo_business_marketing', 'platform_channel_off', 'business_not_eligible',
  'synthetic_business', 'stale_unsent', 'consent_withdrawn',
];

const RAW_SNAKE_CASE = /^[a-z0-9_]+$/;

function extractReasonLabelSource() {
  const lines = app.split('\n');
  const mapLine = lines.find(l => l.includes('const reasonLabelV551='));
  assert.ok(mapLine, 'reasonLabelV551 map not found in app/app.js');
  const bitsLine = lines.find(l => l.includes('const reasonBits='));
  assert.ok(bitsLine, 'reasonBits line not found in app/app.js');
  return { mapLine, bitsLine };
}

function buildReasonLabelFn() {
  const { mapLine, bitsLine } = extractReasonLabelSource();
  /* Build a tiny sandbox that reproduces exactly what loadGrowBbWhatsappStripV551
     does: build the map, then look a key up through the same fallback
     expression used to build reasonBits (with `reasons` and `k`,`v` bound to
     a single-entry object so the real expression executes unmodified). */
  const mapMatch = bitsLine.match(/\.map\((\(\[k,v\]\)=>.*)\);\s*$/);
  assert.ok(mapMatch, 'could not isolate the reasonBits map() callback');
  const src = `
    ${mapLine}
    return function(key){
      const reasons={[key]:1};
      const bits=Object.entries(reasons).map(${mapMatch[1]});
      return bits[0];
    };
  `;
  // eslint-disable-next-line no-new-func
  return new Function(src)();
}

test('v580: every real server suppression reason renders human copy, not raw snake_case', () => {
  const labelFor = buildReasonLabelFn();
  for (const reason of SERVER_REASONS) {
    const rendered = labelFor(reason);
    assert.ok(rendered, `no output rendered for reason "${reason}"`);
    const afterDash = rendered.replace(/^\d+\s*—\s*/, '');
    assert.doesNotMatch(
      afterDash, RAW_SNAKE_CASE,
      `reason "${reason}" rendered raw snake_case: "${rendered}"`
    );
  }
});

test('v580: outbound_off is the correct key (not the old platform_outbound_off typo)', () => {
  const { mapLine } = extractReasonLabelSource();
  assert.match(mapLine, /outbound_off:/, 'outbound_off key missing from reasonLabelV551');
  assert.doesNotMatch(
    mapLine, /platform_outbound_off:/,
    'stale platform_outbound_off key should have been renamed to outbound_off'
  );
});

test('v580: an unknown future reason still renders human copy, never the raw code', () => {
  const labelFor = buildReasonLabelFn();
  const rendered = labelFor('some_future_reason_the_server_invents_later');
  assert.ok(rendered);
  const afterDash = rendered.replace(/^\d+\s*—\s*/, '');
  assert.doesNotMatch(
    afterDash, RAW_SNAKE_CASE,
    `unmapped future reason rendered raw snake_case: "${rendered}"`
  );
});

test('v580: the confirmation-template save handler formats errors with humanErrorV295, like its siblings', () => {
  const lines = app.split('\n');
  const handlerStart = lines.findIndex(l => l.includes("$('setConfirmationTemplateSave')"));
  assert.ok(handlerStart >= 0, 'setConfirmationTemplateSave handler not found');
  const handlerEnd = lines.findIndex((l, i) => i > handlerStart && /^\s*\};?\s*$/.test(l));
  assert.ok(handlerEnd > handlerStart, 'could not find end of setConfirmationTemplateSave handler');
  const handlerSrc = lines.slice(handlerStart, handlerEnd + 1).join('\n');

  assert.match(
    handlerSrc, /err\.innerHTML=`<div class="err">\$\{esc\(humanErrorV295\(error,/,
    'template-save error path must call humanErrorV295(...), like every sibling handler in this function'
  );
  assert.doesNotMatch(
    handlerSrc, /esc\(error\.message\)/,
    'template-save error path must not render error.message raw'
  );
});
