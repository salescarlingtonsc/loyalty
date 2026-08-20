# V401 — Rewards Overview visual pass

Date: 20 August 2026
Scope: the business workspace's Rewards Programme → Overview surface, plus the icon registry the
whole workspace shares. Owner-approved "balanced" direction; no behaviour, data or copy changed.

Extracted production component hash for the reward-overview browser fixture:
`989d9a7832d51411abcac2c0b61c784ac8dbdcc3e42ddae78a9cdd116b125862`

## What was wrong, measured

Against `origin/main` at `50be6f6`, rendered through the repo's own component harness with the
production stylesheet and the production `growPage` render functions:

| | before | after |
|---|---|---|
| icons anywhere in the Overview view | **0** | 11 |
| nested `.card` levels painted `#FFFFFF` | 4 of 4 | 2 of 4 |
| comeback KPI value | 28px | 34px (30.4px ≤640) |
| icon names silently rendering the `info` fallback | 4 | 0 |
| programme tiles sharing one gift-box glyph | 3 | 0 |

The list view one click away carried seven marks and the Dashboard already led its section
headings with a coral glyph, so this page was not missing a design language — it was the one
surface in the module not using the one that exists.

## The four broken icon names

`menu`, `branches`, `business` and `products` were passed to `CUI.icon()` but are not in the
registry, so each rendered `info` — a circled "i". `menu` was the **Rewards Programme** row in the
workspace's own left rail. Now `star`, `branch`, `branch` and `bottle`.

## The gift-box collision

`loyalty` and `giftcard` are the same gift-with-a-bow drawing; the paths differ by one pixel of box
height and only 21% of the inked pixels differ at 18px. Stamp card, Welcome gift and Birthday
benefit therefore all rendered the same symbol, and Limited Offer borrowed it again in the rail.

Three glyphs were added rather than reshuffled, because three meanings genuinely had no mark:
`stamp` (a rubber stamp), `tag`, `cake`. Each was rasterised against all 51 existing glyphs before
landing — nearest neighbours 73%, 79% and 73% different respectively — and each was checked at
16px, the inline size the Overview programme rows use.

Tiers moved from `memberships` to `diamond`, which is what the customer app has shipped since
v396, so the two apps now name the same thing with the same symbol. Memberships moved to
`wallet` so it no longer reads as a sibling of Tiers.

## The two illustrations

Both are decoration: `aria-hidden`, and neither carries meaning the text does not.

- **Limited Offer**, 132px, centred in the empty panel. Gated to **≥1201px** — the same breakpoint
  `.grow-overview-split-v319` collapses at, because the dead column it fills is created by that
  split. Transient by construction: it stops rendering the moment a firm publishes an offer.
- **Retention**, 96px, in the retention-analytics card header. Gated to **≥1024px**.

Placement note: the owner first drew the retention illustration on the *Gone quiet* card's header.
Measured, that row has 88px of free width at 1440 and 13px at 1024 — its caveat sentence runs the
full 954px and the 30/60/90 control has already wrapped — so it cannot hold a 96px object. The
section heading above it has 365–392px free and no control in it, sits 207px above the comeback
numbers rather than 100px, and anchors the whole section rather than one card inside it.

Verified by breakpoint: neither illustration is **fetched at all** below its gate (`display:none`
plus `loading="lazy"`), so tablet and phone pay nothing for them.

## Nesting inversion

Level 3 (the *Gone quiet* card) steps back to `--bg`; level 4 (the two KPI tiles) stays white. The
numbers therefore sit on the brightest surface on the page, which is what keeps them dominant —
and is why no illustration was placed inside that card.

## Gates

`npm run quality`, `bundle-stamp:check`, `runtime-config:check`, `migration-manifest:check` and
`canonical-migrations:check` all pass. `npm test`: 3184 of 3185, the single failure being
`store association generator fails closed and emits exact real identifiers`, which fails
identically on unmodified `origin/main` and is unrelated to this wave.

A recapture script for v142 (`tests/browser/verify-v142-connect-paynow-visual.mjs`) was written as
part of this wave: v142 keys captured Chrome metrics to the fixture's source hash, the fixture
embeds the stylesheet, and no script existed to recapture it — which left hand-editing the hash as
the only apparent way out. It drives the real PayNow flow and asserts the suite's own acceptance
conditions before it writes.
