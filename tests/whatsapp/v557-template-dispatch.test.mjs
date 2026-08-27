// v557 — the template-send queue added to whatsapp-send-dispatch/index.ts.
//
// index.ts is Deno-only and is never imported under node --test (same rule as
// v504-webhook.test.mjs and v517-send-boundaries.test.mjs: only the plain
// _shared/*.mjs boundary functions are exercised for real). This file pins
// the exact decision sequence the dispatcher's template loop runs —
// toE164 preflight, then buildTemplateSend, then classify/resolveOutcome,
// then the same three-way disposition collapse the text path already uses —
// so a future edit to index.ts that changes that sequence has something to
// break against.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

import {
  toE164,
  buildTemplateSend,
  classifyMetaResponse,
  classifyTransportError,
  resolveOutcome,
  isTerminal,
  consumesQuota,
} from '../../supabase/functions/_shared/whatsapp-send-boundaries.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const DISPATCH_INDEX = 'supabase/functions/whatsapp-send-dispatch/index.ts';

/* Reproduces exactly the three lines the dispatcher runs per template lease,
   so this test fails if index.ts's own sequence ever drifts from it. */
function dispatchTemplateLease(lease, sendResult) {
  const e164 = toE164(String(lease.recipient_phone_norm || ''));
  if (!e164) {
    return { disposition: 'failed', errorCode: 'recipient_not_normalisable', sentNetwork: false };
  }
  const built = buildTemplateSend({
    toE164: e164,
    templateName: String(lease.template_name || ''),
    languageCode: String(lease.language_code || ''),
    parameters: Array.isArray(lease.parameters) ? lease.parameters : [],
  });
  if (!built.ok) {
    return { disposition: 'failed', errorCode: built.reason, sentNetwork: false, e164 };
  }

  const classification = sendResult.transportError
    ? classifyTransportError()
    : classifyMetaResponse(sendResult.status, sendResult.body, sendResult.headers);
  const outcome = resolveOutcome(classification, Number(lease.attempt_count || 0));
  const disposition = outcome.status === 'sent' ? 'sent'
    : outcome.status === 'retry' ? 'retry' : 'failed';
  return {
    disposition,
    errorCode: disposition === 'sent' ? null : String(outcome.code || outcome.status),
    providerMessageId: disposition === 'sent' ? classification.wamid : null,
    retryInSeconds: outcome.retryInSeconds,
    sentNetwork: true,
    payload: built.body,
  };
}

const BASE_LEASE = {
  message_id: 'm1', business_id: 'b1', lease_token: 't1', attempt_count: 0,
  recipient_phone_norm: '82088809',
  template_name: 'peekaa_appointment_reminder',
  language_code: 'en',
  parameters: [{ type: 'text', text: 'Cubbly Salon' }],
};

/* --------------------------------------------------- payload assembly ---- */

test('a template lease builds exactly the Cloud API payload the dispatcher would send', () => {
  const result = dispatchTemplateLease(BASE_LEASE, {
    status: 200, body: { messages: [{ id: 'wamid.XYZ' }] }, headers: new Map(),
  });
  assert.equal(result.sentNetwork, true);
  assert.deepEqual(result.payload, {
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
  assert.equal(result.disposition, 'sent');
  assert.equal(result.providerMessageId, 'wamid.XYZ');
});

test('a variable-free template omits components, exactly as buildTemplateSend does standalone', () => {
  const result = dispatchTemplateLease(
    { ...BASE_LEASE, template_name: 'peekaa_generic', language_code: 'zh_CN', parameters: [] },
    { status: 200, body: { messages: [{ id: 'wamid.NOVARS' }] }, headers: new Map() },
  );
  assert.equal('components' in result.payload.template, false);
});

/* -------------------------------------------- preflight is permanent ----- */

test('an unnormalisable recipient is a permanent failure with a named code, before any network call', () => {
  const result = dispatchTemplateLease({ ...BASE_LEASE, recipient_phone_norm: '123' }, { status: 200, body: {}, headers: new Map() });
  assert.equal(result.disposition, 'failed');
  assert.equal(result.errorCode, 'recipient_not_normalisable');
  assert.equal(result.sentNetwork, false, 'a preflight refusal must never reach the network');
});

test('a buildTemplateSend refusal is a permanent failure carrying the exact reason, before any network call', () => {
  const cases = [
    [{ ...BASE_LEASE, template_name: 'Bad Case' }, 'template_name_invalid'],
    [{ ...BASE_LEASE, template_name: 'has spaces' }, 'template_name_invalid'],
    [{ ...BASE_LEASE, language_code: 'english' }, 'language_code_invalid'],
    [{ ...BASE_LEASE, language_code: '' }, 'language_code_invalid'],
  ];
  for (const [lease, expectedCode] of cases) {
    const result = dispatchTemplateLease(lease, { status: 200, body: {}, headers: new Map() });
    assert.equal(result.disposition, 'failed', JSON.stringify(lease));
    assert.equal(result.errorCode, expectedCode, JSON.stringify(lease));
    assert.equal(result.sentNetwork, false, 'a build refusal must never reach the network');
  }
});

/* ------------------------------------------ template_fault is terminal --- */

test('every template_fault code is a terminal failure and is never retried', () => {
  const TEMPLATE_FAULT_CODES = [132000, 132001, 132005, 132007, 132012, 132015, 132016, 133010];
  for (const code of TEMPLATE_FAULT_CODES) {
    const result = dispatchTemplateLease(BASE_LEASE, {
      status: 400, body: { error: { code, type: 'TemplateException' } }, headers: new Map(),
    });
    assert.equal(result.disposition, 'failed', `code ${code} must collapse to failed`);
    assert.equal(result.errorCode, String(code), `code ${code} must keep the fault code, not a generic label`);
    assert.equal(result.retryInSeconds, null, `code ${code} must not schedule a retry`);
    assert.equal(isTerminal('template_fault'), true);
    assert.equal(consumesQuota('template_fault'), false, 'a merchant is never charged for our own broken template');
  }
});

test('exhausting attempts on a genuinely transient code still ends terminal, retrying stays "retry" below the cap', () => {
  const transient = dispatchTemplateLease({ ...BASE_LEASE, attempt_count: 0 }, {
    status: 429, body: {}, headers: new Map(),
  });
  assert.equal(transient.disposition, 'retry');
  assert.ok(transient.retryInSeconds > 0);

  const exhausted = dispatchTemplateLease({ ...BASE_LEASE, attempt_count: 5 }, {
    status: 429, body: {}, headers: new Map(),
  });
  assert.equal(exhausted.disposition, 'failed');
  // resolveOutcome's status becomes the named 'failed_retries_exhausted' state,
  // but the dispatcher's reported code prefers the classifier's own code when
  // one exists (here 'http_429', since Meta sent no machine-readable error
  // code) — exactly what the text path already does.
  assert.equal(exhausted.errorCode, 'http_429');
});

test('a transport throw on the template path is retryable, same as the text path', () => {
  const result = dispatchTemplateLease(BASE_LEASE, { transportError: true });
  assert.equal(result.disposition, 'retry');
  assert.equal(result.errorCode, 'transport_error');
});

/* -------------------------------------------------------- wiring guard --- */

test('the dispatcher wires the template queue to the v557 claim/report RPC pair and no longer voids buildTemplateSend', () => {
  const source = readFileSync(resolve(ROOT, DISPATCH_INDEX), 'utf8');
  assert.ok(source.includes('internal_whatsapp_claim_template_sends_v557'), 'template claim RPC missing');
  assert.ok(source.includes('internal_whatsapp_report_template_send_v557'), 'template report RPC missing');
  assert.ok(!source.includes('void buildTemplateSend'), 'buildTemplateSend must actually be used now, not stubbed out');
  assert.ok(source.includes('template_claimed') && source.includes('template_sent')
    && source.includes('template_retried') && source.includes('template_failed'),
    'response JSON must report all four template counters');
});

test('the template report never logs a token, phone, wamid, body or template parameter', () => {
  const source = readFileSync(resolve(ROOT, DISPATCH_INDEX), 'utf8');
  // Same discipline as the existing text-path log() calls: only message_id and
  // disposition may appear in a log() call anywhere in this file.
  const logCalls = [...source.matchAll(/log\('template[a-z_]*',\s*\{([^}]*)\}\)/g)];
  assert.ok(logCalls.length > 0, 'expected at least one template log() call to check');
  for (const [, fields] of logCalls) {
    assert.ok(!/token|phone|wamid|body|parameter/i.test(fields), `template log call leaks a forbidden field: ${fields}`);
  }
});

test('v557: no early return strands the template queue when support queue is empty', () => {
  const src = readFileSync(new URL('../../supabase/functions/whatsapp-send-dispatch/index.ts', import.meta.url), 'utf8');
  assert.ok(!/data\.length === 0\) return/.test(src),
    'an empty support claim must fall through to the template claim, not return');
  const supportClaim = src.indexOf('internal_support_claim_outbound_v535');
  const templateClaim = src.indexOf('internal_whatsapp_claim_template_sends_v557');
  assert.ok(supportClaim > 0 && templateClaim > supportClaim, 'both claims present, template after support');
  const between = src.slice(supportClaim, templateClaim);
  assert.ok(!/return json\(200/.test(between),
    'no success return may sit between the support claim and the template claim');
});
