# V281 — Profile joins the nav, Scan opens straight into the camera (2026-08-12)

Owner: "change it to scan in the middle and add a profile module at the most right. so 2 left 1
qrcode scanning (must show scan, currently need to choose to upload or scan, just show scan
first.)"

## The navigation

Five slots: **Home · Rewards | Scan (raised centre FAB) | Bookings · Profile**. Profile was
reachable only through the header avatar menu — two taps behind an icon; the owner promoted it
to a first-class destination. The route and page (`#/customer/profile`, `renderCustomerProfile`)
already existed; only the nav entry is new. Grid goes `1fr 1fr auto 1fr 1fr`; the Rewards and
Bookings badges are untouched. Explore stays fully hidden behind `CUSTOMER_EXPLORE_LIVE_V248`.

Rendered in headless Chrome at 390 px from the real extracted nav + real CSS:
`{"slots":["Home","Rewards","Scan QR","Bookings","Profile"],"scanIdx":2,"cols":5,`
`"profileHref":"#/customer/profile"}` — five slots, scan centred, profile rightmost, no
horizontal overflow. Screenshot: `v281-nav-390.png`.

## The scanner

Tapping Scan **is** the consent to scan, so the second "Open camera" tap was pure friction — the
camera now starts the moment the sheet opens. The upload/paste fallbacks still exist (desktop
with no camera, a screenshot of a QR) but wait hidden behind one small "Can't scan? Use a photo
or link" control, and **reveal themselves automatically the moment the camera cannot start** —
opening the paste path and focusing the image input, exactly the behaviour the v167 acceptance
pins. A camera failure also re-shows the camera button as a retry. If the user closes the sheet
while the camera is still being granted, the just-arrived stream is stopped, never leaked.

Proven in headless Chrome with `mediaDevices` absent: sheet opens →
`"Camera is unavailable in this browser. Choose a QR image or paste the QR link."`,
fallback revealed, paste open, manual toggle hidden. Screenshot: `v281-scan-390.png`.

## Test pins moved deliberately

phase1 (`{key:` count 5→6, `key:'profile'` now allowed, grid 4→5 columns), v195 (same),
v242 (grid comment), and the v167 browser fixture's camera step (auto-start replaces the tap).
