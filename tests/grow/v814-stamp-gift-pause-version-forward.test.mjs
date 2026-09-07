/* nestly_v814 — switching a stamp gift off is version-forward, and the owner is told so.
 *
 * Owner ruling 2026-10-07: pausing a stamp gift on a running stamps programme follows the same
 * rule nestly_v805 gave deleting one. public.business_set_reward_paused_v326 now publishes a new
 * configuration version instead of flipping loyalty_rewards.paused alone, which means the call
 * site has two new obligations it did not have before:
 *
 *   1. a pause that cannot publish comes back as publish_status 'pending' with owner-language
 *      blockers instead of raising, and the gift is still switched ON — toasting "Turned off for
 *      customers" there would tell the owner a lie the customers' cards would then contradict.
 *      This is exactly the trap the delete path fell into before v805;
 *   2. when the server DID version forward, the copy must promise what
 *      db/tests/v814_stamp_gift_pause_version_forward.sql proves — a customer already collecting
 *      keeps the gift until their card ends — and NOT the pre-v814 "for customers" wording,
 *      which reads as "for all of them, now".
 *
 * A points gift and a stopped stamps programme still change for everyone at once (mode
 * 'immediate'), and must keep the old wording — proving the new copy is chosen by what the server
 * actually did, not printed unconditionally.
 *
 * The handler's real source is extracted from app/app.js between two literal markers and EXECUTED
 * in a vm sandbox against stubs, so a regression in behaviour — not just in wording — fails here.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const appJs = await readFile(path.join(root, 'app/app.js'), 'utf8');

const FROM = "outerMain.querySelectorAll('[data-grow-points-gift-toggle-v326]').forEach(button=>button.onclick=async()=>{";
const TO = "\n  outerMain.querySelectorAll('[data-grow-points-gift-delete-v326]')";

const handlerSource = (() => {
  const a = appJs.indexOf(FROM);
  assert.ok(a > -1, `missing marker: ${FROM}`);
  const b = appJs.indexOf(TO, a);
  assert.ok(b > a, `missing marker: ${TO}`);
  const src = appJs.slice(a, b);
  const arrow = src.slice(src.indexOf('async()=>{'));
  /* drop the forEach's own closing "});" so what remains is the arrow function alone */
  return arrow.replace(/\}\);\s*$/, '}');
})();

/* one run of the real handler against a stubbed server reply */
async function run({ checked, reply }) {
  const state = {
    growPointsBusyV326: false,
    growPointsErrorV326: '',
    rerenders: 0,
    toasts: [],
    rpcCalls: [],
  };
  const context = {
    get growPointsBusyV326() { return state.growPointsBusyV326; },
    set growPointsBusyV326(v) { state.growPointsBusyV326 = v; },
    get growPointsErrorV326() { return state.growPointsErrorV326; },
    set growPointsErrorV326(v) { state.growPointsErrorV326 = v; },
    button: {
      disabled: false,
      dataset: { growPointsGiftToggleV326: 'gift-1' },
      getAttribute: name => (name === 'aria-checked' ? (checked ? 'true' : 'false') : null),
    },
    S: { biz: { id: 'biz-1' } },
    sb: { rpc: async (name, args) => { state.rpcCalls.push({ name, args }); return reply; } },
    ownerErrorText: e => e?.message || 'error',
    toast: message => { state.toasts.push(message); },
    growRerenderV322: () => { state.rerenders += 1; },
    isGrowCurrent: () => true,
    Array,
  };
  const handler = vm.runInNewContext(`(${handlerSource})`, context);
  await handler();
  return state;
}

test('v814 a pause the server could not publish reports the blockers and toasts nothing', async () => {
  const state = await run({
    checked: true, // currently ON, so the owner is switching it OFF
    reply: {
      data: {
        status: 'ok', reward_id: 'gift-1', paused: false, mode: 'pending',
        version_split: true, publish_status: 'pending',
        blockers: [{ code: 'stamp_final_gift_missing', message: 'add a gift at stamp 5 to finish this change' }],
      },
      error: null,
    },
  });
  assert.equal(state.rpcCalls.length, 1, 'the write RPC still fires');
  assert.equal(state.rpcCalls[0].name, 'business_set_reward_paused_v326');
  assert.equal(state.rpcCalls[0].args.p_paused, true, 'switching an ON gift off asks for paused=true');
  assert.deepEqual(state.toasts, [],
    'a pending pause changed nothing — toasting a change here is the pre-v805 delete bug');
  assert.match(state.growPointsErrorV326, /add a gift at stamp 5/i,
    'the server\'s own owner-language blocker must reach the owner verbatim');
  assert.equal(state.growPointsBusyV326, false, 'the busy flag is released');
});

test('v814 a pending pause with no blocker message still refuses silently-successfully', async () => {
  const state = await run({
    checked: true,
    reply: { data: { publish_status: 'pending', blockers: [] }, error: null },
  });
  assert.deepEqual(state.toasts, []);
  assert.match(state.growPointsErrorV326, /last stamp/i,
    'the fallback must still tell the owner why nothing happened');
});

test('v814 a version-forward pause promises the NEXT card, not "for customers"', async () => {
  const state = await run({
    checked: true,
    reply: {
      data: {
        status: 'ok', reward_id: 'gift-1', paused: true, mode: 'version_forward',
        version_split: true, publish_status: 'published', blockers: [],
      },
      error: null,
    },
  });
  assert.equal(state.growPointsErrorV326, '');
  assert.deepEqual(state.toasts, ['Off from the next card'],
    'the copy must say the change lands on the next card — a customer mid-card keeps the gift');
  assert.doesNotMatch(state.toasts[0], /for customers/i,
    'the pre-v814 "for customers" wording reads as "for all of them, now" and is no longer true');
});

test('v814 un-pausing version-forward says the gift comes back on the next card', async () => {
  const state = await run({
    checked: false, // currently OFF, so the owner is switching it ON
    reply: {
      data: { status: 'ok', paused: false, mode: 'version_forward', publish_status: 'published' },
      error: null,
    },
  });
  assert.equal(state.rpcCalls[0].args.p_paused, false, 'switching an OFF gift on asks for paused=false');
  assert.deepEqual(state.toasts, ['On from the next card']);
});

test('v814 a points gift still changes for everyone at once and keeps the old wording', async () => {
  const off = await run({
    checked: true,
    reply: {
      data: { status: 'ok', paused: true, mode: 'immediate', version_split: false, publish_status: 'published' },
      error: null,
    },
  });
  assert.deepEqual(off.toasts, ['Turned off for customers'],
    'an immediate pause must not borrow the stamp-card copy — nobody is mid-card');
  const on = await run({
    checked: false,
    reply: { data: { status: 'ok', paused: false, mode: 'immediate', publish_status: 'published' }, error: null },
  });
  assert.deepEqual(on.toasts, ['Turned on for customers']);
});

test('v814 a raised error still wins over any outcome handling', async () => {
  const state = await run({
    checked: true,
    reply: { data: null, error: { message: 'owner loyalty configuration access required' } },
  });
  assert.deepEqual(state.toasts, []);
  assert.match(state.growPointsErrorV326, /owner loyalty configuration access required/);
  assert.equal(state.growPointsBusyV326, false);
});
