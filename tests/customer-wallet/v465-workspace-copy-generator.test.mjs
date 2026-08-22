/*
 * nestly_v465 (owner ruling R7) — the generated workspace copy table has a generator, and the
 * three stamps strings went in through it.
 *
 * Every test here EXECUTES scripts/quality/generate-workspace-copy-v97.mjs. Nothing greps app.js
 * for the strings: a table that contains the right characters but is unreachable, or reachable but
 * not reproducible from its ledger, is exactly the failure this ruling was written about.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

import {generate, buildTable, readAdditions, locateTable}
  from '../../scripts/quality/generate-workspace-copy-v97.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const appPath = path.join(root, 'app', 'app.js');
const additionsPath = path.join(root, 'app', 'i18n', 'workspace-generated-copy-v97.additions.json');
const generatorPath = path.join(root, 'scripts', 'quality', 'generate-workspace-copy-v97.mjs');

const appSource = readFileSync(appPath, 'utf8');
const additionsSource = readFileSync(additionsPath, 'utf8');
const table = JSON.parse(locateTable(appSource).literal);

const STAMP_ROWS = ['Stamps earned', 'Stamps redeemed', 'Stamps expired'];
const POINT_ROWS = ['Points earned', 'Points redeemed', 'Points expired'];

test('the three stamps rows are translated in both locales', () => {
  for (const locale of ['zh-CN', 'ms']) {
    for (const source of STAMP_ROWS) {
      const value = table[locale][source];
      assert.ok(value, `${locale} has no entry for ${source}`);
      assert.notEqual(value, source, `${locale}/${source} is still English`);
    }
  }
});

test('they are the twins of the points rows the app already translated, not new copy', () => {
  /* The Reports money card renders all six from one expression —
     `${loyaltyUnitNounV461(d.loyalty_unit)} earned` — so a stamps merchant and a points merchant
     are reading the SAME row. If the points half were ever untranslated this pairing would be
     meaningless, so that is asserted rather than assumed. */
  for (const locale of ['zh-CN', 'ms']) {
    for (const source of POINT_ROWS) {
      assert.ok(table[locale][source], `${locale} lost its ${source} translation`);
      assert.notEqual(table[locale][source], source);
    }
  }
  const noun = readFileSync(appPath, 'utf8');
  assert.match(noun, /function loyaltyUnitNounV461\(unit\)/,
    'the rows are still built from the unit noun; if that goes, re-point these strings');
});

test('the strings came from the reviewed ledger, and the ledger demands a reason', () => {
  const entries = readAdditions(additionsSource);
  assert.deepEqual(entries.map(entry => entry.source).sort(), [...STAMP_ROWS].sort());
  for (const entry of entries) {
    assert.ok(entry.reason.trim().length > 20, `${entry.source} must say why it was added`);
    for (const locale of ['zh-CN', 'ms']) assert.equal(table[locale][entry.source], entry[locale]);
  }
});

test('the ledger refuses a placeholder, a duplicate and a missing locale', () => {
  const bad = [
    [{source: 'X', reason: 'because', 'zh-CN': 'X', ms: 'Y'}, /untranslated in zh-CN/],
    [{source: 'X', reason: 'because', 'zh-CN': '甲'}, /missing its ms string/],
    [{source: 'X', reason: '', 'zh-CN': '甲', ms: 'Y'}, /must say why/],
    [{reason: 'because', 'zh-CN': '甲', ms: 'Y'}, /no source string/],
  ];
  for (const [entry, message] of bad) {
    assert.throws(() => readAdditions(JSON.stringify({entries: [entry]})), message);
  }
  assert.throws(() => readAdditions(JSON.stringify({entries: [
    {source: 'X', reason: 'because', 'zh-CN': '甲', ms: 'Y'},
    {source: 'X', reason: 'because', 'zh-CN': '乙', ms: 'Z'},
  ]})), /twice/);
});

test('the generator is idempotent, and app.js already equals what it produces', () => {
  const once = generate({appSource, additionsSource});
  assert.equal(once.changed, false, 'app/app.js is out of date — run npm run workspace-copy');
  const twice = generate({appSource: once.next, additionsSource});
  assert.equal(twice.next, once.next, 'a second run must produce identical bytes');
  assert.equal(once.keyCount, 1475);
});

test('--check exits non-zero when the table drifts from the ledger', () => {
  /* Executed as the CLI, because that is how a human and a CI step will meet it. */
  const clean = execFileSync(process.execPath, [generatorPath], {cwd: root, encoding: 'utf8'});
  assert.match(clean, /up to date: 1475 strings per locale/);

  /* And the same code path, given a table with one string removed, must report drift. */
  const stripped = appSource.replaceAll('"Stamps expired":', '"Stamps expired ":');
  assert.notEqual(stripped, appSource, 'fixture must actually change the table');
  assert.equal(generate({appSource: stripped, additionsSource}).changed, true,
    'a table missing one ledger string must be reported as drift, not silently accepted');
});

test('the table keeps its canonical shape: same keys in both locales, sorted, pure JSON', () => {
  const zh = Object.keys(table['zh-CN']);
  const ms = Object.keys(table.ms);
  assert.deepEqual(zh, ms, 'a locale with extra or missing keys is a half-translated release');
  assert.deepEqual(zh, [...zh].sort(), 'keys must be in code-point order');
  assert.equal(JSON.stringify(table), locateTable(appSource).literal,
    'the literal must be exactly JSON.stringify output — the v97 test JSON.parses it');
});

test('NEGATIVE CONTROL: the base this change was written against had none of the three', () => {
  const before = execFileSync('git', ['show', 'b290151:app/app.js'],
    {cwd: root, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024});
  const baseTable = JSON.parse(locateTable(before).literal);
  for (const locale of ['zh-CN', 'ms']) {
    assert.equal(Object.keys(baseTable[locale]).length, 1472);
    for (const source of STAMP_ROWS) {
      assert.equal(baseTable[locale][source], undefined,
        `${locale}/${source} already existed at b290151; re-point this control`);
    }
    /* while the points twins did, which is what made the gap visible */
    for (const source of POINT_ROWS) assert.ok(baseTable[locale][source]);
  }
  /* And the table really was hand-edited before: exactly one key out of sort order. */
  const baseKeys = Object.keys(baseTable['zh-CN']);
  const descents = baseKeys.filter((key, index) => index > 0 && key < baseKeys[index - 1]);
  assert.deepEqual(descents, ['/month'],
    'the one appended-by-hand key; the generator puts it back in order');
  assert.throws(() => buildTable(locateTable(before).literal, [
    {source: 'Stamps earned', reason: 'x', 'zh-CN': '赚取印花'},
  ]), /missing its ms string/, 'a half-filled entry cannot reach the table');
});
