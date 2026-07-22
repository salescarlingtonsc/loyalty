import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import {
  mkdtemp, mkdir, readFile, rm, symlink, unlink, writeFile
} from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const repoRoot = fileURLToPath(new URL('../..', import.meta.url));
const planRelativePath = 'db/migrations/migration-order.plan.json';
const manifestRelativePath = 'db/migrations/migration-order.manifest.json';
const digestRelativePath = `${manifestRelativePath}.sha256`;
const generatorRelativePath = 'scripts/migrations/generate-manifest.mjs';

const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

async function isolatedManifestRepo(t) {
  const root = await mkdtemp(path.join(tmpdir(), 'frenly-migration-manifest-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await Promise.all([
    mkdir(path.join(root, 'db/migrations'), { recursive: true }),
    mkdir(path.join(root, 'scripts/migrations'), { recursive: true })
  ]);

  const planBytes = await readFile(path.join(repoRoot, planRelativePath));
  const plan = JSON.parse(planBytes);
  await Promise.all([
    writeFile(path.join(root, planRelativePath), planBytes),
    writeFile(path.join(root, generatorRelativePath), await readFile(path.join(repoRoot, generatorRelativePath)))
  ]);
  await Promise.all(plan.items
    .filter(({ kind }) => kind === 'executable')
    .map(async ({ path: migrationPath }) => {
      await writeFile(path.join(root, migrationPath), await readFile(path.join(repoRoot, migrationPath)));
    }));
  return root;
}

function runGenerator(root, option = '--check') {
  return spawnSync(process.execPath, [generatorRelativePath, option], {
    cwd: root,
    encoding: 'utf8'
  });
}

async function readPlan(root) {
  return JSON.parse(await readFile(path.join(root, planRelativePath), 'utf8'));
}

async function writePlan(root, plan) {
  await writeFile(path.join(root, planRelativePath), `${JSON.stringify(plan, null, 2)}\n`);
}

function assertGeneratorFailure(result, pattern) {
  assert.notEqual(result.status, 0, 'Expected manifest generator to reject the adversarial fixture.');
  assert.match(`${result.stdout}\n${result.stderr}`, pattern);
}

test('manifest covers every executable SQL file with raw-byte SHA-256 and a companion digest', async (t) => {
  const root = await isolatedManifestRepo(t);
  const written = runGenerator(root, '--write');
  assert.equal(written.status, 0, written.stderr);

  const manifestBytes = await readFile(path.join(root, manifestRelativePath));
  const manifest = JSON.parse(manifestBytes);
  const digest = await readFile(path.join(root, digestRelativePath), 'utf8');
  const sqlItems = manifest.items.filter(({ kind }) => kind === 'executable');
  const reservations = manifest.items.filter(({ kind }) => kind === 'missing-history-reservation');

  assert.equal(manifest.schemaVersion, 1);
  assert.equal(manifest.status, 'planning_only_not_deployable');
  assert.equal(manifest.hashAlgorithm, 'sha256-raw-bytes');
  assert.equal(manifest.itemCount, 77);
  assert.equal(manifest.executableCount, 63);
  assert.equal(manifest.reservationCount, 14);
  assert.equal(sqlItems.length, 63);
  assert.equal(reservations.length, 14);
  assert.equal(manifest.sourceCollisionsResolved, false);

  const expectedCollisionCounts = new Map([
    ['20260717', 7],
    ['20260718', 3],
    ['20260719', 5],
    ['20260720', 28],
    ['20260721', 5],
    ['20260722', 9]
  ]);
  assert.deepEqual(
    manifest.sourceDeployVersionCollisions.map(({ sourceDeployVersion, count }) => [sourceDeployVersion, count]),
    [...expectedCollisionCounts]
  );
  const reportedCollisionPaths = [];
  for (const collision of manifest.sourceDeployVersionCollisions) {
    const expectedPaths = sqlItems
      .map(({ path: migrationPath }) => migrationPath)
      .filter((migrationPath) => path.basename(migrationPath).match(/^\d+/)[0] === collision.sourceDeployVersion)
      .sort();
    assert.equal(collision.count, expectedCollisionCounts.get(collision.sourceDeployVersion));
    assert.deepEqual(collision.paths, expectedPaths, collision.sourceDeployVersion);
    assert.deepEqual(collision.paths, [...collision.paths].sort(), `${collision.sourceDeployVersion} paths must be deterministic`);
    reportedCollisionPaths.push(...collision.paths);
  }
  const expectedCollidingPaths = sqlItems
    .map(({ path: migrationPath }) => migrationPath)
    .filter((migrationPath) => expectedCollisionCounts.has(path.basename(migrationPath).match(/^\d+/)[0]))
    .sort();
  assert.deepEqual([...reportedCollisionPaths].sort(), expectedCollidingPaths);
  assert.equal(new Set(reportedCollisionPaths).size, reportedCollisionPaths.length);

  for (const item of sqlItems) {
    const bytes = await readFile(path.join(root, item.path));
    assert.match(item.sha256, /^[a-f0-9]{64}$/);
    assert.equal(item.sha256, sha256(bytes), item.path);
  }
  assert.equal(digest, `${sha256(manifestBytes)}  migration-order.manifest.json\n`);
  assert.equal(runGenerator(root, '--check').status, 0);
});

test('an additional same-prefix migration updates collision reporting deterministically', async (t) => {
  const root = await isolatedManifestRepo(t);
  const plan = await readPlan(root);
  const migrationPath = 'db/migrations/20260720_frenly_v48_extra_collision.sql';
  plan.items.push({
    kind: 'executable',
    path: migrationPath,
    semanticVersion: 'v48',
    proposedDeployVersion: '20260722000118'
  });
  await writeFile(path.join(root, migrationPath), 'select 42;\n');
  await writePlan(root, plan);

  const firstWrite = runGenerator(root, '--write');
  assert.equal(firstWrite.status, 0, firstWrite.stderr);
  const firstManifest = await readFile(path.join(root, manifestRelativePath), 'utf8');
  const manifest = JSON.parse(firstManifest);
  const collision = manifest.sourceDeployVersionCollisions
    .find(({ sourceDeployVersion }) => sourceDeployVersion === '20260720');

  assert.equal(manifest.sourceCollisionsResolved, false);
  assert.equal(collision.count, 29);
  assert.equal(collision.paths.at(-1), migrationPath);
  assert.deepEqual(collision.paths, [...collision.paths].sort());
  assert.equal(runGenerator(root, '--write').status, 0);
  assert.equal(await readFile(path.join(root, manifestRelativePath), 'utf8'), firstManifest);
  assert.equal(runGenerator(root, '--check').status, 0);
});

test('manifest generator reports duplicate proposed deploy IDs and non-monotonic order', async (t) => {
  const root = await isolatedManifestRepo(t);
  const plan = await readPlan(root);
  plan.items[1].proposedDeployVersion = plan.items[0].proposedDeployVersion;
  await writePlan(root, plan);

  assertGeneratorFailure(runGenerator(root, '--write'), /plan item 2.*(?:duplicated|strictly monotonic)/i);
});

test('manifest generator rejects unsafe traversal and resolved symlink escape paths', async (t) => {
  const traversalRoot = await isolatedManifestRepo(t);
  const traversalPlan = await readPlan(traversalRoot);
  traversalPlan.items[0].path = 'db/migrations/../outside.sql';
  await writeFile(path.join(traversalRoot, 'db/outside.sql'), 'select 1;\n');
  await writePlan(traversalRoot, traversalPlan);
  assertGeneratorFailure(runGenerator(traversalRoot, '--write'), /unsafe path/i);

  const symlinkRoot = await isolatedManifestRepo(t);
  const symlinkPlan = await readPlan(symlinkRoot);
  const firstPath = symlinkPlan.items.find(({ kind }) => kind === 'executable').path;
  const outsidePath = path.join(symlinkRoot, 'outside.sql');
  await writeFile(outsidePath, 'select 1;\n');
  await unlink(path.join(symlinkRoot, firstPath));
  await symlink(outsidePath, path.join(symlinkRoot, firstPath));
  assertGeneratorFailure(runGenerator(symlinkRoot, '--write'), /resolves outside db\/migrations/i);
});

test('manifest generator fails when the plan omits or invents executable SQL coverage', async (t) => {
  const extraRoot = await isolatedManifestRepo(t);
  await writeFile(path.join(extraRoot, 'db/migrations/20990101010101_frenly_v99_unplanned.sql'), 'select 99;\n');
  assertGeneratorFailure(runGenerator(extraRoot, '--write'), /every executable migration exactly once/i);

  const missingRoot = await isolatedManifestRepo(t);
  const missingPlan = await readPlan(missingRoot);
  const index = missingPlan.items.findIndex(({ kind }) => kind === 'executable');
  missingPlan.items.splice(index, 1);
  await writePlan(missingRoot, missingPlan);
  assertGeneratorFailure(runGenerator(missingRoot, '--write'), /every executable migration exactly once/i);
});

test('duplicate executable paths and semantic-version drift fail before a manifest is written', async (t) => {
  const duplicateRoot = await isolatedManifestRepo(t);
  const duplicatePlan = await readPlan(duplicateRoot);
  const executableIndexes = duplicatePlan.items
    .map((item, index) => item.kind === 'executable' ? index : -1)
    .filter((index) => index >= 0);
  duplicatePlan.items[executableIndexes[1]].path = duplicatePlan.items[executableIndexes[0]].path;
  await writePlan(duplicateRoot, duplicatePlan);
  assertGeneratorFailure(runGenerator(duplicateRoot, '--write'), /path is duplicated/i);

  const semanticRoot = await isolatedManifestRepo(t);
  const semanticPlan = await readPlan(semanticRoot);
  const semanticIndex = semanticPlan.items.findIndex(({ kind }) => kind === 'executable');
  semanticPlan.items[semanticIndex].semanticVersion = 'v999';
  await writePlan(semanticRoot, semanticPlan);
  assertGeneratorFailure(runGenerator(semanticRoot, '--write'), /semantic version mismatch/i);
});

test('explicit history keeps v11c reserved and orders v12a before v12 without lexical inference', async (t) => {
  const missingReservationRoot = await isolatedManifestRepo(t);
  const missingReservationPlan = await readPlan(missingReservationRoot);
  missingReservationPlan.items = missingReservationPlan.items
    .filter(({ recoveryId }) => recoveryId !== 'frenly_v11c_revoke_truncate');
  await writePlan(missingReservationRoot, missingReservationPlan);
  assertGeneratorFailure(runGenerator(missingReservationRoot, '--write'), /reserve every locally proven missing historical migration/i);

  const wrongOrderRoot = await isolatedManifestRepo(t);
  const wrongOrderPlan = await readPlan(wrongOrderRoot);
  const v12aIndex = wrongOrderPlan.items.findIndex(({ semanticVersion }) => semanticVersion === 'v12a');
  const v12Index = wrongOrderPlan.items.findIndex(({ semanticVersion }) => semanticVersion === 'v12');
  const v12aPayload = {
    path: wrongOrderPlan.items[v12aIndex].path,
    semanticVersion: wrongOrderPlan.items[v12aIndex].semanticVersion
  };
  wrongOrderPlan.items[v12aIndex].path = wrongOrderPlan.items[v12Index].path;
  wrongOrderPlan.items[v12aIndex].semanticVersion = wrongOrderPlan.items[v12Index].semanticVersion;
  wrongOrderPlan.items[v12Index].path = v12aPayload.path;
  wrongOrderPlan.items[v12Index].semanticVersion = v12aPayload.semanticVersion;
  await writePlan(wrongOrderRoot, wrongOrderPlan);
  assertGeneratorFailure(runGenerator(wrongOrderRoot, '--write'), /v12a before v12/i);
});

test('invalid deploy timestamps and unsupported plan keys fail closed', async (t) => {
  const timestampRoot = await isolatedManifestRepo(t);
  const timestampPlan = await readPlan(timestampRoot);
  timestampPlan.items[0].proposedDeployVersion = '20260722009999';
  await writePlan(timestampRoot, timestampPlan);
  assertGeneratorFailure(runGenerator(timestampRoot, '--write'), /not a valid UTC timestamp/i);

  const schemaRoot = await isolatedManifestRepo(t);
  const schemaPlan = await readPlan(schemaRoot);
  schemaPlan.items[0].ignoredByGenerator = true;
  await writePlan(schemaRoot, schemaPlan);
  assertGeneratorFailure(runGenerator(schemaRoot, '--write'), /unsupported or missing keys/i);
});

test('check detects raw SQL, manifest, and companion-digest tampering without exposing SQL contents', async (t) => {
  const sqlRoot = await isolatedManifestRepo(t);
  assert.equal(runGenerator(sqlRoot, '--write').status, 0);
  const sqlPlan = await readPlan(sqlRoot);
  const migrationPath = sqlPlan.items.find(({ kind }) => kind === 'executable').path;
  const canary = 'CANARY_SQL_CONTENT_MUST_NOT_PRINT_4bca22';
  const original = await readFile(path.join(sqlRoot, migrationPath));
  await writeFile(path.join(sqlRoot, migrationPath), Buffer.concat([original, Buffer.from(`\n-- ${canary}\n`)]));
  const sqlCheck = runGenerator(sqlRoot, '--check');
  assertGeneratorFailure(sqlCheck, /migration manifest is stale or modified/i);
  assert.doesNotMatch(`${sqlCheck.stdout}\n${sqlCheck.stderr}`, new RegExp(canary));

  const manifestRoot = await isolatedManifestRepo(t);
  assert.equal(runGenerator(manifestRoot, '--write').status, 0);
  const manifestPath = path.join(manifestRoot, manifestRelativePath);
  await writeFile(manifestPath, `${await readFile(manifestPath, 'utf8')} `);
  assertGeneratorFailure(runGenerator(manifestRoot, '--check'), /migration manifest is stale or modified/i);

  const digestRoot = await isolatedManifestRepo(t);
  assert.equal(runGenerator(digestRoot, '--write').status, 0);
  await writeFile(path.join(digestRoot, digestRelativePath), `${'0'.repeat(64)}  migration-order.manifest.json\n`);
  assertGeneratorFailure(runGenerator(digestRoot, '--check'), /migration manifest digest is stale or modified/i);
});
