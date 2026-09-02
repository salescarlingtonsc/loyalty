/* nestly_v713 (check 17, evidence half) — proving V10/V10b bind against a REAL production shape.
 *
 * db/migrations/20260920_nestly_v713_evidence_pack_typed_findings.sql wires app.v176_evidence_pack
 * (the ONLY function that ever builds the object index.ts sends the model) up to
 * public.get_ci_opportunities_v1's typed candidates, surfaced as a new top-level `findings` key:
 * `findings.ranked[]` (each candidate carrying its own `evidence_class`, 'ASSOCIATION' or
 * 'DIRECT_FACT'), `findings.top_actions[]`, and `evidence_completeness.findings_version`.
 *
 * Before this migration, V10 (checkAssociationCausalBinding) and V10b
 * (checkAssociationPositiveMarker) were proven ONLY against hand-built fixtures that place a
 * synthetic evidence_class object at the fixture's own top level (opportunities.candidates, or a
 * bespoke inline pack literal) — never against the shape a REAL evidence pack this codebase can
 * produce actually carries. tests/ai-reports/fixtures/golden-packs/01-normal-firm.json and
 * 05-whale-firm.json now additively carry a `findings.ranked` block shaped exactly like v713's
 * output (copied field-for-field from the live app.v176_gated_evidence generators: id, domain,
 * pattern, comparison, impact, action, evidence, evidence_class, confidence, limitation,
 * rank_class — see db/migrations/20260920_nestly_v680_ci_envelope.sql's GENERATOR F/H bodies).
 * validate.mjs itself needed no change: typedFindings already walks the WHOLE pack looking for any
 * plain object with its own string `evidence_class`, no matter which key holds it — this file
 * proves that generic walk actually reaches findings.ranked[], not just asserts it in prose.
 *
 * Three binding proofs, using 01-normal-firm.json's own findings.ranked (gateway_followthrough,
 * ASSOCIATION; contactability_gap, DIRECT_FACT), each built by taking the fixture's OWN known-good
 * narrative (already proven clean) and swapping only its "Your customers" sentence — the same
 * technique v706's own refuter tests use against pack02.good:
 *
 *   1. A causal sentence ABOUT the ASSOCIATION candidate (gateway_followthrough) fails — V10 names it.
 *   2. A flat DIRECT_FACT statement (contactability_gap) passes — V10/V10b never look at it.
 *   3. A marker-laundered sentence (an approved ASSOCIATION_MARKER phrase AND a causal construction
 *      in the same window) still fails — V10b's own v707 fix: a marker does not launder a causal
 *      claim riding alongside it.
 *
 * A fourth proof covers assembleUserPrompt (check 81): the exact text sent to the model must
 * surface findings.ranked, with each candidate's evidence_class readable in the prompt.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { RULES, assembleUserPrompt, validateNarrative } from '../../supabase/functions/ai-firm-reports/validate.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const CORPUS_DIR = join(HERE, 'fixtures', 'golden-packs');

function loadFixture(file) {
  return JSON.parse(readFileSync(join(CORPUS_DIR, file), 'utf8'));
}

const pack01 = loadFixture('01-normal-firm.json');
const pack05 = loadFixture('05-whale-firm.json');

const explain = (result) =>
  result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ') || '(none)';
const only = (result, rule) => result.violations.filter((v) => v.rule === rule);

const YOUR_CUSTOMERS_SENTENCE = 'Your largest customer, Alan T., carried 16.0% of all revenue, SGD 800.00.';

function withCustomerLine(sentence) {
  const narrative = pack01.good.replace(YOUR_CUSTOMERS_SENTENCE, sentence);
  assert.notEqual(narrative, pack01.good, 'replacement must have taken effect');
  return narrative;
}

test('sanity: 01-normal-firm.json\'s findings.ranked carries the gateway_followthrough ' +
  'ASSOCIATION candidate and the contactability_gap DIRECT_FACT candidate', () => {
  const ranked = pack01.pack.findings.ranked;
  assert.ok(Array.isArray(ranked) && ranked.length === 2);
  assert.ok(ranked.some((c) => c.id.startsWith('gateway_followthrough') && c.evidence_class === 'ASSOCIATION'));
  assert.ok(ranked.some((c) => c.id === 'contactability_gap' && c.evidence_class === 'DIRECT_FACT'));
  assert.equal(pack01.pack.evidence_completeness.findings_version, 'v713');
});

test('v713 (V10): a causal sentence about the ASSOCIATION candidate in findings.ranked fails', () => {
  const narrative = withCustomerLine(
    "The Seasonal Special's weak follow-up buying causes customers to skip a second visit.");
  const result = validateNarrative(narrative, pack01.pack);
  assert.equal(result.ok, false, explain(result));
  assert.ok(
    only(result, RULES.CAUSAL_BINDING).some((v) => v.detail.includes('Seasonal Special')),
    `expected V10 to name the gateway_followthrough finding:\n  ${explain(result)}`,
  );
});

test('v713 (V10/V10b): a flat DIRECT_FACT statement about contactability_gap passes ' +
  '(neither rule ever looks at a DIRECT_FACT finding)', () => {
  const narrative = withCustomerLine(
    'Only 4 of 10 customers can be reached on WhatsApp, the best available channel.');
  const result = validateNarrative(narrative, pack01.pack);
  assert.equal(only(result, RULES.CAUSAL_BINDING).length, 0,
    `a DIRECT_FACT finding must never trip V10:\n  ${explain(result)}`);
  assert.equal(only(result, RULES.ASSOCIATION_MARKER).length, 0,
    `a DIRECT_FACT finding must never trip V10b:\n  ${explain(result)}`);
});

test('v713 (V10b): a marker-laundered sentence about the ASSOCIATION candidate still fails — ' +
  'an approved marker does not excuse a causal construction riding alongside it', () => {
  const narrative = withCustomerLine(
    'Customers who buy the Seasonal Special tend to return, which results in more repeat visits.');
  const result = validateNarrative(narrative, pack01.pack);
  assert.equal(result.ok, false, explain(result));
  assert.ok(
    only(result, RULES.ASSOCIATION_MARKER).some((v) => v.detail.includes('Seasonal Special')),
    `expected V10b to name the gateway_followthrough finding despite the approved marker:\n  ${explain(result)}`,
  );
});

test('v713 (V10): the SAME binding holds against 05-whale-firm.json\'s own findings.ranked ' +
  '(daypart_shift, ASSOCIATION) — proves the proof is not an accident of one fixture', () => {
  const YOUR_CUSTOMERS_WHALE = 'Chen H. is by far your largest customer, at 85.0% of revenue.';
  const narrative = pack05.good.replace(YOUR_CUSTOMERS_WHALE,
    'Saturday being the busiest day causes Thursday customers to spend more per visit.');
  assert.notEqual(narrative, pack05.good, 'replacement must have taken effect');
  const result = validateNarrative(narrative, pack05.pack);
  assert.equal(result.ok, false, explain(result));
  assert.ok(
    only(result, RULES.CAUSAL_BINDING).length > 0,
    `expected V10 to fire against 05-whale-firm.json's daypart_shift finding:\n  ${explain(result)}`,
  );
});

test('v713 (check 81): assembleUserPrompt surfaces findings.ranked, with each candidate\'s ' +
  'evidence_class readable in the prompt text', () => {
  const report = {
    period_kind: 'monthly',
    period_start: pack01.pack.scope.period_start,
    period_end: pack01.pack.scope.period_end,
    evidence: pack01.pack,
  };
  const prompt = assembleUserPrompt(report);

  assert.match(prompt, /"findings"/, 'the findings key must be in the model-facing prompt');
  assert.match(prompt, /"ranked"/, 'findings.ranked must be in the model-facing prompt');
  assert.match(prompt, /"source_rpc":\s*"public\.get_ci_opportunities_v1"/);

  // Both candidates' own evidence_class must be readable, not just present somewhere in the JSON —
  // grep each candidate's identifying pattern text alongside its evidence_class.
  const associationIdx = prompt.indexOf('Seasonal Special');
  const directFactIdx = prompt.indexOf('contactability_gap');
  assert.ok(associationIdx >= 0, 'the ASSOCIATION candidate\'s pattern text must be in the prompt');
  assert.ok(directFactIdx >= 0, 'the DIRECT_FACT candidate\'s id must be in the prompt');

  const associationClassIdx = prompt.indexOf('"evidence_class": "ASSOCIATION"');
  const directFactClassIdx = prompt.indexOf('"evidence_class": "DIRECT_FACT"');
  assert.ok(associationClassIdx >= 0, 'an ASSOCIATION evidence_class must be readable in the prompt');
  assert.ok(directFactClassIdx >= 0, 'a DIRECT_FACT evidence_class must be readable in the prompt');
});
