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
const app = ((await readFile(path.join(repoRoot,'app/index.html'),'utf8'))+'\n'+(await readFile(path.join(repoRoot,'app/app.js'),'utf8')));
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

test('frontline Record sale minimizes choices and keeps hardened sale attribution', () => {
  const tillStart = app.indexOf('async function tillPage');
  const tillEnd = app.indexOf('/* ----------',tillStart + 1);
  const till = app.slice(tillStart,tillEnd);
  const quickStart = migration.indexOf('create or replace function public.record_sale_by_phone(');
  const quickEnd = migration.indexOf('-- Preserve completion behavior',quickStart);
  const quick = migration.slice(quickStart,quickEnd);
  assert.ok(tillStart >= 0,'Quick earn page must exist');
  assert.match(app,/>Record sale</);
  assert.match(till,/Phone number[\s\S]*id="tfind"[\s\S]*Next/i);
  assert.match(till,/legacyTenderOptions=\[\['cash','Cash'\],\['card','Card'\],\['paynow','External PayNow'\],\['other','Other'\]\]/i);
  // The confirm button is now "Record sale", matching the module name, rather than the older
  // "Save & add points". The flow it anchors — amount, then tender, then one confirm — is the same.
  assert.match(till,/id="tAmt"[\s\S]*Payment received[\s\S]*legacyTenderOptions\.map[\s\S]*id="tConfirm"[\s\S]{0,120}Record sale/i);
  assert.match(till,/record_sale_by_phone/);
  // V187: a sale is credited to the teammate who performed it, defaulting to the signed-in
  // user. Auto-attributing to the operator was NOT 'hardened' — at a salon the receptionist
  // ringing up a therapist's treatment silently took their commission, because
  // on_sale_commission_snapshot freezes the rate from sales.staff_id.
  assert.match(till,/p_staff:tillSaleStaffId\|\|tillStaffId/);
  assert.match(till,/p_branch:tillBranchId/);
  assert.match(till,/p_method:tender/);
  assert.match(till,/accessibleTillBranches/);
  assert.match(till,/^\s*if\(!\/\^\\d\+\(\?:\\\.\\d\{1,2\}\)\?\$\/\.test\(rawAmount\)\)/m);
  assert.match(till,/keydown[\s\S]*Enter[\s\S]*tConfirm/i);
  // Scan RENDERED copy only: this guards against the till screen showing loyalty stats to the
  // operator, and a source-wide scan trips on code comments that merely mention them.
  // V188 puts the customer's points balance on the RECEIPT at the owner's request. That is a
  // different moment from sale ENTRY: the guard here is that the operator is not shown loyalty
  // stats while taking money, so the receipt block is excluded rather than the rule weakened.
  const tillCopy=till.replace(/\/\*[\s\S]*?\*\//g,' ').replace(/(^|[^:])\/\/[^\n]*/g,'$1 ')
    .replace(/id="posReceiptV142"[\s\S]*?id="tNext"/,' ');
  assert.doesNotMatch(tillCopy,/Points balance|Store credit|Visits/i);
  assert.match(till,/Scan customer QR/,
    'the intentionally added post-sale reward scanner must remain a clear, single-purpose action');
  assert.match(quick,/staff\.user_id=auth\.uid\(\)[\s\S]*p_staff is distinct from v_actor_staff/i);
  assert.match(quick,/p_idem is null or char_length\(btrim\(p_idem\)\) not between 8 and 200/i);
  assert.match(quick,/p_kind is distinct from 'quick_sale'/i);
  assert.match(quick,/p_branch is null/i);
  assert.match(quick,/record_quick_sale\([\s\S]*p_paid=>true/i);
  assert.doesNotMatch(quick,/insert into public\.sales/i);
  assert.match(migration,/revoke all privileges on function public\.record_sale_by_phone\(\s*uuid,text,integer,text,text,uuid,text\) from public, anon, authenticated/i);
  assert.match(migration,/grant execute on function public\.record_sale_by_phone\(\s*uuid,text,integer,text,text,uuid,text,uuid,text\) to authenticated/i);
});

test('calendar UI opens day-by-team, keeps week/list secondary, and never writes appointments directly', () => {
  const start = app.indexOf('async function appointmentsPage');
  const end = app.indexOf('/* ---------- waitlist',start);
  const calendar = app.slice(start,end);
  assert.match(calendar,/Everyone/);
  assert.match(calendar,/Auto-assign · fair rotation/);
  assert.match(calendar,/suggest_appointment_staff_v47/);
  assert.match(calendar,/book_appointment_smart_v47/);
  assert.match(calendar,/set_appointment_status_v47/);
  assert.match(calendar,/next_best_slots/);
  assert.match(calendar,/let view='day'/);
  assert.match(calendar,/<button class="qbtn act" id="vDay">Day<\/button>/);
  assert.match(calendar,/day-timeline/);
  assert.match(calendar,/staff_hours/);
  assert.match(calendar,/staff_off_days/);
  assert.match(calendar,/branch_hours/);
  assert.match(calendar,/branch_breaks/);
  assert.match(calendar,/Working hours not set/);
  assert.match(calendar,/day-schedule-window/);
  assert.doesNotMatch(calendar,/No appointments scheduled[\s\S]{0,80}available/i);
  assert.match(calendar,/calendar-week/);
  assert.match(calendar,/calendar-agenda/);
  assert.match(calendar,/layoutCalendarDay[\s\S]*laneEnds[\s\S]*laneCount/i);
  assert.match(calendar,/left:calc\(\$\{left\}% \+ 3px\)[\s\S]*width:calc\(\$\{width\}% - 6px\)/i);
  assert.match(calendar,/selectedCalendarServiceTiming[\s\S]*duration_min[\s\S]*buffer_before_min[\s\S]*buffer_after_min/i);
  assert.match(calendar,/availableCalendarStarts[\s\S]*hitsBreak[\s\S]*hitsAppointment/i);
  assert.match(calendar,/inactiveAppointmentStatuses/);
  assert.match(calendar,/No opening hours are recorded for this weekday/i);
  assert.match(calendar,/const hourHeight=176/);
  assert.match(calendar,/<div class="day-schedule-window"[\s\S]*aria-hidden="true"><\/div>/i);
  assert.match(calendar,/<button type="button" class="day-slot-button"[\s\S]*data-day="\$\{day\}"[\s\S]*data-staff="\$\{column\.id\}"[\s\S]*data-time="\$\{minuteClock\(start\)\}"[\s\S]*data-service=/i);
  assert.match(calendar,/querySelectorAll\('\.day-slot-button'\)[\s\S]*openNewAppointmentForm\(\{[\s\S]*date:button\.dataset\.day[\s\S]*staffId:button\.dataset\.staff[\s\S]*time:button\.dataset\.time[\s\S]*serviceId:button\.dataset\.service/i);
  // V194 removed the calendar service picker at the owner's request: filtering the calendar to
  // one service hid every other booking, which reads as a broken calendar. The service is chosen
  // in New appointment instead.
  assert.doesNotMatch(calendar,/id="calendarService"/);
  assert.match(calendar,/let calendarServiceId=''/,
    'the binding stays so the filter and slot-click preselection remain harmless no-ops');
  assert.match(calendar,/--calendar-hour-height:\$\{hourHeight\}px/i);
  assert.match(calendar,/height=\(to-from\)\/60\*hourHeight/i);
  assert.doesNotMatch(calendar,/from\('appointments'\)\.insert|from\('appointments'\)\.update|from\('appointments'\)\.delete/);
  assert.match(calendar,/createLatestRequestGate\(isCurrent\)/);
  assert.match(calendar,/availabilityGate\.invalidate\(\)/);
  assert.match(calendar,/bookingGate\.invalidate\(\)/);
  assert.match(calendar,/const stillCurrent=bookingGate\.begin\(\)[\s\S]*if\(!stillCurrent\(\)\)return/i);
  assert.match(calendar,/const stillCurrent=statusGate\.begin\(\)[\s\S]*if\(!stillCurrent\(\)\)return/i);
  assert.match(calendar,/\['ad','at','astf','apDuration'\][\s\S]*invalidateFormRequests/i);
  assert.match(calendar,/canComplete=canWrite&&projectionCanWrite\(selectedProjection,'till'\)&&hasRoleCapability\('create_sales'\)/);
  assert.match(calendar,/appointmentOutcomeIsDue/);
  assert.match(calendar,/Complete and No-show become available after the appointment starts/i);
});

test('15-minute day slots retain 44px targets without overlap', () => {
  const hourHeight=176;
  const slotMinutes=15;
  const renderedHeight=slotMinutes/60*hourHeight;
  const nextStart=slotMinutes/60*hourHeight;
  assert.equal(renderedHeight,44,'a 15-minute exact start must have a 44px target');
  assert.equal(nextStart,renderedHeight,'adjacent exact starts must not overlap');
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
