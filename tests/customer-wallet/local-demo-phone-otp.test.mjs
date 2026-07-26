import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const config = await readFile(
  new URL('../../supabase/config.toml', import.meta.url),
  'utf8'
);
const app = await readFile(new URL('../../app/index.html', import.meta.url), 'utf8');

test('local Supabase demo phone uses the owner-requested fixed OTP', () => {
  assert.match(
    config,
    /\[auth\.sms\.test_otp\][\s\S]*\b6581234567\s*=\s*"888888"/
  );
  assert.match(app, /const DEMO_CUSTOMER_PHONE_NUMBERS=\['\+6581234567'\]/);
});

test('the fixed OTP is local configuration, not browser authentication logic', () => {
  assert.doesNotMatch(app, /888888/);
});
