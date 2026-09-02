/* V682 — audit findings F077, F078, F083, F085: an async write handler re-renders a page after
   an await with no route-currency guard, so a late RPC response paints the OLD page over
   whatever the user has since navigated to. These tests EXTRACT the real handlers from
   app/app.js verbatim and EXECUTE them against a fixture where the "current page" flips false
   mid-flight, asserting the late response is a no-op — and that when the page is still current,
   the re-render still happens. Matches the harness shape of tests/business-ui/v551-*.test.mjs. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

function slice(startMarker, endMarker, { fromIndex = 0 } = {}) {
  const start = app.indexOf(startMarker, fromIndex);
  assert.ok(start > -1, `start marker not found: ${startMarker}`);
  const end = app.indexOf(endMarker, start);
  assert.ok(end > start, `end marker not found after start: ${endMarker}`);
  return { text: app.slice(start, end), end };
}

/* ---------------------------------------------------------------- F077: adjGo (adjust points) */

const adjBlock = slice("const aj=$('adjGo');", "const copyRefButton=$('copyRef');").text;

function runAdj({ rpcResult, currentAtResolve }) {
  const calls = { toast: [], clientDetail: [] };
  const sandbox = {
    $: (id) => (id === 'adjGo' ? sandbox.__aj : { value: id === 'adjV' ? '50' : '' }),
    S: { biz: { id: 'biz-1' } },
    id: 'client-1',
    adjustmentIdem: 'idem-1',
    crypto: { randomUUID: () => 'idem-2' },
    sb: { rpc: async (fn, args) => { sandbox.__isCurrentAtResolve = currentAtResolve; return rpcResult; } },
    isClientDetailCurrent: () => sandbox.__isCurrentAtResolve,
    toast: (msg) => calls.toast.push(msg),
    fail: (err) => calls.toast.push(`fail:${err && err.message}`),
    workspaceTemplateTextV97: (key, vars) => `${key}:${vars.balance}`,
    clientDetail: (cid) => calls.clientDetail.push(cid)
  };
  sandbox.__aj = { disabled: false, isConnected: true, onclick: null };
  sandbox.__isCurrentAtResolve = true;
  const context = vm.createContext(sandbox);
  context.__exports = {};
  vm.runInContext(adjBlock + '\n__exports.trigger = () => aj.onclick();', context);
  return { trigger: context.__exports.trigger, aj: sandbox.__aj, calls };
}

test('F077: a late adjust_points_v480 response does not repaint a page the owner has left', async () => {
  const h = runAdj({ rpcResult: { data: { balance: 150 }, error: null }, currentAtResolve: false });
  await h.trigger();
  assert.deepEqual(h.calls.clientDetail, [], 'clientDetail(id) must not be called once the page is stale');
  assert.deepEqual(h.calls.toast, [], 'no toast for a write the user can no longer see');
});

test('F077: a same-page adjust_points_v480 response still re-renders as before', async () => {
  const h = runAdj({ rpcResult: { data: { balance: 150 }, error: null }, currentAtResolve: true });
  await h.trigger();
  assert.deepEqual(h.calls.clientDetail, ['client-1']);
  assert.equal(h.calls.toast[0], 'adjustedBalance:150');
});

/* -------------------------------------------------------------- F078: cfvSave / cfvClear */

const cfvBlock = slice(
  "document.querySelectorAll('.cfvSave').forEach(b=>b.onclick=async()=>{",
  "const birthdayRedeem=$('birthdayRedeem');"
).text;

function runCfv({ handler, rpcError, currentAtResolve }) {
  const calls = { toast: [], fail: [], clientDetail: [] };
  const button = { dataset: { id: 'field-1', type: 'text' }, onclick: null };
  const buttons = { cfvSave: [], cfvClear: [] };
  const sandbox = {
    $: (id) => (id === 'cfv-field-1' ? { value: 'hello' } : null),
    S: { biz: { id: 'biz-1' } },
    id: 'client-1',
    document: {
      querySelectorAll: (sel) => (sel === '.cfvSave' ? buttons.cfvSave : buttons.cfvClear)
    },
    __isCurrentAtResolve: true,
    isClientDetailCurrent: () => sandbox.__isCurrentAtResolve,
    toast: (msg) => calls.toast.push(msg),
    fail: (err) => calls.fail.push(err && err.message),
    clientDetail: (cid) => calls.clientDetail.push(cid),
    sb: {
      from: () => ({
        upsert: async () => { sandbox.__isCurrentAtResolve = currentAtResolve; return { error: rpcError }; },
        delete: () => ({
          eq: () => ({
            eq: () => ({
              eq: async () => { sandbox.__isCurrentAtResolve = currentAtResolve; return { error: rpcError }; }
            })
          })
        })
      })
    }
  };
  buttons[handler].push(button);
  const context = vm.createContext(sandbox);
  vm.runInContext(cfvBlock, context);
  return { trigger: () => button.onclick(), calls };
}

test('F078: a late custom-field Save response does not repaint a page the owner has left', async () => {
  const h = runCfv({ handler: 'cfvSave', rpcError: null, currentAtResolve: false });
  await h.trigger();
  assert.deepEqual(h.calls.clientDetail, []);
  assert.deepEqual(h.calls.toast, []);
});

test('F078: a same-page custom-field Save response still re-renders as before', async () => {
  const h = runCfv({ handler: 'cfvSave', rpcError: null, currentAtResolve: true });
  await h.trigger();
  assert.deepEqual(h.calls.clientDetail, ['client-1']);
  assert.equal(h.calls.toast[0], 'Customer detail saved');
});

test('F078: a late custom-field Clear response does not repaint a page the owner has left', async () => {
  const h = runCfv({ handler: 'cfvClear', rpcError: null, currentAtResolve: false });
  await h.trigger();
  assert.deepEqual(h.calls.clientDetail, []);
  assert.deepEqual(h.calls.toast, []);
});

test('F078: a same-page custom-field Clear response still re-renders as before', async () => {
  const h = runCfv({ handler: 'cfvClear', rpcError: null, currentAtResolve: true });
  await h.trigger();
  assert.deepEqual(h.calls.clientDetail, ['client-1']);
  assert.equal(h.calls.toast[0], 'Customer detail cleared');
});

/* ---------------------------------------------------- F083 / F085: Packages refreshPackagesV584 */

const pkgFnStart = app.indexOf('async function packagesPage(options){');
assert.ok(pkgFnStart > -1, 'packagesPage not found');
const pkgBlock = slice(
  'const routeMain=M(),isCurrent=()=>routeMain.isConnected&&M()===routeMain;',
  'const canWrite=canWriteModule(\'packages\');',
  { fromIndex: pkgFnStart }
).text;
assert.ok(pkgBlock.includes('refreshPackagesV584'), 'sanity: refreshPackagesV584 definition captured');

function runRefreshPackages({ mainConnected }) {
  const calls = { packagesPage: [] };
  const mainNode = { isConnected: true, innerHTML: '' };
  const sandbox = {
    M: () => (mainConnected ? mainNode : { isConnected: false }),
    packagesPage: (opts) => calls.packagesPage.push(opts),
    packagesViewV584: 'plans'
  };
  const context = vm.createContext(sandbox);
  context.__exports = {};
  vm.runInContext(pkgBlock + '\n__exports.refresh = refreshPackagesV584;', context);
  return { refresh: context.__exports.refresh, calls };
}

test('F083/F085: refreshPackagesV584 does not re-render once the Packages page is no longer current', () => {
  const h = runRefreshPackages({ mainConnected: false });
  h.refresh();
  assert.deepEqual(h.calls.packagesPage, [], 'a write refresh must no-op once #main has been replaced by navigation');
});

test('F083/F085: refreshPackagesV584 still re-renders while the Packages page is current', () => {
  const h = runRefreshPackages({ mainConnected: true });
  h.refresh();
  assert.equal(h.calls.packagesPage.length, 1);
  assert.equal(h.calls.packagesPage[0].view, 'plans');
});

test('F083/F085: every write handler that mutates a package refreshes through the guarded refreshPackagesV584, not a raw packagesPage() re-invoke', () => {
  const pkgFnEnd = app.indexOf('\nfunction ', pkgFnStart + 1);
  const body = app.slice(pkgFnStart, pkgFnEnd > -1 ? pkgFnEnd : pkgFnStart + 40000);
  const rawReinvokes = (body.match(/[^V]packagesPage\(\{view:packagesViewV584\}\);/g) || []);
  assert.equal(rawReinvokes.length, 0, 'no call site should re-invoke packagesPage() directly, bypassing the isCurrent() guard');
  const refreshCalls = (body.match(/refreshPackagesV584\(\);/g) || []).length;
  assert.ok(refreshCalls >= 6, `expected multiple write handlers to call the guarded refreshPackagesV584 (found ${refreshCalls})`);
});
