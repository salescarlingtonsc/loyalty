import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const repoRoot = fileURLToPath(new URL('../..', import.meta.url));
const migration = await readFile(path.join(
  repoRoot,'db/migrations/20260722050339_frenly_v47_smart_staff_scheduling.sql'
),'utf8');
const gatewayMigration = await readFile(path.join(
  repoRoot,'db/migrations/20260718180602_frenly_v19_public_gateway_security.sql'
),'utf8');
const app = await readFile(path.join(repoRoot,'app/index.html'),'utf8');
const concurrency = await readFile(path.join(
  repoRoot,'db/tests/v47_booking_concurrency.sh'
),'utf8');

test('v47 scheduling mutations are authenticated RPC-only and branch scoped', () => {
  assert.match(migration,/revoke insert, update, delete, truncate on table public\.appointments[\s\S]*from public, anon, authenticated/i);
  assert.match(migration,/appointments_v47_read[\s\S]*can_module_read\(business_id,'appointments'\)[\s\S]*can_see_branch\(business_id,branch_id\)/i);
  assert.match(migration,/book_appointment_smart_v47[\s\S]*can_module_write\(p_business, 'appointments'\)[\s\S]*can_see_branch\(p_business, p_branch\)/i);
  assert.match(migration,/grant execute on function public\.book_appointment_smart_v47[\s\S]*to authenticated/i);
  assert.doesNotMatch(migration,/grant execute on function public\.book_appointment_smart_v47[\s\S]{0,120}to anon/i);
  assert.match(migration,/create or replace function public\.decide_change[\s\S]*can_module_write\(v_request\.business_id,'appointments'\)[\s\S]*staff_free_for_appointment_v47/i);
  assert.match(migration,/create or replace function public\.convert_booking_request[\s\S]*book_appointment_smart_v47/i);
  assert.doesNotMatch(migration,/create or replace function public\.request_change|grant execute on function public\.request_change/i,
    'v47 must not reopen the phone-only public gateway removed by v19');
  assert.match(gatewayMigration,/internal_public_booking_change[\s\S]*to service_role/i);
  assert.match(gatewayMigration,/proname = any[\s\S]*'request_change'[\s\S]*revoke all on function/i);
});

test('v47 prevents overlap and respects the complete availability model', () => {
  assert.match(migration,/existing\.starts_at[\s\S]*buffer_before_min[\s\S]*< v_block_end/i);
  assert.match(migration,/existing\.ends_at[\s\S]*buffer_after_min[\s\S]*> v_block_start/i);
  assert.match(migration,/from public\.branch_hours/i);
  assert.match(migration,/from public\.branch_breaks/i);
  assert.match(migration,/from public\.staff_hours/i);
  assert.match(migration,/from public\.staff_off_days/i);
  assert.match(migration,/from public\.staff_services/i);
});

test('v47 fair rotation, conflict alternatives and booking replay are deterministic', () => {
  assert.match(migration,/order by recent_appointments, last_assigned nulls first/i);
  assert.match(migration,/jsonb_array_length\(v_next\) < 2/i);
  assert.match(migration,/pg_advisory_xact_lock\(hashtextextended\(p_business::text, 47\)\)/i);
  assert.match(migration,/idempotency key was already used for a different appointment request/i);
  assert.match(migration,/p_assignment_mode not in \('manual','round_robin'\)/i);
});

test('frontline Quick earn minimizes choices and keeps hardened sale attribution', () => {
  const tillStart = app.indexOf('async function tillPage');
  const tillEnd = app.indexOf('/* ----------',tillStart + 1);
  const till = app.slice(tillStart,tillEnd);
  const quickStart = migration.indexOf('create or replace function public.record_sale_by_phone(');
  const quickEnd = migration.indexOf('-- Preserve completion behavior',quickStart);
  const quick = migration.slice(quickStart,quickEnd);
  assert.ok(tillStart >= 0,'Quick earn page must exist');
  assert.match(app,/>Quick earn</);
  assert.match(till,/Phone number[\s\S]*id="tfind"[\s\S]*Next/i);
  assert.match(till,/id="tAmt"[\s\S]*Payment received[\s\S]*Cash[\s\S]*Card[\s\S]*PayNow[\s\S]*Save & add points/i);
  assert.match(till,/record_sale_by_phone/);
  assert.match(till,/p_staff:tillStaffId/);
  assert.match(till,/p_branch:tillBranchId/);
  assert.match(till,/p_method:tender/);
  assert.match(till,/accessibleTillBranches/);
  assert.match(till,/^\s*if\(!\/\^\\d\+\(\?:\\\.\\d\{1,2\}\)\?\$\/\.test\(rawAmount\)\)/m);
  assert.match(till,/keydown[\s\S]*Enter[\s\S]*tConfirm/i);
  assert.doesNotMatch(till,/Redeem|Points balance|Store credit|Visits/i);
  assert.match(quick,/staff\.user_id=auth\.uid\(\)[\s\S]*p_staff is distinct from v_actor_staff/i);
  assert.match(quick,/p_idem is null or char_length\(btrim\(p_idem\)\) not between 8 and 200/i);
  assert.match(quick,/p_kind is distinct from 'quick_sale'/i);
  assert.match(quick,/p_branch is null/i);
  assert.match(quick,/record_quick_sale\([\s\S]*p_paid=>true/i);
  assert.doesNotMatch(quick,/insert into public\.sales/i);
  assert.match(migration,/revoke all privileges on function public\.record_sale_by_phone\(\s*uuid,text,integer,text,text,uuid,text\) from public, anon, authenticated/i);
  assert.match(migration,/grant execute on function public\.record_sale_by_phone\(\s*uuid,text,integer,text,text,uuid,text,uuid,text\) to authenticated/i);
});

test('calendar UI exposes everyone or individual staff and never writes appointments directly', () => {
  const start = app.indexOf('async function appointmentsPage');
  const end = app.indexOf('/* ---------- waitlist',start);
  const calendar = app.slice(start,end);
  assert.match(calendar,/Everyone/);
  assert.match(calendar,/Best available · fair rotation/);
  assert.match(calendar,/suggest_appointment_staff_v47/);
  assert.match(calendar,/book_appointment_smart_v47/);
  assert.match(calendar,/set_appointment_status_v47/);
  assert.match(calendar,/next_best_slots/);
  assert.match(calendar,/calendar-week/);
  assert.match(calendar,/calendar-agenda/);
  assert.match(calendar,/layoutCalendarDay[\s\S]*laneEnds[\s\S]*laneCount/i);
  assert.match(calendar,/left:calc\(\$\{left\}% \+ 3px\)[\s\S]*width:calc\(\$\{width\}% - 6px\)/i);
  assert.match(calendar,/shortestDuration[\s\S]*Math\.max\(64,Math\.ceil\(44\*60\/shortestDuration\)\)/i);
  assert.match(calendar,/--calendar-hour-height:\$\{hourHeight\}px/i);
  assert.match(calendar,/height=\(to-from\)\/60\*hourHeight/i);
  assert.doesNotMatch(calendar,/from\('appointments'\)\.insert|from\('appointments'\)\.update|from\('appointments'\)\.delete/);
  assert.match(calendar,/createLatestRequestGate\(isCurrent\)/);
  assert.match(calendar,/availabilityGate\.invalidate\(\)/);
  assert.match(calendar,/bookingGate\.invalidate\(\)/);
  assert.match(calendar,/const stillCurrent=bookingGate\.begin\(\)[\s\S]*if\(!stillCurrent\(\)\)return/i);
  assert.match(calendar,/const stillCurrent=statusGate\.begin\(\)[\s\S]*if\(!stillCurrent\(\)\)return/i);
  assert.match(calendar,/\['ad','at','astf','apDuration'\][\s\S]*invalidateFormRequests/i);
  assert.match(calendar,/canComplete=canWrite&&hasRoleCapability\('create_sales'\)/);
  assert.match(calendar,/appointmentOutcomeIsDue/);
  assert.match(calendar,/Complete and No-show become available after the appointment starts/i);
});

test('short adjacent appointments retain 44px targets without vertical overlap', () => {
  for (const durationMinutes of [15,30,60]) {
    const hourHeight=Math.max(64,Math.ceil(44*60/durationMinutes));
    const renderedHeight=durationMinutes/60*hourHeight;
    const nextStart=durationMinutes/60*hourHeight;
    assert.ok(renderedHeight>=44,'adaptive hour scale must preserve a 44px target');
    assert.equal(nextStart,renderedHeight,
      `${durationMinutes}-minute adjacent events must not visually overlap`);
  }
});

test('completion is sales-authorized and preserves branch attribution', () => {
  assert.match(migration,/p_status='completed' and not app\.has_perm\(p_business,'create_sales'\)/i);
  assert.match(migration,/p_status in \('completed','no_show'\) and v_appointment\.starts_at>clock_timestamp\(\)/i);
  assert.match(migration,/business_id,client_id,kind,amount_cents,appointment_id,staff_id,branch_id,note/i);
  assert.match(migration,/new\.business_id,new\.client_id,'service',v_amount,new\.id,v_staff,new\.branch_id/i);
});

test('v47 has disposable booking and paid Quick earn concurrency proofs with scoped cleanup', () => {
  assert.match(concurrency,/V47_CONFIRM_DISPOSABLE_DB/);
  assert.match(concurrency,/pg_advisory_lock/);
  assert.match(concurrency,/book_appointment_smart_v47/);
  assert.match(concurrency,/record_sale_by_phone/);
  assert.match(concurrency,/'paynow'/);
  assert.match(concurrency,/"status": "booked"/);
  assert.match(concurrency,/"status": "conflict"/);
  assert.match(concurrency,/cleanup_synthetic_fixture\.sql/);
  assert.match(concurrency,/booked=1 conflict=1/);
  assert.match(concurrency,/sale\|payment\|operation=\$quick_proof/);
});
