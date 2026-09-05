/* nestly_v538 — the WhatsApp Inbox is reachable from the production sidebar.
 * nestly_v768 — and then it is not: owner ruling 2026-09-05, "i am not using
 * whatsapp inbox for now (i do not want business owner to see this at all)".
 *
 * WHY THIS TEST EXISTS. C5 shipped a route, a render function and a MODULES
 * entry, and every one of them was correct — and the nav row still did not
 * exist, because 'support' had been added to a group declared `flat`. Source
 * that "looks wired" is not evidence. The same discipline now guards the
 * reverse: 'support' STAYS in NAVGROUPS.items and MODULES (it is a server-side
 * entitlement; un-retiring it is one line), and the row must still never render
 * — for a tenant WITH the entitlement as much as one without. So this executes
 * the REAL navHtml() against real module lists and asserts on the HTML a
 * merchant would actually receive.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const app = readFileSync(resolve(ROOT, 'app/app.js'), 'utf8');

function boundedRange(startMarker, endPattern) {
  const all = app.split('\n');
  const from = all.findIndex(l => l.startsWith(startMarker));
  assert.ok(from >= 0, `missing ${startMarker}`);
  const to = all.findIndex((l, i) => i >= from && endPattern.test(l));
  assert.ok(to >= from, `no end for ${startMarker}`);
  return all.slice(from, to + 1).join('\n');
}

function buildNav() {
  const modules = boundedRange('const MODULES=', /^\s*\};?$/);
  const retired = boundedRange('const RETIRED_BUSINESS_MODULES_V768=', /;\s*$/);
  const navgroups = boundedRange('const NAVGROUPS=', /^\s*\];$/);
  const activeGroup = boundedRange('function activeGroupKey(', /^\}$/);
  const navFn = boundedRange('function navHtml(page,idPrefix=', /^\}$/);
  const extracted = [modules, retired, navgroups, activeGroup, navFn].join('\n');
  /* Stub only what the extracted ranges do NOT already declare. */
  const candidates = {
    S: `var S={biz:{id:'b1',currency:'SGD'},myRole:'owner',myModules:MODULES_UNDER_TEST,myModulePerms:Object.fromEntries(MODULES_UNDER_TEST.map(m=>[m,'rw']))};`,
    CUI: `var CUI={icon:()=>''};`,
    navOpen: `var navOpen={};`,
    waitlistBadgeHtml: `var waitlistBadgeHtml=()=>'';`,
    appointmentsNavBadgeHtml: `var appointmentsNavBadgeHtml=()=>'';`,
    sectorHidesAppointmentsV276: `var sectorHidesAppointmentsV276=()=>false;`,
    sectorShowsBottlesV275: `var sectorShowsBottlesV275=false;`,
    OWNER_ONLY_MODULES: `var OWNER_ONLY_MODULES=new Set(['branches','staffmembers','settings','setup','bottlesetup']);`,
    FINANCE_MODULES: `var FINANCE_MODULES=new Set(['expenses','pnl','staffperf','customerintel']);`,
    ROLE_CAPABILITIES: `var ROLE_CAPABILITIES={owner:new Set(['view_finance'])};`,
    roleCanUseModule: `var roleCanUseModule=(r,m)=>!FINANCE_MODULES.has(m)||ROLE_CAPABILITIES[r]?.has('view_finance')===true;`,
    filterResolvedModulesForRole: `var filterResolvedModulesForRole=(ms,r)=>[...(Array.isArray(ms)?ms:[])].filter(m=>(r==='owner'||!OWNER_ONLY_MODULES.has(m))&&roleCanUseModule(r,m));`,
    CUSTOMER_INTERFACE_VIEWS_VISIBLE_V334: `var CUSTOMER_INTERFACE_VIEWS_VISIBLE_V334=[['a','Customer Action','#/customer-interface/appointment','customers']];`,
    isBarSectorV275: `var isBarSectorV275=()=>false;`,
    HIDDEN_BUSINESS_SURFACES: `var HIDDEN_BUSINESS_SURFACES=new Set();`,
    CUSTOMER_INTERFACE_TABS_V368: `var CUSTOMER_INTERFACE_TABS_V368=['appointment','actions'];`,
  };
  const harness = Object.entries(candidates)
    .filter(([name]) => !new RegExp(`(?:const|let|var|function)\\s+${name}\\b`).test(extracted))
    .map(([, code]) => code).join('\n');

  return new Function('MODULES_UNDER_TEST', 'PAGE_UNDER_TEST', 'ID_PREFIX',
    `${harness}\n${extracted}\nreturn navHtml(PAGE_UNDER_TEST, ID_PREFIX||'nav');`);
}

/* What public.get_my_modules returned for Cubbly SPA when v538 shipped — it DID
   include 'support' (granted through platform_module_overrides_v94). */
const CUBBLY = ['appointments','bookings','clients','customerintel','dailyreport','dashboard',
  'expenses','giftcards','inventory','loyalty','memberships','packages','pnl','referrals',
  'reports','retention','sales','services','staffperf','support','till','waitlist'];
const CONTROL = CUBBLY.filter(m => m !== 'support');

test('v768: the real retired set is what the rail reads, and it names both modules', () => {
  const retired = boundedRange('const RETIRED_BUSINESS_MODULES_V768=', /;\s*$/);
  const set = new Function(`${retired}\nreturn RETIRED_BUSINESS_MODULES_V768;`)();
  assert.ok(set.has('support'), "'support' must be retired (owner: business owners must not see the inbox)");
  assert.ok(set.has('giftcards'), "'giftcards' must be retired (owner: there is no gift card)");
});

test('v768: a business WITH the support entitlement still gets NO WhatsApp Inbox row', () => {
  const html = buildNav()(CUBBLY, ['dashboard']);
  assert.ok(!html.includes('WhatsApp Inbox'), 'the Inbox label must not appear in the rail');
  assert.ok(!html.includes('href="#/support"'), 'no row may link to the support route');
  /* ...and the rest of the rail is unharmed. */
  assert.match(html, /Customer Interface/, 'the Customer Interface group itself still renders');
  assert.match(html, />Customers/, 'the flat Customers link is untouched');
});

test('v768: a business WITHOUT the entitlement gets no row either', () => {
  const html = buildNav()(CONTROL, ['dashboard']);
  assert.ok(!html.includes('WhatsApp Inbox'));
  assert.ok(!html.includes('href="#/support"'));
});

test('v768: no gift card row for a tenant whose entitlement list still carries giftcards', () => {
  const html = buildNav()(CUBBLY, ['dashboard']);
  assert.ok(!html.includes('href="#/giftcards"'), 'no rail row may lead to gift cards');
  assert.ok(!/>Gift cards</.test(html), 'the Gift cards label must not appear');
});

test("v768: 'support' stays declared on the Customer Interface group so un-retiring is one line", () => {
  const navgroups = boundedRange('const NAVGROUPS=', /^\s*\];$/);
  assert.match(navgroups, /\{key:'customerui'[^}]*items:\[[^\]]*'support'[^\]]*\]/,
    "'support' must remain in the group's items — the retired set is the only switch");
});

test('v768: the router refuses a typed #/support instead of rendering the inbox', () => {
  assert.match(app, /if\(RETIRED_BUSINESS_MODULES_V768\.has\(pageKey\)\)\{\s*toast\(/,
    'the route guard must answer a retired module with a toast, the V303 giftcards shape');
});

test('a flat group still renders exactly one link — the defect that caused v538', () => {
  const flatGroups = app.match(/\{key:'(home|customers)',[^}]*flat:'[^']+',items:\[[^\]]*\]/g) || [];
  assert.equal(flatGroups.length, 2, 'expected exactly the two flat groups');
  for (const g of flatGroups) {
    const items = (g.match(/items:\[([^\]]*)\]/) || [,''])[1].split(',').filter(Boolean);
    assert.equal(items.length, 1,
      `flat group renders items[0] only; a second item is inert: ${g}`);
  }
});

test('the rail never leaks a Meta internal', () => {
  const html = buildNav()(CUBBLY, ['dashboard']);
  for (const forbidden of ['wamid', 'graph.facebook', 'WHATSAPP_', 'phone_number_id', 'PK-']) {
    assert.ok(!html.includes(forbidden), `${forbidden} must not appear in the rail`);
  }
});

test('MOBILE renders the same rail — the drawer calls the same navHtml, and it is inbox-free too', () => {
  const html = buildNav()(CUBBLY, ['dashboard'], 'mnav');
  assert.ok(!html.includes('WhatsApp Inbox'));
  assert.match(html, /Customer Interface/);
});
