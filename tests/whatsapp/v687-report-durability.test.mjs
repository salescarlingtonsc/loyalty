/* Audit F126 — whatsapp-send-dispatch/index.ts fired the outcome RPC and walked away:
 *
 *     await admin.rpc('internal_support_report_outbound_v535', { ... });
 *     if (disposition === 'sent') sent += 1;
 *
 * with no `{ error }` destructured and no try/catch. By the time that line runs Meta has already
 * accepted the message and the customer's phone has already buzzed, and this write is the ONLY
 * record of it. If it failed — a blip to Postgres, a PostgREST timeout, a pooler hiccup — the row
 * stayed status='processing', its 120s lease expired, and internal_support_claim_outbound_v535
 * re-claims any row whose lease has expired regardless of how many times it was attempted. The
 * next cron run sent the same WhatsApp message to the same customer again.
 *
 * Fix (v687): every report goes through reportSendOutcome — bounded retries with backoff, a
 * named non-retryable case for the two codes that can never change (40001 stale lease, P0002 row
 * gone), and a counted, logged, returned failure when it still cannot be written.
 *
 * index.ts is Deno-only and is never imported under node --test (same rule as v504/v517/v557),
 * so the decision itself lives in _shared/whatsapp-send-boundaries.mjs and is EXECUTED here for
 * real, with an injected rpc and an injected clock. The source pins at the bottom only guard the
 * wiring the executed function cannot see.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

import {
  REPORT_ATTEMPTS,
  REPORT_BACKOFF_MS,
  reportFailureCode,
  reportRetryable,
  reportSendOutcome,
} from '../../supabase/functions/_shared/whatsapp-send-boundaries.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const DISPATCH_INDEX = 'supabase/functions/whatsapp-send-dispatch/index.ts';

// A supabase-js-shaped rpc: resolves { data, error } rather than throwing.
function rpcThatFails(times, error = { code: '57014', message: 'canceling statement due to statement timeout' }) {
  const calls = [];
  let remaining = times;
  return {
    calls,
    rpc: async (name, args) => {
      calls.push({ name, args });
      if (remaining > 0) { remaining -= 1; return { data: null, error }; }
      return { data: { status: 'ok' }, error: null };
    },
  };
}

const noSleep = () => Promise.resolve();

test('F126: a report that succeeds first time costs exactly one call', async () => {
  const { rpc, calls } = rpcThatFails(0);
  const result = await reportSendOutcome(rpc, 'internal_support_report_outbound_v535',
    { p_message: 'm1', p_disposition: 'sent' }, { sleep: noSleep });

  assert.equal(result.ok, true);
  assert.equal(result.attempts, 1);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].name, 'internal_support_report_outbound_v535');
});

test('F126: a transient database failure is retried and the outcome IS persisted — the whole point', async () => {
  const { rpc, calls } = rpcThatFails(2);
  const slept = [];
  const result = await reportSendOutcome(rpc, 'internal_support_report_outbound_v535',
    { p_message: 'm2', p_disposition: 'sent', p_provider_message_id: 'wamid.x' },
    { sleep: ms => { slept.push(ms); return Promise.resolve(); } });

  assert.equal(result.ok, true, 'a blip must not leave the send unrecorded and re-claimable');
  assert.equal(result.attempts, 3);
  assert.equal(calls.length, 3);
  assert.deepEqual(slept, REPORT_BACKOFF_MS.slice(0, 2), 'backoff must widen between attempts');
  // Every attempt must carry the SAME arguments — a retry that dropped the wamid would persist a
  // 'sent' row the status webhook can never match.
  for (const call of calls) assert.equal(call.args.p_provider_message_id, 'wamid.x');
});

test('F126: a rpc that THROWS is treated as a failed attempt, not as an unhandled rejection', async () => {
  let calls = 0;
  const rpc = async () => {
    calls += 1;
    if (calls === 1) throw new Error('fetch failed');
    return { data: {}, error: null };
  };
  const result = await reportSendOutcome(rpc, 'fn', {}, { sleep: noSleep });
  assert.equal(result.ok, true);
  assert.equal(calls, 2);
});

test('F126: the whole retry budget stays well inside the 120s lease the worker still holds', () => {
  const total = REPORT_BACKOFF_MS.slice(0, REPORT_ATTEMPTS - 1).reduce((a, b) => a + b, 0);
  assert.ok(total < 30000,
    `report retries must not outlive the lease: ${total}ms of backoff before another worker can re-claim`);
  assert.ok(REPORT_ATTEMPTS >= 2, 'a single attempt is the defect');
});

test('F126: a stale lease is NOT retried — another worker owns the row and the answer cannot change', async () => {
  const { rpc, calls } = rpcThatFails(99, { code: '40001', message: 'stale lease' });
  const result = await reportSendOutcome(rpc, 'fn', {}, { sleep: noSleep });

  assert.equal(result.ok, false);
  assert.equal(result.retryable, false);
  assert.equal(calls.length, 1, 'retrying a stale lease only burns the lease we are racing');
  assert.equal(reportRetryable({ code: '40001' }), false);
  assert.equal(reportRetryable({ code: 'P0002' }), false);
  assert.equal(reportRetryable({ code: '57014' }), true);
});

test('F126: when the outcome still cannot be written the caller is TOLD, with a code and no PII', async () => {
  const { rpc, calls } = rpcThatFails(99);
  const result = await reportSendOutcome(rpc, 'fn', { p_provider_message_id: 'wamid.secret' },
    { sleep: noSleep });

  assert.equal(result.ok, false, 'silence here is exactly what F126 was');
  assert.equal(result.attempts, REPORT_ATTEMPTS);
  assert.equal(calls.length, REPORT_ATTEMPTS);
  const code = reportFailureCode(result.error);
  assert.equal(code, '57014');
  assert.ok(!code.includes('wamid'), 'the wamid decodes to the customer phone number and must never be logged');
  assert.equal(reportFailureCode({}), 'report_write_failed');
});

/* The wiring the executed function cannot see: that index.ts actually routes every report
   through it and no longer has a bare fire-and-forget report call. */
test('F126: index.ts routes every outcome report through reportSendOutcome', () => {
  const source = readFileSync(resolve(ROOT, DISPATCH_INDEX), 'utf8');
  const code = source.replace(/\/\*[\s\S]*?\*\//g, '');

  assert.ok(code.includes('reportSendOutcome'), 'the dispatcher must import and use reportSendOutcome');

  // Not one `await admin.rpc('internal_..._report_...')` may survive: that is the defect verbatim.
  const bare = [...code.matchAll(/await\s+admin\.rpc\(\s*'([a-z0-9_]*report[a-z0-9_]*)'/g)].map(m => m[1]);
  assert.deepEqual(bare, [], `these report RPCs are still fire-and-forget: ${bare.join(', ')}`);

  /* All five report sites go through the helper: the support queue's preflight refusal and its
     outcome, and the template queue's two preflight refusals (unnormalisable recipient, unbuildable
     template) plus its outcome. */
  const routed = [...code.matchAll(/await\s+report\(\s*'([a-z0-9_]+)'/g)].map(m => m[1]);
  assert.equal(routed.length, 5, `expected 5 routed report calls, saw ${routed.length}`);
  assert.equal(routed.filter(n => n === 'internal_support_report_outbound_v535').length, 2);
  assert.equal(routed.filter(n => n === 'internal_whatsapp_report_template_send_v557').length, 3);

  // The failure has to be observable, not just handled.
  assert.ok(/unreported\s*\+=\s*1/.test(code), 'an unpersisted outcome must be counted');
  assert.ok(/unreported,/.test(code), 'the count must be returned in the dispatcher response');
});

test('F126: the unpersisted-outcome log line still carries no wamid, body or recipient', () => {
  const source = readFileSync(resolve(ROOT, DISPATCH_INDEX), 'utf8');
  /* The helper logs under an injected event name ('report_failed' / 'template_report_failed'),
     so the line to inspect is `log(event, { ... })` inside it. */
  const logCalls = [...source.matchAll(/log\(event,\s*\{([\s\S]*?)\n\s*\}\)/g)];
  assert.equal(logCalls.length, 1, 'the dispatcher must log exactly once when it cannot persist an outcome');
  assert.ok(/'report_failed'/.test(source) && /'template_report_failed'/.test(source),
    'both queues must name their own unpersisted-outcome event');
  for (const [, body] of logCalls) {
    for (const forbidden of ['wamid', 'rendered', 'recipient', 'e164', 'phone', 'token']) {
      assert.ok(!body.includes(forbidden), `report_failed log leaks ${forbidden}`);
    }
  }
});
