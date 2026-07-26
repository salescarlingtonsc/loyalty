import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const app=await readFile(new URL('../../app/index.html',import.meta.url),'utf8');

function section(start,end){
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0&&to>from,`missing ${start}`);
  return app.slice(from,to);
}

function permissionHarness(){
  const roleSource=app.match(/const ROLE_CAPABILITIES=\{[\s\S]*?const hasRoleCapability=[^\n]+/)?.[0];
  const moduleSource=app.match(/const FINANCE_MODULES=[\s\S]*?const filterResolvedModulesForRole=[\s\S]*?;/)?.[0];
  const accessSource=app.match(/const canReadModule=[\s\S]*?const canWriteModule=[\s\S]*?;/)?.[0];
  assert.ok(roleSource&&moduleSource&&accessSource);
  const context={S:null};
  const api=vm.runInNewContext(`(()=>{${roleSource};${moduleSource};${accessSource};return {roleCanUseModule,filterResolvedModulesForRole,canReadModule,canWriteModule,hasRoleCapability}})()`,context);
  return {
    evaluate(S,module){
      context.S=S;
      return {
        read:api.canReadModule(module),
        write:api.canWriteModule(module),
        sales:api.hasRoleCapability('create_sales'),
        finance:api.hasRoleCapability('view_finance')
      };
    },
    filter:api.filterResolvedModulesForRole
  };
}

test('owner, manager, frontdesk, staff, and bookkeeper enforce compound finance capability',()=>{
  const harness=permissionHarness();
  assert.deepEqual(
    JSON.parse(JSON.stringify(harness.evaluate({myRole:'owner',myModules:['expenses'],myModulePerms:{expenses:'rw'}},'expenses'))),
    {read:true,write:true,sales:true,finance:true}
  );
  assert.deepEqual(
    JSON.parse(JSON.stringify(harness.evaluate({myRole:'manager',myModules:['pnl'],myModulePerms:{pnl:'r'}},'pnl'))),
    {read:true,write:false,sales:true,finance:true}
  );
  assert.deepEqual(
    JSON.parse(JSON.stringify(harness.evaluate({myRole:'bookkeeper',myModules:['expenses'],myModulePerms:{expenses:'rw'}},'expenses'))),
    {read:true,write:true,sales:false,finance:true}
  );
  for(const role of ['staff','frontdesk']){
    assert.deepEqual(
      JSON.parse(JSON.stringify(harness.evaluate({myRole:role,myModules:['expenses'],myModulePerms:{expenses:'rw'}},'expenses'))),
      {read:false,write:false,sales:true,finance:false}
    );
  }
});

test('fallback filtering preserves owner special modules but removes them and finance from ineligible roles',()=>{
  const {filter}=permissionHarness();
  const modules=['dashboard','branches','settings','setup','expenses','pnl','clients'];
  assert.equal(JSON.stringify(filter(modules,'owner')),JSON.stringify(modules));
  assert.equal(JSON.stringify(filter(modules,'manager')),JSON.stringify(['dashboard','expenses','pnl','clients']));
  assert.equal(JSON.stringify(filter(modules,'bookkeeper')),JSON.stringify(['dashboard','expenses','pnl','clients']));
  assert.equal(JSON.stringify(filter(modules,'staff')),JSON.stringify(['dashboard','clients']));
  assert.equal(JSON.stringify(filter(modules,'frontdesk')),JSON.stringify(['dashboard','clients']));
  const route=section('async function route(){','/* ---------- customer wallet ---------- */');
  assert.match(route,/filterResolvedModulesForRole\(enabled,staffRow\.role\)/);
  assert.match(route,/filterResolvedModulesForRole\(workspaceStaffPersona\.modules,S\.myRole\)/);
  assert.match(route,/S\.myModules\.map\(m=>\[m,S\.myRole==='owner'\?'rw':'r'\]\)/);
  assert.match(route,/filterResolvedModulesForRole\(mm\.modules,S\.myRole\)/);
});

test('Team permissions initialize from module_perms and render Off Read Edit rather than module checkboxes',()=>{
  const settings=section('async function settingsPage(){','/* ---------- billing (read-only) ---------- */');
  assert.match(settings,/s\.module_perms===null\s*\?\{mode:'inherit'/);
  assert.match(settings,/Inherit all enabled modules/);
  assert.match(settings,/Set Off \/ Read \/ Edit explicitly/);
  assert.match(settings,/<option value="off"[\s\S]*>Off<\/option><option value="r"[\s\S]*>Read<\/option><option value="rw"[\s\S]*>Edit<\/option>/);
  assert.match(settings,/Unavailable for \$\{esc\(ROLE_LABELS\[s\.role\]\|\|s\.role\)\}: Expenses and P&amp;L require a finance-capable role/);
  assert.doesNotMatch(section('function modulePermissionGridHtml','function modPanelHtml'),/type="checkbox"/);
  assert.match(settings,/enabledAssignableModules[\s\S]*!OWNER_ONLY_MODULES\.has\(module\)/);
});

test('Team saves exact v74 JSON permissions and refreshes server-resolved dependency additions',()=>{
  const settings=section('async function settingsPage(){','/* ---------- billing (read-only) ---------- */');
  assert.match(settings,/set_staff_module_permissions_v74',\{p_staff:staffId,p_module_perms:requested\}/);
  assert.match(settings,/const added=Object\.keys\(resolved\|\|\{\}\)\.filter\(module=>!requestedKeys\.has\(module\)\)/);
  assert.match(settings,/Required dependencies added as Read/);
  assert.match(settings,/panelSel\[staffId\]=resolved===null\?\{mode:'inherit'/);
  assert.doesNotMatch(settings,/sb\.rpc\('set_staff_modules'/);
});

test('templates stay text arrays but apply every available key as rw through v74',()=>{
  const settings=section('async function settingsPage(){','/* ---------- billing (read-only) ---------- */');
  assert.match(settings,/save_module_template',\{p_business:S\.biz\.id,p_name:name,p_modules:modules\}/);
  assert.match(settings,/const permissions=Object\.fromEntries\(permitted\.map\(module=>\[module,'rw'\]\)\)/);
  assert.match(settings,/set_staff_module_permissions_v74',\{p_staff:staffId,p_module_perms:permissions\}/);
  assert.match(settings,/Apply as Edit access/);
  assert.doesNotMatch(settings,/apply_module_template/);
});

test('role changes use v74 atomically and explain finance removal',()=>{
  const settings=section('async function settingsPage(){','/* ---------- billing (read-only) ---------- */');
  assert.match(settings,/set_staff_role_v74',\{p_staff:id,p_role:role\}/);
  assert.match(settings,/if\(error\)\{fail\(error\);await loadTeam\(\);return\}/);
  assert.match(settings,/Expenses and P&amp;L were removed because/);
  assert.doesNotMatch(settings,/from\('staff'\)\.update\(\{role\}/);
});

test('global Quick earn requires till read, clients read, and sales capability',()=>{
  const global=section('function globalActionsHtml(){','function wireGlobalActions(){');
  assert.match(global,/const canQuickEarn=canReadModule\('till'\)&&canReadModule\('clients'\)&&hasRoleCapability\('create_sales'\)/);
});
