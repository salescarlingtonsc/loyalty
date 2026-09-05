import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

/* nestly_v570 — an owner set a staff member's Dashboard module permission to Off, and the staff
   member still saw the Dashboard row in the rail AND the page still rendered, exposing revenue
   and visit counts. Two client causes, both fixed here:
     (a) the route guard carried a literal `pageKey!=='dashboard'` exemption, so the generic
         module check never judged the dashboard at all;
     (b) navModuleVisible answered `m==='dashboard'` with an unconditional true.
   Honouring the denial means #/dashboard is no longer a safe universal bounce target, so
   firstPermittedPageV570() answers "where can THIS account actually land". These tests EXECUTE
   the shipped helper and the shipped rail filter — a regex over the source would have stayed
   green through the whole exposure, because the code it would have matched was already there. */

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

/* The real permission chain, lifted verbatim: ROLE_CAPABILITIES -> roleCanUseModule ->
   canReadModule -> firstPermittedPageV570. Nothing is paraphrased, so a change to any link in
   that chain is judged here. `S` is the only injected value — it is the session state the
   shipped code reads. */
function makeHelper(S){
  const src=`
    ${section('const ROLE_CAPABILITIES={','const hasRoleCapability=')}
    ${section('const FINANCE_MODULES=new Set(','\n/* Sidebar grouping')}
    ${section('const canReadModule=module=>','const canWriteModule=module=>')}
    return {firstPermittedPageV570,canReadModule};`;
  return new Function('S',src)(S);
}

/* The rail filter as navHtml builds it, against the real NAVGROUPS/MODULES. `enabled` is the
   resolved module list navHtml computes one line above the filter. */
function makeRail(S,resolvedModules){
  const src=`
    ${section('const ROLE_CAPABILITIES={','const hasRoleCapability=')}
    ${section('const FINANCE_MODULES=new Set(','\n/* Sidebar grouping')}
    ${section('const MODULES={','const ROLE_LABELS=')}
    ${section('const CUSTOMER_INTERFACE_VIEWS_V296','const CUSTOMER_INTERFACE_TABS_V368')}
    ${section('const NAVGROUPS=[','\nlet navOpen')}
    const HIDDEN_BUSINESS_SURFACES=new Set([]);
    /* nestly_v768: the retired-module set navModuleVisible and the route guard now read. */
    const RETIRED_BUSINESS_MODULES_V768=new Set(['giftcards','support']);
    const sectorShowsBottlesV275=false;
    const sectorHidesAppointmentsV246=false;
    const enabled=filterResolvedModulesForRole(resolved,S.myRole)
      .filter(module=>!HIDDEN_BUSINESS_SURFACES.has(module))
      .filter(module=>module!=='bottles'||sectorShowsBottlesV275);
    ${section('  const navModuleVisible=m=>','  const visGroups=')}
    const visGroups=NAVGROUPS.map(g=>({...g,items:g.items.filter(navModuleVisible)})).filter(g=>g.items.length);
    return visGroups;`;
  return new Function('S','resolved',src)(S,resolvedModules);
}

const railHasDashboard=groups=>groups.some(g=>g.items.includes('dashboard'));

const ALL=['dashboard','till','clients','sales','appointments','bookings','inventory','loyalty','reports'];
const DENIED=ALL.filter(m=>m!=='dashboard');

test('V570 (i) a permitted dashboard is still the landing page',()=>{
  for(const role of ['owner','manager','staff','frontdesk']){
    const {firstPermittedPageV570}=makeHelper({myRole:role,myModules:ALL});
    assert.equal(firstPermittedPageV570(),'#/dashboard',
      `${role} keeps #/dashboard — nothing changes for anyone who has the module`);
  }
});

test('V570 (ii) a denied dashboard lands on the first module the account can open',()=>{
  const till=makeHelper({myRole:'staff',myModules:DENIED});
  assert.equal(till.firstPermittedPageV570(),'#/till',
    'the till is a frontline staff member\'s whole job, so it is first after the dashboard');

  /* The customer book is the fallback when there is no till. #/clients is the real route key —
     the module is 'clients' and the router maps 'client' onto it, so #/customers is not a route. */
  const clients=makeHelper({myRole:'staff',myModules:['clients','appointments','bookings']});
  assert.equal(clients.firstPermittedPageV570(),'#/clients');

  const appts=makeHelper({myRole:'staff',myModules:['appointments','bookings']});
  assert.equal(appts.firstPermittedPageV570(),'#/appointments');
});

test('V570 (ii-b) every landing page the helper can name is a real route',()=>{
  /* A bounce target that does not resolve would be a different endless loop. */
  const routeMap=section('const P={dashboard,till:tillPage,','};');
  const {firstPermittedPageV570}=makeHelper({myRole:'owner',myModules:ALL});
  const landings=new Function(`${section('const SAFE_LANDING_PAGES_V570=','const firstPermittedPageV570=')}
    return SAFE_LANDING_PAGES_V570;`)();
  for(const key of landings){
    assert.match(routeMap,new RegExp(`(^|[,{\\s])${key}[,:]`),`#/${key} must resolve in the route map`);
  }
  assert.equal(firstPermittedPageV570(),`#/${landings[0]}`);
});

test('V570 (iii) the loop-proof property: never #/dashboard once dashboard is denied',()=>{
  /* This is the whole point of the helper. Enumerate every module subset shape that matters —
     including the empty one — and assert the answer is never the page the guard just refused. */
  const shapes=[
    DENIED, ['till'], ['clients'], ['sales'], ['appointments'], ['bookings'],
    ['loyalty'], ['reports'], ['inventory'], []
  ];
  for(const role of ['staff','frontdesk','manager','bookkeeper']){
    for(const modules of shapes){
      const {firstPermittedPageV570}=makeHelper({myRole:role,myModules:modules});
      const landing=firstPermittedPageV570();
      assert.notEqual(landing,'#/dashboard',
        `${role} with [${modules}] must never be bounced back to the page it was refused`);
      assert.match(landing,/^#\/[a-z-]+$/);
    }
  }
});

test('V570 (iii-b) an account with nothing openable gets an honest card, not a guess',()=>{
  const {firstPermittedPageV570}=makeHelper({myRole:'staff',myModules:[]});
  assert.equal(firstPermittedPageV570(),'#/no-access');

  /* A module that is not a landing page must not be silently upgraded into one. */
  const {firstPermittedPageV570:onlyLoyalty}=makeHelper({myRole:'staff',myModules:['loyalty','reports']});
  assert.equal(onlyLoyalty(),'#/no-access');

  /* #/no-access has no MODULES entry and no page function, so the router MUST intercept it
     before renderShell answers "That page has moved" and bounces again. */
  const guard=section("if(pageKey==='no-access'){","const growModuleKeys=");
  assert.match(guard,/renderWorkspaceAccessUnavailable\(\)/,
    'the terminal landing must render the existing access-unavailable card');
});

test('V570 (iv) the rail omits Dashboard when denied and keeps it when permitted',()=>{
  const permitted=makeRail({myRole:'staff'},ALL);
  assert.ok(railHasDashboard(permitted),'an inheriting staff member keeps the Dashboard row');

  const denied=makeRail({myRole:'staff'},DENIED);
  assert.ok(!railHasDashboard(denied),
    'the bug: Dashboard=Off in the per-staff module editor, and the rail still offered the row');
  /* The rest of the rail is untouched — this is a gate on one key, not a rail rewrite. */
  assert.ok(denied.some(g=>g.items.includes('till')),'the other permitted rows still render');

  const owner=makeRail({myRole:'owner'},ALL);
  assert.ok(railHasDashboard(owner),'an owner always passes app.can_module, so the row stays');
});

test('V570 the route guard no longer exempts the dashboard',()=>{
  /* The exemption is what made an explicit denial a no-op; pin its absence at the consult site. */
  const guard=section('if(MODULES[pageKey]&&!OWNER_ONLY_MODULES.has(pageKey)',"    if(!isRouteCurrent())return;");
  assert.ok(!guard.includes("pageKey!=='dashboard'"),
    'the dashboard must be judged by the same module guard as every other surface');
  assert.match(guard,/return nav\(firstPermittedPageV570\(\)\);/,
    'and the bounce must go somewhere this account can actually open');
});

test('V570 no router refusal bounces to a literal #/dashboard any more',()=>{
  /* One unconverted bounce trades the old exposure for a new endless loop, so the router region
     is checked as a whole rather than guard by guard. */
  const router=section('    const pageKey=page[0]===\'client\'?\'clients\':page[0];','    if(!isRouteCurrent())return;\n    await loadWorkspaceLocaleV97');
  assert.ok(!router.includes("return nav('#/dashboard')"),
    'every refusal in the router must bounce through firstPermittedPageV570()');
  /* #/storedvalue deliberately still bounces to a real alternative surface. */
  assert.match(router,/toast\('Stored value is not available for launch\.'\);\s*\n\s*return nav\('#\/loyalty'\);/);
});

test('V570 a bare #/ no longer hardcodes the dashboard',()=>{
  const line=section('    const page=workspacePage?[workspacePage]','\n    if(frontlineDefault)');
  assert.match(line,/firstPermittedPageV570\(\)\.replace\('#\/',''\)/);
  /* frontlineDefault must still win for till-capable frontline staff. */
  assert.match(line,/frontlineDefault\?\['till'\]/);
});
