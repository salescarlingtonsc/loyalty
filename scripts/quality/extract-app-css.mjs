/* nestly_v527 — the shipped app document stops carrying its own stylesheet.
 *
 * THE MEASUREMENT (26 Aug 2026, live site, mobile Chrome). app/index.html is 512,382 bytes and
 * 98% of it is one inline <style> block. The document is served `cache-control: max-age=0,
 * must-revalidate`, so those bytes cross the wire on EVERY visit — 135 KB compressed — and the
 * browser cannot paint until all of it has parsed. The app's own code did not begin downloading
 * until 982 ms; first contentful paint landed at 3,052 ms. The server answered in 583 ms, so the
 * server was never the problem.
 *
 * The JavaScript beside it is already right: split-app-bundle writes the surface chunks,
 * stamp-app-bundle fingerprints them, and the CDN serves them `immutable`. They are downloaded
 * once and are free forever after. The stylesheet gets none of that purely because of where it
 * sits.
 *
 * WHY THE SOURCE FILE DOES NOT MOVE. 175 test files read CSS out of app/index.html, and every
 * visual-evidence fixture embeds it. Rewriting the source would put all of that in one sweep —
 * the largest possible blast radius for a change whose entire purpose is caching. So this follows
 * the pattern app.js already established: the SOURCE stays where it is and a GENERATED artifact
 * is committed beside it.
 *
 *   app/index.html      source of truth. Unchanged. Keeps every comment. Every test still reads it.
 *   app/app.css         generated: the same rules, comments removed.
 *   app/index.gen.html  generated: the same document, <style> swapped for a fingerprinted <link>.
 *
 * app/vercel.json points /app, /business and /admin at index.gen.html, so index.html is the thing
 * we edit and index.gen.html is the thing customers download.
 *
 * WHY THE COMMENTS COME OUT. 141 KB of the 504 KB stylesheet — 28% — is explanatory prose. It is
 * the record of why each rule exists and it is worth keeping; it is not worth sending to a phone.
 * Measured: 126.8 KB → 62.5 KB compressed, a 64 KB saving on every visit. A CSS comment cannot
 * affect rendering, so this cannot change how anything looks.
 *
 * RUN ORDER MATTERS. This reads the ALREADY-STAMPED index.html, so index.gen.html inherits the
 * JS chunk fingerprints:  split-app-bundle → stamp-app-bundle → extract-app-css.
 *
 * nestly_v530 — AND THE SKELETON NO LONGER WAITS FOR THE WHOLE STYLESHEET.
 *
 * After v527 the document was 8 KB, but first paint still landed at ~556 ms because a
 * <link rel="stylesheet"> in the head is RENDER-BLOCKING: the browser draws nothing at all until
 * it has the entire 62 KB. Measured in Chrome across four variants, throttled to 900 kbps:
 *
 *   control (link in head)                      never painted before the sheet arrived
 *   inline critical CSS + link still in head    never painted before the sheet arrived
 *   inline critical CSS + link at end of body   first paint 532 ms
 *   inline critical CSS + media=print swap      first paint 356 ms
 *
 * Inlining critical CSS on its own does NOTHING — that is the finding that decided the design.
 * The blocking link has to move as well.
 *
 * END OF BODY was chosen over the media swap even though it is slower, because it keeps the
 * browser's own guarantee: a stylesheet still blocks rendering of everything AFTER it, so the
 * real app UI — which the router paints into #root long after boot — can never appear unstyled.
 * The media=print trick makes the sheet fully non-blocking and puts that guarantee in the hands
 * of a race between a 62 KB stylesheet and 1.5 MB of JavaScript. It also needs an inline event
 * handler, which only works because script-src still allows 'unsafe-inline'.
 *
 * THE CRITICAL SET IS DERIVED, NOT HAND-WRITTEN. A rule is kept only if EVERY compound in its
 * selector corresponds to something the boot skeleton's DOM actually contains (see
 * SKELETON_TOKENS). The test renders the skeleton twice — once under the full stylesheet, once
 * under the critical subset — and compares every computed property of every element. It is
 * currently 9,955 bytes raw / 3.2 KB gzipped, and the diff is zero.
 *
 * The kept rules therefore appear TWICE: inline, and again in app.css. They are byte-identical
 * and app.css comes later in document order, so it wins every tie with the same value. No
 * conflict is possible, and the equivalence test is what proves it stays that way.
 *
 * Usage: node scripts/quality/extract-app-css.mjs [--check|--write]
 */
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const repoRoot = new URL('../../', import.meta.url);
export const sourceHtmlPath = new URL('app/index.html', repoRoot);
export const generatedCssPath = new URL('app/app.css', repoRoot);
export const generatedHtmlPath = new URL('app/index.gen.html', repoRoot);
/* nestly_v533: pwa.css is the OTHER render-blocking stylesheet in the head. It is small (3.4 KB)
   but it is a separate round trip, and after v530 the first paint tracked its completion almost
   exactly — 392->476, 328->376, 374->420 on production. It is not fingerprinted and it is not
   generated, so it is read here purely to derive its own critical subset. */
export const pwaCssPath = new URL('app/pwa.css', repoRoot);

/* Every tag, class and id the boot skeleton's DOM contains. A rule can only match that DOM if
   EVERY compound in its descendant chain corresponds to something here — the test is per-token,
   not a substring search. `.customer-expiring-list a` is excluded because that class is not in
   the skeleton; a bare `a { }` is kept because `a` is (the skip link). */
export const SKELETON_TOKENS = new Set([
  '*', ':root', 'html', 'body',
  'a', 'div', 'p', 'span',
  '.skip-link', '.sr-only',
  '.wallet-shell', '.customer-surface', '.wallet-inner',
  '.card', '.pf-skeleton', '.toast',
  '#root', '#toast', '#appStatus', '#appAlert'
]);

/* Top-level blocks with their braces intact, string-aware so a `{` inside content:"" cannot
   throw the depth count off. */
function splitTopLevel(css) {
  const out = []; let depth = 0, start = 0, inString = null;
  for (let i = 0; i < css.length; i += 1) {
    const c = css[i];
    if (inString) { if (c === inString && css[i - 1] !== '\\') inString = null; continue; }
    if (c === '"' || c === "'") { inString = c; continue; }
    if (c === '{') depth += 1;
    else if (c === '}') { depth -= 1; if (depth === 0) { out.push(css.slice(start, i + 1)); start = i + 1; } }
    else if (depth === 0 && c === ';') { out.push(css.slice(start, i + 1)); start = i + 1; }
  }
  return out.map((block) => block.trim()).filter(Boolean);
}

/* The "key" of a compound: its tag if it has one, else its first class or id.
   `.card[aria-busy]:hover` -> `.card`; `div.wallet-inner` -> `div`; `::before` -> ''. */
export function compoundKey(compound) {
  /* :root is checked BEFORE the pseudo-strip, which would otherwise erase it and leave the empty
     "matches anything" key. The rules that define the design tokens hang off it, so it needs to
     name itself rather than be waved through. */
  if (compound.startsWith(':root')) return ':root';
  const bare = compound.replace(/::?[a-z-]+(\([^)]*\))?/gi, '').trim();
  if (!bare) return '';
  const tag = bare.match(/^[a-zA-Z][\w-]*/);
  if (tag) return tag[0].toLowerCase();
  const first = bare.match(/^[.#][\w-]+/);
  return first ? first[0] : bare;
}

export function selectorCanMatchSkeleton(selectorText) {
  return selectorText.split(',').some((part) => {
    const compounds = part.trim().split(/[\s>+~]+/).filter(Boolean);
    if (!compounds.length) return false;
    return compounds.every((compound) => {
      const key = compoundKey(compound);
      return key === '' || SKELETON_TOKENS.has(key);
    });
  });
}

export function criticalCssFor(css) {
  const kept = [];
  for (const block of splitTopLevel(css)) {
    const at = block.match(/^@([a-z-]+)/i);
    if (at) {
      const name = at[1].toLowerCase();
      if (name === 'media' || name === 'supports') {
        const open = block.indexOf('{');
        const inner = criticalCssFor(block.slice(open + 1, block.lastIndexOf('}')));
        if (inner.trim()) kept.push(`${block.slice(0, open + 1)}${inner}}`);
      } else if (['keyframes', 'font-face', 'property', 'charset', 'import', 'layer'].includes(name)) {
        /* Scaffolding. The skeleton's shimmer is an animation, so dropping @keyframes would leave
           it visibly static — and these are cheap. */
        kept.push(block);
      }
      continue;
    }
    const open = block.indexOf('{');
    if (open < 0) continue;
    if (selectorCanMatchSkeleton(block.slice(0, open))) kept.push(block);
  }
  return kept.join('\n');
}

const STYLE_BLOCK = /<style(?![^>]*\bdata-keep-inline\b)[^>]*>([\s\S]*?)<\/style>/g;

export function fingerprint(text) {
  return createHash('sha256').update(text, 'utf8').digest('hex').slice(0, 12);
}

/* Comments only. Deliberately NOT a minifier: whitespace and ordering are left exactly as
   authored so a diff of app.css against the source block stays readable, and so a future
   selector bug can never be blamed on this step. */
export function stripCssComments(css) {
  return css
    .replace(/\/\*[\s\S]*?\*\//g, '')
    // A comment that occupied its own line leaves an empty line behind; collapse runs of them.
    .replace(/\n[ \t]*(?=\n)/g, '')
    .replace(/\n{3,}/g, '\n\n');
}

export const PWA_LINK = '<link rel="stylesheet" href="/pwa.css">';

export function buildArtifacts(sourceHtml, pwaCss = '') {
  const blocks = [...sourceHtml.matchAll(STYLE_BLOCK)];
  if (!blocks.length) {
    throw new Error('extract-app-css: app/index.html has no <style> block to extract');
  }
  const css = stripCssComments(blocks.map((match) => match[1]).join('\n'));
  const hash = fingerprint(css);

  /* nestly_v533: both head stylesheets contribute. Order mirrors the real cascade — pwa.css sat
     first, app.css second, so app.css wins every tie. Keeping that order inside the inline block
     means the critical styles resolve exactly as the full sheets will when they land. */
  const critical = [criticalCssFor(pwaCss), criticalCssFor(css)].filter(Boolean).join('\n');
  if (!critical.includes('.pf-skeleton')) {
    throw new Error('extract-app-css: the critical set does not style the boot skeleton');
  }

  const head = `<style id="criticalCssV530">${critical}</style>`
    + '<link rel="preload" as="style" href="/pwa.css">'
    + `<link rel="preload" as="style" href="/app.css?b=${hash}">`;
  /* End of body: both are still real render-blocking stylesheets, so nothing after them — which
     is all of the app UI — can ever paint unstyled. pwa.css keeps its place ahead of app.css. */
  const sheets = `${PWA_LINK}<link rel="stylesheet" href="/app.css?b=${hash}">`;

  let replaced = 0;
  let html = sourceHtml.replace(STYLE_BLOCK, () => (replaced++ === 0 ? head : ''));
  if (!html.includes(PWA_LINK)) {
    throw new Error('extract-app-css: app/index.html no longer links /pwa.css where expected');
  }
  html = html.replace(PWA_LINK, '');          // out of the head
  if (!html.includes('</body>')) {
    throw new Error('extract-app-css: app/index.html has no </body> to place the stylesheets before');
  }
  html = html.replace('</body>', `${sheets}\n</body>`);

  return { css, critical, html, hash, blockCount: blocks.length };
}

export async function readArtifacts() {
  const [sourceHtml, pwaCss] = await Promise.all([
    readFile(sourceHtmlPath, 'utf8'),
    readFile(pwaCssPath, 'utf8')
  ]);
  return { sourceHtml, pwaCss, ...buildArtifacts(sourceHtml, pwaCss) };
}

async function readOrNull(url) {
  try {
    return await readFile(url, 'utf8');
  } catch {
    return null;
  }
}

export async function checkArtifacts() {
  const { css, html, hash, blockCount, critical } = await readArtifacts();
  const [currentCss, currentHtml] = await Promise.all([
    readOrNull(generatedCssPath),
    readOrNull(generatedHtmlPath)
  ]);
  const stale = [];
  if (currentCss !== css) stale.push('app/app.css');
  if (currentHtml !== html) stale.push('app/index.gen.html');
  return { stale, hash, blockCount, cssBytes: css.length, htmlBytes: html.length,
    criticalBytes: critical.length };
}

async function main() {
  const option = process.argv[2] || '--check';
  if (!['--check', '--write'].includes(option)) {
    throw new Error('Usage: node scripts/quality/extract-app-css.mjs [--check|--write]');
  }
  const { css, html, hash, blockCount, critical } = await readArtifacts();
  const source = await readFile(sourceHtmlPath, 'utf8');

  if (option === '--write') {
    await writeFile(generatedCssPath, css, 'utf8');
    await writeFile(generatedHtmlPath, html, 'utf8');
    const saved = source.length - html.length;
    process.stdout.write(
      `app.css ${Math.round(css.length / 1024)}KB (b=${hash}) from ${blockCount} block(s) · `
      + `critical ${Math.round(critical.length / 1024)}KB inline · `
      + `index.gen.html ${Math.round(html.length / 1024)}KB, ${Math.round(saved / 1024)}KB lighter than the source\n`
    );
    return;
  }

  const { stale } = await checkArtifacts();
  if (stale.length) {
    throw new Error(
      `extract-app-css: ${stale.join(' and ')} ${stale.length > 1 ? 'are' : 'is'} stale. `
      + 'Run: node scripts/quality/extract-app-css.mjs --write'
    );
  }
  process.stdout.write(`Already current (app.css b=${hash})\n`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  await main();
}
