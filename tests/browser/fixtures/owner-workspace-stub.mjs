/* The owner (business) fixture used by the real-Chrome layout harnesses.
 *
 * It is a STRING because it is injected with `context.addInitScript` before any app code runs —
 * it installs a `window.supabase` stand-in with a thenable query builder, so the real app boots
 * its real router against real bundles with no network. Extracted from
 * tests/browser/verify-v447-split-collapse.mjs (V451) so the appbar harness could reuse it
 * verbatim rather than fork a second copy that would drift.
 *
 * MODULES deliberately includes `appointments`, so the app bar renders BOTH "Record sale" and
 * "New appointment" — the crowded header the V451 band measures.
 */
export function ownerWorkspaceStub({biz='b1111111-1111-4111-8111-111111111111',slug='testco'}={}){
  const BIZ=biz,SLUG=slug;
  return `(()=>{
  const BIZ='${BIZ}';
  const MODULES=['loyalty','retention','referrals','memberships','clients','sales','services','till',
    'bookings','reports','inventory','appointments','staffperf','packages','branches','expenses'];
  const program={id:'prog-1',business_id:BIZ,active:true,loyalty_model:'points_tiers',
    earn_points_per_dollar:1,redeem_points:100,reward_credit_cents:100,stamp_target:null,
    stamp_per_cents:500,expiry_mode:'none',expiry_days:null,tier_basis:'visits',
    current_config_version_id:'pub-1',configuration_status:'published'};
  const bizRow={id:BIZ,slug:'${SLUG}',name:'Test Co',currency:'SGD',industry:'facial',points_mode:'both',
    enabled_modules:MODULES,active_config_version_id:'pub-1',join_enabled:true,brand_color:'#7c5cff',
    booking_policy:'Please arrive 10 minutes early.',bio:'A small neighbourhood facial bar.',
    quick_earn_catalogue_enabled:true,created_at:'2026-01-01T00:00:00Z'};
  const TABLES={
    businesses:[bizRow],
    branches:[{id:'br1',business_id:BIZ,name:'Orchard',active:true,is_default:true,billing_state:'active'}],
    services:[{id:'sv1',business_id:BIZ,name:'Signature facial',active:true,price_cents:8800}],
    products:[{id:'pr1',business_id:BIZ,name:'Cleanser',active:true,price_cents:3200,sku:'CL-1'}],
    packages:[{id:'pk1',business_id:BIZ,name:'5x Facial',active:true,price_cents:40000,sessions:5}],
    clients:[],sales:[],appointments:[],points_ledger:[],memberships:[],client_packages:[],waitlist:[],
    client_field_definitions:[],client_field_values:[],client_field_options:[],branch_hours:[],
    stock_batches:[],product_stock:[],
    staff:[{id:'st1',business_id:BIZ,full_name:'Owner Person',role:'owner',user_id:'u-owner',active:true,
      email:'owner@test.co',phone:'',title:null,module_perms:null,modules:null,
      commission_service_bps:null,commission_product_bps:null,created_at:'2026-01-01T00:00:00Z'}],
    staff_invites:[],staff_hours:[],staff_branches:[{business_id:BIZ,staff_id:'st1',branch_id:'br1'}],
    loyalty_programs:[program],loyalty_rewards:[],loyalty_reward_branches:[],
    loyalty_reward_services:[],loyalty_reward_products:[],
    loyalty_tiers:[{id:'t-gold',business_id:BIZ,name:'Gold',threshold:10}],
    loyalty_branch_overrides:[],gift_cards:[],referral_programs:[],membership_plans:[],
    retention_programs:[],firm_config_versions:[]
  };
  const chainable=resolveOut=>{
    const q={single:false,head:false,countMode:null,op:'select'};
    const chain={};
    for(const m of ['eq','neq','is','in','not','gte','lte','lt','gt','or','ilike','contains',
      'overlaps','order','limit','range','abortSignal'])chain[m]=()=>chain;
    chain.select=(cols,opts)=>{if(opts&&opts.count){q.countMode=opts.count;q.head=!!opts.head}return chain};
    chain.single=()=>{q.single=true;return chain};
    chain.maybeSingle=()=>{q.single=true;return chain};
    chain.update=p=>{q.op='update';q.payload=p;return chain};
    chain.insert=p=>{q.op='insert';q.payload=p;return chain};
    chain.upsert=p=>{q.op='upsert';q.payload=p;return chain};
    chain.delete=()=>{q.op='delete';return chain};
    chain.then=(res,rej)=>Promise.resolve(resolveOut(q)).then(res,rej);
    return chain;
  };
  const query=table=>chainable(q=>{
    if(q.op!=='select')return {data:null,error:null};
    const rows=TABLES[table]||[];
    if(q.countMode&&q.head)return {data:null,count:rows.length,error:null};
    if(q.single)return {data:rows[0]??null,error:null};
    return {data:rows,count:q.countMode?rows.length:null,error:null};
  });
  const SPINE=[
    {kind:'points',active:true,customer_visible:true,running_since:'2026-02-01T00:00:00Z',
     paused_since:null,balance_scope:'business_pot'},
    {kind:'tiers',active:true,customer_visible:true,running_since:'2026-02-01T00:00:00Z',
     paused_since:null,balance_scope:'business_pot'}];
  const rpcData=name=>{
    switch(name){
      case 'get_my_personas':return {staff:[{business_id:BIZ,business_slug:'${SLUG}',
        business_name:'Test Co',role:'owner',modules:MODULES}],customer:[],
        default_route:'#/workspace/${SLUG}/dashboard'};
      case 'platform_get_business_control_v94':return {workspace_access:true,quick_earn_catalogue_enabled:true};
      case 'get_my_modules':return {role:'owner',is_super_admin:false,modules:MODULES,
        module_perms:Object.fromEntries(MODULES.map(m=>[m,'rw']))};
      case 'get_my_modules_at_v115':return {role:'owner',modules:MODULES,
        module_perms:Object.fromEntries(MODULES.map(m=>[m,'rw']))};
      case 'get_customer_feature_capabilities':return {};
      case 'get_workspace_locale_preference_v97':return {locale:'en',version:1};
      case 'get_notifications':return {unread:0,items:[]};
      case 'require_module_scope_v145':return null;
      case 'get_business_signup_config':return null;
      case 'get_business_public':return {business:bizRow,services:TABLES.services};
      case 'business_get_customer_capabilities_v89':return {redemption_enabled:true};
      case 'business_programme_usage_v271':return null;
      case 'business_get_welcome_offer_v215':return {configured:false};
      case 'get_programmes_v314':case 'business_get_programmes_v314':
        return {programmes:SPINE,programmes_contract:'v391'};
      default:return null;
    }
  };
  const rpc=name=>chainable(()=>({data:rpcData(name),error:null}));
  const channel=()=>{const c={on:()=>c,subscribe:()=>c,unsubscribe:()=>{}};return c};
  const auth=new Proxy({
    getSession:async()=>({data:{session:{user:{id:'u-owner',email:'owner@test.co'}}},error:null}),
    getUser:async()=>({data:{user:{id:'u-owner',email:'owner@test.co'}},error:null}),
    onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}}),
    signOut:async()=>({error:null})
  },{get:(t,k)=>k in t?t[k]:async()=>({data:null,error:null})});
  const client={from:query,rpc,auth,channel,removeChannel(){},
    functions:{invoke:async()=>({data:null,error:null})},
    storage:{from:()=>({getPublicUrl:()=>({data:{publicUrl:''}})})}};
  Object.defineProperty(window,'supabase',{value:{createClient:()=>client},writable:false,configurable:false});
})();`;
}
