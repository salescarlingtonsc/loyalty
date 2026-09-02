/* nestly_v707 — two independent gaps closed in one pass, each proved by an executing test:
 *
 *   A. Check 17 (typed verdicts), round 2. A refuter proved v706's inversion (V10b requires a
 *      POSITIVE marker) still had a laundering gap: a sentence can carry an APPROVED marker AND an
 *      unlisted causal construction in the same breath ("we observe that weekends make customers
 *      return"), and the marker alone used to satisfy V10b regardless of the causal phrase riding
 *      next to it. The SAME refuter proved a second, opposite-shaped bug: a DIRECT_FACT finding
 *      sharing two ordinary words with an ASSOCIATION finding could make V10b flag a plain,
 *      factual DIRECT_FACT sentence that was never making an association claim at all.
 *      ./validate.mjs fixes both: V10 and V10b now share ONE causal-construction list
 *      (CAUSAL_CONSTRUCTIONS) so a marker can never launder a listed cause, and both rules
 *      attribute a sentence to the best-scoring finding on DISTINCTIVE keywords only (typedFindings/
 *      associationOwnersOf) so a tied or winning DIRECT_FACT finding takes the sentence away from
 *      every ASSOCIATION finding.
 *
 *   B. Check 88 (hallucination suite), round 5. A fullwidth slash (U+FF0F, "Tan／Wong") bypassed the
 *      v706 ASCII-slash tokeniser fix outright — a different code point, same shape bug — and every
 *      caseless script other than CJK (Thai, Arabic, Devanagari, Tamil, Bengali, Hebrew, ...) was
 *      invisible to every existing entity check, all of which are built on either a Latin
 *      capitalisation idea (V6/V9/V9b) or a Han/Hangul/Kana run (V11). Fixed by NFKC-normalising
 *      the narrative before any check runs (closes the fullwidth-punctuation class generally, not
 *      just this one slash) and by a new V11b that fires on a run of a caseless, non-CJK script only
 *      when the narrative is predominantly Latin-script — declaring, rather than hiding, that a
 *      narrative actually WRITTEN in one of those languages disables this check entirely.
 *
 * No source-regex assertions: every check below calls the real validateNarrative.
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
const normalFirm = corpus.find((c) => c.file === '01-normal-firm.json');
const FINDING_LABEL = 'weekend visit and return pattern';
const ORIGINAL_SENTENCE =
  'Customers who visit on a weekend also tend to return sooner than customers who visit on a weekday.';

test('v707 setup: known-good corpus narratives are still clean before the round-2 fixes are exercised', () => {
  for (const { file, pack, good } of corpus) {
    const result = validateNarrative(good, pack);
    assert.equal(result.ok, true,
      `${file}'s known-good narrative must be clean:\n  ` +
      `${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`);
  }
});

/* ============================================================ A1. laundering (check 17) ====== */

// Each of these four keeps an APPROVED marker (so v706's V10b alone would have passed it) AND an
// unlisted causal construction in the same window — the exact laundering shape the refuter proved.
const LAUNDERING_CASES = [
  [
    'marker "we observe" + causal "make ... return"',
    'We observe that weekends make customers return sooner than after a weekday visit.',
  ],
  [
    'marker "also tend" + causal "is why"',
    'Customers who visit on a weekend also tend to return sooner than after a weekday visit ' +
      '— the weekend is why.',
  ],
  [
    'marker "also tend" + causal "is why" via pronoun continuation',
    'Customers who visit on a weekend also tend to return sooner than after a weekday visit. ' +
      'This is why they come back.',
  ],
  [
    'marker "we see" (inside "pattern we see") + causal "accounts for"',
    'Weekend visiting accounts for the sooner return pattern we see.',
  ],
];

for (const [label, sentence] of LAUNDERING_CASES) {
  test(`v707 check 17 (laundering): "${label}" still fails, naming the finding`, () => {
    const narrative = pack02.good.replace(ORIGINAL_SENTENCE, sentence);
    assert.notEqual(narrative, pack02.good, `replacement must have taken effect for "${label}"`);

    const result = validateNarrative(narrative, pack02.pack);
    assert.equal(result.ok, false, `"${sentence}" must be rejected`);
    assert.ok(
      result.violations.some(
        (v) => v.rule === RULES.ASSOCIATION_MARKER && v.detail.includes(FINDING_LABEL),
      ),
      `expected V10b to name the ASSOCIATION finding for "${label}":\n  ` +
      `${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`,
    );
  });
}

test('v707 check 17 (laundering): exactly 4 laundering cases are on the list', () => {
  assert.equal(LAUNDERING_CASES.length, 4);
});

/* ============================================================ A2. DIRECT_FACT false positive === */

// A synthetic pack carrying ONE ASSOCIATION finding and ONE DIRECT_FACT finding that deliberately
// share two ordinary words ("zeptowidget", "bundle") — the exact shape the refuter used to trip
// v706's naive "does the sentence mention >=2 of THIS finding's own keywords" attribution. Under the
// v706 code, a sentence mentioning only the two SHARED words would still count as "about" the
// ASSOCIATION finding (which never checked whether a competing finding explained it better), and
// then fail for carrying no marker even though it was a plain DIRECT_FACT sentence.
const FALSE_POSITIVE_PACK = {
  contract_version: 'v176',
  scope: {
    business_name: 'Ordinary Goods',
    period_kind: 'monthly',
    period_start: '2026-08-01',
    period_end: '2026-08-31',
  },
  opportunities: {
    candidates: [
      {
        id: 'zeptowidget_bundle_affinity',
        domain: 'catalogue',
        label: 'zeptowidget bundle affinity trend',
        evidence_class: 'ASSOCIATION',
      },
      {
        id: 'zeptowidget_bundle_fact',
        domain: 'catalogue',
        label: 'zeptowidget bundle monthly record',
        evidence_class: 'DIRECT_FACT',
      },
    ],
  },
};

test('v707 check 17 (attribution): a DIRECT_FACT finding that WINS the sentence blocks V10b, even ' +
  'though the sentence shares two ordinary words with an ASSOCIATION finding', () => {
  // Shares "zeptowidget"/"bundle" with the ASSOCIATION finding (dropped as non-distinctive by the
  // fix) but only carries the DIRECT_FACT finding's OWN distinctive words ("monthly", "record") —
  // no marker anywhere, and under the old naive attribution this used to fail as if it were an
  // unmarked ASSOCIATION claim.
  const sentence = "The zeptowidget bundle's monthly numbers were recorded as strong, a plain " +
    'record for the owner.';
  const result = validateNarrative(sentence, FALSE_POSITIVE_PACK);
  assert.ok(
    result.violations.every((v) => v.rule !== RULES.ASSOCIATION_MARKER),
    `a plain DIRECT_FACT sentence must not trip V10b:\n  ` +
    `${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`,
  );
});

test('v707 check 17 (attribution): a DIRECT_FACT finding that TIES the sentence also blocks V10b', () => {
  // Carries BOTH findings' distinctive words in equal count (affinity+trend vs monthly+record) —
  // an exact tie, the other half of "ties or wins" from the fix.
  const sentence = 'The zeptowidget bundle shows a strong affinity trend this month, a monthly ' +
    'recorded fact for the owner.';
  const result = validateNarrative(sentence, FALSE_POSITIVE_PACK);
  assert.ok(
    result.violations.every((v) => v.rule !== RULES.ASSOCIATION_MARKER),
    `a tied sentence must not be attributed to the ASSOCIATION finding:\n  ` +
    `${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`,
  );
});

test('v707 check 17 (attribution): the SAME ASSOCIATION finding is still caught with no ' +
  'competing DIRECT_FACT tie — the fix narrows attribution, it does not disable V10b', () => {
  const sentence = 'The zeptowidget bundle shows a strong affinity trend this month.';
  const result = validateNarrative(sentence, FALSE_POSITIVE_PACK);
  assert.equal(result.ok, false, 'expected the unmarked ASSOCIATION sentence to be rejected');
  assert.ok(
    result.violations.some(
      (v) => v.rule === RULES.ASSOCIATION_MARKER &&
        v.detail.includes('zeptowidget bundle affinity trend'),
    ),
    `expected V10b to still name the ASSOCIATION finding:\n  ` +
    `${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`,
  );
});

/* ============================================================ B1. fullwidth punctuation ======= */

test('v707 check 88 (fullwidth): "Tan／Wong" (U+FF0F fullwidth solidus) names both regulars, same ' +
  'as the ASCII slash case v706 already fixed', () => {
  const baseline = validateNarrative(normalFirm.good, normalFirm.pack);
  assert.equal(baseline.ok, true,
    `baseline must be clean:\n  ${baseline.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`);

  const narrative = `${normalFirm.good}\nTwo regulars, Tan\uFF0FWong, came back this month.\n`;
  const result = validateNarrative(narrative, normalFirm.pack);
  assert.equal(result.ok, false, 'expected the fullwidth-slash sentence to be rejected');
  for (const expected of ['Tan', 'Wong']) {
    assert.ok(
      result.violations.some((v) => v.rule === RULES.ENTITY && v.detail.includes(expected)),
      `expected an ENTITY violation naming "${expected}":\n  ` +
      `${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`,
    );
  }
});

/* ============================================================ B2. V11b caseless-script names === */

test('v707 check 88 (V11b): a Thai name in an otherwise-English narrative is caught', () => {
  const narrative = `${normalFirm.good}\nYour regular \u0E2A\u0E21\u0E0A\u0E32\u0E22 returned twice this month.\n`;
  const result = validateNarrative(narrative, normalFirm.pack);
  assert.equal(result.ok, false, 'expected the Thai-name sentence to be rejected');
  assert.ok(
    result.violations.some(
      (v) => v.rule === RULES.ENTITY && v.detail.startsWith('V11b:') &&
        v.detail.includes('\u0E2A\u0E21\u0E0A\u0E32\u0E22'),
    ),
    `expected a V11b-labelled ENTITY violation:\n  ` +
    `${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`,
  );
});

test('v707 check 88 (V11b): a caseless-script run that IS in the pack does not fire', () => {
  const pack = {
    ...normalFirm.pack,
    scope: { ...normalFirm.pack.scope, business_name: '\u0E23\u0E49\u0E32\u0E19\u0E01\u0E32\u0E41\u0E1F' },
  };
  const narrative = `${normalFirm.good}\n\u0E23\u0E49\u0E32\u0E19\u0E01\u0E32\u0E41\u0E1F welcomes every regular back.\n`;
  const result = validateNarrative(narrative, pack);
  assert.ok(
    result.violations.every((v) => !(v.rule === RULES.ENTITY && v.detail.startsWith('V11b:'))),
    `a pack-grounded caseless-script string must not fire V11b:\n  ` +
    `${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`,
  );
});

test('v707 check 88 (V11b): a declared limit — a narrative NOT predominantly Latin-script ' +
  'disables the check entirely (a Thai or Tamil narrative needs its own pack-grounded ' +
  'vocabulary before this check can apply, not shipped here)', () => {
  const ANY_LETTER_RE = /\p{L}/gu;
  const LATIN_LETTER_RE = /\p{Script=Latin}/gu;
  const countLetters = (s, re) => (s.match(re) || []).length;
  const baseLatinLetters = countLetters(normalFirm.good, LATIN_LETTER_RE);

  // A Thai paragraph, repeated until it comfortably outweighs the fixture's own Latin letters (a
  // wide margin below the 80% Latin gate, not a knife-edge one) — it also carries an
  // invented-looking name ("สมชาย") that would fire V11b if the gate were not honoured.
  const THAI_UNIT = '\u0E2A\u0E27\u0E31\u0E2A\u0E14\u0E35\u0E04\u0E23\u0E31\u0E1A ' +
    '\u0E19\u0E35\u0E48\u0E04\u0E37\u0E2D\u0E02\u0E49\u0E2D\u0E04\u0E27\u0E32\u0E21\u0E20\u0E32\u0E29\u0E32\u0E44\u0E17\u0E22 ' +
    '\u0E0A\u0E37\u0E48\u0E2D\u0E2A\u0E21\u0E21\u0E15\u0E34\u0E2D\u0E22\u0E48\u0E32\u0E07\u0E2A\u0E21\u0E0A\u0E32\u0E22';
  let filler = '';
  while (countLetters(filler, ANY_LETTER_RE) < baseLatinLetters * 2) filler += ` ${THAI_UNIT}`;

  const narrative = `${normalFirm.good}\n${filler}\n`;
  const totalLetters = countLetters(narrative, ANY_LETTER_RE);
  const latinLetters = countLetters(narrative, LATIN_LETTER_RE);
  assert.ok(latinLetters / totalLetters < 0.8,
    'test setup must actually push the narrative below the 80% Latin-script gate');

  const result = validateNarrative(narrative, normalFirm.pack);
  assert.ok(
    result.violations.every((v) => !v.detail.startsWith('V11b:')),
    `V11b must not fire on a narrative that is not predominantly Latin-script:\n  ` +
    `${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`,
  );
});

test('v707 check 88: every known-good narrative in the corpus stays clean after NFKC ' +
  'normalisation and the new V11b check', () => {
  for (const { file, pack, good } of corpus) {
    const result = validateNarrative(good, pack);
    assert.equal(result.ok, true,
      `${file}'s known-good narrative must stay clean after the v707 changes:\n  ` +
      `${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`);
  }
});
