# V324 — the Limited Offer page's three named buckets

Date: 2026-08-14
Branch: `codex/v324-rewards-offer-cosmetics`
Production-component source hash: `b5d0e274802732064a3e22cea1aa6036bac72938d93c28cf890aecd1cbc890be`

**Client-only. No migration, no new RPC.** Reuses `business_delete_promotion_v183` (applied
2026-08-06) exactly as the deep editor already calls it.

## The owner's request, verbatim

> "the only source of truth to show
> 1. published - ongoing promotions (with stated expiry - once expired goes to history, allow for
>    firms to delete if needed to and will be discard away)
> 2. Drafts (those unpublished ones, able to delete if needed to)
> 3. History ( expired only, deleted drafts please discard)"

Markup on the same screenshot also struck the duplicate "Limited Offer" heading, the
unpublished-changes banner, and the flat Promotions list, and circled an "Add +" control.

## What changed

The flat `growLimitedOfferListHtmlV319` list on `#/grow/offers` is replaced by three named
buckets — **Published / Draft / History** — behind a filter strip, plus a persistent "+ Add"
button in the page header.

**The drilled Promotions topic (reached by clicking the Promotions tile from Overview) is
untouched.** It still renders the original flat list via the same shared
`growLimitedOfferCategoryHtmlV319` the V319 wave built, because the owner's markup was on the
`#/grow/offers` rail page specifically — the drilled path is a second, narrower entry point this
change was not asked to touch, and `v319-rewards-and-offer.test.mjs`'s pin on that shared
definition being byte-identical is what proves it wasn't.

## The bucket rule — a date test first, `active` second

```js
const growOfferBucketV324=item=>{
  const ends=item.ends_at?new Date(item.ends_at):null;
  if(ends&&ends<=growOffersNowV324)return 'history';
  return item.active===true?'published':'draft';
};
```

- **Published** — `active===true` and not yet ended. Covers both live-now and scheduled offers;
  the owner's own words group both as "ongoing… with stated expiry".
- **Draft** — `active===false` and not yet ended. A promotion never published and never retired.
- **History** — `ends_at<=now`, **regardless of `active`**.

That last line is the one non-obvious call, and it exists because of what "delete" on a Published
row actually does server-side. `business_delete_promotion_v183` does **not** hard-delete a
published item — it **retires** it (`active=false`, `ends_at` pulled to `now()`), deliberately,
because `promotion_alert_runs_v122` and the attempt-receipts table still reference the id. Bucket
by `active` first and a retired item lands in Draft — false, and exactly the confusion the owner's
rule exists to prevent. Bucket by date first and it lands in History, reading exactly the way a
naturally-expired offer does — which is the correct fact: retiring early and letting the clock run
out are the same "no longer available" event from a customer's side. That is why the owner's two
separate sentences — "once expired goes to history" for Published, "will be discard away" for
deleting one — resolve to one rule, not two.

### A second bug the rule alone didn't catch — found by rendering, not reading

`promotionLifecycleV186` (the label source used elsewhere) checks `active` **before** `ends_at`,
so a retired item's own `label` is `'Draft'` — the same word a real, untouched draft gets. The
first render of this page showed a retired promotion sitting in History captioned "Draft", which
is the literal confusion the owner's heading ("History — expired only") exists to prevent. Fixed
by computing the History label directly from the date (`Ended {date}`) rather than trusting
`life.label` for a bucket it was never asked about. Both the naturally-ended and the
retired-while-published cases now read identically: `Ended 30 June 2026` / `Ended 14 August 2026`.

## Delete wording — the owner's one word, split back into two

The owner wrote "delete" for both Published and Draft. The buttons say **Retire** on Published and
**Delete** on Draft — matching the deep editor's own existing wording exactly
(`promotionsPage`, V183: *"the button says which of the two will happen"*), not the owner's single
word, because the two actions are materially different: a Published item's record survives
underneath (reports and alert history still reference it); a Draft's does not. Saying "Delete" for
both would reopen the exact honesty gap V183 was written to close. History rows have no delete
control — the owner's spec never asked for one, and there is nothing left to discard from a
settled record.

Both buttons call **the same RPC, with the same confirm wording and the same toast wording**, as
`promotionsPage`'s own delete flow — a second write path with different wording would be two
sources of truth for one action.

## Accessibility — a filter, not the peer-tab pattern this page's own test forbids

The strip is `role="group"` with `aria-pressed` buttons, not `role="tablist"`.
`v98-grow-unified-ux.test.mjs` forbids `role="tablist"` anywhere in `growPage` — a rule from an
earlier wave about NOT splitting the module's top-level navigation into peer tabs. This control
filters one sub-page's own data, the same shape as the existing "Away threshold" segment
(`role="group"`) elsewhere in this file — matching precedent, not inventing one, and it does not
trip that guard.

## Verification

**14 behavioural tests**, real bytes evaluated (`tests/business-ui/v324-limited-offer-buckets.test.mjs`):
the four bucket-membership cases including the retired-item case above; the tab strip's role and
pressed state; row rendering (counts, active-bucket-only, empty state); Retire-vs-Delete wording;
the retired-in-History label fix; no delete control on History or for a read-only viewer; the
click-wiring facts (tab switch touches no network, delete calls the real RPC with the real
wording); and the pinned wrapper strings this file's changes must not break.

**Rendered in real Chromium** with the actual production `<style>` and the actual extracted
`growOfferBucketV324` / `growOffersRowHtmlV324` / `growOffersTabStripV324` — three screenshots,
one per bucket, confirming the layout matches the sketch and the History-label bug is fixed.
Scratchpad-only, not checked in.

Suite: 3013 tests, 3011 pass — the one unrelated failure is the known env-bound
`tests/mobile` `@capacitor` check. Full validate pipeline green.
