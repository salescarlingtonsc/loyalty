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

export function stampDocument(document, chunks) {
  const urls = chunkUrls(chunks);
  if (!CORE_TAG.test(document)) throw new Error(`${DOCUMENT} does not contain the /app-core.js script tag`);
  if (!MANIFEST_BLOCK.test(document)) throw new Error(`${DOCUMENT} does not contain the #appSurfaceChunks manifest`);
  const manifest = JSON.stringify({
    auth: urls.auth,
    customer: urls.customer,
    business: urls.business,
    i18n: urls.i18n
  });
  return document
    .replace(CORE_TAG, `<script src="${urls.core}" defer></script>`)
    .replace(MANIFEST_BLOCK, `<script type="application/json" id="appSurfaceChunks">\n${manifest}\n</script>`);
}

export async function build(root = repoRoot) {
  const source = await readFile(path.join(root, 'app/app.js'), 'utf8');
  const chunks = renderChunks(source);
  const document = await readFile(path.join(root, DOCUMENT), 'utf8');
  return { chunks, document, stamped: stampDocument(document, chunks) };
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
