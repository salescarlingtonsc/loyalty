import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

async function loadConsole(){
  const source=await read('app/platform-console.js');
  const context={Object,Map,Set};
  context.globalThis=context;
  vm.runInNewContext(source,context,{filename:'platform-console.js'});
  return context.NestlyPlatformConsole;
}

test('operational board stays within five lanes and keeps Case won distinct from Closed',async()=>{
  const Console=await loadConsole();
  const lanes=Array.from(Console.operationalLanes,lane=>({
    key:lane.key,label:lane.label,stages:Array.from(lane.stages)
  }));
  assert.equal(lanes.length,5);
  assert.deepEqual(lanes.find(lane=>lane.key==='case_won'),{
    key:'case_won',label:'Case won',stages:['closed_won','client','account_created','onboarding','activated']
  });
  // The closed lane now legitimately holds all six closed-without-activation
  // states, not just 'lost'. What must stay true is that it remains a
  // distinct lane from case_won (won stays separate from closed).
  assert.deepEqual(lanes.find(lane=>lane.key==='closed')?.stages,[
    'lost','not_interested','no_response','invalid_contact','closed_business','do_not_contact'
  ]);
  assert.notEqual(lanes.find(lane=>lane.key==='closed'),lanes.find(lane=>lane.key==='case_won'));
  assert.equal(Console.operationalLaneFor({lane_key:'case_won',business_id:'firm-1'}),'case_won');
  assert.equal(Console.operationalLaneFor({source_stage_key:'lost'}),'closed');
});

test('onboarding board has prominent search, status and attention filters without horizontal Kanban',async()=>{
  const [source,styles]=await Promise.all([
    read('app/platform-console.js'),read('app/platform-console.css')
  ]);
  for(const id of ['platformProspectSearch','platformLaneFilter','platformAttentionFilter'])
    assert.match(source,new RegExp(id));
  assert.match(source,/fetchFirmDirectoryPageV88\(sb,filters,\{[\s\S]*required:true,limit:50/);
  assert.match(source,/mergeFirmOnboardingItems\(directoryItems,prospectItems\)/);
  assert.match(source,/data-attention-quick/);
  assert.match(source,/attentionSummary:prior\?\.attentionSummary\|\|directory\.attention_summary/);
  assert.match(source,/\['due','Due now','no'\],\['critical','Critical','no'\],\['warning','Warning','new'\]/);
  assert.match(source,/\['info','Monitor','off'\],\['stale','Stale','off'\],\['clean','Clean','ok'\]/);
  assert.match(source,/Open firm directory/);
  assert.match(source,/operationalLanes\.map\(lane=>`<section class="platform-kanban-column"/);
  // v181 (owner request 2026-08-06): the board is drag-and-drop again. The
  // earlier no-drag assertion is retired deliberately; what must stay true is
  // that a drop resolves to a stage and still runs the evidence modal, which
  // the v181 suite pins.
  assert.match(source,/data-lane-drop="\$\{lane\.key\}"/);
  const kanbanRule=styles.match(/\.platform-kanban\{([\s\S]*?)\}/)?.[1]||'';
  assert.match(kanbanRule,/display:grid/);
  assert.match(kanbanRule,/auto-fit/);
  assert.doesNotMatch(kanbanRule,/overflow-x|scroll-snap/);
  assert.match(source,/id="platformOnboardingLoadMore"/);
  assert.match(source,/Load 50 more firms/);
});

test('attention filters preserve independent due, severity, stale and clean meanings',async()=>{
  const Console=await loadConsole();
  const matches=Console.prospectAttentionMatches;
  const warningDue={
    lane_key:'contacting',source_stage_key:'appt_set',
    attention_severity:'warning',attention_due:true,days_unattended:2
  };
  assert.equal(matches(warningDue,'due'),true);
  assert.equal(matches(warningDue,'warning'),true);
  assert.equal(matches(warningDue,'critical'),false);
  assert.equal(matches(warningDue,'stale'),false);
  assert.equal(matches(warningDue,'clean'),false);

  const staleWarning={...warningDue,days_unattended:8,attention_reason:'stale_activity'};
  assert.equal(matches(staleWarning,'stale'),true);
  assert.equal(matches(staleWarning,'warning'),true);

  const clean={
    lane_key:'case_won',source_stage_key:'activated',
    attention_severity:'none',attention_due:false,days_unattended:40,attention_reason:null
  };
  assert.equal(matches(clean,'clean'),true,'terminal rows follow the backend no-attention ruling');
  assert.equal(matches({...clean,attention_severity:'info'},'info'),true);
  assert.equal(matches({...clean,attention_severity:'info'},'clean'),false);
  const activeNone={
    lane_key:'contacting',source_stage_key:'appt_set',
    attention_severity:'none',attention_due:false,attention_reason:null
  };
  assert.equal(matches(activeNone,'clean'),true);
  assert.equal(matches(activeNone,'info'),false);
  assert.equal(matches(activeNone,'warning'),false);
  assert.equal(matches(activeNone,'critical'),false);
});

test('sector templates use friendly pick-and-play modules and an explicit immutable publish review',async()=>{
  const [source,styles]=await Promise.all([
    read('app/platform-console.js'),read('app/platform-console.css')
  ]);
  assert.match(source,/name="modules" value=/);
  assert.match(source,/data-edit-sector/);
  assert.match(source,/Choose the standard modules/);
  assert.match(source,/I reviewed the module list and understand this publishes a new immutable version/);
  assert.match(source,/platform_create_sector_bundle_v75',args/);
  assert.match(source,/platform_create_sector_bundle_v75',\{\.\.\.args,p_dry_run:false\}/);
  assert.match(source,/platform_publish_sector_bundle_v75',\{p_bundle_version:createdBundleId,p_dry_run:true\}/);
  assert.match(source,/platform_publish_sector_bundle_v75',\{p_bundle_version:createdBundleId,p_dry_run:false\}/);
  assert.match(styles,/\.platform-module-options/);
  assert.match(styles,/@media\(max-width:760px\)[\s\S]*\.platform-module-options,.platform-bundle-diff\{grid-template-columns:1fr\}/);
});

test('firm directory search consumes the scalable v88 contract and exposes safe call actions',async()=>{
  const [Console,source]=await Promise.all([loadConsole(),read('app/platform-console.js')]);
  assert.deepEqual(
    JSON.parse(JSON.stringify(Console.normalizePlatformPhone('8123 4567'))),
    {tel:'+6581234567',wa:'6581234567',display:'+6581234567'}
  );
  assert.equal(Console.normalizePlatformPhone('invalid'),null);
  assert.equal(Console.firmId({
    business_id:null,row_id:'row-1',prospect_id:'prospect-1'
  }),'row-1');
  assert.match(source,/platform_list_firm_onboarding_v88/);
  assert.match(source,/p_limit:limit/);
  assert.match(source,/required=false,snapshot=null,cursor=null,limit=50/);
  assert.match(source,/p_after_updated_at:cursor\?\.updated_at/);
  assert.match(source,/firm\.business_id\|\|firm\.id\|\|firm\.row_id\|\|firm\.prospect_id/);
  assert.match(source,/const directoryIds=asArray\(directory\?\.items\)/);
  assert.match(source,/fetchEnterpriseFirmPage\(sb,\{[\s\S]*\.\.\.filters,businesses:directoryIds,search:''/);
  assert.match(source,/Name, sector, UEN, owner phone or email/);
  assert.match(source,/firm\.boss_phone\|\|firm\.owner_phone/);
  assert.match(source,/href="tel:\$\{escapeHtml\(phone\.tel\)\}"/);
  assert.match(source,/https:\/\/wa\.me\/\$\{escapeHtml\(phone\.wa\)\}/);
});

test('enterprise search unions live v88 matches with v82 branch/customer matches without duplicating report generation',async()=>{
  const [Console,source]=await Promise.all([loadConsole(),read('app/platform-console.js')]);
  const directory=[
    {business_id:'business-owner-match',row_id:'business-owner-match'},
    {business_id:'business-shared',row_id:'business-shared'},
    {business_id:null,row_id:'prospect-only',prospect_id:'prospect-only'}
  ];
  const hierarchy=[
    {business_id:'business-shared'},
    {business_id:'business-customer-match'}
  ];
  assert.deepEqual(
    Array.from(Console.resolveEnterpriseSearchBusinessIds(directory,hierarchy)),
    ['business-owner-match','business-shared','business-customer-match']
  );
  assert.deepEqual(
    Array.from(Console.resolveEnterpriseSearchBusinessIds(directory,hierarchy,['business-customer-match'])),
    ['business-customer-match']
  );
  assert.deepEqual(
    Array.from(Console.resolveEnterpriseSearchBusinessIds(directory,hierarchy,['not-matched'])),
    []
  );
  assert.match(source,/let hierarchyFirms=asArray\(rawPayload,\['firms'\]\)/);
  assert.match(source,/const directoryIds=asArray\(directory\?\.items\)[\s\S]*!hierarchyIds\.has/);
  assert.match(source,/fetchEnterpriseFirmPage\(sb,\{[\s\S]*businesses:directoryIds,search:''/);
  assert.match(source,/const unique=new Map\(hierarchyFirms\.map\(firm=>\[firmId\(firm\),firm\]\)\)/);
  assert.match(source,/openEnterpriseFirm\(firm,context,\{\.\.\.filters,search:''\}\)/);
  assert.match(source,/const canonicalReportHash=enterpriseReportHash\(filters\)/);
  assert.match(source,/Continue in Reports/);
  assert.doesNotMatch(source,/id="enterpriseGenerateReport"/);
});
