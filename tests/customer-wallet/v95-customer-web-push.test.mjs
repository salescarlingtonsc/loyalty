import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  customerPushDeadlineElapsed,
  customerPushTtlSeconds,
  supportedCustomerPushEndpoint,
} from '../../supabase/functions/_shared/customer-push-boundaries.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const read = (relative) => readFile(path.join(root, relative), 'utf8');
const migrationPath = 'db/migrations/20260728_nestly_v95_customer_web_push.sql';
const mirrorPath = 'supabase/migrations/20260728140000_nestly_v95_customer_web_push.sql';
const fixturePath = 'db/tests/v95_customer_web_push.sql';
const concurrencyPath = 'db/tests/v95_customer_web_push_concurrency.sh';
const dispatcherPath = 'supabase/functions/customer-push-dispatch/index.ts';
const sharedPath = 'supabase/functions/_shared/customer-push.ts';
const configPath = 'supabase/config.toml';

test('v95 canonical migration mirror is byte-identical and forward-only', async () => {
  const [migration, mirror] = await Promise.all([read(migrationPath), read(mirrorPath)]);
  assert.equal(mirror, migration);
  assert.match(migration, /^-- NESTLY v95/m);
  assert.doesNotMatch(migration, /drop\s+(?:table|function|schema)|alter\s+table[\s\S]*disable\s+row\s+level\s+security/i);
});

test('browser subscription RPCs derive auth.uid and never return raw key material', async () => {
  const migration = await read(migrationPath);
  assert.match(migration, /customer_register_push_subscription_v95[\s\S]*v_actor uuid:=auth\.uid\(\)/i);
  assert.match(migration, /customer_unregister_push_subscription_v95[\s\S]*v_actor uuid:=auth\.uid\(\)/i);
  assert.match(migration, /active customer identity required/i);
  assert.match(migration, /on conflict\(endpoint_hash\)[\s\S]*where customer_push_subscriptions_v95\.auth_user_id=v_actor/i);
  assert.match(migration, /'subscription_id',v_subscription,'status','active'[\s\S]*'evicted_subscription_id',v_evicted/i);
  assert.doesNotMatch(
    migration.match(/create or replace function public\.customer_register_push_subscription_v95[\s\S]+?\n\\$\\$;/i)?.[0] || '',
    /jsonb_build_object\([^)]*endpoint|jsonb_build_object\([^)]*p256dh|jsonb_build_object\([^)]*auth_secret/i,
  );
  assert.match(migration, /unique\(auth_user_id,idempotency_key\)/i);
  assert.match(migration, /idempotency key conflict/i);
  assert.match(migration, /v_active_count>=5/i);
  assert.match(migration, /order by updated_at,created_at,id[\s\S]*for update limit 1/i);
  assert.match(migration, /count\(\*\)>=20[\s\S]*created_at>now\(\)-interval '10 minutes'/i);
  assert.match(migration, /v95-push-identity:/i);
  assert.match(migration, /length\(coalesce\(p_p256dh,''\)\)<>87/i);
  assert.match(migration, /length\(coalesce\(p_auth_secret,''\)\)<>22/i);
});

test('supported push endpoint boundary covers production Chrome, Firefox and Safari without SSRF seams', () => {
  for (const endpoint of [
    'https://fcm.googleapis.com/wp/chrome_token-123:ABC',
    'https://fcm.googleapis.com/fcm/send/legacy_chrome_token',
    'https://updates.push.services.mozilla.com/wpush/v2/firefox_token',
    'https://updates.push.services.mozilla.com/push/legacy_firefox_token',
    'https://web.push.apple.com/QH_safari_token',
    'https://regional.web.push.apple.com/opaque/token',
  ]) {
    assert.equal(supportedCustomerPushEndpoint(endpoint), true, endpoint);
  }
  for (const endpoint of [
    'https://attacker.example.test/collect',
    'https://fcm.googleapis.com.attacker.test/wp/token',
    'https://attacker@fcm.googleapis.com/wp/token',
    'https://fcm.googleapis.com:443/wp/token',
    'http://fcm.googleapis.com/wp/token',
    'https://fcm.googleapis.com/v1/projects/demo/messages:send',
    'https://push.apple.com/token',
    'https://web.push.apple.com/',
    'not a url',
  ]) {
    assert.equal(supportedCustomerPushEndpoint(endpoint), false, endpoint);
  }
});

test('deadline boundary suppresses elapsed work and derives finite whole-second TTL', () => {
  const now = Date.parse('2026-07-28T12:00:00.000Z');
  assert.equal(customerPushDeadlineElapsed(null, now), false);
  assert.equal(customerPushTtlSeconds(null, now), 86400);
  assert.equal(customerPushDeadlineElapsed('2026-07-28T12:00:00.000Z', now), true);
  assert.equal(customerPushDeadlineElapsed('2026-07-28T11:59:59.999Z', now), true);
  assert.equal(customerPushDeadlineElapsed('invalid', now), true);
  assert.equal(customerPushDeadlineElapsed('2026-07-28T12:00:00.999Z', now), false);
  assert.equal(customerPushTtlSeconds('2026-07-28T12:00:00.999Z', now), 0);
  assert.equal(customerPushTtlSeconds('2026-07-28T12:00:10.999Z', now), 10);
  assert.equal(customerPushTtlSeconds('2026-07-29T12:00:00.999Z', now), 86400);
  assert.equal(customerPushTtlSeconds('2026-07-30T12:00:00.000Z', now), 86400);
});

test('raw endpoint and delivery tables are private and browser RPCs have no anon grant', async () => {
  const migration = await read(migrationPath);
  for (const table of [
    'customer_push_subscriptions_v95',
    'customer_push_subscription_operations_v95',
    'customer_push_deliveries_v95',
    'customer_push_delivery_results_v95',
  ]) {
    assert.match(migration, new RegExp(
      `alter table public\\.${table} enable row level security`,
      'i',
    ));
    assert.match(migration, new RegExp(
      `revoke all privileges on table public\\.${table}[\\s\\S]*?from public,anon,authenticated`,
      'i',
    ));
  }
  assert.match(migration, /revoke all on function public\.customer_register_push_subscription_v95[\s\S]*from public,anon,authenticated/i);
  assert.match(migration, /grant execute on function public\.customer_register_push_subscription_v95[\s\S]*to authenticated/i);
  assert.doesNotMatch(migration, /grant execute on function public\.customer_(?:register|unregister)_push_subscription_v95[\s\S]{0,100}to anon/i);
});

test('only the six reviewed inbox source/topic pairs can enter Web Push', async () => {
  const migration = await read(migrationPath);
  const eligibility = migration.match(
    /create or replace function app\.customer_push_event_eligible_v95[\s\S]+?\n\$\$;/i,
  )?.[0] || '';
  const pairs = [...eligibility.matchAll(/\('([^']+)','([^']+)'\)/g)]
    .map((match) => `${match[1]}:${match[2]}`);
  assert.deepEqual(pairs, [
    'c44_actionable_wallet:value_expiry',
    'c44_actionable_wallet:reward_ready',
    'c44_actionable_wallet:visit_progress',
    'c45_birthday_benefit:birthday_benefit',
    'v33_booking_action:booking_updates',
    'v48_appointment_reschedule:booking_updates',
  ]);
  assert.doesNotMatch(eligibility, /marketing|promotion|campaign/i);
  assert.match(migration, /where app\.customer_push_event_eligible_v95\(event\.source_kind,event\.topic\)/i);
  assert.equal(
    (migration.match(/state\.dismissed_at is null and resolution\.id is null/gi)||[]).length,
    2,
    'dismissal and resolution must gate both queue creation and lease selection',
  );
  assert.match(migration, /preference\.business_id=event\.business_id[\s\S]*preference\.identity_id=event\.identity_id[\s\S]*preference\.auth_user_id=event\.auth_user_id[\s\S]*preference\.link_id=event\.link_id/i);
  assert.match(migration, /preference\.channel='in_app'[\s\S]*preference\.topic=event\.topic[\s\S]*preference\.opted_in/i);
  assert.match(migration, /event\.created_at>=subscription\.created_at/i);
  assert.equal((migration.match(/not app\.c46_in_quiet_hours\(/g) || []).length, 2,
    'quiet hours must gate both queue creation and lease selection');
  assert.equal(
    (migration.match(/event\.deadline_at is null or event\.deadline_at>statement_timestamp\(\)/g)||[]).length,
    2,
    'expired events must be excluded at queue and lease time',
  );
});

test('service-only delivery contracts dedupe, lease, retry and append result evidence', async () => {
  const migration = await read(migrationPath);
  assert.match(migration, /unique\(event_id,subscription_id\)/i);
  assert.match(migration, /for update of delivery skip locked/i);
  assert.match(migration, /attempt_count=attempt_count\+1/i);
  assert.match(migration, /lease_until=now\(\)\+v_lease/i);
  assert.match(migration, /push delivery lease is not current/i);
  assert.match(migration, /status in \('sent','failed','gone'\)/i);
  assert.match(migration, /customer_push_delivery_results_v95_immutable/i);
  assert.match(migration, /grant execute on function public\.internal_customer_push_claim_v95[\s\S]*to service_role/i);
  assert.match(migration, /grant execute on function public\.internal_customer_push_report_v95[\s\S]*to service_role/i);
  assert.doesNotMatch(migration, /grant execute on function public\.internal_customer_push_(?:claim|report)_v95[\s\S]{0,120}to authenticated/i);
});

test('dispatcher uses VAPID secrets, bounded concurrency and reports every provider disposition', async () => {
  const [dispatcher, shared, config] = await Promise.all([
    read(dispatcherPath), read(sharedPath), read(configPath),
  ]);
  assert.match(dispatcher, /npm:web-push@3\.6\.7/);
  assert.match(dispatcher, /CUSTOMER_PUSH_VAPID_SUBJECT/);
  assert.match(dispatcher, /CUSTOMER_PUSH_VAPID_PUBLIC_KEY/);
  assert.match(dispatcher, /CUSTOMER_PUSH_VAPID_PRIVATE_KEY/);
  assert.match(shared, /CUSTOMER_PUSH_DISPATCH_SECRET/);
  assert.match(shared, /mismatch \|= expected\.charCodeAt\(index\) \^ supplied\.charCodeAt\(index\)/);
  assert.match(config, /\[functions\.customer-push-dispatch\]\s+verify_jwt = false/i);
  assert.match(dispatcher, /const MAX_CLAIM = 50/);
  assert.match(dispatcher, /const MAX_CONCURRENCY = 8/);
  assert.match(dispatcher, /internal_customer_push_claim_v95/);
  assert.match(dispatcher, /internal_customer_push_report_v95/);
  assert.match(dispatcher, /if \(!supportedCustomerPushEndpoint\(lease\.endpoint\)\)[\s\S]*unsupported_push_endpoint/i);
  assert.match(dispatcher, /else if \(customerPushDeadlineElapsed\(lease\.deadline_at, sendBoundaryAt\)\)[\s\S]*deadline_elapsed/i);
  assert.match(dispatcher, /const ttl = customerPushTtlSeconds\(lease\.deadline_at, sendBoundaryAt\)/i);
  assert.match(dispatcher, /TTL: ttl/i);
  assert.match(dispatcher, /event_type: customerPushEventType\(lease\)/);
  assert.match(dispatcher, /business_slug: lease\.business_slug/);
  assert.match(dispatcher, /notification_id: lease\.event_id/);
  assert.match(shared, /v33_booking_action[\s\S]*booking_request_received/);
  assert.match(shared, /v48_appointment_reschedule[\s\S]*appointment_time_changed/);
  assert.match(shared, /statusCode === 404 \|\| statusCode === 410/);
  assert.match(shared, /statusCode === 429 \|\| statusCode >= 500/);
  assert.doesNotMatch(dispatcher, /customer_name|full_name|phone|email|console\.(?:log|error)|marketing|promotion|campaign/i);
});

test('rollback acceptance exercises replay, isolation, finite eligibility, ACLs and evidence', async () => {
  const [fixture, concurrency] = await Promise.all([
    read(fixturePath), read(concurrencyPath),
  ]);
  assert.match(fixture, /^begin;[\s\S]*rollback;$/im);
  assert.match(fixture, /cross-customer endpoint takeover succeeded/i);
  assert.match(fixture, /wrong worker completed another lease/i);
  assert.match(fixture, /leased queued work after the current topic opt-out/i);
  assert.match(fixture, /deterministic five-device cap failed/i);
  assert.match(fixture, /subscription operation abuse bypassed the bounded rate/i);
  assert.match(fixture, /supported browser push-service boundary drifted/i);
  assert.match(fixture, /v_historical_event,v_optout_event,v_quiet_event,v_ineligible_event/i);
  assert.match(fixture, /finite six-event eligibility allowlist drifted/i);
  assert.match(fixture, /customer read raw push endpoints/i);
  assert.match(fixture, /v95 customer Web Push suite: ALL PASS/i);
  assert.match(concurrency, /V95_CONFIRM_DISPOSABLE_DB/);
  assert.match(concurrency, /while \[ "\$i" -le 8 \]/);
  assert.match(concurrency, /\[ "\$counts" = "5\|3\|8" \]/);
  assert.match(concurrency, /concurrent push registration: PASS/i);
});
