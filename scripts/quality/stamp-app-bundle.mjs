#!/usr/bin/env node
/**
 * Stamp app/index.html's <script src="/app.js"> with a fingerprint of the bundle's own bytes.
 *
 * Why this exists: peekaa.asia is fronted by Cloudflare, whose Browser Cache TTL rewrites the
 * browser-facing max-age on any cacheable asset regardless of what the origin sends — a deployed
 * `no-cache, must-revalidate` still arrived as `max-age=14400`. A returning visitor therefore ran
 * yesterday's application code against today's index.html for up to four hours. Cloudflare keys
 * its cache on the FULL url, so changing the query whenever the bytes change is the one lever we
 * hold without touching the Cloudflare dashboard.
 *
 *   node scripts/quality/stamp-app-bundle.mjs --write   # after any app/app.js edit
 *   node scripts/quality/stamp-app-bundle.mjs --check    # enforced by the test suite
 */
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const BUNDLE = 'app/app.js';
const DOCUMENT = 'app/index.html';
const TAG = /<script src="\/app\.js(?:\?b=[0-9a-f]{12})?" defer><\/script>/;

export function bundleFingerprint(bytes) {
  return createHash('sha256').update(bytes).digest('hex').slice(0, 12);
}

export function stampedTag(fingerprint) {
  return `<script src="/app.js?b=${fingerprint}" defer></script>`;
}

export async function stamp(root = repoRoot) {
  const bundle = await readFile(path.join(root, BUNDLE));
  const document = await readFile(path.join(root, DOCUMENT), 'utf8');
  const match = document.match(TAG);
  if (!match) throw new Error(`${DOCUMENT} does not contain the expected /app.js script tag`);
  const expected = stampedTag(bundleFingerprint(bundle));
  return { document, current: match[0], expected, next: document.replace(TAG, expected) };
}

async function main() {
  const check = process.argv.includes('--check');
  const write = process.argv.includes('--write');
  if (check === write) throw new Error('Usage: node scripts/quality/stamp-app-bundle.mjs --write|--check');
  const { current, expected, next } = await stamp();
  if (current === expected) {
    if (check) console.log(`app.js bundle stamp is current (${expected}).`);
    return;
  }
  if (check) {
    console.error(`app/index.html points at "${current}" but app/app.js hashes to "${expected}".`);
    console.error('Run: node scripts/quality/stamp-app-bundle.mjs --write');
    process.exitCode = 1;
    return;
  }
  await writeFile(path.join(repoRoot, DOCUMENT), next);
  console.log(`Stamped ${DOCUMENT} -> ${expected}`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main();
}
