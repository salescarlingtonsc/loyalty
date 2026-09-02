/* F013 — Reminder & Notification (#/remindernotify) was unreachable for every tenant,
 * including the owner. It was gated on the pseudo-module 'settings' via
 * SURFACE_MODULE_ALIAS_V584, and 'settings' is never in any account's resolved module list
 * (get_my_modules resolves through app.staff_module_perms_at_v115, whose key universe is
 * businesses.enabled_modules ∪ platform_module_overrides_v94 — neither ever holds 'settings',
 * and it is not a module_registry key at all). So canReadModule('settings') was false for
 * every principal, and the route bounced everyone, owner included.
 *
 * The fix mirrors how Settings/Branches/Customer Interface/Program Studio are actually
 * gated: by role, not by a module key nobody holds. 'remindernotify' now sits in
 * OWNER_ONLY_MODULES (so the generic module gate skips it) plus an explicit
 * `pageKey==='remindernotify'&&S.myRole!=='owner'` refusal, and navModuleVisible carries a
 * matching `m==='remindernotify'&&S.myRole==='owner'` branch for the rail row. The
 * 'remindernotify':'settings' alias entry is gone.
 *
 * This test EXECUTES the real router guard and the real rail filter, lifted verbatim out of
 * app/app.js, against a standard fnb sector module bundle (no 'settings' entry — matching
 * production, where no tenant has one) — a source grep would have stayed green through the
 * whole outage, because SURFACE_MODULE_ALIAS_V584 and the module gate were both "correctly
 * shaped" code, just wired to a key that can never be granted.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const here=path.dirname(fileURLToPath(import.meta.url));
const repo=path.resolve(here,'../..');
const app=fs.readFileSync(path.join(repo,'app/app.js'),'utf8');

function section(start,end){
  const from=app.indexOf(start);
  assert.notEqual(from,-1,`missing start marker: ${start}`);
  const to=app.indexOf(end,from+start.length);
  assert.notEqual(to,-1,`missing end marker: ${end}`);
  return app.slice(from,to);
}

/* The standard F&B sector bundle (app/app.js INDUSTRIES.fnb.mods) — what a real business's
   enabled_modules looks like. It deliberately has no 'settings' and no 'remindernotify': no
   production tenant's enabled_modules or platform_module_overrides_v94 row ever carries
   either key, and 'settings' is not even a module_registry entry. */
const FNB_MODULES=['dashboard','till','clients','sales','bookings','waitlist','inventory','loyalty',
  'retention','referrals','giftcards','reports','customerintel','staffperf','dailyreport','pnl','expenses'];

/* Run the real route guard, from the pageKey computation through the generic module gate,
   verbatim. `toast` and `nav` are recorded instead of acting, so the test can see whether the
   route bounced and where. */
function runRouteGuard(S,pageKeyArg){
  const src=`
    ${section('const ROLE_CAPABILITIES={','const hasRoleCapability=')}
    const HIDDEN_BUSINESS_SURFACES=new Set([]);
    ${section('const FINANCE_MODULES=new Set(','\n/* Sidebar grouping')}
    ${section('const MODULES={','const ROLE_LABELS=')}
    ${section('const canReadModule=module=>','const SAFE_LANDING_PAGES_V570=')}
    const SAFE_LANDING_PAGES_V570=['dashboard','till','clients','sales','appointments','bookings'];
    const firstPermittedPageV570=()=>{
      const permitted=SAFE_LANDING_PAGES_V570.find(module=>canReadModule(module));
      return permitted?('#/'+permitted):'#/no-access';
    };
    let toasted=null;
    const toast=msg=>{toasted=msg;};
    /* The real router does 'return nav(...)': nav's return value becomes this whole
       extracted block's return value, so nav must hand back the result the test checks
       rather than merely recording a side effect. */
    const nav=to=>({bounced:true,bouncedTo:to,toasted});
    const page=[pageKeyArg];
    ${section("    const pageKey=page[0]==='client'?'clients':page[0];",
               '    if(!isRouteCurrent())return;\n    await loadWorkspaceLocaleV97')}
    return {bounced:false,bouncedTo:null,toasted};`;
  return new Function('S,pageKeyArg',src)(S,pageKeyArg);
}

/* The rail filter as navHtml actually builds it — real MODULES/NAVGROUPS/navModuleVisible,
   filtered down to just the Operations setup group's items for readability. */
function operationsSetupRow(S,resolvedModules){
  const src=`
    ${section('const ROLE_CAPABILITIES={','const hasRoleCapability=')}
    const HIDDEN_BUSINESS_SURFACES=new Set([]);
    ${section('const FINANCE_MODULES=new Set(','\n/* Sidebar grouping')}
    ${section('const MODULES={','const ROLE_LABELS=')}
    ${section('const CUSTOMER_INTERFACE_VIEWS_V296','const CUSTOMER_INTERFACE_TABS_V368')}
    ${section('const NAVGROUPS=[','\nlet navOpen')}
    const sectorShowsBottlesV275=false;
    const sectorHidesAppointmentsV246=false;
    const enabled=filterResolvedModulesForRole(resolvedModules,S.myRole);
    ${section('  const navModuleVisible=m=>','  const visGroups=')}
    const setupGroup=NAVGROUPS.find(g=>g.key==='setup');
    return setupGroup.items.filter(navModuleVisible);`;
  return new Function('S,resolvedModules',src)(S,resolvedModules);
}

test('F013: an owner with a standard fnb module set reaches #/remindernotify', ()=>{
  const S={myRole:'owner',myModules:FNB_MODULES};
  const result=runRouteGuard(S,'remindernotify');
  assert.equal(result.bounced,false,
    `owner must not be bounced from #/remindernotify; got toast=${result.toasted}`);
});

test('F013: an owner sees the Reminder & Notification row under Operations setup', ()=>{
  const S={myRole:'owner'};
  const items=operationsSetupRow(S,FNB_MODULES);
  assert.ok(items.includes('remindernotify'),
    `expected 'remindernotify' in the Operations setup rail, got ${JSON.stringify(items)}`);
});

test('F013: a plain staff member is refused #/remindernotify and bounced to an openable page', ()=>{
  const S={myRole:'staff',myModules:FNB_MODULES};
  const result=runRouteGuard(S,'remindernotify');
  assert.equal(result.bounced,true,'staff must be bounced from #/remindernotify');
  assert.match(result.toasted,/Only the owner can open Reminder & Notification\./);
  assert.notEqual(result.bouncedTo,'#/remindernotify');
});

test('F013: a plain staff member never sees the Reminder & Notification row', ()=>{
  const S={myRole:'staff'};
  const items=operationsSetupRow(S,FNB_MODULES);
  assert.ok(!items.includes('remindernotify'),
    `staff must not see 'remindernotify' in the rail, got ${JSON.stringify(items)}`);
});

test('F013: manager, frontdesk and bookkeeper are all refused too — this is owner-only, not role-list', ()=>{
  for(const role of ['manager','frontdesk','bookkeeper']){
    const S={myRole:role,myModules:FNB_MODULES};
    const result=runRouteGuard(S,'remindernotify');
    assert.equal(result.bounced,true,`${role} must be bounced from #/remindernotify`);
  }
});

test('F013: the pseudo-module alias to \'settings\' is gone; the only surviving alias is the real custpackages->packages one', ()=>{
  assert.match(app,/const SURFACE_MODULE_ALIAS_V584=Object\.freeze\(\{custpackages:'packages'\}\);/);
  assert.ok(!app.includes("remindernotify:'settings'"),
    'remindernotify must not be aliased to the ungranted settings pseudo-module any more');
});

test("F013: 'remindernotify' is in OWNER_ONLY_MODULES, same as 'settings'/'branches'/'setup'", ()=>{
  assert.match(app,/const OWNER_ONLY_MODULES=new Set\(\[[^\]]*'remindernotify'[^\]]*\]\);/);
});
