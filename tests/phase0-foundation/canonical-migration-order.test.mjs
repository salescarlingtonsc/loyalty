import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import {
  mkdir, mkdtemp, readFile, rm, writeFile
} from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const repoRoot = fileURLToPath(new URL('../..', import.meta.url));
const planRelativePath = 'supabase/canonical-migration-order.plan.json';
const scriptRelativePath = 'scripts/migrations/materialize-canonical-order.mjs';
const recoveryRelativePath = 'supabase/migrations/catalog-recovery.manifest.json';
const manifestRelativePath = 'supabase/canonical-migration-order.manifest.json';
const digestRelativePath = `${manifestRelativePath}.sha256`;
const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

function run(root, option) {
  return spawnSync(process.execPath, [scriptRelativePath, option], {
    cwd: root,
    encoding: 'utf8'
  });
}

function assertFailure(result, pattern) {
  assert.notEqual(result.status, 0, 'expected canonical materializer to fail closed');
  assert.match(`${result.stdout}\n${result.stderr}`, pattern);
}

async function fixture(t) {
  const root = await mkdtemp(path.join(tmpdir(), 'frenly-canonical-order-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await Promise.all([
    mkdir(path.join(root, 'scripts/migrations'), { recursive: true }),
    mkdir(path.join(root, 'supabase/migrations'), { recursive: true }),
    mkdir(path.join(root, 'db/migrations'), { recursive: true })
  ]);
  const planBytes = await readFile(path.join(repoRoot, planRelativePath));
  const plan = JSON.parse(planBytes);
  await Promise.all([
    writeFile(path.join(root, planRelativePath), planBytes),
    writeFile(path.join(root, scriptRelativePath), await readFile(path.join(repoRoot, scriptRelativePath)))
  ]);
  for (const item of plan.items.filter(({ sourcePath }) => sourcePath)) {
    const sourceBytes = await readFile(path.join(repoRoot, item.sourcePath));
    await writeFile(path.join(root, item.sourcePath), sourceBytes);
  }
  return { root, plan };
}

async function addRecoveryEvidence(root, plan) {
  const migrations = [];
  for (const item of plan.items.filter(({ kind }) => kind === 'catalog-applied')) {
    const pathName = `supabase/migrations/${item.version}_${item.name}.sql`;
    const statementBytes = Array.from(
      { length: item.name === 'remote_schema' ? 3 : 1 },
      (_, index) => Buffer.from(`-- exact catalog fixture ${index + 1}: ${item.name}\nselect '${item.version}-${index + 1}'`)
    );
    const canonicalization = statementBytes.length === 1
      ? 'exact-statement-bytes'
      : 'join-statements-with-semicolon-blank-line-and-final-semicolon-newline-v1';
    const canonicalBytes = statementBytes.length === 1
      ? statementBytes[0]
      : Buffer.concat([
        ...statementBytes.flatMap((bytes, index) => index === statementBytes.length - 1
          ? [bytes]
          : [bytes, Buffer.from(';\n\n')]),
        Buffer.from(';\n')
      ]);
    await writeFile(path.join(root, pathName), canonicalBytes);
    migrations.push({
      version: item.version,
      name: item.name,
      statementCount: statementBytes.length,
      statements: statementBytes.map((bytes, index) => ({
        index: index + 1,
        octetLength: bytes.byteLength,
        sha256: sha256(bytes),
        base64: bytes.toString('base64')
      })),
      canonicalization,
      canonicalOctetLength: canonicalBytes.byteLength,
      canonicalSha256: sha256(canonicalBytes),
      path: pathName
    });
  }
  await writeFile(path.join(root, recoveryRelativePath), `${JSON.stringify({
    schemaVersion: 1,
    projectRef: 'gadpooereceldfpfxsod',
    hashAlgorithm: 'sha256-raw-bytes',
    migrations
  }, null, 2)}\n`);
}

test('checked-in canonical plan preserves 45 trusted catalog versions then 30 unique pending versions', () => {
  const result = run(repoRoot, '--check-plan');
  assert.equal(result.status, 0, result.stderr);
});

test('materializer creates one byte-preserving 75-file chain and deterministic manifests', async (t) => {
  const { root, plan } = await fixture(t);
  await addRecoveryEvidence(root, plan);
  const materialized = run(root, '--materialize');
  assert.equal(materialized.status, 0, materialized.stderr);

  const manifestBytes = await readFile(path.join(root, manifestRelativePath));
  const manifest = JSON.parse(manifestBytes);
  assert.equal(manifest.status, 'canonical_deployable_locally_not_applied');
  assert.equal(manifest.catalogAppliedCount, 45);
  assert.equal(manifest.pendingCount, 30);
  assert.equal(manifest.itemCount, 75);
  assert.equal(new Set(manifest.items.map(({ version }) => version)).size, 75);
  assert.equal(manifest.items[44].version, '20260719190540');
  assert.equal(manifest.items[45].version, '20260721000001');
  assert.equal(manifest.items.at(-1).name, 'frenly_v48_calendar_details_reschedule');
  const recovery = JSON.parse(await readFile(path.join(root, recoveryRelativePath), 'utf8'));
  assert.equal(recovery.migrations[0].statementCount, 3);
  assert.equal(recovery.migrations[0].statements.length, 3);
  assert.equal(
    recovery.migrations[0].canonicalization,
    'join-statements-with-semicolon-blank-line-and-final-semicolon-newline-v1'
  );

  for (const item of manifest.items) {
    const bytes = await readFile(path.join(root, item.path));
    assert.equal(item.octetLength, bytes.byteLength);
    assert.equal(item.sha256, sha256(bytes));
  }
  for (const item of plan.items.filter(({ kind }) => kind === 'pending')) {
    assert.deepEqual(
      await readFile(path.join(root, `supabase/migrations/${item.version}_${item.name}.sql`)),
      await readFile(path.join(root, item.sourcePath))
    );
  }
  assert.equal(
    await readFile(path.join(root, digestRelativePath), 'utf8'),
    `${sha256(manifestBytes)}  canonical-migration-order.manifest.json\n`
  );
  assert.equal(run(root, '--check').status, 0);
});

test('catalog byte tampering and missing catalog evidence are hard failures', async (t) => {
  const tamper = await fixture(t);
  await addRecoveryEvidence(tamper.root, tamper.plan);
  assert.equal(run(tamper.root, '--materialize').status, 0);
  const recovered = tamper.plan.items.find(({ kind }) => kind === 'catalog-applied');
  await writeFile(
    path.join(tamper.root, `supabase/migrations/${recovered.version}_${recovered.name}.sql`),
    '-- tampered\n'
  );
  assertFailure(run(tamper.root, '--check'), /(?:byte length|SHA-256) differs from catalog canonical evidence/i);

  const missing = await fixture(t);
  await addRecoveryEvidence(missing.root, missing.plan);
  const recovery = JSON.parse(await readFile(path.join(missing.root, recoveryRelativePath), 'utf8'));
  recovery.migrations.shift();
  await writeFile(path.join(missing.root, recoveryRelativePath), `${JSON.stringify(recovery, null, 2)}\n`);
  assertFailure(run(missing.root, '--materialize'), /required catalog evidence is missing/i);

  const invalidBase64 = await fixture(t);
  await addRecoveryEvidence(invalidBase64.root, invalidBase64.plan);
  const invalidRecovery = JSON.parse(
    await readFile(path.join(invalidBase64.root, recoveryRelativePath), 'utf8')
  );
  invalidRecovery.migrations[0].statements[0].base64 += '\n';
  await writeFile(
    path.join(invalidBase64.root, recoveryRelativePath),
    `${JSON.stringify(invalidRecovery, null, 2)}\n`
  );
  assertFailure(run(invalidBase64.root, '--materialize'), /canonical unwrapped base64/i);
});

test('plan drift, unexpected SQL, and pending target divergence fail closed', async (t) => {
  const duplicate = await fixture(t);
  const duplicatePlan = structuredClone(duplicate.plan);
  duplicatePlan.items[1].version = duplicatePlan.items[0].version;
  await writeFile(
    path.join(duplicate.root, planRelativePath),
    `${JSON.stringify(duplicatePlan, null, 2)}\n`
  );
  assertFailure(run(duplicate.root, '--check-plan'), /strictly ordered|duplicates a migration version/i);

  const renamed = await fixture(t);
  const renamedPlan = structuredClone(renamed.plan);
  renamedPlan.items[0].name = 'plausible_but_untrusted_catalog_name';
  await writeFile(
    path.join(renamed.root, planRelativePath),
    `${JSON.stringify(renamedPlan, null, 2)}\n`
  );
  assertFailure(run(renamed.root, '--check-plan'), /trusted remote inventory exactly/i);

  const extra = await fixture(t);
  await addRecoveryEvidence(extra.root, extra.plan);
  assert.equal(run(extra.root, '--materialize').status, 0);
  await writeFile(path.join(extra.root, 'supabase/migrations/20990101000000_unplanned.sql'), 'select 1;\n');
  assertFailure(run(extra.root, '--check'), /exactly the canonical SQL chain/i);

  const divergent = await fixture(t);
  await addRecoveryEvidence(divergent.root, divergent.plan);
  assert.equal(run(divergent.root, '--materialize').status, 0);
  const pending = divergent.plan.items.find(({ kind }) => kind === 'pending');
  await writeFile(
    path.join(divergent.root, `supabase/migrations/${pending.version}_${pending.name}.sql`),
    '-- divergent pending bytes\n'
  );
  assertFailure(run(divergent.root, '--check'), /differs from its pending source migration/i);
});
