# V324 — Published/Draft/History, corrected onto the wizard's Gifts step

Date: 2026-08-14
Branch: `codex/v324-rewards-offer-cosmetics`
Production-component source hash: `e29707b39b9e98c56ccd47a84fee2f38a4956de7ba8a31383077fd7a00e9ca0c`

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

Suite: 3045 tests, 3043 pass — the one unrelated failure is the known env-bound
`tests/mobile` `@capacitor` check. Full validate pipeline green.
