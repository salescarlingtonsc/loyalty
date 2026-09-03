#!/usr/bin/env node
// nestly_v684 (check 90) — the golden corpus gate for the AI firm report validator.
//
// WHY THIS EXISTS. Every rule in supabase/functions/ai-firm-reports/validate.mjs is unit-tested
// against one hand-built fixture pack (tests/ai-reports/v677-evidence-safe-generation.test.mjs).
// That proves each RULE works in isolation. It does not prove the validator still agrees with
// reality across the SHAPES of business this product actually serves — a sparse new shop, a
// heavily-cash business, a firm with withheld sections, one with a single whale customer, one
// whose own data is adversarial. This script is that end-to-end check: it runs the real
// validateNarrative (no re-implementation) over a small corpus of packs, each paired with a
// KNOWN-GOOD narrative (must validate clean) and a KNOWN-BAD narrative (must NOT validate clean).
// A prompt or rule change that breaks either direction, for any pack, fails the gate.
//
// GOVERNANCE. supabase/functions/ai-firm-reports/index.ts documents PROMPT_VERSION and requires
// this gate to run clean after any SYSTEM_PROMPT or model change. This script records that
// version (read from index.ts, not duplicated by hand) in its own output so a gate run is
// traceable to the prompt it was run against.
//
// USAGE: node scripts/quality/ai-report-golden-gate.mjs  (exit 0 = clean, exit 1 = a pack failed)
//        npm run ai-report:gate

import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { validateNarrative } from '../../supabase/functions/ai-firm-reports/validate.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
// Overridable ONLY for the test suite's own negative test (a gate that can never be observed to
// fail is not proven to gate anything) — normal runs (npm run ai-report:gate, CI) always use the
// shipped corpus below.
const CORPUS_DIR = process.env.AI_REPORT_GOLDEN_CORPUS_DIR ||
  join(ROOT, 'tests', 'ai-reports', 'fixtures', 'golden-packs');
const INDEX_TS = join(ROOT, 'supabase', 'functions', 'ai-firm-reports', 'index.ts');

function readPromptVersion() {
  try {
    const source = readFileSync(INDEX_TS, 'utf8');
    const match = /PROMPT_VERSION\s*=\s*'([^']+)'/.exec(source);
    return match ? match[1] : 'unknown (PROMPT_VERSION not found in index.ts)';
  } catch (error) {
    return `unknown (could not read index.ts: ${error.message})`;
  }
}

function loadCorpus() {
  const files = readdirSync(CORPUS_DIR).filter((f) => f.endsWith('.json')).sort();
  if (files.length === 0) {
    throw new Error(`no golden pack fixtures found in ${CORPUS_DIR}`);
  }
  return files.map((file) => {
    const path = join(CORPUS_DIR, file);
    const parsed = JSON.parse(readFileSync(path, 'utf8'));
    for (const field of ['pack', 'good', 'bad']) {
      if (!(field in parsed)) throw new Error(`${file}: fixture is missing required field "${field}"`);
    }
    return { file, ...parsed };
  });
}

function runGate() {
  const promptVersion = readPromptVersion();
  const corpus = loadCorpus();
  const results = [];
  let failures = 0;

  for (const { file, description, pack, good, bad } of corpus) {
    const goodVerdict = validateNarrative(good, pack);
    const badVerdict = validateNarrative(bad, pack);

    const goodOk = goodVerdict.ok === true;
    const badFails = badVerdict.ok === false;
    const passed = goodOk && badFails;
    if (!passed) failures += 1;

    results.push({
      file,
      description: description || null,
      passed,
      known_good: {
        expected_ok: true,
        actual_ok: goodVerdict.ok,
        violations: goodOk ? [] : goodVerdict.violations,
      },
      known_bad: {
        expected_ok: false,
        actual_ok: badVerdict.ok,
        // A bad narrative that unexpectedly passed carries no violations to show; that IS the bug.
        caught_by: badFails ? badVerdict.violations.map((v) => v.rule) : [],
      },
    });
  }

  return {
    ok: failures === 0,
    prompt_version: promptVersion,
    corpus_size: corpus.length,
    failures,
    results,
  };
}

function printReport(report) {
  console.log(`ai-report-golden-gate: prompt_version=${report.prompt_version} corpus_size=${report.corpus_size}`);
  for (const r of report.results) {
    const mark = r.passed ? 'PASS' : 'FAIL';
    console.log(`  [${mark}] ${r.file}`);
    if (!r.passed) {
      if (!r.known_good.actual_ok) {
        console.log(`    known-good narrative FAILED validation (must pass):`);
        for (const v of r.known_good.violations.slice(0, 5)) {
          console.log(`      ${v.rule} :: ${v.detail}`);
        }
      }
      if (r.known_bad.actual_ok) {
        console.log(`    known-bad narrative PASSED validation (must fail)`);
      }
    }
  }
  console.log(
    report.ok
      ? `ai-report-golden-gate: OK — ${report.corpus_size}/${report.corpus_size} packs clean`
      : `ai-report-golden-gate: FAILED — ${report.failures}/${report.corpus_size} pack(s) did not gate correctly`,
  );
}

const report = runGate();
printReport(report);
process.exit(report.ok ? 0 : 1);
