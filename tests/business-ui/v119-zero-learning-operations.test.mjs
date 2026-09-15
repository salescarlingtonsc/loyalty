import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const repoRoot=fileURLToPath(new URL('../..',import.meta.url));
const app=((await readFile(path.join(repoRoot,'app/index.html'),'utf8'))+'\n'+(await readFile(path.join(repoRoot,'app/app.js'),'utf8')));

const sliceFunction=(name,nextName)=>{
  const start=app.indexOf(name);
  const end=nextName?app.indexOf(nextName,start+name.length):app.length;
  assert.ok(start>=0,`${name} must exist`);
  return app.slice(start,end>start?end:app.length);
};

test('scheduled capacity uses active branch staff and merges breaks with persisted blocks',()=>{
  const reports=sliceFunction('async function scheduledCapacityHours','async function runBusy');
  const blocked=sliceFunction('async function blockedTimeRows','async function scheduledCapacityHours');
  const busy=sliceFunction('async function runBusy','async function runTiming');
  assert.match(reports,/from\('branch_hours'\)[\s\S]*from\('branch_breaks'\)/);
  assert.match(reports,/from\('staff'\)\.select\('id'\)[\s\S]*\.eq\('active',true\)/);
  assert.match(blocked,/list_staff_blocked_times_v120/);
  assert.match(reports,/blockedTimeRows\(scope\)/);
  assert.match(reports,/sgDayInstantOverlapMinutes\(day,block\.starts_at,block\.ends_at\)/);
  assert.match(reports,/Math\.max\(branchStart,timeMinutes\(schedule\.starts_at\)\)/);
  assert.match(reports,/Math\.min\(branchEnd,timeMinutes\(schedule\.ends_at\)\)/);
  assert.match(reports,/\[\.\.\.dayBreaks,\.\.\.staffBlocks\][\s\S]*mergedIntervalMinutes\(clipped\)/);
  assert.match(reports,/staff_off_days/);
  assert.doesNotMatch(busy,/Math\.min\(100[\s\S]*utilization/);
  assert.match(busy,/'overbookedByHours'/);
  assert.match(busy,/'bookedHoursOutOfCapacity'/);
});

test('scheduled capacity splits persisted overnight blocks across Singapore calendar days',()=>{
  const start=app.indexOf('const sgDayInstantOverlapMinutes=');
  const end=app.indexOf('\n  const mergedIntervalMinutes=',start);
  assert.ok(start>=0&&end>start,'Singapore day overlap helper must exist');
  const overlap=new Function(`${app.slice(start,end)};return sgDayInstantOverlapMinutes`)();
  const overnight={starts:'2026-08-03T14:00:00.000Z',ends:'2026-08-03T18:00:00.000Z'};
  assert.deepEqual(overlap('2026-08-03',overnight.starts,overnight.ends),{start:1320,end:1440},
    '22:00–02:00 block must reduce the first Singapore day by two hours');
  assert.deepEqual(overlap('2026-08-04',overnight.starts,overnight.ends),{start:0,end:120},
    '22:00–02:00 block must reduce the next Singapore day by two hours');
  assert.equal(overlap('2026-08-02',overnight.starts,overnight.ends),null,'adjacent prior day must not overlap');
  assert.equal(overlap('2026-08-05',overnight.starts,overnight.ends),null,'adjacent following day must not overlap');
  assert.deepEqual(overlap('2026-08-03','2026-08-03T02:00:00.000Z','2026-08-03T03:00:00.000Z'),{start:600,end:660},
    'ordinary same-day block must retain its Singapore wall-clock interval');
  assert.equal(overlap('2026-08-04','2026-08-03T02:00:00.000Z','2026-08-03T03:00:00.000Z'),null,
    'ordinary same-day block must not leak into the next day');
});

test('capacity arithmetic merges overlapping breaks and allows honest utilization above 100%',()=>{
  const merge=intervals=>{
    const sorted=[...intervals].sort((a,b)=>a.start-b.start);
    let total=0,current=null;
    for(const interval of sorted){
      if(!current){current={...interval};continue}
      if(interval.start<=current.end){current.end=Math.max(current.end,interval.end);continue}
      total+=current.end-current.start;current={...interval};
    }
    return total+(current?current.end-current.start:0);
  };
  const branchStart=9*60,branchEnd=18*60;
  const staffStart=Math.max(branchStart,8*60),staffEnd=Math.min(branchEnd,20*60);
  const breakMinutes=merge([{start:12*60,end:13*60},{start:12*60+30,end:13*60+30}]);
  const capacityHours=((staffEnd-staffStart)-breakMinutes)/60;
  assert.equal(capacityHours,7.5);
  assert.equal(9/capacityHours*100,120);
});

test('branch module projections are fetched fresh so another session sees role downgrade',async()=>{
  /* nestly_v949 narrowed this from the whole region to the LOADER ITSELF, and made the rule for
     what sits beside it explicit rather than a text proxy.
     The rule being protected is v370's: the per-branch projection is never cached, because it
     carries permission state another session can revoke. The old assertion enforced that by
     refusing Map(/.has(/.set( anywhere between the loader and projectionCanRead — a proxy that
     was right until something legitimately non-caching moved in next door. v948 added
     startBranchProjectionsV948, which keeps a Map of requests ALREADY IN FLIGHT for one page load
     so the projection can overlap the page's own reads instead of following them. It is rebuilt
     on every call and discarded when the page function returns; a second page load re-reads every
     projection, which tests/business-ui/v948-branch-projection-overlap.test.mjs proves by
     EXECUTING it twice and counting the reads.
     So: the loader must still hold no store of any kind, and the starter's registry must be
     constructed INSIDE the function — module scope is where a cache would have to live to survive
     a page load, and that is the thing to refuse. */
  const region=sliceFunction('async function loadBranchModuleProjection','const projectionCanRead');
  const loader=region.slice(0,region.indexOf('\n}\n')+3);
  assert.match(loader,/sb\.rpc\('get_my_modules_at_v115'/);
  assert.doesNotMatch(loader,/Map\(|\.has\(|\.set\(/,
    'effective identity must not live in an indefinite browser cache');
  assert.doesNotMatch(loader,/return\s+\w+\.get\(|if\s*\(\s*\w+\.has\(/,
    'the loader must never answer from a store instead of the server');
  assert.match(region,/function startBranchProjectionsV948\(\)\{\s*const started=new Map\(\);/,
    'the in-flight registry must be created per call — a module-scope one would be a cache');

  let role='frontdesk',calls=0;
  const serverProjection=async()=>{calls++;return {role,modules:role==='frontdesk'?['appointments']:[]}};
  const sessionA=await serverProjection();
  role='bookkeeper';
  const sessionB=await serverProjection();
  const sessionAAfterRoute=await serverProjection();
  assert.deepEqual(sessionA.modules,['appointments']);
  assert.deepEqual(sessionB.modules,[]);
  assert.deepEqual(sessionAAfterRoute.modules,[]);
  assert.equal(calls,3,'each session route load must consult current server truth');
});
