#!/usr/bin/env node
/*
 * nestly_v465 — the generator for WORKSPACE_GENERATED_COPY_V97.
 *
 * WHY THIS EXISTS. `WORKSPACE_GENERATED_COPY_V97` in app/app.js is a machine-generated translation
 * table: one frozen JSON object, 1472 source strings per locale, produced in a single pass at v97
 * and never regenerated since. It had no generator in this repo. That is why the only way anyone
 * could add a string was to open a 190KB single-line literal and edit it by hand, and why exactly
 * one entry — "/month" — sits stranded past the end of an otherwise perfectly sorted key order:
 * somebody appended it. When nestly_v461 needed three more strings its author correctly refused to
 * repeat that, and said whoever owns the generator should add them. Nobody did, because nobody did.
 *
 * WHAT IT OWNS. Mutations of the table, and its canonical form:
 *   - source of the additions: app/i18n/workspace-generated-copy-v97.additions.json, a reviewed
 *     ledger where each entry carries its source string, both locales, and why it was added;
 *   - the table's shape: both locales carry the SAME key set, keys sorted by code point, serialised
 *     with JSON.stringify — which is byte-for-byte what the deployed table already is, so adopting
 *     this generator rewrites nothing except the additions and "/month"'s position.
 * It deliberately does NOT own the 1472 existing translations. Those stay where they are, in
 * app/app.js, and are read back out on every run: this is a merge, not a re-translation, so a run
 * can never silently replace reviewed copy with something new.
 *
 * Curated overrides for critical labels still belong in WORKSPACE_COPY_V97, which beats this table
 * at lookup time (curated ?? generated ?? source).
 *
 *   node scripts/quality/generate-workspace-copy-v97.mjs            # --check (default)
 *   node scripts/quality/generate-workspace-copy-v97.mjs --write
 *
 * --check exits 1 when app/app.js does not already equal what --write would produce, so the table
 * cannot drift from its ledger. Running --write twice produces identical bytes.
 */
import {readFileSync, writeFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const appPath = path.join(root, 'app', 'app.js');
const additionsPath = path.join(root, 'app', 'i18n', 'workspace-generated-copy-v97.additions.json');

/* The exact anchors tests/customer-wallet/v97-workspace-localization-acceptance.test.mjs slices
   between. If either moves, that test fails too, so the two cannot drift apart quietly. */
const OPEN = 'const WORKSPACE_GENERATED_COPY_V97=Object.freeze(';
const CLOSE = ');\nconst workspaceTextSourcesV97';
const LOCALES = ['zh-CN', 'ms'];

export function locateTable(source) {
  const from = source.indexOf(OPEN);
  if (from < 0) throw new Error('WORKSPACE_GENERATED_COPY_V97 not found in app/app.js');
  const to = source.indexOf(CLOSE, from + OPEN.length);
  if (to <= from) throw new Error('WORKSPACE_GENERATED_COPY_V97 has no closing anchor');
  return {start: from + OPEN.length, end: to, literal: source.slice(from + OPEN.length, to)};
}

export function readAdditions(raw) {
  const parsed = JSON.parse(raw);
  const entries = Array.isArray(parsed.entries) ? parsed.entries : [];
  const seen = new Set();
  for (const entry of entries) {
    const source = entry?.source;
    if (typeof source !== 'string' || !source.length) {
      throw new Error(`additions entry has no source string: ${JSON.stringify(entry)}`);
    }
    if (seen.has(source)) throw new Error(`additions list names ${JSON.stringify(source)} twice`);
    seen.add(source);
    if (typeof entry.reason !== 'string' || !entry.reason.trim()) {
      throw new Error(`${JSON.stringify(source)} must say why it was added`);
    }
    for (const locale of LOCALES) {
      const value = entry[locale];
      if (typeof value !== 'string' || !value.trim()) {
        throw new Error(`${JSON.stringify(source)} is missing its ${locale} string`);
      }
      /* A "translation" identical to the source is a placeholder, and a placeholder in a
         translation table reads as finished work. */
      if (value === source) {
        throw new Error(`${JSON.stringify(source)} is untranslated in ${locale}`);
      }
    }
  }
  return entries;
}

export function buildTable(existingLiteral, entries) {
  const table = JSON.parse(existingLiteral);
  for (const locale of LOCALES) {
    if (!table[locale] || typeof table[locale] !== 'object') {
      throw new Error(`the generated table has no ${locale} section`);
    }
  }
  for (const entry of entries) {
    for (const locale of LOCALES) {
      const value = entry?.[locale];
      /* Assigning undefined would still CREATE the key, so the key-set check below would pass and
         a locale would ship an entry with no string in it. Refuse instead. */
      if (typeof value !== 'string' || !value.length) {
        throw new Error(`${JSON.stringify(entry?.source)} is missing its ${locale} string`);
      }
      table[locale][entry.source] = value;
    }
  }
  const keys = [...new Set(LOCALES.flatMap(locale => Object.keys(table[locale])))].sort();
  const missing = [];
  for (const locale of LOCALES) {
    for (const key of keys) if (!(key in table[locale])) missing.push(`${locale}: ${key}`);
  }
  if (missing.length) {
    throw new Error(`both locales must carry the same key set; missing ${missing.join(', ')}`);
  }
  const rebuilt = {};
  for (const locale of LOCALES) {
    const section = {};
    for (const key of keys) section[key] = table[locale][key];
    rebuilt[locale] = section;
  }
  return {literal: JSON.stringify(rebuilt), keyCount: keys.length};
}

export function generate({appSource, additionsSource}) {
  const {start, end, literal} = locateTable(appSource);
  const entries = readAdditions(additionsSource);
  const {literal: rebuilt, keyCount} = buildTable(literal, entries);
  return {
    next: appSource.slice(0, start) + rebuilt + appSource.slice(end),
    changed: rebuilt !== literal,
    keyCount,
    addedCount: entries.length,
  };
}

function main(argv) {
  const write = argv.includes('--write');
  const appSource = readFileSync(appPath, 'utf8');
  const additionsSource = readFileSync(additionsPath, 'utf8');
  const {next, changed, keyCount, addedCount} = generate({appSource, additionsSource});
  if (!changed) {
    process.stdout.write(
      `WORKSPACE_GENERATED_COPY_V97 is up to date: ${keyCount} strings per locale, ` +
      `${addedCount} in the additions ledger.\n`);
    return 0;
  }
  if (!write) {
    process.stderr.write(
      'WORKSPACE_GENERATED_COPY_V97 does not match its additions ledger.\n' +
      'Run: node scripts/quality/generate-workspace-copy-v97.mjs --write\n');
    return 1;
  }
  writeFileSync(appPath, next);
  process.stdout.write(
    `WORKSPACE_GENERATED_COPY_V97 rewritten: ${keyCount} strings per locale.\n`);
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = main(process.argv.slice(2));
}
