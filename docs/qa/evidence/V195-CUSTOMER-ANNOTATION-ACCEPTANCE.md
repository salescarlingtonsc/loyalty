# V195 — customer surface, owner annotation batch (2026-08-08)

Source: seven annotated screenshots of production (build `72621e6c4dee`) taken on
7 August 2026 between 23:17 and 23:32.

## What each annotation asked for, and what shipped

| # | Screen | Owner's mark | Shipped |
| --- | --- | --- | --- |
| 1 | Home | "before limited offers i want to see a glance of my expiring rewards" | `customerExpiringRewardsMarkupV195` renders above the offers shelf: the points expiring within 30 days per business, soonest first, the within-7-days row in red. Built from the wallet cards Home already fetched — no extra request. |
| 2 | My Rewards | search field drawn beside the title; "1 linked reward account" struck out | A company-name search filters the tiles already on the page; the subtitle and its helper are gone (the tab badge and each category already print the count). |
| 3 | Programme | "Cubbly Stamp ·" struck out | The header shows the company name, then tier and "Address, phone and offers ›". The programme's own name is not repeated under it. |
| 4 | Programme | "add logo" on both tabs | Tier carries a star, Reward points a redeem glyph. |
| 5 | Programme | star / crown / gem drawn on the tier bar | Each rung marker carries a pictogram by position: first star, top gem, everything between a crown — so a Bronze/Silver/Gold ladder reads the same way. Two new icons (`crown`, `diamond`) added to the shared icon set. |
| 6 | Programme | the whole "Rewards" card crossed out | The card is gone. The reward list it contained — the only way to redeem — moved into the **Reward points** tab, under the balance that pays for it. The repeated balance and the three-step "how rewards work" strip went with the card; one line of instruction survives on the list itself. |
| 7 | Bookings | Scan QR circled, arrow to the header | The scanner is now a header control beside notifications, on every customer screen. The nav is three destinations. Scanning is an action that returns you where you were, not a fourth page. |
| 8 | Bookings | "put filter time here" | A time window (Any time / 7 / 30 / 90 days) beside the page title. Client-side over the same fetched records; Ongoing looks forward, Cancelled and History look back. |
| 9 | Bookings | "company photo" circled next to the name | The business logo heads each booking group, with its initial as the fallback. Logos come from the same media projection My Rewards uses. |
| 10 | Offer sheet | "50% off first prata ← remove this" | A line that only repeats the offer title is dropped — on the card as well as the sheet — compared on letters and digits, so a subset is recognised. |
| 11 | Offer sheet | description tail struck through | "Available until <date>." and the call-to-action sentence are copy **this app** generated (`promotionCopyAssistV104`), repeating the validity row and the button beneath them. Only those exact generated sentences are trimmed; a merchant's own words, including their own dates, are untouched. |
| 12 | Offer sheet | "add book appt button" | A Book now button, rendered only once the business itself confirms customer booking is enabled (the v183 fail-closed rule) — it can never send a customer to a booking page that will refuse them. |
| 13 | Offer sheet | "→ address phone number", "click here straightaway go company profile" | The company row shows the branch address and phone as they load, and its label says where it goes; one tap opens the company profile. |

## Evidence

- `v195-customer-surfaces-390.png` — the expiring glance, My Rewards search, the
  Tier tab with its rung pictograms, and the Bookings filter + company photo,
  rendered at 390px from the **production functions and production CSS** (sliced
  out of `app/index.html` and `app/app.js`, not re-typed).
- `v195-reward-points-tab-390.png` — the Reward points tab, with the relocated
  reward host in place.
- Captures were driven through the Chrome DevTools Protocol from Node's built-in
  WebSocket client against installed Chrome (`--headless=new`).

## Automated coverage

`tests/customer-wallet/v195-owner-annotations.test.mjs` — 21 tests, all executing
the real production functions rather than asserting on markup alone:

- the expiring glance orders by date, marks only the ≤7-day row urgent, states the
  honest empty case, renders nothing for a customer with no reward accounts, and
  contains no RPC call;
- the search filters, restores, hides empty category headings, and never re-reads
  the wallet;
- the rung pictogram mapping over 2, 3 and 5-rung ladders;
- the booking time window in both directions, and that a record with no usable
  time is never silently hidden;
- the description trimmer against real generated copy **and** against merchant
  copy that merely resembles it;
- the sheet's Book now fail-closed gate, and that the redeem control survived the
  removal of the card that used to wrap it.

## Suite

1988 tests, 13 failures — identical to this branch's pre-existing baseline,
verified by running the suite in a clean worktree at the merge-base.
