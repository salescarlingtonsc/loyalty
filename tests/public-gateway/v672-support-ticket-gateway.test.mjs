import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import {
  normalizePublicLocale,
  validSupportTicketPayload,
} from '../../supabase/functions/_shared/validation.ts';

const root = new URL('../../', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');

const gateway = await read('supabase/functions/public-support-ticket/index.ts');
const validation = await read('supabase/functions/_shared/validation.ts');
const config = await read('supabase/config.toml');
const page = await read('app/support.html');
const vercel = await read('app/vercel.json');

const ticket = () => ({
  requester_kind: 'customer',
  contact_name: 'Ada Lim',
  contact_email: 'ada@example.com',
  contact_phone: '+6581234567',
  business_name: '',
  what_happened: 'My stamps vanished after I paid at the counter.',
  locale: 'en',
  idempotency_key: '319df1fd-b9f6-4bd3-9a23-86a332026456',
});

test('support tickets are accepted only through the guarded public gateway', () => {
  assert.match(gateway, /requireOrigin\(req\)/);
  assert.match(gateway, /verifyTurnstile\(req, body\.turnstile_token, 'support_ticket'\)/);
  assert.match(gateway, /support-ticket-abuse/);
  assert.match(gateway, /support-ticket-submit/);
  assert.match(gateway, /internal_submit_support_ticket_v672/);
  // The browser must never reach the table or the RPC directly.
  assert.doesNotMatch(page, /support_tickets_v672/);
  assert.doesNotMatch(page, /internal_submit_support_ticket_v672/);
});

test('anonymous submission is possible because the function does not verify a JWT', () => {
  assert.match(config, /\[functions\.public-support-ticket\]\nverify_jwt = false/);
});

test('the public GET hands out only the Turnstile site key, never a ticket', () => {
  assert.match(gateway, /turnstile_site_key: turnstileSiteKey\(\)/);
  /* A support ticket has no status-by-reference read on purpose: a guessed reference must not
     become a way to read someone else's complaint. */
  assert.doesNotMatch(gateway, /public_reference/);
  assert.doesNotMatch(gateway, /platform_list_support_tickets_v672/);
});

test('payload validation mirrors the database CHECK constraints', () => {
  assert.equal(validSupportTicketPayload(ticket()), true);
  assert.equal(validSupportTicketPayload(null), false);
  assert.equal(validSupportTicketPayload({ ...ticket(), requester_kind: 'staff' }), false);
  assert.equal(validSupportTicketPayload({ ...ticket(), contact_email: 'not-an-email' }), false);
  assert.equal(validSupportTicketPayload({ ...ticket(), contact_phone: '81234567' }), false);
  assert.equal(validSupportTicketPayload({ ...ticket(), what_happened: 'help' }), false);
  assert.equal(validSupportTicketPayload({ ...ticket(), idempotency_key: 'nope' }), false);
  assert.equal(validSupportTicketPayload({ ...ticket(), locale: 'fr' }), false);
});

test('the phone number is optional but a business owner must name their business', () => {
  assert.equal(validSupportTicketPayload({ ...ticket(), contact_phone: '' }), true);
  assert.equal(validSupportTicketPayload({ ...ticket(), contact_phone: undefined }), true);
  assert.equal(
    validSupportTicketPayload({ ...ticket(), requester_kind: 'business_owner' }),
    false,
    'a business owner with no business name must be refused',
  );
  assert.equal(
    validSupportTicketPayload({
      ...ticket(), requester_kind: 'business_owner', business_name: 'Kopi Lab',
    }),
    true,
  );
});

test('every locale the page can send is one the gateway accepts', () => {
  /* The page folds navigator.language itself; this pins the two halves together, because an
     unrecognised tag is a hard server-side refusal rather than a fallback. */
  assert.match(page, /function pageLocale\(\)/);
  for (const sent of ['en', 'zh-CN', 'ms']) {
    assert.equal(normalizePublicLocale(sent), sent, `the page may send ${sent}`);
  }
  assert.equal(normalizePublicLocale('en-US'), null, 'raw browser tags are refused by design');
});

test('the public page reaches the desk at /support and keeps the reply promise', () => {
  assert.match(vercel, /"source": "\/support"/);
  assert.match(vercel, /"destination": "\/support\.html"/);
  assert.match(page, /hello@peekaa\.asia/);
  assert.match(page, /REPLY_WINDOW_DAYS=7/);
  assert.match(page, /business days/);
  // Both identities are offered, and neither is preselected.
  assert.match(page, /I am a customer/);
  assert.match(page, /I am a business owner/);
  assert.match(page, /kind:null/);
});

test('the console reads the queue through the super-admin RPC only', async () => {
  const console_ = await read('app/platform-console.js');
  assert.match(console_, /platform_list_support_tickets_v672/);
  assert.match(console_, /platform_update_support_ticket_v672/);
  assert.match(console_, /activeKey==='support'/);
  assert.doesNotMatch(console_, /from\('support_tickets_v672'\)/);
});
