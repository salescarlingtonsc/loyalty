import {createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {fileURLToPath,pathToFileURL} from 'node:url';

const APP_URL=new URL('../../app/index.html',import.meta.url);
/* The application script was extracted from index.html into app.js. The .test.mjs files
   pass both files joined; this CLI path must read the same pair or it regenerates a
   fixture from a file that no longer contains the components. */
const APP_SCRIPT_URL=new URL('../../app/app.js',import.meta.url);
const readAppSource=async()=>(await Promise.all([readFile(APP_URL,'utf8'),readFile(APP_SCRIPT_URL,'utf8')])).join('\n');
const CUSTOMER_UI_URL=new URL('../../app/customer-ui.js',import.meta.url);
const COMMAND_URL=new URL('../../supabase/functions/stripe-connect-command/index.ts',import.meta.url);
const WEBHOOK_URL=new URL('../../supabase/functions/stripe-connect-webhook/index.ts',import.meta.url);
const FIXTURE_URL=new URL('./v142-connect-paynow-visual.html',import.meta.url);

function between(source,start,end){
  const from=source.indexOf(start),to=source.indexOf(end,from+start.length);
  if(from<0||to<=from)throw new Error(`production source section missing: ${start}`);
  return source.slice(from,to).trim();
}

export async function buildV142Visual(){
  const [app,customerUi,command,webhook]=await Promise.all([
    readAppSource(),readFile(CUSTOMER_UI_URL,'utf8'),
    readFile(COMMAND_URL,'utf8'),readFile(WEBHOOK_URL,'utf8')
  ]);
  const style=app.match(/<style>([\s\S]*?)<\/style>/)?.[1];
  if(!style)throw new Error('production inline stylesheet missing');
  const till=between(app,'function canScanCustomerRedemption','/* ---------- sales ---------- */');
  const sourceHash=createHash('sha256').update([style,customerUi,till,command,webhook].join('\n')).digest('hex');
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="v142-production-source-sha256" content="${sourceHash}"><title>Peekaa V142 production Record sale acceptance</title><style>${style}
  body{padding:20px}.v142-shell{max-width:920px;margin:auto}.v142-provenance{font-size:11px;color:var(--muted);overflow-wrap:anywhere;margin-bottom:10px}
  @media(max-width:600px){body{padding:10px}.card{padding:16px}}
  </style></head><body><div class="v142-shell"><p class="v142-provenance">Actual production Record sale renderer · ${sourceHash}</p><main id="main"></main></div><div id="toast" class="toast"></div><div id="appStatus"></div><div id="appAlert"></div><script>
  ${customerUi}
  const CUI=window.FrenlyCustomerUI;
  const BRAND={productName:'Peekaa',downloadPrefix:'peekaa'};
  const BUSINESS_ID='10000000-0000-4000-8000-000000000142';
  const USER_ID='20000000-0000-4000-8000-000000000142';
  const STAFF_ID='30000000-0000-4000-8000-000000000142';
  const BRANCH_ID='40000000-0000-4000-8000-000000000142';
  const CLIENT_ID='50000000-0000-4000-8000-000000000142';
  const SERVICE_ID='60000000-0000-4000-8000-000000000142';
  const EVALUATION_ID='70000000-0000-4000-8000-000000000142';
  const ATTEMPT_ID='80000000-0000-4000-8000-000000000142';
  const SALE_ID='90000000-0000-4000-8000-000000000142';
  const $=id=>document.getElementById(id);
  const M=()=>document.getElementById('main');
  const esc=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
  const money=cents=>'SGD '+(Number(cents||0)/100).toFixed(2);
  const sgt=iso=>{if(!iso)return null;return new Intl.DateTimeFormat('en-SG',{dateStyle:'medium',timeStyle:'short',timeZone:'Asia/Singapore'}).format(new Date(iso))};
  const formatCustomerJoinedDateV141=value=>value?new Intl.DateTimeFormat('en-SG',{day:'numeric',month:'short',year:'numeric',timeZone:'Asia/Singapore'}).format(new Date(value)):'Unavailable';
  const catalogueImageUrlV158=()=>'';
  const workspaceTemplateAttributeV97=(attribute,key,values)=>attribute+'="'+esc(key==='removeItem'?'Remove '+values.item:key)+'"';
  const workspaceTemplateTextV97=(key,values={})=>key==='itemAdded'?values.item+' added':key==='itemSelected'?values.item+' selected':key;
  const recordProductInteractionV100=()=>{};
  const openMerchantRedemptionScanner=()=>{};
  const fail=error=>window.__consoleErrors.push(String(error?.message||error));
  const toast=message=>{window.__lastToast=message};
  const writeAttemptKey=(slot,fingerprint)=>{const existing=JSON.parse(sessionStorage.getItem(slot)||'null');if(existing?.fingerprint===fingerprint)return existing.key;const value={fingerprint,key:crypto.randomUUID()};sessionStorage.setItem(slot,JSON.stringify(value));return value.key};
  const clearWriteAttempt=slot=>sessionStorage.removeItem(slot);
  const isReplayResult=data=>data?.status==='duplicate_ignored'||data?.replayed===true;
  const S={myRole:'owner',user:{id:USER_ID},biz:{id:BUSINESS_ID,name:'Harbour Café',currency:'SGD',quick_earn_catalogue_enabled:true}};
  const hasRoleCapability=capability=>capability==='create_sales';
  const canReadModule=module=>['clients','loyalty','till','packages','memberships'].includes(module);
  let selectedBranchId=BRANCH_ID,workspaceLocale='en',pendingTillPhone='',pendingTillRedemptionScan=false;
  window.__rpcCalls=[];window.__functionCalls=[];window.__consoleErrors=[];window.__providerConfirmed=false;window.__printRequested=false;
  window.print=()=>{window.__printRequested=true};
  const QR='00020101021226580009SG.PAYNOW010120210202818638330303SGD520400005303702540510.005802SG5912HARBOUR CAFE6009SINGAPORE6304A1B2';
  function QRCode(host,options){window.__qrRawData=String(options.text||'');const canvas=document.createElement('canvas');canvas.width=options.width;canvas.height=options.height;canvas.setAttribute('aria-hidden','true');const ctx=canvas.getContext('2d');ctx.fillStyle='#fff';ctx.fillRect(0,0,canvas.width,canvas.height);ctx.fillStyle='#000';for(let y=0;y<21;y++)for(let x=0;x<21;x++)if((x*y+x+y)%3===0)ctx.fillRect(x*12,y*12,10,10);host.appendChild(canvas)}
  QRCode.CorrectLevel={M:0};
  function queryRows(table){
    /* v187 made sale attribution real: tillPage resolves the acting staff by user_id and
       gates the whole till on it, so the stub row must carry the signed-in user's id and the
       full_name the roster orders by. */
    return {staff:[{id:STAFF_ID,full_name:'Aisyah',user_id:USER_ID}],branches:[{id:BRANCH_ID,name:'Tanjong Pagar',is_default:true}],staff_branches:[{staff_id:STAFF_ID,branch_id:BRANCH_ID}],services:[{id:SERVICE_ID,name:'Harbour Lunch Set',variant_label:'',duration_min:30}],package_plans:[],membership_plans:[]}[table]||[];
  }
  function fixtureQuery(table){
    const query={select(){return query},eq(){return query},order(){return query},limit(){return query},single(){return query},maybeSingle(){return query},then(resolve,reject){return Promise.resolve({data:queryRows(table),error:null}).then(resolve,reject)}};
    return query;
  }
  function paymentStatus(){
    if(!window.__providerConfirmed)return {status:'awaiting_payment',attempt_id:ATTEMPT_ID,amount_cents:1000,currency:'SGD',expires_at:new Date(Date.now()+61*60*1000).toISOString()};
    return {status:'succeeded',attempt_id:ATTEMPT_ID,amount_cents:1000,currency:'SGD',sale_id:SALE_ID,
      customer_name:'Mei Lin',business_name:'Harbour Café',branch_name:'Tanjong Pagar',paid_at:new Date().toISOString(),payment_reference:'pi_v142_demo',
      server_lines:[{name:'Harbour Lunch Set',qty:1,unit_price_cents:1000}],applied_effects:[],subtotal_cents:1000,discount_total_cents:0,gst_cents:0,points_earned:10,points_total:310};
  }
  const sb={from:fixtureQuery,rpc:async(name,args)=>{
    window.__rpcCalls.push({name,args});
    if(name==='get_merchant_payment_status_v142')return {data:{status:'ready',paynow_ready:true,charges_enabled:true,payouts_enabled:true},error:null};
    if(name==='get_my_modules_at_v115')return {data:{module_perms:{till:'rw',clients:'r',loyalty:'rw',packages:'r',memberships:'r',giftcards:'r'}},error:null};
    if(name==='lookup_client_by_phone')return {data:{status:'found',client_id:CLIENT_ID,full_name:'Mei Lin',phone:'81863833',points:300},error:null};
    if(name==='business_get_checkout_catalogue_v94')return {data:{platform_allowed:true,enabled:true,items:[{item_type:'service',item_id:SERVICE_ID,name:'Harbour Lunch Set',unit_cents:1000,checkout_active:true,branch_available:true}]},error:null};
    if(name==='business_get_checkout_preferences_v102')return {data:{status:'available',gift_card_sales_enabled:false,package_earns_points:false},error:null};
    if(name==='staff_get_customer_entitlements_v102')return {data:{packages:[],vouchers:[]},error:null};
    if(name==='evaluate_checkout')return {data:{evaluation_id:EVALUATION_ID,expires_at:new Date(Date.now()+5*60*1000).toISOString(),server_lines:[{name:'Harbour Lunch Set',qty:1,unit_price_cents:1000}],applied_effects:[],subtotal_cents:1000,discount_total_cents:0,total_cents:1000,gst_cents:0,stored_value:{spendable:false,available_cents:0}},error:null};
    if(name==='get_pos_paynow_attempt_v142')return {data:paymentStatus(),error:null};
    return {data:null,error:null};
  },functions:{invoke:async(name,{body})=>{
    window.__functionCalls.push({name,body});
    if(name!=='stripe-connect-command')return {data:null,error:{message:'unexpected function'}};
    setTimeout(()=>{window.__providerConfirmed=true},950);
    return {data:{status:'awaiting_payment',attempt_id:ATTEMPT_ID,amount_cents:1000,currency:'SGD',expires_at:new Date(Date.now()+61*60*1000).toISOString(),qr:{data:QR}},error:null};
  }}};
  ${till}
  window.v142Metrics=()=>({sourceHash:'${sourceHash}',viewport:{clientWidth:document.documentElement.clientWidth,scrollWidth:document.documentElement.scrollWidth},
    amountLocked:document.querySelector('#tPaynowModalV142 .imp-note b')?.textContent.trim()||'',qrExpiry:document.querySelector('#tPaynowModalV142 .imp-note')?.nextElementSibling?.textContent.trim()||'',
    qrVisible:!!document.querySelector('#tPaynowQrV142 canvas'),qrRawData:window.__qrRawData||'',remoteQrImage:!!document.querySelector('#tPaynowModalV142 img[src^="http"]'),receiptVisible:!!document.getElementById('posReceiptV142'),printVisible:!!document.getElementById('tPrintReceiptV142'),printRequested:window.__printRequested,
    servicePhoneVisible:/customer service phone|support phone/i.test(document.body.innerText),touchTargets:[...document.querySelectorAll('button')].filter(node=>node.offsetParent!==null).map(node=>node.getBoundingClientRect().height),
    rpcCalls:window.__rpcCalls,functionCalls:window.__functionCalls,errors:window.__consoleErrors});
  window.addEventListener('error',event=>window.__consoleErrors.push(event.message));
  tillPage().catch(error=>window.__consoleErrors.push(String(error?.stack||error)));
  </script></body></html>`;
}

if(process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url){
  await writeFile(FIXTURE_URL,await buildV142Visual());
  process.stdout.write(`${fileURLToPath(FIXTURE_URL)}\n`);
}
