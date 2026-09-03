# nestly_v750 — tier dialog alignment, measured

Owner photo (production, the day after v748's deploy): the "Edit tier" / "Add a tier" pop-up
(Programmes → Tier membership → Edit / + Add tier) had its content jammed against the dialog's
left edge — the title and every input started at the dialog's left border, the title sat clipped
top-left, and the "Tier name" input was circled in red for uneven label-to-input spacing.

All numbers below were measured with `getComputedStyle`/`getBoundingClientRect` on a real
Chromium render of the production `growPage()` function against the production stylesheet (see
`tests/browser/generate-v750-tier-dialog-visual.mjs` and
`tests/business-ui/v750-tier-dialog-alignment.test.mjs`), not read off the CSS source by eye. A
prior session's hand-built static rig had reported 20px padding on this element, which is what
every non-`!important` rule that names it says — and was wrong, because it never rendered the
dialog inside its real ancestor list.

## Root cause (see the `nestly_v750` comment block in `app/index.html`, around
`[data-grow-tiers-summary-v331]>li:not(.grow-inline-modal-v658)`)

The tier add/edit dialog (`data-grow-tiers-addform-v331`) and the tier delete confirmation
(`data-grow-tiers-deleteconfirm-v331`) both render as direct `<li>` children of the SAME
`<ul data-grow-tiers-summary-v331>` that holds the ordinary tier rows. Two rules meant only for
those ordinary rows reached the pop-ups too:

1. `.grow-overview[data-programme-view="tiers"] [data-grow-tiers-summary-v331]>li{padding:0
   !important;border:0!important;box-shadow:none!important}` — written to strip the outer `<li>`'s
   default card look from a tier row (which supplies its own card via `.grow-tier-card-row-v351`).
   `!important` beats any specificity, so it also zeroed the pop-up's own padding — its only inset,
   since a pop-up has no inner card of its own.
2. `.grow-overview[data-programme-view="tiers"] [data-grow-tiers-summary-v331]>li{padding:20px
   24px;border:1px solid var(--hair);box-shadow:...}` (no `!important`) — at the exact same
   specificity, `(0,3,1)`, as the rule that is actually meant to style these pop-ups
   (`li.grow-inline-modal-v658, ...`). Simply excluding the pop-up from rule 1 let rule 2 win the
   tie by source order instead, giving the dialog an unwanted 1px border and a second box-shadow.

Both are now scoped with `:not(.grow-inline-modal-v658)` — the class every pop-up in this list
carries — so the pop-up falls through entirely to its own dialog rule.

A second, independent defect was found while re-measuring: the label-to-input gap read 12px, not
the 6px the v748 comment intended. The base `label{margin:16px 0 6px}` rule (an unscoped element
selector, this stylesheet's own generic label style) was still applying inside the dialog's flex
column — a flex item's own margin adds to its parent's `gap`, it does not get absorbed by it. Fixed
by zeroing the label's margin inside `.grow-inline-modal-v658 .grow-setup-sentence-v301:not(.row)`.

## Measured, before → after (desktop 1440×1100, "Add a tier")

| Measurement | Before | After | Target |
|---|---|---|---|
| Dialog padding (top/right/bottom/left) | 0 / 0 / 0 / 0 px | 20 / 20 / 20 / 20 px | ≥16px all sides |
| Title left offset from dialog edge | 0px (flush/clipped) | 20px | not flush |
| Title top offset from dialog edge | 0px (flush/clipped) | 20px | not flush |
| "Tier name" label → input gap | 12px | 6px | ≤8px |
| "Required visits" label → input gap | 12px | 6px | ≤8px |
| Field-group vertical rhythm (both groups' height) | 88.875px / 88.875px (padded by the label bug) | 66.875px / 66.875px (equal) | consistent |
| Input right edge vs dialog right edge | flush (0px inset — padding was 0) | 20px inset | nothing overflows |
| Dialog right edge vs viewport | 980px vs 1440px | 980px vs 1440px | no viewport overflow |

"Edit tier" (pre-filled dialog) measured the same before/after shape: padding 0→20/20/20/20, both
label gaps 12px→6px.

## Screenshots

- `before-add-tier-desktop-1440.png` / `after-add-tier-desktop-1440.png`
- `before-edit-tier-desktop-1440.png` / `after-edit-tier-desktop-1440.png`

"Before" was captured by building the same fixture against `app/index.html` as it stood at commit
`fd910554` (the v749 hotfix commit, immediately before this fix). "After" is the current worktree.

## Referral pop-up (nestly_v749 guard, unaffected by this change, re-verified)

`growReferralGiftWrapV420` / `growReferralFriendGiftWrapV421` (kind=points) and
`growReferralPointsWrapV420` / `growReferralFriendPointsWrapV421` (kind=voucher) were measured with
`hidden` attribute present, `offsetParent === null`, and `height === 0` in both directions —
confirmed in `tests/business-ui/v750-tier-dialog-alignment.test.mjs`.
