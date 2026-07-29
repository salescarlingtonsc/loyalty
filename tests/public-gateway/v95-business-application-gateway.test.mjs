import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import {
  normalizeBusinessApplicationLocale,
  validBusinessApplicationPayload,
} from '../../supabase/functions/_shared/validation.ts';

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

test('business application gateway preserves supported Malay and Chinese locale choices',()=>{
  assert.match(gateway,/normalizeBusinessApplicationLocale\(body\.locale\)/);
  for(const locale of ['zh','zh-SG','zh-Hans','zh-cn','ZH-CN']){
    assert.equal(normalizeBusinessApplicationLocale(locale),'zh-CN');
  }
  for(const locale of ['ms','MS','ms-SG','ms-MY','ms-Latn']){
    assert.equal(normalizeBusinessApplicationLocale(locale),'ms');
  }
  assert.equal(normalizeBusinessApplicationLocale('en'),'en');
  assert.equal(normalizeBusinessApplicationLocale('fr'),null);
});

test('business application validation accepts every supported public locale',()=>{
  const application={
    contact_name:'Nur Aisyah',
    contact_email:'owner@example.com',
    contact_phone:'+6581234567',
    business_name:'Kedai Nestly',
    sector_key:'fnb',
    registration_number:'',
    idempotency_key:'319df1fd-b9f6-4bd3-9a23-86a332026456',
    legal_consent:true,
  };

  for(const locale of [
    'en','ms','MS','ms-SG','ms-MY','ms-Latn',
    'zh','zh-CN','zh-SG','zh-Hans'
  ]){
    assert.equal(
      validBusinessApplicationPayload({...application,locale}),
      true,
      `${locale} must be accepted by the shared gateway validator`,
    );
  }
  assert.equal(
    validBusinessApplicationPayload({...application,locale:'fr'}),
    false,
    'unpublished locales remain rejected',
  );
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
