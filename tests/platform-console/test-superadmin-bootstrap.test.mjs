import assert from 'node:assert/strict';
import test from 'node:test';
import {
  bootstrapConfig,
  localSupabaseUrl
} from '../../scripts/dev/bootstrap-test-superadmin.mjs';

test('test super-admin bootstrap is local-only', () => {
  assert.equal(localSupabaseUrl('http://127.0.0.1:54321'), 'http://127.0.0.1:54321');
  assert.equal(localSupabaseUrl('http://localhost:54321'), 'http://localhost:54321');
  assert.throws(() => localSupabaseUrl('https://example.supabase.co'), /local-only/i);
});

test('bootstrap password and service key stay execution-time inputs', () => {
  assert.throws(() => bootstrapConfig({
    SUPABASE_URL: 'http://127.0.0.1:54321',
    SUPABASE_SERVICE_ROLE_KEY: 'test-key'
  }), /password/i);

  const config = bootstrapConfig({
    SUPABASE_URL: 'http://127.0.0.1:54321',
    SUPABASE_SERVICE_ROLE_KEY: 'test-key',
    NESTLY_TEST_SUPERADMIN_PASSWORD: 'test-password-placeholder'
  });
  assert.equal(config.email, 'admin.peekaa@gmail.com');
  assert.equal(config.password, 'test-password-placeholder');
});
