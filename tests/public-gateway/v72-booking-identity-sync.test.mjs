import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import {
  bookingRequestFingerprint,
  gatewayAuthorization,
  idempotencyDecision,
} from '../../supabase/functions/_shared/security.ts';

const root = new URL('../..', import.meta.url).pathname;
const read = (path) => readFile(join(root, path), 'utf8');
const sourcePath = 'db/migrations/20260726_frenly_v72_booking_identity_sync.sql';
const canonicalPath = 'supabase/migrations/20260725130000_frenly_v72_booking_identity_sync.sql';

test('authenticated booking fingerprint is identity-bound while guest v1 remains compatible', async () => {
  const request = {
    slug: 'shop-one',
    name: 'Alex',
    email: 'alex@example.test',
    phone: '+6581234567',
    service: null,
    party: 2,
    preferred: '2026-12-01T04:00:00Z',
    notes: null,
    table_type: null,
    consent: false,
  };
  const userA = '123e4567-e89b-42d3-a456-426614174000';
  const userB = '123e4567-e89b-42d3-a456-426614174001';
  const legacyGuest = await bookingRequestFingerprint(request);
  assert.equal(legacyGuest, await bookingRequestFingerprint(request, null));
  assert.equal(idempotencyDecision(
    await bookingRequestFingerprint(request, userA),
    await bookingRequestFingerprint(request, userA),
  ), 'replay');
  assert.equal(idempotencyDecision(
    await bookingRequestFingerprint(request, userA),
    await bookingRequestFingerprint(request, userB),
  ), 'conflict');
  assert.equal(idempotencyDecision(
    legacyGuest,
    await bookingRequestFingerprint(request, userA),
  ), 'conflict');
  assert.equal(
    await bookingRequestFingerprint(request, userA),
    await bookingRequestFingerprint({
      ...request,
      preferred: '2026-12-01T04:00:00.000Z',
    }, userA),
    'the same authenticated request and exact instant must replay deterministically',
  );
});

test('gateway authorization distinguishes exact configured guest keys from user bearer tokens', () => {
  const publishable = 'sb_publishable_demo_key';
  const legacyAnon = 'eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoiYW5vbiJ9.signature';
  const userJwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyIn0.signature';
  assert.deepEqual(gatewayAuthorization(null, [publishable, legacyAnon]), {
    kind: 'guest', token: null,
  });
  assert.deepEqual(gatewayAuthorization(`Bearer ${publishable}`, [publishable, legacyAnon]), {
    kind: 'guest', token: null,
  });
  assert.deepEqual(gatewayAuthorization(`Bearer ${legacyAnon}`, [publishable, legacyAnon]), {
    kind: 'guest', token: null,
  });
  assert.deepEqual(gatewayAuthorization(`Bearer ${userJwt}`, [publishable, legacyAnon]), {
    kind: 'user', token: userJwt,
  });
  assert.equal(gatewayAuthorization('Basic abc', [publishable]).kind, 'invalid');
  assert.equal(gatewayAuthorization('Bearer not-configured-publishable', [publishable]).kind, 'invalid');
  assert.equal(gatewayAuthorization('Bearer a.b', [publishable]).kind, 'invalid');
  assert.equal(gatewayAuthorization(`Bearer ${'a'.repeat(4097)}`, [publishable]).kind, 'invalid');
});

test('edge validates optional user bearer server-side and never accepts browser client identity', async () => {
  const [edge, gateway, security] = await Promise.all([
    read('supabase/functions/public-booking/index.ts'),
    read('supabase/functions/_shared/gateway.ts'),
    read('supabase/functions/_shared/security.ts'),
  ]);
  assert.match(gateway, /optionalAuthenticatedUserId\(req\)/);
  assert.match(gateway, /SUPABASE_ANON_KEY/);
  assert.match(gateway, /SUPABASE_PUBLISHABLE_KEY/);
  assert.match(gateway, /PUBLIC_GATEWAY_PUBLISHABLE_KEY/);
  assert.match(gateway, /adminClient\(\)\.auth\.getUser\(authorization\.token\)/);
  assert.match(gateway, /if \(error \|\| !\/\^\[0-9a-f\]/);
  assert.match(security, /header\.length > 4096/);
  assert.match(gateway, /access-control-allow-headers': 'content-type, x-client-info, authorization, apikey'/);
  assert.match(gateway, /if \(!origin \|\| !allowedOrigins\(\)\.includes\(origin\)\) return null/);

  /* nestly_v747: the Turnstile step is gone from this endpoint (owner directive 2026-09-03).
     The identity ordering this test exists to protect is unchanged: payload shape is validated
     BEFORE the bearer is resolved, and the fingerprint is computed from the SERVER-resolved user
     id, never a client-supplied one. */
  assert.doesNotMatch(edge, /verifyTurnstile\(/);
  const validate = edge.indexOf('validBookingPayload(body)');
  const authenticate = edge.indexOf('optionalAuthenticatedUserId(req)');
  const fingerprint = edge.indexOf('bookingRequestFingerprint(body, authenticatedUserId)');
  const rpc = edge.indexOf("adminClient().rpc('internal_public_booking_submit'");
  assert.ok(validate >= 0 && authenticate > validate && fingerprint > authenticate && rpc > fingerprint);
  assert.match(edge, /p_authenticated_user: authenticatedUserId/);
  assert.doesNotMatch(edge, /p_(?:customer_)?client_id|body\.(?:customer_)?client_id/);
  assert.match(edge, /catch \{\s+return publicError\(req, 401\)/);
  assert.match(gateway, /authorization\.kind !== 'user'[\s\S]+invalid authorization/);
  assert.match(gateway, /if \(error[\s\S]+throw new Error\('invalid authorization'\)/);
});

test('v72 stores an immutable tenant-safe link and SQL alone resolves verified relationships', async () => {
  const sql = await read(sourcePath);
  assert.match(sql, /add column customer_client_id uuid/);
  assert.match(sql, /foreign key \(business_id, customer_client_id\)[\s\S]+references public\.clients\(business_id, id\) on delete restrict/);
  assert.match(sql, /before update of customer_client_id on public\.booking_requests/);
  assert.match(sql, /booking customer binding is immutable/);

  const resolver = sql.match(/create or replace function app\.resolve_verified_booking_client_v72[\s\S]+?\n\$\$;/)?.[0] || '';
  assert.match(resolver, /link\.business_id = p_business/);
  assert.match(resolver, /link\.auth_user_id = p_authenticated_user/);
  assert.match(resolver, /link\.state = 'verified'/);
  assert.match(resolver, /identity\.status = 'active'/);
  assert.doesNotMatch(resolver, /\.name|\.email|\.phone|phone_norm|email_norm/i);
});

test('bound submission uses the exact client in requests, appointments and waitlist without profile writes', async () => {
  const sql = await read(sourcePath);
  const bound = sql.match(/create or replace function app\.request_bound_booking_v72[\s\S]+?\n\$\$;/)?.[0] || '';
  assert.match(bound, /customer_client_id[\s\S]+p_client/);
  assert.match(bound, /insert into public\.appointments[\s\S]+p_business, p_client, p_service/);
  assert.match(bound, /insert into public\.waitlist[\s\S]+p_business, p_client/);
  assert.match(bound, /app\.apply_bound_booking_consent_v72\([\s\S]+p_authenticated_user, p_consent/);
  assert.doesNotMatch(bound, /insert into public\.clients|upsert_portal_client/);

  const submit = sql.match(/create function public\.internal_public_booking_submit\([\s\S]+?p_authenticated_user uuid[\s\S]+?\n\$\$;/)?.[0] || '';
  assert.match(submit, /if v_bound_client is null then[\s\S]+public\.request_booking/);
  assert.match(submit, /else[\s\S]+app\.request_bound_booking_v72/);
  assert.match(submit, /authenticated_user_id, customer_client_id/);
});

test('checked consent is a tenant-bound audited grant and unchecked consent is not withdrawal', async () => {
  const sql = await read(sourcePath);
  const consent = sql.match(/create or replace function app\.apply_bound_booking_consent_v72[\s\S]+?\n\$\$;/)?.[0] || '';
  assert.match(consent, /if coalesce\(p_consent, false\) is false then\s+return/);
  assert.match(consent, /link\.business_id = p_business/);
  assert.match(consent, /link\.client_id = p_client/);
  assert.match(consent, /link\.auth_user_id = p_authenticated_user/);
  assert.match(consent, /link\.state = 'verified'/);
  assert.match(consent, /identity\.status = 'active'/);
  assert.match(consent, /update public\.clients\s+set marketing_consent = true\s+where business_id = p_business\s+and id = p_client/);
  assert.match(consent, /insert into public\.consents\([\s\S]+p_business, p_client, 'marketing', 'granted',[\s\S]+'authenticated_public_booking_v72', p_authenticated_user/);
  assert.doesNotMatch(consent, /withdrawn|full_name|email|phone|contact/i);
});

test('replay conflict includes validated auth identity and the current resolved link', async () => {
  const sql = await read(sourcePath);
  assert.match(sql, /v_prior_authenticated_user is distinct from p_authenticated_user/);
  assert.match(sql, /v_prior_client is distinct from v_bound_client/);
  assert.match(sql, /v_prior_fingerprint <> decode\(p_request_fingerprint, 'hex'\)/);
  assert.match(sql, /return jsonb_build_object\('conflict', true\)/);
  assert.match(sql, /return v_prior \|\| jsonb_build_object\('replayed', true\)/);
});

test('staff conversion preserves a bound client and guest conversion retains v47 matching', async () => {
  const sql = await read(sourcePath);
  const conversion = sql.match(/create or replace function public\.convert_booking_request[\s\S]+?\n\$\$;/)?.[0] || '';
  assert.match(conversion, /if v_request\.customer_client_id is not null then/);
  assert.match(conversion, /client\.id = v_request\.customer_client_id/);
  assert.match(conversion, /client\.business_id = v_request\.business_id/);
  assert.match(conversion, /else[\s\S]+app\.upsert_portal_client/);
  assert.match(conversion, /public\.book_appointment_smart_v47/);
  assert.ok(
    conversion.indexOf('app.upsert_portal_client') > conversion.indexOf('else'),
    'bound branch must not pass through the contact-matching client upsert',
  );
});

test('customer reader is self-scoped and returns only the safe booking projection', async () => {
  const sql = await read(sourcePath);
  const reader = sql.match(/create or replace function public\.customer_get_booking_requests[\s\S]+?\n\$\$;/)?.[0] || '';
  assert.match(reader, /v_actor uuid := auth\.uid\(\)/);
  assert.match(reader, /identity\.auth_user_id = v_actor/);
  assert.match(reader, /link\.state = 'verified'/);
  assert.match(reader, /request\.customer_client_id = link\.client_id/);
  assert.match(reader, /join app\.booking_management_tokens token/);
  assert.match(reader, /token\.booking_request_id = request\.id/);
  assert.match(reader, /token\.customer_client_id = request\.customer_client_id/);
  assert.match(reader, /token\.authenticated_user_id = v_actor/);
  assert.match(reader, /request\.status in \('new', 'pending', 'waitlisted'\)/);
  assert.match(reader, /request\.status in \('declined', 'expired', 'cancelled'\)/);
  assert.match(reader, /request\.created_at >= current_timestamp - interval '90 days'/);
  assert.match(reader, /request\.appointment_id is null/);
  assert.doesNotMatch(reader, /request\.status in \([^)]*confirmed/);
  assert.match(reader, /p_cursor jsonb default null/);
  assert.match(reader, /jsonb_object_keys\(p_cursor\)/);
  assert.match(reader, /\(request\.created_at, request\.id\) < \(v_cursor_created, v_cursor_id\)/);
  assert.match(reader, /order by request\.created_at desc, request\.id desc/);
  assert.match(reader, /limit v_limit \+ 1/);
  assert.match(reader, /'truncated', \(select count\(\*\) from visible\) > v_limit/);
  assert.match(reader, /'next_cursor'[\s\S]+'created_at', listed\.created_at[\s\S]+'request_id', listed\.id/);
  for (const safeField of [
    'request_id', 'business_slug', 'business_name', 'status',
    'preferred_at', 'party_size', 'service_name', 'created_at',
  ]) {
    assert.match(reader, new RegExp(`'${safeField}'`));
  }
  for (const unsafeField of [
    "'email'", "'phone'", "'name'", "'notes'", "'customer_client_id'",
    "'authenticated_user_id'", "'manage_token'",
  ]) {
    assert.doesNotMatch(reader, new RegExp(unsafeField));
  }
  assert.match(sql, /grant execute on function public\.customer_get_booking_requests\(integer,jsonb\)\s+to authenticated/);
  assert.match(sql, /revoke all on function public\.customer_get_booking_requests\(integer,jsonb\)\s+from public, anon, authenticated/);
});

test('v72 supports DB-first rollout with both service-only submit overloads', async () => {
  const sql = await read(sourcePath);
  const oldSignature = 'text,text,text,text,uuid,integer,timestamptz,text,uuid,boolean,text,text,text';
  const newSignature = `${oldSignature},uuid`;
  const compact = sql.replaceAll(/\s+/g, '');
  assert.match(sql, /OUTAGE-FREE ROLLOUT ORDER \(DB FIRST\)/);
  assert.match(sql, /Apply this migration[\s\S]+Deploy public-booking/);
  assert.doesNotMatch(sql, /drop function(?: if exists)? public\.internal_public_booking_submit/i);
  assert.ok(compact.includes(`revokeallonfunctionpublic.internal_public_booking_submit(${oldSignature})frompublic,anon,authenticated;`));
  assert.ok(compact.includes(`revokeallonfunctionpublic.internal_public_booking_submit(${newSignature})frompublic,anon,authenticated;`));
  assert.ok(compact.includes(`grantexecuteonfunctionpublic.internal_public_booking_submit(${oldSignature})toservice_role;`));
  assert.ok(compact.includes(`grantexecuteonfunctionpublic.internal_public_booking_submit(${newSignature})toservice_role;`));
  const wrapper = sql.match(/create or replace function public\.internal_public_booking_submit\([\s\S]+?p_request_fingerprint text\s*\)[\s\S]+?\n\$\$;/)?.[0] || '';
  assert.match(wrapper, /select public\.internal_public_booking_submit\([\s\S]+p_request_fingerprint, null::uuid/);
});

test('v72 source, canonical materialization and rollback suite are tracked after v71', async () => {
  const [source, canonical, sourcePlan, canonicalPlan, rollback] = await Promise.all([
    read(sourcePath),
    read(canonicalPath),
    read('db/migrations/migration-order.plan.json'),
    read('supabase/canonical-migration-order.plan.json'),
    read('db/tests/v72_booking_identity_sync.sql'),
  ]);
  assert.equal(canonical, source);
  assert.match(sourcePlan, /20260726_frenly_v71_customer_legal_manifest[\s\S]+20260726_frenly_v72_booking_identity_sync/);
  assert.match(canonicalPlan, /20260725120000[\s\S]+20260725130000/);
  assert.match(rollback, /^begin;/m);
  assert.match(rollback, /^rollback;/m);
  assert.match(rollback, /cross-tenant customer binding/);
  assert.match(rollback, /reader leaked a submitted contact or bound client id/);
  assert.match(rollback, /successor identity inherited predecessor booking evidence/);
  assert.match(rollback, /confirmed saturation starved active booking requests/);
  assert.match(rollback, /explicit consent was not attributed to the authenticated customer/);
  assert.match(rollback, /keyset booking pagination returned a duplicate request/);
  assert.match(rollback, /older unresolved requests starved the newest active request/);
  assert.match(rollback, /malformed booking cursor was accepted/);
  assert.match(rollback, /recent terminal booking request disappeared from My Frenly/);
  assert.match(rollback, /terminal booking older than 90 days remained visible/);
  assert.match(rollback, /confirmed booking duplicated the appointments feed/);
});
