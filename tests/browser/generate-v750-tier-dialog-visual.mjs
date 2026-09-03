import {createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {isDirectCliInvocation} from '../../scripts/quality/is-direct-cli-invocation.mjs';

/* nestly_v750. This harness renders the REAL "Edit tier" / "Add a tier" pop-up (and, in the same
   pass, the referral pop-up nestly_v749 restored `hidden` on) through the production growPage()
   render function against the production stylesheet — same recipe as
   generate-reward-overview-owner-visual.mjs (see that file's nestly_v421 notes for why this beats
   a hand-built approximation: growPage reads a dozen module-scope variables and half a dozen
   helper functions, and a fixture that restates any of them drifts the moment production changes
   one). Extended here only where the tiers/referral pop-ups need reads the overview fixture never
   exercised: loyalty_tiers, tier_benefits_v365, products, services, tier_benefit_scope_v656. */

const APP_URL=new URL('../../app/index.html',import.meta.url);
const APP_SCRIPT_URL=new URL('../../app/app.js',import.meta.url);
const CUI_URL=new URL('../../app/customer-ui.js',import.meta.url);
const readAppSource=async()=>(await Promise.all([readFile(APP_URL,'utf8'),readFile(APP_SCRIPT_URL,'utf8')])).join('\n');
const readComponentLibrary=async()=>readFile(CUI_URL,'utf8');
const FIXTURE_URL=new URL('./v750-tier-dialog-visual.html',import.meta.url);

function sourceBetween(source,start,end){
  const from=source.indexOf(start),to=source.indexOf(end,from+start.length);
  if(from<0||to<=from)throw new Error(`production source section missing: ${start}`);
  return source.slice(from,to).trim();
}

export function buildTierDialogVisualFixture(app,componentLibrary=''){
  const style=app.match(/<style>([\s\S]*?)<\/style>/)?.[1];
  if(!style)throw new Error('production inline stylesheet missing');
  const growBack=sourceBetween(app,'function activeGroupKey(pageKey)','function waitlistBadgeHtml');
  const loyaltyAuthority=sourceBetween(app,'function loyaltyAuthorityActionV140','function growLoyaltyEditorIntentV139');
  const loyaltyIsolation=sourceBetween(app,'function growLoyaltyEditorIntentV139','const refreshLoyaltyPanel');
  const snapshotAdapter=sourceBetween(app,'async function growOverviewSnapshot','function ownerRewardJourneyV122');
  const journey=sourceBetween(app,'function ownerRewardJourneyV122','function growStatus');
  const status=sourceBetween(app,'function growStatus','/* v104 starts');
  const retention=sourceBetween(app,'async function retentionPage(','/* ---------- Grow: one customer journey');
  /* growPage itself, including the whole tiers page (growTiersManageV331), the tier
     add/edit dialog template (growTiersAddFormV331), its click wiring (data-grow-tiers-add-v331,
     data-grow-tiers-row-edit-v345, data-grow-tiers-add-cancel-v331, benefit rows), the referrals
     drilled-topic block and its settings pop-up (growReferralSettingsPanelV364), and that pop-up's
     radio wiring — all one function, extracted whole for the reason the v421 notes above give. */
  const grow=sourceBetween(app,'const GROW_PROGRAMME_VIEWS_V371=','/* ---------- Bring-back playbooks');
  const statusWords=sourceBetween(app,'const STATUS_WORDS=Object.freeze({','const ROLE_LABELS=');
  const growState=sourceBetween(app,"let growTopicV229='';","let settingsActiveTab='modules';");
  const dateFormatters=sourceBetween(app,'function promotionDateTextV104(','function promotionBoundaryV104(');
  const dateShift=sourceBetween(app,'const shiftSgDateInput=(date,days)=>{','/* Calendar helpers must not inherit');
  const usageRanges=sourceBetween(app,'function growUsageShiftMonthsV392(','const REPORT_SHARE_COLOURS_V297=');
  const mediaUrl=sourceBetween(app,'function customerMediaUrlV95(','let customerNavCountsV194=');
  const programmeSpine=sourceBetween(app,'const normaliseLoyaltyModelV375=','function rememberProgrammeSpineV314(');
  const promotionItem=sourceBetween(app,'function promotionEditorItemV104(','function promotionScopeMediaV104(');
  const pendingChanges=sourceBetween(app,'function growRewardDiffFieldsV291(','function growPublishFieldRowsV170(');
  const sourceHash=createHash('sha256').update(`${style}\n${growBack}\n${loyaltyAuthority}\n${loyaltyIsolation}\n${snapshotAdapter}\n${journey}\n${status}\n${retention}\n${componentLibrary}\n${grow}\n${growState}\n${dateFormatters}\n${dateShift}\n${usageRanges}\n${mediaUrl}\n${statusWords}\n${programmeSpine}\n${promotionItem}\n${pendingChanges}`).digest('hex');
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="icon" href="data:,">
    <meta name="production-source-sha256" content="${sourceHash}"><title>Peekaa tier dialog browser acceptance (nestly_v750)</title><style>${style}
    body{padding:24px}.visual-shell{max-width:1180px;margin:0 auto}.visual-provenance{margin:0 0 10px;color:var(--muted);font-size:12px;overflow-wrap:anywhere}
    @media(max-width:600px){body{padding:12px}}</style></head><body><div class="visual-shell"><p class="visual-provenance">Production-component harness · ${sourceHash}</p><main id="main"></main></div>
    <script>${componentLibrary}</script>
    <script>
    const $=id=>document.getElementById(id);
    const esc=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
    const money=cents=>'SGD '+(Number(cents||0)/100).toFixed(2);
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
    const S={myRole:isManager?'manager':'owner',myModules:['loyalty','retention','referrals','memberships','giftcards'],
      biz:{id:'business-v750-fixture',currency:'SGD',industry:'cafe'}};
    const canWriteModule=module=>!isManager&&S.myModules.includes(module);
    /* The tiers page gates almost everything on the programme SPINE (programmeSpineRowsV314),
       which production populates from a business_programmes read at bootstrap. This fixture never
       runs that bootstrap, so it is set directly here — a live 'tiers' row, matching the shape
       programmeSpineRowV428 produces (kind/active), which is what programmeSpineOnV314('tiers')
       and liveLoyaltyModelKeysV240 both key off. */
    S.programmes=[{kind:'tiers',active:true},{kind:'points',active:false},{kind:'stamps',active:false},{kind:'referral',active:true}];
    S.programmesBusinessId=S.biz.id;
    /* Real production value (app/app.js): gates Memberships out of growTopicDefsV229. Declared,
       not extracted, because it is a one-line literal with nothing else worth pulling in around
       it — same call the reward-overview generator makes for its own small constants. */
    const UNVERIFIED_MODULES_V466=['memberships','giftcards'];
    /* Stubbed: the workspace-i18n attribute machinery (server-authored copy translation) is
       orthogonal to layout, and this fixture is not evidence about translated copy. */
    const workspaceTemplateAttributeV97=()=>'';
    const workspaceTemplateTextV97=(key,values={})=>key+' '+JSON.stringify(values);
    /* Stubbed: a customer-side stamp-card preview widget, unrelated to the tier/referral dialogs
       this fixture measures. */
    const customerHeroStampCardV422=()=>'';
    /* Real production pagination helper (app/app.js) — a one-line pure function, declared rather
       than extracted for the same reason UNVERIFIED_MODULES_V466 is above. Used by the Limited
       Offer tab strip, which growPage renders even off the tiers/referral surfaces this fixture
       targets. */
    const PAGE_SIZE_V584=20;
    const pageCountV584=total=>Math.max(1,Math.ceil(Math.max(0,Number(total)||0)/PAGE_SIZE_V584));
    /* Stubbed: an async WhatsApp-automation card loader with its own network reads, unrelated to
       the tier/referral dialogs this fixture measures. */
    const loadGrowWaAutomationCardV583=async()=>{};
    const loadGrowBbWhatsappStripV551=async()=>{};
    const wirePagerV584=(host,scope,go)=>{
      if(!host)return;
      host.querySelectorAll(\`[data-pager-v584="\${scope}"] [data-pager-go-v584]\`).forEach(button=>{
        button.onclick=()=>{const target=Number(button.dataset.pagerGoV584);if(Number.isFinite(target))go(Math.max(0,target))};
      });
    };
    /* Two tiers already saved, so the "Edit tier" dialog (the one the owner circled) has a real
       row to open, alongside the "+ Add tier" dialog. */
    const fixture={
      loyalty:{id:'programme-1',active:true,loyalty_model:'points_tiers',earn_points_per_dollar:10,redeem_points:1000,reward_credit_cents:1000,expiry_mode:'inactivity',expiry_days:365},
      rewards:[],
      birthday:null,
      tiers:[
        {id:'tier-1',name:'Gold',threshold:1000,points_multiplier:1,perk_note:'10% off every visit',sort:1,paused:false,deleted_at:null,effective_from:null,expires_at:null},
        {id:'tier-2',name:'Diamond',threshold:5000,points_multiplier:1.5,perk_note:'Free birthday item',sort:2,paused:false,deleted_at:null,effective_from:null,expires_at:null}],
      tierBenefits:[
        {id:'benefit-1',tier_id:'tier-1',label:'10% off',limit_count:null,limit_period:null,sort:1,benefit_kind:'discount_pct',discount_percent:10,product_id:null,item_label:null}],
      products:[{id:'product-1',name:'Iced Latte'}],
      services:[{id:'service-1',name:'Table service'}],
      retention:[],bbCampaigns:[],
      taxonomy:[],
      referral:{id:'referral-1',enabled:true,reward_cents:1000,min_spend_cents:5000,reward_kind:'points',
        reward_label:'',friend_enabled:true,friend_reward_points:null,friend_reward_label:''},
      memberships:[],
      giftcardPreferences:{status:'available',gift_card_sales_enabled:false,package_earns_points:false}};
    window.__tableReads=[];window.__rpcCalls=[];window.__rpcArgs=[];
    function fixtureQuery(table){
      const state={single:false,equals:{}};
      const query={select(){return query},eq(column,value){state.equals[column]=value;return query},is(){return query},in(){return query},not(){return query},gte(){return query},lte(){return query},order(){return query},limit(){return query},single(){state.single=true;return query},
        then(resolve,reject){window.__tableReads.push(table);let data=[];
          if(table==='businesses')data={active_config_version_id:'published-v1'};
          else if(table==='loyalty_programs')data=fixture.loyalty?[fixture.loyalty]:[];
          else if(table==='loyalty_rewards')data=fixture.rewards;
          else if(table==='loyalty_tiers')data=fixture.tiers;
          else if(table==='tier_benefits_v365')data=fixture.tierBenefits;
          else if(table==='tier_benefit_scope_v656')data=[];
          else if(table==='products')data=fixture.products;
          else if(table==='services')data=fixture.services;
          else if(table==='retention_programs')data=fixture.retention;
          else if(table==='bringback_campaigns_v361')data=fixture.bbCampaigns;
          else if(table==='referral_programs')data=fixture.referral?[fixture.referral]:[];
          else if(table==='membership_plans')data=fixture.memberships;
          else if(table==='firm_config_versions')data=state.equals.status==='draft'?[]:[{id:'published-v1',version_no:1,status:'published',snapshot_hash:'published-hash'}];
          else if(table==='firm_reward_taxonomy')data=fixture.taxonomy;
          return Promise.resolve({data,error:null}).then(resolve,reject)}};
      return query;
    }
    const sb={from:fixtureQuery,rpc:async(name,args)=>{window.__rpcCalls.push(name);window.__rpcArgs.push({name,args});
      if(name==='get_active_birthday_program')return {data:{status:'published',as_of:'2026-08-01T00:00:00.000Z',programs:[]},error:null};
      if(name==='owner_list_reward_profitability_products_v122')return {data:{items:[]},error:null};
      if(name==='business_get_checkout_preferences_v102')return {data:fixture.giftcardPreferences,error:null};
      if(name==='get_retention_config_draft')return {data:{programs:fixture.retention,taxonomy:fixture.taxonomy,snapshot_hash:'draft-hash'},error:null};
      if(name==='business_get_welcome_offer_v215')return {data:{status:'none'},error:null};
      if(name==='business_programme_usage_v271')return {data:{items:[]},error:null};
      return {data:{version_id:'draft-v2'},error:null};
    }};
    async function loyaltyPage(){}
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
    /* Measurement surface for the verify script. Everything below reads the rendered dialog, not a
       restated approximation of it — the same discipline the generator comment above explains. */
    window.tierDialogMetrics=()=>{
      const dialog=document.querySelector('[data-grow-tiers-addform-v331]');
      const readEl=(el)=>{if(!el)return null;const cs=getComputedStyle(el);const r=el.getBoundingClientRect();
        return {paddingTop:parseFloat(cs.paddingTop),paddingRight:parseFloat(cs.paddingRight),paddingBottom:parseFloat(cs.paddingBottom),paddingLeft:parseFloat(cs.paddingLeft),
          top:r.top,left:r.left,right:r.right,bottom:r.bottom,width:r.width,height:r.height,display:cs.display,flexDirection:cs.flexDirection};};
      const paragraphs=[...document.querySelectorAll('[data-grow-tiers-addform-v331] .grow-setup-sentence-v301:not(.row)')].map(p=>{
        const label=p.querySelector('label'),input=p.querySelector('input,select,textarea');
        const labelRect=label?label.getBoundingClientRect():null,inputRect=input?input.getBoundingClientRect():null;
        return {id:p.id||null,labelText:label?label.textContent.trim():null,
          rect:p.getBoundingClientRect(),labelRect,inputRect,
          labelToInputGap:(labelRect&&inputRect)?(inputRect.top-labelRect.bottom):null};
      });
      const title=dialog?dialog.querySelector('.grow-points-form-head-v485 b, #growTiersFormTitleV658'):null;
      return {dialogPresent:Boolean(dialog),dialog:readEl(dialog),
        dialogRight:dialog?dialog.getBoundingClientRect().right:null,
        viewportWidth:document.documentElement.clientWidth,
        title:title?{text:title.textContent.trim(),rect:title.getBoundingClientRect()}:null,
        head:readEl(dialog?dialog.querySelector('.grow-points-form-head-v485'):null),
        paragraphs};
    };
    window.referralWrapMetrics=()=>{
      const ids=['growReferralGiftWrapV420','growReferralFriendGiftWrapV421','growReferralPointsWrapV420','growReferralFriendPointsWrapV421'];
      return Object.fromEntries(ids.map(id=>{
        const el=$(id);
        if(!el)return [id,null];
        const r=el.getBoundingClientRect();
        return [id,{hidden:el.hasAttribute('hidden'),offsetParent:Boolean(el.offsetParent),height:r.height,display:getComputedStyle(el).display}];
      }));
    };
    window.matchedCascadeFor=(selectorForElement)=>{
      const el=document.querySelector(selectorForElement);
      if(!el)return null;
      const winners=[];
      for(const sheet of document.styleSheets){
        let rules;try{rules=sheet.cssRules}catch(error){continue}
        for(const rule of rules){
          if(!rule.selectorText)continue;
          try{if(el.matches(rule.selectorText))winners.push({selector:rule.selectorText,cssText:rule.style.cssText});}catch(error){}
        }
      }
      return winners;
    };
    window.__consoleErrors=[];window.addEventListener('error',event=>window.__consoleErrors.push(event.message));
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

if(isDirectCliInvocation(import.meta.url)){
  await writeFile(FIXTURE_URL,buildTierDialogVisualFixture(await readAppSource(),await readComponentLibrary()));
  process.stdout.write(`${fileURLToPath(FIXTURE_URL)}\n`);
}
