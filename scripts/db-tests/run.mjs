#!/usr/bin/env node
/**
 * Executed-SQL harness.  `npm run test:db`
 *
 * WHAT IT DOES
 *   1. boots a throwaway Postgres 17 cluster in a per-invocation temp dir on a free port,
 *   2. builds a BASELINE database: platform bootstrap + the committed schema snapshot
 *      (tests/fixtures/db-schema-snapshot.sql — see scripts/db-tests/snapshot-schema.mjs),
 *   3. runs every db/tests/executed/*.sql against a private copy of that baseline,
 *   4. builds a MIGRATED database by applying every db/migrations migration newer than the
 *      snapshot watermark, in version order, discovered at run time,
 *   5. runs every db/tests/executed/*.sql again against a private copy of THAT.
 *
 * Steps 3 and 5 are the point. A behavioural suite that only runs after the migration proves
 * the migration is self-consistent; running the same suite before and after proves the
 * migration did not change behaviour that was never supposed to change.
 *
 * A test named for a migration NEWER than the snapshot watermark (v423_*.sql and up) is
 * expected to fail in step 3 — the behaviour it tests does not exist yet — and is reported
 * `n/a` there rather than as a failure. Its gate is step 5. A test at or below the watermark
 * (v422_baseline_behaviours.sql) must pass in BOTH: that is what makes it a regression floor
 * rather than a description of whatever shipped last.
 *
 * EVERY TEST GETS ITS OWN DATABASE, cloned from a template. Not paranoia: the first run of
 * this harness found an executed test that opens with `drop schema public cascade` to build
 * its own miniature schema. Sharing one database let it delete the baseline out from under
 * every file that ran after it, and the resulting failures pointed at innocent migrations.
 * Cloning is also cheap — Postgres copies the template's files directly.
 *
 * WHY THIS EXISTS: before it, `npm test` executed no SQL at all. 334 files under db/tests/
 * were read by regex and never run, so two deliberately planted Rewards defects passed a
 * 3297-test suite. Nothing here mocks the database — real engine, real triggers, real RPCs.
 *
 * NO PRODUCTION ACCESS. The snapshot is built from committed migrations; this script never
 * connects to Supabase and needs no credentials.
 *
 * FLAGS
 *   --baseline-only    stop after step 3 (skip pending migrations)
 *   --migrated-only    skip step 3
 *   --keep             leave the cluster running afterwards (for psql poking)
 *   --filter=<substr>  only run executed tests whose filename contains <substr>
 *
 * ENV
 *   DB_TESTS_WORKDIR   reuse a fixed data directory instead of a fresh temp one
 *   DB_TESTS_PORT      pin the port instead of taking a free one
 *
 * Both default to isolated, and that default is load-bearing: two agents ran this harness
 * concurrently on 2026-08-22 and the second one's fresh-init deleted the first one's cluster
 * mid-suite. Set them only when you want a stable cluster to attach to with psql.
 */
import { mkdirSync, existsSync, rmSync , readFileSync} from 'node:fs';
import { join } from 'node:path';
import {
  SNAPSHOT_PATH, SNAPSHOT_WATERMARK_VERSION, ScratchCluster, applyBootstrap,
  discoverPendingMigrations, discoverExecutedTests, requirePostgresBinaries,
  isolatedWorkdir, pickFreePort,
} from './lib.mjs';

const argv = process.argv.slice(2);
const has = (f) => argv.includes(f);
const filter = (argv.find((a) => a.startsWith('--filter=')) || '').slice('--filter='.length);
/* Isolated by default so two runs cannot delete each other's cluster — see isolatedWorkdir().
   Override with DB_TESTS_WORKDIR / DB_TESTS_PORT when you want a stable pair to poke at. */
const { dir: WORK, ephemeral: WORK_IS_TEMP } = isolatedWorkdir('peekaa-db-tests');
const PORT = await pickFreePort();

const BASELINE_DB = 'peekaa_baseline';
const MIGRATED_DB = 'peekaa_migrated';

const t0 = Date.now();
const since = () => `${((Date.now() - t0) / 1000).toFixed(1)}s`;
const failures = [];
const warnings = [];

function head(text) { process.stdout.write(`\n${text}\n`); }

async function runExecutedSuite(cluster, phase, template, tests) {
  head(`── ${phase} (against ${template}) ──────────────────────`);
  if (!tests.length) {
    process.stdout.write('  (no files in db/tests/executed/)\n');
    return;
  }
  for (const [i, test] of tests.entries()) {
    const db = `peekaa_t${i}_${phase.toLowerCase()}`;
    const started = Date.now();
    cluster.createDatabase(db, { template });
    const pinnedHere = phase === 'BASELINE' && test.migrationPinned;
    try {
      await cluster.psqlFile(db, test.path);
      if (pinnedHere) {
        /* Not a failure, but worth saying: a test named for an unapplied migration that already
           passes is either testing something the migration did not change, or the migration is
           not needed. Either way somebody should look. */
        warnings.push({
          phase,
          file: test.path,
          note: `passed BEFORE v${test.version} was applied — a migration-pinned test that is `
            + 'already green may not be testing what the migration changes',
        });
        process.stdout.write(`  ok?   ${test.name}  (passed before its migration)\n`);
      } else {
        process.stdout.write(`  ok    ${test.name}  (${Date.now() - started}ms)\n`);
      }

      /* Contract: an executed test wraps itself in begin; … rollback; and leaves nothing
         behind. Verified per file so the culprit is named rather than guessed.
         ESCAPE HATCH: a file whose header carries the literal marker
         `HARNESS: PHASED-COMMITS` runs as several committed transactions instead — needed
         when the logic under test is time-ordered (version pins, expiry clocks), because
         now() is transaction-fixed and a single rolled-back transaction collapses every
         event onto one instant. Safe because every test file gets its own database, dropped
         after the run; the marker only waives the leak check, nothing else. */
      const phasedCommits = readFileSync(test.path, 'utf8').includes('HARNESS: PHASED-COMMITS');
      const shipped = cluster.scalarOrNull(db, "select to_regclass('public.businesses')::text");
      if (!shipped) {
        warnings.push({
          phase,
          file: test.path,
          note: 'replaced the shipped schema (public.businesses is gone by the end of the run) '
            + '— this file builds its own miniature schema, so it is not exercising the '
            + 'baseline these tests exist to protect',
        });
      } else {
        const leaked = cluster.scalarOrNull(db, 'select count(*) from public.businesses');
        if (!phasedCommits && leaked && leaked !== '0') {
          failures.push({
            phase,
            file: test.path,
            error: `left ${leaked} row(s) in public.businesses — an executed test must roll `
              + 'back (wrap the whole file in begin; … rollback;)',
          });
          process.stdout.write(`  DIRTY ${test.name} left ${leaked} business row(s) behind\n`);
        }
      }
    } catch (e) {
      if (pinnedHere) {
        /* Expected: the behaviour under test does not exist in the frozen baseline. */
        process.stdout.write(`  n/a   ${test.name}  (needs v${test.version}; not in the baseline)\n`);
      } else {
        failures.push({ phase, file: test.path, error: (e.stderr || e.message).trim() });
        process.stdout.write(`  FAIL  ${test.name}\n`);
        for (const line of (e.stderr || e.message).trim().split('\n').slice(0, 12)) {
          process.stdout.write(`        ${line}\n`);
        }
      }
    } finally {
      cluster.dropDatabase(db);
    }
  }
}

async function main() {
  requirePostgresBinaries();
  if (!existsSync(SNAPSHOT_PATH)) {
    throw new Error(
      `Missing schema snapshot: ${SNAPSHOT_PATH}\n`
      + 'Build it with:  node scripts/db-tests/snapshot-schema.mjs'
    );
  }

  mkdirSync(WORK, { recursive: true });
  process.stdout.write(`  workdir ${WORK}  ·  port ${PORT}\n`);
  const cluster = new ScratchCluster({
    dataDir: join(WORK, 'data'), port: PORT, logFile: join(WORK, 'server.log'),
  });
  cluster.init({ fresh: true });
  cluster.start();

  try {
    head('── building baseline ──────────────────────────────────');
    cluster.createDatabase(BASELINE_DB);
    await applyBootstrap(cluster, BASELINE_DB);
    await cluster.psqlFile(BASELINE_DB, SNAPSHOT_PATH);
    const tables = cluster.scalar(BASELINE_DB,
      "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace "
      + "where n.nspname in ('public','app') and c.relkind='r'");
    const routines = cluster.scalar(BASELINE_DB,
      "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace "
      + "where n.nspname in ('public','app')");
    process.stdout.write(
      `  ${tables} tables, ${routines} routines (snapshot watermark v${SNAPSHOT_WATERMARK_VERSION})  ${since()}\n`
    );

    let tests = discoverExecutedTests();
    if (filter) tests = tests.filter((t) => t.name.includes(filter));

    if (!has('--migrated-only')) await runExecutedSuite(cluster, 'BASELINE', BASELINE_DB, tests);

    if (!has('--baseline-only')) {
      const pending = discoverPendingMigrations();
      head('── applying pending migrations ────────────────────────');
      cluster.createDatabase(MIGRATED_DB, { template: BASELINE_DB });
      if (!pending.length) {
        process.stdout.write(`  (none newer than v${SNAPSHOT_WATERMARK_VERSION} in db/migrations/)\n`);
      }
      for (const m of pending) {
        try {
          await cluster.psqlFile(MIGRATED_DB, m.path);
          process.stdout.write(`  applied  v${m.version}  ${m.name}\n`);
        } catch (e) {
          failures.push({ phase: 'MIGRATION', file: m.path, error: (e.stderr || e.message).trim() });
          process.stdout.write(`  FAILED   v${m.version}  ${m.name}\n`);
          for (const line of (e.stderr || e.message).trim().split('\n').slice(0, 12)) {
            process.stdout.write(`           ${line}\n`);
          }
          /* Later migrations assume this one landed; continuing would report noise. */
          break;
        }
      }
      await runExecutedSuite(cluster, 'MIGRATED', MIGRATED_DB, tests);
    }
  } finally {
    if (has('--keep')) {
      process.stdout.write(
        `\nCluster left running: psql -h 127.0.0.1 -p ${PORT} -U postgres -d ${BASELINE_DB}\n`
        + `Data directory: ${WORK}\n`
      );
    } else {
      cluster.stop();
      /* Only a directory this run created is removed. A DB_TESTS_WORKDIR the caller chose is
         theirs, and deleting it is how the 2026-08-22 collision destroyed another run. */
      if (WORK_IS_TEMP) rmSync(WORK, { recursive: true, force: true });
    }
  }

  head('── summary ────────────────────────────────────────────');
  for (const w of warnings) process.stdout.write(`  WARN  ${w.phase}  ${w.file.split('/').pop()}\n        ${w.note}\n`);
  if (failures.length) {
    for (const f of failures) {
      process.stdout.write(`  ${f.phase}  ${f.file.split('/').pop()}\n    ${f.error.split('\n')[0]}\n`);
    }
    process.stdout.write(`\n${failures.length} failure(s) in ${since()}\n`);
    process.exit(1);
  }
  process.stdout.write(`  all executed SQL passed in ${since()}\n`);
}

await main();
