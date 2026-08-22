/* V446 — one customer fixture, shared by the wide-layout geometry test and the route sweep.
 *
 * It is an in-page `window.supabase` stub, installed as an init script, so the REAL bundles, the
 * REAL hash router and the REAL render functions run in a REAL Chrome. Nothing here stubs a
 * function under test: every RPC returns a server-shaped payload and the app does its own work.
 *
 * Deliberate fixture facts the assertions lean on:
 *   · TWO claimable rewards, so the "ready" count is a plural and the reward LIST has more than
 *     one row to lay out.
 *   · one of them carries a deliberately long single word inside a long name, which is what makes
 *     a collapsed copy column visible as letter-wrapping rather than as slightly tight text.
 *   · redemption enabled, availability 'available_at_counter' and a catalog id on both, because
 *     customerRewardCanRedeem (PROTECTED, not under test here) is what decides whether the cards
 *     render at all.
 */
export const BIZ='b2222222-2222-4222-8222-222222222222';
export const SLUG='kopitest';
export const BUSINESS_NAME='Kopi Test Bar';
/* The name the geometry assertions look for. Four ordinary words; nothing about it should force a
   break inside a word at any width. */
export const LONG_REWARD_NAME='Free Kopi Set Breakfast Platter';
export const SHORT_REWARD_NAME='Free Kopi';

export const customerFixtureSource=({
  redemptionEnabled=true,
  rewards='two',
  bookingEnabled=true,
  /* A stamps programme puts the "Stamp card" tile on the profile, which is the tile whose shortcut
     page is titled "Rewards" — the exact doubling REG-002 reported. */
  withStamps=false,
  /* Names that must not be clipped on the merchant's own header: a long Latin one and a
     non-Latin one, because the fix must not depend on English label widths. */
  businessName=BUSINESS_NAME,
  withBranchContact=true,
  /* Home realism, from the coordinator's LIVE reading: this customer holds nine businesses, most
     at 0 pts, one with sessions left, and readiness spread across two of them. A greeting that is
     derived from the cards is only meaningfully testable across several cards in mixed states. */
  extraBusinesses=false
}={})=>`(()=>{
  const BIZ='${BIZ}',SLUG='${SLUG}';
  const BUSINESS={id:BIZ,slug:SLUG,name:${JSON.stringify(businessName)},currency:'SGD',
    brand_color:'#C24135',bio:'A neighbourhood kopitiam.',
    address:'313 Orchard Road #02-11 Singapore 238895',phone:'+65 6123 4567'};
  /* next.label, NOT next.name: customerTierPanelMarkupV194 reads next.label, and a fixture that
     spells it 'name' renders "0 more points to ." — a fixture bug that looks exactly like a
     product bug. (The fail-open is real and reported separately: the sentence prints even when
     the label is empty.) NOTE: no backticks in this block — it lives inside a template literal. */
  const TIER={current:{label:'Gold',benefits:['10% off every visit']},name:'Gold',threshold:10,
    basis:'points_earned',metric:300,points_multiplier:1,perk_note:'10% off every visit',
    next:{label:'Platinum',threshold:500}};
  const LOYALTY={balance:920,unit:'points',enabled:true,tier:TIER};
  const REWARD_ROWS=${rewards==='none'?'[]':`[
    {id:'rw-long',name:${JSON.stringify(LONG_REWARD_NAME)},customer_name:${JSON.stringify(LONG_REWARD_NAME)},
     cost_points:100,availability:'available_at_counter',redemption_kind:'catalog_reward',
     description:'One kopi and one kaya toast set, any weekday morning before eleven.',
     entitlement_expiry_days:30,instructions:'Show this QR to the cashier before you pay.',
     terms:'One per customer per day. Not valid with other offers.',image_ref:null,
     eligibility:{branches:{scope:'all',count:0},services:{scope:'all',count:0},products:{scope:'all',count:0}}},
    {id:'rw-short',name:${JSON.stringify(SHORT_REWARD_NAME)},customer_name:${JSON.stringify(SHORT_REWARD_NAME)},
     cost_points:50,availability:'available_at_counter',redemption_kind:'catalog_reward',
     description:'A hot kopi, on the house.',image_ref:null}
  ]`};
  const NEXT_REWARD={name:${JSON.stringify(SHORT_REWARD_NAME)},cost_units:50,available_now:true,
    remaining_units:0,unit:'points'};
  const CARD={business:BUSINESS,loyalty:LOYALTY,credit:{},packages:{sessions_remaining:0},
    next_eligible_reward:NEXT_REWARD,visit_progress:{},birthday_benefit:null,
    expiry:{expiring_next_30_days:0,next_expiry_at:null}};
  /* A second READY business, so the greeting's old "sum of the per-card 1s" would have printed 2
     — the exact figure measured live — plus three that are not ready, one of them on sessions. */
  const otherCard=(slug,name,ready,over)=>({business:{id:'b-'+slug,slug,name,currency:'SGD'},
    loyalty:{balance:over&&over.balance!=null?over.balance:0,unit:'points',enabled:true,tier:null},
    credit:{},packages:{sessions_remaining:(over&&over.sessions)||0},
    next_eligible_reward:ready
      ?{name:'Free pastry',cost_units:50,available_now:true,remaining_units:0,unit:'points'}
      :{name:'Free pastry',cost_units:50,available_now:false,remaining_units:20,unit:'points'},
    visit_progress:{},birthday_benefit:null,expiry:{expiring_next_30_days:0,next_expiry_at:null}});
  const EXTRA_CARDS=${extraBusinesses?`[
    otherCard('qa-kaya-toast','QA Kaya Toast',true,null),
    otherCard('qa-kopi-lab','QA Kopi Lab',false,null),
    otherCard('bistro-999','Bistro 999',false,{balance:116,sessions:3}),
    otherCard('cafe2u','Cafe2U',false,null)
  ]`:'[]'};
  const ALL_CARDS=[CARD,...EXTRA_CARDS];
  const CAPS={wallet:true,rewards:true,tiers:true,points_mode:'both',activity:true,
    appointments:true,booking_request:${bookingEnabled?'true':'false'},packages:false,membership:false,
    programmes_contract:'v391',
    programmes:[{kind:'points',active:true,customer_visible:true,running_since:'2026-02-01T00:00:00Z',
        paused_since:null,balance_scope:'business_pot'},
      ${withStamps?`{kind:'stamps',active:true,customer_visible:true,running_since:'2026-02-01T00:00:00Z',
        paused_since:null,balance_scope:'business_pot'},`:''}
      {kind:'tiers',active:true,customer_visible:true,running_since:'2026-02-01T00:00:00Z',
        paused_since:null,balance_scope:'business_pot'}]};
  const PRESENTATION={locale:'en',brand:{hero_color:'#C24135'},
    programme:{name:BUSINESS.name+' Rewards',tagline:'Every kopi counts',unit:'points',balance:920,
      tier:TIER,benefits:[{label:'10% off every visit'}],offers:[]},
    catalogue:{rewards:[],products:[],services:[
      {id:'sv1',name:'Kopi',price_cents:500},{id:'sv2',name:'Kaya toast set',price_cents:100}]},
    capabilities:{booking_enabled:${bookingEnabled?'true':'false'}},
    contact:{address:BUSINESS.address,phone:BUSINESS.phone,
      hours:[{day:'Mon-Fri',open:'07:00',close:'19:00'},{day:'Sat-Sun',open:'08:00',close:'16:00'}]}};
  const chainable=resolveOut=>{
    const q={single:false,head:false,countMode:null,op:'select'};
    const chain={};
    for(const m of ['eq','neq','is','in','not','gte','lte','lt','gt','or','ilike','contains',
      'overlaps','order','limit','range','abortSignal'])chain[m]=()=>chain;
    chain.select=(cols,opts)=>{if(opts&&opts.count){q.countMode=opts.count;q.head=!!opts.head}return chain};
    chain.single=()=>{q.single=true;return chain};
    chain.maybeSingle=()=>{q.single=true;return chain};
    chain.update=()=>chain;chain.insert=()=>chain;chain.upsert=()=>chain;chain.delete=()=>chain;
    chain.then=(res,rej)=>Promise.resolve(resolveOut(q)).then(res,rej);
    return chain;
  };
  const query=()=>chainable(q=>q.single?{data:null,error:null}:{data:[],count:0,error:null});
  const DENIED={code:'42501',message:'not available'};
  /* Every RPC the page asks for is recorded, so a test can assert that tapping a control reached
     the intent it claims to (the names, never the effects — nothing here writes). */
  window.__v446Rpc=[];
  const rpcData=name=>{
    switch(name){
      case 'get_customer_feature_capabilities':return {customer_identity:true,customer_wallet:true,
        customer_actions:true,customer_actionable_wallet:true,customer_phone_registration:true,
        customer_birthday_benefits:true,customer_in_app_inbox:true,customer_notifications:true};
      case 'customer_get_profile':return {profile:{full_name:'Mei Ling Tan',birth_date:'1990-03-14',
        gender:null,preferred_language:'en',phone:'81863833',email:'mei@example.sg'}};
      case 'get_my_personas':return {staff:[],customer:[{business_id:BIZ,business_slug:SLUG,
        business_name:BUSINESS.name}],default_route:'#/wallet'};
      case 'customer_get_actionable_business':return {card:CARD};
      case 'customer_get_actionable_wallet':return {cards:ALL_CARDS};
      case 'customer_get_wallet':return ALL_CARDS;
      case 'customer_list_programmes_v89':return {programmes:ALL_CARDS.map(card=>({
        business_id:card.business.id,business_slug:card.business.slug,
        business_name:card.business.name,loyalty:card.loyalty,unit:'points',
        balance:card.loyalty.balance}))};
      case 'customer_get_programme_selector_media_v96':return {items:[]};
      case 'customer_get_business_summary':return {business:BUSINESS,loyalty:LOYALTY,
        packages:{},membership:{}};
      case 'customer_portal_capabilities':return CAPS;
      case 'customer_get_business_actions_v89':return {booking:{enabled:${bookingEnabled?'true':'false'}},
        appointment_changes:{enabled:false},
        redemption:{enabled:${redemptionEnabled?'true':'false'},classic:null},rewards:REWARD_ROWS};
      case 'customer_get_business_presentation_v95':return PRESENTATION;
      case 'customer_get_effective_tier_v143':return {tier:TIER};
      case 'customer_get_promotions_v155':return {items:[]};
      case 'customer_get_reward_catalog':return {points_mode:'both',rewards:REWARD_ROWS};
      case 'customer_get_entitlements_v427':return {items:[]};
      case 'customer_get_reward_history_v422':return {items:[]};
      case 'customer_get_referral_card_v300':return {enabled:false};
      case 'customer_get_growth_offers_v108':return {offers:[]};
      case 'customer_get_home_offers_v167':return {offers:[]};
      case 'customer_get_stamp_card_v323':return ${withStamps?`{enabled:true,contract:'v323',slots:10,filled:7,
        cycle_index:2,running:true,validity_days:90,expires_at:'2026-12-31T00:00:00Z',expired:false,
        spend_per_stamp_cents:500,ready:false,pot_migrated:false,
        milestones:[{slot:5,name:'Free kaya toast',claimed_this_cycle:true,availability:'claimed',
            is_final:false,stamps_to_go:0},
          {slot:10,name:${JSON.stringify(LONG_REWARD_NAME)},claimed_this_cycle:false,
            availability:'in_progress',is_final:true,stamps_to_go:3}]}`:'null'};
      case 'customer_get_transaction_history_v81':
      case 'customer_get_transaction_history_v167':return {items:[]};
      case 'customer_get_loyalty_details':return {loyalty:{balance:920,unit:'points'},activity:[],
        expiry:{expiring_next_30_days:0,next_expiry_at:null}};
      case 'customer_get_booking_requests':return {items:[]};
      case 'customer_get_appointments_page':return {items:[],page:1,total:0};
      case 'customer_record_account_open_v175':return {status:'ok'};
      case 'customer_sync_in_app_inbox_global':return {status:'ok'};
      case 'customer_get_in_app_inbox_global_count':return {unread:0};
      /* The compact header's Directions/Call buttons are REPLACED by this read (app.js ~11220).
         Until it lands — and permanently, for a branch with neither address nor phone — the wordy
         placeholder stands. withBranchContact:false exercises that state on purpose. */
      case 'customer_get_offer_business_contact_v173':return {business:BUSINESS,
        branch:${withBranchContact?'{address:BUSINESS.address,phone:BUSINESS.phone}':'{}'}};
      default:return null;
    }
  };
  const SILENT=new Set(['customer_get_gift_cards','customer_get_packages','customer_get_memberships',
    'customer_get_pending_promotion_prompt_v122','customer_get_bottles_v275']);
  const rpc=(name,args)=>{
    window.__v446Rpc.push({name,args:args||null});
    return SILENT.has(name)
      ?chainable(()=>({data:null,error:DENIED}))
      :chainable(()=>({data:rpcData(name),error:null}));
  };
  const channel=()=>{const c={on:()=>c,subscribe:()=>c,unsubscribe:()=>{}};return c};
  const auth=new Proxy({
    getSession:async()=>({data:{session:{user:{id:'u-cust',email:'mei@example.sg'}}},error:null}),
    getUser:async()=>({data:{user:{id:'u-cust',email:'mei@example.sg'}},error:null}),
    onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}}),
    signOut:async()=>({error:null})
  },{get:(t,k)=>k in t?t[k]:async()=>({data:null,error:null})});
  const client={from:query,rpc,auth,channel,removeChannel(){},
    functions:{invoke:async()=>({data:null,error:null})},
    storage:{from:()=>({getPublicUrl:()=>({data:{publicUrl:''}})})}};
  Object.defineProperty(window,'supabase',{value:{createClient:()=>client},writable:false,configurable:false});
})();`;
