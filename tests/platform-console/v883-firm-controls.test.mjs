/* nestly_v883 — Firm controls on the firm record.

   Owner, 2026-09-10: "I need to manually input the start date (select frequency) and the next
   payment date is furnished automatically. I need to easily switch modules on or off as a super
   admin, for all or individual branches. These functions are so hard to access, and it always
   glitches me out to the main kanban page."

   The renderers and the date arithmetic are EXECUTED (vm-loaded console, stub CUI); the wiring,
   the close-path fix and the migration contract are pinned by source. */
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

async function loadConsole(){
  const source=await read('app/platform-console.js');
  const context={Object,URL,URLSearchParams,Intl,Date,Map,Set,Proxy,Reflect,JSON,Number,String,Array,RegExp,Math,encodeURIComponent,decodeURIComponent};
  context.globalThis=context;
  vm.runInNewContext(source,context,{filename:'platform-console.js'});
  return context.NestlyPlatformConsole;
}
const stubCUI=Object.freeze({
  icon:name=>`<i data-icon="${name}"></i>`,
  card:({title,description,body})=>`<section><h2>${title}</h2><p>${description??''}</p>${body}</section>`,
  status:(text,tone)=>`<span class="status ${tone}">${text}</span>`,
  loadingState:({title,body})=>`<div><h3>${title}</h3><p>${body}</p></div>`,
  errorState:({title,message})=>`<div><h3>${title}</h3><p>${message}</p></div>`,
  field:({id,label,value='',control='input',options=[],attributes=''})=>control==='select'
    ?`<label for="${id}">${label}</label><select id="${id}" ${attributes}>${options.map(option=>`<option value="${option.value}"${option.selected?' selected':''}>${option.label}</option>`).join('')}</select>`
    :`<label for="${id}">${label}</label><input id="${id}" value="${value}" ${attributes}>`
});

test('the next payment is the start day plus one cadence, month-end clamped like Postgres',async()=>{
  const {billingNextPaymentDay}=await loadConsole();
  assert.equal(billingNextPaymentDay('2026-10-01','monthly'),'2026-11-01');
  assert.equal(billingNextPaymentDay('2026-12-15','monthly'),'2027-01-15');
  assert.equal(billingNextPaymentDay('2026-11-30','quarterly'),'2027-02-28');
  assert.equal(billingNextPaymentDay('2026-08-31','half_yearly'),'2027-02-28');
  assert.equal(billingNextPaymentDay('2028-02-29','annual'),'2029-02-28');
  assert.equal(billingNextPaymentDay('2026-01-31','monthly'),'2026-02-28');
  assert.equal(billingNextPaymentDay('2026-10-01','weekly'),null);
  assert.equal(billingNextPaymentDay('not a day','monthly'),null);
  assert.equal(billingNextPaymentDay('',null),null);
});

test('a manual subscription gets the start + frequency form with the computed next payment; a provider-owned one is read-only',async()=>{
  const {billingScheduleCardHtml}=await loadConsole();
  const manual=billingScheduleCardHtml({exists:true,editable:true,provider:'manual',cadence:null,period_start_day:null,next_payment_day:null},stubCUI);
  assert.match(manual,/data-billing-schedule-form/);
  assert.match(manual,/data-billing-start/);
  assert.match(manual,/data-billing-cadence/);
  assert.match(manual,/<option value="monthly" selected>/);
  assert.match(manual,/<option value="quarterly">/);
  assert.match(manual,/<option value="half_yearly">/);
  assert.match(manual,/<option value="annual">/);
  assert.match(manual,/Save schedule/);
  assert.match(manual,/Not set yet/);
  const saved=billingScheduleCardHtml({exists:true,editable:true,provider:'manual',cadence:'quarterly',period_start_day:'2026-10-01',next_payment_day:'2027-01-01'},stubCUI);
  assert.match(saved,/value="2026-10-01"/);
  assert.match(saved,/<option value="quarterly" selected>/);
  assert.match(saved,/data-billing-next>1 Jan 2027</);
  assert.match(saved,/Saved: Every 3 months from 1 Oct 2026/);
  const stripe=billingScheduleCardHtml({exists:true,editable:false,provider:'stripe',cadence:'monthly',period_start_day:'2026-09-06',next_payment_day:'2026-10-06',payment_status:'paid'},stubCUI);
  assert.doesNotMatch(stripe,/data-billing-schedule-form/);
  assert.match(stripe,/Managed by Stripe/);
  assert.match(stripe,/6 Oct 2026/);
  const none=billingScheduleCardHtml({exists:false,editable:false},stubCUI);
  assert.doesNotMatch(none,/data-billing-schedule-form/);
  assert.match(none,/No subscription record exists/);
});

test('module switches reflect the effective mode, name their source, scope to branches and never list inventory',async()=>{
  const {moduleSwitchesHtml}=await loadConsole();
  const effective={modules:[
    {module_key:'till',mode:'rw',source:'sector_entitlement',override_mode:'inherit',override_version:null},
    {module_key:'loyalty',mode:'disabled',source:'firm_override',override_mode:'disabled',override_version:3},
    {module_key:'appointments',mode:'r',source:'firm_override',override_mode:'r',override_version:1},
    {module_key:'inventory',mode:'disabled',source:'global_inventory_policy'}
  ]};
  const branches=[{branch_id:'b1',name:'Choa Chu Kang',active:true},{branch_id:'b2',name:'Closed outlet',active:false},{branch_id:'b3',name:'Jurong',active:true}];
  const html=moduleSwitchesHtml(effective,branches,'',stubCUI);
  assert.equal((html.match(/data-module-scope=/g)||[]).length,3,'whole firm + two active branches');
  assert.match(html,/aria-selected="true" data-module-scope=""/);
  assert.match(html,/aria-checked="true" aria-label="Quick earn access" data-module-switch="till"/);
  assert.match(html,/aria-checked="false" aria-label="Loyalty access" data-module-switch="loyalty"/);
  assert.match(html,/aria-checked="true" aria-label="Appointments access" data-module-switch="appointments"/);
  assert.match(html,/Firm setting · Read only/);
  assert.match(html,/Follows template/);
  assert.doesNotMatch(html,/data-module-switch="inventory"/);
  assert.doesNotMatch(html,/data-module-switch="customerintel"/);
  assert.match(html,/data-module-reset>Follow the template for every module/);
  const branchScope=moduleSwitchesHtml({modules:effective.modules.map(module=>({...module,override_mode:'inherit',override_version:null}))},branches,'b1',stubCUI);
  assert.match(branchScope,/aria-selected="true" data-module-scope="b1"|data-module-scope="b1"[^>]*aria-selected="true"/);
  assert.match(branchScope,/apply to this branch only/);
  assert.doesNotMatch(branchScope,/data-module-reset/,'nothing to reset when every module inherits');
  const single=moduleSwitchesHtml(effective,[{branch_id:'b1',name:'Only',active:true}],'',stubCUI);
  assert.doesNotMatch(single,/data-module-scope=/,'one branch means no scope chooser');
});

test('the drawer subtitle names the stage, sector and conversion instead of "Loading…"',async()=>{
  const {prospectSubtitleText}=await loadConsole();
  const text=prospectSubtitleText({prospect:{current_stage_key:'activated',converted_at:'2026-09-06T03:58:32Z'},company:{industry:'salon'}});
  assert.match(text,/Activated/);
  assert.match(text,/Peekaa merchant since 6 Sept? 2026$/);
  assert.doesNotMatch(text,/Loading/);
});

test('the firm record hosts the controls and wires them to the existing writers',async()=>{
  const source=await read('app/platform-console.js');
  assert.match(source,/\.\.\.\(converted&&isSuperAdmin\?\[\['detail-controls','Controls'\]\]:\[\]\)/);
  assert.match(source,/\$\{converted&&isSuperAdmin\?firmControlsSectionHtml\(CUI\):''\}/);
  assert.match(source,/if\(prospect\.converted_business_id&&context\.access\?\.role==='super_admin'\)loadFirmControls\(detail,context\)/);
  assert.match(source,/rpc\(sb,'platform_get_billing_schedule_v883',\{p_business:businessId\}\)/);
  assert.match(source,/rpc\(sb,'platform_set_billing_schedule_v883',\{/);
  assert.match(source,/p_start_day:start\.value,p_cadence:cadence\.value/);
  assert.match(source,/rpc\(sb,'platform_get_business_payments_v779',\{p_business:businessId\}\)\.then\(asObject\)\.catch\(\(\)=>\(\{\}\)\)/);
  assert.match(source,/rpc\(sb,'platform_set_module_overrides_v105',\{\s*p_business:businessId,p_branch:state\.scope\|\|null,p_reason:reason,p_changes:changes/);
  assert.match(source,/mode:on\?'disabled':'rw',expected_version:prior\.version/);
  assert.match(source,/mode:'inherit',expected_version:module\.override_version\?\?null/);
  assert.match(source,/data-prospect-subtitle/);
  const html=await read('app/index.html');
  assert.match(html,/platform-console\.js\?v=20260910-v88[34]/);
  assert.match(html,/platform-console\.css\?v=20260910-v88[34]/);
  const css=await read('app/platform-console.css');
  assert.match(css,/\.platform-switch\.on \.platform-switch-knob\{background:var\(--green\)\}/);
});

test('closing the drawer refreshes the board that opened it, never the onboarding board by default',async()=>{
  const source=await read('app/platform-console.js');
  const close=source.slice(source.indexOf('async function openProspectDetail('),source.indexOf('async function loadProspectDetail('));
  assert.match(close,/if\(typeof context\.onBoardDirty==='function'\)context\.onBoardDirty\(\);/);
  assert.match(close,/else if\(context\.onboardingFilters\)renderOnboarding\(/);
  assert.doesNotMatch(close,/context\.onboardingFilters\|\|defaultOnboardingFilters\(\)/);
  assert.match(source,/openProspectDetail\(item,\{\.\.\.context,prospectCloseHash:crmHash\(active\),onBoardDirty:\(\)=>renderCrm\(context,active\)\}\)/);
  assert.match(source,/openProspectDetail\(\{\.\.\.item,prospect_id:item\.id\},\{\.\.\.drawerContext,prospectCloseHash:null,onBoardDirty:\(\)=>\{dirty=true;load\(\)\}\}\)/);
  const onboardingCallers=source.match(/openProspectDetail\((?:requestedItem|item),\{\s*\.\.\.context,onboardingFilters:filters/g)||[];
  assert.ok(onboardingCallers.length>=1,'the onboarding board still passes its filters and keeps its own refresh');
});

test('nestly_v883 sets a manual schedule only, computes the next payment server-side and never flips paid state',async()=>{
  const sql=await read('db/migrations/20261010_nestly_v883_firm_billing_schedule.sql');
  assert.match(sql,/^begin;/m);
  assert.match(sql,/^commit;/m);
  assert.match(sql,/create or replace function public\.platform_get_billing_schedule_v883\(p_business uuid\)/);
  assert.match(sql,/create or replace function public\.platform_set_billing_schedule_v883\(\s*p_business uuid,\s*p_start_day date,\s*p_cadence text,\s*p_reason text\s*\)/);
  assert.match(sql,/if v_before\.billing_provider <> 'manual' then\s*raise exception 'provider_owns_schedule'/);
  assert.match(sql,/v_next\s*:= \(\(p_start_day \+ make_interval\(months => v_months\)\)::date::timestamp\) at time zone 'Asia\/Singapore'/);
  assert.match(sql,/next_payment_at = v_next/);
  const update=sql.slice(sql.indexOf('update public.subscriptions'),sql.indexOf('returning * into v_after'));
  assert.doesNotMatch(update,/\bstatus\s*=/);
  assert.doesNotMatch(update,/payment_status/);
  assert.doesNotMatch(update,/last_paid_at/);
  assert.match(sql,/revoke all on function public\.platform_set_billing_schedule_v883\(uuid, date, text, text\) from public, anon;/);
  assert.match(sql,/grant execute on function public\.platform_set_billing_schedule_v883\(uuid, date, text, text\) to authenticated, service_role;/);
  const copy=await read('supabase/migrations/20261010180000_nestly_v883_firm_billing_schedule.sql');
  assert.equal(copy,sql,'the supabase copy is byte-identical');
  const suite=await read('db/tests/v883_firm_billing_schedule.sql');
  assert.match(suite,/provider_owns_schedule/);
  assert.match(suite,/^rollback;/m);
});
