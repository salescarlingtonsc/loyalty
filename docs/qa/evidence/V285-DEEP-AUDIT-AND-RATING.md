# V285 — deep app audit: scores, what was fixed, what remains (2026-08-12)

Owner: "i need you to do a deep analysis of the app's function/modules/buttons and UI UX. i need
you to rate it over 10. and i need you to close the gap."

Method: nine parallel auditors (one per surface) traced every rendered interactive element to its
wiring, every async path to its stale-render guard and error state, and the 390 px CSS reality;
every blocker/major finding was then **adversarially verified by an independent agent told to
refute it**. 39 serious findings checked, 34 survived, 5 refuted (recorded below so they are not
re-reported). 6 surviving blockers → 5 confirmed; all 5 fixed in this commit, plus 1 major.

## Scores (before → after this commit's fixes)

| Surface | Function | UX | What moved the score |
|---|---|---|---|
| Scan + join | 5 → 7.5 | 7 | both dead-ends fixed (same-hash nav) |
| My Rewards | 6 → 7 | 6 | search actually filters now |
| Bookings | 6.5 | 7 | unchanged — majors remain (no cancel affordance, stale states) |
| Home | 7 | 7 | unchanged — majors remain (inbox blocks first paint, expiring count) |
| Profile + nav | 7 | 7 | Profile now first-class in the nav (v281) |
| Till / Record sale | 5 → 7 | 7 | cross-customer entitlement leak fixed |
| Dashboard + Grow | 7 | 7.5 | model-switch "blocker" was refuted (owner-only + RLS agree) |
| Promotions + share | 6 → 7.5 | 6 → 7 | imageless share fixed; auto-redirect removed |
| Cross-cutting (auth, routing, a11y) | 8 | 8 | strongest surface |

**Overall: 6.5/10 before this commit → 7.5/10 after.** The remaining half-point gaps to 8+ are
the confirmed majors below; the path to 9+ is closing the booking-management loop on the
customer side and the empty-state/first-paint work on Home.

## The five blockers, all fixed here

1. **QR sign-up ended on a dead "Creating your account…" button.** After registration the code
   ran `nav('#/join')` — but the page was already at `#/join`, and assigning `location.hash` its
   current value fires no `hashchange`. The brand-new customer sat on a spinner forever. Fixed
   with an explicit `route()` when already there; same fix for the second site below.
2. **Rescanning from the expired-QR screen did nothing.** Same same-hash no-op: the new token was
   remembered and never submitted.
3. **My Rewards search filtered nothing.** It set `[hidden]` on tiles whose own
   `display:block` class beats the UA sheet — the status line said "3 matches" while every tile
   stayed visible. Two CSS rules fix it; proven by computed style in headless Chrome.
4. **The till offered customer B customer A's packages, vouchers and welcome offer.** The
   catalogue snapshot (which carries the looked-up customer's entitlements) was only dropped for
   walk-ins. This could consume A's paid sessions on B's sale. Every return to the phone step now
   drops the snapshot.
5. **A shared link for an imageless offer 302'd the recipient to the marketing homepage.** The
   share RPC still required published artwork — a rule v172/v173 deliberately removed from every
   customer surface. Migration v285 (applied to production, verified rolled back) restores the
   parity; the page falls back to a summary card.

Plus one major: the `/o/` page **no longer auto-redirects after 1.2 s** into a booking wizard
that never shows the offer. The page is the destination; "View this offer" carries the reader on.

One reported blocker was **refuted** and not acted on: "points-model switch reports success on a
filtered write" — the button renders only for owners, and the RLS write policy admits exactly the
same owners, so the silent-204 path cannot occur for anyone who can press it.

## Confirmed majors NOT yet fixed (the remaining gap, worst first)

**Bookings** — the weakest loop in the product: the customer Bookings page has no cancel or
reschedule affordance at all (only the guest manage-token flow has one); the portal Change
button ignores `appointment_changes_enabled`; the manage panel doesn't refresh after a cancel;
the page load has no timeout; six computed partial-failure messages are never rendered; guest
lookup prints browser-timezone times instead of SGT.

**Home** — first paint is blocked by an unbounded inbox sync; the "expiring rewards" pill counts
a truncated list; a fresh account can render two "nothing" cards with no next action.

**Profile** — a transient profile-read failure shows as a permanent "not available for this
account"; marketing-consent failure has no retry; preferred language saves a value nothing reads
(EN-only surface).

**Till** — no staff-attribution picker in the itemized checkout (quick flow has it); a branch
switch during catalogue load can leave the other branch's items sellable; Back abandons a live
PayNow attempt.

**Dashboard/Grow** — inactive tile counts 30+ but drills into 30–59 only; a failed inactive-60
read renders as "0 · Stable"; a scheduled promotion lists under "Ongoing"; category drill
sticks across navigation.

**Scanner/i18n** — a blocked jsQR CDN is reported as a camera failure; the scan sheet and #/join
are hardcoded English on an otherwise translated surface.

**Share/native** — the Capacitor native app never reaches the OS share plugin (web
`navigator.share` only); the merchant preview card has live controls that can discard an unsaved
draft; wallet "View details" opens a poorer modal than Home's sheet.

**Cross-cutting** — signed-out deep link to `#/customer/communications` lands on the *business*
sign-in card; reward/tier dialogs bypass `CUI.activateDialog` (no focus trap/Back handling).

Refuted (do not re-report): guest/signed-in cancel asymmetry; manage-booking cancel path;
Bookings badge staleness (no cancel control exists on that page to stale it); sign-out
error-swallowing (supabase-js clears local session regardless); the points-model silent write.

25 minor/polish findings are retained in the session audit data.

---

## Addendum (v286–v289, same day): the remaining-gap list above is CLOSED

Nine parallel surface owners re-verified every remaining finding before touching it and fixed
all that reproduced; three items were found already fixed at HEAD (till staff picker — v287;
the dashboard inactive tile — v287; imageless share — v285) and were pinned instead. One item
was structurally out of client scope and got its own migration: **v289** (applied to production,
verified) makes `internal_public_booking_change` enforce `appointment_changes_enabled`
server-side for reschedules — cancel deliberately stays ungated, because refusing a
cancellation only manufactures a no-show.

Deliberately not "fixed": the scanner/join English copy (the customer surface is EN-only by
product state — a pin now fails the day a second locale lands), the session-only sound
preference (a product decision), and the index.html chunk preloader's pathname blind spot
(inline HTML script, flagged with its covering test named).

Post-closure scores: Bookings 6.5 → 8 (change/cancel on the page, deadlines, honest partial
failures, SGT), Home 7 → 8, Profile 7 → 8, Till 7 → 8, Dashboard/Grow 7 → 8, Share 7.5 → 8,
Scanner 7.5 → 8. **Overall: 8/10.** The remaining distance to 9+ is feature depth (customer-side
withdrawal of un-actioned booking *requests* needs new server surface; per-offer share pages
with live state), not defects.

Suite at close: 2708/2708. Every fix pinned by a v286+ test; fixtures and evidence recaptured
from merged sources; live build 30275c83cf7a serves byte-identical chunks containing every fix.
