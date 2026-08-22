#!/usr/bin/env node
/**
 * Regenerate tests/fixtures/db-schema-snapshot.sql.
 *
 *   node scripts/db-tests/snapshot-schema.mjs            # rebuild the snapshot
 *   node scripts/db-tests/snapshot-schema.mjs --check     # rebuild into memory, diff, exit 1 on drift
 *
 * PROVENANCE. The snapshot is a schema-only pg_dump of a scratch cluster that has replayed
 * the committed canonical migration chain (supabase/canonical-migration-order.manifest.json)
 * on top of db/tests/rehearsal/bootstrap.sql. It is derived entirely from files in this
 * repository — no production credentials are used to build it, and none are needed to use it.
 * That is the point: CI restores the snapshot and never talks to production.
 *
 * WHY A SNAPSHOT AND NOT A REPLAY EVERY TIME. The replay is only a few seconds, but it is
 * the thing most likely to break for reasons unrelated to the change under test (see
 * scripts/db-tests/chain-drift-patches.mjs). Freezing it means a Rewards regression fails
 * with a Rewards error, not a 2026-08 migration error. `--check` in CI keeps the two honest.
 *
 * REFRESH IT WHEN: the canonical chain gains migrations you want folded into the baseline.
 * After refreshing, raise SNAPSHOT_WATERMARK_VERSION in scripts/db-tests/lib.mjs to the
 * highest vNNN now baked in, so those migrations stop being applied twice.
 */
import { spawnSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import {
  REPO_ROOT, SNAPSHOT_PATH, SNAPSHOT_WATERMARK_VERSION, ScratchCluster,
  applyBootstrap, replayCanonicalChain, canonicalChainPaths, requirePostgresBinaries,
  isolatedWorkdir, pickFreePort,
} from './lib.mjs';

const CHECK = process.argv.includes('--check');
/* Same isolation rule as run.mjs: a snapshot rebuild must not be able to delete a concurrent
   test run's cluster, or vice versa. */
const { dir: WORK, ephemeral: WORK_IS_TEMP } = isolatedWorkdir('peekaa-db-snapshot');
const PORT = await pickFreePort();

/* pg_dump emits a header whose "Dumped by"/"Dumped from" lines carry the local binary version,
   and Postgres 17 wraps every dump in \restrict/\unrestrict with a RANDOM token. Both make the
   file differ between machines and between runs for no schema reason. Stripped so a diff on this
   file means the schema changed. */
function normalise(sql) {
  return sql
    .split('\n')
    .filter((line) => !/^-- (Dumped from database version|Dumped by pg_dump version)/.test(line))
    .filter((line) => !/^\\(un)?restrict\s/.test(line))
    .join('\n')
    /* The snapshot is restored on top of db/tests/rehearsal/bootstrap.sql, which has already
       created the platform schemas — and `public` exists in any fresh database anyway. Plain
       CREATE SCHEMA would abort the load on line 41 before a single table appeared. */
    .replace(/^CREATE SCHEMA (?!IF NOT EXISTS)/gm, 'CREATE SCHEMA IF NOT EXISTS ')
    .replace(/\n{3,}/g, '\n\n')
    .trimEnd() + '\n';
}

function header(chainCount) {
  return [
    '--',
    '-- Peekaa executed-SQL harness: frozen schema baseline.',
    '--',
    '-- GENERATED FILE — do not hand-edit. Refresh with:',
    '--     node scripts/db-tests/snapshot-schema.mjs',
    '--',
    '-- Provenance: schema-only pg_dump of a scratch Postgres 17 cluster that replayed',
    `-- db/tests/rehearsal/bootstrap.sql + scripts/db-tests/bootstrap-extras.sql, then all`,
    `-- ${chainCount} migrations in supabase/canonical-migration-order.manifest.json order.`,
    '-- Built from repository files only; no production credentials are involved.',
    `-- Baked-in watermark: nestly_v${SNAPSHOT_WATERMARK_VERSION} (see SNAPSHOT_WATERMARK_VERSION).`,
    '--',
    '',
  ].join('\n');
}

let replayNotes = { tolerated: [], pinNotes: [], pinTotal: 0 };

/**
 * The snapshot ships whatever rows the migrations seeded. Tenant rows must never be among
 * them — a baseline carrying somebody's real business would make every test that counts rows
 * a lottery, and would put customer data in the repository.
 */
const TENANT_ROW_CHECKS = [
  ['businesses', 'true'],
  ['clients', 'true'],
  ['sales', 'true'],
  ['appointments', 'true'],
  ['credit_ledger', 'true'],
  ['points_ledger', 'true'],
  ['customer_identities', 'true'],
  ['staff', 'true'],
  /* audit_log legitimately carries four platform rows after a clean replay: two
     SALES_BACKFILL_WINDOW_OPEN/CLOSE pairs written by the migrations that open a backfill
     window. They belong to no tenant (business_id is null), so only tenant-scoped rows are
     a problem here. */
  ['audit_log', 'business_id is not null'],
];

function assertRowsAreSeedOnly(cluster) {
  const dirty = [];
  for (const [table, predicate] of TENANT_ROW_CHECKS) {
    const n = cluster.scalarOrNull('snapshot', `select count(*) from public.${table} where ${predicate}`);
    if (n && n !== '0') dirty.push(`${table}=${n}`);
  }
  if (dirty.length) {
    throw new Error(
      `Refusing to write a snapshot containing tenant rows: ${dirty.join(', ')}.\n`
      + 'A migration in the chain inserted them. Find it and make the snapshot build from a '
      + 'clean replay before committing this file.'
    );
  }
}

async function build() {
  requirePostgresBinaries();
  const cluster = new ScratchCluster({
    dataDir: join(WORK, 'data'),
    port: PORT,
    logFile: join(WORK, 'server.log'),
  });
  mkdirSync(WORK, { recursive: true });
  cluster.init({ fresh: true });
  cluster.start();
  try {
    cluster.createDatabase('snapshot');
    await applyBootstrap(cluster, 'snapshot');
    const planned = canonicalChainPaths({ maxVersion: SNAPSHOT_WATERMARK_VERSION });
    process.stdout.write(`  replaying ${planned.length} canonical migrations (through v${SNAPSHOT_WATERMARK_VERSION})…\n`);
    const { count, tolerated, pinNotes } = await replayCanonicalChain(cluster, 'snapshot', { maxVersion: SNAPSHOT_WATERMARK_VERSION });
    for (const t of tolerated) {
      process.stdout.write(`  TOLERATED  ${t.migration}\n             ${t.error}\n`);
    }
    const pinTotal = pinNotes.reduce((n, x) => n + x.pinsNeutralised, 0);
    process.stdout.write(
      `  neutralised ${pinTotal} start-state body-hash pin(s) across ${pinNotes.length} migration(s)\n`
    );
    replayNotes = { tolerated, pinNotes, pinTotal };

    /* Schema AND data, for the two schemas the product owns. auth/cron/net/storage/vault are
       platform surface and come from bootstrap.sql at restore time, not from here.

       DATA IS NOT OPTIONAL. A --schema-only snapshot looks complete and is not: migrations
       seed reference rows that guards read at runtime. The first build of this snapshot
       omitted them, and every executed test that created a business died on "unknown
       modules: loyalty" — the module registry the dependency trigger consults was empty. No
       tenant rows can leak in, because this database has only ever had migrations applied to
       it; assertRowsAreSeedOnly() below proves that rather than assuming it.

       Comments are kept (no --no-comments): several suites assert on catalog comment text. */
    const dump = spawnSync('pg_dump', [
      '--no-owner', '--no-privileges',
      '--schema=public', '--schema=app', '-d', 'snapshot',
    ], { env: cluster.env, encoding: 'utf8', maxBuffer: 512 * 1024 * 1024 });
    if (dump.status !== 0) throw new Error(`pg_dump failed:\n${dump.stderr}`);

    assertRowsAreSeedOnly(cluster);

    /* Privileges are dropped from the dump above because roles differ between the scratch
       cluster and production; grants that matter to behaviour are re-asserted by the
       executed tests themselves, which is where a grant regression should be caught. */
    return header(count) + normalise(dump.stdout);
  } finally {
    cluster.stop();
    if (WORK_IS_TEMP) rmSync(WORK, { recursive: true, force: true });
  }
}

/**
 * WHAT --check CAN AND CANNOT SEE.
 *
 * The snapshot is NOT byte-reproducible, and cannot be made so: the migration chain seeds
 * reference rows whose ids default to gen_random_uuid(), whose created_at/updated_at default to
 * now(), and whose secrets come from gen_random_bytes(). Every rebuild writes different values
 * for all three, none of which mean anything changed.
 *
 * So --check compares a MASKED form, with timestamps, UUIDs and hex blobs replaced by
 * placeholders. What that still catches is everything worth catching: a table, column,
 * constraint, index, policy, trigger or function added, removed or altered, and any change to
 * the CONTENT of a seeded row — a label, a threshold, a flag, an enum member. What it cannot
 * catch is a change to a seeded row's identity alone, or to a seeded secret.
 *
 * Masking is for comparison only. The written file keeps its real values, because a baseline
 * restored with placeholder ids would not be a working database.
 */
function maskVolatile(sql) {
  return sql
    .replace(/\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(\.\d+)?[+-]\d{2}(:\d{2})?/g, '<timestamp>')
    .replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/g, '<uuid>')
    .replace(/\\\\x[0-9a-f]{16,}/g, '<blob>');
}

const built = await build();

if (CHECK) {
  let current = '';
  try { current = readFileSync(SNAPSHOT_PATH, 'utf8'); } catch { /* missing */ }
  if (maskVolatile(current) !== maskVolatile(built)) {
    process.stderr.write(
      '\nSchema snapshot is stale: replaying the canonical chain no longer reproduces\n'
      + `${SNAPSHOT_PATH}\n\nRefresh it with:\n    node scripts/db-tests/snapshot-schema.mjs\n\n`
    );
    process.exit(1);
  }
  process.stdout.write('Schema snapshot matches a fresh canonical-chain replay.\n');
} else {
  mkdirSync(dirname(SNAPSHOT_PATH), { recursive: true });
  writeFileSync(SNAPSHOT_PATH, built);
  process.stdout.write(`Wrote ${SNAPSHOT_PATH} (${built.length} bytes).\n`);
}
