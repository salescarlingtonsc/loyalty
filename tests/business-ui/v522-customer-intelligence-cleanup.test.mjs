import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';

/* nestly_v522 — Customer Intelligence pre-release cleanup.
   Owner ruling 2026-08-26: keep the module disabled for now, but finish it for release, and do
   NOT enable economics_driver_policy_v109 to make the page look complete.

   The audit that produced this work reconciled every displayed figure against production base
   tables and found the arithmetic sound; what was wrong was the packaging. These tests pin the
   four packaging fixes. They EXECUTE the real modules and the real gate function rather than
   grepping for the lines that implement them — this repo has been burned by source-regex tests
   staying green over dead behaviour. */

const here=path.dirname(fileURLToPath(import.meta.url));
const repo=path.resolve(here,'../..');
const require=createRequire(import.meta.url);
const app=fs.readFileSync(path.join(repo,'app/app.js'),'utf8');
const RevenueTruthUI=require(path.join(repo,'app/revenue-truth.js'));

function section(start,end){
  const from=app.indexOf(start);
  assert.notEqual(from,-1,`missing start marker: ${start}`);
  const to=app.indexOf(end,from+start.length);
  assert.notEqual(to,-1,`missing end marker: ${end}`);
  return app.slice(from,to);
}
const ci=section('async function customerIntelligencePage(){','function reportCalendarPresetV300(');
const dashboard=section('async function dashboard(){','async function clientsPage(){');
const reports=section('async function reportsPage(){','async function setupPage(){');

/* ---- 3. finance capability mapping: the rail and the server must agree ------------------ */

test('V522 customerintel is a finance module, so the rail matches the RPCs',()=>{
  /* Executed, not grepped: build the real gate out of app.js and run it for all five roles.
     Production truth, measured 2026-08-26: get_revenue_truth_v106 and get_customer_intelligence_v83
     both raise 42501 without app.has_perm(business,'view_finance'), and app.role_perms grants
     view_finance to exactly owner, manager and bookkeeper. */
  const src=[
    section('const ROLE_CAPABILITIES={','const hasRoleCapability='),
    section('const FINANCE_MODULES=new Set(','const OWNER_ONLY_MODULES='),
    section('const roleCanUseModule=(role,module)=>','\nconst '),
  ].join('\n');
  const roleCanUseModule=new Function(`${src}; return roleCanUseModule;`)();

  const permitted=['owner','manager','bookkeeper'];
  const denied=['staff','frontdesk'];
  for(const role of permitted){
    assert.equal(roleCanUseModule(role,'customerintel'),true,
      `${role} holds view_finance on the server and must see the module`);
  }
  for(const role of denied){
    assert.equal(roleCanUseModule(role,'customerintel'),false,
      `${role} is refused 42501 by both RPCs, so the rail must not offer the module`);
  }
  /* The pre-existing finance modules must be unaffected. */
  assert.equal(roleCanUseModule('frontdesk','pnl'),false);
  assert.equal(roleCanUseModule('frontdesk','clients'),true);
});

/* ---- 1. "Paid visits" -------------------------------------------------------------------- */

test('V522 the customer table says Paid visits, never a bare Visits',()=>{
  assert.match(ci,/<th>Paid visits<\/th>/);
  assert.match(ci,/data-label="Paid visits"/);
  assert.doesNotMatch(ci,/<th>Visits<\/th>/,
    'a bare "Visits" column here means something different from the Dashboard\'s Visits');
  assert.doesNotMatch(ci,/data-label="Visits"/);
});

test('V522 the export column is renamed with the label',()=>{
  assert.match(ci,/'paid_visit_count'/);
  assert.doesNotMatch(ci,/'visit_count'/,
    'the CSV must not disagree with the column heading it was exported from');
});

test('V522 help text names both metrics so they cannot be confused',()=>{
  /* Measured on production for Cubbly SPA, 28 Jul - 26 Aug 2026: the Dashboard counts 46 valid
     visits where Customer Intelligence counts 23, because this surface excludes zero-price rows
     such as package sessions. Both are defensible; shipping them under one word was not. */
  assert.match(ci,/Paid visits<\/b> counts only visits that charged an amount/);
  assert.match(ci,/Valid visits<\/b>, which also counts zero-price visits/);
});

/* ---- 2. one canonical lifecycle presentation --------------------------------------------- */

const lifecycle={status:'ok',metrics:{transacting_identified_customers:5,
  existing_returning_customers:4,repeat_purchasers_in_period:4,reactivated_customers:0,
  existing_customer_share_pct:80,repeat_in_period_rate_pct:80},coverage:{},definitions:{}};
const truth={status:'ok',
  scope:{business_id:'b',currency:'SGD',timezone:'per_outlet',branch_id:null,
    period:{from:'2026-07-28',to:'2026-08-27'}},
  totals:{known_revenue_minor:448500,identified_revenue_minor:445500,anonymous_revenue_minor:3000,
    completed_transactions:27,identified_transactions:26,anonymous_transactions:1,
    itemized_transactions:20},
  coverage:{identity_revenue_pct:99.33,identity_transaction_pct:96.3,
    reconciled_transaction_pct:0,itemization_transaction_pct:74.07},
  freshness:{},limitations:[]};
const renderTruth=(t=truth,l=lifecycle)=>
  RevenueTruthUI.render(RevenueTruthUI.buildViewModel({truth:t,lifecycle:l,requestState:'ok'}));
const textOf=html=>String(html).replace(/<[^>]+>/g,' ').replace(/\s+/g,' ').trim();

test('V522 retention is summarised in one line and points at the canonical screen',()=>{
  const html=renderTruth(),text=textOf(html);
  assert.match(text,/4 of 5 identified customers who purchased in this period had bought before/);
  assert.match(text,/Repeat purchase rate this period: 80%/);
  assert.match(html,/href="#\/reports"/,'the summary must lead to the full analysis');
  assert.match(text,/Business Insights (&rarr;|→) Customer Retention/);
});

test('V522 the duplicated lifecycle metric cards are gone',()=>{
  /* Business Insights -> Customer Retention renders these from the SAME
     get_customer_lifecycle_v107 call, and it carries the period-on-period comparison this
     surface never had. Two visually different answers from one RPC is the thing being removed. */
  const text=textOf(renderTruth());
  for(const label of ['Reactivated customers','Existing customer share','Repeat purchasers this period']){
    assert.ok(!text.includes(label),`"${label}" belongs to Business Insights only`);
  }
});

test('V522 a lifecycle with no denominator refuses to invent one',()=>{
  const text=textOf(renderTruth(truth,{status:'ok',
    metrics:{transacting_identified_customers:0,existing_returning_customers:0,
      repeat_in_period_rate_pct:null},coverage:{},definitions:{}}));
  assert.match(text,/Not enough data to describe returning customers/);
  assert.ok(!/0 of 0/.test(text),'a zero denominator must not be dressed up as a real answer');
});

/* ---- 5. the dead anonymousRevenueCents reference ------------------------------------------ */

test('V522 a missing anonymous revenue figure is captioned as missing',()=>{
  /* revenueMarkup tested truth.totals.anonymousRevenueCents, a key buildViewModel never sets,
     so the "not supplied" branch was unreachable and a missing figure was captioned as a real
     recorded zero. The VALUE was always honest; only the caption was wrong. */
  const text=textOf(renderTruth({...truth,
    totals:{...truth.totals,anonymous_revenue_minor:null}}));
  assert.match(text,/has not been supplied/i);
  assert.match(text,/Not available/,'the value itself must stay honest');
  assert.ok(!/SGD\s*0\.00/.test(text),'never a synthetic zero');
});

/* ---- no duplicated metric labels across the four money surfaces --------------------------- */

test('V522 no metric label is shared between Customer Intelligence and Dashboard or Reports',()=>{
  const labels=src=>{
    const out=new Set();
    for(const m of src.matchAll(/<th>([^<${}]{3,40})<\/th>/g))out.add(m[1].trim());
    for(const m of src.matchAll(/"l">([^<${}]{3,40})<\/div>/g))out.add(m[1].trim());
    for(const m of src.matchAll(/metricCard\('([^']{3,40})'/g))out.add(m[1].trim());
    return out;
  };
  const rtSrc=fs.readFileSync(path.join(repo,'app/revenue-truth.js'),'utf8');
  const ciLabels=labels(ci+rtSrc);
  for(const other of [labels(dashboard),labels(reports)]){
    const shared=[...ciLabels].filter(label=>other.has(label));
    assert.deepEqual(shared,[],
      `these labels appear on two surfaces and must either mean the same thing or be renamed: ${shared.join(', ')}`);
  }
});

/* ---- the gated section is absent, not a placeholder --------------------------------------- */

test('V522 Sector Economics is not rendered at all while its flag refuses',()=>{
  /* Owner ruling: "do not expose an evidence-gated placeholder as half of a newly enabled
     module". The module degrades honestly on its own, but an honest placeholder still occupies a
     third of the page. Executed, not grepped: pull the real predicate out of app.js and run it
     against the error shapes production actually returns. */
  const start=ci.indexOf('const economicsGatedOffV522=');
  assert.notEqual(start,-1,'the v109 suppression gate is gone');
  const end=ci.indexOf(';',ci.indexOf('String(error?.message||\'\')))',start));
  const gate=new Function('errors',
    `${ci.slice(start,end+1).replace('lastEconomicsBundle?.errors||[]','errors||[]')}
     return economicsGatedOffV522;`);

  assert.equal(gate([{code:'0A000',message:'v109 economics and sector policy is not enabled'}]),true,
    'production today: the flag is off and the section must be absent');
  assert.equal(gate([{message:'v109 economics and sector policy is not enabled'}]),true,
    'PostgREST does not always carry the code through');
  assert.equal(gate([]),false,'with the flag on the section must come back with no other change');
  assert.equal(gate([{code:'42501',message:'finance permission required'}]),false,
    'a permission failure is a different story and keeps its own state');
});

/* ---- the v109 flag stays off -------------------------------------------------------------- */

test('V522 nothing here turns Sector Economics on',()=>{
  /* Owner ruling: do not enable v109 merely to make the page look complete. Its three RPCs
     refuse with 0A000 in production and none of its numbers has ever been reconciled.
     The flag name appears in app.js only inside the comment explaining the suppression above —
     what must not exist is any client path that could WRITE it. Platform feature flags live in
     app.platform_feature_flags and are changed by migration, never from a browser. */
  const writers=[...app.matchAll(/\.rpc\(\s*['"]([a-zA-Z0-9_]+)/g)].map(match=>match[1]);
  /* Match feature FLAGS specifically. An earlier, looser /set_feature/ matched
     business_set_featured_offer_v462 — a featured offer, nothing to do with flags. */
  const suspicious=writers.filter(name=>/feature_flag|platform_feature/i.test(name));
  assert.deepEqual(suspicious,[],`the client must not be able to flip a platform feature flag: ${suspicious.join(', ')}`);
  /* And the flag must only ever be read about, never assigned, in client source. */
  assert.ok(!/economics_driver_policy_v109\s*[:=]/.test(app),
    'the client assigns the platform flag');
});

/* ---- surface assets carry a hand-maintained cache key ------------------------------------- */

test('V522 every surface asset cache key is at least as new as the file it serves',()=>{
  /* app/index.html carries a per-surface asset list whose "?v=" tokens are written BY HAND, not
     derived from content like the app chunks are. Editing revenue-truth.js without bumping its
     token shipped the new file to the CDN under the old URL, so a returning browser kept the old
     module — observed live on 2026-08-26: production served "Customer behaviour" while the page
     still rendered the previous "Exact customer meanings".

     The invariant: a file annotated with nestly_vNNN markers must not be served under a cache key
     older than its newest marker. This is checkable, and it is exactly what was missed. */
  const html=fs.readFileSync(path.join(repo,'app/index.html'),'utf8');
  const assets=[...html.matchAll(/"\/([a-z0-9-]+\.(?:js|css))\?v=([^"]+)"/g)]
    .map(([,file,key])=>({file,key}));
  assert.ok(assets.length>0,'the surface asset list is gone');

  /* KNOWN PRE-EXISTING, reported to the owner 2026-08-26 rather than fixed here: customer-ui.js
     carries nestly_v396 markers but is still served under "20260813-v298-caption-once", so some
     returning customer browsers may be running a stale copy of it. It is the same defect class
     this test exists for, in the CUSTOMER surface — outside the Customer Intelligence mandate
     this file belongs to, and a one-token fix somebody who owns that surface should make.
     Remove the entry when the token is bumped; do not add to this list to make a build pass. */
  const knownPreExisting=new Set(['customer-ui.js']);
  const stale=[];
  for(const {file,key} of assets){
    const full=path.join(repo,'app',file);
    if(!fs.existsSync(full))continue;
    const source=fs.readFileSync(full,'utf8');
    const markers=[...source.matchAll(/nestly_v(\d+)/g)].map(match=>Number(match[1]));
    if(!markers.length||knownPreExisting.has(file))continue;
    const newest=Math.max(...markers);
    /* Keys look like 20260826-v522 or 20260819-w2c; only the -vNNN shape is comparable. */
    const keyVersion=/-v(\d+)$/.exec(key);
    if(!keyVersion){
      /* A non-version key cannot be compared, so it must not be older than a versioned file.
         Flag only when the file carries a marker newer than any key we can read. */
      stale.push(`${file} carries nestly_v${newest} but its cache key "${key}" is unversioned`);
      continue;
    }
    if(Number(keyVersion[1])<newest){
      stale.push(`${file} carries nestly_v${newest} but is served as "?v=${key}"`);
    }
  }
  assert.deepEqual(stale,[],
    `bump the ?v= token in app/index.html for: ${stale.join('; ')}`);
});
