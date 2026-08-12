# V301 — Programmes setup wizard (acceptance evidence)

Owner report (2026-08-13): **"Business owners cannot set up rewards."** The cold-start path was
~13 clicks through three stacked popups (`rewardAutoSetupModal` → `rewardDialogV238` →
`growPubModal`); closing any one of them dumped the owner on a page they had not chosen; drafts
piled up unpublished (the demo tenant carried 8 open drafts and a paused programme); and the
publish confirmation could **double-open** — `openPublishFlow` was auto-invoked through a
`queueMicrotask` while its own button stayed enabled, so a second `#growPubModal` duplicated the
first's element ids and the visible dialog's buttons were wired to the dialog underneath it.

Owner directive: **one page with step subtabs (Step 1 → 2 → 3 → …), select-and-Next simplicity a
layman can complete unaided, publish at completion, no popups.**

## What shipped

New surface `#/grow/setup` (`growSetupWizardV301`), rendered as a fourth **view** of the
Programmes page — the rail keeps Programmes lit and the three rail children (Overview / List /
History) are untouched. Four steps, zero dialogs:

1. **Choose** — two option cards, Points or Stamp card, preselected from the live/draft model.
2. **Earning** — one sentence, one input, with a live worked example under it.
3. **Reward** — the draft's reward catalogue inline: existing rewards as rows with Edit, three
   one-tap suggestions, and the V293 two-decision form (name + company cost → points cost).
   An existing fixed-redemption (`classic`) firm edits its points→credit pair here instead.
4. **Go live** — the programme summary, the publish gate's own "What changes for customers"
   list, the ON/keep-paused choice, and Publish.

Every Next saves immediately through the **same** RPCs the full editor uses
(`create_loyalty_config_draft` on the first save only, then `save_loyalty_config_draft` carrying
the snapshot hash refreshed from each response). Publish is
`save_loyalty_config_draft {active}` → `preview_publish_impact` → `publish_loyalty_config`, with
the acknowledgement rendered **inline** when the server flags an advanced rule. No new writer,
no new RPC, no migration.

Entry points rewired: the cold-start rewards branch of `openGrowEditorV258`, the pending Points
System / Stamp card cards (labelled "Continue set up →" when a resumable draft exists), the bare
Point system row's "Set up →", and both unpublished-changes banners (which now open the wizard's
final step at `#/grow/setup/review`). `openRewardsAutoSetup` survives for its one remaining
caller, the Bring-back cold start — a different engine with no wizard of its own.

Double-modal defect fixed in **both** publish flows (still reachable through
`#/studio/<draft>`): a re-entrancy flag plus an id check, and the triggering button stays
disabled for the whole queued auto-open rather than only for the RPC inside it.

## Regression tests (fail before, pass after)

- `tests/business-ui/v301-programmes-setup-wizard.test.mjs` (22 tests)
- `tests/browser/verify-v301-setup-wizard-walkthrough.mjs` — real bundles, real router, stubbed
  Supabase that records every write; steps a–h PASS, including zero `.modal` elements at every
  step and a 390×844 pass with no horizontal overflow.

Adjusted stale source pins whose asserted intent is unchanged (each carries a V301 comment):
`v172-grow-surface-guard`, `v173-programme-tabs-suggestions`, `v180-owner-screenshot-batch`,
`v198-programmes-unpublished-marker`, `v244-ongoing-and-pending-programmes`,
`v245-pending-nav-and-appointment-amend`, `v250-programmes-nav-and-reward-cards`,
`v271-programme-overview-and-point-system-row`.

## Regenerated fixtures and captured evidence

`app/app.js` and `app/index.html` both changed, so every fixture that embeds a production-source
hash was regenerated from source: v129, v130, v131, v141, v142, v145, v104, v105 and the reward
overview. Chrome captures were re-run for `v142-connect-paynow-pos/metrics.json` (PASS) and
`v104-promotions-production-render-metrics.json` (PASS).

Regenerated `tests/browser/reward-overview-owner-visual.html` production-source-sha256:

    0f46f64abb16e1920d9d9f1597b1b0660e73c9e3d52ae91f0d607785ff962bd0

## Same release: the phantom "Gift cards" Overview row

Owner report (same message): **"i already removed gift card - but it keeps appearing"** in
Programmes → Overview. Root cause: the Overview row was injected by `growProgrammeEntriesV271`
whenever the `giftcards` module was enabled AND `businesses.gift_card_sales_enabled` was true
(still true in production — confirmed by direct query). V294/V296 removed the gift-cards *entry
points* from Programmes but deliberately never touched that flag, so the synthesized row
outlived the module's departure. Fix: the Overview no longer synthesizes a Gift cards programme
row at all (gift cards are a Serve & sell counter capability, per the owner's V294 ruling), and
`growOverviewSnapshot` no longer fetches checkout preferences — one less RPC per Overview load.
The Serve & sell page and the Customer Interface switch keep their own
`business_get_checkout_preferences_v102` reads unchanged. Regression:
`tests/business-ui/v301-overview-no-gift-cards-row.test.mjs` (3 tests) plus the flipped pin in
`v271-programme-overview-and-point-system-row.test.mjs`; a real-bundle Chrome check with the
module on and the flag true renders the Overview with no "Gift cards" text and no
checkout-preferences RPC fired.

## Verification tally (orchestrator re-run, this tree)

- `node --check app/app.js` OK; `npm run bundle-stamp:check` current
  (core 329KB · auth 23KB · customer 376KB · business 1650KB · i18n 208KB).
- `npm test`: **2832 pass / 0 fail** (baseline at v299 HEAD: 2806/2807 — the one failure is the
  environment-bound mobile store-readiness sub-test absent on this machine).
- Browser walkthroughs (real bundles, stubbed client): **v301 a–h PASS**, v296 1–7 PASS,
  v294 1–9 PASS, v293 a–g PASS. Zero page errors in all runs.

## Captured screens (this directory)

`v301-{list,overview-no-giftcards,wizard-step1,wizard-step2,wizard-step3,wizard-step4,wizard-published}-{desktop-1440,mobile-390}.png`
— fourteen captures from the real-bundle stubbed-client harness; the overview pair shows the
table without the Gift cards row; the published pair shows the inline success state
("Published — customers can use this now") with the toast visible and no dialog anywhere.

## Known limitations

- `stamp_target` is read from the draft's own programme row; the Programmes snapshot's
  `loyalty_programs` select does not carry it, so a firm whose only source is the published row
  starts step 3 from the product default of 8 until the draft is read.
- Editing an existing reward from the wizard sends only the three fields the inline form owns
  (name, points cost, company cost). `save_loyalty_reward_draft` coalesces every absent key from
  the existing version, so a description, image or store-credit value set in the full editor is
  preserved rather than blanked by a form that never showed it.
