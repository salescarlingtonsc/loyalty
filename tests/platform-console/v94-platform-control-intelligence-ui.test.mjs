import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

test('super-admin firm drawer exposes approval, billing access and representative contact truth',async()=>{
  const source=await read('app/platform-console.js');
  assert.match(source,/platform_get_business_control_v94/);
  assert.match(source,/data-business-approval="approved"/);
  assert.match(source,/platform_decide_business_approval_v94/);
  assert.match(source,/Awaiting a super-admin decision\. No business data is exposed/);
  assert.match(source,/Daily reminders run from the due date\. Owner access pauses on day 14/);
  assert.match(source,/href="tel:\$\{escapeHtml\(contact\.tel\)\}"/);
  assert.match(source,/Owner access resumes only after provider payment truth is reconciled/);
});

test('module controls support firm and branch scope while inventory is globally absent',async()=>{
  const source=await read('app/platform-console.js');
  const catalog=source.slice(
    source.indexOf('const sectorModuleCatalog'),
    source.indexOf('const sectorModuleByKey')
  );
  assert.doesNotMatch(catalog,/\['inventory','Inventory'/);
  assert.match(source,/platform_get_effective_modules_v94/);
  assert.match(source,/platform_set_module_override_v94/);
  assert.match(source,/!\['inventory','customerintel'\]\.includes\(module\.module_key\)/);
  assert.match(source,/Branch-specific settings override firm policy/);
  assert.match(source,/Branch overrides take priority over firm and sector settings/);
  assert.match(source,/Inventory is globally unavailable to firms/);
  assert.match(source,/mode:'inherit'|value:'inherit'/);
  assert.match(source,/value:'disabled'/);
  assert.match(source,/value:'r'/);
  assert.match(source,/value:'rw'/);
});

test('customer intelligence is platform-scoped and produces evidence-backed consultant briefs',async()=>{
  const source=await read('app/platform-console.js');
  for(const rpc of [
    'platform_get_assigned_firm_report_v94',
    'platform_get_catalogue_affinity_v94',
    'platform_get_consultative_recommendations_v94'
  ])assert.match(source,new RegExp(rpc));
  assert.match(source,/Monthly consultant brief/);
  assert.match(source,/Products bought with services/);
  assert.match(source,/canonical, non-reversed sale lines/);
  assert.match(source,/No recommendation claimed/);
  assert.match(source,/suppresses advice when the exact scope has insufficient or unreliable data/);
  assert.match(source,/JSON\.stringify\(action\.evidence\|\|\{\}\)/);
});

test('delegated admins and sales consultants use server-scoped routes instead of super-admin-only enterprise readers',async()=>{
  const source=await read('app/platform-console.js');
  assert.match(source,/const useScopedV89=access\.role!=='super_admin'/);
  assert.match(source,/useScopedV89&&activeKey==='firms'\)task=renderScopedFirms\(context\)/);
  assert.match(source,/useScopedV89&&activeKey==='reports'\)task=renderScopedReports\(context\)/);
  assert.match(source,/database verifies the assignment again before returning customer intelligence/i);
});

test('catalogue intelligence control is explicit and mobile controls remain single-column',async()=>{
  const [source,styles]=await Promise.all([
    read('app/platform-console.js'),read('app/platform-console.css')
  ]);
  assert.match(source,/platform_set_catalogue_intelligence_v94/);
  assert.match(source,/catalogue-first sales and item-level intelligence/);
  assert.match(styles,/\.platform-control-status/);
  assert.match(styles,/\.platform-enterprise-table \.platform-link-button\{[\s\S]*?min-height:44px/);
  assert.match(styles,/\.platform-context-list a\{[\s\S]*?min-height:44px/);
  assert.match(styles,/@media\(max-width:760px\)[\s\S]*\.platform-branch-control-list\{grid-template-columns:1fr\}/);
});
