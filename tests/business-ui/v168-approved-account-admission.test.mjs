import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

const read=path=>readFileSync(new URL(`../../${path}`,import.meta.url),'utf8');

const migration=read('supabase/migrations/20260805210000_nestly_v168_approved_account_signup_admission.sql');
const dbMigration=read('db/migrations/20260805_nestly_v168_approved_account_signup_admission.sql');
const platformConsole=read('app/platform-console.js');
const app=read('app/index.html');

test('V168 admits platform-approved account-only business signups to continue setup',()=>{
  assert.match(migration,/create or replace function public\.complete_business_google_oauth_v138/);
  assert.match(migration,/platform_account_signup_triage_v164/);
  assert.match(migration,/triage\.triage_status='contacted'/);
  assert.match(migration,/requires_business_setup/);
  assert.match(migration,/platform_account_signup_approved/);
  assert.match(migration,/not exists\(select 1 from public\.staff/);
  assert.match(migration,/not exists\(select 1 from public\.self_serve_business_onboarding_v130/);
  assert.match(migration,/not exists\(select 1 from public\.business_applications_v95/);
  assert.match(migration,/existing active business account or approved setup request required/);
});

test('V168 keeps canonical migration copies aligned',()=>{
  assert.equal(dbMigration,migration);
});

test('platform admin copy says approve opens setup but not workspace access',()=>{
  assert.match(platformConsole,/Approval lets the same user sign in and continue business setup/);
  assert.match(platformConsole,/User may now sign in to continue business setup/);
  assert.match(platformConsole,/workspace access still requires business details and verified payment or manual billing/i);
  assert.doesNotMatch(platformConsole,/Approval records the admin decision/);
});

test('business sign-in denial copy points to approval state instead of stale Google account wording',()=>{
  assert.match(app,/No approved business setup or active workspace was found/);
  assert.doesNotMatch(app,/No business account was found for that Google login/);
});
