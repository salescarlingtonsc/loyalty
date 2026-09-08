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
const { ICONS, SOURCE, LOCKUP, renderIcons } = await import(new URL('scripts/brand/generate-icons.mjs', root).href
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

test('the icons are built from the square app-icon tile, not the lockup or the eyes-only mark', async () => {
  /* v549's distinction still holds — app/brand/peekaa-mark.png is the eyes alone and is what the
     old icons looked like — but nestly_v830 moved the source again, from the wide lockup to the
     finished square tile. The lockup must NOT come back: app/landing.html and the sign-in hero
     render it at a fixed 240x68, so anything square in that file breaks those layouts, and
     anything wide here gets letterboxed back into a picture-of-an-icon. */
  assert.equal(SOURCE, 'app/brand/peekaa-appicon.png');
  assert.equal(LOCKUP, 'app/brand/peekaa-logo.png');
  assert.notEqual(SOURCE, LOCKUP, 'the icon source and the site lockup are different assets');
  const { execFileSync } = await import('node:child_process');
  const dims = f => execFileSync('python3', ['-c',
    'import sys;from PIL import Image;print(*Image.open(sys.argv[1]).size)',
    new URL(f, root).pathname], { encoding: 'utf8' }).trim().split(' ').map(Number);
  const [tw, th] = dims(SOURCE);
  assert.equal(tw, th, 'the app-icon source is square — a wide lockup here would be letterboxed');
  const [lw, lh] = dims(LOCKUP);
  assert.ok(lw > lh * 1.2, 'the site lockup is still the wide wordmark it is laid out as');
  const mark = await readFile(new URL('app/brand/peekaa-mark.png', root));
  const tile = await readFile(new URL(SOURCE, root));
  assert.notEqual(createHash('sha256').update(tile).digest('hex'),
    createHash('sha256').update(mark).digest('hex'), 'the icon is not the eyes-only mark');
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
