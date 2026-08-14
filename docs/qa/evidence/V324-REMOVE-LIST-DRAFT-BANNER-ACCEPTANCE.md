# V324 — the unpublished-changes banner is gone from the Rewards Programme list

Date: 2026-08-14
Branch: `codex/v324-rewards-offer-cosmetics`
Production-component source hash: `0f6c949e434f4aa10c95ad6ac924ed3d2b145971f9a08e0095c84339bba31ead`

**Client-only. No migration.** First increment of a larger, multi-part flow the owner specified
across five annotated screenshots — see the queued work in
[[claim-v324-points-system-page]] for the rest.

## The owner's markup

Photo 1: the "You have unpublished changes… Review & publish" banner on the main Rewards
Programme list (`#/grow`, showing "Ongoing programmes" / "Pending setup") scribbled out —
*"remove this shaded area."*

## Scope: this one screen only, not the concept everywhere

`growUnpublishedMarkerV198` is a single shared render used across Overview, History, the drilled
categories, **and** the main list — one component, several call sites via one `programmeView`
condition. The owner marked up only the list view. The banner still answers a real question on
the others: Tiers, Referral, and the wizard's own edits still go through a draft/publish cycle
that hasn't been converted to immediate writes (only gifts are, in the queued work). Removing it
everywhere would have hidden that a Tier ladder edit sits unpublished, with no visible indicator
anywhere in the module.

Fix: `programmeView!=='list'` added to the existing `programmeView!=='setup'` exclusion — one new
clause on the same condition, not a second component and not a global deletion.

```js
const growUnpublishedMarkerV198=growDraftPendingId&&canRewards&&programmeView!=='setup'&&programmeView!=='list'
  ?`<div class="imp-note" id="growOverviewDraftBarV198" …
```

## Verification

**One pre-existing test updated, one new test added** (`v198-programmes-unpublished-marker.test.mjs`):
the source-text pin on the exact condition string was rewritten to match the new clause (a
required update — the string literally changed); a new test evaluates the **real predicate**
(lifted from `app.js` and run with `new Function`, not a regex) confirming `'list'` suppresses the
marker even with a pending draft while `'overview'` and `'history'` still show it — the property a
source-text match alone can't prove.

Suite: 3049 tests, 3047 pass — the one unrelated failure is the known env-bound
`tests/mobile` `@capacitor` check. Full validate pipeline green.
