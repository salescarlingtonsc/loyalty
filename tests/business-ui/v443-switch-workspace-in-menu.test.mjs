/* V443 (owner sketch, annotated screenshot 2026-08-22): "Switch workspace" moves out of the
 * header appbar and into the profile menu's top workspace section, right beside the current
 * workspace name. It must call the EXACT SAME businessWorkspaceSwitchHtml() the header used —
 * not a reimplementation — because that function's dropdown links (#/workspace/<slug>/dashboard)
 * feed the router's identity-verified workspace resolution in route() (see the '#/workspace/'
 * branch), which carries a known navigation race the owner does not want re-litigated by a
 * parallel copy of the switching logic.
 *
 * This file executes the real, extracted source of businessWorkspaceSwitchHtml() and profileHtml()
 * in a vm context (matching the harness style already used by tests/quality/frontend-role-matrix
 * .test.mjs's permissionHarness()) rather than grepping for markup strings — a spy wraps the real
 * switch function so the assertions prove profileHtml() actually calls it, with the real staff
 * list and the real slug, not merely that similar-looking text appears somewhere in the source.
 * The header side is proven by executing the extracted <header class="appbar"> template literal
 * with no businessWorkspaceSwitchHtml binding available at all: if a future edit reintroduces the
 * call, evaluation throws ReferenceError and the test fails loudly instead of silently drifting.
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

function slice(startMarker, endMarker) {
  const start = app.indexOf(startMarker);
  assert.ok(start >= 0, `missing start marker: ${startMarker}`);
  const end = app.indexOf(endMarker, start + startMarker.length);
  assert.ok(end >= 0, `missing end marker: ${endMarker}`);
  return app.slice(start, end);
}

const escSrc = app.match(/const esc=[^\n]+;/)?.[0];
assert.ok(escSrc, 'missing esc() source');
const sortStaffWorkspacesSrc = slice('function sortStaffWorkspaces(', 'function customerWorkspaceSwitchHtml(');
const businessWorkspaceSwitchHtmlSrc = slice('function businessWorkspaceSwitchHtml(', 'function renderNoCustomerDestination(');
const profileHtmlSrc = slice('function profileHtml(){', 'function wireProfile(page){');
const headerFragment = (() => {
  const start = app.indexOf('<header class="appbar">');
  assert.ok(start >= 0, 'missing header appbar markup');
  const end = app.indexOf('</header>', start);
  assert.ok(end >= 0, 'missing header appbar close tag');
  return app.slice(start, end + '</header>'.length);
})();
const staffMobileActionsHtmlSrc = slice('function staffMobileActionsHtml(page){', 'function wireStaffMobileActions(){');

/* Builds a vm context that executes the real businessWorkspaceSwitchHtml() and profileHtml()
   source, with the switch function wrapped in a call-recording spy that still forwards to the
   real implementation — so its return value in profileHtml()'s output is genuinely produced by
   the shared function, not a look-alike stub. */
function renderProfileMenu(S) {
  const context = {
    S,
    profileOpen: true,
    BRAND: { customerLabel: 'My Rewards' },
    INDUSTRIES: { facial: { label: 'Facial / Spa' } },
    CUI: { icon: (name) => `<i data-icon="${name}"></i>` },
    userDisplayNameV158: () => 'Owner Tester',
    workspaceLanguagePickerV97: () => '<select id="stubWorkspaceLanguage"></select>',
    profileBranchScopeLabelV158: () => 'All branches',
    /* Stubbed rather than the real V97 i18n-attribute machinery — that machinery is exercised by
       tests/customer-wallet/v97-workspace-localization-acceptance.test.mjs; this file is about
       WHERE the switcher renders and WHICH function it calls, not its aria-label templating. */
    workspaceTemplateAttributeV97: (attribute, key, values) => `data-stub-${attribute}="${key}:${JSON.stringify(values)}"`,
    switchCalls: [],
  };
  vm.createContext(context);
  vm.runInContext(`${escSrc}\n${sortStaffWorkspacesSrc}\n${businessWorkspaceSwitchHtmlSrc}`, context);
  vm.runInContext(
    `const __realBusinessWorkspaceSwitchHtml=businessWorkspaceSwitchHtml;
     businessWorkspaceSwitchHtml=(...args)=>{switchCalls.push(args);return __realBusinessWorkspaceSwitchHtml(...args)};`,
    context
  );
  vm.runInContext(profileHtmlSrc, context);
  const html = vm.runInContext('profileHtml()', context);
  return { html, switchCalls: context.switchCalls };
}

function fixtureS({ hasCustomerPersona = true } = {}) {
  return {
    biz: { name: 'Kaya Toast HQ', industry: 'facial', slug: 'kaya-toast' },
    staffWorkspaces: [
      { business_name: 'QA Kopi Lab', business_slug: 'qa-kopi-lab' },
      { business_name: 'QA Kaya Toast', business_slug: 'qa-kaya-toast' },
      { business_name: 'Kaya Toast HQ', business_slug: 'kaya-toast' },
    ],
    hasCustomerPersona,
    myRole: 'owner',
    isSA: false,
    user: { email: 'owner@example.com', user_metadata: {} },
  };
}

test('V443 the profile menu renders the Switch control by calling the real businessWorkspaceSwitchHtml, once, with the header\'s own staff list and slug', () => {
  const S = fixtureS();
  const { html, switchCalls } = renderProfileMenu(S);

  assert.equal(switchCalls.length, 1, 'businessWorkspaceSwitchHtml must be invoked exactly once');
  const [staffArg, slugArg, hasCustomerPersonaArg] = switchCalls[0];
  assert.equal(staffArg, S.staffWorkspaces, 'must be called with the SAME staffWorkspaces reference the header used — the "complete stable list"');
  assert.equal(slugArg, S.biz.slug);
  /* V443: the menu already has its own dedicated Customer view row (pmWallet). Passing the real
     S.hasCustomerPersona through here would make the shared function render a SECOND "Customer
     view" destination inside its own dropdown — a duplicate door to the same place. */
  assert.equal(hasCustomerPersonaArg, false, 'hasCustomerPersona must be forced false to avoid a duplicate Customer view entry');

  assert.match(html, /class="business-workspace-switch"/, 'the real switch details/summary markup must be present');
  assert.match(html, /href="#\/workspace\/qa-kopi-lab\/dashboard"/);
  assert.match(html, /href="#\/workspace\/qa-kaya-toast\/dashboard"/);
  assert.doesNotMatch(html, /href="#\/workspace\/kaya-toast\/dashboard"/, 'the current workspace must not list itself as a switch destination');

  const walletHrefCount = (html.match(/href="#\/wallet"/g) || []).length;
  assert.equal(walletHrefCount, 1, 'exactly one Customer view / wallet link — the existing pmWallet row, not a second one from the switch dropdown');

  const nameIndex = html.indexOf('Kaya Toast HQ');
  const switchIndex = html.indexOf('class="business-workspace-switch"');
  const signedInIndex = html.indexOf('Signed in as');
  assert.ok(nameIndex >= 0 && switchIndex > nameIndex, 'the Switch control must render within/after the workspace name');
  assert.ok(signedInIndex > switchIndex, 'the Switch control must stay inside the TOP workspace section, before "Signed in as"');
});

test('V443 a single-workspace owner with no customer persona sees no Switch control at all', () => {
  const S = fixtureS({ hasCustomerPersona: false });
  S.staffWorkspaces = [{ business_name: 'Kaya Toast HQ', business_slug: 'kaya-toast' }];
  const { html, switchCalls } = renderProfileMenu(S);
  assert.equal(switchCalls.length, 1);
  assert.equal(switchCalls[0][2], false);
  assert.doesNotMatch(html, /business-workspace-switch/, 'nothing to switch to means no control, same as the old header behaviour');
});

test('V443 the header appbar no longer references businessWorkspaceSwitchHtml at all', () => {
  assert.doesNotMatch(headerFragment, /businessWorkspaceSwitchHtml\(/);
  /* Matches the rendered control's own visible label (as businessWorkspaceSwitchHtml emits it),
     not the V443 explanatory comment left in the header source, which mentions the retired
     control by name on purpose. */
  assert.doesNotMatch(headerFragment, /<span>Switch workspace<\/span>/);

  /* Execute the extracted header template literal for real. businessWorkspaceSwitchHtml is
     deliberately NOT defined in this context: if a future edit reintroduces the call, evaluation
     throws ReferenceError and this test fails instead of silently passing a stale grep. */
  const context = {
    page: ['dashboard'],
    mobileWorkspaceTitleHtml: () => '<div data-stub="title"></div>',
    globalActionsHtml: () => '<div data-stub="global-actions"></div>',
    mobileSearchShellHtml: () => '<div data-stub="mobile-search"></div>',
    canReadModule: () => true,
    bookingRequestsBadgeWrapHtml: () => '<span data-stub="bookings-badge"></span>',
    bellHtml: () => '<div data-stub="bell"></div>',
    profileHtml: () => '<div data-stub="profile"></div>',
  };
  vm.createContext(context);
  const html = vm.runInContext('`' + headerFragment.replace(/\\/g, '\\\\').replace(/`/g, '\\`') + '`', context);

  assert.match(html, /<header class="appbar">/);
  assert.doesNotMatch(html, /business-workspace-switch/);
  assert.doesNotMatch(html, /<span>Switch workspace<\/span>/);
  assert.match(html, /data-stub="profile"/, 'profileHtml() — which now owns the switcher — is still rendered');
});

test('V443 the mobile "More" drawer does not carry its own copy of the switcher', () => {
  /* The narrow/iPad header hid .business-workspace-switch entirely via CSS
     (.appbar>.business-workspace-switch{display:none!important} under max-width:960px) rather
     than relocating it, so there is no second render site to move — this pins that staying true. */
  assert.doesNotMatch(staffMobileActionsHtmlSrc, /businessWorkspaceSwitchHtml/);
});
