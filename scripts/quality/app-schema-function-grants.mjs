#!/usr/bin/env node
/* Source-scan for `grant execute on function app.* ... to (public|anon|authenticated)`.
 *
 * WHY THIS EXISTS (nestly_v720). app.v176_evidence_pack was reported PUBLIC-executable in the
 * local rehearsal harness. Production was already correct (verified 2026-09-02, read-only
 * query) -- the exposure was a harness-fidelity bug in scripts/db-tests/baseline-grants.sql,
 * now fixed there. That fix, and the belt-and-braces revoke + internal gate added in
 * db/migrations/20260902_nestly_v720_evidence_pack_grants.sql, are what actually CLOSE the
 * defect; this script is deliberately secondary. It exists only to make the next migration
 * that grants EXECUTE on a schema-`app` function to public/anon/authenticated visible for
 * review at a glance, before it ships.
 *
 * WHAT THIS IS NOT. This is a source-regex scan, not an executable proof -- exactly the trap
 * this repo's own bug-closure protocol names ("a source-regex assertion stays green over dead
 * code"; docs/engineering/BUG_CLOSURE_PROTOCOL.md, False-closure traps). It cannot tell you
 * whether a matched grant is safe (the function may carry its own internal auth check) or
 * whether an app.* function is exposed WITHOUT ever appearing as a literal `grant` statement
 * (Postgres grants EXECUTE to PUBLIC by default on `CREATE FUNCTION`, no GRANT text required --
 * exactly how the original harness-fidelity bug arose). The real, executable proof is
 * db/tests/executed/v720_corpus_evidence_pack_grants.sql, which queries pg_proc/aclexplode
 * against a REAL, fully-migrated database and asserts the true exposed set equals an explicit,
 * justified allowlist. Run that (via `npm run test:db` or
 * `node scripts/db-tests/run.mjs --filter=v720_corpus`) for the actual gate. This script is a
 * grep, printed for a human to read during review -- nothing here fails the build.
 *
 * USAGE
 *   node scripts/quality/app-schema-function-grants.mjs [--json] [dir ...]
 *   npm run sec:app-grants
 *
 * Defaults to scanning db/migrations. Exits 0 always (informational only); pass --json for a
 * machine-readable list instead of the printed table.
 */
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO_ROOT = fileURLToPath(new URL('../..', import.meta.url));

const GRANT_RE =
  /grant\s+(?:execute\s+on\s+function|all(?:\s+privileges)?\s+on\s+(?:function|all\s+functions\s+in\s+schema\s+app))\s+([^;]*?)\s+to\s+([^;]+?);/gis;
const APP_FN_RE = /\bapp\.[a-z0-9_]+\s*\([^)]*\)/i;
const ROLE_RE = /\b(public|anon|authenticated)\b/i;

function stripComments(sql) {
  return sql
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/^[ \t]*--.*$/gm, ' ');
}

function listSqlFiles(dir) {
  const out = [];
  let entries;
  try {
    entries = readdirSync(dir);
  } catch {
    return out;
  }
  for (const entry of entries) {
    const full = join(dir, entry);
    const st = statSync(full);
    if (st.isDirectory()) out.push(...listSqlFiles(full));
    else if (entry.endsWith('.sql')) out.push(full);
  }
  return out.sort();
}

function scanFile(path) {
  const raw = readFileSync(path, 'utf8');
  const sql = stripComments(raw);
  const hits = [];
  let m;
  GRANT_RE.lastIndex = 0;
  while ((m = GRANT_RE.exec(sql))) {
    const [full, targetClause, roleClause] = m;
    const isAppFunctionGrant =
      /\ball\s+functions\s+in\s+schema\s+app\b/i.test(targetClause) ||
      APP_FN_RE.test(targetClause);
    if (!isAppFunctionGrant) continue;
    if (!ROLE_RE.test(roleClause)) continue;
    const roles = (roleClause.match(/\b(public|anon|authenticated|service_role)\b/gi) || [])
      .map((r) => r.toLowerCase());
    if (!roles.some((r) => r === 'public' || r === 'anon' || r === 'authenticated')) continue;
    const line = raw.slice(0, raw.indexOf(full.slice(0, 40))).split('\n').length;
    hits.push({
      file: relative(REPO_ROOT, path),
      line,
      target: targetClause.trim().replace(/\s+/g, ' '),
      roles: [...new Set(roles)],
      statement: full.trim().replace(/\s+/g, ' '),
    });
  }
  return hits;
}

function main() {
  const args = process.argv.slice(2);
  const asJson = args.includes('--json');
  const dirs = args.filter((a) => !a.startsWith('--'));
  const roots = (dirs.length ? dirs : ['db/migrations']).map((d) => join(REPO_ROOT, d));

  const files = roots.flatMap((d) => listSqlFiles(d));
  const hits = files.flatMap(scanFile);

  if (asJson) {
    process.stdout.write(JSON.stringify(hits, null, 2) + '\n');
    return;
  }

  if (hits.length === 0) {
    console.log('app-schema-function-grants: no `grant execute on function app.*` to '
      + 'public/anon/authenticated found in ' + (dirs.length ? dirs.join(', ') : 'db/migrations')
      + '.');
    console.log('(Secondary check only -- see this file\'s header. The proof is '
      + 'db/tests/executed/v720_corpus_evidence_pack_grants.sql.)');
    return;
  }

  console.log(`app-schema-function-grants: ${hits.length} grant statement(s) exposing a `
    + 'schema-app function to public/anon/authenticated -- review each:\n');
  for (const hit of hits) {
    console.log(`  ${hit.file}:${hit.line}`);
    console.log(`    target: ${hit.target}`);
    console.log(`    roles:  ${hit.roles.join(', ')}`);
    console.log(`    stmt:   ${hit.statement.slice(0, 160)}${hit.statement.length > 160 ? '…' : ''}`);
    console.log('');
  }
  console.log('This list is informational (source-regex, not proof -- see the header of this '
    + 'file). Cross-check against db/tests/executed/v720_corpus_evidence_pack_grants.sql\'s '
    + 'v_allowlist_43 / v_known_other before adding a new grant, and add any genuinely new, '
    + 'justified exposure to that fixture\'s allowlist in the same change.');
}

main();
