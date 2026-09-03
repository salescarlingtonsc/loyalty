// The Singapore-day invariant, enforced statically over every NEW migration.
//
// OWNER RULING (2026-09-02): every date and time in Peekaa is Asia/Singapore (GMT+8), never
// UTC. The production session TimeZone is UTC, so in a function body:
//
//     current_date                  is the UTC day, eight hours behind Singapore
//     <timestamptz>::date           is the UTC day of that instant
//     now()::date                   likewise
//     <date>::timestamptz           is UTC midnight, i.e. 08:00 Singapore time
//
// Fourteen sites had drifted onto the UTC day before nestly_v685, and nobody caught it,
// because the estate's convention was the literal `at time zone 'Asia/Singapore'` open-coded
// inline across 88 migration files. Open-coded conventions are not enforceable: a reviewer
// reading `current_date` cannot tell "deliberately UTC" from "forgot". v685 replaced the
// convention with an AUTHORITY — app.sg_today() / sg_day() / sg_day_start() / sg_month() —
// and this guard is the half that makes the authority stick.
//
// SCOPE, deliberately forward-only. Only migrations whose filename date is 2026-09-02 or
// later AND whose version is v685 or higher are checked. v685 is the migration that created
// the authority; before it there was nothing to call, so flagging the 88 historical files
// would produce hundreds of findings nobody can act on and the guard would be turned off
// within a week. Every migration written from now on has somewhere correct to go.
//
// ALLOWLIST — two pattern-based exemptions, no per-file exceptions:
//
//   1. $marker$…$marker$ dollar-quoted blocks. That is the repo's extract-and-diff idiom
//      (nestly_v474, v566, v677, v685): the OLD text a migration is REMOVING is passed as a
//      $marker$ literal so the patch fails closed if the live body has drifted. Flagging it
//      would make it impossible to ever delete a `current_date` — the guard would forbid its
//      own remedy. Note this is narrower than "all dollar quotes": $$ / $function$ / $body$
//      blocks are real code and are fully checked.
//
//   2. The bodies of app.sg_* functions themselves. They are the ONE place a Singapore day is
//      allowed to be computed from raw parts, which is the entire point of having them.
//
//   And one narrower-than-it-looks exclusion: whole `comment on … is '…';` statements. A
//   catalog comment is documentation that happens to be delivered as SQL, and the honest ones
//   NAME the thing they replaced — app.sg_today()'s own comment says it replaces current_date.
//   This drops the statement, not string literals in general: a `execute 'update … current_date'`
//   anywhere else is still caught, which is why the exclusion is written as a quote-aware scan
//   of `comment on` statements rather than "strip all literals".
//
// Comments are stripped before matching, reusing the same lexer the PS-0 writer scanner was
// hardened with. This file's own header quotes `current_date` in prose, and so does v685's;
// a guard that reads narration as SQL is worse than no guard.

import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { stripSqlComments } from '../../scripts/ps0/discover-writers.mjs';

const repoRoot = fileURLToPath(new URL('../..', import.meta.url));
const migrationsDir = path.join(repoRoot, 'db/migrations');

// The authority landed here. Files at or after this point have somewhere correct to go.
export const AUTHORITY_DATE = 20260902;
export const AUTHORITY_VERSION = 685;

export function isInScope(filename) {
  const m = /^(\d{8})_.*?_v(\d+)[_.]/.exec(filename);
  if (!m) return false;
  return Number(m[1]) >= AUTHORITY_DATE && Number(m[2]) >= AUTHORITY_VERSION;
}

/** Allowlist 1: the extract-and-diff anchors — text a migration is removing, not adding. */
export function stripMarkerLiterals(sql) {
  return sql.replace(/\$marker\$[\s\S]*?\$marker\$/g, ' /*marker*/ ');
}

/**
 * `comment on … is '…';` — documentation, dropped whole. Quote-aware, because a catalog
 * comment routinely contains a semicolon and a naive scan to the next `;` would eat live SQL.
 */
export function stripCommentOnStatements(sql) {
  let out = '';
  let i = 0;
  const n = sql.length;
  const head = /^comment\s+on\b/i;
  while (i < n) {
    if ((i === 0 || /[\s;)]/.test(sql[i - 1])) && head.test(sql.slice(i, i + 12))) {
      let j = i;
      while (j < n) {
        if (sql[j] === "'") {
          j += 1;
          while (j < n) {
            if (sql[j] === "'" && sql[j + 1] === "'") { j += 2; continue; }
            if (sql[j] === "'") { j += 1; break; }
            j += 1;
          }
          continue;
        }
        if (sql[j] === ';') { j += 1; break; }
        j += 1;
      }
      out += ' /*comment-on*/ ';
      i = j;
      continue;
    }
    out += sql[i];
    i += 1;
  }
  return out;
}

/** Allowlist 2: the bodies of the app.sg_* helpers, the one place a day may be built by hand. */
export function stripSgAuthorityDefinitions(sql) {
  let out = sql;
  const header = /create\s+(?:or\s+replace\s+)?function\s+app\.sg_[a-z0-9_]+\s*\(/gi;
  for (;;) {
    header.lastIndex = 0;
    const hit = header.exec(out);
    if (!hit) break;
    const open = out.indexOf('$function$', hit.index);
    const close = open === -1 ? -1 : out.indexOf('$function$', open + '$function$'.length);
    // A definition we cannot delimit is NOT silently trusted: cut to end of statement instead
    // of giving up, so an unparseable helper can never smuggle an exemption past the scan.
    const end = close === -1 ? out.indexOf(';', hit.index) : close + '$function$'.length;
    if (end === -1) { out = out.slice(0, hit.index); break; }
    out = `${out.slice(0, hit.index)} /*sg-authority*/ ${out.slice(end)}`;
  }
  return out;
}

// Each rule is a pure function of the scannable text so it can be, and is, proven below to
// fire on a deliberately broken fixture. Presence-only: the message names the remedy.
export const RULES = [
  {
    id: 'current_date',
    pattern: /\bcurrent_date\b/i,
    remedy: 'app.sg_today()',
  },
  {
    id: 'now()::date',
    pattern: /\b(?:now|clock_timestamp|statement_timestamp|transaction_timestamp)\s*\(\s*\)\s*::\s*date\b/i,
    remedy: 'app.sg_today(), or app.sg_day(clock_timestamp())',
  },
  {
    id: '<something>_at::date',
    // Any identifier ending in _at — created_at, paid_at, accepted_at, period_start is not one
    // but v.something_at is — cast straight to date. Qualified or bare.
    pattern: /\b[A-Za-z0-9_]*\.?[A-Za-z0-9_]*_at\s*::\s*date\b/i,
    remedy: 'app.sg_day(<the instant>)',
  },
  {
    id: 'timestamptz::date',
    pattern: /::\s*timestamptz[\s)]*::\s*date\b/i,
    remedy: 'app.sg_day(<the instant>)',
  },
];

export function scannableText(sql) {
  return stripSqlComments(
    stripCommentOnStatements(stripSgAuthorityDefinitions(stripMarkerLiterals(sql)))
  );
}

export function violationsIn(sql) {
  const text = scannableText(sql);
  return RULES.filter((rule) => rule.pattern.test(text)).map((rule) => rule.id);
}

async function inScopeMigrations() {
  const names = (await readdir(migrationsDir)).filter((n) => n.endsWith('.sql') && isInScope(n));
  return Promise.all(names.sort().map(async (name) => ({
    name,
    sql: await readFile(path.join(migrationsDir, name), 'utf8'),
  })));
}

test('the scope filter takes migrations from v685 forward and leaves the history alone', () => {
  assert.equal(isInScope('20260902_nestly_v685_singapore_day_authority.sql'), true);
  assert.equal(isInScope('20260903_nestly_v690_something.sql'), true);
  // Same day, earlier version — written before the authority existed.
  assert.equal(isInScope('20260902_nestly_v680_manual_payment_reopens_workspace.sql'), false);
  // Later version number, earlier calendar date: both conditions must hold.
  assert.equal(isInScope('20260901_nestly_v700_backdated.sql'), false);
  assert.equal(isInScope('migration-order.manifest.json'), false);
});

test('every rule fires on a deliberately broken fixture', () => {
  const broken = {
    'current_date': 'create or replace function app.f() returns date as $$ select current_date; $$;',
    'now()::date': "create or replace function app.f() returns date as $$ select now()::date; $$;",
    '<something>_at::date': 'create or replace function app.f() returns date as $$ select i.paid_at::date; $$;',
    'timestamptz::date': "create or replace function app.f() returns date as $$ select (x::timestamptz)::date; $$;",
  };
  for (const rule of RULES) {
    assert.ok(
      violationsIn(broken[rule.id]).includes(rule.id),
      `rule ${rule.id} did not fire on its own broken fixture — the guard proves nothing`
    );
  }
});

test('the two allowlists are narrow: they exempt anchors and sg_* bodies, nothing else', () => {
  // 1. An extract-and-diff anchor is exempt...
  assert.deepEqual(
    violationsIn("select app.v685_patch('app','f',$marker$current_date$marker$,$marker$app.sg_today()$marker$,1);"),
    []
  );
  // ...but the same text one character outside the anchor is not.
  assert.ok(
    violationsIn("select app.v685_patch('app','f',$marker$x$marker$,$marker$y$marker$,1); select current_date;")
      .includes('current_date')
  );
  // A $$ body is NOT an anchor and stays fully checked.
  assert.ok(violationsIn('create function app.f() as $$ select current_date; $$;').includes('current_date'));

  // 2. The authority's own body is exempt...
  const authority = "create or replace function app.sg_today() returns date language sql stable\n"
    + "as $function$\n  select (now() at time zone 'Asia/Singapore')::date;\n$function$;";
  assert.deepEqual(violationsIn(`${authority}\nselect 1;`), []);
  // ...and the exemption ends with it.
  assert.ok(violationsIn(`${authority}\nselect current_date;`).includes('current_date'));
  // A non-sg_ function in app is not exempt, however similar the name.
  assert.ok(
    violationsIn("create or replace function app.sgx_today() returns date as $function$ select current_date; $function$;")
      .includes('current_date')
  );
});

test('a catalog comment may name what it replaced; nothing else may', () => {
  assert.deepEqual(
    violationsIn("comment on function app.sg_today() is 'replaces current_date; the UTC day';\nselect 1;"),
    []
  );
  // The exclusion ends at the statement's own semicolon, not at the first one inside its text.
  assert.ok(
    violationsIn("comment on function app.f() is 'a; b'; select current_date;").includes('current_date')
  );
  // And a plain string literal elsewhere is NOT exempt.
  assert.ok(
    violationsIn("do $$ begin execute 'update t set d = current_date'; end $$;").includes('current_date')
  );
});

test('narration is not SQL — a comment quoting the forbidden text does not trip the guard', () => {
  assert.deepEqual(violationsIn('-- current_date is the UTC day, and paid_at::date with it\nselect 1;'), []);
  assert.deepEqual(violationsIn('/* now()::date was wrong here */ select 1;'), []);
});

test('every migration from v685 forward decides its days through app.sg_*', async () => {
  const files = await inScopeMigrations();
  assert.ok(files.length > 0, 'no in-scope migration found — the scope filter or the directory moved');
  const offenders = files
    .map((f) => ({ name: f.name, ids: violationsIn(f.sql) }))
    .filter((f) => f.ids.length > 0);
  assert.deepEqual(
    offenders,
    [],
    'these migrations decide a day in UTC. Use the authority instead: '
      + RULES.map((r) => `${r.id} -> ${r.remedy}`).join('; ')
  );
});

test('v685 itself is in scope and clean, so the guard is not measuring an empty set', async () => {
  const files = await inScopeMigrations();
  const v685 = files.find((f) => f.name.includes('_v685_singapore_day_authority'));
  assert.ok(v685, 'nestly_v685 is missing from db/migrations');
  assert.deepEqual(violationsIn(v685.sql), []);
  // It must genuinely contain anchors and authority bodies — otherwise the allowlists above
  // are being exercised only by this file's own fixtures.
  assert.match(v685.sql, /\$marker\$/);
  assert.match(v685.sql, /create or replace function app\.sg_today\(\)/);
});
