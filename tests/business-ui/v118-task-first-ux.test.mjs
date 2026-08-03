import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const html = readFileSync(new URL('../../app/index.html', import.meta.url), 'utf8');

function section(start, end) {
  const from = html.indexOf(start);
  const to = html.indexOf(end, from + start.length);
  assert.notEqual(from, -1, `missing section start: ${start}`);
  assert.notEqual(to, -1, `missing section end: ${end}`);
  return html.slice(from, to);
}

test('V141 supersedes duplicate home tasks: app bar keeps primary jobs and dashboard leads with visible analytics', () => {
  const dashboard = section('async function dashboard(){', '/* ---------- customers ---------- */');
  const shell = section('function renderShell(page){', '/* ---------- dashboard ---------- */');
  assert.doesNotMatch(dashboard, /Common tasks|Record a sale|Add appointment|Find a customer|Set up rewards/);
  assert.match(shell, /globalActionsHtml\(\)/);
  assert.match(shell, /dashboardBranchWrap/);
  assert.match(dashboard, /<section class="card performance-panel"/);
  assert.match(dashboard, /<h2 id="performanceTitle">Performance<\/h2>/);
  assert.doesNotMatch(dashboard, /<details class="card performance-panel"/);
});

test('appointments open in a simple day-by-team view with advanced controls secondary', () => {
  const appointments = section('async function appointmentsPage(){', '/* ---------- waitlist');
  assert.match(appointments, /let view='day'/);
  assert.match(appointments, /id="vDay"[^>]*>Day</);
  assert.match(appointments, /id="vWeek"[^>]*>Week</);
  assert.match(appointments, /id="vList"[^>]*>List</);
  assert.match(appointments, /<details class="appointment-more"/);
  assert.match(appointments, /id="appointmentFormCard"[^>]*hidden/);
  assert.match(appointments, /openNewAppointmentForm\(\{date='',staffId='',time='',serviceId=''\}=\{\}\)/);
});

test('day view uses named staff timelines, visible booking facts and contextual creation without false availability claims', () => {
  const day = section('  function renderDay(day){', '  function renderWeek(start){');
  assert.match(day, /day-timeline/);
  assert.match(day, /day-team-head/);
  assert.match(day, /day-team-track/);
  assert.match(day, /staffLabel\(person\)/);
  assert.match(day, /appointmentTimeRange\(item\)/);
  assert.match(day, /appointmentDuration\(item\)/);
  assert.match(day, /recordedSchedule\(person\.id,day\)/);
  assert.match(day, /schedule\.state!==['"]working['"]/);
  assert.match(day, /day-schedule-window/);
  assert.match(day, /day-break-window/);
  assert.match(day, /todayMinutes/);
  assert.match(day, /day-now-line/);
  assert.match(day, /data-day="\$\{day\}"/);
  assert.match(day, /data-staff="\$\{column\.id\}"/);
  assert.match(day, /class="day-slot-button"/);
  assert.match(day, /data-time="\$\{minuteClock\(start\)\}"/);
  assert.match(day, /data-service="\$\{esc\(calendarServiceId\)\}"/);
  assert.match(day, /openNewAppointmentForm\(\{\s*date:button\.dataset\.day,\s*staffId:button\.dataset\.staff,\s*time:button\.dataset\.time,\s*serviceId:button\.dataset\.service\s*\}\)/);
  assert.match(day, /Choose a green start time/);
});

test('day view derives availability only from persisted staff and branch schedules', () => {
  const appointments = section('async function appointmentsPage(){', '/* ---------- waitlist');
  assert.match(appointments, /from\('staff_hours'\)\.select\('staff_id,weekday,starts_at,ends_at',\{count:'exact'\}\)/);
  assert.match(appointments, /from\('staff_off_days'\)\.select\('staff_id,starts_on,ends_on,reason',\{count:'exact'\}\)/);
  assert.match(appointments, /from\('branch_hours'\)\.select\('branch_id,weekday,opens_at,closes_at',\{count:'exact'\}\)/);
  assert.match(appointments, /from\('branch_breaks'\)\.select\('branch_id,weekday,starts_at,ends_at',\{count:'exact'\}\)/);
  assert.match(appointments, /function recordedSchedule\(personId,day\)/);
  assert.match(appointments, /state:'unknown',label:'Working hours not set'/);
  assert.match(appointments, /state:'off',label:'Off',reason:leave\.reason\|\|'Time off'/);
  assert.match(appointments, /state:'off',label:'Branch closed'/);
  assert.match(appointments, /function availableCalendarStarts\(column\)/);
  assert.match(appointments, /selectedCalendarServiceTiming\(\)/);
  assert.match(appointments, /intervalsOverlap\(occupiedStart,occupiedEnd,interval\.from,interval\.to\)/);
  assert.match(appointments, /buffer_before_min/);
  assert.match(appointments, /buffer_after_min/);
});

test('appointment completion describes checkout truthfully without promising loyalty', () => {
  const appointments = section('async function appointmentsPage(){', '/* ---------- waitlist');
  assert.match(appointments, /Complete &amp; checkout/);
  assert.match(appointments, /set_appointment_status_v47/);
  assert.match(appointments, /Review Sales for the final points outcome/);
  assert.doesNotMatch(appointments, /Completed — sale and loyalty recorded/);
});

test('reports answer money, capacity and returning-customer questions from recorded data', () => {
  const reports = section('async function reportsPage(){', '/* ---------- get started');
  assert.match(reports, /Business answers/);
  assert.match(reports, /How is money moving\?/);
  assert.match(reports, /How busy are we\?/);
  assert.match(reports, /Who is coming back\?/);
  assert.match(reports, /How is the team doing\?/);
  assert.match(reports, /id:'moneyAnswer'/);
  assert.match(reports, /id:'busyAnswer'/);
  assert.match(reports, /id:'returningAnswer'/);
  assert.match(reports, /id="moneyDetails"/);
  assert.match(reports, /id="busyDetails"/);
  assert.match(reports, /id="returningDetails"/);
  assert.match(reports, /get_customer_lifecycle_v107/);
  assert.match(reports, /staff_hours/);
  assert.match(reports, /staff_off_days/);
  assert.match(reports, /branch_hours/);
  assert.match(reports, /branch_breaks/);
  assert.match(reports, /mergedIntervalMinutes/);
  assert.match(reports, /eligible completed purchases that retain positive value after reversals or refunds/i);
  assert.match(reports, /not inferred from visits/i);
  assert.match(reports, /Scheduled capacity needs both branch opening hours and team working hours/);
  assert.match(reports, /branch-open active-team hours after merged breaks, staff blocks/i);
  assert.match(reports, /Overbooked by/);
});

test('dashboard and report layouts collapse to one column on narrow phones', () => {
  assert.match(html, /@media\(max-width:960px\)\{[\s\S]*?\.dashboard-charts\{grid-template-columns:1fr\}/);
  assert.match(html, /<button type="button" class="dashboard-metric kpi"/);
  assert.match(html, /\.report-decision-card\{[^}]*min-height:150px/);
  assert.match(html, /\.day-timeline-scroll\{[^}]*overflow:auto/);
  assert.match(html, /@media\s*\(prefers-reduced-motion:\s*reduce\)/);
});

test('appointment actions use branch-projected permissions and expose a truthful zero-access state', () => {
  const appointments = section('async function appointmentsPage(){', '/* ---------- waitlist');
  assert.match(appointments, /loadBranchModuleProjection\(branch\.id\)/);
  assert.match(appointments, /projectionCanRead\(branchProjection\[branch\.id\],'appointments'\)/);
  assert.match(appointments, /projectionCanWrite\(selectedProjection,'appointments'\)/);
  assert.match(appointments, /projectionCanWrite\(selectedProjection,'till'\)/);
  assert.match(appointments, /hasRoleCapability\('create_sales'\)/);
  assert.match(appointments, /No appointment access/);
  assert.match(appointments, /This account has no active branch where Appointments is enabled/);
});
