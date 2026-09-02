/* CI-100 check 98 — "RPC failure, partial response, model failure and export failure show
 * explicit unavailable states — never zeros." This file covers the MODEL FAILURE half for the
 * AI firm report.
 *
 * supabase/functions/ai-firm-reports/index.ts's processQueue() used to fold every model-call
 * failure (a thrown network/API error, a timed-out request, a refusal, an empty narrative) into
 * one generic catch block that stored the raw SDK exception text as the failure reason — never a
 * blank/partial "ready" report, but also never a NAMED reason a caller (or a person reading the
 * platform console) could reliably branch or localise on.
 *
 * enforce.mjs's decideGenerationFailure() is the fix: a single, pure, dual-runtime function (same
 * pattern as decideNarrativeOutcome, already covered by v677/v706/v707/v712's own suites) that
 * classifies EITHER the thrown error OR the resolved-but-unusable response into one of four named
 * reasons — 'model_unavailable' | 'model_timeout' | 'malformed_output' | 'empty_narrative' — or
 * returns null when the response is genuinely usable. These tests execute it directly, the same
 * way tests/ai-reports/v677-evidence-safe-generation.test.mjs executes validateNarrative and
 * tests/ai-reports/v713-findings-ranked-binding.test.mjs and its siblings execute
 * decideNarrativeOutcome.
 */
import test from 'node:test';
import assert from 'node:assert/strict';

import { decideGenerationFailure } from '../../supabase/functions/ai-firm-reports/enforce.mjs';

function textResponse(text, stopReason = 'end_turn') {
  return { content: [{ type: 'text', text }], stop_reason: stopReason };
}

/* ---------------------------------------------------------------- a usable response is not a failure */

test('decideGenerationFailure: a normal, non-empty text response is NOT a failure (returns null)', () => {
  const outcome = decideGenerationFailure(textResponse('## Summary\nThe business grew.'));
  assert.equal(outcome, null);
});

test('decideGenerationFailure: multiple text blocks joined are still usable', () => {
  const outcome = decideGenerationFailure({
    content: [{ type: 'text', text: '## Summary' }, { type: 'text', text: 'More text.' }],
    stop_reason: 'end_turn',
  });
  assert.equal(outcome, null);
});

/* ---------------------------------------------------------------- malformed_output */

test('decideGenerationFailure: stop_reason "refusal" -> malformed_output, narrative_md null', () => {
  const outcome = decideGenerationFailure(textResponse('I cannot help with that.', 'refusal'));
  assert.deepEqual(outcome, { status: 'failed', narrative_md: null, failure_reason: 'malformed_output' });
});

test('decideGenerationFailure: missing content array -> malformed_output', () => {
  const outcome = decideGenerationFailure({ stop_reason: 'end_turn' });
  assert.equal(outcome.failure_reason, 'malformed_output');
  assert.equal(outcome.status, 'failed');
  assert.equal(outcome.narrative_md, null);
});

test('decideGenerationFailure: content is not an array -> malformed_output', () => {
  const outcome = decideGenerationFailure({ content: 'not-an-array', stop_reason: 'end_turn' });
  assert.equal(outcome.failure_reason, 'malformed_output');
});

test('decideGenerationFailure: empty content array -> malformed_output', () => {
  const outcome = decideGenerationFailure({ content: [], stop_reason: 'end_turn' });
  assert.equal(outcome.failure_reason, 'malformed_output');
});

/* ---------------------------------------------------------------- empty_narrative */

test('decideGenerationFailure: content present but text is empty string -> empty_narrative', () => {
  const outcome = decideGenerationFailure(textResponse(''));
  assert.deepEqual(outcome, { status: 'failed', narrative_md: null, failure_reason: 'empty_narrative' });
});

test('decideGenerationFailure: text is whitespace-only -> empty_narrative', () => {
  const outcome = decideGenerationFailure(textResponse('   \n\t  '));
  assert.equal(outcome.failure_reason, 'empty_narrative');
});

test('decideGenerationFailure: only non-text blocks (no text block at all) -> empty_narrative', () => {
  const outcome = decideGenerationFailure({
    content: [{ type: 'tool_use', id: 'x', name: 'noop', input: {} }],
    stop_reason: 'end_turn',
  });
  assert.equal(outcome.failure_reason, 'empty_narrative');
});

/* ---------------------------------------------------------------- model_timeout */

test('decideGenerationFailure: an AbortError (request timed out) -> model_timeout', () => {
  const error = new Error('The user aborted a request.');
  error.name = 'AbortError';
  const outcome = decideGenerationFailure(error);
  assert.deepEqual(outcome, { status: 'failed', narrative_md: null, failure_reason: 'model_timeout' });
});

test('decideGenerationFailure: SDK APIConnectionTimeoutError name -> model_timeout', () => {
  const error = new Error('Request timed out.');
  error.name = 'APIConnectionTimeoutError';
  assert.equal(decideGenerationFailure(error).failure_reason, 'model_timeout');
});

test('decideGenerationFailure: a bare message mentioning "timed out" -> model_timeout', () => {
  const error = new Error('connect ETIMEDOUT 1.2.3.4:443, request timed out');
  assert.equal(decideGenerationFailure(error).failure_reason, 'model_timeout');
});

test('decideGenerationFailure: ETIMEDOUT error code -> model_timeout', () => {
  const error = Object.assign(new Error('connection failed'), { code: 'ETIMEDOUT' });
  assert.equal(decideGenerationFailure(error).failure_reason, 'model_timeout');
});

/* ---------------------------------------------------------------- model_unavailable */

test('decideGenerationFailure: a 500 API error -> model_unavailable', () => {
  const error = Object.assign(new Error('Internal server error'), { status: 500, name: 'InternalServerError' });
  assert.deepEqual(decideGenerationFailure(error), { status: 'failed', narrative_md: null, failure_reason: 'model_unavailable' });
});

test('decideGenerationFailure: a 529 overloaded error -> model_unavailable', () => {
  const error = Object.assign(new Error('Overloaded'), { status: 529 });
  assert.equal(decideGenerationFailure(error).failure_reason, 'model_unavailable');
});

test('decideGenerationFailure: a connection-refused / network error with no status -> model_unavailable', () => {
  const error = Object.assign(new Error('connect ECONNREFUSED 1.2.3.4:443'), { code: 'ECONNREFUSED' });
  assert.equal(decideGenerationFailure(error).failure_reason, 'model_unavailable');
});

test('decideGenerationFailure: a plain string thrown (non-Error) -> model_unavailable, never throws itself', () => {
  assert.doesNotThrow(() => decideGenerationFailure('boom'));
  assert.equal(decideGenerationFailure('boom').failure_reason, 'model_unavailable');
});

test('decideGenerationFailure: null/undefined input -> model_unavailable, never throws', () => {
  assert.doesNotThrow(() => decideGenerationFailure(null));
  assert.doesNotThrow(() => decideGenerationFailure(undefined));
  assert.equal(decideGenerationFailure(null).failure_reason, 'model_unavailable');
  assert.equal(decideGenerationFailure(undefined).failure_reason, 'model_unavailable');
});

/* ---------------------------------------------------------------- shape stability */

test('decideGenerationFailure: every failure return always has narrative_md: null and status: "failed"', () => {
  const cases = [
    textResponse('', 'end_turn'),
    textResponse('x', 'refusal'),
    { content: [] },
    new Error('anything'),
    Object.assign(new Error('timeout'), { name: 'AbortError' }),
  ];
  for (const input of cases) {
    const outcome = decideGenerationFailure(input);
    assert.ok(outcome, 'expected a failure object for this case');
    assert.equal(outcome.status, 'failed');
    assert.equal(outcome.narrative_md, null);
    assert.ok(
      ['model_unavailable', 'model_timeout', 'malformed_output', 'empty_narrative'].includes(outcome.failure_reason),
      `failure_reason "${outcome.failure_reason}" must be one of the four named reasons`,
    );
  }
});
