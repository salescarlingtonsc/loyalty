# V421 — the Rewards Overview browser harness runs again

Date: 22 August 2026
Scope: `tests/browser/reward-overview-owner-visual.html` (its generator) and
`tests/browser/verify-reward-overview-owner.mjs` (its capture walkthrough). No production
behaviour, data or copy changed — every edit is in the harness.

Extracted production component hash for the reward-overview browser fixture:
`92d3cc958c040859c778db5c67a13686b30e7f6c2cb1bb58c2d8f7a0de102047`

## What was wrong

The fixture had stopped rendering. Loading it produced a page stuck on **"Loading Programmes…"**,
and the walkthrough timed out on `#rewardJourneyTitle`. Nothing surfaced it, because the only
suite that reads this fixture (`tests/business-ui/v128-simple-rewards-setup.test.mjs`) compares the
checked-in file's own hash against an evidence document — so a fixture that no longer matched its
generator, and could not run at all, stayed green.

Regenerating it from `origin/main` produced a **different hash** than the checked-in file, which is
how long it had been drifting.

## Why it stopped: seven missing declarations, all stub drift

`growPage` is extracted from production whole; everything it *reads* has to be there too, and it
was not. Each fault threw a `ReferenceError` before the first paint:

| missing | what it is | fix |
|---|---|---|
| `growUsageFromV386` / `growUsageToV386` | the usage table's date window | extract the whole Grow module state block |
| `programmeSpineRowsV314` + the V375/V378 unit helpers | which programmes are running, and whether the firm counts points or stamps | extracted from production |
| `STATUS_WORDS` | the one source of truth every availability pill reads | extracted |
| `GROW_PROGRAMME_VIEWS_V371` | the view list `growPage` matches its own hash against — it sits one line above the function, so the old slice missed it | anchor the slice one declaration earlier |
| `promotionDateShortV324` | the dd/mm/yyyy formatter the tables print through | extract both formatters instead of hand-restating one |
| `growUsageQuickRangesV388` and its comparison arithmetic | This week / Last month | extracted |
| `customerMediaUrlV95` | turns a stored object path into a gift photo url | extracted (its whitelist of image kinds is a v418 rule) |

A ninth stub was replaced for a different reason: **`CUI` was hand-written**, and its `icon()`
mapped eight names to bullet characters. On a page whose entire v401 pass was about icons, that
made this fixture say nothing about the thing it was evidence of. The real shared library
(`app/customer-ui.js`) is inlined now — the same object production binds `CUI` to — so the
captures show the real glyphs, and an icon change restales this evidence exactly as a render
change does.

The Grow state block is now extracted **whole** rather than restated variable by variable, which is
the drift that produced this in the first place.

Two further harness faults, found once it rendered:

- **`nav()` was a no-op.** Every tile that drills — `#/grow/points`, `#/grow/tiers`,
  `#/grow/bringback`, which is how this landing has worked since V326/V331/V358 — did nothing when
  clicked, so the walkthrough could only ever see the landing. It routes for real now.
- **The Bring-back page had no data.** It reads `bringback_campaigns_v361`; the fixture carried
  `retention_programs`, which is what the *old* overview rows read. The page the tile opens was
  therefore permanently empty. One live campaign and one paused campaign are stubbed now.

## The walkthrough, brought up to the page that exists

It had been frozen at the page as it stood in early August:

- **`#growAutoSetup` no longer exists.** It was deleted in `190baf6` (6 August) when Programmes was
  simplified to one list, and six unit tests that pinned it were re-pointed in that same commit.
  This harness was not, because it had already stopped running. The ~120 lines that drove it are
  removed, with the reason recorded in the file. The dialog itself (`openRewardsAutoSetup`) is
  alive but its one remaining caller is the Bring-back cold start, a shape this fixture cannot
  express — driving it from anywhere else would be evidence of a flow the product does not have.
- **`.grow-programme-row` / `data-programme-kind` became `.grow-topic-card-v343` /
  `data-grow-topic-v229`** in the V343/V362 restructure: seven tiles, one per programme family.
  Memberships and Gift cards left this page entirely. Individual rewards and Bring-back rules left
  it too — they live on the page their tile opens.
- **`#growSecondarySettings`** — the collapsed disclosure two assertions were about — is gone; its
  sections became their own views.
- The two **exact-id** invariants (two rewards sharing a name; two Bring-back campaigns) are the
  most valuable thing this file guards, and both are re-pointed at their current doors:
  `data-grow-points-gift-edit-v343` and `data-grow-bb-edit-v361`. Both verified to open the record
  that was pressed and not its twin.

## One finding, recorded rather than asserted away

`growTopicActionV244` picks a tile's action word from the tile's **status alone** and never
consults `canSetupGrow`. A read-only manager is therefore offered **"Turn on →"** on a tier ladder
and **"Set up →"** on a welcome gift. Nothing breaks if they press it — the destination page gates
the write — but they are promised an action they do not have. The walkthrough now pins the
manager's action words so that fixing this is a deliberate, visible change rather than a silent
one. Not fixed here: this pass changed no production code.

## Result

`node tests/browser/verify-reward-overview-owner.mjs` → `PASS`, capturing nine screenshots at
1440, 844, 412, 390 and 375, for an owner and for a read-only manager. `npm test` green
(3269/3269), as are `quality`, `bundle-stamp:check`, `runtime-config:check`,
`migration-manifest:check` and `canonical-migrations:check`.

One measured observation, not a defect: at 375px the **All / On / Not set up / History** strip is
399px against a 327px box and scrolls inside itself (`overflow-x:auto`), so History sits off the
right edge with no visible affordance. It is reachable, and it is pinned as a scroller so that a
later pass cannot quietly turn it into a clip.
