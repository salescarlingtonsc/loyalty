/* v255 client telemetry — batching, privacy and the surfaces that now emit.
 *
 * Points 9 and 10 of the audit's verification checklist are behavioural, not textual, so this
 * suite EXECUTES the real batching block out of app/app.js in a vm sandbox with stubbed
 * globals. Everything else (the emit sites, the DAU wiring) is asserted against the source,
 * because those are single call sites whose whole content is the call itself.
 */
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const app=await readFile(new URL('../../app/app.js',import.meta.url),'utf8');

const BLOCK_START='const PRODUCT_INTERACTION_EVENTS_V100=new Set([';
const BLOCK_END='\nlet customerFeatureCapabilities=null;';
function telemetrySource(){
  const from=app.indexOf(BLOCK_START),to=app.indexOf(BLOCK_END,from);
  assert.ok(from>=0&&to>from,'the v100/v255 telemetry block must be locatable in app/app.js');
  return app.slice(from,to);
}

let uuidCounter=0;
function sandbox({rpc,fetchImpl}={}){
  const store=new Map();
  const listeners=new Map();
  const context={
    S:{user:{id:'11111111-1111-4111-8111-111111111111'}},
    SB_URL:'https://example.supabase.co',
    SB_KEY:'sb_publishable_test',
    sessionStorage:{
      getItem:key=>store.has(key)?store.get(key):null,
      setItem:(key,value)=>{store.set(key,String(value))},
      removeItem:key=>{store.delete(key)}
    },
    crypto:{randomUUID:()=>{
      uuidCounter+=1;
      return `2000${String(uuidCounter).padStart(4,'0')}-1111-4111-8111-111111111111`;
    }},
    setTimeout,clearTimeout,Promise,Set,Map,JSON,String,Number,Math,Date,Array,Object,
    fetch:fetchImpl||(()=>Promise.resolve({ok:true})),
    document:{
      visibilityState:'visible',
      addEventListener:(name,handler)=>listeners.set(`document:${name}`,handler)
    },
    window:{addEventListener:(name,handler)=>listeners.set(`window:${name}`,handler)},
    sb:{
      rpc:rpc||(()=>Promise.resolve({data:null,error:null})),
      auth:{
        onAuthStateChange:()=>{},
        getSession:()=>Promise.resolve({data:{session:{access_token:'test-token'}}})
      }
    }
  };
  vm.createContext(context);
  /* `let`/`const` in a vm script live in the script's own lexical scope, not on the context
     object, so the queue has to be handed out explicitly. */
  vm.runInContext(
    `${telemetrySource()}\nglobalThis.__queueV256=()=>productInteractionQueueV256;`,
    context
  );
  context.__listeners=listeners;
  context.queue=()=>context.__queueV256();
  return context;
}

const settle=()=>new Promise(resolve=>setImmediate(resolve));
const BUSINESS='8492e8d6-8888-4383-ada0-7e1ed69f0caa';

test('the client allowlist matches the v255 taxonomy and adds the three new context keys',()=>{
  const source=telemetrySource();
  for(const name of [
    'merchant.surface_viewed','customer.session_started','customer.surface_viewed',
    'customer.promotion_viewed','customer.promotion_opened','customer.reward_viewed',
    'customer.notification_opened','customer.explore_searched'
  ])assert.ok(source.includes(`'${name}'`),`${name} must be in the client allowlist`);
  for(const key of ['surface_key','promotion_id','query_shape']){
    assert.ok(source.includes(`'${key}'`),`${key} must be an allowed context dimension`);
  }
});

test('events queue instead of sending one request each, and flush at ten',async()=>{
  const calls=[];
  const context=sandbox({rpc:(name,args)=>{calls.push([name,args]);return Promise.resolve({data:{},error:null})}});
  for(let index=0;index<9;index+=1){
    context.recordProductInteractionV100('customer.surface_viewed',BUSINESS,{context:{surface_key:'wallet'}});
  }
  assert.equal(calls.length,0,'nine events must still be queued, not sent');
  assert.equal(context.queue().length,9);
  context.recordProductInteractionV100('customer.surface_viewed',BUSINESS,{context:{surface_key:'wallet'}});
  assert.equal(calls.length,1,'the tenth event must flush the batch');
  assert.equal(calls[0][0],'record_product_interactions_batch_v255');
  assert.equal(calls[0][1].p_events.length,10);
  assert.equal(context.queue().length,0);
});

test('a 1000-event burst never grows the queue past the cap and never blocks',async()=>{
  let inFlight=null;
  const context=sandbox({rpc:()=>{
    inFlight=inFlight||new Promise(()=>{});
    return inFlight; // never settles: the flush must not stall the caller
  }});
  const started=Date.now();
  for(let index=0;index<1000;index+=1){
    context.recordProductInteractionV100('customer.surface_viewed',BUSINESS,{context:{surface_key:'wallet'}});
  }
  assert.ok(Date.now()-started<2000,'recording must never block the caller');
  assert.ok(
    context.queue().length<=50,
    `the queue must stay at or under the cap, saw ${context.queue().length}`
  );
});

test('a failing flush is swallowed: offline, 500 and 42501 all leave the caller unaffected',async()=>{
  for(const failure of [
    ()=>Promise.reject(new TypeError('Failed to fetch')),
    ()=>Promise.resolve({data:null,error:{code:'PGRST301',message:'server error'}}),
    ()=>Promise.resolve({data:null,error:{code:'42501',message:'permission denied'}}),
    ()=>{throw new Error('client blew up')}
  ]){
    const context=sandbox({rpc:failure});
    for(let index=0;index<10;index+=1){
      context.recordProductInteractionV100('customer.surface_viewed',BUSINESS,{context:{surface_key:'wallet'}});
    }
    await settle();
    context.recordProductInteractionV100('customer.surface_viewed',BUSINESS,{context:{surface_key:'wallet'}});
  }
});

test('hiding the page and pagehide flush through a keepalive fetch, never sendBeacon',async()=>{
  const source=telemetrySource();
  assert.doesNotMatch(source,/sendBeacon\s*\(/,'sendBeacon cannot carry the Authorization header');
  const requests=[];
  const context=sandbox({fetchImpl:(url,init)=>{requests.push([url,init]);return Promise.resolve({ok:true})}});
  context.recordProductInteractionV100('customer.surface_viewed',BUSINESS,{context:{surface_key:'wallet'}});
  await settle();
  context.document.visibilityState='hidden';
  context.__listeners.get('document:visibilitychange')();
  assert.equal(requests.length,1,'hiding the page must flush');
  assert.match(requests[0][0],/rpc\/record_product_interactions_batch_v255$/);
  assert.equal(requests[0][1].keepalive,true);
  assert.equal(requests[0][1].headers.authorization,'Bearer test-token');
  assert.ok(context.__listeners.has('window:pagehide'),'pagehide must also flush');
});

test('a customer event with no business is dropped, except discovery search',()=>{
  const calls=[];
  const context=sandbox({rpc:(name,args)=>{calls.push(args);return Promise.resolve({data:{},error:null})}});
  context.recordProductInteractionV100('customer.surface_viewed',null,{context:{surface_key:'wallet'}});
  assert.equal(context.queue().length,0,'a tenant-less programme view must be dropped');
  context.recordProductInteractionV100('customer.explore_searched',null,{
    context:{query_shape:'t2:short:matched'}
  });
  assert.equal(context.queue().length,1);
  assert.equal(context.queue()[0].business_id,null);
});

test('search capture records a shape and never the typed text',()=>{
  const context=sandbox();
  assert.equal(context.exploreQueryShapeV256('chicken rice',true),'t2:short:matched');
  assert.equal(context.exploreQueryShapeV256('facial',false),'t1:short:unmatched');
  assert.equal(context.exploreQueryShapeV256('',false),'t0:empty:unmatched');
  const long=context.exploreQueryShapeV256('somewhere quiet for a long slow haircut near the office',true);
  assert.equal(long,'t6:long:matched');
  for(const word of ['chicken','rice','facial','haircut','office']){
    assert.ok(!long.includes(word)&&!context.exploreQueryShapeV256(word,true).includes(word),
      `${word} must never reach the recorded shape`);
  }
  context.recordProductInteractionV100('customer.explore_searched',null,{
    context:{query_shape:context.exploreQueryShapeV256('chicken rice',true),surface_key:'explore'}
  });
  assert.equal(
    JSON.stringify(context.queue()[0].context).includes('chicken'),
    false
  );
});

test('unallowlisted event names and context keys never leave the client',()=>{
  const context=sandbox();
  context.recordProductInteractionV100('customer.something_new',BUSINESS,{context:{}});
  assert.equal(context.queue().length,0);
  context.recordProductInteractionV100('customer.surface_viewed',BUSINESS,{
    context:{surface_key:'wallet',phone:'81863833',note:'free text'}
  });
  const recorded=context.queue()[0].context;
  assert.deepEqual(Object.keys(recorded),['surface_key']);
});

test('session start is recorded once per browser session and reset on sign-out',()=>{
  const context=sandbox();
  context.recordCustomerSessionStartV256(BUSINESS,'en');
  context.recordCustomerSessionStartV256(BUSINESS,'en');
  assert.equal(
    context.queue().filter(item=>item.event_name==='customer.session_started').length,
    1
  );
  context.resetProductInteractionSessionV100();
  assert.equal(context.queue().length,0,'sign-out must drop the previous session queue');
  context.recordCustomerSessionStartV256(BUSINESS,'en');
  assert.equal(context.queue().length,1);
});

test('the surfaces the audit named are wired, including the one-line customer DAU fix',()=>{
  assert.match(app,/recordProductInteractionV100\('merchant\.surface_viewed',S\.biz\.id,\{/);
  assert.match(app,/recordProductInteractionV100\('customer\.surface_viewed',businessId,\{/);
  assert.match(app,/recordProductInteractionV100\('customer\.promotion_viewed',businessId,\{/);
  assert.match(app,/recordProductInteractionV100\(\s*'customer\.notification_opened'/);
  assert.match(app,/recordProductInteractionV100\('customer\.reward_viewed',businessId,\{/);
  assert.match(app,/recordProductInteractionV100\('customer\.promotion_opened',customerWalletBusinessIdV256,\{/);
  assert.match(app,/recordProductInteractionV100\('customer\.explore_searched',null,\{/);
  /* Audit 3: customer_account_open_days_v175 was purpose-built for customer DAU and its wallet
     channel had no caller at all, so only the booking path had ever fired. */
  assert.match(app,/sb\.rpc\('customer_record_account_open_v175',\{p_business:businessId\}\)/);
});
