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

    d52a5aa0fc4f43e650dcd7969a32f089e0887b9c5743d55f5d83d7f1554769d5

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

## V302 follow-up — the fix that did not reach the owner who reported it

The owner re-tested the shipped V301 build and reported no change: **"it still showing gift card
and same UI UX"**, from a workspace whose programme is PAUSED with four rewards and a published
configuration. Three defects, all confirmed against production before changing anything:

1. **The wizard never opened for them.** `growSetupEntryV301` excluded a paused programme that
   already carried a catalogue, on the theory that such a programme is being *managed*. Paused is
   the state a failed setup ATTEMPT ends in — so the one workspace that reported "setting up
   rewards does not work" was the exact state the fix could not reach, and its "Set up →" still
   fell through to the old drill and the old New-reward dialog. The gate is now `!loyaltyLive`:
   anything not running is unfinished setup. Nothing is withheld — the wizard carries a permanent
   **More reward settings** link (`#growSetupFullEditorV302`) into the full editor, which holds
   the tiers, archived rewards and reward history the drill holds.
2. **A published catalogue could vanish from step 3.** `create_loyalty_config_draft` copies the
   programme row and the tiers into a new draft but NOT the reward versions (that is what
   `ensure_published_reward_in_draft_v138` does, on demand, one reward at a time). Reading the
   draft alone showed an owner with four published rewards an empty step 3, inviting duplicates.
   The list is now published rewards MERGED with the draft's versions (`mergeRewardsV302`), draft
   winning per id, in both the initial state and every re-read.
3. **Editing a published reward could write NULLs onto it.** `save_loyalty_reward_draft` coalesces
   the fields it is not given from that reward's version *in this draft*; for a reward the draft
   had never carried there is none, so the wizard's three-field form would have stored a NULL
   description and fulfilment kind beside the edit, and publishing writes the draft's values onto
   `loyalty_rewards`. The wizard now performs the same ensure-then-edit the full editor does.

Checked and found safe, so deliberately NOT changed: `publish_loyalty_config` UPDATEs
`loyalty_rewards` from the draft's reward versions via a join and leaves rows the draft does not
carry untouched — a partial draft can never delete a published reward. (Tiers are delete+insert;
rewards are not.)

Regression: walkthrough step **(i)** puts the fixture into the owner's own reported shape —
published configuration, paused programme, existing reward — and proves the tile opens the wizard,
that step 3 lists the published reward the fresh draft does not carry, that Edit loads it inline
with no dialog, and that `ensure_published_reward_in_draft_v138` precedes the write. Verified
red-first: with the V301 gate restored, step (i) fails at the tile click.

`verify-v294-owner-batch-walkthrough` steps 5a/6 now switch their fixture's programme ON for the
reward-card grid — the grid is the surface a RUNNING programme's owner drills into — and switch it
back. Every assertion in them is unchanged, which is the point: widening the wizard's entry took no
capability away.

Suite 2838/2838; V301 (a–i), V293, V294, V296 walkthroughs pass on the V302 bundles.

## V303 follow-up — the wizard becomes the loyalty module's only front door

Owner re-test on the deployed V302 build, with screenshots: (1) "remove gift cards from the
business UI entirely"; (2) "tiered membership / stamps - still not able to build like points" —
the tiers card still landed on the old drill and model-picker editor; (3) "pressing add rewards -
still brings me to this page" — the old New-reward dialog, from a LIVE programme's grid. The V302
gate stopped at `!loyaltyLive`, so a live programme's owner still got every old surface.

Shipped: the three point-engine cards (Points System / Tiered membership / Stamp card) open the
wizard ALWAYS — live or not, prefilled, labelled "Edit →" when running. Step 1 offers the same
four models as the editor (Points System · Tiered membership · Points + tiers · Stamp card). A
model with tiers runs FIVE steps — Choose · Earning · Tiers · Reward · Go live — with an inline
tier ladder (name + threshold, one-tap Bronze/Silver/Gold defaults) writing through
`save_loyalty_tier_draft_v143`; the full tier row is read and carried so a wizard edit can never
blank multipliers or benefits set in the advanced editor. `businesses.points_mode` (an instant
live switch) is applied only AFTER `publish_loyalty_config` succeeds, stated in plain words on
the Go-live step, with an honest inline retry that never claims the publish failed. Add reward
and per-reward Edit on the live grid land on the wizard's Reward step with the form armed — the
old dialog is no longer reachable from any primary path (reward-history un-archiving keeps the
full editor, one click away behind "More reward settings"). "Start from a template" now arms the
wizard's inline form instead of the dialog.

Gift cards are out of the business UI: no Serve & sell nav row, no Customer Interface sub-tab or
switch, and `#/giftcards` is refused with a plain toast. Kept deliberately: the module key in
entitlement lists (server truth other tenants' scopes are written against), read-side reporting
of historical gift-card sales, the customer wallet's gift credit, and all DB code.
**Known consequence, flagged:** `redeem_gift_card_at_branch_v117`'s only call site was the
removed page, so an outstanding card balance is no longer redeemable from the business UI — the
one such card lives on the owner's demo tenant.

Walkthrough steps j–m pin the report: a LIVE fixture (4 rewards, 3 tiers, published config) —
all three cards open the wizard with zero `.modal`; the tiers build fires the tier RPC then
publish THEN the mode write, in order; Add/Edit from the live grid reach the wizard, never the
dialog; gift cards absent from nav and Customer Interface with the route refused. Suite
2841/2841; V301 (a–m), V293, V294, V296 walkthroughs pass on the V303 bundles.
