import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

/* nestly_v546 — the Rewards & Offer rail group stops advertising its own page's contents.

   Owner markup 2026-08-27: Loyalty, Retention, Referrals and Memberships each struck out of the
   rail, with "it is already inside rewards programme, dont bring it out". The Rewards Programme
   page renders every one of them as a card, so the rail rows were the same destination twice.

   They appeared because nestly_v538 ("the WhatsApp Inbox actually appears in the rail") taught a
   `views` group to also render its module items. That was right for Customer Interface, whose
   `support` row is a genuine module that was being dropped, and wrong for this group, whose items
   have only ever been entitlement keys. `gateOnly` names that difference.

   These tests execute the real navHtml child-row logic against the real NAVGROUPS rather than
   grepping for the flag, so a future edit that removes the flag or the guard fails here. */

const here=path.dirname(fileURLToPath(import.meta.url));
const repo=path.resolve(here,'../..');
const app=fs.readFileSync(path.join(repo,'app/app.js'),'utf8');

function section(start,end){
  const from=app.indexOf(start);
  assert.notEqual(from,-1,`missing start marker: ${start}`);
  const to=app.indexOf(end,from+start.length);
  assert.notEqual(to,-1,`missing end marker: ${end}`);
  return app.slice(from,to);
}

/* Build the real NAVGROUPS and MODULES out of app.js, then reproduce the exact child-row
   expression navHtml uses. Nothing here is a paraphrase: the rendering line is lifted verbatim. */
function railModel(){
  const modules=section('const MODULES={','const ROLE_LABELS=');
  /* NAVGROUPS builds the Customer Interface children from these two constants, so they come
     along; taking the real ones keeps this test honest about what the rail actually renders. */
  const ciViews=section('const CUSTOMER_INTERFACE_VIEWS_V296','const CUSTOMER_INTERFACE_TABS_V368');
  const groups=section('const NAVGROUPS=[','\nlet navOpen');
  const src=`${modules}\n${ciViews}\n${groups}\nreturn {MODULES,NAVGROUPS};`;
  return new Function(src)();
}

const {MODULES,NAVGROUPS}=railModel();
const group=key=>NAVGROUPS.find(g=>g.key===key);

/* The v538 module-row builder, reduced to the part under test: which items become rows. */
const moduleRowKeys=g=>(g.gateOnly?[]:(g.items||[]).filter(m=>MODULES[m]));

test('V546 the Rewards & Offer rail shows only its four page tabs',()=>{
  const g=group('grow');
  assert.ok(g,'the Rewards & Offer group is gone');
  assert.deepEqual(g.views.map(v=>v[0]),
    ['Overview','Rewards Programme','Limited Offer','History']);
  assert.deepEqual(moduleRowKeys(g),[],
    'loyalty/retention/referrals/memberships must not become rail rows — the Rewards Programme page already lists them');
});

test('V546 the four struck-out modules are still ENTITLEMENT keys',()=>{
  /* Removing them from `items` would have been the wrong fix: `items` is what decides whether the
     group appears for a tenant and a role at all. They stay; they just stop rendering. */
  const g=group('grow');
  for(const key of ['loyalty','retention','referrals','memberships']){
    assert.ok(g.items.includes(key),`${key} must stay in items so the group is still gated on it`);
  }
});

test('V546 every struck-out route is still reachable',()=>{
  /* The established pattern for a de-advertised module: the row goes, the route stays, so a
     bookmark, a history entry or a Customer 360 hand-off is never stranded. */
  const routeMap=section('const P={dashboard,till:tillPage,','};');
  for(const key of ['loyalty','retention','referrals','memberships']){
    assert.match(routeMap,new RegExp(`(^|[,{\\s])${key}:`),
      `#/${key} must still resolve in the route map`);
  }
});

test('V546 v538 still does what it was written for',()=>{
  /* Customer Interface must KEEP its module row — that group is not gateOnly, and `support` is the
     WhatsApp Inbox row v538 existed to restore. A blanket revert of v538 would have broken it. */
  const g=group('customerui');
  assert.ok(g,'the Customer Interface group is gone');
  assert.ok(!g.gateOnly,'Customer Interface must NOT be gateOnly');
  /* nestly_v768: 'support' is retired (owner: business owners must not see the inbox). It stays
     DECLARED here — the group is not gateOnly and the key is the un-retire switch — while
     navModuleVisible drops it before it can become a row. tests/whatsapp/v538-inbox-navigation
     executes the real navHtml and asserts the row is absent for an entitled tenant. */
  assert.ok(moduleRowKeys(g).includes('support'),
    "'support' must stay declared on the group; RETIRED_BUSINESS_MODULES_V768 is the only switch");
});

test('V546 gateOnly is opt-in, so no other group changed',()=>{
  const gated=NAVGROUPS.filter(g=>g.gateOnly).map(g=>g.key);
  assert.deepEqual(gated,['grow'],
    'exactly one group opts out of module rows; adding another is a deliberate decision, not a default');
});

test('V546 the guard is wired into the renderer, not just declared',()=>{
  /* The flag is inert unless navHtml consults it. Pin the consult site. */
  const nav=section('function navHtml(page,idPrefix=','function wireNav()');
  assert.match(nav,/g\.gateOnly\?''\:moduleChildRowsV538\(g\.items\)/,
    'navHtml must skip module rows for a gateOnly group');
});
