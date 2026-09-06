/* W4B2 audit wave (this session's own fixes) — regressions for F034, F037, F038, F039, F086,
   F100, F106, F107. F026/F029/F030/F031/F032 have their own coverage in
   tests/business-ui/w4b2-audit-wave.test.mjs (a parallel pass on the same audit list); F098's
   fix (the studioPage() draftVersionId-collision bounce) is covered there too.

   Each test extracts the real source between two literal marker strings found in app/app.js and
   executes it in a vm sandbox against stub globals, so a regression in behaviour — not just in
   wording — fails the test. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const appJs = await readFile(path.join(root, 'app/app.js'), 'utf8');
const section = (from, to) => {
  const a = appJs.indexOf(from); assert.ok(a > -1, `missing: ${from}`);
  const b = appJs.indexOf(to, a); assert.ok(b > a, `missing: ${to} after ${from}`);
  return appJs.slice(a, b);
};

/* ================================================================== F034 */
/* Bring-back Save must clear growBbBusyV361 BEFORE the isGrowCurrent() early return, so
   navigating away while the RPC is in flight never leaves Save/Turn on/Delete permanently dead. */

test('F034 growBbSave clears the busy flag even when the owner has navigated away', async () => {
  const src = section(
    'growBbSave.onclick=async()=>{',
    "\n  outerMain.querySelectorAll('[data-grow-bb-toggle-v361]')"
  );
  const fn = src.slice('growBbSave.onclick='.length).replace(/;\s*$/, ''); // "async()=>{ ... }"
  const rpcCalls = [];
  const context = {
    growBbBusyV361: false, growBbErrorV361: '', growBbEditingV361: 'camp-1', growBbAddOpenV361: true,
    S: { biz: { id: 'biz-1' } },
    sb: { rpc: async (name, args) => { rpcCalls.push({ name, args }); return { error: { message: 'boom' } }; } },
    ownerErrorText: e => e?.message || 'error',
    toast: () => {},
    growRerenderV322: () => { context.rerendered = (context.rerendered || 0) + 1; },
    growPage: async () => {}, fail: () => {},
    routedSurface: 'bringback', hashParam: null, routedFocus: null,
    isGrowCurrent: () => false, // simulates: owner navigated away before the RPC resolved
    $: id => ({ value: id === 'growBbNameV361' ? 'Come back' : id === 'growBbRewardV361' ? 'Free coffee' : id === 'growBbAwayV361' ? '30' : '' }),
  };
  const handler = vm.runInNewContext(`(${fn})`, context);
  await handler();
  assert.equal(rpcCalls.length, 1, 'the write RPC still fires');
  assert.equal(context.growBbBusyV361, false, 'busy flag must be released even though the page navigated away');
});

/* ================================================================== F037 */
/* Same defect class on the Stamp Card length stepper: growPointsBusyV326 must be released before
   the isGrowCurrent() bail so every control on the editor is not permanently disabled. */

test('F037 growStampsSetLengthV422 clears the busy flag even when the owner has navigated away', async () => {
  const src = section(
    'const growStampsSetLengthV422=async next=>{',
    "\n  outerMain.querySelectorAll('[data-grow-stamps-len-v416]')"
  );
  const fn = src.slice('const growStampsSetLengthV422='.length).replace(/;\s*$/, ''); // "async next=>{ ... }"
  const rpcCalls = [];
  const context = {
    growPointsBusyV326: false, growPointsErrorV326: '',
    S: { biz: { id: 'biz-1' } },
    sb: { rpc: async (name, args) => { rpcCalls.push({ name, args }); return { data: {}, error: { message: 'boom' } }; } },
    ownerErrorText: e => e?.message || 'error',
    growRerenderV322: () => {},
    snapshot: { loyalty: {} },
    growStampPublishToastV433: () => {}, workspaceTemplateTextV97: () => '',
    isGrowCurrent: () => false,
  };
  const stepper = vm.runInNewContext(`(${fn})`, context);
  await stepper(12);
  assert.equal(rpcCalls.length, 1, 'the length RPC still fires');
  assert.equal(context.growPointsBusyV326, false, 'busy flag must be released even though the page navigated away');
});

/* ================================================================== F038 */
/* UPDATED BY nestly_v693. This pin used to require the opposite sentence: while the server flipped
   loyalty_rewards.active on the LIVE row, "you keep it mid-card" was a lie and the only honest
   copy was "it stops paying out for everyone right away". nestly_v693 made the server tell the
   truth instead — business_delete_reward_v326 now withdraws a stamp gift version-forward (the
   v433 begin/commit path) and every reader asks app.reward_live_on_offer_v693 — so the copy must
   now promise exactly what db/tests/v693_stamp_gift_delete_version_forward.sql proves. If this
   assertion is ever flipped back, that migration has been reverted; check the server first.
   The sibling suite tests/business-ui/w4b2-audit-wave.test.mjs pins the neighbouring F031 delete
   controls and carries no F038 copy assertion, so nothing there needs to move with this. */

test('F038 the delete confirmation promises what the server now does: next card only', () => {
  const src = section('<b>Take this gift off stamp', '</p>');
  assert.doesNotMatch(src, /stops paying out for everyone right away/i,
    'the pre-v693 "immediately for everyone" copy must be gone — it now understates the fix');
  assert.match(src, /keep this gift until they finish/i,
    'the copy must say an open card keeps the gift');
  assert.match(src, /comes off the next card/i,
    'the copy must say the withdrawal lands on the next card');
});

/* ================================================================== F039 */
/* growPage's render epoch: a call whose epoch has been superseded by a newer growPage()
   invocation must report itself as no longer current, independent of which one's async work
   resolves first — this is what stops a slow pre-write quiet rerender from painting stale data
   over a "Saved" toast. */

test('F039 an older growPage epoch loses currency to a newer one sharing the same <main> node', () => {
  const src = section(
    'const myGrowRenderEpochV039=++growPageRenderEpoch;',
    '\n  const modules=S.myModules||[];'
  );
  const sameMainNode = { isConnected: true, contains: () => true };
  const mount = vm.runInNewContext(`(function(){ ${src} return isGrowCurrent; })`, {
    growPageRenderEpoch: 0,
    M: () => sameMainNode, // same <main> node handed out to every call, by design
  });
  const isCurrentA = mount(); // call A starts first (the pre-write quiet render)
  const isCurrentB = mount(); // call B starts after A, e.g. the post-write quiet render
  assert.equal(isCurrentB(), true, 'the newer call is current');
  assert.equal(isCurrentA(), false,
    'the older call must lose currency once a newer growPage() call has started, even though ' +
    'outerMain.isConnected and M()===outerMain both still hold for it');
});

/* ================================================================== F086 */
/* Opening Grow via real navigation must refresh the programme spine cache so a switch made from
   another tab/session is reflected in the on/off confirm text; a quiet in-page rerender must not
   pay for a second fetch. */

test('F086 growPage refreshes the programme spine on a real navigation, not a quiet rerender', async () => {
  const src = section(
    'if(fromRouteV288&&canRewards){\n    await refreshProgrammeSpineV314();\n    if(!isGrowCurrent())return;\n  }',
    '\n  if(!quiet)outerMain.innerHTML=CUI.loadingState'
  );
  const run = async (fromRouteV288, canRewards, isGrowCurrentResult = true) => {
    let refreshed = 0;
    const context = {
      fromRouteV288, canRewards,
      refreshProgrammeSpineV314: async () => { refreshed += 1; },
      isGrowCurrent: () => isGrowCurrentResult,
    };
    await vm.runInNewContext(`(async()=>{ ${src} })()`, context);
    return refreshed;
  };
  assert.equal(await run(true, true), 1, 'a real navigation into Grow (fromRouteV288) must refresh the spine');
  assert.equal(await run(false, true), 0, 'a quiet in-page rerender must not pay for a second fetch');
  assert.equal(await run(true, false), 0, 'no loyalty module access means nothing to refresh');
});

/* ================================================================== F100 */
/* Program Studio's pause/resume/emergency-pause completion handler must not repaint the page if
   the owner has navigated away while the RPC was in flight. */

test('F100 studioOverview only rerenders via studioPage() while still the current page', () => {
  const src = section('const rerender=()=>{if(isCurrent())studioPage()};', '\n  const legacyRows=legacy.map');
  assert.equal(src, 'const rerender=()=>{if(isCurrent())studioPage()};', 'the guarded rerender must be present verbatim');
  const calls = [];
  const runWith = isCurrentResult => {
    const context = { isCurrent: () => isCurrentResult, studioPage: () => { calls.push('painted'); } };
    const rerender = vm.runInNewContext(`(()=>{if(isCurrent())studioPage()})`, context);
    rerender();
  };
  runWith(false);
  assert.equal(calls.length, 0, 'must not repaint studioPage() over whatever page the owner navigated to');
  runWith(true);
  assert.equal(calls.length, 1, 'still repaints normally while the owner stayed on Program Studio');
});

/* ================================================================== F106 */
/* commitLocationsV488 must coalesce a commit requested while one is already in flight into a
   trailing re-run, instead of silently dropping it. */

test('F106 a shelf edit requested during an in-flight commit is not dropped', async () => {
  const body = section(
    'let pendingCommitLocationsV488=false;',
    '\n\n  /* V278 tier windows.'
  );
  let rpcResolvers = [];
  const rpcCallArgs = [];
  const context = {
    committingLocationsV488: false,
    locations: [{ id: 'a', name: 'Shelf A', in_use: false }],
    savedKeepV488: { days: 30, capacity: 500 },
    S: { biz: { id: 'biz-1' } },
    sb: {
      rpc: (name, args) => {
        rpcCallArgs.push(args);
        return new Promise(resolve => { rpcResolvers.push(resolve); });
      },
    },
    isCurrent: () => true,
    $: () => ({}), // 'bkLocList' presence check
    paintLocations: () => {},
    toast: () => { context.toasted = (context.toasted || 0) + 1; },
    ownerErrorText: () => 'error',
  };
  vm.createContext(context);
  vm.runInContext(body, context);
  const first = context.commitLocationsV488(); // in-flight, paused awaiting rpcResolvers[0]
  // A second edit arrives before the first RPC resolves — must be queued, not dropped.
  context.locations.push({ id: null, name: 'Chiller 1', in_use: false });
  const second = context.commitLocationsV488();
  await second; // this call only marks "pending" and returns immediately — never fires its own RPC
  assert.equal(rpcCallArgs.length, 1, 'the second call must not fire a concurrent RPC — it queues');
  // Resolving the in-flight RPC lets the do/while loop notice the queued edit and fire a
  // trailing call — which `first` will not settle until we also resolve. Give it a beat to reach
  // that second `await` before asserting on it.
  rpcResolvers[0]({ data: { locations: [{ id: 'a', name: 'Shelf A', in_use: false }] } });
  await new Promise(r => setImmediate(r));
  assert.equal(rpcCallArgs.length, 2, 'the queued edit must be sent as a trailing call once the first finishes');
  assert.ok(rpcCallArgs[1].p_locations.some(l => l.name === 'Chiller 1'),
    'the trailing call must carry the edit that arrived while the first commit was in flight');
  rpcResolvers[1]({ data: { locations: rpcCallArgs[1].p_locations } });
  await first;
  assert.equal(context.committingLocationsV488, false, 'the in-flight guard must be released once the queue drains');
});

/* ================================================================== F107 */
/* Switching to the Retrieved/Expired tab must clear the "Expiring soon" filter (and disable the
   checkbox) rather than silently zeroing every row on that tab. */

test('F107 paintExpiringFilterV107 disables and clears the filter off the Storage tab', () => {
  const body = section('const paintExpiringFilterV107=()=>{', '\n  paintExpiringFilterV107();');
  assert.match(body, /\n  \};$/, 'the function must close cleanly right before its first call');
  const fn = body.slice('const paintExpiringFilterV107='.length).replace(/;\s*$/, ''); // "()=>{ ... }"
  const run = status => {
    const box = { disabled: false, checked: true, closest: () => ({ style: { setProperty: () => {} } }) };
    const context = { filters: { status, expiring: true }, $: () => box };
    vm.runInNewContext(`(${fn})()`, context);
    return { box, filters: context.filters };
  };
  const onStorage = run('storage');
  assert.equal(onStorage.box.disabled, false, 'the checkbox stays enabled on the Storage tab');
  assert.equal(onStorage.filters.expiring, true, 'an existing Storage-tab filter is left alone');

  const onRetrieved = run('retrieved');
  assert.equal(onRetrieved.box.disabled, true, 'the checkbox is disabled off the Storage tab');
  assert.equal(onRetrieved.box.checked, false, 'a stale checked box is cleared');
  assert.equal(onRetrieved.filters.expiring, false,
    'filters.expiring must be reset so the RPC never sends an impossible status+expiring combination');
});
