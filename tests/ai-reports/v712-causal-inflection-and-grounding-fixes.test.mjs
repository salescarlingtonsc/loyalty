/* nestly_v712 — six items closed off the refuter's ledger at 115a11db (checks 17, 88), each proved
 * by an executing test against the real validateNarrative:
 *
 *   1. CAUSAL_CONSTRUCTIONS verb forms. Several entries were a single FIXED copula ("is why") or a
 *      single verb inflection ("accounts for", "explains", "produces") that a plain tense or number
 *      change slipped past cleanly - "weekend visits ARE WHY customers come back sooner" evaded the
 *      old bare /\bis\s+why\b/i entirely. Every such entry is now generalised to its ordinary
 *      English inflections (is/are/was/were/'s, present/past/participle, singular/plural) - the
 *      SAME idiom, written the way English actually conjugates it, not a new one.
 *
 *   2. Conditional causation. The prompt (EVIDENCE_CLASS_INSTRUCTION) already forbids "if you keep
 *      X, Y will..." but nothing here ever checked for it. A conditional
 *      ("if you keep pushing weekend visits, returns may rise") and the comparative
 *      "the more X, the more/faster/sooner Y" both state a cause with no word from the old list at
 *      all; both are now on CAUSAL_CONSTRUCTIONS.
 *
 *   3. CJK substring collision (V11). Grounding used to be a raw substring test, so a pack customer
 *      named "陈美玲" grounded ANY substring of that name, including "美玲" written to mean a
 *      DIFFERENT, invented person. V11 now grounds on a WHOLE CJK TOKEN match (a run equal to a
 *      whole pack string, or bounded by non-CJK characters on both sides within one) - closing the
 *      collision at the cost of a declared, accepted limit (a true nickname reference now also
 *      fails, see checkCjkEntities's own comment).
 *
 *   4. Numeric-ID coincidence (V1). "customer #4471" used to ground against ANY numeric leaf in the
 *      pack - a revenue figure, a stamp count, anything that happened to equal 4471 - even though an
 *      ID cue ("customer #", "order ", "ticket ", ...) names a record LOOKUP, not a quantity. A
 *      numeral introduced by one of those cues must now match a pack field whose OWN key looks like
 *      an identifier (ID_KEY_RE: "id"/"ref"/"number" anywhere in the key, "no" at the end), never an
 *      unrelated numeric coincidence.
 *
 *   5. The V9b honest-limits comment named "Grace", "Summer", "Faith" and "Will" alongside "May",
 *      "June", "March", "August" as words V9b cannot catch as invented names. That was wrong for the
 *      first four - none of them is a month name, a day name, or in COMMON_SENTENCE_STARTERS, so an
 *      invented "Grace"/"Summer"/"Faith"/"Will" opening a sentence IS caught. Only the month-name
 *      collisions are genuine false negatives. The comment is corrected; this file pins both halves
 *      of the corrected claim so it cannot silently drift back to the wrong one.
 *
 *   6. False positive: "Will you visit us again this month?" is an ordinary question, not a naming
 *      claim, and used to be flagged by V9b purely because "Will" opens the sentence capitalised.
 *      A narrow, position-scoped exemption (isInterrogativeModalOpening) now reads a sentence-
 *      initial modal followed within two tokens by an interrogative subject as a question - "Will"
 *      used as an actual invented PERSON name (no such shape around it) is still caught, proven
 *      alongside the fix.
 *
 * No source-regex assertions except where a rule's own regex constant is the thing under test
 * (items 1/2, which check CAUSAL_CONSTRUCTIONS is exercised through validateNarrative, and item 5's
 * pin, which is inherently about a false-negative shape) - every check below calls the real
 * validateNarrative over a full evidence pack and narrative.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { RULES, validateNarrative } from '../../supabase/functions/ai-firm-reports/validate.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const CORPUS_DIR = join(HERE, 'fixtures', 'golden-packs');

function loadCorpus() {
  const files = readdirSync(CORPUS_DIR).filter((f) => f.endsWith('.json')).sort();
  return files.map((file) => ({ file, ...JSON.parse(readFileSync(join(CORPUS_DIR, file), 'utf8')) }));
}

const corpus = loadCorpus();
const pack02 = corpus.find((c) => c.file === '02-sparse-firm.json');
const pack01 = corpus.find((c) => c.file === '01-normal-firm.json');
const FINDING_LABEL = 'weekend visit and return pattern';
const ORIGINAL_SENTENCE =
  'Customers who visit on a weekend also tend to return sooner than customers who visit on a weekday.';

test('v712 setup: known-good corpus narratives are still clean before these fixes are exercised', () => {
  for (const { file, pack, good } of corpus) {
    const result = validateNarrative(good, pack);
    assert.equal(result.ok, true,
      `${file}'s known-good narrative must be clean:\n  ` +
      `${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`);
  }
});

/* ================================================== item 1: copula/inflection generalisation === */

// Each sentence replaces pack02's ORIGINAL ASSOCIATION-finding sentence with one that names the
// SAME finding (so it is attributed to it) via a causal construction that ONLY an inflected or
// copula-generalised form of the CAUSAL_CONSTRUCTIONS entry can catch — the bare, un-generalised
// regex that shipped before this fix would have missed every one of these.
const INFLECTION_CASES = [
  [
    'a fixed copula ("is why") generalised to "are why" — the refuter\'s own check-17 input',
    'It appears to be the case that weekend visits are why customers come back sooner.',
  ],
  ['"is why" generalised to "was why"',
    'It appears to be the case that weekend visits was why customers come back sooner.'],
  ['"is why" generalised to "that is why"',
    'The weekend slot drives repeats, and that is why weekend visits return sooner.'],
  ['"is why" generalised to the contraction "\'s why"',
    "The weekend slot drives repeats. That's why weekend visits return sooner."],
  ['"accounts for" generalised to "accounted for"',
    'Weekend visiting accounted for the sooner weekend return pattern we see.'],
  ['"explains" generalised to "explained"',
    'Weekend visiting, we observe, explained the sooner weekend return pattern.'],
  ['"produces" generalised to "produced"',
    'Weekend visiting, we observe, produced the sooner weekend return pattern.'],
  ['"is behind" (fixed copula) generalised to "was behind"',
    'We observe that the weekend slot was behind the sooner weekend return.'],
  ['"is the reason" (fixed copula) generalised to "was the reason"',
    'We observe that the weekend slot was the reason for the sooner weekend return.'],
  ['"leads to" generalised to the past tense "led to"',
    'We observe that the weekend slot led to a sooner weekend return.'],
  ['"results in" generalised to "resulted in"',
    'We observe that the weekend slot resulted in a sooner weekend return.'],
  ['"stems from" generalised to "stemmed from"',
    'We observe that the sooner weekend return stemmed from the weekend slot.'],
  ['"means that" generalised to "meant that"',
    'We observe that the weekend slot meant that weekend visits returned sooner.'],
  ['"translates into" generalised to "translated into"',
    'We observe that the weekend slot translated into a sooner weekend return.'],
  ['"paves the way" generalised to "paved the way"',
    'We observe that the weekend slot paved the way for a sooner weekend return.'],
  ['"follows from" generalised to "followed from"',
    'We observe that the sooner weekend return followed from the weekend slot.'],
  ['"results from" generalised to "resulted from"',
    'We observe that the sooner weekend return resulted from the weekend slot.'],
  ['"brings about" generalised to "brought about"',
    'We observe that the weekend slot brought about a sooner weekend return.'],
  ['"spurs" generalised to "spurred"',
    'We observe that the weekend slot spurred a sooner weekend return.'],
  ['"prompts" generalised to "prompted"',
    'We observe that the weekend slot prompted a sooner weekend return.'],
  ['"boosts" generalised to "boosted"',
    'We observe that the weekend slot boosted the sooner weekend return.'],
  ['"fuels" generalised to "fuelled"/"fueled"',
    'We observe that the weekend slot fuelled the sooner weekend return.'],
  ['"triggers" generalised to "triggered"',
    'We observe that the weekend slot triggered the sooner weekend return.'],
  ['"pushes" generalised to "pushed"',
    'We observe that the weekend slot pushed a sooner weekend return.'],
];

for (const [label, sentence] of INFLECTION_CASES) {
  test(`v712 check 17 (item 1): ${label} is now caught`, () => {
    const narrative = pack02.good.replace(ORIGINAL_SENTENCE, sentence);
    assert.notEqual(narrative, pack02.good, `replacement must have taken effect for "${label}"`);
    const result = validateNarrative(narrative, pack02.pack);
    assert.ok(
      result.violations.some((v) => v.rule === RULES.CAUSAL_BINDING && v.detail.includes(FINDING_LABEL)),
      `expected V10 (causal binding) to fire for "${sentence}":\n  ` +
      `${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ') || '(none)'}`,
    );
  });
}

/* ============================================================ item 2: conditional causation ==== */

const CONDITIONAL_CASES = [
  [
    'a conditional causal claim ("if you keep X, Y may/will...") — the exact refuter check-17 input',
    'Weekend visits are associated with faster returns; if you keep pushing weekend visits, ' +
      'returns may rise.',
  ],
  [
    'the comparative "the more X, the more/faster/sooner Y" construction',
    'We observe that the more weekend visits happen, the more weekend visitors return sooner.',
  ],
];

for (const [label, sentence] of CONDITIONAL_CASES) {
  test(`v712 check 17 (item 2): ${label} is now caught`, () => {
    const narrative = pack02.good.replace(ORIGINAL_SENTENCE, sentence);
    assert.notEqual(narrative, pack02.good, `replacement must have taken effect for "${label}"`);
    const result = validateNarrative(narrative, pack02.pack);
    assert.ok(
      result.violations.some((v) => v.rule === RULES.CAUSAL_BINDING && v.detail.includes(FINDING_LABEL)),
      `expected V10 (causal binding) to fire for "${sentence}":\n  ` +
      `${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ') || '(none)'}`,
    );
  });
}

test('v712 check 17: the refuter\'s exact L4 ("is why" via "are why") input is rejected end to end', () => {
  const narrative = pack02.good.replace(
    ORIGINAL_SENTENCE,
    'It appears to be the case that weekend visits are why customers come back sooner.',
  );
  const result = validateNarrative(narrative, pack02.pack);
  assert.equal(result.ok, false);
});

test('v712 check 17: the refuter\'s exact L25 (conditional "if you keep...may") input is rejected ' +
  'end to end', () => {
  const narrative = pack02.good.replace(
    ORIGINAL_SENTENCE,
    'Weekend visits are associated with faster returns; if you keep pushing weekend visits, ' +
      'returns may rise.',
  );
  const result = validateNarrative(narrative, pack02.pack);
  assert.equal(result.ok, false);
});

/* ============================================================ item 3: CJK whole-token grounding = */

const cjkPack = {
  contract_version: 'v176',
  scope: {
    business_name: 'CJK Test Co', period_kind: 'monthly',
    period_start: '2026-08-01', period_end: '2026-08-31',
  },
  insights: {
    top_customers: { rows: [{ label: '陈美玲', revenue_cents: 12000, visits: 3 }] },
  },
};
const cjkGood = '## Summary\n陈美玲 was a top spender this month.\n## What went well\nok\n' +
  '## What needs attention\nok\n## Your customers\nok\n## Do these three things next\n1. a\n2. b\n3. c';
const cjkSubstringCollision = '## Summary\n美玲 was a top spender this month.\n## What went well\nok\n' +
  '## What needs attention\nok\n## Your customers\nok\n## Do these three things next\n1. a\n2. b\n3. c';

test('v712 check 88 (item 3): a CJK name that IS the pack\'s whole token still grounds clean', () => {
  const result = validateNarrative(cjkGood, cjkPack);
  assert.equal(result.ok, true,
    `expected clean, got:\n  ${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`);
});

test('v712 check 88 (item 3): a CJK substring of a longer pack name, naming a different person, ' +
  'is now caught (the refuter\'s own collision — "陈美玲" in the pack, "美玲" in the narrative)', () => {
  const result = validateNarrative(cjkSubstringCollision, cjkPack);
  assert.equal(result.ok, false);
  assert.ok(
    result.violations.some((v) => v.detail.includes('V11') && v.detail.includes('美玲')),
    `expected V11 to name "美玲":\n  ${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`,
  );
});

/* ======================================================= item 4: numeric-ID coincidence (V1) ==== */

const idCoincidencePack = {
  contract_version: 'v176',
  scope: {
    business_name: 'ID Test Co', period_kind: 'monthly',
    period_start: '2026-08-01', period_end: '2026-08-31',
  },
  insights: { retention: { customers_served: 2 }, sales: { current: { revenue_cents: 4471 } } },
};
const idNarrative = '## Summary\nWe noted customer #4471 as a repeat visitor this month.\n' +
  '## What went well\nok\n## What needs attention\nok\n## Your customers\nok\n' +
  '## Do these three things next\n1. a\n2. b\n3. c';

test('v712 check 88 (item 4): "customer #4471" is rejected when 4471 exists ONLY as an unrelated ' +
  'numeric value (revenue), never as an ID field — the refuter\'s own check-88 input', () => {
  const result = validateNarrative(idNarrative, idCoincidencePack);
  assert.equal(result.ok, false);
  assert.ok(
    result.violations.some((v) => v.rule === RULES.NUMERIC && v.detail.includes('4471')),
    `expected V1 to name 4471:\n  ${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`,
  );
});

const idGroundedPack = {
  contract_version: 'v176',
  scope: {
    business_name: 'ID Test Co', period_kind: 'monthly',
    period_start: '2026-08-01', period_end: '2026-08-31',
  },
  insights: {
    top_customers: { rows: [{ customer_id: 4471, label: 'Tan W.', revenue_cents: 1000, visits: 2 }] },
  },
};

test('v712 check 88 (item 4): "customer #4471" grounds clean when the pack carries a matching ' +
  'ID-typed field (customer_id) — the fix narrows what counts as evidence, it does not remove it', () => {
  const result = validateNarrative(idNarrative, idGroundedPack);
  assert.equal(result.ok, true,
    `expected clean, got:\n  ${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`);
});

/* =========================================================== item 5: V9b comment correctness ==== */

// Pins the CORRECTED claim: "Grace"/"Summer"/"Faith"/"Will" (none of them a month, day, or starter
// word) ARE caught opening a sentence; only the month-name collisions ("May"/"June"/"March"/
// "August", all folded into COMMON_SENTENCE_STARTERS via MONTHS) are the genuine false negatives.
const REPLACED_SENTENCE = 'Your largest customer, Alan T., carried 16.0% of all revenue, SGD 800.00.';

const CAUGHT_NON_MONTH_WORDS = ['Grace', 'Summer', 'Faith'];
for (const word of CAUGHT_NON_MONTH_WORDS) {
  test(`v712 check 88 (item 5): an invented "${word}" opening a sentence IS caught by V9b`, () => {
    const narrative = pack01.good.replace(
      REPLACED_SENTENCE,
      `${REPLACED_SENTENCE} ${word} spent more than usual this period.`,
    );
    const result = validateNarrative(narrative, pack01.pack);
    assert.ok(
      result.violations.some((v) => v.detail.includes(`"${word}"`)),
      `expected V9b to name "${word}":\n  ${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`,
    );
  });
}

const MONTH_FALSE_NEGATIVES = ['May', 'June', 'March', 'August'];
for (const month of MONTH_FALSE_NEGATIVES) {
  test(`v712 check 88 (item 5): month-name collision "${month}" opening a sentence stays an ` +
    'accepted false negative for V9b specifically (V2 may still flag it as an out-of-period month, ' +
    'a different rule)', () => {
    const narrative = pack01.good.replace(
      REPLACED_SENTENCE,
      `${REPLACED_SENTENCE} ${month} spent more than usual this period.`,
    );
    const result = validateNarrative(narrative, pack01.pack);
    assert.ok(
      !result.violations.some((v) => v.detail.includes('V9b') && v.detail.includes(`"${month}"`)),
      `V9b must NOT name "${month}" (declared false negative):\n  ` +
      `${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`,
    );
  });
}

/* ================================================ item 6: interrogative modal exemption (V9b) === */

test('v712 check 17/88 (item 6): "Will you visit us again this month?" validates clean — the ' +
  'refuter\'s own false-positive input', () => {
  const narrative = pack01.good.replace(
    REPLACED_SENTENCE,
    `${REPLACED_SENTENCE} Will you visit us again this month?`,
  );
  const result = validateNarrative(narrative, pack01.pack);
  assert.equal(result.ok, true,
    `expected clean, got:\n  ${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`);
});

const OTHER_INTERROGATIVE_OPENERS = [
  'Would you like a reminder next month?',
  'Could we reach out to your regulars sooner next time?',
  'Do customers usually return within a month?',
  'Is this something worth watching next month?',
];
for (const sentence of OTHER_INTERROGATIVE_OPENERS) {
  test(`v712 check 17/88 (item 6): "${sentence}" (a genuine question) validates clean`, () => {
    const narrative = pack01.good.replace(REPLACED_SENTENCE, `${REPLACED_SENTENCE} ${sentence}`);
    const result = validateNarrative(narrative, pack01.pack);
    assert.equal(result.ok, true,
      `expected clean, got:\n  ${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`);
  });
}

test('v712 check 17/88 (item 6): "Will" used as an invented PERSON name (no interrogative shape) ' +
  'is still caught — the fix narrows the exemption, it does not disable V9b for "Will"', () => {
  const narrative = pack01.good.replace(
    REPLACED_SENTENCE,
    `${REPLACED_SENTENCE} Will asked about his account balance today.`,
  );
  const result = validateNarrative(narrative, pack01.pack);
  assert.ok(
    result.violations.some((v) => v.detail.includes('"Will"')),
    `expected V9b to name "Will":\n  ${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`,
  );
});

/* ================================================================== corpus stays clean, again === */

test('v712: every known-good narrative in the corpus is still clean after all six fixes', () => {
  for (const { file, pack, good } of corpus) {
    const result = validateNarrative(good, pack);
    assert.equal(result.ok, true,
      `${file}'s known-good narrative must be clean:\n  ` +
      `${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`);
  }
});
