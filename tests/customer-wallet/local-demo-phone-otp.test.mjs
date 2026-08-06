import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const config = await readFile(
  new URL('../../supabase/config.toml', import.meta.url),
  'utf8'
);
const app = ((await readFile(new URL('../../app/index.html',import.meta.url),'utf8'))+'\n'+(await readFile(new URL('../../app/app.js',import.meta.url),'utf8')));

test('tracked Supabase configuration cannot push a fixed OTP to a hosted project', () => {
  assert.doesNotMatch(config, /\[auth\.sms\.test_otp\]/);
  assert.doesNotMatch(config, /\b6581234567\s*=\s*"888888"/);
  assert.doesNotMatch(app, /DEMO_CUSTOMER_PHONE_NUMBERS/);
});

test('the browser has no fixed OTP or production number bypass', () => {
  assert.doesNotMatch(app, /888888/);
  assert.match(app, /const customerPhoneBlockedInProduction=\(\)=>\(/);
});
