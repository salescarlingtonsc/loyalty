# V244 — customer nav revamp: Home · Rewards · Scan · Explore · Bookings (2026-08-08)

Owner, with a Grab home-screen reference (bottom bar circled):

> "4 modules below (home / rewards / scan / explore / bookings) … explore = search for nearby
> peekaa businessess (can type example food near me, chicken rice, dessert shop etc) - then will
> pop up relevant business based on search - like google search)"

## What shipped

**Navigation** — five slots, matching the reference:

| Slot | What it is |
| --- | --- |
| Home | unchanged — expiring rewards, then offers |
| Rewards | the existing My Rewards tab, shortened label, count badge kept |
| **Scan** | the raised coral centre control (Grab-style FAB). Same action, same `customerNavScan` id, same scanner — it returned from the header, where v195 had parked it, because the reference makes scanning the app's signature action. The header keeps bell + profile only. |
| Explore | **new** — search the whole Peekaa ecosystem |
| Bookings | unchanged, count badge kept |

**Explore** — the search runs on the **server** (`customer_explore_businesses_v244`, applied to
production), because "chicken rice" should find a business that *sells* chicken rice — a fact only
the catalogue knows:

- tokenised AND match over business name, industry, active service names and active product
  names; filler words ("near", "me", "shop"…) are dropped, so "facial near me" reads as "facial";
- each result can say why it appeared — "Has: Chicken Rice" — via `match_note`;
- results carry the business logo (same customer-visible media projection as My Rewards), the
  default branch address, and the caller's own points for joined businesses;
- the empty query is the whole join-enabled directory, joined businesses first — this is the
  v242 "All businesses" section, which moved here from the bottom of Home. Its rules are
  unchanged: an unjoined business never navigates, never shows points, and says the only way in
  is the shop's own QR;
- debounced input, epoch-guarded replies (a stale response can never overwrite a newer query),
  honest loading/empty/no-match/error states with retry.

## Also in this batch (owner: "delete the duplicate reward")

Cubbly's two identical "A thank-you on your next visits" (150 points) rewards are now one. Done
through the platform's own draft → publish route (config version 18), NOT by editing published
rows — published reward configuration is immutable by trigger and stayed that way. The publish
also repaired drift the live demo switch had left: the version now records the visits basis and
the visits ladder (Basic 0 / Gold 20 / Diamond 100) that production was already running.

## Verification

- `db/tests/v244_customer_explore_search.sql` ran against production and rolled back: directory
  listing with joined-first ordering, "facial near me" finding the facial seller with the match
  named, AND semantics (an impossible extra token empties the result), unjoined rows never
  carrying a balance, anon refused.
- `tests/customer-modules/v242-business-directory.test.mjs` re-pointed at Explore — every v242
  invariant (isolation, joined/unjoined semantics, dedup by id only, honest states, escaping,
  no interpolated a11y attributes) executes the real render functions.
- `v244-explore-and-nav-390.png` — the Explore page and the five-slot nav with the centre FAB,
  rendered at 390px from production functions and CSS via the Chrome DevTools Protocol.
- Suite: 2136 tests, 13 failures — identical to the pre-existing baseline.
