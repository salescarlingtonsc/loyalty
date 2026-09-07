/* nestly_v816 — an outcome the database never learned can never be sent again.
 *
 * nestly_v687 made the outcome write durable and then said, in the dispatcher's own return
 * value, that it could not close the residual:
 *
 *   "Non-zero means at least one outcome Meta gave us was never written down, so at least one
 *    row is still 'processing' with a lease that will expire and be re-claimed — i.e. a
 *    duplicate is coming. Closing that residual for good needs a queue that can record 'sent,
 *    unconfirmed' … which is a schema decision for the owner."
 *
 * The owner made it: a possibly-undelivered message is preferred to a duplicate WhatsApp. So
 * when reportSendOutcome finally gives up on a 'sent' disposition the worker no longer walks
 * away leaving the row re-claimable — it calls the quarantine RPC, which moves the row to the
 * terminal 'sent_unconfirmed' that neither claim RPC will ever return.
 *
 * index.ts is Deno-only and is never imported under node --test (the v504/v517/v557/v687 rule),
 * so the decisions live in _shared/whatsapp-send-boundaries.mjs and are EXECUTED here with an
 * injected rpc and an injected clock. The source pins at the bottom guard only the wiring the
 * executed functions cannot see.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

import {
  QUARANTINE_SEND_FN,
  REPORT_ATTEMPTS,
  quarantineArgs,
  quarantineSend,
  reportFailureCode,
  shouldQuarantineUnreported,
} from '../../supabase/functions/_shared/whatsapp-send-boundaries.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const DISPATCH_INDEX = 'supabase/functions/whatsapp-send-dispatch/index.ts';
const noSleep = () => Promise.resolve();

function rpcThatFails(times, error = { code: '57014', message: 'statement timeout' }) {
  const calls = [];
  let remaining = times;
  return {
    calls,
    rpc: async (name, args) => {
      calls.push({ name, args });
      if (remaining > 0) { remaining -= 1; return { data: null, error }; }
      return { data: { status: 'ok', quarantined: true }, error: null };
    },
  };
}

/* ------------------------------------------------------------------ when to quarantine */

test('v816: only an unreported SENT outcome is quarantined', () => {
  // Meta took it and we could not write that down: the row must never be re-claimable.
  assert.equal(shouldQuarantineUnreported('sent', false), true);
  // A report that landed changes nothing — the row is already terminal in the database.
  assert.equal(shouldQuarantineUnreported('sent', true), false);
  // A 'retry' left in flight is SUPPOSED to be tried again, and a 'failed' we could not write
  // was never delivered. Retiring either as "sent, unconfirmed" would be a lie; the expired
  // lease sweep is where a vanished worker's rows belong.
  assert.equal(shouldQuarantineUnreported('retry', false), false);
  assert.equal(shouldQuarantineUnreported('failed', false), false);
});

/* --------------------------------------------------------------- what it sends to Postgres */

test('v816: the quarantine call names the queue, the message and the lease it holds', () => {
  const args = quarantineArgs({
    queue: 'template', messageId: 'm-1', leaseToken: 'lease-1', workerId: 'worker-1',
  });
  assert.deepEqual(args, {
    p_queue: 'template',
    p_message: 'm-1',
    p_lease_token: 'lease-1',
    // Default reason — this call site exists for exactly one failure mode.
    p_reason: 'report_write_failed',
    p_worker_id: 'worker-1',
  });
  // An empty lease must arrive as SQL NULL, not as the string '', or the RPC's
  // `lease_token is distinct from p_lease_token` check would compare against a cast error.
  assert.equal(quarantineArgs({ queue: 'support', messageId: 'm', leaseToken: '' }).p_lease_token, null);
});

/* ------------------------------------------------------------------- durability, executed */

test('v816: quarantine goes through the same bounded-retry machinery as the report', async () => {
  const { rpc, calls } = rpcThatFails(2);
  const slept = [];
  const result = await quarantineSend(rpc, quarantineArgs({
    queue: 'support', messageId: 'm-2', leaseToken: 'lease-2', workerId: 'w',
  }), { sleep: ms => { slept.push(ms); return Promise.resolve(); } });

  assert.equal(result.ok, true, 'a blip must not leave the row re-claimable');
  assert.equal(calls.length, 3);
  assert.equal(calls[0].name, QUARANTINE_SEND_FN);
  assert.equal(slept.length, 2, 'the retries must back off, not hammer');
  // Every attempt carries the same lease: a retry that dropped it would be refused with 40001.
  for (const call of calls) assert.equal(call.args.p_lease_token, 'lease-2');
});

test('v816: a lost lease is NOT retried — this worker no longer decides that row', async () => {
  const { rpc, calls } = rpcThatFails(99, { code: '40001', message: 'stale lease' });
  const result = await quarantineSend(rpc, quarantineArgs({
    queue: 'support', messageId: 'm-3', leaseToken: 'lease-3',
  }), { sleep: noSleep });

  assert.equal(result.ok, false);
  assert.equal(result.retryable, false);
  assert.equal(calls.length, 1);
});

test('v816: when even the quarantine cannot be written the caller is told, with no PII', async () => {
  const { rpc, calls } = rpcThatFails(99);
  const result = await quarantineSend(rpc, quarantineArgs({
    queue: 'support', messageId: 'm-4', leaseToken: 'lease-4',
  }), { sleep: noSleep });

  assert.equal(result.ok, false, 'silence is the defect v687 named');
  assert.equal(calls.length, REPORT_ATTEMPTS);
  const code = reportFailureCode(result.error);
  assert.equal(code, '57014');
  assert.ok(!code.includes('wamid'), 'the wamid decodes to the customer phone number');
  /* And the row is still safe: it keeps its expired lease, so the NEXT run's sweep retires it.
     The one thing that can no longer happen is a second send. */
});

/* ------------------------------------------------------- the wiring the functions cannot see */

test('v816: the dispatcher quarantines an unreported send before releasing the row', () => {
  const source = readFileSync(resolve(ROOT, DISPATCH_INDEX), 'utf8');
  const code = source.replace(/\/\*[\s\S]*?\*\//g, '');

  assert.ok(code.includes('shouldQuarantineUnreported'),
    'the dispatcher must ask the boundary module, not re-derive the rule');
  assert.ok(code.includes('quarantineSend') && code.includes('quarantineArgs'),
    'the quarantine must go through the shared bounded-retry helper');

  /* It has to happen inside the report helper, AFTER the unreported count and the log line —
     i.e. on the failure path, never on the ok path. */
  const helper = code.slice(code.indexOf('const report = async'), code.indexOf('for (const lease of data'));
  assert.ok(helper.includes('if (result.ok) return true;'), 'the ok path must still return early');
  assert.ok(helper.indexOf('unreported += 1') < helper.indexOf('shouldQuarantineUnreported'),
    'an unpersisted outcome is still counted as unreported, and then quarantined');
  assert.ok(/quarantined\s*\+=\s*1/.test(helper), 'a successful quarantine must be counted');

  // Both lanes must pass their queue name, or the RPC cannot know which table to retire.
  const routed = [...code.matchAll(/await\s+report\(\s*'([a-z0-9_]+)'[\s\S]*?,\s*'(support|template)'\)/g)];
  assert.equal(routed.length, 5, `all five report sites must name their queue, saw ${routed.length}`);
  assert.equal(routed.filter(m => m[2] === 'support').length, 2);
  assert.equal(routed.filter(m => m[2] === 'template').length, 3);
});

test('v816: the expired-lease sweep runs BEFORE either claim, and its failure is not fatal', () => {
  const source = readFileSync(resolve(ROOT, DISPATCH_INDEX), 'utf8');
  const code = source.replace(/\/\*[\s\S]*?\*\//g, '');

  const sweep = code.indexOf('internal_whatsapp_quarantine_expired_sends_v816');
  const supportClaim = code.indexOf('internal_support_claim_outbound_v535');
  const templateClaim = code.indexOf('internal_whatsapp_claim_template_sends_v557');
  assert.ok(sweep > -1, 'the dispatcher must call the quarantine sweep');
  assert.ok(sweep < supportClaim && sweep < templateClaim,
    'a stranded row must be retired before anything is claimed');
  assert.ok(code.includes("log('quarantine_sweep_failed'"),
    'a sweep that fails must say so rather than disappear');
  assert.ok(!/sweepError[\s\S]{0,80}return json\(503/.test(code),
    'a failed sweep must not stop the run: both claim RPCs quarantine their own queue too');
});

test('v816: the response tells the operator how many messages were retired', () => {
  const source = readFileSync(resolve(ROOT, DISPATCH_INDEX), 'utf8');
  const response = source.slice(source.lastIndexOf('return json(200,'));
  for (const field of ['unreported,', 'quarantined,', 'quarantined_expired:']) {
    assert.ok(response.includes(field), `the cron response must carry ${field}`);
  }
});

test('v816: the quarantine log line carries no wamid, body, recipient or token', () => {
  const source = readFileSync(resolve(ROOT, DISPATCH_INDEX), 'utf8');
  const logCalls = [...source.matchAll(/log\('quarantine',\s*\{([\s\S]*?)\n\s*\}\)/g)];
  assert.equal(logCalls.length, 1, 'exactly one place logs a quarantine outcome');
  for (const [, body] of logCalls) {
    for (const forbidden of ['wamid', 'rendered', 'recipient', 'e164', 'phone', 'token']) {
      assert.ok(!body.includes(forbidden), `the quarantine log leaks ${forbidden}`);
    }
  }
});

/* ------------------------------------------------------------------------- the DB contract */

test('v816: the migration is the authority for the terminal state, and both mirrors match', () => {
  const db = readFileSync(
    resolve(ROOT, 'db/migrations/20261007_nestly_v816_whatsapp_sent_unconfirmed.sql'), 'utf8');
  const mirror = readFileSync(
    resolve(ROOT, 'supabase/migrations/20261007070000_nestly_v816_whatsapp_sent_unconfirmed.sql'), 'utf8');
  assert.equal(db, mirror, 'the two migration copies must be byte-identical');

  /* The claims must not re-claim 'processing' — that predicate IS the duplicate. Comments are
     stripped first: the header quotes the old predicate verbatim, which is the point of it. */
  const statements = db.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*--.*$/gm, '');
  assert.ok(!/status in \('queued','processing'\)/.test(statements),
    "no claim may still match status in ('queued','processing')");
  assert.ok(db.includes("when 'sent_unconfirmed' then 22"),
    'sent_unconfirmed must rank between sent (20) and failed (25)');
  // The reminder guard has to count it, or the duplicate returns through the enqueue door.
  assert.ok(/appointment_already_reminded_v581[\s\S]*?'sent_unconfirmed'/.test(db),
    'app.appointment_already_reminded_v581 must treat a quarantined reminder as already sent');
  assert.ok(db.includes(QUARANTINE_SEND_FN),
    'the migration must define the RPC the dispatcher calls');
});
