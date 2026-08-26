#!/usr/bin/env node
/**
 * Build the surface bundles from app/app.js and stamp app/index.html with their fingerprints.
 *
 *   npm run bundle-stamp          # after ANY edit to app/app.js
 *   npm run bundle-stamp:check    # enforced by the test suite and npm run validate
 *
 * Two things happen here, and both must stay in step with app/app.js:
 *
 * 1. app/app.js is partitioned by surface (see split-app-bundle.mjs). index.html loads only the
 *    shared core; the customer and workspace chunks arrive on demand, and the translation tables
 *    only for a non-English locale.
 * 2. Every url carries a fingerprint of that chunk's own bytes. peekaa.asia is fronted by
 *    Cloudflare, whose Browser Cache TTL rewrites the browser-facing max-age no matter what the
 *    origin sends, so a stable url would let a visitor run the previous deploy's code against the
 *    new index.html. A changed chunk is a new url; an unchanged one stays cached.
 */
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { OUTPUTS, renderChunks } from './split-app-bundle.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const DOCUMENT = 'app/index.html';
const CORE_TAG = /<script src="\/app-core\.js(?:\?b=[0-9a-f]{12})?" defer><\/script>/;
const MANIFEST_BLOCK = /<script type="application\/json" id="appSurfaceChunks">\n[\s\S]*?\n<\/script>/;
/* nestly_v529: app-core.js is the biggest thing on the critical path and, being a <script defer>
   in the BODY, its bytes were not requested until everything above it had finished — 1,013 ms in
   on production. A head preload starts it with the first wave instead. It carries the SAME
   fingerprinted URL as the tag, which is why the stamper owns both: a preload one fingerprint
   behind the tag would fetch 178 KB twice and be slower than having none. */
/* nestly_v535: THE CUSTOMER CHUNK'S HINT. Profiled on production: app-customer.js (189 KB) was
   not requested until 677 ms, because route() awaits sb.auth.getSession() before it decides which
   surface to load — so the biggest file on the customer critical path waited for app-core to
   download (295->577), execute, and resolve a session.
   It does not have to. appSurfaceForRouteV185 returns 'customer' for the bare root and for every
   customer prefix WITHOUT consulting the session at all; only the remaining routes need it. So
   for exactly those hashes the answer is knowable from the head, and this hint starts the
   download with the first wave instead of after it.
   The prefix list is READ OUT OF app.js by this stamper rather than retyped, so the hint cannot
   drift from the router and start preloading 189 KB on a workspace route. */
const CUSTOMER_PREFIXES = /const CUSTOMER_ROUTE_PREFIXES_V185=(\[[^\]]*\]);/;
const SURFACE_HINT = /<script id="surfaceHintV535">[\s\S]*?<\/script>/;
const CORE_PRELOAD = /<link rel="preload" as="script" href="\/app-core\.js(?:\?b=[0-9a-f]{12})?">/;

export function fingerprint(text) {
  return createHash('sha256').update(text).digest('hex').slice(0, 12);
}

export function chunkUrls(chunks) {
  const urls = {};
  for (const [surface, target] of Object.entries(OUTPUTS)) {
    urls[surface] = `/${path.basename(target)}?b=${fingerprint(chunks[surface])}`;
  }
  return urls;
}

export function surfaceHint(customerUrl, prefixes) {
  /* Deliberately tiny and dependency-free: it runs while the head is still parsing, before any
     application code exists. It only ever ADDS a preload — it never changes which chunk the
     router later loads, so a wrong answer here costs bandwidth, never correctness. */
  const list = JSON.stringify(prefixes);
  return '<script id="surfaceHintV535">'
    + `(function(){var h=(location.hash||'').split('?')[0];var p=${list};`
    + "if(h===''||h==='#/'||p.some(function(x){return h===x.replace(/\\/$/,'')||h.indexOf(x)===0})){"
    + `var l=document.createElement('link');l.rel='preload';l.as='script';l.href=${JSON.stringify(customerUrl)};`
    + 'document.head.appendChild(l);}})();</script>';
}

export function stampDocument(document, chunks, appSource = '') {
  const urls = chunkUrls(chunks);
  if (!CORE_TAG.test(document)) throw new Error(`${DOCUMENT} does not contain the /app-core.js script tag`);
  if (!CORE_PRELOAD.test(document)) throw new Error(`${DOCUMENT} does not contain the /app-core.js preload link`);
  if (!MANIFEST_BLOCK.test(document)) throw new Error(`${DOCUMENT} does not contain the #appSurfaceChunks manifest`);
  const manifest = JSON.stringify({
    auth: urls.auth,
    customer: urls.customer,
    business: urls.business,
    i18n: urls.i18n
  });
  const prefixMatch = appSource.match(CUSTOMER_PREFIXES);
  if (appSource && !prefixMatch) {
    throw new Error('stamp-app-bundle: CUSTOMER_ROUTE_PREFIXES_V185 could not be read from app/app.js');
  }
  const prefixes = prefixMatch ? JSON.parse(prefixMatch[1].replace(/'/g, '"')) : [];
  if (!SURFACE_HINT.test(document)) {
    throw new Error(`${DOCUMENT} does not contain the #surfaceHintV535 script`);
  }

  return document
    .replace(SURFACE_HINT, surfaceHint(urls.customer, prefixes))
    .replace(CORE_PRELOAD, `<link rel="preload" as="script" href="${urls.core}">`)
    .replace(CORE_TAG, `<script src="${urls.core}" defer></script>`)
    .replace(MANIFEST_BLOCK, `<script type="application/json" id="appSurfaceChunks">\n${manifest}\n</script>`);
}

export async function build(root = repoRoot) {
  const source = await readFile(path.join(root, 'app/app.js'), 'utf8');
  const chunks = renderChunks(source);
  const document = await readFile(path.join(root, DOCUMENT), 'utf8');
  return { chunks, document, stamped: stampDocument(document, chunks, source) };
}

async function main() {
  const check = process.argv.includes('--check');
  const write = process.argv.includes('--write');
  if (check === write) throw new Error('Usage: node scripts/quality/stamp-app-bundle.mjs --write|--check');
  const { chunks, document, stamped } = await build();
  const stale = [];
  for (const [surface, target] of Object.entries(OUTPUTS)) {
    const current = await readFile(path.join(repoRoot, target), 'utf8').catch(() => null);
    if (current === chunks[surface]) continue;
    stale.push(target);
    if (write) await writeFile(path.join(repoRoot, target), chunks[surface]);
  }
  if (document !== stamped) {
    stale.push(DOCUMENT);
    if (write) await writeFile(path.join(repoRoot, DOCUMENT), stamped);
  }
  const sizes = Object.entries(chunks)
    .map(([surface, text]) => `${surface} ${(text.length / 1024).toFixed(0)}KB`).join(' · ');
  if (check) {
    if (stale.length) {
      console.error(`Stale: ${stale.join(', ')}`);
      console.error('Run: npm run bundle-stamp');
      process.exitCode = 1;
      return;
    }
    console.log(`Surface bundles and stamps are current (${sizes}).`);
    return;
  }
  console.log(stale.length ? `Rebuilt: ${stale.join(', ')} (${sizes})` : `Already current (${sizes})`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main();
}
