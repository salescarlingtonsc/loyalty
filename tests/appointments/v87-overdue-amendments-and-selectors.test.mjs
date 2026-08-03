import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../../',import.meta.url);
const app=await readFile(new URL('app/index.html',root),'utf8');
const source=await readFile(new URL('db/migrations/20260726_nestly_v87_overdue_appointment_amendments.sql',root),'utf8');
const deploy=await readFile(new URL('supabase/migrations/20260726220000_nestly_v87_overdue_appointment_amendments.sql',root),'utf8');
const fixture=await readFile(new URL('db/tests/v87_overdue_appointment_amendments.sql',root),'utf8');
const calendar=app.slice(app.indexOf('async function appointmentsPage()'),app.indexOf('/* ---------- waitlist ---------- */'));

test('v87 source and deploy migrations are identical and preserve the future target guard',()=>{
  assert.equal(source,deploy);
  assert.match(source,/v_appointment\.status<>''booked'' or v_appointment\.starts_at<=clock_timestamp\(\)/);
  assert.match(source,/v_new_guard[\s\S]*v_appointment\.status<>''booked'' then/);
  assert.match(source,/revoke all privileges[\s\S]*grant execute[\s\S]*to authenticated/);
  assert.match(source,/notify pgrst, 'reload schema';[\s\S]*commit;/);
});

test('v87 rollback suite behaviorally invokes the RPC across success, rejection and replay boundaries',()=>{
  assert.match(fixture,/^begin;[\s\S]*rollback;\n$/m);
  assert.match(fixture,/v_overdue_start timestamptz:=clock_timestamp\(\)-interval '3 hours'/);
  assert.match(fixture,/v_future_target timestamptz:=clock_timestamp\(\)\+interval '4 days'/);
  assert.match(fixture,/v_first:=public\.reschedule_appointment_v48\(/);
  assert.match(fixture,/v_replay:=public\.reschedule_appointment_v48\(/);
  assert.match(fixture,/past amendment target[\s\S]*'22023'/);
  assert.match(fixture,/completed appointment[\s\S]*cancelled appointment[\s\S]*no-show appointment/);
  assert.match(fixture,/out-of-scope branch amendment[\s\S]*'42501'/);
  assert.match(fixture,/foreign-tenant amendment[\s\S]*'42501'/);
  assert.match(fixture,/same-key replay did not return the original outcome/);
  assert.match(fixture,/changed payload with reused idempotency key[\s\S]*'22023'/);
  assert.match(fixture,/v87_operation_count\(f\.business_id,v_key\)<>1/);
  assert.match(fixture,/v87_audit_count\(f\.business_id,f\.overdue_appointment\)<>1/);
});

test('booked appointments expose direct, prefilled amendments including overdue records',()=>{
  assert.match(calendar,/const amendableBooked=item\.status==='booked'&&canWrite/);
  assert.match(calendar,/data-appointment-amend/);
  assert.match(calendar,/openAppointmentDetails\(item,\{startEditing:true\}\)/);
  assert.match(calendar,/if\(startEditing\)\{editForm\.hidden=false/);
  assert.match(calendar,/This booked appointment is overdue\. You can move it to a future slot/);
  assert.match(calendar,/The new start must be in the future/);
  assert.match(calendar,/sb\.rpc\('reschedule_appointment_v48'/);
});

test('customer and staff selectors are duplicate-safe without exposing unique staff contacts',()=>{
  assert.match(calendar,/clients'\)\.select\('id,full_name,phone,phone_norm,email',\{count:'exact'\}\)/);
  assert.match(calendar,/placeholder="Search name or phone"/);
  assert.match(calendar,/customerLabel\(client\)/);
  assert.match(calendar,/customerMatches\(client,query\)/);
  assert.match(calendar,/staffNameCounts/);
  assert.match(calendar,/if\(\(staffNameCounts\[key\]\|\|0\)<2\)return name/);
  assert.match(calendar,/const contact=String\(person\?\.phone\|\|person\?\.email/);
  assert.match(calendar,/esc\(staffLabel\(person\)\)/);
});
