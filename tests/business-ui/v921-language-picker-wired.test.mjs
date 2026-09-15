/**
 * nestly_v921 — the workspace language picker is actually bound to a handler.
 *
 * THE DEFECT THIS PINS. wireWorkspaceLanguageV97() is called from renderShell, and renderShell
 * always runs with profileOpen === false (it is initialised false, and route() resets it via
 * resetPopoverStateV452 before every render). The desktop picker lives inside profileHtml()'s
 * `${profileOpen? … }` branch, so at the moment renderShell wires it the <select> does not exist,
 * wirePicker's `if(!picker)return` takes the early exit, and nothing is bound. Opening the menu
 * calls renderProfile -> wireProfile, which did not wire it either. Choosing 中文 therefore did
 * nothing at all: no request, no error, and an English workspace with the select showing 中文,
 * because that is ordinary DOM state the browser keeps on its own.
 *
 * This test EXECUTES the real profileHtml() and the real wireProfile() against a DOM stub and
 * asserts a function is bound to the picker. A grep would have passed against the broken code —
 * the call existed, it was simply made at a moment when its target did not.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');
const slice = (from, to) => {
  const start = app.indexOf(from);
  assert.ok(start >= 0, `missing: ${from}`);
  const end = app.indexOf(to, start + from.length);
  assert.ok(end > start, `missing: ${to}`);
  return app.slice(start, end);
};

/* The real functions under test — including wireWorkspaceLanguageV97 itself, so the whole path
   from "menu opens" to "a handler is bound" runs exactly as it does in production. */
const SRC = [
  slice('function workspaceLanguagePickerV97(', 'const workspaceTranslationV97='),
  slice('function wireWorkspaceLanguageV97(){', 'function renderShell(page){'),
  slice('function profileHtml(){', '/* ---------- V452: ONE dismiss discipline'),
  slice('function wireProfile(page){', 'function renderProfile(page){'),
].join('\n');

function harness({ profileOpen }) {
  /* Every element the wiring touches is a plain object; assigning .onclick/.onchange on it is
     exactly what the production code does, so a bound handler is observable as a function. */
  const nodes = new Map();
  const node = (id) => {
    if (!nodes.has(id)) nodes.set(id, { id, isConnected: true, value: '', disabled: false, style: {}, dataset: {},
      querySelector: () => null, querySelectorAll: () => [], setAttribute() {}, getAttribute: () => null,
      addEventListener() {}, removeAttribute() {}, focus() {}, closest: () => null, matches: () => false });
    return nodes.get(id);
  };
  const context = {
    console,
    profileOpen,
    nodes,
    workspaceLocale: 'en',
    S: { biz: { name: 'Cubbly SPA', industry: 'facial', slug: 'cubbly' }, user: { email: 'o@x.com' },
         myRole: 'owner', hasCustomerPersona: false, staffWorkspaces: [], isSA: false },
    BRAND: { customerLabel: 'My Peekaa', productName: 'Peekaa' },
    INDUSTRIES: { facial: { label: 'Facial / Spa' } },
    CUI: { icon: (n) => `<i data-i="${n}"></i>` },
    esc: (v) => String(v ?? ''),
    userDisplayNameV158: () => 'Chuan Seng',
    profileBranchScopeLabelV158: () => 'All branches',
    businessWorkspaceSwitchHtml: () => '<div class="stub-switch"></div>',
    workspaceTemplateAttributeV97: () => '',
    accountDeletionCardHtml: () => '',
    hydrateProfileBranchSelectorV158() {},
    wirePopoverDismissV452() {},
    closeAllPopoversV452() {},
    renderProfile() {},
    setWorkspaceLocaleV97: async () => true,
    /* The real $ the production code uses: by id. */
    $: (id) => node(id),
    document: { getElementById: (id) => node(id), querySelectorAll: () => [], addEventListener() {} },
  };
  vm.createContext(context);
  vm.runInContext(SRC, context);
  return context;
}

test('v921 the desktop language picker only exists inside the OPEN account menu', () => {
  const closed = harness({ profileOpen: false });
  const openMenu = harness({ profileOpen: true });
  const whenClosed = vm.runInContext('profileHtml()', closed);
  const whenOpen = vm.runInContext('profileHtml()', openMenu);

  assert.doesNotMatch(whenClosed, /id="workspaceLanguageV97"/,
    'a closed menu renders no picker — which is why wiring it from renderShell can never work');
  assert.match(whenOpen, /id="workspaceLanguageV97"/,
    'the open menu is the only place the desktop picker exists');
});

test('v921 opening the account menu binds a handler to the language picker', () => {
  const context = harness({ profileOpen: true });
  vm.runInContext('wireProfile(["dashboard"])', context);

  const picker = context.nodes.get('workspaceLanguageV97');
  assert.ok(picker, 'wireProfile must reach the picker by id');
  assert.equal(typeof picker.onchange, 'function',
    'choosing a language must DO something — before v921 nothing was bound and 中文 was inert');
});

test('v921 the binding actually commits the chosen locale', async () => {
  const context = harness({ profileOpen: true });
  const calls = [];
  context.setWorkspaceLocaleV97 = async (locale) => { calls.push(locale); context.workspaceLocale = locale; return true; };
  vm.runInContext('wireProfile(["dashboard"])', context);

  const picker = context.nodes.get('workspaceLanguageV97');
  picker.value = 'zh-CN';
  await picker.onchange();

  assert.deepEqual(calls, ['zh-CN'], 'the chosen value must be committed, not merely displayed');
  assert.equal(picker.value, 'zh-CN', 'and the control reflects the locale that was actually stored');
  assert.equal(picker.disabled, false, 'the control is released again once the write settles');
});

test('v921 the mobile picker was never affected, and still is not', () => {
  /* It renders unconditionally inside the More drawer, so it exists when renderShell wires it.
     That is why the language mechanism looked sound: one of the two pickers always worked. */
  const dock = slice('function staffMobileActionsHtml(page){', 'function wireStaffMobileActions(){');
  assert.match(dock, /workspaceLanguagePickerV97\('workspaceLanguageMobileV151'\)/);
  assert.doesNotMatch(dock, /profileOpen/, 'the drawer picker is not behind the account menu');

  const wiring = slice('function wireWorkspaceLanguageV97(){', '\n}');
  assert.match(wiring, /wirePicker\(\$\('workspaceLanguageV97'\)\)/);
  assert.match(wiring, /wirePicker\(\$\('workspaceLanguageMobileV151'\)\)/,
    'both pickers are still bound by the same function; only WHEN it runs was wrong');
});
