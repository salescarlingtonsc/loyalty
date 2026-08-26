/* nestly_v538 — the WhatsApp Inbox is reachable from the production sidebar.
 *
 * WHY THIS TEST EXISTS. C5 shipped a route, a render function and a MODULES
 * entry, and every one of them was correct — and the nav row still did not
 * exist, because 'support' had been added to a group declared `flat`, and a
 * flat group renders items[0] and nothing else. Source that "looks wired" is
 * not evidence. So this executes the REAL navHtml() against real module lists
 * and asserts on the HTML a merchant would actually receive.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const app = readFileSync(resolve(ROOT, 'app/app.js'), 'utf8');

function lines(from, to) {
  /* Line-addressed, because navHtml's dependencies are scattered and a
     text-delimited slice pulled in half the application. These four ranges are
     the real production source for MODULES, NAVGROUPS, activeGroupKey and
     navHtml; everything else is stubbed so the rail is the only thing under
     test. */
  return app.split('\n').slice(from - 1, to).join('\n');
}

function boundedRange(startMarker, endPattern) {
  const all = app.split('\n');
  const from = all.findIndex(l => l.startsWith(startMarker));
  assert.ok(from >= 0, `missing ${startMarker}`);
  const to = all.findIndex((l, i) => i > from && endPattern.test(l));
  assert.ok(to > from, `no end for ${startMarker}`);
  return all.slice(from, to + 1).join('\n');
}

function buildNav() {
  const modules = boundedRange('const MODULES=', /^\s*\};?$/);
  const navgroups = boundedRange('const NAVGROUPS=', /^\s*\];$/);
  const activeGroup = boundedRange('function activeGroupKey(', /^\}$/);
  const navFn = boundedRange('function navHtml(page,idPrefix=', /^\}$/);
  const extracted = [modules, navgroups, activeGroup, navFn].join('\n');
  /* Stub only what the extracted ranges do NOT already declare. Guessing which
     helpers came along for the ride is how this harness kept colliding. */
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
    `${harness}\n${modules}\n${navgroups}\n${activeGroup}\n${navFn}\nreturn navHtml(PAGE_UNDER_TEST, ID_PREFIX||'nav');`);
}

/* Exactly what public.get_my_modules returns for Cubbly SPA in production, which
   DOES include 'support' (granted through platform_module_overrides_v94). */
const CUBBLY = ['appointments','bookings','clients','customerintel','dailyreport','dashboard',
  'expenses','giftcards','inventory','loyalty','memberships','packages','pnl','referrals',
  'reports','retention','sales','services','staffperf','support','till','waitlist'];
/* A control tenant with no support entitlement — the same list minus 'support'. */
const CONTROL = CUBBLY.filter(m => m !== 'support');

test('a business WITH the support entitlement gets a WhatsApp Inbox row', () => {
  const html = buildNav()(CUBBLY, ['dashboard']);
  assert.match(html, /WhatsApp Inbox/, 'the Inbox label must appear in the rail');
  assert.match(html, /href="#\/support"/, 'the row must link to the support route');
});

test('it sits inside CUSTOMER INTERFACE, not Customers (owner ruling)', () => {
  const html = buildNav()(CUBBLY, ['dashboard']);
  const ci = html.indexOf('Customer Interface');
  const inbox = html.indexOf('WhatsApp Inbox');
  assert.ok(ci >= 0, 'the Customer Interface group must render');
  assert.ok(inbox > ci, 'the Inbox row must fall inside the Customer Interface group');
  /* The Customers group is flat and must stay a single link. Regression guard for
     the exact defect this migration fixes: adding an item to a flat group is
     silently inert, so nobody should be tempted to put it back there. */
  const customers = html.indexOf('>Customers');
  if (customers >= 0 && customers < ci) {
    assert.ok(inbox > ci,
      'the Inbox must not be rendered as part of the flat Customers group');
  }
});

test('a business WITHOUT the entitlement gets no row at all', () => {
  const html = buildNav()(CONTROL, ['dashboard']);
  assert.ok(!html.includes('WhatsApp Inbox'), 'no Inbox label for an unentitled tenant');
  assert.ok(!html.includes('href="#/support"'), 'no support link for an unentitled tenant');
  /* ...and the rest of the rail is unharmed. */
  assert.match(html, /Customer Interface/, 'the group itself still renders');
  assert.match(html, />Customers/, 'the flat Customers link is untouched');
});

test('opening #/support lights the Customer Interface group', () => {
  const html = buildNav()(CUBBLY, ['support']);
  const inbox = html.indexOf('href="#/support"');
  assert.ok(inbox >= 0);
  const row = html.slice(inbox - 40, inbox + 160);
  assert.match(row, /class="act"|aria-current="page"/,
    'the Inbox row must show as active on its own route');
});

test('a flat group still renders exactly one link — the defect that caused this', () => {
  const html = buildNav()(CUBBLY, ['dashboard']);
  /* Dashboard and Customers are flat single-surface groups. If a future change
     adds a second item to either, this catches it before it ships as a silent
     no-op the way 'support' did. */
  const flatGroups = app.match(/\{key:'(home|customers)',[^}]*flat:'[^']+',items:\[[^\]]*\]/g) || [];
  assert.equal(flatGroups.length, 2, 'expected exactly the two flat groups');
  for (const g of flatGroups) {
    const items = (g.match(/items:\[([^\]]*)\]/) || [,''])[1].split(',').filter(Boolean);
    assert.equal(items.length, 1,
      `flat group renders items[0] only; a second item is inert: ${g}`);
  }
});

test('the rail never leaks a Meta internal', () => {
  const html = buildNav()(CUBBLY, ['support']);
  for (const forbidden of ['wamid', 'graph.facebook', 'WHATSAPP_', 'phone_number_id', 'PK-']) {
    assert.ok(!html.includes(forbidden), `${forbidden} must not appear in the rail`);
  }
});

test('MOBILE renders the same row — the drawer calls the same navHtml', () => {
  /* app/app.js:16110 builds the mobile "More workspace modules" drawer with
     navHtml(page,'mobile-nav'), so the rail and the drawer are one code path.
     Asserting it rather than assuming it: a second mobile-only module list is
     exactly the kind of thing that would silently diverge. */
  const desktop = buildNav()(CUBBLY, ['dashboard'], 'nav');
  const mobile = buildNav()(CUBBLY, ['dashboard'], 'mobile-nav');
  assert.match(mobile, /WhatsApp Inbox/, 'the mobile drawer must carry the Inbox');
  assert.match(mobile, /href="#\/support"/);
  /* Same items either way; only element ids differ. */
  /* idPrefix is the ONLY intended difference, and it lands in id, for and
     aria-controls. Normalise all three; anything else that differs is a real
     divergence between the two surfaces. */
  const strip = html => html
    .replace(/\bid="[^"]*"/g, '')
    .replace(/\bfor="[^"]*"/g, '')
    .replace(/\baria-controls="[^"]*"/g, '');
  assert.equal(strip(mobile), strip(desktop),
    'desktop and mobile must render an identical module list');
});

test('MOBILE hides it for an unentitled tenant too', () => {
  const mobile = buildNav()(CONTROL, ['dashboard'], 'mobile-nav');
  assert.ok(!mobile.includes('WhatsApp Inbox'));
});

/* nestly_v540 — an unconfirmed send must not look delivered. */
test('the thread names delivery state in words, not a raw enum', () => {
  const copy = app.match(/const SUPPORT_DELIVERY_COPY_V540=Object\.freeze\(\{[\s\S]*?\}\);/);
  assert.ok(copy, 'the delivery vocabulary must exist');
  for (const state of ['queued','processing','sent','delivered','read','failed']) {
    assert.match(copy[0], new RegExp(`\\b${state}:`), `${state} must have merchant-facing copy`);
  }
  /* The two states that mean "not with the customer yet" must not read as done. */
  assert.match(copy[0], /queued:'Sending/);
  assert.match(copy[0], /failed:'Not sent'/);
});

test('pending and failed sends are visually distinguished, not just annotated', () => {
  const render = app.slice(app.indexOf('function supportRenderThreadV531'),
                           app.indexOf('function supportNewIdemKeyV535'));
  assert.match(render, /const pending=out&&\(message\.status==='queued'\|\|message\.status==='processing'\)/);
  assert.match(render, /var\(--danger\)/, 'a failed send must carry the danger colour');
  assert.match(render, /dashed/, 'a pending send must be visibly unfinished');
});

test('the thread keeps polling until every outbound message is terminal', () => {
  const render = app.slice(app.indexOf('function supportRenderThreadV531'),
                           app.indexOf('function supportNewIdemKeyV535'));
  assert.match(render, /SUPPORT_TERMINAL_STATUS_V540/);
  assert.match(render, /statusPoll=setInterval/);
  /* And it must be cleaned up, or every thread a busy merchant opens leaks a timer. */
  assert.match(render, /registerRouteDisposerV535\(\(\)=>\{clearInterval\(timer\);if\(statusPoll\)clearInterval\(statusPoll\)\;\}\)/);
  const terminal = app.match(/const SUPPORT_TERMINAL_STATUS_V540=new Set\(\[([^\]]*)\]\)/)[1];
  assert.ok(!terminal.includes("'sent'"),
    "'sent' is NOT terminal — Meta still owes us delivered/read, so polling must continue");
});
