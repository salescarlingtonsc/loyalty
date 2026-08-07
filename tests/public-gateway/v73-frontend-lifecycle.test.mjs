import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const app=((await readFile(new URL('../../app/index.html',import.meta.url),'utf8'))+'\n'+(await readFile(new URL('../../app/app.js',import.meta.url),'utf8')));

function section(start,end){
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0&&to>from,`missing ${start}`);
  return app.slice(from,to);
}

test('route generation rejects an older workspace resolution before it can commit state',async()=>{
  const source=app.match(/let routeRenderEpoch=0;[^\n]*\n(?:let [^\n]+\n)*const beginRouteInvocation=\(\)=>\{[\s\S]*?\n\};/)?.[0];
  assert.ok(source);
  const {beginRouteInvocation}=vm.runInNewContext(`(()=>{${source};return {beginRouteInvocation}})()`);
  const committed=[];
  let releaseOld;
  const oldPending=new Promise(resolve=>{releaseOld=resolve});
  const run=async(isCurrent,pending,value)=>{
    await pending;
    if(!isCurrent())return;
    committed.push(value);
  };
  const oldCurrent=beginRouteInvocation();
  const oldRun=run(oldCurrent,oldPending,'old workspace');
  const newCurrent=beginRouteInvocation();
  await run(newCurrent,Promise.resolve(),'new workspace');
  releaseOld();
  await oldRun;
  assert.deepEqual(committed,['new workspace']);
});

test('workspace, business, module, persona, and profile awaits are generation guarded',()=>{
  const route=section('async function route(){','/* ---------- customer wallet ---------- */');
  for(const guarded of [
    /get_my_personas'\);\s*if\(!isRouteCurrent\(\)\)return;\s*S\.staffWorkspaces=/,
    /from\('businesses'\)\.select\('\*'\)\.eq\('slug',workspaceSlug\)\.single\(\);\s*if\(!isRouteCurrent\(\)\)return;/,
    /get_my_modules',\{p_business:S\.biz\.id\}\);\s*if\(!isRouteCurrent\(\)\)return;/,
    /from\('staff'\)\.select\('role,modules,module_perms'\)[\s\S]*?limit\(1\);\s*if\(!isRouteCurrent\(\)\)return;/,
    /loadCustomerFeatureCapabilities\(\);\s*if\(!isRouteCurrent\(\)\)return;/,
    /customer_get_profile'\);\s*if\(!isRouteCurrent\(\)\)return;/
  ])assert.match(route,guarded);
  assert.match(route,/catch\(e\)\{\s*if\(!isRouteCurrent\(\)\)return;/);
});

test('owners cannot see or mutate a disabled module while owner-only special pages remain explicit',()=>{
  const source=app.match(/const canReadModule=[\s\S]*?const canWriteModule=[\s\S]*?;/)?.[0];
  const roleSource=app.match(/const ROLE_CAPABILITIES=\{[\s\S]*?const hasRoleCapability=[^\n]+/)?.[0];
  const compoundSource=app.match(/const FINANCE_MODULES=[\s\S]*?const filterResolvedModulesForRole=[\s\S]*?;/)?.[0];
  assert.ok(source&&roleSource&&compoundSource);
  const evaluate=modules=>vm.runInNewContext(`(()=>{const S={myRole:'owner',myModules:${JSON.stringify(modules)},myModulePerms:{appointments:'rw'}};${roleSource};${compoundSource};${source};return [canReadModule('appointments'),canWriteModule('appointments')]})()`);
  assert.equal(JSON.stringify(evaluate([])),JSON.stringify([false,false]));
  assert.equal(JSON.stringify(evaluate(['appointments'])),JSON.stringify([true,true]));
  const route=section('async function route(){','/* ---------- customer wallet ---------- */');
  for(const page of ['settings','branches','setup','studio']){
    assert.match(route,new RegExp(`pageKey==='${page}'&&S\\.myRole!=='owner'`));
  }
  assert.match(route,/if\(pageKey==='storedvalue'\)[\s\S]*Stored value is not available for launch/);
  const global=section('function globalActionsHtml(){','function wireGlobalActions(){');
  assert.match(global,/canViewAppts\?`<button[\s\S]*canNewAppt\?'New appointment':'View calendar'/);
});

test('staff-only multi-workspace business entry and shell use the same complete stable list',()=>{
  const route=section('async function route(){','/* ---------- customer wallet ---------- */');
  assert.match(route,/if\(h==='#\/business'\)[\s\S]*const staff=sortStaffWorkspaces\(businessPersonas\?\.staff\|\|\[\]\)/);
  assert.match(route,/if\(staff\.length>1\)return renderPersonaChoice\(businessPersonas,\{includeCustomer:false\}\)/);
  assert.doesNotMatch(route,/from\('staff'\)\.select\('business_id'\)[\s\S]*?limit\(1\)/);
  assert.match(route,/S\.staffWorkspaces=staff/);
  const persona=section('function renderPersonaChoice(personas,{includeCustomer=true}={})','function renderAuth(');
  assert.match(persona,/const staff=sortStaffWorkspaces/);
  assert.match(persona,/staff\.map\(workspace=>/);
  assert.match(persona,/const hasCustomer=includeCustomer&&/);
  const shell=section('function renderShell(page){','const M=');
  assert.match(shell,/businessWorkspaceSwitchHtml\(S\.staffWorkspaces,S\.biz\.slug,S\.hasCustomerPersona\)/);
});

test('v73 staff decisions are authority-gated, duplicate-safe, state-aware, and truthfully refreshed',()=>{
  const bookings=section('async function bookingsPage(){','/* ---------- grow recommender');
  assert.match(bookings,/STAFF_BOOKING_DECISION_STATUSES\.has\(b\.status\)/);
  assert.match(bookings,/pendingDecisions\.has\(id\)/);
  assert.match(bookings,/button=>button\.disabled=true/);
  assert.match(bookings,/staff_decide_booking_request_v73',\{\s*p_business:S\.biz\.id,p_request:id,p_decision:decision,p_branch:null/);
  assert.match(bookings,/decision==='confirm'\?canConvertBooking:decision==='decline'\?canDeclineBooking/);
  assert.match(bookings,/bookingDecisionNotice\(data,decision\)/);
  assert.match(bookings,/await load\(\)/);
  assert.doesNotMatch(bookings,/from\('booking_requests'\)\.update/);

  const source=app.match(/function bookingDecisionNotice\([^\n]*\)\{[\s\S]*?\n\}/)?.[0];
  const notice=vm.runInNewContext(`(${source})`);
  assert.deepEqual(
    JSON.parse(JSON.stringify(notice({outcome:'applied',actual_status:'confirmed'},'confirm'))),
    {ok:true,text:'Confirm applied. Current status: confirmed.'}
  );
  assert.match(notice({outcome:'capacity_conflict',actual_status:'waitlisted'},'confirm').text,/capacity conflict.*waitlisted/i);
  assert.match(notice({outcome:'replayed',actual_status:'declined',replayed:true},'decline').text,/already applied.*declined/i);
});

test('linked waitlist decisions never directly mutate queue status or claim a seat without an appointment',()=>{
  const waitlist=section('async function waitlistPage(){','/* ---------- inventory ---------- */');
  assert.match(waitlist,/if\(w\.booking_request_id\)\{/);
  assert.match(waitlist,/staff_decide_booking_request_v73/);
  assert.match(waitlist,/Confirm appointment/);
  assert.match(waitlist,/Decline request/);
  assert.match(waitlist,/if\(row\?\.booking_request_id\)\{[\s\S]*must be decided with Confirm or Decline/);
  assert.match(waitlist,/w\.booking_request_id\?'<span class="pill new">Linked booking/);
  assert.match(waitlist,/Linked booking requests must be confirmed into a real appointment/);
  assert.match(waitlist,/Appointment form opened — the walk-in is still waiting until a booking is completed/);
  assert.doesNotMatch(waitlist,/window\.wlBook=[\s\S]{0,240}updateWl\(id,'booked'\)/);
});

test('customer booking requests split active from recent terminal outcomes and Home counts active only',()=>{
  const source=app.match(/const ACTIVE_CUSTOMER_BOOKING_REQUEST_STATUSES=[\s\S]*?function composeCustomerBookingGroups\([^\n]*\)\{[\s\S]*?\n\}/)?.[0];
  assert.ok(source);
  const {compose,isActive}=vm.runInNewContext(`(()=>{${source};return {compose:composeCustomerBookingGroups,isActive:isActiveCustomerBookingRequest}})()`);
  const groups=compose([],{items:[
    {request_id:'a',business_slug:'one',business_name:'One',status:'pending'},
    {request_id:'b',business_slug:'one',business_name:'One',status:'declined'},
    {request_id:'c',business_slug:'one',business_name:'One',status:'expired'},
    {request_id:'d',business_slug:'one',business_name:'One',status:'cancelled'}
  ]},[]);
  assert.equal(groups[0].activeRequests.length,1);
  assert.equal(groups[0].recentRequests.length,3);
  assert.equal([{status:'pending'},{status:'declined'}].filter(isActive).length,1);
  const bookings=section('async function renderCustomerBookings(){','async function renderCustomerMessages(){');
  // v178 (owner sketch): the same composed groups are now split across Bookings | Cancelled |
  // History tabs, so the page reads tabRequests/tabAppointments rather than the raw buckets.
  assert.match(bookings,/Earlier request updates/);
  assert.match(bookings,/Cancelled requests/);
  assert.match(bookings,/group\.tabRequests/);
  assert.match(bookings,/group\.tabAppointments/);
  assert.match(bookings,/customerBookingTabGroupsV178\(allGroups,currentBookingTab,currentBookingWindow\)/);
  assert.match(app,/bookingRequestResult\.data\.items\.filter\(isActiveCustomerBookingRequest\)\.length/);
});
