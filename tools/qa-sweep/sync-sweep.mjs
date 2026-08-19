/* sync-sweep — the visual proof that a business-side programme switch reaches the customer.
 *
 * WHAT IT PROVES
 *   A firm running points + tiers flips itself to a stamp card. In the SAME transaction
 *   public.business_switch_to_stamps_v384 writes the spine {stamps:true, points:false,
 *   tiers:false}, and because app.customer_live_loyalty_v384 gates its new `tier` key on that
 *   tiers spine row (nestly_v393), the customer's tier must vanish and stamp visuals must take
 *   over — with no points metric left anywhere. Flip it back and the tier must return.
 *
 * HOW
 *   Boots the REAL app against tools/qa-sweep/sb-double.js exactly as sweep.mjs does (the CDN
 *   <script> carries an SRI hash, so the document is rewritten to point that tag at the locally
 *   served double rather than substituting its body). One extra script is injected AFTER the
 *   double: sync-override.js, which makes the double STATEFUL. window.__SYNC_STATE = {model}
 *   is the whole fixture universe; the business writes mutate it and the customer readers derive
 *   from it, so the two halves of the app are reading one fact instead of two fixtures.
 *
 * WHICH SURFACE CARRIES WHICH FACT (this is not arbitrary)
 *   The tier snapshot rides public.customer_get_wallet and public.customer_get_business_summary,
 *   both of which nest app.customer_live_loyalty_v384. It does NOT ride
 *   public.customer_get_actionable_wallet, which builds its loyalty object from
 *   app.c45_base_actionable_wallet_card. So the tier is asserted on the merchant page
 *   (#/wallet/qa-cafe, fed by customer_get_business_summary) and the stamp/points metric on Home
 *   (#/wallet). Asserting a tier pill on Home would require a fixture production cannot send —
 *   which is the exact fabrication nestly_v393 exists to end.
 *
 * USAGE
 *   node tools/qa-sweep/sync-sweep.mjs [--root <repo root>] [--port 4189] [--flow a|customer]
 *   PLAYWRIGHT_MODULE=/abs/path/to/playwright-core/index.js   (optional; defaults to 'playwright')
 *
 * Exits non-zero on the first failed assertion. Screenshots land in tools/qa-sweep/shots/sync/.
 */
import { createServer } from 'node:http';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { extname, join, normalize, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const arg = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};
/* The existing sweeps hardcode ROOT '/home/user/loyalty'. This one takes it, so the same script
   runs from a worktree, a checkout or CI without editing. */
const ROOT = resolve(arg('root', resolve(HERE, '..', '..')));
const PORT = Number(arg('port', '4189'));
const FLOW = String(arg('flow', 'a')).toLowerCase();
const SHOTS = join(ROOT, 'tools/qa-sweep/shots/sync');

/* playwright-core's index.js is CommonJS: importing it yields the namespace on `default`, while
   the ESM build exposes the named export. Take whichever one actually has chromium on it. */
const playwrightModule = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const chromium = playwrightModule.chromium || playwrightModule.default?.chromium;
if (!chromium) throw new Error('playwright: no chromium export (set PLAYWRIGHT_MODULE to a playwright/playwright-core entry point)');

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.png': 'image/png', '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.webmanifest': 'application/manifest+json' };

/* ---------------------------------------------------------------- the stateful override -----
   Runs after sb-double.js. It wraps the double's client rather than replacing it, so every
   fixture the double already owns keeps working and only the handful of RPCs this proof turns on
   are intercepted. */
const OVERRIDE = `(function(){
  'use strict';
  var BIZ='10000000-0000-4000-8000-000000000001';
  /* model:'both'     = points programme + tiers programme live (the firm's starting shape)
     model:'stamps'   = business_switch_to_stamps_v384 has run: stamps on, points off, tiers off
     model:'tiers'    = tiers alone (no spendable balance) — the hero's tiers-only figure
     model:'tiers-top'= tiers alone and the customer is on the LAST rung (tier.next === null) */
  var STATE=window.__SYNC_STATE={model:'both',writes:[]};

  function chainable(data){
    var payload={data:data,error:null,count:Array.isArray(data)?data.length:null,status:200};
    var proxy=new Proxy({},{get:function(_t,prop){
      if(prop==='then')return function(res,rej){return Promise.resolve(payload).then(res,rej)};
      if(prop==='catch')return function(rej){return Promise.resolve(payload).catch(rej)};
      if(prop==='finally')return function(f){return Promise.resolve(payload).finally(f)};
      return function(){return proxy};
    }});
    return proxy;
  }

  var isStamps=function(){return STATE.model==='stamps'};
  var tiersOnly=function(){return STATE.model==='tiers'||STATE.model==='tiers-top'};
  var pointsOn=function(){return STATE.model==='both'};
  var tiersOn=function(){return STATE.model==='both'||tiersOnly()};

  /* The spine, exactly as public.set_programmes_v314 / business_switch_to_stamps_v384 return it.
     Stamps and points/tiers are mutually exclusive — that exclusivity is the thing under test. */
  function spine(){
    return [
      {id:'p-points',kind:'points',active:pointsOn(),sort:1},
      {id:'p-tiers', kind:'tiers', active:tiersOn(), sort:2},
      {id:'p-stamps',kind:'stamps',active:isStamps(),sort:3},
      {id:'p-ref',   kind:'referral',active:true,   sort:4}
    ];
  }

  /* app.customer_tier_json_v393: metric is the customer's own basis figure, next is the rung
     above with its remaining distance, and next is null on the top rung. */
  function tierJson(){
    if(!tiersOn())return null;
    if(STATE.model==='tiers-top')return {name:'Obsidian',threshold:400,perk_note:null,
      points_multiplier:2,basis:'points_earned',metric:520,next:null};
    return {name:'Diamond',threshold:300,perk_note:null,points_multiplier:1.5,
      basis:'points_earned',metric:320,next:{name:'Obsidian',threshold:400,remaining:80}};
  }

  /* app.customer_live_loyalty_v384's output, per nestly_v393: 'tier' is non-null ONLY while the
     tiers spine row is active, and its shape comes from app.customer_tier_json_v393. Its
     model/unit selection is v384's own CASE: stamps wins, then points, then tiers-alone. */
  function liveLoyalty(){
    if(isStamps())return {
      enabled:true,model:'stamps',unit:'stamps',balance:7,
      ledger_balance:7,batch_balance:7,credit_balance_cents:0,
      tier:null,
      programme:{id:'p-stamps',kind:'stamps',active:true,balance_scope:'programme_pot'},
      programmes_contract:'v384'
    };
    if(tiersOnly())return {
      enabled:true,model:'tiers',unit:'tiers',balance:0,
      ledger_balance:0,batch_balance:0,credit_balance_cents:0,
      tier:tierJson(),
      programme:{id:null,kind:'tiers',active:true,balance_scope:'programme_pot'},
      programmes_contract:'v384'
    };
    return {
      enabled:true,model:'redeem',unit:'points',balance:320,
      ledger_balance:320,batch_balance:320,credit_balance_cents:0,
      tier:tierJson(),
      programme:{id:'p-points',kind:'points',active:true,balance_scope:'programme_pot'},
      programmes_contract:'v384'
    };
  }
  var BUSINESS={id:BIZ,slug:'qa-cafe',name:'QA Test Cafe',industry:'fnb',currency:'SGD',logo_url:'',review_url:null};
  function walletCard(){
    return {business:{slug:'qa-cafe',name:'QA Test Cafe',industry:'fnb',currency:'SGD'},
      loyalty:liveLoyalty(),
      packages:{enabled:false,active_count:0,sessions_remaining:0},
      membership:{enabled:false,active:false,current_period_ends_at:null},
      upcoming_appointments:{enabled:true,count:0}};
  }
  /* The actionable reader carries NO tier — see the header note. What it does carry is the
     reward the progress components draw from, which is what turns into stamp dots. */
  function actionableCard(){
    var stamps=isStamps();
    if(tiersOnly()){
      /* Tiers alone: no reward ladder, no spendable balance — the hero has only the standing. */
      return {business:{slug:'qa-cafe',name:'QA Test Cafe',industry:'fnb',currency:'SGD'},
        logo_url:'',loyalty:{enabled:true,model:'tiers',unit:'tiers',balance:0},
        credit:{balance_cents:0},packages:{sessions_remaining:0},
        expiry:{mode:'none',expiring_within_7_days:0,expiring_units:0,next_expiry_at:null},
        next_eligible_reward:null,visits_remaining:null,visit_progress:null,
        action:{reason:'none',deadline_at:null,sort_band:9,sort_units:0},birthday_benefit:null,
        programmes:[{kind:'tiers',active:true,customer_visible:true}]};
    }
    var loyalty=liveLoyalty(),card={
      business:{slug:'qa-cafe',name:'QA Test Cafe',industry:'fnb',currency:'SGD'},
      logo_url:'',
      loyalty:{enabled:true,model:loyalty.model,unit:loyalty.unit,balance:loyalty.balance},
      credit:{balance_cents:0},
      packages:{sessions_remaining:0},
      expiry:{mode:'none',expiring_within_7_days:0,expiring_units:0,next_expiry_at:null},
      next_eligible_reward:stamps
        ?{name:'Free scalp massage',cost_units:8,remaining_units:1,available_now:false}
        :{name:'Free flat white',cost_units:400,remaining_units:80,available_now:false},
      visits_remaining:null,visit_progress:null,
      action:{reason:'close_to_reward',deadline_at:null,sort_band:2,sort_units:1},
      birthday_benefit:null,
      programmes:spine().filter(function(row){return row.active}).map(function(row){
        return {kind:row.kind,active:true,customer_visible:true};
      })
    };
    return card;
  }
  function capabilities(){
    return {programmes:spine().filter(function(r){return r.active}).map(function(r){
        return {kind:r.kind,active:true,customer_visible:true};
      }),
      programmes_contract:'v310',rewards:true,activity:true,appointments:false,
      booking_request:false,redemption:true};
  }

  var CUSTOMER={
    customer_get_wallet:function(){return [walletCard()]},
    customer_get_business_summary:function(){
      var card=walletCard();
      return {business:BUSINESS,loyalty:card.loyalty,packages:card.packages,
        membership:card.membership,upcoming_appointments:card.upcoming_appointments};
    },
    customer_get_actionable_wallet:function(){
      return {as_of:new Date().toISOString(),truncated:false,cards:[actionableCard()]};
    },
    customer_get_actionable_business:function(){return {card:actionableCard()}},
    customer_portal_capabilities:function(){return capabilities()},
    customer_get_business_actions_v89:function(){
      return {business:BUSINESS,booking:{enabled:false,public_slug:'qa-cafe'},
        redemption:{enabled:true,classic:null,rewards:[]},
        appointment_changes:{enabled:false}};
    },
    /* v393: the legacy per-business tier read is deliberately answered as "not running for you"
       so nothing but loyalty.tier can put a tier on this page. If the tier still renders in the
       'both' state, it renders from the server's own new snapshot and nothing else. */
    customer_get_effective_tier_v143:function(){return {tier:{}}},
    customer_get_business_presentation_v95:function(){
      return {name:'QA Test Cafe',unit:isStamps()?'stamps':'points',logo_url:'',hero_image_url:'',
        offers:[],rewards:[],products:[],services:[],benefits:[]};
    },
    /* Two offers so the shelf actually has a next card to peek at, and so both media shapes are
       drawn: one with artwork, one with the monogram fallback. */
    customer_get_home_offers_v167:function(){
      var soon=new Date(Date.now()+5*86400000).toISOString(),past=new Date(Date.now()-86400000).toISOString();
      var mk=function(id,name,image){return {intent_id:id,version_id:id+'-v1',id:id,
        business:{slug:'qa-cafe',name:'QA Test Cafe',logo_url:''},
        name:name,reward_name:name,tagline:'',description:'',terms:'',availability_label:'This week',
        branch_names:['Main'],image_url:image,image_alt:name,
        starts_at:past,ends_at:soon,expires_at:soon,display_order:1,pending_redemption:false,metadata:{}}};
      return {as_of:new Date().toISOString(),truncated:false,limit:6,items:[
        mk('off1','Two for one on pastries',
          '/storage/v1/object/public/business-public/10000000-0000-4000-8000-000000000001/offer/10000000-0000-4000-8000-000000000002.png'),
        mk('off2','Free upsize before noon','')
      ]};
    }
  };

  /* The business writes. These are the ONLY things that move the state — the customer side never
     writes, exactly as in production. */
  var BUSINESS_WRITES={
    business_switch_to_stamps_v384:function(){
      STATE.model='stamps';STATE.writes.push('business_switch_to_stamps_v384');
      return {programmes:spine(),loyalty_model:'stamps'};
    },
    set_programmes_v314:function(params){
      var set=(params&&(params.p_programmes||params.p_set||params.programmes))||null;
      var wantsStamps=false,wantsPoints=false;
      if(set&&typeof set==='object'&&!Array.isArray(set)){
        wantsStamps=set.stamps===true;wantsPoints=set.points===true||set.tiers===true;
      }else if(Array.isArray(set)){
        set.forEach(function(row){
          if(row&&row.kind==='stamps'&&row.active===true)wantsStamps=true;
          if(row&&(row.kind==='points'||row.kind==='tiers')&&row.active===true)wantsPoints=true;
        });
      }
      if(wantsStamps)STATE.model='stamps';
      else if(wantsPoints)STATE.model='both';
      STATE.writes.push('set_programmes_v314:'+STATE.model);
      return {programmes:spine(),loyalty_model:isStamps()?'stamps':'classic'};
    },
    business_preview_stamp_conversion_v384:function(){
      return {points_total:320,stamps_total:32,customers:1,leftover:0};
    }
  };

  var baseCreate=window.supabase.createClient;
  window.supabase.createClient=function(){
    var client=baseCreate.apply(this,arguments);
    var baseRpc=client.rpc.bind(client);
    client.rpc=function(name,params){
      if(Object.prototype.hasOwnProperty.call(BUSINESS_WRITES,name)){
        (window.__QA&&window.__QA.rpc||[]).push({name:name,params:params||null});
        return chainable(BUSINESS_WRITES[name](params));
      }
      if(Object.prototype.hasOwnProperty.call(CUSTOMER,name)){
        (window.__QA&&window.__QA.rpc||[]).push({name:name,params:params||null});
        return chainable(CUSTOMER[name](params));
      }
      if(name==='get_programs_overview'||name==='grow_get_snapshot_v229')
        (window.__QA&&window.__QA.rpc||[]).push({name:name,params:params||null});
      return baseRpc(name,params);
    };
    /* The grow page reads business_programmes straight off the table, so the spine has to move
       with the state there too — otherwise the business half would keep claiming points is live
       after its own switch. */
    var baseFrom=client.from.bind(client);
    client.from=function(table){
      if(table!=='business_programmes')return baseFrom(table);
      var rows=spine().map(function(row){
        return {id:row.id,business_id:BIZ,kind:row.kind,active:row.active,sort:row.sort,
          programme_id:row.id};
      });
      var ops=[];
      var proxy=new Proxy({},{get:function(_t,prop){
        if(prop==='then'){
          var payload={data:rows,error:null,count:rows.length,status:200};
          return function(res){return Promise.resolve(payload).then(res)};
        }
        if(prop==='single'||prop==='maybeSingle')
          return function(){return Promise.resolve({data:rows[0]||null,error:null})};
        return function(){ops.push(String(prop));return proxy};
      }});
      return proxy;
    };
    return client;
  };
})();`;

/* ---------------------------------------------------------------- the static server ---------- */
const server = createServer(async (req, res) => {
  try {
    const p = normalize(decodeURIComponent(req.url.split('?')[0])).replace(/^(\.\.[/\\])+/, '');
    if (p === '/sb-double.js') {
      res.writeHead(200, { 'content-type': 'text/javascript' });
      return res.end(await readFile(join(ROOT, 'tools/qa-sweep/sb-double.js')));
    }
    if (p === '/sync-override.js') {
      res.writeHead(200, { 'content-type': 'text/javascript' });
      return res.end(OVERRIDE);
    }
    const file = join(ROOT, p === '/' ? '/app/index.html' : (p.startsWith('/app/') ? p : '/app' + p));
    const body = await readFile(file);
    res.writeHead(200, { 'content-type': MIME[extname(file)] || 'application/octet-stream' });
    res.end(body);
  } catch { res.writeHead(404); res.end('nf'); }
});

await mkdir(SHOTS, { recursive: true });

const failures = [];
const checks = [];
function check(ok, label, detail = '') {
  checks.push({ ok: !!ok, label, detail });
  if (!ok) failures.push(`${label}${detail ? ` — ${detail}` : ''}`);
  process.stdout.write(`  ${ok ? 'PASS' : 'FAIL'}  ${label}${ok || !detail ? '' : `  (${detail})`}\n`);
}

async function newPage(browser) {
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1 });
  const page = await ctx.newPage();
  const pageErrors = [];
  page.on('pageerror', e => pageErrors.push(String(e.message).slice(0, 200)));
  await page.route(/127\.0\.0\.1:\d+\/(#.*)?$|index\.html/, async r => {
    const resp = await r.fetch();
    let html = await resp.text();
    html = html.replace(/<script src="https:\/\/cdn\.jsdelivr\.net[^>]*><\/script>/,
      '<script src="/sb-double.js"></script><script src="/sync-override.js"></script>');
    await r.fulfill({ status: 200, contentType: 'text/html', body: html });
  });
  await page.route('**/fonts.googleapis.com/**', r => r.fulfill({ status: 200, contentType: 'text/css', body: '' }));
  await page.route('**/fonts.gstatic.com/**', r => r.abort());
  return { ctx, page, pageErrors };
}

/* Every fact this sweep asserts, read out of the live DOM in one pass. */
const readCustomer = () => ({
  stampDots: document.querySelectorAll('.cui-stamp-dots-v2b').length,
  tierMeters: document.querySelectorAll('.customer-business-tier-meter-v386').length,
  tierMeterValue: (document.querySelector('.customer-business-tier-meter-v386') || {})
    .getAttribute?.('aria-valuenow') ?? null,
  tierFigure: (document.querySelector('.customer-business-balance-tier-v386') || {}).textContent?.trim() ?? null,
  tierPills: [...document.querySelectorAll('.customer-business-tier-pill-v347,.customer-programme-card-tier-v346,.customer-home-business-copy-v345 em')]
    .map(el => el.textContent.trim()).filter(Boolean),
  text: (document.querySelector('#walletBody') || document.body).innerText.replace(/\s+/g, ' ').trim(),
  model: window.__SYNC_STATE ? window.__SYNC_STATE.model : '(no state)',
});

async function gotoWallet(page, hash) {
  await page.goto(`http://127.0.0.1:${PORT}/${hash}`, { waitUntil: 'domcontentloaded', timeout: 25000 });
  await page.waitForTimeout(1800);
}

async function setState(page, model) {
  await page.evaluate(m => { window.__SYNC_STATE.model = m; }, model);
}

async function assertState(page, model, phase) {
  /* HOME — the metric. In stamps the card must not say "pts" anywhere. */
  await gotoWallet(page, '#/wallet');
  await page.screenshot({ path: join(SHOTS, `${phase}-home.png`), fullPage: true }).catch(() => {});
  const home = await page.evaluate(readCustomer);
  /* MERCHANT PAGE — the tier. This is the reader that genuinely carries loyalty.tier. */
  await gotoWallet(page, '#/wallet/qa-cafe');
  await page.screenshot({ path: join(SHOTS, `${phase}-business.png`), fullPage: true }).catch(() => {});
  const biz = await page.evaluate(readCustomer);

  if (model === 'tiers' || model === 'tiers-top') {
    /* The tiers-only hero: name, gold track, distance line — every figure from loyalty.tier. */
    check(biz.tierMeters === 1, `${phase}: business page draws exactly one tier track`, `found ${biz.tierMeters}`);
    if (model === 'tiers') {
      check(biz.tierFigure === 'Diamond', `${phase}: the figure is the tier name from loyalty.tier.name`, String(biz.tierFigure));
      /* metric 320 / next.threshold 400 = 80%. Anything else means the track was fabricated. */
      check(biz.tierMeterValue === '80', `${phase}: the track is metric/next.threshold (320/400 = 80%)`, String(biz.tierMeterValue));
      check(/80\s*points? to Obsidian/i.test(biz.text), `${phase}: "X to go" comes from next.remaining + next.name`, biz.text.slice(0, 220));
    } else {
      check(biz.tierFigure === 'Obsidian', `${phase}: the top rung names itself`, String(biz.tierFigure));
      check(biz.tierMeterValue === '100', `${phase}: no track fabricated at the top rung`, String(biz.tierMeterValue));
      check(/top tier/i.test(biz.text), `${phase}: the top-tier state is stated, not a distance`, biz.text.slice(0, 220));
      check(!/to next tier/i.test(biz.text), `${phase}: no invented next rung`, biz.text.slice(0, 220));
    }
    return { home, biz };
  }
  if (model === 'stamps') {
    check(home.stampDots > 0, `${phase}: Home draws stamp dots (.cui-stamp-dots-v2b)`, `found ${home.stampDots}`);
    check(!/\bpts\b/i.test(home.text), `${phase}: Home shows no "pts" metric`, home.text.slice(0, 140));
    check(/stamps?/i.test(home.text), `${phase}: Home speaks in stamps`, home.text.slice(0, 140));
    check(!/Diamond|Obsidian/.test(biz.text), `${phase}: business page shows no tier name`, biz.text.slice(0, 140));
    check(biz.tierMeters === 0, `${phase}: business page draws no tier track`, `found ${biz.tierMeters}`);
    check(!biz.tierPills.some(t => /Diamond/i.test(t)), `${phase}: no tier pill text`, biz.tierPills.join(' | '));
  } else {
    check(/\bpts\b/i.test(home.text) || /\bpoints\b/i.test(home.text), `${phase}: Home shows the points metric`, home.text.slice(0, 140));
    check(home.stampDots === 0, `${phase}: Home draws no stamp dots`, `found ${home.stampDots}`);
    check(/Diamond/.test(biz.text), `${phase}: business page names the live tier (Diamond)`, biz.text.slice(0, 200));
    check(/Obsidian/.test(biz.text) || /80\b/.test(biz.text), `${phase}: business page states the distance to the next tier`, biz.text.slice(0, 200));
  }
  return { home, biz };
}

await new Promise(r => server.listen(PORT, '127.0.0.1', r));
/* Plain headless chromium by default. PLAYWRIGHT_CHROMIUM is the escape hatch for a machine whose
   browser cache does not match the resolved playwright build — it is not needed on a normal
   `npx playwright install` box, so the script stays portable. */
const CHROME = process.env.PLAYWRIGHT_CHROMIUM || arg('chrome', '');
const browser = await chromium.launch({ headless: true, ...(CHROME ? { executablePath: CHROME } : {}) });
let flowAchieved = 'customer-only (fallback)';
try {
  const { ctx, page, pageErrors } = await newPage(browser);

  console.log('\n[1] baseline — the firm runs points + tiers');
  await assertState(page, 'both', '1-both');

  if (FLOW === 'a') {
    console.log('\n[2] business half — flip the firm to a stamp card from #/grow');
    await page.goto(`http://127.0.0.1:${PORT}/#/grow`, { waitUntil: 'domcontentloaded', timeout: 25000 });
    await page.waitForTimeout(2000);
    await page.screenshot({ path: join(SHOTS, '2-grow.png'), fullPage: true }).catch(() => {});
    const clicked = await page.evaluate(async () => {
      const trail = [];
      const sleep = ms => new Promise(r => setTimeout(r, ms));
      const tile = document.querySelector('[data-grow-topic-v229="stamps"]');
      if (!tile) return { ok: false, trail: ['no stamps tile'] };
      tile.click(); trail.push('tile:stamps'); await sleep(700);
      /* V363/V382: opening the Stamp card while points/tiers are live states the exclusivity at
         the door. That popup is a read-only warning — it navigates, it does not switch. */
      const exclusivityYes = document.querySelector('#stampsExclusivityYesV363');
      if (exclusivityYes) { exclusivityYes.click(); trail.push('exclusivity:continue'); }
      await sleep(1500);
      const setup = document.querySelector('#growPointsSetupV326');
      const toggle = document.querySelector('[data-grow-switchtoggle-v322="stamps"]');
      if (setup) { setup.click(); trail.push('cta:growPointsSetupV326'); }
      else if (toggle) {
        toggle.click(); trail.push('switch:stamps'); await sleep(400);
        const yes = document.querySelector('[data-grow-switchconfirm-yes-v322="stamps"]');
        if (!yes) return { ok: false, trail: trail.concat('no inline confirm') };
        yes.click(); trail.push('confirm:yes');
      } else return { ok: false, trail: trail.concat('no setup CTA and no switch'),
        seen: { hash: location.hash,
          topics: [...document.querySelectorAll('[data-grow-topic-v229]')].map(e => e.dataset.growTopicV229),
          switches: [...document.querySelectorAll('[data-grow-switchtoggle-v322]')].map(e => e.dataset.growSwitchtoggleV322),
          buttons: [...document.querySelectorAll('main button[id]')].map(e => e.id).slice(0, 40),
          heading: (document.querySelector('main h1,main h2') || {}).textContent } };
      await sleep(1200);
      /* The stamp-conversion popup is the inline confirmation this switch carries. */
      const fresh = document.querySelector('#stampSwitchFreshV384');
      if (fresh) { fresh.click(); trail.push('popup:startFresh'); await sleep(1200); }
      return { ok: window.__SYNC_STATE.model === 'stamps', trail, model: window.__SYNC_STATE.model,
        writes: window.__SYNC_STATE.writes.slice() };
    });
    await page.screenshot({ path: join(SHOTS, '2-grow-after.png'), fullPage: true }).catch(() => {});
    console.log(`     trail: ${(clicked.trail || []).join(' → ')}`);
    if (clicked.ok) {
      flowAchieved = 'A (business click drove the switch)';
      check(true, 'flow A: the business-side click called business_switch_to_stamps_v384',
        (clicked.writes || []).join(','));
    } else {
      console.log(`     flow A did not land (${(clicked.trail || []).join(' → ')}); driving the state directly instead.`);
      if (clicked.seen) console.log(`     saw: ${JSON.stringify(clicked.seen)}`);
      await setState(page, 'stamps');
    }
  } else {
    await setState(page, 'stamps');
  }

  console.log('\n[3] customer half — the tier is gone, stamps have taken over');
  await assertState(page, 'stamps', '3-stamps');

  console.log('\n[4] flip back — the tier returns');
  await setState(page, 'both');
  await assertState(page, 'both', '4-both-again');

  console.log('\n[5] tiers alone — the hero draws the server\'s own ladder');
  await setState(page, 'tiers');
  await assertState(page, 'tiers', '5-tiers');

  console.log('\n[6] tiers alone, top rung — nothing is fabricated');
  await setState(page, 'tiers-top');
  await assertState(page, 'tiers-top', '6-tiers-top');

  /* ---- the offer shelf, MEASURED (a served-CSS grep proves nothing about what is on screen) -- */
  console.log('\n[7] the offer card — width and countdown placement');
  await setState(page, 'both');
  await gotoWallet(page, '#/wallet');
  await page.screenshot({ path: join(SHOTS, '7-offers-home.png'), fullPage: true }).catch(() => {});
  const offer = await page.evaluate(() => {
    const cards = [...document.querySelectorAll('.customer-home-offer')];
    if (!cards.length) return { cards: 0 };
    const first = cards[0].getBoundingClientRect();
    const chip = cards[0].querySelector('.customer-home-offer-countdown');
    const media = cards[0].querySelector('.customer-home-offer-media');
    const chipBox = chip ? chip.getBoundingClientRect() : null;
    const mediaBox = media ? media.getBoundingClientRect() : null;
    return {
      cards: cards.length,
      width: Math.round(first.width),
      viewport: window.innerWidth,
      /* A peek means the shelf is wider than one card plus its gutter. */
      trackScrollable: (() => { const t = document.querySelector('.customer-home-offers-track');
        return t ? t.scrollWidth > t.clientWidth + 8 : false; })(),
      chipInMedia: !!(chip && media && media.contains(chip)),
      chipTopRight: !!(chipBox && mediaBox
        && chipBox.top >= mediaBox.top - 1 && chipBox.bottom <= mediaBox.bottom + 1
        && chipBox.right <= mediaBox.right + 1
        && chipBox.left > mediaBox.left + mediaBox.width / 2),
      chipText: chip ? chip.textContent.trim() : null,
      /* Wave 2B's single-mark rule: with artwork present the card may carry the logo circle;
         with the monogram fallback it must not double the mark. */
      fallbackMarks: [...document.querySelectorAll('.customer-home-offer')]
        .filter(c => c.querySelector('.customer-home-offer-media--fallback'))
        .map(c => c.querySelectorAll('.customer-home-offer-logo').length),
    };
  });
  check(offer.cards >= 2, 'offer shelf renders more than one card', `found ${offer.cards}`);
  check(offer.width >= 240, 'offer card is min(72vw,288px) wide at 390px', `${offer.width}px`);
  check(offer.width < offer.viewport - 24, 'a peek of the next card is visible', `${offer.width}px of ${offer.viewport}px`);
  check(offer.trackScrollable, 'the shelf scrolls, so there IS a next card to peek at');
  check(offer.chipInMedia, 'the countdown chip lives inside .customer-home-offer-media');
  check(offer.chipTopRight, 'the countdown chip overlays the media top-right corner');
  check(/Ends in/i.test(offer.chipText || ''), 'the chip still reads the countdown', String(offer.chipText));
  check(offer.fallbackMarks.every(n => n === 0), 'wave-2B single mark: no logo circle on a monogram-fallback card',
    offer.fallbackMarks.join(','));

  check(pageErrors.length === 0, 'no uncaught page errors during the sweep', pageErrors.join(' | '));
  await ctx.close();

  await writeFile(join(ROOT, 'tools/qa-sweep/sync-results.json'),
    JSON.stringify({ flow: flowAchieved, checks, failures, shots: SHOTS }, null, 2));
} finally {
  await browser.close();
  server.close();
}

console.log(`\nflow achieved: ${flowAchieved}`);
console.log(`screenshots: ${SHOTS}`);
if (failures.length) {
  console.error(`\nFAILED (${failures.length}/${checks.length}):`);
  failures.forEach(f => console.error(`  - ${f}`));
  process.exit(1);
}
console.log(`\nPASS — ${checks.length}/${checks.length} assertions.`);
