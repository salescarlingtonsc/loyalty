#!/usr/bin/env node
/**
 * Build every Peekaa app icon and favicon from ONE source of truth: app/brand/peekaa-logo.png.
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
export const SOURCE = 'app/brand/peekaa-logo.png';
/* --bg is the manifest's own background_color, so the icon and the splash it sits on agree. */
export const BACKGROUND = '#F7EBDB';

/* padding = fraction of the square left EMPTY around the lockup.
   0.14 matches the reference the owner supplied; the maskable's 0.26 keeps every inked pixel
   inside the 80% safe circle even when Android crops to a squircle. */
export const ICONS = [
  /* 32px is the browser tab, and six lowercase letters across ~30 pixels is roughly five pixels
     per letter — "peekaa" reads as texture there no matter what padding is chosen. The owner asked
     for the full lockup on the favicon too, so it is the full lockup; the padding is simply as
     tight as the square allows, and the 192 below is offered alongside it for the surfaces
     (bookmarks, new-tab tiles) that ask for something bigger and CAN show the name. */
  { file: 'app/icons/peekaa-32.png', size: 32, padding: 0.04 },
  { file: 'app/icons/apple-touch-icon.png', size: 180, padding: 0.14 },
  { file: 'app/icons/peekaa-192.png', size: 192, padding: 0.14 },
  { file: 'app/icons/peekaa-512.png', size: 512, padding: 0.14 },
  { file: 'app/icons/peekaa-512-maskable.png', size: 512, padding: 0.26 },
  /* The App Store marketing icon. It was hand-made in the 2026-08-02 rebrand and then missed by
     v549, so it still carried the EYES ONLY while the home-screen tile beside it carried the
     wordmark — the exact drift this script exists to end, and the owner's v549 photo named the
     "app icon" explicitly. It lives here rather than in a second script because there is one
     lockup, one cream, one padding; Apple's rules are only that it be 1024² and opaque, and the
     PY step already flattens to RGB. iOS masks the corners itself, so no rounding here. */
  { file: 'ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png', size: 1024, padding: 0.14 },
];

const PY = `
import sys, json
from PIL import Image
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
    canvas.convert("RGB").save(icon["path"], "PNG", optimize=True)
print("ok")
`;

export async function renderIcons(targetDir) {
  const spec = {
    source: path.join(repoRoot, SOURCE),
    background: BACKGROUND,
    icons: ICONS.map(icon => ({ ...icon, path: path.join(targetDir, path.basename(icon.file)) })),
  };
  const result = spawnSync('python3', ['-c', PY, JSON.stringify(spec)], { encoding: 'utf8' });
  if (result.status !== 0) throw new Error(`icon render failed: ${result.stderr || result.stdout}`);
}

const sha = buffer => createHash('sha256').update(buffer).digest('hex');

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
    if (current && sha(current) === sha(fresh)) continue;
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
