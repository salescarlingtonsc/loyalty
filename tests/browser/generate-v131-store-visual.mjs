import {createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {fileURLToPath,pathToFileURL} from 'node:url';

const APP_URL=new URL('../../app/index.html',import.meta.url);
/* The application script was extracted from index.html into app.js. The .test.mjs files
   pass both files joined; this CLI path must read the same pair or it regenerates a
   fixture from a file that no longer contains the components. */
const APP_SCRIPT_URL=new URL('../../app/app.js',import.meta.url);
const readAppSource=async()=>(await Promise.all([readFile(APP_URL,'utf8'),readFile(APP_SCRIPT_URL,'utf8')])).join('\n');
const FIXTURE_URL=new URL('./v131-store-visual.html',import.meta.url);

function between(source,start,end){
  const from=source.indexOf(start),to=source.indexOf(end,from+start.length);
  if(from<0||to<=from)throw new Error(`production source section missing: ${start}`);
  return source.slice(from,to).trim();
}

export function buildV131StoreVisual(app){
  const style=app.match(/<style>([\s\S]*?)<\/style>/)?.[1];
  const customerAccess=between(app,'function renderCustomerWalletUnavailable(','function renderCustomerWalletRetry(');
  const blockedAccess=between(app,'function renderPersonaResolutionUnavailable(){','function renderNativeBusinessCompanion(){');
  const native=between(app,'async function returnToNativeSignIn(){','function renderBusinessWorkspaceControl(');
  const persona=between(app,'function renderPersonaChoice(','function businessApplicationInviteToken(');
  const deletion=between(app,'function accountDeletionCardHtml(){','function renderPasswordUpdate(){');
  const sourceHash=createHash('sha256').update([style,customerAccess,blockedAccess,native,persona,deletion].join('\n')).digest('hex');
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="production-source-sha256" content="${sourceHash}"><link rel="icon" href="data:,"><title>Peekaa V131 store acceptance</title><style>${style}body{padding:16px}.v131-nav{position:fixed;z-index:300;top:8px;right:8px;display:flex;gap:6px;max-width:calc(100vw - 16px);overflow:auto}.center-wrap{padding-top:68px}@media(max-width:600px){body{padding:0}.v131-nav{position:relative;top:auto;right:auto;padding:8px}.center-wrap{padding:12px}.modal-card{margin:12px;max-height:calc(100dvh - 24px)}}</style></head><body><nav class="v131-nav"><button class="btn" data-view="native">Native</button><button class="btn ghost" data-view="deletion">Profile</button><button class="btn ghost" data-view="persona">Workspaces</button><button class="btn ghost" data-view="customer-unavailable">Customer blocked</button><button class="btn ghost" data-view="customer-error">Customer error</button><button class="btn ghost" data-view="persona-error">Account error</button><button class="btn ghost" data-view="workspace-error">Staff blocked</button></nav><div id="root"></div><script>
  const root=document.getElementById('root'),$=id=>document.getElementById(id);
  const esc=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
  const brandWordmark=()=>'<span>Peekaa</span>',legalLinks=()=>'<div class="legal-links">Terms · Privacy</div>',sgt=value=>new Date(value).toLocaleString('en-SG');
  const BRAND={customerLabel:'Loyalty'};const S={user:{id:'v131-browser-user'}};window.__signOuts=0;const killChannels=()=>{},resetClientSessionState=()=>{S.user=null},renderAuth=()=>show('native'),route=()=>show('persona'),nav=()=>{};let customerFeatureCapabilities=null;
  const sortStaffWorkspaces=staff=>[...(staff||[])].sort((a,b)=>String(a.business_name).localeCompare(String(b.business_name)));
  const fixtureState=new URLSearchParams(location.search).get('state')||'ready';window.__rpcCalls=[];
  const pendingRequest={request_id:'00000000-0000-0000-0000-000000000131',status:'pending',requested_at:'2026-08-01T13:00:00Z',response_due_at:'2026-08-31T13:00:00Z'};
  const completedDeletedRequest={...pendingRequest,status:'completed',resolution_code:'deleted_where_permitted',retention_until:null};
  const completedRetainedRequest={...pendingRequest,status:'completed',resolution_code:'retained_legal',retention_until:'2031-08-31T13:00:00Z'};
  const sb={auth:{signOut:async()=>{window.__signOuts+=1;return {}}},rpc:async(name,args)=>{window.__rpcCalls.push({name,args});if(name==='get_account_deletion_request_v131'){if(fixtureState==='load-error')return {data:null,error:{message:'synthetic load error'}};if(fixtureState==='pending')return {data:pendingRequest,error:null};if(fixtureState==='completed-deleted')return {data:completedDeletedRequest,error:null};if(fixtureState==='completed-retained')return {data:completedRetainedRequest,error:null};return {data:null,error:null}}return {data:null,error:null}}};
  const CUI={icon:()=>'',announce:()=>{},focusRoute:node=>node?.focus(),activateDialog(modal,{onClose,initialFocus}){const prior=document.activeElement;const close=()=>{modal.remove();prior?.focus()};modal.addEventListener('keydown',event=>{if(event.key==='Escape'){event.preventDefault();onClose?.()}});setTimeout(()=>modal.querySelector(initialFocus)?.focus(),0);return ()=>close()}};
  ${customerAccess}
  ${blockedAccess}
  ${native}
  ${persona}
  ${deletion}
  function show(view){document.querySelectorAll('[data-view]').forEach(button=>button.className=button.dataset.view===view?'btn':'btn ghost');if(view==='native')return renderNativeBusinessCompanion();if(view==='persona')return renderPersonaChoice({staff:[{business_slug:'radiant-skin',business_name:'Radiant Skin Studio'},{business_slug:'harbour-cafe',business_name:'Harbour Café'}],customer:[{}]});if(view==='customer-unavailable')return renderCustomerWalletUnavailable();if(view==='customer-error')return renderCustomerCapabilityRetry('We could not check your customer access. Please try again.');if(view==='persona-error')return renderPersonaResolutionUnavailable();if(view==='workspace-error')return renderWorkspaceAccessUnavailable();root.innerHTML='<main class="center-wrap" id="main" tabindex="-1"><section class="auth-card card"><h1>Customer profile</h1>'+accountDeletionCardHtml()+'</section></main>';wireAccountDeletionButton()}
  document.querySelectorAll('[data-view]').forEach(button=>button.onclick=()=>show(button.dataset.view));
  window.v131Metrics=()=>({state:fixtureState,width:document.documentElement.clientWidth,scrollWidth:document.documentElement.scrollWidth,heading:document.querySelector('h1,h2')?.textContent.trim(),buttons:[...document.querySelectorAll('button')].filter(item=>item.offsetParent!==null).map(item=>({text:item.textContent.trim(),height:item.getBoundingClientRect().height})),dialog:!!document.querySelector('[role="dialog"]'),body:document.body.innerText,rpcCalls:window.__rpcCalls,signOuts:window.__signOuts,userActive:!!S.user});
  show(new URLSearchParams(location.search).get('view')||'native');
  </script></body></html>`;
}

if(process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url){
  const app=await readAppSource();
  await writeFile(FIXTURE_URL,buildV131StoreVisual(app));
  process.stdout.write(`${fileURLToPath(FIXTURE_URL)}\n`);
}
