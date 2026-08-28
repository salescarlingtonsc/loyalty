/* nestly_v574 — WhatsApp marketing consent: a customer-facing card that grants and withdraws with
 * the SAME one-tap switch, and a staff-facing line that can only ever read it, never set it.
 *
 * Executes the REAL render/wire functions extracted out of app/app-customer.js and
 * app/app-business.js (the technique used by tests/whatsapp/v538-inbox-navigation.test.mjs), not
 * source-regex greps — a grep would stay green even if the switch silently stopped calling the
 * RPC or the staff panel grew a setter nobody meant to add.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const customerSrc = readFileSync(resolve(ROOT, 'app/app-customer.js'), 'utf8');
const businessSrc = readFileSync(resolve(ROOT, 'app/app-business.js'), 'utf8');

function boundedRange(src, startMarker, endPattern) {
  const all = src.split('\n');
  const from = all.findIndex(l => l.startsWith(startMarker));
  assert.ok(from >= 0, `missing ${startMarker}`);
  const to = all.findIndex((l, i) => i > from && endPattern.test(l));
  assert.ok(to > from, `no end for ${startMarker}`);
  return all.slice(from, to + 1).join('\n');
}

/* ---------- customer card: renderCustomerWallet's WhatsApp section ---------- */

function buildCustomerFns() {
  const markupFn = boundedRange(customerSrc, 'function customerWhatsappConsentCardMarkupV574(', /^\}$/);
  const wireFn = boundedRange(customerSrc, 'function wireCustomerWhatsappConsentV574(', /^\}$/);
  const harness = `
    var escCalls=[];
    function esc(s){escCalls.push(s);return String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
  `;
  return new Function(
    'window',
    `${harness}
    ${markupFn}
    ${wireFn}
    return {customerWhatsappConsentCardMarkupV574,wireCustomerWhatsappConsentV574};`
  )(globalThis);
}

/* Minimal DOM-ish stand-ins — just enough for querySelector('#id') and closest('#id') on the
   fragment the markup function itself produced, via jsdom-free string/innerHTML plumbing is more
   than this needs: we drive the wiring function directly against a tiny fake element instead. */
function fakeInputHost(html, checked) {
  const listeners = {};
  const input = {
    id: 'customerWhatsappConsentToggleV574',
    checked,
    disabled: false,
    isConnected: true,
    set onchange(fn) { listeners.change = fn; },
    get onchange() { return listeners.change; },
    closest(sel) { return sel === '#walletWhatsappConsentV574' ? host : null; },
  };
  const host = {
    _html: html,
    outerHTML: html,
    querySelector(sel) { return sel === '#customerWhatsappConsentToggleV574' ? input : null; },
  };
  return { host, input, fire: () => listeners.change() };
}

test('customer card: renders UNTICKED when the server says allowed=false', () => {
  const { customerWhatsappConsentCardMarkupV574 } = buildCustomerFns();
  const html = customerWhatsappConsentCardMarkupV574('Cubbly SPA', { business_id: 'b1', whatsapp_marketing: { allowed: false } });
  assert.doesNotMatch(html, /type="checkbox"[^>]*checked/, 'must not be pre-ticked');
  assert.match(html, /type="checkbox"/);
});

test('customer card: renders TICKED only when the server says allowed=true', () => {
  const { customerWhatsappConsentCardMarkupV574 } = buildCustomerFns();
  const html = customerWhatsappConsentCardMarkupV574('Cubbly SPA', { business_id: 'b1', whatsapp_marketing: { allowed: true } });
  assert.match(html, /type="checkbox" checked/);
});

test('customer card: the business name appears in the heading and the switch label, escaped', () => {
  const { customerWhatsappConsentCardMarkupV574 } = buildCustomerFns();
  const html = customerWhatsappConsentCardMarkupV574('Tan & Sons <Café>', { business_id: 'b1', whatsapp_marketing: { allowed: false } });
  assert.match(html, /WhatsApp from Tan &amp; Sons &lt;Café&gt;/);
  assert.match(html, /Receive useful WhatsApp updates and offers from Tan &amp; Sons &lt;Café&gt;\./);
});

test('customer card: no permission entry (not yet linked) renders disabled, no switch at all', () => {
  const { customerWhatsappConsentCardMarkupV574 } = buildCustomerFns();
  const html = customerWhatsappConsentCardMarkupV574('Cubbly SPA', null);
  assert.doesNotMatch(html, /type="checkbox"/, 'an unlinked business must not offer a switch to tap');
  assert.match(html, /We'll ask about WhatsApp once this business has confirmed your membership\./);
});

test('customer card: exact required copy strings are present verbatim', () => {
  const { customerWhatsappConsentCardMarkupV574 } = buildCustomerFns();
  const html = customerWhatsappConsentCardMarkupV574('Cubbly SPA', { business_id: 'b1', whatsapp_marketing: { allowed: true } });
  assert.match(html, /Only this business\. Turning it on here does not affect any other business you follow, and it never changes your booking confirmations, receipts or security messages — those are not marketing and keep sending\./);
});

test('customer switch: toggling ON calls the v574 RPC with a fresh idempotency key and the right args', async () => {
  const { wireCustomerWhatsappConsentV574 } = buildCustomerFns();
  const calls = [];
  global.sb = { rpc: (name, args) => { calls.push({ name, args }); return Promise.resolve({ data: { status: 'ok', state: { allowed: true } }, error: null }); } };
  globalThis.crypto.randomUUID = (() => { let n = 0; return () => `key-${++n}`; })();
  global.CUI = { announce: () => {} };
  global.$ = () => null;
  const { host, input, fire } = fakeInputHost('<section id="walletWhatsappConsentV574"></section>', true);
  wireCustomerWhatsappConsentV574('biz-123', 'Cubbly SPA', host, () => true);
  await fire();
  assert.equal(calls.length, 1);
  assert.equal(calls[0].name, 'customer_set_whatsapp_marketing_consent_v574');
  assert.deepEqual(calls[0].args, { p_business: 'biz-123', p_opted_in: true, p_idempotency_key: 'key-1' });
});

test('customer switch: toggling OFF (withdrawal) is the identical one-tap RPC call, opted_in=false', async () => {
  const { wireCustomerWhatsappConsentV574 } = buildCustomerFns();
  const calls = [];
  global.sb = { rpc: (name, args) => { calls.push({ name, args }); return Promise.resolve({ data: { status: 'ok', state: { allowed: false } }, error: null }); } };
  globalThis.crypto.randomUUID = () => 'withdraw-key';
  global.CUI = { announce: () => {} };
  global.$ = () => null;
  const { host, fire } = fakeInputHost('<section id="walletWhatsappConsentV574"></section>', false);
  wireCustomerWhatsappConsentV574('biz-123', 'Cubbly SPA', host, () => true);
  await fire();
  assert.equal(calls.length, 1);
  assert.equal(calls[0].args.p_opted_in, false);
});

test('customer switch: a second toggle mints a NEW idempotency key, not a reused one', async () => {
  const { wireCustomerWhatsappConsentV574 } = buildCustomerFns();
  const calls = [];
  global.sb = { rpc: (name, args) => { calls.push(args); return Promise.resolve({ data: { status: 'ok', state: { allowed: true } }, error: null }); } };
  let n = 0;
  globalThis.crypto.randomUUID = () => `k${++n}`;
  global.CUI = { announce: () => {} };
  global.$ = () => null;
  const { host, fire } = fakeInputHost('<section id="walletWhatsappConsentV574"></section>', true);
  wireCustomerWhatsappConsentV574('biz-123', 'Cubbly SPA', host, () => true);
  await fire();
  await fire();
  assert.equal(calls.length, 2);
  assert.notEqual(calls[0].p_idempotency_key, calls[1].p_idempotency_key);
});

test('customer switch: a failed save reverts the switch to its previous state', async () => {
  const { wireCustomerWhatsappConsentV574 } = buildCustomerFns();
  global.sb = { rpc: () => Promise.resolve({ data: null, error: { message: 'boom' } }) };
  globalThis.crypto.randomUUID = () => 'k';
  const announced = [];
  global.CUI = { announce: m => announced.push(m) };
  const statusNode = { textContent: '' };
  global.$ = id => (id === 'customerWhatsappConsentStatusV574' ? statusNode : null);
  const { host, input, fire } = fakeInputHost('<section id="walletWhatsappConsentV574"></section>', true);
  wireCustomerWhatsappConsentV574('biz-123', 'Cubbly SPA', host, () => true);
  await fire();
  assert.equal(input.checked, false, 'a failed ON-toggle must revert to unchecked');
  assert.match(statusNode.textContent, /That choice could not be saved, so it has been put back\. Please try again\./);
});

test('customer switch: a "refused / not_linked_to_business" response reverts and swaps to the disabled card', async () => {
  const { wireCustomerWhatsappConsentV574, customerWhatsappConsentCardMarkupV574 } = buildCustomerFns();
  global.sb = { rpc: () => Promise.resolve({ data: { status: 'refused', reason: 'not_linked_to_business' }, error: null }) };
  globalThis.crypto.randomUUID = () => 'k';
  global.CUI = { announce: () => {} };
  global.$ = () => null;
  const { host, input, fire } = fakeInputHost('<section id="walletWhatsappConsentV574"></section>', true);
  let rewritten = null;
  Object.defineProperty(host, 'outerHTML', { set(v) { rewritten = v; }, get() { return host._html; } });
  wireCustomerWhatsappConsentV574('biz-123', 'Cubbly SPA', host, () => true);
  await fire();
  assert.equal(input.checked, false);
  assert.ok(rewritten, 'the card must be replaced with the disabled variant');
  assert.match(rewritten, /We'll ask about WhatsApp once this business has confirmed your membership\./);
  assert.equal(rewritten, customerWhatsappConsentCardMarkupV574('Cubbly SPA', null));
});

/* ---------- staff read-only line: staffClientWhatsappConsentRowMarkupV574 ---------- */

function buildStaffFns() {
  const dateFn = boundedRange(businessSrc, 'function formatCustomerJoinedDateV141(', /^\}$/);
  const rowFn = boundedRange(businessSrc, 'function staffClientWhatsappConsentRowMarkupV574(', /^\}$/);
  const harness = `
    function esc(s){return String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
  `;
  return new Function(
    `${harness}
    ${dateFn}
    ${rowFn}
    return {staffClientWhatsappConsentRowMarkupV574};`
  )();
}

test('staff row: allowed shows "Allowed by customer · {date}" and NO toggle/button', () => {
  const { staffClientWhatsappConsentRowMarkupV574 } = buildStaffFns();
  const html = staffClientWhatsappConsentRowMarkupV574({ opted_in: true, decided_at: '2026-08-20T03:00:00Z' });
  assert.match(html, /Allowed by customer · 20 Aug 2026/);
  assert.match(html, /WhatsApp offers/);
  assert.doesNotMatch(html, /<button/i, 'staff must never get a setter for this');
  assert.doesNotMatch(html, /<input/i, 'staff must never get a toggle for this');
  assert.match(html, /Only the customer can change this, from their own Peekaa app\./);
});

test('staff row: not opted in (or no row at all) shows "Not allowed", still no control', () => {
  const { staffClientWhatsappConsentRowMarkupV574 } = buildStaffFns();
  const notOptedIn = staffClientWhatsappConsentRowMarkupV574({ opted_in: false, decided_at: '2026-08-20T03:00:00Z' });
  const missing = staffClientWhatsappConsentRowMarkupV574(null);
  for (const html of [notOptedIn, missing]) {
    assert.match(html, /Not allowed/);
    assert.doesNotMatch(html, /<button/i);
    assert.doesNotMatch(html, /<input/i);
    assert.doesNotMatch(html, /Allowed by customer/);
  }
});

test('staff row: the label is escaped and the row uses the same c360-summary-row-v294 shape', () => {
  const { staffClientWhatsappConsentRowMarkupV574 } = buildStaffFns();
  const html = staffClientWhatsappConsentRowMarkupV574(null);
  assert.match(html, /<div class="c360-summary-row-v294"><span class="c360-summary-label-v294">WhatsApp offers<\/span>/);
});

/* ---------- wiring survives an unavailable/erroring RPC without breaking the panel ---------- */

test('the staff read is fired with .catch(()=>null) so a broken RPC cannot throw into the panel', () => {
  const around = businessSrc.slice(
    businessSrc.indexOf('const whatsappPermissionRequestV574='),
    businessSrc.indexOf('const whatsappPermissionRequestV574=') + 400
  );
  assert.match(around, /staff_get_client_messaging_permission_v574/);
  assert.match(around, /\.catch\(\(\)=>null\)/);
});
