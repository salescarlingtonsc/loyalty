#!/usr/bin/env node
/**
 * Turn the supplied app-icon render into a full-bleed square tile:
 *
 *   node scripts/brand/prepare-appicon.mjs
 *
 * Input  app/brand/peekaa-appicon-source.png   (the artwork as delivered)
 * Output app/brand/peekaa-appicon.png          (what generate-icons.mjs builds from)
 *
 * nestly_v830 (owner: "how do i change the peekaa app logo to this? i dont want to use
 * existing one"). The delivered render is a *picture of an app icon* — a rounded tile,
 * floating on white, with a drop shadow. Shipping that as the 1024 would be the classic
 * double-rounded-corner mistake: iOS masks the icon itself, at ~22.4% of the width, while
 * this artwork's own corners are rounder than that (~25%+). The tile's arc would therefore
 * sit *inside* Apple's mask and you would see white wedges outside it.
 *
 * So this step reconstructs the artwork as a square that bleeds to all four edges, and lets
 * iOS own the corner shape — the only party that should:
 *
 *   1. Separate tile from background by CHROMA, not brightness. The drop shadow is a neutral
 *      grey, so a plain "not white" test swallows it and drags the crop box downward; every
 *      brand colour here is chromatic, and the only achromatic ink (pupils, outlines) is very
 *      dark. Hence `chroma > 18 or luminance < 120`.
 *   2. Fill holes before taking the bounding box, or the white eyeballs punch through the mask.
 *   3. Erode 20px before keeping any original pixel, which discards the tile's own rim and 3D
 *      bevel. Left in, that rim draws a visible squircle *inside* Apple's mask — the very
 *      artefact this script exists to remove.
 *   4. Fill everything outside that with the nearest colour sampled from 30px deep, so the
 *      cream runs off the top corners and the red band runs off the bottom ones. A single
 *      flat fill colour cannot work: this icon is cream at the top and red at the bottom.
 *
 * Requires numpy + scipy. Deliberately NOT part of `npm run icons`, which must keep working
 * with PIL alone — the cleaned tile is committed, so the icon build and its --check stay
 * dependency-light. Re-run this only when the artwork itself is replaced.
 */
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export const RAW = 'app/brand/peekaa-appicon-source.png';
export const TILE = 'app/brand/peekaa-appicon.png';

const PY = `
import sys, numpy as np
from PIL import Image
from scipy import ndimage
raw, out = sys.argv[1], sys.argv[2]
a = np.asarray(Image.open(raw).convert("RGB")).astype(np.int16)
mask = (a.max(2) - a.min(2) > 18) | (a.mean(2) < 120)
mask = ndimage.binary_fill_holes(mask)
lbl, n = ndimage.label(mask)
mask = lbl == int(np.argmax(ndimage.sum(mask, lbl, range(1, n + 1)))) + 1
ys, xs = np.where(mask)
y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
S = max(y1 - y0 + 1, x1 - x0 + 1)
cy, cx = (y0 + y1) // 2, (x0 + x1) // 2
big = np.pad(a, ((S, S), (S, S), (0, 0)), mode="edge")
bigm = np.pad(mask, ((S, S), (S, S)), constant_values=False)
t, l = cy + S - S // 2, cx + S - S // 2
crop, cropm = big[t:t + S, l:l + S].astype(np.uint8), bigm[t:t + S, l:l + S]
keep = ndimage.binary_erosion(cropm, iterations=20)
src = ndimage.binary_erosion(cropm, iterations=30)
idx = ndimage.distance_transform_edt(~src, return_distances=False, return_indices=True)
Image.fromarray(np.where(keep[..., None], crop, crop[tuple(idx)]).astype(np.uint8)).save(out, "PNG", optimize=True)
print(S)
`;

const r = spawnSync('python3', ['-c', PY, path.join(repoRoot, RAW), path.join(repoRoot, TILE)], { encoding: 'utf8' });
if (r.status !== 0) throw new Error(`app icon prepare failed: ${r.stderr || r.stdout}`);
console.log(`Wrote ${TILE} at ${r.stdout.trim()}px square.`);
