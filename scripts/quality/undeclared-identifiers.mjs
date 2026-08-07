#!/usr/bin/env node
/* Undeclared-identifier guard for the app bundle.
 *
 * Why this exists. On 2026-08-07 V200 deleted a `const headline` from the dashboard renderer
 * but left four references to it. `node --check` passed — an undeclared identifier is a runtime
 * ReferenceError, not a syntax error — and all ~1850 tests passed, because none of them execute
 * that render path. The app was deployed and every dashboard threw
 * "Can't find variable: headline" on load. The owner found it, not the test suite.
 * The same shape nearly recurred twice more the same day (`tillBranchIdForCalendar`,
 * `profileBranchScopeLabelV158`).
 *
 * What it checks. Every versioned identifier (a name ending in V<number>, which is this
 * codebase's convention for anything introduced by a numbered change) that is REFERENCED as
 * code must have a declaration somewhere in the same file. That is the exact class of bug
 * above, and versioned names are where it happens, because they are what gets renamed and
 * removed between versions.
 *
 * What it deliberately does not check. Unversioned identifiers, cross-file globals (allowlisted
 * below), property accesses and DOM id strings. This is a targeted guard against a known,
 * repeated, production-breaking mistake — not a general linter.
 *
 * Scope: app/app.js only, and that is on purpose. app-core / app-business / app-customer are
 * build-time SPLITS of this one file that share a single runtime scope, so a reference in one
 * chunk to a declaration in another is correct and would be a false positive here. app/app.js
 * is also the file every edit is made in, so it is the file where the mistake is made.
 *
 * Usage: node scripts/quality/undeclared-identifiers.mjs [file ...]
 */
import { readFileSync } from 'node:fs';

/* Defined in another file and attached to the global scope at load time. */
const CROSS_FILE_GLOBALS = new Set(['NestlyMediaSyncV95']);

/* Comments are stripped so prose that names a deleted function ("V204 removed
   bundleLinePricesV187") is not mistaken for a live reference. */
function stripComments(source) {
  return source
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/^[ \t]*\/\/.*$/gm, ' ');
}

function declarationsIn(source) {
  const declared = new Set();
  const patterns = [
    /\b(?:function|class)\s+([A-Za-z_$][\w$]*)/g,
    /\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)/g,
    /\b(?:const|let|var)\s*\{([^}]*)\}/g,
    /\b([A-Za-z_$][\w$]*)\s*(?::|=[^=])/g,
  ];
  for (const pattern of patterns) {
    for (const match of source.matchAll(pattern)) {
      for (const part of String(match[1]).split(',')) {
        const id = part.trim().replace(/^\.\.\./, '').split(/[=:\s]/)[0];
        if (id) declared.add(id);
      }
    }
  }
  return declared;
}

export function findUndeclared(source) {
  const code = stripComments(source);
  const declared = declarationsIn(code);
  const referenced = new Map();
  for (const match of code.matchAll(/(.)([A-Za-z_$][\w$]*V\d{2,3})\b/g)) {
    const [, previous, name] = match;
    /* '.' is a property access; the quote and '#' cases are DOM id strings and CSS
       selectors, which name elements rather than bindings. */
    if (previous === '.' || previous === "'" || previous === '"' || previous === '#' || previous === '-') continue;
    if (!referenced.has(name)) referenced.set(name, match.index);
  }
  return {
    checked: referenced.size,
    missing: [...referenced.keys()]
      .filter((name) => !declared.has(name) && !CROSS_FILE_GLOBALS.has(name))
      .map((name) => ({ name, index: referenced.get(name) })),
  };
}

function main() {
  const files = process.argv.slice(2);
  const targets = files.length ? files : ['app/app.js'];
  let failed = false;
  for (const file of targets) {
    const source = readFileSync(file, 'utf8');
    const { checked, missing } = findUndeclared(source);
    for (const { name, index } of missing) {
      const line = source.slice(0, index).split('\n').length;
      console.error(`UNDECLARED ${name} — referenced at ${file}:${line} with no declaration`);
      failed = true;
    }
    if (!missing.length) console.log(`${file}: ${checked} versioned references, all declared`);
  }
  process.exit(failed ? 1 : 0);
}

if (import.meta.url === `file://${process.argv[1]}`) main();
