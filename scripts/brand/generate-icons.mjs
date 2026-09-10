#!/usr/bin/env node
/**
 * Build every Peekaa app icon and favicon from ONE source of truth: app/brand/peekaa-appicon.png.
 *
 *   node scripts/brand/generate-icons.mjs            # write
 *   node scripts/brand/generate-icons.mjs --check    # fail if any icon is stale
 *
 * nestly_v549 (owner: "i need you to copy this as the correct version, with peekaa wordings —
 * for favicon / app icon / and website favicon"). The five icons under app/icons/ were hand-made
 * and carried the EYES ONLY, so the home-screen tile and the browser tab showed a mark with no
 * name on it while every other surface showed the full wordmark. They were also unreproducible:
 * nothing in the repo said how they had been made, so "regenerate the icons" meant "open an image
 * editor and hope". This script is that missing step, and --check makes a stale icon a test
 * failure rather than something noticed in a screenshot months later.
 *
 * The composition is the brand lockup on the brand cream, centred, at one padding ratio for every
 * size — so the tab, the home screen and the install prompt are the same picture, not three
 * cousins. The maskable variant is the exception and must be: Android crops it to an arbitrary
 * shape, so its content is held inside the inner 80% safe zone the spec defines.
 */
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
/* Two brand assets, two jobs. The LOCKUP is the wide wordmark the site header, the sign-in
   hero, the OG card and schema.org all point at, sized 240x68 in markup — it is not an icon and
   must never be swapped for one. The TILE is the finished square app-icon artwork, prepared by
   scripts/brand/prepare-appicon.mjs. nestly_v830 moved the icon family onto the TILE; before
   that every icon was the lockup letterboxed onto cream, which is why they all carried padding. */
export const LOCKUP = 'app/brand/peekaa-logo.png';
export const SOURCE = 'app/brand/peekaa-appicon.png';
/* --bg is the manifest's own background_color, so the icon and the splash it sits on agree. */
export const BACKGROUND = '#F7EBDB';

/* padding = fraction of the square left EMPTY around the lockup.
   0.14 matches the reference the owner supplied; the maskable's 0.26 keeps every inked pixel
   inside the 80% safe circle even when Android crops to a squircle. */
export const ICONS = [
  /* padding = fraction of the square left EMPTY around the artwork. The tile is a finished icon
     that already carries its own background, so every square surface takes it FULL BLEED: an
     inset would letterbox a picture of an icon inside another icon, and on iOS it would also
     stack a second corner radius inside Apple's own mask. */
  { file: 'app/icons/peekaa-32.png', size: 32, padding: 0 },
  { file: 'app/icons/apple-touch-icon.png', size: 180, padding: 0 },
  { file: 'app/icons/peekaa-192.png', size: 192, padding: 0 },
  { file: 'app/icons/peekaa-512.png', size: 512, padding: 0 },
  /* The exception, and it must be. Android crops a maskable icon to an arbitrary shape — as far
     as a circle inscribed in the square — so anything outside the inner 80% safe zone can be cut.
     Full bleed would slice the "Peekaa" wordmark off the bottom of the tile, so this one is inset
     onto the brand cream and keeps every inked pixel inside the safe circle. */
  { file: 'app/icons/peekaa-512-maskable.png', size: 512, padding: 0.26 },
  /* The App Store icon, compiled into the binary. Apple requires 1024 square and opaque, and the
     PY step flattens to RGB. iOS applies its own ~22.4% corner mask, so no rounding here — the
     tile deliberately bleeds its cream off the top corners and its red band off the bottom ones
     so that whatever Apple's mask keeps is the artwork's own colour, never a white wedge. */
  { file: 'ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png', size: 1024, padding: 0 },
];

const PY = `
import sys, json
from PIL import Image, PngImagePlugin
spec = json.loads(sys.argv[1])
src = Image.open(spec["source"]).convert("RGBA")
bg = spec["background"].lstrip("#")
rgb = tuple(int(bg[i:i+2], 16) for i in (0, 2, 4))
for icon in spec["icons"]:
    size, pad = icon["size"], icon["padding"]
    box = size * (1 - 2 * pad)
    scale = min(box / src.width, box / src.height)
    w, h = max(1, round(src.width * scale)), max(1, round(src.height * scale))
    mark = src.resize((w, h), Image.LANCZOS)
    canvas = Image.new("RGBA", (size, size), rgb + (255,))
    canvas.alpha_composite(mark, ((size - w) // 2, (size - h) // 2))
    info = PngImagePlugin.PngInfo()
    info.add_text(spec["stampKey"], icon["stamp"])
    canvas.convert("RGB").save(icon["path"], "PNG", optimize=True, pnginfo=info)
print("ok")
`;

/* The build stamp. Pillow's PNG encoder is not byte-stable across builds — the same pixels come
   out as different files on macOS and on ubuntu — so "is this icon current" cannot be "are the
   bytes identical": that only ever passed on the machine that rendered them (found the day
   `icons:check` first ran in CI). Instead every rendered icon carries a tEXt chunk holding the
   sha256 of everything that determines its pixels — the source tile's bytes, this icon's spec,
   the background, and the render recipe itself — and --check compares the stamp the committed
   file carries with the stamp the current inputs produce. Change the tile, the padding, or the
   recipe and the stamp moves; change the Pillow build and it does not. */
export const STAMP_KEY = 'peekaa-build';

export async function iconStamp(icon, sourceBytes) {
  const src = sourceBytes ?? await readFile(path.join(repoRoot, SOURCE));
  return createHash('sha256')
    .update(src)
    .update('\0')
    .update(JSON.stringify({ file: icon.file, size: icon.size, padding: icon.padding, background: BACKGROUND, recipe: PY }))
    .digest('hex');
}

/* Reads the build stamp out of a PNG's tEXt chunks; null when the file carries none. */
export function readStamp(png) {
  if (!Buffer.isBuffer(png) || png.length < 8 || png.toString('latin1', 1, 4) !== 'PNG') return null;
  let offset = 8;
  while (offset + 8 <= png.length) {
    const length = png.readUInt32BE(offset);
    const type = png.toString('latin1', offset + 4, offset + 8);
    const data = png.subarray(offset + 8, offset + 8 + length);
    if (type === 'tEXt') {
      const nul = data.indexOf(0);
      if (nul > 0 && data.toString('latin1', 0, nul) === STAMP_KEY) return data.toString('latin1', nul + 1);
    }
    if (type === 'IEND') break;
    offset += 12 + length;
  }
  return null;
}

export async function renderIcons(targetDir) {
  const sourceBytes = await readFile(path.join(repoRoot, SOURCE));
  const spec = {
    source: path.join(repoRoot, SOURCE),
    background: BACKGROUND,
    stampKey: STAMP_KEY,
    icons: await Promise.all(ICONS.map(async icon => ({
      ...icon, path: path.join(targetDir, path.basename(icon.file)), stamp: await iconStamp(icon, sourceBytes),
    }))),
  };
  const result = spawnSync('python3', ['-c', PY, JSON.stringify(spec)], { encoding: 'utf8' });
  if (result.status !== 0) throw new Error(`icon render failed: ${result.stderr || result.stdout}`);
}

/* nestly_v459's guard, for the same reason it exists: `node --test` with no path argument
   collects every .mjs under tests/, and a test that IMPORTS this module to reuse ICONS and
   renderIcons must not thereby run the writer. Without this, `npm test` would rewrite the very
   icons it is comparing against — the exact self-healing race v459 documented. */
const { isDirectCliInvocation } = await import('../quality/is-direct-cli-invocation.mjs');
if (!isDirectCliInvocation(import.meta.url)) {
  /* imported for ICONS / SOURCE / renderIcons — do nothing else */
} else {
const check = process.argv.includes('--check');
const { mkdtemp, rm } = await import('node:fs/promises');
const { tmpdir } = await import('node:os');
const staging = await mkdtemp(path.join(tmpdir(), 'peekaa-icons-'));
try {
  await renderIcons(staging);
  const stale = [];
  for (const icon of ICONS) {
    const fresh = await readFile(path.join(staging, path.basename(icon.file)));
    const current = await readFile(path.join(repoRoot, icon.file)).catch(() => null);
    const stamp = readStamp(fresh);
    if (stamp && current && readStamp(current) === stamp) continue;
    stale.push(icon.file);
    if (!check) await writeFile(path.join(repoRoot, icon.file), fresh);
  }
  if (check && stale.length) {
    console.error(`Stale icons — run \`node scripts/brand/generate-icons.mjs\`:\n  ${stale.join('\n  ')}`);
    process.exit(1);
  }
  console.log(check ? 'Icons are current.' : (stale.length ? `Rebuilt: ${stale.join(', ')}` : 'Already current.'));
} finally {
  await rm(staging, { recursive: true, force: true });
}
}
