/* NESTLY v903 — the Business Intelligence call-to-action leads to immediate action.
 *
 * Owner report, 2026-09-15: the CTA inside the "Why is Peekaa telling me this?" pop-up was pressed
 * on three cards — "Review payments", "Open bring-back list", "See busy and quiet times" — and
 * "it does not work — i need it to lead me to immediate action."
 *
 * The control was never inert. It was being UNDONE, by two defaults of the dialog system it closes
 * through (CUI.activateDialog in app/customer-ui.js):
 *
 *   · the deactivator calls history.back() unless handOffHistory:true. history.back() is
 *     asynchronous, so on a route CTA the pop landed AFTER nav() had set the hash and carried the
 *     owner straight back to this page;
 *   · the deactivator calls returnFocus.focus() unless restoreFocus:false. Focus went back to the
 *     "Why is Peekaa telling me this?" button, the browser scrolled that button into view, and the
 *     scrollIntoView that had just run was cancelled.
 *
 * So this file is DOM-level rather than string-level: it EXECUTES biOpenExplainV892 against a
 * hand-rolled document / CUI / nav / requestAnimationFrame stub graph and presses the buttons. A
 * grep for "handOffHistory" would have stayed green while the click still did nothing.
 *
 * It also pins the two halves of the contract the fix rests on:
 *   · the flags really are in the deactivator's signature (app/customer-ui.js), and dismissal —
 *     Close, Escape, Back, backdrop (nestly_v578) — still closes with neither of them;
 *   · every route a CTA names is a key in the ROUTER'S OWN page map, parsed out of app/app.js
 *     rather than kept by hand in a test.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

/* nestly_v960: sentences in the sliced region are named templates now — the sandbox carries the
   REAL runtime, so a missing key fails here instead of rendering as an empty string. */
import { workspaceTemplateRuntime } from '../support/workspace-template-runtime.mjs';
const TPL_V960 = workspaceTemplateRuntime('en');

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const customerUi = readFileSync(join(root, 'app', 'customer-ui.js'), 'utf8');

const START = '/* nestly_v892 — BUSINESS INTELLIGENCE';
const END = '/* nestly_v892 END —';
const from = app.indexOf(START);
assert.ok(from > -1, 'the Business Intelligence presentation layer must exist in app/app.js');
const to = app.indexOf(END, from);
assert.ok(to > from, 'it must close with its end marker');
const block = app.slice(from, to);

/* ==================================================================================================
   The stub graph. Nothing here is a browser — every object models exactly what the opener touches,
   and records it, so an assertion cannot pass on a call that never happened.
   ================================================================================================== */

/* One Explore <details> group. `open`, a scroll recorder, and a <summary> that counts focus. */
function groupStub() {
  const summary = { focusCount: 0, focus() { this.focusCount += 1; } };
  return {
    open: false, scrolls: [], summary, isConnected: true,
    scrollIntoView(options) { this.scrolls.push(options); },
    querySelector(selector) {
      assert.equal(selector, 'summary', 'the group is asked for its summary and nothing else');
      return summary;
    }
  };
}

/* The dialog element the opener builds, plus a body that records what was mounted. A querySelector
   for an attribute the rendered markup does not carry returns null — which is how "a CTA with
   nowhere to go" reaches the opener. */
function domStub() {
  const appended = [];
  const handles = new Map();
  const makeNode = () => ({
    className: '', tabIndex: 0, innerHTML: '', removed: false,
    attributes: new Map(),
    setAttribute(name, value) { this.attributes.set(name, String(value)); },
    remove() { this.removed = true; },
    querySelector(selector) {
      const match = /^\[([a-z-]+)\]$/.exec(selector);
      assert.ok(match, `unmodelled selector: ${selector}`);
      const attribute = match[1];
      if (!this.innerHTML.includes(`${attribute}=`)) return null;
      if (!handles.has(attribute)) handles.set(attribute, { onclick: null });
      return handles.get(attribute);
    }
  });
  return {
    handles, appended,
    document: { createElement: () => makeNode(), body: { append: (node) => appended.push(node) } }
  };
}

/* Everything one opened pop-up produced: the mounted dialog, the options activateDialog was given,
   every argument the deactivator was called with, every nav(), and the pending animation frames. */
function openExplain(card, { group = null } = {}) {
  const { document, appended, handles } = domStub();
  const activations = [];
  const closeCalls = [];
  const navCalls = [];
  const frames = [];
  const context = vm.createContext({ ...TPL_V960,
    esc: (x) => String(x ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'),
    money: (c) => `SGD ${((c || 0) / 100).toFixed(2)}`,
    walletDate: (v) => `WD:${v}`,
    S: { biz: { currency: 'SGD' }, myRole: 'owner' },
    RevenueTruthUI: { money: (cents, currency) => `${currency} ${(Number(cents) / 100).toFixed(2)}` },
    ownerBriefLinesV826: () => [],
    document,
    nav: (href) => navCalls.push(href),
    requestAnimationFrame: (fn) => { frames.push(fn); return frames.length; },
    CUI: {
      icon: () => '<svg aria-hidden="true"></svg>',
      activateDialog(dialog, options) {
        activations.push({ dialog, options });
        return (arg) => { closeCalls.push(arg); dialog.removed = true; };
      }
    }
  });
  context.__exports = {};
  vm.runInContext(`${block}\n__exports.open=biOpenExplainV892;__exports.land=biLandOnSectionV903;`, context);
  const dialog = context.__exports.open(card, { findSection: () => group });
  const flushFrames = () => { const queued = frames.splice(0); for (const fn of queued) fn(); };
  return {
    dialog, appended, activations, closeCalls, navCalls, frames, flushFrames,
    land: context.__exports.land,
    cta: handles.get('data-bi-explain-cta') || null,
    closeButton: handles.get('data-bi-explain-close') || null
  };
}

/* scrollIntoView is handed an object built INSIDE the vm realm, whose prototype is not this
   realm's Object, so assert.deepEqual refuses it outright. Read the two fields instead — the same
   realm-crossing care v902 takes when it compares arrays as text. */
const scrollsOf = (group) => group.scrolls.map((options) => ({ behavior: options.behavior, block: options.block }));

const ROUTE_CARD = {
  type: 'needs_attention', topic: 'cash',
  finding: 'SGD 2,445.00 not yet collected',
  why: '8 sales are not recorded as fully paid.',
  action: 'Review the open sales and record any payments already received.',
  cta: { kind: 'route', href: '#/sales', label: 'Review payments' }
};
const SECTION_CARD = {
  type: 'opportunity', topic: 'rhythm',
  finding: 'Tuesday brings in more money per visit than Friday',
  action: 'Try an offer on your quiet day.',
  cta: { kind: 'section', section: 'behaviour', label: 'See busy and quiet times' }
};

/* ==================================================================================================
   1. The route CTA — "Open bring-back list", "Review payments".
   ================================================================================================== */
test('v903 route CTA: it navigates, and it closes with the two flags that let the navigation stand', () => {
  const opened = openExplain(ROUTE_CARD);
  assert.equal(opened.appended.length, 1, 'exactly one pop-up is mounted');
  assert.ok(opened.cta, 'a route CTA with an href is rendered');
  assert.deepEqual(opened.navCalls, [], 'nothing has navigated before the press');

  opened.cta.onclick();

  assert.deepEqual(opened.navCalls, ['#/sales'], 'the press navigates to the exact href on the card');
  assert.equal(opened.closeCalls.length, 1, 'the pop-up is closed exactly once');
  const flags = opened.closeCalls[0];
  assert.equal(flags.restoreFocus, false,
    'focus must NOT be thrown back to the button that opened the pop-up: the destination page takes it');
  assert.equal(flags.handOffHistory, true,
    'and no history.back() may be queued — it would land after nav() and undo the navigation');
  assert.equal(opened.dialog.removed, true, 'the pop-up is gone');
});

test('v903 route CTA: the order is close-then-navigate, so nothing is queued against the hash change', () => {
  const opened = openExplain(ROUTE_CARD);
  const order = [];
  /* Re-wire the two recorders to record their ORDER as well as their arguments. */
  const seenClose = opened.closeCalls, seenNav = opened.navCalls;
  const before = seenClose.push.bind(seenClose);
  seenClose.push = (...args) => { order.push('close'); return before(...args); };
  const beforeNav = seenNav.push.bind(seenNav);
  seenNav.push = (...args) => { order.push('nav'); return beforeNav(...args); };
  opened.cta.onclick();
  assert.deepEqual(order, ['close', 'nav'],
    'the dialog leaves first; navigating first would leave its history entry stranded above the route');
});

/* ==================================================================================================
   2. The section CTA — "See busy and quiet times", "See who comes back", and the rest.
   ================================================================================================== */
test('v903 section CTA: it opens the group, scrolls to it and puts focus on its summary', () => {
  const group = groupStub();
  const opened = openExplain(SECTION_CARD, { group });
  assert.ok(opened.cta, 'a section CTA whose group exists on the page is rendered');
  assert.equal(group.open, false, 'the group starts closed');

  opened.cta.onclick();

  assert.equal(group.open, true, 'the group is opened');
  assert.equal(opened.closeCalls.length, 1);
  assert.equal(opened.closeCalls[0].restoreFocus, false,
    'focus must not snap back to the opener — the browser scrolls it into view and undoes the landing');

  /* The landing is deliberately one frame late; see the next test for why. */
  assert.deepEqual(scrollsOf(group), [], 'nothing has scrolled yet');
  opened.flushFrames();
  assert.deepEqual(scrollsOf(group), [{ behavior: 'smooth', block: 'start' }],
    'exactly one scroll, to the top of the group');
  assert.equal(group.summary.focusCount, 1,
    'and the summary takes focus, so a keyboard user lands on the group rather than staying put');
});

test('v903 section CTA: the history entry is UNWOUND, not handed off — handing it off strands a dead Back', () => {
  const opened = openExplain(SECTION_CARD, { group: groupStub() });
  opened.cta.onclick();
  const flags = opened.closeCalls[0];
  /* A section CTA keeps the owner on #/customerintel. activateDialog's entry carries that very same
     url, so handing it off would leave an entry a Back press pops without firing hashchange — the
     owner would press Back once and see nothing happen. Unwinding it is the correct exit; the price
     is that history.back() is asynchronous, which is precisely why the scroll is deferred a frame
     (the browser restores the outgoing entry's scroll position during that traversal). */
  assert.notEqual(flags.handOffHistory, true,
    'the section CTA must let the deactivator unwind its own history entry');
  assert.equal(opened.frames.length, 1,
    'and the landing waits a frame precisely because that unwind has been asked for');
});

test('v903 section CTA: the scroll is deferred, so a synchronous history unwind cannot cancel it', () => {
  const group = groupStub();
  const opened = openExplain(SECTION_CARD, { group });
  opened.cta.onclick();
  assert.equal(opened.frames.length, 1, 'the landing is queued on the next animation frame');
  assert.equal(group.summary.focusCount, 0, 'and has not run yet');
  opened.flushFrames();
  assert.equal(group.summary.focusCount, 1, 'it runs once the frame arrives');
});

test('v903 landing helper: without defer it lands in the same tick, which is what the idea opener needs', () => {
  const group = groupStub();
  const { land } = openExplain(SECTION_CARD, { group: groupStub() });
  land(group);
  assert.deepEqual(scrollsOf(group), [{ behavior: 'smooth', block: 'start' }]);
  assert.equal(group.summary.focusCount, 1);
  /* A group that is not on the page is a no-op rather than a crash. */
  assert.doesNotThrow(() => land(null));
});

/* ==================================================================================================
   3. Dismissal is unchanged — Close, Escape, Back and the backdrop.
   ================================================================================================== */
test('v903 dismissal: the Close button closes with the defaults, keeping focus and the history unwind', () => {
  const opened = openExplain(ROUTE_CARD);
  assert.ok(opened.closeButton, 'the pop-up always offers a Close button');
  opened.closeButton.onclick();
  assert.equal(opened.closeCalls.length, 1);
  const flags = opened.closeCalls[0];
  assert.equal(flags.restoreFocus, true, 'focus returns to the button that opened the pop-up');
  assert.notEqual(flags.handOffHistory, true, 'and the dialog unwinds its own history entry');
  assert.deepEqual(opened.navCalls, [], 'dismissing navigates nowhere');
});

test('v903 dismissal: Escape, Back and a backdrop click all arrive through onClose, with the same defaults', () => {
  const group = groupStub();
  const opened = openExplain(SECTION_CARD, { group });
  assert.equal(opened.activations.length, 1, 'the pop-up is a real activateDialog dialog');
  assert.equal(opened.activations[0].options.initialFocus, '[data-bi-explain-cta],[data-bi-explain-close]',
    'the action takes focus on open when there is one');
  /* activateDialog calls onClose with NO arguments for all three of Escape, popstate and backdrop,
     so proving onClose's defaults proves all three. */
  opened.activations[0].options.onClose();
  assert.equal(opened.closeCalls.length, 1);
  assert.equal(opened.closeCalls[0].restoreFocus, true);
  assert.notEqual(opened.closeCalls[0].handOffHistory, true);
  assert.deepEqual(scrollsOf(group), [], 'dismissing does not land the owner anywhere');
  assert.equal(group.open, false, 'and does not open the group');
  assert.equal(opened.frames.length, 0, 'nothing is queued for a later frame');
});

test('v903 dismissal: a card whose CTA has nowhere to go still opens and still closes', () => {
  /* findSection returns null: the Explore group this card names is not on the page. */
  const opened = openExplain(SECTION_CARD, { group: null });
  assert.equal(opened.cta, null, 'no dead control is rendered');
  opened.closeButton.onclick();
  assert.equal(opened.closeCalls[0].restoreFocus, true);
});

test('v903 the two escape hatches this fix depends on are really in the deactivator signature', () => {
  assert.match(customerUi, /return \(\{restoreFocus=true,handOffHistory=false\}=\{\}\)=>\{/,
    'app/customer-ui.js must still offer both flags, with dismissal as the default');
  assert.match(customerUi, /if\(handOffHistory\)closedByUs=true;/,
    'handOffHistory must still be what skips the unwind');
  assert.match(customerUi, /if\(restoreFocus&&returnFocus\?\.isConnected\)returnFocus\.focus\(\);/,
    'restoreFocus must still be what returns focus to the opener');
  /* nestly_v578: backdrop dismissal is a property of the dialog SYSTEM, and this pop-up inherits it
     by construction. It must not be re-hand-wired on the pop-up itself. */
  assert.match(customerUi, /dialog\.addEventListener\('mousedown',backdropDown\);/);
  assert.match(customerUi, /dialog\.addEventListener\('click',backdropClick\);/);
  const opener = block.slice(block.indexOf('function biOpenExplainV892('));
  assert.ok(!/dialog\.onclick\s*=/.test(opener.slice(0, opener.indexOf('\n}\n'))),
    'the pop-up does not hand-wire its own backdrop handler');
});

/* ==================================================================================================
   4. Destinations — read out of the source, against the router's own page map.
   ================================================================================================== */
/* The router's page map, parsed from app/app.js. Comments, string bodies and everything nested
   inside a handler are blanked first, so `{fromRouteV288:true}` and the nav('#/grow/bringback')
   inside the retention redirect cannot be mistaken for top-level route keys. A quoted key at the
   top level ('customer-interface') is kept. */
const ROUTE_KEYS_V903 = (() => {
  const start = app.indexOf('const P={dashboard,');
  assert.ok(start > -1, "the router's page map must exist in app/app.js");
  const open = app.indexOf('{', start);
  let depth = 0, mode = 'code', quote = '', masked = '', closed = false;
  for (let i = open; i < app.length; i++) {
    const c = app[i], next = app[i + 1];
    if (mode === 'block') { if (c === '*' && next === '/') { mode = 'code'; masked += '  '; i += 1; } else masked += ' '; continue; }
    if (mode === 'line') { if (c === '\n') { mode = 'code'; masked += '\n'; } else masked += ' '; continue; }
    if (mode === 'string') {
      if (c === '\\') { masked += '  '; i += 1; continue; }
      if (c === quote) mode = 'code';
      masked += depth === 1 ? c : ' ';
      continue;
    }
    if (c === '/' && next === '*') { mode = 'block'; masked += '  '; i += 1; continue; }
    if (c === '/' && next === '/') { mode = 'line'; masked += '  '; i += 1; continue; }
    if (c === '"' || c === "'" || c === '`') { mode = 'string'; quote = c; masked += depth === 1 ? c : ' '; continue; }
    if (c === '{' || c === '(' || c === '[') { depth += 1; masked += depth === 1 ? c : ' '; continue; }
    if (c === '}' || c === ')' || c === ']') { masked += depth === 1 ? c : ' '; depth -= 1; if (!depth) { closed = true; break; } continue; }
    masked += depth === 1 ? c : ' ';
  }
  assert.ok(closed, 'the page map must close');
  const keys = new Set([...masked.matchAll(/[{,]\s*'?([a-z][a-z-]*)'?\s*[:,}]/g)].map((match) => match[1]));
  for (const known of ['dashboard', 'sales', 'clients', 'custpackages', 'servicemapping', 'grow', 'customerintel']) {
    assert.ok(keys.has(known), `the parse must find the real route "${known}", got: ${[...keys].sort().join(' ')}`);
  }
  assert.ok(!keys.has('fromroutev288') && !keys.has('view'),
    'and must not pick up an option object inside a handler body');
  return keys;
})();

test('v903 destination: the unpaid-money card leads to the screen where a payment is recorded', () => {
  /* nestly_v960: the finding is a named template now; the card is still found by the key it names. */
  const card = block.slice(block.indexOf("amountNotYetCollected"));
  const cta = card.slice(0, card.indexOf('evidence:'));
  assert.match(cta, /cta:\{kind:'route',href:'#\/sales',label:'Review payments'\}/,
    'Review payments navigates to Sales & refunds instead of scrolling to a panel on this page');
  assert.ok(!/cta:\{kind:'section',section:'money',label:'Review payments'\}/.test(block),
    'and the old scroll-to-a-panel form is gone');
});

test('v903 destination: the v108 daily action stays a section CTA, because its control is on this page', () => {
  assert.match(block, /cta:\{kind:'section',section:'money',label:'Open today’s best action'\}/,
    'approve/dismiss/hold-out for the daily action live on the Revenue Truth control under Explore');
});

test('v903 destination: every analysis CTA is still a scroll, not a navigation', () => {
  for (const label of ['See busy and quiet times', 'See who comes back', 'View services', 'See rewards',
    'See staff performance', 'See the full evidence', 'See who you may contact']) {
    const at = block.indexOf(`label:'${label}'`);
    assert.ok(at > -1, `"${label}" must still be offered`);
    for (const match of block.matchAll(new RegExp(`cta:\\{[^}]*label:'${label}'`, 'g'))) {
      assert.match(match[0], /kind:'section'/,
        `"${label}" is about reading the panel, so it stays a scroll`);
    }
  }
});

test('v903 destination: every CTA href on this page is a key in the router\'s own page map', () => {
  const hrefs = [...block.matchAll(/href:'(#[^']*)'/g)].map((match) => match[1]);
  assert.ok(hrefs.length >= 10, `the scan must find the page's routes, found ${hrefs.length}`);
  for (const href of new Set(hrefs)) {
    assert.match(href, /^#\/[a-z]/, `${href} must be a hash route`);
    const key = href.replace(/^#\//, '').split('/')[0];
    assert.ok(ROUTE_KEYS_V903.has(key),
      `${href} resolves to "${key}", which the router's page map does not declare`);
  }
  /* The set is exactly the destinations this page claims — a new one has to be added deliberately. */
  assert.deepEqual([...new Set(hrefs)].sort(),
    ['#/clients', '#/custpackages', '#/grow/bringback', '#/sales', '#/servicemapping']);
});

/* ==================================================================================================
   5. The other opener on the page — the idea CTA, which is not inside a dialog.
   ================================================================================================== */
test('v903 idea opener: it lands the same way, and needs neither close flag', () => {
  const start = app.indexOf("body.querySelectorAll('[data-bi-open-v892]')");
  assert.ok(start > -1, 'the opener binding must exist');
  const binding = app.slice(start, start + 520);
  assert.ok(binding.includes('group.open=true'), 'it still opens the group');
  assert.ok(binding.includes('biLandOnSectionV903(group)'),
    'and lands through the same helper, so the summary takes focus here too');
  assert.ok(!binding.includes('handOffHistory') && !binding.includes('restoreFocus'),
    'it is not inside a dialog, so neither close flag belongs here');
  assert.ok(!binding.includes('requestAnimationFrame'),
    'and nothing unwinds a history entry underneath it, so the landing is not deferred');
});
