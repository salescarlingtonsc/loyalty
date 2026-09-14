/**
 * nestly_v904 — the Help Centre.
 *
 * Two things this pins, because both are ways the feature fails SILENTLY:
 *
 *  1. THE CONTENT CANNOT OUTLIVE THE PRODUCT. Every guide names a route, and the router refuses
 *     several routes outright (gift cards, memberships, stored value, the WhatsApp inbox) while
 *     others have no navigation door at all (Expenses, P&L). A guide pointing at one of those is
 *     not a broken link — it is the app telling a business owner to open something that will bounce
 *     them back with a toast, which is worse than saying nothing. The refusal list is READ OUT OF
 *     app/app.js here rather than copied, so retiring one more module fails this test until the
 *     guide goes with it.
 *
 *  2. THE ACCESS RULES MIRROR THE WORKSPACE'S. helpAccessOkV904 is a second implementation of
 *     gates that already exist in route()/navModuleVisible. A second implementation is a second
 *     thing to get wrong, so the real predicate is executed here against real role/module/sector
 *     fixtures — not grepped.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');
const cui = readFileSync(new URL('../../app/customer-ui.js', import.meta.url), 'utf8');

function section(from, to) {
  const start = app.indexOf(from);
  assert.ok(start >= 0, `anchor not found: ${from}`);
  const end = app.indexOf(to, start + from.length);
  assert.ok(end > start, `anchor not found after ${from}: ${to}`);
  return app.slice(start, end);
}

/* The Help block, executed for real against a stubbed workspace — the same technique the visual
   fixture generators use. Everything it calls is stubbed to the production definition or to the
   smallest honest stand-in. */
const helpBlock = section(
  '/* ============================================================================================\n   nestly_v904 — HELP CENTRE.',
  '/* ---------- platform (super-admin only) ----------',
);
const context = { console };
vm.createContext(context);
vm.runInContext('var window=globalThis;var document={getElementById:()=>null,querySelectorAll:()=>[]};', context);
vm.runInContext(cui, context);
vm.runInContext(`
var CUI=window.FrenlyCustomerUI;
var esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
var workspaceLocale='en';
var S={myRole:'owner',myModules:[],biz:{id:'x',industry:'salon'}};
${section('const FINANCE_MODULES=new Set(', 'const OWNER_ONLY_MODULES=')}
${section('const ROLE_CAPABILITIES={', 'const hasRoleCapability=')}
var roleCanUseModule=(role,m)=>!FINANCE_MODULES.has(m)||ROLE_CAPABILITIES[role]?.has('view_finance')===true;
var canReadModule=m=>S.myModules?.includes(m)===true&&roleCanUseModule(S.myRole,m);
var isBarSectorV275=()=>String(S.biz?.industry||'').toLowerCase()==='bar';
var sectorHidesAppointmentsV276=()=>['fnb','bar'].includes(String(S.biz?.industry||'').toLowerCase());
var routeParamV288=()=>'';var exploreQueryShapeV256=()=>'t1:short:matched';
var recordProductInteractionV100=()=>{};var nav=()=>{};var $=()=>null;
var M=()=>({innerHTML:'',querySelectorAll:()=>[]});
var matchMedia=()=>({matches:true,addEventListener(){}});
`, context);
vm.runInContext(helpBlock, context);

const TOPICS = vm.runInContext('HELP_TOPICS_V904', context);
const CONTEXT_MAP = vm.runInContext('HELP_CONTEXT_V904', context);
const GLOSSARY = vm.runInContext('HELP_GLOSSARY_V904', context);
const VIEWS = vm.runInContext('Object.keys(HELP_VIEWS_V904)', context);
const slugs = new Set(TOPICS.map((topic) => topic.slug));

function as(role, modules, industry = 'salon') {
  context.S.myRole = role;
  context.S.myModules = modules;
  context.S.biz.industry = industry;
}
const visibleSlugs = () => vm.runInContext('helpVisibleTopicsV904().map(t=>t.slug)', context);
/* The real ALLMODS, so "an owner with everything" means what production means by it. A const
   declaration evaluates to undefined, so it is declared and then read back. */
vm.runInContext(section('const ALLMODS=[', '\n'), context);
const ALL_MODULES = vm.runInContext('ALLMODS', context);
assert.ok(Array.isArray(ALL_MODULES) && ALL_MODULES.includes('till'), 'ALLMODS did not load');

test('v904 the Help route is wired, and is the one surface no module gate can refuse', () => {
  const dispatch = section('const P={dashboard,till:tillPage', "'customer-interface':customerInterfacePageV243}");
  assert.match(dispatch, /\bhelp:helpPage\b/, 'the router must dispatch #/help');

  /* No MODULES entry is the mechanism, not an oversight: route()'s generic gate refuses any
     MODULES key the account cannot read, and documentation must open for everyone. */
  const modules = section('const MODULES={dashboard:', 'const ROLE_LABELS=');
  assert.doesNotMatch(modules, /(^|[{,\s])'?help'?\s*:/, "'help' must not be a MODULES key");

  /* And nothing in the guard chain names it. */
  const guard = section("const growModuleKeys=['loyalty'", 'if(!isRouteCurrent())return;\n    await loadWorkspaceLocaleV97');
  assert.doesNotMatch(guard, /pageKey==='help'/, 'no route guard may refuse the Help Centre');
});

test('v904 Help has a door in the rail, the app bar and the account menu, for every role', () => {
  const nav = section('function navHtml(page,idPrefix=', 'function wireNav()');
  assert.match(nav, /href="#\/help" class="nav-help-v904/, 'the rail carries a Help row');
  /* Appended AFTER the NAVGROUPS map, so it is not filtered by navModuleVisible — Help is not a
     module and has no entitlement to gate it on. */
  assert.ok(nav.indexOf('.join(\'\')') < nav.indexOf('nav-help-v904'),
    'the Help row is appended outside the module-gated groups');

  const header = section('<header class="appbar">', '<main class="main" id="main"');
  assert.match(header, /\$\{helpTriggerHtmlV904\(page\)\}/, 'the app bar carries the contextual Help control');

  const profile = section('function profileHtml()', '/* ---------- V452: ONE dismiss discipline');
  assert.match(profile, /id="pmHelpV904"/, 'the account menu carries Help Centre');
  /* Unconditional: every row around it is wrapped in an S.myRole check, and this one must not be. */
  assert.doesNotMatch(profile, /S\.myRole==='owner'\?`<a href="#\/help"/, 'Help is not owner-only');
});

test('v904 no guide sends a reader at a route the workspace refuses or hides', () => {
  /* Read the refusals out of production rather than copying them here. */
  const retired = [...section('const RETIRED_BUSINESS_MODULES_V768=new Set([', ']);')
    .matchAll(/'([a-z]+)'/g)].map((m) => m[1]);
  const unverified = [...section('const UNVERIFIED_MODULES_V466=[', '];')
    .matchAll(/'([a-z]+)'/g)].map((m) => m[1]);
  assert.ok(retired.includes('giftcards') && retired.includes('support'));
  assert.ok(unverified.includes('memberships'));

  /* Plus the two the router refuses by name, and the two nestly_v518 took out of the rail — a
     route with no navigation door cannot be given step-by-step instructions. */
  const unreachable = new Set([...retired, ...unverified, 'storedvalue', 'expenses', 'pnl',
    /* HIDE_WHATSAPP_API_SURFACES_V824 leaves this page with no content to describe. */
    'remindernotify']);
  assert.match(app, /const HIDE_WHATSAPP_API_SURFACES_V824=true/,
    'if the WhatsApp surfaces are un-hidden, Reminder & Notification becomes documentable');

  for (const topic of TOPICS) {
    const key = String(topic.route || '').replace('#/', '').split('/')[0];
    assert.ok(!unreachable.has(key),
      `the "${topic.title}" guide points at #/${key}, which the workspace refuses or does not offer`);
  }
});

test('v904 every cross-reference resolves', () => {
  for (const topic of TOPICS) {
    for (const related of topic.related || []) {
      assert.ok(slugs.has(related), `${topic.slug}: related "${related}" is not a guide`);
    }
    const taskSlugs = new Set();
    for (const task of topic.tasks || []) {
      assert.ok(!taskSlugs.has(task.slug), `${topic.slug}: duplicate task "${task.slug}"`);
      taskSlugs.add(task.slug);
      assert.ok((task.steps || []).length, `${topic.slug}/${task.slug} has no steps`);
      assert.ok((task.keywords || []).length, `${topic.slug}/${task.slug} has no keywords`);
    }
    for (const problem of topic.problems || []) {
      assert.ok(problem.q && (problem.causes || []).length && (problem.fix || []).length,
        `${topic.slug}: "${problem.q}" must state both the reasons and what to do`);
    }
  }
  for (const [route, slug] of Object.entries(CONTEXT_MAP)) {
    assert.ok(slugs.has(slug), `contextual map ${route} -> "${slug}" is not a guide`);
  }
  /* The four computed pages are reserved first segments of #/help/<x>. */
  for (const view of VIEWS) assert.ok(!slugs.has(view), `guide slug "${view}" collides with a view`);
  assert.equal(new Set(GLOSSARY.map(([term]) => term)).size, GLOSSARY.length, 'duplicate glossary term');
});

test('v904 a guide is never offered to an account that cannot act on it', () => {
  as('owner', ALL_MODULES);
  const owner = visibleSlugs();
  assert.ok(owner.includes('branches') && owner.includes('staff') && owner.includes('subscription'));

  /* Front desk: no owner-only screens, and no finance screens — the same two boundaries route()
     enforces with its owner guards and FINANCE_MODULES. */
  as('frontdesk', ALL_MODULES);
  const frontdesk = visibleSlugs();
  for (const ownerOnly of ['branches', 'staff', 'subscription', 'customer-app']) {
    assert.ok(!frontdesk.includes(ownerOnly), `front desk must not be shown the ${ownerOnly} guide`);
  }
  /* FINANCE_MODULES, and only those. Business Insights and Daily report are deliberately NOT in
     that set: get_reports_summary and get_dashboard_summary require 'view_sales', which every
     role holds — so a front-desk account with those modules really can open them, and the guides
     say so. (An earlier draft of this content claimed both were finance-gated; this assertion is
     what caught it.) */
  for (const finance of ['commission', 'intelligence']) {
    assert.ok(!frontdesk.includes(finance), `front desk has no finance access: ${finance}`);
  }
  assert.ok(frontdesk.includes('record-sale') && frontdesk.includes('customers'));

  /* A bookkeeper may read the money, and may not ring a sale — but Record sale still exists for
     them to read about, exactly as the rail still offers it. The guide tracks canReadModule, which
     is the same answer the rail gives. */
  as('bookkeeper', ALL_MODULES);
  assert.ok(visibleSlugs().includes('commission'), 'a bookkeeper has finance access');

  /* Waitlist needs BOTH keys, the same pair the rail requires. */
  as('manager', ['waitlist']);
  assert.ok(!visibleSlugs().includes('waitlist'), 'Waitlist without Bookings is not offered');
  as('manager', ['waitlist', 'bookings']);
  assert.ok(visibleSlugs().includes('waitlist'));

  /* Sector rules: bottles is bar-only, Appointments is hidden where the sector seats parties. */
  as('owner', [...ALL_MODULES, 'bottles'], 'salon');
  assert.ok(!visibleSlugs().includes('bottles'), 'bottle keep is exclusive to the bar sector');
  as('owner', [...ALL_MODULES, 'bottles'], 'bar');
  assert.ok(visibleSlugs().includes('bottles'));
  assert.ok(!visibleSlugs().includes('appointments'), 'a bar takes bookings, not appointments');
  as('owner', ALL_MODULES, 'fnb');
  assert.ok(!visibleSlugs().includes('appointments'), 'a cafe takes bookings, not appointments');

  /* A task may narrow its parent, never widen it: setting up the Point system is owner-only
     inside a guide every role with loyalty may read. */
  as('staff', ALL_MODULES);
  const staffRewardTasks = vm.runInContext(
    "helpTopicTasksV904(helpTopicV904('rewards')).map(t=>t.slug)", context);
  assert.ok(!staffRewardTasks.includes('set-up-points'), 'only the owner sets up a programme');
  assert.ok(staffRewardTasks.includes('check-programme-results'), 'but the results are readable');
});

test('v904 search answers the words a business owner actually types', () => {
  as('owner', ALL_MODULES);
  const top = (query) => vm.runInContext(
    `helpSearchV904(${JSON.stringify(query)}).slice(0,6).map(r=>r.href)`, context);

  assert.ok(top('add a customer').includes('#/help/customers/add-customer'));
  assert.ok(top('new customer').includes('#/help/customers/add-customer'));
  assert.ok(top('create a reward').some((href) => href.startsWith('#/help/rewards')));
  assert.ok(top('points').some((href) => href.startsWith('#/help/rewards')));
  assert.ok(top('scan qr').includes('#/help/record-sale/scan-redemption'));
  assert.ok(top('add branch').includes('#/help/branches/add-branch'));
  assert.ok(top('payment').some((href) => href.startsWith('#/help/subscription')
    || href.startsWith('#/help/record-sale')));
  assert.ok(top('staff access').some((href) => href.startsWith('#/help/staff')
    || href.startsWith('#/help/roles')));
  assert.ok(top('customer cannot login').length > 0, 'natural phrasing still finds something');

  /* Every word must match (AND), or a two-word query returns the whole corpus. */
  assert.equal(vm.runInContext("helpSearchV904('qqqq zzzz').length", context), 0);
  /* And a search can never surface a guide the reader is refused. */
  as('frontdesk', ALL_MODULES);
  assert.ok(!top('add branch').some((href) => href.startsWith('#/help/branches')),
    'front desk must not find the Branches guide');
});

test('v904 an unknown or refused guide is answered, never 404ed', () => {
  const page = section('function helpPage(topicSlug,taskSlug){', 'function helpWireV904(');
  assert.match(page, /if\(requested&&!view&&\(!topic\|\|!helpAccessOkV904\(topic\)\)\)/);
  assert.match(page, /helpHomeHtmlV904\(fallbackQuery\)/,
    'it lands on the home page with what was asked for pre-filled into search');
  /* A task slug that no longer resolves falls back to its guide, which still holds those steps. */
  assert.match(page, /built=task\?helpTaskHtmlV904\(topic,task\):helpTopicHtmlV904\(topic\)/);
});

test('v904 Help analytics records what was searched, never what was typed', () => {
  const record = section('function helpRecordV904(surfaceKey,outcome,queryShape){', '\n}');
  assert.match(record, /'merchant\.surface_viewed'/,
    'it rides the existing taxonomy — a new event name would need a migration');
  assert.match(record, /surface_key:String\(surfaceKey\|\|'help'\)\.slice\(0,80\)/);
  assert.doesNotMatch(record, /query:|search_text|query_text|input\.value/);

  const wiring = section('function helpWireV904(currentQuery){', '\n}');
  assert.match(wiring, /exploreQueryShapeV256\(query,matched\)/,
    'the search term reaches analytics as a shape, never as text');
  assert.doesNotMatch(wiring, /helpRecordV904\([^)]*,\s*query\s*[,)]/);
});
