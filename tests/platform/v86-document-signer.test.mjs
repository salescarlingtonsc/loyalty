import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');

test('v86 signer is authenticated, actor-bound and private-bucket only', async () => {
  const [source, config] = await Promise.all([
    read('supabase/functions/sme-document-signer/index.ts'),
    read('supabase/config.toml'),
  ]);
  assert.match(config, /\[functions\.sme-document-signer\]\s+verify_jwt = true/);
  assert.match(source, /authenticatedUserId\(req\)/);
  assert.match(source, /PRIVATE_BUCKET = 'sme-private'/);
  assert.match(source, /p_actor: actor/g);
  assert.match(source, /service_consume_document_signing_request_v86/);
  assert.match(source, /service_get_consumed_document_upload_v86/);
  assert.match(source, /service_finalize_document_upload_v86/);
  assert.doesNotMatch(source, /getPublicUrl|SUPABASE_SERVICE_ROLE_KEY.*body/);
});

test('v86 signer binds finalization to server-observed bytes', async () => {
  const source = await read('supabase/functions/sme-document-signer/index.ts');
  assert.match(source, /\.download\(String\(target\.object_path\)/);
  assert.match(source, /bytes\.byteLength !== Number\(target\.size_bytes\)/);
  assert.match(source, /p_sha256: await digestHex\(bytes\)/);
  assert.match(source, /p_observed_size_bytes: bytes\.byteLength/);
  assert.doesNotMatch(
    source,
    /body\?\.(?:sha256|observed_size_bytes|bucket_id|object_path)/,
  );
});

test('v86 signer exposes bounded upload/read exchange contracts', async () => {
  const [source, docs] = await Promise.all([
    read('supabase/functions/sme-document-signer/index.ts'),
    read('supabase/functions/README.md'),
  ]);
  assert.match(source, /createSignedUploadUrl/);
  assert.match(source, /signed_upload_token: signed\.token/);
  assert.match(source, /createSignedUrl\(String\(target\.object_path\), secondsRemaining/);
  assert.match(source, /Math\.min\(\s*300/);
  assert.match(source, /MAX_DOCUMENT_BYTES = 25 \* 1024 \* 1024/);
  assert.match(docs, /uploadToSignedUrl/);
  assert.match(docs, /re-resolve the actor-bound target/);
});
