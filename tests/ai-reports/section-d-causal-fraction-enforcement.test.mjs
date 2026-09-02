/* section-d closure — four section-D gaps closed in one pass, each proved by an executing test. The
 * exact inputs below are reused from the section-D refuter harness
 * (/private/tmp/claude-501/-Users-cs-Downloads-loyalty-main/b2eb2901-2f29-4ab9-8d07-185769b6d407/
 * scratchpad/adversarial-section-d.mjs), against the REAL validate.mjs / enforce.mjs / index.ts in
 * this worktree — that harness pins a copy of validate.mjs from BEFORE this session's fixes, so its
 * own printed verdicts for the cases below are the "before" state; the expectations here are the
 * corrected "after" state docs/qa/CI-100-CHECKLIST.md checks 83, 85, 88 and 81/90 ask for.
 *
 *   85. V3 (checkCausal) now ALSO tests the shared CAUSAL_CONSTRUCTIONS list (the one V10/V10b
 *       already use) UNCONDITIONALLY — no typed ASSOCIATION finding required — so "as a result"
 *       and a pronoun-continuation causal idiom ("This pushes customers to return sooner.") are
 *       caught even on a pack with zero typed findings, while an honest non-causal "because" that
 *       explains a coverage/limitation gap stays clean.
 *
 *   88. COMMON_SENTENCE_STARTERS gained a broad discourse-word list and an exported
 *       PRODUCT_VOCABULARY, plus a new grounding source (the pack's own object KEYS, not only its
 *       string values) — closing a class of false positives V9b was firing on ordinary report
 *       prose ("There were more visits this month.", "Regulars returned sooner.") while a genuinely
 *       invented name ("Melissa spent...") is still caught exactly as before.
 *
 *   83. scanNumberWords gained ordinal/fraction/dozen/"X in Y" quantity-phrase parsing
 *       (scanQuantityPhrases) — "a third of customers" / "a dozen regulars" now state a real
 *       numeric claim that must ground against the pack, the same as any digit or spelled-out
 *       cardinal number; "several"/"many"/"most" still make no numeric claim at all.
 *
 *   81/90 (enforcement). The pass/fail DECISION index.ts's processQueue() used to make inline
 *       (`if (!verdict.ok) throw new Error(validationFailureReason(verdict.violations))`) is now
 *       decideNarrativeOutcome() in ./enforce.mjs — a plain, dual-runtime .mjs function this suite
 *       can call directly, executed here for both a clean and a violating narrative.
 *
 * No source-regex assertions except the one this file's own header says is unavoidable: index.ts
 * is Deno + npm: specifiers and cannot be imported or executed under `node --test` at all, so the
 * proof that it actually WIRES decideNarrativeOutcome in is a source check, declared as such below.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import {
  RULES,
  PRODUCT_VOCABULARY,
  validateNarrative,
} from '../../supabase/functions/ai-firm-reports/validate.mjs';
import { decideNarrativeOutcome } from '../../supabase/functions/ai-firm-reports/enforce.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const CORPUS_DIR = join(HERE, 'fixtures', 'golden-packs');
const INDEX_TS = join(ROOT, 'supabase', 'functions', 'ai-firm-reports', 'index.ts');

function loadCorpus() {
  const files = readdirSync(CORPUS_DIR).filter((f) => f.endsWith('.json')).sort();
  return files.map((file) => ({ file, ...JSON.parse(readFileSync(join(CORPUS_DIR, file), 'utf8')) }));
}
const corpus = loadCorpus();
const pack01Raw = corpus.find((c) => c.file === '01-normal-firm.json');
// nestly_v713 (check 17, evidence half) additively gave 01-normal-firm.json's pack its own
// findings.ranked block (gateway_followthrough/contactability_gap) so the golden corpus exercises
// V10/V10b against a REAL production shape, not only hand-built fixtures — see
// v713-findings-ranked-binding.test.mjs. This file's own point is the OPPOSITE precondition: V3's
// unconditional CAUSAL_CONSTRUCTIONS check must catch a bare causal idiom even with ZERO typed
// findings anywhere in the pack. A deep-cloned, findings-stripped copy of pack01 keeps that
// precondition true regardless of what the shared golden fixture carries.
const pack01 = {
  ...pack01Raw,
  pack: (() => {
    const stripped = JSON.parse(JSON.stringify(pack01Raw.pack));
    delete stripped.findings;
    if (stripped.evidence_completeness) delete stripped.evidence_completeness.findings_version;
    return stripped;
  })(),
};

const explain = (result) =>
  result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ') || '(none)';
const only = (result, rule) => result.violations.filter((v) => v.rule === rule);

// The exact skeleton the section-D refuter harness builds around one variable "Your customers"
// line — 5 required headings, 3 numbered actions, the identified-revenue caveat pack01 itself
// needs (identified_revenue_share_pct=80), so every case below isolates ONLY the rule under test.
function wrap(customerLine) {
  return [
    '## Summary',
    'Sales were steady this month for Normal Cafe at the Tampines branch. Revenue was SGD 5,000.00.',
    '## What went well',
    '- 7 of 10 customers this month had already bought before, a returning-customer share of 70.0%.',
    '## What needs attention',
    '- 3 regulars have not been seen in a while. One returned visit each is worth SGD 90.00.',
    '- About 80% of revenue came from identified customers; the customer figures describe them.',
    '## Your customers',
    customerLine,
    '## Do these three things next',
    '1. Send one win-back message to the 3 at-risk regulars this week.',
    '2. Review the Tampines branch roster next month.',
    '3. Ask the 4 customers who returned in August what brought them back.',
  ].join('\n');
}

/* ==================================================================== check 85: V3 unconditional */

test('section-d check 85: pack01 carries no typed (evidence_class) findings at all — the exact ' +
  'precondition "unconditionally" is proving', () => {
  const stack = [pack01.pack];
  let found = false;
  while (stack.length) {
    const node = stack.pop();
    if (!node || typeof node !== 'object') continue;
    if (Array.isArray(node)) { stack.push(...node); continue; }
    if (node.evidence_class === 'ASSOCIATION' || node.evidence_class === 'DIRECT_FACT') found = true;
    stack.push(...Object.values(node));
  }
  assert.equal(found, false, 'pack01 must carry zero typed findings for this section to be meaningful');
});

test('section-d check 85: "as a result" is now caught on a pack with no typed findings (V10/V10b never fire)', () => {
  const result = validateNarrative(
    wrap('As a result, three regulars came back this month.'), pack01.pack);
  assert.equal(result.ok, false, explain(result));
  assert.ok(only(result, RULES.CAUSAL).some((v) => /as a result/i.test(v.detail)), explain(result));
  assert.deepEqual(only(result, RULES.CAUSAL_BINDING), []);
  assert.deepEqual(only(result, RULES.ASSOCIATION_MARKER), []);
});

test('section-d check 85: a pronoun-continuation causal idiom ("This pushes...") is now caught on a ' +
  'pack with no typed findings', () => {
  const result = validateNarrative(
    wrap('Weekend visits build momentum. This pushes customers to return sooner.'), pack01.pack);
  assert.equal(result.ok, false, explain(result));
  assert.ok(only(result, RULES.CAUSAL).some((v) => /pushes/i.test(v.detail)), explain(result));
});

test('section-d check 85: an honest non-causal "because" explaining a coverage/limitation gap stays clean', () => {
  const result = validateNarrative(
    wrap('The figure is incomplete because item coverage is low this month.'), pack01.pack);
  assert.equal(result.ok, true, explain(result));
});

test('section-d check 85: the exemption is narrow — "because" is still caught when its object is NOT ' +
  'a coverage/limitation phrase', () => {
  const result = validateNarrative(
    wrap('Regulars came back this month because the weather was good.'), pack01.pack);
  assert.ok(only(result, RULES.CAUSAL).some((v) => /because/i.test(v.detail)), explain(result));
});

test('section-d check 85: "because of the campaign" (intervention attribution) is still caught, ' +
  'unchanged from before this session', () => {
  const result = validateNarrative(wrap('Sales rose because of the campaign this month.'), pack01.pack);
  assert.ok(only(result, RULES.CAUSAL).some((v) => /because_of_intervention/.test(v.detail)), explain(result));
});

test('section-d check 85: every known-good narrative in the corpus stays free of V3 (CAUSAL) violations', () => {
  for (const { file, pack, good } of corpus) {
    const result = validateNarrative(good, pack);
    assert.ok(result.violations.every((v) => v.rule !== RULES.CAUSAL),
      `${file}'s known-good narrative must not trip V3:\n  ${explain(result)}`);
  }
});

/* ============================================================ check 88: sentence-initial false positives */

test('section-d check 88: PRODUCT_VOCABULARY is exported and carries "regulars"', () => {
  assert.ok(PRODUCT_VOCABULARY instanceof Set);
  assert.ok(PRODUCT_VOCABULARY.has('regulars'));
});

test('section-d check 88: "There were more visits this month." validates clean (broad discourse starter)', () => {
  const result = validateNarrative(wrap('There were more visits this month.'), pack01.pack);
  assert.equal(result.ok, true, explain(result));
});

test('section-d check 88: "Regulars returned sooner." validates clean (PRODUCT_VOCABULARY)', () => {
  const result = validateNarrative(wrap('Regulars returned sooner.'), pack01.pack);
  assert.equal(result.ok, true, explain(result));
});

test('section-d check 88: "Melissa spent more than usual this month." is STILL caught — the new ' +
  'exemptions never widen to cover a genuinely invented name', () => {
  const result = validateNarrative(wrap('Melissa spent more than usual this month.'), pack01.pack);
  assert.equal(result.ok, false);
  assert.ok(only(result, RULES.ENTITY).some((v) => v.detail.includes('Melissa')), explain(result));
});

test('section-d check 88: a sentence-initial word grounds via the pack\'s own object KEY, not only its ' +
  'string values', () => {
  const pack = {
    scope: { period_kind: 'monthly', period_start: '2026-08-01', period_end: '2026-08-31' },
    insights: { zeptowidget_affinity_score: 42 },
  };
  const narrative = [
    '## Summary', 'Zeptowidget affinity is worth watching this month.',
    '## What went well', '- Nothing new this month.',
    '## What needs attention', '- Nothing new this month.',
    '## Your customers', 'No customer detail this month.',
    '## Do these three things next', '1. Do one thing.', '2. Do another thing.', '3. Do a third thing.',
  ].join('\n');
  const result = validateNarrative(narrative, pack);
  assert.ok(result.violations.every((v) => !v.detail.includes('"Zeptowidget"')),
    `"Zeptowidget" must ground via the pack's own key insights.zeptowidget_affinity_score:\n  ${explain(result)}`);
});

test('section-d check 88: every known-good narrative in the corpus stays free of V9b violations', () => {
  for (const { file, pack, good } of corpus) {
    const result = validateNarrative(good, pack);
    assert.ok(result.violations.every((v) => !(v.rule === RULES.ENTITY && v.detail.startsWith('V9b'))),
      `${file}'s known-good narrative must not trip V9b:\n  ${explain(result)}`);
  }
});

/* ==================================================================== check 83: quantity phrases */

test('section-d check 83: "a third of customers" states a real 33.3% claim and is caught when ungrounded', () => {
  const result = validateNarrative(wrap('A third of customers returned this month.'), pack01.pack);
  assert.equal(result.ok, false);
  assert.ok(only(result, RULES.NUMERIC).some((v) => /33\.3/.test(v.detail) && /A third/.test(v.detail)),
    explain(result));
});

test('section-d check 83: "a dozen regulars" states a real count of 12 and is caught when ungrounded', () => {
  const result = validateNarrative(wrap('A dozen regulars are at risk this month.'), pack01.pack);
  assert.equal(result.ok, false);
  assert.ok(only(result, RULES.NUMERIC).some((v) => /^12 /.test(v.detail) && /A dozen/.test(v.detail)),
    explain(result));
});

test('section-d check 83: a fraction that DOES match the pack\'s own derived percentages grounds clean, ' +
  'the same as any other percent claim ("half" -> 50, which pack01 genuinely carries)', () => {
  const result = validateNarrative(wrap('About half of revenue came from regulars.'), pack01.pack);
  assert.equal(result.ok, true, explain(result));
});

test('section-d check 83: "several", "many" and "most" state no numeric claim at all (declared gap)', () => {
  for (const word of ['Several', 'Many', 'Most']) {
    const result = validateNarrative(wrap(`${word} regulars came back this month.`), pack01.pack);
    assert.deepEqual(only(result, RULES.NUMERIC), [],
      `"${word}" must never manufacture a numeric claim:\n  ${explain(result)}`);
  }
});

test('section-d check 83: correct arithmetic with digits is unaffected by the quantity-phrase extension', () => {
  const result = validateNarrative(wrap('SGD 90.00 / 3 customers = SGD 30.00 each.'), pack01.pack);
  assert.equal(result.ok, true, explain(result));
});

test('section-d check 83: every known-good narrative in the corpus is unaffected by the quantity-phrase extension', () => {
  for (const { file, pack, good } of corpus) {
    const result = validateNarrative(good, pack);
    assert.equal(result.ok, true, `${file}'s known-good narrative must still pass:\n  ${explain(result)}`);
  }
});

/* ====================================================== check 81/90: decideNarrativeOutcome */

test('section-d enforcement: decideNarrativeOutcome returns status "ready" for a clean narrative, ' +
  'narrative_md unchanged, no failure_reason', () => {
  const good = wrap('Your largest customer, Alan T., carried 16.0% of all revenue, SGD 800.00.');
  const outcome = decideNarrativeOutcome(good, pack01.pack);
  assert.equal(outcome.status, 'ready');
  assert.equal(outcome.narrative_md, good);
  assert.equal(outcome.failure_reason, null);
  assert.deepEqual(outcome.violations, []);
});

test('section-d enforcement: decideNarrativeOutcome returns status "failed" for a violating narrative, ' +
  'narrative_md null, a machine-readable failure_reason, and the raw violations', () => {
  const bad = wrap('This month SGD 999.99 was earned by one loyal customer.');
  const outcome = decideNarrativeOutcome(bad, pack01.pack);
  assert.equal(outcome.status, 'failed');
  assert.equal(outcome.narrative_md, null);
  assert.equal(typeof outcome.failure_reason, 'string');
  assert.match(outcome.failure_reason, /narrative_validation:/);
  assert.match(outcome.failure_reason, /V1_NUMERIC_CLAIM/);
  assert.ok(outcome.violations.length > 0);
  assert.ok(outcome.violations.every((v) => typeof v.rule === 'string' && typeof v.detail === 'string'));
});

test('section-d enforcement: decideNarrativeOutcome forwards opts to validateNarrative unchanged ' +
  '(opts.causalEvidence opens the causal gate exactly as it does when called directly)', () => {
  const narrative = wrap('The win-back message caused three regulars to return this month.');
  const shut = decideNarrativeOutcome(narrative, pack01.pack);
  assert.equal(shut.status, 'failed');
  const open = decideNarrativeOutcome(narrative, pack01.pack, { causalEvidence: true });
  assert.deepEqual(open.violations.filter((v) => v.rule === RULES.CAUSAL), [],
    explain({ violations: open.violations }));
});

test('section-d enforcement: index.ts imports and uses decideNarrativeOutcome — the only source-text ' +
  'assertion in this suite, because index.ts is a Deno edge function (npm: specifiers, Deno.serve, ' +
  'Deno.env) that cannot be imported or executed under `node --test` at all; every OTHER behaviour ' +
  'this file asserts is proven by actually calling decideNarrativeOutcome/validateNarrative above, ' +
  'never by reading source text', () => {
  const src = readFileSync(INDEX_TS, 'utf8');
  assert.match(src, /import\s*\{\s*decideNarrativeOutcome\s*\}\s*from\s*'\.\/enforce\.mjs'/,
    'index.ts must import decideNarrativeOutcome from ./enforce.mjs');
  assert.match(src, /decideNarrativeOutcome\(/,
    'index.ts must actually call decideNarrativeOutcome, not merely import it');
  // index.ts's own comments still mention validateNarrative BY NAME, correctly, as documentation
  // (it explains what decideNarrativeOutcome calls under the hood) — this only checks the old
  // direct IMPORT of validateNarrative from ./validate.mjs is gone, not the word itself.
  assert.doesNotMatch(src, /import\s*\{[^}]*\bvalidateNarrative\b[^}]*\}\s*from\s*'\.\/validate\.mjs'/,
    'index.ts must no longer import validateNarrative directly — decideNarrativeOutcome ' +
    'is now the one place index.ts talks to the validator');
});

test('section-d enforcement: index.ts type-checks (node --experimental-strip-types --check)', () => {
  execFileSync(process.execPath, ['--experimental-strip-types', '--check', INDEX_TS], { stdio: 'pipe' });
});
