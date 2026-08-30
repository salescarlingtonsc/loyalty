/* V439 — Settings > Staff Members > "Add staff" opened BOTH the Import Team members popup AND
 * the manual add form (staffManualAddCard), stacked on top of each other. Owner: "delete this
 * pop-up when I click Add member".
 *
 * Root cause: importBtn('staff',...) builds the CSV-import button with an INLINE
 * onclick="openImport('staff',()=>settingsPage())" (app.js, function importBtn). Before this fix,
 * enhanceStaffMembersTabsV164 found that this was the ONLY button in the settings-team-card's
 * intro row, so it grabbed *that exact button*, relabelled it "Add staff", moved it into the new
 * toolbar, and ALSO addEventListener('click', openManualAdd)'d it. The inline onclick attribute
 * survived the relabel/move, so one click fired both handlers.
 *
 * Fix: "Add staff" is now always a freshly created button wired only to openManualAdd; the
 * original import button is kept in the toolbar as its own honestly-labelled control ("Import
 * from Excel"), inline onclick untouched.
 *
 * This is executing coverage, not a source-regex pin (house rule: source-regex tests are
 * vacuous — a grep stays green while the behaviour is dead). There is no jsdom/happy-dom
 * dependency in this repo (confirmed: no such package in package.json/node_modules), and
 * enhanceStaffMembersTabsV164 is inline template-string/DOM-mutation code inside app.js, not an
 * isolated module — so this file extracts the REAL function bodies (importBtn,
 * enhanceStaffMembersTabsV164) and the REAL small consts they depend on (esc, ROLE_LABELS,
 * STAFF_ROLE_OPTIONS_V207) straight out of app.js by source slicing, loads the REAL
 * app/customer-ui.js (self-contained, attaches window.FrenlyCustomerUI, needs no DOM to define
 * its functions) for CUI.action/icon, and runs all of it against a small purpose-built DOM shim
 * (Element/TextNode/querySelector/innerHTML parsing/click-with-inline-onclick) that implements
 * exactly the subset of the DOM API this code path uses. Nothing under test is stubbed.
 *
 * Sanity check on the harness itself: running this same harness against the pre-fix app.js
 * (git show HEAD^{/nestly_v438}:app/app.js, i.e. the commit before this fix) reproduces the bug
 * exactly — clicking the single toolbar button both opens staffManualAddCard AND calls
 * openImport — which is how this harness was validated before being trusted for the fix.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');
const customerUiSrc = readFileSync(new URL('../../app/customer-ui.js', import.meta.url), 'utf8');

/* ---------- extract the real source (functions by brace-matching, consts by line) ---------- */

function extractFunction(src, name) {
  // This codebase's convention (verified for both functions extracted below): a top-level
  // function's closing brace sits alone on its own line at column 0. No other line inside either
  // function body is a bare "}" — every nested block is indented — so "keep lines until one is
  // exactly '}'" is an exact, non-heuristic function-body extraction here.
  const startRe = new RegExp(`^function ${name}\\(`, 'm');
  const m = startRe.exec(src);
  assert.ok(m, `extractFunction: missing function ${name}`);
  const rest = src.slice(m.index);
  const lines = rest.split('\n');
  const acc = [];
  for (const line of lines) {
    acc.push(line);
    if (line === '}') return acc.join('\n');
  }
  throw new Error(`extractFunction: no column-0 closing brace found for ${name}`);
}

function extractConst(src, name) {
  // Line-based, not a generic JS statement scanner: a naive semicolon-index scan misfires on
  // esc's own regex character class `[&<>"']`, which contains a literal quote character. All
  // three consts pulled below are dense one/two-line declarations whose final line ends with
  // ';' and nothing else, so "keep taking lines until one trims to end with ';'" is exact for
  // them.
  const lines = src.split('\n');
  const startIdx = lines.findIndex(l => l.startsWith(`const ${name}=`));
  assert.ok(startIdx >= 0, `extractConst: missing const ${name}`);
  const acc = [];
  for (let i = startIdx; i < lines.length; i++) {
    acc.push(lines[i]);
    if (lines[i].trim().endsWith(';')) return acc.join('\n');
  }
  throw new Error(`extractConst: unterminated const ${name}`);
}

const importBtnSrc = extractFunction(app, 'importBtn');
const enhanceSrc = extractFunction(app, 'enhanceStaffMembersTabsV164');
/* nestly_v658 (owner photo 8: "+add staff ... will also pop up to edit / create"). Add staff now
   lifts the existing manual-add card into a dialog through the shared presentFormModalV658 /
   dismissFormModalV658 pair, so the extracted function has two new dependencies. They are handed
   in as REAL source rather than stubbed: the whole point of this test is that pressing Add staff
   opens the manual card and nothing else, and a stub could not tell us whether it still does. */
const presentFormModalSrc = extractFunction(app, 'presentFormModalV658');
const dismissFormModalSrc = extractFunction(app, 'dismissFormModalV658');
const escSrc = extractConst(app, 'esc');
const roleLabelsSrc = extractConst(app, 'ROLE_LABELS');
const staffRoleOptionsSrc = extractConst(app, 'STAFF_ROLE_OPTIONS_V207');

/* Prove we extracted the fixed source, not a stale duplicate elsewhere in the file. */
assert.match(enhanceSrc, /staff-members-import-top/,
  'extraction did not pick up the V439 fix (separate import control)');
assert.match(enhanceSrc, /addTop\.addEventListener\('click',openManualAdd\)/);
assert.doesNotMatch(enhanceSrc, /originalAdd/,
  'the V439 fix removed the "hijack the import button" code path entirely');

/* ---------- minimal DOM shim: just enough of the platform for this code path ---------- */

class TextNode {
  constructor(text) { this.nodeType = 3; this.textContent = text; this.parentNode = null; }
}
const VOID_TAGS = new Set(['area','base','br','col','embed','hr','img','input','link','meta','source','track','wbr']);

function findTagEnd(html, start) {
  // Finds the '>' that actually closes the tag starting at `start` (the '<'). A naive
  // indexOf('>', start) breaks the instant an attribute value contains a literal '>' — which
  // onclick="openImport('staff',()=>settingsPage())" always does, via the arrow function's '=>'.
  // Track quote state so a '>' inside "..." or '...' is never mistaken for the tag boundary.
  let i = start;
  let inQuote = null;
  while (i < html.length) {
    const c = html[i];
    if (inQuote) { if (c === inQuote) inQuote = null; i++; continue; }
    if (c === '"' || c === "'") { inQuote = c; i++; continue; }
    if (c === '>') return i;
    i++;
  }
  return -1;
}

class Element {
  constructor(tagName) {
    this.nodeType = 1;
    this.tagName = tagName.toUpperCase();
    this.attrs = new Map();
    this.childNodes = [];
    this.parentNode = null;
    this._listeners = {};
    this._style = null;
  }
  get children() { return this.childNodes.filter(n => n.nodeType === 1); }
  get nextElementSibling() {
    if (!this.parentNode) return null;
    const sibs = this.parentNode.children;
    const i = sibs.indexOf(this);
    return i >= 0 ? (sibs[i + 1] || null) : null;
  }
  get id() { return this.attrs.get('id') || ''; }
  set id(v) { this.setAttribute('id', v); }
  get className() { return this.attrs.get('class') || ''; }
  set className(v) { this.setAttribute('class', v); }
  get classList() {
    const self = this;
    return {
      add: (...cls) => { const s = new Set((self.className||'').split(/\s+/).filter(Boolean)); cls.forEach(c=>s.add(c)); self.className=[...s].join(' '); },
      remove: (...cls) => { const s = new Set((self.className||'').split(/\s+/).filter(Boolean)); cls.forEach(c=>s.delete(c)); self.className=[...s].join(' '); },
      contains: (c) => new Set((self.className||'').split(/\s+/).filter(Boolean)).has(c),
      toggle: (c, force) => {
        const has = new Set((self.className||'').split(/\s+/).filter(Boolean)).has(c);
        const want = force === undefined ? !has : force;
        if (want) self.classList.add(c); else self.classList.remove(c);
        return want;
      }
    };
  }
  get dataset() {
    const self = this;
    return new Proxy({}, {
      get(_, prop) {
        const attr = 'data-' + String(prop).replace(/[A-Z]/g, m => '-' + m.toLowerCase());
        return self.attrs.get(attr);
      },
      set(_, prop, value) {
        const attr = 'data-' + String(prop).replace(/[A-Z]/g, m => '-' + m.toLowerCase());
        self.setAttribute(attr, String(value));
        return true;
      }
    });
  }
  get style() {
    if (!this._style) {
      this._style = {};
      const raw = this.attrs.get('style') || '';
      raw.split(';').forEach(decl => {
        const idx = decl.indexOf(':');
        if (idx < 0) return;
        const prop = decl.slice(0, idx).trim();
        const val = decl.slice(idx + 1).trim();
        if (!prop) return;
        const camel = prop.replace(/-([a-z])/g, (_, c) => c.toUpperCase());
        this._style[camel] = val;
      });
    }
    return this._style;
  }
  get hidden() { return this.attrs.has('hidden'); }
  set hidden(v) { v ? this.setAttribute('hidden', '') : this.removeAttribute('hidden'); }
  setAttribute(name, value) {
    this.attrs.set(name, String(value));
    if (name === 'onclick') this._onclickSrc = String(value);
    if (name === 'style') this._style = null;
  }
  getAttribute(name) { return this.attrs.has(name) ? this.attrs.get(name) : null; }
  removeAttribute(name) {
    this.attrs.delete(name);
    if (name === 'onclick') this._onclickSrc = null;
    if (name === 'style') this._style = null;
  }
  hasAttribute(name) { return this.attrs.has(name); }
  set textContent(v) { this.childNodes = [new TextNode(v)]; }
  get textContent() { return this.childNodes.map(n => n.textContent).join(''); }
  set innerHTML(html) {
    this.childNodes = [];
    parseHTML(html).forEach(n => this.appendChild(n));
  }
  appendChild(node) {
    if (node.parentNode) node.parentNode.removeChild(node);
    node.parentNode = this; this.childNodes.push(node); return node;
  }
  removeChild(node) {
    const i = this.childNodes.indexOf(node);
    if (i >= 0) this.childNodes.splice(i, 1);
    node.parentNode = null;
    return node;
  }
  remove() { if (this.parentNode) this.parentNode.removeChild(this); }
  /* nestly_v658: presentFormModalV658 inserts the modal backdrop as the card's previous sibling,
     so the shim needs the one DOM call that does it. Modelled on before() below. */
  insertBefore(node, ref) {
    if (node.parentNode) node.parentNode.removeChild(node);
    const idx = ref ? this.childNodes.indexOf(ref) : -1;
    node.parentNode = this;
    if (idx >= 0) this.childNodes.splice(idx, 0, node); else this.childNodes.push(node);
    return node;
  }
  prepend(node) {
    if (node.parentNode) node.parentNode.removeChild(node);
    node.parentNode = this; this.childNodes.unshift(node);
  }
  before(node) {
    if (!this.parentNode) return;
    if (node.parentNode) node.parentNode.removeChild(node);
    const idx = this.parentNode.childNodes.indexOf(this);
    node.parentNode = this.parentNode;
    this.parentNode.childNodes.splice(idx, 0, node);
  }
  insertAdjacentHTML(position, html) {
    const nodes = parseHTML(html);
    if (position === 'beforeend') nodes.forEach(n => this.appendChild(n));
    else if (position === 'afterbegin') nodes.slice().reverse().forEach(n => this.prepend(n));
  }
  addEventListener(type, fn) { (this._listeners[type] = this._listeners[type] || []).push(fn); }
  removeEventListener(type, fn) { if (this._listeners[type]) this._listeners[type] = this._listeners[type].filter(f => f !== fn); }
  click() {
    // Mirrors real DOM semantics: the onclick="" content attribute and any
    // addEventListener('click', ...) listeners are independent and BOTH fire on activation —
    // which is exactly the mechanism the V439 bug exploited (both were wired to the same button).
    if (this._onclickSrc) new Function(this._onclickSrc).call(this);
    (this._listeners.click || []).forEach(fn => fn.call(this, { type: 'click', target: this }));
  }
  focus() { this._focused = true; }
  closest(sel) {
    let node = this;
    while (node) { if (node.nodeType === 1 && matchesSimple(node, sel)) return node; node = node.parentNode; }
    return null;
  }
  contains(node) {
    let n = node;
    while (n) { if (n === this) return true; n = n.parentNode; }
    return false;
  }
  querySelector(sel) { return queryAll(this, sel)[0] || null; }
  querySelectorAll(sel) { return queryAll(this, sel); }
}

function matchesSimple(el, simpleSel) {
  simpleSel = simpleSel.trim();
  if (simpleSel === '*' || simpleSel === '') return true;
  let rest = simpleSel;
  const tagMatch = rest.match(/^[a-zA-Z][a-zA-Z0-9]*/);
  if (tagMatch) {
    if (el.tagName !== tagMatch[0].toUpperCase()) return false;
    rest = rest.slice(tagMatch[0].length);
  }
  for (const cm of rest.matchAll(/\.([a-zA-Z0-9_-]+)/g)) { if (!el.classList.contains(cm[1])) return false; }
  const idMatch = rest.match(/#([a-zA-Z0-9_-]+)/);
  if (idMatch && el.id !== idMatch[1]) return false;
  for (const am of rest.matchAll(/\[([a-zA-Z0-9_-]+)(?:="([^"]*)")?\]/g)) {
    if (!el.hasAttribute(am[1])) return false;
    if (am[2] !== undefined && el.getAttribute(am[1]) !== am[2]) return false;
  }
  return true;
}

// Supports exactly what this code path uses: ":scope > sel[, sel2]" (direct children) and plain
// "sel[, sel2]" (any-depth descendant search, document order) — including comma groups like
// 'button,a', and simple tag/.class/#id/[attr] selectors.
function queryAll(root, selector) {
  const out = [];
  for (const g of selector.split(',').map(s => s.trim()).filter(Boolean)) {
    if (g.startsWith(':scope')) {
      let rest = g.slice(':scope'.length).trim();
      if (rest.startsWith('>')) rest = rest.slice(1).trim();
      for (const child of root.children) { if (matchesSimple(child, rest)) out.push(child); }
    } else {
      (function walk(node) {
        for (const child of node.children) {
          if (matchesSimple(child, g)) out.push(child);
          walk(child);
        }
      })(root);
    }
  }
  return out;
}

function parseHTML(html) {
  const root = new Element('#fragment');
  const stack = [root];
  let idx = 0;
  const len = html.length;
  while (idx < len) {
    if (html.startsWith('<!--', idx)) {
      const end = html.indexOf('-->', idx + 4);
      idx = end === -1 ? len : end + 3;
      continue;
    }
    if (html[idx] === '<') {
      if (html[idx + 1] === '/') {
        const end = findTagEnd(html, idx);
        if (end === -1) { idx = len; continue; }
        const tagName = html.slice(idx + 2, end).trim();
        idx = end + 1;
        for (let s = stack.length - 1; s > 0; s--) {
          if (stack[s].tagName === tagName.toUpperCase()) { stack.length = s; break; }
        }
        continue;
      } else {
        const end = findTagEnd(html, idx);
        if (end === -1) { idx = len; continue; }
        let tagContent = html.slice(idx + 1, end);
        idx = end + 1;
        let selfClose = false;
        if (tagContent.endsWith('/')) { selfClose = true; tagContent = tagContent.slice(0, -1); }
        const m = tagContent.match(/^([a-zA-Z][a-zA-Z0-9-]*)/);
        if (!m) continue;
        const tagName = m[1];
        const attrsStr = tagContent.slice(tagName.length);
        const el = new Element(tagName);
        const attrRe = /([a-zA-Z_:][-a-zA-Z0-9_:.]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;
        let am;
        while ((am = attrRe.exec(attrsStr))) {
          const value = am[2] !== undefined ? am[2] : am[3] !== undefined ? am[3] : am[4] !== undefined ? am[4] : '';
          el.setAttribute(am[1].toLowerCase(), value);
        }
        stack[stack.length - 1].appendChild(el);
        if (!selfClose && !VOID_TAGS.has(tagName.toLowerCase())) stack.push(el);
        continue;
      }
    }
    let next = html.indexOf('<', idx);
    if (next === -1) next = len;
    const text = html.slice(idx, next);
    if (text.length) stack[stack.length - 1].appendChild(new TextNode(text));
    idx = next;
  }
  return root.children;
}

const documentShim = { createElement: (tag) => new Element(tag) };

/* ---------- wire the real extracted code against the shim ---------- */

function loadCUI() {
  // customer-ui.js is a self-contained IIFE: `(function(global){ ... })(typeof window!=='undefined'
  // ? window : globalThis)`. Passing a plain object as `window` makes it attach
  // window.FrenlyCustomerUI to that object instead of polluting the real global — and none of its
  // top-level code touches `document`, only the function bodies we never call do.
  const fakeWindow = {};
  new Function('window', customerUiSrc)(fakeWindow);
  assert.ok(fakeWindow.FrenlyCustomerUI, 'customer-ui.js did not attach FrenlyCustomerUI');
  return fakeWindow.FrenlyCustomerUI;
}

const CUI = loadCUI();
const importBtn = new Function('CUI', `${importBtnSrc}\nreturn importBtn;`)(CUI);
const { esc, STAFF_ROLE_OPTIONS_V207 } = new Function(
  `${escSrc}\n${roleLabelsSrc}\n${staffRoleOptionsSrc}\nreturn {esc, ROLE_LABELS, STAFF_ROLE_OPTIONS_V207};`
)();
const enhanceStaffMembersTabsV164 = new Function('document', 'esc', 'STAFF_ROLE_OPTIONS_V207',
  `${presentFormModalSrc}\n${dismissFormModalSrc}\n${enhanceSrc}\nreturn enhanceStaffMembersTabsV164;`
)(documentShim, esc, STAFF_ROLE_OPTIONS_V207);

/* ---------- fixture: the real settings-team-card markup (app.js line ~42546), with the real
   importBtn('staff', 'Add staff without app access', 'settingsPage') output spliced in exactly
   as production does ---------- */

function makeTeamPanel() {
  const importButtonHtml = importBtn('staff', 'Add staff without app access', 'settingsPage');
  const html = `<section class="settings-panel" id="setpanel-team" role="tabpanel" aria-labelledby="settab-team" tabindex="-1" hidden>
    <div class="card settings-team-card"><div class="row"><b>Team</b><span class="spacer"></span>${importButtonHtml}</div><p class="muted small" style="margin:6px 0 10px">Add a roster-only staff member for appointments or reporting, or create an invite when they need to sign in.</p>
      <div id="team"><div class="card">loading</div></div>
      <hr style="border:none;border-top:1px solid var(--line);margin:16px 0">
      <b>Create company invite</b><p class="muted small" style="margin:5px 0 10px">Send the link or code to the staff member.</p>
      <div class="row" style="margin-top:10px"><select id="ir"><option value="manager">Manager</option></select>
      <input id="ie" type="email" placeholder="email (optional, for your records)">
      <button class="btn sm" id="igo">Create invite</button></div>
      <div id="invites" style="margin-top:10px"></div>
      <hr style="border:none;border-top:1px solid var(--line);margin:16px 0">
      <b class="small">Module templates</b>
      <p class="muted small" style="margin:4px 0 8px">Reusable module sets.</p>
      <div id="tplList"></div>
    </div>
  </section>`;
  return parseHTML(html)[0];
}

function withOpenImportSpy(run) {
  const calls = [];
  const priorOpenImport = globalThis.openImport;
  const priorSettingsPage = globalThis.settingsPage;
  globalThis.openImport = (...args) => { calls.push(args); };
  globalThis.settingsPage = () => {};
  try {
    return run(calls);
  } finally {
    globalThis.openImport = priorOpenImport;
    globalThis.settingsPage = priorSettingsPage;
  }
}

/* ---------- tests ---------- */

test('V439: "Add staff" opens only the manual add card, and never calls openImport', () => {
  withOpenImportSpy((openImportCalls) => {
    const teamPanel = makeTeamPanel();
    enhanceStaffMembersTabsV164(teamPanel);

    const toolbar = teamPanel.querySelector('.staff-members-toolbar');
    assert.ok(toolbar, 'the staff members toolbar was not built');

    // (c) exactly one Add-staff toolbar control exists.
    const addButtons = toolbar.querySelectorAll('.staff-members-add-top');
    assert.equal(addButtons.length, 1, 'exactly one Add-staff toolbar control must exist');
    assert.equal(addButtons[0].textContent.trim(), 'Add staff');

    const manualCard = teamPanel.querySelector('#staffManualAddCard');
    assert.ok(manualCard, 'the manual add card is missing');
    assert.equal(manualCard.style.display, 'none', 'the manual add card starts hidden');

    // (a) activating "Add staff" shows staffManualAddCard and does NOT invoke openImport.
    addButtons[0].click();
    assert.equal(manualCard.style.display, 'block', 'Add staff must open the manual add card');
    assert.equal(openImportCalls.length, 0,
      'Add staff must NOT invoke openImport — this exact double-fire was the V439 bug');
  });
});

test('V439: Import from Excel is still its own reachable control and still routes to openImport', () => {
  withOpenImportSpy((openImportCalls) => {
    const teamPanel = makeTeamPanel();
    enhanceStaffMembersTabsV164(teamPanel);

    const toolbar = teamPanel.querySelector('.staff-members-toolbar');
    const addBtn = toolbar.querySelector('.staff-members-add-top');
    const importControl = toolbar.querySelector('.staff-members-import-top');

    // (b) a separate import control exists whose activation DOES route to openImport('staff', ...).
    assert.ok(importControl, 'the import control must still exist as its own toolbar control');
    assert.notEqual(importControl, addBtn, 'the import control must be a DIFFERENT element from Add staff');
    assert.equal(importControl.textContent.trim(), 'Import from Excel');
    // The inline onclick built by importBtn()/CUI.action() must survive untouched — that
    // onclick="openImport('staff',()=>settingsPage())" attribute is the real production wiring,
    // not a re-implementation.
    assert.equal(importControl.getAttribute('onclick'), "openImport('staff',()=>settingsPage())");

    importControl.click();
    assert.equal(openImportCalls.length, 1, 'the import control must call openImport exactly once');
    assert.equal(openImportCalls[0][0], 'staff');

    // Clicking Import must not ALSO pop the manual add card — the two surfaces are independent.
    const manualCard = teamPanel.querySelector('#staffManualAddCard');
    assert.notEqual(manualCard.style.display, 'block',
      'the import control must not also open the manual add card');
  });
});

test('V439: enhancement is idempotent (re-running on the same panel is a no-op guard)', () => {
  withOpenImportSpy(() => {
    const teamPanel = makeTeamPanel();
    enhanceStaffMembersTabsV164(teamPanel);
    const toolbarFirst = teamPanel.querySelector('.staff-members-toolbar');
    enhanceStaffMembersTabsV164(teamPanel);
    const toolbars = teamPanel.querySelectorAll('.staff-members-toolbar');
    assert.equal(toolbars.length, 1, 'a second enhancement pass must not build a second toolbar');
    assert.equal(toolbars[0], toolbarFirst);
  });
});
