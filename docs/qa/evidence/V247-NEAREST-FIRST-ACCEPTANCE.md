# V247 — Explore sorts nearest first, and the nav count moves to the corner (2026-08-08)

Owner: "yes please add the geocoding + nearest first sorting" and "the rewards showing (2) - it
should be at top right (not below)".

## 1 · The count badge

It was in the flow, under the label, which pushed that tab taller than its neighbours. It is now
an absolutely-positioned corner badge on its own tab — the way every app marks a tab with
something waiting. Nothing else about the nav changed.

## 2 · Nearest first

Three pieces, because "nearest" needed all three:

**Where a location lives** — `branches.latitude/longitude`, plus the provenance a derived value
must carry: `geocoded_address` (the exact text the coordinates came from), `geocoded_at`,
`geocode_source`. Provenance is what makes it re-checkable: edit the branch address and the
stored `geocoded_address` no longer matches, so the geocoder re-runs. A coordinate with no record
of where it came from is a guess. A check constraint makes the pair all-or-nothing and on-planet.

**How far** — `app.v247_distance_km`, plain haversine on a 6371 km sphere. No PostGIS: the
directory is tens of rows and every input is already in the row being scanned.

**The geocoder** — `scripts/geo/geocode-branches.mjs`, using OneMap, Singapore's official mapping
service (no key, no account, and it understands local address forms). It is idempotent by
provenance, and it **refuses** anything ambiguous: OneMap answers "ang mo kio" with ten distinct
places, and the script writes nothing rather than picking one. A wrong pin is worse than no pin —
no pin says "we don't know", a wrong pin sends a customer to the wrong shop.

It also tries candidates strongest-signal first, because OneMap matches address *forms*, not free
text. Verified live: `"313 Orchard Road, Singapore 238895"` returns **nothing**, while the postal
code `238895` alone resolves exactly. Owners type the full thing, so the ladder is: six-digit
postal code → address stripped of unit/country noise → the raw text.

**In the app** — a "Near me" toggle. The customer's position is a function ARGUMENT: never
stored, never logged, never written to a row, and forgotten the moment the toggle goes off. With
a position, results order nearest first, each row shows its distance, and businesses with no
address are **shown last, never dropped** — a customer must not lose a business they belong to
because its owner has not typed an address. The list says so out loud: "Nearest first · 2
businesses have no address yet, shown last". Denial is treated as a decision, not an error:
"Location is off for this site" and the list stays.

A firm with several outlets is as far away as its **nearest** outlet, not whichever branch row
happened to sort first.

## Verification

`db/tests/v247_explore_nearest_first.sql`, run against production and rolled back:

- haversine against a known pair (Orchard→Changi, ~18.4 km) within 100 m, identity = 0, and a
  missing coordinate = null rather than 0;
- with a position, a located business is first with its distance, unlocated last with null, and
  the result count is identical to the unsorted list — nothing dropped;
- the same shop is farther from Woodlands than from Orchard, so distance follows the caller;
- an out-of-range position is **ignored, not clamped** — the list falls back to name order;
- the caller's position is not written to any row;
- a client still sending only `p_query` resolves to the new signature; anon still refused.

`tests/customer-modules/v242-business-directory.test.mjs` (+8 tests) executes the real render
functions. One of them caught a real bug before it shipped: `Number(null)` and `Number('')` are
both `0`, so an unlocated business would have rendered "50 m". The helper now rejects anything
that is not genuinely a number.

`v247-explore-nearest-first-390.png` — Near me on, distances, the "shown last" line, and the
corner badges, rendered at 390px from production functions and CSS.

Suite: 2148 tests, 13 failures — identical to the pre-existing baseline.

## What the owner needs to know

**Almost no business has an address yet.** Of the join-enabled directory, only the demo tenant
now has one. Nearest-first is live and correct, but it can only rank what it can locate:

- businesses enter their address in Settings → Branches;
- then `node scripts/geo/geocode-branches.mjs` fills the coordinates (I can run it on request);
- until then those businesses appear at the bottom of a Near me search, clearly marked.

To make the feature demonstrable I set the **demo tenant's** default branch (Cubbly · Orchard,
already named for Orchard) to `313 Orchard Road, Singapore 238895` and geocoded it. That is demo
data on the demo tenant — change it in Settings whenever you like. No real tenant's address was
invented.
