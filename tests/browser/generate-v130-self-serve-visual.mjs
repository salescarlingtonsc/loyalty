import {createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {fileURLToPath,pathToFileURL} from 'node:url';

const APP_URL=new URL('../../app/index.html',import.meta.url);
const FIXTURE_URL=new URL('./v130-self-serve-visual.html',import.meta.url);

function between(source,start,end){
  const from=source.indexOf(start),to=source.indexOf(end,from+start.length);
  if(from<0||to<=from)throw new Error(`production source section missing: ${start}`);
  return source.slice(from,to).trim();
}

export function buildV130SelfServeVisual(app){
  const style=app.match(/<style>([\s\S]*?)<\/style>/)?.[1];
  if(!style)throw new Error('production inline stylesheet missing');
  const oauth=between(app,'function businessOAuthRedirectUrl(){','function renderBusinessApplication(){');
  const signup=between(app,'function renderBusinessApplication(){','async function renderApprovedBusinessInviteSignup(');
  const auth=between(app,"function renderAuth(mode='in'",'function validNewPassword(');
  const oauthCallback=between(app,'async function consumeBusinessOAuthRedirect(){','async function consumePasswordRecoveryRedirect()');
  const onboard=between(app,'function renderOnboard(){','/* ============================================================================');
  const control=between(app,'function renderBusinessWorkspaceControl(','/* ---------- auth ---------- */');
  const deletion=between(app,'function accountDeletionCardHtml(){','function renderPasswordUpdate(){');
  const sourceHash=createHash('sha256').update([style,oauth,signup,auth,oauthCallback,onboard,control,deletion].join('\n')).digest('hex');
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="production-source-sha256" content="${sourceHash}"><link rel="icon" href="data:,"><title>Peekaa V130 actual-renderer browser acceptance</title><style>${style}body{padding:16px}.v130-nav{position:fixed;z-index:300;top:8px;right:8px;display:flex;gap:6px}.v130-nav .btn{padding:8px 12px}.center-wrap{padding-top:68px}@media(max-width:600px){body{padding:0}.v130-nav{position:relative;top:auto;right:auto;padding:8px;overflow:auto}.center-wrap{padding:12px}.grid2{grid-template-columns:1fr}}</style></head><body><nav class="v130-nav" aria-label="V130 acceptance views"><button class="btn" data-view="signup">Signup</button><button class="btn ghost" data-view="login">Login</button><button class="btn ghost" data-view="setup">Setup</button><button class="btn ghost" data-view="pending">Pending</button><button class="btn ghost" data-view="control">Control</button></nav><div id="root"></div><script>
  const root=document.getElementById('root'),$=id=>document.getElementById(id);
  const esc=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
  const money=cents=>'SGD '+(Number(cents||0)/100).toFixed(2);const sgt=value=>new Date(value).toLocaleString('en-SG');
  const brandWordmark=()=>'<span>Peekaa</span>';const legalLinks=()=>'<div class="legal-links"><a href="#">Terms</a> · <a href="#">Privacy</a></div>';
  const passwordControlHtml=id=>'<div class="password-control"><input id="'+id+'" type="password"></div>';
  const authChallengeHtml=()=>'<div class="challenge"><div class="challenge-status">Security check complete</div></div>';
  const bindPasswordVisibility=()=>{},destroyMountedTurnstiles=()=>{};
  const businessApplicationLanguage=()=>{const locale=sessionStorage.getItem('nestly-business-application-locale');return WORKSPACE_LOCALES_V97.includes(locale)?locale:'en'};
  const mountTurnstile=(_site,options)=>{setTimeout(()=>options.onToken('synthetic-browser-token'),0);return Promise.resolve({reset(){}})};
  const validNewPassword=value=>String(value).length>=12;const AUTH_TURNSTILE_SITE_KEY='synthetic';
  const NestlyNativeBridge={isNative:false,publicUrl:path=>location.origin+path};const WORKSPACE_LOCALES_V97=['en','zh-CN','ms'];
  const SB_URL='https://synthetic.supabase.co',SB_KEY='synthetic-publishable-key';
  const businessApplicationInviteToken=()=>'',renderNativeBusinessCompanion=()=>{},route=()=>{},resetClientSessionState=()=>{},killChannels=()=>{},nav=value=>{window.__lastNavigation=value},toast=()=>{};
  const CUI={icon:()=>'',activateDialog(modal,{onClose,initialFocus}){const prior=document.activeElement;const close=()=>{modal.remove();prior?.focus()};modal.addEventListener('keydown',event=>{if(event.key==='Escape'){event.preventDefault();onClose?.()}});setTimeout(()=>modal.querySelector(initialFocus)?.focus(),0);return ()=>close()}};const S={user:{id:'v131-browser-user'},hasCustomerPersona:false};
  let currentView='signup';window.__consoleErrors=[];window.__rpcCalls=[];window.__oauthStarts=[];window.__persistentSetSessionCalls=0;window.__transientSetSessionCalls=0;window.__signOutCalls=0;window.__admission={data:{admitted:true},error:null};window.__holdAdmission=false;
  const plans=[{cadence:'annual',cadence_months:12,base_amount_cents:118800,included_customer_capacity:1000,capacity_block_size:1000,capacity_block_amount_cents:12000,compare_at_monthly_cents:16800,tax_behavior:'exclusive'},{cadence:'monthly',cadence_months:1,base_amount_cents:14900,included_customer_capacity:1000,capacity_block_size:1000,capacity_block_amount_cents:1000,compare_at_monthly_cents:16800,tax_behavior:'exclusive'}];
  const modules=['Customer CRM and QR signup','Loyalty points, stamps and rewards','Appointments, team schedule and waitlist','Promotions and template-assisted promotion wording'];
  const pending={business_id:'00000000-0000-0000-0000-000000000130',business_slug:'radiant-skin-studio',business_name:'Radiant Skin Studio',cadence:'annual',customer_capacity:3000,total_cents:142800,status:'payment_pending'};
  const sb={auth:{signUp:async()=>({data:{session:null},error:null}),signOut:async()=>{window.__signOutCalls+=1;localStorage.removeItem('v138-persistent-session');return {}},signInWithPassword:async()=>({error:null}),setSession:async()=>{window.__persistentSetSessionCalls+=1;localStorage.setItem('v138-persistent-session','admitted');return {error:null}},signInWithOAuth:async args=>{window.__oauthStarts.push(args);return {data:{url:'https://accounts.google.com/'},error:null}}},rpc:async(name,args)=>{window.__rpcCalls.push({name,args,client:'persistent'});if(name==='begin_business_google_oauth_signup_v138')return {data:{accepted:true},error:null};if(name==='get_self_serve_checkout_v130')return {data:{onboarding:currentView==='pending'||currentView==='control'?pending:null,plans,sectors:[{sector_key:'facial',label:'Facial / Spa'}],gst_registered:false,money_back_days:30,included_modules:modules},error:null};if(name==='start_self_serve_business_v130')return {data:{...pending},error:null};if(name==='request_self_serve_checkout_v130')return {data:{command_id:'00000000-0000-0000-0000-000000000131'},error:null};return {data:null,error:null}},functions:{invoke:async()=>({data:{status:'processing'},error:null})}};
  const transientAdmissionClient={auth:{setSession:async()=>{window.__transientSetSessionCalls+=1;return {error:null}}},rpc:async(name,args)=>{window.__rpcCalls.push({name,args,client:'transient'});if(window.__holdAdmission)await new Promise(()=>{});if(name==='complete_business_google_oauth_v138')return window.__admission;return {data:null,error:null}}};
  window.supabase={createClient:()=>transientAdmissionClient};
  ${oauth}
  ${signup}
  ${auth}
  ${oauthCallback}
  ${deletion}
  ${onboard}
  ${control}
  function showView(view){currentView=view;document.querySelectorAll('[data-view]').forEach(button=>button.className=button.dataset.view===view?'btn':'btn ghost');if(view==='signup')renderBusinessApplication();else if(view==='login')renderAuth('in');else if(view==='control')renderBusinessWorkspaceControl({business_id:pending.business_id,approval:{status:'pending'},subscription:{workspace_paused:false}});else renderOnboard()}
  document.querySelectorAll('[data-view]').forEach(button=>button.onclick=()=>showView(button.dataset.view));
  window.runBusinessOAuthCallback=async({intent='signin',attemptToken=null,admitted=true}={})=>{
    window.__admission=admitted?{data:{admitted:true},error:null}:{data:null,error:{message:'rejected'}};
    sessionStorage.setItem('nestly-business-google-oauth',JSON.stringify({startedAt:Date.now(),returnPath:'/business',intent,legalAccepted:intent==='signup',attemptToken}));
    history.replaceState(null,'',location.pathname+'?oauth=business#access_token=access&refresh_token=refresh');
    await consumeBusinessOAuthRedirect();
    return {persistentSetSessionCalls:window.__persistentSetSessionCalls,transientSetSessionCalls:window.__transientSetSessionCalls,signOutCalls:window.__signOutCalls,notice:sessionStorage.getItem('nestly-business-oauth-notice'),rpcCalls:window.__rpcCalls,persistedSession:localStorage.getItem('v138-persistent-session')};
  };
  window.startInterruptedBusinessOAuthCallback=async()=>{
    window.__holdAdmission=true;
    sessionStorage.setItem('nestly-business-google-oauth',JSON.stringify({startedAt:Date.now(),returnPath:'/business',intent:'signin',legalAccepted:false,attemptToken:null}));
    history.replaceState(null,'',location.pathname+'?oauth=business#access_token=access&refresh_token=refresh');
    void consumeBusinessOAuthRedirect();
  };
  window.addEventListener('error',event=>window.__consoleErrors.push(event.message));
  window.v130Metrics=()=>({view:currentView,width:document.documentElement.clientWidth,scrollWidth:document.documentElement.scrollWidth,heading:document.querySelector('h1,h2')?.textContent.trim()||'',buttons:[...document.querySelectorAll('button')].filter(item=>item.offsetParent!==null).map(item=>({text:item.textContent.trim(),height:item.getBoundingClientRect().height})),fields:[...document.querySelectorAll('input,select')].filter(item=>item.offsetParent!==null).map(item=>item.id),errors:window.__consoleErrors,rpcCalls:window.__rpcCalls,oauthStarts:window.__oauthStarts,persistentSetSessionCalls:window.__persistentSetSessionCalls,transientSetSessionCalls:window.__transientSetSessionCalls,signOutCalls:window.__signOutCalls,persistedSession:localStorage.getItem('v138-persistent-session')});
  showView(new URLSearchParams(location.search).get('view')||'signup');
  </script></body></html>`;
}

if(process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url){
  const app=await readFile(APP_URL,'utf8');
  await writeFile(FIXTURE_URL,buildV130SelfServeVisual(app));
  process.stdout.write(`${fileURLToPath(FIXTURE_URL)}\n`);
}
