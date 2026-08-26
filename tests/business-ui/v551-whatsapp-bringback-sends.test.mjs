/* V551 — bring-back vouchers reach the customer's phone.
   These tests EXECUTE the extracted delivery-strip loader against fixture payloads shaped like
   the deployed get_retention_send_stats_v551 output, and pin the migration's contract lines the
   dispatcher and consent posture depend on. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const migration = readFileSync(
  join(root, 'db', 'migrations', '20260827_nestly_v551_whatsapp_bringback_sends.sql'), 'utf8');
const dispatcher = readFileSync(
  join(root, 'supabase', 'functions', 'whatsapp-retention-dispatch', 'index.ts'), 'utf8');

const blockStart = app.indexOf('async function loadGrowBbWhatsappStripV551(');
const blockEnd = app.indexOf('/* V550 — the recovered-revenue report renderer', blockStart);
assert.ok(blockStart > -1 && blockEnd > blockStart, 'the strip loader is a top-level function before the V550 renderer');
const block = app.slice(blockStart, blockEnd);

function run(rpcResult) {
  const calls = [];
  const host = { innerHTML: '<!-- untouched -->', isConnected: true };
  const rootEl = { querySelector: (sel) => (sel === '#growBbWhatsappStripV551' ? host : null) };
  const sandbox = {
    esc: (x) => String(x ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'),
    S: { biz: { id: 'biz-1' } },
    sb: { rpc: async (fn, args) => { calls.push({ fn, args }); return rpcResult; } },
    document: { querySelector: () => null }
  };
  const context = vm.createContext(sandbox);
  context.__exports = {};
  vm.runInContext(block + '\n__exports.load = loadGrowBbWhatsappStripV551;', context);
  return { load: () => context.__exports.load(rootEl), host, calls };
}

test('V551 while the template is in review, the strip says so instead of showing a dead zero', async () => {
  const h = run({ data: { queued: 3, sent: 0, delivered: 0, read: 0, failed: 0, suppressed: 0, suppressed_reasons: {}, template_status: 'submitted' }, error: null });
  await h.load();
  assert.equal(h.calls[0].fn, 'get_retention_send_stats_v551');
  assert.ok(h.host.innerHTML.includes('being reviewed by WhatsApp'));
  assert.ok(h.host.innerHTML.includes('queue up and send automatically'));
});

test('V551 counts and named suppression reasons are printed in owner words', async () => {
  const h = run({ data: {
    queued: 1, sent: 4, delivered: 3, read: 2, failed: 1, suppressed: 5,
    suppressed_reasons: { consent_missing: 3, no_phone: 1, customer_opted_out: 1 },
    template_status: 'approved'
  }, error: null });
  await h.load();
  const html = h.host.innerHTML;
  assert.ok(html.includes('>4</b> Sent') && html.includes('>2</b> Read') && html.includes('>5</b> Not sent'));
  assert.ok(html.includes('has not consented'), 'consent_missing gets a human sentence');
  assert.ok(html.includes('replied STOP'), 'customer_opted_out gets a human sentence');
  assert.ok(html.includes('no phone number on file'));
  assert.ok(!html.includes('being reviewed'), 'approved template shows the live copy');
});

test('V551 an RPC error leaves the page silent, and the payload is never re-derived', async () => {
  const h = run({ data: null, error: { message: 'boom' } });
  await h.load();
  assert.equal(h.host.innerHTML, '');
  assert.ok(!block.includes('capability_state'), 'the browser never re-evaluates the gates');
});

/* ------------------------------------------------- migration + dispatcher contract pins */

test('V551 every gate is a named suppression and consent is checked twice', () => {
  for (const reason of ['platform_outbound_off', 'retention_sends_off', 'capability_disabled',
    'synthetic_client', 'consent_missing', 'preference_opt_out', 'no_phone',
    'consent_withdrawn', 'stale_unsent', 'customer_opted_out']) {
    assert.ok(migration.includes(`'${reason}'`), `named suppression: ${reason}`);
  }
  assert.ok(migration.includes("coalesce(v_client.marketing_consent, false)"),
    'consent is affirmative-only at enqueue');
  assert.ok(migration.includes("not coalesce(c.marketing_consent, false)"),
    'and re-checked at claim');
  assert.ok(migration.includes("t.template_key = s.template_key and t.status = 'approved'"),
    'claim refuses an unapproved template');
});

test('V551 the null lease is stale by definition', () => {
  assert.ok(migration.includes('if v_row.lease_token is null or v_row.lease_token is distinct from p_lease_token then'),
    'a report against an unleased row is refused');
});

test('V551 the dispatcher is the template edition of the shared boundaries, on the same secret', () => {
  assert.ok(dispatcher.includes("from '../_shared/whatsapp-send-boundaries.mjs'"));
  assert.ok(dispatcher.includes('bindTemplateParameters') && dispatcher.includes('buildTemplateSend'));
  assert.ok(dispatcher.includes("env('WHATSAPP_DISPATCH_SECRET')") &&
    dispatcher.includes('x-peekaa-whatsapp-dispatch-secret'),
    'same header + env as the support dispatcher — one secret drives both lanes');
  assert.ok(dispatcher.includes("internal_retention_claim_v551") && dispatcher.includes("internal_retention_report_v551"));
  // Comments legitimately NAME the support queue (to say it is never touched); code must not.
  const dispatcherCode = dispatcher.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
  assert.ok(!dispatcherCode.includes('support_messages'), 'the retention lane never touches the support queue');
});

test('V551 the STOP sweep writes the consents vocabulary the table accepts', () => {
  assert.ok(migration.includes("'whatsapp', 'withdrawn', 'whatsapp_stop_reply'"),
    "consents.action is 'withdrawn' (the CHECK allows only granted/withdrawn)");
  assert.ok(migration.includes("in ('stop', 'unsubscribe')"));
});
