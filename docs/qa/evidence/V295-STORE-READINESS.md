# V295 — closing the pre-store gaps: live balances and an honest notification state (2026-08-12)

Owner: "please close the gap and guide me how to publish in IOS", after choosing **customer app
in the App Store, business on the Home-Screen PWA**.

## 1 · The balance updates while the customer is looking at it

The counter moment: the customer holds the phone showing their QR, staff record the sale, the
customer looks back. The wallet only ever read on render, so the new balance was invisible until
they navigated — and a balance earned while the phone was in a pocket was stale on return.

**Deliberately NOT a realtime socket.** Verified against production: customers hold no SELECT
policy on `points_ledger` or `credit_ledger` — the only read policies are
`app.has_perm(business_id,'view_sales')` (staff) and super-admin. Supabase `postgres_changes`
applies RLS, so a customer subscription would deliver nothing, and widening the ledger's read
policy to drive an animation would trade the most sensitive table in the system for a UI nicety.

Instead, `watchCustomerWalletV295`:

- **foreground return → immediate re-read** (the common case);
- **a slow poll while actually watching** — 20 s, paused whenever the tab is hidden, capped at 9
  ticks (~3 minutes) so a phone left face-up on a counter stops costing queries; any customer
  action re-renders and re-arms it;
- every tick epoch- **and** DOM-guarded, so a stale page can never repaint over a newer one;
- torn down by `disposeCurrentRoute()` like every other customer overlay, and starting one stops
  the previous.

**Verified in a real browser** (extracted production function, Chromium): hiding the tab produced
no read; returning to the foreground produced exactly one; a hidden tab did not poll; and a page
whose epoch had moved on stopped refreshing.
`{"afterHide":0,"afterReturn":1,"hiddenNoPoll":true,"staleStopsRefreshing":true}`

## 2 · The native app stops hiding notifications

The device-notifications card was simply removed in the native shell, so an App Store customer had
no idea notifications existed at all. It now states the truth — updates arrive in the Peekaa
inbox, lock-screen alerts are not switched on for this app yet — with a button to the inbox that
does work.

## 3 · Native push: sequenced, not skipped

Web Push works in Home-Screen web apps but not inside a WebView, so lock-screen alerts in the iOS
app need Apple's APNs. That requires a `.p8` key which cannot exist until the owner completes
Apple Developer enrolment (Step 1 of the runbook), and shipping an untested push entitlement into
a first App Review is a bad trade. Recorded as build 2 in
[IOS-APP-STORE-RUNBOOK.md](../../release/IOS-APP-STORE-RUNBOOK.md), to be built and tested through
TestFlight once the key exists.

## Store-side state

`npm run mobile:store:validate` passes (icons + Apple third-party privacy manifests; the check
fails closed). `npm run mobile:sync` runs clean and stages today's web build — including v290,
v291 and v294 — into the Xcode project with all Capacitor plugins registered.

Suite 2788/2788.
