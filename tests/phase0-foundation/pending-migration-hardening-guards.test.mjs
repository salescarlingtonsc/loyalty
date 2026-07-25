// Static "applied hardening must not be silently dropped" guards over the PENDING migration set.
//
// Two production defects had the same shape and no gate caught either of them:
//
//   * v66a — `create or replace view public.v_business_billing` re-created a view that v14b had
//     declared `with (security_invoker = on)`, WITHOUT that reloption. A definer-rights view over
//     tenant tables silently became a privilege-escalation surface. Caught only by human review.
//   * v67 rev-2 — `create or replace function public.get_revenue_summary` was rebuilt from its v20
//     source, which predates v21's sweep that hardened EVERY security-definer function to
//     `pg_catalog, public, app, pg_temp`. The rebuild carried v20's `set search_path = public`,
//     silently downgrading the applied catalog. The existing preflight only asserts that SOME
//     search_path is pinned, which is exactly why this slipped through.
//
// Both are "a CREATE OR REPLACE regressed hardening that the applied catalog already had". These
// guards make that class statically detectable BEFORE apply. Each checker is a pure function so it
// can be, and is, proven to FAIL on a deliberately broken fixture below.

import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
// Reused (not re-implemented): the same comment stripper the PS-0 writer scanner was hardened with
// after a `-- don't` comment desynced it. A guard that reads commented-out or narrated SQL as real
// SQL is worse than no guard — this file's own header quotes `set search_path = public` in prose.
import { stripSqlComments } from '../../scripts/ps0/discover-writers.mjs';

const repoRoot = fileURLToPath(new URL('../..', import.meta.url));
const planPath = path.join(repoRoot, 'supabase/canonical-migration-order.plan.json');

// v21 §"Every SECURITY DEFINER function gets a deterministic search path with pg_temp last".
export const CANONICAL_SEARCH_PATH = ['pg_catalog', 'public', 'app', 'pg_temp'];

// A migration may INSERT extra schemas between `public`/`app` and the trailing `pg_temp` when the
// body resolves objects that live outside them. Extras are allowlisted by name so a typo or a junk
// schema still fails, and the exact set of functions using one is pinned below.
const ALLOWED_EXTRA_SCHEMAS = new Set(['extensions']);

// Pinned inventory of pending definer functions whose search_path is a canonical SUPERSET. Adding a
// new one is a deliberate act that must be reviewed, so it has to be recorded here.
const KNOWN_SEARCH_PATH_SUPERSETS = [
  'frenly_v48_calendar_details_reschedule :: public.reschedule_appointment_v48 :: extensions',
];

const splitSearchPath = (raw) =>
  raw
    .split(',')
    .map((entry) => entry.trim().replace(/^["']|["']$/g, '').toLowerCase())
    .filter(Boolean);

/**
 * Why an entry list is not a canonical pin, or null when it is.
 * Canonical = pg_catalog first, pg_temp last, public before app, no unknown extras.
 */
export function searchPathProblem(entries) {
  for (const required of CANONICAL_SEARCH_PATH) {
    if (!entries.includes(required)) return `missing "${required}"`;
  }
  if (entries[0] !== 'pg_catalog') return 'pg_catalog must be first';
  if (entries[entries.length - 1] !== 'pg_temp') return 'pg_temp must be last';
  if (entries.indexOf('public') > entries.indexOf('app')) return 'public must precede app';
  const extras = entries.filter((entry) => !CANONICAL_SEARCH_PATH.includes(entry));
  const unknown = extras.filter((entry) => !ALLOWED_EXTRA_SCHEMAS.has(entry));
  if (unknown.length > 0) return `unexpected schema(s) ${unknown.join(', ')}`;
  return null;
}

/** Every `create [or replace] function public.X ... as $tag$` HEADER in `sql`, comments removed. */
export function publicFunctionHeaders(sql) {
  return [...stripSqlComments(sql).matchAll(
    /create\s+(?:or\s+replace\s+)?function\s+(public\.[a-z0-9_]+)[\s\S]*?\$[a-z0-9_]*\$/gi
  )];
}

/** GUARD 1 — every SECURITY DEFINER public function defined in `sql` must pin the canonical path. */
export function definerSearchPathViolations(sql) {
  const violations = [];
  const definitions = publicFunctionHeaders(sql);
  for (const definition of definitions) {
    const header = definition[0];
    if (!/security\s+definer/i.test(header)) continue;
    const pinned = header.match(/set\s+search_path\s*(?:to|=)\s*([^\n;]+)/i);
    if (!pinned) {
      violations.push({ name: definition[1], searchPath: null, problem: 'no search_path pinned' });
      continue;
    }
    const entries = splitSearchPath(pinned[1]);
    const problem = searchPathProblem(entries);
    if (problem) violations.push({ name: definition[1], searchPath: entries.join(', '), problem });
  }
  return violations;
}

const VIEW_DEFINITION =
  /create\s+(?:or\s+replace\s+)?(?:recursive\s+)?view\s+(?:if\s+not\s+exists\s+)?(public\.[a-z0-9_]+)(\s*with\s*\([^)]*\))?/gi;
const VIEW_ALTER = /alter\s+view\s+(?:if\s+exists\s+)?(public\.[a-z0-9_]+)\s*(set|reset)\s*\(([^)]*)\)/gi;

/**
 * Ordered reloption events for public views in one migration: `create ... view` definitions plus the
 * `alter view ... set/reset (security_invoker = ...)` statements that also change the setting (v66a
 * restored the reloption that way, not by re-creating the view).
 */
export function viewReloptionEvents(sql) {
  const code = stripSqlComments(sql);
  const events = [];
  for (const match of code.matchAll(VIEW_DEFINITION)) {
    events.push({
      offset: match.index,
      type: 'create',
      name: match[1].toLowerCase(),
      securityInvoker: /security_invoker\s*=\s*(?:on|true)/i.test(match[2] ?? ''),
    });
  }
  for (const match of code.matchAll(VIEW_ALTER)) {
    if (!/security_invoker/i.test(match[3])) continue;
    events.push({
      offset: match.index,
      type: 'alter',
      name: match[1].toLowerCase(),
      securityInvoker: match[2].toLowerCase() === 'set' && /security_invoker\s*=\s*(?:on|true)/i.test(match[3]),
    });
  }
  return events.sort((a, b) => a.offset - b.offset);
}

/**
 * GUARD 2 — a pending `create or replace view` must not drop a `security_invoker` reloption that an
 * EARLIER migration in canonical order declared, unless a LATER migration puts it back (which is how
 * the v66→v66a defect+remediation pair reads). `files` is the canonical-ordered migration list.
 */
export function viewReloptionViolations(files) {
  const timeline = new Map(); // view -> ordered events across the whole canonical chain
  for (const file of files) {
    for (const event of viewReloptionEvents(file.sql)) {
      const history = timeline.get(event.name) ?? [];
      history.push({ ...event, migration: file.name, kind: file.kind });
      timeline.set(event.name, history);
    }
  }

  const violations = [];
  for (const [view, history] of timeline) {
    history.forEach((entry, position) => {
      if (entry.kind !== 'pending' || entry.type !== 'create' || entry.securityInvoker) return;
      const declaredBy = history.slice(0, position).filter((prior) => prior.securityInvoker).pop();
      if (!declaredBy) return;
      const restoredBy = history.slice(position + 1).find((later) => later.securityInvoker);
      violations.push({
        view,
        migration: entry.migration,
        declaredBy: declaredBy.migration,
        restoredBy: restoredBy?.migration ?? null,
      });
    });
  }
  return violations;
}

async function orderedMigrations() {
  const plan = JSON.parse(await readFile(planPath, 'utf8'));
  return Promise.all(
    plan.items.map(async (item) => {
      const relativePath =
        item.kind === 'pending'
          ? item.sourcePath
          : `supabase/migrations/${item.version}_${item.name}.sql`;
      return { ...item, relativePath, sql: await readFile(path.join(repoRoot, relativePath), 'utf8') };
    })
  );
}

test('pending SECURITY DEFINER public functions pin the CANONICAL v21 search_path', async () => {
  const failures = [];
  const supersets = [];
  for (const migration of (await orderedMigrations()).filter(({ kind }) => kind === 'pending')) {
    for (const violation of definerSearchPathViolations(migration.sql)) {
      failures.push(`${migration.name}: ${violation.name} has search_path [${violation.searchPath}] — ${violation.problem}`);
    }
    for (const definition of publicFunctionHeaders(migration.sql)) {
      if (!/security\s+definer/i.test(definition[0])) continue;
      const pinned = definition[0].match(/set\s+search_path\s*(?:to|=)\s*([^\n;]+)/i);
      if (!pinned) continue;
      for (const extra of splitSearchPath(pinned[1]).filter((entry) => !CANONICAL_SEARCH_PATH.includes(entry))) {
        supersets.push(`${migration.name} :: ${definition[1]} :: ${extra}`);
      }
    }
  }

  assert.deepEqual(
    failures,
    [],
    'A pending migration re-created a definer function without the v21 hardened search_path ' +
      `(canonical: ${CANONICAL_SEARCH_PATH.join(', ')}). Rebuilding a body from a pre-v21 source ` +
      `silently downgrades the applied catalog:\n  - ${failures.join('\n  - ')}`
  );
  assert.deepEqual(
    supersets.sort(),
    [...KNOWN_SEARCH_PATH_SUPERSETS].sort(),
    'A definer function added a non-canonical schema to its search_path. Justify it and pin it in ' +
      'KNOWN_SEARCH_PATH_SUPERSETS, or drop the extra schema.'
  );
});

test('a pending `create or replace view` never drops an applied security_invoker reloption', async () => {
  const violations = viewReloptionViolations(await orderedMigrations());
  const unremediated = violations.filter(({ restoredBy }) => restoredBy === null);
  assert.deepEqual(
    unremediated.map((v) => `${v.migration}: ${v.view} loses the security_invoker declared by ${v.declaredBy}`),
    [],
    'A pending migration re-created a view without the security_invoker reloption an earlier ' +
      'migration declared. A definer-rights view over tenant tables is a privilege-escalation ' +
      'surface — re-add `with (security_invoker = on)`.'
  );

  // The v66a defect itself: v66 dropped it, v66a put it back. Pinned so removing the remediation
  // cannot pass unnoticed, and so this guard is proven to see the historical instance.
  assert.deepEqual(
    violations.map((v) => `${v.migration}:${v.view}->${v.restoredBy}`),
    ['frenly_v66_ps2live_topup_sale:public.v_business_billing->frenly_v66a_ps2live_billing_view_secinvoker'],
    'the known transient security_invoker drop (v66, remediated by v66a) changed shape'
  );
});

test('GUARD 1 fails on a deliberately broken fixture', () => {
  // The exact v67 rev-2 defect: a v20-era body re-created with the pre-v21 `set search_path = public`.
  const regressed = [
    'create or replace function public.get_revenue_summary(p_business uuid)',
    'returns json',
    'language plpgsql',
    'security definer',
    'set search_path = public',
    'as $$ begin return null; end $$;',
  ].join('\n');
  assert.deepEqual(
    definerSearchPathViolations(regressed),
    [{ name: 'public.get_revenue_summary', searchPath: 'public', problem: 'missing "pg_catalog"' }],
    'GUARD 1 must reject a definer function pinned to a non-canonical search_path'
  );

  // "Some search_path" is not enough — this is what the existing preflight accepts and this rejects.
  const reordered = regressed.replace('set search_path = public', "set search_path to 'public', 'app', 'pg_temp', 'pg_catalog'");
  assert.equal(definerSearchPathViolations(reordered)[0].problem, 'pg_catalog must be first');
  const noPin = regressed.replace('set search_path = public\n', '');
  assert.equal(definerSearchPathViolations(noPin)[0].problem, 'no search_path pinned');
  const junkSchema = regressed.replace('set search_path = public', "set search_path to 'pg_catalog', 'public', 'app', 'attacker', 'pg_temp'");
  assert.equal(definerSearchPathViolations(junkSchema)[0].problem, 'unexpected schema(s) attacker');

  // Whitespace/quoting-insensitive, and a SECURITY INVOKER function is out of scope.
  const canonical = regressed.replace('set search_path = public', 'SET  search_path   TO   pg_catalog,public , app,pg_temp');
  assert.deepEqual(definerSearchPathViolations(canonical), []);
  const invoker = regressed.replace('security definer', 'security invoker');
  assert.deepEqual(definerSearchPathViolations(invoker), []);
});

test('GUARD 2 fails on a deliberately broken fixture', () => {
  // The exact v66a defect shape: applied migration declares security_invoker, a pending one rebuilds
  // the view without it and nothing later restores it.
  const applied = {
    kind: 'catalog-applied',
    name: 'frenly_v14b_billing',
    sql: 'create view public.v_demo_billing with (security_invoker = on) as select 1;',
  };
  const regressing = {
    kind: 'pending',
    name: 'frenly_vXX_regression',
    sql: 'create or replace view public.v_demo_billing as select 1, 2;',
  };
  // v66a restored the real view with ALTER VIEW ... SET, not by re-creating it.
  const remediation = {
    kind: 'pending',
    name: 'frenly_vXXa_repair',
    sql: 'alter view public.v_demo_billing set (security_invoker = true);',
  };

  const unremediated = viewReloptionViolations([applied, regressing]);
  assert.deepEqual(unremediated, [
    {
      view: 'public.v_demo_billing',
      migration: 'frenly_vXX_regression',
      declaredBy: 'frenly_v14b_billing',
      restoredBy: null,
    },
  ], 'GUARD 2 must reject a pending view rebuild that drops an applied security_invoker reloption');

  // A later restoration downgrades it to a transient (reported, but not a hard failure) — the shape
  // the real v66/v66a pair has.
  assert.equal(viewReloptionViolations([applied, regressing, remediation])[0].restoredBy, 'frenly_vXXa_repair');
  // A view that never had the reloption is not retroactively required to gain one.
  assert.deepEqual(
    viewReloptionViolations([
      { kind: 'catalog-applied', name: 'a', sql: 'create view public.v_plain as select 1;' },
      { kind: 'pending', name: 'b', sql: 'create or replace view public.v_plain as select 2;' },
    ]),
    []
  );
});
