import test from 'node:test';
import assert from 'node:assert/strict';
import { access, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import {
  normalizeOriginList,
  validBookingPayload,
  validJoinPayload,
  validManagePayload,
} from '../../supabase/functions/_shared/validation.ts';
import {
  authoritativeClientIp,
  bookingChangeFingerprint,
  bookingRequestFingerprint,
  deriveManagementToken,
  idempotencyDecision,
  sha256Hex,
  turnstileBindingValid,
} from '../../supabase/functions/_shared/security.ts';

const root = new URL('../..', import.meta.url).pathname;
const read = (path) => readFile(join(root, path), 'utf8');
const migrationPath = 'db/migrations/20260718180602_frenly_v19_public_gateway_security.sql';

test('v19 lives only in the canonical post-v18, pre-v20 migration sequence', async () => {
  const canonical = [
    'db/migrations/20260718135940_frenly_v18_scalable_reporting.sql',
    migrationPath,
    'db/migrations/20260719_frenly_v20_financial_engine.sql',
  ];
  await Promise.all(canonical.map((path) => access(join(root, path))));
  assert.ok(canonical[0] < canonical[1] && canonical[1] < canonical[2]);
  await assert.rejects(access(join(root, 'supabase/migrations/20260718180602_frenly_v19_public_gateway_security.sql')));
  const sql = await read(migrationPath);
  assert.match(sql, /source parity through v17, v18 reporting, v19 gateway, v20 financial/);
});

test('v19 preserves authenticated app schema usage required by v18 reporting helpers', async () => {
  const [v18, v19] = await Promise.all([
    read('db/migrations/20260718135940_frenly_v18_scalable_reporting.sql'),
    read(migrationPath),
  ]);
  assert.match(v18, /create or replace function public\.get_dashboard_summary/);
  for (const helper of ['has_perm', 'can_module', 'can_see_branch']) {
    assert.match(v18, new RegExp(`app\\.${helper}\\(`));
    assert.match(v18, new RegExp(`grant execute on function app\\.${helper}[^;]+to authenticated`, 's'));
  }
  assert.doesNotMatch(v19, /revoke all on schema app from[^;]*authenticated/i);
  assert.doesNotMatch(v19, /revoke usage on schema app from[^;]*authenticated/i);
  assert.match(v19, /revoke create on schema app from public, anon, authenticated/);
  assert.match(v19, /revoke usage on schema app from public, anon/);
  assert.match(v19, /grant usage on schema app to authenticated, service_role/);
});

test('validation rejects malformed, cross-shape and tokenless requests', () => {
  assert.deepEqual(normalizeOriginList('https://a.example, https://b.example,https://a.example'), [
    'https://a.example', 'https://b.example',
  ]);
  assert.equal(validJoinPayload({ slug: 'shop-one', name: 'Alex', phone: '91234567' }), true);
  assert.equal(validJoinPayload({ slug: '../shop', name: 'Alex', phone: '91234567' }), false);
  assert.equal(validBookingPayload({
    slug: 'shop-one', name: 'Alex', phone: '+6591234567', party: 2,
    preferred: '2026-12-01T04:00:00.000Z', notes: '', submission_id: '319df1fd-b9f6-4bd3-9a23-86a332026456',
  }), true);
  assert.equal(validBookingPayload({
    slug: 'shop-one', name: 'Alex', phone: '+6591234567', party: 51,
    preferred: '2026-12-01T04:00:00.000Z', notes: '', submission_id: '319df1fd-b9f6-4bd3-9a23-86a332026456',
  }), false);
  assert.equal(validBookingPayload({
    slug: 'shop-one', name: 'Alex', phone: '+6591234567', party: 2, service: 'not-a-uuid',
    preferred: '2026-12-01T04:00:00.000Z', submission_id: '319df1fd-b9f6-4bd3-9a23-86a332026456',
  }), false);
  assert.equal(validBookingPayload({
    slug: 'shop-one', name: 'Alex', phone: '+6591234567', party: 2, consent: 'true',
    preferred: '2026-12-01T04:00:00.000Z', submission_id: '319df1fd-b9f6-4bd3-9a23-86a332026456',
  }), false);
  const token = 'A'.repeat(43);
  assert.equal(validManagePayload({ action: 'lookup', token }), true);
  assert.equal(validManagePayload({ action: 'lookup', token: 'phone-number' }), false);
  const submission_id = '319df1fd-b9f6-4bd3-9a23-86a332026456';
  assert.equal(validManagePayload({ action: 'change', token, submission_id, kind: 'cancel', proposed: null }), true);
  assert.equal(validManagePayload({ action: 'change', token, kind: 'cancel', proposed: null }), false);
  assert.equal(validManagePayload({ action: 'change', token, submission_id, kind: 'reschedule', proposed: null }), false);
});

test('migration stores only SHA-256 token hashes and links conversion', async () => {
  const sql = await read(migrationPath);
  assert.match(sql, /token_hash bytea not null unique/);
  assert.match(sql, /booking_management_token_idempotency[\s\S]+\(business_id, idempotency_hash\)/);
  assert.match(sql, /octet_length\(token_hash\) = 32/);
  assert.match(sql, /decode\(p_token_hash, 'hex'\)/);
  assert.match(sql, /trg_link_booking_management_token/);
  assert.match(sql, /after insert or update of appointment_id on public\.booking_requests/);
  assert.doesNotMatch(sql, /token_plain|plaintext_token|manage_token\s+text/i);
  assert.match(sql, /return v_prior \|\| jsonb_build_object\('replayed', true\)/);
});

test('management capability is deterministic across lost-response retries and domain separated', async () => {
  const secret = 'test-only-management-secret-with-32-plus-characters';
  const submission = '319df1fd-b9f6-4bd3-9a23-86a332026456';
  const first = await deriveManagementToken(secret, 'shop-one', submission);
  const replay = await deriveManagementToken(secret, 'shop-one', submission);
  assert.equal(first, replay);
  assert.match(first, /^[A-Za-z0-9_-]{43}$/);
  assert.notEqual(first, await deriveManagementToken(secret, 'shop-two', submission));
  assert.notEqual(first, await deriveManagementToken(secret, 'shop-one', '10c22e1c-466f-427d-ad88-f5cebc15f997'));
  assert.notEqual(first, await deriveManagementToken(`${secret}-rotated`, 'shop-one', submission));
  assert.equal((await sha256Hex(first)).length, 64);
  await assert.rejects(deriveManagementToken('too-short', 'shop-one', submission), /gateway unavailable/);
});

test('booking replay returns the same derived raw capability while SQL stores only its hash', async () => {
  const [bookingFn, shared, sql] = await Promise.all([
    read('supabase/functions/public-booking/index.ts'),
    read('supabase/functions/_shared/gateway.ts'),
    read(migrationPath),
  ]);
  assert.match(shared, /PUBLIC_GATEWAY_TOKEN_SECRET/);
  assert.match(bookingFn, /deriveBookingManagementToken\(body\.slug, body\.submission_id\)/);
  assert.match(bookingFn, /json\(req, 200, \{ \.\.\.data, manage_token: manageToken \}\)/);
  assert.doesNotMatch(bookingFn, /data\.replayed\s*\?/);
  assert.match(sql, /decode\(p_token_hash, 'hex'\)/);
  assert.doesNotMatch(sql, /token_plain|plaintext_token|manage_token\s+text/i);
});

test('booking request fingerprints replay only an unchanged canonical request', async () => {
  const base = {
    slug: 'shop-one', name: ' Alex ', email: 'alex@example.com', phone: '+6591234567',
    service: '15bc01ec-2a8a-448f-8394-d3b72218f955', party: 2,
    preferred: '2026-12-01T04:00:00Z', notes: ' window ', table_type: null, consent: false,
  };
  const exact = await bookingRequestFingerprint({ ...base, preferred: '2026-12-01T12:00:00+08:00' });
  const stored = await bookingRequestFingerprint(base);
  assert.equal(idempotencyDecision(stored, exact), 'replay');
  for (const changed of [
    { name: 'Mallory' }, { phone: '+6581234567' }, { email: 'other@example.com' },
    { service: null }, { party: 3 }, { preferred: '2026-12-01T05:00:00Z' },
    { notes: 'aisle' }, { consent: true },
  ]) {
    assert.equal(idempotencyDecision(stored, await bookingRequestFingerprint({ ...base, ...changed })), 'conflict');
  }
  const sql = await read(migrationPath);
  assert.match(sql, /request_fingerprint bytea not null check \(octet_length\(request_fingerprint\) = 32\)/);
  assert.match(sql, /v_prior_fingerprint <> decode\(p_request_fingerprint, 'hex'\)[\s\S]+jsonb_build_object\('conflict', true\)/);
});

test('booking consent cannot take over an existing phone or record a false withdrawal', async () => {
  const sql = await read(migrationPath);
  assert.match(sql, /set_config\('app\.portal_client_created', '', true\)/);
  assert.match(sql, /set_config\('app\.portal_client_created', v_client::text, true\)/);
  assert.match(sql, /coalesce\(p_consent, false\) is false[\s\S]+return/);
  assert.match(sql, /current_setting\('app\.portal_client_created', true\) is distinct from p_client::text[\s\S]+return/);
  assert.match(sql, /marketing_consent = true/);
  assert.match(sql, /'granted', 'public_booking_v19_new_client', null/);
  assert.doesNotMatch(sql, /'withdrawn'[\s\S]{0,120}'public_booking_v19_new_client'/);
  assert.match(sql, /revoke all on function app\.upsert_portal_client\(uuid,text,text,text\) from public, anon, authenticated/);
  assert.match(sql, /revoke all on function app\.apply_booking_consent\(uuid,uuid,boolean\) from public, anon, authenticated/);
});

test('public consent event is compatible with nullable uuid actor column', async () => {
  const sql = await read(migrationPath);
  const consentInsert = sql.match(/insert into public\.consents \(business_id, client_id, channel, action, source, actor\)[\s\S]+?;/)?.[0] || '';
  assert.ok(consentInsert, 'v19 must insert the genuine new-client opt-in event');
  assert.match(consentInsert, /'public_booking_v19_new_client', null\)/);
  assert.doesNotMatch(consentInsert, /actor[\s\S]+?'customer'/i);
});

test('migration enforces tenant ownership, field bounds and future dates', async () => {
  const sql = await read(migrationPath);
  assert.match(sql, /s\.id = p_service and s\.business_id = v_business\.id/);
  assert.match(sql, /bt\.id = p_table_type and bt\.business_id = v_business\.id/);
  assert.match(sql, /p_party not between 1 and 50/);
  assert.match(sql, /p_preferred < clock_timestamp\(\) \+ interval '15 minutes'/);
  assert.match(sql, /a\.id = v_token\.appointment_id and a\.business_id = v_token\.business_id/);
  assert.match(sql, /for update of a/);
  assert.match(sql, /alter table public\.change_requests alter column phone drop not null/);
  assert.doesNotMatch(sql, /select public\.request_change\(/);
  assert.match(sql, /Repeated phone-only signup is deliberately opaque and never mutates PII or consent/);
  assert.match(sql, /booking_requests_id_business_unique unique \(id, business_id\)/);
  assert.match(sql, /foreign key \(booking_request_id, business_id\)[\s\S]+references public\.booking_requests\(id, business_id\)/);
  assert.match(sql, /foreign key \(appointment_id, business_id\)[\s\S]+references public\.appointments\(id, business_id\)/);
  assert.match(sql, /where booking_request_id = new\.id and business_id = new\.business_id/);
});

test('all private gateway tables enable RLS with no end-user table grants', async () => {
  const sql = await read(migrationPath);
  for (const table of [
    'public_gateway_rate_limits', 'booking_management_tokens', 'booking_management_change_submissions',
  ]) {
    assert.match(sql, new RegExp(`alter table app\\.${table} enable row level security`));
    assert.match(sql, new RegExp(`revoke all on app\\.${table} from public, anon, authenticated`));
  }
  assert.doesNotMatch(sql, /create policy[\s\S]+on app\./i);
});

test('booking changes are idempotent, conflict truthful and never auto-reschedule timestamps', async () => {
  const base = { kind: 'reschedule', proposed: '2026-12-01T04:00:00Z', note: null };
  const stored = await bookingChangeFingerprint(base);
  assert.equal(idempotencyDecision(stored, await bookingChangeFingerprint({ ...base })), 'replay');
  assert.equal(idempotencyDecision(stored, await bookingChangeFingerprint({ ...base, proposed: '2026-12-01T05:00:00Z' })), 'conflict');
  assert.equal(idempotencyDecision(stored, await bookingChangeFingerprint({ kind: 'cancel', proposed: null, note: null })), 'conflict');

  const sql = await read(migrationPath);
  assert.match(sql, /booking_management_change_submissions/);
  assert.match(sql, /primary key \(management_token_id, submission_id\)/);
  assert.match(sql, /v_prior\.request_fingerprint <> decode\(p_request_fingerprint, 'hex'\)/);
  assert.match(sql, /if found then\s+return jsonb_build_object\('conflict', true\);\s+end if;[\s\S]+insert into public\.change_requests/);
  assert.match(sql, /if v_auto and p_kind = 'cancel' then/);
  assert.doesNotMatch(sql, /set starts_at = p_proposed/);
  assert.doesNotMatch(sql, /ends_at = p_proposed/);
});

test('internal RPCs are service-role-only and legacy public gateways are revoked', async () => {
  const sql = await read(migrationPath);
  for (const name of [
    'internal_gateway_rate_limit', 'internal_public_join', 'internal_public_booking_submit',
    'internal_public_booking_lookup', 'internal_public_booking_change',
  ]) {
    assert.match(sql, new RegExp(`grant execute on function public\\.${name}[^;]+ to service_role`, 's'));
    assert.match(sql, new RegExp(`revoke all on function public\\.${name}[^;]+ from public, anon, authenticated`, 's'));
  }
  for (const name of ['join_program', 'request_booking', 'get_business_public', 'list_my_appointments', 'request_change']) {
    assert.match(sql, new RegExp(`'${name}'`));
  }
  assert.match(sql, /revoke all on function %s from public, anon, authenticated/);
});

test('rate limits use peppered hashes, bounded TTL and no raw IP column', async () => {
  const [sql, shared, security] = await Promise.all([
    read(migrationPath), read('supabase/functions/_shared/gateway.ts'),
    read('supabase/functions/_shared/security.ts'),
  ]);
  assert.match(sql, /key_hash text not null check \(key_hash ~ '\^\[0-9a-f\]\{64\}\$'\)/);
  assert.match(sql, /expires_at < v_now - interval '1 day'/);
  assert.doesNotMatch(sql, /\bip_address\b|\bclient_ip\b/i);
  assert.match(shared, /PUBLIC_GATEWAY_IP_PEPPER/);
  assert.match(shared, /sha256Hex\(`\$\{pepper\}\\0\$\{authoritativeClientIp\(req\.headers\)\}`\)/);
  assert.match(security, /headers\.get\('cf-connecting-ip'\)/);
  assert.doesNotMatch(shared, /console\.(log|error|warn)/);
});

test('client IP keys on the trusted Cloudflare header and ignores spoofable X-Forwarded-For', () => {
  // Supabase Edge sits behind Cloudflare, which sets cf-connecting-ip to the true peer and
  // overwrites client-supplied values. The rightmost X-Forwarded-For entry is an internal
  // edge node that rotates per request (observed: many AWS IPs for one client), so it must
  // not key the limiter; without the trusted header we use one shared 'unknown' bucket.
  const trusted = new Headers({ 'cf-connecting-ip': '203.0.113.7', 'x-forwarded-for': '198.51.100.9, 99.82.173.48' });
  const rotatedNode = new Headers({ 'cf-connecting-ip': '203.0.113.7', 'x-forwarded-for': '192.0.2.45, 99.83.104.110' });
  assert.equal(authoritativeClientIp(trusted), '203.0.113.7');
  assert.equal(authoritativeClientIp(rotatedNode), '203.0.113.7');
  assert.equal(authoritativeClientIp(new Headers({ 'cf-connecting-ip': 'spoofed' })), 'unknown');
  assert.equal(authoritativeClientIp(new Headers({ 'x-forwarded-for': '198.51.100.9, 203.0.113.7' })), 'unknown');
  assert.equal(authoritativeClientIp(new Headers()), 'unknown');
});

test('manage booking applies an IP-only bucket before any attacker-selected token bucket', async () => {
  const manageFn = await read('supabase/functions/manage-booking/index.ts');
  const ipLimit = manageFn.indexOf("enforceRateLimit(req, 'manage-booking-ip'");
  const tokenHash = manageFn.indexOf('sha256Hex(String(body.token))');
  const tokenLimit = manageFn.indexOf("enforceRateLimit(req, 'manage-booking-token'");
  assert.ok(ipLimit >= 0 && tokenHash > ipLimit && tokenLimit > tokenHash);
  assert.match(manageFn, /'manage-booking-ip', 20, 600\)/);
  assert.match(manageFn, /'manage-booking-token', 10, 600, tokenHash\)/);
});

test('malformed public writes consume only broad abuse limits, not narrow shared-NAT quotas', async () => {
  const [joinFn, bookingFn] = await Promise.all([
    read('supabase/functions/public-join/index.ts'), read('supabase/functions/public-booking/index.ts'),
  ]);
  for (const [source, prefix, validator, action, rpcName] of [
    [joinFn, 'join', 'validJoinPayload', 'public_join', 'internal_public_join'],
    [bookingFn, 'booking', 'validBookingPayload', 'public_booking', 'internal_public_booking_submit'],
  ]) {
    const abuse = source.indexOf(`enforceRateLimit(req, '${prefix}-submit-abuse'`);
    const syntax = source.indexOf(`${validator}(body)`);
    const verify = source.indexOf(`verifyTurnstile(req, body.turnstile_token, '${action}')`);
    const narrow = source.indexOf(`enforceRateLimit(req, '${prefix}-submit'`);
    const rpc = source.indexOf(`adminClient().rpc('${rpcName}'`);
    assert.ok(abuse >= 0 && syntax > abuse && verify > syntax && narrow > verify && rpc > narrow);
  }
});

test('Turnstile validation binds production tokens to action and Origin hostname', () => {
  assert.equal(turnstileBindingValid({
    success: true, action: 'public_join', hostname: 'staging.example.com',
  }, 'public_join', 'staging.example.com'), true);
  assert.equal(turnstileBindingValid({
    success: true, action: 'public_booking', hostname: 'staging.example.com',
  }, 'public_join', 'staging.example.com'), false);
  assert.equal(turnstileBindingValid({
    success: true, action: 'public_join', hostname: 'attacker.example',
  }, 'public_join', 'staging.example.com'), false);
  assert.equal(turnstileBindingValid({
    success: false, action: 'public_join', hostname: 'staging.example.com',
  }, 'public_join', 'staging.example.com'), false);
  assert.equal(turnstileBindingValid({
    success: true, action: 'test', hostname: 'localhost',
  }, 'public_join', 'staging.example.com', true), true);
  assert.equal(turnstileBindingValid({
    success: true, action: 'public_join', hostname: 'staging.example.com',
  }, 'public_join', 'staging.example.com', true), false);
});

test('edge functions use exact-origin CORS, generic errors and mandatory Turnstile', async () => {
  const [shared, config, joinFn, bookingFn, manageFn] = await Promise.all([
    read('supabase/functions/_shared/gateway.ts'), read('supabase/config.toml'),
    read('supabase/functions/public-join/index.ts'), read('supabase/functions/public-booking/index.ts'),
    read('supabase/functions/manage-booking/index.ts'),
  ]);
  assert.match(shared, /PUBLIC_GATEWAY_ALLOWED_ORIGINS/);
  assert.match(shared, /allowedOrigins\(\)\.includes\(origin\)/);
  assert.doesNotMatch(shared, /access-control-allow-origin['"]?\s*:\s*['"]\*/i);
  assert.match(shared, /We could not process that request\./);
  assert.match(shared, /This request conflicts with an earlier submission\./);
  assert.match(shared, /TURNSTILE_SECRET_KEY/);
  assert.match(shared, /TURNSTILE_SITE_KEY/);
  assert.match(shared, /if \(!siteKey \|\| !secretKey\) throw new Error\('gateway unavailable'\)/);
  assert.doesNotMatch(shared, /if \(!secret\) return true/);
  assert.match(shared, /TURNSTILE_TEST_ALLOWED_ORIGINS/);
  assert.match(shared, /turnstileBindingValid\(result, expectedAction, expectedHostname, testMode\)/);
  assert.match(joinFn, /verifyTurnstile\(req, body\.turnstile_token, 'public_join'\)/);
  assert.match(joinFn, /turnstile_site_key: turnstileSiteKey\(\)/);
  assert.match(bookingFn, /verifyTurnstile\(req, body\.turnstile_token, 'public_booking'\)/);
  assert.match(bookingFn, /turnstile_site_key: turnstileSiteKey\(\)/);
  assert.match(bookingFn, /if \(data\.conflict\) return conflictError\(req\)/);
  assert.match(manageFn, /sha256Hex\(String\(body\.token\)\)/);
  assert.match(manageFn, /if \(data\.conflict\) return conflictError\(req\)/);
  for (const name of ['public-join', 'public-booking', 'manage-booking']) {
    assert.match(config, new RegExp(`\\[functions\\.${name}\\]\\nverify_jwt = false`));
  }
});

test('Origin is browser isolation rather than authentication', async () => {
  const [shared, docs] = await Promise.all([
    read('supabase/functions/_shared/gateway.ts'), read('supabase/functions/README.md'),
  ]);
  assert.match(shared, /allowedOrigins\(\)\.includes\(origin\)/);
  assert.match(docs, /Exact-origin CORS is browser isolation, not authentication/);
  assert.match(docs, /non-browser client can spoof an[\s\S]+`Origin`/);
  assert.match(docs, /Turnstile and IP limits/);
  assert.match(docs, /possession of the capability token/);
});

test('public frontends contain no insecure gateway RPC calls', async () => {
  const [app, joinPage] = await Promise.all([read('app/index.html'), read('app/join.html')]);
  const insecure = /\.rpc\(['"](?:join_program|get_join_page|get_business_public|request_booking|list_my_appointments|request_change)['"]/;
  assert.doesNotMatch(app, insecure);
  assert.doesNotMatch(joinPage, insecure);
  assert.match(app, /functions\/v1\/\$\{name\}/);
  assert.match(joinPage, /functions\/v1\/public-join/);
  assert.doesNotMatch(app, /Pick your country code and enter your number/);
});

test('public write forms render and reset explicit Turnstile widgets under exact CSP origins', async () => {
  const [app, joinPage, vercel, docs] = await Promise.all([
    read('app/index.html'), read('app/join.html'), read('app/vercel.json'), read('supabase/functions/README.md'),
  ]);
  for (const page of [app, joinPage]) {
    assert.match(page, /https:\/\/challenges\.cloudflare\.com\/turnstile\/v0\/api\.js\?render=explicit/);
    assert.match(page, /aria-live="polite"/);
    assert.match(page, /Retry security check/);
    assert.match(page, /'expired-callback'/);
    assert.match(page, /'error-callback':\(errorCode\)=>/);
    assert.match(page, /logTurnstileError\(errorCode\)/);
    assert.match(page, /console\.warn\('Turnstile error code:',code\)/);
    assert.match(page, /\.reset\(widgetId\)/);
    assert.match(page, /function'\)api\.remove\(widgetId\);else api\.reset\(widgetId\)/);
    assert.match(page, /document\.getElementById\(container\)\?\.replaceChildren\(\)/);
    assert.match(page, /retryEl\.onclick=retryRender/);
    assert.doesNotMatch(page, /FRENLY_TURNSTILE_TOKEN/);
    assert.doesNotMatch(page, /TURNSTILE_SECRET_KEY|CLOUDFLARE_SECRET_KEY|secretKey\s*=/);
  }
  assert.match(app, /action:'public_booking'/);
  assert.match(joinPage, /action:'public_join'/);
  assert.match(app, /turnstile_token:bookingTurnstileToken/);
  assert.match(joinPage, /turnstile_token:turnstileToken/);
  assert.match(vercel, /script-src[^;]+https:\/\/challenges\.cloudflare\.com/);
  assert.match(vercel, /frame-src https:\/\/challenges\.cloudflare\.com/);
  assert.match(vercel, /connect-src[^;]+https:\/\/gadpooereceldfpfxsod\.supabase\.co[^;]+wss:\/\/gadpooereceldfpfxsod\.supabase\.co[^;]+https:\/\/challenges\.cloudflare\.com/);
  assert.match(docs, /both are required before exposing public join[\s\S]+booking writes/);
});

test('staff auth submit stays disabled until Turnstile returns a token', async () => {
  const app = await read('app/index.html');
  const authStart = app.indexOf("function renderAuth(mode='in')");
  const authEnd = app.indexOf('function validNewPassword', authStart);
  const auth = app.slice(authStart, authEnd);
  assert.match(auth, /<button class="btn" id="go" disabled>/);
  assert.match(auth, /let authToken='',authControl=null/);
  assert.match(auth, /onToken:\(token\)=>\{authToken=token;\$\(\'go\'\)\.disabled=!token\}/);
  assert.match(auth, /if\(!authToken\) return/);
});

test('booking capabilities are scrubbed from current history and change retries retain an intent ID', async () => {
  const app = await read('app/index.html');
  const portalStart = app.indexOf('async function renderPortal(slug)');
  const firstAwait = app.indexOf("await publicGateway('public-booking'", portalStart);
  const scrub = app.indexOf("history.replaceState(null,'',`${location.pathname}${location.search}#/b/", portalStart);
  assert.ok(portalStart >= 0 && scrub > portalStart && scrub < firstAwait);
  assert.doesNotMatch(app, /history\.replaceState\(null,'',manageUrl\)/);
  assert.match(app, /const manageUrl=`\$\{location\.origin\}/);
  assert.match(app, /if\(!changeAttempt\|\|changeAttempt\.key!==key\)changeAttempt=\{key,id:crypto\.randomUUID\(\)\}/);
  assert.match(app, /submission_id:changeAttempt\.id/);
  assert.match(app, /changeAttempt=null/);
  assert.match(app, /bookingSubmissionKey!==nextBookingKey/);
});

test('password recovery is complete and non-enumerating', async () => {
  const app = await read('app/index.html');
  // Supabase Auth CAPTCHA is enabled in production: every recovery request must carry a
  // single-use Turnstile captchaToken alongside the redirect (and reset the widget after use).
  assert.match(app, /resetPasswordForEmail\(email,\{redirectTo:redirect\.toString\(\),captchaToken:authToken\}\)/);
  assert.match(app, /signUp\(\{email,password,options:\{captchaToken\}\}\)/);
  assert.match(app, /signInWithPassword\(\{email,password,options:\{captchaToken\}\}\)/);
  assert.match(app, /event==='PASSWORD_RECOVERY'/);
  assert.match(app, /hash\.get\('type'\)==='recovery'/);
  assert.match(app, /flowType:'implicit'/);
  assert.doesNotMatch(app, /exchangeCodeForSession/);
  const accessRead = app.indexOf("const accessToken=hash.get('access_token')");
  const recoveryScrub = app.indexOf("history.replaceState(null,'',location.pathname+'?recovery=1#/recover')", accessRead);
  const setSession = app.indexOf('await sb.auth.setSession({access_token:accessToken,refresh_token:refreshToken})', accessRead);
  assert.ok(accessRead >= 0 && recoveryScrub > accessRead && recoveryScrub < setSession);
  assert.match(app, /function renderRecoveryInvalid\(\)/);
  assert.match(app, /This password reset link is invalid or expired/);
  assert.match(app, /updateUser\(\{password\}\)/);
  assert.match(app, /If an account exists for that email, a reset link is on its way\./);
  assert.match(app, /password\.length>=12/);
});

test('auth and public surfaces link to all policy pages', async () => {
  const [app, joinPage] = await Promise.all([read('app/index.html'), read('app/join.html')]);
  for (const page of ['/privacy.html', '/terms.html', '/data-request.html']) {
    assert.ok(app.includes(`href="${page}"`));
    assert.ok(joinPage.includes(`href="${page}"`));
  }
});
