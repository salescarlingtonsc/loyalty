import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { lstat, readFile, readdir, realpath, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, '..', '..');
const migrationsDir = path.join(repoRoot, 'db/migrations');
const planPath = path.join(migrationsDir, 'migration-order.plan.json');
const manifestPath = path.join(migrationsDir, 'migration-order.manifest.json');
const digestPath = `${manifestPath}.sha256`;
const requiredReservations = new Set([
  'frenly_v3_engine', 'frenly_v4_onboarding_rpc', 'frenly_v5_memberships_giftcards',
  'frenly_v6_ops_modules', 'frenly_v7_team_brand', 'frenly_v11c_revoke_truncate',
  'frenly_v14a_superadmin_roles_phone', 'frenly_v14b_billing_module_perms',
  'frenly_v14c_customer_signup_phone_till', 'frenly_v14d_harden_search_path',
  'frenly_v15a_booking_capacity_schema', 'frenly_v15b_booking_flows_notify_cron',
  'frenly_v15c_convert_idempotency_guard', 'frenly_v15d_booking_consent'
]);

function exactKeys(value, expected, label) {
  assert.ok(value && typeof value === 'object' && !Array.isArray(value), `${label} must be an object`);
  assert.deepEqual(Object.keys(value).sort(), [...expected].sort(), `${label} has unsupported or missing keys`);
}

function semanticVersion(fileName) {
  if (/^\d+_frenly_init\.sql$/.test(fileName)) return 'v1';
  const match = fileName.match(/^\d+_frenly_v(?<major>\d+)(?:(?:_(?<minor>\d+))|(?<letter>[a-z]))?(?:_[a-z0-9_]+)?\.sql$/);
  assert.ok(match, `Cannot derive semantic version from ${fileName}`);
  if (match.groups.minor) return `v${match.groups.major}.${match.groups.minor}`;
  return `v${match.groups.major}${match.groups.letter || ''}`;
}

function assertDeployVersion(value, label) {
  assert.match(value, /^\d{14}$/, `${label} must be a 14-digit proposed deploy version`);
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

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

async function buildExpectedManifest() {
  const plan = JSON.parse(await readFile(planPath, 'utf8'));
  exactKeys(plan, ['schemaVersion', 'status', 'items'], 'migration order plan');
  assert.equal(plan.schemaVersion, 1);
  assert.equal(plan.status, 'planning_only_not_deployable');
  assert.ok(Array.isArray(plan.items) && plan.items.length > 0, 'migration order plan must contain items');

  const seenPaths = new Set();
  const seenReservations = new Set();
  const seenVersions = new Set();
  const entries = [];
  const sourceVersions = new Map();
  let priorVersion = '';
  const realMigrationsDir = await realpath(migrationsDir);

  for (let index = 0; index < plan.items.length; index += 1) {
    const item = plan.items[index];
    const label = `plan item ${index + 1}`;
    assertDeployVersion(item.proposedDeployVersion, label);
    assert.ok(item.proposedDeployVersion > priorVersion, `${label} deploy version must be strictly monotonic`);
    assert.ok(!seenVersions.has(item.proposedDeployVersion), `${label} deploy version is duplicated`);
    priorVersion = item.proposedDeployVersion;
    seenVersions.add(item.proposedDeployVersion);

    if (item.kind === 'executable') {
      exactKeys(item, ['kind', 'path', 'semanticVersion', 'proposedDeployVersion'], label);
      assert.match(item.path, /^db\/migrations\/[A-Za-z0-9_]+\.sql$/, `${label} has an unsafe path`);
      assert.ok(!seenPaths.has(item.path), `${label} path is duplicated`);
      const absolute = path.resolve(repoRoot, item.path);
      assert.equal(path.dirname(absolute), migrationsDir, `${label} must remain directly under db/migrations`);
      assert.equal(path.dirname(await realpath(absolute)), realMigrationsDir, `${label} resolves outside db/migrations`);
      assert.ok((await lstat(absolute)).isFile(), `${label} is not a regular file`);
      assert.equal(item.semanticVersion, semanticVersion(path.basename(item.path)), `${label} semantic version mismatch`);
      const bytes = await readFile(absolute);
      entries.push({
        order: index + 1,
        kind: item.kind,
        path: item.path,
        semanticVersion: item.semanticVersion,
        proposedDeployVersion: item.proposedDeployVersion,
        sha256: sha256(bytes)
      });
      const sourceDeployVersion = path.basename(item.path).match(/^\d+/)[0];
      const collisionMembers = sourceVersions.get(sourceDeployVersion) || [];
      collisionMembers.push(item.path);
      sourceVersions.set(sourceDeployVersion, collisionMembers);
      seenPaths.add(item.path);
    } else if (item.kind === 'missing-history-reservation') {
      exactKeys(item, [
        'kind', 'recoveryId', 'semanticVersion', 'proposedDeployVersion', 'exactEvidence'
      ], label);
      assert.match(item.recoveryId, /^frenly_v[a-z0-9_]+$/, `${label} recovery id is invalid`);
      assert.equal(item.exactEvidence, 'missing', `${label} must remain blocked on missing exact evidence`);
      assert.ok(!seenReservations.has(item.recoveryId), `${label} reservation is duplicated`);
      entries.push({ order: index + 1, ...item });
      seenReservations.add(item.recoveryId);
    } else {
      assert.fail(`${label} has unsupported kind`);
    }
  }

  const sqlPaths = (await readdir(migrationsDir, { withFileTypes: true }))
    .filter((entry) => entry.isFile() && entry.name.endsWith('.sql'))
    .map((entry) => `db/migrations/${entry.name}`)
    .sort();
  assert.deepEqual([...seenPaths].sort(), sqlPaths,
    'plan must contain every executable migration exactly once and no nonexistent migration');
  assert.deepEqual(seenReservations, requiredReservations,
    'plan must reserve every locally proven missing historical migration');

  const orderOf = (predicate) => entries.findIndex(predicate);
  assert.ok(orderOf((item) => item.semanticVersion === 'v12a')
    < orderOf((item) => item.semanticVersion === 'v12'), 'explicit order must preserve v12a before v12');
  assert.ok(orderOf((item) => item.recoveryId === 'frenly_v11c_revoke_truncate')
    > orderOf((item) => item.semanticVersion === 'v11b'), 'v11c reservation must follow v11b');
  assert.ok(orderOf((item) => item.recoveryId === 'frenly_v11c_revoke_truncate')
    < orderOf((item) => item.semanticVersion === 'v12a'), 'v11c reservation must precede v12a');

  const sourceDeployVersionCollisions = [...sourceVersions.entries()]
    .filter(([, paths]) => paths.length > 1)
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([sourceDeployVersion, paths]) => ({
      sourceDeployVersion,
      count: paths.length,
      paths: [...paths].sort()
    }));

  return {
    schemaVersion: 1,
    status: 'planning_only_not_deployable',
    sourcePlan: 'db/migrations/migration-order.plan.json',
    hashAlgorithm: 'sha256-raw-bytes',
    itemCount: entries.length,
    executableCount: seenPaths.size,
    reservationCount: seenReservations.size,
    sourceCollisionsResolved: sourceDeployVersionCollisions.length === 0,
    sourceDeployVersionCollisions,
    items: entries
  };
}

async function main() {
  const option = process.argv[2] || '--check';
  assert.ok(['--check', '--write'].includes(option),
    'Usage: node scripts/migrations/generate-manifest.mjs [--check|--write]');
  assert.equal(process.argv.length, option === process.argv[2] ? 3 : 2, 'Unexpected arguments');
  const expected = `${JSON.stringify(await buildExpectedManifest(), null, 2)}\n`;
  const digest = `${sha256(Buffer.from(expected))}  migration-order.manifest.json\n`;
  if (option === '--write') {
    await writeFile(manifestPath, expected, 'utf8');
    await writeFile(digestPath, digest, 'utf8');
    return;
  }
  assert.equal(await readFile(manifestPath, 'utf8'), expected, 'migration manifest is stale or modified');
  assert.equal(await readFile(digestPath, 'utf8'), digest, 'migration manifest digest is stale or modified');
}

await main();
