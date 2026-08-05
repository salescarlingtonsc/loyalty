import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* V170 error-message choke point. The first implementation gated pass-through on
   "starts with an uppercase letter", but ~96% of this codebase's own RPC messages are
   lowercase-first owner prose, so real sentences were discarded or actively mismapped
   ("no sessions remaining" -> "Your session expired"). The adversarial verifier proved it
   by execution; this test pins the corrected inverted design with those exact probes:
   pass through by default, rewrite only machine-noise signatures. */

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(resolve(repoRoot, 'app/index.html'), 'utf8');

const start = app.indexOf('const OWNER_ERROR_NOISE_RULES_V170');
assert.ok(start > 0, 'OWNER_ERROR_NOISE_RULES_V170 must exist');
const end = app.indexOf('const fail=', start);
assert.ok(end > start, 'fail() must follow ownerErrorText');
const source = app.slice(start, end);
const ownerErrorText = new Function(`${source}; return ownerErrorText;`)();

test('owner-authored RPC prose passes through verbatim, whatever its casing', () => {
  for (const message of [
    'choose Cash, Card, PayNow or Other',
    'no sessions remaining',
    'drawer session already closed',
    'a unique approved NON-SUBSCRIPTION transaction reference is required',
    'a reason of at least 10 characters is required to reclassify a historical sale',
    'You already have a manual-payment application with Peekaa. Nothing further is needed — the team will contact you, or ask Peekaa admin to activate your approved workspace.',
    'active clients-module write authorization is required',
    'stale_evaluation: catalog prices changed since evaluation; re-evaluate',
    'total_zero_not_supported: this checkout totals zero after discounts and cannot be recorded; re-price it',
  ]) {
    assert.equal(ownerErrorText({ message, code: '22023' }), message,
      `owner prose must survive verbatim: ${message.slice(0, 50)}`);
  }
});

test('machine noise is rewritten to owner language', () => {
  assert.equal(ownerErrorText({ message: 'duplicate key value violates unique constraint "clients_phone_norm_key"' }),
    'This already exists — no duplicate was created.');
  assert.equal(ownerErrorText({ message: 'null value in column "name" of relation "services" violates not-null constraint' }),
    "That change couldn't be saved. Check the details and try again.");
  assert.equal(ownerErrorText({ message: 'permission denied for table clients' }),
    "You don't have access to do that. Ask an owner to check your permissions.");
  assert.equal(ownerErrorText({ message: 'JWT expired' }),
    'Your session expired. Sign in again.');
  assert.equal(ownerErrorText({ message: 'TypeError: Failed to fetch' }),
    'Connection problem. Check your internet and try again.');
  assert.match(ownerErrorText({ message: "Could not find the function public.nope in the schema cache", code: 'PGRST202' }),
    /went wrong on our side/);
});

test('empty errors get the safe generic sentence', () => {
  assert.equal(ownerErrorText(null), 'Something went wrong. Nothing was changed.');
  assert.equal(ownerErrorText({}), 'Something went wrong. Nothing was changed.');
});
