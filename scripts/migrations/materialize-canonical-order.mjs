import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import {
  copyFile, lstat, mkdir, readFile, readdir, realpath, writeFile
} from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, '..', '..');
const supabaseDir = path.join(repoRoot, 'supabase');
const migrationsDir = path.join(supabaseDir, 'migrations');
const planPath = path.join(supabaseDir, 'canonical-migration-order.plan.json');
const recoveryPath = path.join(migrationsDir, 'catalog-recovery.manifest.json');
const manifestPath = path.join(supabaseDir, 'canonical-migration-order.manifest.json');
const digestPath = `${manifestPath}.sha256`;
const projectRef = 'gadpooereceldfpfxsod';

const expectedCatalogIdentities = [
  '20260718152809_remote_schema',
  '20260718175010_enable_pg_cron',
  '20260718175336_frenly_init',
  '20260718175347_lock_down_rls_auto_enable',
  '20260718175426_frenly_v2_saas',
  '20260718175514_frenly_v3_engine',
  '20260718175527_frenly_v4_onboarding_rpc',
  '20260718175707_frenly_v5_memberships_giftcards',
  '20260718175749_frenly_v6_ops_modules',
  '20260718175847_frenly_v7_team_brand',
  '20260718175913_frenly_v8_requests_consumption',
  '20260718175936_frenly_v9_giftcard_revenue',
  '20260718180019_frenly_v10_sale_policy',
  '20260718180110_frenly_v10_1_policy_snapshot',
  '20260718180155_frenly_v11a_branches_staff_services',
  '20260718180329_frenly_v11b_money',
  '20260718180339_frenly_v11c_revoke_truncate',
  '20260718180403_frenly_v12a_completion_staff',
  '20260718180431_frenly_v12_commission_snapshot',
  '20260718180512_frenly_v14a_superadmin_roles_phone',
  '20260718180548_frenly_v14b_billing_module_perms',
  '20260718180644_frenly_v14c_customer_signup_phone_till',
  '20260718180659_frenly_v14d_harden_search_path',
  '20260718180738_frenly_v15a_booking_capacity_schema',
  '20260718180853_frenly_v15b_booking_flows_notify_cron',
  '20260718180906_frenly_v15c_convert_idempotency_guard',
  '20260718180946_frenly_v15d_booking_consent',
  '20260718181016_frenly_v17_branch_visibility',
  '20260719032517_frenly_v18_scalable_reporting',
  '20260719032658_frenly_v19_public_gateway_security',
  '20260719034201_frenly_v20_financial_engine',
  '20260719034347_frenly_v21_security_hardening',
  '20260719100654_frenly_v13_flat_commission',
  '20260719154139_frenly_v22_flat_commission_reconciliation',
  '20260719155403_frenly_v22a_app_default_privileges',
  '20260719155614_frenly_v22b_global_function_default_privileges',
  '20260719174110_frenly_v23_loyalty_points_tiers',
  '20260719174309_frenly_v23a_redeem_reward_anon_revoke',
  '20260719174612_frenly_v23b_redeem_reward_perm_fix',
  '20260719174754_frenly_v23c_redeem_reward_column_fix',
  '20260719175305_frenly_v23d_restore_loyalty_programs',
  '20260719175525_frenly_v23e_redeem_reward_ledger_routes',
  '20260719175826_frenly_v23f_restore_expiry_columns',
  '20260719185223_frenly_v23g_loyalty_model_consolidation',
  '20260719190540_frenly_v24_stamps_model'
];

const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

function exactKeys(value, expected, label) {
  assert.ok(value && typeof value === 'object' && !Array.isArray(value), `${label} must be an object`);
  assert.deepEqual(Object.keys(value).sort(), [...expected].sort(), `${label} has unsupported or missing keys`);
}

function assertTimestamp(value, label) {
  assert.match(value, /^\d{14}$/, `${label} must be a 14-digit migration version`);
  const year = Number(value.slice(0, 4));
  const month = Number(value.slice(4, 6));
  const day = Number(value.slice(6, 8));
  const hour = Number(value.slice(8, 10));
  const minute = Number(value.slice(10, 12));
  const second = Number(value.slice(12, 14));
  const parsed = new Date(Date.UTC(year, month - 1, day, hour, minute, second));
  assert.equal(parsed.toISOString().slice(0, 19).replace(/[-:T]/g, ''), value,
    `${label} is not a valid UTC timestamp`);
}

function targetRelativePath(item) {
  return `supabase/migrations/${item.version}_${item.name}.sql`;
}

function decodeCanonicalBase64(value, label) {
  assert.match(value, /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/,
    `${label} must be canonical unwrapped base64`);
  const bytes = Buffer.from(value, 'base64');
  assert.equal(bytes.toString('base64'), value, `${label} is not a canonical base64 encoding`);
  return bytes;
}

function canonicalizeStatements(statements) {
  if (statements.length === 1) {
    return { mode: 'exact-statement-bytes', bytes: statements[0] };
  }
  return {
    mode: 'join-statements-with-semicolon-blank-line-and-final-semicolon-newline-v1',
    bytes: Buffer.concat([
      ...statements.flatMap((bytes, index) => index === statements.length - 1
        ? [bytes]
        : [bytes, Buffer.from(';\n\n')]),
      Buffer.from(';\n')
    ])
  };
}

async function regularContainedFile(relativePath, allowedDir, label) {
  assert.match(relativePath, /^(?:db|supabase)\/migrations\/[A-Za-z0-9_]+\.sql$/,
    `${label} has an unsafe path`);
  const absolute = path.resolve(repoRoot, relativePath);
  assert.equal(path.dirname(absolute), allowedDir, `${label} escapes its migration directory`);
  const allowedReal = await realpath(allowedDir);
  assert.equal(path.dirname(await realpath(absolute)), allowedReal, `${label} resolves outside its migration directory`);
  assert.ok((await lstat(absolute)).isFile(), `${label} must be a regular file`);
  return absolute;
}

async function loadPlan() {
  const plan = JSON.parse(await readFile(planPath, 'utf8'));
  exactKeys(plan, [
    'schemaVersion', 'projectRef', 'status', 'catalogCutoffVersion',
    'requireCatalogEvidenceForAllApplied', 'items'
  ], 'canonical plan');
  assert.equal(plan.schemaVersion, 1);
  assert.equal(plan.projectRef, projectRef);
  assert.equal(plan.status, 'exact_catalog_recovered_canonical_locally_not_applied');
  assert.equal(plan.requireCatalogEvidenceForAllApplied, true,
    'every applied migration must retain catalog byte/hash evidence');
  assert.ok(Array.isArray(plan.items));
  assert.equal(plan.items.length, 97, 'canonical plan must contain 45 catalog and 52 pending migrations');

  const seenVersions = new Set();
  const seenNames = new Set();
  let priorVersion = '';
  let pendingStarted = false;

  for (const [index, item] of plan.items.entries()) {
    const label = `canonical item ${index + 1}`;
    assertTimestamp(item.version, label);
    assert.ok(item.version > priorVersion, `${label} must be strictly ordered by unique version`);
    assert.ok(!seenVersions.has(item.version), `${label} duplicates a migration version`);
    assert.ok(!seenNames.has(item.name), `${label} duplicates a migration name`);
    assert.match(item.name, /^[a-z][a-z0-9_]*$/, `${label} has an unsafe name`);
    priorVersion = item.version;
    seenVersions.add(item.version);
    seenNames.add(item.name);

    if (item.kind === 'catalog-applied') {
      assert.ok(!pendingStarted, `${label} places an applied migration after pending work`);
      const expected = item.sourcePath
        ? ['kind', 'version', 'name', 'sourcePath']
        : ['kind', 'version', 'name', 'catalogEvidenceRequired'];
      exactKeys(item, expected, label);
      if (item.sourcePath) {
        await regularContainedFile(item.sourcePath, path.join(repoRoot, 'db/migrations'), `${label} source`);
      } else {
        assert.equal(item.catalogEvidenceRequired, true, `${label} must require catalog evidence`);
      }
    } else if (item.kind === 'pending') {
      pendingStarted = true;
      exactKeys(item, ['kind', 'version', 'name', 'sourcePath'], label);
      await regularContainedFile(item.sourcePath, path.join(repoRoot, 'db/migrations'), `${label} source`);
      assert.ok(item.version > plan.catalogCutoffVersion, `${label} must follow the catalog cutoff`);
    } else {
      assert.fail(`${label} has unsupported kind`);
    }
  }

  const applied = plan.items.filter(({ kind }) => kind === 'catalog-applied');
  const pending = plan.items.filter(({ kind }) => kind === 'pending');
  assert.equal(applied.length, 45);
  assert.equal(pending.length, 52);
  assert.deepEqual(applied.map(({ version, name }) => `${version}_${name}`), expectedCatalogIdentities,
    'catalog versions and names must match the trusted remote inventory exactly');
  assert.equal(applied.at(-1).version, plan.catalogCutoffVersion);
  return plan;
}

async function loadRecoveryEvidence(plan) {
  let raw;
  try {
    raw = await readFile(recoveryPath, 'utf8');
  } catch (error) {
    if (error.code === 'ENOENT') return new Map();
    throw error;
  }
  const recovery = JSON.parse(raw);
  exactKeys(recovery, ['schemaVersion', 'projectRef', 'hashAlgorithm', 'migrations'], 'catalog recovery manifest');
  assert.equal(recovery.schemaVersion, 1);
  assert.equal(recovery.projectRef, projectRef);
  assert.equal(recovery.hashAlgorithm, 'sha256-raw-bytes');
  assert.ok(Array.isArray(recovery.migrations));
  const planByVersion = new Map(plan.items
    .filter(({ kind }) => kind === 'catalog-applied')
    .map((item) => [item.version, item]));
  const evidence = new Map();
  for (const [index, item] of recovery.migrations.entries()) {
    const label = `catalog recovery item ${index + 1}`;
    exactKeys(item, [
      'version', 'name', 'statementCount', 'statements', 'canonicalization',
      'canonicalOctetLength', 'canonicalSha256', 'path'
    ], label);
    const planned = planByVersion.get(item.version);
    assert.ok(planned, `${label} is not a catalog-applied migration in the canonical plan`);
    assert.equal(item.name, planned.name, `${label} name does not match its trusted catalog version`);
    assert.ok(Number.isSafeInteger(item.statementCount) && item.statementCount >= 1,
      `${label} has an invalid statement count`);
    assert.ok(Array.isArray(item.statements), `${label} statements must be an array`);
    assert.equal(item.statements.length, item.statementCount,
      `${label} must preserve every catalog statement`);
    const statementBytes = item.statements.map((statement, statementOffset) => {
      const statementLabel = `${label} statement ${statementOffset + 1}`;
      exactKeys(statement, ['index', 'octetLength', 'sha256', 'base64'], statementLabel);
      assert.equal(statement.index, statementOffset + 1,
        `${statementLabel} index must be consecutive and one-based`);
      assert.ok(Number.isSafeInteger(statement.octetLength) && statement.octetLength >= 0,
        `${statementLabel} has an invalid octet length`);
      assert.match(statement.sha256, /^[a-f0-9]{64}$/, `${statementLabel} has an invalid SHA-256`);
      const bytes = decodeCanonicalBase64(statement.base64, `${statementLabel} base64`);
      assert.equal(bytes.byteLength, statement.octetLength,
        `${statementLabel} decoded byte length differs from catalog metadata`);
      assert.equal(sha256(bytes), statement.sha256,
        `${statementLabel} decoded SHA-256 differs from catalog metadata`);
      return bytes;
    });
    const canonical = canonicalizeStatements(statementBytes);
    assert.equal(item.canonicalization, canonical.mode,
      `${label} canonicalization does not match its statement count`);
    assert.ok(Number.isSafeInteger(item.canonicalOctetLength) && item.canonicalOctetLength >= 0,
      `${label} has an invalid canonical octet length`);
    assert.match(item.canonicalSha256, /^[a-f0-9]{64}$/,
      `${label} has an invalid canonical SHA-256`);
    assert.equal(canonical.bytes.byteLength, item.canonicalOctetLength,
      `${label} reconstructed byte length differs from canonical metadata`);
    assert.equal(sha256(canonical.bytes), item.canonicalSha256,
      `${label} reconstructed SHA-256 differs from canonical metadata`);
    assert.equal(item.path, targetRelativePath(planned), `${label} path is not canonical`);
    assert.ok(!evidence.has(item.version), `${label} duplicates catalog evidence`);
    evidence.set(item.version, { ...item, canonicalBytes: canonical.bytes });
  }
  return evidence;
}

async function materializeSourceBackedTargets(plan, evidence) {
  await mkdir(migrationsDir, { recursive: true });
  for (const item of plan.items) {
    const target = path.resolve(repoRoot, targetRelativePath(item));
    const recovered = evidence.get(item.version);
    if (recovered) {
      await writeFile(target, recovered.canonicalBytes);
      continue;
    }
    assert.notEqual(item.kind, 'catalog-applied',
      `required catalog evidence is missing for ${item.version}`);
    assert.ok(item.sourcePath, `${targetRelativePath(item)} has no catalog evidence or local source`);
    await copyFile(path.resolve(repoRoot, item.sourcePath), target);
  }
}

async function buildManifest(plan, evidence) {
  const missingTargets = [];
  const missingEvidence = [];
  const entries = [];

  for (const [index, item] of plan.items.entries()) {
    const relativePath = targetRelativePath(item);
    const target = path.resolve(repoRoot, relativePath);
    let bytes;
    try {
      bytes = await readFile(target);
      await regularContainedFile(relativePath, migrationsDir, `canonical target ${index + 1}`);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      missingTargets.push(relativePath);
      continue;
    }

    const recovered = evidence.get(item.version);
    if (item.kind === 'catalog-applied' && !recovered) missingEvidence.push(item.version);
    if (recovered) {
      assert.equal(bytes.byteLength, recovered.canonicalOctetLength,
        `${relativePath} byte length differs from catalog canonical evidence`);
      assert.equal(sha256(bytes), recovered.canonicalSha256,
        `${relativePath} SHA-256 differs from catalog canonical evidence`);
      assert.deepEqual(bytes, recovered.canonicalBytes,
        `${relativePath} bytes differ from deterministic catalog reconstruction`);
    }
    if (item.kind === 'pending') {
      assert.deepEqual(bytes, await readFile(path.resolve(repoRoot, item.sourcePath)),
        `${relativePath} differs from its pending source migration`);
    }

    entries.push({
      order: index + 1,
      kind: item.kind,
      version: item.version,
      name: item.name,
      path: relativePath,
      octetLength: bytes.byteLength,
      sha256: sha256(bytes),
      provenance: recovered ? 'catalog-statements' : 'local-source'
    });
  }

  assert.deepEqual(missingTargets, [], `canonical SQL targets are missing: ${missingTargets.join(', ')}`);
  assert.deepEqual(missingEvidence, [],
    `required catalog evidence is missing for versions: ${missingEvidence.join(', ')}`);

  return {
    schemaVersion: 1,
    status: 'canonical_deployable_locally_not_applied',
    projectRef,
    sourcePlan: 'supabase/canonical-migration-order.plan.json',
    catalogRecoveryManifest: 'supabase/migrations/catalog-recovery.manifest.json',
    hashAlgorithm: 'sha256-raw-bytes',
    catalogAppliedCount: 45,
    pendingCount: 52,
    itemCount: entries.length,
    items: entries
  };
}

async function assertOnlyPlannedSql(plan) {
  const actual = (await readdir(migrationsDir, { withFileTypes: true }))
    .filter((entry) => entry.isFile() && entry.name.endsWith('.sql'))
    .map(({ name }) => `supabase/migrations/${name}`)
    .sort();
  const expected = plan.items.map(targetRelativePath).sort();
  assert.deepEqual(actual, expected, 'supabase/migrations must contain exactly the canonical SQL chain');
}

async function main() {
  const option = process.argv[2] || '--check-plan';
  assert.ok(['--check-plan', '--materialize', '--check'].includes(option),
    'Usage: node scripts/migrations/materialize-canonical-order.mjs [--check-plan|--materialize|--check]');
  assert.equal(process.argv.length, process.argv[2] ? 3 : 2, 'Unexpected arguments');
  const plan = await loadPlan();
  if (option === '--check-plan') return;

  const evidence = await loadRecoveryEvidence(plan);
  if (option === '--materialize') await materializeSourceBackedTargets(plan, evidence);
  const manifest = await buildManifest(plan, evidence);
  await assertOnlyPlannedSql(plan);
  const bytes = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`);
  const digest = `${sha256(bytes)}  canonical-migration-order.manifest.json\n`;

  if (option === '--materialize') {
    await writeFile(manifestPath, bytes);
    await writeFile(digestPath, digest, 'utf8');
    return;
  }
  assert.deepEqual(await readFile(manifestPath), bytes, 'canonical migration manifest is stale or modified');
  assert.equal(await readFile(digestPath, 'utf8'), digest,
    'canonical migration manifest digest is stale or modified');
}

await main();
