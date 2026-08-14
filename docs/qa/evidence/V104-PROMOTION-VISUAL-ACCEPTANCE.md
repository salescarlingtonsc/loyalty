# V104 promotion visual acceptance

Date: 29 July 2026
Scope: deterministic, direct production-render acceptance
Generator: `tests/browser/generate-v104-promotions-visual.mjs`
Rendered fixture: `tests/browser/v104-promotions-visual.html`
Captured metrics: `docs/qa/evidence/v104-promotions-production-render-metrics.json`

This evidence is generated from the current `app/index.html`, not from an
independently restyled mock. The generator extracts the complete production
stylesheet plus the exact production date, CTA, card and details-dialog
functions, invokes `customerPromotionCardV104` for two realistic spa offers,
and records a SHA-256 provenance value.

Production source SHA-256:
`ded6c3a046b0ef61f46e8a85ee1fd185166b710925e25e8f5068ffd0331e8c03`

The shared production stylesheet changed during the 2026-08-01 rewards
overview work. `verify-v104-promotions-visual.mjs` therefore refreshed the
three Chromium captures and metrics from the newly generated fixture rather
than carrying forward the former source hash. The promotion-specific geometry
and acceptance thresholds still pass.

The only harness CSS is a small provenance label. The offer media is a
deterministic text-free SVG so visual layout is reproducible; it is not evidence
of an authenticated owner upload.

## Actual-render procedure

Installed Chrome rendered the fixture through the Chrome DevTools Protocol at
1440, 390 and 412 CSS pixels. Device metrics were overridden before navigation,
the browser waited for two animation frames, and then it captured DOM geometry,
accessibility state and screenshots.

The mobile 390px run opened the first offer's Terms. The 412px run opened the
second offer's deliberately oversized, unbroken coupon token. The desktop run
activated the production `View details` CTA and captured the real modal.

## Acceptance results

| Viewport | Cards | Card layout | Document width | Horizontal overflow | CTA target |
| --- | ---: | --- | --- | --- | --- |
| 1440 × 1000 | 2 | two columns (`513px` each) | `1440 / 1440` | No | `44px`, `44px` |
| 390 × 844 | 2 | one column (`362px`) | `390 / 390` | No | `44px`, `44px` |
| 412 × 915 | 2 | one column (`384px`) | `412 / 412` | No | `44px`, `44px` |

Both cards show authoritative customer-facing validity:

- `Valid 1 August 2026 – 30 August 2026`
- `Valid 15 August 2026 – 15 September 2026`

Terms expansion passed:

- at 390px, the first Terms block expanded to the full `318px` available
  content width and `57px` total height; its terms value was
  `318px / 318px` scroll/client width and `36px / 36px` scroll/client height;
- at 412px, the long-token Terms block expanded to the full `340px` available
  content width and `111px` total height; its terms value was
  `340px / 340px` scroll/client width and `91px / 91px` scroll/client height.

The second card begins below the first at both mobile widths. Long coupon text
wraps without document or card overflow. Promotion headlines render in white
over the media, with no synthetic image text competing with the headline.

The details CTA opened a modal with:

- `role="dialog"`;
- `aria-modal="true"`;
- `aria-labelledby="customerPromotionDetailsTitle"`;
- initial keyboard focus on `#customerPromotionDetailsClose`.

The dialog's deliberately oversized description, offer and terms values also
passed wrap/clipping checks: every measured `h2`, `p` and `dd` had equal
scroll/client width and equal scroll/client height. The longest dialog term
measured `366px / 366px` wide and `119px / 119px` high.

## Captures

- `docs/qa/evidence/v104-promotions-desktop-1440.png` — real details modal open
- `docs/qa/evidence/v104-promotions-mobile-390.png` — first Terms expanded
- `docs/qa/evidence/v104-promotions-mobile-412.png` — maximum-token Terms expanded

## Regression gates

```text
node --test \
  tests/grow/v104-promotion-visual-fixture.test.mjs \
  tests/customer-wallet/v104-customer-promotions-ui.test.mjs

7 tests, 7 passed, 0 failed
git diff --check: clean
```

The fixture test also requires byte-for-byte regeneration from the current
production CSS/functions, white promotion headline contrast, mobile one-column
layout, wrap guards, 44px CTA measurement support and the production dialog.

## v192 re-capture (2026-08-07)

The owner reported that the offer list "occupies more than a screen". The card's
360px floor was removed and the artwork cap lowered — `object-fit:contain` is
unchanged, so an uploaded EDM is still never cropped and nothing is painted over
it; only the displayed size changed. Full size remains one tap away in the offer
sheet.

`v104-promotions-production-render-metrics.json` was re-captured from the current
production render at all three viewports. Card height, the number this change was
about:

| viewport | before | after |
| --- | --- | --- |
| desktop 1440 | 852px | **625px** |
| mobile 390 | 763 / 898px | **452 / 587px** |
| mobile 412 | 700 / 1000px | **385 / 688px** |

## v194 re-capture (2026-08-07)

The customer programme page was restructured (tappable company header, Tier /
Reward points tabs, booking action moved into the header), which changed
`app/index.html` and therefore the fixture's production-source hash. The fixture
was regenerated and **all four artefacts in this folder — the metrics JSON and
the three PNGs — were re-captured from it**, so the stale-image caveat recorded
under v192 no longer applies.

Capture method: installed Chrome in `--headless=new` driven over the Chrome
DevTools Protocol from Node's built-in WebSocket client
(`Emulation.setDeviceMetricsOverride` for the exact viewport,
`Runtime.evaluate` of the fixture's own `window.v104AcceptanceMetrics()`,
`Page.captureScreenshot` with `captureBeyondViewport`). No Playwright, and no
hand-edited numbers: the JSON is the fixture's own report verbatim.

Card heights are unchanged from the v192 figures above (625px desktop,
452/587px at 390, 385/689px at 412) — this release did not touch the promotion
card, and the re-capture proves it.

## v328 re-capture (2026-08-15) — fixed a capture-tooling bug, not a production bug

`tests/grow/v104-promotion-visual-fixture.test.mjs` was failing on `main` at the
`firstTerms.open===true` assertion (mobile390 card 0's Terms disclosure). The
committed `mobile390`/`mobile412` `details.open` values were `false` and
`desktop1440.modal` was `null`, so the query-string-driven Terms/modal captures
had silently never fired.

Root cause: whichever static server produced the metrics committed in `5c01f5c`
served `/tests/browser/v104-promotions-visual.html?openTerms=0` through a
clean-URL redirect (`.html` → extensionless) that **dropped the query string**
on the 301. `verify-v104-promotions-visual.mjs` followed the redirect, loaded
the fixture with no `openTerms`/`openModal` params, and captured the
always-closed/no-modal state — a harness artifact, not a change in
`customerPromotionCardV104` or its CSS. Confirmed by recapturing through a
server that serves the `.html` path directly (no redirect): `details.open` and
`modal` come back correct and match the source's actual behaviour.

The v326 owner requirement this suite guards — offer cards side by side on
phone widths — was **already correctly implemented**; `capture.cards[1].rect`
vs `capture.cards[0].rect` passed before and after this recapture. Only the
Terms-disclosure and modal-open metrics (and their PNGs) were wrong.

Recaptured `v104-promotions-production-render-metrics.json` and all three PNGs
from the current production source (hash unchanged,
`888b1ffeb33f31e849e4300cdb50db87a3205f899948d628cdc7783dd5dd16cc`):

```text
node --test tests/grow/v104-promotion-visual-fixture.test.mjs
4 tests, 4 passed, 0 failed
```

`npm run validate` run in full afterward: 3064/3065, the one failure being the
known env-bound `tests/mobile/v131-store-publication-readiness.test.mjs` check
(missing `node_modules/@capacitor` privacy manifests in this worktree),
unrelated to this change.

## Still pending

- authenticated owner image upload, draft, publish and unpublish against the
  target environment;
- linked-customer refresh and CTA acceptance against the same target rows;
- authorized production migration and production smoke.

Accordingly, this document proves the deterministic production render and its
responsive behavior. It does not claim target-environment data acceptance.
