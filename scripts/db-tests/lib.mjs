/**
 * Shared plumbing for the executed-SQL harness: scratch Postgres cluster lifecycle, psql
 * invocation, canonical-chain replay, and dynamic discovery of the files sibling work drops
 * into db/migrations/ and db/tests/executed/.
 *
 * No Docker, no Supabase CLI, no production credentials. A local Postgres 17 binary is the
 * only requirement (`initdb`, `pg_ctl`, `psql`, `createdb`, `pg_dump` on PATH).
 */
import { spawn, spawnSync } from 'node:child_process';
import { createServer } from 'node:net';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { existsSync, mkdirSync, readdirSync, readFileSync, appendFileSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  prepareMigrationSql, TOLERATED_CHAIN_FAILURES, CHAIN_NON_MIGRATIONS,
} from './chain-drift-patches.mjs';

export const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');

/** The version the committed schema snapshot was frozen at. Migrations newer than this are
 *  applied on top of the snapshot at run time; see discoverPendingMigrations(). */
export const SNAPSHOT_WATERMARK_VERSION = 422;

export const SNAPSHOT_PATH = join(REPO_ROOT, 'tests/fixtures/db-schema-snapshot.sql');
/* The snapshot is dumped with --no-privileges, so the roles it restores hold no grants at all.
   Applied immediately after it to restore Supabase's baseline posture, without which the
   migration chain halts at v599 and no v6xx migration reaches the harness — see the file. */
export const BASELINE_GRANTS_PATH = join(REPO_ROOT, 'scripts/db-tests/baseline-grants.sql');
export const EXECUTED_TESTS_DIR = join(REPO_ROOT, 'db/tests/executed');

const PG_ENV = (port) => ({
  ...process.env,
  PGHOST: '127.0.0.1',
  PGPORT: String(port),
  PGUSER: 'postgres',
  PGDATABASE: 'postgres',
  LC_ALL: 'C',
});

function must(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, { encoding: 'utf8', ...opts });
  if (r.error) throw r.error;
  if (r.status !== 0) {
    throw new Error(`${cmd} ${args.join(' ')} exited ${r.status}\n${r.stderr || ''}${r.stdout || ''}`);
  }
  return r;
}

export function requirePostgresBinaries() {
  const missing = ['initdb', 'pg_ctl', 'psql', 'createdb', 'pg_dump'].filter((bin) => {
    const r = spawnSync('sh', ['-c', `command -v ${bin}`], { encoding: 'utf8' });
    return r.status !== 0;
  });
  if (missing.length) {
    throw new Error(
      `Postgres client/server binaries not on PATH: ${missing.join(', ')}.\n`
      + '  macOS:  brew install postgresql@17 && brew link --force postgresql@17\n'
      + '  Debian: apt-get install -y postgresql-17 postgresql-client-17 '
      + '(then add /usr/lib/postgresql/17/bin to PATH)'
    );
  }
}

/* ------------------------------------------------------- isolation primitives */

/**
 * A workdir and a port that no other run can be using.
 *
 * NOT a nicety. Two agents ran this harness at the same time on 2026-08-22: the second one's
 * `init({fresh: true})` deleted the shared $TMPDIR/peekaa-db-tests directory out from under the
 * first, and its cluster on the fixed port 54499 died mid-suite. The failure surfaced as
 * unrelated SQL errors in the innocent run, which is the worst possible way to lose an hour.
 *
 * Both remain overridable — DB_TESTS_WORKDIR and DB_TESTS_PORT — because a stable pair is what
 * you want when you are poking at a kept cluster with psql. The DEFAULT is isolated.
 */
export function isolatedWorkdir(prefix) {
  if (process.env.DB_TESTS_WORKDIR) return { dir: process.env.DB_TESTS_WORKDIR, ephemeral: false };
  return { dir: mkdtempSync(join(tmpdir(), `${prefix}-`)), ephemeral: true };
}

/** Ask the OS for a free TCP port by binding 0 and reading back what it gave us. */
export function pickFreePort() {
  if (process.env.DB_TESTS_PORT) return Promise.resolve(Number(process.env.DB_TESTS_PORT));
  return new Promise((ok, fail) => {
    const probe = createServer();
    probe.on('error', fail);
    probe.listen(0, '127.0.0.1', () => {
      const { port } = probe.address();
      probe.close(() => ok(port));
    });
  });
}

/* ------------------------------------------------------------------ cluster */

export class ScratchCluster {
  constructor({ dataDir, port, logFile }) {
    this.dataDir = dataDir;
    this.port = port;
    this.logFile = logFile;
    this.started = false;
  }

  get env() { return PG_ENV(this.port); }

  init({ fresh = true } = {}) {
    /* A previous crashed run can leave a postmaster holding the port with its data directory
       already deleted; the next start then fails with "Address already in use" and a stack
       trace that says nothing about why. Shut the old one down through its own data dir
       first, while that still means something. */
    if (existsSync(join(this.dataDir, 'postmaster.pid'))) {
      spawnSync('pg_ctl', ['-D', this.dataDir, '-m', 'immediate', '-w', 'stop'],
        { env: { ...process.env, LC_ALL: 'C' }, encoding: 'utf8' });
    }
    if (fresh && existsSync(this.dataDir)) rmSync(this.dataDir, { recursive: true, force: true });
    if (!existsSync(this.dataDir)) {
      mkdirSync(dirname(this.dataDir), { recursive: true });
      /* LC_ALL=C avoids the macOS "postmaster became multithreaded during startup" locale bug
         documented in db/tests/rehearsal/README.md. */
      must('initdb', ['-D', this.dataDir, '-U', 'postgres', '-E', 'UTF8', '--no-locale', '-A', 'trust'],
        { env: { ...process.env, LC_ALL: 'C' } });
      appendFileSync(join(this.dataDir, 'postgresql.conf'), [
        `port = ${this.port}`,
        "listen_addresses = '127.0.0.1'",
        /* TCP only: macOS socket paths under a scratchpad exceed the 107-byte limit. */
        "unix_socket_directories = ''",
        /* Supabase runs UTC. Several defects only reproduce when the server clock disagrees
           with SGT, so this is load-bearing, not cosmetic. */
        "timezone = 'UTC'",
        /* Disposable cluster: durability buys nothing and costs seconds. */
        'fsync = off',
        'synchronous_commit = off',
        'full_page_writes = off',
        '',
      ].join('\n'));
    }
  }

  start() {
    must('pg_ctl', ['-D', this.dataDir, '-l', this.logFile, '-w', '-o', `-p ${this.port}`, 'start'],
      { env: { ...process.env, LC_ALL: 'C' } });
    this.started = true;
  }

  stop() {
    if (!this.started) return;
    spawnSync('pg_ctl', ['-D', this.dataDir, '-m', 'immediate', '-w', 'stop'],
      { env: { ...process.env, LC_ALL: 'C' }, encoding: 'utf8' });
    this.started = false;
  }

  createDatabase(name, { template = null } = {}) {
    spawnSync('dropdb', ['--if-exists', name], { env: this.env, encoding: 'utf8' });
    must('createdb', template ? ['-T', template, name] : [name], { env: this.env });
  }

  dropDatabase(name) {
    spawnSync('dropdb', ['--if-exists', '--force', name], { env: this.env, encoding: 'utf8' });
  }

  /** Single-value query that returns null instead of throwing when the SQL cannot run. */
  scalarOrNull(db, sql) {
    const r = spawnSync('psql', ['-d', db, '-X', '-t', '-A', '-c', sql], { env: this.env, encoding: 'utf8' });
    return r.status === 0 ? r.stdout.trim() : null;
  }

  /**
   * Run a .sql file with `psql -f <path>`.
   *
   * Deliberately not piped through stdin: psql then reports errors against the real file and
   * line number, and a 5 MB snapshot does not race a psql that exits early (which showed up
   * as an unhandled EPIPE rather than the SQL error that caused it).
   */
  psqlFile(db, file, { quiet = true } = {}) {
    return this.#spawnPsql(db, ['-f', file], null, { label: file, quiet });
  }

  /** Run SQL text through psql's stdin with ON_ERROR_STOP. */
  psql(db, sql, { label = '<sql>', quiet = true } = {}) {
    return this.#spawnPsql(db, ['-f', '-'], sql, { label, quiet });
  }

  #spawnPsql(db, fileArgs, stdinText, { label, quiet }) {
    return new Promise((ok, fail) => {
      const args = ['-d', db, '-v', 'ON_ERROR_STOP=1', '-X', ...fileArgs];
      if (quiet) args.push('-q');
      const child = spawn('psql', args, { env: this.env, stdio: [stdinText == null ? 'ignore' : 'pipe', 'pipe', 'pipe'] });
      let out = ''; let err = '';
      child.stdout.on('data', (d) => { out += d; });
      child.stderr.on('data', (d) => { err += d; });
      child.on('error', fail);
      child.on('close', (code) => {
        if (code === 0) ok({ stdout: out, stderr: err });
        else fail(Object.assign(new Error(`psql failed on ${label}`), { label, stderr: err, stdout: out }));
      });
      if (stdinText != null) {
        /* psql can exit before the whole script is written (ON_ERROR_STOP on an early
           statement). The close handler already carries the real error, so a broken pipe
           here is noise, not the failure. */
        child.stdin.on('error', () => {});
        child.stdin.end(stdinText);
      }
    });
  }

  /** Single-value query, trimmed. */
  scalar(db, sql) {
    const r = must('psql', ['-d', db, '-X', '-t', '-A', '-c', sql], { env: this.env });
    return r.stdout.trim();
  }
}

/* ------------------------------------------------------------- chain replay */

/**
 * Canonical manifest order, optionally cut off at a version.
 *
 * The cutoff matters: sibling work lands new migrations in supabase/migrations AND extends
 * the manifest. Without it the snapshot would silently absorb whatever shipped that day and
 * then those same migrations would be applied a second time from db/migrations. Pinning the
 * snapshot at the watermark keeps it a fixed baseline no matter what else lands.
 */
export function canonicalChainPaths({ maxVersion = null } = {}) {
  const manifest = JSON.parse(
    readFileSync(join(REPO_ROOT, 'supabase/canonical-migration-order.manifest.json'), 'utf8')
  );
  return manifest.items
    .map((item) => item.path)
    .filter((path) => {
      if (maxVersion == null) return true;
      const m = /_v(\d+)[a-z]?_/.exec(path.split('/').pop());
      return !m || Number(m[1]) <= maxVersion;
    });
}

/** bootstrap.sql + bootstrap-extras.sql: the platform surface hosted Supabase provides. */
export async function applyBootstrap(cluster, db) {
  await cluster.psqlFile(db, join(REPO_ROOT, 'db/tests/rehearsal/bootstrap.sql'));
  await cluster.psqlFile(db, join(REPO_ROOT, 'scripts/db-tests/bootstrap-extras.sql'));
}

/** Replay every committed migration in canonical manifest order. */
export async function replayCanonicalChain(cluster, db, { onFile, maxVersion = null } = {}) {
  const paths = canonicalChainPaths({ maxVersion });
  const tolerated = [];
  const pinNotes = [];
  const skipped = [];
  for (const relPath of paths) {
    if (onFile) onFile(relPath);
    const nonMigration = CHAIN_NON_MIGRATIONS.find((n) => n.migration === relPath);
    if (nonMigration) { skipped.push(nonMigration); continue; }
    const sql = prepareMigrationSql(relPath, readFileSync(join(REPO_ROOT, relPath), 'utf8'), pinNotes);
    try {
      await cluster.psql(db, sql, { label: relPath });
    } catch (e) {
      const text = e.stderr || e.message || '';
      const allow = TOLERATED_CHAIN_FAILURES.find(
        (t) => t.migration === relPath && text.includes(t.expectError)
      );
      if (!allow && !process.env.DB_TESTS_DISCOVER) {
        throw new Error(`canonical chain replay failed at ${relPath}\n${text}`);
      }
      /* A tolerated migration aborts its own transaction, so nothing it did is left behind —
         the database is exactly as the previous migration left it. */
      tolerated.push({
        migration: relPath,
        error: text.trim().split('\n').filter((l) => l.startsWith('psql:'))[0] || text.trim().split('\n')[0],
        supersededBy: allow?.supersededBy,
        undeclared: !allow,
      });
    }
  }
  return { count: paths.length, tolerated, pinNotes, skipped };
}

/* ------------------------------------------------------- dynamic discovery */

/**
 * DYNAMIC-DISCOVERY CONTRACT FOR SIBLING AGENTS
 *
 * Drop a migration at db/migrations/<YYYYMMDD>_nestly_v<NNN>_<slug>.sql. If NNN is greater
 * than SNAPSHOT_WATERMARK_VERSION it is discovered automatically and applied on top of the
 * committed schema snapshot, in ascending NNN order, before any test runs. Nothing here
 * needs editing when a migration lands — no list, no manifest entry, no registration.
 *
 * Files at or below the watermark are already baked into the snapshot and are skipped.
 * Regenerating the snapshot (scripts/db-tests/snapshot-schema.mjs) raises the watermark.
 */
export function discoverPendingMigrations({ watermark = SNAPSHOT_WATERMARK_VERSION } = {}) {
  const dir = join(REPO_ROOT, 'db/migrations');
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((n) => n.endsWith('.sql'))
    .map((name) => {
      const m = /_nestly_v(\d+)[_.]/.exec(name) || /_v(\d+)[_.]/.exec(name);
      return m ? { name, version: Number(m[1]), path: join(dir, name) } : null;
    })
    .filter((f) => f && f.version > watermark)
    /* Registered migrations apply in CANONICAL DEPLOY ORDER (db/migrations/migration-order.plan.json
       proposedDeployVersion) — the order production actually receives them — so a rehearsal here
       cannot pass in an order prod never runs. Two sessions may legitimately ship twin semantic
       numbers (main's nestly_v685 Singapore-day authority vs the CI wave's v685 shadow
       reconciliation, 2026-09-03); ascending NNN put the CI wave's v674 before main's v685 and
       v685's anchored patch then found nothing to patch, while prod would have applied them the
       other way round. Unregistered files (dropped by a sibling agent before governance) keep the
       old contract: after every registered file, ascending NNN, then filename. */
    .map((f) => ({ ...f, deployVersion: deployVersionByPath().get(`db/migrations/${f.name}`) ?? null }))
    .sort((a, b) => {
      if (a.deployVersion && b.deployVersion) return a.deployVersion.localeCompare(b.deployVersion);
      if (a.deployVersion !== b.deployVersion) return a.deployVersion ? -1 : 1;
      return a.version - b.version || a.name.localeCompare(b.name);
    });
}

let deployVersionCache = null;
/** path (repo-relative, db/migrations/<file>) -> proposedDeployVersion, from the canonical order plan. */
function deployVersionByPath() {
  if (deployVersionCache) return deployVersionCache;
  deployVersionCache = new Map();
  const planPath = join(REPO_ROOT, 'db/migrations/migration-order.plan.json');
  if (existsSync(planPath)) {
    const plan = JSON.parse(readFileSync(planPath, 'utf8'));
    for (const item of plan.items ?? []) {
      if (item.kind === 'executable' && item.path && item.proposedDeployVersion) {
        deployVersionCache.set(item.path, String(item.proposedDeployVersion));
      }
    }
  }
  return deployVersionCache;
}

/**
 * DYNAMIC-DISCOVERY CONTRACT FOR SIBLING AGENTS
 *
 * Drop an executed test at db/tests/executed/<name>.sql. Every .sql file in that directory
 * is run, in filename order, each on a freshly-restored database state. A test file owns its
 * own transaction: `begin; ... rollback;`. It signals failure by RAISE EXCEPTION — psql runs
 * with ON_ERROR_STOP=1, so any error fails the run and names the file.
 *
 * Unlike db/tests/*.sql (which are point-in-time migration suites and are NOT safe to replay
 * against the latest schema — see db/tests/rehearsal/README.md), everything in executed/ must
 * pass against the CURRENT final schema, both before and after the pending migrations apply.
 */
export function discoverExecutedTests({ watermark = SNAPSHOT_WATERMARK_VERSION } = {}) {
  if (!existsSync(EXECUTED_TESTS_DIR)) return [];
  return readdirSync(EXECUTED_TESTS_DIR)
    .filter((n) => n.endsWith('.sql'))
    .sort()
    .map((name) => {
      const m = /^v(\d+)/.exec(name);
      const version = m ? Number(m[1]) : null;
      const path = join(EXECUTED_TESTS_DIR, name);
      /* Opt-in marker for a file that is not a behavioural suite against the shared schema at
         all: it builds and drops its own scratch schema (see v427_entitlements.sql's header).
         Cloning the shared baseline/migrated template for one of these means the file's own
         `drop schema ... cascade` tears down every object the whole platform has accumulated —
         thousands of them on the migrated template — which blows past Postgres's
         max_locks_per_transaction and fails with "out of shared memory", a harness artifact that
         has nothing to do with the migration the file is actually proving. Declared by the
         file itself (first line, exact text) rather than inferred, so nothing is silently
         reclassified. */
      const isolated = readFileSync(path, 'utf8').split('\n', 1)[0].trim() === '-- db-tests: isolated';
      return {
        name,
        path,
        version,
        isolated,
        /* A test named for a migration NEWER than the frozen baseline is testing behaviour that
           does not exist in the baseline yet, so failing there is the correct answer, not a
           regression. Its gate is the MIGRATED phase. A test at or below the watermark — the
           baseline-behaviour suites — must pass in BOTH, which is what makes them a regression
           floor rather than a description of whatever shipped last.
           Inferred from the filename rather than a directive so nothing has to be registered:
           every executed test in this repo is named for the migration it belongs to. */
        migrationPinned: version != null && version > watermark,
      };
    });
}
