/* nestly_v899 — what Meta's answer means for our send gate.
 *
 * These EXECUTE the real mapping the admin plane imports. The bias of every assertion is the
 * same: 'approved' is the only status that lets a template send, so the tests care far more
 * about what does NOT become 'approved' than about what does.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

import {
  planTemplateReconcile,
  reconcileTemplateStatuses,
  registryStatusForMeta,
} from '../../supabase/functions/_shared/whatsapp-template-status-boundaries.mjs';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const readRepoFile = (relative) => readFileSync(resolve(repoRoot, relative), 'utf8');

test('only Meta APPROVED opens the gate', () => {
  assert.deepEqual(registryStatusForMeta('APPROVED'), { status: 'approved', recognised: true });
  // Waiting on a human at Meta.
  for (const pending of ['PENDING', 'IN_APPEAL', 'PENDING_REVIEW']) {
    assert.equal(registryStatusForMeta(pending).status, 'submitted', pending);
  }
  // Needs an edit, not a wait — worth keeping distinct from the rest.
  assert.equal(registryStatusForMeta('REJECTED').status, 'rejected');
  // Exists, must not send.
  for (const stopped of ['PAUSED', 'DISABLED', 'LIMIT_EXCEEDED', 'DELETED', 'PENDING_DELETION']) {
    assert.equal(registryStatusForMeta(stopped).status, 'paused', stopped);
  }
  // Case and whitespace are Meta's business, not ours.
  assert.equal(registryStatusForMeta('  approved  ').status, 'approved');
});

test('a status Meta invents later is paused and named, never guessed at', () => {
  const unknown = registryStatusForMeta('SOME_FUTURE_STATE');
  assert.equal(unknown.status, 'paused', 'an unrecognised status must not be sendable');
  assert.equal(unknown.recognised, false, 'and must be reported so a human sees it');
  for (const empty of ['', null, undefined]) {
    const answer = registryStatusForMeta(empty);
    assert.equal(answer.status, 'paused');
    assert.equal(answer.recognised, false);
  }
});

test('reconcile records Meta, and refuses to invent a row', () => {
  const registry = [
    { template_key: 'bring_back_v1', meta_name: 'peekaa_bring_back_v1', status: 'submitted' },
    { template_key: 'appointment_updated', meta_name: 'peekaa_appt_updated', status: 'submitted' },
  ];
  const meta = [
    { name: 'peekaa_bring_back_v1', status: 'APPROVED', id: '276' },
    { name: 'peekaa_appt_updated', status: 'APPROVED', id: '220' },
    // Created in Business Manager by somebody; Peekaa has never heard of it.
    { name: 'someone_elses_template', status: 'APPROVED', id: '999' },
  ];
  const plan = reconcileTemplateStatuses(meta, registry);

  assert.deepEqual(plan.observations, [
    { meta_name: 'peekaa_bring_back_v1', status: 'approved', meta_template_id: '276' },
    { meta_name: 'peekaa_appt_updated', status: 'approved', meta_template_id: '220' },
  ]);
  // The gate's membership is decided by the migrations and the TEMPLATES array, never by whatever
  // exists in the WABA — otherwise anyone with Business Manager access could add a sendable row.
  assert.deepEqual(plan.ignored, ['someone_elses_template']);
  assert.deepEqual(plan.absentAtMeta, []);
  assert.deepEqual(plan.unrecognised, []);
});

test('a template that has vanished from Meta stops being sendable — unless it was never sent', () => {
  const registry = [
    { template_key: 'appointment_reminder', meta_name: 'peekaa_appt_reminder', status: 'approved' },
    // v894's OTP template: written, registered, not yet submitted. Absent from Meta is its NORMAL
    // state and must not be reported as something going wrong.
    { template_key: 'signup_otp', meta_name: 'peekaa_signup_otp', status: 'draft' },
  ];
  const plan = reconcileTemplateStatuses([], registry);

  assert.deepEqual(plan.observations, [
    { meta_name: 'peekaa_appt_reminder', status: 'paused', meta_template_id: null },
  ]);
  assert.deepEqual(plan.absentAtMeta, ['peekaa_appt_reminder']);
  assert.ok(!plan.absentAtMeta.includes('peekaa_signup_otp'),
    'a draft template is not missing, it is unsent');
});

test('an unrecognised Meta status still reaches the database, as paused and flagged', () => {
  const registry = [{ template_key: 'bring_back_v1', meta_name: 'peekaa_bring_back_v1', status: 'approved' }];
  const plan = reconcileTemplateStatuses(
    [{ name: 'peekaa_bring_back_v1', status: 'QUARANTINED_BY_META', id: '276' }], registry);

  assert.deepEqual(plan.observations, [
    { meta_name: 'peekaa_bring_back_v1', status: 'paused', meta_template_id: '276' },
  ]);
  assert.deepEqual(plan.unrecognised, [
    { meta_name: 'peekaa_bring_back_v1', meta_status: 'QUARANTINED_BY_META' },
  ]);
});

test('a second language row does not decide the gate for the one we hold', () => {
  const registry = [{ template_key: 'bring_back_v1', meta_name: 'peekaa_bring_back_v1', status: 'approved' }];
  const plan = reconcileTemplateStatuses([
    { name: 'peekaa_bring_back_v1', status: 'APPROVED', id: '276' },
    { name: 'peekaa_bring_back_v1', status: 'REJECTED', id: '277' },
  ], registry);
  assert.equal(plan.observations.length, 1, 'one registered template, one observation');
  assert.equal(plan.observations[0].status, 'approved');
});

test('malformed input cannot produce a write', () => {
  assert.deepEqual(reconcileTemplateStatuses(null, null).observations, []);
  assert.deepEqual(reconcileTemplateStatuses(undefined, []).observations, []);
  assert.deepEqual(reconcileTemplateStatuses([{ status: 'APPROVED' }], []).observations, [],
    'a Meta row with no name names no registry row');
});

test('nestly_v900/v973: a registered template this plane never submits is not "absent from Meta"', () => {
  /* THE BUG, EXECUTED — not greped for. The first live reconcile paused peekaa_bring_back_v1, a
     template Meta had approved, because the Meta list reaching the reconciler had been filtered to
     this function's TEMPLATES array, and bring_back is registered by migration v551 and has never
     been in it. "Not in our submission catalogue" read as "deleted at Meta".
     The registry below is production's shape; the Meta list is what the Graph API really returns,
     including the demo template nobody registered. */
  const registry = [
    { template_key: 'bring_back_v1', meta_name: 'peekaa_bring_back_v1', status: 'approved' },
    { template_key: 'appointment_reminder', meta_name: 'peekaa_appt_reminder', status: 'approved' },
    { template_key: 'signup_otp', meta_name: 'peekaa_signup_otp', status: 'draft' },
  ];
  const plan = planTemplateReconcile({
    httpOk: true,
    metaRows: [
      { name: 'peekaa_bring_back_v1', status: 'APPROVED', id: '276' },
      { name: 'peekaa_appt_reminder', status: 'APPROVED', id: '160' },
      { name: 'hello_world', status: 'APPROVED', id: '001' },
    ],
    registry,
  });

  assert.equal(plan.ok, true);
  assert.deepEqual(plan.absentAtMeta, [], 'nothing Meta listed may be paused as absent');
  assert.ok(!plan.observations.some((o) => o.status === 'paused'),
    'the v900 regression: no approved template may come back paused');
  assert.deepEqual(plan.ignored, ['hello_world'], "Meta's demo template is not ours to gate");
  assert.ok(!plan.observations.some((o) => o.meta_name === 'peekaa_signup_otp'),
    'a draft template absent from Meta is unsent, not missing');
});

test('nestly_v973: a failed Meta read refuses, and writes nothing', () => {
  const registry = [{ template_key: 'bring_back_v1', meta_name: 'peekaa_bring_back_v1', status: 'approved' }];
  // The destructive shape: an errored Graph call returns no rows, every template looks absent, and
  // a naive reconcile pauses the whole lane. Executed, not asserted about the source.
  const refused = planTemplateReconcile({ httpOk: false, metaRows: [], registry });
  assert.deepEqual(refused, { ok: false, reason: 'meta_read_failed' });
  assert.equal(refused.observations, undefined, 'a refusal must carry nothing writable');

  // Even if the failed call somehow carried rows, a non-2xx is still not evidence.
  assert.deepEqual(
    planTemplateReconcile({ httpOk: false, metaRows: [{ name: 'peekaa_bring_back_v1', status: 'DELETED' }], registry }),
    { ok: false, reason: 'meta_read_failed' },
  );
});

test('nestly_v973: a 200 with an empty list refuses too', () => {
  const registry = [{ template_key: 'bring_back_v1', meta_name: 'peekaa_bring_back_v1', status: 'approved' }];
  for (const metaRows of [[], null, undefined]) {
    const refused = planTemplateReconcile({ httpOk: true, metaRows, registry });
    assert.deepEqual(refused, { ok: false, reason: 'meta_returned_no_templates' },
      'an empty list is a scoping oddity, never mass deletion');
  }
  // A registry that failed to read is its own refusal, and also writes nothing.
  assert.deepEqual(
    planTemplateReconcile({ httpOk: true, metaRows: [{ name: 'x', status: 'APPROVED' }], registry: null }),
    { ok: false, reason: 'registry_read_failed' },
  );
});

test('nestly_v973: a template Meta really did delete still gets paused', () => {
  // The guards must not have made reconcile toothless: a NON-empty list that omits a live template
  // is the real deletion signal, and it must still close the gate.
  const registry = [
    { template_key: 'bring_back_v1', meta_name: 'peekaa_bring_back_v1', status: 'approved' },
    { template_key: 'appointment_reminder', meta_name: 'peekaa_appt_reminder', status: 'approved' },
  ];
  const plan = planTemplateReconcile({
    httpOk: true,
    metaRows: [{ name: 'peekaa_bring_back_v1', status: 'APPROVED', id: '276' }],
    registry,
  });
  assert.equal(plan.ok, true);
  assert.deepEqual(plan.absentAtMeta, ['peekaa_appt_reminder']);
  assert.deepEqual(
    plan.observations.find((o) => o.meta_name === 'peekaa_appt_reminder'),
    { meta_name: 'peekaa_appt_reminder', status: 'paused', meta_template_id: null },
  );
});

test('nestly_v973: the handler delegates the decision rather than re-implementing it', () => {
  /* The ONLY thing a source check may legitimately assert is WIRING — that the handler routes
     through the boundary the tests above execute. Behaviour is proven by executing that boundary,
     never by matching this file's text. v900's version of this test asserted the behaviour itself
     by grep, and went red the moment the same logic moved one file left. */
  const source = readRepoFile('supabase/functions/whatsapp-admin-templates/index.ts');
  assert.match(source, /import \{ planTemplateReconcile \}/,
    'the handler must import the decision, not carry a copy of it');
  assert.ok(!/reconcileTemplateStatuses\(/.test(source),
    'the handler must not call the low-level mapper directly, bypassing the guards');
  assert.equal((source.match(/planTemplateReconcile\(/g) || []).length, 3,
    'both refusals and the plan all go through the one decision');
  // The read-only status action must stay read-only: it still answers from the filtered list.
  assert.match(source, /if \(action !== 'reconcile'\) \{\n\s*return Response\.json\(\{ action, http: r\.status, templates: rows/);
});

test('the RPC is service_role only and never inserts', () => {
  const migration = readRepoFile('db/migrations/20261011_nestly_v899_template_status_reconcile.sql');
  assert.match(migration, /grant execute on function public\.internal_whatsapp_template_reconcile_v899\(jsonb\) to service_role/);
  assert.match(migration, /revoke all on function public\.internal_whatsapp_template_reconcile_v899\(jsonb\)[\s\S]{0,80}from public, anon, authenticated/);
  assert.ok(!/insert\s+into\s+public\.whatsapp_template_registry_v551/i.test(migration),
    'reconcile must never add a row to the send gate');
  // The parameter contract the sender binds against is not Meta's to rewrite.
  for (const column of ['body_text', 'parameter_descriptors', 'category', 'language_code']) {
    assert.ok(!new RegExp(`set[\\s\\S]{0,200}${column}\\s*=`).test(migration),
      `reconcile must not write ${column}`);
  }
});
