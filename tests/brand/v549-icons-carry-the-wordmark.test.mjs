import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, mkdtemp, rm } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import path from 'node:path';

/* nestly_v549 (owner, photo 3 — the home-screen tile beside the full logo: "i need you to copy
   this as the correct version, with peekaa wordings ... for favicon / app icon / and website
   favicon"). The five icons carried the EYES ONLY while every other surface showed the wordmark,
   and nothing in the repo recorded how they had been made — so they could drift from the brand
   indefinitely and the only detector was somebody noticing a screenshot.
   This test is the detector. It rebuilds every icon from app/brand/peekaa-logo.png into a temp
   directory and demands byte equality with what is committed, the same contract the browser
   visual fixtures are held to. Change the logo, or change the padding, and this fails until
   `npm run icons` is run. */
const root = new URL('../../', import.meta.url);
const { ICONS, SOURCE, renderIcons } = await import(new URL('scripts/brand/generate-icons.mjs', root).href
  + '?export-only=1').catch(() => ({}));

test('every app icon and favicon is a current build of the brand lockup', async () => {
  assert.ok(Array.isArray(ICONS) && ICONS.length >= 5, 'the icon set is declared in one place');
  const staging = await mkdtemp(path.join(tmpdir(), 'peekaa-icons-test-'));
  try {
    await renderIcons(staging);
    for (const icon of ICONS) {
      const fresh = await readFile(path.join(staging, path.basename(icon.file)));
      const committed = await readFile(new URL(icon.file, root));
      assert.equal(
        createHash('sha256').update(committed).digest('hex'),
        createHash('sha256').update(fresh).digest('hex'),
        `${icon.file} is stale — run \`npm run icons\``,
      );
    }
  } finally {
    await rm(staging, { recursive: true, force: true });
  }
});

test('the icons are built from the wordmark lockup, not the eyes-only mark', async () => {
  /* The distinction the owner drew: app/brand/peekaa-mark.png is the eyes alone and is what the
     old icons looked like. The source of truth for every icon is the full lockup. */
  assert.equal(SOURCE, 'app/brand/peekaa-logo.png');
  const logo = await readFile(new URL('app/brand/peekaa-logo.png', root));
  const mark = await readFile(new URL('app/brand/peekaa-mark.png', root));
  assert.notEqual(createHash('sha256').update(logo).digest('hex'),
    createHash('sha256').update(mark).digest('hex'), 'the two brand assets are still distinct');
});

test('every icon the app and the manifest reference is one this script builds', async () => {
  const declared = new Set(ICONS.map(icon => path.basename(icon.file)));
  const referenced = new Set();
  for (const file of ['app/index.html', 'app/landing.html', 'app/manifest.webmanifest']) {
    const text = await readFile(new URL(file, root), 'utf8');
    for (const match of text.matchAll(/\/icons\/([a-z0-9.-]+\.png)/gi)) referenced.add(match[1]);
  }
  assert.ok(referenced.size >= 4, 'the icon links were found at all');
  for (const name of referenced) {
    assert.ok(declared.has(name), `${name} is shipped but not generated — it will drift`);
  }
});
