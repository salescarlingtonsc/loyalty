import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = path => readFile(new URL(path, root), 'utf8');

test('client conversion uses the exact v79 optimistic and idempotent contract', async () => {
  const source = await read('app/platform-console.js');

  assert.match(source, /Create Peekaa account/);
  assert.match(source, /previewThenConfirm\(\{\s*title:'Create Peekaa account'/);
  assert.match(source, /convert_sme_prospect_v79',\{\s*p_prospect:prospect\.id,\s*p_expected_version:prospectVersion\(prospect\),\s*p_idempotency_key:idempotencyKey\(\)/);
  assert.match(source, /result\.outcome==='duplicate_workspace'/);
  assert.match(source, /No workspace was created/);
  assert.match(source, /result\.owner_invitation\?\.raw_token/);
  assert.match(source, /Shown once/);
  assert.match(source, /navigator\?\.clipboard\?\.writeText/);
  assert.doesNotMatch(source, /localStorage.*raw_token|sessionStorage.*raw_token/);
});

test('converted prospect drawer loads and renders backend onboarding truth', async () => {
  const source = await read('app/platform-console.js');

  assert.match(source, /get_business_onboarding_v79',\{\s*p_business:prospect\.converted_business_id/);
  assert.match(source, /hydrateOnboardingCards/);
  assert.match(source, /onboarding_summary:facts/);
  assert.match(source, /Evidence-managed lifecycle/);
  assert.match(source, /Evidence-backed onboarding/);
  assert.match(source, /Active blockers/);
  assert.match(source, /Owner invitations/);
  assert.match(source, /Recent evidence events/);
  assert.match(source, /Checklist version/);
  assert.match(source, /facts\.mandatoryFulfilled/);
  assert.match(source, /item\.waivable===true&&item\.item_key!=='go_live_approved'/);
});

test('all v79 onboarding actions pass the current checklist version and a fresh idempotency key', async () => {
  const source = await read('app/platform-console.js');
  for (const rpc of [
    'start_business_onboarding_v79',
    'refresh_business_onboarding_v79',
    'reissue_workspace_owner_invite_v79',
    'record_onboarding_manual_evidence_v79',
    'waive_onboarding_item_v79',
    'block_business_onboarding_v79',
    'unblock_business_onboarding_v79',
    'activate_business_v79'
  ]) assert.match(source,new RegExp(rpc));

  assert.match(source, /const expected=\{p_business:businessId,p_expected_version:facts\.version\}/);
  assert.match(source, /record_onboarding_manual_evidence_v79',\{\s*p_business:detail\.prospect\.converted_business_id,\s*p_item_key:itemKey,\s*p_evidence:evidence,\s*p_expected_version:facts\.version,\s*p_idempotency_key:idempotencyKey\(\)/);
  assert.match(source, /waive_onboarding_item_v79',\{\s*p_business:detail\.prospect\.converted_business_id,\s*p_item_key:itemKey,\s*p_reason:form\.get\('reason'\),\s*p_expected_version:facts\.version,\s*p_idempotency_key:idempotencyKey\(\)/);
  assert.match(source, /block_business_onboarding_v79',\{\s*p_business:detail\.prospect\.converted_business_id,\s*p_item_key:itemKey,\s*p_reason:form\.get\('reason'\),\s*p_expected_version:facts\.version,\s*p_idempotency_key:idempotencyKey\(\)/);
  assert.match(source, /unblock_business_onboarding_v79',\{\s*p_business:detail\.prospect\.converted_business_id,\s*p_item_key:itemKey,\s*p_expected_version:facts\.version,\s*p_idempotency_key:idempotencyKey\(\)/);
  assert.match(source, /activationReady\?'':` disabled title="\$\{escapeHtml\(pt\('Complete every mandatory item and super-admin go-live approval first\.'\)\)\}"`/);
});

test('stale disconnected onboarding language is removed', async () => {
  const source = await read('app/platform-console.js');

  assert.doesNotMatch(source, /activation checklist is not connected/i);
  assert.doesNotMatch(source, /Activated remains unavailable until the real launch checklist is connected/);
  assert.doesNotMatch(source, /Onboarding data is not connected/);
  assert.match(source, /Onboarding system update required/);
});
