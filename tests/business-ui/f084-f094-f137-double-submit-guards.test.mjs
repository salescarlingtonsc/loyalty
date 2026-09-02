/* Audit F084, F094, F137 — three Save/Create buttons on the business app had no double-submit
   guard: nothing disabled the button (or ignored re-entry) between the click and the write's
   `await` resolving, and none of the three server writers is idempotent on its own —
   `products.insert`, `create_invite` and `save_reward_taxonomy` (with `p_taxonomy_id:null`) all
   unconditionally create a brand-new row on every call. A double click (or a slow network plus
   an impatient second click — the app's own low-literacy-first, touch-first target audience per
   CLAUDE.md) fired the handler twice and created two rows: two identical products (F084), two
   live invite codes for the same role (F094), or two reward-type rows with the identical label
   and two different ids (F137).

   The fix reuses the CUI.setButtonBusy(button,{busy,label}) idiom already used by every sibling
   Save/Create control on these same pages (e.g. the Packages Add form, staff_create_client,
   waitlist edit save) plus an explicit `if(button.disabled)return;` guard at the top of the
   handler, matching the idiom already used elsewhere in app.js (e.g. the wallet withdraw-request
   button, line ~8445).

   This suite EXECUTES the real handlers out of app/app.js in a vm sandbox with stubbed globals —
   a real CUI.setButtonBusy implementation (so `button.disabled` actually flips), and a
   controllable sb.from/sb.rpc so the test can fire the handler twice back-to-back BEFORE the
   first write settles, exactly reproducing a double click, and assert only one write happened. */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

function section(source, from, to) {
  const start = source.indexOf(from);
  assert.ok(start > -1, `missing: ${from}`);
  const end = source.indexOf(to, start);
  assert.ok(end > start, `missing: ${to}`);
  return source.slice(start, end);
}

// A minimal, real setButtonBusy — mirrors app/customer-ui.js's implementation closely enough
// that `button.disabled` genuinely flips true/false, which is what the guard checks.
function makeCUI() {
  const busyCalls = [];
  return {
    calls: busyCalls,
    setButtonBusy(button, {busy = true, label = 'Working…'} = {}) {
      busyCalls.push({busy, label});
      if (!button) return () => {};
      button.disabled = !!busy;
      return () => {};
    }
  };
}

function makeButton(id) {
  return {id, disabled: false, isConnected: true, dataset: {}};
}

function deferred() {
  let resolve;
  const promise = new Promise(r => {resolve = r});
  return {promise, resolve};
}

test('F084: the Add-product Save button ignores a second click while the insert is in flight', async () => {
  const handler = section(app, "if(canWrite)$('padd2').onclick=async()=>{", '  if(canWrite&&$(\'openProductForm\'))');
  assert.match(handler, /CUI\.setButtonBusy\(button,\{busy:true,label:'Saving…'\}\)/,
    'the fix must use the same busy idiom every sibling Save control on this page uses');
  assert.match(handler, /if\(button\.disabled\)return;/, 'a re-entrant click while busy must be a no-op');

  const cui = makeCUI();
  const inserts = [];
  const insertGate = deferred();
  const button = makeButton('padd2');
  const els = {
    padd2: button,
    pn2: {value: 'Chicken rice'},
    ps2: {value: ''},
    pp2: {value: '5.00'},
    productFormCard: {}
  };
  const ctx = {
    $: id => els[id],
    canWrite: true,
    S: {biz: {id: 'biz-1'}},
    sb: {from: table => ({insert: row => {inserts.push([table, row]); return insertGate.promise}})},
    toast: () => {}, fail: () => {}, CUI: cui,
    dismissFormModalV658: () => {}, loadInv: () => {}
  };
  vm.createContext(ctx);
  vm.runInContext(`${handler}\nglobalThis.__onclick=$('padd2').onclick;`, ctx);

  // Two rapid clicks, neither awaited before the second fires — exactly what a double click does.
  const first = ctx.__onclick();
  const second = ctx.__onclick();
  assert.equal(button.disabled, true, 'the button must be disabled synchronously before the insert settles');
  assert.equal(inserts.length, 1, 'the second click must not fire a second insert while the first is in flight');

  insertGate.resolve({error: null});
  await first;
  await second;
  assert.equal(inserts.length, 1, 'settling the first write must not let a queued second click through either');
});

test('F094: Create-invite ignores a second click while create_invite is in flight', async () => {
  const handler = section(app, "$('igo').onclick=async()=>{", "  await loadTemplates();");
  assert.match(handler, /CUI\.setButtonBusy\(button,\{busy:true,label:'Creating…'\}\)/);
  assert.match(handler, /if\(button\.disabled\)return;/);

  const cui = makeCUI();
  const rpcCalls = [];
  const rpcGate = deferred();
  const button = makeButton('igo');
  const els = {igo: button, ir: {value: 'manager'}, ie: {value: ''}};
  const ctx = {
    $: id => els[id],
    S: {biz: {id: 'biz-1'}},
    sb: {rpc: (name, args) => {rpcCalls.push([name, args]); return rpcGate.promise}},
    fail: () => {}, CUI: cui,
    copyTextToClipboard: async () => {}, staffInviteLinkV151: () => '', ROLE_LABELS: {}, esc: s => s,
    loadTeam: () => {}
  };
  vm.createContext(ctx);
  vm.runInContext(`${handler}\nglobalThis.__onclick=$('igo').onclick;`, ctx);

  const first = ctx.__onclick();
  const second = ctx.__onclick();
  assert.equal(button.disabled, true);
  assert.equal(rpcCalls.length, 1, 'a double click must mint exactly one create_invite call, not two live codes');
  assert.equal(rpcCalls[0][0], 'create_invite');

  rpcGate.resolve({data: {code: 'ABC123'}, error: null});
  await first;
  await second;
  assert.equal(rpcCalls.length, 1);
});

test('F137: Add-reward-type ignores a second click while save_reward_taxonomy is in flight', async () => {
  const handler = section(
    app,
    "$('rtAdd').onclick=async()=>{",
    "document.querySelectorAll('.taxonomyRename')"
  );
  assert.match(handler, /CUI\.setButtonBusy\(button,\{busy:true,label:'Adding…'\}\)/);
  assert.match(handler, /if\(button\.disabled\)return;/);

  const cui = makeCUI();
  const rpcCalls = [];
  const rpcGate = deferred();
  const button = makeButton('rtAdd');
  const els = {rtAdd: button, rtName: {value: 'Free coffee'}, rtKind: {value: 'free_item'}};
  const ctx = {
    $: id => els[id],
    S: {biz: {id: 'biz-1'}},
    sb: {rpc: (name, args) => {rpcCalls.push([name, args]); return rpcGate.promise}},
    toast: () => {}, fail: () => {}, CUI: cui,
    isRetentionCurrent: () => true, refreshRetentionPanel: () => {}, draftVersionId: 'draft-1'
  };
  vm.createContext(ctx);
  vm.runInContext(`${handler}\nglobalThis.__onclick=$('rtAdd').onclick;`, ctx);

  const first = ctx.__onclick();
  const second = ctx.__onclick();
  assert.equal(button.disabled, true);
  assert.equal(rpcCalls.length, 1,
    'a double click/tap must not mint two firm_reward_taxonomy rows with the same label');
  assert.equal(rpcCalls[0][0], 'save_reward_taxonomy');
  assert.equal(rpcCalls[0][1].p_taxonomy_id, null,
    'the server mints a fresh UUID whenever p_taxonomy_id is null — the client guard is the only thing preventing a duplicate');

  rpcGate.resolve({error: null});
  await first;
  await second;
  assert.equal(rpcCalls.length, 1);
});
