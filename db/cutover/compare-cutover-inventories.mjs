#!/usr/bin/env node
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const REQUIRED_PATHS = [
  'inventory.sections.extensions',
  'inventory.sections.migration_history',
  'inventory.sections.schemas',
  'inventory.sections.tables',
  'inventory.sections.columns',
  'inventory.sections.constraints',
  'inventory.sections.indexes',
  'inventory.sections.views',
  'inventory.sections.functions',
  'inventory.sections.function_execute_grants',
  'inventory.sections.triggers',
  'inventory.sections.rls_tables',
  'inventory.sections.policies',
  'inventory.sections.grants',
  'inventory.sections.realtime_publications',
  'inventory.sections.cron_jobs',
  'inventory.metrics.table_row_counts',
  'inventory.metrics.auth_user_count',
  'inventory.metrics.storage_counts',
  'reconciliation.metrics.entity_counts',
  'reconciliation.metrics.tenant_aggregates',
  'reconciliation.metrics.orphan_checks',
  'reconciliation.metrics.immutable_sales_flags',
  'reconciliation.metrics.points_ledger_reconciliation',
  'reconciliation.metrics.credit_balance_reconciliation',
  'reconciliation.metrics.gift_card_member_liability',
  'reconciliation.metrics.duplicate_cron_jobs',
  'reconciliation.metrics.function_execute_exposure'
];

const VOLATILE_KEYS = new Set(['scope', 'project_ref', 'generated_at', 'generated_at_utc', 'compared_at_utc']);
const BLOCKING_SEVERITY = new Set([
  'P0_MISSING_METRIC',
  'P0_SECURITY',
  'P0_FINANCIAL',
  'P0_DATA_LOSS',
  'P0_OPERATIONAL',
  'P1_SCHEMA_DRIFT'
]);

const SAFE_META_KEYS = new Set([
  'active',
  'active_member_count',
  'accrual_revenue_cents',
  'all_tables',
  'balance_mismatch_count',
  'balance_view_credit_cents',
  'balance_view_points',
  'batch_remaining_points',
  'bucket_count',
  'bucket_fingerprint',
  'buckets_table_exists',
  'business_id',
  'check_name',
  'client_count',
  'client_credit_balance_exists',
  'client_points_balance_exists',
  'collation',
  'column_name',
  'command',
  'command_fingerprint',
  'command_fingerprints',
  'constraint_name',
  'constraint_type',
  'credit_ledger_exists',
  'database_name',
  'data_type',
  'default_fingerprint',
  'definition_fingerprint',
  'delete',
  'duplicate_count',
  'earned_points',
  'enabled',
  'entity_counts',
  'extension_name',
  'function_name',
  'function_schema',
  'generated',
  'gift_card_liability_cents',
  'gift_cards_exists',
  'grantable',
  'grantee',
  'grantor',
  'hardening_required',
  'identity',
  'identity_arguments',
  'immutable_sales_flags',
  'immutable_trigger_present',
  'index_name',
  'insert',
  'is_primary',
  'is_unique',
  'is_valid',
  'job_fingerprint',
  'job_id',
  'kind',
  'language',
  'ledger_credit_cents',
  'ledger_points',
  'leakproof',
  'member_credit_liability_cents',
  'memberships_exists',
  'missing_snapshot_count',
  'mutable_grants',
  'not_null',
  'object_kind',
  'object_name',
  'object_count',
  'objects_by_bucket',
  'objects_table_exists',
  'orphan_count',
  'ordinal',
  'owner',
  'parallel',
  'permissive',
  'persistence',
  'points_batches_exists',
  'points_ledger_exists',
  'policy_name',
  'privilege',
  'publication_name',
  'relkind',
  'return_type',
  'rls_enabled',
  'rls_forced',
  'roles',
  'row_count',
  'runnable',
  'risk_code',
  'schedule',
  'schedules',
  'schema_name',
  'search_path',
  'security_definer',
  'security_invoker',
  'snapshot_columns_present',
  'staff_count',
  'strict',
  'table_exists',
  'table_name',
  'tenant_rows',
  'total_liability_cents',
  'trigger_name',
  'truncate',
  'update',
  'username',
  'using_fingerprint',
  'version',
  'view_name',
  'volatility',
  'with_check_fingerprint'
]);

const UNSAFE_KEY_PATTERN = /(^|_)(email|phone|mobile|name|full_name|first_name|last_name|note|notes|message|password|password_hash|encrypted_password|token|access_token|refresh_token|secret|api_key|authorization|jwt|gift_card_code|code)($|_)/i;
const EMAIL_VALUE_PATTERN = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i;
const DB_URL_PATTERN = /\b(postgres|postgresql):\/\/|supabase\.co\b|service_role\b|anon_key\b|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/i;

function usage(exitCode = 2) {
  const message = [
    'Usage: node db/cutover/compare-cutover-inventories.mjs <source-cutover.json> <target-cutover.json> [--out diff.json]',
    '',
    'Inputs must be JSON files only. Database URLs, Supabase URLs, tokens, and inline JSON are rejected.'
  ].join('\n');
  (exitCode === 0 ? console.log : console.error)(message);
  process.exit(exitCode);
}

function isUrlLike(value) {
  return /:\/\//.test(value) || DB_URL_PATTERN.test(value);
}

function parseArgs(argv) {
  if (argv.includes('--help') || argv.includes('-h')) usage(0);
  const positional = [];
  let outPath = null;

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--out') {
      outPath = argv[i + 1];
      i += 1;
      if (!outPath) usage();
      continue;
    }
    positional.push(arg);
  }

  if (positional.length !== 2) usage();
  for (const arg of [...positional, outPath].filter(Boolean)) {
    if (isUrlLike(arg)) {
      throw piiError(`Refusing URL/token-like argument: ${arg}`);
    }
  }
  return { sourcePath: positional[0], targetPath: positional[1], outPath };
}

function piiError(message) {
  const err = new Error(message);
  err.code = 'PII_GUARD';
  return err;
}

function readJsonFile(filePath) {
  const absolute = resolve(filePath);
  const raw = readFileSync(absolute, 'utf8');
  if (DB_URL_PATTERN.test(raw)) {
    throw piiError(`Refusing ${filePath}: contains a URL/token-like value`);
  }
  try {
    return JSON.parse(raw);
  } catch (error) {
    throw new Error(`Invalid JSON in ${filePath}: ${error.message}`);
  }
}

function assertNoPii(value, path = '$') {
  if (Array.isArray(value)) {
    value.forEach((item, index) => assertNoPii(item, `${path}[${index}]`));
    return;
  }

  if (value && typeof value === 'object') {
    for (const [key, child] of Object.entries(value)) {
      const migrationHistoryName = key === 'name' && /\.migration_history\[\d+\]$/.test(path);
      if (!migrationHistoryName && !SAFE_META_KEYS.has(key) && UNSAFE_KEY_PATTERN.test(key)) {
        throw piiError(`Refusing possible PII/secrets key at ${path}.${key}`);
      }
      assertNoPii(child, `${path}.${key}`);
    }
    return;
  }

  if (typeof value === 'string') {
    if (EMAIL_VALUE_PATTERN.test(value)) {
      throw piiError(`Refusing possible email value at ${path}`);
    }
    if (DB_URL_PATTERN.test(value)) {
      throw piiError(`Refusing possible URL/token/secret value at ${path}`);
    }
  }
}

function normalizeEnvelope(input) {
  if (input && input.inventory && input.reconciliation) {
    return {
      inventory: input.inventory,
      reconciliation: input.reconciliation
    };
  }

  if (input?.kind === 'supabase_cutover_inventory_v1') {
    return { inventory: input, reconciliation: {} };
  }

  throw new Error('Expected a combined { inventory, reconciliation } JSON object');
}

function hasPath(object, path) {
  const parts = path.split('.');
  let cursor = object;
  for (const part of parts) {
    if (!cursor || typeof cursor !== 'object' || !(part in cursor)) return false;
    cursor = cursor[part];
  }
  return true;
}

function getPath(object, path) {
  return path.split('.').reduce((cursor, part) => (cursor == null ? undefined : cursor[part]), object);
}

function stable(value) {
  if (Array.isArray(value)) {
    return value.map(stable).sort((a, b) => stableString(a).localeCompare(stableString(b)));
  }
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value)
        .filter(([key]) => !VOLATILE_KEYS.has(key))
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([key, child]) => [key, stable(child)])
    );
  }
  return value;
}

function stableString(value) {
  return JSON.stringify(stable(value));
}

function classify(path, missing = false) {
  if (missing) return 'P0_MISSING_METRIC';
  if (/function_execute|polic|rls|grant|security_definer|mutable_grants/i.test(path)) return 'P0_SECURITY';
  if (/liability|credit|points|amount_cents|revenue|payment|sales_amount|snapshot/i.test(path)) return 'P0_FINANCIAL';
  if (/row_count|entity_counts|tenant_aggregates|orphan|auth_user_count|storage_counts/i.test(path)) return 'P0_DATA_LOSS';
  if (/cron|realtime|publication/i.test(path)) return 'P0_OPERATIONAL';
  if (/extensions|migration_history|schemas|tables|columns|constraints|indexes|views|functions|triggers/i.test(path)) return 'P1_SCHEMA_DRIFT';
  return 'P2_REVIEW';
}

function addFinding(findings, { severity, path, rule, message, source, target }) {
  findings.push({
    severity,
    blocker: BLOCKING_SEVERITY.has(severity),
    path,
    rule,
    message,
    ...(source !== undefined ? { source } : {}),
    ...(target !== undefined ? { target } : {})
  });
}

function compareAtPath(source, target, path, findings) {
  const sourceValue = stable(getPath(source, path));
  const targetValue = stable(getPath(target, path));
  if (stableString(sourceValue) === stableString(targetValue)) return;

  if (Array.isArray(sourceValue) && Array.isArray(targetValue)) {
    const sourceRows = new Map();
    const targetRows = new Map();
    for (const row of sourceValue.map(stableString)) sourceRows.set(row, (sourceRows.get(row) ?? 0) + 1);
    for (const row of targetValue.map(stableString)) targetRows.set(row, (targetRows.get(row) ?? 0) + 1);

    const missing = [];
    const extra = [];
    for (const [row, count] of sourceRows) {
      const delta = count - (targetRows.get(row) ?? 0);
      for (let i = 0; i < delta; i += 1) missing.push(JSON.parse(row));
    }
    for (const [row, count] of targetRows) {
      const delta = count - (sourceRows.get(row) ?? 0);
      for (let i = 0; i < delta; i += 1) extra.push(JSON.parse(row));
    }

    addFinding(findings, {
      severity: classify(path),
      path,
      rule: 'array_mismatch',
      message: `${path} differs: ${missing.length} source rows missing from target comparison set, ${extra.length} target rows not in source comparison set`,
      source: { missing_in_target: missing },
      target: { extra_in_target: extra }
    });
    return;
  }

  addFinding(findings, {
    severity: classify(path),
    path,
    rule: 'value_mismatch',
    message: `${path} differs`,
    source: sourceValue,
    target: targetValue
  });
}

function addMissingMetricFindings(source, target, findings) {
  for (const requiredPath of REQUIRED_PATHS) {
    if (!hasPath(source, requiredPath)) {
      addFinding(findings, {
        severity: 'P0_MISSING_METRIC',
        path: requiredPath,
        rule: 'missing_source_metric',
        message: `Source output is missing required metric ${requiredPath}`
      });
    }
    if (!hasPath(target, requiredPath)) {
      addFinding(findings, {
        severity: 'P0_MISSING_METRIC',
        path: requiredPath,
        rule: 'missing_target_metric',
        message: `Target output is missing required metric ${requiredPath}`
      });
    }
  }
}

function addSelfFindings(label, envelope, findings) {
  const exposure = getPath(envelope, 'reconciliation.metrics.function_execute_exposure') ?? {};
  for (const key of [
    'known_risk_public_execute_grants',
    'unexpected_anon_execute_grants',
    'unexpected_public_execute_grants',
    'security_definer_without_search_path',
    'public_security_definer_exposed_to_anon'
  ]) {
    const rows = exposure[key];
    if (Array.isArray(rows) && rows.length > 0) {
      addFinding(findings, {
        severity: 'P0_SECURITY',
        path: `reconciliation.metrics.function_execute_exposure.${key}`,
        rule: `${label}_${key}`,
        message: `${label} has ${rows.length} ${key.replaceAll('_', ' ')}`,
        source: label === 'source' ? rows : undefined,
        target: label === 'target' ? rows : undefined
      });
    }
  }

  const cronDuplicates = getPath(envelope, 'reconciliation.metrics.duplicate_cron_jobs');
  if (Array.isArray(cronDuplicates) && cronDuplicates.length > 0) {
    addFinding(findings, {
      severity: 'P0_OPERATIONAL',
      path: 'reconciliation.metrics.duplicate_cron_jobs',
      rule: `${label}_duplicate_cron_jobs`,
      message: `${label} has ${cronDuplicates.length} duplicate cron job definitions`,
      source: label === 'source' ? cronDuplicates : undefined,
      target: label === 'target' ? cronDuplicates : undefined
    });
  }

  const orphanChecks = getPath(envelope, 'reconciliation.metrics.orphan_checks');
  if (Array.isArray(orphanChecks)) {
    const nonzero = orphanChecks.filter((row) => row?.runnable === true && Number(row?.orphan_count ?? 0) !== 0);
    if (nonzero.length > 0) {
      addFinding(findings, {
        severity: 'P0_DATA_LOSS',
        path: 'reconciliation.metrics.orphan_checks',
        rule: `${label}_orphan_rows`,
        message: `${label} has nonzero orphan/cross-tenant integrity checks`,
        source: label === 'source' ? nonzero : undefined,
        target: label === 'target' ? nonzero : undefined
      });
    }
  }

  const immutable = getPath(envelope, 'reconciliation.metrics.immutable_sales_flags');
  if (immutable && typeof immutable === 'object') {
    const problems = [];
    if (immutable.sales_table_exists === true && immutable.snapshot_columns_present !== true) problems.push('snapshot_columns_missing');
    if (Number(immutable.missing_snapshot_count ?? 0) !== 0) problems.push('missing_snapshot_rows');
    if (immutable.sales_table_exists === true && immutable.immutable_trigger_present !== true) problems.push('immutable_trigger_missing');
    if (Array.isArray(immutable.mutable_grants) && immutable.mutable_grants.length > 0) problems.push('mutable_sales_grants');
    if (problems.length > 0) {
      addFinding(findings, {
        severity: 'P0_FINANCIAL',
        path: 'reconciliation.metrics.immutable_sales_flags',
        rule: `${label}_immutable_sales_flags_invalid`,
        message: `${label} sales immutability checks failed: ${problems.join(', ')}`,
        source: label === 'source' ? immutable : undefined,
        target: label === 'target' ? immutable : undefined
      });
    }
  }

  for (const path of [
    'reconciliation.metrics.points_ledger_reconciliation.tenant_rows',
    'reconciliation.metrics.credit_balance_reconciliation.tenant_rows'
  ]) {
    const rows = getPath(envelope, path);
    if (Array.isArray(rows)) {
      const mismatched = rows.filter((row) => Number(row?.balance_mismatch_count ?? 0) !== 0);
      if (mismatched.length > 0) {
        addFinding(findings, {
          severity: 'P0_FINANCIAL',
          path,
          rule: `${label}_ledger_balance_mismatch`,
          message: `${label} has ledger/view balance mismatches at ${path}`,
          source: label === 'source' ? mismatched : undefined,
          target: label === 'target' ? mismatched : undefined
        });
      }
    }
  }
}

export function compareCutoverOutputs(sourceInput, targetInput) {
  assertNoPii(sourceInput);
  assertNoPii(targetInput);

  const source = normalizeEnvelope(sourceInput);
  const target = normalizeEnvelope(targetInput);
  const findings = [];

  addMissingMetricFindings(source, target, findings);
  if (findings.length === 0) {
    for (const path of REQUIRED_PATHS) compareAtPath(source, target, path, findings);
  }

  addSelfFindings('source', source, findings);
  addSelfFindings('target', target, findings);

  findings.sort((a, b) => {
    const severity = a.severity.localeCompare(b.severity);
    if (severity !== 0) return severity;
    const path = a.path.localeCompare(b.path);
    if (path !== 0) return path;
    return a.rule.localeCompare(b.rule);
  });

  const blockers = findings.filter((finding) => finding.blocker);
  return {
    ok: blockers.length === 0 && findings.length === 0,
    launch_blocked: blockers.length > 0,
    summary: {
      findings: findings.length,
      blockers: blockers.length,
      source_required_paths: REQUIRED_PATHS.length,
      target_required_paths: REQUIRED_PATHS.length
    },
    severity_classes: {
      P0_MISSING_METRIC: 'A required metric is absent. The comparator fails closed.',
      P0_SECURITY: 'RLS, policy, grant, function exposure, or privileged function posture blocks launch.',
      P0_FINANCIAL: 'Sales immutability, revenue, ledger, credit, points, or liability mismatch blocks launch.',
      P0_DATA_LOSS: 'Row-count, tenant aggregate, auth/storage count, or orphan mismatch blocks launch.',
      P0_OPERATIONAL: 'Cron/realtime operational drift that can duplicate jobs or lose updates blocks launch.',
      P1_SCHEMA_DRIFT: 'Schema/catalog drift blocks cutover until explained and signed off.',
      P2_REVIEW: 'Non-blocking advisory drift.'
    },
    launch_blocking_rules: [
      'Any P0 finding blocks launch.',
      'Any P1 schema drift blocks launch unless a written cutover exception names the exact object and risk owner.',
      'Any missing required metric blocks launch.',
      'Any known-risk phone-only public RPC exposure blocks launch until OTP or signed-token hardening exists.',
      'Any unexpected anon/public function execute exposure blocks launch.',
      'Any nonzero orphan or cross-tenant integrity check blocks launch.',
      'Any sales immutability, ledger/view balance, credit, points, or liability mismatch blocks launch.',
      'Any duplicate cron definition blocks launch.'
    ],
    findings
  };
}

function main() {
  try {
    const { sourcePath, targetPath, outPath } = parseArgs(process.argv.slice(2));
    const result = compareCutoverOutputs(readJsonFile(sourcePath), readJsonFile(targetPath));
    const output = `${JSON.stringify(result, null, 2)}\n`;
    if (outPath) writeFileSync(resolve(outPath), output);
    process.stdout.write(output);
    process.exit(result.launch_blocked || !result.ok ? 1 : 0);
  } catch (error) {
    const status = error.code === 'PII_GUARD' ? 2 : 1;
    process.stderr.write(`${error.code ?? 'ERROR'}: ${error.message}\n`);
    process.exit(status);
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}
