# V296 — owner iPad markup 2026-08-12 (build bc8f299b3f19): acceptance evidence

Seven owner items across Customer 360, Gift cards, Customer Interface and the Programmes group.
UI only: no migration, no `db/`, no `supabase/`, no governance manifest touched.

## What shipped (owner's words in quotes)

1. **Customer 360 — the programme rows show the customer's own numbers.** The owner struck out
   the generic line "Earn 1 points for every SGD 1 spent, redeem on rewards" and wrote
   **"0 points"** beside the Paused pill. Each row in "Available Customer Programmes" now states
   THIS customer's standing: the points row prints their live balance (`300 points`) plus the next
   reward when the server projection reports one; a stamp-card programme prints stamps collected;
   the tier row prints the tier they are actually in, resolved from the firm's own `tier_basis`
   over figures already on the page (visits / lifetime spend), with one extra bounded read only
   when the basis is `points_earned`. An unreadable ladder says so — it never invents a tier.
   Promotion and referral rows keep their short customer-facing description (the owner circled
   those two approvingly). The trailing paragraph "This programme is paused, so nothing can be
   redeemed right now…" is deleted: the Paused pill already says it, and V259's real point — that
   paused is not "your points vanished" — is still made by the paused note on the summary card,
   beside the number it explains.

2. **Gift cards — the "Offer gift cards" block is gone** ("remove this"). First established that
   no equivalent control existed anywhere else: `set_gift_card_sales_enabled_v102` had exactly one
   call site in the whole app, this block. So the capability was **moved, not deleted** — same RPC,
   same copy, same owner-only authority — to a new **Customer Interface → Gift cards** sub-tab
   (item 3). The Gift cards page keeps the honest consequence: when issuance is off it still says
   so, and now says where to turn it back on. The **"← Back to Grow overview"** header button is
   removed from Gift cards and from every other grow submodule header that still carried it
   (Retention programs, Promotions, Referrals, Memberships); `growBackActionHtmlV138` is deleted.
   The one surviving "Back to Grow overview" is a recovery link inside an error card, not a header
   ornament. The rail's Programmes group is the way back now, on every page.

3. **Customer Interface is a nav group with sub-tabs** ("please make sub-tab under 'Customer
   Interface' so it will be easier to view. eg: Workspace & Brand, XX, XX"). Exactly the V294
   Programmes pattern: a `NAVGROUPS` entry declaring `views`, rendered by `navHtml` with
   active-state. `CUSTOMER_INTERFACE_VIEWS_V296` is the single source of truth the rail and the
   page both read — Preview · Workspace & brand · Customer programme · Sign-up & fields · Gift
   cards. Every section is still RENDERED and wired; the chosen sub-tab is the one shown, so
   nothing was removed and no control lost its handler. The bare `#/customer-interface` still lands
   on the preview, and the V269 Settings redirects now land on the section that absorbed each tab.

4. **The in-page Overview / List / History pill strip is removed** (owner circled it: "remove").
   The V294 rail children are that menu; the strip printed it a second time one line below.
   Only the control is gone: `programmeView` still resolves `overview`, `history` and the legacy
   `ongoing` / `available` / `settings` hashes, so every rail child and every existing deep link
   lands exactly where it did.

5. **The Promotions drill lists each promotion by title** ("when clicked in, can straightaway go
   inside see which promotions available"; sketch: "1. XXX / small details here, 2. XXX …", "can
   see what promo title"). The single aggregate row the owner struck out is replaced by one row
   per promotion: its title, a short detail line built from `promotionLifecycleV186` (the same
   predicate the customer surfaces publish against) plus its own offer facts, and its own action
   opening `#/promotions/<id>`. The count survives as a small header line. A final row adds another
   promotion, so the list is never a dead end.

6. **Pending-setup cards stop cross-referencing the live model** ("X NO — not linked to point").
   `otherModelLiveV235()` printed "<other model> is the live model" as the Tiered membership and
   Stamp card subtitles, and the Points card carried "Live model · set the earning rate and
   rewards". All four "Live model" cross-references are gone; each card keeps its status pill and
   the owner's benefit line, and any line that states an ERROR or the next action is untouched.

7. **"Points redemption" → "Points System"** (the owner struck "redemption" and wrote "System").
   Renamed on the programme card, the loyalty-model picker option, the model-name table, the
   classic-reward name and the Customer 360 row. The stored keys are untouched — the option value
   is still `redeem`, `loyalty_programs.loyalty_model` is still `classic`/`points_tiers` — so this
   is a label change and no customer's programme changes shape. The i18n catalogues
   (`WORKSPACE_GENERATED_COPY_V97` / `WORKSPACE_TEMPLATE_COPY_V97`) hold no key for any of these
   strings, so nothing there needed to move; the one new interpolated accessibility attribute (the
   Customer Interface section label) is classified `data-workspace-i18n`, which the v97 exhaustive
   classifier enforces.

8. **Gap sweep.** Fixed: the promotions drill was a single row with one "Manage" link and no way to
   create — it now lists every promotion with Edit plus an add row; `focusRoutedWorkspaceControl`
   on the Gift cards page still named `giftCardEnabled` as its fallback focus target after that
   control moved, so it resolved to nothing — retargeted to the amount field; the V269 Settings
   redirects landed on the top of Customer Interface rather than the section that absorbed the tab.
   **Deliberately left:** issued gift cards have no edit/delete — a card is an append-only ledger
   instrument and retiring one is a redemption, not a row deletion; a retired customer field can be
   renamed and retired but not deleted, because deleting it would orphan every answer recorded
   against it (V291's ruling, unchanged).

## Acceptance

`tests/browser/verify-v296-programmes-batch-walkthrough.mjs` — real stamped bundles, real router,
Chrome via `playwright-core`, recording Supabase fixture, served on **port 4196** (4173 belongs to
another worktree). PASS, steps 1-7: the c360 row shows "300 points" with no generic earn line and
no trailing paused paragraph while the Paused pill survives; the tier row states this customer's
standing; the Gift cards page carries neither "Offer gift cards" nor a back button while issue and
redeem still work; the Customer Interface group renders five children and each lands on its own
section with the others hidden, and the moved switch still writes `set_gift_card_sales_enabled_v102`;
no `[data-grow-view-v271]` pill remains while all three rail children and the three legacy deep
links still resolve; the promotions drill lists both promotions by title with their own
`#/promotions/<id>` actions and an add row; no card says "is the live model" or "Live model ·"; and
"Points System" appears in the tile and in the model picker while the option value stays `redeem`.

Re-run green after the change: `verify-v295-owner-fixes-walkthrough.mjs` (ports 4198),
`verify-v294-owner-batch-walkthrough.mjs` (4197), `verify-v293-reward-editor-walkthrough.mjs` (4199).

Full triage: zero new failures against the `origin/main` baseline. The one known pre-existing
failure (`tests/mobile/v131-store-publication-readiness`) is unchanged.

## Regenerated fixtures

- `tests/browser/reward-overview-owner-visual.html` — production source sha256
  `e4c25977a186f1c18f70b16a5e5b9c961a88dba052198dd29c524e1e85038bf7` (regenerated once more after
  the rebase onto v297, which moved the shared stylesheet again). Its generator's `growBack`
  slice was anchored on `function growBackActionHtmlV138`, which this release deletes; it is
  re-anchored on `function activeGroupKey(pageKey)` — the same block, named by what survived.
- `tests/browser/v129-trial-test-visual.html` and `tests/browser/v145-launch-freeze-visual.html`
  regenerated from current production source; their acceptance tests pass.

## Test pins retargeted (never weakened)

- `v138-auth-grow-closure` — "every editable Grow submodule offers a stable return to the one
  overview" became "the stable return is the rail, not a per-page back button". The requirement (no
  submodule is a dead end) is asserted against the rail group that now carries it.
- `v271-programme-overview-and-point-system-row` — the strip assertions become assertions on the
  three hashes and the rail's generic `navViewActiveV296` resolver, plus `doesNotMatch` on the
  removed control.
- `v240-points-and-tiers-together` — the deleted "both live" sentence is replaced by direct
  assertions on the tile status keys, which is tighter than the copy it pinned.
- `v230-one-loyalty-model` — the option label pin follows the rename; the option VALUE pin is
  unchanged.
- `v259-points-provenance-and-brand-move` — "paused is not 'not set up yet'" is now asserted on the
  programme row's Paused pill instead of the deleted paragraph, with the "never set up" sentence
  still pinned.
- `v243` / `v269` / `v288` — section anchors follow `customerInterfacePageV243(hashParam)`; the
  V269 heading list follows the renamed and added sections.
- `verify-v294-owner-batch-walkthrough.mjs` — the c360 programme-row needle follows the rename.

Each retarget carries a V296 comment naming the owner instruction that moved it.
