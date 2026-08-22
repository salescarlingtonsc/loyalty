import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* V450 — the owner reported dashboard content showing through the open account menu. V440 answered
   the wrong half of that: it fixed the PAINT ORDER (z-index 43, above the whole .appbar popover
   family) and was verified by hit-testing, which passed — pointer events did reach the menu. The
   symptom the owner actually saw survived, because the menu was still translucent: measured live on
   production build dcb6a533d42f, `.profile .menu` was rgba(255,255,255,.86) over a backdrop blur,
   with "Open calendar", "Apply", "Minimise" and "INACTIVE CUSTOMERS" sitting geometrically behind
   it — and "Minimise" rendered legibly across the menu's own "Settings" row.

   Two things make that a defect rather than a taste call. First, it is the LEAST opaque popover in
   its own family (its sibling .business-workspace-switch .menu was already .94) while being the one
   that opens over live figures. Second, text that reads through a menu is text a user can mistake
   for a menu item.

   These tests re-derive the values from the real <style> block rather than restating them, so a
   silent revert fails here. They assert the RELATIONSHIP (this menu is at least as opaque as every
   sibling popover) instead of pinning one magic number, so a future redesign of the family stays
   free to move — as long as it never leaves this menu the see-through one again. */

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const indexHtml = readFileSync(resolve(root, 'app/index.html'), 'utf8');

const section = (source, start, end) => {
  const from = source.indexOf(start), to = source.indexOf(end, from);
  assert.ok(from >= 0 && to > from, `missing section ${start}`);
  return source.slice(from, to);
};

/* Same brace-depth walker as v440: descend @media/@supports (tagging the condition), skip
   @keyframes/@font-face/@page whose "selectors" are offsets, never flatten. */
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
      i++;
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
        i++;
        rules.push({ selectors: header.split(',').map((s) => s.trim()).filter(Boolean), decl, media: mediaCtx });
      } else {
        i++;
      }
    }
  }
  walk(null);
  return rules;
}

const rules = parseCssRules(section(indexHtml, '<style>', '</style>'));

/* last base-cascade `background` declared for an exact selector — the one that applies at the
   desktop width the bug was measured at */
function backgroundOf(selector) {
  let found;
  for (const rule of rules) {
    if (rule.media) continue;
    if (!rule.selectors.includes(selector)) continue;
    const m = rule.decl.match(/(?:^|[;{\s])background\s*:\s*([^;}]+)/);
    if (m) found = m[1].trim();
  }
  return found;
}

/* alpha of a background value. Custom properties resolve to their :root value; a token that is
   itself opaque (a hex or a nested opaque var) counts as 1. */
function alphaOf(value, depth = 0) {
  assert.ok(depth < 5, `custom property nesting too deep to resolve: ${value}`);
  if (!value) return null;
  const v = value.trim();
  const rgba = v.match(/rgba?\(([^)]+)\)/);
  if (rgba) {
    const parts = rgba[1].split(/[,/]/).map((s) => s.trim()).filter(Boolean);
    return parts.length >= 4 ? Number(parts[3]) : 1;
  }
  if (/^#[0-9a-f]{3,4}$/i.test(v) || /^#[0-9a-f]{6}$/i.test(v)) return 1;
  if (/^#[0-9a-f]{8}$/i.test(v)) return parseInt(v.slice(7, 9), 16) / 255;
  const varMatch = v.match(/^var\(\s*(--[\w-]+)\s*(?:,\s*([^)]+))?\)$/);
  if (varMatch) {
    const [, name, fallback] = varMatch;
    const decl = new RegExp(`${name}\\s*:\\s*([^;}]+)`).exec(indexHtml);
    if (decl) return alphaOf(decl[1], depth + 1);
    if (fallback) return alphaOf(fallback, depth + 1);
    return null;
  }
  if (/^(white|#fff)$/i.test(v)) return 1;
  return null;
}

/* the popovers that hang off the appbar and can open over page content */
const SIBLING_POPOVERS = ['.business-workspace-switch .menu', '.customer-workspace-switch .menu', '.notif-menu'];

test('sanity: the walker and the alpha resolver actually work', () => {
  // guards against every assertion below passing vacuously on an undefined/unparsed value
  assert.equal(alphaOf('rgba(255, 255, 255, .86)'), 0.86);
  assert.equal(alphaOf('#FFFFFF'), 1);
  assert.equal(alphaOf('rgba(0,0,0,0)'), 0);
  const switcher = backgroundOf('.business-workspace-switch .menu');
  assert.ok(switcher, 'walker found no background for the workspace-switch menu — parser is broken');
  assert.ok(alphaOf(switcher) !== null, `could not resolve alpha of ${switcher}`);
});

test('V450: the account menu is fully opaque — page content cannot read through it', () => {
  const bg = backgroundOf('.profile .menu');
  assert.ok(bg, '.profile .menu declares no background at all');
  const alpha = alphaOf(bg);
  assert.ok(alpha !== null, `could not resolve the alpha of ${bg}`);
  assert.equal(alpha, 1, `.profile .menu resolves to ${bg} (alpha ${alpha}); dashboard text reads through anything below 1`);
});

test('V450: the account menu is never the see-through one in its own popover family', () => {
  const mine = alphaOf(backgroundOf('.profile .menu'));
  const measured = [];
  for (const sel of SIBLING_POPOVERS) {
    const bg = backgroundOf(sel);
    if (!bg) continue; // a sibling may legitimately not declare its own background
    const a = alphaOf(bg);
    if (a === null) continue;
    measured.push([sel, a]);
    assert.ok(mine >= a, `.profile .menu (alpha ${mine}) is more transparent than ${sel} (alpha ${a}) — it opens over the busiest surface, so it must be at least as opaque`);
  }
  assert.ok(measured.length > 0, 'no sibling popover backgrounds were resolved — this test would pass vacuously');
});

test('V450: every appbar popover that opens over page content is opaque', () => {
  /* .notif-menu carried the identical rgba(255,255,255,.86) and opens over the same dashboard
     figures — it stayed unreported only because it needs unread notifications to open. Fixing the
     class rather than the one reported instance is the point; this test pins the whole family. */
  const family = ['.profile .menu', '.notif-menu', ...SIBLING_POPOVERS];
  const checked = [];
  for (const sel of family) {
    const bg = backgroundOf(sel);
    if (!bg) continue;
    const a = alphaOf(bg);
    if (a === null) continue;
    checked.push(sel);
    assert.equal(a, 1, `${sel} resolves to ${bg} (alpha ${a}) — content behind it reads through`);
  }
  assert.ok(checked.length >= 2, `only ${checked.length} popover backgrounds resolved — test would be near-vacuous`);
});

test('V450: the menu keeps a real background token, not a hardcoded colour that ignores dark mode', () => {
  const bg = backgroundOf('.profile .menu');
  assert.match(bg, /var\(--/, `.profile .menu background is "${bg}" — it must come from a theme token so the dark palette applies`);
});

test('V450 does not undo V440: the menu keeps its explicit paint order above the appbar family', () => {
  // the two fixes answer different halves of the same report; neither may silently replace the other
  let z;
  for (const rule of rules) {
    if (rule.media || !rule.selectors.includes('.profile .menu')) continue;
    const m = rule.decl.match(/z-index\s*:\s*(-?\d+)/);
    if (m) z = Number(m[1]);
  }
  assert.equal(z, 43, '.profile .menu lost the V440 z-index');
});
