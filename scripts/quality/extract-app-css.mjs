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
 * Usage: node scripts/quality/extract-app-css.mjs [--check|--write]
 */
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const repoRoot = new URL('../../', import.meta.url);
export const sourceHtmlPath = new URL('app/index.html', repoRoot);
export const generatedCssPath = new URL('app/app.css', repoRoot);
export const generatedHtmlPath = new URL('app/index.gen.html', repoRoot);

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

export function buildArtifacts(sourceHtml) {
  const blocks = [...sourceHtml.matchAll(STYLE_BLOCK)];
  if (!blocks.length) {
    throw new Error('extract-app-css: app/index.html has no <style> block to extract');
  }
  const css = stripCssComments(blocks.map((match) => match[1]).join('\n'));
  const hash = fingerprint(css);
  const link = `<link rel="stylesheet" href="/app.css?b=${hash}">`;

  /* The FIRST style block becomes the link; the rest are removed. Their order is preserved inside
     app.css, so the cascade is byte-identical to what the source produced. */
  let replaced = 0;
  const html = sourceHtml.replace(STYLE_BLOCK, () => (replaced++ === 0 ? link : ''));

  return { css, html, hash, blockCount: blocks.length };
}

export async function readArtifacts() {
  const sourceHtml = await readFile(sourceHtmlPath, 'utf8');
  return { sourceHtml, ...buildArtifacts(sourceHtml) };
}

async function readOrNull(url) {
  try {
    return await readFile(url, 'utf8');
  } catch {
    return null;
  }
}

export async function checkArtifacts() {
  const { css, html, hash, blockCount } = await readArtifacts();
  const [currentCss, currentHtml] = await Promise.all([
    readOrNull(generatedCssPath),
    readOrNull(generatedHtmlPath)
  ]);
  const stale = [];
  if (currentCss !== css) stale.push('app/app.css');
  if (currentHtml !== html) stale.push('app/index.gen.html');
  return { stale, hash, blockCount, cssBytes: css.length, htmlBytes: html.length };
}

async function main() {
  const option = process.argv[2] || '--check';
  if (!['--check', '--write'].includes(option)) {
    throw new Error('Usage: node scripts/quality/extract-app-css.mjs [--check|--write]');
  }
  const { css, html, hash, blockCount } = await readArtifacts();
  const source = await readFile(sourceHtmlPath, 'utf8');

  if (option === '--write') {
    await writeFile(generatedCssPath, css, 'utf8');
    await writeFile(generatedHtmlPath, html, 'utf8');
    const saved = source.length - html.length;
    process.stdout.write(
      `app.css ${Math.round(css.length / 1024)}KB (b=${hash}) from ${blockCount} block(s) · `
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
