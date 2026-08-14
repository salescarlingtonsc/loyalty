# V324 — Point system's reward catalogue gets Published/Draft/History

Date: 2026-08-14
Branch: `codex/v324-rewards-offer-cosmetics`
Production-component source hash: `0d10fbd68a3d1d6b583004556bfa926695a5dd021bf2d8692ef3efbc5c6cef1b`

**Client-only. No migration, no new RPC, no new data source.**

## The owner's request

> "do the same for the individual programs: (points/ tiered membership (all 7 - attached).
> click into points system - it should similarly show
> 1. publish 2. draft 3. history (for point system rewards)"

Scoping decision, confirmed with the owner before building: apply this pattern one programme at a
time, starting with Points System. Referrals (a single set of rules, not a list of items) stays
as its current single-editor screen — "History" has no meaning for it.

## No new bucket logic — this reorganizes data that already existed

Unlike Limited Offer, Points System's three groups were **already computed**, just merged into
one continuous grid with History collapsed underneath:

- `rewardCardsV250` — live, scheduled or paused-with-programme rewards. **Published.**
- `growPendingNewRewardsV268` — rewards created in the current draft, never published, already
  rendered inline with a "Not live yet" pill and "Customers see this once you publish." **Draft.**
- `rewardHistoryCardsV294` — ended or retired rewards, previously inside a collapsed
  `<details>Reward history</details>`. **History.**

This change only reorganizes which group is showing, behind the same `.v150-segment` filter strip
built for Limited Offer. None of the three source lists moved, so their card markup
(`rewardCardHtmlV250`), their click routing (`data-rewards-overview-edit`), and the
`growTemplatesOpen` template flow are byte-identical to before.

## The one thing that had to be preserved carefully

The click handler that routes a reward card into the wizard's quick-edit form deliberately
**excludes** anything inside `[data-reward-history-v294]`:

> "The Reward-history cards... what an owner does there is un-archive a retired reward — a job
> the wizard's three-field form cannot do and does not show... Those cards therefore keep the full
> editor, which is where un-archiving lives."

Moving History from a collapsed `<details>` into its own tab meant that attribute had to move with
it, unchanged, onto the new tab-content wrapper — otherwise a retired reward's Edit would have
started silently opening the wrong screen. It did; verified by a dedicated test
(`V324 the History tab shows only rewardHistoryCardsV294, and keeps the wizard-bypass attribute`).

## Test footprint — the real risk in this change

Seven test files already pin `rewardCardGridV250` and its inputs (`v227`, `v229`, `v250`, `v268`,
`v271`, `v301`, plus a browser walkthrough script) — far more than Limited Offer's two, because
this component is one of the most heavily-used surfaces in the app. All seven pass unmodified
(83/83): every pinned boundary (`rewardCardsV250` → `rewardCardGridV250`'s declaration, the exact
`reward-card-add-v250` / `reward-card-pending-new-v268` / `reward-card-templates-v250` markup, the
`rewardCardGridV250` symbol appearing exactly twice) held without needing a single test edit,
because the restructuring only touches what's **between** those existing boundaries, not the
boundaries themselves.

`v98-grow-unified-ux.test.mjs`'s "no peer tabs" guard also still passes — the strip is
`role="group"` with `aria-pressed`, the same choice made for Limited Offer and for the matching
"Away threshold" segment elsewhere in the file, not `role="tablist"`.

## Verification

**10 new behavioural tests** (`tests/business-ui/v324-points-reward-tabs.test.mjs`), the real
`rewardCardStatusV250` / `rewardCardHtmlV250` / the new tab-strip template lifted verbatim and
evaluated: each tab shows only its own bucket; the Add card is Published-only; empty states; tab
counts and pressed state; `role="group"` not `"tablist"`; a read-only viewer sees no Add card;
tab-switching touches no network; the `rewardCardGridV250` symbol count; the router reset.

**Rendered in real Chromium** with the actual production `<style>` and the actual extracted
`rewardCardStatusV250` / `rewardCardHtmlV250` / tab-strip template — three screenshots, one per
bucket, clicked through with real Playwright clicks. No console errors. Scratchpad-only, not
checked in.

Suite: 3032 tests, 3030 pass — the one unrelated failure is the known env-bound
`tests/mobile` `@capacitor` check. Full validate pipeline green.
