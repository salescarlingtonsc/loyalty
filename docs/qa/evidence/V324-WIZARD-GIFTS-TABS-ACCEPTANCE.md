# V324 — Published/Draft/History, corrected onto the wizard's Gifts step

Date: 2026-08-14
Branch: `codex/v324-rewards-offer-cosmetics`
Production-component source hash: `c465eb7d2e49e7c8407678b52cc8beb4b5d9c009e388647f2d0406de2a9a7143`

**Client-only. No migration, no new RPC.** Reuses `growRewardPendingChangesV291`, already shipped
and tested for Overview's pending-change markers.

## This corrects a real mistake in `V324-POINTS-REWARD-TABS-ACCEPTANCE.md`

That build put the Published/Draft/History tabs into `growPage`'s drilled `topicOnV229('points')`
category — the screen the "Points System" *tile* used to open. It shipped correctly (83 pinned
tests, 10 new tests, real Chromium render) but is **unreachable for an owner**:

```js
const growSetupEntryV301=key=>canSetupGrow&&['points','stamps','tiers'].includes(String(key||''));
```

Clicking Points, Tiered membership, or Stamp card sends an owner straight to the setup wizard,
unconditionally — "live or not" (V303's own comment, after **three separate owner rounds**
rejecting the drilled category as the editing surface: *"tiered membership / stamps - still not
able to build like points"*). The owner caught this by testing the actual click, not the code.

The earlier build is **left in place, not reverted** — it's still correct and still reachable for
a read-only staff member (`canSetupGrow===false` bypasses the wizard redirect), so it isn't dead
weight. But it is not what an owner sees, which is what this document corrects.

## What's actually on the reachable screen

The wizard's Gifts step (`stepThreeHtml()`) had no Published/Draft/History concept at all before
this change — one flat list (`state.rewards`), with a retired-during-this-session reward shown
inline as "· Removed" + Undo. No distinction between "currently live" and "added this session,
never published."

### The data problem this build had to solve, that Overview didn't

`state.rewards` is deliberately **pre-filtered at mount** (V304): rewards retired *before* this
wizard session opened are dropped entirely, so a reward removed in a *previous* visit never
reappears as a phantom "Removed" row this session didn't touch. That's correct for the existing
flat list, but it means `state.rewards` cannot answer "what's in History" on its own — a
pre-session-retired reward simply isn't there.

Fix: one merge (`mergedRewardsV324`), computed once, split into `state.rewards` (unchanged
filtered contract) and a new `state.rewardsAllV324` (the same merge, unfiltered) — both arrays
hold **the same object references** for every overlapping reward. A Remove/Undo click, which
mutates a reward object found via `state.rewards.find(...)`, is therefore visible from
`state.rewardsAllV324` immediately, with no second write path and no re-fetch. Verified by a
dedicated test asserting `state.rewards` and `state.rewardsAllV324` trace to one `mergeRewardsV302`
call, not two independent ones.

### The bucket rule

- **Published** — currently live (`active!==false`) and not only-in-draft. A live reward with an
  *unpublished edit* stays here, unmoved — it's still what customers see today; only the item's
  small "pending" marker changes, matching how the rest of the app already treats that case.
- **Draft** — live (`active!==false`) **and** present only in the current draft, never published.
  Computed from `growRewardPendingChangesV291({liveRewards: snapshot.rewards, draftRewards:
  snapshot.draftDetail.rewards}).added` — the exact same diff Overview already computes and tests,
  reused rather than reimplemented.
- **History** — `active===false`, read from `rewardsAllV324` (not `state.rewards`, which can't see
  a pre-session retirement at all — see above).

## Addendum — "still the same": the tabs existed but were two clicks away

Shipping the tabs onto the reachable screen wasn't the whole fix. The owner clicked "Points
System" twice after that deploy and landed on the wizard's **Programmes** step (Step 1 of 8) both
times — the same screen shown before any of this work started. The tile's click handler had only
ever carried *which model* to open the wizard on (`pendingGrowSetupModelV303`); it never said
*which step*, so every click — including "Edit" on an already-live programme — restarted the
five-screen walkthrough from the top. The tabs were real, but two Next-clicks away from where an
owner lands.

**Fix:** the tile click now reuses `pendingGrowSetupRewardV303` — the exact hand-off the
reward-card Edit path already uses to jump to the Gifts step — with a new `mode:'view'` that arms
no form, only moves `state.step`. Scoped to `kind==='points'` only: that hand-off recognises just
the `'reward'` step, so arming it for a Tiered/Stamp tile would silently no-op rather than jump
anywhere — worse than not trying, because it would read as fixed in the diff without being fixed
in the browser. Tiered/Stamp get this same treatment when their own tabs are built.

**A real bug caught mid-fix, before it shipped:** the hand-off consumer's existing branch was
`else if(rewardHandoffV303.mode!=='edit')`, which pre-fills an "Add reward" form — written when
`'add'` was the only other mode that existed. `mode:'view'` would have silently fallen into that
same branch and opened a **blank Add Reward form** instead of just landing on the tab view. Caught
by re-reading the consumer before assuming the new mode was safe to add, not by the tests (which
were written after, and could easily have encoded the same wrong assumption). Narrowed to
`mode==='add'` specifically, with a dedicated test pinning that the old catch-all is gone and a
second test confirming the original add-template path (used by "Start from a template") still
works — a fixed-length-slice test elsewhere in the suite (`v172-reward-templates.test.mjs`,
`app.slice(start, start+1600)`) caught a first version of this comment being too long and pushing
the real code past its window; shortened.

## Verification

**13 behavioural tests** (`tests/business-ui/v324-wizard-gifts-tabs.test.mjs`), real bytes lifted
and evaluated: the `growSetupEntryV301` premise this build depends on; the shared-merge assertion;
each bucket's membership including the pre-session-retired case that would silently vanish if
History read `state.rewards`; a live-with-pending-edit reward staying Published; the "Not live
yet" pill on Draft only; History rows being the exact existing "· Removed" + Undo markup, not a
new one; tab counts and pressed state; `role="group"`; empty states; tab-switch touching no
network; the diff reuse.

**A second real bug caught by rendering, not by writing tests**: the test harness in
`w6i2-programmes-home.test.mjs` builds `growSetupWizardV301` via `new Function(...)` with an
explicit, curated list of injected collaborators — `growRewardPendingChangesV291` and
`growRewardDiffOptionsFromSnapshotV291` weren't in it, because they're defined in `app.js` just
*before* the text range that harness slices out (unlike `mergeRewardsV302`, which happens to sit
lexically inside that range and so needed no change). Fifteen unrelated-looking wizard tests broke
with `ReferenceError`; fixed by injecting both functions the same way the harness already injects
`growSetupComparisonV301`. All 40 tests in that file pass, plus the 73 across the other two
wizard-pinned files (`v301-programmes-setup-wizard`, `v322-owner-rulings`).

**Rendered in real Chromium**, this time against a synthetic reward set matching the wizard's real
pre/post-session-retirement split (pre-session-retired items present only in `rewardsAllV324`) —
three screenshots, all three tabs, no console errors, visually identical row style to the actual
wizard the owner is looking at.

Suite (final, both passes): 3048 tests, 3046 pass — the one unrelated failure is the known
env-bound `tests/mobile` `@capacitor` check. Full validate pipeline green.
