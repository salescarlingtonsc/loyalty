/* nestly_v886 — owner ruling 2026-09-13: "make OFF symmetric".
   v265 made the Marketing choices tick a promise in one direction only. Ticking it recorded
   consent and then turned on every one of the eighteen v263 category x channel switches; UNticking
   it recorded the withdrawal and left all eighteen exactly as they were. The card's own sentence
   says "Peekaa stops sending straight away", and the two gates that read the v263 matrix rather
   than the platform consent event (business_offers x whatsapp on the bring-back sends,
   business_offers x in_app on promotion alerts) kept letting sends through after a withdrawal.

   These tests EXECUTE the save handler, because the defect was an absent branch: a grep for
   customer_set_all_communications_v263 was green throughout the whole period the bug existed. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

function slice(startMarker, endMarker) {
  const start = app.indexOf(startMarker);
  assert.ok(start > -1, `missing start: ${startMarker}`);
  const end = app.indexOf(endMarker, start);
  assert.ok(end > start, `missing end: ${endMarker}`);
  return app.slice(start, end);
}

const writers = slice('async function grantAllCommunicationsV265(){', 'function customerSignupConsentRecorded(){');
const handler = slice("  const marketingSave=$('customerProfileMarketingSave');", '  /* v286: re-runs the profile render');

/* One switch per direction, so the test can see which RPC the handler chose. */
function harness({ preferenceResult = { data: { outcome: 'updated' } }, allResult = {} } = {}) {
  const nodes = new Map();
  for (const id of ['customerProfileMarketing', 'customerProfileMarketingStatus', 'customerProfileMarketingSave'])
    nodes.set(id, { id, checked: false, disabled: false, innerHTML: '', isConnected: true });

  const calls = [];
  const sb = {
    rpc: async (name, args) => {
      calls.push({ name, args });
      if (name === 'customer_set_platform_marketing_preference') return preferenceResult;
      if (name === 'customer_set_all_communications_v263') return allResult;
      return {};
    }
  };
  const factory = new Function(
    '$', 'esc', 'CUI', 'isCurrent', 'sb', 'customerMarketingSaveErrorTextV4C', 'crypto',
    `${writers}\n${handler}\nreturn {};`
  );
  factory(
    id => nodes.get(id), String, { announce() {} }, () => true, sb,
    () => 'could not be saved', { randomUUID: () => 'fixed-key' }
  );
  return { nodes, calls };
}

const allCalls = calls => calls.filter(c => c.name === 'customer_set_all_communications_v263');

test('unticking marketing turns every communication switch OFF', async () => {
  const { nodes, calls } = harness();
  nodes.get('customerProfileMarketing').checked = false;
  await nodes.get('customerProfileMarketingSave').onclick();
  assert.deepEqual(
    calls.map(c => c.name),
    ['customer_set_platform_marketing_preference', 'customer_set_all_communications_v263'],
    'the withdrawal is recorded first, then the switches follow it'
  );
  assert.deepEqual(allCalls(calls)[0].args, { p_enabled: false });
  assert.match(nodes.get('customerProfileMarketingStatus').innerHTML, /withdrawn/);
});

test('ticking marketing still turns every communication switch ON, in that order', async () => {
  const { nodes, calls } = harness();
  nodes.get('customerProfileMarketing').checked = true;
  await nodes.get('customerProfileMarketingSave').onclick();
  assert.deepEqual(allCalls(calls)[0].args, { p_enabled: true });
  const consentAt = calls.findIndex(c => c.name === 'customer_set_platform_marketing_preference');
  const switchesAt = calls.findIndex(c => c.name === 'customer_set_all_communications_v263');
  assert.ok(consentAt >= 0 && switchesAt > consentAt, 'delivery must never start before the evidence exists');
});

test('a failed withdrawal of the switches is reported, not papered over', async () => {
  const { nodes } = harness({ allResult: { error: { message: 'nope' } } });
  nodes.get('customerProfileMarketing').checked = false;
  await nodes.get('customerProfileMarketingSave').onclick();
  const shown = nodes.get('customerProfileMarketingStatus').innerHTML;
  assert.match(shown, /class="err"/);
  assert.match(shown, /could not be turned off/);
  assert.doesNotMatch(shown, /turned back on/, 'the grant wording must not be shown for a withdrawal');
});

test('a failed grant keeps its own v265 wording', async () => {
  const { nodes } = harness({ allResult: { error: { message: 'nope' } } });
  nodes.get('customerProfileMarketing').checked = true;
  await nodes.get('customerProfileMarketingSave').onclick();
  assert.match(nodes.get('customerProfileMarketingStatus').innerHTML, /could not be turned back on/);
});

test('a refused consent write never touches the switches in either direction', async () => {
  for (const checked of [true, false]) {
    const { nodes, calls } = harness({ preferenceResult: { error: { code: '42501' } } });
    nodes.get('customerProfileMarketing').checked = checked;
    await nodes.get('customerProfileMarketingSave').onclick();
    assert.deepEqual(allCalls(calls), [], `switches were written despite a refused consent write (checked=${checked})`);
  }
});

test('the two writers reuse the one RPC rather than re-implementing it', () => {
  assert.match(writers, /grantAllCommunicationsV265[\s\S]{0,400}?customer_set_all_communications_v263',\{p_enabled:true\}/);
  assert.match(writers, /withdrawAllCommunicationsV886[\s\S]{0,1400}?customer_set_all_communications_v263',\{p_enabled:false\}/);
});

test('the two biometric controls are one card, and every binding id survives the merge', () => {
  const card = slice('<section class="card" id="customerPasskeys"', '${customerAccountDeletionCardHtmlV749()}');
  /* nestly_v887 withdrew the passkey half, so #customerPasskeyAdd is gone with it — see
     v887-phone-biometrics-only.test.mjs. Everything else still binds by id. */
  for (const id of ['customerPasskeyList', 'customerPasskeyManageStatus',
    'customerAppLockV860', 'customerAppLockBodyV860', 'customerAppLockStatusV860'])
    assert.ok(card.includes(`id="${id}"`), `${id} did not survive the merge`);
  /* Both doors are still named, and named differently — that was the whole confusion. */
  assert.match(card, /Sign in with Face ID/);
  assert.match(card, /Lock the app with Face ID/);
  /* The app lock half stays native-only: there is no owner check to perform on the web. */
  assert.match(card, /\$\{NestlyNativeBridge\.isNative\?`<div id="customerAppLockV860"/);
  /* And it is no longer a second card of its own. */
  assert.doesNotMatch(app, /<section class="card" id="customerAppLockV860"/);
});
