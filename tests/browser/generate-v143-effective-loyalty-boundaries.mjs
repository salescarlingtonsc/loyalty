import {createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {fileURLToPath,pathToFileURL} from 'node:url';

const APP_URL=new URL('../../app/index.html',import.meta.url);
const FIXTURE_URL=new URL('./v143-effective-loyalty-boundaries.html',import.meta.url);

function sourceBetween(source,start,end){
  const from=source.indexOf(start),to=source.indexOf(end,from+start.length);
  if(from<0||to<=from)throw new Error(`production source section missing: ${start}`);
  return source.slice(from,to).trim();
}

export function buildV143Fixture(app){
  const style=app.match(/<style>([\s\S]*?)<\/style>/)?.[1];
  if(!style)throw new Error('production inline stylesheet missing');
  const boundaries=sourceBetween(app,'const boundaryInputValue=','const eligibilitySummary=');
  const authoring=sourceBetween(app,'const productById=','const firmExpiryMode=');
  const retryClient=sourceBetween(app,'const writeAttemptKey=','/* Server replay signal');
  const sourceHash=createHash('sha256').update(`${style}\n${boundaries}\n${authoring}\n${retryClient}`).digest('hex');
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="production-source-sha256" content="${sourceHash}"><title>Peekaa v143 effective loyalty acceptance</title><style>${style}
  body{padding:24px}.v143-shell{max-width:1120px;margin:0 auto}.evidence{font-size:12px;color:var(--muted);overflow-wrap:anywhere;margin-bottom:14px}
  .boundary-list{display:grid;gap:10px}.boundary-row{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:12px;padding:14px 0;border-bottom:1px solid var(--line)}
  .boundary-row:last-child{border-bottom:0}.boundary-row p{margin-top:5px}.actions{display:flex;align-items:center;gap:8px}.editor-grid{display:grid;grid-template-columns:1fr 1fr;gap:12px}.authoring-grid{display:grid;grid-template-columns:1fr 1fr;gap:12px}.authoring-grid .full{grid-column:1/-1}
  @media(max-width:600px){body{padding:12px}.card{padding:16px}.editor-grid,.authoring-grid{grid-template-columns:1fr}.authoring-grid .full{grid-column:auto}.boundary-row{grid-template-columns:minmax(0,1fr)}.actions{justify-content:flex-start}.cui-page-title h1{font-size:1.55rem}}
  </style></head><body><main class="v143-shell"><p class="evidence">Production-component harness · ${sourceHash}</p><div id="main"></div></main><script>
  const esc=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
  ${boundaries}
  ${retryClient}
  const params=new URLSearchParams(location.search),role=params.get('role')||'owner',state=params.get('state')||'ready';
  const tierDefaultCalls=[];
  let committedDefaults=null,loseFirstDefaultsResponse=params.get('defaultsLost')==='1';
  const v143Client={rpc:async(name,args)=>{
    if(name!=='add_recommended_loyalty_tiers_v143')throw new Error('Unexpected RPC '+name);
    tierDefaultCalls.push({name,args});
    committedDefaults??={status:'draft_ready',published:false,version_id:'00000000-0000-4000-8000-000000000143',tier_ids:['member','plus','vip']};
    if(loseFirstDefaultsResponse){loseFirstDefaultsResponse=false;return {data:null,error:{message:'Synthetic response lost after commit'}}}
    return {data:committedDefaults,error:null};
  }};
  const now=Date.parse('2026-08-02T12:00:00+08:00');
  const rewards=[
    {name:'Glow Facial',active:true,cost_points:500,claim_available_from:'2026-08-01T00:00:00+08:00',claim_available_until:'2026-08-03T00:00:00+08:00'},
    {name:'Radiance Facial',active:true,cost_points:900,claim_available_from:'2026-08-03T00:00:00+08:00'},
    {name:'July Glow',active:true,cost_points:450,claim_available_until:'2026-08-02T12:00:00+08:00'},
    {name:'Paused Facial',active:false,cost_points:300}
  ];
  const tiers=[
    {name:'Glow',threshold:0,active:true,effective_from:'2026-08-01T00:00:00+08:00',expires_at:'2026-08-03T00:00:00+08:00'},
    {name:'Radiance',threshold:5,active:true,effective_from:'2026-08-03T00:00:00+08:00'},
    {name:'Silver July',threshold:2,active:true,expires_at:'2026-08-02T12:00:00+08:00'},
    {name:'Paused VIP',threshold:8,active:false}
  ];
  const status=(item,start,end)=>boundaryState(item,start,end,now);
  const pill=value=>'<span class="pill '+value.tone+'">'+esc(value.label)+'</span>';
  const range=(item,start,end)=>[item[start]?'Starts '+boundaryInputValue(item[start]).replace('T',' '):'',item[end]?'Ends '+boundaryInputValue(item[end]).replace('T',' '):''].filter(Boolean).join(' · ')||'No date boundary';
  const row=(item,type,action)=>{const isReward=type==='reward',s=status(item,isReward?'claim_available_from':'effective_from',isReward?'claim_available_until':'expires_at');return '<div class="boundary-row" data-kind="'+type+'" data-status="'+s.key+'"><div><div class="inline-status"><b>'+esc(item.name)+'</b>'+pill(s)+'</div><p class="muted small">'+esc(isReward?item.cost_points+' points':item.threshold+' visits')+' · '+esc(range(item,isReward?'claim_available_from':'effective_from',isReward?'claim_available_until':'expires_at'))+'</p></div><div class="actions">'+action(item,s)+'</div></div>'};
  const owner=()=>'<header class="cui-page-head"><div class="cui-page-title"><div><h1>Loyalty setup</h1><p>Owner configuration · product economics and tier benefits</p></div></div></header><section class="card"><h2>New reward</h2><div class="authoring-grid"><div class="full"><label>Start from a product</label><select id="productSource"><option value="">Custom reward</option><option value="serum">Radiance Serum</option></select><p id="productEconomics" class="muted small" style="margin-top:6px">Choose a product or keep Custom reward.</p></div><div class="full"><label>Reward name customers see *</label><input id="customerName" placeholder="e.g. Free bowl of noodles"></div><div><label>Company cost budget (SGD)</label><input id="budget" type="number" value="5.00"></div><div><label>Estimated company cost per point (SGD)</label><input id="pointCost" type="number" value="0.010"></div><div><label>Points cost *</label><input id="pointsCost" type="number"></div><div id="pointsMath" class="imp-note"></div></div></section><section class="card" style="margin-top:16px"><h2>Tier benefits</h2><button class="btn ghost sm" id="addDefaults" type="button">Add recommended tiers</button><p id="draftStatus" class="muted small" style="margin-top:8px">No tiers yet.</p><div id="defaultTiers" class="boundary-list"></div><label>Benefits for selected tier</label><textarea id="tierBenefits" rows="3" placeholder="One customer benefit per line">Priority booking</textarea><button class="btn ghost sm" id="addRewardBenefit" type="button" style="margin-top:8px">Add Glow Facial · 500</button></section><section class="card" style="margin-top:16px"><h2>Rewards</h2><div class="boundary-list">'+rewards.map(item=>row(item,'reward',()=>'<button class="btn ghost sm">Edit</button>')).join('')+'</div></section><section class="card" style="margin-top:16px"><h2>Effective tiers</h2><div class="boundary-list">'+tiers.map(item=>row(item,'tier',()=>'<button class="btn ghost sm">Edit</button>')).join('')+'</div><div class="editor-grid"><div><label>Tier effective from</label><input type="datetime-local" value="2026-08-03T00:00"></div><div><label>Tier expires at</label><input type="datetime-local" value="2026-08-31T23:59"></div></div><button class="btn" style="margin-top:16px">Save tier draft</button></section>';
  const staff=()=>'<header class="cui-page-head"><div class="cui-page-title"><div><h1>Redeem reward</h1><p>Staff · current rewards only</p></div></div></header><div class="permission-banner"><p>Programme settings are read only. Redemptions require Loyalty edit permission and a valid customer QR.</p></div><section class="card"><div class="boundary-list">'+rewards.filter(item=>status(item,'claim_available_from','claim_available_until').key==='live').map(item=>row(item,'reward',()=>'<button class="btn sm" disabled>Scan customer QR</button>')).join('')+'</div></section>';
  const customer=()=>'<header class="cui-page-head"><div class="cui-page-title"><div><h1>Glow Orchard rewards</h1><p>Customer programme · Glow · 620 points</p></div></div></header><section class="card"><h2>Glow benefits</h2><ul class="rec-why" style="margin-top:10px"><li>Priority booking</li><li>Glow Facial (500 points)</li></ul></section><section class="card" style="margin-top:16px"><div class="boundary-list">'+rewards.filter(item=>item.active!==false).map(item=>row(item,'reward',(reward,s)=>s.key==='live'?'<button class="btn sm">Redeem</button>':'<span class="muted small">'+(s.key==='scheduled'?'Available soon':'Offer ended')+'</span>')).join('')+'</div></section><section class="card" style="margin-top:16px"><h2>Current tier</h2><p style="margin-top:8px"><b>Glow</b> · 0 of 5 visits toward the next current tier</p></section>';
  const empty=()=>'<header class="cui-page-head"><div class="cui-page-title"><div><h1>Loyalty boundaries</h1><p>No configured rewards or tiers</p></div></div></header><section class="card"><div class="empty"><div class="big">★</div><b>No rewards yet</b><p>Create a reward draft when the programme is ready.</p></div></section>';
  const disabled=()=>'<header class="cui-page-head"><div class="cui-page-title"><div><h1>Loyalty unavailable</h1><p>This programme is currently paused.</p></div></div></header><section class="card"><div class="empty"><b>Rewards are not available</b><p>There are no customer actions while Loyalty is disabled.</p></div></section>';
  const retry=()=>'<header class="cui-page-head"><div class="cui-page-title"><div><h1>Loyalty boundaries</h1><p>Configuration could not load safely.</p></div></div></header><section class="card"><p class="err">The latest programme could not be loaded.</p><button class="btn" id="retry" style="margin-top:16px">Retry</button></section>';
  document.getElementById('main').innerHTML=state==='empty'?empty():state==='disabled'?disabled():state==='retry'?retry():role==='staff'?staff():role==='customer'?customer():owner();
  const calculatePoints=()=>{const budget=Number(document.getElementById('budget')?.value),pointCost=Number(document.getElementById('pointCost')?.value);if(!(budget>0&&pointCost>0))return;const points=Math.max(1,Math.ceil(budget/pointCost));document.getElementById('pointsCost').value=String(points);document.getElementById('pointsMath').innerHTML='<b>'+points+' points</b><br><span class="small">SGD '+budget.toFixed(2)+' ÷ SGD '+pointCost.toFixed(3)+' per point, rounded up.</span>'};
  document.getElementById('budget')?.addEventListener('input',calculatePoints);document.getElementById('pointCost')?.addEventListener('input',calculatePoints);calculatePoints();
  document.getElementById('productSource')?.addEventListener('change',event=>{if(event.target.value!=='serum')return;document.getElementById('productEconomics').innerHTML='<b>Radiance Serum</b> · sells for SGD 88.00 · company cost SGD 26.00. All reward fields remain editable.';document.getElementById('customerName').value='Radiance Serum';document.getElementById('budget').value='26.00';calculatePoints()});
  document.getElementById('addDefaults')?.addEventListener('click',async event=>{
    const button=event.currentTarget,statusNode=document.getElementById('draftStatus');
    button.disabled=true;button.textContent='Adding tiers…';statusNode.textContent='Saving all three tiers together…';
    const slot='peekaa.loyalty.recommended-tiers.v143.fixture-business';
    const fingerprint=JSON.stringify(['fixture-business','fixture-draft','fixture-snapshot','visits']);
    const idempotencyKey=writeAttemptKey(slot,fingerprint);
    const {data,error}=await addRecommendedLoyaltyTiersV143({client:v143Client,businessId:'fixture-business',versionId:'fixture-draft',basis:'visits',expectedSnapshotHash:'fixture-snapshot',idempotencyKey});
    if(error){button.disabled=false;button.textContent='Retry adding tiers';statusNode.textContent='The first save may have reached the server. Retry safely to confirm it without duplicates.';return}
    clearWriteAttempt(slot);
    document.getElementById('defaultTiers').innerHTML=['Member · from 0 visits · Standard points earning','Plus · from 5 visits · 25% more points','VIP · from 12 visits · 50% more points'].map(value=>'<div class="boundary-row"><b>'+value+'</b></div>').join('');
    statusNode.textContent=data?.published===false?'Recommended tiers added. Nothing was published.':'Unexpected publish state.';
    button.disabled=true;button.textContent='Recommended tiers added';
  });
  document.getElementById('addRewardBenefit')?.addEventListener('click',()=>{const field=document.getElementById('tierBenefits');const benefit='Glow Facial (500 points)';if(!field.value.split(/\\r?\\n/).includes(benefit))field.value+=(field.value.trim()?'\\n':'')+benefit});
  document.getElementById('retry')?.addEventListener('click',()=>{history.replaceState({},'',location.pathname+'?role=owner');location.reload()});
  window.v143Metrics=()=>({role,state,width:document.documentElement.clientWidth,scrollWidth:document.documentElement.scrollWidth,statuses:[...document.querySelectorAll('[data-status]')].map(node=>node.dataset.status),buttons:[...document.querySelectorAll('button')].map(button=>({text:button.textContent.trim(),disabled:button.disabled})),customerName:document.getElementById('customerName')?.value||'',budget:document.getElementById('budget')?.value||'',pointsCost:document.getElementById('pointsCost')?.value||'',tierBenefits:document.getElementById('tierBenefits')?.value||'',tierDefaultCalls:[...tierDefaultCalls],defaultTierRows:document.querySelectorAll('#defaultTiers .boundary-row').length,draftStatus:document.getElementById('draftStatus')?.textContent||'',sourceHash:'${sourceHash}',consoleErrors:window.__errors});
  window.__errors=[];window.addEventListener('error',event=>window.__errors.push(event.message));
  </script></body></html>`;
}

if(process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url){
  await writeFile(FIXTURE_URL,buildV143Fixture(await readFile(APP_URL,'utf8')));
  process.stdout.write(`${fileURLToPath(FIXTURE_URL)}\n`);
}
