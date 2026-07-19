import { readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = resolve(import.meta.dirname, '../..');
const sqlFiles = [
  'db/cutover/_inventory_core.sql',
  'db/cutover/_reconciliation_core.sql',
  'db/cutover/source_inventory.sql',
  'db/cutover/source_reconciliation.sql',
  'db/cutover/rehearsal_inventory.sql',
  'db/cutover/rehearsal_reconciliation.sql',
  'db/cutover/target_inventory.sql',
  'db/cutover/target_reconciliation.sql'
];

const wrapperExpectations = [
  {
    path: 'db/cutover/source_inventory.sql',
    scope: 'source',
    projectRef: 'kyzovonwnscrzmkvocid',
    core: '_inventory_core.sql'
  },
  {
    path: 'db/cutover/source_reconciliation.sql',
    scope: 'source',
    projectRef: 'kyzovonwnscrzmkvocid',
    core: '_reconciliation_core.sql'
  },
  {
    path: 'db/cutover/rehearsal_inventory.sql',
    scope: 'rehearsal',
    projectRef: 'wtegnefsgnyxhflzizcu',
    core: '_inventory_core.sql'
  },
  {
    path: 'db/cutover/rehearsal_reconciliation.sql',
    scope: 'rehearsal',
    projectRef: 'wtegnefsgnyxhflzizcu',
    core: '_reconciliation_core.sql'
  },
  {
    path: 'db/cutover/target_inventory.sql',
    scope: 'target',
    projectRef: 'gadpooereceldfpfxsod',
    core: '_inventory_core.sql'
  },
  {
    path: 'db/cutover/target_reconciliation.sql',
    scope: 'target',
    projectRef: 'gadpooereceldfpfxsod',
    core: '_reconciliation_core.sql'
  }
];

function stripSqlComments(sql) {
  return sql
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/--.*$/gm, '');
}

test('cutover SQL does not project raw PII, auth secrets, storage object names, or cron commands', () => {
  for (const relativePath of sqlFiles) {
    const sql = stripSqlComments(readFileSync(join(root, relativePath), 'utf8')).toLowerCase();
    assert.doesNotMatch(sql, /\bselect\s+\*\s+from\s+auth\.users\b/, relativePath);
    assert.doesNotMatch(sql, /\bauth\.users\.(email|encrypted_password|confirmation_token|recovery_token|raw_user_meta_data|raw_app_meta_data)\b/, relativePath);
    assert.doesNotMatch(sql, /\b(public\.)?clients\.(email|phone|full_name|notes)\b/, relativePath);
    assert.doesNotMatch(sql, /\b(public\.)?booking_requests\.(email|phone|name|notes)\b/, relativePath);
    assert.doesNotMatch(sql, /\b(public\.)?gift_cards\.(code|recipient_email)\b/, relativePath);
    assert.doesNotMatch(sql, /\bstorage\.objects\.(name|metadata|path_tokens)\b/, relativePath);
    assert.doesNotMatch(sql, /\bcron\.job\.command\b/, relativePath);
  }
});

test('all cutover wrappers emit quiet unaligned tuples-only JSON for the expected project ref', () => {
  for (const wrapper of wrapperExpectations) {
    const sql = readFileSync(join(root, wrapper.path), 'utf8');
    assert.match(sql, /^\\set ON_ERROR_STOP on$/m, wrapper.path);
    assert.match(sql, /^\\set QUIET on$/m, wrapper.path);
    assert.match(sql, /^\\pset tuples_only on$/m, wrapper.path);
    assert.match(sql, /^\\pset format unaligned$/m, wrapper.path);
    assert.match(sql, /^\\pset footer off$/m, wrapper.path);
    assert.match(sql, /^\\pset pager off$/m, wrapper.path);
    assert.match(sql, new RegExp(`^\\\\set gate_scope '${wrapper.scope}'$`, 'm'), wrapper.path);
    assert.match(sql, new RegExp(`^\\\\set gate_project_ref '${wrapper.projectRef}'$`, 'm'), wrapper.path);
    assert.match(sql, new RegExp(`^\\\\ir ${wrapper.core}$`, 'm'), wrapper.path);
  }
});

test('public RPC exposure classification is exact by schema, name, and identity arguments', () => {
  const sql = stripSqlComments(readFileSync(join(root, 'db/cutover/_reconciliation_core.sql'), 'utf8'));
  assert.match(sql, /accepted_public_rpc\(schema_name, function_name, identity_arguments\)/);
  assert.doesNotMatch(sql, /allowed_anon_public_rpc\(function_name\)/);
  assert.match(sql, /a\.schema_name = g\.schema_name\s+and a\.function_name = g\.function_name\s+and a\.identity_arguments = g\.identity_arguments/);
  assert.match(sql, /known_risk_public_rpc\(schema_name, function_name, identity_arguments, risk_code, hardening_required\)/);
  assert.match(sql, /'public', 'list_my_appointments', 'p_slug text, p_phone text'/);
  assert.match(sql, /'public', 'request_change', 'p_slug text, p_appointment uuid, p_phone text, p_kind text, p_proposed timestamp with time zone, p_note text'/);
});
