import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const gateway = await readFile(
  new URL('../../supabase/functions/public-business-application/index.ts', import.meta.url),
  'utf8',
);
const validation = await readFile(
  new URL('../../supabase/functions/_shared/validation.ts', import.meta.url),
  'utf8',
);

test('business applications are accepted only through the guarded public gateway', () => {
  assert.match(gateway, /requireOrigin\(req\)/);
  assert.match(gateway, /verifyTurnstile\(req, body\.turnstile_token, 'business_application'\)/);
  assert.match(gateway, /business-application-abuse/);
  assert.match(gateway, /business-application-submit/);
  assert.match(gateway, /internal_submit_business_application_v95/);
  assert.doesNotMatch(gateway, /\.rpc\('submit_business_application_v95'/);
});

test('business application payload requires legal consent and an idempotency key', () => {
  assert.match(validation, /validBusinessApplicationPayload/);
  assert.match(validation, /body\.legal_consent === true/);
  assert.match(validation, /UUID_PATTERN\.test\(String\(body\.idempotency_key/);
  assert.match(validation, /PHONE_PATTERN\.test\(String\(body\.contact_phone/);
});

test('public status lookup returns no applicant PII', () => {
  assert.match(gateway, /get_business_application_status_v95/);
  assert.doesNotMatch(gateway, /approved_email/);
});

test('approved invitation inspection is rate limited and service-role mediated', () => {
  assert.match(gateway, /business-application-invitation/);
  assert.match(gateway, /internal_get_approved_business_invitation_v95/);
  assert.match(gateway, /\^\[a-f0-9\]\{64\}\$/);
});
