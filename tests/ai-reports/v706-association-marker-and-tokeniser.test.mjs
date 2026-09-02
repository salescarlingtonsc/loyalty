/* nestly_v706 — two independent gaps closed in one pass, each proved by an executing test:
 *
 *   A. Check 17 (typed verdicts). An independent refuter proved V10's causal-phrase BLACKLIST
 *      (checkAssociationCausalBinding, ./validate.mjs) is evaded by 27/27 ordinary causal idioms
 *      that are simply not on its fixed list — "boosts", "is behind", "so ... that" with words
 *      between the two cue words, a pronoun continuation ("This pushes..."), a bare conditional,
 *      and 23 more, none of which is "because/due to/cause/drive/leads to/results in/thanks to/as
 *      a result/so that/which means...will". V10b (checkAssociationPositiveMarker) inverts the
 *      burden: a sentence that references an ASSOCIATION finding's own vocabulary must POSITIVELY
 *      carry an approved marker phrase, or it fails — no fixed blacklist to run out of words on.
 *      This suite re-creates all 27 idioms against 02-sparse-firm.json's own
 *      "weekend visit and return pattern" ASSOCIATION finding and proves each one is now rejected.
 *
 *   B. Check 88 (hallucination suite), tokeniser round 4. Four more undeclared bypasses in the
 *      shared name tokeniser (orphanWords/isCapitalisedCandidate/hasCapitalisedRunPartner,
 *      ./validate.mjs), each proved against 01-normal-firm.json's own known-good narrative with one
 *      extra sentence appended — the same shape v705's own five-case refuter suite already uses.
 *
 * No source-regex assertions: every check below calls the real validateNarrative.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { RULES, assembleUserPrompt, validateNarrative } from '../../supabase/functions/ai-firm-reports/validate.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const CORPUS_DIR = join(HERE, 'fixtures', 'golden-packs');
const INDEX_TS = join(ROOT, 'supabase', 'functions', 'ai-firm-reports', 'index.ts');

function loadCorpus() {
  const files = readdirSync(CORPUS_DIR).filter((f) => f.endsWith('.json')).sort();
  return files.map((file) => ({ file, ...JSON.parse(readFileSync(join(CORPUS_DIR, file), 'utf8')) }));
}

const corpus = loadCorpus();

/* ============================================================ A. V10b: 27 refuter idioms ===== */

const pack02 = corpus.find((c) => c.file === '02-sparse-firm.json');
const FINDING_LABEL = 'weekend visit and return pattern';
const ORIGINAL_SENTENCE =
  'Customers who visit on a weekend also tend to return sooner than customers who visit on a weekday.';

test('v706 setup: 02-sparse-firm.json still carries the ASSOCIATION finding and its observed-' +
  'pattern sentence this suite rewrites', () => {
  assert.ok(pack02, 'expected 02-sparse-firm.json in the golden corpus');
  assert.match(pack02.good, new RegExp(ORIGINAL_SENTENCE.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  const baseline = validateNarrative(pack02.good, pack02.pack);
  assert.equal(baseline.ok, true,
    `baseline must be clean:\n  ${baseline.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`);
});

// Each of the 27 keeps the finding's own vocabulary (weekend / return / sooner / weekday / visit)
// so sentenceMentionsFinding still binds the sentence to the finding, and deliberately avoids
// every word ASSOCIATION_MARKERS itself matches ("tend", "pattern", "also", "we observe"/"we see",
// "correlat", "coincide", "alongside", "in the same period", "at the same time", "more/less
// often/likely", "appears/seems to") so the marker check has nothing to catch it on by accident.
// None of the 27 uses a V10-blacklisted word either (because/due to/cause/drive/leads to/results
// in/thanks to/as a result/so that/which means...will) — that absence IS the refuter's point.
const CAUSAL_IDIOM_SENTENCES = [
  ['boosts', 'Visiting on a weekend boosts how soon customers return, compared with a weekday visit.'],
  ['fuels', 'Visiting on a weekend fuels a faster return compared with a weekday visit.'],
  ['triggers', 'Visiting on a weekend triggers a faster return than a weekday visit.'],
  ['explains', 'Visiting on a weekend explains why customers return sooner than after a weekday visit.'],
  ['is behind', 'A weekend visit is behind the faster return customers show compared with a weekday visit.'],
  ['owing to', 'Owing to a weekend visit, customers return sooner than after a weekday visit.'],
  ['stems from', 'The faster return stems from visiting on a weekend rather than a weekday.'],
  ['is why', 'A weekend visit is why customers return sooner than after a weekday visit.'],
  ['means that', 'Visiting on a weekend means that customers return sooner than after a weekday visit.'],
  ['translates into', 'Visiting on a weekend translates into a faster return than a weekday visit.'],
  ['so ... that', 'Weekend visits leave customers so satisfied that they return sooner than after a weekday visit.'],
  ['as a consequence of', 'As a consequence of visiting on a weekend, customers return sooner than after a weekday visit.'],
  ['this pushes (pronoun)', 'Weekend visits build stronger momentum than weekday visits. This pushes customers to return sooner.'],
  ['if-conditional', 'If you keep encouraging weekend visits, customers will return sooner than after a weekday visit.'],
  ['pave the way', 'Weekend visits pave the way for customers to return sooner than after a weekday visit.'],
  ['sets up', 'A weekend visit sets up a faster return than a weekday visit.'],
  ['follows from', 'A faster return follows from visiting on a weekend rather than a weekday.'],
  ['accounts for', 'Visiting on a weekend accounts for customers returning sooner than after a weekday visit.'],
  ['is the reason', 'A weekend visit is the reason customers return sooner than after a weekday visit.'],
  ['produces', 'Visiting on a weekend produces a faster return than a weekday visit.'],
  ['gives rise to', 'Visiting on a weekend gives rise to a faster return than a weekday visit.'],
  ['results from', 'The faster return results from visiting on a weekend rather than a weekday.'],
  ['on account of', 'On account of a weekend visit, customers return sooner than after a weekday visit.'],
  ['in light of', 'In light of a weekend visit, customers return sooner than after a weekday visit.'],
  ['brings about', 'Visiting on a weekend brings about a faster return than a weekday visit.'],
  ['spurs', 'Visiting on a weekend spurs a faster return than a weekday visit.'],
  ['prompts', 'Visiting on a weekend prompts a faster return than a weekday visit.'],
];

test('v706 check 17: exactly 27 refuter idioms are on the list', () => {
  assert.equal(CAUSAL_IDIOM_SENTENCES.length, 27);
});

for (const [label, sentence] of CAUSAL_IDIOM_SENTENCES) {
  test(`v706 check 17 (V10b): "${label}" evades V10's blacklist but is now caught by V10b`, () => {
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
    // The whole point of these 27: none of them is one of V10's own fixed blacklist phrases, so
    // V10 (the causal-BINDING rule specifically, not V3's separate unconditional causal gate)
    // must NOT be the rule that catches this sentence — proving V10b is doing new work, not
    // riding on a blacklist hit that already existed.
    assert.ok(
      result.violations.every((v) => v.rule !== RULES.CAUSAL_BINDING),
      `"${label}" was expected to evade V10 (that is the refuter's point) but V10 fired anyway:\n  ` +
      `${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`,
    );
  });
}

test('v706 check 17 (V10b): every known-good narrative in the corpus is free of V10b violations', () => {
  for (const { file, pack, good } of corpus) {
    const result = validateNarrative(good, pack);
    assert.ok(result.violations.every((v) => v.rule !== RULES.ASSOCIATION_MARKER),
      `${file}'s known-good narrative must not trip V10b:\n  ` +
      `${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`);
  }
});

test('v706 check 17 (V10b): 02-sparse-firm.json and 06-adversarial-firm.json carry the only ' +
  'two ASSOCIATION findings in the corpus, and both good narratives already carry an approved ' +
  'marker ("also tend") — no fixture rewrite was needed', () => {
  const withAssociation = corpus.filter(({ pack }) => {
    const stack = [pack];
    let found = false;
    while (stack.length) {
      const node = stack.pop();
      if (!node || typeof node !== 'object') continue;
      if (node.evidence_class === 'ASSOCIATION') { found = true; break; }
      for (const v of Object.values(node)) stack.push(v);
    }
    return found;
  });
  assert.deepEqual(
    withAssociation.map((c) => c.file).sort(),
    ['02-sparse-firm.json', '06-adversarial-firm.json'],
  );
  for (const { file, good } of withAssociation) {
    assert.match(good, /also tend/i, `${file}'s good narrative must carry an approved marker`);
  }
});

test('v706 check 17: the model-facing prompt instructs use of an approved association marker', () => {
  const report = {
    period_kind: 'monthly', period_start: '2026-08-01', period_end: '2026-08-31',
    evidence: { opportunities: { candidates: [] } },
  };
  const prompt = assembleUserPrompt(report);
  assert.match(prompt, /tend to/);
  assert.match(prompt, /ASSOCIATION finding must use one of these words/i);
});

test('v706 check 17: PROMPT_VERSION was bumped for the EVIDENCE_CLASS_INSTRUCTION change', () => {
  const indexTs = readFileSync(INDEX_TS, 'utf8');
  const declared = /PROMPT_VERSION\s*=\s*'([^']+)'/.exec(indexTs);
  assert.ok(declared, 'index.ts must declare PROMPT_VERSION');
  assert.equal(declared[1], 'v706');
});

/* ============================================================ B. check 88, tokeniser round 4 = */

const normalFirm = corpus.find((c) => c.file === '01-normal-firm.json');

const TOKENISER_REFUTER_CASES = [
  {
    label: 'internal apostrophe ("O\'Brien")',
    sentence: "Your regular O'Brien returned twice this month.",
    token: "O'Brien",
  },
  {
    label: 'period-glued honorific ("Mr.Tan")',
    sentence: 'Mr.Tan returned twice this month.',
    token: 'Tan',
  },
  {
    label: 'slash-adjacent double exemption ("Tan/Wong")',
    sentence: 'Two regulars, Tan/Wong, came back this month.',
    // Both names must be named — the bug was that hasCapitalisedRunPartner treated the two
    // slash-split tokens as run partners of EACH OTHER, deferring to V6, while V6's own
    // whitespace-only tokeniser never actually formed that run — so neither rule ever caught
    // either name. Proving both closes the gap in both directions at once.
    tokens: ['Tan', 'Wong'],
  },
  {
    label: 'CJK name ("美玲")',
    sentence: 'Your regular 美玲 returned twice this month.',
    token: '美玲',
  },
];

for (const { label, sentence, token, tokens } of TOKENISER_REFUTER_CASES) {
  test(`v706 check 88: an undetected orphan name via ${label} is now caught by name`, () => {
    const baseline = validateNarrative(normalFirm.good, normalFirm.pack);
    assert.equal(baseline.ok, true,
      `01-normal-firm.json's known-good narrative must itself be clean before the refuter ` +
      `sentence is appended:\n  ${baseline.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`);

    const narrative = `${normalFirm.good}\n${sentence}\n`;
    const result = validateNarrative(narrative, normalFirm.pack);
    assert.equal(result.ok, false, `expected "${sentence}" to be rejected`);

    for (const expected of tokens || [token]) {
      assert.ok(
        result.violations.some((v) => v.rule === RULES.ENTITY && v.detail.includes(expected)),
        `expected an ENTITY violation naming "${expected}":\n  ` +
        `${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`,
      );
    }
  });
}

test('v706 check 88: the CJK rule (V11) names itself in the violation detail', () => {
  const narrative = `${normalFirm.good}\nYour regular 美玲 returned twice this month.\n`;
  const result = validateNarrative(narrative, normalFirm.pack);
  assert.ok(
    result.violations.some((v) => v.rule === RULES.ENTITY && v.detail.startsWith('V11:') && v.detail.includes('美玲')),
    `expected a V11-labelled ENTITY violation:\n  ` +
    `${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`,
  );
});

test('v706 check 88: a single CJK character is a declared limit and is never flagged', () => {
  // 美 alone (one Han character) — the file's own honest-limit note: a run of 2+ is the floor.
  const narrative = `${normalFirm.good}\nYour regular 美 returned twice this month.\n`;
  const result = validateNarrative(narrative, normalFirm.pack);
  assert.ok(
    result.violations.every((v) => !v.detail.includes('美')),
    'a lone CJK character must not be flagged (declared limit)',
  );
});

test('v706 check 88: a CJK run that IS in the pack (e.g. a business name) does not fire', () => {
  const pack = {
    ...normalFirm.pack,
    scope: { ...normalFirm.pack.scope, business_name: '美玲甜品店' },
  };
  const narrative = `${normalFirm.good}\n美玲甜品店 welcomes every regular back.\n`;
  const result = validateNarrative(narrative, pack);
  assert.ok(
    result.violations.every((v) => !(v.rule === RULES.ENTITY && v.detail.startsWith('V11:'))),
    `a pack-grounded CJK string must not fire V11:\n  ` +
    `${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`,
  );
});

test('v706 check 88: every known-good narrative in the corpus stays clean after the tokeniser ' +
  'widening (apostrophe / glued-honorific split / whitespace-only run-partner / CJK)', () => {
  for (const { file, pack, good } of corpus) {
    const result = validateNarrative(good, pack);
    assert.equal(result.ok, true,
      `${file}'s known-good narrative must stay clean after the v706 tokeniser widening:\n  ` +
      `${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`);
  }
});

test('v706 check 88: "Chen H." (a real, whitespace-separated two-token pack name) still stays ' +
  'V6\'s territory, not V9\'s, after the run-partner fix', () => {
  // Mutation guard for the hasCapitalisedRunPartner rewrite: a LEGITIMATE two-word capitalised
  // run, separated by ordinary whitespace, must still be recognised as a run (and therefore left
  // to V6, not double-flagged by V9) — the fix narrows run-partner recognition to whitespace-only
  // gaps, it must not stop recognising the whitespace case that was always correct.
  const pack = {
    ...normalFirm.pack,
    insights: {
      ...normalFirm.pack.insights,
      top_customers: {
        ...normalFirm.pack.insights.top_customers,
        rows: [...normalFirm.pack.insights.top_customers.rows, {
          label: 'Chen H.', revenue_cents: 10000, visits: 1, is_new_this_period: false,
        }],
      },
    },
  };
  const narrative = `${normalFirm.good}\nYour regular Chen H. came back this month.\n`;
  const result = validateNarrative(narrative, pack);
  assert.equal(result.ok, true,
    `a real pack name split by whitespace must not fire:\n  ` +
    `${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`);
});
