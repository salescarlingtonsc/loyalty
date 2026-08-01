import {createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {fileURLToPath,pathToFileURL} from 'node:url';

const APP_URL=new URL('../../app/index.html',import.meta.url);
const FIXTURE_URL=new URL('./reward-overview-owner-visual.html',import.meta.url);

function sourceBetween(source,start,end){
  const from=source.indexOf(start),to=source.indexOf(end,from+start.length);
  if(from<0||to<=from)throw new Error(`production source section missing: ${start}`);
  return source.slice(from,to).trim();
}

export function buildRewardOverviewVisualFixture(app){
  const style=app.match(/<style>([\s\S]*?)<\/style>/)?.[1];
  if(!style)throw new Error('production inline stylesheet missing');
  const snapshotAdapter=sourceBetween(app,'async function growOverviewSnapshot','function ownerRewardJourneyV122');
  const journey=sourceBetween(app,'function ownerRewardJourneyV122','function growStatus');
  const status=sourceBetween(app,'function growStatus','/* v104 starts');
  const grow=sourceBetween(app,'async function growPage(','/* ---------- Bring-back playbooks');
  const sourceHash=createHash('sha256').update(`${style}\n${snapshotAdapter}\n${journey}\n${status}\n${grow}`).digest('hex');
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <meta name="production-source-sha256" content="${sourceHash}"><title>Nestly rewards overview browser acceptance</title><style>${style}
    body{padding:24px}.visual-shell{max-width:1180px;margin:0 auto}.visual-provenance{margin:0 0 10px;color:var(--muted);font-size:12px;overflow-wrap:anywhere}
    @media(max-width:600px){body{padding:12px}}</style></head><body><div class="visual-shell"><p class="visual-provenance">Production-component harness · ${sourceHash}</p><main id="main"></main></div>
    <script>
    const $=id=>document.getElementById(id);
    const esc=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
    const money=cents=>'SGD '+(Number(cents||0)/100).toFixed(2);
    const CUI={icon:(name)=>'<span aria-hidden="true">'+({till:'◎',loyalty:'★',customers:'●',retention:'↺',inventory:'□',referrals:'↗',memberships:'◇',giftcard:'▣'}[name]||'•')+'</span>',
      loadingState:({title})=>'<section class="card">Loading '+esc(title)+'…</section>',
      emptyState:({title,body})=>'<div class="empty"><b>'+esc(title)+'</b><p>'+esc(body)+'</p></div>',announce:()=>{}};
    const workspaceLocale='en';
    const workspaceTemplateHtmlV97=(key,{count,version}={})=>key==='growDraftReady'?'Draft '+version+' is ready. Review every step before publishing.':count+' published '+(count===1?'reward':'rewards');
    const recordProductInteractionV100=()=>{};
    const localizeWorkspaceSubtreeV97=()=>{};
    const productProfitabilityV122=()=>null;
    const fail=error=>{throw error};
    const toast=message=>{window.__lastToast=message};
    const nav=()=>{};
    const routeDispose=null;
    const M=()=>document.getElementById('main');
    const evidenceParams=new URLSearchParams(location.search);
    const isManager=evidenceParams.get('role')==='manager';
    const S={myRole:isManager?'manager':'owner',myModules:['loyalty'],biz:{id:'business-spa-glow',currency:'SGD',industry:'Facial / Spa'}};
    const canWriteModule=module=>!isManager&&module==='loyalty';
    const fixture={currentVersion:'published-v1',draft:isManager?null:{id:'draft-v2',version_no:2},
      loyalty:{id:'programme-1',active:true,loyalty_model:'points_tiers',earn_points_per_dollar:10,redeem_points:1000,reward_credit_cents:1000,expiry_mode:'inactivity',expiry_days:365},
      rewards:[
        {id:'11111111-1111-4111-8111-111111111111',active:true,customer_name:'Signature reward',cost_points:500,estimated_cost_cents:400,sort:1},
        {id:'22222222-2222-4222-8222-222222222222',active:true,customer_name:'Signature reward',cost_points:1500,estimated_cost_cents:900,sort:2},
        {id:'33333333-3333-4333-8333-333333333333',active:false,customer_name:'Seasonal facial',cost_points:750,sort:3}],
      birthday:{program_id:'birthday-1',active:true,customer_label:'Birthday Glow',customer_description:'Available during the birthday month.',fulfillment_kind:'discount_pct',discount_percent:20},
      products:[],retention:[]};
    window.__tableReads=[];window.__rpcCalls=[];
    function fixtureQuery(table){
      const state={single:false};
      const query={select(){return query},eq(){return query},is(){return query},order(){return query},limit(){return query},single(){state.single=true;return query},
        then(resolve,reject){window.__tableReads.push(table);let data=[];
          if(table==='businesses')data={active_config_version_id:fixture.currentVersion};
          else if(table==='loyalty_programs')data=[fixture.loyalty];
          else if(table==='loyalty_rewards')data=fixture.rewards;
          else if(table==='retention_programs')data=fixture.retention;
          else if(table==='firm_config_versions')data=fixture.draft?[fixture.draft]:[];
          return Promise.resolve({data,error:null}).then(resolve,reject)}};
      return query;
    }
    const sb={from:fixtureQuery,rpc:async(name)=>{window.__rpcCalls.push(name);
      if(name==='get_active_birthday_program')return {data:{status:'published',as_of:'2026-08-01T00:00:00.000Z',programs:[fixture.birthday]},error:null};
      if(name==='owner_list_reward_profitability_products_v122')return {data:{items:fixture.products},error:null};
      return {data:{version_id:'draft-v2'},error:null};
    }};
    async function loyaltyPage(){
      const host=M();
      host.innerHTML='<section class="card"><h2>Rewards and earning editor</h2><label for="lm">Loyalty model</label><select id="lm"><option>Simple points</option></select><label for="lr">Points needed to redeem</label><input id="lr" value="1000"><button class="btn sm" id="rwAdd">+ Add reward</button><div class="reward-list">'+fixture.rewards.map(reward=>'<button class="btn ghost sm rwEdit" data-reward-id="'+reward.id+'">Edit '+esc(reward.customer_name)+'</button>').join('')+'</div><div id="rwEditor"></div><label for="birthdayLabel">Birthday benefit</label><input id="birthdayLabel" value="Birthday Glow"></section>';
      host.querySelectorAll('.rwEdit').forEach(button=>button.onclick=()=>{
        const reward=fixture.rewards.find(item=>item.id===button.dataset.rewardId);
        window.__openedRewardId=reward?.id||null;
        $('rwEditor').innerHTML='<div class="reward-editor"><label for="rwCustomerName">Customer-facing name</label><input id="rwCustomerName" value="'+esc(reward?.customer_name||'')+'"><p id="openedRewardIdentity">'+esc(reward?.id||'')+'</p></div>';
      });
      $('rwAdd').onclick=()=>{$('rwEditor').innerHTML='<div class="reward-editor"><input id="rwCustomerName" value=""></div>'};
    }
    async function retentionPage(){} async function storedValuePage(){} async function studioPage(){}
    ${snapshotAdapter}
    ${journey}
    ${status}
    ${grow}
    window.rewardOverviewMetrics=()=>({sourceHash:'${sourceHash}',role:S.myRole,
      viewport:{clientWidth:document.documentElement.clientWidth,scrollWidth:document.documentElement.scrollWidth},
      title:$('rewardJourneyTitle')?.textContent||'',cards:[...document.querySelectorAll('.rewards-overview-card')].map(card=>({tag:card.tagName,kind:card.dataset.rewardsOverviewEdit||null,rewardId:card.dataset.rewardId||null,height:card.getBoundingClientRect().height,width:card.getBoundingClientRect().width,text:card.textContent.trim()})),
      editButtons:document.querySelectorAll('[data-rewards-overview-edit]').length,openedRewardId:window.__openedRewardId||null,
      birthdayRpcCalls:window.__rpcCalls.filter(name=>name==='get_active_birthday_program').length,
      birthdayTableReads:window.__tableReads.filter(name=>name==='birthday_program_versions').length,
      activeElement:document.activeElement?.id||'',consoleErrors:window.__consoleErrors||[]});
    window.__consoleErrors=[];window.addEventListener('error',event=>window.__consoleErrors.push(event.message));
    growPage('overview',null).catch(error=>{window.__consoleErrors.push(String(error?.stack||error));document.body.dataset.renderError='true'});
    </script></body></html>`;
}

if(process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url){
  await writeFile(FIXTURE_URL,buildRewardOverviewVisualFixture(await readFile(APP_URL,'utf8')));
  process.stdout.write(`${fileURLToPath(FIXTURE_URL)}\n`);
}
