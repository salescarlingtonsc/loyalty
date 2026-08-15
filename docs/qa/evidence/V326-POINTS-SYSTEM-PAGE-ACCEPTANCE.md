# V326 — the Points System page (Photo 3), tile rewiring, edit-jump, and the add-gift flow

Date: 2026-08-15
Branch: `codex/v324-rewards-offer-cosmetics`
Production-component source hash: `e9cb244838721a437f8a171d8cff6cd95bc0be73e59e2af27cfa4c07ccf37821`

Third and final increment of the owner's 5-photo Points System flow. Photo 1 (the banner removal)
shipped in [V324-REMOVE-LIST-DRAFT-BANNER-ACCEPTANCE.md](V324-REMOVE-LIST-DRAFT-BANNER-ACCEPTANCE.md);
the database layer (Photos 3/4's data model) shipped in
[V326-POINTS-GIFT-LIFECYCLE-ACCEPTANCE.md](V326-POINTS-GIFT-LIFECYCLE-ACCEPTANCE.md). This is the
client — the new `#/grow/points` page itself, the tile rewiring, the wizard edit-jump, and the
add-gift flow — built on top of that already-verified, already-deployed schema.

## What shipped, against the owner's own photo annotations

- **Photo 1** (done previously): the unpublished-changes banner removed from the Rewards Programme
  list.
- **Photo 2** ("clicked into point system > photo 3"): the Points System tile now opens the new
  page unconditionally — `if(tile.dataset.growTopicV229==='points')return nav('#/grow/points');`,
  checked before `growSetupEntryV301` is even consulted. Tiers and stamps are untouched and still
  open the wizard, per the owner's own queue order (they're next, not now).
- **Photo 3** ("able to toggle on/off for whole point system OR individual gifts... add a delete
  button... which will land in history"): the new page. Published | History tabs (no Draft — every
  change here is immediate-write). A "Point system" summary row with the earn-rate text, an
  on/off toggle that reuses the EXACT R6 mechanism (`writeProgrammeSwitchesV314` /
  `data-grow-switchtoggle-v322`, scoped to `kind="points"` — one more row in that confirm/cancel
  micro-UI, not a second one), an "Add gifts" button, and an "edit" link. Each gift row has its own
  on/off toggle (`business_set_reward_paused_v326`) and a Delete button
  (`business_delete_reward_v326`) that moves it to History, behind a confirm.
- **Photos 4-5** ("edit... jump specifically into wizard's Earning and Expiry steps... click 'add
  gift' > add new gift... prompt to add more or go back to photo 3"): the edit link sets a new
  `pendingGrowSetupRewardV303={mode:'earning'}` hand-off that lands the wizard on the Earning step
  specifically (not Gifts — gift management is this page's own job now), guarded on that step
  existing on the rail. The Add gifts button opens an inline name+points form on the page itself;
  saving calls `business_create_reward_v326` and shows an "Add another gift? / Done" prompt.

## The one real owner decision this needed before building

AskUserQuestion, 2026-08-15: for a business that has never set up a Points System, should the tile
still open the wizard for first-time setup, or should Photo 3 be the landing page even before
setup, with an empty state? **Owner chose "Photo 3 always, with an empty state."** The tile now
routes to `#/grow/points` unconditionally — configured or not, live or not — and the new page shows
either the full summary+gift-list content or a "Points System is not set up yet" prompt whose CTA
does what the tile used to do (`pendingGrowSetupModelV303={kind:'points',from:'points'}` into the
wizard). The empty/full split is the same test the tile's own summary line already used
(`liveLoyaltyModelKeysV240.includes('redeem')`) — points counts as "configured" the moment it is
the live loyalty MODEL, whether currently on or administratively paused.

## Verification — the two failure classes from earlier this session, both re-checked

Two real misses earlier in this session (wrong screen, then wrong step — both from verifying code
correctness in isolation instead of the actual click path) set the bar here: every routing and
step-landing claim below is proven by **executing the real code sliced verbatim from app.js**
(`new Function`), not by reading it and asserting it looks right.

- **Tile → page.** `outerMain.querySelectorAll('[data-grow-topic-v229]')`'s click handler,
  executed for `'points'`, `'tiers'`, `'stamps'`, and a plain drill key, against both
  `canSetupGrow: true` and `false` — confirms `nav('#/grow/points')` fires for points in every
  case, before `growSetupEntryV301` is ever reached, while tiers/stamps are untouched.
- **Hash → view.** `programmeView`, `hashParamIsProgrammeView` and `growCategoryViewV271`,
  executed for `hashParam='points'` and others — confirms it resolves to the `'points'` view, is
  recognised as a page (not handed to `mountGrowSurface` as a deep-link editor action — a real gap
  the research for this build actually found and fixed, not merely re-verified), and is excluded
  from the drilled-category branch.
- **Edit link → wizard step.** The real `rewardHandoffV303` block plus `railW6I2`, executed for a
  points-only rail (`mode:'earning'` → step 2, "Earning"), a points+tiers rail (still step 2), the
  pre-existing `mode:'view'` hand-off (still step 3, "Gifts" — unaffected), and a stamps-only rail
  with no Earning step at all (stays step 1, does not crash or misland).
- **Page content**, executed with synthetic snapshot data across 9 scenarios: not-configured →
  empty state with the setup CTA; loyalty not included → its own empty state, no CTA; configured →
  summary row with earn-rate text, ON pill, edit/add/toggle controls; Published tab shows a live
  gift with "Turn off" and a paused gift with "Turn on", excludes retired rewards; History tab
  shows only the retired reward with no toggle/delete controls; delete-confirm opens for exactly
  the pending gift; the add-gift form preserves in-progress values and the post-save prompt shows
  "Add another gift" / "Done"; read-only staff sees the same state with zero interactive controls.
- **RPC call shapes.** The three new immediate-write RPC calls
  (`business_set_reward_paused_v326`/`business_delete_reward_v326`/`business_create_reward_v326`)
  match the exact parameter names the v326 migration's functions declare, and none of the confirm-
  panel-opening interactions (switching tabs, opening a delete confirm) touch the network — only
  the actual confirm/save clicks do.

All of this is now a persisted suite, not a one-off script:
`tests/business-ui/v326-points-system-page.test.mjs`, 16/16 passing. The pre-existing tile-click
and wizard-hand-off tests that pinned the now-superseded behaviour
(`tests/business-ui/v324-wizard-gifts-tabs.test.mjs`) were updated in place, not deleted, with the
supersession recorded inline.

Full `npm run validate`: 3050 tests, 3049 pass — the one failure is the pre-existing, environment-
bound `tests/mobile/v131-store-publication-readiness.test.mjs` Capacitor privacy-manifest check,
unrelated to this change.

## Not yet built (owner's queue, explicitly not guessed at here)

Tiered membership, Stamp card, Memberships, and Lifestyle bring-back rules each get the same
Published/History treatment next, one at a time, with the same click-path-first verification
discipline this file follows. Referrals is excluded — a single-config screen with no list to
bucket, confirmed earlier this session.
