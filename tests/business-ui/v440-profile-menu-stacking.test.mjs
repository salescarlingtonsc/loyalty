import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* V440 — confirmed live at 1180px (build 1039401): with the header profile-avatar menu open on
   the dashboard, the Performance card's heading, date range and "Minimise" button painted
   THROUGH the open menu. The menu hit-tested correctly (pointer events reached it) but its
   computed z-index was `auto` — every sibling popover hanging off the .appbar (the notification
   bell, the workspace switcher) already carried an explicit z-index; .profile .menu was the one
   omission. The fix in app/index.html gives it z-index:43, one above the workspace-switch menu
   it's about to gain as a nested child (a concurrent change moves that switcher inside this
   menu) and above every other sticky/fixed page-content layer in the app.

   These tests do not hand-copy the "40/41/42/43" numbers into assertions as a source-of-truth
   table — they parse the REAL <style> block out of app/index.html with a small brace-depth CSS
   walker, and execute the REAL profileHtml() render function (extracted from app/app.js and run
   in a vm sandbox) to prove the `.profile .menu` selector really targets the markup the account
   button opens. A hand-copied-values test would stay green even if someone silently reverted the
   fix and rewrote the comment; this one has to re-derive the numbers from source every run. */

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const appJs = readFileSync(resolve(root, 'app/app.js'), 'utf8');
const indexHtml = readFileSync(resolve(root, 'app/index.html'), 'utf8');

const section = (source, start, end) => {
  const from = source.indexOf(start), to = source.indexOf(end, from);
  assert.ok(from >= 0 && to > from, `missing section ${start}`);
  return source.slice(from, to);
};

/* ---- a tiny, real CSS-rule walker ----
   Parses the actual stylesheet text: tracks brace depth so @media/@supports wrappers are
   descended into (their contents are tagged with the condition, not silently flattened),
   while @keyframes/@font-face/@page bodies are skipped outright (their "selectors" are
   keyframe offsets like `50%`, not elements — matching them against an element selector
   would be a false positive). zIndexOf() returns the LAST declared z-index for an exact,
   non-media-scoped selector match — i.e. the value that actually applies at the 1180px
   viewport width the bug was measured at (nothing in this file changes these particular
   selectors' z-index inside a media query). */
function parseCssRules(cssText) {
  const text = cssText.replace(/\/\*[\s\S]*?\*\//g, '');
  const rules = [];
  let i = 0;
  const n = text.length;
  function walk(mediaCtx) {
    while (i < n) {
      while (i < n && /\s/.test(text[i])) i++;
      if (i >= n) return;
      if (text[i] === '}') { i++; return; }
      const headerStart = i;
      while (i < n && text[i] !== '{') {
        if (text[i] === '}') { i++; return; }
        i++;
      }
      const header = text.slice(headerStart, i).trim();
      i++; // consume '{'
      if (/^@media|^@supports/.test(header)) {
        walk(header);
      } else if (/^@(-webkit-)?keyframes|^@font-face|^@page/.test(header)) {
        let depth = 1;
        while (i < n && depth > 0) {
          if (text[i] === '{') depth++;
          else if (text[i] === '}') depth--;
          i++;
        }
      } else if (header) {
        const declStart = i;
        let depth = 1;
        while (i < n && depth > 0) {
          if (text[i] === '{') depth++;
          else if (text[i] === '}') depth--;
          if (depth > 0) i++;
        }
        const decl = text.slice(declStart, i);
        i++; // consume the closing '}'
        const selectors = header.split(',').map((s) => s.trim()).filter(Boolean);
        rules.push({ selectors, decl, media: mediaCtx });
      } else {
        i++;
      }
    }
  }
  walk(null);
  return rules;
}

const styleBlock = section(indexHtml, '<style>', '</style>');
const rules = parseCssRules(styleBlock);

function zIndexOf(selector) {
  let found;
  for (const rule of rules) {
    if (rule.media) continue; // only the base (non-media) cascade applies at desktop width
    if (!rule.selectors.includes(selector)) continue;
    const m = rule.decl.match(/z-index\s*:\s*(-?\d+)/);
    if (m) found = Number(m[1]);
  }
  return found;
}

test('sanity: the CSS walker actually parses — it finds values already documented in-file', () => {
  // this guards against the parser above silently matching nothing and every real test
  // below passing vacuously because zIndexOf() always returns undefined
  assert.equal(zIndexOf('.appbar'), 40);
  assert.equal(zIndexOf('.notif-menu'), 41);
  assert.equal(zIndexOf('.business-workspace-switch .menu'), 42);
  assert.equal(zIndexOf('.customer-workspace-switch .menu'), 42);
  assert.equal(zIndexOf('.day-timeline-head'), 8);
  assert.equal(zIndexOf('.calendar-week-head'), 4);
  assert.equal(zIndexOf('.modal'), 210);
});

test('V440: the profile/account menu declares an explicit z-index, not auto', () => {
  const menuZ = zIndexOf('.profile .menu');
  assert.equal(typeof menuZ, 'number', '.profile .menu must set a real z-index — the bug was it had none (computed: auto)');
});

test('V440: the menu outranks the rest of the .appbar popover family it belongs to', () => {
  const menuZ = zIndexOf('.profile .menu');
  assert.ok(menuZ > zIndexOf('.appbar'), 'the menu must outrank its own sticky host bar');
  assert.ok(menuZ > zIndexOf('.notif-menu'), 'the menu must outrank the notification-bell popover');
  assert.ok(menuZ > zIndexOf('.business-workspace-switch .menu'),
    'the menu must outrank the workspace switcher — which a concurrent change nests inside it');
  assert.ok(menuZ > zIndexOf('.customer-workspace-switch .menu'));
});

test('V440: the menu decisively outranks the sticky/fixed page-content layers in the audit', () => {
  const menuZ = zIndexOf('.profile .menu');
  // representative sticky/fixed page-content selectors pulled from the audit (see report) —
  // anything that could plausibly be visible behind an open header popover on the SAME
  // business/staff surface .profile .menu opens on. (.customer-primary-nav is deliberately
  // excluded: it is the customer-wallet bottom nav, a different app surface that never
  // coexists on screen with the staff/business .appbar, and its cascaded z-index — 70, from
  // the last of three same-specificity redeclarations in this file — intentionally sits in
  // the app-chrome tier alongside modals/toasts, not the page-content tier.)
  const pageContentSelectors = [
    '.day-timeline-head', '.day-team-head', '.day-time-axis', '.calendar-week-head',
    '.day-now-line', '.day-timeline-event', '.reward-auto-actions', '.till-sticky-cart-v373',
  ];
  for (const selector of pageContentSelectors) {
    const contentZ = zIndexOf(selector);
    assert.equal(typeof contentZ, 'number', `expected ${selector} to still declare an explicit z-index (audit drift?)`);
    assert.ok(menuZ > contentZ, `.profile .menu (z:${menuZ}) must outrank ${selector} (z:${contentZ})`);
  }
});

test('V440: profileHtml() really renders <div class="menu"> nested inside <div class="profile">', () => {
  // executes the REAL render function (extracted, not hand-transcribed) so the CSS selector
  // above is proven to target the actual account-menu markup, not a same-named coincidence
  const source = section(appJs, 'function profileHtml(){', 'function wireProfile(page){');
  const sandbox = {
    S: {
      biz: { name: 'Kopi Corner', industry: 'cafe' },
      user: { id: 'u1', email: 'owner@example.com' },
      hasCustomerPersona: false, myRole: 'owner', isSA: false,
    },
    INDUSTRIES: { cafe: { label: 'Cafe' } },
    BRAND: { customerLabel: 'Wallet' },
    CUI: { icon: (name) => `<svg data-icon="${name}"></svg>` },
    esc: (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])),
    profileOpen: true,
    userDisplayNameV158: () => 'Chuan Seng',
    profileBranchScopeLabelV158: () => 'All branches',
    workspaceLanguagePickerV97: () => '<select id="workspaceLanguageV97"></select>',
    workspaceTemplateAttributeV97: (attr) => `${attr}="Account menu"`,
    /* V443 moved the workspace switcher inside profileHtml(); its own rendering is covered by
       tests/business-ui/v443-switch-workspace-in-menu.test.mjs — here it only needs to exist. */
    businessWorkspaceSwitchHtml: () => '<div class="business-workspace-switch"></div>',
  };
  const html = vm.runInNewContext(`${source}\nprofileHtml();`, sandbox);
  assert.match(html, /^<div class="profile" id="profwrap">/);
  assert.match(html, /<div class="menu" id="profmenu"[^>]*>/);
  const wrapperIndex = html.indexOf('id="profwrap"');
  const menuIndex = html.indexOf('id="profmenu"');
  assert.ok(wrapperIndex >= 0 && menuIndex > wrapperIndex,
    'the menu element must be nested inside the profile wrapper for `.profile .menu` to apply to it');
  assert.match(html, /Sign out/, 'this is the same menu the bug report identified (contains Sign out)');
});
