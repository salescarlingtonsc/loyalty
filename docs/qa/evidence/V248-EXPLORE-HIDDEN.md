# V248 — Explore is hidden from customers (2026-08-08)

Owner: "for now - explore module (put coming soon (with a peekaa icon) - make peekaa icon move)",
then, before it shipped: **"just hide the explore button entire (so will not shown to customers)"**.

## What shipped

`CUSTOMER_EXPLORE_LIVE_V248 = false` — one constant, controlling the whole feature:

- **no tab.** The nav is four slots again: Home · Rewards · Scan · Bookings, with Scan still the
  raised centre control. The Explore entry is spread into the array conditionally, not deleted.
- **no route.** `#/customer/explore` typed by hand redirects to Home rather than rendering a page
  a customer has no way to reach from the app.
- **nothing deleted.** The finished search — v245 catalogue matching, v247 nearest-first with
  geocoding — is untouched and still fully tested. Flipping the constant to `true` restores the
  tab and the route together.

The coming-soon panel with the animated Peekaa mark was built and then removed when the owner
changed the instruction; its markup and CSS went with it rather than being left orphaned. Because
no "coming soon" string survives in shippable source, the two launch-freeze guards that ban
placeholder copy (`v145-launch-freeze-audit`, `c42-consumer-registration`) were **restored to
their original strict form** — they had been narrowed to accommodate the exception, and no longer
need to be.

## A bug caught before it shipped

Gating the nav on the constant put a `const` **read above its own declaration** — a temporal dead
zone crash at load (`Cannot access 'CUSTOMER_EXPLORE_LIVE_V248' before initialization`), which
`node --check` cannot see and no existing test would have caught. It is the same failure that
took the Appointments page down in v217. The declaration was moved above `CUSTOMER_PRIMARY_NAV`,
and a test now pins that ordering:

```
test('the flag is declared before the navigation reads it', …)
```

Verified for real, not just by assertion: the nav was rendered in headless Chrome from the
production source and reported `{"ready":true,"slots":["Home","Rewards1","Scan","Bookings1"],
"cols":4,"explore":false}`.

## Verification

- `v248-nav-without-explore.png` — the four-slot bar, rendered from production functions and CSS.
- `tests/customer-modules/v242-business-directory.test.mjs` — Explore hidden, route refusing, no
  orphaned coming-soon markup or CSS, the flag declared before use, and the whole search still
  present and asserted.
- Suite: 2183 tests, 13 failures — identical to the pre-existing baseline.
