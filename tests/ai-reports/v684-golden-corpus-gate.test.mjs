/* nestly_v684 — check 90: the golden corpus gate, executed.
 *
 * scripts/quality/ai-report-golden-gate.mjs runs the REAL validateNarrative over every fixture in
 * tests/ai-reports/fixtures/golden-packs/ and fails if a known-good narrative does not validate
 * clean, or a known-bad narrative does. This suite does two things:
 *
 *   1. Runs the same corpus in-process (calling validateNarrative directly, not the script) so a
 *      broken fixture shows up as a normal test failure with a normal stack trace.
 *   2. Actually spawns the gate script as `npm test` / CI would, and asserts it exits 0 against
 *      the shipped corpus — proving the script itself works, not just the logic it wraps.
 *
 * No source-regex assertions: every check below either runs validateNarrative or runs the gate.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { RULES, validateNarrative } from '../../supabase/functions/ai-firm-reports/validate.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const CORPUS_DIR = join(HERE, 'fixtures', 'golden-packs');
const GATE_SCRIPT = join(ROOT, 'scripts', 'quality', 'ai-report-golden-gate.mjs');

function loadCorpus() {
  const files = readdirSync(CORPUS_DIR).filter((f) => f.endsWith('.json')).sort();
  return files.map((file) => ({ file, ...JSON.parse(readFileSync(join(CORPUS_DIR, file), 'utf8')) }));
}

const corpus = loadCorpus();

test('v684 check 90: the golden corpus exists and has at least 6 packs', () => {
  assert.ok(corpus.length >= 6, `expected >= 6 golden packs, found ${corpus.length}`);
  for (const { file, pack, good, bad } of corpus) {
    assert.ok(pack && typeof pack === 'object', `${file}: fixture must carry a "pack" object`);
    assert.equal(typeof good, 'string', `${file}: fixture must carry a "good" narrative string`);
    assert.equal(typeof bad, 'string', `${file}: fixture must carry a "bad" narrative string`);
    assert.notEqual(good, bad, `${file}: good and bad narratives must differ`);
  }
});

test('v684 check 90: the corpus covers the required business shapes', () => {
  // Not a source-regex check on the validator — a content check on the corpus itself, so the
  // fixture set cannot quietly narrow to "six variations on one shape".
  const files = corpus.map((c) => c.file).join(' ');
  for (const shape of ['normal', 'sparse', 'anonymous', 'unavailable', 'whale', 'adversarial']) {
    assert.match(files, new RegExp(shape, 'i'), `expected a "${shape}" fixture in the corpus`);
  }
});

for (const { file, pack, good } of corpus) {
  test(`v684 check 90: ${file} known-good narrative validates clean`, () => {
    const result = validateNarrative(good, pack);
    assert.equal(result.ok, true,
      `${file}'s known-good narrative must pass:\n  ` +
      result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  '));
  });
}

for (const { file, pack, bad } of corpus) {
  test(`v684 check 90: ${file} known-bad narrative is rejected`, () => {
    const result = validateNarrative(bad, pack);
    assert.equal(result.ok, false, `${file}'s known-bad narrative must be caught, but validated clean`);
    assert.ok(result.violations.length > 0);
  });
}

test('v684 check 90 / check 88 (V9): 01-normal-firm.json\'s bad narrative also carries an orphan ' +
  'invented name, and V9 catches it', () => {
    // 01-normal-firm.json's "bad" narrative was extended (nestly_v701) with an orphan single-token
    // invented name ("Priya") with no direct-address cue in front of it — exactly the shape
    // checkOrphanProperNouns (V9) exists to close. It sits alongside the pre-existing fabricated
    // revenue figure, so the pack was already correctly rejected before this addition; this test
    // proves V9 SPECIFICALLY fires on it, not merely that some other rule already would have.
    const fixture = corpus.find((c) => c.file === '01-normal-firm.json');
    assert.ok(fixture, 'expected 01-normal-firm.json in the golden corpus');
    assert.match(fixture.bad, /Priya/, 'the fixture must still carry the orphan name this test checks');
    const result = validateNarrative(fixture.bad, fixture.pack);
    assert.equal(result.ok, false);
    assert.ok(
      result.violations.some((v) => v.rule === RULES.ENTITY && v.detail.includes('Priya')),
      `expected V9 to catch "Priya":\n  ${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`,
    );
  });

test('v684 check 90 / check 88 (V9b): 05-whale-firm.json\'s bad narrative also carries a ' +
  'SENTENCE-INITIAL orphan invented name, and V9b names it', () => {
    // 05-whale-firm.json's "bad" narrative was extended (nestly_v701 refuter fix) with an orphan
    // invented name written as its OWN sentence ("Jasmine mentioned she loves the new
    // collection.") — no direct-address cue, and sentence-initial, exactly the shape the
    // independent refuter used to defeat V9 (checkOrphanProperNouns exempts sentence-initial
    // tokens unconditionally). V9b (checkOrphanProperNounsSentenceInitial) is the rule that must
    // catch this one; this test proves the gate's verdict actually NAMES V9b in the violation
    // detail, not merely that some other rule already would have rejected the pack.
    const fixture = corpus.find((c) => c.file === '05-whale-firm.json');
    assert.ok(fixture, 'expected 05-whale-firm.json in the golden corpus');
    assert.match(fixture.bad, /Jasmine/, 'the fixture must still carry the orphan name this test checks');
    const result = validateNarrative(fixture.bad, fixture.pack);
    assert.equal(result.ok, false);
    assert.ok(
      result.violations.some(
        (v) => v.rule === RULES.ENTITY && v.detail.includes('V9b') && v.detail.includes('Jasmine'),
      ),
      `expected V9b to name "Jasmine":\n  ${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`,
    );
  });

test('v705 check 17 (V10): 02-sparse-firm.json\'s bad narrative rewrites its ASSOCIATION ' +
  'finding as a cause, and V10 names it', () => {
    // 02-sparse-firm.json's pack carries opportunities.candidates[0], an ASSOCIATION finding
    // ("weekend visit and return pattern"). Its "good" narrative states the pattern as observed
    // ("also tend to return sooner"); its "bad" narrative was extended (nestly_v705) to restate
    // the SAME finding with a causal construction ("leads to") instead. checkAssociationCausal-
    // Binding (V10) is the rule that must catch this specific rewrite, not merely that some other
    // rule already would have rejected the pack (the pack was already correctly rejected before
    // this addition, via the pre-existing "Marcus Lim" orphan name).
    const fixture = corpus.find((c) => c.file === '02-sparse-firm.json');
    assert.ok(fixture, 'expected 02-sparse-firm.json in the golden corpus');
    assert.match(fixture.bad, /leads to/, 'the fixture must still carry the causal rewrite this test checks');
    const result = validateNarrative(fixture.bad, fixture.pack);
    assert.equal(result.ok, false);
    assert.ok(
      result.violations.some(
        (v) => v.rule === RULES.CAUSAL_BINDING && v.detail.includes('weekend visit and return pattern'),
      ),
      `expected V10 to name the ASSOCIATION finding:\n  ${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`,
    );
    // And the SAME finding stated as an observed pattern (the "good" narrative) must not fire V10.
    const clean = validateNarrative(fixture.good, fixture.pack);
    assert.ok(clean.violations.every((v) => v.rule !== RULES.CAUSAL_BINDING),
      `the good narrative's observed-pattern phrasing must not trip V10:\n  ` +
      `${clean.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`);
  });

test('v705 check 17 (V10): 06-adversarial-firm.json\'s bad narrative rewrites its ASSOCIATION ' +
  'finding with a DIFFERENT causal construction ("results in"), and V10 names it too', () => {
    // Deliberately a different causal phrase from the 02-sparse-firm.json test above ("results in"
    // vs "leads to"), and neither is one of V3's own CAUSAL_PATTERNS words — proving V10 is doing
    // independent work, not riding on V3's unconditional causal gate.
    const fixture = corpus.find((c) => c.file === '06-adversarial-firm.json');
    assert.ok(fixture, 'expected 06-adversarial-firm.json in the golden corpus');
    assert.match(fixture.bad, /results in/, 'the fixture must still carry the causal rewrite this test checks');
    const result = validateNarrative(fixture.bad, fixture.pack);
    assert.equal(result.ok, false);
    assert.ok(
      result.violations.some(
        (v) => v.rule === RULES.CAUSAL_BINDING &&
          v.detail.includes('Mystery Box purchase and repeat visit link'),
      ),
      `expected V10 to name the ASSOCIATION finding:\n  ${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`,
    );
    const clean = validateNarrative(fixture.good, fixture.pack);
    assert.ok(clean.violations.every((v) => v.rule !== RULES.CAUSAL_BINDING),
      `the good narrative's observed-pattern phrasing must not trip V10:\n  ` +
      `${clean.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`);
  });

test('v705 check 17 (V10): a DIRECT_FACT finding may be stated flatly, even with causal wording ' +
  'nearby, because V10 only ever looks at ASSOCIATION findings', () => {
  // A synthetic pack proves the exemption directly rather than relying on absence-of-evidence: a
  // finding identical in shape to the ASSOCIATION ones above, but classed DIRECT_FACT, must never
  // be flagged by V10 no matter how flatly (or causally) it is worded.
  const pack = {
    scope: { period_kind: 'monthly', period_start: '2026-08-01', period_end: '2026-08-31' },
    opportunities: {
      candidates: [{
        id: 'coverage_gap',
        label: 'tracked item coverage gap',
        pattern: 'Only part of revenue is tracked at the item level.',
        evidence_class: 'DIRECT_FACT',
      }],
    },
  };
  const narrative = '## Summary\nLow item coverage caused a tracked item coverage gap this month.\n' +
    '## What went well\n- Nothing new.\n## What needs attention\n- None.\n## Your customers\n' +
    'No customer detail this period.\n## Do these three things next\n1. Do one thing.\n' +
    '2. Do another thing.\n3. Do a third thing.\n';
  const result = validateNarrative(narrative, pack);
  assert.ok(result.violations.every((v) => v.rule !== RULES.CAUSAL_BINDING),
    `a DIRECT_FACT finding must never trip V10:\n  ` +
    `${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`);
});

test('v705 check 17 (V10): every known-good narrative in the corpus is free of V10 violations', () => {
  // Corpus-wide, not just the two fixtures that carry an ASSOCIATION finding: proves the new rule
  // never fires a false positive anywhere in the shipped known-good set, the same "prove the
  // negative across the whole corpus" shape as v677's own T-pass mutation guard.
  for (const { file, pack, good } of corpus) {
    const result = validateNarrative(good, pack);
    assert.ok(result.violations.every((v) => v.rule !== RULES.CAUSAL_BINDING),
      `${file}'s known-good narrative must not trip V10:\n  ` +
      `${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`);
  }
});

/* v705 check 88, refuter round 2 — five undeclared bypasses in the shared tokeniser V9/V9b build
 * on (orphanWords / isCapitalisedCandidate), each proved against 01-normal-firm.json's OWN
 * known-good narrative with one extra sentence appended: if the sentence were left out, the
 * narrative validates clean (it is the shipped known-good text); appending it must flip the
 * verdict and the violation must NAME the specific invented token, not merely fail for some other
 * reason. Each case is its own regression test so a future change that reopens ANY ONE of the
 * five shows up as its own failure, not a single combined assertion that could pass 4/5.
 */
const V9_REFUTER_CASES = [
  {
    label: 'possessive ("Melissa\'s")',
    sentence: "Your regular Melissa's third visit pleased staff this month.",
    token: 'Melissa',
  },
  {
    label: 'hyphenated ("Mei-Ling")',
    sentence: 'Your regular Mei-Ling returned twice this month.',
    token: 'Mei-Ling',
  },
  {
    label: 'em-dash-glued ("month—Marcus—and")',
    sentence: 'One regular came back twice this month—Marcus—and said thanks.',
    token: 'Marcus',
  },
  {
    label: 'camelCase mid-sentence ("JavaBrew")',
    sentence: 'Your customers tried the new JavaBrew blend this month.',
    token: 'JavaBrew',
  },
  {
    label: 'Unicode ("Zoë")',
    sentence: 'Your regular Zoë came back twice this month.',
    token: 'Zoë',
  },
];

for (const { label, sentence, token } of V9_REFUTER_CASES) {
  test(`v705 check 88: an undetected orphan name via ${label} is now caught by name`, () => {
    const fixture = corpus.find((c) => c.file === '01-normal-firm.json');
    assert.ok(fixture, 'expected 01-normal-firm.json in the golden corpus');

    const baseline = validateNarrative(fixture.good, fixture.pack);
    assert.equal(baseline.ok, true,
      `01-normal-firm.json's known-good narrative must itself be clean before the refuter ` +
      `sentence is appended:\n  ${baseline.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`);

    const narrative = `${fixture.good}\n${sentence}\n`;
    const result = validateNarrative(narrative, fixture.pack);
    assert.equal(result.ok, false, `expected "${sentence}" to be rejected`);
    assert.ok(
      result.violations.some((v) => v.rule === RULES.ENTITY && v.detail.includes(token)),
      `expected an ENTITY violation naming "${token}":\n  ` +
      `${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`,
    );
  });
}

test('v705 check 88: every known-good narrative in the corpus stays clean after the ' +
  'tokeniser widening', () => {
  // The widened shape (internal capitals mid-sentence, hyphenated segments, Unicode letters,
  // dash/slash token boundaries) is strictly MORE tokens than before — this is the corpus-wide
  // proof that widening it did not turn any existing good narrative's own legitimate wording into
  // a false positive.
  for (const { file, pack, good } of corpus) {
    const result = validateNarrative(good, pack);
    assert.equal(result.ok, true,
      `${file}'s known-good narrative must stay clean after the V9/V9b tokeniser widening:\n  ` +
      `${result.violations.map((v) => `${v.rule} :: ${v.detail}`).join('\n  ')}`);
  }
});

test('v684 check 90: a known-good narrative is not passing because the pack was ignored', () => {
  // Same mutation-guard spirit as v677's own T-pass test, applied once to the corpus: swap the
  // known-good and known-bad narratives across the FIRST fixture's pack and confirm the verdict
  // flips both ways. If it didn't, the corpus packs would not actually be doing anything.
  const first = corpus[0];
  const asGood = validateNarrative(first.good, first.pack);
  const asBad = validateNarrative(first.bad, first.pack);
  assert.notEqual(asGood.ok, asBad.ok, `${first.file}: good/bad must not validate identically`);
});

test('v684 check 90: the gate script runs the same corpus and exits 0', () => {
  const output = execFileSync(process.execPath, [GATE_SCRIPT], { encoding: 'utf8' });
  assert.match(output, /ai-report-golden-gate: OK/);
  assert.match(output, new RegExp(`corpus_size=${corpus.length}`));
  for (const { file } of corpus) {
    assert.match(output, new RegExp(`\\[PASS\\] ${file.replace(/\./g, '\\.')}`));
  }
});

test('v684 check 90: the gate script records a PROMPT_VERSION read from index.ts', () => {
  const indexTs = readFileSync(
    join(ROOT, 'supabase', 'functions', 'ai-firm-reports', 'index.ts'), 'utf8');
  const declared = /PROMPT_VERSION\s*=\s*'([^']+)'/.exec(indexTs);
  assert.ok(declared, 'index.ts must declare PROMPT_VERSION for the gate to read');

  const output = execFileSync(process.execPath, [GATE_SCRIPT], { encoding: 'utf8' });
  assert.match(output, new RegExp(`prompt_version=${declared[1]}\\b`),
    'the gate must report the SAME PROMPT_VERSION index.ts declares, not a hard-coded copy');
});

test('v684 check 90: the REAL gate script fails (non-zero exit) on a broken known-good narrative', async () => {
  // Proves the gate script can actually fail, not just always print OK — this runs the real
  // scripts/quality/ai-report-golden-gate.mjs, pointed (via AI_REPORT_GOLDEN_CORPUS_DIR) at a
  // private, temporary one-pack corpus that never touches the shipped fixtures. Its "good"
  // narrative claims a dollar figure that is nowhere in the pack, so it must be REJECTED —
  // making the gate itself fail, since a known-good is supposed to pass.
  const { mkdtempSync, writeFileSync, rmSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const dir = mkdtempSync(join(tmpdir(), 'ai-report-gate-broken-'));
  try {
    writeFileSync(join(dir, '01-broken.json'), JSON.stringify({
      pack: { insights: { at_risk: { customers: 4 } } },
      good: '## Summary\nRevenue was SGD 999,999.99, a number nowhere in the evidence.\n',
      bad: '## Summary\nRevenue was SGD 999,999.99, a number nowhere in the evidence.\n',
    }));

    let threw = false;
    let output = '';
    try {
      output = execFileSync(process.execPath, [GATE_SCRIPT], {
        encoding: 'utf8',
        env: { ...process.env, AI_REPORT_GOLDEN_CORPUS_DIR: dir },
      });
    } catch (error) {
      threw = true;
      output = `${error.stdout || ''}${error.stderr || ''}`;
      assert.equal(error.status, 1);
    }
    assert.ok(threw, 'a broken known-good narrative must make the REAL gate script exit non-zero');
    assert.match(output, /ai-report-golden-gate: FAILED/);
    assert.match(output, /known-good narrative FAILED validation/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
