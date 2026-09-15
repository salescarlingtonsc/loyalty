/* nestly_v940 — the real named-template runtime, for harnesses that execute one render function.
 *
 * WHY THIS EXISTS. A growing number of render functions carry a sentence that mixes reviewed
 * English with a runtime value. Such a sentence renders as ONE text node, so the flat catalogue —
 * which keys on whole nodes — can never reach it, and it stays English for a zh-CN or ms reader
 * however complete that catalogue becomes. The fix is workspaceTemplateHtmlV97, a named template
 * held in WORKSPACE_TEMPLATE_COPY_V97 in all three locales.
 *
 * Several tests slice a single render function out of app.js and run it in a vm. Those harnesses
 * build their own sandbox, so a renderer that starts calling the template helper fails with a bare
 * ReferenceError — a failure about the harness, not about the code under test.
 *
 * This module pulls the REAL implementation out of app.js and hands it back for the sandbox, the
 * same "execute the real thing, never a stub" posture those harnesses already take with helpers
 * like ciFreshnessCaptionHtmlV734. A stub here would be worse than useless: it would let a
 * template with a missing key, an unbalanced placeholder or a dropped value pass a test that
 * claims to render the production markup.
 */
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

function slice(from, to) {
  const start = app.indexOf(from);
  if (start < 0) throw new Error(`workspace template runtime: missing ${from}`);
  const end = app.indexOf(to, start + from.length);
  if (end <= start) throw new Error(`workspace template runtime: missing ${to}`);
  return app.slice(start, end);
}

const SOURCE = [
  slice('const WORKSPACE_TEMPLATE_COPY_V97=', 'const WORKSPACE_INTERPOLATED_UI_INVENTORY_V97='),
  slice('const workspaceTemplateTextV97=', 'const WORKSPACE_TEMPLATE_ATTRIBUTES_V97='),
  slice('const workspaceTemplateInnerHtmlV97=', 'function localizeWorkspaceTemplateV97('),
].join('\n');

/* The one escaper every render path in app.js shares. Harnesses define their own `esc` for the
   function under test; the template runtime needs one too, and it must be the same one. */
const ESC = (value) => String(value ?? '')
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;').replace(/'/g, '&#39;');

/**
 * Build the named-template helpers, ready to spread into a vm sandbox.
 * @param {string} locale which locale the renderer should produce ('en' by default, as a harness
 *   asserting English markup expects; pass 'zh-CN' or 'ms' to assert a localized render).
 */
export function workspaceTemplateRuntime(locale = 'en') {
  const context = vm.createContext({ esc: ESC, workspaceLocale: locale });
  /* These are `const` declarations, which land in the script's lexical scope rather than on the
     context object, so they have to be handed out explicitly. */
  vm.runInContext(SOURCE + `
    __runtime={WORKSPACE_TEMPLATE_COPY_V97,workspaceTemplateTextV97,
      workspaceTemplateInnerHtmlV97,workspaceTemplateHtmlV97};`, context);
  return { workspaceLocale: locale, ...context.__runtime };
}
