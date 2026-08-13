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

    909465a464dfd950d89cac3c8bac2e114f03e0d63adf619586560ce16b959750

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

## V304 follow-up — the two list steps save themselves

Owner re-test of the deployed V303 build. First line: **"the UI UX is working now"** — the shape is
right, so nothing was restructured. Three defects inside it:

1. **"i typed the points or cost needed for points redemption - but not reflected in the system and
   not auto saved (it needs to reflect as i change it, so will not have confusion)"**
2. **"i need to be able to add extra tier / delete tier"**
3. **"for rewards subtab - i need to be able to add or delete. because now i need to press 'next'
   then press 'back' to view changes"**

One root cause behind all three: the Reward and Tiers steps wrote **only** inside `advance()`. The
list above the form therefore could not change until the owner left the step and came back, a
second reward or tier could not be added without advancing, and nothing could be removed at all.
The write itself was never wrong, so it was lifted out rather than rewritten.

**Shared writers.** `saveRewardFormV304` (V302's ensure-then-edit materialisation + the V293
three-field edit envelope) and `saveTierFormV304` / `writeTierRowV304`
(`save_loyalty_tier_draft_v143`, full row carried) are now the single writer for each step, called
by **all four** intents: the new in-form button, the debounced auto-save, Remove/Undo, and Next.
`advance()` keeps no second copy of either write.

**In-form action.** `#growSetupRewardSaveV304` ("Add reward" / "Save") and
`#growSetupTierSaveV304` ("Add tier" / "Save") sit inside the form card. Pressing one performs the
write and re-renders the step **in place** — the list gains the row, the form clears, focus returns
to the name field, and the affected row flashes "· Saved ✓". The step number never changes.

**Live reflection.** While the form is editing a listed row, typing patches that row's name and
number straight into the DOM (never a per-keystroke re-render, so the caret is never moved) and
marks it "· editing". Both the render and the patch compose their text through the same
`rewardRowPointsTextV304` / `tierRowThresholdTextV304` helper, so the optimistic line cannot drift
from the rendered one — and interpolated runtime copy stays in a named function, which is what the
v97 pin requires.

**Auto-save.** 900ms after the last keystroke, for an **existing** row only — a half-typed new
reward is never written, which would spawn junk rows. The button and Next flush the pending timer
before performing the identical write, so one intent is never two.

**Save serialisation.** Every save runs through one promise chain (`runSaveV304`). Both writers
carry the snapshot hash they last read and the server bumps it on each write, so two in flight
together means the second is stale (40001). `retryOnConflictV304` re-reads the draft and retries
**once**, silently, for the case the chain cannot see — another tab, or the deep editor.

**Remove, with undo, no dialogs.** Every row carries Remove beside Edit. Remove is the archive
write through the same writer (`active:false`); the row keeps its place for the rest of the visit,
muted and dashed, with an Undo that writes `active:true` back. No `confirm()` and no modal — the
undo **is** the safety, and the wizard's "never inserts a dialog" pin still holds. Removing the
last active tier of a tier model is refused inline ("Keep at least one tier, or switch model in
Choose."); the last active reward likewise, because the step's own validation already requires one.

**The list now carries `active`.** `rewardListFrom`/`tierListFrom` no longer filter on it; the
archived rows are dropped **once**, after the merge, at state init. This fixed a real latent bug as
well as enabling Undo: filtering before `mergeRewardsV302` dropped the draft's `active:false`
version, so the published row that still said active won the merge and a removed reward reappeared
on the step. Step counts and the "at least one reward/tier" validation count only active rows, and
the Go-live summary lists only what a customer can still claim. The publish change list already
prints an archived reward as "no longer offered" (`growSetupComparisonV301`), verified unchanged.

**Known limitation, unchanged by this release:** tier changes are not in the Go-live change list at
all — `growSetupComparisonV301` compares the programme row, rewards, birthday and bring-back, and
never carried tiers. A removed tier therefore publishes correctly (tiers are delete+insert) but is
not itemised on the Go-live step. Out of scope here; flagged rather than fixed.

### Verification (this tree)

- `node --check app/app.js` OK; `npm run bundle-stamp:check` current
  (core 332KB · auth 23KB · customer 380KB · business 1712KB · i18n 208KB).
- `npm test`: **2846 pass / 0 fail** (2841 at the V303 baseline; the five new V304 tests are the delta).
- `tests/business-ui/v301-programmes-setup-wizard.test.mjs`: 30 tests (5 new V304 tests).
- Browser walkthroughs (real bundles, stubbed client): **v301 a–n PASS**, v296 1–7 PASS,
  v294 1–9 PASS, v293 a–g PASS.
- Nine fixtures regenerated from source; Chrome captures re-run for
  `v104-promotions-production-render-metrics.json` (PASS) and `v142-connect-paynow-pos/metrics.json`
  (PASS).

Walkthrough step **(n)** pins the report end to end against the LIVE fixture: "Add reward" grows
the list with `data-grow-setup-step-v301` unchanged; editing a listed reward shows the new cost in
the row **before** any write and with no RPC yet recorded, then auto-saves ~900ms later
(`ensure_published_reward_in_draft_v138` first, exactly as Next did) and clears "· editing";
Remove records `active:false` and leaves "Removed · Undo"; Undo records `active:true`; "Add tier"
grows the ladder in place; three tier removals record `active:false` each; and the fourth is
refused inline with zero writes. Zero `.modal` at every point.

## V304 follow-up — the list tells the truth while you type

Owner, on the live V303 build: the UX works, but a typed points cost was "not reflected in the
system and not auto saved", tiers need add/delete, and rewards need add/delete "because now i
need to press next then press back to view changes". Root cause: both steps persisted only on
Next, so the rows above the form lagged one navigation behind the owner's own edits.

Shipped, same pattern on the Reward and Tiers steps: an in-form **Add / Save** button that writes
immediately through the same draft writers and refreshes the list in place; live row reflection
while editing (the row's own text updates as the owner types, "· editing" until saved); a 900ms
debounced auto-save for edits to existing rows (never for half-typed new ones), serialized
through one promise chain with a single silent re-read-and-retry on a snapshot-hash conflict;
and per-row **Remove · Undo** (the archive write, `active:false`, with undo re-activating — no
dialogs). Removing the last active tier of a tier model, or the last reward, is refused inline.
Fixed en route: `rewardListFrom` filtered archived rows BEFORE the published/draft merge, so a
draft's `active:false` could be resurrected by the published row — the filter now runs after.
Known gap (pre-existing, flagged): the Go-live change list does not itemise tier changes.

Walkthrough step (n) pins it on the LIVE fixture: add-in-place without leaving the step, row text
updating before any save, the auto-save firing with the typed cost, Remove/Undo writing
`active:false`/`true`, and the last-tier guard. Suite 2846/2846; V301 (a–n), V293, V294, V296
walkthroughs pass on the V304 bundles.

## V305 — four scenarios, four step lists, and integrity said out loud

Owner, 2026-08-13, on the shipped V304 build:

> "when i press 'tiered membership' - it shows both tier & points? can you explain the logic?"
> "firms should be able to choose either they wants points only / tiered only / tier + points /
> stamps - these are 4 scenarios"
> "so if the points only rewards is already activated and firms press tier + points (technically
> the points structure remains the same and just needs to edit the tiered membership) - vice versa"
> "you need to ensure programs integrity"

**The logic could not be explained because it was wrong.** Tiered membership ran
Choose · Earning · Tiers · Reward · Go live, and two of those five steps contradict the engine the
card selects:

- **`points_mode='tiers'` turns redemption OFF.** `growTiersModeNoteV229` already says so on the
  Programmes page itself — rewards stay saved, customers cannot claim them while tiers run alone.
  A Reward step was therefore inviting the owner to price rewards the engine will refuse.
- **`tier_basis='visits'` — the default — means the points earn rate does not touch climbing.**
  An earn-rate step asked for a number that changes nothing about the ladder being built.

### Shipped

**A. Per-scenario step lists.** The step-list mechanism V303 introduced now carries four lists, and
`data-grow-setup-step-v301` still numbers against whichever is active:

| Card | Steps |
| --- | --- |
| Points System (`redeem`) | Choose · Earning · Reward · Go live (unchanged) |
| **Tiered membership (`tiers`)** | **Choose · Climbing · Tiers · Go live — no Reward step** |
| Points + tiers (`both`) | Choose · Earning · Tiers · Reward · Go live (unchanged five) |
| Stamp card (`stamps`) | Choose · Earning · Reward · Go live (unchanged) |

New step kind `climb` — "How do customers climb tiers?" — offers **Visits** (default, from the
stored `tier_basis`) and **Points earned**. Choosing Points reveals the earn-rate sentence inline
on the same step, reusing the Earning step's own `#growSetupEarnV301` input so `readStepFields`,
the live example and the input listener stay one implementation. Next saves `{tier_basis}` plus the
earn fields through `save_loyalty_config_draft` — the row build is now `programRowV305`, shared with
the Earning step so a tiers-only draft and a points draft carry the identical field set. Points +
tiers instead carries a compact **"Tier level is earned by"** control at the *top* of the Tiers
step (above the thresholds it re-units), saved with that step's Next and only when it changed.
The "at least one reward" rule lives inside the reward branch, which tiers-only never reaches; the
"at least one tier" rule applies to both tier models, unchanged. The reward hand-off
(`pendingGrowSetupRewardV303`) and the success panel's "Add another reward" are both suppressed
where the active list has no Reward step — `stepNumberOrNullV305` distinguishes "no such step" from
"the last step", which the old fallback could not.

**B. Integrity said out loud.** `GROW_SETUP_INTEGRITY_V305` is the full twelve-direction matrix,
shown as one plain line under step 1's cards whenever the highlighted card differs from what is
live:

| live → chosen | line |
| --- | --- |
| points → tiers only | Your rewards stay saved, but customers cannot claim them while Tiered membership runs alone. |
| points → points + tiers | Your points set-up stays exactly as it is — you are only adding tiers. |
| points → stamps | Your points programme stays saved. The stamp card replaces it for customers. |
| tiers only → points | Your tiers stay saved and stop being what customers see. Customers can claim point rewards again. |
| tiers only → points + tiers | Your tiers stay exactly as they are — you are only letting customers claim rewards again. |
| tiers only → stamps | Your tiers and points stay saved. The stamp card replaces them for customers. |
| points + tiers → points | Tiers stop showing to customers but stay saved. Points continue unchanged. |
| points + tiers → tiers only | Your tiers continue unchanged. Rewards stay saved, but customers cannot claim them while Tiered membership runs alone. |
| points + tiers → stamps | Your points and tiers stay saved. The stamp card replaces them for customers. |
| stamps → points | Your stamp card stays saved. Customers collect points for rewards instead. |
| stamps → tiers only | Your stamp card stays saved. Points build tiers instead, and rewards cannot be claimed while tiers run alone. |
| stamps → points + tiers | Your stamp card stays saved. Points buy rewards and build tiers instead. |

The Go-live mode lines (`modeChangeLineV303`) now name what survives too — "…customers stop
claiming point rewards. **Every reward you set up stays saved.**" / "…side by side. **Nothing you
have already set up changes.**" — and a tiers-only programme additionally carries
`data-grow-setup-claimline-v305` whether or not the mode is *changing*, because the consequence is
true of the state being published either way. The Go-live summary for tiers-only describes the
**ladder**, not the catalogue this mode will not let customers claim.

**C. No destructive writes.** The wizard's data surface is now pinned by an exact allowlist test:
RPCs are precisely `create_loyalty_config_draft`, `save_loyalty_config_draft`,
`save_loyalty_tier_draft_v143`, `ensure_published_reward_in_draft_v138`,
`get_loyalty_reward_draft`, `preview_publish_impact`, `publish_loyalty_config`; table access is
precisely `businesses.update` (the `points_mode` switch). No `.delete()`, in any spelling. Removal
remains an archive write (`active:false`) through the same helper, with Undo writing `active:true`.

### Fixed en route — the change list contradicted the promise

`growSetupComparisonV301` fed **every** live reward into `growRewardPendingChangesV291`. A draft
legitimately carries only the reward versions it has been made to carry —
`create_loyalty_config_draft` copies the programme row and the tiers, never the rewards — so every
untouched reward landed in the helper's `removed` bucket and the Go-live step printed
"Free flat white — no longer offered" for the whole catalogue, directly beneath a line promising
they stay saved. `publish_loyalty_config` does no such thing: it UPDATEs from the versions the draft
holds and leaves untouched rows alone. The comparison's live side is now scoped to the ids the
draft actually carries — exactly the set publishing can change. An archived reward is still
reported, as "Offered: Yes → No", because the draft carries that version.

The walkthrough stub carried the same misconception (`publish_loyalty_config` replaced
`loyalty_rewards`/`loyalty_tiers` wholesale with the draft's versions). It now upserts, matching the
server, which is what makes the "nothing was destroyed" assertion in step (o) meaningful rather
than a test of the stub's shortcut.

### Verification (this tree)

- `node --check app/app.js` OK; `npm run bundle-stamp:check` current
  (core 332KB · auth 23KB · customer 380KB · business 1728KB · i18n 208KB).
- `npm test`: **2853 pass / 0 fail** (2846 at the V304 baseline; the seven new V305 tests are the
  delta — six in the wizard suite plus the change-list scoping pin).
- `tests/business-ui/v301-programmes-setup-wizard.test.mjs`: **37 tests** (30 at V304). Three
  existing pins were updated with V305 comments (the step-list shape, the programme-row helper the
  Earning branch now calls, and the gated reward hand-off), and one of them —
  `V301 (b) step 2 mirrors the #lsave field set` — was found to be passing **vacuously**: its
  `state.step===2` slice had matched nothing since V303 moved to kind-based dispatch. It now slices
  `programRowV305` and asserts the slice is non-empty. `tests/business-ui/v172-reward-templates.test.mjs`
  re-anchored on the hand-off declaration name.
- Browser walkthroughs (real bundles, stubbed client): **v301 a–o PASS**, v296 1–7 PASS,
  v294 1–9 PASS, v293 a–g PASS. Zero page errors in all runs.
- Nine fixtures regenerated from source; Chrome captures re-run on 4173 for
  `v142-connect-paynow-pos/metrics.json` (PASS) and
  `v104-promotions-production-render-metrics.json` (PASS).

Walkthrough step **(o)** pins the report on the LIVE points fixture: the Tiered membership stepper
reads Choose · Climbing · Tiers · Go live with **no Reward chip**; the integrity line on step 1
carries `data-grow-setup-integrity-v305="redeem>tiers"` and switches to `redeem>both` when the
highlighted card does, and disappears entirely on the model that is already live; Climbing defaults
to Visits with **no earn input rendered**, and choosing "Points earned" reveals it; Next records
`{tier_basis:'points', earn_points_per_dollar:3}`; the ladder's threshold label flips to Points;
Go live carries both the preserved-wording mode line and the cannot-claim line; publish records
`points_mode='tiers'` **after** `publish_loyalty_config`; **not one reward write of any kind** is
recorded across the whole switch and all four rewards are still in the table afterwards; and the
success panel offers no "Add another reward". Then Points + tiers: five steps, Earning untouched,
the basis control present on the Tiers step and re-labelling the threshold on the spot.

**Known limitation, unchanged:** tier changes are still not itemised in the Go-live change list —
`growSetupComparisonV301` compares the programme row, rewards, birthday and bring-back, and has
never carried tiers. Flagged rather than fixed; out of scope here.

## V305 follow-up — four scenarios, four step lists, integrity said out loud

Owner: "when i press 'tiered membership' - it shows both tier & points? can you explain the
logic?" / the four scenarios (points only / tiered only / tier + points / stamps) / switching
must preserve the other engine's structure / "you need to ensure programs integrity".

The logic WAS wrong for tiers-only: a Reward step priced rewards `points_mode='tiers'` refuses,
and the earn-rate step changed nothing under the default `tier_basis='visits'`. Tiers-only now
runs Choose · **Climbing** · Tiers · Go live — Climbing asks the one deciding question (visits or
points earned) and reveals the earn-rate sentence only under a points basis. Points + tiers keeps
its five steps and gains the same basis control atop its Tiers step. Step 1 shows a 12-direction
integrity line whenever the highlighted card differs from the live model (each line restates what
the engine already preserves — nothing is deleted by any switch), and the Go-live mode lines name
what survives; tiers-only carries the cannot-claim line always.

Fixed en route (integrity would have been contradicted on the very screen promising it): the
Go-live comparison fed EVERY live reward into the V291 differ, so a draft carrying no reward
versions — the normal case — printed the whole catalogue as "no longer offered".
`publish_loyalty_config` updates only from draft-carried versions, so the comparison is now
scoped to exactly that set; an archived reward still shows as "Offered: Yes → No". The
walkthrough stub's publish was also corrected from wholesale replace to production's upsert
semantics so "nothing destroyed" is a real assertion, not a measurement of the stub.

Walkthrough step (o) pins it on the LIVE points fixture: tiers-only stepper has no Reward chip,
Climbing defaults to Visits with no earn input, Points reveals it and Next records tier_basis,
the step-1 integrity line renders, publish applies mode after publish, and the reward table
survives untouched. Suite 2853/2853; V301 (a–o), V293, V294, V296 pass on the V305 bundles.
