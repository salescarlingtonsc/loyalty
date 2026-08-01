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
`8f0f2c6b90d952f2127ff7a4c9f43d81118df5270af1e4a9adfddfa5d30878d7`

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

## Still pending

- authenticated owner image upload, draft, publish and unpublish against the
  target environment;
- linked-customer refresh and CTA acceptance against the same target rows;
- authorized production migration and production smoke.

Accordingly, this document proves the deterministic production render and its
responsive behavior. It does not claim target-environment data acceptance.
