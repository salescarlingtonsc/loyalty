import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../..',import.meta.url);
const [app,migration,mirror,sqlFixture,concurrencyFixture,visual,ledger,trace,fixtures]=await Promise.all([
  Promise.all([readFile(new URL('app/index.html',root),'utf8'),readFile(new URL('app/app.js',root),'utf8')]).then(f=>f.join('\n')),
  readFile(new URL('db/migrations/20260731_nestly_v120_staff_blocked_times.sql',root),'utf8'),
  readFile(new URL('supabase/migrations/20260731120000_nestly_v120_staff_blocked_times.sql',root),'utf8'),
  readFile(new URL('db/tests/v120_staff_blocked_times.sql',root),'utf8'),
  readFile(new URL('db/tests/v120_staff_blocked_times_concurrency.sh',root),'utf8'),
  readFile(new URL('tests/browser/v120-staff-blocked-times-visual.html',root),'utf8'),
  readFile(new URL('docs/qa/OWNER-ISSUE-LEDGER.md',root),'utf8'),
  readFile(new URL('docs/qa/TRACEABILITY-MATRIX.md',root),'utf8'),
  readFile(new URL('docs/qa/REALISTIC-FIXTURES.md',root),'utf8')
]);

const between=(source,start,end)=>{
  const from=source.indexOf(start),to=source.indexOf(end,from+start.length);
  assert.ok(from>=0,`missing ${start}`);
  assert.ok(to>from,`missing ${end}`);
  return source.slice(from,to);
};

test('Appointments owns blocked-time authoring without a new module or navigation item',()=>{
  const appointments=between(app,'async function appointmentsPage(){','/* ---------- waitlist');
  const moduleMap=between(app,'const MODULES=','const ROLE_LABELS=');
  assert.match(appointments,/id="openBlockTime"[\s\S]{0,120}CUI\.icon\('staff',\{size:20\}\)\} Block time/);
  assert.match(appointments,/function openBlockedTimeDialog/);
  assert.match(appointments,/id="blockTimeStaff"/);
  assert.match(appointments,/id="blockTimeDate"/);
  assert.match(appointments,/id="blockTimeStart"/);
  assert.match(appointments,/id="blockTimeEnd"/);
  assert.match(appointments,/id="blockTimeReason" maxlength="160"/);
  assert.match(appointments,/create_staff_blocked_time_v120/);
  assert.match(appointments,/delete_staff_blocked_time_v120/);
  assert.doesNotMatch(moduleMap,/blocked.?time/i);
});

test('calendar load, retry, refresh projection, empty team and read-only states are explicit',()=>{
  const appointments=between(app,'async function appointmentsPage(){','/* ---------- waitlist');
  assert.match(appointments,/list_staff_blocked_times_v120/);
  assert.match(appointments,/Promise\.all\(\[[\s\S]*appointmentResult[\s\S]*blockResult/);
  assert.match(appointments,/Calendar unavailable/);
  assert.match(appointments,/id="calendarRetry">Try again/);
  assert.match(appointments,/No team member assigned/);
  assert.match(appointments,/if\(canWrite\)\{[\s\S]*\$\('openBlockTime'\)\.onclick/);
  assert.match(appointments,/canWrite&&block\.id\?/,
    'read-only and cross-branch blocks must not expose Remove');
  assert.match(appointments,/Busy at another branch/);
});

test('day availability and reporting consume the same persisted blocks',()=>{
  const appointments=between(app,'async function appointmentsPage(){','/* ---------- waitlist');
  const blockedReports=between(app,'async function blockedTimeRows','async function scheduledCapacityHours');
  const reports=between(app,'async function scheduledCapacityHours','async function runBusy');
  assert.match(appointments,/const hitsBlockedTime=column\.blocks\.some/);
  assert.match(appointments,/intervalsOverlap\(occupiedStart,occupiedEnd,blockStart,blockEnd\)/);
  assert.match(appointments,/day-blocked-window/);
  assert.match(blockedReports,/list_staff_blocked_times_v120/);
  assert.match(reports,/blockedTimeRows\(scope\)/);
  assert.match(reports,/\[\.\.\.dayBreaks,\.\.\.staffBlocks\]/);
  assert.match(reports,/mergedIntervalMinutes\(clipped\)/);

  const merged=intervals=>{
    const sorted=[...intervals].sort((a,b)=>a.start-b.start);
    let total=0,current=null;
    for(const interval of sorted){
      if(!current){current={...interval};continue}
      if(interval.start<=current.end){current.end=Math.max(current.end,interval.end);continue}
      total+=current.end-current.start;current={...interval};
    }
    return total+(current?current.end-current.start:0);
  };
  const unavailable=merged([
    {start:12*60+30,end:13*60+30},
    {start:13*60,end:14*60},
    {start:15*60,end:16*60}
  ]);
  assert.equal(unavailable,150,'overlapping break/block time is subtracted once');
  assert.equal((9*60-unavailable)/60,6.5);
});

test('server writers are replay-safe and serialize overlapping block/appointment writes',()=>{
  assert.equal(mirror,migration,'canonical V120 mirror must be byte-identical');
  assert.match(migration,/staff_blocked_time_operations_v120/);
  assert.match(migration,/primary key \(business_id,actor,operation_type,idempotency_key\)/);
  assert.match(migration,/request_hash text not null/);
  assert.match(migration,/idempotency key reused with different blocked time/);
  assert.match(migration,/v120:staff-calendar:'\|\|p_business::text\|\|':'\|\|p_staff::text/);
  assert.match(migration,/v120:block-delete:/);
  assert.match(migration,/this time is already blocked[\s\S]*errcode='23P01'/);
  assert.match(migration,/an appointment or its buffer already uses this time/);
  assert.match(migration,/zz_appointments_guard_staff_blocked_time_v120/);
  assert.match(migration,/app\.staff_free_for_appointment_v47\([\s\S]*new\.starts_at,new\.ends_at,new\.id/);
  assert.match(migration,/p_idempotency_key text/);
});

test('availability is staff-wide across branches, buffer-aware, and missing hours fail closed',()=>{
  const availability=between(migration,
    'create or replace function app.staff_free_for_appointment_v47',
    'create or replace function app.guard_staff_blocked_time_v120');
  assert.match(availability,/v_block_start:=p_starts-make_interval/);
  assert.match(availability,/v_block_end:=p_ends\+make_interval/);
  assert.match(availability,/not exists \([\s\S]*public\.branch_hours/);
  assert.match(availability,/not exists \([\s\S]*public\.staff_hours/);
  assert.match(availability,/blocked\.business_id=p_business and blocked\.staff_id=p_staff/);
  assert.doesNotMatch(availability,/blocked\.branch_id=p_branch/);

  const create=between(migration,
    'create or replace function public.create_staff_blocked_time_v120',
    'create or replace function public.delete_staff_blocked_time_v120');
  assert.match(create,/appointment\.business_id=p_business[\s\S]*appointment\.staff_id=p_staff/);
  assert.doesNotMatch(create,/appointment\.branch_id=p_branch/);
  assert.match(create,/char_length\(btrim\(coalesce\(p_reason,''\)\)\) > 160/);
});

test('delete retains a complete audit snapshot and never exposes table access',()=>{
  assert.match(migration,/STAFF_TIME_UNBLOCK[\s\S]*'staff_id',v_block\.staff_id[\s\S]*'starts_at',v_block\.starts_at[\s\S]*'ends_at',v_block\.ends_at[\s\S]*'reason',v_block\.reason/);
  assert.match(migration,/alter table public\.staff_blocked_times enable row level security/);
  assert.match(migration,/revoke all privileges on table public\.staff_blocked_times[\s\S]*from public,anon,authenticated/);
  assert.doesNotMatch(migration,/create policy .*staff_blocked_times/i);
});

test('durable QA memory records the exact SPA-GLOW acceptance and only legal lifecycle state',()=>{
  assert.match(ledger,/\| `APPT-BLOCK-001` \|[\s\S]*\| `VERIFIED_LOCAL` \|/);
  assert.match(trace,/\| `APPT-BLOCK-001` \|[\s\S]*Supplier training[\s\S]*\| `VERIFIED_LOCAL` \|/);
  assert.match(fixtures,/Supplier training/);
  assert.match(fixtures,/31 July 2026 from 14:00–15:00 Singapore time/);
});

test('disposable SQL fixture approves the synthetic V94 workspace before exercising module writers',()=>{
  assert.match(sqlFixture,/update public\.business_workspace_controls_v94[\s\S]*approval_status='approved'/);
  assert.match(sqlFixture,/where business_id=v_business and approval_status='pending'/);
  assert.match(sqlFixture,/if not found then[\s\S]*fixture workspace control was not pending/);
});

test('two-session fixture races block against block and direct appointment writers',()=>{
  assert.match(concurrencyFixture,/V120_CONFIRM_DISPOSABLE_DB/);
  assert.match(concurrencyFixture,/DATABASE_URL and PGPASSWORD are required/);
  assert.match(concurrencyFixture,/gadpooereceldfpfxsod/);
  assert.match(concurrencyFixture,/its name must contain v120_concurrency/);
  assert.match(concurrencyFixture,/Drop the entire dedicated v120_concurrency database now/);
  assert.doesNotMatch(concurrencyFixture,/delete from public\.businesses/);
  assert.match(concurrencyFixture,/application_name='\$app_name' and wait_event='PgSleep'/);
  assert.match(concurrencyFixture,/block-vs-block race did not serialize to one winner/);
  assert.match(concurrencyFixture,/block-vs-appointment race did not serialize to the block winner/);
  assert.match(concurrencyFixture,/appointment-vs-block reverse race did not serialize to the appointment winner/);
  assert.match(concurrencyFixture,/2\|1\|2\|2/);
});

test('390px layout keeps both appointment actions full width and timeline horizontally scrollable',()=>{
  assert.match(app,/@media\(max-width:560px\)[^{]*\{[\s\S]*\.appointment-primary-action \.btn\{width:100%\}/);
  assert.match(app,/\.day-timeline-scroll\{[^}]*overflow:auto/);
  assert.match(app,/\.day-blocked-window\{[^}]*min-height:44px/);
  assert.match(app,/\.day-blocked-window button\{[^}]*min-width:44px;min-height:44px/);
  for(const state of ['modal','save-error','remove-error','readonly','empty','error']){
    assert.match(visual,new RegExp(`state==='${state}'`));
  }
  assert.match(visual,/Chen Wei/);
  assert.match(visual,/Aisha Rahman/);
  assert.match(visual,/Supplier training/);
});
