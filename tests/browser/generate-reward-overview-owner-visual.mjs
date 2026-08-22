import {createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {fileURLToPath,pathToFileURL} from 'node:url';

const APP_URL=new URL('../../app/index.html',import.meta.url);
/* The application script was extracted from index.html into app.js. The .test.mjs files
   pass both files joined; this CLI path must read the same pair or it regenerates a
   fixture from a file that no longer contains the components. */
const APP_SCRIPT_URL=new URL('../../app/app.js',import.meta.url);
/* nestly_v421: the REAL shared component library. The harness used to hand-stub CUI, and its
   icon() mapped eight names to bullet characters — on a page whose whole v401 pass was about
   icons, that made the evidence say nothing about the thing it was evidence of. It is inlined
   (not <script src>) so the fixture stays a single self-contained file, and it is part of the
   source hash, so an icon change restales this evidence exactly as a render change does. */
const CUI_URL=new URL('../../app/customer-ui.js',import.meta.url);
const readAppSource=async()=>(await Promise.all([readFile(APP_URL,'utf8'),readFile(APP_SCRIPT_URL,'utf8')])).join('\n');
const readComponentLibrary=async()=>readFile(CUI_URL,'utf8');
const FIXTURE_URL=new URL('./reward-overview-owner-visual.html',import.meta.url);

function sourceBetween(source,start,end){
  const from=source.indexOf(start),to=source.indexOf(end,from+start.length);
  if(from<0||to<=from)throw new Error(`production source section missing: ${start}`);
  return source.slice(from,to).trim();
}

export function buildRewardOverviewVisualFixture(app,componentLibrary=''){
  const style=app.match(/<style>([\s\S]*?)<\/style>/)?.[1];
  if(!style)throw new Error('production inline stylesheet missing');
  /* V296: growBackActionHtmlV138 was deleted with the owner's "remove" on the grow submodule
     headers (2026-08-12). The slice it named is still extracted — activeGroupKey and the badge
     helpers live in it and the fixture's rail needs them — it is simply anchored on the block that
     survived rather than on a function that no longer exists. */
  const growBack=sourceBetween(app,'function activeGroupKey(pageKey)','function waitlistBadgeHtml');
  const loyaltyAuthority=sourceBetween(app,'function loyaltyAuthorityActionV140','function growLoyaltyEditorIntentV139');
  const loyaltyIsolation=sourceBetween(app,'function growLoyaltyEditorIntentV139','const refreshLoyaltyPanel');
  const snapshotAdapter=sourceBetween(app,'async function growOverviewSnapshot','function ownerRewardJourneyV122');
  const journey=sourceBetween(app,'function ownerRewardJourneyV122','function growStatus');
  const status=sourceBetween(app,'function growStatus','/* v104 starts');
  const retention=sourceBetween(app,'async function retentionPage(','/* ---------- Grow: one customer journey');
  /* nestly_v421: anchored one declaration earlier. GROW_PROGRAMME_VIEWS_V371 is the list growPage
     matches its own hash against and it sits immediately above the function, so slicing from
     'async function growPage(' left the page reading an undefined constant. */
  const grow=sourceBetween(app,'const GROW_PROGRAMME_VIEWS_V371=','/* ---------- Bring-back playbooks');
  /* V299: growPage now normalizes each promotion row through promotionEditorItemV104 (the V295
     "can straightaway go inside see which promotions available" drilling). The fixture ran the
     real growPage without that helper, so it threw before #rewardJourneyTitle ever rendered. */
  /* nestly_v421: growPage reads the PROGRAMME SPINE (which programmes this firm is running, and
     whether it counts points or stamps) throughout — the row names, the exclusivity warning, the
     Live/Paused pill. None of it was in the fixture, so the page threw a ReferenceError before
     #rewardJourneyTitle ever rendered and the harness sat on its loading state. Extracted from
     production rather than stubbed: these are pure readers over S.programmes, so running the real
     ones is both easier and more honest than inventing lookalikes. */
  /* The status vocabulary is a single source of truth in production (STATUS_WORDS) and every pill
     reads it through statusOnOff. Extracted, not restated, so a change to the words shows up in
     this evidence rather than being contradicted by it. */
  const statusWords=sourceBetween(app,'const STATUS_WORDS=Object.freeze({','const ROLE_LABELS=');
  /* nestly_v421: the Grow module's own state — the open tab, the date windows, which group is
     expanded, the half-typed draft a re-render must not eat. growPage reads a dozen of these and
     the harness declared two of them, so the page threw on the first one it reached. Extracted
     whole rather than restated one at a time: a fixture that declares its own copies drifts the
     moment production adds another, which is exactly how this one ended up stuck. */
  const growState=sourceBetween(app,"let growTopicV229='';","let settingsActiveTab='modules';");
  /* nestly_v421: the two date formatters the tables print through. The harness restated the long
     one by hand and did not have the short one at all — and a hand-restated formatter is the one
     thing this evidence must not carry, since "all dates use dd/mm/yyyy" (V324) is a rule an
     owner asked for and the screenshots are how it is checked. */
  const dateFormatters=sourceBetween(app,'function promotionDateTextV104(','function promotionBoundaryV104(');
  /* nestly_v421: the usage card's date windows — the quick ranges (This week / Last month / …) and
     the comparison arithmetic behind them, plus the day-shift helper they are built on. Real
     production functions, because they compute the dates the screenshots are evidence OF. */
  const dateShift=sourceBetween(app,'const shiftSgDateInput=(date,days)=>{','/* Calendar helpers must not inherit');
  const usageRanges=sourceBetween(app,'function growUsageShiftMonthsV392(','const REPORT_SHARE_COLOURS_V297=');
  /* nestly_v421: the gift rows show the photo a merchant uploaded, and this is the one helper that
     turns a stored object path into a url. Extracted rather than stubbed because its whitelist of
     image KINDS is a rule (v418: it must agree with app.v95_storage_path_owned), and a stub would
     quietly render kinds production refuses. */
  const mediaUrl=sourceBetween(app,'function customerMediaUrlV95(','let customerNavCountsV194=');
  const programmeSpine=sourceBetween(app,'const normaliseLoyaltyModelV375=','function rememberProgrammeSpineV314(');
  const promotionItem=sourceBetween(app,'function promotionEditorItemV104(','function promotionScopeMediaV104(');
  /* V299: growPage also reads the V291 pending-changes helpers when it summarizes a draft. */
  const pendingChanges=sourceBetween(app,'function growRewardDiffFieldsV291(','function growPublishFieldRowsV170(');
  const sourceHash=createHash('sha256').update(`${style}\n${growBack}\n${loyaltyAuthority}\n${loyaltyIsolation}\n${snapshotAdapter}\n${journey}\n${status}\n${retention}\n${componentLibrary}\n${grow}\n${growState}\n${dateFormatters}\n${dateShift}\n${usageRanges}\n${mediaUrl}\n${statusWords}\n${programmeSpine}\n${promotionItem}\n${pendingChanges}`).digest('hex');
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="icon" href="data:,">
    <meta name="production-source-sha256" content="${sourceHash}"><title>Peekaa rewards overview browser acceptance</title><style>${style}
    body{padding:24px}.visual-shell{max-width:1180px;margin:0 auto}.visual-provenance{margin:0 0 10px;color:var(--muted);font-size:12px;overflow-wrap:anywhere}
    @media(max-width:600px){body{padding:12px}}</style></head><body><div class="visual-shell"><p class="visual-provenance">Production-component harness · ${sourceHash}</p><main id="main"></main></div>
    <script>${componentLibrary}</script>
    <script>
    const $=id=>document.getElementById(id);
    const esc=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
    const money=cents=>'SGD '+(Number(cents||0)/100).toFixed(2);
    /* nestly_v421: the REAL shared component library (app/customer-ui.js), inlined above as
       FrenlyCustomerUI — the same object production binds CUI to. It used to be hand-stubbed
       here, with icon() mapping eight names to bullet characters, which made this fixture useless
       as evidence about icons: exactly what the v401 pass on this page was about. */
    const CUI=window.FrenlyCustomerUI;
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
    ${dateFormatters}
    ${dateShift}
    ${usageRanges}
    const SB_URL='https://fixture.supabase.co';
    ${mediaUrl}
    const fail=error=>{throw error};
    const toast=message=>{window.__lastToast=message};
    /* Real navigation — see renderFromHashV421 at the foot of this harness. */
    const nav=hash=>{if(typeof hash==='string'&&hash.startsWith('#')){location.hash=hash;window.__renderFromHashV421?.()}};
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
      /* nestly_v421: the Bring-back page reads bringback_campaigns_v361, the table v361 gave it —
         NOT retention_programs, which is what this fixture carried and what the overview rows used
         to read. Without it the page the Bring-back tile opens is permanently empty, which is what
         it rendered when this harness was first made to run again. One live campaign and one the
         firm has paused, so both states are on screen. */
      bbCampaigns:emptyPrograms?[]:[
        {id:'bring-back-1',name:'Glow regular return',reward_label:'Glow credit',away_days:30,expiry_days:30,active:!configuredOff,created_at:'2026-08-01T00:00:00.000Z'},
        {id:'bring-back-2',name:'Paused facial return',reward_label:'Glow credit',away_days:60,expiry_days:30,active:false,created_at:'2026-08-02T00:00:00.000Z'}],
      referral:emptyPrograms?null:{id:'referral-1',enabled:!configuredOff,reward_cents:1000,min_spend_cents:5000},
      memberships:emptyPrograms?[]:[{id:'membership-1',name:'Glow Monthly',active:!configuredOff}],
      giftcardPreferences:{status:'available',gift_card_sales_enabled:false,package_earns_points:false}};
    window.__tableReads=[];window.__rpcCalls=[];window.__rpcArgs=[];window.__recommendationFailed=false;
    /* v229's topic filter, the v386 usage window and the rest of the Grow module state used to be
       restated here one variable at a time; they come from production now (growState above). */
    function fixtureQuery(table){
      const state={single:false,equals:{}};
      const query={select(){return query},eq(column,value){state.equals[column]=value;return query},is(){return query},in(){return query},not(){return query},gte(){return query},lte(){return query},order(){return query},limit(){return query},single(){state.single=true;return query},
        then(resolve,reject){window.__tableReads.push(table);let data=[];
          if(table==='businesses')data={active_config_version_id:fixture.currentVersion};
          else if(table==='loyalty_programs')data=fixture.loyalty?[fixture.loyalty]:[];
          else if(table==='loyalty_rewards')data=fixture.rewards;
          else if(table==='retention_programs')data=fixture.retention;
          else if(table==='bringback_campaigns_v361')data=fixture.bbCampaigns;
          else if(table==='referral_programs')data=fixture.referral?[fixture.referral]:[];
          else if(table==='membership_plans')data=fixture.memberships;
          else if(table==='firm_config_versions')data=state.equals.status==='draft'?(fixture.draft?[fixture.draft]:[]):[{id:'published-v1',version_no:1,status:'published',snapshot_hash:'published-hash'}];
          else if(table==='firm_reward_taxonomy')data=fixture.taxonomy;
          /* nestly_v456 (audit A). 'bringback_campaigns_v361' joins this set because nestly_v429
             moved the Bring-back tile's read there — growRewardsSnapshot's retentionRequest is
             that table now, and public.retention_programs is no longer read by this page at all.
             The failure set had not moved with it, so \`partial=all\` left the one table the tile
             actually depends on answering NORMALLY: the tile rendered a real, data-backed state
             ("On / View") while the walkthrough asserted 'Unavailable', and the read-failure path
             it exists to prove was never executed. retention_programs stays listed — harmless,
             and the day a reader comes back to it the fixture is already honest about it. */
          const failedTables=partialOverview==='all'
            ?new Set(['loyalty_programs','loyalty_rewards','retention_programs',
              'bringback_campaigns_v361','referral_programs','membership_plans'])
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
      if(name==='business_get_welcome_offer_v215')return {data:{status:'none'},error:null};
      if(name==='business_programme_usage_v271')return {data:{items:[]},error:null};
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
    ${growState}
    ${statusWords}
    ${programmeSpine}
    ${promotionItem}
    ${pendingChanges}
    ${grow}
    window.rewardOverviewMetrics=()=>({sourceHash:'${sourceHash}',role:S.myRole,
      viewport:{clientWidth:document.documentElement.clientWidth,scrollWidth:document.documentElement.scrollWidth},
      /* nestly_v421: the landing's programme cards are .grow-topic-card-v343, keyed by
         data-grow-topic-v229 — the V343/V362 restructure that turned .grow-programme-row into a
         tile grid. Both selectors are read, so this measurement survives the next one: the old
         rows are still what a DRILLED view renders. */
      title:$('rewardJourneyTitle')?.textContent||'',cards:[...document.querySelectorAll('.grow-topic-card-v343,.grow-programme-row')].map(card=>({tag:card.tagName,programmeKind:card.dataset.growTopicV229||card.dataset.programmeKind||null,kind:card.dataset.rewardsOverviewEdit||null,rewardId:card.dataset.rewardId||null,programId:card.dataset.programId||null,href:card.getAttribute('href'),height:card.getBoundingClientRect().height,width:card.getBoundingClientRect().width,text:card.textContent.trim()})),
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
    /* nestly_v421: nav() was a no-op, so every tile that DRILLS (#/grow/points, #/grow/tiers,
       #/grow/bringback — which is how this landing works since V326/V331/V358) did nothing at all
       when clicked and the walkthrough could only ever see the landing. It routes for real now:
       set the hash, re-render from it, exactly as the app's own router does. */
    function renderFromHashV421(){
      const routed=(location.hash.startsWith('#/')?location.hash.slice(2):location.hash).split('/');
      const routedSurface=routed[0]==='loyalty'?'rewards':routed[0]==='retention'?'winback':'overview';
      const hashParam=routed[0]==='grow'?(routed[1]||null):(routed[1]||null);
      return growPage(routedSurface,hashParam,routed[2]||null,{fromRouteV288:true})
        .catch(error=>{window.__consoleErrors.push(String(error?.stack||error));document.body.dataset.renderError='true'});
    }
    window.__renderFromHashV421=renderFromHashV421;
    renderFromHashV421();
    </script></body></html>`;
}

if(process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url){
  await writeFile(FIXTURE_URL,buildRewardOverviewVisualFixture(await readAppSource(),await readComponentLibrary()));
  process.stdout.write(`${fileURLToPath(FIXTURE_URL)}\n`);
}
