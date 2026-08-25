/* v517 — the WhatsApp send decision module.
 *
 * These EXECUTE the real functions the dispatcher will import. The Meta call is
 * exercised against a real local http server rather than a stub object, so
 * header parsing, body bytes, status handling and JSON decoding all genuinely
 * run — the parts a hand-rolled fake would quietly skip.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

import {
  MAX_ATTEMPTS,
  bindTemplateParameters,
  buildTemplateSend,
  classifyMetaResponse,
  classifyTransportError,
  consumesQuota,
  formatE164,
  isTerminal,
  nextAttemptDelaySeconds,
  parseRetryAfter,
  resolveOutcome,
  sendPath,
  shouldRetry,
  toE164,
} from '../../supabase/functions/_shared/whatsapp-send-boundaries.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');

/* ----------------------------------------------------------- addressing --- */

test('a Singapore mobile becomes E.164 without a plus', () => {
  assert.equal(toE164('82088809'), '6582088809');
  assert.equal(toE164('91234567'), '6591234567');
  assert.equal(formatE164('82088809'), '+6582088809');
});

test('every SG mobile prefix app.norm_phone admits is accepted here', () => {
  // app.norm_phone admits 3 (VoIP), 6 (fixed line), 8 and 9. This module must not
  // silently narrow that set — a mismatch would make phone_norm rows unsendable
  // with no explanation anywhere.
  for (const prefix of ['3', '6', '8', '9']) {
    assert.equal(toE164(`${prefix}1234567`), `65${prefix}1234567`, `prefix ${prefix}`);
  }
});

test('anything app.norm_phone would have rejected is rejected here too', () => {
  for (const bad of [
    null, undefined, '', '1234567', '812345678', '+6582088809', '6582088809',
    '8208880a', '  82088809  ', 12345678, '02088809', '72088809',
  ]) {
    assert.equal(toE164(bad), null, `${String(bad)} must not become an address`);
  }
});

test('the send path names no host and no credential', () => {
  assert.equal(sendPath('222222222222222'), '/v21.0/222222222222222/messages');
  for (const bad of ['', null, 'abc', '../../evil', '1'.repeat(40)]) {
    assert.equal(sendPath(bad), null, `${String(bad)} must not build a path`);
  }
});

/* ------------------------------------------------------- parameter bind --- */

const DESCRIPTORS = [{ key: 'business' }, { key: 'customer' }, { key: 'service' }, { key: 'when' }];

test('named values bind to positional parameters in descriptor order', () => {
  const bound = bindTemplateParameters(DESCRIPTORS, {
    customer: 'Sarah', business: 'Cubbly Salon', when: '26 Aug, 3:00 PM', service: 'Hair Treatment',
  });
  assert.equal(bound.ok, true);
  assert.deepEqual(bound.parameters.map((p) => p.text),
    ['Cubbly Salon', 'Sarah', 'Hair Treatment', '26 Aug, 3:00 PM']);
  assert.ok(bound.parameters.every((p) => p.type === 'text'));
});

test('a missing or blank value refuses the send and names what is missing', () => {
  for (const values of [
    { business: 'Cubbly', customer: 'Sarah', service: 'Cut' },              // absent
    { business: 'Cubbly', customer: 'Sarah', service: 'Cut', when: '' },     // empty
    { business: 'Cubbly', customer: 'Sarah', service: 'Cut', when: '   ' },  // whitespace
    { business: 'Cubbly', customer: 'Sarah', service: 'Cut', when: null },
  ]) {
    const bound = bindTemplateParameters(DESCRIPTORS, values);
    assert.equal(bound.ok, false);
    assert.equal(bound.reason, 'parameter_missing');
    assert.deepEqual(bound.missing, ['when']);
  }
});

test('newlines and tabs are flattened — Meta rejects them inside a parameter', () => {
  const bound = bindTemplateParameters([{ key: 'note' }], { note: 'line one\nline\ttwo   spaced' });
  assert.equal(bound.ok, true);
  assert.equal(bound.parameters[0].text, 'line one line two spaced');
});

test('a malformed descriptor list is refused, not silently skipped', () => {
  for (const bad of [null, 'nope', [{ nokey: 1 }], [''], [{ key: '' }]]) {
    assert.equal(bindTemplateParameters(bad, { a: 1 }).ok, false);
  }
});

/* ------------------------------------------------------------ assembly ---- */

test('a valid template send assembles exactly what the Cloud API expects', () => {
  const built = buildTemplateSend({
    toE164: '6582088809',
    templateName: 'peekaa_appointment_reminder',
    languageCode: 'en',
    parameters: [{ type: 'text', text: 'Cubbly Salon' }],
  });
  assert.equal(built.ok, true);
  assert.deepEqual(built.body, {
    messaging_product: 'whatsapp',
    recipient_type: 'individual',
    to: '6582088809',
    type: 'template',
    template: {
      name: 'peekaa_appointment_reminder',
      language: { code: 'en' },
      components: [{ type: 'body', parameters: [{ type: 'text', text: 'Cubbly Salon' }] }],
    },
  });
});

test('a template with no variables omits components entirely', () => {
  const built = buildTemplateSend({
    toE164: '6582088809', templateName: 'peekaa_generic', languageCode: 'zh_CN', parameters: [],
  });
  assert.equal(built.ok, true);
  assert.equal('components' in built.body.template, false);
});

test('a bad recipient, template name or language is refused before any network call', () => {
  const base = { toE164: '6582088809', templateName: 'peekaa_ok', languageCode: 'en', parameters: [] };
  const cases = [
    [{ ...base, toE164: '+6582088809' }, 'recipient_invalid'],
    [{ ...base, toE164: '0582088809' }, 'recipient_invalid'],
    [{ ...base, toE164: '' }, 'recipient_invalid'],
    [{ ...base, templateName: 'Peekaa_Bad_Case' }, 'template_name_invalid'],
    [{ ...base, templateName: 'has spaces' }, 'template_name_invalid'],
    [{ ...base, templateName: '' }, 'template_name_invalid'],
    [{ ...base, languageCode: 'english' }, 'language_code_invalid'],
    [{ ...base, languageCode: '' }, 'language_code_invalid'],
  ];
  for (const [input, reason] of cases) {
    const built = buildTemplateSend(input);
    assert.equal(built.ok, false);
    assert.equal(built.reason, reason, JSON.stringify(input));
  }
});

/* ------------------------------------------------------ classification ---- */

test('a 200 with a wamid is sent; a 200 WITHOUT one is a fault, not a success', () => {
  const good = classifyMetaResponse(200, { messages: [{ id: 'wamid.ABC' }] });
  assert.equal(good.disposition, 'sent');
  assert.equal(good.wamid, 'wamid.ABC');

  // Without a wamid the status webhook can never correlate this message, so it
  // would be invisible forever. Marking it sent would be a lie.
  const blind = classifyMetaResponse(200, { messages: [] });
  assert.equal(blind.disposition, 'failed');
  assert.equal(blind.code, 'accepted_without_wamid');
});

test('each Meta error class routes to the right owner', () => {
  const cases = [
    [131026, 'undeliverable', 'recipient not on WhatsApp — only the merchant can fix the number'],
    [132001, 'template_fault', 'our template — the merchant cannot fix this'],
    [133010, 'template_fault', 'template not approved'],
    [190, 'config_fault', 'expired token — every tenant is about to fail'],
    [131031, 'config_fault', 'account locked'],
    [130429, 'retry', 'rate limited'],
    [131056, 'retry', 'pair rate limit'],
  ];
  for (const [code, expected, why] of cases) {
    const got = classifyMetaResponse(400, { error: { code, type: 'OAuthException' } });
    assert.equal(got.disposition, expected, `${code}: ${why}`);
    assert.equal(got.code, String(code));
  }
});

test('HTTP class decides when Meta sends no code — 429/5xx retry, other 4xx do not', () => {
  assert.equal(classifyMetaResponse(429, {}).disposition, 'retry');
  assert.equal(classifyMetaResponse(500, {}).disposition, 'retry');
  assert.equal(classifyMetaResponse(503, {}).disposition, 'retry');
  // Retrying a request Meta rejected on its merits only burns quota.
  assert.equal(classifyMetaResponse(400, {}).disposition, 'failed');
  assert.equal(classifyMetaResponse(403, {}).disposition, 'failed');
  assert.equal(classifyMetaResponse(404, {}).disposition, 'failed');
});

test('the classifier never carries Meta error prose, which can echo a phone number', () => {
  const got = classifyMetaResponse(400, {
    error: {
      code: 131026, type: 'OAuthException',
      message: 'Message undeliverable to +6591234567',
      error_data: { details: 'recipient +6591234567 is not a WhatsApp user' },
    },
  });
  const serialised = JSON.stringify(got);
  assert.ok(!serialised.includes('6591234567'), 'a recipient number must not survive classification');
  assert.ok(!serialised.includes('undeliverable to'), 'raw Meta prose must not be persisted');
  assert.equal(got.code, '131026');
  assert.equal(got.metaType, 'OAuthException');
});

test('a transport throw is retryable — the message may in fact have reached Meta', () => {
  const got = classifyTransportError();
  assert.equal(got.disposition, 'retry');
  assert.equal(got.code, 'transport_error');
  assert.equal(consumesQuota(got.disposition), false);
});

test('Retry-After is honoured and bounded', () => {
  assert.equal(parseRetryAfter(new Headers({ 'retry-after': '42' })), 42);
  assert.equal(parseRetryAfter(new Headers({ 'retry-after': '99999' })), 3600);
  assert.equal(parseRetryAfter(new Headers({})), null);
  assert.equal(parseRetryAfter(new Headers({ 'retry-after': 'soon' })), null);
  assert.equal(parseRetryAfter(new Headers({ 'retry-after': '-5' })), null);
});

/* ------------------------------------------------------------- outcome ---- */

test('ONLY a genuine send consumes quota', () => {
  assert.equal(consumesQuota('sent'), true);
  for (const d of ['retry', 'undeliverable', 'template_fault', 'config_fault', 'failed']) {
    assert.equal(consumesQuota(d), false, `${d} must never charge the merchant`);
  }
});

test('every disposition except retry is terminal', () => {
  assert.equal(isTerminal('retry'), false);
  for (const d of ['sent', 'undeliverable', 'template_fault', 'config_fault', 'failed']) {
    assert.equal(isTerminal(d), true, d);
  }
});

test('backoff grows, is capped, and never goes below what Meta asked for', () => {
  const delays = [0, 1, 2, 3, 4].map((a) => nextAttemptDelaySeconds(a, null, 0));
  assert.deepEqual(delays, [15, 30, 60, 120, 240]);
  assert.ok(nextAttemptDelaySeconds(99, null, 0) <= 300 + 7, 'capped');
  // Meta asking for longer wins over our own schedule.
  assert.equal(nextAttemptDelaySeconds(0, 600, 0), 600);
  // Our schedule wins when it is already longer.
  assert.equal(nextAttemptDelaySeconds(4, 10, 0), 240);
});

test('retries are bounded and exhaustion is a NAMED state, not a bare failure', () => {
  assert.equal(shouldRetry('retry', 0), true);
  assert.equal(shouldRetry('retry', MAX_ATTEMPTS - 1), true);
  assert.equal(shouldRetry('retry', MAX_ATTEMPTS), false);
  assert.equal(shouldRetry('undeliverable', 0), false);

  const exhausted = resolveOutcome({ disposition: 'retry', code: '130429' }, MAX_ATTEMPTS);
  assert.equal(exhausted.status, 'failed_retries_exhausted');
  assert.equal(exhausted.consumeQuota, false);
  assert.equal(exhausted.code, '130429');
});

test('resolveOutcome is the whole state machine, and only sent charges', () => {
  const sent = resolveOutcome({ disposition: 'sent', code: null }, 0);
  assert.deepEqual(sent, { status: 'sent', consumeQuota: true, retryInSeconds: null, code: null });

  const soon = resolveOutcome({ disposition: 'retry', code: '1', retryAfterSeconds: null }, 1);
  assert.equal(soon.status, 'retry');
  assert.ok(soon.retryInSeconds >= 30);
  assert.equal(soon.consumeQuota, false);

  for (const d of ['undeliverable', 'template_fault', 'config_fault', 'failed']) {
    const out = resolveOutcome({ disposition: d, code: 'x' }, 0);
    assert.equal(out.status, d);
    assert.equal(out.retryInSeconds, null);
    assert.equal(out.consumeQuota, false);
  }
});

/* ----------------------------------------------- real transport exercise -- */

async function withServer(handler, run) {
  const server = createServer(handler);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  try {
    return await run(`http://127.0.0.1:${server.address().port}`);
  } finally {
    await new Promise((r) => server.close(r));
  }
}

test('the whole send path runs against a real server: request bytes out, disposition in', async () => {
  let observed = null;
  await withServer((req, res) => {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      observed = { method: req.method, url: req.url, auth: req.headers.authorization, body: JSON.parse(body) };
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ messages: [{ id: 'wamid.LIVE' }] }));
    });
  }, async (base) => {
    const built = buildTemplateSend({
      toE164: toE164('82088809'),
      templateName: 'peekaa_appointment_reminder',
      languageCode: 'en',
      parameters: bindTemplateParameters(DESCRIPTORS, {
        business: 'Cubbly Salon', customer: 'Sarah', service: 'Hair Treatment', when: '26 Aug, 3:00 PM',
      }).parameters,
    });
    assert.equal(built.ok, true);
    const response = await fetch(`${base}${sendPath('222222222222222')}`, {
      method: 'POST',
      headers: { authorization: 'Bearer test-token', 'content-type': 'application/json' },
      body: JSON.stringify(built.body),
    });
    const classified = classifyMetaResponse(response.status, await response.json(), response.headers);
    assert.equal(classified.disposition, 'sent');
    assert.equal(classified.wamid, 'wamid.LIVE');
  });

  assert.equal(observed.method, 'POST');
  assert.equal(observed.url, '/v21.0/222222222222222/messages');
  assert.equal(observed.body.to, '6582088809');
  assert.equal(observed.body.template.name, 'peekaa_appointment_reminder');
  assert.deepEqual(observed.body.template.components[0].parameters.map((p) => p.text),
    ['Cubbly Salon', 'Sarah', 'Hair Treatment', '26 Aug, 3:00 PM']);
});

test('a real 429 with Retry-After produces a retry that waits at least that long', async () => {
  await withServer((req, res) => {
    res.writeHead(429, { 'content-type': 'application/json', 'retry-after': '90' });
    res.end(JSON.stringify({ error: { code: 130429, type: 'OAuthException' } }));
  }, async (base) => {
    const response = await fetch(`${base}/v21.0/1/messages`, { method: 'POST', body: '{}' });
    const classified = classifyMetaResponse(response.status, await response.json(), response.headers);
    assert.equal(classified.disposition, 'retry');
    assert.equal(classified.retryAfterSeconds, 90);
    assert.ok(resolveOutcome(classified, 0).retryInSeconds >= 90);
  });
});

test('a real 401 from an expired token is a config fault, never a retry loop', async () => {
  await withServer((req, res) => {
    res.writeHead(401, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: { code: 190, type: 'OAuthException' } }));
  }, async (base) => {
    const response = await fetch(`${base}/v21.0/1/messages`, { method: 'POST', body: '{}' });
    const classified = classifyMetaResponse(response.status, await response.json(), response.headers);
    assert.equal(classified.disposition, 'config_fault');
    // Critical: a bad token must NOT burn five attempts per message across every tenant.
    assert.equal(resolveOutcome(classified, 0).retryInSeconds, null);
  });
});

/* --------------------------------------------------------------- fences --- */

test('no WhatsApp secret name appears in any browser-served bundle', () => {
  const names = [
    'WHATSAPP_ACCESS_TOKEN', 'WHATSAPP_APP_SECRET', 'WHATSAPP_WEBHOOK_VERIFY_TOKEN',
    'WHATSAPP_PHONE_NUMBER_ID', 'WHATSAPP_BUSINESS_ACCOUNT_ID',
  ];
  const bundles = [
    'app/app.js', 'app/app-core.js', 'app/app-business.js', 'app/app-customer.js',
    'app/app-auth.js', 'app/platform-console.js', 'app/index.html', 'app/runtime-config.js',
  ];
  for (const bundle of bundles) {
    const source = readFileSync(resolve(ROOT, bundle), 'utf8');
    for (const name of names) {
      assert.ok(!source.includes(name), `${name} must not appear in ${bundle}`);
    }
  }
});

test('the send module names no credential and no host of its own', () => {
  // The host and every secret are supplied by the caller from server-side env.
  // Keeping them out of this module is what lets it be imported by a test.
  const source = readFileSync(
    resolve(ROOT, 'supabase/functions/_shared/whatsapp-send-boundaries.mjs'), 'utf8');
  for (const forbidden of [
    'graph.facebook.com', 'WHATSAPP_ACCESS_TOKEN', 'WHATSAPP_PHONE_NUMBER_ID', 'Deno.env',
  ]) {
    assert.ok(!source.includes(forbidden), `${forbidden} does not belong in a pure boundaries module`);
  }
});
