/* nestly_v880 — Grow handlers that re-render to paint their own busy state must not invalidate
   themselves. F039 (1a0fbb71, 2026-09-07) made growPage bump growPageRenderEpoch synchronously on
   entry; every handler that called growRerenderV322() before its first await therefore bumped the
   epoch itself and failed its own isGrowCurrent() check after the RPC. Tier membership's Set up
   wrote the basis and never switched the programme on (ÉLAN Wellness, three attempts 7–9 Sep),
   and its busy flag stayed true until sign-out. The earlier tests in this folder stubbed
   isGrowCurrent, so they could not see this: these run the handler against the REAL epoch
   arithmetic, with growRerenderV322 doing exactly what growPage does on entry. */
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
const growPageSrc = section('async function growPage(routedSurface,hashParam', '\n/* ---------- Bring-back playbooks (v50 campaign');
const helperLine = growPageSrc.split('\n').find(l => l.trim().startsWith('const growRerenderOwnV880='));
assert.ok(helperLine, 'growRerenderOwnV880 must exist inside growPage');

/* A vm context that reproduces the real epoch mechanics: growRerenderV322 bumps the shared
   counter (as growPage does on entry), isGrowCurrent compares against the handler's own epoch. */
function epochContext(extra) {
  const context = {
    growPageRenderEpoch: 0, rerenders: 0, rpcCalls: [],
    S: { biz: { id: 'biz-1' } },
    ownerErrorText: e => e?.message || 'error',
    toast: () => {},
    crypto: { randomUUID: () => 'key-1' },
    console,
    ...extra,
  };
  context.growRerenderV322 = () => { context.rerenders += 1; context.growPageRenderEpoch += 1; };
  vm.createContext(context);
  vm.runInContext(`
    let myGrowRenderEpochV039=++growPageRenderEpoch;
    const isGrowCurrent=()=>growPageRenderEpoch===myGrowRenderEpochV039;
    ${helperLine}
  `, context);
  return context;
}

test('v880 Tier membership Set up runs BOTH writes and releases busy under real epoch arithmetic', async () => {
  const src = section("const growTiersSetupCta=$('growTiersSetupV331');", "\n  outerMain.querySelectorAll('[data-grow-tiers-manage-tab-v331]')");
  const context = epochContext({
    growTiersBusyV331: false, growTiersErrorV331: '', growTiersAddOpenV331: '', growTiersAddDraftV331: null,
    snapshot: { loyalty: { tier_basis: 'spend' } },
    programmeExclusionsV322: () => ['stamps'],
    sb: { rpc: async (name, args) => { context.rpcCalls.push({ name, args }); return { error: null }; } },
    writeProgrammeSwitchesV314: async (biz, set) => { context.rpcCalls.push({ name: 'set_programmes_v314', args: set }); return { ok: true }; },
  });
  const cta = { onclick: null };
  context.$ = () => cta;
  vm.runInContext(src, context);
  assert.equal(typeof cta.onclick, 'function');
  await cta.onclick();
  assert.deepEqual(context.rpcCalls.map(c => c.name), ['business_set_tier_basis_v347', 'set_programmes_v314'],
    'the programme switch must run after the basis write — this is the write that never ran in production');
  assert.deepEqual(JSON.parse(JSON.stringify(context.rpcCalls[1].args)), { tiers: true, stamps: false });
  assert.equal(context.growTiersBusyV331, false, 'busy flag released');
  assert.equal(context.growTiersAddOpenV331, 'form', 'the add-tier form opens after setup');
  assert.equal(context.growTiersErrorV331, '');
  assert.ok(context.rerenders >= 2, 'busy render + final render');
});

test('v880 Tier membership Set up still bails (and releases busy) when SOMEONE ELSE re-rendered Grow mid-flight', async () => {
  const src = section("const growTiersSetupCta=$('growTiersSetupV331');", "\n  outerMain.querySelectorAll('[data-grow-tiers-manage-tab-v331]')");
  const context = epochContext({
    growTiersBusyV331: false, growTiersErrorV331: '', growTiersAddOpenV331: '', growTiersAddDraftV331: null,
    snapshot: { loyalty: {} }, programmeExclusionsV322: () => [],
    sb: { rpc: async (name) => { context.rpcCalls.push({ name }); context.growPageRenderEpoch += 1; /* a route change */ return { error: null }; } },
    writeProgrammeSwitchesV314: async () => { context.rpcCalls.push({ name: 'set_programmes_v314' }); return { ok: true }; },
  });
  const cta = { onclick: null };
  context.$ = () => cta;
  vm.runInContext(src, context);
  await cta.onclick();
  assert.deepEqual(context.rpcCalls.map(c => c.name), ['business_set_tier_basis_v347'], 'a stale handler must not keep writing');
  assert.equal(context.growTiersBusyV331, false, 'busy flag must be released on the navigated-away path (F034 class)');
});

test('v880 Points/Stamp Set up completes its post-write work under real epoch arithmetic', async () => {
  const src = section("const growPointsSetupCta=$('growPointsSetupV326');", "\n  outerMain.querySelectorAll('[data-grow-points-manage-tab-v326]')");
  const context = epochContext({
    growPointsBusyV326: false, growPointsErrorV326: '', growPointsAddOpenV326: '', growPointsAddDraftV326: null,
    growPointsSpineKindV326: 'points', growPointsIsStampsV326: false,
    snapshot: { loyalty: { loyalty_model: 'stamps' } }, programmeExclusionsV322: () => ['stamps'],
    writeProgrammeSwitchesWithStampConversionV384: async () => ({ ok: true, data: {} }),
  });
  const cta = { onclick: null };
  context.$ = () => cta;
  vm.runInContext(src, context);
  await cta.onclick();
  assert.equal(context.growPointsBusyV326, false);
  assert.equal(context.growPointsAddOpenV326, 'form', 'the add-reward form opens — the step F039 silently skipped');
  assert.equal(context.snapshot.loyalty.loyalty_model, 'classic', 'local echo of the model applied');
});

/* Divergence scanner: nobody re-introduces the self-invalidating shape, and no busy flag is
   released only AFTER the currency check (the F034/F037 class). */
test('v880 scanner: every busy-flag pre-await re-render inside growPage adopts its own epoch', () => {
  const lines = growPageSrc.split('\n');
  const offenders = lines.filter(l => /Busy[A-Za-z0-9]*=true;/.test(l) && /growRerenderV322\(/.test(l));
  assert.deepEqual(offenders, [], 'use growRerenderOwnV880 for the busy render, never growRerenderV322');
});

test('v880 scanner: no isGrowCurrent() bail is immediately followed by the busy release it skips', () => {
  const lines = growPageSrc.split('\n');
  const offenders = [];
  lines.forEach((l, i) => {
    if (/if\(!isGrowCurrent\(\)\)return( null)?;/.test(l.trim()) && /^\s*grow[A-Za-z0-9]*Busy[A-Za-z0-9]*=false;/.test(lines[i + 1] || ''))
      offenders.push(`${l.trim()} -> ${lines[i + 1].trim()}`);
  });
  assert.deepEqual(offenders, [], 'release the busy flag BEFORE the route-currency check');
});
