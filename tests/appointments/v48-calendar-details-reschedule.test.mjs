import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../../',import.meta.url);
const app=await readFile(new URL('app/index.html',root),'utf8');
const customerUi=await readFile(new URL('app/customer-ui.js',root),'utf8');
const source=await readFile(new URL('db/migrations/20260722_frenly_v48_calendar_details_reschedule.sql',root),'utf8');
const deploy=await readFile(new URL('supabase/migrations/20260722133000_frenly_v48_calendar_details_reschedule.sql',root),'utf8');
const fixture=await readFile(new URL('db/tests/v48_calendar_details_reschedule.sql',root),'utf8');
const calendar=app.slice(app.indexOf('async function appointmentsPage()'),app.indexOf('/* ---------- waitlist ---------- */'));

test('v48 source and deploy migrations are byte-identical forward-only changes',()=>{
  assert.equal(source,deploy);
  assert.match(source,/^-- FRENLY v48[\s\S]*\nbegin;/);
  assert.match(source,/notify pgrst, 'reload schema';\n\ncommit;\n$/);
});

test('v48 reschedule RPC is authenticated, branch-scoped, locked and replay-safe',()=>{
  assert.match(source,/create or replace function public\.reschedule_appointment_v48\([\s\S]*security definer[\s\S]*auth\.uid\(\)[\s\S]*can_module_write\(p_business,'appointments'\)/i);
  assert.match(source,/can_see_branch\(p_business,v_appointment\.branch_id\)/);
  assert.match(source,/for update/);
  assert.match(source,/pg_advisory_xact_lock[\s\S]*v48:appointment-reschedule/);
  assert.match(source,/pg_advisory_xact_lock\(hashtextextended\(p_business::text,47\)\)[\s\S]*staff_free_for_appointment_v47[\s\S]*update public\.appointments/);
  assert.match(source,/appointment_reschedule_operations[\s\S]*request_hash[\s\S]*response jsonb/);
  assert.match(source,/appointment_reschedule_operations_immutable_guard[\s\S]*c46_append_only_guard/);
  assert.match(source,/idempotency key was already used for a different appointment change/);
  assert.match(source,/revoke all privileges on function public\.reschedule_appointment_v48[\s\S]*from public, anon, authenticated;[\s\S]*grant execute[\s\S]*to authenticated;/i);
  assert.doesNotMatch(source,/grant execute on function public\.reschedule_appointment_v48[\s\S]{0,180}\bto anon\b/i);
});

test('v48 validates appointment relationships and returns non-mutating conflict suggestions',()=>{
  assert.match(source,/only a future booked appointment can be changed/);
  assert.match(source,/appointment branch is not active/);
  assert.match(source,/appointment service is not active at this branch/);
  assert.match(source,/assigned staff must be active at this branch/);
  assert.match(source,/choose a different date, time, duration, staff member or note/);
  assert.match(source,/staff_free_for_appointment_v47\([\s\S]*p_appointment/);
  assert.match(source,/suggest_appointment_reschedule_v48[\s\S]*next_best_slots/);
  const conflict=source.slice(source.indexOf("if not app.staff_free_for_appointment_v47("),source.indexOf("update public.appointments"));
  assert.match(conflict,/'status','conflict'/);
  assert.doesNotMatch(conflict,/update public\.appointments/);
});

test('v48 rollback fixture covers lock ordering, truthful notification states and invalid relationships',()=>{
  assert.match(fixture,/pg_get_functiondef[\s\S]*v47 shared scheduling lock before availability/);
  assert.match(fixture,/no-link appointment must be not_applicable/);
  assert.match(fixture,/inactive identity appointment must be not_applicable/);
  assert.match(fixture,/inactive staff assignment/);
  assert.match(fixture,/foreign staff assignment/);
  assert.match(fixture,/inactive service reschedule/);
  assert.match(fixture,/unavailable reschedule result mismatch/);
  assert.match(fixture,/opt-out was not suppressed/);
  assert.match(fixture,/opted-in in-app confirmation missing/);
  assert.match(fixture,/^begin;[\s\S]*rollback;\n$/m);
});

test('v48 creates only customer-safe opted-in in-app confirmations',()=>{
  assert.match(source,/source_kind[\s\S]*'v48_appointment_reschedule'/);
  assert.match(source,/link\.state='verified'/);
  assert.match(source,/preference\.channel='in_app'[\s\S]*preference\.topic='booking_updates'[\s\S]*preference\.opted_in/);
  assert.match(source,/'Appointment time changed'/);
  assert.match(source,/'Open this business wallet to review your updated appointment\.'/);
  assert.match(source,/notification_state[\s\S]*'in_app_created'[\s\S]*'suppressed'[\s\S]*'unavailable'/);
  assert.match(source,/if app\.platform_feature_enabled\('customer_in_app_inbox'\) then\s+v_notification_state:='not_applicable'/);
  assert.doesNotMatch(source,/http|sms|whatsapp|provider receipt/i);
});

test('week and mobile calendar expose unambiguous duration-aware appointment buttons',()=>{
  assert.match(calendar,/const appointmentTimeRange=/);
  assert.match(calendar,/calendar-event-time/);
  assert.match(calendar,/height=\(to-from\)\/60\*hourHeight/);
  assert.match(calendar,/aria-current="date"/);
  assert.match(calendar,/calendarDayLabel\(a\.starts_at\)/);
  assert.match(calendar,/appointmentDuration\(a\)\} min/);
  assert.match(calendar,/aria-label="View \$\{esc\(a\.services/);
});

test('appointment detail sheet exposes authorized particulars and safe call/edit controls',()=>{
  assert.match(calendar,/role','dialog'/);
  assert.match(calendar,/CUI\.activateDialog\(dialog,\{onClose:close/);
  assert.match(calendar,/appointmentDetailTitle/);
  assert.match(calendar,/Booked price/);
  assert.match(calendar,/client\.birth_date/);
  assert.match(calendar,/Customer notes/);
  assert.match(calendar,/normalizeSingaporeCustomerPhone\(item\?\.clients\?\.phone\)/);
  assert.match(calendar,/href="tel:\$\{callNumber\}"/);
  assert.match(calendar,/Change appointment/);
  assert.match(calendar,/Confirm change/);
  assert.match(calendar,/reschedule_appointment_v48/);
  assert.match(calendar,/does not send SMS or WhatsApp/);
  const resolverSource=calendar.match(/const resolveBookedPriceCents=\(appointmentTotal,serviceTotal\)=>\{[^\n]+\};/)?.[0];
  assert.ok(resolverSource,'booked-price resolver must exist');
  const resolveBookedPriceCents=Function(`${resolverSource};return resolveBookedPriceCents`)();
  assert.equal(resolveBookedPriceCents(12500,9800),12500);
  assert.equal(resolveBookedPriceCents(0,9800),9800);
  assert.equal(resolveBookedPriceCents(null,0),null);
  assert.match(calendar,/bookedPriceCents===null\?'Not available':esc\(money\(bookedPriceCents\)\)/,
    'a zero appointment total must fall back to the positive service price instead of displaying a false complimentary booking');
});

test('calendar rows minimize PII and fetch one branch-scoped detail record on demand',()=>{
  const minimal="select('id,branch_id,service_id,starts_at,ends_at,status,staff_id,clients(full_name),services!appointments_service_id_fkey(name)')";
  assert.equal(calendar.split(minimal).length-1,2,'week and list queries must use the minimal projection');
  assert.match(calendar,/async function openAppointmentDetails\(summary\)[\s\S]*Loading customer and service information/);
  assert.match(calendar,/select\('id,branch_id,service_id,starts_at,ends_at,status,staff_id,note,total_cents,clients\(full_name,phone,phone_norm,email,birth_date,notes\),services!appointments_service_id_fkey\(name,duration_min,price_cents\)'\)[\s\S]*eq\('branch_id',summary\.branch_id\)[\s\S]*eq\('id',summary\.id\)\.maybeSingle\(\)/);
  assert.match(calendar,/const stillCurrent=detailGate\.begin\(\)[\s\S]*if\(!stillCurrent\(\)\|\|!loading\.isConnected\)\{removeLoading\(\{restoreFocus:false\}\);return\}/);
  assert.match(calendar,/Unable to load details[\s\S]*appointmentDetailRetry/);
  assert.match(calendar,/appointmentDetailRetry'\)\?\.focus\(\)/);
  assert.match(calendar,/CUI\.activateDialog\(loading,\{onClose:close[\s\S]*appointmentDetailRetry/,
    'the original focus trap and close path must remain active after replacing error content');
});

test('route changes dispose loaded and pending appointment dialogs without PII, controls or focus traps',()=>{
  const lifecycle=app.match(/let routeDispose=\(\)=>\{\};[\s\S]*?function disposeCurrentRoute\(\)\{[\s\S]*?\n\}/)?.[0];
  assert.ok(lifecycle,'route-owned disposer must be defined');
  const dialogs=[];
  const document={querySelectorAll:selector=>selector==='.appointment-detail-modal'?dialogs.filter(dialog=>dialog.isConnected):[]};
  const hooks=Function('document',`${lifecycle};return {setCleanup:cleanup=>{routeDispose=cleanup},disposeCurrentRoute}`)(document);
  const exerciseRouteChange=html=>{
    let trapActive=true,restoreAttempted=false;
    const dialog={isConnected:true,innerHTML:html,remove(){this.isConnected=false}};dialogs.push(dialog);
    hooks.setCleanup(({restoreFocus}={})=>{restoreAttempted=restoreFocus!==false;trapActive=false;dialog.remove()});
    hooks.disposeCurrentRoute();
    const connected=dialogs.filter(item=>item.isConnected);
    assert.equal(connected.length,0);
    assert.equal(trapActive,false);
    assert.equal(restoreAttempted,false);
    assert.equal(connected.some(item=>/Customer notes|Date of birth|appointmentRescheduleForm|Confirm change/.test(item.innerHTML)),false);
  };
  exerciseRouteChange('<div class="appointment-detail-modal">Customer notes Date of birth <form id="appointmentRescheduleForm">Confirm change</form></div>');
  exerciseRouteChange('<div class="appointment-detail-modal">Loading customer and service information…</div>');
  assert.match(app,/async function route\(\)\{[\s\S]{0,160}disposeCurrentRoute\(\)/);
  assert.match(app,/function renderShell\(page\)\{[\s\S]{0,160}disposeCurrentRoute\(\)/);
  assert.match(calendar,/async function appointmentsPage\(\)\{\s*disposeCurrentRoute\(\);\s*const routeMain=M\(\)/,
    'realtime direct page refresh must dispose the previous appointment route before registering a new owner');
  assert.match(calendar,/routeDispose=closeAppointmentDetails/);
  assert.match(customerUi,/return \(\{restoreFocus=true\}=\{\}\)=>\{[\s\S]*if\(restoreFocus&&returnFocus\?\.isConnected\)returnFocus\.focus\(\)/);
  assert.match(calendar,/if\(!stillCurrent\(\)\|\|!loading\.isConnected\)\{removeLoading\(\{restoreFocus:false\}\);return\}[\s\S]*removeLoading\(\);renderAppointmentDetails\(data\)/,
    'only stale/route disposal may suppress focus restoration; a successful detail transition must preserve the calendar trigger');
});

test('reschedule form prevents stale responses and restores all controls after failure or conflict',()=>{
  assert.match(calendar,/const setReschedulePending=pending=>\{[\s\S]*editForm\.setAttribute\('aria-busy',String\(pending\)\)[\s\S]*\[\.\.\.editForm\.elements\]\.forEach\(control=>\{control\.disabled=pending\}\)/);
  assert.match(calendar,/const invalidateRescheduleEdit=\(\)=>\{rescheduleGate\.invalidate\(\);setReschedulePending\(false\)/);
  assert.match(calendar,/const stillCurrent=rescheduleGate\.begin\(\);setReschedulePending\(true\)[\s\S]*await sb\.rpc\('reschedule_appointment_v48'/);
  assert.match(calendar,/if\(!stillCurrent\(\)\)\{if\(editForm\.isConnected\)setReschedulePending\(false\);return\}setReschedulePending\(false\);/);
  assert.match(calendar,/if\(error\)[\s\S]*if\(data\?\.status==='conflict'\)/);
  assert.match(calendar,/not_applicable:' No verified active customer wallet is linked to this appointment\.'/);
});

test('appointments page never performs direct appointment mutations',()=>{
  assert.doesNotMatch(calendar,/sb\.from\('appointments'\)\.(?:insert|update|upsert|delete)\s*\(/);
  assert.doesNotMatch(calendar,/\.from\('appointments'\)[\s\S]{0,140}\.(?:insert|update|upsert|delete)\s*\(/);
  assert.match(calendar,/sb\.rpc\('book_appointment_smart_v47'/);
  assert.match(calendar,/sb\.rpc\('reschedule_appointment_v48'/);
  assert.match(calendar,/sb\.rpc\('set_appointment_status_v47'/);
});
