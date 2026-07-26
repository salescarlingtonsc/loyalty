import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import test from 'node:test';

const root = new URL('../..', import.meta.url).pathname;
const read = (path) => readFile(join(root, path), 'utf8');
const sourcePath = 'db/migrations/20260726_frenly_v73_booking_lifecycle.sql';
const canonicalPath = 'supabase/migrations/20260725140000_frenly_v73_booking_lifecycle.sql';

test('v73 installs the linked waitlist invariant only after fail-closed data preflight', async () => {
  const sql = await read(sourcePath);
  const preflight = sql.indexOf('do $v73_waitlist_preflight$');
  const foreignKey = sql.indexOf('add constraint waitlist_booking_request_business_fk_v73');
  const uniqueIndex = sql.indexOf('create unique index waitlist_one_link_per_booking_request_v73_uk');
  assert.ok(preflight >= 0 && foreignKey > preflight && uniqueIndex > foreignKey);
  assert.match(sql, /waitlist_row\.business_id <> request\.business_id/);
  assert.match(sql, /group by waitlist_row\.booking_request_id\s+having count\(\*\) > 1/);
  assert.match(sql, /foreign key \(booking_request_id, business_id\)[\s\S]+references public\.booking_requests\(id, business_id\)/);
  assert.match(sql, /on delete set null \(booking_request_id\)/);
  assert.match(sql, /on public\.waitlist\(booking_request_id\)\s+where booking_request_id is not null/);
});

test('v73 locks request then linked waitlist and uses the request as natural idempotency', async () => {
  const sql = await read(sourcePath);
  const fn = sql.match(/create or replace function public\.staff_decide_booking_request_v73[\s\S]+?\n\$\$;/)?.[0] || '';
  const requestLock = fn.indexOf('from public.booking_requests request');
  const waitlistLock = fn.indexOf('from public.waitlist waitlist_row');
  assert.ok(requestLock >= 0 && waitlistLock > requestLock);
  assert.match(fn, /where request\.id = p_request[\s\S]+request\.business_id = p_business[\s\S]+for update/);
  assert.match(fn, /where waitlist_row\.booking_request_id = p_request[\s\S]+waitlist_row\.business_id = p_business[\s\S]+for update/);
  assert.match(fn, /'booking-request:' \|\| p_request::text/);
  assert.doesNotMatch(fn, /p_(?:customer_)?client|p_name|p_phone|p_email/);
});

test('confirm and decline use their exact independent module permissions', async () => {
  const sql = await read(sourcePath);
  const fn = sql.match(/create or replace function public\.staff_decide_booking_request_v73[\s\S]+?\n\$\$;/)?.[0] || '';
  assert.match(fn, /p_business is null or p_request is null or p_decision is null[\s\S]+p_decision not in \('confirm', 'decline'\)/);
  const decline = fn.indexOf("if p_decision = 'decline' then");
  const bookingsGate = fn.indexOf("app.can_module_write(p_business, 'bookings')");
  const confirmGate = fn.indexOf("app.can_module_write(p_business, 'appointments')");
  assert.ok(decline >= 0 && bookingsGate > decline && confirmGate > bookingsGate);
  assert.doesNotMatch(fn.slice(0, decline), /can_module_write\(p_business, 'bookings'\)/);
  assert.match(fn, /not app\.can_see_branch\(p_business, v_branch\)/);
  assert.match(fn, /order by branch\.is_default desc, branch\.created_at, branch\.id/);
});

test('v73 terminal transitions are truthful and applied transitions synchronize waitlist state', async () => {
  const sql = await read(sourcePath);
  assert.match(sql, /v_request\.status = 'declined'[\s\S]+'replayed', true/);
  assert.match(sql, /v_request\.status = 'confirmed'[\s\S]+'replayed', true/);
  assert.match(sql, /v_request\.status in \('confirmed', 'expired', 'cancelled'\)[\s\S]+'terminal_conflict'/);
  assert.match(sql, /v_request\.status in \('declined', 'expired', 'cancelled'\)[\s\S]+'terminal_conflict'/);
  assert.match(sql, /set status = 'declined',\s+expires_at = null/);
  assert.match(sql, /set status = 'removed'/);
  assert.match(sql, /set status = 'confirmed',\s+appointment_id = v_appointment\.id,\s+expires_at = null/);
  assert.match(sql, /set status = 'booked'/);
});

test('waitlisted and expired pending table requests recheck locked current capacity', async () => {
  const sql = await read(sourcePath);
  const fn = sql.match(/create or replace function public\.staff_decide_booking_request_v73[\s\S]+?\n\$\$;/)?.[0] || '';
  const availability = sql.match(/create or replace view public\.v_table_availability[\s\S]+?where table_type\.active;/)?.[0] || '';
  assert.match(fn, /v_request\.status = 'waitlisted'[\s\S]+v_request\.status = 'pending'[\s\S]+v_request\.expires_at <= clock_timestamp\(\)/);
  assert.match(fn, /from public\.booking_tables table_type[\s\S]+for update/);
  assert.match(fn, /held_request\.id <> p_request/);
  assert.match(fn, /held_request\.expires_at is null[\s\S]+held_request\.expires_at > clock_timestamp\(\)/);
  assert.match(fn, /held_appointment\.status = 'booked'/);
  assert.match(fn, /coalesce\(v_available, 0\) <= 0[\s\S]+'capacity_conflict'/);
  assert.match(availability, /held_request\.status in \('new', 'pending'\)[\s\S]+held_request\.expires_at is null[\s\S]+held_request\.expires_at > clock_timestamp\(\)/);
});

test('bound versus guest conversion and conflict rollback preserve v72 semantics', async () => {
  const sql = await read(sourcePath);
  const fn = sql.match(/create or replace function public\.staff_decide_booking_request_v73[\s\S]+?\n\$\$;/)?.[0] || '';
  assert.match(fn, /if v_request\.customer_client_id is not null then[\s\S]+client\.id = v_request\.customer_client_id/);
  assert.match(fn, /else[\s\S]+app\.upsert_portal_client[\s\S]+app\.apply_booking_consent/);
  assert.match(fn, /begin[\s\S]+book_appointment_smart_v47[\s\S]+raise exception 'v73 scheduling conflict'[\s\S]+exception[\s\S]+when sqlstate 'P0731' or exclusion_violation/);
  assert.match(fn, /'scheduling_conflict', false/);
  assert.match(fn, /set party_size = v_request\.party_size,\s+source = 'portal',\s+table_type_id = v_request\.table_type_id/);
});

test('v73 response and decision audit are operationally safe and replay-free', async () => {
  const sql = await read(sourcePath);
  const result = sql.match(/create or replace function app\.booking_decision_result_v73[\s\S]+?\n\$\$;/)?.[0] || '';
  for (const field of [
    'request_id', 'requested_decision', 'outcome', 'actual_status', 'replayed',
    'appointment_id', 'branch_id', 'starts_at', 'ends_at',
    'waitlist_id', 'waitlist_status',
  ]) assert.match(result, new RegExp(`'${field}'`));
  const composition = result.match(
    /select\s+(jsonb_build_object\([\s\S]+?\)\s*\|\|\s*jsonb_strip_nulls\(jsonb_build_object\([\s\S]+?\)\))/i
  )?.[1] || '';
  assert.match(composition, /^jsonb_build_object\(/i);
  assert.match(composition, /'requested_decision', p_decision/i);
  assert.match(composition, /\)\s*\|\|\s*jsonb_strip_nulls\(jsonb_build_object\(/i);
  assert.doesNotMatch(composition, /\)\)\s*\|\|/,
    'mandatory response object must close exactly once before concatenation');
  assert.match(result, /jsonb_build_object\([\s\S]+?'requested_decision', p_decision[\s\S]+?\)\s*\|\|\s*jsonb_strip_nulls\(jsonb_build_object\(/,
    'requested_decision belongs to the mandatory response object and cannot be stripped');
  for (const field of ['name', 'phone', 'email', 'notes', 'client_id', 'staff_id']) {
    assert.doesNotMatch(result, new RegExp(`'${field}'`));
  }
  assert.equal((sql.match(/'BOOKING_REQUEST_DECISION_V73'/g) || []).length, 2,
    'exactly the confirm and decline applied branches write the decision audit');
  const firstAudit = sql.indexOf("'BOOKING_REQUEST_DECISION_V73'");
  assert.ok(firstAudit > sql.indexOf("set status = 'declined'"));
});

test('legacy conversion is a non-recursive authenticated compatibility wrapper', async () => {
  const sql = await read(sourcePath);
  const wrapper = sql.match(/create or replace function public\.convert_booking_request\(p_request uuid\)[\s\S]+?\n\$\$;/)?.[0] || '';
  assert.match(wrapper, /public\.staff_decide_booking_request_v73\(/);
  assert.equal((wrapper.match(/public\.convert_booking_request\(/g) || []).length, 1,
    'the only convert_booking_request occurrence must be its declaration');
  assert.match(wrapper, /row_to_json\(appointment\)/);
  assert.match(sql, /revoke all on function public\.convert_booking_request\(uuid\)\s+from public, anon, authenticated/);
  assert.match(sql, /grant execute on function public\.convert_booking_request\(uuid\)\s+to authenticated/);
});

test('v73 RPC is fixed-search-path, authenticated-only, and browser tables remain untouched', async () => {
  const sql = await read(sourcePath);
  const fn = sql.match(/create or replace function public\.staff_decide_booking_request_v73[\s\S]+?\n\$\$;/)?.[0] || '';
  assert.match(fn, /security definer/);
  assert.match(fn, /set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'/);
  assert.match(sql, /revoke all on function public\.staff_decide_booking_request_v73\([\s\S]+from public, anon, authenticated/);
  assert.match(sql, /grant execute on function public\.staff_decide_booking_request_v73\([\s\S]+to authenticated/);
  assert.doesNotMatch(sql, /grant (?:insert|update|delete|all).*booking_requests|grant (?:insert|update|delete|all).*waitlist/i);
});

test('v73 rollback and two-session evidence cover the lifecycle matrix', async () => {
  const [rollback, concurrency] = await Promise.all([
    read('db/tests/v73_booking_lifecycle.sql'),
    read('db/tests/v73_booking_lifecycle_concurrency.sh'),
  ]);
  assert.match(rollback, /^begin;/m);
  assert.match(rollback, /^rollback;/m);
  for (const evidence of [
    'NULL decision confirmed a booking request',
    'NULL decision mutated or audited a booking request',
    'decline result stripped requested_decision or was not safe and applied',
    'appointments:rw manager could not confirm',
    'appointments:rw frontdesk could not confirm',
    'bookings:r manager declined a request',
    'frontdesk confirmed outside its branch',
    'bound client conversion drifted',
    'capacity conflict mutated the request',
    'expired sibling pending hold caused a false capacity conflict',
    'scheduling conflict leaked a side effect',
    'duplicate linked waitlist rows were accepted',
    'cross-tenant linked waitlist row was accepted',
  ]) assert.match(rollback, new RegExp(evidence.replaceAll(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  assert.match(concurrency, /V73_CONFIRM_DISPOSABLE_DB/);
  assert.match(concurrency, /'confirm'/);
  assert.match(concurrency, /decline/);
  assert.match(concurrency, /BOOKING_REQUEST_DECISION_V73/);
  assert.match(concurrency, /appointment_count/);
});

test('v73 source, canonical order and materialization are exact after v72', async () => {
  const [source, canonical, sourcePlan, canonicalPlan] = await Promise.all([
    read(sourcePath),
    read(canonicalPath),
    read('db/migrations/migration-order.plan.json'),
    read('supabase/canonical-migration-order.plan.json'),
  ]);
  assert.equal(canonical, source);
  assert.match(sourcePlan, /v72_booking_identity_sync[\s\S]+v73_booking_lifecycle/);
  assert.match(canonicalPlan, /20260725130000[\s\S]+20260725140000/);
});
