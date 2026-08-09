import {createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {fileURLToPath,pathToFileURL} from 'node:url';

const APP_URL=new URL('../../app/index.html',import.meta.url);
/* The application script was extracted from index.html into app.js. The .test.mjs files
   pass both files joined; this CLI path must read the same pair or it regenerates a
   fixture from a file that no longer contains the components. */
const APP_SCRIPT_URL=new URL('../../app/app.js',import.meta.url);
const readAppSource=async()=>(await Promise.all([readFile(APP_URL,'utf8'),readFile(APP_SCRIPT_URL,'utf8')])).join('\n');
const FIXTURE_URL=new URL('./reward-overview-owner-visual.html',import.meta.url);

function sourceBetween(source,start,end){
  const from=source.indexOf(start),to=source.indexOf(end,from+start.length);
  if(from<0||to<=from)throw new Error(`production source section missing: ${start}`);
  return source.slice(from,to).trim();
}

export function buildRewardOverviewVisualFixture(app){
  const style=app.match(/<style>([\s\S]*?)<\/style>/)?.[1];
  if(!style)throw new Error('production inline stylesheet missing');
  const growBack=sourceBetween(app,'function growBackActionHtmlV138','function waitlistBadgeHtml');
  const loyaltyAuthority=sourceBetween(app,'function loyaltyAuthorityActionV140','function growLoyaltyEditorIntentV139');
  const loyaltyIsolation=sourceBetween(app,'function growLoyaltyEditorIntentV139','const refreshLoyaltyPanel');
  const snapshotAdapter=sourceBetween(app,'async function growOverviewSnapshot','function ownerRewardJourneyV122');
  const journey=sourceBetween(app,'function ownerRewardJourneyV122','function growStatus');
  const status=sourceBetween(app,'function growStatus','/* v104 starts');
  const retention=sourceBetween(app,'async function retentionPage(','/* ---------- Grow: one customer journey');
  const grow=sourceBetween(app,'async function growPage(','/* ---------- Bring-back playbooks');
  const sourceHash=createHash('sha256').update(`${style}\n${growBack}\n${loyaltyAuthority}\n${loyaltyIsolation}\n${snapshotAdapter}\n${journey}\n${status}\n${retention}\n${grow}`).digest('hex');
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="icon" href="data:,">
    <meta name="production-source-sha256" content="${sourceHash}"><title>Peekaa rewards overview browser acceptance</title><style>${style}
    body{padding:24px}.visual-shell{max-width:1180px;margin:0 auto}.visual-provenance{margin:0 0 10px;color:var(--muted);font-size:12px;overflow-wrap:anywhere}
    @media(max-width:600px){body{padding:12px}}</style></head><body><div class="visual-shell"><p class="visual-provenance">Production-component harness · ${sourceHash}</p><main id="main"></main></div>
    <script>
    const $=id=>document.getElementById(id);
    const esc=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
    const money=cents=>'SGD '+(Number(cents||0)/100).toFixed(2);
    const CUI={icon:(name)=>'<span aria-hidden="true">'+({till:'◎',loyalty:'★',customers:'●',retention:'↺',inventory:'□',referrals:'↗',memberships:'◇',giftcard:'▣'}[name]||'•')+'</span>',
      loadingState:({title})=>'<section class="card">Loading '+esc(title)+'…</section>',
      emptyState:({title,body})=>'<div class="empty"><b>'+esc(title)+'</b><p>'+esc(body)+'</p></div>',announce:()=>{},
      pageHeader:({title,subtitle})=>'<header class="cui-page-head"><div class="cui-page-title"><div><h1>'+esc(title)+'</h1><p>'+esc(subtitle||'')+'</p></div></div></header>',
      action:({id,label,variant='primary'})=>'<button class="btn '+esc(variant)+'" id="'+esc(id)+'">'+esc(label)+'</button>',
      activateDialog:(modal,{onClose,initialFocus}={})=>{const prior=document.activeElement;
        const keydown=event=>{if(event.key==='Escape'){event.preventDefault();onClose?.()}};
        document.addEventListener('keydown',keydown);queueMicrotask(()=>modal.querySelector(initialFocus)?.focus());
        return ({restoreFocus=true}={})=>{document.removeEventListener('keydown',keydown);modal.remove();if(restoreFocus)prior?.focus?.()};}};
    const workspaceLocale='en';
    const workspaceTemplateHtmlV97=(key,{count}={})=>key==='growDraftReady'?'Recommendation draft is ready. Edit any setting; nothing changes for customers until publication.':count+' published '+(count===1?'reward':'rewards');
    const recordProductInteractionV100=()=>{};
    const localizeWorkspaceSubtreeV97=()=>{};
    const productProfitabilityV122=()=>null;
    const sgDateInputValue=(date=new Date())=>{
      const values={};
      new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Singapore',year:'numeric',month:'2-digit',day:'2-digit'})
        .formatToParts(date).forEach(part=>{if(part.type!=='literal')values[part.type]=part.value});
      return values.year+'-'+values.month+'-'+values.day;
    };
    const promotionDateTextV104=value=>new Intl.DateTimeFormat('en-SG',{
      timeZone:'Asia/Singapore',day:'numeric',month:'long',year:'numeric'
    }).format(new Date(value+'T12:00:00+08:00'));
    const fail=error=>{throw error};
    const toast=message=>{window.__lastToast=message};
    const nav=()=>{};
    const openProtectedGrowPublishReview=()=>{};
    const refreshRetentionPanel=()=>{};
    const renderPlaybooks=()=>{};
    ${growBack}
    ${loyaltyAuthority}
    ${loyaltyIsolation}
    const routeDispose=null;
    const M=()=>document.getElementById('main');
    const evidenceParams=new URLSearchParams(location.search);
    const isManager=evidenceParams.get('role')==='manager';
    const hasExistingDraft=evidenceParams.get('draft')==='existing';
    const failRecommendationOnce=evidenceParams.get('failOnce')==='1';
    const concurrentDraft=evidenceParams.get('concurrentDraft')==='1';
    const emptyPrograms=evidenceParams.get('empty')==='1';
    const partialOverview=evidenceParams.get('partial')||'';
    const configuredOff=evidenceParams.get('configured')==='off';
    const futureRetention=evidenceParams.get('futureRetention')==='1';
    const fixtureSector=evidenceParams.get('sector')||'facial';
    const cafeFixture=fixtureSector==='cafe';
    const classicFixture=fixtureSector==='other';
    const requestedModules=evidenceParams.get('modules');
    const selectedModules=requestedModules?requestedModules.split(',').filter(Boolean):['loyalty','retention','referrals','memberships','giftcards'];
    const S={myRole:isManager?'manager':'owner',myModules:selectedModules,biz:{id:cafeFixture?'business-cafe-harbour':classicFixture?'business-other':'business-spa-glow',currency:'SGD',industry:fixtureSector}};
    const canWriteModule=module=>!isManager&&S.myModules.includes(module);
    const fixture={currentVersion:'published-v1',draft:hasExistingDraft?{id:'draft-v2',version_no:2}:null,
      loyalty:emptyPrograms?null:{id:'programme-1',active:true,loyalty_model:'points_tiers',earn_points_per_dollar:10,redeem_points:1000,reward_credit_cents:1000,expiry_mode:'inactivity',expiry_days:365},
      rewards:emptyPrograms?[]:[
        {id:'11111111-1111-4111-8111-111111111111',active:true,customer_name:'Signature reward',cost_points:500,estimated_cost_cents:400,sort:1},
        {id:'22222222-2222-4222-8222-222222222222',active:true,customer_name:'Signature reward',cost_points:1500,estimated_cost_cents:900,sort:2},
        {id:'33333333-3333-4333-8333-333333333333',active:false,customer_name:'Seasonal facial',cost_points:750,sort:3}],
      birthday:emptyPrograms?null:{program_id:'birthday-1',active:true,customer_label:'Birthday Glow',customer_description:'Available during the birthday month.',fulfillment_kind:'discount_pct',discount_percent:20},
      products:[],retention:emptyPrograms?[]:[
        {id:'bring-back-1',program_id:'bring-back-1',name:'Glow regular return',active:!configuredOff,goal_visits:2,period_days:30,reward_taxonomy_id:'taxonomy-1',reward_label:'Glow credit',fulfillment_kind:'credit',credit_cents:1000,starts_on:futureRetention?'2099-01-01':'2026-08-01'},
        {id:'bring-back-2',program_id:'bring-back-2',name:'Paused facial return',active:false,goal_visits:1,period_days:60,reward_taxonomy_id:'taxonomy-1',reward_label:'Glow credit',fulfillment_kind:'credit',credit_cents:500,starts_on:'2026-08-01'}],
      taxonomy:[{id:'taxonomy-1',label:'Glow credit',fulfillment_kind:'credit',active:true,sort:1}],
      referral:emptyPrograms?null:{id:'referral-1',enabled:!configuredOff,reward_cents:1000,min_spend_cents:5000},
      memberships:emptyPrograms?[]:[{id:'membership-1',name:'Glow Monthly',active:!configuredOff}],
      giftcardPreferences:{status:'available',gift_card_sales_enabled:false,package_earns_points:false}};
    window.__tableReads=[];window.__rpcCalls=[];window.__rpcArgs=[];window.__recommendationFailed=false;
    function fixtureQuery(table){
      const state={single:false,equals:{}};
      const query={select(){return query},eq(column,value){state.equals[column]=value;return query},is(){return query},in(){return query},order(){return query},limit(){return query},single(){state.single=true;return query},
        then(resolve,reject){window.__tableReads.push(table);let data=[];
          if(table==='businesses')data={active_config_version_id:fixture.currentVersion};
          else if(table==='loyalty_programs')data=fixture.loyalty?[fixture.loyalty]:[];
          else if(table==='loyalty_rewards')data=fixture.rewards;
          else if(table==='retention_programs')data=fixture.retention;
          else if(table==='referral_programs')data=fixture.referral?[fixture.referral]:[];
          else if(table==='membership_plans')data=fixture.memberships;
          else if(table==='firm_config_versions')data=state.equals.status==='draft'?(fixture.draft?[fixture.draft]:[]):[{id:'published-v1',version_no:1,status:'published',snapshot_hash:'published-hash'}];
          else if(table==='firm_reward_taxonomy')data=fixture.taxonomy;
          const failedTables=partialOverview==='all'
            ?new Set(['loyalty_programs','loyalty_rewards','retention_programs','referral_programs','membership_plans'])
            :new Set(partialOverview==='1'?['referral_programs']:[]);
          const error=failedTables.has(table)?{message:'Synthetic programme status failure'}:null;
          return Promise.resolve({data:error?null:data,error}).then(resolve,reject)}};
      return query;
    }
    const sb={from:fixtureQuery,rpc:async(name,args)=>{window.__rpcCalls.push(name);window.__rpcArgs.push({name,args});
      if(name==='get_active_birthday_program')return partialOverview==='all'?{data:null,error:{message:'Synthetic birthday failure'}}:{data:{status:'published',as_of:'2026-08-01T00:00:00.000Z',programs:fixture.birthday?[fixture.birthday]:[]},error:null};
      if(name==='owner_list_reward_profitability_products_v122')return {data:{items:fixture.products},error:null};
      if(name==='business_get_checkout_preferences_v102')return partialOverview==='all'?{data:null,error:{message:'Synthetic gift-card failure'}}:{data:fixture.giftcardPreferences,error:null};
      if(name==='get_retention_config_draft')return {data:{programs:fixture.retention,taxonomy:fixture.taxonomy,snapshot_hash:'draft-hash'},error:null};
      if(name==='create_grow_config_draft_v138')return {data:{version_id:'draft-v2',version_no:2,status:'draft',snapshot_hash:'draft-hash',replayed:false,published:false},error:null};
      if(name==='ensure_published_retention_in_draft_v138')return {data:{program_id:args.p_program,config_version_id:args.p_config_version,snapshot_hash:'draft-after-retention',replayed:false,published:false},error:null};
      if(name==='generate_retention_recommendation'){
        if(failRecommendationOnce&&!window.__recommendationFailed){window.__recommendationFailed=true;return {data:null,error:{message:'Synthetic lost response'}}}
        const governedRecommendation=cafeFixture
          ?{model:'stamps',reference_price_cents:1200,suggested_spend_per_stamp_cents:600,suggested_reward_cost:8}
          :classicFixture
          ?{model:'classic',reference_price_cents:3000,suggested_spend_per_stamp_cents:null,suggested_reward_cost:null}
          :{model:'points_tiers',reference_price_cents:6400,suggested_reward_cost:320};
        const data=concurrentDraft
          ?{draft_config_version_id:'draft-concurrent',status:'existing_draft',resumed_existing:true,...governedRecommendation,published:false}
          :{draft_config_version_id:'draft-v2',status:'draft_ready',resumed_existing:false,...governedRecommendation,published:false};
        window.__lastRecommendation=data;
        return {data,error:null};
      }
      return {data:{version_id:'draft-v2'},error:null};
    }};
    async function loyaltyPage(modelOverride,draftVersionId,recommendation,stableRefresh,editorIntent){
      const host=M();
      host.innerHTML='<div id="loyaltyAuthority">'+loyaltyAuthorityActionV140({canManage:!isManager,draftVersionId})+'</div><section class="card" id="loyaltyCustomerRedemption">Customer redemption</section><div class="split"><section class="card" id="loyaltyProgramEditor"><h2>Earning editor</h2><label for="lm">Loyalty model</label><select id="lm"><option>Simple points</option></select><label for="lr">Points needed to redeem</label><input id="lr" value="1000"></section><section class="card" id="loyaltyRewardEditor"><h2>Reward editor</h2><button class="btn sm" id="rwAdd">+ Add reward</button><div class="reward-list" id="rwList">'+fixture.rewards.map(reward=>'<button class="btn ghost sm rwEdit" data-reward-id="'+reward.id+'">Edit '+esc(reward.customer_name)+'</button>').join('')+'</div><div id="rwEditor"></div></section></div><section class="card" id="birthdayEditorCard"><label for="birthdayLabel">Birthday benefit</label><input id="birthdayLabel" value="Birthday Glow"></section>';
      applyGrowLoyaltyEditorIsolationV139(host,editorIntent);
      host.querySelectorAll('.rwEdit').forEach(button=>button.onclick=()=>{
        const reward=fixture.rewards.find(item=>item.id===button.dataset.rewardId);
        window.__openedRewardId=reward?.id||null;
        $('rwEditor').innerHTML='<div class="reward-editor"><label for="rwCustomerName">Customer-facing name</label><input id="rwCustomerName" value="'+esc(reward?.customer_name||'')+'"><p id="openedRewardIdentity">'+esc(reward?.id||'')+'</p></div>';
        pruneRewardSiblingsV139(host);
      });
      if($('rwAdd'))$('rwAdd').onclick=()=>{$('rwEditor').innerHTML='<div class="reward-editor"><label for="rwCustomerName">Customer-facing name</label><input id="rwCustomerName" value=""></div>';pruneRewardSiblingsV139(host)};
    }
    async function storedValuePage(){} async function studioPage(){}
    ${retention}
    ${snapshotAdapter}
    ${journey}
    ${status}
    ${grow}
    window.rewardOverviewMetrics=()=>({sourceHash:'${sourceHash}',role:S.myRole,
      viewport:{clientWidth:document.documentElement.clientWidth,scrollWidth:document.documentElement.scrollWidth},
      title:$('rewardJourneyTitle')?.textContent||'',cards:[...document.querySelectorAll('.grow-programme-row')].map(card=>({tag:card.tagName,programmeKind:card.dataset.programmeKind||null,kind:card.dataset.rewardsOverviewEdit||null,rewardId:card.dataset.rewardId||null,programId:card.dataset.programId||null,href:card.getAttribute('href'),height:card.getBoundingClientRect().height,width:card.getBoundingClientRect().width,text:card.textContent.trim()})),
      editButtons:document.querySelectorAll('[data-rewards-overview-edit]').length,openedRewardId:window.__openedRewardId||null,
      autoSetupButtons:document.querySelectorAll('#growAutoSetup').length,secondaryOpen:$('growSecondarySettings')?.open||false,
      overviewTop:$('rewardJourneyTitle')?.getBoundingClientRect().top||null,secondaryTop:$('growSecondarySettings')?.getBoundingClientRect().top||null,
      recommendationCalls:window.__rpcArgs.filter(call=>call.name==='generate_retention_recommendation').map(call=>call.args),
      growDraftCalls:window.__rpcArgs.filter(call=>call.name==='create_grow_config_draft_v138').map(call=>call.args),
      recommendationResult:window.__lastRecommendation||null,
      dialogOpen:Boolean($('rewardAutoSetupModal')),dialogStep:$('rewardAutoStepTitle')?.textContent||'',
      birthdayRpcCalls:window.__rpcCalls.filter(name=>name==='get_active_birthday_program').length,
      birthdayTableReads:window.__tableReads.filter(name=>name==='birthday_program_versions').length,
      retentionName:$('rn')?.value||'',retentionMissing:Boolean($('retentionExactProgramMissing')),
      authorityLabel:$('loyaltyAuthority')?.textContent.trim()||'',
      editorIntent:M()?.dataset.growEditorIntent||'',programEditors:document.querySelectorAll('#loyaltyProgramEditor').length,
      rewardEditors:document.querySelectorAll('#loyaltyRewardEditor').length,birthdayEditors:document.querySelectorAll('#birthdayEditorCard').length,
      redemptionEditors:document.querySelectorAll('#loyaltyCustomerRedemption').length,rewardLists:document.querySelectorAll('#rwList').length,
      overviewHomeVisible:Boolean(document.querySelector('.grow-hero')?.offsetParent),
      activeElement:document.activeElement?.id||'',consoleErrors:window.__consoleErrors||[]});
    window.__consoleErrors=[];window.addEventListener('error',event=>window.__consoleErrors.push(event.message));
    const routed=(location.hash.startsWith('#/')?location.hash.slice(2):location.hash).split('/');
    const routedSurface=routed[0]==='loyalty'?'rewards':routed[0]==='retention'?'winback':'overview';
    growPage(routedSurface,routed[1]||null,routed[2]||null).catch(error=>{window.__consoleErrors.push(String(error?.stack||error));document.body.dataset.renderError='true'});
    </script></body></html>`;
}

if(process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url){
  await writeFile(FIXTURE_URL,buildRewardOverviewVisualFixture(await readAppSource()));
  process.stdout.write(`${fileURLToPath(FIXTURE_URL)}\n`);
}
