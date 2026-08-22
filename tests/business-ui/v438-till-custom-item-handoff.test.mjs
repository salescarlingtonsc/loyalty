import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {resolve, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';

/* nestly_v438 — the till's "Add other item" flow.
 *
 * THE BUG (live-reproduced 2026-08-22 on a fresh production tenant): closing the Add-item sheet
 * unwinds its dialog history entry with history.back(), which is ASYNCHRONOUS. The pop landed
 * AFTER openCustomModal() had pushed ITS entry, fired the new modal's popstate handler, and
 * closed the "Other item" form the instant it opened — silently. On a business with no catalogue
 * items this was the ONLY way to key a sale, so the till dead-ended. Same failure shape v183
 * documented for customer sheets; same cure: the outgoing dialog hands its history entry to the
 * incoming one ({handOffHistory:true} + inheritHistoryId).
 *
 * Two layers, both EXECUTED (source-regex tests are vacuous — house rule):
 *   1. the REAL CUI.activateDialog from app/customer-ui.js, run against hand-stubbed
 *      window/history/document, proving (a) the old default-close sequence really does destroy
 *      the incoming dialog (the harness can see the bug), and (b) the hand-off sequence keeps it
 *      alive with exactly one history entry consumed at the end;
 *   2. the till handler sliced from app/app.js, executed with recorders, pinning that it closes
 *      with {handOffHistory:true} and opens with the inherited id.
 */

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const cuiSrc = readFileSync(resolve(root, 'app/customer-ui.js'), 'utf8');
const appSrc = readFileSync(resolve(root, 'app/app.js'), 'utf8');

/* ---- a minimal DOM/history world, honest about the one async fact that matters ------------- */
function makeWorld() {
  const listeners = {popstate: []};
  const pendingBacks = [];
  const stack = [{}];
  const history = {
    get state() { return stack[stack.length - 1]; },
    pushState(state) { stack.push(state); },
    back() {
      /* The real history.back() never pops synchronously — that asynchrony IS the bug. */
      pendingBacks.push(() => {
        if (stack.length > 1) stack.pop();
        for (const listener of [...listeners.popstate]) listener();
      });
    },
  };
  const window = {
    addEventListener: (name, fn) => {(listeners[name] ||= []).push(fn);},
    removeEventListener: (name, fn) => {
      const list = listeners[name] || [];
      const at = list.indexOf(fn);
      if (at >= 0) list.splice(at, 1);
    },
  };
  const makeDialog = () => {
    const dialog = {
      isConnected: true,
      listeners: [],
      addEventListener(name, fn) { this.listeners.push([name, fn]); },
      removeEventListener() {},
      querySelectorAll: () => [],
      querySelector: () => null,
      focus() {},
      remove() { this.isConnected = false; },
    };
    return dialog;
  };
  const document = {activeElement: null};
  const flushBacks = () => { while (pendingBacks.length) pendingBacks.shift()(); };
  return {window, history, document, makeDialog, flushBacks};
}

function loadActivateDialog(world) {
  /* customer-ui.js is an IIFE over `window`; shadow the globals it reaches for. */
  const factory = new Function(
    'window', 'document', 'history', 'requestAnimationFrame', 'globalThis',
    `${cuiSrc}\nreturn window.FrenlyCustomerUI;`
  );
  const cui = factory(world.window, world.document, world.history, (fn) => fn(), world.window);
  assert.equal(typeof cui.activateDialog, 'function', 'real activateDialog loaded');
  return cui;
}

test('the default close-then-open sequence really does destroy the incoming dialog (bug is observable)', () => {
  const world = makeWorld();
  const cui = loadActivateDialog(world);
  const sheet = world.makeDialog();
  const closeSheet = cui.activateDialog(sheet, {onClose: () => {}});

  let modalClosed = false;
  const modal = world.makeDialog();
  closeSheet();                       // default: schedules the ASYNC history.back()
  cui.activateDialog(modal, {onClose: () => { modalClosed = true; modal.remove(); }});
  world.flushBacks();                 // the pending pop lands on the NEW entry

  assert.equal(modalClosed, true,
    'without the hand-off, the stray back() closes the incoming dialog — the exact live bug');
});

test('the hand-off keeps the custom-item modal alive, and one Back still closes exactly one', () => {
  const world = makeWorld();
  const cui = loadActivateDialog(world);
  const sheet = world.makeDialog();
  const closeSheet = cui.activateDialog(sheet, {onClose: () => {}});
  const inherited = cui.currentDialogHistoryId();
  assert.ok(inherited > 0, 'the sheet holds a dialog history entry');

  let modalClosed = false;
  const modal = world.makeDialog();
  closeSheet({handOffHistory: true}); // no back() scheduled; the entry stays for the modal
  const closeModal = cui.activateDialog(modal,
    {onClose: () => { modalClosed = true; modal.remove(); }, inheritHistoryId: inherited});
  world.flushBacks();

  assert.equal(modalClosed, false, 'the modal survives the transition');
  assert.equal(modal.isConnected, true, 'the modal is still on the page');
  assert.equal(world.history.state?.cuiDialog, inherited, 'the modal adopted the SAME entry — no double push');

  closeModal();                       // a normal close unwinds the one shared entry
  world.flushBacks();
  assert.equal(world.history.state?.cuiDialog, undefined, 'exactly one entry consumed at the end');
});

test('the till handler executes the hand-off contract', () => {
  const from = appSrc.indexOf("if($('tCustomOpen'))$('tCustomOpen').onclick=()=>{");
  assert.ok(from > 0, 'handler found in app/app.js');
  const to = appSrc.indexOf('};', appSrc.indexOf('openCustomModal({inheritHistoryId:inheritV438});', from));
  const handlerSrc = appSrc.slice(from, to + 2);

  const calls = [];
  const button = {onclick: null};
  new Function('$', 'CUI', 'closeTillAddSheetV373', 'openCustomModal', handlerSrc)(
    (id) => (id === 'tCustomOpen' ? button : null),
    {currentDialogHistoryId: () => 42},
    (options) => calls.push(['close', options]),
    (options) => calls.push(['open', options]),
  );
  assert.equal(typeof button.onclick, 'function', 'the handler was wired');
  button.onclick();
  assert.deepEqual(calls, [
    ['close', {handOffHistory: true}],
    ['open', {inheritHistoryId: 42}],
  ], 'closes the sheet handing its entry over, then opens the modal inheriting it — in that order');
});
