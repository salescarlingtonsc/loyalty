# V295 — owner defects from live screenshots (2026-08-12/13): acceptance evidence

Three owner-reported defects, all UI-only. No migration, no governance manifest change, no
`db/` or `supabase/` file touched. Built and proven on 2026-08-12.

## What shipped (owner's words in quotes)

1. **Dashboard — one date everywhere.** "for date selected should reflect schedule &
   Performance … should not be static, must follow selected date". The schedule card heading
   follows the chosen day: today → "Today schedule", tomorrow → "Tomorrow's schedule", any other
   day → "Schedule · 13 Aug 2026" (the app's existing SGT formatter,
   `dashboardScheduleDayLabelV252`; the dated form is registered interpolated copy
   `scheduleHeadingDay` with en / zh-CN / ms). The V294 link is now two-way: the Today/7d/30d/90d
   pills and Apply move the schedule card to the range's END day and re-light the matching
   Today/Tomorrow tab. One applier with a direction flag, so a single gesture never writes the
   range twice. The Performance subtitle, the four KPI drill-through tiles and the
   "Understand your business" charts all read the same resolved `#df`/`#dt` inside `load()`.
   Helper copy: "Linked both ways with the figures below."
2. **Customer 360 — "there's an empty box and UI UX not aligned".** The "+ New customer" chip
   overlapped the first-purchase sentence because that sentence carried a `-10px` top margin
   written when `.c360-badges` still had its own `16px` bottom margin, which V294's
   `.c360-top-main-v294` rule had zeroed. The empty box was that same wrapper's
   `flex:1 1 240px`, read by the mobile column direction as a 240px basis HEIGHT, and on desktop
   as a tall void beside the taller summary card. The band is removed; the chips and their
   sentence are a plain stack, and the summary card is now the content grid's top-right cell
   (ordered first below 960px so the figures stack above the content on a phone). Nothing was
   removed: visits, lifetime spend, points with its V259 history button, the paused note, the
   expiry line, spendable credit and PDPA consent all remain in that card.
3. **Publish confirmation — "this draft is so confusing, i do not know what changed - just be
   straight forward without all unnecessary details".** The dialog leads with one plain bulleted
   list of concrete lines built from the same V291 comparison inputs, covering every change type
   the gate computes: programme numbers (`growPublishFieldRowsV170`), reward changes / additions
   / removals, the birthday benefit and bring-back rules. When nothing changes it is one
   sentence — "Nothing changes for customers in this draft." — and nothing else; when a section
   could not be read it says that instead, because an unreadable draft is not a draft that
   changes nothing. Deleted: the "Server-confirmed advanced-action safety" tally box and the
   "Safety check complete…" paragraph. Advanced rules render only when there is at least one.
   Kept unchanged: the PAUSED warning banner, the `needConfirm` danger styling, the
   acknowledgement checkbox and the disabled-until-ticked Publish button. The review page behind
   the dialog gets the same treatment — change list first, machinery folded into a collapsed
   "Technical detail" disclosure that still carries the comparison basis, the gate's own
   description and the welcome-offer caveat.

## Scripted acceptance

`tests/browser/verify-v295-owner-fixes-walkthrough.mjs` drives the real stamped bundles
(`app/index.html` + `app-core.js` + `app-business.js`) through the real router in Chrome, with
the Supabase client replaced by an in-page recording fixture.

```
STEP 1a. schedule heading follows the chosen day (Tomorrow)
  ok - first paint heading reads "Today schedule"
  ok - heading reads "Tomorrow’s schedule" after the Tomorrow tab
  ok - Performance subtitle is the single day "13 Aug 2026 to 13 Aug 2026"
STEP 1b. an arbitrary date names itself in the heading
  ok - heading reads "Schedule · 21 Aug 2026"
  ok - Performance subtitle followed the picked date
STEP 1c. the top range moves the schedule card to the range END day
  ok - the 7d pill moved the schedule card to the range end day and the heading followed
  ok - the schedule date input holds that same day
  ok - the Today tab is re-lit and Tomorrow is not
  ok - Performance subtitle reads the 7-day range "6 Aug 2026 to 12 Aug 2026"
  ok - the From/To pair is the same resolved range the subtitle prints
  ok - the four KPI drill-through tiles rendered against that same applied range
  ok - no KPI tile is left showing a stale-range placeholder
STEP 2a. customer 360 at desktop 1440
  ok - [1440px] the content grid rendered 4 cells
  ok - [1440px] no empty card in the content grid (empty: [])
  ok - [1440px] all 2 points elements live inside the summary card, none orphaned
  ok - [1440px] summary card still carries "Visits"
  ok - [1440px] summary card still carries "Lifetime spend"
  ok - [1440px] summary card still carries "Points"
  ok - [1440px] summary card still carries "Spendable credit"
  ok - [1440px] summary card still carries "PDPA consent"
  ok - [1440px] the first-purchase explainer is on the page
  ok - [1440px] the status chip row does not overlap the explainer sentence
  ok - [1440px] the summary card sits inside the content grid, not above an empty left column
STEP 2b. customer 360 at mobile 390
  ok - [390px] the content grid rendered 4 cells
  ok - [390px] no empty card in the content grid (empty: [])
  ok - [390px] all 2 points elements live inside the summary card, none orphaned
  ok - [390px] summary card still carries "Visits"
  ok - [390px] summary card still carries "Lifetime spend"
  ok - [390px] summary card still carries "Points"
  ok - [390px] summary card still carries "Spendable credit"
  ok - [390px] summary card still carries "PDPA consent"
  ok - [390px] the first-purchase explainer is on the page
  ok - [390px] the status chip row does not overlap the explainer sentence
  ok - [390px] the summary card stacks at the top of the content, it does not float between cards
STEP 3a. a no-change draft says it once and drops the ceremony
  ok - the dialog says "Nothing changes for customers in this draft." exactly once (found 1)
  ok - "Server-confirmed advanced-action safety" is absent
  ok - "Safety check complete" is absent
  ok - no box announces the absence of advanced-rule changes
  ok - the review page behind it says it once too
  ok - the review page machinery lives in a Technical detail disclosure
  ok - that disclosure starts collapsed
  ok - Technical detail keeps "welcome offer is not part of this draft"
  ok - Technical detail keeps "compared with the programme customers earn on today"
  ok - Technical detail keeps "lists every programme, reward, birthday and bring-back value this draft changes"
STEP 3b. a changed draft leads with the concrete change
  ok - the no-change sentence is NOT shown when something changed
  ok - the change list rendered 2 plain lines
  ok - the reward cost change is one plain line (["Free Moisturiser — Cost: 150 points → 1500 points","Free Lolipop — now offered for 50 points"])
  ok - the added reward is one plain line
  ok - the deleted machinery stays deleted on a changed draft too
STEP 3c. paused draft keeps its warning; Publish stays gated on the checkbox
  ok - the PAUSED warning banner is still present
  ok - Publish now starts disabled
  ok - Publish now enables only after the acknowledgement is ticked
V295 owner fixes walkthrough PASS (steps 1-3)
```

`verify-v294-owner-batch-walkthrough.mjs` — PASS (steps 1-9).
`verify-v293-reward-editor-walkthrough.mjs` — PASS (steps a-g).

Full `node --test` sweep: zero new failures against the origin/main baseline. The one known
pre-existing failure (`tests/mobile/v131-store-publication-readiness`) is unchanged.

## Regenerated fixtures and recaptured evidence

The shared production stylesheet changed, so every browser fixture that embeds it was
regenerated from current production source, and the two captured-evidence suites were re-run
against a server for this worktree:

- `tests/browser/reward-overview-owner-visual.html` — production source sha256
  `b0567b2d686767de22517c801c09692fef825d377b8455836d15432041c071a5`
- `tests/browser/v104-promotions-visual.html` + `docs/qa/evidence/v104-promotions-*` — PASS,
  source hash `c37bce2fc908661d01a8b292213db79a7229173815a56c1463217aff2d95d334`
- `tests/browser/v142-connect-paynow-visual.html` +
  `docs/qa/evidence/v142-connect-paynow-pos/*` — PASS, source hash
  `ddbd80022c589800458593a0b1f683db4ba57b2dcd2a62df0b1c6e9c3fcdefc1`
- `v105-admin`, `v129-trial-test`, `v130-self-serve`, `v131-store`, `v141-dashboard`,
  `v145-launch-freeze` fixtures regenerated; their acceptance tests pass.

## Test pins retargeted (never weakened)

`v145-launch-freeze-audit`, `v175-publish-diff-model-aware`, `v191`/`v291-client-debt-closure`,
`v252-activity-table-and-schedule-dates`, `v266-sales-filter-and-dashboard-period`,
`v97-workspace-localization-acceptance` (template inventory 130 → 131), and the V294
walkthrough's helper-copy assertion. Each retarget carries a V295 comment naming the owner
instruction that moved it. Where a pin defended a rule rather than a string — publish
completeness, the paused warning, the confirmation gate — the rule is now pinned more tightly
than before.
