import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, relative, resolve } from 'node:path';
import test from 'node:test';

/* nestly_v821 — the "undeclared identifier ships silently" class, applied to edge functions.
 *
 * WHAT WENT WRONG. nestly_v791 restored supabase/functions/stripe-billing-reconcile/index.ts
 * (Stripe returned as the platform billing provider) and it imports drainBoundedProviderPages
 * from ../_shared/billing-reconciliation.ts. nestly_v755 had deleted that helper from the shared
 * module when Razorpay replaced Stripe, and v791 never restored it. Nothing in the repo notices:
 * Deno functions are not built, bundled or type-checked by `npm test`, so a named import with no
 * matching export is a green tree and a `worker boot error: Uncaught SyntaxError ... does not
 * provide an export named 'drainBoundedProviderPages'` in production. The nightly billing
 * reconciliation cron (nestly-v624-billing-reconcile) recorded 503 BOOT_ERROR every night from
 * 2026-09-05 with the deploy looking perfectly healthy.
 *
 * WHAT THIS TEST DOES. It is a static cross-check, not a type checker: for EVERY
 * supabase/functions/<fn>/index.ts and every supabase/functions/_shared/*.ts, it reads each
 * relative import of a local TypeScript module and asserts that every name that import binds is
 * actually exported by the target file. A missing export fails here instead of at worker boot.
 *
 * It deliberately reads only relative (./ or ../) .ts imports — npm:/jsr:/https: specifiers are
 * somebody else's package and are not ours to verify. */

const root = resolve(new URL('../..', import.meta.url).pathname);
const functionsDir = resolve(root, 'supabase/functions');

/* Strip comments and string/template literals so a name mentioned in prose or in a SQL string
   can neither create a false export nor hide a real one. Regex literals are left alone: none of
   these files opens a regex with a quote or a comment marker. */
function stripComments(source) {
  return source
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/(^|[^:])\/\/[^\n]*/g, '$1 ');
}

function stripNoise(source) {
  return stripComments(source)
    .replace(/`(?:\\[\s\S]|[^\\`])*`/g, '``')
    .replace(/'(?:\\[\s\S]|[^\\'\n])*'/g, "''")
    .replace(/"(?:\\[\s\S]|[^\\"\n])*"/g, '""');
}

/* Every name a module makes importable. */
function exportedNames(source) {
  const code = stripNoise(source);
  const names = new Set();
  const declared =
    /\bexport\s+(?:declare\s+)?(?:default\s+)?(?:async\s+)?(?:function\s*\*?|const|let|var|class|type|interface|enum|abstract\s+class)\s+([A-Za-z_$][\w$]*)/g;
  for (const m of code.matchAll(declared)) names.add(m[1]);
  /* export { a, b as c } — the exported name is the one after `as`. */
  for (const m of code.matchAll(/\bexport\s*\{([^}]*)\}/g)) {
    for (const clause of m[1].split(',')) {
      const parts = clause.trim().replace(/^type\s+/, '').split(/\s+as\s+/);
      const name = (parts[1] ?? parts[0] ?? '').trim();
      if (name) names.add(name);
    }
  }
  if (/\bexport\s+default\b/.test(code)) names.add('default');
  return names;
}

/* Every relative-.ts import, with the names it binds. `import * as ns` and bare side-effect
   imports bind no individual name, so they carry none. */
function localImports(source) {
  const code = stripComments(source);
  const out = [];
  /* The clause may not cross a `;` or a string literal: without that bound the match would run
     from an earlier `import ... from 'npm:...'` all the way to this statement's specifier and
     report that statement's bindings as this one's. */
  const re = /\bimport\s+([^;'"`]*?)\s+from\s*['"](\.[^'"]*?\.ts)['"]/g;
  for (const m of code.matchAll(re)) {
    const clause = m[1];
    const names = [];
    const braces = clause.match(/\{([\s\S]*?)\}/);
    if (braces) {
      for (const piece of braces[1].split(',')) {
        const local = piece.trim().replace(/^type\s+/, '').split(/\s+as\s+/)[0].trim();
        if (local) names.push(local);
      }
    }
    const defaultBinding = clause.replace(/\{[\s\S]*?\}/, '').replace(/,/g, ' ').trim();
    if (/^[A-Za-z_$][\w$]*$/.test(defaultBinding)) names.push('default');
    out.push({ specifier: m[2], names });
  }
  return out;
}

function sourceFiles() {
  const files = [];
  for (const entry of readdirSync(functionsDir)) {
    const full = resolve(functionsDir, entry);
    if (!statSync(full).isDirectory()) continue;
    for (const child of readdirSync(full)) {
      if (child.endsWith('.ts')) files.push(resolve(full, child));
    }
  }
  return files;
}

test('every named import an edge function takes from a local module is really exported', () => {
  const files = sourceFiles();
  assert.ok(files.length > 5, 'no edge-function sources were found to check');

  const cache = new Map();
  const missing = [];
  let checked = 0;

  for (const file of files) {
    for (const { specifier, names } of localImports(readFileSync(file, 'utf8'))) {
      const target = resolve(dirname(file), specifier);
      let exported = cache.get(target);
      if (!exported) {
        let text;
        try {
          text = readFileSync(target, 'utf8');
        } catch {
          missing.push(`${relative(root, file)} imports ${specifier}, which does not exist`);
          continue;
        }
        exported = exportedNames(text);
        cache.set(target, exported);
      }
      for (const name of names) {
        checked += 1;
        if (!exported.has(name)) {
          missing.push(
            `${relative(root, file)} imports { ${name} } from ${specifier}, ` +
            `but ${relative(root, target)} does not export it`);
        }
      }
    }
  }

  assert.ok(checked > 20, `only ${checked} local imports were cross-checked; the parser is wrong`);
  assert.deepEqual(missing, [],
    `an edge function imports a name its module does not export — this is a worker boot error, ` +
    `not a type warning:\n  ${missing.join('\n  ')}`);
});
