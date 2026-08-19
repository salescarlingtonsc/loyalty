import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const app=((await readFile(new URL('../../app/index.html',import.meta.url),'utf8'))+'\n'+(await readFile(new URL('../../app/app.js',import.meta.url),'utf8')));

function section(start,end){
  const from=app.indexOf(start),to=app.indexOf(end,from);
  assert.ok(from>=0&&to>from,`missing ${start}`);
  return app.slice(from,to);
}

function permissionHarness(){
  const roleSource=app.match(/const ROLE_CAPABILITIES=\{[\s\S]*?const hasRoleCapability=[^\n]+/)?.[0];
  const compoundSource=app.match(/const FINANCE_MODULES=[\s\S]*?const filterResolvedModulesForRole=[\s\S]*?;/)?.[0];
  const readWriteSource=app.match(/const canReadModule=[\s\S]*?const canWriteModule=[\s\S]*?;/)?.[0];
  assert.ok(roleSource&&compoundSource&&readWriteSource);
  const context={S:null};
  const functions=vm.runInNewContext(
    `(()=>{${roleSource}\n${compoundSource}\n${readWriteSource};return {canReadModule,canWriteModule,hasRoleCapability}})()`,
    context
  );
  return {
    evaluate(S,module){
      context.S=S;
      return {
        read:functions.canReadModule(module),
        write:functions.canWriteModule(module),
        createSales:functions.hasRoleCapability('create_sales')
      };
    }
  };
}

test('owner, manager and frontdesk r/rw permissions preserve read while gating mutation',()=>{
  const harness=permissionHarness();
  assert.deepEqual(harness.evaluate({myRole:'owner',myModules:['services'],myModulePerms:{services:'rw'}},'services'),
    {read:true,write:true,createSales:true});
  assert.deepEqual(harness.evaluate({myRole:'owner',myModules:[],myModulePerms:{}},'services'),
    {read:false,write:false,createSales:true});
  assert.deepEqual(harness.evaluate({myRole:'manager',myModules:['services'],myModulePerms:{services:'r'}},'services'),
    {read:true,write:false,createSales:true});
  assert.deepEqual(harness.evaluate({myRole:'manager',myModules:['services'],myModulePerms:{services:'rw'}},'services'),
    {read:true,write:true,createSales:true});
  assert.deepEqual(harness.evaluate({myRole:'frontdesk',myModules:['appointments'],myModulePerms:{appointments:'r'}},'appointments'),
    {read:true,write:false,createSales:true});
  assert.deepEqual(harness.evaluate({myRole:'frontdesk',myModules:['appointments'],myModulePerms:{appointments:'rw'}},'appointments'),
    {read:true,write:true,createSales:true});
});

test('services and inventory render explicit read-only states and bind mutations only behind rw',()=>{
  const services=section('async function servicesPage(){','/* ---------- bookings ---------- */');
  const inventory=section('async function inventoryPage(){','/* ---------- packages ---------- */');
  assert.match(services,/const canWrite=canWriteModule\('services'\)/);
  assert.match(services,/Read-only services access/);
  // The Services header gained Add bundle / Add service actions alongside the import button.
  assert.match(services,/canWrite\?importBtn\('services'\)\+CUI\.action\(/);
  for(const handler of [
    /if\(canWrite\)\$\('sadd'\)\.onclick/,
    /if\(canWrite\)\$\('badd3'\)\.onclick/,
    // radd3 removed with the Resources module, which no longer exists anywhere in the app.
    /if\(canWrite\)\$\('ladd'\)\.onclick/
  ])assert.match(services,handler);
  assert.match(services,/const \{error\}=await sb\.from\('services'\)\.update[\s\S]*if\(error\)return fail\(error\)/);
  assert.match(services,/id="servicesRetry"/);

  assert.match(inventory,/const canWrite=canWriteModule\('inventory'\)/);
  /* V221 renamed the module to Products; the read-only state it guards is unchanged. */
  assert.match(inventory,/Read-only product access/);
  assert.match(inventory,/canWrite\?importBtn\('inventory'\):''/);
  assert.match(inventory,/if\(canWrite\)\$\('padd2'\)\.onclick/);
  assert.match(inventory,/if\(canWrite\)\$\('badd2'\)\.onclick/);
  assert.match(inventory,/id="inventoryRetry"/);
});

test('packages and expenses retain reads while their write actions follow the exact module matrix',()=>{
  const packages=section('async function packagesPage(){','/* ---------- branches');
  const expenses=section('async function expensesPage(){','/* ---------- P&L ---------- */');
  assert.match(packages,/const canWrite=canWriteModule\('packages'\)/);
  assert.match(packages,/if\(canWrite\)\{[\s\S]*\$\('kadd'\)\.onclick/);
  /* V285 retarget: the canSell capability gate and the #ksell handler it guarded are both GONE,
     because the control they protected has not existed since selling a package moved into the
     till — no markup here or in index.html renders #ksell, #kc, #kk or #kSaleBranch. The pin now
     asserts the absence, which is the state the role matrix actually needs: there is no
     unguarded sell control on this page, and the guarded one is not merely unbound. */
  assert.doesNotMatch(packages,/\$\('ksell'\)/);
  assert.doesNotMatch(packages,/const canSell=/);
  assert.doesNotMatch(packages,/sb\.rpc\('sell_package_v102'/,
    'the removed handler held this page\'s only sell call; the till keeps its own');
  assert.match(packages,/canWrite&&k\.remaining>0/);
  assert.match(packages,/canWrite&&x\.can_reverse/);
  assert.match(packages,/id="packagesRetry"/);

  assert.match(expenses,/const canWrite=canWriteModule\('expenses'\)/);
  assert.match(expenses,/require_module_scope_v145/);
  assert.doesNotMatch(expenses,/get_revenue_summary/);
  assert.match(expenses,/Read-only expenses access/);
  assert.match(expenses,/if\(canWrite\)\$\('exAdd'\)\.onclick/);
  /* V285 retarget: Void is still the same canWrite-gated control; it is now preceded by the
     equally gated Edit, so the pin follows the pair rather than the exact adjacency. */
  assert.match(expenses,/canWrite\?`<button class="btn ghost sm" onclick="editExpenseV285/);
  assert.match(expenses,/<button class="btn danger sm" onclick="voidExp/);
  assert.match(expenses,/id="expensesRetry"/);
});

test('global appointment, setup, and booking decision controls match their mutation authority',()=>{
  const global=section('function globalActionsHtml(){','function wireGlobalActions(){');
  const route=section('async function route(){','/* ---------- customer wallet ---------- */');
  const profile=section('function profileHtml(){','function wireProfile(page){');
  const bookings=section('async function bookingsPage(){','/* ---------- grow recommender');
  assert.match(global,/const canViewAppts=canReadModule\('appointments'\)/);
  assert.match(global,/const canNewAppt=canWriteModule\('appointments'\)/);
  assert.match(global,/const canQuickEarn=canReadModule\('till'\)&&canReadModule\('clients'\)&&hasRoleCapability\('create_sales'\)/);
  assert.match(global,/canNewAppt\?'New appointment':'View calendar'/);
  assert.match(route,/pageKey==='setup'&&S\.myRole!=='owner'/);
  assert.match(profile,/S\.myRole==='owner'\?`<a href="#\/setup"/);
  /* V288 (audit A2 HIGH 1): RETARGETED, not deleted. Confirming a booking request is a
     BOOKINGS right — the fnb and bar sectors hold no appointments module at all, so gating
     confirmation on it left them able only to decline their own public page's requests. */
  assert.match(bookings,/const canConvertBooking=canWriteModule\('bookings'\)/);
  assert.match(bookings,/const canDeclineBooking=canWriteModule\('bookings'\)/);
  assert.match(bookings,/const canDecideChange=canWriteModule\('appointments'\)/);
  /* V325 (owner-authorized relocation, 2026-08-14 Customer Interface cosmetics brief): the
     auto-approve control (and its non-owner readout) moved to Customer Interface > Appointment
     Setting; Bookings keeps only a value readout + pointer link, for every role. */
  assert.match(bookings,/Auto-approve is \$\{S\.biz\.auto_approve_changes\?'on':'off'\}\. Change this in/);
  const bookingRulesRoleMatrix=section('function bookingRulesCardHtmlV325(){','function wireBookingRulesV325(');
  assert.match(bookingRulesRoleMatrix,/Only the owner can change this setting/);
  assert.match(bookings,/staff_decide_booking_request_v73/);
  assert.match(bookings,/decision==='confirm'\?canConvertBooking:decision==='decline'\?canDeclineBooking/);
  assert.doesNotMatch(bookings,/from\('booking_requests'\)\.update/);
  assert.match(bookings,/window\.decideCr=canDecideChange\?/);
});

test('multi-workspace choices are stable, complete, and never pick staff zero',()=>{
  const sortSource=app.match(/function sortStaffWorkspaces\([^\n]*\)\{[\s\S]*?\n\}/)?.[0];
  assert.ok(sortSource);
  const sort=vm.runInNewContext(`(${sortSource})`);
  const sorted=sort([
    {business_name:'Zulu',business_slug:'zulu'},
    {business_name:'Alpha',business_slug:'beta'},
    {business_name:'Alpha',business_slug:'alpha'}
  ]);
  assert.equal(JSON.stringify(sorted.map(item=>item.business_slug)),JSON.stringify(['alpha','beta','zulu']));
  const persona=section('function renderPersonaChoice(personas,{includeCustomer=true}={})','function renderAuth(');
  const customerSwitch=section('function customerWorkspaceSwitchHtml(','function renderNoCustomerDestination(');
  assert.match(persona,/staff\.map\(workspace=>/);
  assert.doesNotMatch(persona,/staff\[0\]/);
  assert.match(customerSwitch,/workspaces\.map\(workspace=>/);
  assert.match(customerSwitch,/aria-label="Open \$\{workspaces\.length\} authorized staff workspaces"/);
  assert.doesNotMatch(customerSwitch,/staff\[0\]/);
});
